module Fluxion::CLI
  # `fluxion import` — turn what is installed into a profile fragment.
  class ImportCommand < GroupCommand
    def name : String
      "import"
    end

    def summary : String
      "Generate a review-required profile fragment from this host"
    end

    def subcommands : Array(Command)
      [
        ImportPackagesCommand.new(@globals, @output, @error_output, @deps),
        ImportFlatpaksCommand.new(@globals, @output, @error_output, @deps),
      ] of Command
    end
  end

  abstract class ImportSubcommand < Command
    @output_path : String?
    @force = false
    @from_host = false

    def register(parser : OptionParser) : Nil
      parser.on("--from-host", "Read from the current host") { @from_host = true }
      parser.on("--output=PATH", "Where to write the fragment") { |value| @output_path = value }
      parser.on("--force", "Overwrite an existing file") { @force = true }
    end

    protected def destination : String
      # `--from-host` is required rather than implied so the command reads as a
      # deliberate act: this writes a file describing the machine.
      raise Failure.invalid_input("Specify --from-host") unless @from_host
      output = @output_path
      raise Failure.invalid_input("Specify --output") unless output
      output
    end

    # A complete profile rather than a bare fragment.
    #
    # The Java version emitted just the phase, which meant the output could not
    # be validated or previewed without hand-editing a header onto it first.
    # Emitting the header costs four lines and loses nothing: the phase below
    # it still lifts straight into an existing profile.
    protected def header(io : IO, name : String) : Nil
      facts = deps.host_facts
      ProfileDocument.header(io, name, facts.distribution, facts.version)
      io << '\n'
    end

    protected def finish(path : String, description : String, &) : ExitCode
      written = OutputFile.write(path, yield, @force)
      puts "#{Style.green(Symbols.success)} Imported #{description}: #{written}"
      puts Style.dim("Review it and remove anything machine-specific before merging it into a profile.")
      ExitCode::Success
    end

    # Quoted only when it has to be, so the common case stays readable.
    protected def yaml_scalar(value : String) : String
      value.matches?(/\A[A-Za-z0-9_.+:-]+\z/) ? value : %("#{value.gsub('"', "\\\"")}")
    end
  end

  class ImportPackagesCommand < ImportSubcommand
    def name : String
      "packages"
    end

    def summary : String
      "Import the host's installed packages"
    end

    def usage : String
      "fluxion import packages --from-host --output PATH"
    end

    def run(arguments : Array(String)) : ExitCode
      parse(arguments)
      path = destination

      facts = deps.host_facts
      manager = facts.distribution.try(&.package_managers.first)
      raise Failure.external("No supported host package database found") unless manager

      runner = deps.runner
      names = installed(runner, facts)
      raise Failure.external("No installed packages found") if names.empty?

      finish(path, "packages") do
        String.build do |io|
          io << "# Review required. Generated from this host's package database.\n"
          io << "# Remove machine-specific, transient, or unwanted packages before applying.\n"
          header(io, "imported-packages")
          io << "  phases:\n"
          io << "    - name: imported-packages\n"
          io << "      steps:\n"
          io << "        - name: imported-packages\n"
          io << "          kind: " << ProfileDocument.packages_kind(manager) << '\n'
          io << "          spec:\n"
          io << "            packages:\n"
          names.each { |name| io << "              - " << yaml_scalar(name) << '\n' }
        end
      end
    end

    private def installed(runner : Executor::ShellRunner, facts : HostFacts) : Array(String)
      # Explicitly-installed packages only where the manager tracks that: a
      # fragment listing every transitive dependency is unusable.
      argv = facts.distribution.try(&.installed_query_argv(explicit_only: true))
      return [] of String unless argv && Host.command_exists?(argv.first)

      result = runner.run(Executor::Command.new(argv, timeout: 30.seconds))
      return [] of String unless result.success?
      result.stdout.lines.map(&.strip).reject(&.empty?).sort!.uniq!
    end
  end

  class ImportFlatpaksCommand < ImportSubcommand
    def name : String
      "flatpaks"
    end

    def summary : String
      "Import the host's installed Flatpak apps"
    end

    def usage : String
      "fluxion import flatpaks --from-host --output PATH"
    end

    def run(arguments : Array(String)) : ExitCode
      parse(arguments)
      path = destination

      raise Failure.external("Flatpak command not found") unless Host.command_exists?("flatpak")

      runner = deps.runner
      apps = list(runner, ["flatpak", "list", "--app", "--columns=application"])
      raise Failure.external("No installed Flatpak apps found") if apps.empty?

      remotes = list(runner, ["flatpak", "remotes", "--columns=name"])
      remote = remotes.includes?("flathub") ? "flathub" : (remotes.first? || "flathub")

      finish(path, "Flatpaks") do
        String.build do |io|
          io << "# Review required. Generated from this host's Flatpak installation.\n"
          io << "# Remove machine-specific, transient, or unwanted apps before applying.\n"
          header(io, "imported-flatpaks")
          io << "  phases:\n"
          io << "    - name: imported-flatpaks\n"
          io << "      steps:\n"
          io << "        - name: imported-flatpaks\n"
          io << "          kind: flatpak-packages\n"
          io << "          spec:\n"
          io << "            remote: " << yaml_scalar(remote) << '\n'
          io << "            apps:\n"
          apps.each { |app| io << "              - " << yaml_scalar(app) << '\n' }
        end
      end
    end

    private def list(runner : Executor::ShellRunner, argv : Array(String)) : Array(String)
      result = runner.run(Executor::Command.new(argv, timeout: 15.seconds))
      return [] of String unless result.success?
      result.stdout.lines.map(&.strip).reject(&.empty?).sort!
    end
  end
end
