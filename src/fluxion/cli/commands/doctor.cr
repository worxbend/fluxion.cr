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
      "fluxion doctor [-c FILE]"
    end

    enum Level
      Pass
      Warn
      Fail
    end

    record Check, level : Level, name : String, detail : String

    @profile_name = "default"

    def register(parser : OptionParser) : Nil
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

    # Existence only. What is inside belongs to the tool that reads it, and
    # `doctor` answers "can this host run this profile" before a run rather
    # than validating someone else's schema.
    private def delegated_check(step : Step, config : String) : Check
      info = File.info?(config)
      unless info
        # A warning, not a failure. A delegated config is routinely produced by
        # an earlier phase of the same run — `dotfiles-apply` pointing at a
        # repo that `git-repo` clones is the shipped example — and `doctor` is
        # the command you run on the fresh machine before any of that has
        # happened. `lint` already takes this position one screen away.
        return Check.new(Level::Warn, "#{step.kind} config", "#{config} does not exist yet")
      end

      # Existing but not a regular file is unambiguous.
      return Check.new(Level::Fail, "#{step.kind} config", "#{config} is not a regular file") unless info.file?
      Check.new(Level::Pass, "#{step.kind} config", config)
    end

    private def profile_checks(profile : Profile) : Array(Check)
      checks = [] of Check
      checks << Check.new(Level::Pass, "target os", profile.target.to_s)

      seen = Set(String).new
      profile.steps.each do |step|
        step.required_commands.each do |command|
          next unless seen.add?(command)
          checks << command_check(command)
        end

        step.delegated_config.try { |config| checks << delegated_check(step, config) }

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

    private def command_check(command : String, required : Bool = true) : Check
      return Check.new(Level::Pass, "#{command} command", command) if Host.command_exists?(command)
      Check.new(required ? Level::Fail : Level::Warn, "#{command} command", "not found on PATH")
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

    # The only piece of binstaller's schema Fluxion knows, and it is used to
    # decide whether to say anything at all rather than to validate.
    BINSTALLER_API_VERSION = "binstaller.io/v1alpha1"

    # A profile is a hand-written manifest; anything larger is not one, and
    # `lint` should not read an arbitrary file from the profile's directory
    # without a ceiling.
    MAX_DELEGATED_CONFIG_BYTES = 4_i64 * 1024 * 1024

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

    # Fluxion used to refuse a binary download with no digest at parse time.
    # That refusal now lives in binstaller's own `spec.policy.mode: strict`, so
    # this says when a referenced profile is not asking for it.
    #
    # Best-effort and advisory by design: the file belongs to another tool, may
    # not exist yet when `lint` runs, and its schema is not Fluxion's to
    # validate. Anything unreadable or unrecognised is simply not reported.
    private def binstaller_findings(step : BinstallerProfileStep) : Array(Finding)
      findings = [] of Finding

      info = File.info?(step.config)
      return findings unless info && info.file? && info.size <= MAX_DELEGATED_CONFIG_BYTES

      body = File.read(step.config)
      document = YAML.parse(body)
      return findings unless document.as_h?.try(&.[]?(YAML::Any.new("apiVersion"))).try(&.as_s?) == BINSTALLER_API_VERSION

      spec = document.as_h?.try(&.[]?(YAML::Any.new("spec"))).try(&.as_h?)
      mode = spec.try(&.[]?(YAML::Any.new("policy"))).try(&.as_h?)
        .try(&.[]?(YAML::Any.new("mode"))).try(&.as_s?)
      unless mode == "strict"
        findings << Finding.new(Diagnostic::Severity::Warning, "binstaller-not-strict", step.name,
          "#{File.basename(step.config)} does not set spec.policy.mode: strict, " \
          "so missing checksums and mutable URLs are only flagged rather than refused")
      end

      unpinned = spec.try(&.[]?(YAML::Any.new("plan"))).try(&.as_a?).try do |plan|
        plan.compact_map do |entry|
          mapping = entry.as_h?
          next unless mapping
          download = mapping[YAML::Any.new("spec")]?.try(&.as_h?)
            .try(&.[]?(YAML::Any.new("download"))).try(&.as_h?)
          next if download.try(&.[]?(YAML::Any.new("checksum")))
          mapping[YAML::Any.new("name")]?.try(&.as_s?)
        end
      end

      if unpinned && !unpinned.empty?
        findings << Finding.new(Diagnostic::Severity::Warning, "binstaller-unpinned", step.name,
          "#{unpinned.size == 1 ? "1 entry declares" : "#{unpinned.size} entries declare"} " \
          "no checksum: #{unpinned.first(5).join(", ")}")
      end

      findings
    rescue
      # Advisory by contract. The file belongs to another tool, is written by
      # hand, and an empty placeholder or a plan of bare tool names is an
      # ordinary state for it to be in — `YAML::Any#[]` raises rather than
      # returning nil for those, which turned `lint` into a crash with a
      # contextless message naming neither the file nor the step.
      [] of Finding
    end

    private def analyse(profile : Profile) : Array(Finding)
      findings = [] of Finding

      profile.steps.each do |step|
        case step
        when ShellCommandStep
          findings.concat(command_findings(step))
        when ShellScriptStep
          findings.concat(script_findings(step))
          step.scripts.each do |script|
            next unless script.remote?
            findings << Finding.new(Diagnostic::Severity::Info, "remote-script", step.name,
              "runs a remote script; the pinned digest is what makes this reviewable")
          end
        when ManualStep
          next if step.probe_command
          findings << Finding.new(Diagnostic::Severity::Warning, "manual-without-probe", step.name,
            "has no probeCommand, so it can never be marked complete and will block every rerun")
        when BinstallerProfileStep
          findings.concat(binstaller_findings(step))
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
      shell_text_findings(step.name, step.commands.compact_map(&.shell_command))
    end

    # An inline `content:` body is shell text handed straight to an
    # interpreter, so it earns the same reading as a `commands` entry. It used
    # to be invisible here: a body could pipe curl into sh and lint said
    # nothing, while the identical text in a `commands` step was flagged.
    private def script_findings(step : ShellScriptStep) : Array(Finding)
      shell_text_findings(step.name, step.scripts.compact_map(&.content))
    end

    private def shell_text_findings(name : String, texts : Array(String)) : Array(Finding)
      findings = [] of Finding

      texts.each do |text|
        if text.matches?(PIPE_TO_SHELL)
          # The whole point of the typed kinds is that a remote script gets
          # pinned and verified; a pipe to a shell opts out of all of it.
          findings << Finding.new(Diagnostic::Severity::Warning, "pipe-to-shell", name,
            "pipes downloaded content into a shell; use a shell-script step with a sha256 instead")
        end

        if text.matches?(DESTRUCTIVE)
          findings << Finding.new(Diagnostic::Severity::Warning, "destructive-command", name,
            "looks destructive; consider a confirm guard so it needs --yes")
        end

        if text.matches?(EMBEDDED_SUDO)
          findings << Finding.new(Diagnostic::Severity::Info, "embedded-sudo", name,
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
