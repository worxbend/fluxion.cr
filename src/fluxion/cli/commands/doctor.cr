module Fluxion::CLI
  # `fluxion doctor` — is this host ready to run this profile?
  #
  # Answers before a run rather than during one. A missing `flatpak` discovered
  # halfway through an apply has already left the machine half-configured; the
  # same finding up front costs nothing.
  class DoctorCommand < Command
    def name : String
      "doctor"
    end

    def summary : String
      "Check host readiness for a profile"
    end

    def usage : String
      "fluxion doctor [-c FILE] [--skip-network]"
    end

    enum Level
      Pass
      Warn
      Fail
    end

    record Check, level : Level, name : String, detail : String

    @skip_network = false
    @profile_name = "default"

    def register(parser : OptionParser) : Nil
      parser.on("--skip-network", "Skip reachability checks for remote artifacts") { @skip_network = true }
      parser.on("--profile=NAME", "State profile name [default: default]") { |value| @profile_name = value }
    end

    def run(arguments : Array(String)) : ExitCode
      parse(arguments)
      checks = [] of Check

      profile = begin
        loaded = load_profile
        checks << Check.new(Level::Pass, "config file", "loaded #{loaded.name}")
        loaded
      rescue error : Failure | ConfigError
        checks << Check.new(Level::Fail, "config file", error.message || "could not be loaded")
        nil
      end

      checks.concat(host_checks)
      checks.concat(state_checks)
      profile.try { |config| checks.concat(profile_checks(config)) }

      width = checks.max_of(&.name.size)
      checks.each { |check| puts render(check, width) }

      failures = checks.count(&.level.fail?)
      return ExitCode::Success if failures.zero?

      puts
      raise Failure.external("Doctor found #{failures} failing check#{"s" if failures != 1}")
    end

    private def render(check : Check, width : Int32) : String
      label, colour = case check.level
                      in Level::Pass then {"pass", ->(text : String) { Style.green(text) }}
                      in Level::Warn then {"warn", ->(text : String) { Style.yellow(text) }}
                      in Level::Fail then {"fail", ->(text : String) { Style.red(text) }}
                      end

      "[#{colour.call(label)}] #{Style.pad(check.name, width)}  #{Style.dim(check.detail)}"
    end

    private def host_checks : Array(Check)
      checks = [] of Check
      facts = deps.host_facts

      if facts.distribution
        checks << Check.new(Level::Pass, "host os", facts.to_s)
      else
        # Not fatal: a profile may declare nothing that depends on the
        # distribution, and refusing to run on an unrecognised host would be
        # worse than saying so.
        checks << Check.new(Level::Warn, "host os",
          "unrecognised#{facts.distribution_id.try { |id| ": #{id}" }}")
      end

      checks << command_check("sudo", required: false)
      checks
    end

    private def state_checks : Array(Check)
      store = deps.store
      directory = store.root

      if Dir.exists?(directory)
        info = File.info(directory)
        if info.permissions.group_write? || info.permissions.other_write?
          # A writable state directory would let someone else make Fluxion skip
          # work that was never done.
          return [Check.new(Level::Fail, "state directory", "#{directory} is writable by another account")]
        end
        return [Check.new(Level::Pass, "state directory", directory)]
      end

      parent = File.dirname(directory)
      return [Check.new(Level::Pass, "state directory", "#{directory} (will be created)")] if Dir.exists?(parent)
      [Check.new(Level::Warn, "state directory", "#{parent} does not exist yet")]
    end

    private def profile_checks(profile : Profile) : Array(Check)
      checks = [] of Check
      checks << Check.new(Level::Pass, "target os", profile.target.to_s)

      seen = Set(String).new
      profile.steps.each do |step|
        required_commands(step).each do |command|
          next unless seen.add?(command)
          checks << command_check(command)
        end

        case step
        when DefaultShellStep
          info = File.info?(step.shell_path)
          checks << if info && info.permissions.owner_execute?
            Check.new(Level::Pass, "shell path", step.shell_path)
          else
            Check.new(Level::Fail, "shell path", "#{step.shell_path} is not executable")
          end
        end
      end

      checks
    end

    private def required_commands(step : Step) : Array(String)
      case step
      when PackagesStep      then [step.package_manager.command]
      when SystemUpdateStep  then [step.package_manager.command]
      when FlatpakStep       then ["flatpak"]
      when FlatpakRemoteStep then ["flatpak"]
      when ToolPackagesStep  then [step.backend.command]
      when GitRepoStep       then ["git"]
      when GitConfigStep     then ["git"]
      when SystemdUnitStep   then ["systemctl"]
      when GpgKeyStep        then ["gpg"]
      when NerdFontsStep     then ["fc-list"]
      else                        [] of String
      end
    end

    private def command_check(command : String, required : Bool = true) : Check
      return Check.new(Level::Pass, "#{command} command", command) if Host.command_exists?(command)
      Check.new(required ? Level::Fail : Level::Warn, "#{command} command", "not found on PATH")
    end

    private def reachable?(url : String) : Bool
      uri = URI.parse(url)
      client = HTTP::Client.new(uri)
      client.connect_timeout = 3.seconds
      client.read_timeout = 3.seconds
      begin
        response = client.head(uri.request_target)
        response.status.success? || response.status.redirection?
      ensure
        client.close rescue nil
      end
    rescue
      false
    end
  end

  # `fluxion lint` — profile quality and safety advice.
  #
  # Deliberately separate from `validate`: validation answers "would this run",
  # which is a yes/no with an exit code. Lint answers "is this a good profile",
  # which is advice and never fails the command.
  class LintCommand < Command
    def name : String
      "lint"
    end

    def summary : String
      "Score profile quality and flag safety concerns"
    end

    def usage : String
      "fluxion lint [-c FILE] [--format text|json]"
    end

    record Finding, severity : Diagnostic::Severity, rule : String, step : String, message : String

    @format = Format::Text

    def register(parser : OptionParser) : Nil
      format_option(parser, [Format::Text, Format::Json]) { |value| @format = value }
    end

    def run(arguments : Array(String)) : ExitCode
      parse(arguments)
      profile = load_profile
      findings = analyse(profile)

      case @format
      when .json? then render_json(profile, findings)
      else             render_text(profile, findings)
      end

      ExitCode::Success
    end

    private def analyse(profile : Profile) : Array(Finding)
      findings = [] of Finding

      profile.steps.each do |step|
        case step
        when ShellCommandStep
          findings.concat(command_findings(step))
        when ShellScriptStep
          step.scripts.each do |script|
            next unless script.remote?
            findings << Finding.new(Diagnostic::Severity::Info, "remote-script", step.name,
              "runs a remote script; the pinned digest is what makes this reviewable")
          end
        when ManualStep
          next if step.probe_command
          findings << Finding.new(Diagnostic::Severity::Warning, "manual-without-probe", step.name,
            "has no probeCommand, so it can never be marked complete and will block every rerun")
        end

        if step.mutating? && step.probe_command.nil? && unprobeable?(step)
          findings << Finding.new(Diagnostic::Severity::Warning, "no-probe", step.name,
            "#{step.kind} has no observable footprint, so it reruns every time; add a probeCommand")
        end
      end

      findings
    end

    # Kinds Fluxion cannot check on its own. Everything else has a typed probe.
    private def unprobeable?(step : Step) : Bool
      step.is_a?(ShellCommandStep) || step.is_a?(ShellScriptStep) || step.is_a?(ToolchainStep)
    end

    DESTRUCTIVE   = /\brm\s+-[a-z]*[rf]|\bmkfs\b|\bdd\s+if=|>\s*\/dev\/[sn]d/
    PIPE_TO_SHELL = /\b(curl|wget)\b[^|]*\|\s*(sudo\s+)?(ba|z|)sh\b/
    EMBEDDED_SUDO = /(^|\s)sudo\s/

    private def command_findings(step : ShellCommandStep) : Array(Finding)
      findings = [] of Finding

      step.commands.each do |command|
        text = command.shell_command
        next unless text

        if text.matches?(PIPE_TO_SHELL)
          # The whole point of the typed kinds is that a remote script gets
          # pinned and verified; a pipe to a shell opts out of all of it.
          findings << Finding.new(Diagnostic::Severity::Warning, "pipe-to-shell", step.name,
            "pipes downloaded content into a shell; use a shell-script step with a sha256 instead")
        end

        if text.matches?(DESTRUCTIVE)
          findings << Finding.new(Diagnostic::Severity::Warning, "destructive-command", step.name,
            "looks destructive; consider a confirm guard so it needs --yes")
        end

        if text.matches?(EMBEDDED_SUDO)
          findings << Finding.new(Diagnostic::Severity::Info, "embedded-sudo", step.name,
            "embeds sudo; set sudo: true so Fluxion can authenticate once up front")
        end
      end

      findings
    end

    # A single number is what makes a profile's quality comparable over time.
    # Errors would already have failed validation, so only advice is weighed.
    private def score(findings : Array(Finding)) : Int32
      penalty = findings.sum do |finding|
        finding.severity.warning? ? 10 : 3
      end
      Math.max(0, 100 - penalty)
    end

    private def render_text(profile : Profile, findings : Array(Finding)) : Nil
      value = score(findings)
      colour = value >= 90 ? ->(text : String) { Style.green(text) } : value >= 70 ? ->(text : String) { Style.yellow(text) } : ->(text : String) { Style.red(text) }

      puts "Profile: #{Style.bold(profile.name)}"
      puts "Quality score: #{colour.call(value.to_s)}#{Style.dim("/100")}"

      if findings.empty?
        puts
        puts "#{Style.green(Symbols.success)} No lint findings."
        return
      end

      puts
      width = findings.max_of(&.rule.size)
      findings.each do |finding|
        label = finding.severity.warning? ? Style.yellow("warning") : Style.blue("info")
        puts "#{label} #{Style.pad(finding.rule, width)}  #{Style.cyan(finding.step)}: #{finding.message}"
      end
    end

    private def render_json(profile : Profile, findings : Array(Finding)) : Nil
      puts({
        "profileName" => profile.name,
        "score"       => score(findings),
        "findings"    => findings.map do |finding|
          {
            "severity" => finding.severity.label,
            "rule"     => finding.rule,
            "step"     => finding.step,
            "message"  => finding.message,
          }
        end,
      }.to_json)
    end
  end
end
