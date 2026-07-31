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
      getter next_plan_entry : String?
      getter exit_code : Int32

      def initialize(@item : String, @message : String, @next_plan_entry : String? = nil, @exit_code : Int32 = 75)
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

  # Whether an item should run, and if not, why.
  abstract struct SkipDecision
    abstract def item_key : String

    struct Skip < SkipDecision
      getter item_key : String
      getter reason : InstallationStatus

      def initialize(@item_key : String, @reason : InstallationStatus)
      end
    end

    struct Run < SkipDecision
      getter item_key : String

      def initialize(@item_key : String)
      end
    end

    def skip? : Bool
      is_a?(Skip)
    end
  end
end
