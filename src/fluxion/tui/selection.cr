module Fluxion::TUI
  # Which parts of a profile the user chose to run.
  #
  # Selection is by job and by step rather than by item: choosing individual
  # packages out of a list is a level of control nobody has asked for, and it
  # would make the resulting run impossible to describe afterwards.
  class Selection
    getter profile : Profile

    def initialize(@profile : Profile)
      @jobs = {} of String => Bool
      @steps = {} of String => Bool

      # Everything starts selected: the common case is running the profile as
      # written, and the selector exists to remove things from that.
      @profile.jobs.each do |job|
        @jobs[job.name] = true
        job.steps.each { |step| @steps[step.name] = true }
      end
    end

    def job?(name : String) : Bool
      @jobs[name]? || false
    end

    def step?(name : String) : Bool
      @steps[name]? || false
    end

    # Toggling a job takes its steps with it: a job with nothing selected is
    # indistinguishable from a deselected job, so they are kept in step.
    def toggle_job(job : Job) : Nil
      enabled = !job?(job.name)
      @jobs[job.name] = enabled
      job.steps.each { |step| @steps[step.name] = enabled }
    end

    def toggle_step(job : Job, step : Step) : Nil
      @steps[step.name] = !step?(step.name)
      # A job is selected exactly when at least one of its steps is.
      @jobs[job.name] = job.steps.any? { |candidate| step?(candidate.name) }
    end

    def select_all : Nil
      @jobs.each_key { |name| @jobs[name] = true }
      @steps.each_key { |name| @steps[name] = true }
    end

    def select_none : Nil
      @jobs.each_key { |name| @jobs[name] = false }
      @steps.each_key { |name| @steps[name] = false }
    end

    def any_selected? : Bool
      @jobs.any? { |_, enabled| enabled }
    end

    def selected_steps : Int32
      @steps.count { |_, enabled| enabled }
    end

    def selected_items : Int32
      @profile.jobs.sum do |job|
        job.steps.sum { |step| step?(step.name) ? step.items.size : 0 }
      end
    end

    # The profile as chosen. Dependencies are narrowed to jobs that survived,
    # so a kept job does not wait forever on one the user removed.
    def apply : Profile
      jobs = @profile.jobs.compact_map do |job|
        next unless job?(job.name)
        steps = job.steps.select { |step| step?(step.name) }
        next if steps.empty?

        Job.new(
          job.name,
          steps,
          job.depends_on.select { |name| job?(name) },
          job.restart_policy,
          job.continue_on_step_error?,
          job.description,
        )
      end

      Profile.new(
        @profile.name,
        @profile.target,
        jobs,
        policy: @profile.policy,
        skipped_plan_entries: @profile.skipped_plan_entries,
        source_setups: @profile.source_setups,
        base_dir: @profile.base_dir,
      )
    end
  end
end
