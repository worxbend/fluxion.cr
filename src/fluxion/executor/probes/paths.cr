module Fluxion::Executor
  # Anything identified by an absolute path existing.
  class PathProbe < Probe
    # `CompiledBinary` is retained for the same reason the enum member is:
    # nothing produces it since `binary-downloads` was removed, but state files
    # previous runs wrote still contain it, and `status` should answer for
    # those rather than reporting "no probe registered".
    TYPES = [ItemType::CompiledBinary, ItemType::FileWrite, ItemType::OhMyZsh, ItemType::GpgKey]

    def supports?(item : StepItem) : Bool
      TYPES.includes?(item.item_type) && item.key.starts_with?('/')
    end

    def probe(item : StepItem, runner : ShellRunner) : InstallationStatus
      info = File.info?(item.key)
      return InstallationStatus::NotInstalled.new(item.key) unless info

      InstallationStatus::InstalledByProbe.new(item.key)
    end
  end
end
