module Fluxion::Executor
  # Repository files, keyed by the path the step would write.
  #
  # An apt source is compared with the line the step writes, and its keyring
  # has to be there too. Presence alone used to be enough, on the grounds that
  # the files were unreadable without privileges and that the step re-checks
  # before writing. Neither holds: sources.list.d is world-readable, and a
  # step whose probe says "installed" never runs at all. A vendor package or a
  # hand-written line at the same path, pointing at another keyring, therefore
  # counted as done on every run, and the declared source and keyring were
  # never written.
  #
  # The rpm-style kinds are still checked for presence only: the file they
  # write embeds the installed key's path, which only their executor renders.
  class RepositoryFileProbe < Probe
    # A source list is one line. Anything this large is not the one declared,
    # and a probe has no business reading an unbounded file to find that out.
    MAX_SOURCE_LIST_BYTES = 64 * 1024

    TYPES = [ItemType::AptRepository, ItemType::RpmRepository,
             ItemType::ZypperRepository, ItemType::PacmanRepository]

    def supports?(item : StepItem) : Bool
      TYPES.includes?(item.item_type)
    end

    def probe(item : StepItem, runner : ShellRunner) : InstallationStatus
      if item.item_type.pacman_repository?
        # Pacman repositories are sections inside a shared config file, so the
        # section header is what marks presence.
        result = runner.run(Command.new(
          ["grep", "-Fqx", "--", "[#{item.key}]", PacmanRepositoryStep::DEFAULT_CONFIG],
          timeout: PROBE_TIMEOUT))
        return InstallationStatus::InstalledByProbe.new(item.key) if result.success?
        return InstallationStatus::NotInstalled.new(item.key) if result.exit_code == 1
        return InstallationStatus::Unknown.new(item.key, "grep exited #{result.exit_code}")
      end

      info = File.info?(item.key)
      return InstallationStatus::NotInstalled.new(item.key) unless info && info.file?
      return InstallationStatus::NotInstalled.new(item.key) if info.size == 0

      if repository = item.step.as?(AptRepositoryStep)
        return probe_apt_source(item, repository, info)
      end
      InstallationStatus::InstalledByProbe.new(item.key)
    end

    # The executor writes exactly `source` and a newline; a file without the
    # final newline still says the same thing to apt, so that much is allowed.
    private def probe_apt_source(item : StepItem, repository : AptRepositoryStep,
                                 info : File::Info) : InstallationStatus
      return InstallationStatus::NotInstalled.new(item.key) if info.size > MAX_SOURCE_LIST_BYTES

      content = begin
        File.read(item.key)
      rescue error : IO::Error
        return InstallationStatus::Unknown.new(item.key, "could not read #{item.key}: #{error.message}")
      end
      return InstallationStatus::NotInstalled.new(item.key) unless content.chomp == repository.source

      # Only a keyring this step installs itself is its business: without a
      # signing key it belongs to another step, and rerunning this one could
      # not produce it.
      keyring = repository.keyring
      if repository.signing_key && keyring
        present = File.info?(keyring).try { |found| found.file? && found.size > 0 }
        return InstallationStatus::NotInstalled.new(item.key) unless present
      end

      InstallationStatus::InstalledByProbe.new(item.key)
    end
  end

  # `gpg-key` entries that install a keyring, checked for the declared key.
  #
  # Registered ahead of `PathProbe`, which used to answer for these by the path
  # alone: a keyring left at the same path by a vendor package or an older
  # setup, holding another key, counted as installed, so the declared key was
  # never written. The rule is the executor's own — exactly one primary key,
  # the declared one — read unprivileged from the installed file.
  #
  # An RPM-imported key has no path to read and no step here to compare with,
  # and neither does an item from a state file alone, so those are left to the
  # probes after this one.
  class GpgKeyringProbe < Probe
    def supports?(item : StepItem) : Bool
      item.item_type.gpg_key? && item.key.starts_with?('/') && !entry(item).nil?
    end

    def probe(item : StepItem, runner : ShellRunner) : InstallationStatus
      expected = entry(item).not_nil!.fingerprint

      info = File.info?(item.key)
      return InstallationStatus::NotInstalled.new(item.key) unless info && info.file? && info.size > 0
      return InstallationStatus::Unknown.new(item.key, "gpg is not on PATH") unless runner.command_exists?("gpg")

      result = GpgKeyListing.run(runner, item.key, PROBE_TIMEOUT)
      unless result.success?
        return InstallationStatus::Unknown.new(item.key,
          "gpg could not read the keyring (exit #{result.exit_code})")
      end

      if GpgKeyListing.primary_fingerprints(result.stdout) == [expected.value]
        InstallationStatus::InstalledByProbe.new(item.key)
      else
        InstallationStatus::NotInstalled.new(item.key)
      end
    end

    private def entry(item : StepItem) : GpgKeyEntry?
      item.step.as?(GpgKeyStep).try(&.keys.find { |key| key.keyring == item.key })
    end
  end
end
