module Fluxion::Executor
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
    def items(step : Step) : Array(StepItem)
      packages = step.as(PackagesStep)
      actions = packages.actions.map_with_index do |action, index|
        StepItem.new(step.name, "action[#{index}]", ItemType::PackageAction,
          action.to_s, packages.package_manager, step)
      end
      actions + super
    end

    def commands(step : Step, item : StepItem) : Array(Command)
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

    def commands(step : Step, item : StepItem) : Array(Command)
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

    def commands(step : Step, item : StepItem) : Array(Command)
      tool = step.as(ToolPackagesStep)
      package = tool.packages.find { |candidate| candidate.name == item.key }
      return [] of Command unless package
      [Command.new(tool.backend.install_argv(package), timeout: INSTALL_TIMEOUT)]
    end

    # Checked up front so a missing backend produces an actionable message
    # instead of a bare command-not-found from each package in turn.
    def execute(step : Step, item : StepItem, runner : ShellRunner, &sink : String ->) : StepResult
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

    def commands(step : Step, item : StepItem) : Array(Command)
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

    def commands(step : Step, item : StepItem) : Array(Command)
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
        # Not `[] of Command`. `run_commands` treats an empty sequence as done,
        # so a manager with no branch here reported `✔ ok` having run nothing,
        # and `RunSummary#ok?` then exited 0. `step_parser` rejects the two
        # managers that legitimately have no system-update path before a step
        # can be built, so reaching this means the enum grew and this table did
        # not.
        raise ExecutionError.new(
          "No system-update commands defined for #{manager.config_name}")
      end
    end
  end
end
