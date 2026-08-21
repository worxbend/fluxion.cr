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

    # A per-item discriminator, mixed into the phase fingerprint alongside the
    # key so that two steps whose items happen to share a name still hash
    # differently, and shown by `ItemRef#to_s`.
    #
    # Explicitly NOT the vocabulary a user sees. `status`, `diff`, `plan` and
    # `state forget` all speak `Step#item_type` — a closed enum — and the two
    # disagree for six kinds, which is why `plan --format json` once printed
    # "binary" for an item `status` called "compiled_binary" (see the comment
    # in cli/commands/plan.cr#step_json). A free string each step writes by
    # hand is fine for a hash input and wrong for anything a user types back.
    #
    # Some kinds deliberately put a value here that `item_type` does not
    # carry — `ToolPackagesStep` writes its backend — so this cannot simply be
    # replaced by `item_type`: doing that would make changing `backend: npm` to
    # `backend: cargo` invisible to the fingerprint.
    getter fingerprint_tag : String

    # Name of the step that owns this item.
    getter step_name : String

    # Human-facing label when `key` alone reads poorly.
    getter display : String?

    def initialize(@key : String, @fingerprint_tag : String, @step_name : String, @display : String? = nil)
    end

    def label : String
      @display || @key
    end

    def to_s(io : IO) : Nil
      io << @step_name << '/' << @fingerprint_tag << '/' << @key
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

    # The discriminator this step's items are recorded under.
    #
    # Abstract, and answered by the step, because this value is load-bearing
    # well past the executor: it is what the state file persists, the key
    # `ProbeRegistry` dispatches on, and half of `status`'s dedupe identity.
    # It used to be decided by a `case` over the step hierarchy, which Crystal
    # cannot check for exhaustiveness — so a new kind whose arm nobody added
    # fell through to a default and recorded its items under the wrong type,
    # with no compile error to say so. As an abstract method the compiler
    # refuses to build a subclass that forgets it.
    abstract def item_type : ItemType

    # Everything this step installs, in declaration order.
    abstract def items : Array(ItemRef)

    # The package manager that installs this step's items, for the few kinds
    # where the concept applies at all. Nil for the rest, which is most of them.
    def item_package_manager : PackageManager?
      nil
    end

    # Executables this step needs on PATH before it can do anything.
    #
    # Answered by the step because the step is what knows: `doctor` asks every
    # step in the profile and reports what is missing, but deciding that a
    # git-repo step needs `git` is not a diagnostic policy, it is a fact about
    # the kind. Empty for the many kinds that shell out to nothing in
    # particular.
    def required_commands : Array(String)
      [] of String
    end

    # Path to another tool's config file, for the kinds that delegate their
    # work — binstaller, dotbot, nerd-fonts. Nil for every kind that does its
    # own work, which is most of them.
    #
    # The same three kinds hash this file in `content_digest`, for the same
    # reason: what the step actually does lives in a file Fluxion does not
    # read. Naming the path once here is what lets both callers stop asking
    # each class by name.
    def delegated_config : String?
      nil
    end

    # One-line summary for `plan` and `list`.
    def summary : String
      Text.pluralize(items.size, "item")
    end

    # True when the step mutates the host. Purely informational steps still
    # appear in plans but never need sudo or a dry-run guard.
    def mutating? : Bool
      true
    end

    # SHA-256 over whatever decides this step's work but is not in its item keys.
    #
    # `Fingerprint.of` hashes step scalars and item keys, which is enough for a
    # step that names what it installs. It is not enough for two shapes:
    #
    # * A delegated kind — binstaller, dotbot, nerd-fonts-installer — whose item
    #   key is a path to another tool's config. The work changes when that file
    #   changes, and nothing in the fingerprint saw it, so once the step
    #   succeeded editing the config never ran it again.
    # * An inline script body, which lives in the profile but is not part of any
    #   item key.
    #
    # For a delegated config the file's *bytes* are hashed, never parsed:
    # Fluxion does not know those schemas and should not learn them, and an
    # upstream field rename cannot break a byte hash. Nil when neither applies.
    def content_digest : String?
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

    protected def item(key : String, fingerprint_tag : String, display : String? = nil) : ItemRef
      ItemRef.new(key, fingerprint_tag, @name, display)
    end
  end
end
