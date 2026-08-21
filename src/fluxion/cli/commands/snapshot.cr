module Fluxion::CLI
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

      runner = deps.runner
      facts = deps.host_facts

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
      argv = facts.distribution.try(&.installed_query_argv)
      return [] of String unless argv
      lines(runner, argv)
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
end
