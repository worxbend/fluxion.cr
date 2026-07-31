module Fluxion
  # A single unit of tracked work inside a step.
  #
  # Steps are the config-level grouping ("install these twelve packages"), but
  # Fluxion probes, skips, reports, and records state at item granularity so
  # that one failed package does not lose the other eleven. `key` is what the
  # user types for `state forget --item`, so it must be stable across runs and
  # meaningful on its own: a package name, an absolute install path, a repo
  # file, a key fingerprint.
  struct ItemRef
    getter key : String

    # Short type label shown in `status`/`diff` and used to disambiguate
    # `state forget` when the same key appears in two steps.
    getter type : String

    # Name of the step that owns this item.
    getter step_name : String

    # Human-facing label when `key` alone reads poorly.
    getter display : String?

    def initialize(@key : String, @type : String, @step_name : String, @display : String? = nil)
    end

    def label : String
      @display || @key
    end

    def to_s(io : IO) : Nil
      io << @step_name << '/' << @type << '/' << @key
    end
  end

  # Base class for every kind of work a profile can declare.
  #
  # Subclasses hold only validated data — no IO, no process handles, no
  # terminal. Turning a step into commands is the executor's job, which is what
  # lets `plan`, `dry-run`, `explain`, and `apply` share one description of the
  # work and disagree only about whether to run it.
  abstract class Step
    getter name : String
    getter description : String?

    # Whether the step keeps going after one of its items fails. The default
    # differs per kind and is set by each subclass, because "keep installing
    # the other packages" and "keep running the rest of this script" are very
    # different risks.
    getter? continue_on_error : Bool

    # Shell snippet that reports whether this step's work is already done.
    # Runs under `/bin/bash -lc`; exit 0 means done.
    getter probe_command : String?

    # Manifest-level `when` guard. Nil for the stable jobs/steps schema, which
    # has no per-step conditions.
    #
    # Settable because a manifest plan entry carries its `when` and
    # `execution.continueOnError` alongside the spec the step is built from,
    # and threading both through every kind's constructor would add two
    # parameters to twenty-seven signatures for no gain.
    property condition : Condition?

    setter continue_on_error : Bool

    def initialize(
      @name : String,
      @description : String? = nil,
      @continue_on_error : Bool = false,
      @probe_command : String? = nil,
      @condition : Condition? = nil,
    )
    end

    # The config `type` (stable schema) that produces this step.
    abstract def kind : String

    # Everything this step installs, in declaration order.
    abstract def items : Array(ItemRef)

    # One-line summary for `plan` and `list`.
    def summary : String
      count = items.size
      count == 1 ? "1 item" : "#{count} items"
    end

    # True when the step mutates the host. Purely informational steps still
    # appear in plans but never need sudo or a dry-run guard.
    def mutating? : Bool
      true
    end

    # True when reaching this step ends the run and writes a resume point.
    def halts? : Bool
      false
    end

    protected def item(key : String, type : String, display : String? = nil) : ItemRef
      ItemRef.new(key, type, @name, display)
    end
  end
end
