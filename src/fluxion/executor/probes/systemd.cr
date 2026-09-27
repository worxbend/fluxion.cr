module Fluxion::Executor
  # systemd units, checked against the state the profile asked for.
  class SystemdUnitProbe < Probe
    # Every word `systemctl is-enabled` and `systemctl is-active` can print.
    #
    # The lists exist because the runner folds stderr into stdout, so a
    # systemctl that cannot answer at all — the ordinary case inside a
    # container, where it writes "System has not been booted with systemd as
    # init system (PID 1). Can't operate." and exits 1 — hands this probe a
    # sentence where a state word belongs. Exit codes cannot tell the two
    # apart, because the legitimate `disabled` also exits 1 and `is-active`
    # exits non-zero for the legitimate `inactive` and `failed`. The word
    # itself is the only signal that a question was answered.
    IS_ENABLED_WORDS = %w[enabled enabled-runtime linked linked-runtime alias
      masked masked-runtime static indirect disabled generated transient
      not-found bad bad-setting]

    IS_ACTIVE_WORDS = %w[active reloading inactive deactivating activating
      failed maintenance refreshing unknown]

    def supports?(item : StepItem) : Bool
      item.item_type.systemd_unit?
    end

    def probe(item : StepItem, runner : ShellRunner) : InstallationStatus
      # In a container or an image build there is no systemd, and a profile
      # that mentions units should still be usable there.
      return InstallationStatus::Unknown.new(item.key, "systemctl is not available") unless runner.command_exists?("systemctl")

      step = item.step.as?(SystemdUnitStep)
      unit = step.try(&.units.find { |candidate| candidate.qualified_name == item.key })
      scope = step.try(&.scope) || SystemdScope::System

      enabled = runner.run(Command.new(
        ["systemctl", scope.flag, "is-enabled", item.key], timeout: PROBE_TIMEOUT))
      word = enabled.stdout.lines.first?.try(&.strip) || ""
      unless IS_ENABLED_WORDS.includes?(word)
        # The rejected text, not the exit code, is why this probe gave up —
        # `disabled` exits 1 legitimately, so the code says nothing on its own.
        # The runner merges stderr into stdout, so the text quoted here is the
        # diagnostic systemctl actually produced.
        return InstallationStatus::Unknown.new(item.key,
          "systemctl is-enabled said #{word.inspect} (exit #{enabled.exit_code})")
      end

      return InstallationStatus::InstalledByProbe.new(item.key, word) if unit.nil?

      if unit.masked?
        return word == "masked" ? InstallationStatus::InstalledByProbe.new(item.key, word) : InstallationStatus::NotInstalled.new(item.key)
      end

      if unit.enabled? && !SystemdUnit::ALREADY_ENABLED.includes?(word)
        # Units with no [Install] section cannot be enabled and are reachable
        # as a dependency, so requiring `enabled` of them would never pass.
        return InstallationStatus::InstalledByProbe.new(item.key, word) if SystemdUnit::NOT_ENABLEABLE.includes?(word)
        return InstallationStatus::NotInstalled.new(item.key)
      end

      return InstallationStatus::InstalledByProbe.new(item.key, word) if unit.state.unchanged?

      active = runner.run(Command.new(
        ["systemctl", scope.flag, "is-active", item.key], timeout: PROBE_TIMEOUT))
      state = active.stdout.lines.first?.try(&.strip) || ""
      unless IS_ACTIVE_WORDS.includes?(state)
        return InstallationStatus::Unknown.new(item.key,
          "systemctl is-active said #{state.inspect} (exit #{active.exit_code})")
      end

      # `unknown` is in the vocabulary above even though systemd does not list
      # it among the active states, because `is-active` prints it for a unit it
      # has never heard of; treating that as "not running" is the honest
      # reading, and it is what this probe did before the allowlist existed.
      running = state == "active"

      satisfied = unit.state.started? ? running : !running
      satisfied ? InstallationStatus::InstalledByProbe.new(item.key, word) : InstallationStatus::NotInstalled.new(item.key)
    end
  end
end
