module Fluxion::CLI
  # `fluxion plan` — the phase-ordered execution plan, without touching the
  # host.
  #
  # Shares phase ordering and item expansion with `apply`, so what it prints
  # is what would run rather than a separate description that can drift.
  class PlanCommand < Command
    def name : String
      "plan"
    end

    def summary : String
      "Show the execution plan without making any changes"
    end

    def usage : String
      "fluxion plan [-c FILE] [--show-commands] [--format text|table|tree|json]"
    end

    @format = Format::Text
    @show_commands = false

    def register(parser : OptionParser) : Nil
      parser.on("--show-commands", "Show the command preview for each item") { @show_commands = true }
      format_option(parser, [Format::Text, Format::Table, Format::Tree, Format::Json]) { |value| @format = value }
    end

    def run(arguments : Array(String)) : ExitCode
      parse(arguments)
      profile = load_profile

      case @format
      when .json?  then render_json(profile)
      when .table? then render_table(profile)
      when .tree?  then render_tree(profile)
      else              render_text(profile)
      end

      ExitCode::Success
    end

    # -- text ---------------------------------------------------------------

    private def render_text(profile : Profile) : Nil
      header(profile)
      puts "Execution plan for: #{Style.bold(profile.name)}"
      puts

      unless profile.source_setups.empty?
        puts Style.bold_blue("Source setup:")
        profile.source_setups.each do |setup|
          setup.items.each { |item| puts "  #{Style.dim(Symbols.bullet)} #{item.label}" }
        end
        puts
      end

      profile.ordered_phases.each_with_index do |phase, index|
        dependencies = phase.depends_on.empty? ? Style.dim("no deps") : Style.dim("after: #{phase.depends_on.join(", ")}")
        puts "#{Style.bold_blue("Phase #{index + 1}:")} #{Style.bold(phase.name)} [#{dependencies}]"

        phase.steps.each do |step|
          puts "  #{Style.cyan(step.kind)} #{Style.dim("—")} #{step.name}"
          step.items.each do |item|
            puts "    #{Style.dim(Symbols.bullet)} #{item.label}  #{Style.dim("would run")}"
          end
        end

        case policy = phase.restart_policy
        when RestartPolicy::PromptLogout
          puts "  #{Style.bold_yellow("#{Symbols.arrow} After this phase: RESTART REQUIRED")}"
        when RestartPolicy::RequiresNewShell
          puts "  #{Style.yellow("#{Symbols.arrow} After this phase: new-shell wrapper (#{policy.shell})")}"
        end
        puts
      end

      render_skipped(profile)
      counts(profile)
    end

    private def header(profile : Profile) : Nil
      facts = deps.host_facts
      puts "#{Style.dim("Profile:")} #{profile.name}"
      puts "#{Style.dim("Target:")}  #{profile.target}"
      puts "#{Style.dim("Host:")}    #{facts}"
      puts
    end

    private def render_skipped(profile : Profile) : Nil
      return if profile.skipped_plan_entries.empty?
      puts Style.bold_yellow("Skipped entries:")
      profile.skipped_plan_entries.each do |entry|
        puts "  #{Style.dim(Symbols.skipped)} #{Style.pad(entry.name, 28)} #{Style.dim(entry.reason)}"
      end
      puts
    end

    private def counts(profile : Profile) : Nil
      puts Style.dim(
        "Counts: source_setups=#{profile.source_setups.size} " \
        "steps=#{profile.steps.size} " \
        "skipped=#{profile.skipped_plan_entries.size} " \
        "items=#{profile.items.size + profile.source_setups.sum(&.items.size)}"
      )
    end

    # -- table --------------------------------------------------------------

    private def render_table(profile : Profile) : Nil
      rows = [] of {String, String, String, String}

      profile.source_setups.each do |setup|
        setup.items.each { |item| rows << {"source-setup", setup.name, item.label, "would run"} }
      end

      profile.ordered_phases.each do |phase|
        phase.steps.each do |step|
          step.items.each { |item| rows << {phase.name, step.name, item.label, "would run"} }
        end
      end

      # A skipped entry has no phase column to fill: the phase it was declared
      # in is exactly what the reason names when a phase-level `when` is unmet.
      profile.skipped_plan_entries.each do |entry|
        rows << {"(skipped)", entry.name, entry.kind, "skipped: #{entry.reason}"}
      end

      if rows.empty?
        puts Style.dim("(nothing to do)")
        return
      end

      widths = {
        Math.max(5, rows.max_of(&.[0].size)),
        Math.max(4, rows.max_of(&.[1].size)),
        Math.max(4, Math.min(40, rows.max_of(&.[2].size))),
      }

      puts Style.bold(
        "#{"PHASE".ljust(widths[0])}  #{"STEP".ljust(widths[1])}  " \
        "#{"ITEM".ljust(widths[2])}  STATUS"
      )
      puts Style.dim("-" * (widths[0] + widths[1] + widths[2] + 6 + 20))

      rows.each do |phase, step, item, status|
        colour = status.starts_with?("skipped") ? Style.yellow(status) : Style.dim(status)
        puts "#{phase.ljust(widths[0])}  #{Style.cyan(step.ljust(widths[1]))}  " \
             "#{Style.truncate(item, widths[2]).ljust(widths[2])}  #{colour}"
      end
    end

    # -- tree ---------------------------------------------------------------

    private def render_tree(profile : Profile) : Nil
      puts "Execution plan for: #{Style.bold(profile.name)}"

      unless profile.source_setups.empty?
        puts "#{Symbols.branch} #{Style.bold_blue("source setup")}"
        profile.source_setups.each do |setup|
          puts "   #{Symbols.branch} #{Style.cyan(setup.name)} #{Style.dim("(#{setup.step.kind})")}"
          setup.items.each { |item| puts "      #{Symbols.branch} #{item.label}" }
        end
      end

      profile.ordered_phases.each do |phase|
        dependencies = phase.depends_on.empty? ? "no deps" : "after: #{phase.depends_on.join(", ")}"
        puts "#{Symbols.branch} #{Style.bold(phase.name)} #{Style.dim("[#{dependencies}]")}"
        phase.steps.each do |step|
          puts "   #{Symbols.branch} #{Style.cyan(step.name)} #{Style.dim("(#{step.kind})")}"
          step.items.each { |item| puts "      #{Symbols.branch} #{item.label}" }
        end
      end

      return if profile.skipped_plan_entries.empty?
      puts "#{Symbols.branch} #{Style.yellow("skipped entries")}"
      profile.skipped_plan_entries.each do |entry|
        puts "   #{Symbols.branch} #{entry.name} #{Style.dim("(#{entry.kind}) — #{entry.reason}")}"
      end
    end

    # -- json ---------------------------------------------------------------

    private def render_json(profile : Profile) : Nil
      puts({
        "profileName"  => profile.name,
        "target"       => profile.target.to_s,
        "sourceSetups" => profile.source_setups.map { |setup| step_json(setup.step) },
        "phases"       => profile.ordered_phases.map do |phase|
          {
            "name"          => phase.name,
            "dependsOn"     => phase.depends_on,
            "restartEffect" => phase.restart_policy.json_name,
            "steps"         => phase.steps.map { |step| step_json(step) },
          }
        end,
        "skippedEntries" => profile.skipped_plan_entries.map do |entry|
          {"name" => entry.name, "kind" => entry.kind, "status" => "skipped", "reason" => entry.reason}
        end,
      }.to_json)
    end

    private def step_json(step : Step)
      # `ItemType`, not `ItemRef#type`. The two are separate vocabularies —
      # `ItemRef#type` is a free string each Step writes by hand — and they
      # disagree for six kinds, so `plan --format json` reported `"binary"` for
      # the same item `status --format json` called `"compiled_binary"`, and
      # `state forget --type` rejected the value `plan` had just printed.
      item_type = Executor::ItemTypes.for(step).json_name

      {
        "name"  => step.name,
        "type"  => step.kind,
        "items" => step.items.map do |item|
          {
            "key"         => item.key,
            "displayName" => item.label,
            "type"        => item_type,
            "status"      => "would run",
          }
        end,
      }
    end
  end

  # `fluxion graph` — the phase dependency graph, for pasting into a renderer.
  class GraphCommand < Command
    def name : String
      "graph"
    end

    def summary : String
      "Render the phase dependency graph"
    end

    def usage : String
      "fluxion graph [-c FILE] [--format mermaid|dot|json]"
    end

    @format = Format::Mermaid

    def register(parser : OptionParser) : Nil
      format_option(parser, [Format::Mermaid, Format::Dot, Format::Json]) { |value| @format = value }
    end

    def run(arguments : Array(String)) : ExitCode
      parse(arguments)
      profile = load_profile

      case @format
      when .dot?  then render_dot(profile)
      when .json? then render_json(profile)
      else             render_mermaid(profile)
      end

      ExitCode::Success
    end

    private def render_mermaid(profile : Profile) : Nil
      # Nodes first, then edges: Mermaid accepts either, but grouping them
      # keeps a hand-edited diagram readable.
      puts "flowchart TD"
      profile.phases.each { |phase| puts %(  #{node_id(phase.name)}["#{escape(phase.name)}"]) }
      profile.phases.each do |phase|
        phase.depends_on.each { |dependency| puts "  #{node_id(dependency)} --> #{node_id(phase.name)}" }
      end
    end

    private def render_dot(profile : Profile) : Nil
      puts "digraph fluxion {"
      puts "  rankdir=LR;"
      profile.phases.each { |phase| puts %(  "#{escape(phase.name)}";) }
      profile.phases.each do |phase|
        phase.depends_on.each { |dependency| puts %(  "#{escape(dependency)}" -> "#{escape(phase.name)}";) }
      end
      puts "}"
    end

    private def render_json(profile : Profile) : Nil
      edges = profile.phases.flat_map do |phase|
        phase.depends_on.map { |dependency| {"from" => dependency, "to" => phase.name} }
      end

      puts({
        "profileName" => profile.name,
        "phases"      => profile.phases.map do |phase|
          {
            "name"      => phase.name,
            "dependsOn" => phase.depends_on,
            "stepCount" => phase.steps.size,
          }
        end,
        "edges" => edges,
      }.to_json)
    end

    # Mermaid identifiers cannot contain punctuation, so the name is sanitized
    # for the node id and kept verbatim in the label.
    private def node_id(name : String) : String
      "p_#{name.gsub(/[^A-Za-z0-9_]/, "_")}"
    end

    private def escape(text : String) : String
      text.gsub('\\', "\\\\").gsub('"', "\\\"")
    end
  end
end
