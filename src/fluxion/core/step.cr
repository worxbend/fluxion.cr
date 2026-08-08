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

    # The step's `when` guard. Nil when the step declared none.
    #
    # Settable because a step carries its `when` and `execution.continueOnError`
    # alongside the `spec` it is built from, and threading both through every
    # kind's constructor would add two parameters to twenty-seven signatures
    # for no gain.
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

    # The internal step type. Several config kinds share one type — the six
    # package kinds all produce `packages` — so this is not the `kind:` a
    # profile writes; `Config::PlanKinds::STEP_TYPES` maps between the two.
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

    # SHA-256 of the config file this step delegates to, when it delegates.
    #
    # The kinds that hand their work to another tool — binstaller, dotbot,
    # nerd-fonts-installer — carry a path, not a description of the work. Their
    # item key is that path, so `Fingerprint.of` saw nothing change when the
    # file behind it changed: once such a step succeeded, editing the config it
    # points at never ran it again under `--skip-already-installed`.
    #
    # The file's *bytes* are hashed, never parsed. Fluxion does not know those
    # schemas and should not learn them — a new tool, a bumped version or an
    # edited URL all move the digest, and an upstream field rename cannot break
    # this. Nil for every step that describes its own work.
    def external_config_digest : String?
      nil
    end

    # Whether one of this step's items declared `confirm`, and so needs
    # `apply --yes`.
    #
    # Answered by the step because only the step knows where its items live —
    # the orchestrator used to reach into `ShellCommandStep#commands` and
    # `ShellScriptStep#scripts` by name, so a third kind gaining a `confirm`
    # field would have been silently unguarded.
    def requires_approval?(item_key : String) : Bool
      false
    end

    # True when reaching this step ends the run and writes a resume point.
    #
    # The orchestrator deliberately branches on `is_a?(InterruptStep)` rather
    # than on this, because it needs the narrowed type for the payload — the
    # message and the exit code. Rewriting that branch to ask `halts?` and then
    # `.as(InterruptStep)` would look tidier and be unsafe: the cast is only
    # sound while exactly one kind halts, which is precisely what this
    # predicate exists to stop being an assumption. Use `halts?` where the
    # question is all you need; use `is_a?` where the payload is.
    def halts? : Bool
      false
    end

    protected def item(key : String, type : String, display : String? = nil) : ItemRef
      ItemRef.new(key, type, @name, display)
    end
  end
end
