module Fluxion
  # What a finished process reported.
  struct ProcessResult
    getter exit_code : Int32
    getter stdout : String
    getter stderr : String
    getter elapsed : Time::Span

    def initialize(@exit_code : Int32, @stdout : String = "", @stderr : String = "", @elapsed : Time::Span = Time::Span.zero)
    end

    def success? : Bool
      @exit_code == 0
    end

    # stdout and stderr are merged by the process launcher, so `stderr` is
    # normally empty and this is effectively stdout. It stays a single accessor
    # so callers do not have to know that.
    def detail : String
      stderr = @stderr.strip
      return stderr unless stderr.empty?
      @stdout.strip
    end
  end

  # The outcome of one item.
  #
  # Modelled as a closed set of variants rather than a status code plus
  # optional fields, because "succeeded" and "paused for a logout" carry
  # genuinely different payloads and the renderers switch on all five.
  abstract struct StepResult
    abstract def item : String

    struct Success < StepResult
      getter item : String
      getter elapsed : Time::Span

      # Version the executor observed after installing, when it could tell.
      getter detected_version : String?

      # Digest of what was actually installed, recorded for provenance.
      getter checksum : String?

      def initialize(@item : String, @elapsed : Time::Span = Time::Span.zero, @detected_version : String? = nil, @checksum : String? = nil)
      end
    end

    struct Failure < StepResult
      getter item : String
      getter error_message : String
      getter exit_code : Int32
      getter elapsed : Time::Span

      def initialize(@item : String, @error_message : String, @exit_code : Int32 = 1, @elapsed : Time::Span = Time::Span.zero)
      end
    end

    # The item did not need to run. Never a failure: skipping is the whole
    # point of `--skip-already-installed`.
    struct Skipped < StepResult
      getter item : String
      getter reason : String

      def initialize(@item : String, @reason : String)
      end
    end

    struct DryRun < StepResult
      getter item : String
      getter would_execute : Array(String)

      def initialize(@item : String, @would_execute : Array(String))
      end
    end

    # An explicit checkpoint: state is written, a resume command is printed,
    # and the run stops cleanly with the configured exit code.
    struct Paused < StepResult
      getter item : String
      getter message : String
      getter exit_code : Int32

      # Where to resume is `RunSummary#next_phase`, decided by the orchestrator
      # — the only thing that knows what comes next. The `nextPlanEntry` key in
      # `State::Store` is unrelated: it is the legacy Java spelling, kept
      # because those state files are read directly.
      def initialize(@item : String, @message : String, @exit_code : Int32 = 75)
      end
    end

    def failure? : Bool
      is_a?(Failure)
    end

    def success? : Bool
      is_a?(Success)
    end
  end

  # What a probe concluded about an item.
  #
  # `Unknown` is distinct from `NotInstalled` on purpose: the probe itself
  # failing is not evidence of absence, and the difference shows up in
  # `status --failed` and in whether `plan` says "would run" or
  # "would run (probe unknown)".
  abstract struct InstallationStatus
    abstract def item : String

    # How this status reads in `status`, in `plan`, and as a skipped item's
    # reason.
    #
    # Answered by each variant rather than by a `case` over the hierarchy,
    # which Crystal cannot check for exhaustiveness — a fifth variant whose arm
    # nobody added would write nothing at all, and render as an empty string
    # with no compile error to say so.
    abstract def to_s(io : IO) : Nil

    # A prior run recorded this as successfully installed.
    struct InstalledFromState < InstallationStatus
      getter item : String
      getter installed_at : Time
      getter version : String?

      def initialize(@item : String, @installed_at : Time, @version : String? = nil)
      end

      def to_s(io : IO) : Nil
        io << "installed (state"
        @version.try { |value| io << ": " << value }
        io << ')'
      end
    end

    # A live probe confirmed it is present right now.
    struct InstalledByProbe < InstallationStatus
      getter item : String
      getter detected_version : String?

      def initialize(@item : String, @detected_version : String? = nil)
      end

      def to_s(io : IO) : Nil
        io << "installed (probe"
        @detected_version.try { |value| io << ": " << value }
        io << ')'
      end
    end

    # Neither state nor probe can confirm it. Treated as absent.
    struct NotInstalled < InstallationStatus
      getter item : String

      def initialize(@item : String)
      end

      def to_s(io : IO) : Nil
        io << "not installed"
      end
    end

    # The probe command itself failed. Treated conservatively as absent, but
    # reported differently so the user knows the answer is unreliable.
    struct Unknown < InstallationStatus
      getter item : String
      getter reason : String

      def initialize(@item : String, @reason : String)
      end

      def to_s(io : IO) : Nil
        io << "unknown: " << @reason
      end
    end

    def installed? : Bool
      is_a?(InstalledFromState) || is_a?(InstalledByProbe)
    end
  end
end
