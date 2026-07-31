module Fluxion::Config
  # Entry points the manifest mapper uses.
  #
  # Most plan kinds have the same spec fields as their stable-schema
  # counterpart, so they go through `build_kind` and reuse one parser. Only the
  # kinds whose shape genuinely differs — the package family, where the manager
  # comes from the kind id rather than a field — get their own function here.
  module StepParser
    # Builds a step from a plan entry's `spec` node using the stable schema's
    # parser for that `type`.
    def build_kind(context : Context, spec : Node, type : String, name : String, description : String?, probe : String?) : Step?
      build(context, spec, type, name, description, probe)
    end

    def manifest_packages(context : Context, spec : Node, kind : PlanKinds::Kind, name : String, description : String?, probe : String?) : Step?
      manager = kind.package_manager || aur_helper(context, spec)
      return unless manager

      packages_node = spec["packages"]
      packages = packages_node.items.compact_map do |entry|
        entry.scalar? ? entry.string? : context.optional_string(entry["name"])
      end

      if packages.empty?
        context.error(packages_node.path, "must contain at least one item")
      end
      packages.each_with_index do |package, index|
        validate_package_name(context, "#{packages_node.path}[#{index}]", package)
      end

      PackagesStep.new(
        name, manager, packages,
        actions: package_actions(context, spec["actions"], manager),
        description: description,
        continue_on_error: context.bool(spec["continueOnError"], true),
        probe_command: probe,
      )
    end

    # `aur-packages` is the one package kind whose manager is a choice rather
    # than a property of the kind, because paru and yay are interchangeable.
    private def aur_helper(context : Context, spec : Node) : PackageManager?
      node = spec["packageManager"]
      raw = node.string?
      if raw.nil? || raw.strip.empty?
        context.error(node.path, "must be one of paru, yay")
        return
      end

      case raw.strip.downcase
      when "paru" then PackageManager::Paru
      when "yay"  then PackageManager::Yay
      else
        context.error(node.path, "unsupported AUR helper '#{raw.strip}'", "expected paru or yay")
        nil
      end
    end

    def manifest_flatpak(context : Context, spec : Node, name : String, description : String?, probe : String?) : Step?
      # `apps` is the manifest spelling; `appIds` matches the stable schema and
      # is accepted so a fragment can be moved between the two.
      ids_node = spec["apps"]
      ids_node = spec["appIds"] unless ids_node.present?
      app_ids = ids_node.string_list

      if app_ids.empty?
        context.error(spec["apps"].path, "must contain at least one item")
      end

      FlatpakStep.new(
        name, app_ids,
        context.optional_string(spec["remote"]) || FlatpakStep::DEFAULT_REMOTE,
        description: description,
        continue_on_error: context.bool(spec["continueOnError"], true),
        probe_command: probe,
      )
    end

    def manifest_sdkman(context : Context, spec : Node, name : String, description : String?, probe : String?) : Step?
      packages_node = spec["packages"]
      candidates = packages_node.items.compact_map do |entry|
        if entry.scalar?
          value = entry.string?
          value ? SdkmanCandidate.new(value) : nil
        elsif entry.mapping?
          candidate = context.require_string(entry["candidate"], "SDKMAN candidate")
          next if candidate.empty?
          validate_sdkman_value(context, entry["candidate"], candidate, "candidate")
          version = context.optional_string(entry["version"])
          version.try { |value| validate_sdkman_value(context, entry["version"], value, "version") }
          SdkmanCandidate.new(candidate, version)
        else
          context.error(entry.path, "must be a candidate string or object")
          nil
        end
      end

      if candidates.empty?
        context.error(packages_node.path, "must contain at least one item")
        return
      end

      SdkmanPackagesStep.new(
        name, candidates,
        description: description,
        continue_on_error: context.bool(spec["continueOnError"], true),
        probe_command: probe,
      )
    end

    SDKMAN_SAFE_VALUE = /\A[A-Za-z0-9._+-]+\z/

    private def validate_sdkman_value(context : Context, node : Node, value : String, subject : String) : Nil
      return if value.matches?(SDKMAN_SAFE_VALUE)
      # SDKMAN has no argv interface — it is a set of shell functions — so its
      # operands are interpolated into a shell command and must be inert.
      context.error(node.path, "SDKMAN #{subject} contains unsafe shell characters")
    end

    def manifest_interrupt(context : Context, spec : Node, name : String, description : String?) : Step?
      interrupt(context, spec, name, description)
    end

    def manifest_file_writes(context : Context, spec : Node, name : String, description : String?, probe : String?) : Step?
      file_writes(context, spec, name, description, probe)
    end
  end
end
