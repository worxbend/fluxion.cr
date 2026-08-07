module Fluxion::CLI
  # `fluxion tools` — the external tools Fluxion delegates to.
  class ToolsCommand < GroupCommand
    def name : String
      "tools"
    end

    def summary : String
      "Inspect and install the delegated external tools"
    end

    def subcommands : Array(Command)
      [
        ToolsListCommand.new(@globals, @output, @error_output, @deps),
        ToolsInstallCommand.new(@globals, @output, @error_output, @deps),
      ] of Command
    end
  end

  class ToolsListCommand < Command
    def name : String
      "list"
    end

    def summary : String
      "Show each tool, its pinned version, and where it would come from"
    end

    def usage : String
      "fluxion tools list [--format text|json]"
    end

    @format = Format::Text

    def register(parser : OptionParser) : Nil
      format_option(parser, [Format::Text, Format::Json]) { |value| @format = value }
    end

    def run(arguments : Array(String)) : ExitCode
      parse(arguments)
      broker = deps.tool_broker
      resolutions = Executor::KnownTools.all.map { |spec| broker.locate(spec) }

      @format.json? ? render_json(resolutions) : render_text(resolutions)
      ExitCode::Success
    end

    private def render_text(resolutions : Array(Executor::ToolBroker::Resolution)) : Nil
      puts "Platform: #{Style.cyan("linux/#{Host.architecture || "unknown"}")}"
      puts

      width = resolutions.max_of(&.spec.name.size)
      resolutions.each do |resolution|
        source = case resolution.source
                 in .path?     then Style.green("on PATH: #{resolution.path}")
                 in .cache?    then Style.cyan("cached: #{resolution.path}")
                 in .download? then Style.dim("would download #{resolution.path}")
                 end
        puts "#{Style.cyan(Style.pad(resolution.spec.name, width))}  " \
             "#{Style.dim(resolution.spec.version)}  #{source}"
      end

      puts
      puts Style.dim("A tool already on PATH is used as-is; Fluxion never replaces it.")
    end

    private def render_json(resolutions : Array(Executor::ToolBroker::Resolution)) : Nil
      puts({
        "platform" => "linux/#{Host.architecture || "unknown"}",
        "tools"    => resolutions.map do |resolution|
          {
            "tool"       => resolution.spec.name,
            "repository" => resolution.spec.repository,
            "version"    => resolution.spec.version,
            "executable" => resolution.spec.executable,
            "source"     => resolution.source.to_s.downcase,
            "path"       => resolution.path,
          }
        end,
      }.to_json)
    end
  end

  class ToolsInstallCommand < Command
    def name : String
      "install"
    end

    def summary : String
      "Download and verify a tool into Fluxion's cache"
    end

    def usage : String
      "fluxion tools install <tool>"
    end

    def run(arguments : Array(String)) : ExitCode
      positional = parse(arguments)
      selector = positional.first?
      known = Executor::KnownTools.all

      unless selector
        raise Failure.invalid_input("Specify a tool. Known tools: #{known.map(&.name).join(", ")}")
      end

      spec = known.find { |candidate| candidate.name.compare(selector, case_insensitive: true).zero? }
      unless spec
        raise Failure.invalid_input(
          "Unknown tool '#{selector}'. Known tools: #{known.map(&.name).join(", ")}")
      end

      broker = deps.tool_broker
      resolution = broker.locate(spec)

      # A tool the user manages themselves is theirs; Fluxion uses it and
      # installs nothing.
      if resolution.source.path?
        puts "#{Style.green(Symbols.success)} #{spec.name} is already on PATH at #{resolution.path}"
        return ExitCode::Success
      end

      path = broker.install(spec)
      puts "#{Style.green(Symbols.success)} #{spec.name} #{spec.version} installed at #{path}"
      ExitCode::Success
    end
  end
end
