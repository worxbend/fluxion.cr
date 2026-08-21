module Fluxion::CLI
  # `fluxion registry` — configurations shared through a git repository.
  #
  # This file holds the group and the plumbing every subcommand shares. The
  # subcommands themselves sit beside it in `registry/`, grouped by what they
  # act on: `sources.cr` for the registries a machine is configured to use,
  # `catalogue.cr` for reading what one offers, `configurations.cr` for
  # installing and editing individual configurations, and `init.cr` for
  # scaffolding a registry to publish.
  class RegistryCommand < GroupCommand
    def name : String
      "registry"
    end

    def summary : String
      "Install configurations from a shared registry"
    end

    def subcommands : Array(Command)
      [
        RegistryListCommand.new(@globals, @output, @error_output, @deps),
        RegistryAddCommand.new(@globals, @output, @error_output, @deps),
        RegistryRemoveCommand.new(@globals, @output, @error_output, @deps),
        RegistrySyncCommand.new(@globals, @output, @error_output, @deps),
        RegistryLsCommand.new(@globals, @output, @error_output, @deps),
        RegistryShowCommand.new(@globals, @output, @error_output, @deps),
        RegistryInstallCommand.new(@globals, @output, @error_output, @deps),
        RegistryUninstallCommand.new(@globals, @output, @error_output, @deps),
        RegistryEditCommand.new(@globals, @output, @error_output, @deps),
        RegistryStatusCommand.new(@globals, @output, @error_output, @deps),
        RegistryPublishCommand.new(@globals, @output, @error_output, @deps),
        RegistryInitCommand.new(@globals, @output, @error_output, @deps),
      ] of Command
    end
  end

  # Shared plumbing: resolving which registry to act on, and reporting drift.
  abstract class RegistrySubcommand < Command
    @registry_name : String?
    @format = Format::Text

    # Manifests already read during this invocation, keyed by registry name.
    #
    # Reading one is not free — it is a file read, a YAML parse, and a round of
    # diagnostics — and `install` alone used to ask for the same manifest three
    # times: once for itself and twice inside `entry`. Worse than the cost, each
    # read printed the manifest's warnings again, so a registry with one warning
    # made `install` print it three times and left the user looking for three
    # problems. A command instance serves exactly one invocation, so a plain
    # hash is the whole of the lifetime question.
    @manifests = {} of String => Registry::Manifest

    protected def settings : Registry::Settings
      Registry::Settings.load
    end

    protected def source : Registry::Source
      settings.resolve(@registry_name)
    end

    protected def store(source : Registry::Source = self.source) : Registry::Store
      Registry::Store.new(source)
    end

    protected def git : Registry::Git
      deps.git
    end

    protected def register_registry_option(parser : OptionParser) : Nil
      parser.on("--registry=NAME", "Which registry to use") { |value| @registry_name = value }
    end

    # The preamble every id-taking subcommand shares: read the id, refuse an
    # empty one, and resolve the registry it applies to.
    protected def resolve_registry(arguments : Array(String)) : {String, Registry::Source, Registry::Store}
      positional = parse(arguments)
      id = positional.first?
      raise Failure.invalid_input("Specify a configuration id") unless id

      target = source
      {id, target, store(target)}
    end

    # As above, plus the configuration the id names — which is what four of the
    # five id-taking subcommands actually want.
    protected def resolve_entry(arguments : Array(String)) : {Registry::Source, Registry::Store, Registry::Entry}
      id, target, catalogue = resolve_registry(arguments)
      {target, catalogue, entry(target, id)}
    end

    # The registry named on the command line, falling back to `--registry` and
    # then to the default. Positional-first, because `fluxion registry ls mine`
    # is the spelling people reach for.
    protected def named_source(positional : Array(String)) : Registry::Source
      settings.resolve(positional.first? || @registry_name)
    end

    # Loads the manifest, telling the user to sync rather than leaving them
    # with a bare "no such file".
    protected def manifest(source : Registry::Source) : Registry::Manifest
      @manifests.fetch(source.name) { @manifests[source.name] = read_manifest(source) }
    end

    private def read_manifest(source : Registry::Source) : Registry::Manifest
      unless source.cloned?
        raise Failure.invalid_input(
          "#{source.name} has not been synced yet. Run: fluxion registry sync #{source.name}")
      end

      parsed, diagnostics = store(source).manifest
      unless parsed
        diagnostics.each { |diagnostic| @error_output.puts "#{Style.red("error")} #{diagnostic}" }
        raise Failure.configuration("#{source.name} does not publish a usable registry manifest")
      end

      diagnostics.select(&.warning?).each do |diagnostic|
        @error_output.puts "#{Style.yellow("warning")} #{diagnostic}"
      end

      parsed
    end

    protected def entry(source : Registry::Source, id : String) : Registry::Entry
      published = manifest(source)
      found = published.entry?(id)
      return found if found

      available = published.ids
      hint = available.empty? ? nil : "available: #{available.first(8).join(", ")}"
      raise Failure.invalid_input("#{source.name} has no entry '#{id}'#{hint ? " — #{hint}" : ""}")
    end

    protected def drift_label(drift : Registry::Store::Drift) : String
      case drift
      in .current?  then Style.green("current")
      in .upstream? then Style.cyan("update available")
      in .local?    then Style.yellow("locally edited")
      in .both?     then Style.yellow("edited, update available")
      in .absent?   then Style.dim("not installed")
      end
    end

    # Streams git output only when the user asked for detail. Git is chatty,
    # and a progress meter buried under it helps nobody.
    protected def progress(line : String) : Nil
      return unless @globals.verbose?
      @error_output.puts Style.dim("  #{line}")
    end
  end
end
