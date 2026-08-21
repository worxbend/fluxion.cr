module Fluxion::CLI
  # `fluxion registry ls`, also reachable as the top-level `remote-ls`.
  class RegistryLsCommand < RegistrySubcommand
    def name : String
      "ls"
    end

    def summary : String
      "List the configurations a registry offers"
    end

    def usage : String
      "fluxion registry ls [NAME] [--search TEXT] [--installed] [--format text|json]"
    end

    @search : String?
    @installed_only = false
    @all_hosts = false

    def register(parser : OptionParser) : Nil
      parser.on("--search=TEXT", "Match id, name, description, or tag") { |value| @search = value }
      parser.on("--installed", "Only what is already installed") { @installed_only = true }
      parser.on("--all", "Include entries written for other distributions") { @all_hosts = true }
      format_option(parser, [Format::Text, Format::Json]) { |value| @format = value }
    end

    def run(arguments : Array(String)) : ExitCode
      target = named_source(parse(arguments))
      catalogue = store(target)
      parsed = manifest(target)

      distribution = deps.host_facts.distribution
      entries = @search.try { |query| parsed.search(query) } || parsed.entries
      entries = entries.select { |entry| catalogue.installed?(entry) } if @installed_only
      # A profile written for another distribution is hidden rather than shown
      # and refused, because a long list of things that cannot work is noise.
      # Anything already installed stays visible regardless: hiding a file the
      # user has on disk would be worse than showing one they cannot use.
      unless @all_hosts || @installed_only
        entries = entries.select { |entry| entry.targets?(distribution) || catalogue.installed?(entry) }
      end

      @format.json? ? render_json(target, parsed, entries, catalogue) : render_text(target, parsed, entries, catalogue)
      ExitCode::Success
    end

    private def render_text(target : Registry::Source, parsed : Registry::Manifest,
                            entries : Array(Registry::Entry), catalogue : Registry::Store) : Nil
      puts "#{Style.bold(parsed.name)} #{Style.dim("(#{target.name})")}"
      parsed.description.try { |text| puts Style.dim("  #{text}") }
      puts

      if entries.empty?
        puts Style.dim("(nothing matches)")
        hidden = parsed.entries.size
        if hidden > 0 && !@all_hosts
          puts Style.dim("#{hidden} entr#{hidden == 1 ? "y is" : "ies are"} written for other distributions — pass --all to see them")
        end
        return
      end

      id_width = entries.max_of(&.id.size)
      entries.each do |entry|
        state = drift_label(catalogue.drift(entry))
        puts "#{Style.cyan(Style.pad(entry.id, id_width))}  #{Style.pad(entry.name, 32)}  #{state}"
        entry.description.try { |text| puts "#{" " * id_width}  #{Style.dim(text)}" }
      end

      puts
      puts Style.dim("fluxion registry install <id>   ·   fluxion registry show <id>")
    end

    private def render_json(target : Registry::Source, parsed : Registry::Manifest,
                            entries : Array(Registry::Entry), catalogue : Registry::Store) : Nil
      puts({
        "registry" => target.name,
        "name"     => parsed.name,
        "entries"  => entries.map do |entry|
          {
            "id"            => entry.id,
            "name"          => entry.name,
            "description"   => entry.description,
            "path"          => entry.path,
            "distributions" => entry.distributions.map(&.config_name),
            "tags"          => entry.tags,
            "requires"      => entry.requires,
            "installed"     => catalogue.installed?(entry),
            "state"         => catalogue.drift(entry).to_s.downcase,
          }
        end,
      }.to_json)
    end
  end

  # The top-level spelling. `fluxion remote-ls` is the first thing anyone
  # reaches for, and making them find it under a group first is friction for
  # no benefit.
  class RemoteLsCommand < RegistryLsCommand
    def name : String
      "remote-ls"
    end

    def usage : String
      "fluxion remote-ls [NAME] [--search TEXT] [--format text|json]"
    end
  end

  class RegistryShowCommand < RegistrySubcommand
    def name : String
      "show"
    end

    def summary : String
      "Show one configuration in detail"
    end

    def usage : String
      "fluxion registry show <id> [--registry NAME]"
    end

    def register(parser : OptionParser) : Nil
      register_registry_option(parser)
      format_option(parser, [Format::Text, Format::Json]) { |value| @format = value }
    end

    def run(arguments : Array(String)) : ExitCode
      target, catalogue, found = resolve_entry(arguments)
      body = File.read(catalogue.source_path(found))

      if @format.json?
        puts({
          "id"            => found.id,
          "name"          => found.name,
          "description"   => found.description,
          "registry"      => target.name,
          "path"          => found.path,
          "distributions" => found.distributions.map(&.config_name),
          "tags"          => found.tags,
          "requires"      => found.requires,
          "installed"     => catalogue.installed?(found),
          "state"         => catalogue.drift(found).to_s.downcase,
          "profile"       => body,
        }.to_json)
        return ExitCode::Success
      end

      puts "#{Style.bold(found.name)} #{Style.dim("(#{found.id})")}"
      found.description.try { |text| puts text }
      puts
      puts "#{Style.dim("Registry:")}      #{target.name}"
      puts "#{Style.dim("Path:")}          #{found.path}"
      unless found.distributions.empty?
        puts "#{Style.dim("Distributions:")} #{found.distributions.map(&.config_name).join(", ")}"
      end
      puts "#{Style.dim("Tags:")}          #{found.tags.join(", ")}" unless found.tags.empty?
      puts "#{Style.dim("Requires:")}      #{found.requires.join(", ")}" unless found.requires.empty?
      puts "#{Style.dim("State:")}         #{drift_label(catalogue.drift(found))}"
      puts
      puts Style.bold("Profile:")
      body.each_line { |line| puts "  #{Style.dim(line)}" }

      ExitCode::Success
    end
  end

  class RegistryStatusCommand < RegistrySubcommand
    def name : String
      "status"
    end

    def summary : String
      "Compare installed configurations against the registry"
    end

    def usage : String
      "fluxion registry status [NAME] [--format text|json]"
    end

    def register(parser : OptionParser) : Nil
      format_option(parser, [Format::Text, Format::Json]) { |value| @format = value }
    end

    def run(arguments : Array(String)) : ExitCode
      target = named_source(parse(arguments))
      catalogue = store(target)
      parsed = manifest(target)

      states = parsed.entries.select { |entry| catalogue.installed?(entry) }
        .map { |entry| {entry, catalogue.drift(entry)} }

      # Something installed that the registry no longer lists is worth saying:
      # it is usually an entry that was renamed or withdrawn upstream.
      orphans = catalogue.installed_ids - parsed.ids

      if @format.json?
        puts({
          "registry"  => target.name,
          "revision"  => git.revision(target),
          "installed" => states.map do |entry, drift|
            {"id" => entry.id, "state" => drift.to_s.downcase}
          end,
          "orphans" => orphans,
        }.to_json)
        return ExitCode::Success
      end

      puts "#{Style.bold(target.name)} #{Style.dim(git.revision(target).try { |revision| "@ #{revision}" } || "")}"
      puts

      if states.empty? && orphans.empty?
        puts Style.dim("Nothing installed from this registry.")
        return ExitCode::Success
      end

      unless states.empty?
        width = states.max_of { |entry, _| entry.id.size }
        states.each do |entry, drift|
          puts "#{Style.cyan(Style.pad(entry.id, width))}  #{drift_label(drift)}"
        end
      end

      unless orphans.empty?
        puts
        puts Style.yellow("No longer published by #{target.name}:")
        orphans.each { |id| puts "  #{Symbols.skipped} #{id}" }
      end

      ExitCode::Success
    end
  end
end
