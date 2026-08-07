module Fluxion::Executor
  # How much a run is allowed to trust prior knowledge.
  enum RunMode
    # Run everything the profile declares, recording what succeeded.
    RecordOnly
    # Skip what state or a probe says is already there.
    SkipInstalled
    # Ignore state entirely and trust only live probes.
    LiveReprobe

    def self.from_options(skip_installed : Bool, reprobe : Bool) : self
      return LiveReprobe if reprobe
      skip_installed ? SkipInstalled : RecordOnly
    end

    def probes? : Bool
      !record_only?
    end

    def trusts_state? : Bool
      skip_installed?
    end
  end

  # Options for one run.
  struct RunOptions
    getter mode : RunMode

    # Emit what would happen without doing any of it.
    getter? dry_run : Bool

    # Probe and report, installing nothing.
    getter? probe_only : Bool

    # Approves items that declared `confirm`. Fluxion never prompts for these
    # interactively — a run that pauses for input is a run that hangs in CI.
    getter? approved : Bool

    # Restrict the run to these phases.
    getter only_phases : Array(String)

    # Skip every phase before this one.
    getter from_phase : String?

    getter profile_name : String

    def initialize(
      @mode : RunMode = RunMode::RecordOnly,
      @dry_run : Bool = false,
      @probe_only : Bool = false,
      @approved : Bool = false,
      @only_phases : Array(String) = [] of String,
      @from_phase : String? = nil,
      @profile_name : String = "default",
    )
    end

    # True when nothing may touch the host.
    def read_only? : Bool
      @dry_run || @probe_only
    end
  end

  # What a finished run amounted to.
  #
  # A class rather than a struct: it is threaded through phase and step execution
  # and mutated there, and a struct would be copied at each call so every
  # increment would be lost.
  class RunSummary
    property succeeded = 0
    property failed = 0
    property skipped = 0
    property dry_run = 0
    property paused = 0

    # Phases that failed, and phases blocked by a failed dependency.
    property failed_phases = [] of String
    property blocked_phases = [] of String

    # Where to resume from, when the run stopped early.
    property next_phase : String?

    # The exit code the checkpoint that stopped the run asked for.
    #
    # A profile may set `interrupt.exitCode`, and the parser range-checks it,
    # but the value used to stop here: `RunSummary` counted pauses and nothing
    # else, so the CLI always returned 75 and a wrapper script branching on a
    # custom code never fired. The first checkpoint wins, because it is the one
    # that ended the run.
    property paused_exit_code : Int32?

    def initialize
    end

    def record(result : StepResult) : Nil
      case result
      when StepResult::Success then @succeeded += 1
      when StepResult::Failure then @failed += 1
      when StepResult::Skipped then @skipped += 1
      when StepResult::DryRun  then @dry_run += 1
      when StepResult::Paused
        @paused += 1
        @paused_exit_code ||= result.exit_code
      end
    end

    def ok? : Bool
      @failed.zero? && @failed_phases.empty?
    end

    def to_s(io : IO) : Nil
      io << "ok=" << @succeeded << " failed=" << @failed << " skipped=" << @skipped
      io << " dry_run=" << @dry_run << " paused=" << @paused
    end
  end
end
