module Fluxion::Executor
  # Waits out another process holding the package manager's lock, then runs
  # the command again.
  #
  # On a fresh Ubuntu install `unattended-upgrades` or a second terminal's
  # `apt-get` often holds `/var/lib/dpkg/lock-frontend` for minutes. apt does
  # not wait by default: it exits 100 with "Could not get lock", and a whole
  # package list failed item by item in the fallback, each with the same lock
  # error, although nothing was wrong with any of the packages. zypper, pacman
  # and snap refuse the same way. What such a failure means is "not yet", so
  # the command is run again after a pause that grows from `FIRST_PAUSE` to
  # `MAX_PAUSE`.
  #
  # Only commands Fluxion builds for a package manager are retried, and only
  # when their output carries that manager's own lock message: rerunning one
  # that failed for any other reason would repeat a real failure, and a
  # profile's own shell command may not be safe to run twice.
  #
  # The budget covers one episode of contention across the whole run, not one
  # command: when a batch gives up and falls back to one process per package,
  # the packages after it would otherwise each wait the full budget again. An
  # episode ends when a package manager command gets past the lock. Ctrl-C
  # ends the wait at once, and the command's last result stands.
  class LockWaitingRunner < ShellRunner
    BUDGET      = 15.minutes
    FIRST_PAUSE = 5.seconds
    MAX_PAUSE   = 30.seconds

    # How often a pause looks at the cancellation signal.
    POLL = 250.milliseconds

    # What each manager prints when another process holds its lock, matched
    # without regard to case. Keyed by the executable's basename.
    APT_LOCKED = ["could not get lock", "unable to acquire the dpkg frontend lock",
                  "unable to lock the administration directory", "unable to lock directory"]
    LOCK_MESSAGES = {
      "apt-get" => APT_LOCKED,
      "apt"     => APT_LOCKED,
      "dpkg"    => APT_LOCKED,
      "zypper"  => ["system management is locked"],
      "pacman"  => ["unable to lock database"],
      "paru"    => ["unable to lock database"],
      "yay"     => ["unable to lock database"],
      "dnf"     => ["failed to obtain the transaction lock", "failed to obtain lock"],
      "snap"    => ["change in progress"],
    }

    getter waited : Time::Span = Time::Span.zero

    # `pause` replaces the real sleep, for specs; it is told how long to wait.
    def initialize(@inner : ShellRunner,
                   @cancellation : CancellationSignal = CancellationSignal.never,
                   @budget : Time::Span = BUDGET,
                   @pause : (Time::Span -> Nil)? = nil)
    end

    # The lock messages of the package manager `argv` runs, or nil when it
    # runs something else. Looks past a `sudo` marker, normalised or not.
    def self.lock_messages(argv : Array(String)) : Array(String)?
      target(argv).try { |name| LOCK_MESSAGES[name]? }
    end

    # The basename of the executable `argv` runs, past a `sudo` marker.
    def self.target(argv : Array(String)) : String?
      rest = Sudo.invocation?(argv) ? argv[1..] : argv
      rest.skip_while { |word| word == "-n" || word == "--" }.first?.try { |path| File.basename(path) }
    end

    def run(command : Command, &sink : String ->) : ProcessResult
      result = @inner.run(command) { |line| sink.call(line) }
      messages = LockWaitingRunner.lock_messages(command.argv)
      return result unless messages

      pause = FIRST_PAUSE
      while locked?(command, result, messages)
        remaining = @budget - @waited
        if remaining <= Time::Span.zero || @cancellation.cancelled?
          sink.call("#{target(command)} is still locked by another process; giving up after waiting #{describe(@waited)}")
          return result
        end

        pause = {pause, remaining}.min
        sink.call("#{target(command)} is locked by another process; trying again in #{describe(pause)}")
        wait(pause)
        @waited += pause
        return result if @cancellation.cancelled?

        pause = {pause * 2, MAX_PAUSE}.min
        result = @inner.run(command) { |line| sink.call(line) }
      end

      # Past the lock, whatever the outcome: the next contention is a new
      # episode with the whole budget again.
      @waited = Time::Span.zero
      result
    end

    def command_exists?(name : String) : Bool
      @inner.command_exists?(name)
    end

    def resolve_command(name : String) : String?
      @inner.resolve_command(name)
    end

    private def locked?(command : Command, result : ProcessResult, messages : Array(String)) : Bool
      return false if command.success?(result.exit_code)
      output = "#{result.stdout}\n#{result.stderr}".downcase
      messages.any? { |message| output.includes?(message) }
    end

    private def wait(span : Time::Span) : Nil
      if pause = @pause
        return pause.call(span)
      end

      deadline = Time.instant + span
      until @cancellation.cancelled?
        left = deadline - Time.instant
        break if left <= Time::Span.zero
        sleep({left, POLL}.min)
      end
    end

    private def target(command : Command) : String
      LockWaitingRunner.target(command.argv) || "the package manager"
    end

    private def describe(span : Time::Span) : String
      seconds = span.total_seconds.round.to_i
      seconds < 60 ? "#{seconds}s" : "#{seconds // 60}m#{(seconds % 60).to_s.rjust(2, '0')}s"
    end
  end
end
