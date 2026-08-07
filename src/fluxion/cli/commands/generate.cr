module Fluxion::CLI
  # Writes a file the user asked for, refusing to clobber silently.
  module OutputFile
    # Writes atomically, and refuses an existing path without `--force`.
    #
    # The symlink check matters: without it, a pre-positioned link would let
    # this write through to somewhere the user never named.
    def self.write(path : String, content : String, force : Bool) : String
      absolute = File.expand_path(path)

      if File.exists?(absolute) || File.symlink?(absolute)
        unless force
          raise Failure.invalid_input("#{absolute} already exists. Use --force to overwrite.")
        end
        if File.symlink?(absolute)
          raise Failure.io("Refusing to write through a symbolic link: #{absolute}")
        end
      end

      directory = File.dirname(absolute)
      unless Dir.exists?(directory)
        raise Failure.io("Directory does not exist: #{directory}")
      end

      temporary = "#{absolute}.fluxion-#{Random::Secure.hex(6)}"
      begin
        File.write(temporary, content)
        File.rename(temporary, absolute)
      rescue error
        File.delete(temporary) rescue nil
        raise Failure.io("Failed to write #{absolute}: #{error.message}")
      end

      absolute
    end
  end

  # The parts of a WorkstationProfile every generator emits the same way.
  #
  # Shared rather than duplicated per command because the header is what makes
  # the output loadable at all: a fragment without it is refused before the
  # parser looks at anything else, so a generator that got it wrong would
  # produce a file nobody can validate.
  module ProfileDocument
    extend self

    # Writes everything above `spec.phases`, leaving the caller to append its
    # own phases indented two spaces under `spec:`.
    def header(io : IO, name : String, distribution : Distribution?, release : String?) : Nil
      io << "apiVersion: " << Config::Manifest::SUPPORTED_API_VERSION << '\n'
      io << "kind: " << Config::Manifest::SUPPORTED_KIND << '\n'
      io << "metadata:\n"
      io << "  name: " << name << '\n'
      io << "spec:\n"
      io << "  target:\n"
      io << "    os:\n"
      io << "      distribution: " << (distribution || Distribution::Fedora).config_name << '\n'
      release.try { |value| io << "      release: \"" << value << "\"\n" }
    end

    # The step kind that installs with this manager, read from the same table
    # `validate` checks against so a generated profile can never name a kind
    # the parser would reject.
    def packages_kind(manager : PackageManager) : String
      kind = Config::PlanKinds::ALL.find { |candidate| candidate.package_manager == manager }
      raise Failure.configuration("No step kind installs with #{manager}") unless kind
      kind.id
    end
  end

  # `fluxion generate` — a starter profile for this machine.
  #
  # Deliberately free of personal defaults: it produces something to read and
  # edit, not something to run unexamined.
  class GenerateCommand < Command
    def name : String
      "generate"
    end

    def summary : String
      "Generate a starter profile"
    end

    def usage : String
      "fluxion generate --output PATH [--os auto|fedora|arch|opensuse|debian] [--preset minimal|developer|desktop]"
    end

    PRESETS = %w[minimal developer desktop]

    @os = "auto"
    @preset = "minimal"
    @profile_name = "starter"
    @output_path : String?
    @force = false

    def register(parser : OptionParser) : Nil
      parser.on("--os=NAME", "Target OS: auto, fedora, arch, opensuse, debian") { |value| @os = value }
      parser.on("--preset=NAME", "Preset: #{PRESETS.join(", ")}") { |value| @preset = value }
      parser.on("--profile=NAME", "Profile name [default: starter]") { |value| @profile_name = value }
      parser.on("--output=PATH", "Where to write the profile") { |value| @output_path = value }
      parser.on("--force", "Overwrite an existing file") { @force = true }
    end

    def run(arguments : Array(String)) : ExitCode
      parse(arguments)

      output = @output_path
      raise Failure.invalid_input("Specify --output") unless output

      unless PRESETS.includes?(@preset)
        raise Failure.invalid_input("Unsupported preset '#{@preset}'. Expected one of: #{PRESETS.join(", ")}")
      end

      distribution = resolve_distribution
      written = OutputFile.write(output, render(distribution), @force)

      puts "#{Style.green(Symbols.success)} Generated profile: #{written}"
      puts Style.dim("Review it before running: fluxion validate -c #{written}")
      ExitCode::Success
    end

    private def resolve_distribution : Distribution
      if @os == "auto"
        detected = Host.facts.distribution
        raise Failure.configuration(
          "Could not detect the distribution; pass --os explicitly") unless detected
        return detected
      end

      parsed = Distribution.from_config?(@os)
      raise Failure.configuration("Unsupported generator OS: #{@os}") unless parsed
      parsed
    end

    private def render(distribution : Distribution) : String
      manager = distribution.package_managers.first

      String.build do |io|
        io << "# Generated by fluxion generate. Review before applying.\n"
        ProfileDocument.header(io, @profile_name, distribution, Host.facts.version)
        io << '\n'
        io << "  phases:\n"
        io << "    - name: base\n"
        io << "      steps:\n"
        io << "        - name: core-tools\n"
        io << "          kind: " << ProfileDocument.packages_kind(manager) << '\n'
        io << "          spec:\n"
        io << "            packages:\n"
        packages(distribution).each { |package| io << "              - " << package << '\n' }

        if @preset == "developer" || @preset == "desktop"
          io << '\n'
          io << "        - name: git-identity\n"
          io << "          kind: git-config\n"
          io << "          spec:\n"
          io << "            scope: global\n"
          io << "            entries:\n"
          io << "              init.defaultBranch: main\n"
          io << "              pull.rebase: \"true\"\n"
        end

        if @preset == "desktop"
          io << '\n'
          io << "    - name: desktop\n"
          io << "      dependsOn: [base]\n"
          io << "      steps:\n"
          io << "        - name: desktop-apps\n"
          io << "          kind: flatpak-packages\n"
          io << "          spec:\n"
          io << "            remote: flathub\n"
          io << "            apps:\n"
          io << "              - org.mozilla.firefox\n"
        end
      end
    end

    # Names that exist in every distribution's repositories, so a generated
    # profile validates and applies without editing.
    private def packages(distribution : Distribution) : Array(String)
      common = %w[git curl jq]
      return common if @preset == "minimal"

      case distribution
      in .fedora?           then common + %w[ripgrep fd-find neovim zsh]
      in .arch?             then common + %w[ripgrep fd neovim zsh]
      in .open_suse?        then common + %w[ripgrep fd neovim zsh]
      in .debian?, .ubuntu? then common + %w[ripgrep fd-find neovim zsh]
      end
    end
  end

  # `fluxion snapshot` — a read-only inventory of this host.
  #
  # Records only what a profile could plausibly declare. It does not read shell
  # history, dotfile contents, or credentials: a snapshot is something people
  # paste into issues.
  class SnapshotCommand < Command
    def name : String
      "snapshot"
    end

    def summary : String
      "Write a review-required inventory of this host"
    end

    def usage : String
      "fluxion snapshot --output PATH [--force]"
    end

    COMMAND_TIMEOUT = 5.seconds
    MAX_ENTRIES     = 20_000

    @output_path : String?
    @force = false

    def register(parser : OptionParser) : Nil
      parser.on("--output=PATH", "Where to write the snapshot") { |value| @output_path = value }
      parser.on("--force", "Overwrite an existing file") { @force = true }
    end

    def run(arguments : Array(String)) : ExitCode
      parse(arguments)
      output = @output_path
      raise Failure.invalid_input("Specify --output") unless output

      runner = Executor::SystemShellRunner.new
      facts = Host.facts

      snapshot = {
        "fluxionVersion" => VERSION,
        "capturedAt"     => Time.utc.to_rfc3339,
        "host"           => {
          "distribution" => facts.distribution.try(&.config_name),
          "id"           => facts.distribution_id,
          "version"      => facts.version,
          "codename"     => facts.codename,
          "architecture" => facts.architecture.try(&.config_name),
          "prettyName"   => facts.pretty_name,
        },
        "packageManagers" => PackageManager.values.select { |manager| Host.command_exists?(manager.command) }
          .map(&.config_name),
        "packages" => packages(runner, facts),
        "flatpaks" => lines(runner, ["flatpak", "list", "--app", "--columns=application"]),
        "shell"    => ENV["SHELL"]?,
        "tools"    => %w[git curl gpg systemctl flatpak cargo npm go pipx uv]
          .select { |tool| Host.command_exists?(tool) },
      }

      written = OutputFile.write(output, snapshot.to_pretty_json + "\n", @force)
      puts "#{Style.green(Symbols.success)} Snapshot written: #{written}"
      puts Style.dim("It records package names and tool presence only — no history, dotfiles, or credentials.")
      ExitCode::Success
    end

    private def packages(runner : Executor::ShellRunner, facts : HostFacts) : Array(String)
      argv = SnapshotCommand.query_argv(facts.distribution)
      return [] of String unless argv
      lines(runner, argv)
    end

    # The command that lists installed package names, per distribution.
    def self.query_argv(distribution : Distribution?) : Array(String)?
      return unless distribution
      case distribution
      in .fedora?, .open_suse? then ["rpm", "-qa", "--qf", "%{NAME}\\n"]
      in .arch?                then ["pacman", "-Qq"]
      in .debian?, .ubuntu?    then ["dpkg-query", "-W", "-f=${Package}\\n"]
      end
    end

    private def lines(runner : Executor::ShellRunner, argv : Array(String)) : Array(String)
      return [] of String unless Host.command_exists?(argv.first)
      result = runner.run(Executor::Command.new(argv, timeout: COMMAND_TIMEOUT))
      return [] of String unless result.success?
      # Sorted and bounded: a snapshot is for reading and diffing, and the
      # order a package database happens to return is not information.
      result.stdout.lines.map(&.strip).reject(&.empty?).sort!.first(MAX_ENTRIES)
    end
  end

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
        ImportPackagesCommand.new(@globals, @output, @error_output),
        ImportFlatpaksCommand.new(@globals, @output, @error_output),
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
      facts = Host.facts
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

      facts = Host.facts
      manager = facts.distribution.try(&.package_managers.first)
      raise Failure.external("No supported host package database found") unless manager

      runner = Executor::SystemShellRunner.new
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
      argv = facts.distribution.try(&.arch?) ? ["pacman", "-Qqe"] : SnapshotCommand.query_argv(facts.distribution)
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

      runner = Executor::SystemShellRunner.new
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
