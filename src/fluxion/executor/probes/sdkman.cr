module Fluxion::Executor
  # `sdkman-packages` candidates, read from SDKMAN's own directory.
  #
  # `sdk install` unpacks each version to `candidates/<candidate>/<version>`
  # and links `current` to the default one, so the layout on disk is the
  # answer and nothing needs to be sourced to read it. The directory is the
  # one `sdkman-init.sh` settles on for the executor's shell: `SDKMAN_DIR`
  # when it is set, `~/.sdkman` otherwise.
  #
  # Without this every candidate was unknown to `status`, and `--re-probe`
  # ran `sdk install` for each one again.
  class SdkmanProbe < Probe
    def supports?(item : StepItem) : Bool
      item.item_type.sdkman_package? && !configured_check?(item)
    end

    def probe(item : StepItem, runner : ShellRunner) : InstallationStatus
      root = File.join(SdkmanProbe.directory, "candidates", item.key)
      pin = item.step.as?(SdkmanPackagesStep)
        .try(&.candidates.find { |candidate| candidate.candidate == item.key })
        .try(&.version)

      # Validation keeps both operands inert, but "." and ".." are inert too
      # and would walk out of the candidate's directory.
      if {item.key, pin}.any?(&.in?(".", ".."))
        return InstallationStatus::Unknown.new(item.key, "not a SDKMAN candidate path")
      end

      # A pinned candidate is installed when that version is; which one is the
      # default is `sdk default`'s business, and `sdk install` of a version
      # already there does not change it.
      if pin
        present = Dir.exists?(File.join(root, pin))
        return present ? InstallationStatus::InstalledByProbe.new(item.key, pin) : InstallationStatus::NotInstalled.new(item.key)
      end

      # `Dir.exists?` follows the link, so a `current` left pointing at a
      # removed version counts as absent.
      current = File.join(root, "current")
      return InstallationStatus::NotInstalled.new(item.key) unless Dir.exists?(current)

      version = File.symlink?(current) ? File.basename(File.readlink(current)) : nil
      InstallationStatus::InstalledByProbe.new(item.key, version.presence)
    rescue error : File::Error
      InstallationStatus::Unknown.new(item.key, "could not read #{root}: #{error.message}")
    end

    def self.directory : String
      ENV["SDKMAN_DIR"]?.presence || File.join(Host.home, ".sdkman")
    end
  end
end
