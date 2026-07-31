module Fluxion::CLI
  # `fluxion plan` — the phase-ordered execution plan, without touching the
  # host.
  #
  # Shares job ordering and item expansion with `apply`, so what it prints is
  # what would run rather than a separate description that can drift.
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

      profile.ordered_jobs.each_with_index do |job, index|
        dependencies = job.depends_on.empty? ? Style.dim("no deps") : Style.dim("after: #{job.depends_on.join(", ")}")
        puts "#{Style.bold_blue("Job #{index + 1}:")} #{Style.bold(job.name)} [#{dependencies}]"

        job.steps.each do |step|
          puts "  #{Style.cyan(step.kind)} #{Style.dim("—")} #{step.name}"
          step.items.each do |item|
            puts "    #{Style.dim(Symbols.bullet)} #{item.label}  #{Style.dim("would run")}"
          end
        end

        case policy = job.restart_policy
        when RestartPolicy::PromptLogout
          puts "  #{Style.bold_yellow("#{Symbols.arrow} After this job: RESTART REQUIRED")}"
        when RestartPolicy::RequiresNewShell
          puts "  #{Style.yellow("#{Symbols.arrow} After this job: new-shell wrapper (#{policy.shell})")}"
        end
        puts
      end

      render_skipped(profile)
      counts(profile)
    end

    private def header(profile : Profile) : Nil
      facts = Host.facts
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

      profile.ordered_jobs.each do |job|
        job.steps.each do |step|
          step.items.each { |item| rows << {job.name, step.name, item.label, "would run"} }
        end
      end

      profile.skipped_plan_entries.each do |entry|
        rows << {"manifest-plan", entry.name, entry.kind, "skipped: #{entry.reason}"}
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
        "#{"JOB".ljust(widths[0])}  #{"STEP".ljust(widths[1])}  " \
        "#{"ITEM".ljust(widths[2])}  STATUS"
      )
      puts Style.dim("-" * (widths[0] + widths[1] + widths[2] + 6 + 20))

      rows.each do |job, step, item, status|
        colour = status.starts_with?("skipped") ? Style.yellow(status) : Style.dim(status)
        puts "#{job.ljust(widths[0])}  #{Style.cyan(step.ljust(widths[1]))}  " \
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

      profile.ordered_jobs.each do |job|
        dependencies = job.depends_on.empty? ? "no deps" : "after: #{job.depends_on.join(", ")}"
        puts "#{Symbols.branch} #{Style.bold(job.name)} #{Style.dim("[#{dependencies}]")}"
        job.steps.each do |step|
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
        "jobs"         => profile.ordered_jobs.map do |job|
          {
            "name"          => job.name,
            "dependsOn"     => job.depends_on,
            "restartEffect" => restart_effect(job.restart_policy),
            "steps"         => job.steps.map { |step| step_json(step) },
          }
        end,
        "skippedEntries" => profile.skipped_plan_entries.map do |entry|
          {"name" => entry.name, "kind" => entry.kind, "status" => "skipped", "reason" => entry.reason}
        end,
      }.to_json)
    end

    private def step_json(step : Step)
      {
        "name"  => step.name,
        "type"  => step.kind,
        "items" => step.items.map do |item|
          {
            "key"         => item.key,
            "displayName" => item.label,
            "type"        => item.type,
            "status"      => "would run",
          }
        end,
      }
    end

    private def restart_effect(policy : RestartPolicy) : String
      case policy
      when RestartPolicy::PromptLogout     then "prompt_logout"
      when RestartPolicy::RequiresNewShell then "requires_new_shell"
      else                                      "none"
      end
    end
  end

  # `fluxion graph` — the job dependency graph, for pasting into a renderer.
  class GraphCommand < Command
    def name : String
      "graph"
    end

    def summary : String
      "Render the job dependency graph"
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
      profile.jobs.each { |job| puts %(  #{node_id(job.name)}["#{escape(job.name)}"]) }
      profile.jobs.each do |job|
        job.depends_on.each { |dependency| puts "  #{node_id(dependency)} --> #{node_id(job.name)}" }
      end
    end

    private def render_dot(profile : Profile) : Nil
      puts "digraph fluxion {"
      puts "  rankdir=LR;"
      profile.jobs.each { |job| puts %(  "#{escape(job.name)}";) }
      profile.jobs.each do |job|
        job.depends_on.each { |dependency| puts %(  "#{escape(dependency)}" -> "#{escape(job.name)}";) }
      end
      puts "}"
    end

    private def render_json(profile : Profile) : Nil
      edges = profile.jobs.flat_map do |job|
        job.depends_on.map { |dependency| {"from" => dependency, "to" => job.name} }
      end

      puts({
        "profileName" => profile.name,
        "jobs"        => profile.jobs.map do |job|
          {
            "name"      => job.name,
            "dependsOn" => job.depends_on,
            "stepCount" => job.steps.size,
          }
        end,
        "edges" => edges,
      }.to_json)
    end

    # Mermaid identifiers cannot contain punctuation, so the name is sanitized
    # for the node id and kept verbatim in the label.
    private def node_id(name : String) : String
      "j_#{name.gsub(/[^A-Za-z0-9_]/, "_")}"
    end

    private def escape(text : String) : String
      text.gsub('\\', "\\\\").gsub('"', "\\\"")
    end
  end
end
