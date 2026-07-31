module Fluxion
  # Base class for every error Fluxion raises deliberately. The CLI maps these
  # to stable exit codes and prints them without a stack trace, so anything
  # that escapes as a plain `Exception` is a bug rather than a user error.
  class Error < Exception
  end

  # The profile could not be read, parsed, or mapped into the domain model.
  class ConfigError < Error
  end

  # The profile parsed but broke a rule that makes it unsafe or impossible to
  # execute. Carries every diagnostic so the CLI can print them all at once
  # instead of making the user fix one line per run.
  class ValidationError < Error
    getter diagnostics : Array(Diagnostic)

    def initialize(@diagnostics : Array(Diagnostic))
      super(build_message(@diagnostics))
    end

    private def build_message(diagnostics : Array(Diagnostic)) : String
      errors = diagnostics.count(&.error?)
      String.build do |io|
        io << errors << (errors == 1 ? " validation error" : " validation errors")
        diagnostics.each { |diagnostic| io << '\n' << "  " << diagnostic }
      end
    end
  end

  # Something outside Fluxion failed: a process, the filesystem, the network.
  class ExecutionError < Error
  end

  # A remote artifact did not match the checksum, signature, or fingerprint the
  # profile pinned it to. Always fatal for the step that requested it — Fluxion
  # never falls back to running unverified bytes.
  class TrustError < ExecutionError
  end

  # The host is missing something the profile needs.
  class HostError < Error
  end

  # Raised when the user cancels an interactive run.
  class CancelledError < Error
    def initialize(message = "cancelled")
      super(message)
    end
  end
end
