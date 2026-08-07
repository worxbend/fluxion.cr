module Fluxion::Executor
  # Executors that change system or account state: group membership, git
  # configuration, checked-out repositories, systemd units, and sysctl-style
  # settings.
  # `user-groups` — append-only membership.
  class UserGroupsExecutor < StepExecutor
    TIMEOUT = 30.seconds

    def supports?(step : Step) : Bool
      step.is_a?(UserGroupsStep)
    end

    def commands(step : Step, item : StepItem) : Array(Command)
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
    def execute(step : Step, item : StepItem, runner : ShellRunner, &sink : String ->) : StepResult
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

    def commands(step : Step, item : StepItem) : Array(Command)
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

    def commands(step : Step, item : StepItem) : Array(Command)
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
    def execute(step : Step, item : StepItem, runner : ShellRunner, &sink : String ->) : StepResult
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

    private def verify(repo : GitRepo, destination : String, item : StepItem, runner : ShellRunner) : StepResult
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

    def commands(step : Step, item : StepItem) : Array(Command)
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
    def execute(step : Step, item : StepItem, runner : ShellRunner, &sink : String ->) : StepResult
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

    def commands(step : Step, item : StepItem) : Array(Command)
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
end
