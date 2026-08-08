module Fluxion::Config
  # Turns one `spec:` payload into a `Step`.
  #
  # The entry point is `build_kind`, reached from the kind a step declared.
  # Dispatch is a single table so the set of supported kinds cannot drift
  # between what `validate` accepts, what `kinds` lists, and what the executor
  # can actually run.
  module StepParser
    extend self

    def levenshtein(a : String, b : String) : Int32
      previous = (0..b.size).to_a
      current = Array.new(b.size + 1, 0)

      a.each_char_with_index do |a_char, i|
        current[0] = i + 1
        b.each_char_with_index do |b_char, j|
          cost = a_char == b_char ? 0 : 1
          current[j + 1] = Math.min(Math.min(current[j] + 1, previous[j + 1] + 1), previous[j] + cost)
        end
        previous = current.dup
      end

      previous[b.size]
    end

    # One branch per supported step type. Splitting the table would only
    # relocate the branching somewhere less obvious to read.
    #
    # ameba:disable Metrics/CyclomaticComplexity
    protected def build(context : Context, node : Node, kind : String, name : String, description : String?, probe : String?) : Step?
      case kind
      when "tool-packages"      then tool_packages(context, node, name, description, probe)
      when "system-update"      then system_update(context, node, name, description, probe)
      when "apt-repository"     then apt_repository(context, node, name, description, probe)
      when "rpm-repository"     then rpm_repository(context, node, name, description, probe)
      when "zypper-repository"  then zypper_repository(context, node, name, description, probe)
      when "pacman-repository"  then pacman_repository(context, node, name, description, probe)
      when "flatpak-remote"     then flatpak_remote(context, node, name, description, probe)
      when "gpg-key"            then gpg_key(context, node, name, description, probe)
      when "binstaller-profile" then binstaller(context, node, name, description, probe)
      when "nerd-fonts"         then nerd_fonts(context, node, name, description, probe)
      when "dotbot"             then dotbot(context, node, name, description, probe)
      when "toolchain"          then toolchain(context, node, name, description, probe)
      when "oh-my-zsh"          then oh_my_zsh(context, node, name, description, probe)
      when "shell-script"       then shell_script(context, node, name, description, probe)
      when "shell-command"      then shell_command(context, node, name, description, probe)
      when "shell-reload"       then shell_reload(context, node, name, description)
      when "default-shell"      then default_shell(context, node, name, description, probe)
      when "assert"             then assert_step(context, node, name, description)
      when "manual"             then manual(context, node, name, description, probe)
      when "user-groups"        then user_groups(context, node, name, description, probe)
      when "git-config"         then git_config(context, node, name, description, probe)
      when "git-repo"           then git_repo(context, node, name, description, probe)
      when "systemd-unit"       then systemd_unit(context, node, name, description, probe)
      when "system-setting"     then system_setting(context, node, name, description, probe)
      end
    end

    # -- package kinds ------------------------------------------------------

    private def package_actions(context : Context, node : Node, manager : PackageManager) : Array(PackageAction)
      return [] of PackageAction unless node.present?

      node.items.map do |entry|
        action_name, args = if entry.scalar?
                              {entry.string? || "", [] of String}
                            else
                              {context.require_string(entry["action"], "action"), entry["args"].string_list}
                            end

        if action_name.empty?
          context.error(entry.path, "action must not be blank")
        elsif !PackageAction.supported?(manager, action_name)
          supported = PackageAction.supported_for(manager)
          hint = supported.empty? ? "#{manager} accepts no pre-install actions" : "expected one of #{supported.join(", ")}"
          context.error(entry.path, "unsupported action '#{action_name}' for #{manager}", hint)
        end

        PackageAction.new(action_name, args)
      end
    end

    private def tool_packages(context : Context, node : Node, name : String, description : String?, probe : String?) : Step?
      backend_node = node["backend"]
      backend = ToolBackend.from_config?(backend_node.string?)
      unless backend
        raw = backend_node.string?
        if raw.nil? || raw.strip.empty?
          context.error(backend_node.path, "backend is required")
        else
          context.error(backend_node.path, "'#{raw.strip}' is not a supported backend",
            "expected one of #{ToolBackend.config_names.join(", ")}")
        end
        return
      end

      packages_node = node["packages"]
      packages = packages_node.items.map do |entry|
        if entry.scalar?
          split_versioned(entry.string? || "")
        else
          ToolPackage.new(
            context.require_string(entry["name"], "package name"),
            context.optional_string(entry["version"]),
          )
        end
      end

      if packages.empty?
        context.error(packages_node.path, "must contain at least one package")
      end
      report_duplicates(context, packages_node.path, packages.map(&.name), "package")

      ToolPackagesStep.new(
        name, backend, packages,
        description: description,
        continue_on_error: context.bool(node["continueOnError"], true),
        probe_command: probe,
      )
    end

    # Splits at the last `@` so a scoped npm name like `@scope/pkg@1.0` keeps
    # its leading marker and still pins correctly.
    private def split_versioned(raw : String) : ToolPackage
      at = raw.rindex('@')
      return ToolPackage.new(raw) if at.nil? || at == 0
      ToolPackage.new(raw[0, at], raw[(at + 1)..])
    end

    private def system_update(context : Context, node : Node, name : String, description : String?, probe : String?) : Step?
      manager_node = node["packageManager"]
      manager = PackageManager.from_config?(manager_node.string?)
      unless manager
        context.error(manager_node.path, "packageManager is required")
        return
      end
      unless manager.supports_system_update?
        context.error(manager_node.path, "does not support system-update: #{manager}",
          "use tool-packages or a flatpak step instead")
        return
      end

      dist_upgrade = context.bool(node["distUpgrade"], false)
      refresh_only = context.bool(node["refreshOnly"], false)
      if dist_upgrade && refresh_only
        context.error(node.path,
          "cannot be both distUpgrade and refreshOnly",
          "one asks for the largest possible upgrade and the other for none at all")
      end

      SystemUpdateStep.new(
        name, manager,
        dist_upgrade: dist_upgrade,
        refresh_only: refresh_only,
        timeout: context.duration(node["timeout"], SystemUpdateStep::DEFAULT_TIMEOUT),
        description: description,
        continue_on_error: context.bool(node["continueOnError"], false),
        probe_command: probe,
      )
    end

    # -- helpers ------------------------------------------------------------

    UNSAFE_PACKAGE_CHARS = /[\s$;|&`><"'\\]/

    private def validate_package_name(context : Context, path : String, value : String) : Nil
      if value.strip.empty?
        context.error(path, "package name must not be blank")
      elsif value.starts_with?('-')
        context.error(path, "package name must not be interpreted as an option: #{value}")
      elsif value.matches?(UNSAFE_PACKAGE_CHARS)
        context.error(path, "package name contains unsafe shell characters: #{value}")
      end
    end

    private def report_duplicates(context : Context, path : String, values : Array(String), subject : String) : Nil
      seen = Set(String).new
      values.each do |value|
        # A duplicate is a warning, not an error: installing something twice is
        # wasteful rather than wrong, and refusing would block a profile that
        # merges two fragments.
        context.warning(path, "duplicate #{subject}: #{value}") unless seen.add?(value)
      end
    end
  end
end
