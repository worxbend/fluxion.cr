module Fluxion::CLI
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
      document.next_phase.try { |phase| puts "- Next phase: `#{phase}`" }
      puts
      puts "## Phases"
      puts
      if document.phases.empty?
        puts "_No phases recorded._"
      else
        puts "| Phase | Status | Completed |"
        puts "| --- | --- | --- |"
        document.phases.each { |phase| puts "| #{phase.phase} | #{phase.status} | #{phase.completed_at} |" }
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
      puts "<h2>Phases</h2><table><tr><th>Phase</th><th>Status</th><th>Completed</th></tr>"
      document.phases.each do |phase|
        puts "<tr><td>#{html_escape(phase.phase)}</td><td>#{phase.status}</td><td>#{phase.completed_at}</td></tr>"
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
end
