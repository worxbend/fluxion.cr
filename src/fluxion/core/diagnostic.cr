module Fluxion
  # A single validation or lint finding, anchored to the config path that
  # produced it so the user can jump straight to the offending line.
  struct Diagnostic
    enum Severity
      Error
      Warning
      Info

      def label : String
        case self
        in .error?   then "error"
        in .warning? then "warning"
        in .info?    then "info"
        end
      end
    end

    getter severity : Severity

    # Dotted path into the config document, e.g. `jobs[1].steps[0].packages[2]`.
    getter path : String

    getter message : String

    # Optional remediation hint, e.g. `Did you mean 'dnf-packages'?`.
    getter hint : String?

    # Stable identifier for lint rules, e.g. `binary-without-checksum`. Nil for
    # plain validation errors, which are identified by their path and message.
    getter rule : String?

    def initialize(@severity : Severity, @path : String, @message : String, @hint : String? = nil, @rule : String? = nil)
    end

    def self.error(path : String, message : String, hint : String? = nil, rule : String? = nil) : self
      new(Severity::Error, path, message, hint, rule)
    end

    def self.warning(path : String, message : String, hint : String? = nil, rule : String? = nil) : self
      new(Severity::Warning, path, message, hint, rule)
    end

    def self.info(path : String, message : String, hint : String? = nil, rule : String? = nil) : self
      new(Severity::Info, path, message, hint, rule)
    end

    def error? : Bool
      @severity.error?
    end

    def warning? : Bool
      @severity.warning?
    end

    def to_s(io : IO) : Nil
      io << @severity.label << ' ' << @path << ": " << @message
      hint = @hint
      io << " (" << hint << ')' if hint
    end
  end

  # Accumulates diagnostics in the order they are found. Validation reports
  # every problem in one pass rather than aborting at the first, because a
  # profile with five typos should take one run to fix, not five.
  class DiagnosticCollector
    getter diagnostics : Array(Diagnostic)

    def initialize
      @diagnostics = [] of Diagnostic
    end

    def error(path : String, message : String, hint : String? = nil, rule : String? = nil) : Nil
      @diagnostics << Diagnostic.error(path, message, hint, rule)
    end

    def warning(path : String, message : String, hint : String? = nil, rule : String? = nil) : Nil
      @diagnostics << Diagnostic.warning(path, message, hint, rule)
    end

    def info(path : String, message : String, hint : String? = nil, rule : String? = nil) : Nil
      @diagnostics << Diagnostic.info(path, message, hint, rule)
    end

    def <<(diagnostic : Diagnostic) : Nil
      @diagnostics << diagnostic
    end

    def concat(others : Enumerable(Diagnostic)) : Nil
      @diagnostics.concat(others)
    end

    def errors : Array(Diagnostic)
      @diagnostics.select(&.error?)
    end

    def warnings : Array(Diagnostic)
      @diagnostics.select(&.warning?)
    end

    def errors? : Bool
      @diagnostics.any?(&.error?)
    end

    def empty? : Bool
      @diagnostics.empty?
    end

    # Raises with everything collected so far when any diagnostic is an error.
    # `strict` also fails on warnings, backing `validate --strict`.
    def raise_if_failed!(strict : Bool = false) : Nil
      return unless errors? || (strict && @diagnostics.any?(&.warning?))
      raise ValidationError.new(@diagnostics)
    end
  end
end
