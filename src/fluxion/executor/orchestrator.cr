module Fluxion::Executor
  # How much a run is allowed to trust prior knowledge.
  enum RunMode
    # Run everything the profile declares, recording what succeeded.
    RecordOnly
    # Skip what state or a probe says is already there.
    SkipInstalled
    # Ignore state entirely and trust only live probes.
    LiveReprobe

    def self.from_options(skip_installed : Bool, reprobe : Bool) : self
      return LiveReprobe if reprobe
      skip_installed ? SkipInstalled : RecordOnly
    end

    def probes? : Bool
      !record_only?
    end

    def trusts_state? : Bool
      skip_installed?
    end
  end

  # Options for one run.
  struct RunOptions
    getter mode : RunMode

    # Emit what would happen without doing any of it.
    getter? dry_run : Bool

    # Probe and report, installing nothing.
    getter? probe_only : Bool

    # Approves items that declared `confirm`. Fluxion never prompts for these
    # interactively — a run that pauses for input is a run that hangs in CI.
    getter? approved : Bool

    # Restrict the run to these phases.
    getter only_phases : Array(String)

    # Skip every phase before this one.
    getter from_phase : String?

    getter profile_name : String

    def initialize(
      @mode : RunMode = RunMode::RecordOnly,
      @dry_run : Bool = false,
      @probe_only : Bool = false,
      @approved : Bool = false,
      @only_phases : Array(String) = [] of String,
      @from_phase : String? = nil,
      @profile_name : String = "default",
    )
    end

    # True when nothing may touch the host.
    def read_only? : Bool
      @dry_run || @probe_only
    end
  end

  # What a finished run amounted to.
  #
  # A class rather than a struct: it is threaded through phase and step execution
  # and mutated there, and a struct would be copied at each call so every
  # increment would be lost.
  class RunSummary
    property succeeded = 0
    property failed = 0
    property skipped = 0
    property dry_run = 0
    property paused = 0

    # Phases that failed, and phases blocked by a failed dependency.
    property failed_phases = [] of String
    property blocked_phases = [] of String

    # Where to resume from, when the run stopped early.
    property next_phase : String?

    def initialize
    end

    def record(result : StepResult) : Nil
      case result
      when StepResult::Success then @succeeded += 1
      when StepResult::Failure then @failed += 1
      when StepResult::Skipped then @skipped += 1
      when StepResult::DryRun  then @dry_run += 1
      when StepResult::Paused  then @paused += 1
      end
    end

    def ok? : Bool
      @failed.zero? && @failed_phases.empty?
    end

    def to_s(io : IO) : Nil
      io << "ok=" << @succeeded << " failed=" << @failed << " skipped=" << @skipped
      io << " dry_run=" << @dry_run << " paused=" << @paused
    end
  end

  # Runs a profile.
  #
  # Ordering, skip decisions, failure propagation, and cancellation all live
  # here so the step executors stay ignorant of everything except their own
  # commands. That is what lets `dry-run` and `apply` be the same traversal
  # with one flag different.
  class Orchestrator
    getter runner : ShellRunner
    getter executors : ExecutorRegistry
    getter probes : ProbeRegistry

    def initialize(
      @runner : ShellRunner,
      @executors : ExecutorRegistry = ExecutorRegistry.default,
      @probes : ProbeRegistry = ProbeRegistry.default,
      @state : State::Store? = nil,
    )
    end

    def run(profile : Profile, options : RunOptions, listener : ExecutionListener,
            cancellation : CancellationSignal = CancellationSignal.new) : RunSummary
      summary = RunSummary.new
      phases = select_phases(profile, options)
      recorder = Recorder.new(@state, options)

      # Buffered state is flushed even when an error escapes the loop below.
      # `Recorder` deliberately holds every successful item in memory and writes
      # once, so without this a run that installed fifty packages and then hit
      # an unexpected failure recorded none of them — leaving
      # `--skip-already-installed` useless exactly when it matters most, and no
      # resume point for a run that got most of the way through.
      begin
        # A source setup configures a repository the packages that follow depend
        # on, so it runs first and a failure there stops the run.
        unless run_source_setups(profile, options, listener, summary, cancellation, recorder)
          return summary
        end

        run_phases(phases, options, listener, summary, cancellation, recorder)
        recorder.resume_at(nil) if summary.next_phase.nil? && summary.ok?
      ensure
        recorder.flush
      end

      summary
    end

    # The phase traversal proper: ordering, blocking, fingerprint skips, and
    # what each outcome means for the rest of the run.
    private def run_phases(phases : Array(Phase), options : RunOptions,
                           listener : ExecutionListener, summary : RunSummary,
                           cancellation : CancellationSignal, recorder : Recorder) : Nil
      completed = Set(String).new

      phases.each do |phase|
        if cancellation.cancelled?
          summary.next_phase = phase.name
          listener.on_event(ExecutionEvent.cancelled(phase.name, phase.name))
          break
        end

        blocked_by = phase.depends_on.find { |dependency| summary.failed_phases.includes?(dependency) || summary.blocked_phases.includes?(dependency) }
        if blocked_by
          summary.blocked_phases << phase.name
          listener.on_event(ExecutionEvent.phase_blocked(phase.name, blocked_by))
          next
        end

        fingerprint = State::Fingerprint.of(phase)
        if recorder.already_completed?(phase, fingerprint)
          # A completed phase is only skipped while its fingerprint still
          # matches, so editing a package list makes it run again rather than
          # being silently considered done.
          listener.on_event(ExecutionEvent.phase_started(phase.name))
          listener.on_event(ExecutionEvent.phase_completed(phase.name))
          completed << phase.name
          next
        end

        outcome = run_phase(phase, options, listener, summary, cancellation, recorder)
        completed << phase.name

        case outcome
        in PhaseOutcome::Completed
          recorder.phase_completed(phase, fingerprint)
          next
        in PhaseOutcome::Failed
          recorder.phase_failed(phase, fingerprint)
          summary.failed_phases << phase.name
          listener.on_event(ExecutionEvent.phase_failed(phase.name))
          next
        in PhaseOutcome::Halted
          # A logout checkpoint or an interrupt: state is written and a resume
          # point recorded, then the run stops cleanly.
          summary.next_phase = phases[(phases.index(phase) || 0) + 1]?.try(&.name)
          recorder.resume_at(summary.next_phase)
          break
        in PhaseOutcome::Cancelled
          summary.next_phase = phase.name
          recorder.resume_at(phase.name)
          break
        end
      end
    end

    # Buffers state changes and writes them once.
    #
    # Writing per item would multiply a large profile's run by hundreds of
    # fsyncs; buffering keeps the file consistent with what actually happened
    # while touching the disk once. Nothing is recorded for a read-only run —
    # a dry run that claimed work was done would make the next real run skip it.
    private class Recorder
      def initialize(@store : State::Store?, @options : RunOptions)
        @document = nil.as(State::Document?)
        @dirty = false
      end

      def already_completed?(phase : Phase, fingerprint : String) : Bool
        return false unless @options.mode.trusts_state?
        document.try(&.phase_completed?(phase.name, fingerprint)) || false
      end

      # What a prior run recorded about this item, if anything.
      #
      # Answered from the document the recorder already holds. The store's own
      # lookup re-reads and re-parses the whole state file on every call, so
      # asking it once per item made a run cost a file read and a JSON parse
      # per package — the same mistake buffering the writes here avoids.
      def recorded(item : ModuleItem) : InstallationStatus::InstalledFromState?
        record = document.try(&.find(item.step_name, item.key, item.item_type.json_name))
        return unless record
        InstallationStatus::InstalledFromState.new(item.key, record.completed_at, record.version)
      end

      def item_succeeded(item : ModuleItem, result : StepResult::Success) : Nil
        return unless recording?
        document.try do |state|
          state.record(State::ItemRecord.new(
            profile: @options.profile_name,
            step: item.step_name,
            item_key: item.key,
            item_type: item.item_type.json_name,
            completed_at: Time.utc,
            version: result.detected_version,
            checksum: result.checksum,
          ))
          @dirty = true
        end
      end

      def phase_completed(phase : Phase, fingerprint : String) : Nil
        record_phase(phase, "completed", fingerprint)
      end

      def phase_failed(phase : Phase, fingerprint : String) : Nil
        record_phase(phase, "failed", fingerprint)
      end

      def resume_at(phase : String?) : Nil
        return unless recording?
        document.try do |state|
          state.next_phase = phase
          @dirty = true
        end
      end

      def flush : Nil
        return unless @dirty
        store = @store
        state = @document
        return unless store && state
        store.save(state)
      rescue ExecutionError
        # A run that installed everything correctly should not be reported as
        # failed because the bookkeeping could not be written; the next run
        # simply re-probes.
      end

      private def record_phase(phase : Phase, status : String, fingerprint : String) : Nil
        return unless recording?
        document.try do |state|
          state.record(State::PhaseRecord.new(phase.name, status, Time.utc, fingerprint))
          @dirty = true
        end
      end

      private def recording? : Bool
        !@options.read_only? && !@store.nil?
      end

      private def document : State::Document?
        return @document if @document
        store = @store
        return unless store
        @document = store.load(@options.profile_name)
      rescue ExecutionError
        # An unreadable state file is not evidence about the host, so the run
        # continues with live probes and simply records nothing.
        nil
      end
    end

    private enum PhaseOutcome
      Completed
      Failed
      Halted
      Cancelled
    end

    private def run_phase(phase : Phase, options : RunOptions, listener : ExecutionListener,
                          summary : RunSummary, cancellation : CancellationSignal,
                          recorder : Recorder) : PhaseOutcome
      listener.on_event(ExecutionEvent.phase_started(phase.name))
      failed = false

      phase.steps.each do |step|
        return PhaseOutcome::Cancelled if cancellation.cancelled?

        # An interrupt is a control step, not work: it records where to resume
        # and stops, rather than running anything.
        #
        # A preview describes it instead of obeying it. Stopping here would
        # leave everything after the checkpoint undescribed, which is the
        # opposite of what a dry run is for.
        if step.is_a?(InterruptStep)
          next preview_interrupt(step, listener, summary) if options.read_only?
          halt(step, listener, summary)
          return PhaseOutcome::Halted
        end

        step_failed = run_step(step, options, listener, summary, cancellation, recorder)
        failed ||= step_failed
        return PhaseOutcome::Failed if step_failed && !phase.continue_on_step_error?
      end

      return PhaseOutcome::Failed if failed

      listener.on_event(ExecutionEvent.phase_completed(phase.name))

      policy = phase.restart_policy
      if policy.is_a?(RestartPolicy::PromptLogout)
        listener.on_event(ExecutionEvent.restart_required(phase.name, policy.message))
        return PhaseOutcome::Halted
      end

      PhaseOutcome::Completed
    end

    private def preview_interrupt(step : InterruptStep, listener : ExecutionListener, summary : RunSummary) : Nil
      result = StepResult::DryRun.new(step.name,
        ["interrupt", step.name, "exit", step.exit_code.to_s, "—", step.message])
      listener.on_event(ExecutionEvent.item_started(step.name, step.name))
      listener.on_event(ExecutionEvent.item_completed(step.name, step.name, result))
      summary.record(result)
    end

    private def halt(step : InterruptStep, listener : ExecutionListener, summary : RunSummary) : Nil
      message = String.build do |io|
        io << step.message
        step.instructions.each { |instruction| io << ' ' << instruction }
      end

      result = StepResult::Paused.new(step.name, message, nil, step.exit_code)
      listener.on_event(ExecutionEvent.item_started(step.name, step.name))
      listener.on_event(ExecutionEvent.item_completed(step.name, step.name, result))
      summary.record(result)
    end

    # Returns true when the step should be treated as failed.
    private def run_step(step : Step, options : RunOptions, listener : ExecutionListener,
                         summary : RunSummary, cancellation : CancellationSignal,
                         recorder : Recorder? = nil) : Bool
      executor = @executors.for(step)
      unless executor
        listener.on_event(ExecutionEvent.step_started(step.name))
        result = StepResult::Failure.new(step.name, "no executor for step kind '#{step.kind}'", 1)
        listener.on_event(ExecutionEvent.item_completed(step.name, step.name, result))
        listener.on_event(ExecutionEvent.step_completed(step.name))
        summary.record(result)
        return true
      end

      listener.on_event(ExecutionEvent.step_started(step.name))
      any_failed = false

      begin
        executor.items(step).each do |item|
          break if cancellation.cancelled?

          result = run_item(step, item, executor, options, listener, recorder)
          summary.record(result)
          recorder.try(&.item_succeeded(item, result)) if result.is_a?(StepResult::Success)
          next unless result.is_a?(StepResult::Failure)

          any_failed = true
          break unless step.continue_on_error?
        end
      ensure
        listener.on_event(ExecutionEvent.step_completed(step.name))
      end

      any_failed
    end

    private def run_item(step : Step, item : ModuleItem, executor : StepExecutor,
                         options : RunOptions, listener : ExecutionListener,
                         recorder : Recorder? = nil) : StepResult
      listener.on_event(ExecutionEvent.item_started(step.name, item.key))

      if decision = skip_decision(item, options, recorder)
        result = StepResult::Skipped.new(item.key, decision.to_s)
        listener.on_event(ExecutionEvent.item_completed(step.name, item.key, result))
        return result
      end

      if options.read_only?
        result = executor.preview(step, item)
        listener.on_event(ExecutionEvent.item_completed(step.name, item.key, result))
        return result
      end

      if step_requires_approval?(step, item) && !options.approved?
        result = StepResult::Failure.new(item.key,
          "explicit confirmation required; re-run with --yes", 2)
        listener.on_event(ExecutionEvent.item_completed(step.name, item.key, result))
        return result
      end

      result = executor.execute(step, item, @runner) do |line|
        listener.on_event(ExecutionEvent.item_output(step.name, item.key, line))
      end

      listener.on_event(ExecutionEvent.item_completed(step.name, item.key, result))
      listener.on_event(ExecutionEvent.error(step.name, item.key, result)) if result.is_a?(StepResult::Failure)
      result
    end

    # Whether this item can be skipped, and on what evidence.
    private def skip_decision(item : ModuleItem, options : RunOptions,
                              recorder : Recorder?) : InstallationStatus?
      return unless options.mode.probes?

      if options.mode.trusts_state?
        if recorded = recorder.try(&.recorded(item))
          return recorded
        end
      end

      status = @probes.probe(item, @runner)
      status.installed? ? status : nil
    end

    # `confirm` items need explicit approval. Fluxion does not prompt for them
    # in either plain or TUI mode: a run that waits for input is a run that
    # hangs unattended.
    private def step_requires_approval?(step : Step, item : ModuleItem) : Bool
      case step
      when ShellCommandStep
        step.commands.any? { |command| command.name == item.key && command.confirmation_required? }
      when ShellScriptStep
        step.scripts.any? { |script| script.name == item.key && script.confirmation_required? }
      else
        false
      end
    end

    private def select_phases(profile : Profile, options : RunOptions) : Array(Phase)
      phases = profile.ordered_phases

      unless options.only_phases.empty?
        unknown = options.only_phases.reject { |name| profile.phase?(name) }
        unless unknown.empty?
          raise ExecutionError.new(
            "Unknown phase#{"s" if unknown.size != 1}: #{unknown.join(", ")}. " \
            "Valid phases: #{profile.phases.map(&.name).join(", ")}")
        end
        return phases.select { |phase| options.only_phases.includes?(phase.name) }
      end

      if from = options.from_phase
        index = phases.index { |phase| phase.name == from }
        unless index
          raise ExecutionError.new(
            "Unknown phase: #{from}. Valid phases: #{profile.phases.map(&.name).join(", ")}")
        end
        return phases[index..]
      end

      phases
    end

    private def run_source_setups(profile : Profile, options : RunOptions, listener : ExecutionListener,
                                  summary : RunSummary, cancellation : CancellationSignal,
                                  recorder : Recorder? = nil) : Bool
      profile.source_setups.each do |setup|
        return false if cancellation.cancelled?

        executor = @executors.for(setup.step)
        unless executor
          # A source setup Fluxion cannot perform would leave later package
          # installs pointing at a repository that was never configured, so it
          # stops the run rather than being noted and skipped.
          listener.on_event(ExecutionEvent.step_started(setup.name))
          result = StepResult::Failure.new(setup.name,
            "no executor for source kind '#{setup.step.kind}'", 1)
          listener.on_event(ExecutionEvent.item_completed(setup.name, setup.name, result))
          listener.on_event(ExecutionEvent.step_completed(setup.name))
          summary.record(result)
          return options.read_only?
        end

        return false if run_step(setup.step, options, listener, summary, cancellation, recorder) && !options.read_only?
      end

      true
    end
  end
end
