module Fluxion::Executor
  # The state bookkeeping an `Orchestrator` run writes through, and the
  # traversal methods that feed it. Kept apart from orchestrator.cr so the
  # traversal itself reads in one sitting.
  class Orchestrator
    # Buffers state changes and writes them once.
    #
    # Writing per item would multiply a large profile's run by hundreds of
    # fsyncs; buffering keeps the file consistent with what actually happened
    # while touching the disk once. Nothing is recorded for a read-only run —
    # a dry run that claimed work was done would make the next real run skip it.
    private class Traversal
      # One item's outcome, into the summary, the state and the logout rule.
      private def record(step : Step, item : StepItem, result : StepResult) : Nil
        @summary.record(result)
        @recorder.item_succeeded(item, result) if result.is_a?(StepResult::Success)
        @phase_changed_host ||= changes_host?(step, result)
      end

      # Whether this result did (or, in a preview, would do) work a logout
      # could be needed for. A check changes nothing, so an assert does not
      # count however it ends.
      private def changes_host?(step : Step, result : StepResult) : Bool
        return false if step.rechecked_every_run?
        result.is_a?(StepResult::Success) || result.is_a?(StepResult::DryRun)
      end

      # Carries a prompt-logout phase's owed logout across runs.
      #
      # `@phase_changed_host` only sees this run. A phase that added the user
      # to `docker`, then failed on a later item or was interrupted, asked for
      # nothing; once the user fixed that item and ran again, every item was
      # skipped, so no logout was asked for either, though the group change
      # still needed one. The debt is written to state until a run asks.
      private def settle_logout(phase : Phase, outcome : PhaseOutcome) : Nil
        return unless phase.restart_policy.is_a?(RestartPolicy::PromptLogout)

        if outcome.logout_required?
          @recorder.logout_requested(phase)
        elsif @phase_changed_host && !outcome.completed?
          @recorder.owe_logout(phase)
        end
      end
    end

    private class Recorder
      def initialize(@store : State::Store?, @options : RunOptions)
        @document = nil.as(State::Document?)
        @loaded = false
        @dirty = false
      end

      # A phase holding an assert is never skipped whole: the assert has to run
      # on this apply, and the rest of the phase is still skipped item by item.
      # Nor is one that still owes a logout, or the logout would never be asked.
      def already_completed?(phase : Phase, fingerprint : String) : Bool
        return false unless @options.mode.trusts_state?
        return false if phase.rechecked_every_run?
        return false if logout_owed?(phase)
        document.try(&.phase_completed?(phase.name, fingerprint)) || false
      end

      # What a prior run recorded about this item, if anything.
      #
      # Nothing is answered from state unless the run mode trusts it: a
      # `--reprobe` run must consult live probes only. The rule lives here, next
      # to the state document it governs and beside the same check in
      # `already_completed?`, rather than in the caller — a caller that forgot
      # it would silently get state-trusting behaviour in every mode.
      #
      # Answered from the document the recorder already holds. The store's own
      # lookup re-reads and re-parses the whole state file on every call, so
      # asking it once per item made a run cost a file read and a JSON parse
      # per package — the same mistake buffering the writes here avoids.
      #
      # A check answers for the host as it is now, never from state — including
      # the passes state files written before that rule already hold.
      def recorded(item : StepItem) : InstallationStatus::InstalledFromState?
        return unless @options.mode.trusts_state?
        return if rechecked_every_run?(item)

        record = document.try(&.find(item.step_name, item.key, item.item_type.json_name))
        return unless record

        # A step whose work is decided by something outside its item keys — a
        # delegated tool's config file, a shell script's inline body or remote
        # sha256 pin, a packages step's pre-install actions — records a digest
        # of that input, and is only still done while the digest still matches.
        # That digest is the only thing Fluxion writes to `checksum`, so no new
        # state field is needed; a state file that predates the digest, or one
        # migrated from the Java implementation, reports something else and
        # re-runs the item once.
        expected = item.step.try(&.content_digest)
        return if expected && record.checksum != expected

        InstallationStatus::InstalledFromState.new(item.key, record.completed_at, record.version)
      end

      def item_succeeded(item : StepItem, result : StepResult::Success) : Nil
        return unless recording?
        return if rechecked_every_run?(item)
        document.try do |state|
          state.record(State::ItemRecord.new(
            profile: @options.profile_name,
            step: item.step_name,
            item_key: item.key,
            item_type: item.item_type.json_name,
            completed_at: Time.utc,
            version: result.detected_version,
            checksum: item.step.try(&.content_digest),
          ))
          @dirty = true
        end
      end

      def phase_completed(phase : Phase, fingerprint : String) : Nil
        record_phase(phase, PhaseStatus::Completed, fingerprint)
      end

      def phase_failed(phase : Phase, fingerprint : String) : Nil
        record_phase(phase, PhaseStatus::Failed, fingerprint)
      end

      # Whether an earlier run changed the host in this prompt-logout phase and
      # stopped before the phase finished, so the logout was never asked for.
      # Read in every mode: it is a fact about a request, not about the host.
      def logout_owed?(phase : Phase) : Bool
        document.try(&.pending_logout.includes?(phase.name)) || false
      end

      def owe_logout(phase : Phase) : Nil
        return unless recording?
        document.try do |state|
          next if state.pending_logout.includes?(phase.name)
          state.pending_logout << phase.name
          @dirty = true
        end
      end

      def logout_requested(phase : Phase) : Nil
        return unless recording?
        document.try do |state|
          @dirty = true if state.pending_logout.delete(phase.name)
        end
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

      # Takes the enum rather than a string so the four recordable outcomes come
      # from one place. `PhaseRecord` still stores the spelling, because the
      # state file is a compatibility surface — the Java implementation's files
      # are read directly — and its shape is not ours to change here.
      private def record_phase(phase : Phase, status : PhaseStatus, fingerprint : String) : Nil
        return unless recording?
        document.try do |state|
          state.record(State::PhaseRecord.new(phase.name, status.json_name, Time.utc, fingerprint))
          @dirty = true
        end
      end

      private def recording? : Bool
        !@options.read_only? && !@store.nil?
      end

      private def rechecked_every_run?(item : StepItem) : Bool
        item.step.try(&.rechecked_every_run?) || false
      end

      # The state file, read at most once per run.
      #
      # The flag remembers that the attempt happened, not just that it
      # succeeded: a state file that cannot be read leaves `@document` nil, and
      # guarding on the document alone would send every later caller back to
      # the store to re-read and re-parse the same unreadable file.
      private def document : State::Document?
        return @document if @loaded
        @loaded = true
        store = @store
        return unless store
        @document = store.load(@options.profile_name)
      rescue ExecutionError
        # An unreadable state file is not evidence about the host, so the run
        # continues with live probes and simply records nothing.
        nil
      end
    end
  end
end
