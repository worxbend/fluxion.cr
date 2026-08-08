module Fluxion::Executor
  # Turns one step into the work it represents.
  #
  # A step executor exists to produce commands. `dry-run` prints them,
  # `apply` runs them, and `plan --show-commands` previews them — from the same
  # method, so a preview cannot describe something different from what runs.
  #
  # Kinds that need more than a command sequence (a verified download, an
  # atomic install) override `execute` and still supply `commands` for preview.
  abstract class StepExecutor
    abstract def supports?(step : Step) : Bool

    # The items this step tracks. Defaults to what the step itself declares;
    # overridden where execution order differs from declaration order.
    def items(step : Step) : Array(StepItem)
      step.items.map { |item| step_item(step, item) }
    end

    # Commands for one item, in order. Empty means there is nothing to do.
    abstract def commands(step : Step, item : StepItem) : Array(Command)

    # Runs one item. The default runs each command in order and stops at the
    # first that fails, because a later command in a sequence normally assumes
    # the earlier one worked.
    def execute(step : Step, item : StepItem, runner : ShellRunner, &sink : String ->) : StepResult
      run_commands(step, item, runner) { |line| sink.call(line) }
    end

    # Runs this item's commands in order, stopping at the first failure.
    #
    # Named rather than left inline in `execute` so a subclass that adds its
    # own preconditions can still reach it, without depending on where it sits
    # in the hierarchy.
    def run_commands(step : Step, item : StepItem, runner : ShellRunner, &sink : String ->) : StepResult
      started = Time.instant
      sequence = commands(step, item)
      return StepResult::Success.new(item.key, Time.instant - started) if sequence.empty?

      sequence.each do |command|
        result = runner.run(command) { |line| sink.call(line) }
        next if command.success?(result.exit_code)

        return StepResult::Failure.new(
          item.key,
          failure_message(command, result),
          result.exit_code,
          Time.instant - started,
        )
      end

      StepResult::Success.new(item.key, Time.instant - started)
    end

    # What a dry run would do.
    def preview(step : Step, item : StepItem) : StepResult::DryRun
      StepResult::DryRun.new(item.key, commands(step, item).flat_map(&.preview))
    end

    # Success, or a Failure describing what the process reported.
    #
    # The kinds that override `execute` to run one specific tool all ended with
    # this same three-line tail, differing only in the label — nine copies, and
    # so nine chances to drop the elapsed time or the exit code from one of
    # them.
    protected def outcome(item : StepItem, result : ProcessResult,
                          started : Time::Instant, label : String) : StepResult
      elapsed = Time.instant - started
      return StepResult::Success.new(item.key, elapsed) if result.success?

      StepResult::Failure.new(item.key,
        "#{label} exited #{result.exit_code}: #{result.detail}", result.exit_code, elapsed)
    end

    private def failure_message(command : Command, result : ProcessResult) : String
      detail = result.detail
      summary = "#{command.preview.join(' ')} exited #{result.exit_code}"
      detail.empty? ? summary : "#{summary}: #{detail}"
    end

    protected def step_item(step : Step, item : ItemRef) : StepItem
      StepItem.new(step.name, item.key, ItemTypes.for(step), item.display,
        ItemTypes.package_manager_for(step), step)
    end
  end

  # Picks the executor that handles a step.
  class ExecutorRegistry
    getter executors : Array(StepExecutor)

    def initialize(@executors : Array(StepExecutor) = [] of StepExecutor)
    end

    def self.default : self
      new([
        PackagesExecutor.new,
        FlatpakExecutor.new,
        ToolPackagesExecutor.new,
        SdkmanExecutor.new,
        SystemUpdateExecutor.new,
        UserGroupsExecutor.new,
        GitConfigExecutor.new,
        GitRepoExecutor.new,
        SystemdUnitExecutor.new,
        SystemSettingExecutor.new,
        DefaultShellExecutor.new,
        ShellReloadExecutor.new,
        ShellCommandExecutor.new,
        ShellScriptExecutor.new,
        AssertExecutor.new,
        ManualExecutor.new,
        ToolchainExecutor.new,
        OhMyZshExecutor.new,
        FileWriteExecutor.new,
        AptRepositoryExecutor.new,
        RpmStyleRepositoryExecutor.new,
        PacmanRepositoryExecutor.new,
        FlatpakRemoteExecutor.new,
        GpgKeyExecutor.new,
        DotbotExecutor.new,
        NerdFontsExecutor.new,
        BinstallerExecutor.new,
      ] of StepExecutor)
    end

    def <<(executor : StepExecutor) : self
      @executors << executor
      self
    end

    def for(step : Step) : StepExecutor?
      @executors.find(&.supports?(step))
    end
  end
end
