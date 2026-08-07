module Fluxion::Config
  # Shell-driven kinds and the two human-checkpoint kinds.
  module StepParser
    private def shell_script(context : Context, node : Node, name : String, description : String?, probe : String?) : Step?
      working_dir = context.local_path(node["workingDir"], required: false)
      scripts_node = node["scripts"]

      items = if scripts_node.present?
                scripts_node.items.map_with_index do |entry, index|
                  shell_script_item(context, entry, "#{name}[#{index}]", working_dir)
                end.compact
              else
                # A single script may be declared inline on the step instead.
                item = shell_script_item(context, node, name, working_dir)
                item ? [item] : [] of ShellScriptItem
              end

      if items.empty?
        context.error(scripts_node.present? ? scripts_node.path : node.path, "script items must not be empty")
        return
      end
      report_duplicates(context, node.path, items.map(&.name), "script item name")

      ShellScriptStep.new(
        name, items, working_dir,
        description: description,
        continue_on_error: context.bool(node["continueOnError"], false),
        probe_command: probe,
      )
    end

    private def shell_script_item(context : Context, node : Node, fallback_name : String, inherited_dir : String?) : ShellScriptItem?
      # A bare string in the `scripts` list is just a path.
      if node.scalar?
        path = node.string?
        return unless path
        return ShellScriptItem.new(name: path, script: context.resolve_local(path), working_dir: inherited_dir)
      end

      script_node = node["script"]
      url_node = node["url"]
      has_script = script_node.present?
      has_url = url_node.present?

      if has_script == has_url
        context.error(node.path, "must define exactly one of script or url")
        return
      end

      sha256 = context.sha256(node["sha256"])
      if has_url && sha256.nil?
        context.error(node["sha256"].path,
          "is required for a remote script",
          "Fluxion verifies the digest before executing, including under sudo")
        return
      end
      if has_script && node["sha256"].present?
        context.error(node["sha256"].path, "is only valid for a remote URL",
          "a local script is an operator-controlled input")
      end

      url = has_url ? context.https_url(url_node) : nil
      return if has_url && url.nil?

      ShellScriptItem.new(
        name: context.optional_string(node["name"]) || fallback_name,
        script: has_script ? context.local_path(script_node) : nil,
        url: url,
        args: node["args"].string_list,
        working_dir: context.local_path(node["cwd", "workingDir"], required: false) || inherited_dir,
        environment: environment(context, node["env"]),
        sudo: context.bool(node["sudo"], false),
        allowed_exit_codes: exit_codes(context, node["allowedExitCodes"]),
        creates: context.local_path(node["creates"], required: false),
        unless_command: context.optional_string(node["unless"]),
        confirm: confirm(context, node["confirm"]),
        timeout: item_timeout(context, node),
        sha256: sha256,
      )
    end

    private def shell_command(context : Context, node : Node, name : String, description : String?, probe : String?) : Step?
      shell = context.optional_string(node["shell"]) || ShellCommandStep::DEFAULT_SHELL
      working_dir = context.local_path(node["workingDir"], required: false)
      commands_node = node["commands"]

      items = commands_node.items.map_with_index do |entry, index|
        shell_command_item(context, entry, "#{name}[#{index}]", shell, working_dir)
      end.compact

      if items.empty?
        context.error(commands_node.path, "commands must not be empty")
        return
      end
      report_duplicates(context, commands_node.path, items.map(&.name), "command item name")

      ShellCommandStep.new(
        name, items, shell, working_dir,
        description: description,
        continue_on_error: context.bool(node["continueOnError"], true),
        probe_command: probe,
      )
    end

    private def shell_command_item(context : Context, node : Node, fallback_name : String, shell : String, inherited_dir : String?) : ShellCommandItem?
      # A bare string runs through the shell; a bare array is a direct argv
      # vector. Keeping them distinct all the way down is what lets previews
      # and redaction reflect the real execution boundary.
      if node.scalar?
        command = node.string?
        return unless command
        return ShellCommandItem.new(name: command, shell_command: command, shell: shell, working_dir: inherited_dir)
      end

      if node.sequence?
        argv = node.string_list
        return if argv.empty?
        return ShellCommandItem.new(name: argv.join(' '), argv: argv, shell: shell, working_dir: inherited_dir)
      end

      run_node = node["run"]
      shell_command = context.optional_string(node["shellCommand"]) ||
                      (run_node.scalar? ? run_node.string? : nil)

      argv = if node["argv"].present?
               node["argv"].string_list
             elsif run_node.sequence?
               run_node.string_list
             elsif node["command"].present?
               [context.require_string(node["command"], "command")] + node["args"].string_list
             end

      if (shell_command.nil?) == (argv.nil? || argv.empty?)
        context.error(node.path, "must define exactly one shell string or direct argv command")
        return
      end

      ShellCommandItem.new(
        name: context.optional_string(node["name"]) || shell_command || fallback_name,
        shell_command: shell_command,
        argv: argv,
        shell: context.optional_string(node["shell"]) || shell,
        working_dir: context.local_path(node["cwd", "workingDir"], required: false) || inherited_dir,
        environment: environment(context, node["env"]),
        sudo: context.bool(node["sudo"], false),
        allowed_exit_codes: exit_codes(context, node["allowedExitCodes"]),
        creates: context.local_path(node["creates"], required: false),
        unless_command: context.optional_string(node["unless"]),
        confirm: confirm(context, node["confirm"]),
        timeout: item_timeout(context, node),
      )
    end

    private def item_timeout(context : Context, node : Node) : Time::Span
      seconds = node["timeoutSeconds"].int?
      if seconds
        if seconds <= 0
          context.error(node["timeoutSeconds"].path, "must be a positive integer")
          return ShellItemFields::DEFAULT_TIMEOUT
        end
        return seconds.seconds
      end
      context.duration(node["timeout"], ShellItemFields::DEFAULT_TIMEOUT)
    end

    private def exit_codes(context : Context, node : Node) : Array(Int32)
      return [] of Int32 unless node.present?
      codes = [] of Int32
      node.each_item do |entry, _|
        value = entry.int?
        if value.nil? || value < 0
          context.error(entry.path, "allowedExitCodes must contain non-negative integers")
          next
        end
        codes << value
      end
      codes
    end

    # `confirm: true` is shorthand for a generic prompt; a string supplies its
    # own wording. Either way the item needs `apply --yes`.
    private def confirm(context : Context, node : Node) : String?
      return unless node.present?
      if value = node.string?
        return value unless value.strip.empty?
      end
      case node.bool?
      when true  then "confirm"
      when false then nil
      else
        context.error(node.path, "must be a boolean or non-blank string")
        nil
      end
    end

    private def environment(context : Context, node : Node) : Array(ShellEnvironmentVariable)
      return [] of ShellEnvironmentVariable unless node.present?
      unless node.mapping?
        context.error(node.path, "env must be an object")
        return [] of ShellEnvironmentVariable
      end

      variables = [] of ShellEnvironmentVariable
      node.each_entry do |name, value|
        unless ShellEnvironmentVariable.portable_name?(name)
          context.error(value.path, "environment variable name must be portable",
            "letters, digits and underscore, not starting with a digit")
          next
        end

        if value.scalar?
          text = value.string?
          if text.nil?
            context.error(value.path, "value must be a string")
            next
          end
          variables << ShellEnvironmentVariable.new(name, text, sensitive_name?(name))
          next
        end

        unless value.mapping?
          context.error(value.path, "must be a string or object")
          next
        end

        text = value["value"].string?
        if text.nil?
          context.error(value["value"].path, "value is required and must be a string")
          next
        end
        sensitive = value["sensitive"].bool?
        if value["sensitive"].present? && sensitive.nil?
          context.error(value["sensitive"].path, "must be a boolean")
        end
        variables << ShellEnvironmentVariable.new(name, text, sensitive.nil? ? sensitive_name?(name) : sensitive)
      end
      variables
    end

    # Names that almost always carry a secret. Getting this wrong in the safe
    # direction only costs a `<redacted>` in the output; getting it wrong the
    # other way leaks a token into logs and state.
    SENSITIVE_NAME = /(^|[^a-z0-9])(?:api[._-]?key|access[._-]?key|private[._-]?key|key[._-]?passphrase|passphrase|authorization|token|secret|password|passwd|credentials?)($|[^a-z0-9])/

    def sensitive_name?(name : String) : Bool
      normalized = name.gsub(/([a-z0-9])([A-Z])/, "\\1_\\2").downcase
      normalized.matches?(SENSITIVE_NAME)
    end

    private def shell_reload(context : Context, node : Node, name : String, description : String?) : Step?
      shell = ShellKind.from_config?(node["shell"].string?)
      if node["shell"].present? && shell.nil?
        context.error(node["shell"].path, "unsupported shell", "one of zsh, bash, sh")
      end
      ShellReloadStep.new(name, shell || ShellKind::Zsh, description)
    end

    private def default_shell(context : Context, node : Node, name : String, description : String?, probe : String?) : Step?
      path = context.absolute_path(node["shell", "shellPath"])
      return unless path
      DefaultShellStep.new(name, path, description, probe)
    end

    private def assert_step(context : Context, node : Node, name : String, description : String?) : Step?
      command = context.require_string(node["command"], "assert command")
      return if command.empty?

      # A default message is better than none, but a profile that supplies one
      # is telling the user how to fix the machine, which is the whole point.
      message = context.optional_string(node["message"]) || "Assertion failed: #{name}"

      AssertStep.new(
        name, command, message,
        shell: context.optional_string(node["shell"]) || AssertStep::DEFAULT_SHELL,
        working_dir: context.local_path(node["workingDir"], required: false),
        description: description,
      )
    end

    private def manual(context : Context, node : Node, name : String, description : String?, probe : String?) : Step?
      message = context.require_string(node["message"], "manual message")
      return if message.empty?
      if probe.nil?
        context.warning(node.path,
          "manual steps without a probeCommand can never be marked complete",
          "add a probeCommand so a rerun can skip it")
      end
      ManualStep.new(name, message, description, probe)
    end
  end
end
