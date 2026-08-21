module Fluxion::CLI
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
