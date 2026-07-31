module Fluxion::Config
  # The `WorkstationProfile` manifest frontend.
  #
  # One ordered plan, selected by host facts and per-entry `when` rules, rather
  # than the stable schema's job DAG. `spec.target.os` is informational: it is
  # mapped so validation, state, and reports have a declared target, but it
  # never decides what runs.
  module Manifest
    extend self

    SUPPORTED_API_VERSION = "initkit.io/v1alpha1"
    SUPPORTED_KIND        = "WorkstationProfile"

    def parse(context : Context, root : Node, path : String) : Profile
      interpolator = Interpolator.new(context.host, context.diagnostics)
      document = interpolator.interpolate(root)
      root = Node.root(document)

      validate_header(context, root)
      name = parse_metadata(context, root)
      spec = root["spec"]

      target = parse_target(context, spec["target"])
      policy = parse_policy(context, spec["policy"])

      selection = select_plan_entries(context, spec["plan"])
      steps = selection.selected.compact_map { |entry| plan_step(context, entry) }
      sources, skipped_sources = parse_sources(context, spec["sources"], steps)

      Profile.new(
        name,
        target,
        [Job.new(
          Profile::MANIFEST_JOB_NAME,
          steps,
          description: "WorkstationProfile plan",
          # A manifest is an ordered plan the user wrote as a sequence; if an
          # entry fails, later entries usually depend on it.
          continue_on_step_error: false,
        )],
        policy: policy,
        skipped_plan_entries: selection.skipped + skipped_sources,
        source_setups: sources,
        base_dir: context.base_dir,
      )
    end

    private def validate_header(context : Context, root : Node) : Nil
      check_header(context, root["apiVersion"], "apiVersion", SUPPORTED_API_VERSION)
      check_header(context, root["kind"], "kind", SUPPORTED_KIND)
    end

    private def check_header(context : Context, node : Node, field : String, expected : String) : Nil
      value = node.string?
      if value.nil? || value.strip.empty?
        context.error(node.path.empty? ? field : node.path, "is required and must be '#{expected}'")
        return
      end
      return if value.strip == expected
      context.error(node.path, "must be '#{expected}' but was '#{value.strip}'")
    end

    private def parse_metadata(context : Context, root : Node) : String
      metadata = root["metadata"]
      unless metadata.present?
        context.error("metadata", "metadata is required")
        return "workstation"
      end

      name = context.optional_string(metadata["name"])
      if name.nil?
        context.error(metadata["name"].path, "must not be blank")
        return "workstation"
      end
      name
    end

    private def parse_target(context : Context, node : Node) : TargetOs
      unless node.present?
        context.error("spec.target", "spec.target is required")
        return TargetOs.new(Distribution::Fedora)
      end

      os = node["os"]
      unless os.present?
        context.error(os.path, "spec.target.os is required")
        return TargetOs.new(Distribution::Fedora)
      end

      distribution = Distribution.from_config?(os["distribution"].string?)
      unless distribution
        raw = os["distribution"].string?
        if raw.nil? || raw.strip.empty?
          context.error(os["distribution"].path, "is required")
        else
          context.error(os["distribution"].path, "unsupported target OS distribution: #{raw.strip}")
        end
        distribution = Distribution::Fedora
      end

      # Debian and Ubuntu identify releases by codename first; everywhere else
      # a release or version number is the useful label.
      release = if distribution.debian? || distribution.ubuntu?
                  context.optional_string(os["codename"]) ||
                    context.optional_string(os["release"]) ||
                    context.optional_string(os["version"])
                else
                  context.optional_string(os["release"]) || context.optional_string(os["version"])
                end

      TargetOs.new(distribution, release)
    end

    private def parse_policy(context : Context, node : Node) : Policy
      return Policy.empty unless node.present?

      state_path = node["statePath"]
      if state_path.present? && context.optional_string(state_path).nil?
        context.error(state_path.path, "must not be blank")
      end

      Policy.new(
        dry_run: context.bool?(node["dryRun"]),
        continue_on_error: context.bool?(node["continueOnError"]),
        require_sudo: context.bool?(node["requireSudo"]),
      )
    end

    # -- plan selection -----------------------------------------------------

    private record Selection,
      selected : Array(Node),
      skipped : Array(SkippedPlanEntry)

    private def select_plan_entries(context : Context, plan : Node) : Selection
      selected = [] of Node
      skipped = [] of SkippedPlanEntry
      seen = {} of String => String

      plan.each_item do |entry, _|
        name = context.optional_string(entry["name"])
        if name.nil?
          context.error(entry["name"].path, "must not be blank")
        elsif previous = seen[name]?
          context.error(entry["name"].path,
            "duplicates plan entry '#{name}' first declared at #{previous}")
        else
          seen[name] = entry["name"].path
        end

        kind_node = entry["kind"]
        raw_kind = kind_node.string?
        if raw_kind.nil? || raw_kind.strip.empty?
          context.error(kind_node.path, raw_kind.nil? ? "is required" : "must not be blank")
          next
        end

        kind = raw_kind.strip.downcase
        unless PlanKinds.find(kind)
          context.error(kind_node.path, "unsupported plan kind '#{raw_kind.strip}'",
            PlanKinds.suggestion_for(kind))
          next
        end

        condition = ConditionParser.parse(context, entry["when"])
        reason = condition.try(&.unmet_reason(context.host) { |command| Host.command_exists?(command) })
        if reason
          skipped << SkippedPlanEntry.new(name || "<unnamed>", kind, "when.#{reason}")
          next
        end

        selected << entry
      end

      Selection.new(selected, skipped)
    end

    # -- plan entries -------------------------------------------------------

    private def plan_step(context : Context, entry : Node) : Step?
      name = context.optional_string(entry["name"]) || "<unnamed>"
      kind_id = entry["kind"].string?.not_nil!.strip.downcase
      kind = PlanKinds.find(kind_id).not_nil!
      spec = entry["spec"]
      description = context.optional_string(entry["description"])
      probe = context.optional_string(spec["probeCommand"])
      condition = ConditionParser.parse(context, entry["when"])

      if kind.category.installer? && !spec.present?
        context.error(entry.path, "spec is required for plan entry '#{name}'")
        return
      end

      continue_on_error = context.bool?(entry["execution"]["continueOnError"])
      continue_on_error = context.bool?(spec["continueOnError"]) if continue_on_error.nil?

      step = build_plan_step(context, spec, kind, name, description, probe)
      return unless step

      # `execution.continueOnError` overrides whatever the step kind defaults
      # to, so it is applied after construction rather than threaded through
      # every parser.
      apply_entry_overrides(step, condition, continue_on_error)
    end

    private def build_plan_step(context : Context, spec : Node, kind : PlanKinds::Kind, name : String, description : String?, probe : String?) : Step?
      case kind.category
      in PlanKinds::Category::Packages
        StepParser.manifest_packages(context, spec, kind, name, description, probe)
      in PlanKinds::Category::Apps
        StepParser.manifest_flatpak(context, spec, name, description, probe)
      in PlanKinds::Category::Sdkman
        StepParser.manifest_sdkman(context, spec, name, description, probe)
      in PlanKinds::Category::Control
        StepParser.manifest_interrupt(context, spec, name, description)
      in PlanKinds::Category::Installer
        type = PlanKinds::STEP_TYPES[kind.id]?
        return StepParser.manifest_file_writes(context, spec, name, description, probe) if kind.id == "file-writes"
        return unless type
        StepParser.build_kind(context, spec, type, name, description, probe)
      end
    end

    private def apply_entry_overrides(step : Step, condition : Condition?, continue_on_error : Bool?) : Step
      step.condition = condition if condition
      step.continue_on_error = continue_on_error unless continue_on_error.nil?
      step
    end

    # -- sources ------------------------------------------------------------

    # Each section maps onto the package manager whose entries it configures.
    # `rpm` is an alias for `dnf`, and `pacman` is accepted by the schema but
    # produces no setup operations — a pacman mirror is not a finite artifact
    # Fluxion can verify.
    SOURCE_SECTIONS = {
      "apt"     => PackageManager::Apt,
      "dnf"     => PackageManager::Dnf,
      "rpm"     => PackageManager::Dnf,
      "zypper"  => PackageManager::Zypper,
      "flatpak" => PackageManager::Flatpak,
    }

    SOURCE_KINDS = {
      "apt"     => "apt-repository",
      "dnf"     => "rpm-repository",
      "rpm"     => "rpm-repository",
      "zypper"  => "zypper-repository",
      "flatpak" => "flatpak-remote",
    }

    private def parse_sources(context : Context, node : Node, steps : Array(Step)) : {Array(SourceSetup), Array(SkippedPlanEntry)}
      setups = [] of SourceSetup
      skipped = [] of SkippedPlanEntry
      return {setups, skipped} unless node.present?

      required = required_managers(steps)

      SOURCE_SECTIONS.each do |section, manager|
        section_node = node[section]
        next unless section_node.present?

        section_node.each_item do |entry, _|
          name = context.optional_string(entry["name"])
          if name.nil?
            context.error(entry["name"].path, "is required")
            next
          end

          # A section for a manager no selected entry uses is reported rather
          # than applied: adding a Debian repository on a Fedora host is work
          # the user asked for but the machine cannot use.
          unless required.includes?(manager)
            skipped << SkippedPlanEntry.new(name, "#{section}-source",
              "source section #{section} is not relevant to selected host package managers")
            next
          end

          step = StepParser.build_kind(context, entry["spec"], SOURCE_KINDS[section], name, nil, nil)
          setups << SourceSetup.new(step, manager) if step
        end
      end

      {setups, skipped}
    end

    private def required_managers(steps : Array(Step)) : Set(PackageManager)
      managers = Set(PackageManager).new
      steps.each do |step|
        case step
        when PackagesStep     then managers << normalize(step.package_manager)
        when SystemUpdateStep then managers << normalize(step.package_manager)
        when FlatpakStep      then managers << PackageManager::Flatpak
        end
      end
      managers
    end

    # AUR helpers drive pacman underneath, so a pacman source is relevant to
    # them too.
    private def normalize(manager : PackageManager) : PackageManager
      manager.aur? ? PackageManager::Pacman : manager
    end
  end
end
