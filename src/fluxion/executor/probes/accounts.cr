module Fluxion::Executor
  # The user's login shell.
  class DefaultShellProbe < Probe
    def supports?(item : StepItem) : Bool
      item.item_type.default_shell?
    end

    def probe(item : StepItem, runner : ShellRunner) : InstallationStatus
      user = Host.target_user
      result = runner.run(Command.new(["getent", "passwd", user], timeout: 5.seconds))
      unless result.success?
        return InstallationStatus::Unknown.new(item.key, "getent passwd exited #{result.exit_code}")
      end

      fields = result.stdout.strip.split(':')
      unless fields.size >= 7
        return InstallationStatus::Unknown.new(item.key, "unexpected getent output")
      end

      current = fields[6]
      return InstallationStatus::InstalledByProbe.new(item.key, current) if current == item.key
      InstallationStatus::NotInstalled.new(item.key)
    end
  end

  # Group membership, read from the group database.
  class UserGroupProbe < Probe
    def supports?(item : StepItem) : Bool
      item.item_type.user_group?
    end

    def probe(item : StepItem, runner : ShellRunner) : InstallationStatus
      user, group = UserGroupsStep.split_item_key(item.key)
      target = user.presence || Host.target_user

      result = runner.run(Command.new(["id", "-nG", target], timeout: PROBE_TIMEOUT))
      unless result.success?
        return InstallationStatus::Unknown.new(item.key, "id -nG exited #{result.exit_code}")
      end

      member = result.stdout.split(/\s+/).any? { |name| name == group }
      member ? InstallationStatus::InstalledByProbe.new(item.key) : InstallationStatus::NotInstalled.new(item.key)
    end
  end
end
