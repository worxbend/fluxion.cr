module Fluxion::Registry
  # Git operations against a registry mirror.
  #
  # Goes through `ShellRunner` rather than shelling out directly, so the
  # commands are observable in specs and get the same redaction and timeout
  # handling as every other process Fluxion starts.
  class Git
    CLONE_TIMEOUT = 5.minutes
    QUICK_TIMEOUT = 60.seconds

    def initialize(@runner : Executor::ShellRunner)
    end

    def available? : Bool
      @runner.command_exists?("git")
    end

    # Clones a registry, or fast-forwards an existing mirror.
    def sync(source : Source, &sink : String ->) : Nil
      require_git

      if source.cloned?
        pull(source, &sink)
      else
        clone(source, &sink)
      end
    end

    private def clone(source : Source, &sink : String ->) : Nil
      Dir.mkdir_p(File.dirname(source.mirror_path), 0o700)

      argv = ["git", "clone"]
      # A registry is read almost every time and written almost never, so the
      # default is a shallow clone. `--push` deepens it when history is needed.
      argv.concat(["--depth", "1"])
      source.ref.try { |ref| argv.concat(["--branch", ref]) }
      argv.concat(["--", source.url, source.mirror_path])

      run!(argv, "clone #{source.url}", CLONE_TIMEOUT, &sink)
    end

    private def pull(source : Source, &sink : String ->) : Nil
      # Fetch then hard-reset rather than merge: the mirror is a mirror, and a
      # merge conflict in a directory the user never edits would be a puzzle
      # with no useful answer.
      ref = source.ref || current_branch(source) || "HEAD"

      run!(git_in(source, ["fetch", "--depth", "1", "origin", ref]),
        "fetch #{source.name}", CLONE_TIMEOUT, &sink)

      run!(git_in(source, ["reset", "--hard", "FETCH_HEAD"]),
        "update #{source.name}", QUICK_TIMEOUT, &sink)
    end

    # The commit the mirror is currently at.
    def revision(source : Source) : String?
      return unless source.cloned?
      result = @runner.run(command(git_in(source, ["rev-parse", "--short", "HEAD"]), QUICK_TIMEOUT))
      return unless result.success?
      result.stdout.strip.presence
    end

    def current_branch(source : Source) : String?
      result = @runner.run(command(git_in(source, ["rev-parse", "--abbrev-ref", "HEAD"]), QUICK_TIMEOUT))
      return unless result.success?
      branch = result.stdout.strip
      branch.presence && branch != "HEAD" ? branch : nil
    end

    # Paths modified in the mirror. Normally empty — the mirror is not where
    # editing happens — so anything here is worth telling the user about.
    def modified(source : Source) : Array(String)
      return [] of String unless source.cloned?

      result = @runner.run(command(
        git_in(source, ["status", "--porcelain=v1", "--untracked-files=all"]),
        QUICK_TIMEOUT))
      return [] of String unless result.success?

      result.stdout.lines.compact_map do |line|
        stripped = line.strip
        next if stripped.empty?
        # `XY path`, where XY is the two-column status.
        stripped.split(/\s+/, 2)[1]?
      end
    end

    # Commits and pushes whatever is staged in the mirror.
    def publish(source : Source, message : String, &sink : String ->) : Nil
      require_git

      # A shallow clone cannot push, so history is deepened first — only when
      # someone actually publishes, which is rare.
      run(git_in(source, ["fetch", "--unshallow", "origin"]), CLONE_TIMEOUT, &sink)

      run!(git_in(source, ["add", "--all", "--", Manifest::PROFILE_DIRECTORY, Manifest::FILE_NAME]),
        "stage changes", QUICK_TIMEOUT, &sink)

      status = @runner.run(command(git_in(source, ["diff", "--cached", "--quiet"]), QUICK_TIMEOUT))
      if status.success?
        raise ExecutionError.new("Nothing to publish: the mirror matches the registry")
      end

      run!(git_in(source, ["commit", "-m", message]), "commit", QUICK_TIMEOUT, &sink)

      branch = source.ref || current_branch(source) || "HEAD"
      run!(git_in(source, ["push", "origin", "HEAD:#{branch}"]),
        "push to #{source.url}", CLONE_TIMEOUT, &sink)
    end

    private def git_in(source : Source, argv : Array(String)) : Array(String)
      ["git", "-C", source.mirror_path] + argv
    end

    private def command(argv : Array(String), timeout : Time::Span) : Executor::Command
      Executor::Command.new(argv,
        # Terminal prompting is disabled so a private registry with no
        # credentials configured fails immediately instead of hanging on a
        # username prompt nobody is watching.
        env: {"GIT_TERMINAL_PROMPT" => "0", "GIT_OPTIONAL_LOCKS" => "0"},
        timeout: timeout)
    end

    private def run(argv : Array(String), timeout : Time::Span, &sink : String ->) : ProcessResult
      @runner.run(command(argv, timeout), &sink)
    end

    private def run!(argv : Array(String), description : String, timeout : Time::Span, &sink : String ->) : Nil
      result = run(argv, timeout, &sink)
      return if result.success?

      detail = result.detail.presence || "git exited #{result.exit_code}"
      raise ExecutionError.new("Failed to #{description}: #{detail}")
    end

    private def require_git : Nil
      return if available?
      raise ExecutionError.new("git is not on PATH, and registries are git repositories")
    end
  end
end
