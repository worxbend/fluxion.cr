module Fluxion::Config
  # Host-configuration kinds.
  module StepParser
    private def user_groups(context, node, name, description, probe) : Step?
      groups_node = node["groups"]
      groups = groups_node.string_list

      if groups.empty?
        context.error(groups_node.path, "requires at least one group")
        return
      end

      groups.each_with_index do |group, index|
        if group.strip.empty?
          context.error("#{groups_node.path}[#{index}]", "must not be blank")
        elsif group.starts_with?('-') || group.starts_with?('!')
          # Membership is append-only. Silently dropping a user out of a group
          # they depend on is a worse failure than having to run `gpasswd -d`
          # by hand, so removal syntax is rejected rather than ignored.
          context.error("#{groups_node.path}[#{index}]",
            "contains '#{group}'. Group membership is append-only; Fluxion never removes a user from a group",
            "use gpasswd -d by hand")
        end
      end
      report_duplicates(context, groups_node.path, groups, "group")

      UserGroupsStep.new(
        name, groups,
        user: context.optional_string(node["user"]),
        create_missing: context.bool(node["createMissing"], false),
        logout_checkpoint: context.bool(node["logoutCheckpoint"], true),
        checkpoint_message: context.optional_string(node["checkpointMessage"]),
        description: description,
        continue_on_error: context.bool(node["continueOnError"], false),
        probe_command: probe,
      )
    end

    private def git_config(context, node, name, description, probe) : Step?
      entries_node = node["entries"]
      entries = entries_node.string_map

      if entries.empty?
        context.error(entries_node.path, "requires at least one entry")
        return
      end

      entries.each_key do |key|
        # `git config` itself rejects a bare key, so catching it here turns a
        # confusing runtime error into a config diagnostic.
        next if key.includes?('.')
        context.error(entries_node.path,
          "has key '#{key}'; git config keys are section.key",
          "for example user.email")
      end

      scope = GitConfigScope.from_config?(node["scope"].string?)
      if node["scope"].present? && scope.nil?
        context.error(node["scope"].path, "unsupported scope", "one of global, system, local")
      end

      GitConfigStep.new(
        name, entries,
        scope: scope || GitConfigScope::Global,
        description: description,
        continue_on_error: context.bool(node["continueOnError"], false),
        probe_command: probe,
      )
    end

    private def git_repo(context, node, name, description, probe) : Step?
      repos_node = node["repos"]
      repos = repos_node.items.compact_map { |entry| git_repo_entry(context, entry) }

      if repos.empty?
        context.error(repos_node.path, "requires at least one repository")
        return
      end
      report_duplicates(context, repos_node.path, repos.map(&.destination), "destination")

      GitRepoStep.new(
        name, repos,
        description: description,
        continue_on_error: context.bool(node["continueOnError"], false),
        probe_command: probe,
      )
    end

    private def git_repo_entry(context : Context, entry : Node) : GitRepo?
      url_node = entry["url"]
      url = context.https_url(url_node)
      if url && (url.includes?('?') || url.includes?('#'))
        context.error(url_node.path, "must not contain query or fragment data")
        url = nil
      end

      destination = context.optional_string(entry["dest", "destination"])
      if destination.nil?
        context.error(entry["dest"].path, "destination is required")
      end

      ref = context.require_string(entry["ref"], "ref")
      unless ref.empty? || GitRepo.commit?(ref)
        context.error(entry["ref"].path,
          "must be an exact immutable 40-hex commit",
          "branches and tags can move, so they cannot pin a checkout")
      end

      # The legacy `update` field only ever meant "leave it alone"; anything
      # else would let an existing checkout be reset under the user.
      update = context.optional_string(entry["update"])
      if update && update.downcase != "none"
        context.error(entry["update"].path,
          "must be none for an immutable commit checkout")
      end

      depth = entry["depth"].int?
      if depth && depth < 1
        context.error(entry["depth"].path, "must be at least 1")
        depth = nil
      end

      # `commit?` already implies non-empty, so checking it alone is enough.
      return unless url && destination && GitRepo.commit?(ref)

      GitRepo.new(url, destination, ref, depth, context.bool(entry["submodules"], false))
    end

    private def systemd_unit(context, node, name, description, probe) : Step?
      units_node = node["units"]
      units = units_node.items.compact_map { |entry| systemd_unit_entry(context, entry) }

      if units.empty?
        context.error(units_node.path, "requires at least one unit")
        return
      end
      report_duplicates(context, units_node.path, units.map(&.qualified_name), "unit")

      scope = SystemdScope.from_config?(node["scope"].string?)
      if node["scope"].present? && scope.nil?
        context.error(node["scope"].path, "unsupported scope", "one of system, user")
      end

      SystemdUnitStep.new(
        name, units,
        scope: scope || SystemdScope::System,
        description: description,
        continue_on_error: context.bool(node["continueOnError"], false),
        probe_command: probe,
      )
    end

    private def systemd_unit_entry(context : Context, entry : Node) : SystemdUnit?
      # A bare string is a unit to enable and leave in its current state.
      if entry.scalar?
        unit = entry.string?
        return unless unit
        return SystemdUnit.new(unit)
      end

      unit = context.require_string(entry["name"], "unit name")
      return if unit.empty?

      state = SystemdState.from_config?(entry["state"].string?)
      if entry["state"].present? && state.nil?
        context.error(entry["state"].path, "unsupported state", "one of started, stopped, unchanged")
      end

      enabled = context.bool(entry["enabled"], true)
      masked = context.bool(entry["mask", "masked"], false)
      if masked && enabled && entry["enabled"].present?
        # Masking is a refusal to start, so the pair is a contradiction rather
        # than a precedence question.
        context.error(entry.path, "cannot both mask and enable '#{unit}'")
      end

      SystemdUnit.new(unit, masked ? false : enabled, state || SystemdState::Unchanged, masked)
    end

    private def system_setting(context, node, name, description, probe) : Step?
      step = SystemSettingStep.new(
        name,
        local_rtc: context.bool?(node["localRtc"]),
        ntp: context.bool?(node["ntp"]),
        timezone: context.optional_string(node["timezone"]),
        hostname: context.optional_string(node["hostname"]),
        locale: node["locale"].string_map,
        description: description,
        continue_on_error: context.bool(node["continueOnError"], false),
        probe_command: probe,
      )

      if step.empty?
        context.error(node.path, "declares no system setting to apply")
        return
      end
      step
    end

    private def file_writes(context, node, name, description, probe) : Step?
      files_node = node["files"]
      files_node = node["writes"] unless files_node.present?

      files = files_node.items.map_with_index do |entry, index|
        file_write_entry(context, entry, "#{name}[#{index}]")
      end.compact

      # An entry that resolves to no files is dropped rather than failing:
      # every file may legitimately have been excluded by its own `when`.
      return if files.empty? && files_node.present?

      if files.empty?
        context.error(node.path, "must contain at least one file")
        return
      end
      report_duplicates(context, files_node.path, files.map(&.item_key), "destination")

      FileWriteStep.new(
        name, files,
        description: description,
        continue_on_error: context.bool(node["continueOnError"], false),
        probe_command: probe,
      )
    end

    private def file_write_entry(context : Context, entry : Node, fallback_name : String) : FileWriteItem?
      unless entry.mapping?
        context.error(entry.path, "must be an object")
        return
      end

      destination = context.absolute_path(entry["destination"])
      return unless destination
      if File.dirname(destination) == "/" && File.basename(destination).empty?
        context.error(entry["destination"].path, "must not be the filesystem root")
        return
      end

      content_node = entry["content"]
      source_node = entry["source"]
      if content_node.present? == source_node.present?
        context.error(entry.path, "must define exactly one of content or source")
        return
      end

      content = nil.as(String?)
      if content_node.present?
        content = content_node.string?
        if content.nil?
          context.error(content_node.path, "content must be a string")
          return
        end
      end

      FileWriteItem.new(
        name: context.optional_string(entry["name"]) || fallback_name,
        destination: destination,
        content: content,
        source: source_node.present? ? context.absolute_path(source_node) : nil,
        owner: context.optional_string(entry["owner"]),
        group: context.optional_string(entry["group"]),
        mode: context.file_mode(entry["mode"]),
        sudo: context.bool(entry["sudo"], false),
      )
    end

    private def interrupt(context, node, name, description) : Step?
      message = context.optional_string(node["message"]) ||
                "Execution paused by interrupt entry: #{name}"

      resume = InterruptStep::ResumeMode.from_config?(node["resumeFrom"].string?)
      if node["resumeFrom"].present? && resume.nil?
        context.error(node["resumeFrom"].path, "must be either current or next")
      end

      exit_code = context.int(node["exitCode"], InterruptStep::DEFAULT_EXIT_CODE)
      unless (0..255).includes?(exit_code)
        context.error(node["exitCode"].path, "must be between 0 and 255")
        exit_code = InterruptStep::DEFAULT_EXIT_CODE
      end

      InterruptStep.new(
        name, message,
        instructions: node["instructions"].string_list,
        resume_from: resume || InterruptStep::ResumeMode::Next,
        exit_code: exit_code,
        description: description,
      )
    end
  end
end
