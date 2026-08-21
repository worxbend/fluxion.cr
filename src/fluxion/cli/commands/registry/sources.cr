module Fluxion::CLI
  class RegistryAddCommand < RegistrySubcommand
    def name : String
      "add"
    end

    def summary : String
      "Configure a registry"
    end

    def usage : String
      "fluxion registry add <url> [--name NAME] [--ref BRANCH] [--default]"
    end

    @custom_name : String?
    @ref : String?
    @default = false
    @no_sync = false

    def register(parser : OptionParser) : Nil
      parser.on("--name=NAME", "Local name [default: derived from the URL]") { |value| @custom_name = value }
      parser.on("--ref=BRANCH", "Branch or tag to track") { |value| @ref = value }
      parser.on("--default", "Use this registry when none is named") { @default = true }
      parser.on("--no-sync", "Configure without cloning yet") { @no_sync = true }
    end

    def run(arguments : Array(String)) : ExitCode
      positional = parse(arguments)
      url = positional.first?
      raise Failure.invalid_input("Specify a registry URL") unless url

      if problem = Registry::Source.validate_url(url)
        raise Failure.invalid_input(problem)
      end

      name = @custom_name || Registry::Source.derive_name(url)
      unless name
        raise Failure.invalid_input(
          "Could not derive a name from #{url}. Pass --name explicitly.")
      end
      unless Registry::Source.valid_name?(name)
        raise Failure.invalid_input(
          "'#{name}' is not a usable registry name: letters, digits, '.', '_', and '-' only")
      end

      current = settings
      # The first registry is the default whether or not it was asked for —
      # with only one configured, every command would resolve to it anyway.
      is_default = @default || current.sources.empty?
      added = Registry::Source.new(name, url.strip, @ref, is_default)

      current.add(added).save
      puts "#{Style.green(Symbols.success)} Registered #{Style.bold(name)} #{Style.dim("(#{url})")}"

      return ExitCode::Success if @no_sync

      puts Style.dim("  syncing…")
      git.sync(added) { |line| progress(line) }

      parsed, _ = store(added).manifest
      if parsed
        puts "#{Style.green(Symbols.success)} #{Text.pluralize(parsed.entries.size, "configuration")} available"
        puts Style.dim("  fluxion remote-ls")
      else
        @error_output.puts "#{Style.yellow(Symbols.warning)} " \
                           "Synced, but #{name} does not publish a #{Registry::Manifest::FILE_NAME}"
      end

      ExitCode::Success
    end
  end

  class RegistryListCommand < RegistrySubcommand
    def name : String
      "list"
    end

    def summary : String
      "Show the configured registries"
    end

    def usage : String
      "fluxion registry list [--format text|json]"
    end

    def register(parser : OptionParser) : Nil
      format_option(parser, [Format::Text, Format::Json]) { |value| @format = value }
    end

    def run(arguments : Array(String)) : ExitCode
      parse(arguments)
      sources = settings.sources

      if @format.json?
        puts({"registries" => sources.map { |source| describe(source) }}.to_json)
        return ExitCode::Success
      end

      if sources.empty?
        puts Style.dim("No registries configured.")
        puts
        puts "Add one with: #{Style.cyan("fluxion registry add https://github.com/you/profiles")}"
        return ExitCode::Success
      end

      width = sources.max_of(&.name.size)
      sources.each do |source|
        marker = source.default? ? Style.green("*") : " "
        state = if source.cloned?
                  revision = git.revision(source)
                  Style.dim("synced#{revision ? " @ #{revision}" : ""}")
                else
                  Style.yellow("not synced")
                end
        puts "#{marker} #{Style.cyan(Style.pad(source.name, width))}  #{source.url}  #{state}"
      end

      puts
      puts Style.dim("* is the default. Installed configurations live in #{Registry::Source.install_root}")
      ExitCode::Success
    end

    private def describe(source : Registry::Source)
      {
        "name"        => source.name,
        "url"         => source.url,
        "ref"         => source.ref,
        "default"     => source.default?,
        "synced"      => source.cloned?,
        "revision"    => source.cloned? ? git.revision(source) : nil,
        "mirrorPath"  => source.mirror_path,
        "installPath" => source.install_path,
      }
    end
  end

  class RegistryRemoveCommand < RegistrySubcommand
    def name : String
      "remove"
    end

    def summary : String
      "Forget a registry"
    end

    def usage : String
      "fluxion registry remove <name> [--purge]"
    end

    @purge = false

    def register(parser : OptionParser) : Nil
      parser.on("--purge", "Also delete the configurations installed from it") { @purge = true }
    end

    def run(arguments : Array(String)) : ExitCode
      positional = parse(arguments)
      name = positional.first?
      raise Failure.invalid_input("Specify a registry name") unless name

      current = settings
      target = current.find(name)
      raise Failure.invalid_input("Unknown registry '#{name}'") unless target

      current.remove(name).save

      # The mirror is disposable, so it always goes. Installed configurations
      # are the user's, so they only go when asked.
      FileUtils.rm_rf(target.mirror_path) rescue nil
      puts "#{Style.green(Symbols.success)} Removed #{Style.bold(name)}"

      if @purge
        FileUtils.rm_rf(target.install_path) rescue nil
        puts Style.dim("  deleted #{target.install_path}")
      elsif Dir.exists?(target.install_path)
        puts Style.dim("  configurations installed from it are still at #{target.install_path}")
      end

      ExitCode::Success
    end
  end

  class RegistrySyncCommand < RegistrySubcommand
    def name : String
      "sync"
    end

    def summary : String
      "Fetch the latest configurations from a registry"
    end

    def usage : String
      "fluxion registry sync [NAME] [--all]"
    end

    @all = false

    def register(parser : OptionParser) : Nil
      parser.on("--all", "Sync every configured registry") { @all = true }
    end

    def run(arguments : Array(String)) : ExitCode
      positional = parse(arguments)

      targets = if @all
                  settings.sources
                else
                  [settings.resolve(positional.first?)]
                end

      if targets.empty?
        puts Style.dim("No registries configured.")
        return ExitCode::Success
      end

      client = git
      targets.each do |target|
        print "#{Style.cyan(target.name)} … "
        @output.flush

        before = client.revision(target)
        client.sync(target) { |line| progress(line) }
        after = client.revision(target)

        if before && after && before == after
          puts Style.dim("already current @ #{after}")
        else
          puts "#{Style.green("updated")}#{after ? Style.dim(" @ #{after}") : ""}"
        end

        report_updates(target)
      end

      ExitCode::Success
    end

    # Syncing refreshes the mirror; it never touches installed files. Saying
    # which ones have moved on is what makes that separation useful rather than
    # merely safe.
    private def report_updates(target : Registry::Source) : Nil
      parsed, _ = store(target).manifest
      return unless parsed

      catalogue = store(target)
      stale = parsed.entries.select do |entry|
        catalogue.installed?(entry) && catalogue.drift(entry).upstream_changed?
      end
      return if stale.empty?

      puts "  #{Style.cyan("#{stale.size} installed #{Text.singular_or_plural(stale.size, "configuration")} changed upstream:")}"
      stale.each { |entry| puts "    #{Symbols.arrow} #{entry.id}" }
      puts Style.dim("  fluxion registry install <id> --force  to take the update")
    end
  end
end
