module Fluxion::CLI
  # `fluxion validate` — load the profile, map it, and report diagnostics.
  #
  # Separate from `lint` on purpose: this answers "would this run at all",
  # which is a yes/no question with an exit code scripts can branch on. Lint
  # answers "is this a good profile", which is advice.
  class ValidateCommand < Command
    def name : String
      "validate"
    end

    def summary : String
      "Validate a config file"
    end

    def usage : String
      "fluxion validate [-c FILE] [--strict] [--format text|json]"
    end

    @strict = false
    @format = Format::Text

    def register(parser : OptionParser) : Nil
      parser.on("--strict", "Fail when warnings are present") { @strict = true }
      format_option(parser, [Format::Text, Format::Json]) { |value| @format = value }
    end

    def run(arguments : Array(String)) : ExitCode
      parse(arguments)
      profile, diagnostics = load_with_diagnostics

      errors = diagnostics.count(&.error?)
      warnings = diagnostics.count(&.warning?)
      failed = errors > 0 || (@strict && warnings > 0)

      case @format
      when .json? then render_json(profile, diagnostics, failed)
      else             render_text(profile, diagnostics, failed)
      end

      return ExitCode::Success unless failed
      @error_output.puts Style.bold_red("Config validation failed")
      ExitCode::ConfigurationError
    end

    private def render_text(profile : Profile, diagnostics : Array(Diagnostic), failed : Bool) : Nil
      diagnostics.each { |diagnostic| puts format_diagnostic(diagnostic) }
      puts unless diagnostics.empty?

      jobs = profile.jobs.size
      steps = profile.steps.size
      shape = "profile #{Style.bold(profile.name)} with #{pluralize(jobs, "job")}, #{pluralize(steps, "step")}"

      if failed
        puts "#{Style.red(Symbols.failure)} Config has #{pluralize(diagnostics.size, "issue")}: #{shape}"
      else
        puts "#{Style.green(Symbols.success)} Config is valid: #{shape}"
      end
    end

    private def format_diagnostic(diagnostic : Diagnostic) : String
      label = case diagnostic.severity
              in .error?   then Style.red("error")
              in .warning? then Style.yellow("warning")
              in .info?    then Style.blue("info")
              end

      String.build do |io|
        io << label << ' ' << Style.dim(diagnostic.path) << ": " << diagnostic.message
        diagnostic.hint.try { |hint| io << '\n' << "        " << Style.dim(hint) }
      end
    end

    private def render_json(profile : Profile, diagnostics : Array(Diagnostic), failed : Bool) : Nil
      puts({
        "profileName" => profile.name,
        "jobCount"    => profile.jobs.size,
        "stepCount"   => profile.steps.size,
        # Reflects errors only. `--strict` changes the exit code, not whether
        # the profile is structurally valid.
        "valid"  => diagnostics.none?(&.error?),
        "failed" => failed,
        "issues" => diagnostics.map do |diagnostic|
          {
            "severity" => diagnostic.severity.label,
            "path"     => diagnostic.path,
            "message"  => diagnostic.message,
            "hint"     => diagnostic.hint,
          }
        end,
      }.to_json)
    end

    private def pluralize(count : Int32, noun : String) : String
      "#{count} #{noun}#{"s" if count != 1}"
    end
  end

  # `fluxion kinds` — list the plan kinds a manifest may use.
  #
  # Takes no config file: the answer is a property of the build, not of any
  # profile. Reading the same registry `validate` checks against is what stops
  # the documented list and the accepted list from drifting apart.
  class KindsCommand < Command
    def name : String
      "kinds"
    end

    def summary : String
      "List the plan kinds a WorkstationProfile can use"
    end

    def usage : String
      "fluxion kinds [--format text|json]"
    end

    @format = Format::Text

    def register(parser : OptionParser) : Nil
      format_option(parser, [Format::Text, Format::Json]) { |value| @format = value }
    end

    def run(arguments : Array(String)) : ExitCode
      parse(arguments)

      case @format
      when .json? then render_json
      else             render_text
      end

      ExitCode::Success
    end

    private def render_text : Nil
      width = Config::PlanKinds::ALL.max_of(&.id.size)

      puts "#{Style.bold("KIND".ljust(width))}  #{Style.bold("DESCRIPTION")}"
      puts Style.dim("-" * (width + 2 + 60))

      Config::PlanKinds::ALL.each do |kind|
        puts "#{Style.cyan(kind.id.ljust(width))}  #{kind.summary}"
        next if kind.package_actions.empty?
        puts "#{" " * width}  #{Style.dim("actions: #{kind.package_actions.join(", ")}")}"
      end

      puts
      puts Style.dim("Reference: docs/workstation-profile.md")
    end

    private def render_json : Nil
      puts({
        "kinds" => Config::PlanKinds::ALL.map do |kind|
          {
            "id"             => kind.id,
            "summary"        => kind.summary,
            "category"       => kind.category.config_name,
            "packageActions" => kind.package_actions.sort,
          }
        end,
      }.to_json)
    end
  end

  # `fluxion list` — show the steps a profile declares.
  class ListCommand < Command
    def name : String
      "list"
    end

    def summary : String
      "List the steps in a config file"
    end

    def usage : String
      "fluxion list [-c FILE] [--format text|json]"
    end

    @format = Format::Text

    def register(parser : OptionParser) : Nil
      format_option(parser, [Format::Text, Format::Json]) { |value| @format = value }
    end

    def run(arguments : Array(String)) : ExitCode
      parse(arguments)
      profile = load_profile

      case @format
      when .json? then render_json(profile)
      else             render_text(profile)
      end

      ExitCode::Success
    end

    private def render_text(profile : Profile) : Nil
      puts "Profile: #{Style.bold(profile.name)}  OS: #{Style.cyan(profile.target.to_s)}"
      puts

      rows = [] of {String, String, String, String}
      profile.source_setups.each do |setup|
        rows << {setup.name, "source setup", setup.items.size.to_s, setup.step.summary}
      end
      profile.jobs.each do |job|
        job.steps.each { |step| rows << {step.name, step.kind, step.items.size.to_s, step.summary} }
      end

      if rows.empty?
        puts Style.dim("(no steps declared)")
        return
      end

      name_width = Math.max(6, rows.max_of(&.[0].size))
      type_width = Math.max(4, rows.max_of(&.[1].size))

      puts Style.bold("#{"STEP".ljust(name_width)}  #{"TYPE".ljust(type_width)}  #{"ITEMS".rjust(5)}  DETAILS")
      puts Style.dim("-" * (name_width + type_width + 5 + 8 + 30))

      rows.each do |step_name, kind, count, details|
        puts "#{Style.cyan(step_name.ljust(name_width))}  " \
             "#{Style.dim(kind.ljust(type_width))}  " \
             "#{count.rjust(5)}  #{details}"
      end

      unless profile.skipped_plan_entries.empty?
        puts
        puts Style.yellow("Skipped entries:")
        profile.skipped_plan_entries.each do |entry|
          puts "  #{Style.dim(Symbols.skipped)} #{entry.name} #{Style.dim("(#{entry.kind}) — #{entry.reason}")}"
        end
      end
    end

    private def render_json(profile : Profile) : Nil
      puts({
        "profileName"  => profile.name,
        "target"       => profile.target.to_s,
        "sourceSetups" => profile.source_setups.map do |setup|
          {
            "name"        => setup.name,
            "type"        => "source-setup",
            "description" => setup.step.summary,
            "itemCount"   => setup.items.size,
          }
        end,
        "steps" => profile.steps.map do |step|
          {
            "name"        => step.name,
            "type"        => step.kind,
            "description" => step.summary,
            "itemCount"   => step.items.size,
          }
        end,
        "skippedEntries" => profile.skipped_plan_entries.map do |entry|
          {"name" => entry.name, "kind" => entry.kind, "reason" => entry.reason}
        end,
      }.to_json)
    end
  end
end
