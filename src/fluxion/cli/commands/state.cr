module Fluxion::CLI
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
        StateShowCommand.new(@globals, @output, @error_output, @deps),
        StatePathCommand.new(@globals, @output, @error_output, @deps),
        StateResetCommand.new(@globals, @output, @error_output, @deps),
        StateForgetCommand.new(@globals, @output, @error_output, @deps),
      ] of Command
    end
  end

  # Shared plumbing for the state subcommands.
  abstract class StateSubcommand < Command
    @profile_name = "default"
    @format = Format::Text

    protected def store : State::Store
      deps.store
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
          puts({"profileName" => profile, "lastRunAt" => nil, "phases" => [] of String, "items" => [] of String}.to_json)
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
      document.next_phase.try { |phase| puts "#{Style.yellow("Next phase:")} #{phase}" }
      puts

      puts Style.bold("Phases:")
      if document.phases.empty?
        puts "  #{Style.dim("(none)")}"
      else
        width = document.phases.max_of(&.phase.size)
        document.phases.each do |phase|
          colour = phase.completed? ? Style.green(phase.status) : Style.red(phase.status)
          puts "  #{Style.pad(phase.phase, width)}  #{colour}  #{Style.dim(phase.completed_at.to_s)}"
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
      "Remove one phase or item from the recorded state"
    end

    def usage : String
      "fluxion state forget --profile NAME (--phase NAME | --item KEY [--step NAME] [--type TYPE])"
    end

    @phase : String?
    @item : String?
    @step : String?
    @type : String?

    def register(parser : OptionParser) : Nil
      parser.on("--profile=NAME", "Profile name [default: default]") { |value| @profile_name = value }
      parser.on("--phase=NAME", "Phase to forget") { |value| @phase = value }
      parser.on("--item=KEY", "Item key to forget") { |value| @item = value }
      parser.on("--step=NAME", "Step qualifying --item") { |value| @step = value }
      parser.on("--type=TYPE", "Item type qualifying --item") { |value| @type = value }
    end

    # `forget` is two commands wearing one name — forgetting a phase and
    # forgetting an item share only their argument validation — so `run` does
    # the validation and hands off.
    def run(arguments : Array(String)) : ExitCode
      parse(arguments)

      phase = @phase.presence
      item = @item.presence
      raise Failure.invalid_input("Specify --phase or --item") if phase.nil? && item.nil?
      if (@step || @type) && item.nil?
        raise Failure.invalid_input("--step and --type only qualify --item")
      end

      unless store.exists?(@profile_name)
        puts Style.dim("No state recorded for profile: #{@profile_name}")
        return ExitCode::Success
      end

      document = store.load(@profile_name)
      phase ? forget_phase(document, phase) : forget_item(document, item.not_nil!)
    end

    private def forget_phase(document : State::Document, phase : String) : ExitCode
      unless document.forget_phase(phase)
        raise Failure.invalid_input("No recorded phase named '#{phase}'")
      end

      store.save(document)
      puts "#{Style.green(Symbols.success)} Forgot phase '#{phase}'"
      ExitCode::Success
    end

    private def forget_item(document : State::Document, key : String) : ExitCode
      type = requested_type
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

    private def requested_type : String?
      @type.try do |raw|
        parsed = ItemType.from_config?(raw)
        raise Failure.invalid_input("Unknown item type: #{raw}") unless parsed
        parsed.json_name
      end
    end
  end
end
