module Fluxion::TUI
  # Which parts of a profile the user chose to run.
  #
  # Selection is by phase and by step rather than by item: choosing individual
  # packages out of a list is a level of control nobody has asked for, and it
  # would make the resulting run impossible to describe afterwards.
  class Selection
    getter profile : Profile

    def initialize(@profile : Profile)
      @phases = {} of String => Bool
      @steps = {} of String => Bool

      # Everything starts selected: the common case is running the profile as
      # written, and the selector exists to remove things from that.
      @profile.phases.each do |phase|
        @phases[phase.name] = true
        phase.steps.each { |step| @steps[step.name] = true }
      end
    end

    def phase?(name : String) : Bool
      @phases[name]? || false
    end

    def step?(name : String) : Bool
      @steps[name]? || false
    end

    # Toggling a phase takes its steps with it: a phase with nothing selected
    # is indistinguishable from a deselected phase, so they are kept in step.
    def toggle_phase(phase : Phase) : Nil
      enabled = !phase?(phase.name)
      @phases[phase.name] = enabled
      phase.steps.each { |step| @steps[step.name] = enabled }
    end

    def toggle_step(phase : Phase, step : Step) : Nil
      @steps[step.name] = !step?(step.name)
      # A phase is selected exactly when at least one of its steps is.
      @phases[phase.name] = phase.steps.any? { |candidate| step?(candidate.name) }
    end

    def select_all : Nil
      @phases.each_key { |name| @phases[name] = true }
      @steps.each_key { |name| @steps[name] = true }
    end

    def select_none : Nil
      @phases.each_key { |name| @phases[name] = false }
      @steps.each_key { |name| @steps[name] = false }
    end

    def any_selected? : Bool
      @phases.any? { |_, enabled| enabled }
    end

    def selected_steps : Int32
      @steps.count { |_, enabled| enabled }
    end

    def selected_items : Int32
      @profile.phases.sum do |phase|
        phase.steps.sum { |step| step?(step.name) ? step.items.size : 0 }
      end
    end

    # The profile as chosen. Dependencies are narrowed to phases that survived,
    # so a kept phase does not wait forever on one the user removed.
    def apply : Profile
      phases = @profile.phases.compact_map do |phase|
        next unless phase?(phase.name)
        steps = phase.steps.select { |step| step?(step.name) }
        next if steps.empty?

        Phase.new(
          phase.name,
          steps,
          phase.depends_on.select { |name| phase?(name) },
          phase.restart_policy,
          phase.continue_on_step_error?,
          phase.description,
        )
      end

      Profile.new(
        @profile.name,
        @profile.target,
        phases,
        policy: @profile.policy,
        skipped_plan_entries: @profile.skipped_plan_entries,
        source_setups: @profile.source_setups,
        base_dir: @profile.base_dir,
      )
    end
  end
end
