module Fluxion::CLI
  # A command that dispatches to subcommands.
  #
  # Bare invocation prints its own subcommands rather than doing something:
  # `fluxion state` with no verb is a question, not an instruction.
  abstract class GroupCommand < Command
    def run(arguments : Array(String)) : ExitCode
      # Global flags may precede the verb, so the subcommand is the first
      # argument that is not a flag rather than simply the first argument.
      index = arguments.index { |argument| !argument.starts_with?('-') }
      verb = index.try { |position| arguments[position] }

      if verb.nil? || arguments.includes?("-h") || arguments.includes?("--help")
        @globals.color = false if arguments.includes?("--no-color")
        @globals.apply_color!
        print_subcommands
        return ExitCode::Success
      end

      command = subcommands.find { |candidate| candidate.name == verb }
      unless command
        raise Failure.invalid_input(
          "Unknown #{name} subcommand '#{verb}'. Try: #{subcommands.map(&.name).join(", ")}")
      end

      command.output = @output
      command.error_output = @error_output
      # The verb is removed and everything around it kept, so flags on either
      # side reach the subcommand's own parser.
      remaining = arguments.dup
      remaining.delete_at(index.not_nil!)
      command.run(remaining)
    end

    private def print_subcommands : Nil
      puts "#{Style.bold("fluxion #{name}")} — #{summary}"
      puts
      puts Style.bold("Subcommands:")
      width = subcommands.max_of(&.name.size)
      subcommands.each do |command|
        puts "  #{Style.cyan(command.name.ljust(width))}  #{command.summary}"
      end
    end
  end
end
