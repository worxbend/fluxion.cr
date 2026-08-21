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
    include DownloadSupport

    def supports?(step : Step) : Bool
      step.is_a?(ShellScriptStep)
    end

    def commands(step : Step, item : StepItem) : Array(Command)
      script = find(step, item)
      return [] of Command unless script

      [command_for(step.as(ShellScriptStep), script, source_preview(script))]
    end

    def execute(step : Step, item : StepItem, runner : ShellRunner, &sink : String ->) : StepResult
      scripts = step.as(ShellScriptStep)
      script = find(step, item)
      return StepResult::Success.new(item.key) unless script

      # Guards first, so a script that is already satisfied is never fetched or
      # written. This used to sit after the remote check, which meant a
      # `creates:` that was already present still paid for the download.
      if skip = guard(script, runner)
        return skip
      end

      with_workspace do |workspace|
        path = case
               when script.inline? then write_inline(script, workspace)
               when script.remote? then fetch_remote(script, workspace)
               else                     script.script
               end

        unless path && File.exists?(path)
          return StepResult::Failure.new(item.key, "script not found: #{path}", 1)
        end

        command = command_for(scripts, script, path)
        started = Time.instant
        result = runner.run(command) { |line| sink.call(line) }
        return StepResult::Success.new(item.key, Time.instant - started) if command.success?(result.exit_code)

        StepResult::Failure.new(item.key,
          "#{command.preview.join(' ')} exited #{result.exit_code}: #{result.detail}",
          result.exit_code, Time.instant - started)
      end
    rescue error : Error
      failure(item, error)
    end

    # One builder for the preview and the run, so they cannot describe
    # different things.
    private def command_for(step : ShellScriptStep, script : ShellScriptItem, path : String) : Command
      argv = [interpreter(step, script, path), path] + script.args
      argv.unshift("sudo") if script.sudo?

      Command.new(
        argv,
        env: environment(script),
        working_dir: script.working_dir,
        timeout: script.timeout,
        success_codes: script.allowed_exit_codes.to_set,
        sensitive: script.environment,
      )
    end

    # What the preview names as the script, when there is no local file yet.
    private def source_preview(script : ShellScriptItem) : String
      return PublicUrl.from(script.url || "") if script.remote?
      return "<inline #{script.name}>" if script.inline?
      script.script || script.name
    end

    # Declared shell wins, then the step's, then a local file's shebang, then
    # bash.
    #
    # The shebang is consulted for a `script:` source ONLY, because that is the
    # only one whose bytes exist when the preview is built. Reading it for a
    # remote script made `plan` say bash while the run picked whatever the
    # fetched file declared — a preview describing something other than what
    # runs, which is the one thing this codebase says it will not do. An inline
    # body has no shebang at all, which is why the parser requires `shell:`
    # there. Declare `shell:` on a remote script to choose its interpreter.
    #
    # A declared shell reaches argv as the bare name so `sudo` resolves it
    # against the root-owned system directories rather than a hardcoded path.
    private def interpreter(step : ShellScriptStep, script : ShellScriptItem, path : String) : String
      if shell = step.shell_for(script)
        return shell.command
      end

      return "/bin/bash" unless script.script && File.file?(path)
      first = File.open(path, &.gets(chomp: true)) rescue nil
      return "/bin/bash" unless first && first.starts_with?("#!")

      first.lchop("#!").strip.split(/\s+/).first? || "/bin/bash"
    end

    # An inline body becomes a file in the run's private 0700 workspace, at
    # mode 0500. Never `[shell, "-lc", body]`: a body passed as an argument
    # shows up in process listings, and `$0`/`$@` would not behave as a script.
    private def write_inline(script : ShellScriptItem, workspace : String) : String
      path = File.join(workspace, "#{script.name.gsub(/[^A-Za-z0-9._-]/, "_")}.sh")
      File.write(path, script.content)
      File.chmod(path, 0o500)
      path
    end

    # A remote script is downloaded and digest-verified before it is run —
    # which is what the `sha256` the parser insists on is for.
    private def fetch_remote(script : ShellScriptItem, workspace : String) : String
      url = script.url.not_nil!
      digest = script.sha256.not_nil!
      path = File.join(workspace, "remote.sh")

      downloader(Downloader::MAX_TEXT_BYTES).download_verified(url, path, digest)
      File.chmod(path, 0o500)
      path
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
