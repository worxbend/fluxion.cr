module Fluxion::CLI
  # Exit codes are part of Fluxion's interface: scripts branch on them, and CI
  # decides whether a bootstrap step passed. They are therefore fixed, and
  # distinguish *why* something failed rather than only that it did.
  enum ExitCode
    Success = 0

    # An unexpected failure. Anything landing here is a bug rather than a
    # situation Fluxion knows how to describe.
    GeneralFailure = 1

    # Bad arguments, or a selector that matches nothing.
    InvalidInput = 2

    # The profile could not be loaded or did not validate.
    ConfigurationError = 3

    # A local filesystem or stream failure.
    IoError = 4

    # Something outside Fluxion failed: a package manager, a download, a
    # required command that is missing.
    ExternalDependencyError = 5

    # Stopped at an explicit checkpoint. Not a failure — the run did exactly
    # what the profile asked — so it is distinct from every error code, and a
    # profile may choose its own value here.
    Paused = 75

    # Stopped at a safe boundary after the user interrupted. Follows the shell
    # convention of 128 + SIGINT.
    Cancelled = 130
  end

  # Raised to end a command with a specific code and message.
  #
  # Carrying the code with the message means each command decides how its own
  # failures should be classified, rather than a single mapping at the top
  # having to guess from an exception type.
  class Failure < Error
    getter exit_code : ExitCode

    def initialize(@exit_code : ExitCode, message : String)
      super(message)
    end

    def self.invalid_input(message : String) : self
      new(ExitCode::InvalidInput, message)
    end

    def self.configuration(message : String) : self
      new(ExitCode::ConfigurationError, message)
    end

    def self.io(message : String) : self
      new(ExitCode::IoError, message)
    end

    def self.external(message : String) : self
      new(ExitCode::ExternalDependencyError, message)
    end
  end

  # Maps an escaped exception to the code that best describes it.
  def self.exit_code_for(error : Exception) : ExitCode
    case error
    when Failure         then error.exit_code
    when ValidationError then ExitCode::ConfigurationError
    when ConfigError     then ExitCode::ConfigurationError
    when CancelledError  then ExitCode::Cancelled
    when TrustError      then ExitCode::ExternalDependencyError
    when ExecutionError  then ExitCode::ExternalDependencyError
    when HostError       then ExitCode::ExternalDependencyError
    when File::Error, IO::Error
      ExitCode::IoError
    when ArgumentError
      ExitCode::InvalidInput
    else
      ExitCode::GeneralFailure
    end
  end
end
