module Fluxion
  # A group of steps that run together, ordered against other phases by
  # `dependsOn`.
  class Phase
    getter name : String
    getter description : String
    getter depends_on : Array(String)
    getter steps : Array(Step)
    getter restart_policy : RestartPolicy

    # When false, the first failed step hard-fails the phase and blocks every
    # phase that depends on it. Defaults to true so one bad package does not
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

    # True when finishing this phase ends the run and writes a resume point.
    def halts? : Bool
      @restart_policy.halts? || @steps.any?(&.halts?)
    end

    def to_s(io : IO) : Nil
      io << @name
    end
  end

  # Profile-level execution defaults. Each is optional so "not stated" stays
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

  # A step or source that host facts or a `when` rule excluded.
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
    getter phases : Array(Phase)
    getter skipped_plan_entries : Array(SkippedPlanEntry)
    getter source_setups : Array(SourceSetup)

    # Directory the profile was loaded from. Relative script, working-directory,
    # and `creates` paths resolve against this, so a profile stays portable
    # regardless of where it is run from.
    getter base_dir : String

    def initialize(
      @name : String,
      @target : TargetOs,
      @phases : Array(Phase),
      @policy : Policy = Policy.empty,
      @skipped_plan_entries : Array(SkippedPlanEntry) = [] of SkippedPlanEntry,
      @source_setups : Array(SourceSetup) = [] of SourceSetup,
      @base_dir : String = Dir.current,
    )
    end

    def steps : Array(Step)
      @phases.flat_map(&.steps)
    end

    def items : Array(ItemRef)
      @phases.flat_map(&.items)
    end

    def phase?(name : String) : Phase?
      @phases.find { |phase| phase.name == name }
    end

    # Phases in dependency order. Ties break on declaration order so the same
    # profile always plans identically.
    def ordered_phases : Array(Phase)
      remaining = @phases.dup
      resolved = [] of Phase
      resolved_names = Set(String).new

      until remaining.empty?
        ready = remaining.select { |phase| phase.depends_on.all? { |dep| resolved_names.includes?(dep) } }
        if ready.empty?
          raise ConfigError.new("Circular dependency detected among phases: #{remaining.map(&.name).sort!.join(", ")}")
        end
        ready.each do |phase|
          resolved << phase
          resolved_names << phase.name
        end
        remaining.reject! { |phase| resolved_names.includes?(phase.name) }
      end

      resolved
    end
  end
end
