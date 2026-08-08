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

      case manager
      when .apt?
        return InstallationStatus::NotInstalled.new(item.key) unless result.success?
        status, _, version = result.stdout.strip.partition('\t')
        return InstallationStatus::NotInstalled.new(item.key) unless status == "install ok installed"
        InstallationStatus::InstalledByProbe.new(item.key, version.presence)
      when .flatpak?
        installed = result.stdout.lines.any? { |line| line.strip == item.key }
        installed ? InstallationStatus::InstalledByProbe.new(item.key) : InstallationStatus::NotInstalled.new(item.key)
      else
        interpret_query(item.key, result, manager)
      end
    end

    # rpm and pacman both use exit 1 for "not installed" and anything else for
    # a real failure, which is the difference between NotInstalled and Unknown.
    private def interpret_query(key : String, result : ProcessResult, manager : PackageManager) : InstallationStatus
      return InstallationStatus::InstalledByProbe.new(key, extract_version(result.stdout, manager)) if result.success?
      return InstallationStatus::NotInstalled.new(key) if result.exit_code == 1

      InstallationStatus::Unknown.new(key,
        "#{manager.query_argv(key).first} exited #{result.exit_code}")
    end

    private def extract_version(stdout : String, manager : PackageManager) : String?
      line = stdout.lines.first?.try(&.strip)
      return if line.nil? || line.empty?

      case manager
      when .pacman?, .paru?, .yay?
        # `pacman -Q git` prints "git 2.45.2".
        line.split(' ')[1]?
      else
        # `rpm -q git` prints "git-2.45.2-1.fc44.x86_64".
        _, _, remainder = line.partition('-')
        remainder.presence
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
      Path.posix(Host.home + path[1..]).normalize.to_s if path.starts_with?("~/")
      path.starts_with?("~/") ? Path.posix(Host.home, path[2..]).normalize.to_s : path
    end
  end

  # Git configuration keys, compared by value so drift is visible.
  class GitConfigProbe < Probe
    def supports?(item : StepItem) : Bool
      item.item_type.git_config?
    end

    def probe(item : StepItem, runner : ShellRunner) : InstallationStatus
      scope, _, key = item.key.partition(':')
      return InstallationStatus::Unknown.new(item.key, "malformed git-config item key") if key.empty?

      step = item.step.as?(GitConfigStep)
      desired = step.try(&.entries[key]?)

      result = runner.run(Command.new(["git", "config", "--#{scope}", "--get", key], timeout: PROBE_TIMEOUT))
      return InstallationStatus::NotInstalled.new(item.key) unless result.success?

      current = result.stdout.strip
      return InstallationStatus::NotInstalled.new(item.key) if current.empty?
      return InstallationStatus::InstalledByProbe.new(item.key, current) if desired.nil? || current == desired
      InstallationStatus::NotInstalled.new(item.key)
    end
  end

  # systemd units, checked against the state the profile asked for.
  class SystemdUnitProbe < Probe
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
      running = active.stdout.lines.first?.try(&.strip) == "active"

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
      user, _, group = item.key.rpartition(':')
      group = item.key if group.empty?
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
