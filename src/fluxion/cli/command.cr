require "option_parser"

module Fluxion::CLI
  # Options every command understands.
  class GlobalOptions
    property config_path : String?
    property? no_tui : Bool = false
    property? verbose : Bool = false

    # Colour override. Nil leaves the automatic terminal detection alone.
    property color : Bool? = nil

    def resolved_config_path : String
      @config_path || Config::Loader.default_path
    end

    def explicit_config? : Bool
      !@config_path.nil?
    end

    # The TUI needs a real terminal. In CI, a pipe, or a build tool this is
    # false regardless of `--no-tui`, so a run never blocks on a UI nobody can
    # see.
    def use_tui? : Bool
      !@no_tui && STDOUT.tty? && STDIN.tty?
    end

    def register(parser : OptionParser) : Nil
      parser.on("-c FILE", "--config=FILE", "YAML profile path [default: ~/.config/fluxion/default.yaml]") do |value|
        @config_path = value
      end
      parser.on("--no-tui", "Use plain stdout instead of the terminal UI") { @no_tui = true }
      parser.on("-v", "--verbose", "More detailed output") { @verbose = true }
      parser.on("--color", "Force coloured output") { @color = true }
      parser.on("--no-color", "Disable coloured output") { @color = false }
    end

    def apply_color! : Nil
      Style.enabled = @color
    end
  end

  # How structured output should be rendered.
  enum Format
    Text
    Table
    Tree
    Json
    Mermaid
    Dot
    Markdown
    Html

    def self.from_config?(value : String?) : self?
      return unless value
      parse?(value.strip.downcase)
    end

    def config_name : String
      to_s.downcase
    end
  end

  # One subcommand.
  #
  # Each owns its own option parsing so `fluxion plan --help` describes plan
  # rather than a merged surface, and so adding a command touches one file.
  abstract class Command
    getter globals : GlobalOptions

    # Injectable so specs can assert on what a command renders without
    # spawning the binary, and so a future TUI can capture the same output.
    property output : IO
    property error_output : IO

    # Everything that reaches the outside world, for the same reason as above:
    # a command that builds its own `SystemShellRunner` cannot be handed a fake.
    property deps : Deps

    def initialize(@globals : GlobalOptions = GlobalOptions.new,
                   @output : IO = STDOUT,
                   @error_output : IO = STDERR,
                   @deps : Deps = Deps.new)
    end

    # Shorthands so renderers read the same as they would with Kernel#puts.
    protected def puts(*values) : Nil
      if values.empty?
        @output.puts
      else
        values.each { |value| @output.puts(value) }
      end
    end

    protected def print(value) : Nil
      @output.print(value)
    end

    abstract def name : String
    abstract def summary : String
    abstract def run(arguments : Array(String)) : ExitCode

    # Subcommands beneath this one, for `state`, `tools`, `import`, `report`.
    def subcommands : Array(Command)
      [] of Command
    end

    def usage : String
      "fluxion #{name} [options]"
    end

    # Command-specific flags. The base registers nothing.
    def register(parser : OptionParser) : Nil
    end

    # Parses `arguments`, returning the leftover positional ones.
    protected def parse(arguments : Array(String)) : Array(String)
      positional = [] of String
      parser = OptionParser.new do |options|
        options.banner = "Usage: #{usage}\n\n#{summary}\n"
        register(options)
        @globals.register(options)
        options.on("-h", "--help", "Print this help") do
          @output.puts options
          raise HelpRequested.new
        end
        options.unknown_args { |before, after| positional = before + after }
        options.invalid_option { |flag| raise Failure.invalid_input("Unknown option: '#{flag}'\n\n#{options}") }
        options.missing_option { |flag| raise Failure.invalid_input("Missing value for '#{flag}'") }
      end

      parser.parse(arguments.dup)
      @globals.apply_color!
      positional
    end

    # Loads the profile, turning validation failures into a configuration exit.
    protected def load_profile : Profile
      path = @globals.resolved_config_path
      Config::Loader.load(path, deps.host_facts)
    rescue error : ValidationError
      raise Failure.configuration(error.message || "Config validation failed")
    end

    # Loads without failing on diagnostics, for the commands that report them.
    protected def load_with_diagnostics : {Profile, Array(Diagnostic)}
      Config::Loader.load_with_diagnostics(@globals.resolved_config_path, deps.host_facts)
    end

    protected def format_option(parser : OptionParser, accepted : Array(Format), &block : Format ->) : Nil
      names = accepted.map(&.config_name)
      parser.on("--format=FORMAT", "Output format: #{names.join(", ")}") do |value|
        format = Format.from_config?(value)
        unless format && accepted.includes?(format)
          raise Failure.invalid_input("Unsupported format '#{value}'. Expected one of: #{names.join(", ")}")
        end
        block.call(format)
      end
    end
  end

  # Thrown when `--help` was handled, so the caller exits cleanly without the
  # command running.
  class HelpRequested < Exception
  end
end
