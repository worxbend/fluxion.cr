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

  # `fluxion state` — inspect and edit what previous runs recorded.
  class StateCommand < GroupCommand
    def name : String
      "state"
    end

    def summary : String
      "Inspect and edit the recorded state"
    end

    def subcommands : Array(Command)
      [
        StateShowCommand.new(@globals, @output, @error_output),
        StatePathCommand.new(@globals, @output, @error_output),
        StateResetCommand.new(@globals, @output, @error_output),
        StateForgetCommand.new(@globals, @output, @error_output),
      ] of Command
    end
  end

  # Shared plumbing for the state subcommands.
  abstract class StateSubcommand < Command
    @profile_name = "default"
    @format = Format::Text

    protected def store : State::Store
      State::Store.new
    end

    protected def profile_argument(positional : Array(String)) : String
      positional.first? || @profile_name
    end
  end

  class StateShowCommand < StateSubcommand
    def name : String
      "show"
    end

    def summary : String
      "Print everything recorded for a profile"
    end

    def usage : String
      "fluxion state show [PROFILE] [--format text|json]"
    end

    def register(parser : OptionParser) : Nil
      format_option(parser, [Format::Text, Format::Json]) { |value| @format = value }
    end

    def run(arguments : Array(String)) : ExitCode
      positional = parse(arguments)
      profile = profile_argument(positional)

      unless store.exists?(profile)
        if @format.json?
          puts({"profileName" => profile, "lastRunAt" => nil, "jobs" => [] of String, "items" => [] of String}.to_json)
        else
          puts Style.dim("No state recorded for profile: #{profile}")
        end
        return ExitCode::Success
      end

      document = store.load(profile)
      @format.json? ? render_json(document) : render_text(document)
      ExitCode::Success
    end

    private def render_text(document : State::Document) : Nil
      puts "Profile: #{Style.bold(document.profile_name)}  #{Style.dim("(last run: #{document.last_run_at})")}"
      document.next_job.try { |job| puts "#{Style.yellow("Next job:")} #{job}" }
      puts

      puts Style.bold("Jobs:")
      if document.jobs.empty?
        puts "  #{Style.dim("(none)")}"
      else
        width = document.jobs.max_of(&.job.size)
        document.jobs.each do |job|
          colour = job.completed? ? Style.green(job.status) : Style.red(job.status)
          puts "  #{Style.pad(job.job, width)}  #{colour}  #{Style.dim(job.completed_at.to_s)}"
        end
      end

      puts
      puts Style.bold("Items:")
      if document.items.empty?
        puts "  #{Style.dim("(none)")}"
      else
        step_width = document.items.max_of(&.step.size)
        key_width = Math.min(40, document.items.max_of(&.item_key.size))
        document.items.each do |item|
          puts "  #{Style.cyan(Style.pad(item.step, step_width))}  " \
               "#{Style.pad(Style.truncate(item.item_key, key_width), key_width)}  " \
               "#{Style.dim(item.item_type)}  #{Style.dim(item.version || "")}"
        end
      end
    end

    private def render_json(document : State::Document) : Nil
      puts document.to_json
    end
  end

  class StatePathCommand < StateSubcommand
    def name : String
      "path"
    end

    def summary : String
      "Print the state file path for a profile"
    end

    def usage : String
      "fluxion state path [PROFILE]"
    end

    def run(arguments : Array(String)) : ExitCode
      positional = parse(arguments)
      puts store.path(profile_argument(positional))
      ExitCode::Success
    end
  end

  class StateResetCommand < StateSubcommand
    def name : String
      "reset"
    end

    def summary : String
      "Delete everything recorded for a profile"
    end

    def usage : String
      "fluxion state reset [PROFILE] --force"
    end

    @force = false

    def register(parser : OptionParser) : Nil
      parser.on("--force", "Delete without confirming") { @force = true }
    end

    def run(arguments : Array(String)) : ExitCode
      positional = parse(arguments)
      profile = profile_argument(positional)

      unless store.exists?(profile)
        puts Style.dim("No state recorded for profile: #{profile}")
        return ExitCode::Success
      end

      # Requiring --force rather than prompting keeps the command usable from a
      # script, and stops a stray reset from being one keystroke away.
      unless @force
        raise Failure.invalid_input(
          "Refusing to delete state for '#{profile}' without --force")
      end

      store.reset(profile)
      puts "#{Style.green(Symbols.success)} State reset for profile: #{profile}"
      ExitCode::Success
    end
  end

  class StateForgetCommand < StateSubcommand
    def name : String
      "forget"
    end

    def summary : String
      "Remove one job or item from the recorded state"
    end

    def usage : String
      "fluxion state forget --profile NAME (--job NAME | --item KEY [--step NAME] [--type TYPE])"
    end

    @job : String?
    @item : String?
    @step : String?
    @type : String?

    def register(parser : OptionParser) : Nil
      parser.on("--profile=NAME", "Profile name [default: default]") { |value| @profile_name = value }
      parser.on("--job=NAME", "Job to forget") { |value| @job = value }
      parser.on("--item=KEY", "Item key to forget") { |value| @item = value }
      parser.on("--step=NAME", "Step qualifying --item") { |value| @step = value }
      parser.on("--type=TYPE", "Item type qualifying --item") { |value| @type = value }
    end

    def run(arguments : Array(String)) : ExitCode
      parse(arguments)

      job = @job.presence
      item = @item.presence
      raise Failure.invalid_input("Specify --job or --item") if job.nil? && item.nil?
      if (@step || @type) && item.nil?
        raise Failure.invalid_input("--step and --type only qualify --item")
      end

      unless store.exists?(@profile_name)
        puts Style.dim("No state recorded for profile: #{@profile_name}")
        return ExitCode::Success
      end

      type = @type.try do |raw|
        parsed = ItemType.from_config?(raw)
        raise Failure.invalid_input("Unknown item type: #{raw}") unless parsed
        parsed.json_name
      end

      document = store.load(@profile_name)

      if job
        unless document.forget_job(job)
          raise Failure.invalid_input("No recorded job named '#{job}'")
        end
        store.save(document)
        puts "#{Style.green(Symbols.success)} Forgot job '#{job}'"
        return ExitCode::Success
      end

      key = item.not_nil!
      matches = document.items.count do |record|
        record.item_key == key &&
          (@step.nil? || record.step == @step) &&
          (type.nil? || record.item_type == type)
      end

      raise Failure.invalid_input("No recorded item with key '#{key}'") if matches.zero?
      if matches > 1
        # Deleting several entries because one key was ambiguous would silently
        # forget more than the user asked for.
        raise Failure.invalid_input(
          "Item key '#{key}' matches #{matches} entries; qualify it with --step and --type")
      end

      document.forget_item(key, @step, type)
      store.save(document)
      puts "#{Style.green(Symbols.success)} Forgot item '#{key}'"
      ExitCode::Success
    end
  end

  # `fluxion report` — render what the last run recorded.
  class ReportCommand < Command
    def name : String
      "report"
    end

    def summary : String
      "Render a report from the recorded state"
    end

    def usage : String
      "fluxion report [--profile NAME] [--format markdown|html|json]"
    end

    @profile_name = "default"
    @format = Format::Markdown

    def register(parser : OptionParser) : Nil
      parser.on("--profile=NAME", "Profile name [default: default]") { |value| @profile_name = value }
      format_option(parser, [Format::Markdown, Format::Html, Format::Json]) { |value| @format = value }
    end

    def run(arguments : Array(String)) : ExitCode
      parse(arguments)

      unless store.exists?(@profile_name)
        raise Failure.configuration("No state recorded for profile: #{@profile_name}")
      end

      document = store.load(@profile_name)
      case @format
      when .html? then render_html(document)
      when .json? then puts document.to_json
      else             render_markdown(document)
      end

      ExitCode::Success
    end

    private def store : State::Store
      State::Store.new
    end

    private def render_markdown(document : State::Document) : Nil
      puts "# Fluxion run report"
      puts
      puts "- Profile: `#{document.profile_name}`"
      puts "- Last run: `#{document.last_run_at}`"
      puts "- Fluxion version: `#{document.fluxion_version}`"
      document.next_job.try { |job| puts "- Next job: `#{job}`" }
      puts
      puts "## Jobs"
      puts
      if document.jobs.empty?
        puts "_No jobs recorded._"
      else
        puts "| Job | Status | Completed |"
        puts "| --- | --- | --- |"
        document.jobs.each { |job| puts "| #{job.job} | #{job.status} | #{job.completed_at} |" }
      end
      puts
      puts "## Items"
      puts
      if document.items.empty?
        puts "_No items recorded._"
      else
        puts "| Step | Item | Type | Version | Completed |"
        puts "| --- | --- | --- | --- | --- |"
        document.items.each do |item|
          puts "| #{escape(item.step)} | #{escape(item.item_key)} | #{item.item_type} | " \
               "#{escape(item.version || "")} | #{item.completed_at} |"
        end
      end
    end

    # A pipe would break the table, and a newline would break the row.
    private def escape(text : String) : String
      text.gsub('|', "\\|").gsub('\n', ' ')
    end

    private def render_html(document : State::Document) : Nil
      puts "<!doctype html>"
      puts %(<html><head><meta charset="utf-8"><title>Fluxion run report</title></head><body>)
      puts "<h1>Fluxion run report</h1>"
      puts "<p><strong>Profile:</strong> #{html_escape(document.profile_name)}</p>"
      puts "<p><strong>Last run:</strong> #{document.last_run_at}</p>"
      puts "<h2>Jobs</h2><table><tr><th>Job</th><th>Status</th><th>Completed</th></tr>"
      document.jobs.each do |job|
        puts "<tr><td>#{html_escape(job.job)}</td><td>#{job.status}</td><td>#{job.completed_at}</td></tr>"
      end
      puts "</table>"
      puts "<h2>Items</h2><table><tr><th>Step</th><th>Item</th><th>Type</th><th>Version</th></tr>"
      document.items.each do |item|
        puts "<tr><td>#{html_escape(item.step)}</td><td>#{html_escape(item.item_key)}</td>" \
             "<td>#{item.item_type}</td><td>#{html_escape(item.version || "")}</td></tr>"
      end
      puts "</table></body></html>"
    end

    private def html_escape(text : String) : String
      text.gsub('&', "&amp;").gsub('<', "&lt;").gsub('>', "&gt;")
    end
  end

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
        ToolsListCommand.new(@globals, @output, @error_output),
        ToolsInstallCommand.new(@globals, @output, @error_output),
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
      broker = Executor::ToolBroker.new(Executor::SystemShellRunner.new)
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

      broker = Executor::ToolBroker.new(Executor::SystemShellRunner.new)
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
