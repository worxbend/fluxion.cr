module Fluxion::CLI
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
      id, target, catalogue = resolve_registry(arguments)
      parsed = manifest(target)
      found = entry(target, id)

      pending = @with_requires ? with_requirements(parsed, found) : [found]
      installed = pending.map { |item| {item, catalogue.install(item, @force)} }

      installed.each do |item, path|
        puts "#{Style.green(Symbols.success)} Installed #{Style.bold(item.id)} #{Style.dim("→ #{path}")}"
      end

      # A distribution mismatch is a warning rather than a refusal: a profile
      # may legitimately be run somewhere its author did not anticipate.
      distribution = deps.host_facts.distribution
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
      _, catalogue, found = resolve_entry(arguments)

      if catalogue.uninstall(found)
        puts "#{Style.green(Symbols.success)} Removed #{Style.bold(found.id)}"
      else
        puts Style.dim("'#{found.id}' was not installed")
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
      target, catalogue, found = resolve_entry(arguments)

      path = catalogue.installed_path(found)
      # Editing something that is not there would create an empty file and
      # leave the user wondering where the configuration went.
      unless File.exists?(path)
        raise Failure.invalid_input(
          "'#{found.id}' is not installed. Run: fluxion registry install #{found.id}")
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
        Config::Loader.load(path, deps.host_facts)
        puts "#{Style.green(Symbols.success)} #{path} is valid"
      rescue error : ValidationError | ConfigError
        @error_output.puts "#{Style.yellow(Symbols.warning)} Saved, but it does not validate:"
        @error_output.puts error.message
      end

      if catalogue.drift(found).locally_edited?
        puts Style.dim("  fluxion registry publish  to send this back to #{target.name}")
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
        catalogue.drift(entry).locally_edited?
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

      puts "#{Style.green(Symbols.success)} Published #{Text.pluralize(candidates.size, "configuration")}"
      ExitCode::Success
    end
  end
end
