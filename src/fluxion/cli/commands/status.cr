module Fluxion::CLI
  # Compares what a profile declares against what the host and state say.
  #
  # `status`, `diff`, and `explain` are three views of this one computation, so
  # they can never disagree about whether something is installed.
  class StatusReport
    enum Classification
      # Declared, and present.
      Installed
      # Declared, and absent.
      Missing
      # Recorded by a previous run but no longer declared.
      StateOnly
      # The probe could not answer. Distinct from Missing on purpose: absence
      # of evidence is not evidence of absence, and reinstalling on that basis
      # would be wrong.
      Unknown
      # State and the live probe disagree about the version.
      VersionDrift

      def label : String
        case self
        in .installed?     then "installed"
        in .missing?       then "missing"
        in .state_only?    then "state-only"
        in .unknown?       then "unknown"
        in .version_drift? then "version-drift"
        end
      end

      def title : String
        case self
        in .installed?     then "Already installed"
        in .missing?       then "Would install"
        in .state_only?    then "Only in state"
        in .unknown?       then "Needs review"
        in .version_drift? then "Version drift"
        end
      end

      # Whether this classification represents work still to do.
      def change? : Bool
        !installed?
      end
    end

    record Entry,
      step : String,
      key : String,
      display : String,
      type : String,
      classification : Classification,
      detail : String,
      state_version : String?,
      live_version : String?

    getter profile : Profile
    getter entries : Array(Entry)

    def initialize(@profile : Profile, @entries : Array(Entry))
    end

    def self.build(profile : Profile, runner : Executor::ShellRunner,
                   probes : Executor::ProbeRegistry, store : State::Store,
                   profile_name : String) : self
      document = begin
        store.load(profile_name)
      rescue ExecutionError
        State::Document.new(profile_name)
      end

      registry = Executor::ExecutorRegistry.default

      # Gathered first so the whole sweep can be probed at once. Declaration
      # order is preserved through both the sweep and the zip below, so the
      # report reads in the order the profile is written.
      items = [] of StepItem
      profile.steps.each do |step|
        executor = registry.for(step)
        next unless executor
        executor.items(step).each { |item| items << item }
      end

      statuses = Executor::ProbeSweep.probe_all(items, probes, runner)

      entries = [] of Entry
      seen = Set(String).new
      items.each_with_index do |item, index|
        seen << identity(item.step_name, item.key, item.item_type.json_name)
        entries << classify(item, statuses[index], document)
      end

      # Anything state remembers that the profile no longer declares. Worth
      # surfacing: it is usually a package someone removed from the profile but
      # not from the machine.
      document.items.each do |record|
        next if seen.includes?(identity(record.step, record.item_key, record.item_type))
        entries << Entry.new(record.step, record.item_key, record.item_key, record.item_type,
          Classification::StateOnly, "recorded #{record.completed_at.to_s("%Y-%m-%d")} but no longer declared",
          record.version, nil)
      end

      new(profile, entries)
    end

    private def self.identity(step : String, key : String, type : String) : String
      # A NUL separator, because a step name may contain a space or a
      # slash but never this.
      "#{step}\u0000#{key}\u0000#{type}"
    end

    private def self.classify(item : StepItem, status : InstallationStatus,
                              document : State::Document) : Entry
      recorded = document.find(item.step_name, item.key, item.item_type.json_name)

      classification, detail, live = case status
                                     when InstallationStatus::InstalledByProbe
                                       {Classification::Installed, status.to_s, status.detected_version}
                                     when InstallationStatus::InstalledFromState
                                       {Classification::Installed, status.to_s, nil}
                                     when InstallationStatus::Unknown
                                       {Classification::Unknown, status.reason, nil}
                                     else
                                       {Classification::Missing, "not installed", nil}
                                     end

      # A recorded version that no longer matches the live one is drift: the
      # thing is installed, but not the thing state believes.
      if classification.installed? && recorded && live && recorded.version && recorded.version != live
        classification = Classification::VersionDrift
        detail = "state has #{recorded.version}, host has #{live}"
      end

      Entry.new(item.step_name, item.key, item.display_name, item.item_type.json_name,
        classification, detail, recorded.try(&.version), live)
    end

    def count(classification : Classification) : Int32
      @entries.count(&.classification.== classification)
    end

    def changes : Array(Entry)
      @entries.select(&.classification.change?)
    end

    def summary : Hash(String, Int32)
      {
        "total"        => @entries.size,
        "installed"    => count(Classification::Installed),
        "missing"      => count(Classification::Missing),
        "stateOnly"    => count(Classification::StateOnly),
        "unknown"      => count(Classification::Unknown),
        "versionDrift" => count(Classification::VersionDrift),
      }
    end
  end

  # Commands that report on the host without changing it.
  abstract class ReportingCommand < Command
    @format = Format::Text
    @profile_name = "default"

    def register(parser : OptionParser) : Nil
      parser.on("--profile=NAME", "State profile name [default: default]") { |value| @profile_name = value }
      format_option(parser, [Format::Text, Format::Json]) { |value| @format = value }
    end

    protected def build_report : StatusReport
      profile = load_profile
      StatusReport.build(profile, deps.runner,
        Executor::ProbeRegistry.default, deps.store, @profile_name)
    end

    protected def colour_for(classification : StatusReport::Classification, text : String) : String
      case classification
      in .installed?     then Style.green(text)
      in .missing?       then Style.yellow(text)
      in .state_only?    then Style.dim(text)
      in .unknown?       then Style.magenta(text)
      in .version_drift? then Style.cyan(text)
      end
    end

    protected def symbol_for(classification : StatusReport::Classification) : String
      case classification
      in .installed?     then Symbols.success
      in .missing?       then Symbols.pending
      in .state_only?    then Symbols.skipped
      in .unknown?       then Symbols.warning
      in .version_drift? then Symbols.arrow
      end
    end

    protected def entry_json(entry : StatusReport::Entry)
      {
        "step"         => entry.step,
        "key"          => entry.key,
        "displayName"  => entry.display,
        "type"         => entry.type,
        "status"       => entry.classification.label,
        "detail"       => entry.detail,
        "stateVersion" => entry.state_version,
        "liveVersion"  => entry.live_version,
      }
    end
  end

  # `fluxion status` — live status for every configured item.
  class StatusCommand < ReportingCommand
    def name : String
      "status"
    end

    def summary : String
      "Show installation status for every item in a profile"
    end

    def usage : String
      "fluxion status [-c FILE] [--missing|--failed|--summary] [--format text|json]"
    end

    @summary_only = false
    @filter : StatusReport::Classification?
    @failed = false

    def register(parser : OptionParser) : Nil
      super
      parser.on("--summary", "Print only the aggregate counts") { @summary_only = true }
      parser.on("--missing", "Show only configured items that are missing") do
        @filter = StatusReport::Classification::Missing
      end
      parser.on("--state-only", "Show only state entries the profile no longer declares") do
        @filter = StatusReport::Classification::StateOnly
      end
      parser.on("--version-drift", "Show only items whose live version differs") do
        @filter = StatusReport::Classification::VersionDrift
      end
      parser.on("--failed", "Show missing, unknown, and version-drift items") { @failed = true }
    end

    def run(arguments : Array(String)) : ExitCode
      parse(arguments)
      report = build_report
      entries = filtered(report)

      case @format
      when .json? then render_json(report, entries)
      else             render_text(report, entries)
      end

      ExitCode::Success
    end

    # The filters are deliberately not combinable: each answers one question,
    # and intersecting them produces a set nobody asked for.
    private def filtered(report : StatusReport) : Array(StatusReport::Entry)
      return [] of StatusReport::Entry if @summary_only

      if @failed
        wanted = [StatusReport::Classification::Missing,
                  StatusReport::Classification::Unknown,
                  StatusReport::Classification::VersionDrift]
        return report.entries.select { |entry| wanted.includes?(entry.classification) }
      end

      if filter = @filter
        return report.entries.select(&.classification.== filter)
      end

      report.entries
    end

    private def render_text(report : StatusReport, entries : Array(StatusReport::Entry)) : Nil
      puts "Profile: #{Style.bold(report.profile.name)}"
      puts

      unless @summary_only
        if entries.empty?
          puts Style.dim("(no items match)")
        else
          width = Math.min(48, entries.max_of { |entry| "#{entry.step}/#{entry.display}".size })
          entries.each do |entry|
            label = Style.pad(Style.truncate("#{entry.step}/#{entry.display}", width), width)
            puts "#{colour_for(entry.classification, symbol_for(entry.classification))} " \
                 "#{label}  #{colour_for(entry.classification, entry.classification.label)}  " \
                 "#{Style.dim(entry.detail)}"
          end
        end
        puts
      end

      counts = report.summary
      puts "#{Style.bold("Total:")}         #{counts["total"]}"
      puts "#{Style.green("Installed:")}     #{counts["installed"]}"
      puts "#{Style.yellow("Missing:")}       #{counts["missing"]}"
      puts "#{Style.dim("State-only:")}    #{counts["stateOnly"]}"
      puts "#{Style.magenta("Unknown:")}       #{counts["unknown"]}"
      puts "#{Style.cyan("Version drift:")} #{counts["versionDrift"]}"
    end

    private def render_json(report : StatusReport, entries : Array(StatusReport::Entry)) : Nil
      puts({
        "profileName" => report.profile.name,
        "summary"     => report.summary,
        "items"       => entries.map { |entry| entry_json(entry) },
      }.to_json)
    end
  end

  # `fluxion diff` — what differs from the host, omitting what already matches.
  class DiffCommand < ReportingCommand
    def name : String
      "diff"
    end

    def summary : String
      "Show what would change on this host"
    end

    def usage : String
      "fluxion diff [-c FILE] [--format text|json]"
    end

    def run(arguments : Array(String)) : ExitCode
      parse(arguments)
      report = build_report

      case @format
      when .json? then render_json(report)
      else             render_text(report)
      end

      ExitCode::Success
    end

    private def render_text(report : StatusReport) : Nil
      puts "Diff for profile: #{Style.bold(report.profile.name)}"
      puts

      changes = report.changes
      if changes.empty?
        puts "#{Style.green(Symbols.success)} No changes detected."
        return
      end

      # Grouped by classification so the answer to "what will this do" is one
      # block rather than scattered through a list.
      StatusReport::Classification.each do |classification|
        next if classification.installed?
        group = changes.select(&.classification.== classification)
        next if group.empty?

        puts colour_for(classification, "#{classification.title}:")
        group.each do |entry|
          puts "  #{Symbols.bullet} #{entry.display} #{Style.dim("(#{entry.type})")}: #{Style.dim(entry.detail)}"
        end
        puts
      end
    end

    private def render_json(report : StatusReport) : Nil
      puts({
        "profileName" => report.profile.name,
        "summary"     => report.summary,
        "changes"     => report.changes.map { |entry| entry_json(entry) },
      }.to_json)
    end
  end

  # `fluxion explain` — why one phase or item would run or skip.
  class ExplainCommand < ReportingCommand
    def name : String
      "explain"
    end

    def summary : String
      "Explain why a phase or item would run or skip"
    end

    def usage : String
      "fluxion explain [-c FILE] (--phase NAME | --item KEY) [--format text|json]"
    end

    @phase : String?
    @item : String?

    def register(parser : OptionParser) : Nil
      super
      parser.on("--phase=NAME", "Phase to explain") { |value| @phase = value }
      parser.on("--item=KEY", "Item key or display name to explain") { |value| @item = value }
    end

    def run(arguments : Array(String)) : ExitCode
      parse(arguments)

      phase = @phase.presence
      item = @item.presence
      # Both would be two questions; neither would be none.
      if phase.nil? == item.nil?
        raise Failure.invalid_input("Specify exactly one of --phase or --item")
      end

      phase ? explain_phase(phase) : explain_item(item.not_nil!)
    end

    private def explain_phase(name : String) : ExitCode
      profile = load_profile
      phase = profile.phase?(name)
      unless phase
        raise Failure.invalid_input(
          "Unknown phase '#{name}'. Valid phases: #{profile.phases.map(&.name).join(", ")}")
      end

      if @format.json?
        puts({
          "kind"                => "phase",
          "name"                => phase.name,
          "dependsOn"           => phase.depends_on,
          "restartEffect"       => phase.restart_policy.json_name,
          "continueOnStepError" => phase.continue_on_step_error?,
          "steps"               => phase.steps.map { |step| {"name" => step.name, "type" => step.kind, "items" => step.items.size} },
        }.to_json)
        return ExitCode::Success
      end

      puts "#{Style.bold("Phase:")} #{Style.bold(phase.name)}"
      puts "#{Style.dim("Depends on:")}   #{phase.depends_on.empty? ? "(none)" : phase.depends_on.join(", ")}"
      puts "#{Style.dim("Restart:")}      #{phase.restart_policy}"
      puts "#{Style.dim("On failure:")}   #{phase.continue_on_step_error? ? "continue" : "stop and block dependents"}"
      puts
      puts Style.bold("Steps:")
      phase.steps.each do |step|
        puts "  #{Style.cyan(step.name)} #{Style.dim("(#{step.kind})")} — #{step.summary}"
      end
      ExitCode::Success
    end

    private def explain_item(key : String) : ExitCode
      report = build_report
      # Matching on either the key or the display name is what lets a user
      # paste whichever one the previous command printed.
      entry = report.entries.find { |candidate| candidate.key == key || candidate.display == key }
      unless entry
        raise Failure.invalid_input("Unknown item '#{key}'")
      end

      profile = report.profile
      phase = profile.phases.find { |candidate| candidate.steps.any?(&.name.== entry.step) }

      if @format.json?
        puts(entry_json(entry).merge({"phase" => phase.try(&.name)}).to_json)
        return ExitCode::Success
      end

      puts "#{Style.bold("Item:")} #{Style.bold(entry.display)}"
      puts "#{Style.dim("Phase:")}  #{phase.try(&.name) || "(unknown)"}"
      puts "#{Style.dim("Step:")}   #{entry.step}"
      puts "#{Style.dim("Type:")}   #{entry.type}"
      puts "#{Style.dim("Status:")} #{colour_for(entry.classification, entry.classification.label)}"
      puts "#{Style.dim("Reason:")} #{entry.detail}"
      ExitCode::Success
    end
  end
end
