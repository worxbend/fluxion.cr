module Fluxion::Executor
  # Flatpak applications, and the extensions a flatpak step installs the same way.
  #
  # `flatpak install -y REMOTE ID` installs whatever ref ID names, and an OBS
  # plugin (com.obsproject.Studio.Plugin.*) or a GL driver is a runtime ref, not
  # an app. `flatpak list --app` leaves runtimes out, so those items read as
  # absent after every install and ran again on every run. The listing is every
  # installed ref (`PackageManager::Flatpak#query_argv`).
  class FlatpakProbe < Probe
    def supports?(item : StepItem) : Bool
      item.item_type.flatpak?
    end

    def probe(item : StepItem, runner : ShellRunner) : InstallationStatus
      return InstallationStatus::Unknown.new(item.key, "flatpak is not on PATH") unless runner.command_exists?("flatpak")

      result = runner.run(Command.new(PackageManager::Flatpak.query_argv(item.key), timeout: SLOW_PROBE_TIMEOUT))

      unless result.success?
        return InstallationStatus::Unknown.new(item.key, "flatpak list exited #{result.exit_code}")
      end

      installed = result.stdout.lines.any? { |line| line.strip == item.key }
      installed ? InstallationStatus::InstalledByProbe.new(item.key) : InstallationStatus::NotInstalled.new(item.key)
    end
  end

  # Flatpak remotes.
  class FlatpakRemoteProbe < Probe
    def supports?(item : StepItem) : Bool
      item.item_type.flatpak_remote?
    end

    def probe(item : StepItem, runner : ShellRunner) : InstallationStatus
      return InstallationStatus::Unknown.new(item.key, "flatpak is not on PATH") unless runner.command_exists?("flatpak")

      result = runner.run(Command.new(["flatpak", "remotes", "--columns=name"], timeout: SLOW_PROBE_TIMEOUT))
      unless result.success?
        return InstallationStatus::Unknown.new(item.key, "flatpak remotes exited #{result.exit_code}")
      end

      present = result.stdout.lines.any? { |line| line.strip == item.key }
      present ? InstallationStatus::InstalledByProbe.new(item.key) : InstallationStatus::NotInstalled.new(item.key)
    end
  end
end
