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

      unless runner.command_exists?(query_command(manager))
        return InstallationStatus::Unknown.new(item.key,
          "#{query_command(manager)} is not on PATH")
      end

      result = runner.run(Command.new(manager.query_argv(item.key), timeout: PROBE_TIMEOUT))

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
    private def interpret_dpkg_query(key : String, stdout : String) : InstallationStatus
      stdout.each_line do |line|
        status, _, version = line.strip.partition('|')
        return InstallationStatus::InstalledByProbe.new(key, version.presence) if status == "install ok installed"
      end
      InstallationStatus::NotInstalled.new(key)
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

    private def query_command(manager : PackageManager) : String
      manager.query_argv("x").first
    end
  end

  # What `cargo install --list` says about one crate.
  #
  # It prints every installed crate and pays no attention to the name it was
  # asked about, so its exit code says nothing about this item and the listing
  # has to be scanned the way the flatpak probe scans its own.
  #
  # Each crate is a line at column 0 reading "name vX.Y.Z:", with the source
  # in parentheses when it came from a git checkout or a local path, and the
  # binaries it provides indented underneath. Matching on the name followed
  # by a space is therefore enough to tell a crate named `rg` from a binary
  # named `rg` listed under some other crate.
  module CargoInstallList
    LIST_ARGV = PackageManager::Cargo.query_argv("")

    def self.status(key : String, result : ProcessResult) : InstallationStatus
      unless result.success?
        return InstallationStatus::Unknown.new(key, "cargo install --list exited #{result.exit_code}")
      end

      line = result.stdout.lines.find(&.starts_with?("#{key} "))
      return InstallationStatus::NotInstalled.new(key) unless line

      # "ripgrep v14.1.0:" and "mycrate v0.1.0 (/home/me/src):" both yield the
      # bare version, since only the first spelling carries the colon.
      version = line.split(' ')[1]?.try(&.lchop('v').rchop(':'))
      InstallationStatus::InstalledByProbe.new(key, version.presence)
    end
  end

  # `tool-packages` items installed by `cargo` or `cargo-binstall`.
  #
  # cargo-binstall records what it installs in cargo's own install list, so
  # both backends are answered by the same listing `PackageProbe` reads for
  # `cargo-packages`. Without this every crate was unknown to `status`, and
  # `--re-probe` ran every install again.
  #
  # The other backends are not claimed, so a step's `probeCommand` still
  # answers for them.
  class ToolPackageProbe < Probe
    BACKENDS = [ToolBackend::Cargo, ToolBackend::CargoBinstall]

    def supports?(item : StepItem) : Bool
      item.item_type.tool_package? && !package(item).nil?
    end

    def probe(item : StepItem, runner : ShellRunner) : InstallationStatus
      package = package(item).not_nil!
      return InstallationStatus::Unknown.new(item.key, "cargo is not on PATH") unless runner.command_exists?("cargo")

      status = CargoInstallList.status(item.key, runner.run(Command.new(CargoInstallList::LIST_ARGV, timeout: PROBE_TIMEOUT)))
      pin = package.version
      return status unless pin && status.is_a?(InstallationStatus::InstalledByProbe)

      pinned?(status.detected_version, pin) ? status : InstallationStatus::NotInstalled.new(item.key)
    end

    # A crate installed at another version than the pin is not the configured
    # item, the same reading `GitRepoProbe` gives a checkout at the wrong
    # commit; otherwise a changed pin would never be applied under
    # `--re-probe`. A plain or partial version ("0.10.2", "0.10", "=0.10.2")
    # is compared component by component. A requirement with an operator is
    # left to the installer, which resolves it against the registry — this
    # probe cannot, so presence is the answer it gives.
    private def pinned?(installed : String?, pin : String) : Bool
      wanted = pin.strip.lchop('=').strip
      return true unless wanted.matches?(/\A\d+(\.\d+){0,2}(-[0-9A-Za-z.-]+)?\z/)
      return false unless installed

      installed == wanted || installed.starts_with?("#{wanted}.")
    end

    private def package(item : StepItem) : ToolPackage?
      step = item.step.as?(ToolPackagesStep)
      return unless step && BACKENDS.includes?(step.backend)
      step.packages.find { |candidate| candidate.name == item.key }
    end
  end

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
      item.item_type.sdkman_package?
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

      result = runner.run(Command.new(GpgKeyListing.argv(item.key), timeout: PROBE_TIMEOUT))
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

  # Cloned repositories, checked by origin and HEAD rather than mere presence.
  class GitRepoProbe < Probe
    def supports?(item : StepItem) : Bool
      item.item_type.git_repo?
    end

    def probe(item : StepItem, runner : ShellRunner) : InstallationStatus
      # Through the injected runner rather than `Host` directly: this probe is
      # handed a seam and consulting the real host anyway makes it answer from
      # a different machine than the one a spec is describing.
      destination = runner.command_exists?("git") ? expand(item.key) : nil
      return InstallationStatus::Unknown.new(item.key, "git is not on PATH") unless destination
      return InstallationStatus::NotInstalled.new(item.key) unless Dir.exists?(File.join(destination, ".git"))

      step = item.step.as?(GitRepoStep)
      repo = step.try(&.repos.find { |candidate| expand(candidate.destination) == destination })
      return InstallationStatus::InstalledByProbe.new(item.key) unless repo

      head = runner.run(Command.new(
        ["git", "-C", destination, "rev-parse", "--verify", "HEAD"],
        env: {"GIT_OPTIONAL_LOCKS" => "0"}, timeout: PROBE_TIMEOUT))

      unless head.success?
        return InstallationStatus::Unknown.new(item.key, "could not read HEAD")
      end

      # A checkout at the wrong commit is not the configured item, so it counts
      # as absent rather than present-but-stale.
      actual = head.stdout.strip.downcase
      return InstallationStatus::NotInstalled.new(item.key) unless actual == repo.ref.downcase
      InstallationStatus::InstalledByProbe.new(item.key, actual[0, 7])
    end

    private def expand(path : String) : String
      path.starts_with?("~/") ? Path.posix(Host.home, path[2..]).normalize.to_s : path
    end
  end

  # Git configuration keys, compared by value so drift is visible.
  class GitConfigProbe < Probe
    def supports?(item : StepItem) : Bool
      item.item_type.git_config?
    end

    def probe(item : StepItem, runner : ShellRunner) : InstallationStatus
      # Same guard as `GitRepoProbe`: without git there is no answer to give,
      # and "git is missing" is not the same claim as "the key is unset".
      return InstallationStatus::Unknown.new(item.key, "git is not on PATH") unless runner.command_exists?("git")

      scope, _, key = item.key.partition(':')
      return InstallationStatus::Unknown.new(item.key, "malformed git-config item key") if key.empty?

      step = item.step.as?(GitConfigStep)
      desired = step.try(&.entries[key]?)

      result = runner.run(Command.new(["git", "config", "--#{scope}", "--get", key], timeout: PROBE_TIMEOUT))
      unless result.success?
        # `git config --get` exits 1 for "that key is not set", which is a real
        # answer. Any other code — 128 when `--local` is used outside a work
        # tree — means the question was never answered, and reporting that as
        # absence would tell the user a key is missing that may well be set.
        return InstallationStatus::NotInstalled.new(item.key) if result.exit_code == 1
        return InstallationStatus::Unknown.new(item.key,
          "git config --#{scope} --get exited #{result.exit_code}")
      end

      current = result.stdout.strip
      return InstallationStatus::NotInstalled.new(item.key) if current.empty?
      return InstallationStatus::InstalledByProbe.new(item.key, current) if desired.nil? || current == desired
      InstallationStatus::NotInstalled.new(item.key)
    end
  end

  # systemd units, checked against the state the profile asked for.
  class SystemdUnitProbe < Probe
    # Every word `systemctl is-enabled` and `systemctl is-active` can print.
    #
    # The lists exist because the runner folds stderr into stdout, so a
    # systemctl that cannot answer at all — the ordinary case inside a
    # container, where it writes "System has not been booted with systemd as
    # init system (PID 1). Can't operate." and exits 1 — hands this probe a
    # sentence where a state word belongs. Exit codes cannot tell the two
    # apart, because the legitimate `disabled` also exits 1 and `is-active`
    # exits non-zero for the legitimate `inactive` and `failed`. The word
    # itself is the only signal that a question was answered.
    IS_ENABLED_WORDS = %w[enabled enabled-runtime linked linked-runtime alias
      masked masked-runtime static indirect disabled generated transient
      not-found bad bad-setting]

    IS_ACTIVE_WORDS = %w[active reloading inactive deactivating activating
      failed maintenance refreshing unknown]

    def supports?(item : StepItem) : Bool
      item.item_type.systemd_unit?
    end

    def probe(item : StepItem, runner : ShellRunner) : InstallationStatus
      # In a container or an image build there is no systemd, and a profile
      # that mentions units should still be usable there.
      return InstallationStatus::Unknown.new(item.key, "systemctl is not available") unless runner.command_exists?("systemctl")

      step = item.step.as?(SystemdUnitStep)
      unit = step.try(&.units.find { |candidate| candidate.qualified_name == item.key })
      scope = step.try(&.scope) || SystemdScope::System

      enabled = runner.run(Command.new(
        ["systemctl", scope.flag, "is-enabled", item.key], timeout: PROBE_TIMEOUT))
      word = enabled.stdout.lines.first?.try(&.strip) || ""
      unless IS_ENABLED_WORDS.includes?(word)
        # The rejected text, not the exit code, is why this probe gave up —
        # `disabled` exits 1 legitimately, so the code says nothing on its own.
        # The runner merges stderr into stdout, so the text quoted here is the
        # diagnostic systemctl actually produced.
        return InstallationStatus::Unknown.new(item.key,
          "systemctl is-enabled said #{word.inspect} (exit #{enabled.exit_code})")
      end

      return InstallationStatus::InstalledByProbe.new(item.key, word) if unit.nil?

      if unit.masked?
        return word == "masked" ? InstallationStatus::InstalledByProbe.new(item.key, word) : InstallationStatus::NotInstalled.new(item.key)
      end

      if unit.enabled? && !SystemdUnit::ALREADY_ENABLED.includes?(word)
        # Units with no [Install] section cannot be enabled and are reachable
        # as a dependency, so requiring `enabled` of them would never pass.
        return InstallationStatus::InstalledByProbe.new(item.key, word) if SystemdUnit::NOT_ENABLEABLE.includes?(word)
        return InstallationStatus::NotInstalled.new(item.key)
      end

      return InstallationStatus::InstalledByProbe.new(item.key, word) if unit.state.unchanged?

      active = runner.run(Command.new(
        ["systemctl", scope.flag, "is-active", item.key], timeout: PROBE_TIMEOUT))
      state = active.stdout.lines.first?.try(&.strip) || ""
      unless IS_ACTIVE_WORDS.includes?(state)
        return InstallationStatus::Unknown.new(item.key,
          "systemctl is-active said #{state.inspect} (exit #{active.exit_code})")
      end

      # `unknown` is in the vocabulary above even though systemd does not list
      # it among the active states, because `is-active` prints it for a unit it
      # has never heard of; treating that as "not running" is the honest
      # reading, and it is what this probe did before the allowlist existed.
      running = state == "active"

      satisfied = unit.state.started? ? running : !running
      satisfied ? InstallationStatus::InstalledByProbe.new(item.key, word) : InstallationStatus::NotInstalled.new(item.key)
    end
  end

  # Host settings, read back through the same tools that set them.
  #
  # Each setting is compared by value, so a machine already on the profile's
  # timezone skips the item and one on another zone does not. Nothing here
  # needs privileges: the `show` side of timedatectl, hostnamectl and localectl
  # is readable by any user.
  class SystemSettingProbe < Probe
    def supports?(item : StepItem) : Bool
      item.item_type.system_setting?
    end

    def probe(item : StepItem, runner : ShellRunner) : InstallationStatus
      step = item.step.as?(SystemSettingStep)
      return InstallationStatus::Unknown.new(item.key, "no system-setting step to compare with") unless step

      case key = item.key
      when "ntp"
        step.ntp?.try { |wanted| compare_flag(item, runner, "NTP", wanted) } || unset(item)
      when "localRtc"
        step.local_rtc?.try { |wanted| compare_flag(item, runner, "LocalRTC", wanted) } || unset(item)
      when "timezone"
        step.timezone.try { |wanted| compare(item, wanted, read(item, runner, "timedatectl", ["show", "-p", "Timezone", "--value"])) } || unset(item)
      when "hostname"
        step.hostname.try { |wanted| compare(item, wanted, read(item, runner, "hostnamectl", ["--static"])) } || unset(item)
      else
        name = key.lchop?("locale:")
        wanted = name.try { |variable| step.locale[variable]? }
        return unset(item) unless name && wanted
        compare_locale(item, runner, name, wanted)
      end
    end

    # timedatectl prints its booleans as "yes" and "no". Anything else is the
    # runner's merged stderr — "System has not been booted with systemd" in a
    # container — and is no answer at all.
    private def compare_flag(item : StepItem, runner : ShellRunner, property : String,
                             wanted : Bool) : InstallationStatus
      answer = read(item, runner, "timedatectl", ["show", "-p", property, "--value"])
      return answer if answer.is_a?(InstallationStatus)
      return unanswered(item, "timedatectl", answer, 0) unless answer.in?("yes", "no")

      compare(item, wanted ? "yes" : "no", answer)
    end

    # `localectl status` lists one VAR=value per line under "System Locale:",
    # and the headings of the lines that follow contain ": ", which no locale
    # assignment does.
    private def compare_locale(item : StepItem, runner : ShellRunner, name : String,
                               wanted : String) : InstallationStatus
      answer = read(item, runner, "localectl", ["status"], whole: true)
      return answer if answer.is_a?(InstallationStatus)

      current = nil
      answer.each_line do |raw|
        line = raw.strip.lchop("System Locale:").strip
        next if line.includes?(": ")
        variable, equals, value = line.partition('=')
        current = value if equals == "=" && variable == name
      end

      current ? compare(item, wanted, current) : InstallationStatus::NotInstalled.new(item.key)
    end

    # The tool's answer, trimmed to its first line unless `whole` is set, or
    # the status that says why there is none.
    private def read(item : StepItem, runner : ShellRunner, tool : String, arguments : Array(String),
                     whole : Bool = false) : String | InstallationStatus
      return InstallationStatus::Unknown.new(item.key, "#{tool} is not on PATH") unless runner.command_exists?(tool)

      result = runner.run(Command.new([tool] + arguments, timeout: PROBE_TIMEOUT))
      output = whole ? result.stdout : (result.stdout.lines.first?.try(&.strip) || "")
      return output if result.success? && !output.strip.empty?
      unanswered(item, tool, output, result.exit_code)
    end

    private def compare(item : StepItem, wanted : String, current : String | InstallationStatus) : InstallationStatus
      return current if current.is_a?(InstallationStatus)
      return InstallationStatus::InstalledByProbe.new(item.key, current) if current == wanted
      InstallationStatus::NotInstalled.new(item.key)
    end

    private def unanswered(item : StepItem, tool : String, said : String, exit_code : Int32) : InstallationStatus
      InstallationStatus::Unknown.new(item.key,
        "#{tool} said #{said.strip.lines.first?.inspect} (exit #{exit_code})")
    end

    # An item key the step does not set: not something this probe was asked.
    private def unset(item : StepItem) : InstallationStatus
      InstallationStatus::Unknown.new(item.key, "#{item.key} is not set by this step")
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

  # Deliberately absent: a NerdFontProbe grepping `fc-list` for the item key.
  #
  # It only worked while an inline font list made each family its own item.
  # With the config delegated the key is a path, which `fc-list` will never
  # report. It also registered ahead of `ConfiguredProbeCommand` with an
  # unconditional `supports?`, so it silently shadowed any `probeCommand` a
  # user wrote on this kind — which is now the only way to make the step
  # skippable.

  # The fallback: whatever the step's own `probeCommand` says.
  #
  # Registered last so a typed probe always wins, but it is what makes kinds
  # with no observable footprint — shell commands, scripts, manual checkpoints
  # — skippable at all.
  #
  # The command belongs to the step, so its answer is the step's: every item
  # of the step is done, or none is.
  class ConfiguredProbeCommand < Probe
    def supports?(item : StepItem) : Bool
      !item.step.try(&.probe_command).nil?
    end

    def answers_for_step? : Bool
      true
    end

    def probe(item : StepItem, runner : ShellRunner) : InstallationStatus
      command = item.step.try(&.probe_command)
      return InstallationStatus::Unknown.new(item.key, "no probeCommand configured") unless command

      result = runner.run(Command.new(["/bin/bash", "-lc", command], timeout: 30.seconds))
      result.success? ? InstallationStatus::InstalledByProbe.new(item.key) : InstallationStatus::NotInstalled.new(item.key)
    end
  end

  # Answers for an assert by running its check.
  #
  # An assert has no footprint a typed probe could look for: whether it holds
  # is only known by asking, and `AssertStep#mutating?` is the promise that
  # asking changes nothing. Without this a report could say nothing about a
  # guard but "unknown", for the guards that hold and the ones that fail alike,
  # and `status --failed` listed every one of them.
  #
  # The argv and working directory are the step's own, so a report checks what
  # `apply` checks. The time allowed is a probe's, not the step's five minutes:
  # a report runs every probe in the profile, and one that could wait that
  # long would make the whole command useless.
  class AssertProbe < Probe
    TIMEOUT = 60.seconds

    def supports?(item : StepItem) : Bool
      item.step.is_a?(AssertStep)
    end

    def probe(item : StepItem, runner : ShellRunner) : InstallationStatus
      assert = item.step.as(AssertStep)
      result = runner.run(Command.new(assert.argv, working_dir: assert.working_dir, timeout: TIMEOUT))
      return InstallationStatus::InstalledByProbe.new(item.key) if result.success?

      # A check that ran out of time has not said the guard fails. The runner
      # reports a timeout in `stderr`, which a finished process never fills,
      # because the two streams are merged into `stdout`.
      if result.exit_code == SystemShellRunner::TIMEOUT_EXIT_CODE && !result.stderr.empty?
        return InstallationStatus::Unknown.new(item.key, "check did not finish within #{TIMEOUT.total_seconds.to_i}s")
      end

      InstallationStatus::NotInstalled.new(item.key)
    end
  end
end
