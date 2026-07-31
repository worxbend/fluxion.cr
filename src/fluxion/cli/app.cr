module Fluxion::CLI
  # The `fluxion` entry point: picks a subcommand and maps whatever escapes it
  # to an exit code.
  class App
    getter globals : GlobalOptions
    getter output : IO
    getter error_output : IO

    def initialize(@globals : GlobalOptions = GlobalOptions.new,
                   @output : IO = STDOUT,
                   @error_output : IO = STDERR)
    end

    def commands : Array(Command)
      [
        ApplyCommand.new(@globals, @output, @error_output),
        DryRunCommand.new(@globals, @output, @error_output),
        PlanCommand.new(@globals, @output, @error_output),
        StatusCommand.new(@globals, @output, @error_output),
        DiffCommand.new(@globals, @output, @error_output),
        ExplainCommand.new(@globals, @output, @error_output),
        DoctorCommand.new(@globals, @output, @error_output),
        LintCommand.new(@globals, @output, @error_output),
        StateCommand.new(@globals, @output, @error_output),
        ReportCommand.new(@globals, @output, @error_output),
        ToolsCommand.new(@globals, @output, @error_output),
        GenerateCommand.new(@globals, @output, @error_output),
        SnapshotCommand.new(@globals, @output, @error_output),
        ImportCommand.new(@globals, @output, @error_output),
        ValidateCommand.new(@globals, @output, @error_output),
        ListCommand.new(@globals, @output, @error_output),
        GraphCommand.new(@globals, @output, @error_output),
        KindsCommand.new(@globals, @output, @error_output),
      ] of Command
    end

    def run(arguments : Array(String)) : ExitCode
      first = arguments.first?

      case first
      when nil
        print_usage(@output)
        return ExitCode::Success
      when "-h", "--help", "help"
        print_usage(@output)
        return ExitCode::Success
      when "-V", "--version", "version"
        @output.puts "fluxion #{VERSION}"
        return ExitCode::Success
      end

      command = commands.find { |candidate| candidate.name == first }
      unless command
        @error_output.puts "#{Style.red("Error:")} Unknown command '#{first}'"
        @error_output.puts
        print_usage(@error_output)
        return ExitCode::InvalidInput
      end

      command.run(arguments[1..])
    rescue HelpRequested
      ExitCode::Success
    rescue IO::Error
      # stdout closed early, which is what `fluxion kinds | head` looks like.
      # Reporting it would print an error the user cannot act on, to a pipe
      # that is already gone.
      ExitCode::Success
    rescue error : Exception
      report(error)
    end

    # Prints one line, never a stack trace: a profile with a typo is a normal
    # outcome, and burying the message under a backtrace helps nobody.
    private def report(error : Exception) : ExitCode
      message = error.message.presence || error.class.name
      @error_output.puts "#{Style.red("Error:")} #{Executor::Redaction.sanitize(message)}"

      if @globals.verbose?
        error.backtrace?.try { |backtrace| @error_output.puts Style.dim(backtrace.join('\n')) }
      end

      CLI.exit_code_for(error)
    end

    def print_usage(io : IO = @output) : Nil
      io.puts Style.bold("fluxion") + " — turn a fresh Linux machine into your machine"
      io.puts
      io.puts Style.bold("Usage:")
      io.puts "  fluxion <command> [options]"
      io.puts
      io.puts Style.bold("Commands:")

      width = commands.max_of(&.name.size)
      commands.each do |command|
        io.puts "  #{Style.cyan(command.name.ljust(width))}  #{command.summary}"
      end

      io.puts
      io.puts Style.bold("Global options:")
      io.puts "  -c, --config=FILE  YAML profile path [default: ~/.config/fluxion/default.yaml]"
      io.puts "      --no-tui       Use plain stdout instead of the terminal UI"
      io.puts "  -v, --verbose      More detailed output"
      io.puts "      --color        Force coloured output"
      io.puts "      --no-color     Disable coloured output"
      io.puts "  -h, --help         Print help for a command"
      io.puts "  -V, --version      Print the version"
      io.puts
      io.puts Style.dim("Run 'fluxion <command> --help' for command-specific options.")
    end
  end
end
