module Fluxion::Executor
  # Deliberately absent: a NerdFontProbe grepping `fc-list` for the item key.
  #
  # It only worked while an inline font list made each family its own item.
  # With the config delegated the key is a path, which `fc-list` will never
  # report. It also registered ahead of `ConfiguredProbeCommand` with an
  # unconditional `supports?`, so it silently shadowed any `probeCommand` a
  # user wrote on this kind — which is now the only way to make the step
  # skippable.

  # The fallback: whatever the step's own `probeCommand` says.
  #
  # Registered last so a typed probe always wins, but it is what makes kinds
  # with no observable footprint — shell commands, scripts, manual checkpoints
  # — skippable at all.
  #
  # The command belongs to the step, so its answer is the step's: every item
  # of the step is done, or none is.
  class ConfiguredProbeCommand < Probe
    def supports?(item : StepItem) : Bool
      !item.step.try(&.probe_command).nil?
    end

    def answers_for_step? : Bool
      true
    end

    def probe(item : StepItem, runner : ShellRunner) : InstallationStatus
      command = item.step.try(&.probe_command)
      return InstallationStatus::Unknown.new(item.key, "no probeCommand configured") unless command

      result = runner.run(Command.new(["/bin/bash", "-lc", command], timeout: 30.seconds))
      result.success? ? InstallationStatus::InstalledByProbe.new(item.key) : InstallationStatus::NotInstalled.new(item.key)
    end
  end

  # Answers for an assert by running its check.
  #
  # An assert has no footprint a typed probe could look for: whether it holds
  # is only known by asking, and `AssertStep#mutating?` is the promise that
  # asking changes nothing. Without this a report could say nothing about a
  # guard but "unknown", for the guards that hold and the ones that fail alike,
  # and `status --failed` listed every one of them.
  #
  # The argv and working directory are the step's own, so a report checks what
  # `apply` checks. The time allowed is a probe's, not the step's five minutes:
  # a report runs every probe in the profile, and one that could wait that
  # long would make the whole command useless.
  class AssertProbe < Probe
    TIMEOUT = 60.seconds

    def supports?(item : StepItem) : Bool
      item.step.is_a?(AssertStep)
    end

    def probe(item : StepItem, runner : ShellRunner) : InstallationStatus
      assert = item.step.as(AssertStep)
      result = runner.run(Command.new(assert.argv, working_dir: assert.working_dir, timeout: TIMEOUT))
      return InstallationStatus::InstalledByProbe.new(item.key) if result.success?

      # A check that ran out of time has not said the guard fails. The runner
      # reports a timeout in `stderr`, which a finished process never fills,
      # because the two streams are merged into `stdout`.
      if result.exit_code == SystemShellRunner::TIMEOUT_EXIT_CODE && !result.stderr.empty?
        return InstallationStatus::Unknown.new(item.key, "check did not finish within #{TIMEOUT.total_seconds.to_i}s")
      end

      InstallationStatus::NotInstalled.new(item.key)
    end
  end
end
