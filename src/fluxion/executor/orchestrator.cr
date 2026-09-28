module Fluxion::Executor
  # Runs a profile.
  #
  # Ordering, skip decisions, failure propagation, and cancellation all live
  # here so the step executors stay ignorant of everything except their own
  # commands. That is what lets `dry-run` and `apply` be the same traversal
  # with one flag different.
  #
  # The orchestrator itself is reusable and holds only the collaborators it was
  # built with. Everything that belongs to one particular run — the options, the
  # listener, the summary being filled in, the cancellation signal, the state
  # recorder — lives on `Traversal`, which is created per run and thrown away
  # after it.
  #
  # Package batching lives in step_batch.cr and the state `Recorder` in
  # orchestrator_recorder.cr; both reopen this class.
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
      phases = select_phases(profile, options)
      recorder = Recorder.new(@state, options)

      Traversal.new(@runner, @executors, @probes, options, listener, cancellation, recorder)
        .walk(profile, phases)
    end

    private def select_phases(profile : Profile, options : RunOptions) : Array(Phase)
      phases = profile.ordered_phases

      unless options.only_phases.empty?
        unknown = options.only_phases.reject { |name| profile.phase?(name) }
        unless unknown.empty?
          raise ExecutionError.new(
            "Unknown #{Text.singular_or_plural(unknown.size, "phase")}: #{unknown.join(", ")}. " \
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

    # One run of one profile.
    #
    # Every method below used to be a private method on `Orchestrator` taking
    # the same five arguments — options, listener, summary, cancellation,
    # recorder — and passing them on to the next one. Six methods carried that
    # convoy, which made every signature three lines long, made the one genuine
    # argument of each method hard to pick out among the passengers, and left
    # `recorder` typed as nilable purely so the signatures were easier to write.
    # Holding them as fields of an object that exists for the length of one run
    # says the same thing once.
    private class Traversal
      def initialize(
        @runner : ShellRunner,
        @executors : ExecutorRegistry,
        @probes : ProbeRegistry,
        @options : RunOptions,
        @listener : ExecutionListener,
        @cancellation : CancellationSignal,
        @recorder : Recorder,
      )
        @summary = RunSummary.new
        @batch = StepBatch.new
        @phase_changed_host = false
      end

      def walk(profile : Profile, phases : Array(Phase)) : RunSummary
        # Buffered state is flushed even when an error escapes the traversal
        # below. `Recorder` deliberately holds every successful item in memory
        # and writes once, so without this a run that installed fifty packages
        # and then hit an unexpected failure recorded none of them — leaving
        # `--skip-already-installed` useless exactly when it matters most, and
        # no resume point for a run that got most of the way through.
        begin
          # A source setup configures a repository the packages that follow
          # depend on, so it runs first and a failure there stops the run.
          return @summary unless source_setups_succeeded?(profile)

          run_phases(phases)

          # Clearing the resume point says "there is nothing left to do". A
          # cancelled run reaches here with no phases selected — a profile whose
          # every phase was filtered out — and has plenty left to do.
          if @summary.next_phase.nil? && @summary.ok? && !@cancellation.cancelled?
            @recorder.resume_at(nil)
          end
        ensure
          @recorder.flush
        end

        @summary
      end

      # The phase traversal proper: ordering, blocking, fingerprint skips, and
      # what each outcome means for the rest of the run.
      private def run_phases(phases : Array(Phase)) : Nil
        phases.each do |phase|
          if @cancellation.cancelled?
            cancel_at(phase.name)
            break
          end

          if blocked_by = blocking_dependency(phase)
            @summary.blocked_phases << phase.name
            @listener.on_event(ExecutionEvent.phase_blocked(phase.name, blocked_by))
            next
          end

          fingerprint = State::Fingerprint.of(phase)
          if @recorder.already_completed?(phase, fingerprint)
            # A completed phase is only skipped while its fingerprint still
            # matches, so editing a package list makes it run again rather than
            # being silently considered done.
            @listener.on_event(ExecutionEvent.phase_started(phase.name))
            @listener.on_event(ExecutionEvent.phase_completed(phase.name))
            next
          end

          outcome = run_phase(phase)
          settle_logout(phase, outcome)
          case outcome
          in PhaseOutcome::Completed
            @recorder.phase_completed(phase, fingerprint)
            next
          in PhaseOutcome::Failed
            @recorder.phase_failed(phase, fingerprint)
            @summary.failed_phases << phase.name
            @listener.on_event(ExecutionEvent.phase_failed(phase.name))
            next
          in PhaseOutcome::LogoutRequired
            # The phase ran to the end, so it is recorded as completed like any
            # other: the documented contract of `prompt-logout`. Without this
            # the phase was never marked done, so every later run re-ran it and
            # asked for a logout again, and `--skip-already-installed` could
            # never skip it.
            @recorder.phase_completed(phase, fingerprint)
            @summary.logout_required = true
            stop_before_next(phases, phase)
            break
          in PhaseOutcome::Halted
            # An interrupt step: a resume point is recorded, then the run stops
            # cleanly.
            stop_before_next(phases, phase)
            break
          in PhaseOutcome::Cancelled
            cancel_at(phase.name)
            break
          end
        end
      end

      private def stop_before_next(phases : Array(Phase), phase : Phase) : Nil
        @summary.next_phase = phases[(phases.index(phase) || 0) + 1]?.try(&.name)
        @recorder.resume_at(@summary.next_phase)
      end

      # The single exit for cancellation, so every path that notices the signal
      # records the same resume point and announces it the same way.
      #
      # The two arms above used to do half of this each: the one between phases
      # emitted the event without writing the resume point to the state file,
      # and the one for a phase interrupted mid-flight wrote the resume point
      # without emitting anything. The second is the path a real Ctrl-C almost
      # always takes — the signal arrives while a step is running, not in the
      # window between two phases — and `ExecutionEvent.cancelled` is the only
      # thing that makes `CLI::Reporter` print "Stopped at your request; state
      # was saved" and the TUI show its cancellation notice. So the common
      # interruption saved a resume point that nothing ever told the user about.
      private def cancel_at(phase_name : String) : Nil
        @summary.next_phase = phase_name
        @recorder.resume_at(phase_name)
        @listener.on_event(ExecutionEvent.cancelled(phase_name, phase_name))
      end

      # The dependency that stops this phase running, or nil.
      #
      # A phase blocked by one that was itself blocked is blocked too, which is
      # what keeps a failure early on from being followed by a cascade of steps
      # running against a machine that is not in the state they assume.
      private def blocking_dependency(phase : Phase) : String?
        phase.depends_on.find do |dependency|
          @summary.failed_phases.includes?(dependency) ||
            @summary.blocked_phases.includes?(dependency)
        end
      end

      private def run_phase(phase : Phase) : PhaseOutcome
        @listener.on_event(ExecutionEvent.phase_started(phase.name))
        failed = false
        @phase_changed_host = false

        phase.steps.each do |step|
          return PhaseOutcome::Cancelled if @cancellation.cancelled?

          # An interrupt is a control step, not work: it records where to resume
          # and stops, rather than running anything.
          #
          # A preview describes it instead of obeying it. Stopping here would
          # leave everything after the checkpoint undescribed, which is the
          # opposite of what a dry run is for.
          if step.is_a?(InterruptStep)
            next preview_interrupt(step) if @options.read_only?
            halt(step)
            return PhaseOutcome::Halted
          end

          step_failed = step_failed?(step)
          failed ||= step_failed

          # Asked after every step, including the last, because the check at the
          # top of the loop cannot see a cancellation that arrived *during* a
          # step: `step_failed?` abandons its item loop on the signal and
          # reports `false` — nothing failed — which is indistinguishable from
          # every item having run. Without this the phase would be announced and
          # recorded as completed, fingerprint and all, and the next
          # `--skip-already-installed` run would skip the items that never ran.
          #
          # It comes before the `Failed` return because a signal that arrives
          # during a step which also had a failed item is still a stop the user
          # asked for: the `Failed` arm in `run_phases` records no resume point,
          # while a phase stopped part-way through has to be resumable from
          # itself.
          return PhaseOutcome::Cancelled if @cancellation.cancelled?
          return PhaseOutcome::Failed if step_failed && !phase.continue_on_step_error?
        end

        # Before the logout branch below for the same reason: the `LogoutRequired` arm
        # points the resume at the phase *after* this one.
        return PhaseOutcome::Failed if failed

        @listener.on_event(ExecutionEvent.phase_completed(phase.name))

        # A phase that ran nothing has nothing for the user to log out of: every
        # item skipped on a probe or on state, or only asserts re-checked. It
        # used to ask anyway, so `--re-probe` (which never skips a phase whole)
        # and any phase holding an assert (never skipped whole either) stopped
        # at the checkpoint with exit 75 on every run of a converged host.
        # Unless an earlier run changed the host and stopped before the end of
        # the phase: that logout is still owed (see `settle_logout`).
        policy = phase.restart_policy
        if policy.is_a?(RestartPolicy::PromptLogout) && (@phase_changed_host || @recorder.logout_owed?(phase))
          @listener.on_event(ExecutionEvent.restart_required(phase.name, policy.message))
          return PhaseOutcome::LogoutRequired
        end

        PhaseOutcome::Completed
      end

      private def preview_interrupt(step : InterruptStep) : Nil
        result = StepResult::DryRun.new(step.name,
          ["interrupt", step.name, "exit", step.exit_code.to_s, "—", step.message])
        report_single_item(step.name, result)
      end

      private def halt(step : InterruptStep) : Nil
        message = String.build do |io|
          io << step.message
          step.instructions.each { |instruction| io << ' ' << instruction }
        end

        report_single_item(step.name, StepResult::Paused.new(step.name, message, step.exit_code))
      end

      # Returns true when the step should be treated as failed.
      private def step_failed?(step : Step) : Bool
        executor = @executors.for(step)
        return report_missing_executor(step.name, "step", step.kind) unless executor

        @listener.on_event(ExecutionEvent.step_started(step.name))
        any_failed = false
        items = executor.items(step)
        @batch = StepBatch.new

        begin
          items.each_with_index do |item, index|
            if @cancellation.cancelled?
              settle_covered(step, executor, items[index..])
              break
            end

            result = run_item(step, item, executor, items[(index + 1)..])
            record(step, item, result)
            next unless result.is_a?(StepResult::Failure)

            any_failed = true
            next if step.continue_on_error?
            settle_covered(step, executor, items[(index + 1)..])
            break
          end
        ensure
          @listener.on_event(ExecutionEvent.step_completed(step.name))
        end

        any_failed
      end

      # `later` is the rest of the step's items, which a batch may take on.
      private def run_item(step : Step, item : StepItem, executor : StepExecutor,
                           later : Array(StepItem)) : StepResult
        @listener.on_event(ExecutionEvent.item_started(step.name, item.key))

        # Done by a batch an earlier item ran, or described by its preview.
        if @batch.covers?(item)
          result = @options.read_only? ? StepResult::DryRun.new(item.key, [] of String) : StepResult::Success.new(item.key, Time::Span.zero)
          return completed(step.name, item.key, result)
        end

        if decision = skip_decision(item)
          return completed(step.name, item.key, StepResult::Skipped.new(item.key, decision.to_s))
        end

        batch = plan_batch(step, item, executor, later)

        if @options.read_only?
          preview = batch ? StepResult::DryRun.new(item.key, batch[0].preview) : executor.preview(step, item)
          @batch.cover(batch[1]) if batch
          return completed(step.name, item.key, preview)
        end

        if step.requires_approval?(item.key) && !@options.approved?
          return completed(step.name, item.key, StepResult::Failure.new(item.key,
            "explicit confirmation required; re-run with --yes", 2))
        end

        if batch && (installed = run_batch(step, item, *batch))
          return completed(step.name, item.key, installed)
        end

        # The one place a `Fluxion::Error` from an executor becomes a failed
        # item.
        #
        # Twelve executors rescue it themselves and return a Failure, while the
        # base `execute` does not — so whether a trust or execution error failed
        # one item or unwound the whole run depended on whether that kind
        # happened to override `execute`. Catching it here gives every kind the
        # same contract, and leaves the ones that already rescue doing no harm.
        result = begin
          executor.execute(step, item, @runner) do |line|
            @listener.on_event(ExecutionEvent.item_output(step.name, item.key, line))
          end
        rescue error : Error
          StepResult::Failure.new(item.key, error.message || error.class.name, 1)
        end

        completed(step.name, item.key, result)
        @listener.on_event(ExecutionEvent.error(step.name, item.key, result)) if result.is_a?(StepResult::Failure)
        result
      end

      # Announces an item's outcome and hands it back, so the callers above read
      # as "this is what happened" rather than as three lines of event plumbing
      # repeated once per branch.
      private def completed(step_name : String, key : String, result : StepResult) : StepResult
        @listener.on_event(ExecutionEvent.item_completed(step_name, key, result))
        result
      end

      # Whether this item can be skipped, and on what evidence.
      #
      # Remembered for the length of the step, because planning a batch asks
      # it of every later item before those items are reached, and a batch
      # that has just installed them must not be answered by a fresh probe
      # that would call them skipped.
      private def skip_decision(item : StepItem) : InstallationStatus?
        return unless @options.mode.probes?

        @batch.decisions.fetch(item.key) do
          @batch.decisions[item.key] = decide_skip(item)
        end
      end

      private def decide_skip(item : StepItem) : InstallationStatus?
        if recorded = @recorder.recorded(item)
          return recorded
        end

        status = probe(item)
        status.installed? ? status : nil
      end

      # A step's own `probeCommand` answers for the whole step, so it is asked
      # once, at the first item that needs it — before any item of the step
      # has run, since every item is decided before it runs — and that answer
      # stands for the rest of the step. Asked again per item, a probe that the
      # first script made true reported the scripts after it as already
      # installed, and they never ran.
      private def probe(item : StepItem) : InstallationStatus
        return @probes.probe(item, @runner) unless @probes.answers_for_step?(item)

        @batch.step_probe ||= @probes.probe(item, @runner)
      end

      # `confirm` items need explicit approval. Fluxion does not prompt for them
      # in either plain or TUI mode: a run that waits for input is a run that
      # hangs unattended.

      # False when a source setup failed, in which case the caller stops: the
      # packages that follow depend on the repository these configure.
      #
      # Cancellation deliberately does not answer false here. It stops the
      # remaining setups but lets the caller carry on to `run_phases`, which
      # owns cancellation: its first check records the resume point and emits
      # the `Cancelled` event. Reporting cancellation as "the setups did not
      # succeed" made `walk` return immediately instead, so a run interrupted
      # during its source setups was the one cancellation that saved no resume
      # point and told the user nothing.
      #
      # Named as a predicate, and for success, because its sibling
      # `step_failed?` returns true for the opposite outcome — two bare `Bool`s
      # with opposite polarity and verb names read identically at the call site.
      private def source_setups_succeeded?(profile : Profile) : Bool
        profile.source_setups.each do |setup|
          break if @cancellation.cancelled?

          unless @executors.for(setup.step)
            # A source setup Fluxion cannot perform would leave later package
            # installs pointing at a repository that was never configured, so it
            # stops the run rather than being noted and skipped.
            report_missing_executor(setup.name, "source", setup.step.kind)
            return @options.read_only?
          end

          if step_failed?(setup.step) && !@options.read_only?
            # A setup that failed *because* the user interrupted it is a
            # cancellation, not a failure, and belongs to `run_phases` like
            # every other one.
            break if @cancellation.cancelled?
            return false
          end
        end

        true
      end

      # Reports a kind nothing can carry out as a failed step of one item, and
      # returns true so a caller asking "did this fail?" can hand it straight
      # back. Both callers — an unknown step kind and an unknown source-setup
      # kind — reported this identically before; the only thing that differed
      # was the noun in the message.
      private def report_missing_executor(name : String, noun : String, kind : String) : Bool
        result = StepResult::Failure.new(name, "no executor for #{noun} kind '#{kind}'", 1)

        @listener.on_event(ExecutionEvent.step_started(name))
        @listener.on_event(ExecutionEvent.item_completed(name, name, result))
        @listener.on_event(ExecutionEvent.step_completed(name))
        @summary.record(result)
        true
      end

      # An interrupt: a control step whose whole existence is one result. It is
      # announced as an item so the reporters and the TUI tree, which are built
      # around items, have something to show.
      private def report_single_item(name : String, result : StepResult) : Nil
        @listener.on_event(ExecutionEvent.item_started(name, name))
        @listener.on_event(ExecutionEvent.item_completed(name, name, result))
        @summary.record(result)
      end

      private enum PhaseOutcome
        Completed
        Failed
        LogoutRequired
        Halted
        Cancelled
      end
    end
  end
end
