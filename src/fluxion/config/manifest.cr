module Fluxion::Config
  # The `WorkstationProfile` document.
  #
  # `spec.phases[]` becomes the profile's phase DAG and each phase's `steps[]`
  # its steps. `spec.target.os` is informational: it is mapped so validation,
  # state, and reports have a declared target, but host facts and `when` rules
  # decide what actually runs.
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

      phases, skipped = parse_phases(context, spec["phases"], target)
      validate_graph(context, phases)

      sources, skipped_sources = parse_sources(context, spec["sources"], phases.flat_map(&.steps))

      Profile.new(
        name,
        target,
        phases,
        policy: policy,
        skipped_plan_entries: skipped + skipped_sources,
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
      if name.includes?(' ')
        context.error(metadata["name"].path, "must not contain spaces")
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
        # The accepted list is derived rather than written out, so adding a
        # distribution cannot leave this hint naming an outdated set.
        accepted = "one of #{Distribution.values.map(&.config_name).join(", ")}"
        if raw.nil? || raw.strip.empty?
          context.error(os["distribution"].path, "is required", accepted)
        else
          context.error(os["distribution"].path,
            "unsupported target OS distribution: #{raw.strip}", accepted)
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

    # -- phases -------------------------------------------------------------

    # Names are tracked as name => declaring path so a duplicate can point at
    # the first occurrence, which is the one the user has to look at.
    private record Names,
      phases : Hash(String, String) = {} of String => String,
      steps : Hash(String, String) = {} of String => String

    private def parse_phases(context : Context, node : Node, target : TargetOs) : {Array(Phase), Array(SkippedPlanEntry)}
      phases = [] of Phase
      skipped = [] of SkippedPlanEntry

      if node.items.empty?
        context.error(node.path, "at least one phase is required")
        return {phases, skipped}
      end

      names = Names.new
      node.each_item do |entry, _|
        phases << parse_phase(context, entry, target, names, skipped)
      end

      {phases, skipped}
    end

    private def parse_phase(context : Context, entry : Node, target : TargetOs,
                            names : Names, skipped : Array(SkippedPlanEntry)) : Phase
      name = context.optional_string(entry["name"])
      if name.nil?
        context.error(entry["name"].path, "must not be blank")
      elsif previous = names.phases[name]?
        context.error(entry["name"].path, "duplicates phase '#{name}' first declared at #{previous}")
      else
        names.phases[name] = entry["name"].path
      end
      label = name || "<unnamed>"

      # A phase whose `when` is unmet contributes no steps, but every one of
      # them is still recorded as skipped: a step that vanishes from `plan`
      # looks like it was never in the profile.
      condition = ConditionParser.parse(context, entry["when"])
      unmet = condition.try(&.unmet_reason(context.host) { |command| Host.command_exists?(command) })

      steps_node = entry["steps"]
      context.error(steps_node.path, "at least one step is required") if steps_node.items.empty?

      steps = [] of Step
      steps_node.each_item do |step_node, _|
        step = parse_step(context, step_node, target, names, skipped, label, unmet)
        steps << step if step
      end

      # The policy is still parsed when the phase is skipped, so a malformed
      # one is reported, but it is not carried: a phase that ran nothing has
      # nothing for the user to log out of.
      restart_policy = parse_restart_policy(context, entry["restartPolicy"])
      restart_policy = RestartPolicy::None.new if unmet

      Phase.new(
        label,
        steps,
        depends_on: entry["dependsOn"].string_list,
        restart_policy: restart_policy,
        continue_on_step_error: context.bool(entry["execution"]["continueOnError"], true),
        description: context.optional_string(entry["description"]) || "",
      )
    end

    private def parse_restart_policy(context : Context, node : Node) : RestartPolicy
      return RestartPolicy::None.new unless node.present?

      type_node = node["type"]
      case type_node.string?.try(&.strip.downcase)
      when "none", nil
        RestartPolicy::None.new
      when "prompt-logout"
        RestartPolicy::PromptLogout.new(
          context.optional_string(node["message"]) || RestartPolicy::PromptLogout::DEFAULT_MESSAGE)
      when "requires-new-shell"
        shell = ShellKind.from_config?(node["shell"].string?)
        if node["shell"].present? && shell.nil?
          context.error(node["shell"].path, "unsupported shell", "one of zsh, bash, sh")
        end
        RestartPolicy::RequiresNewShell.new(shell || ShellKind::Zsh)
      else
        context.error(type_node.path,
          "unsupported restart policy '#{type_node.string?}'",
          "one of #{RestartPolicy::TYPES.join(", ")}")
        RestartPolicy::None.new
      end
    end

    # -- steps --------------------------------------------------------------

    private def parse_step(context : Context, entry : Node, target : TargetOs, names : Names,
                           skipped : Array(SkippedPlanEntry), phase : String, phase_unmet : String?) : Step?
      name = context.optional_string(entry["name"])
      if name.nil?
        context.error(entry["name"].path, "must not be blank")
      elsif previous = names.steps[name]?
        # Step names are the handle for `state forget`, `explain --item`, and
        # the TUI selector, so they are unique across the whole profile rather
        # than only within a phase.
        context.error(entry["name"].path, "duplicates step '#{name}' first declared at #{previous}")
      else
        names.steps[name] = entry["name"].path
      end
      label = name || "<unnamed>"

      kind = step_kind(context, entry)
      return unless kind

      if phase_unmet
        skipped << SkippedPlanEntry.new(label, kind.id, "phase #{phase} when.#{phase_unmet}")
        return
      end

      condition = ConditionParser.parse(context, entry["when"])
      reason = condition.try(&.unmet_reason(context.host) { |command| Host.command_exists?(command) })
      if reason
        skipped << SkippedPlanEntry.new(label, kind.id, "when.#{reason}")
        return
      end

      build_step(context, entry, kind, label, condition, target)
    end

    private def step_kind(context : Context, entry : Node) : PlanKinds::Kind?
      node = entry["kind"]
      raw = node.string?
      if raw.nil? || raw.strip.empty?
        context.error(node.path, raw.nil? ? "is required" : "must not be blank")
        return
      end

      id = raw.strip.downcase
      kind = PlanKinds.find(id)
      unless kind
        context.error(node.path, "unsupported step kind '#{raw.strip}'", PlanKinds.suggestion_for(id))
        return
      end
      kind
    end

    private def build_step(context : Context, entry : Node, kind : PlanKinds::Kind,
                           name : String, condition : Condition?, target : TargetOs) : Step?
      spec = entry["spec"]
      description = context.optional_string(entry["description"])
      probe = context.optional_string(spec["probeCommand"])

      # Control kinds describe an interaction rather than an installation, so
      # they are allowed to carry nothing but a name.
      if kind.category.installer? && !spec.present?
        context.error(entry.path, "spec is required for step '#{name}'")
        return
      end

      continue_on_error = context.bool?(entry["execution"]["continueOnError"])
      continue_on_error = context.bool?(spec["continueOnError"]) if continue_on_error.nil?

      step = build_kind_step(context, spec, kind, name, description, probe)
      return unless step

      validate_package_manager(context, step, entry, target, condition)

      # `execution.continueOnError` overrides whatever the step kind defaults
      # to, so it is applied after construction rather than threaded through
      # every parser.
      step.condition = condition if condition
      step.continue_on_error = continue_on_error unless continue_on_error.nil?
      step
    end

    private def build_kind_step(context : Context, spec : Node, kind : PlanKinds::Kind, name : String, description : String?, probe : String?) : Step?
      case kind.category
      in PlanKinds::Category::Packages
        StepParser.manifest_packages(context, spec, kind, name, description, probe)
      in PlanKinds::Category::Apps
        StepParser.manifest_flatpak(context, spec, name, description, probe)
      in PlanKinds::Category::Sdkman
        StepParser.manifest_sdkman(context, spec, name, description, probe)
      in PlanKinds::Category::Control
        # `interrupt` is the one control kind with no step type behind it; the
        # rest share the ordinary builders.
        return StepParser.manifest_interrupt(context, spec, name, description) if kind.id == "interrupt"
        build_by_step_type(context, spec, kind, name, description, probe)
      in PlanKinds::Category::Installer
        return StepParser.manifest_file_writes(context, spec, name, description, probe) if kind.id == "file-writes"
        build_by_step_type(context, spec, kind, name, description, probe)
      end
    end

    private def build_by_step_type(context : Context, spec : Node, kind : PlanKinds::Kind, name : String, description : String?, probe : String?) : Step?
      type = PlanKinds::STEP_TYPES[kind.id]?
      unless type
        # A kind listed in `PlanKinds::ALL` but missing from `STEP_TYPES` used to
        # return nil here, and the nil was swallowed twice on the way out — so
        # `fluxion kinds` listed the kind, `fluxion validate` reported success,
        # and the step simply vanished from `plan` and `apply` with nothing said.
        # The executor side has always been loud about a missing executor; this
        # matches it.
        context.error(spec.path, "step kind '#{kind.id}' has no builder registered")
        return
      end
      StepParser.build_kind(context, spec, type, name, description, probe)
    end

    # A profile that targets Fedora but installs with apt fails late and
    # confusingly. Catching it at parse time costs nothing.
    private def validate_package_manager(context : Context, step : Step, entry : Node,
                                         target : TargetOs, condition : Condition?) : Nil
      manager = case step
                when PackagesStep     then step.package_manager
                when SystemUpdateStep then step.package_manager
                end
      return unless manager

      # Cargo owns its own tree rather than the distribution's, so no target
      # rules it out; only the managers a distribution actually ships are
      # worth checking against one.
      return unless Distribution.values.any?(&.package_managers.includes?(manager))

      # A step guarded by a distribution rule is deliberately for a machine
      # other than the declared target — the whole point of one profile that
      # bootstraps several distributions. Checking it against the target would
      # reject the pattern the schema exists to support, and only on the hosts
      # where that branch is actually selected.
      return if condition.try(&.narrows_distribution?)

      expected = target.distribution.package_managers
      return if expected.includes?(manager)

      context.error("#{entry.path}.kind",
        "package manager #{manager} is not valid for target #{target.distribution}",
        "expected #{expected.join(" or ")}")
    end

    # Every dependency must name a declared phase, otherwise the execution
    # order is undefined rather than merely surprising.
    private def validate_graph(context : Context, phases : Array(Phase)) : Nil
      names = phases.map(&.name).to_set
      phases.each_with_index do |phase, index|
        phase.depends_on.each do |dependency|
          next if names.includes?(dependency)
          context.error("spec.phases[#{index}].dependsOn",
            "phase '#{phase.name}' declares dependency on unknown phase '#{dependency}'")
        end
      end

      # A cycle can only be looked for once the graph is otherwise sound; a
      # missing or duplicated name would report as a cycle and mislead.
      return if context.diagnostics.errors?

      begin
        Profile.new("graph-check", TargetOs.new(Distribution::Fedora), phases).ordered_phases
      rescue error : ConfigError
        context.error("spec.phases", error.message || "cycle in phase dependency graph")
      end
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
