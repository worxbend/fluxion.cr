module Fluxion::Executor
  # Decides whether an item is already present, without changing anything.
  #
  # Probes are what make a rerun cheap and a plan honest. They must be
  # read-only, idempotent, and bounded: `status`, `diff`, and
  # `plan --skip-already-installed` all run every probe in a profile, so one
  # that hangs makes the whole command useless.
  #
  # An unanswerable probe reports `Unknown` rather than `NotInstalled`. The
  # difference matters: absence of evidence would silently reinstall things,
  # and the user is told which items Fluxion could not check.
  #
  # This file holds the base class, the registry and the package probe; every
  # other probe lives in probes/, one file per area.
  abstract class Probe
    abstract def supports?(item : StepItem) : Bool
    abstract def probe(item : StepItem, runner : ShellRunner) : InstallationStatus

    # True when the answer describes the item's whole step rather than the
    # item itself, so every item of the step shares it. Such an answer is
    # settled once, when the step begins: asked again before each item, it
    # would see what the step's own earlier items just did.
    def answers_for_step? : Bool
      false
    end

    # Whether the item's step declares its own `probeCommand`.
    #
    # The typed probes for `tool-packages`, `sdkman-packages` and
    # `system-setting` arrived in 0.4.0. Until then a `probeCommand` was the
    # only answer those kinds had, and it is the escape hatch for the cases a typed
    # probe reads wrongly: a crate whose installed name differs from the
    # profile's (`helix` recorded as `helix-term`), a candidate under a custom
    # SDKMAN layout. Registered ahead of `ConfiguredProbeCommand` and claiming
    # every item, they silently overrode it — the same shadowing that got
    # NerdFontProbe removed — so a probe reported missing on every run could no
    # longer be corrected from the profile. Those probes step aside for it.
    private def configured_check?(item : StepItem) : Bool
      !item.step.try(&.probe_command).nil?
    end
  end

  # Picks the first probe that handles an item.
  #
  # Order matters, so it is explicit rather than derived: package probes are
  # registered by package manager, and the first match wins.
  class ProbeRegistry
    getter probes : Array(Probe)

    def initialize(@probes : Array(Probe) = [] of Probe)
    end

    def self.default : self
      new([
        PackageProbe.new,
        ToolPackageProbe.new,
        SdkmanProbe.new,
        FlatpakProbe.new,
        FlatpakRemoteProbe.new,
        RepositoryFileProbe.new,
        GpgKeyringProbe.new,
        PathProbe.new,
        DefaultShellProbe.new,
        GitRepoProbe.new,
        GitConfigProbe.new,
        SystemdUnitProbe.new,
        SystemSettingProbe.new,
        UserGroupProbe.new,
        ConfiguredProbeCommand.new,
      ] of Probe)
    end

    # The registry `status`, `diff` and `explain` report from: the default one,
    # plus the assert check.
    #
    # Kept out of `default` because that is also the registry `apply` asks
    # before running an item, and an assert asked there would run twice on the
    # run it fails — once as the probe, once as the step — for nothing, since
    # the step is the same check.
    def self.for_reports : self
      default << AssertProbe.new
    end

    def <<(probe : Probe) : self
      @probes << probe
      self
    end

    def probe(item : StepItem, runner : ShellRunner) : InstallationStatus
      probe = @probes.find(&.supports?(item))
      unless probe
        return InstallationStatus::Unknown.new(item.key,
          "no probe registered for #{item.item_type.json_name}")
      end

      probe.probe(item, runner)
    rescue error : ExecutionError
      InstallationStatus::Unknown.new(item.key, "probe could not be executed: #{error.message}")
    end

    # Whether the probe that answers for this item answers for its whole step.
    def answers_for_step?(item : StepItem) : Bool
      @probes.find(&.supports?(item)).try(&.answers_for_step?) || false
    end
  end

  # Timeouts are short: a probe that has not answered in seconds is not going
  # to, and a profile may have hundreds of them.
  PROBE_TIMEOUT      = 10.seconds
  SLOW_PROBE_TIMEOUT = 15.seconds

  # System packages, via each manager's query command.
  class PackageProbe < Probe
    def supports?(item : StepItem) : Bool
      item.item_type.package? && !item.package_manager.nil?
    end

    def probe(item : StepItem, runner : ShellRunner) : InstallationStatus
      manager = item.package_manager.not_nil!
      argv = manager.query_argv(item.key)

      if manager.cargo?
        cargo = CargoInstallList.executable(runner)
        return CargoInstallList.not_found(item.key) unless cargo
        argv = [cargo] + argv[1..]
      elsif !runner.command_exists?(argv.first)
        return InstallationStatus::Unknown.new(item.key, "#{argv.first} is not on PATH")
      end

      result = runner.run(Command.new(argv, timeout: PROBE_TIMEOUT))

      # Exhaustive on purpose. Cargo used to fall into a default written for
      # rpm and pacman, which reported every crate installed because
      # `cargo install --list` exits 0 whatever was asked of it. Writing the
      # arms out means the next `PackageManager` member fails to compile here
      # rather than inheriting a default whose contract does not hold for it.
      case manager
      in .apt?
        return InstallationStatus::NotInstalled.new(item.key) unless result.success?
        interpret_dpkg_query(item.key, result.stdout)
      in .flatpak?
        installed = result.stdout.lines.any? { |line| line.strip == item.key }
        installed ? InstallationStatus::InstalledByProbe.new(item.key) : InstallationStatus::NotInstalled.new(item.key)
      in .cargo?
        CargoInstallList.status(item.key, result)
      in .dnf?, .zypper?, .pacman?, .paru?, .yay?
        interpret_query(item.key, result, manager)
      end
    end

    # One "status|version" line per installed architecture of the package, in
    # the format `PackageManager#query_argv` asks dpkg-query for. Any one of
    # them fully installed is enough; a package removed with its configuration
    # left behind reads "deinstall ok config-files" and counts as absent.
    #
    # `${Status}` is three words — want, error flag, state — and a package
    # pinned with `apt-mark hold` wants "hold", not "install". Matching the
    # whole string against "install ok installed" called every held package
    # absent, so `--re-probe` ran `apt-get install` for it on every run.
    private def interpret_dpkg_query(key : String, stdout : String) : InstallationStatus
      stdout.each_line do |line|
        status, _, version = line.strip.partition('|')
        return InstallationStatus::InstalledByProbe.new(key, version.presence) if dpkg_installed?(status)
      end
      InstallationStatus::NotInstalled.new(key)
    end

    private def dpkg_installed?(status : String) : Bool
      words = status.split(' ')
      return false unless words.size == 3

      want, error, state = words
      state == "installed" && error == "ok" && want.in?("install", "hold")
    end

    # rpm and pacman both use exit 1 for "not installed" and anything else for
    # a real failure, which is the difference between NotInstalled and Unknown.
    private def interpret_query(key : String, result : ProcessResult, manager : PackageManager) : InstallationStatus
      return InstallationStatus::InstalledByProbe.new(key, extract_version(result.stdout, manager, key)) if result.success?
      return InstallationStatus::NotInstalled.new(key) if result.exit_code == 1

      InstallationStatus::Unknown.new(key,
        "#{manager.query_argv(key).first} exited #{result.exit_code}")
    end

    private def extract_version(stdout : String, manager : PackageManager, key : String) : String?
      line = stdout.lines.first?.try(&.strip)
      return if line.nil? || line.empty?

      case manager
      when .pacman?, .paru?, .yay?
        # `pacman -Q git` prints "git 2.45.2".
        line.split(' ')[1]?
      else
        # `rpm -q docker-compose` prints "docker-compose-2.29.7-1.fc41.x86_64".
        # A package name may itself contain hyphens, so the key is removed as a
        # literal prefix instead of splitting on the first hyphen, which used to
        # report "compose-2.29.7-1.fc41.x86_64" as the version. The split stays
        # as the fallback for the case where rpm answered with a different name
        # than the key, as it does for a capability or file-path query.
        (line.lchop?("#{key}-") || line.partition('-')[2]).presence
      end
    end
  end
end
