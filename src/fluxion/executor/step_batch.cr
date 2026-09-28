module Fluxion::Executor
  # Package batching for `Orchestrator::Traversal`: one `apt-get install
  # p1 ... pN` for every item of a step that would run, falling back to one
  # process per item when it fails. Kept apart from orchestrator.cr so the
  # traversal itself reads in one sitting; `run_item` is the only caller.
  class Orchestrator
    private class Traversal
      # The command that installs this item together with every later item of
      # the step that would also run, and those items, or nil when this item
      # runs on its own.
      #
      # Asked once per step, at the first item that can batch: whatever that
      # batch leaves out, or everything after a batch that failed, runs one
      # process per item as before. A batch of one is no batch.
      private def plan_batch(step : Step, item : StepItem, executor : StepExecutor,
                             later : Array(StepItem)) : {Command, Array(StepItem)}?
        return if @batch.planned? || !executor.batches?(step, item)
        @batch.planned = true

        members = [item] + later.select { |other| executor.batches?(step, other) && would_run?(step, other) }
        return if members.size < 2

        executor.batch_command(step, members).try { |command| {command, members} }
      end

      private def would_run?(step : Step, item : StepItem) : Bool
        return false if step.requires_approval?(item.key) && !@options.approved?
        skip_decision(item).nil?
      end

      # Runs a batch on behalf of `item`, which reports its output and its time.
      # Returns nil when the batch failed, and the item then runs on its own
      # like every other member will.
      #
      # A batch that failed because the user interrupted it is not retried one
      # by one: Ctrl-C kills the one-transaction install, and falling back
      # started a fresh `apt-get install` for the first package after the user
      # had asked to stop. The item fails as cancelled instead, and the step's
      # own cancellation check stops the rest.
      private def run_batch(step : Step, item : StepItem, command : Command,
                            members : Array(StepItem)) : StepResult?
        started = Time.instant
        result = @runner.run(command) do |line|
          @listener.on_event(ExecutionEvent.item_output(step.name, item.key, line))
        end

        unless command.success?(result.exit_code)
          return cancelled_batch(item) if @cancellation.cancelled?
          @listener.on_event(ExecutionEvent.item_output(step.name, item.key,
            "installing #{members.size} together exited #{result.exit_code}; installing one at a time"))
          return
        end

        @batch.cover(members)
        StepResult::Success.new(item.key, Time.instant - started)
      rescue Error
        # Whatever went wrong, the per-item path is still there to try, and it
        # reports its own failure properly — unless the user asked to stop.
        @cancellation.cancelled? ? cancelled_batch(item) : nil
      end

      private def cancelled_batch(item : StepItem) : StepResult
        StepResult::Failure.new(item.key, "cancelled", 130)
      end

      # Reports the items of `rest` that a batch already installed, when the
      # step stops before reaching them.
      #
      # A batch member is only reported, counted and recorded when the item
      # loop gets to it. A step that stopped first — the user pressed Ctrl-C
      # while `apt-get install a b c` was finishing and it still exited 0, or
      # an item between the members failed — left `b` and `c` installed but
      # absent from the run summary and from state, so the next
      # `--skip-already-installed` run had to probe them again. Nothing is run
      # here: a covered item only reports what the batch did.
      private def settle_covered(step : Step, executor : StepExecutor, rest : Array(StepItem)) : Nil
        rest.each do |item|
          next unless @batch.covers?(item)
          record(step, item, run_item(step, item, executor, [] of StepItem))
        end
      end

      # What the step being run has decided about batching.
      private class StepBatch
        # Skip decisions already made, by item key; nil means "run it".
        getter decisions = {} of String => InstallationStatus?

        property? planned = false

        # The step's own `probeCommand` answer, once asked.
        property step_probe : InstallationStatus? = nil

        @covered = Set(String).new

        # Items a batch installed, or a previewed batch would install.
        def cover(items : Array(StepItem)) : Nil
          items.each { |member| @covered << member.key }
        end

        def covers?(item : StepItem) : Bool
          @covered.includes?(item.key)
        end
      end
    end
  end
end
