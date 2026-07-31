module Fluxion::Config
  # Turns one `steps[]` / `modules[]` entry into a `Step`.
  #
  # Dispatch is a single table keyed by the `type` discriminator so the set of
  # supported kinds cannot drift between what `validate` accepts, what `kinds`
  # lists, and what the executor can actually run.
  module StepParser
    extend self

    # Every `type` the stable jobs/steps schema accepts, in the order the
    # documentation lists them. `kinds` and the did-you-mean suggester both
    # read this, so adding a kind here is the only edit needed.
    KINDS = %w[
      packages
      apt-repository
      rpm-repository
      pacman-repository
      flatpak
      flatpak-remote
      shell-script
      compiled-binary
      dotbot
      default-shell
      oh-my-zsh
      toolchain
      nerd-fonts
      shell-reload
      shell-command
      assert
      manual
      binstaller-profile
      user-groups
      git-config
      git-repo
      systemd-unit
      system-setting
      system-update
      gpg-key
      tool-packages
      zypper-repository
    ]

    def parse(context : Context, node : Node) : Step?
      type_node = node["type"]
      raw_type = type_node.string?
      if raw_type.nil? || raw_type.strip.empty?
        context.error(type_node.path, "step type is required")
        return
      end

      kind = raw_type.strip.downcase
      unless KINDS.includes?(kind)
        context.error(type_node.path, "unsupported step type '#{raw_type.strip}'", suggestion_for(kind))
        return
      end

      name = context.require_string(node["name"], "step name")
      return if name.empty?

      build(context, node, kind, name,
        context.optional_string(node["description"]),
        context.optional_string(node["probeCommand"]))
    end

    # Levenshtein against the known kinds, with a budget that scales with the
    # input so a short typo does not match everything. Ties resolve to the
    # first kind in declaration order.
    def suggestion_for(kind : String) : String?
      return if kind.empty?
      budget = Math.max(2, kind.size // 3)
      best : String? = nil
      best_distance = Int32::MAX

      KINDS.each do |candidate|
        distance = levenshtein(kind, candidate)
        next if distance > budget || distance >= best_distance
        best = candidate
        best_distance = distance
      end

      best.try { |match| "Did you mean '#{match}'?" }
    end

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

    # Shared by both frontends: the stable schema passes the step node, a
    # manifest passes the plan entry's `spec` node, and everything below reads
    # the same field names from whichever it is given.
    # One branch per supported kind. Splitting the table would only relocate
    # the branching somewhere less obvious to read.
    #
    # ameba:disable Metrics/CyclomaticComplexity
    protected def build(context : Context, node : Node, kind : String, name : String, description : String?, probe : String?) : Step?
      case kind
      when "packages"           then packages(context, node, name, description, probe)
      when "flatpak"            then flatpak(context, node, name, description, probe)
      when "tool-packages"      then tool_packages(context, node, name, description, probe)
      when "system-update"      then system_update(context, node, name, description, probe)
      when "apt-repository"     then apt_repository(context, node, name, description, probe)
      when "rpm-repository"     then rpm_repository(context, node, name, description, probe)
      when "zypper-repository"  then zypper_repository(context, node, name, description, probe)
      when "pacman-repository"  then pacman_repository(context, node, name, description, probe)
      when "flatpak-remote"     then flatpak_remote(context, node, name, description, probe)
      when "gpg-key"            then gpg_key(context, node, name, description, probe)
      when "compiled-binary"    then compiled_binary(context, node, name, description, probe)
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

    private def packages(context, node, name, description, probe) : Step?
      manager_node = node["packageManager"]
      manager = PackageManager.from_config?(manager_node.string?)
      unless manager
        raw = manager_node.string?
        if raw.nil? || raw.strip.empty?
          context.error(manager_node.path, "packageManager is required")
        else
          context.error(manager_node.path, "unsupported package manager '#{raw.strip}'")
        end
        return
      end

      packages_node = node["packages"]
      packages = packages_node.string_list
      if packages.empty?
        context.error(packages_node.path, "must contain at least one package")
      end
      packages.each_with_index do |package, index|
        validate_package_name(context, "#{packages_node.path}[#{index}]", package)
      end

      report_duplicates(context, packages_node.path, packages, "package")

      PackagesStep.new(
        name, manager, packages,
        actions: package_actions(context, node["actions"], manager),
        description: description,
        continue_on_error: context.bool(node["continueOnError"], true),
        probe_command: probe,
      )
    end

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

    private def flatpak(context, node, name, description, probe) : Step?
      ids_node = node["appIds", "apps"]
      app_ids = ids_node.string_list
      if app_ids.empty?
        context.error(ids_node.path, "must contain at least one app ID")
      end
      app_ids.each_with_index do |app_id, index|
        unless FLATPAK_APP_ID.matches?(app_id)
          context.error("#{ids_node.path}[#{index}]",
            "must be a reverse-DNS Flatpak application ID", "for example com.spotify.Client")
        end
      end
      report_duplicates(context, ids_node.path, app_ids, "app ID")

      # A blank remote is a common way of writing "the default"; treating it as
      # flathub is friendlier than failing on an empty string.
      remote = context.optional_string(node["remote"]) || FlatpakStep::DEFAULT_REMOTE

      FlatpakStep.new(
        name, app_ids, remote,
        description: description,
        continue_on_error: context.bool(node["continueOnError"], true),
        probe_command: probe,
      )
    end

    FLATPAK_APP_ID = /\A[A-Za-z][A-Za-z0-9_-]*(?:\.[A-Za-z][A-Za-z0-9_-]*){2,}\z/

    private def tool_packages(context, node, name, description, probe) : Step?
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

    private def system_update(context, node, name, description, probe) : Step?
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
