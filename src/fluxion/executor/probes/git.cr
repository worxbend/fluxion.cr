module Fluxion::Executor
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
end
