module Fluxion::CLI
  # `fluxion apply` — execute a profile.
  #
  # `dry-run` is the same traversal with mutation switched off, which is what
  # makes the preview trustworthy: it exercises the same ordering, the same
  # skip decisions, and the same command construction as the real run.
  class ApplyCommand < Command
    def name : String
      "apply"
    end

    def summary : String
      "Apply a bootstrap profile"
    end

    def usage : String
      "fluxion apply [-c FILE] [--dry-run] [--phase NAME] [--yes]"
    end

    # Runs with mutation disabled regardless of flags.
    property? forced_dry_run : Bool = false

    @dry_run = false
    @probe_only = false
    @skip_installed = false
    @reprobe = false
    @approved = false
    @stream_output = false
    @only_phases = [] of String
    @from_phase : String?
    @profile_name = "default"

    def register(parser : OptionParser) : Nil
      parser.on("--dry-run", "Show what would happen without changing anything") { @dry_run = true }
      parser.on("--phase=NAME", "Run only these phases (repeatable, or comma-separated)") do |value|
        @only_phases.concat(value.split(',').map(&.strip).reject(&.empty?))
      end
      parser.on("--from-phase=NAME", "Start from this phase, skipping earlier ones") { |value| @from_phase = value }
      parser.on("-y", "--yes", "Approve items that declared confirm") { @approved = true }
      parser.on("--skip-already-installed", "Skip work state or a probe says is done") { @skip_installed = true }
      parser.on("--re-probe", "Ignore saved state and trust only live probes") { @reprobe = true }
      parser.on("--probe-only", "Probe without installing anything") { @probe_only = true }
      parser.on("--show-output", "Echo each command's own output") { @stream_output = true }
      parser.on("--profile=NAME", "State profile name [default: default]") { |value| @profile_name = value }
    end

    def run(arguments : Array(String)) : ExitCode
      parse(arguments)
      profile = load_profile

      dry_run = @dry_run || @forced_dry_run || (profile.policy.dry_run == true)
      options = Executor::RunOptions.new(
        mode: Executor::RunMode.from_options(@skip_installed, @reprobe),
        dry_run: dry_run,
        probe_only: @probe_only,
        approved: @approved,
        only_phases: @only_phases,
        from_phase: @from_phase,
        profile_name: @profile_name,
      )

      # A run that mutates the host as root has no way to drop back to the
      # user's account for the steps that must not be root-owned, so it is
      # refused rather than producing a half-root home directory.
      if !options.read_only? && Host.root?
        raise Failure.external(
          "Refusing to apply as root: run as your own user and let Fluxion escalate per step")
      end

      cancellation = install_interrupt_handler
      orchestrator = Executor::Orchestrator.new(
        Executor::SystemShellRunner.new,
        state: State::Store.new,
      )

      # The TUI needs a real terminal on both ends. In CI, a pipe, or a build
      # tool it is not available regardless of the flag, so a run never blocks
      # on a UI nobody can see.
      if @globals.use_tui? && TUI::App.available?
        return run_with_tui(profile, options, orchestrator, cancellation)
      end

      header(profile, options)
      reporter = Reporter.new(@output, @stream_output)
      summary = orchestrator.run(profile, options, reporter, cancellation)
      reporter.print_summary

      exit_code_for(summary, cancellation, options.read_only?)
    end

    private def run_with_tui(profile : Profile, options : Executor::RunOptions,
                             orchestrator : Executor::Orchestrator,
                             cancellation : CancellationSignal) : ExitCode
      outcome = TUI::App.new(profile, options).run(orchestrator, cancellation)
      # Nil means the user backed out of the selector, which is a decision
      # rather than a failure.
      return ExitCode::Success unless outcome

      exit_code_for(outcome.summary, cancellation, options.read_only?)
    end

    private def header(profile : Profile, options : Executor::RunOptions) : Nil
      mode = if options.probe_only?
               Style.cyan("probe-only")
             elsif options.dry_run?
               Style.cyan("dry-run")
             else
               Style.bold_yellow("live")
             end

      puts "#{Style.bold("Fluxion")} #{Style.dim("·")} #{profile.name} #{Style.dim("·")} #{mode}"
      puts "#{Style.dim("Target:")} #{profile.target}   #{Style.dim("Host:")} #{Host.facts}"
      puts
    end

    # The first interrupt asks for a clean stop at the next item boundary; the
    # second gives up on that and exits, because a user pressing Ctrl-C twice
    # has stopped caring about a tidy shutdown.
    private def install_interrupt_handler : CancellationSignal
      signal = CancellationSignal.new

      Process.on_terminate do |_reason|
        if signal.cancel
          @error_output.puts
          @error_output.puts Style.bold_yellow(
            "Stopping after the current step; press Ctrl-C again to quit now.")
        else
          @error_output.puts Style.red("Interrupted.")
          exit ExitCode::Cancelled.value
        end
      end

      signal
    end

    private def exit_code_for(summary : Executor::RunSummary, cancellation : CancellationSignal,
                              read_only : Bool = false) : ExitCode
      return ExitCode::Cancelled if cancellation.cancelled?
      # A preview never pauses. Reporting 75 for one would tell a script the
      # run stopped at a checkpoint when nothing ran at all.
      return ExitCode::Paused if summary.paused > 0 && !read_only
      return ExitCode::ExternalDependencyError unless summary.ok?
      ExitCode::Success
    end
  end

  # `fluxion dry-run` — apply with mutation switched off.
  #
  # A separate command rather than a flag alias because it is the one people
  # reach for first, and it should be impossible to turn into a real run by
  # editing a single character of a shell history entry.
  class DryRunCommand < ApplyCommand
    def name : String
      "dry-run"
    end

    def summary : String
      "Show what would be executed without making any changes"
    end

    def usage : String
      "fluxion dry-run [-c FILE]"
    end

    def initialize(globals : GlobalOptions = GlobalOptions.new,
                   output : IO = STDOUT,
                   error_output : IO = STDERR)
      super
      self.forced_dry_run = true
    end
  end
end
