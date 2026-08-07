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

      # `next_plan_entry` used to sit here, always passed nil and never read —
      # a third word for "phase" alongside `phase` and `step`. Where to resume
      # is `RunSummary#next_phase`, decided by the orchestrator, which is the
      # only thing that knows what comes next. The `nextPlanEntry` key in
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

    # A prior run recorded this as successfully installed.
    struct InstalledFromState < InstallationStatus
      getter item : String
      getter installed_at : Time
      getter version : String?

      def initialize(@item : String, @installed_at : Time, @version : String? = nil)
      end
    end

    # A live probe confirmed it is present right now.
    struct InstalledByProbe < InstallationStatus
      getter item : String
      getter detected_version : String?

      def initialize(@item : String, @detected_version : String? = nil)
      end
    end

    # Neither state nor probe can confirm it. Treated as absent.
    struct NotInstalled < InstallationStatus
      getter item : String

      def initialize(@item : String)
      end
    end

    # The probe command itself failed. Treated conservatively as absent, but
    # reported differently so the user knows the answer is unreliable.
    struct Unknown < InstallationStatus
      getter item : String
      getter reason : String

      def initialize(@item : String, @reason : String)
      end
    end

    def installed? : Bool
      is_a?(InstalledFromState) || is_a?(InstalledByProbe)
    end

    def to_s(io : IO) : Nil
      case status = self
      when InstalledFromState
        io << "installed (state"
        status.version.try { |value| io << ": " << value }
        io << ')'
      when InstalledByProbe
        io << "installed (probe"
        status.detected_version.try { |value| io << ": " << value }
        io << ')'
      when NotInstalled then io << "not installed"
      when Unknown      then io << "unknown: " << status.reason
      end
    end
  end

  # Deliberately absent: a `SkipDecision` variant type pairing an item key with
  # the `InstallationStatus` that justified skipping it.
  #
  # It was declared and documented here but never constructed anywhere in `src`
  # or `spec`, while `Orchestrator#skip_decision` answered the same question
  # with a plain nilable `InstallationStatus` — which is all the caller needs,
  # since it already knows the item. Reintroducing the type means finding a
  # second caller first.
end
