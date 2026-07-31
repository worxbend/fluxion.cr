module Fluxion
  # A group of steps that run together, ordered against other jobs by
  # `dependsOn`.
  #
  # The stable schema calls these `jobs` (with `phases` as a legacy alias) and
  # the manifest frontend produces exactly one, named `manifest-plan`.
  class Job
    getter name : String
    getter description : String
    getter depends_on : Array(String)
    getter steps : Array(Step)
    getter restart_policy : RestartPolicy

    # When false, the first failed step hard-fails the job and blocks every
    # job that depends on it. Defaults to true so one bad package does not
    # abandon the rest of a bootstrap.
    getter? continue_on_step_error : Bool

    def initialize(
      @name : String,
      @steps : Array(Step),
      @depends_on : Array(String) = [] of String,
      @restart_policy : RestartPolicy = RestartPolicy::None.new,
      @continue_on_step_error : Bool = true,
      @description : String = "",
    )
    end

    def items : Array(ItemRef)
      @steps.flat_map(&.items)
    end

    # True when finishing this job ends the run and writes a resume point.
    def halts? : Bool
      @restart_policy.halts? || @steps.any?(&.halts?)
    end

    def to_s(io : IO) : Nil
      io << @name
    end
  end

  # Manifest-level execution defaults. Each is optional so "not stated" stays
  # distinguishable from "explicitly false" — a per-entry setting overrides the
  # default, but only when a default exists.
  struct Policy
    getter dry_run : Bool?
    getter continue_on_error : Bool?
    getter require_sudo : Bool?

    def initialize(@dry_run : Bool? = nil, @continue_on_error : Bool? = nil, @require_sudo : Bool? = nil)
    end

    def self.empty : self
      new
    end
  end

  # A manifest plan entry that host facts or a `when` rule excluded.
  #
  # Recorded rather than dropped so `plan`, `dry-run`, `apply`, and the TUI can
  # all show what was skipped and why — silence would look like the entry was
  # never in the profile.
  struct SkippedPlanEntry
    getter name : String
    getter kind : String
    getter reason : String

    def initialize(@name : String, @kind : String, @reason : String)
    end
  end

  # A repository or remote declared under `spec.sources`, paired with the
  # package manager it belongs to.
  #
  # Source setups run as a prelude before the package entries that need them,
  # and are reported as skipped work when no selected entry uses that manager.
  struct SourceSetup
    getter step : Step
    getter package_manager : PackageManager

    def initialize(@step : Step, @package_manager : PackageManager)
    end

    def name : String
      @step.name
    end

    def items : Array(ItemRef)
      @step.items
    end
  end

  # A fully validated profile, ready to plan or execute.
  class Profile
    getter name : String
    getter target : TargetOs
    getter policy : Policy
    getter jobs : Array(Job)
    getter skipped_plan_entries : Array(SkippedPlanEntry)
    getter source_setups : Array(SourceSetup)

    # Directory the profile was loaded from. Relative script, working-directory,
    # and `creates` paths resolve against this, so a profile stays portable
    # regardless of where it is run from.
    getter base_dir : String

    def initialize(
      @name : String,
      @target : TargetOs,
      @jobs : Array(Job),
      @policy : Policy = Policy.empty,
      @skipped_plan_entries : Array(SkippedPlanEntry) = [] of SkippedPlanEntry,
      @source_setups : Array(SourceSetup) = [] of SourceSetup,
      @base_dir : String = Dir.current,
    )
    end

    def steps : Array(Step)
      @jobs.flat_map(&.steps)
    end

    def items : Array(ItemRef)
      @jobs.flat_map(&.items)
    end

    def job?(name : String) : Job?
      @jobs.find { |job| job.name == name }
    end

    # True when this profile came from a WorkstationProfile manifest, which
    # produces exactly one job with this reserved name.
    def manifest? : Bool
      @jobs.size == 1 && @jobs.first.name == MANIFEST_JOB_NAME
    end

    MANIFEST_JOB_NAME = "manifest-plan"

    # Jobs in dependency order. Ties break on declaration order so the same
    # profile always plans identically.
    def ordered_jobs : Array(Job)
      remaining = @jobs.dup
      resolved = [] of Job
      resolved_names = Set(String).new

      until remaining.empty?
        ready = remaining.select { |job| job.depends_on.all? { |dep| resolved_names.includes?(dep) } }
        if ready.empty?
          raise ConfigError.new("Circular dependency detected among jobs: #{remaining.map(&.name).sort!.join(", ")}")
        end
        ready.each do |job|
          resolved << job
          resolved_names << job.name
        end
        remaining.reject! { |job| resolved_names.includes?(job.name) }
      end

      resolved
    end
  end
end
