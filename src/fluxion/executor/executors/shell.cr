module Fluxion::Executor
  # Executors for shell-facing work: the login shell, reloads, and the
  # arbitrary-command kinds — plus the shared item lookup those last ones use.
  # `default-shell` — change the login shell.
  class DefaultShellExecutor < StepExecutor
    TIMEOUT = 30.seconds

    def supports?(step : Step) : Bool
      step.is_a?(DefaultShellStep)
    end

    def commands(step : Step, item : StepItem) : Array(Command)
      shell = step.as(DefaultShellStep).shell_path
      [Command.new(["sudo", "chsh", "-s", shell, Host.target_user], timeout: TIMEOUT)]
    end

    # Setting a login shell that does not exist locks the user out of their own
    # account, so this is checked before the change rather than after.
    def execute(step : Step, item : StepItem, runner : ShellRunner, &sink : String ->) : StepResult
      shell = step.as(DefaultShellStep).shell_path
      info = File.info?(shell)
      unless info && info.file? && info.permissions.owner_execute?
        return StepResult::Failure.new(item.key, "shell is not an executable file: #{shell}", 1)
      end
      run_commands(step, item, runner) { |line| sink.call(line) }
    end
  end

  # `shell-reload` — confirm a fresh login shell starts cleanly.
  class ShellReloadExecutor < StepExecutor
    TIMEOUT = 30.seconds

    def supports?(step : Step) : Bool
      step.is_a?(ShellReloadStep)
    end

    def commands(step : Step, item : StepItem) : Array(Command)
      [Command.new(step.as(ShellReloadStep).reload_argv, timeout: TIMEOUT)]
    end

    def execute(step : Step, item : StepItem, runner : ShellRunner, &sink : String ->) : StepResult
      result = run_commands(step, item, runner) { |line| sink.call(line) }
      return result unless result.is_a?(StepResult::Failure)

      shell = step.as(ShellReloadStep).shell
      StepResult::Failure.new(item.key,
        "shell init failed — check your .#{shell}rc for errors: #{result.error_message}",
        result.exit_code, result.elapsed)
    end
  end

  # Idempotency guards and environment handling, shared by the two structured
  # item kinds.
  #
  # A module rather than a base class: the two executors find their items in
  # different collections, and inheriting would union their return types.
  module ShellItemSupport
    GUARD_TIMEOUT = 30.seconds

    # `creates` is answered locally and costs nothing, so it runs first;
    # `unless` costs a process.
    protected def guard(item : ShellItemFields, runner : ShellRunner) : StepResult::Skipped?
      if creates = item.creates
        return StepResult::Skipped.new(item.name, "#{creates} already exists") if File.exists?(creates)
      end

      if guard = item.unless_command
        result = runner.run(Command.new(
          ["/bin/bash", "-lc", guard],
          env: environment(item),
          working_dir: item.working_dir,
          timeout: GUARD_TIMEOUT,
          sensitive: item.environment,
        ))
        return StepResult::Skipped.new(item.name, "unless guard matched") if result.success?
      end

      nil
    end

    protected def environment(item : ShellItemFields) : Hash(String, String)
      item.environment.to_h { |variable| {variable.name, variable.value} }
    end
  end

  # `shell-command` — inline commands and direct argv vectors.
  class ShellCommandExecutor < StepExecutor
    include ShellItemSupport

    def supports?(step : Step) : Bool
      step.is_a?(ShellCommandStep)
    end

    def commands(step : Step, item : StepItem) : Array(Command)
      command = find(step, item)
      return [] of Command unless command

      [Command.new(
        command.command,
        env: environment(command),
        working_dir: command.working_dir,
        timeout: command.timeout,
        success_codes: command.allowed_exit_codes.to_set,
        sensitive: command.environment,
      )]
    end

    def execute(step : Step, item : StepItem, runner : ShellRunner, &sink : String ->) : StepResult
      command = find(step, item)
      return StepResult::Success.new(item.key) unless command

      if skip = guard(command, runner)
        return skip
      end
      run_commands(step, item, runner) { |line| sink.call(line) }
    end

    private def find(step : Step, item : StepItem) : ShellCommandItem?
      step.as(ShellCommandStep).commands.find { |command| command.name == item.key }
    end
  end

  # `shell-script` — run a local or verified remote script.
  class ShellScriptExecutor < StepExecutor
    include ShellItemSupport

    def supports?(step : Step) : Bool
      step.is_a?(ShellScriptStep)
    end

    def commands(step : Step, item : StepItem) : Array(Command)
      script = find(step, item)
      return [] of Command unless script

      # A remote script has to be downloaded and verified before it can be
      # named, so its preview describes the fetch rather than a local path.
      path = script.script
      unless path
        return [Command.new(["fluxion", "fetch-verified", PublicUrl.from(script.url || ""), "|", "sh"] + script.args)]
      end

      argv = [interpreter(path), path] + script.args
      argv.unshift("sudo") if script.sudo?

      [Command.new(
        argv,
        env: environment(script),
        working_dir: script.working_dir,
        timeout: script.timeout,
        success_codes: script.allowed_exit_codes.to_set,
        sensitive: script.environment,
      )]
    end

    def execute(step : Step, item : StepItem, runner : ShellRunner, &sink : String ->) : StepResult
      script = find(step, item)
      return StepResult::Success.new(item.key) unless script

      if script.remote?
        return StepResult::Failure.new(item.key,
          "remote scripts require the verified download path, which is not wired up yet", 1)
      end

      if skip = guard(script, runner)
        return skip
      end

      path = script.script
      unless path && File.exists?(path)
        return StepResult::Failure.new(item.key, "script not found: #{path}", 1)
      end

      run_commands(step, item, runner) { |line| sink.call(line) }
    end

    # Reads the shebang so a Python or Ruby helper runs under the right
    # interpreter, falling back to bash when there is none.
    private def interpreter(path : String) : String
      return "/bin/bash" unless File.exists?(path)

      first = File.open(path, &.gets(chomp: true)) rescue nil
      return "/bin/bash" unless first && first.starts_with?("#!")

      first.lchop("#!").strip.split(/\s+/).first? || "/bin/bash"
    end

    private def find(step : Step, item : StepItem) : ShellScriptItem?
      step.as(ShellScriptStep).scripts.find { |script| script.name == item.key }
    end
  end

  # `assert` — require a host condition before continuing.
  class AssertExecutor < StepExecutor
    TIMEOUT = 5.minutes

    def supports?(step : Step) : Bool
      step.is_a?(AssertStep)
    end

    def commands(step : Step, item : StepItem) : Array(Command)
      assert = step.as(AssertStep)
      [Command.new(assert.argv, working_dir: assert.working_dir, timeout: TIMEOUT)]
    end

    # The configured message replaces the command output: it is written for
    # someone who has to go fix the machine, not for a debugging session.
    def execute(step : Step, item : StepItem, runner : ShellRunner, &sink : String ->) : StepResult
      result = run_commands(step, item, runner) { |line| sink.call(line) }
      return result unless result.is_a?(StepResult::Failure)
      StepResult::Failure.new(item.key, step.as(AssertStep).message, result.exit_code, result.elapsed)
    end
  end

  # `manual` — a human checkpoint.
  class ManualExecutor < StepExecutor
    TIMEOUT = 5.minutes

    def supports?(step : Step) : Bool
      step.is_a?(ManualStep)
    end

    def commands(step : Step, item : StepItem) : Array(Command)
      probe = step.probe_command
      return [] of Command unless probe
      [Command.new(["/bin/bash", "-lc", probe], timeout: TIMEOUT)]
    end

    # Without a probe there is no way to know the human did the thing, so the
    # step fails with its message rather than silently passing.
    def execute(step : Step, item : StepItem, runner : ShellRunner, &_sink : String ->) : StepResult
      manual = step.as(ManualStep)
      # The command comes from `commands` rather than being rebuilt here, so the
      # preview and the run cannot describe different things — which is the
      # whole reason previews are generated from the same method as the run.
      command = commands(step, item).first?
      unless command
        return StepResult::Failure.new(item.key, "Manual step required: #{manual.message}", 2)
      end

      result = runner.run(command)
      return StepResult::Success.new(item.key, result.elapsed) if result.success?
      StepResult::Failure.new(item.key, manual.message, result.exit_code, result.elapsed)
    end
  end
end
