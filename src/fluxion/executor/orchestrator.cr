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

    # Restrict the run to these jobs.
    getter only_jobs : Array(String)

    # Skip every job before this one.
    getter from_job : String?

    getter profile_name : String

    def initialize(
      @mode : RunMode = RunMode::RecordOnly,
      @dry_run : Bool = false,
      @probe_only : Bool = false,
      @approved : Bool = false,
      @only_jobs : Array(String) = [] of String,
      @from_job : String? = nil,
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
  # A class rather than a struct: it is threaded through job and step execution
  # and mutated there, and a struct would be copied at each call so every
  # increment would be lost.
  class RunSummary
    property succeeded = 0
    property failed = 0
    property skipped = 0
    property dry_run = 0
    property paused = 0

    # Jobs that failed, and jobs blocked by a failed dependency.
    property failed_jobs = [] of String
    property blocked_jobs = [] of String

    # Where to resume from, when the run stopped early.
    property next_job : String?

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
      @failed.zero? && @failed_jobs.empty?
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
      jobs = select_jobs(profile, options)
      recorder = Recorder.new(@state, options)

      # A source setup configures a repository the packages that follow depend
      # on, so it runs first and a failure there stops the run.
      unless run_source_setups(profile, options, listener, summary, cancellation, recorder)
        return summary
      end

      completed = Set(String).new

      jobs.each do |job|
        if cancellation.cancelled?
          summary.next_job = job.name
          listener.on_event(ExecutionEvent.cancelled(job.name, job.name))
          break
        end

        blocked_by = job.depends_on.find { |dependency| summary.failed_jobs.includes?(dependency) || summary.blocked_jobs.includes?(dependency) }
        if blocked_by
          summary.blocked_jobs << job.name
          listener.on_event(ExecutionEvent.phase_blocked(job.name, blocked_by))
          next
        end

        fingerprint = State::Fingerprint.of(job)
        if recorder.already_completed?(job, fingerprint)
          # A completed job is only skipped while its fingerprint still
          # matches, so editing a package list makes it run again rather than
          # being silently considered done.
          listener.on_event(ExecutionEvent.phase_started(job.name))
          listener.on_event(ExecutionEvent.phase_completed(job.name))
          completed << job.name
          next
        end

        outcome = run_job(job, options, listener, summary, cancellation, recorder)
        completed << job.name

        case outcome
        in JobOutcome::Completed
          recorder.job_completed(job, fingerprint)
          next
        in JobOutcome::Failed
          recorder.job_failed(job, fingerprint)
          summary.failed_jobs << job.name
          listener.on_event(ExecutionEvent.phase_failed(job.name))
          next
        in JobOutcome::Halted
          # A logout checkpoint or an interrupt: state is written and a resume
          # point recorded, then the run stops cleanly.
          summary.next_job = jobs[(jobs.index(job) || 0) + 1]?.try(&.name)
          recorder.resume_at(summary.next_job)
          break
        in JobOutcome::Cancelled
          summary.next_job = job.name
          recorder.resume_at(job.name)
          break
        end
      end

      recorder.resume_at(nil) if summary.next_job.nil? && summary.ok?
      recorder.flush
      summary
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

      def already_completed?(job : Job, fingerprint : String) : Bool
        return false unless @options.mode.trusts_state?
        document.try(&.job_completed?(job.name, fingerprint)) || false
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

      def job_completed(job : Job, fingerprint : String) : Nil
        record_job(job, "completed", fingerprint)
      end

      def job_failed(job : Job, fingerprint : String) : Nil
        record_job(job, "failed", fingerprint)
      end

      def resume_at(job : String?) : Nil
        return unless recording?
        document.try do |state|
          state.next_job = job
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

      private def record_job(job : Job, status : String, fingerprint : String) : Nil
        return unless recording?
        document.try do |state|
          state.record(State::JobRecord.new(job.name, status, Time.utc, fingerprint))
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

    private enum JobOutcome
      Completed
      Failed
      Halted
      Cancelled
    end

    private def run_job(job : Job, options : RunOptions, listener : ExecutionListener,
                        summary : RunSummary, cancellation : CancellationSignal,
                        recorder : Recorder) : JobOutcome
      listener.on_event(ExecutionEvent.phase_started(job.name))
      failed = false

      job.steps.each do |step|
        return JobOutcome::Cancelled if cancellation.cancelled?

        # An interrupt is a control step, not work: it records where to resume
        # and stops, rather than running anything.
        #
        # A preview describes it instead of obeying it. Stopping here would
        # leave everything after the checkpoint undescribed, which is the
        # opposite of what a dry run is for.
        if step.is_a?(InterruptStep)
          next preview_interrupt(step, listener, summary) if options.read_only?
          halt(step, listener, summary)
          return JobOutcome::Halted
        end

        step_failed = run_step(step, options, listener, summary, cancellation, recorder)
        failed ||= step_failed
        return JobOutcome::Failed if step_failed && !job.continue_on_step_error?
      end

      return JobOutcome::Failed if failed

      listener.on_event(ExecutionEvent.phase_completed(job.name))

      policy = job.restart_policy
      if policy.is_a?(RestartPolicy::PromptLogout)
        listener.on_event(ExecutionEvent.restart_required(job.name, policy.message))
        return JobOutcome::Halted
      end

      JobOutcome::Completed
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

          result = run_item(step, item, executor, options, listener)
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
                         options : RunOptions, listener : ExecutionListener) : StepResult
      listener.on_event(ExecutionEvent.item_started(step.name, item.key))

      if decision = skip_decision(item, options)
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
    private def skip_decision(item : ModuleItem, options : RunOptions) : InstallationStatus?
      return unless options.mode.probes?

      if options.mode.trusts_state?
        if recorded = @state.try(&.find(options.profile_name, item))
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

    private def select_jobs(profile : Profile, options : RunOptions) : Array(Job)
      jobs = profile.ordered_jobs

      unless options.only_jobs.empty?
        unknown = options.only_jobs.reject { |name| profile.job?(name) }
        unless unknown.empty?
          raise ExecutionError.new(
            "Unknown job#{"s" if unknown.size != 1}: #{unknown.join(", ")}. " \
            "Valid jobs: #{profile.jobs.map(&.name).join(", ")}")
        end
        return jobs.select { |job| options.only_jobs.includes?(job.name) }
      end

      if from = options.from_job
        index = jobs.index { |job| job.name == from }
        unless index
          raise ExecutionError.new(
            "Unknown job: #{from}. Valid jobs: #{profile.jobs.map(&.name).join(", ")}")
        end
        return jobs[index..]
      end

      jobs
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
