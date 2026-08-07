module Fluxion::CLI
  # `fluxion registry` — configurations shared through a git repository.
  class RegistryCommand < GroupCommand
    def name : String
      "registry"
    end

    def summary : String
      "Install configurations from a shared registry"
    end

    def subcommands : Array(Command)
      [
        RegistryListCommand.new(@globals, @output, @error_output),
        RegistryAddCommand.new(@globals, @output, @error_output),
        RegistryRemoveCommand.new(@globals, @output, @error_output),
        RegistrySyncCommand.new(@globals, @output, @error_output),
        RegistryLsCommand.new(@globals, @output, @error_output),
        RegistryShowCommand.new(@globals, @output, @error_output),
        RegistryInstallCommand.new(@globals, @output, @error_output),
        RegistryUninstallCommand.new(@globals, @output, @error_output),
        RegistryEditCommand.new(@globals, @output, @error_output),
        RegistryStatusCommand.new(@globals, @output, @error_output),
        RegistryPublishCommand.new(@globals, @output, @error_output),
        RegistryInitCommand.new(@globals, @output, @error_output),
      ] of Command
    end
  end

  # Shared plumbing: resolving which registry to act on, and reporting drift.
  abstract class RegistrySubcommand < Command
    @registry_name : String?
    @format = Format::Text

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
      Registry::Git.new(Executor::SystemShellRunner.new)
    end

    protected def register_registry_option(parser : OptionParser) : Nil
      parser.on("--registry=NAME", "Which registry to use") { |value| @registry_name = value }
    end

    # Loads the manifest, telling the user to sync rather than leaving them
    # with a bare "no such file".
    protected def manifest(source : Registry::Source) : Registry::Manifest
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
      found = manifest(source).entry?(id)
      return found if found

      available = manifest(source).ids
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
        puts "#{Style.green(Symbols.success)} #{parsed.entries.size} configuration#{"s" if parsed.entries.size != 1} available"
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
        catalogue.installed?(entry) &&
          {Registry::Store::Drift::Upstream, Registry::Store::Drift::Both}.includes?(catalogue.drift(entry))
      end
      return if stale.empty?

      puts "  #{Style.cyan("#{stale.size} installed configuration#{"s" if stale.size != 1} changed upstream:")}"
      stale.each { |entry| puts "    #{Symbols.arrow} #{entry.id}" }
      puts Style.dim("  fluxion registry install <id> --force  to take the update")
    end
  end

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
      positional = parse(arguments)
      target = settings.resolve(positional.first? || @registry_name)
      catalogue = store(target)
      parsed = manifest(target)

      distribution = Host.facts.distribution
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
      positional = parse(arguments)
      id = positional.first?
      raise Failure.invalid_input("Specify a configuration id") unless id

      target = source
      catalogue = store(target)
      found = entry(target, id)
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

  class RegistryInstallCommand < RegistrySubcommand
    def name : String
      "install"
    end

    def summary : String
      "Install a configuration by id"
    end

    def usage : String
      "fluxion registry install <id> [--force] [--registry NAME]"
    end

    @force = false
    @with_requires = false

    def register(parser : OptionParser) : Nil
      register_registry_option(parser)
      parser.on("--force", "Overwrite local edits") { @force = true }
      parser.on("--with-requires", "Also install what this entry requires") { @with_requires = true }
    end

    def run(arguments : Array(String)) : ExitCode
      positional = parse(arguments)
      id = positional.first?
      raise Failure.invalid_input("Specify a configuration id") unless id

      target = source
      catalogue = store(target)
      parsed = manifest(target)
      found = entry(target, id)

      pending = @with_requires ? with_requirements(parsed, found) : [found]
      installed = pending.map { |item| {item, catalogue.install(item, @force)} }

      installed.each do |item, path|
        puts "#{Style.green(Symbols.success)} Installed #{Style.bold(item.id)} #{Style.dim("→ #{path}")}"
      end

      # A distribution mismatch is a warning rather than a refusal: a profile
      # may legitimately be run somewhere its author did not anticipate.
      distribution = Host.facts.distribution
      unless found.targets?(distribution)
        @error_output.puts "#{Style.yellow(Symbols.warning)} " \
                           "'#{found.id}' is written for #{found.distributions.map(&.config_name).join(", ")}; " \
                           "this host is #{distribution.try(&.config_name) || "unrecognised"}"
      end

      unless @with_requires || found.requires.empty?
        puts Style.dim("  it expects alongside it: #{found.requires.join(", ")} (--with-requires)")
      end

      # The requested entry, not the first requirement installed on its behalf.
      path = installed.find! { |item, _| item.id == found.id }[1]
      puts
      puts Style.dim("Review before running:")
      puts "  #{Style.cyan("fluxion dry-run -c #{path}")}"

      ExitCode::Success
    end

    # Requirements first, so a profile that builds on another is installed in
    # an order that makes sense to read.
    private def with_requirements(parsed : Registry::Manifest, root : Registry::Entry) : Array(Registry::Entry)
      ordered = [] of Registry::Entry
      collect(parsed, root, ordered, Set(String).new)
      ordered
    end

    # `seen` is marked on the way in, so a requirement cycle stops rather than
    # recursing until the stack runs out.
    private def collect(parsed : Registry::Manifest, entry : Registry::Entry,
                        ordered : Array(Registry::Entry), seen : Set(String)) : Nil
      return unless seen.add?(entry.id)

      entry.requires.each do |required|
        dependency = parsed.entry?(required)
        unless dependency
          raise Failure.invalid_input(
            "'#{entry.id}' requires '#{required}', which #{parsed.name} does not publish")
        end
        collect(parsed, dependency, ordered, seen)
      end

      ordered << entry
    end
  end

  class RegistryUninstallCommand < RegistrySubcommand
    def name : String
      "uninstall"
    end

    def summary : String
      "Remove an installed configuration"
    end

    def usage : String
      "fluxion registry uninstall <id> [--registry NAME]"
    end

    def register(parser : OptionParser) : Nil
      register_registry_option(parser)
    end

    def run(arguments : Array(String)) : ExitCode
      positional = parse(arguments)
      id = positional.first?
      raise Failure.invalid_input("Specify a configuration id") unless id

      target = source
      catalogue = store(target)
      found = entry(target, id)

      if catalogue.uninstall(found)
        puts "#{Style.green(Symbols.success)} Removed #{Style.bold(id)}"
      else
        puts Style.dim("'#{id}' was not installed")
      end

      ExitCode::Success
    end
  end

  class RegistryEditCommand < RegistrySubcommand
    def name : String
      "edit"
    end

    def summary : String
      "Open an installed configuration in your editor"
    end

    def usage : String
      "fluxion registry edit <id> [--registry NAME]"
    end

    def register(parser : OptionParser) : Nil
      register_registry_option(parser)
    end

    def run(arguments : Array(String)) : ExitCode
      positional = parse(arguments)
      id = positional.first?
      raise Failure.invalid_input("Specify a configuration id") unless id

      target = source
      catalogue = store(target)
      found = entry(target, id)

      path = catalogue.installed_path(found)
      # Editing something that is not there would create an empty file and
      # leave the user wondering where the configuration went.
      unless File.exists?(path)
        raise Failure.invalid_input(
          "'#{id}' is not installed. Run: fluxion registry install #{id}")
      end

      editor = ENV["VISUAL"]?.presence || ENV["EDITOR"]?.presence
      unless editor
        raise Failure.invalid_input(
          "Set $EDITOR or $VISUAL to choose an editor. The file is at #{path}")
      end

      # The one spawn in src/fluxion outside SystemShellRunner, and deliberately
      # so. Every rule that seam applies is wrong here: an editor needs the real
      # terminal rather than captured pipes, must not be killed by a timeout,
      # and produces no output to redact. Routing it through `ShellRunner` would
      # mean adding an interactive mode used exactly once, which buys nothing.
      status = Process.run(editor, [path], shell: true,
        input: Process::Redirect::Inherit,
        output: Process::Redirect::Inherit,
        error: Process::Redirect::Inherit)

      unless status.success?
        raise Failure.io("#{editor} exited #{status.exit_code}")
      end

      # Validating right after the edit turns a typo into a message now rather
      # than a failure on the next apply.
      begin
        Config::Loader.load(path, Host.facts)
        puts "#{Style.green(Symbols.success)} #{path} is valid"
      rescue error : ValidationError | ConfigError
        @error_output.puts "#{Style.yellow(Symbols.warning)} Saved, but it does not validate:"
        @error_output.puts error.message
      end

      case catalogue.drift(found)
      when .local?, .both?
        puts Style.dim("  fluxion registry publish  to send this back to #{target.name}")
      end

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
      positional = parse(arguments)
      target = settings.resolve(positional.first? || @registry_name)
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

  class RegistryPublishCommand < RegistrySubcommand
    def name : String
      "publish"
    end

    def summary : String
      "Send locally edited configurations back to the registry"
    end

    def usage : String
      "fluxion registry publish [--message TEXT] [--id ID] [--registry NAME]"
    end

    @message : String?
    @ids = [] of String
    @dry_run = false

    def register(parser : OptionParser) : Nil
      register_registry_option(parser)
      parser.on("--message=TEXT", "Commit message") { |value| @message = value }
      parser.on("--id=ID", "Publish only this entry (repeatable)") { |value| @ids << value }
      parser.on("--dry-run", "Show what would be published, change nothing") { @dry_run = true }
    end

    def run(arguments : Array(String)) : ExitCode
      parse(arguments)
      target = source
      catalogue = store(target)
      parsed = manifest(target)

      candidates = parsed.entries.select do |entry|
        next false unless @ids.empty? || @ids.includes?(entry.id)
        {Registry::Store::Drift::Local, Registry::Store::Drift::Both}.includes?(catalogue.drift(entry))
      end

      if candidates.empty?
        puts Style.dim("Nothing to publish: no installed configuration has local edits.")
        return ExitCode::Success
      end

      # Anything changed upstream *and* locally would be overwritten by
      # publishing, so it is refused rather than resolved by guessing.
      conflicted = candidates.select { |entry| catalogue.drift(entry).both? }
      unless conflicted.empty?
        raise Failure.invalid_input(
          "#{conflicted.map(&.id).join(", ")} changed both locally and upstream. " \
          "Reconcile them first — `fluxion registry show <id>` prints the registry's version.")
      end

      puts "Publishing to #{Style.bold(target.name)} #{Style.dim("(#{target.url})")}"
      candidates.each { |entry| puts "  #{Symbols.arrow} #{entry.id}" }

      if @dry_run
        puts
        puts Style.cyan("Dry run: nothing was staged, committed, or pushed.")
        return ExitCode::Success
      end

      candidates.each { |entry| catalogue.stage(entry) }

      message = @message || "Update #{candidates.map(&.id).join(", ")}"
      git.publish(target, message) { |line| progress(line) }

      # Re-installing re-records the digest, so what was just published reads
      # as current rather than as a pending local edit.
      candidates.each { |entry| catalogue.install(entry, force: true) }

      puts "#{Style.green(Symbols.success)} Published #{candidates.size} configuration#{"s" if candidates.size != 1}"
      ExitCode::Success
    end
  end

  class RegistryInitCommand < RegistrySubcommand
    def name : String
      "init"
    end

    def summary : String
      "Scaffold a registry repository"
    end

    def usage : String
      "fluxion registry init [DIRECTORY] [--name NAME]"
    end

    @custom_name : String?

    def register(parser : OptionParser) : Nil
      parser.on("--name=NAME", "Registry name") { |value| @custom_name = value }
    end

    def run(arguments : Array(String)) : ExitCode
      positional = parse(arguments)
      directory = File.expand_path(positional.first? || ".")
      name = @custom_name || File.basename(directory)

      manifest_path = File.join(directory, Registry::Manifest::FILE_NAME)
      if File.exists?(manifest_path)
        raise Failure.invalid_input("#{manifest_path} already exists")
      end

      profiles = File.join(directory, Registry::Manifest::PROFILE_DIRECTORY)
      Dir.mkdir_p(profiles)
      File.write(manifest_path, Registry::Manifest.template(name))

      example = File.join(profiles, "workstation.yaml")
      File.write(example, EXAMPLE_PROFILE) unless File.exists?(example)

      puts "#{Style.green(Symbols.success)} Registry scaffolded in #{directory}"
      puts
      width = Registry::Manifest::FILE_NAME.size
      puts "  #{Style.cyan(Style.pad(Registry::Manifest::FILE_NAME, width))}  " \
           "#{Style.dim("the manifest — one entry per configuration")}"
      puts "  #{Style.cyan(Style.pad("#{Registry::Manifest::PROFILE_DIRECTORY}/", width))}  " \
           "#{Style.dim("the profiles those entries name")}"
      puts
      puts Style.dim("Push it to a git host, then:")
      puts "  #{Style.cyan("fluxion registry add <url>")}"

      ExitCode::Success
    end

    EXAMPLE_PROFILE = <<-YAML
      # A starting point. Replace it with what your machines actually need.
      apiVersion: initkit.io/v1alpha1
      kind: WorkstationProfile
      metadata:
        name: workstation
      spec:
        target:
          os:
            distribution: fedora

        phases:
          - name: base
            steps:
              - name: core-tools
                kind: dnf-packages
                spec:
                  packages: [git, curl, jq]

      YAML
  end
end
