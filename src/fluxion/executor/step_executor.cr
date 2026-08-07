module Fluxion::Executor
  # Turns one step into the work it represents.
  #
  # A step executor exists to produce commands. `dry-run` prints them,
  # `apply` runs them, and `plan --show-commands` previews them — from the same
  # method, so a preview cannot describe something different from what runs.
  #
  # Kinds that need more than a command sequence (a verified download, an
  # atomic install) override `execute` and still supply `commands` for preview.
  abstract class StepExecutor
    abstract def supports?(step : Step) : Bool

    # The items this step tracks. Defaults to what the step itself declares;
    # overridden where execution order differs from declaration order.
    def items(step : Step) : Array(ModuleItem)
      step.items.map { |item| module_item(step, item) }
    end

    # Commands for one item, in order. Empty means there is nothing to do.
    abstract def commands(step : Step, item : ModuleItem) : Array(Command)

    # Runs one item. The default runs each command in order and stops at the
    # first that fails, because a later command in a sequence normally assumes
    # the earlier one worked.
    def execute(step : Step, item : ModuleItem, runner : ShellRunner, &sink : String ->) : StepResult
      run_commands(step, item, runner) { |line| sink.call(line) }
    end

    # Runs this item's commands in order, stopping at the first failure.
    #
    # Named rather than left inline in `execute` so a subclass that adds its
    # own preconditions can still reach it, without depending on where it sits
    # in the hierarchy.
    def run_commands(step : Step, item : ModuleItem, runner : ShellRunner, &sink : String ->) : StepResult
      started = Time.instant
      sequence = commands(step, item)
      return StepResult::Success.new(item.key, Time.instant - started) if sequence.empty?

      sequence.each do |command|
        result = runner.run(command) { |line| sink.call(line) }
        next if command.success?(result.exit_code)

        return StepResult::Failure.new(
          item.key,
          failure_message(command, result),
          result.exit_code,
          Time.instant - started,
        )
      end

      StepResult::Success.new(item.key, Time.instant - started)
    end

    # What a dry run would do.
    def preview(step : Step, item : ModuleItem) : StepResult::DryRun
      StepResult::DryRun.new(item.key, commands(step, item).flat_map(&.preview))
    end

    private def failure_message(command : Command, result : ProcessResult) : String
      detail = result.detail
      summary = "#{command.preview.join(' ')} exited #{result.exit_code}"
      detail.empty? ? summary : "#{summary}: #{detail}"
    end

    protected def module_item(step : Step, item : ItemRef) : ModuleItem
      ModuleItem.new(step.name, item.key, ItemTypes.for(step), item.display,
        ItemTypes.package_manager_for(step), step)
    end
  end

  # Picks the executor that handles a step.
  class ExecutorRegistry
    getter executors : Array(StepExecutor)

    def initialize(@executors : Array(StepExecutor) = [] of StepExecutor)
    end

    def self.default : self
      new([
        PackagesExecutor.new,
        FlatpakExecutor.new,
        ToolPackagesExecutor.new,
        SdkmanExecutor.new,
        SystemUpdateExecutor.new,
        UserGroupsExecutor.new,
        GitConfigExecutor.new,
        GitRepoExecutor.new,
        SystemdUnitExecutor.new,
        SystemSettingExecutor.new,
        DefaultShellExecutor.new,
        ShellReloadExecutor.new,
        ShellCommandExecutor.new,
        ShellScriptExecutor.new,
        AssertExecutor.new,
        ManualExecutor.new,
        CompiledBinaryExecutor.new,
        ToolchainExecutor.new,
        OhMyZshExecutor.new,
        FileWriteExecutor.new,
        AptRepositoryExecutor.new,
        RpmStyleRepositoryExecutor.new,
        PacmanRepositoryExecutor.new,
        FlatpakRemoteExecutor.new,
        GpgKeyExecutor.new,
        DotbotExecutor.new,
        NerdFontsExecutor.new,
        BinstallerExecutor.new,
      ] of StepExecutor)
    end

    def <<(executor : StepExecutor) : self
      @executors << executor
      self
    end

    def for(step : Step) : StepExecutor?
      @executors.find(&.supports?(step))
    end
  end

  # `packages` — one process per package.
  #
  # The isolation is the point: if `git` installs and `some-typo` does not, the
  # user gets git and one clear error rather than a transaction that rolled
  # everything back.
  class PackagesExecutor < StepExecutor
    INSTALL_TIMEOUT = 10.minutes

    def supports?(step : Step) : Bool
      step.is_a?(PackagesStep)
    end

    # Pre-install actions run before the packages, and are tracked as their own
    # items so a failed metadata refresh is visible rather than folded into the
    # first package's failure.
    def items(step : Step) : Array(ModuleItem)
      packages = step.as(PackagesStep)
      actions = packages.actions.map_with_index do |action, index|
        ModuleItem.new(step.name, "action[#{index}]", ItemType::PackageAction,
          action.to_s, packages.package_manager, step)
      end
      actions + super
    end

    def commands(step : Step, item : ModuleItem) : Array(Command)
      packages = step.as(PackagesStep)
      manager = packages.package_manager

      if item.item_type.package_action?
        index = item.key.lchop("action[").rchop("]").to_i?
        action = index.try { |value| packages.actions[value]? }
        return [] of Command unless action

        argv, success = manager.action_argv(action)
        return [Command.new(argv, timeout: INSTALL_TIMEOUT, success_codes: success)]
      end

      [Command.new(manager.install_argv(item.key), timeout: INSTALL_TIMEOUT)]
    end
  end

  # `flatpak` — install applications from a remote.
  class FlatpakExecutor < StepExecutor
    INSTALL_TIMEOUT = 15.minutes

    def supports?(step : Step) : Bool
      step.is_a?(FlatpakStep)
    end

    def commands(step : Step, item : ModuleItem) : Array(Command)
      remote = step.as(FlatpakStep).remote
      [Command.new(["flatpak", "install", "-y", remote, item.key], timeout: INSTALL_TIMEOUT)]
    end
  end

  # `tool-packages` — ecosystem installers.
  class ToolPackagesExecutor < StepExecutor
    INSTALL_TIMEOUT = 30.minutes

    def supports?(step : Step) : Bool
      step.is_a?(ToolPackagesStep)
    end

    def commands(step : Step, item : ModuleItem) : Array(Command)
      tool = step.as(ToolPackagesStep)
      package = tool.packages.find { |candidate| candidate.name == item.key }
      return [] of Command unless package
      [Command.new(tool.backend.install_argv(package), timeout: INSTALL_TIMEOUT)]
    end

    # Checked up front so a missing backend produces an actionable message
    # instead of a bare command-not-found from each package in turn.
    def execute(step : Step, item : ModuleItem, runner : ShellRunner, &sink : String ->) : StepResult
      backend = step.as(ToolPackagesStep).backend
      unless runner.command_exists?(backend.command)
        return StepResult::Failure.new(item.key,
          "#{backend.command} is not on PATH; install it before this step", 1)
      end
      run_commands(step, item, runner) { |line| sink.call(line) }
    end
  end

  # `sdkman-packages` — SDKMAN has no argv interface, only shell functions, so
  # its candidates are installed through a sourced login shell.
  class SdkmanExecutor < StepExecutor
    INSTALL_TIMEOUT = 10.minutes

    def supports?(step : Step) : Bool
      step.is_a?(SdkmanPackagesStep)
    end

    def commands(step : Step, item : ModuleItem) : Array(Command)
      sdkman = step.as(SdkmanPackagesStep)
      candidate = sdkman.candidates.find { |value| value.candidate == item.key }
      return [] of Command unless candidate

      version = candidate.version.try { |value| " #{value}" } || ""
      script = %(source "$HOME/.sdkman/bin/sdkman-init.sh" && sdk install #{candidate.candidate}#{version})
      [Command.new(["/bin/bash", "-lc", script], timeout: INSTALL_TIMEOUT)]
    end
  end

  # `system-update` — refresh metadata, or upgrade everything.
  class SystemUpdateExecutor < StepExecutor
    def supports?(step : Step) : Bool
      step.is_a?(SystemUpdateStep)
    end

    def commands(step : Step, item : ModuleItem) : Array(Command)
      update = step.as(SystemUpdateStep)
      manager = update.package_manager
      timeout = update.timeout

      case manager
      when .zypper?
        prefix = ["sudo", "zypper", "--non-interactive"]
        refresh = Command.new(prefix + ["refresh"], timeout: timeout)
        return [refresh] if update.refresh_only?
        [refresh, Command.new(prefix + [update.dist_upgrade? ? "dup" : "update", "-y"], timeout: timeout)]
      when .dnf?
        # `dnf check-update` exits 100 when updates are available, which is the
        # answer to the question rather than a failure.
        if update.refresh_only?
          [Command.new(["sudo", "dnf", "check-update", "--refresh"],
            timeout: timeout, success_codes: Set{0, 100})]
        else
          [Command.new(["sudo", "dnf", "upgrade", "-y", "--refresh"], timeout: timeout)]
        end
      when .pacman?, .paru?, .yay?
        argv = update.refresh_only? ? ["sudo", "pacman", "-Sy", "--noconfirm"] : ["sudo", "pacman", "-Syu", "--noconfirm"]
        [Command.new(argv, timeout: timeout)]
      when .apt?
        refresh = Command.new(["sudo", "apt-get", "update"], timeout: timeout)
        return [refresh] if update.refresh_only?
        verb = update.dist_upgrade? ? "full-upgrade" : "upgrade"
        [refresh, Command.new(["sudo", "apt-get", verb, "-y"], timeout: timeout)]
      else
        [] of Command
      end
    end
  end

  # `user-groups` — append-only membership.
  class UserGroupsExecutor < StepExecutor
    TIMEOUT = 30.seconds

    def supports?(step : Step) : Bool
      step.is_a?(UserGroupsStep)
    end

    def commands(step : Step, item : ModuleItem) : Array(Command)
      groups = step.as(UserGroupsStep)
      _, _, group = item.key.rpartition(':')
      group = item.key if group.empty?
      user = Host.target_user(groups.user)

      commands = [] of Command
      commands << Command.new(["sudo", "groupadd", "-f", group], timeout: TIMEOUT) if groups.create_missing?
      commands << Command.new(["sudo", "usermod", "-aG", group, user], timeout: TIMEOUT)
      commands
    end

    # A missing group usually means a typo or an uninstalled package, and
    # quietly creating a real but useless group would hide that.
    def execute(step : Step, item : ModuleItem, runner : ShellRunner, &sink : String ->) : StepResult
      groups = step.as(UserGroupsStep)
      unless groups.create_missing?
        _, _, group = item.key.rpartition(':')
        group = item.key if group.empty?

        exists = runner.run(Command.new(["getent", "group", group], timeout: TIMEOUT))
        unless exists.success?
          return StepResult::Failure.new(item.key,
            "group '#{group}' does not exist; install the package that provides it " \
            "or set createMissing: true", 1)
        end
      end
      run_commands(step, item, runner) { |line| sink.call(line) }
    end
  end

  # `git-config` — set one key at a time so drift is reportable per key.
  class GitConfigExecutor < StepExecutor
    TIMEOUT = 30.seconds

    def supports?(step : Step) : Bool
      step.is_a?(GitConfigStep)
    end

    def commands(step : Step, item : ModuleItem) : Array(Command)
      config = step.as(GitConfigStep)
      _, _, key = item.key.partition(':')
      value = config.entries[key]?
      return [] of Command unless value

      argv = ["git", "config", config.scope.flag, key, value]
      argv.unshift("sudo") if config.scope.privileged?
      [Command.new(argv, timeout: TIMEOUT)]
    end
  end

  # `git-repo` — clone at an exact commit.
  #
  # A new checkout is staged beside its destination and only moved into place
  # once origin and HEAD verify, so an interrupted clone never leaves a
  # half-populated directory that later looks installed.
  class GitRepoExecutor < StepExecutor
    TIMEOUT = 10.minutes

    def supports?(step : Step) : Bool
      step.is_a?(GitRepoStep)
    end

    def commands(step : Step, item : ModuleItem) : Array(Command)
      repo = step.as(GitRepoStep).repos.find { |candidate| candidate.destination == item.key }
      return [] of Command unless repo

      destination = expand(repo.destination)
      depth = repo.depth.try { |value| ["--depth", value.to_s] } || [] of String

      commands = [
        Command.new(["git", "init", "--quiet", "--", destination], timeout: TIMEOUT),
        Command.new(["git", "-C", destination, "remote", "add", "origin", repo.url], timeout: TIMEOUT),
        # Fetching the commit directly keeps the pin reachable even after the
        # upstream default branch has moved past a shallow depth.
        Command.new(["git", "-c", "protocol.file.allow=never", "-C", destination, "fetch"] +
                    depth + ["origin", repo.ref], timeout: TIMEOUT),
        Command.new(["git", "-C", destination, "checkout", "--detach", "FETCH_HEAD"], timeout: TIMEOUT),
      ]

      if repo.submodules?
        commands << Command.new(
          ["git", "-c", "protocol.allow=never", "-c", "protocol.https.allow=always",
           "-C", destination, "submodule", "update", "--init", "--recursive"], timeout: TIMEOUT)
      end

      commands
    end

    # An existing destination is inspected, never pulled or reset: overwriting
    # a checkout the user has been working in would lose their work.
    def execute(step : Step, item : ModuleItem, runner : ShellRunner, &sink : String ->) : StepResult
      repo = step.as(GitRepoStep).repos.find { |candidate| candidate.destination == item.key }
      return StepResult::Success.new(item.key) unless repo

      destination = expand(repo.destination)
      return run_commands(step, item, runner) { |line| sink.call(line) } unless Dir.exists?(destination)

      unless Dir.exists?(File.join(destination, ".git"))
        return StepResult::Failure.new(item.key,
          "git-repo destination exists but is not a Git worktree: #{destination}", 1)
      end

      verify(repo, destination, item, runner)
    end

    private def verify(repo : GitRepo, destination : String, item : ModuleItem, runner : ShellRunner) : StepResult
      env = {"GIT_OPTIONAL_LOCKS" => "0"}

      origin = runner.run(Command.new(["git", "-C", destination, "remote", "get-url", "origin"],
        env: env, timeout: TIMEOUT))
      unless origin.success? && origin.stdout.strip == repo.url
        return StepResult::Failure.new(item.key,
          "git-repo destination origin does not match the configured URL", 1)
      end

      head = runner.run(Command.new(["git", "-C", destination, "rev-parse", "--verify", "HEAD"],
        env: env, timeout: TIMEOUT))
      unless head.success? && head.stdout.strip.compare(repo.ref, case_insensitive: true) == 0
        return StepResult::Failure.new(item.key,
          "git-repo destination HEAD does not match the configured commit", 1)
      end

      StepResult::Success.new(item.key, detected_version: repo.ref[0, 7])
    end

    private def expand(path : String) : String
      # Destinations support shell-style paths so they can be copied straight
      # out of an existing script.
      expanded = path.gsub(/\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-([^}]*))?\}/) do |_, match|
        ENV[match[1]]?.presence || match[2]? || ""
      end
      expanded.starts_with?("~/") ? File.join(Host.home, expanded[2..]) : expanded
    end
  end

  # `systemd-unit` — enable, start, stop, or mask.
  class SystemdUnitExecutor < StepExecutor
    TIMEOUT = 2.minutes

    def supports?(step : Step) : Bool
      step.is_a?(SystemdUnitStep)
    end

    def commands(step : Step, item : ModuleItem) : Array(Command)
      units = step.as(SystemdUnitStep)
      unit = units.units.find { |candidate| candidate.qualified_name == item.key }
      return [] of Command unless unit

      # Masking is a refusal to start, so it replaces the rest rather than
      # combining with it.
      return [systemctl(units, "mask", unit.qualified_name)] if unit.masked?

      commands = [] of Command
      commands << systemctl(units, "enable", unit.qualified_name) if unit.enabled?
      case unit.state
      when .started? then commands << systemctl(units, "start", unit.qualified_name)
      when .stopped? then commands << systemctl(units, "stop", unit.qualified_name)
      end
      commands
    end

    # A profile that mentions units should stay usable in a container or an
    # image build, so a missing systemd skips rather than fails.
    def execute(step : Step, item : ModuleItem, runner : ShellRunner, &sink : String ->) : StepResult
      unless runner.command_exists?("systemctl")
        return StepResult::Skipped.new(item.key, "systemctl is not available")
      end
      run_commands(step, item, runner) { |line| sink.call(line) }
    end

    private def systemctl(step : SystemdUnitStep, verb : String, unit : String) : Command
      argv = ["systemctl", step.scope.flag, verb, unit]
      argv.unshift("sudo") if step.scope.privileged?
      Command.new(argv, timeout: TIMEOUT)
    end
  end

  # `system-setting` — timedatectl / hostnamectl / localectl.
  class SystemSettingExecutor < StepExecutor
    TIMEOUT = 60.seconds

    def supports?(step : Step) : Bool
      step.is_a?(SystemSettingStep)
    end

    def commands(step : Step, item : ModuleItem) : Array(Command)
      setting = step.as(SystemSettingStep)

      argv = case item.key
             when "localRtc"
               setting.local_rtc?.try { |value| ["sudo", "timedatectl", "set-local-rtc", value ? "1" : "0"] }
             when "ntp"
               setting.ntp?.try { |value| ["sudo", "timedatectl", "set-ntp", value.to_s] }
             when "timezone"
               setting.timezone.try { |value| ["sudo", "timedatectl", "set-timezone", value] }
             when "hostname"
               setting.hostname.try { |value| ["sudo", "hostnamectl", "set-hostname", value] }
             else
               locale_argv(setting, item.key)
             end

      argv ? [Command.new(argv, timeout: TIMEOUT)] : [] of Command
    end

    private def locale_argv(setting : SystemSettingStep, key : String) : Array(String)?
      return unless key.starts_with?("locale:")
      name = key.lchop("locale:")
      value = setting.locale[name]?
      value.try { |entry| ["sudo", "localectl", "set-locale", "#{name}=#{entry}"] }
    end
  end

  # `default-shell` — change the login shell.
  class DefaultShellExecutor < StepExecutor
    TIMEOUT = 30.seconds

    def supports?(step : Step) : Bool
      step.is_a?(DefaultShellStep)
    end

    def commands(step : Step, item : ModuleItem) : Array(Command)
      shell = step.as(DefaultShellStep).shell_path
      [Command.new(["sudo", "chsh", "-s", shell, Host.target_user], timeout: TIMEOUT)]
    end

    # Setting a login shell that does not exist locks the user out of their own
    # account, so this is checked before the change rather than after.
    def execute(step : Step, item : ModuleItem, runner : ShellRunner, &sink : String ->) : StepResult
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

    def commands(step : Step, item : ModuleItem) : Array(Command)
      [Command.new(step.as(ShellReloadStep).reload_argv, timeout: TIMEOUT)]
    end

    def execute(step : Step, item : ModuleItem, runner : ShellRunner, &sink : String ->) : StepResult
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

    def commands(step : Step, item : ModuleItem) : Array(Command)
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

    def execute(step : Step, item : ModuleItem, runner : ShellRunner, &sink : String ->) : StepResult
      command = find(step, item)
      return StepResult::Success.new(item.key) unless command

      if skip = guard(command, runner)
        return skip
      end
      run_commands(step, item, runner) { |line| sink.call(line) }
    end

    private def find(step : Step, item : ModuleItem) : ShellCommandItem?
      step.as(ShellCommandStep).commands.find { |command| command.name == item.key }
    end
  end

  # `shell-script` — run a local or verified remote script.
  class ShellScriptExecutor < StepExecutor
    include ShellItemSupport

    def supports?(step : Step) : Bool
      step.is_a?(ShellScriptStep)
    end

    def commands(step : Step, item : ModuleItem) : Array(Command)
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

    def execute(step : Step, item : ModuleItem, runner : ShellRunner, &sink : String ->) : StepResult
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

    private def find(step : Step, item : ModuleItem) : ShellScriptItem?
      step.as(ShellScriptStep).scripts.find { |script| script.name == item.key }
    end
  end

  # `assert` — require a host condition before continuing.
  class AssertExecutor < StepExecutor
    TIMEOUT = 5.minutes

    def supports?(step : Step) : Bool
      step.is_a?(AssertStep)
    end

    def commands(step : Step, item : ModuleItem) : Array(Command)
      assert = step.as(AssertStep)
      [Command.new(assert.argv, working_dir: assert.working_dir, timeout: TIMEOUT)]
    end

    # The configured message replaces the command output: it is written for
    # someone who has to go fix the machine, not for a debugging session.
    def execute(step : Step, item : ModuleItem, runner : ShellRunner, &sink : String ->) : StepResult
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

    def commands(step : Step, item : ModuleItem) : Array(Command)
      probe = step.probe_command
      return [] of Command unless probe
      [Command.new(["/bin/bash", "-lc", probe], timeout: TIMEOUT)]
    end

    # Without a probe there is no way to know the human did the thing, so the
    # step fails with its message rather than silently passing.
    def execute(step : Step, item : ModuleItem, runner : ShellRunner, &_sink : String ->) : StepResult
      manual = step.as(ManualStep)
      probe = manual.probe_command
      unless probe
        return StepResult::Failure.new(item.key, "Manual step required: #{manual.message}", 2)
      end

      result = runner.run(Command.new(["/bin/bash", "-lc", probe], timeout: TIMEOUT))
      return StepResult::Success.new(item.key, result.elapsed) if result.success?
      StepResult::Failure.new(item.key, manual.message, result.exit_code, result.elapsed)
    end
  end
end
