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
        detected = deps.host_facts.distribution
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
        ProfileDocument.header(io, @profile_name, distribution, deps.host_facts.version)
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
end
