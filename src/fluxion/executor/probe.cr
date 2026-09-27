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
        FlatpakProbe.new,
        FlatpakRemoteProbe.new,
        RepositoryFileProbe.new,
        PathProbe.new,
        DefaultShellProbe.new,
        GitRepoProbe.new,
        GitConfigProbe.new,
        SystemdUnitProbe.new,
        UserGroupProbe.new,
        ConfiguredProbeCommand.new,
      ] of Probe)
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
        interpret_cargo_listing(item.key, result)
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

    # `cargo install --list` prints every installed crate and pays no attention
    # to the name it was asked about, so its exit code says nothing about this
    # item and the listing has to be scanned the way the flatpak arm scans its
    # own.
    #
    # Each crate is a line at column 0 reading "name vX.Y.Z:", with the source
    # in parentheses when it came from a git checkout or a local path, and the
    # binaries it provides indented underneath. Matching on the name followed
    # by a space is therefore enough to tell a crate named `rg` from a binary
    # named `rg` listed under some other crate.
    private def interpret_cargo_listing(key : String, result : ProcessResult) : InstallationStatus
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

  # Flatpak applications.
  class FlatpakProbe < Probe
    def supports?(item : StepItem) : Bool
      item.item_type.flatpak?
    end

    def probe(item : StepItem, runner : ShellRunner) : InstallationStatus
      return InstallationStatus::Unknown.new(item.key, "flatpak is not on PATH") unless runner.command_exists?("flatpak")

      result = runner.run(Command.new(
        ["flatpak", "list", "--app", "--columns=application"], timeout: SLOW_PROBE_TIMEOUT))

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
  # Only presence is checked, not content: reading a root-owned repo file to
  # compare it would need privileges a probe must not take, and the step
  # itself re-verifies before writing.
  class RepositoryFileProbe < Probe
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
      InstallationStatus::InstalledByProbe.new(item.key)
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
  class ConfiguredProbeCommand < Probe
    def supports?(item : StepItem) : Bool
      !item.step.try(&.probe_command).nil?
    end

    def probe(item : StepItem, runner : ShellRunner) : InstallationStatus
      command = item.step.try(&.probe_command)
      return InstallationStatus::Unknown.new(item.key, "no probeCommand configured") unless command

      result = runner.run(Command.new(["/bin/bash", "-lc", command], timeout: 30.seconds))
      result.success? ? InstallationStatus::InstalledByProbe.new(item.key) : InstallationStatus::NotInstalled.new(item.key)
    end
  end
end
