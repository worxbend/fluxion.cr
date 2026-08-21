module Fluxion::TUI
  # The shape of a run, as it happens: phases, the steps inside them, and the
  # items inside those.
  #
  # Split out of `ExecutionScreen` because the two answer to different things.
  # This side changes when the executor reports something new — a kind of
  # result, a level of nesting, a rule about what counts as finished. The screen
  # changes when the drawing or the key bindings change. Holding both in one
  # class meant every reader of the rendering had to scroll past the bookkeeping
  # and every reader of the bookkeeping had to scroll past the rendering.
  #
  # Nothing here knows about terminals, styles, or keys. It also does no locking
  # of its own: the screen owns the one mutex, because it is the screen that has
  # two fibers — the executor's, delivering events, and the drawing fiber — and
  # a second lock down here would only be a second thing to get wrong.
  class RunTree
    # The phase events are filed under before any phase has started — a run
    # that fails in its first step still has to put that output somewhere.
    UNGROUPED = "run"

    # What has happened to one item.
    enum ItemState
      Pending
      Running
      Succeeded
      Failed
      Skipped
      Preview
      Paused

      def terminal? : Bool
        !pending? && !running?
      end
    end

    # One item of one step: the smallest thing the run reports on.
    class ItemRow
      getter key : String
      property state : ItemState
      property detail : String?
      # Monotonic, not wall clock: a run that spans a clock adjustment must
      # not report an item as having taken a negative amount of time.
      property started_at : Time::Instant
      property finished_at : Time::Instant?

      def initialize(@key : String, @state : ItemState = ItemState::Pending, @detail : String? = nil)
        @started_at = Time.instant
      end

      def duration : Time::Span?
        @finished_at.try { |finished| finished - @started_at }
      end
    end

    # A step and the items it is working through.
    class StepGroup
      getter name : String
      getter items : Array(ItemRow)
      property? collapsed : Bool

      def initialize(@name : String)
        @items = [] of ItemRow
        @collapsed = false
      end

      def find_or_add(key : String) : ItemRow
        @items.find { |item| item.key == key } || begin
          row = ItemRow.new(key)
          @items << row
          row
        end
      end

      def failed? : Bool
        @items.any?(&.state.failed?)
      end

      def running? : Bool
        @items.any?(&.state.running?)
      end

      def finished : Int32
        @items.count(&.state.terminal?)
      end
    end

    # A phase and the steps under it.
    class PhaseGroup
      getter name : String
      getter steps : Array(StepGroup)
      property? collapsed : Bool
      property? blocked : Bool
      property blocked_by : String?

      def initialize(@name : String)
        @steps = [] of StepGroup
        @collapsed = false
        @blocked = false
      end

      def find_or_add(name : String) : StepGroup
        @steps.find { |step| step.name == name } || begin
          group = StepGroup.new(name)
          @steps << group
          group
        end
      end

      def failed? : Bool
        @steps.any?(&.failed?)
      end

      def running? : Bool
        @steps.any?(&.running?)
      end
    end

    # A row of the tree, flattened so cursor movement is a single index.
    record Node, phase : PhaseGroup, step : StepGroup?, item : ItemRow?

    getter phases : Array(PhaseGroup)

    # The phase and step the run is in the middle of, which is both what the
    # header says and where an event that names only a step is filed.
    getter current_phase : String
    getter current_step : String

    def initialize
      @phases = [] of PhaseGroup
      @current_phase = ""
      @current_step = ""
    end

    # ── Recording ────────────────────────────────────────────────────────────

    def phase_started(name : String) : PhaseGroup
      @current_phase = name
      phase(name)
    end

    def step_started(name : String) : StepGroup
      @current_step = name
      step(name)
    end

    # The phase of this name, added if the run has not mentioned it before.
    # Separate from `phase_started` because a blocked phase is recorded without
    # ever becoming the phase the run is in.
    def phase(name : String) : PhaseGroup
      name = UNGROUPED if name.empty?
      @phases.find { |group| group.name == name } || begin
        group = PhaseGroup.new(name)
        @phases << group
        group
      end
    end

    def item(step_name : String, key : String) : ItemRow
      step(step_name).find_or_add(key)
    end

    # Where an event that names only a step belongs: under whichever phase is
    # running, or under `UNGROUPED` before the first one starts.
    private def step(name : String) : StepGroup
      phase(@current_phase).find_or_add(name)
    end

    # ── Reading ──────────────────────────────────────────────────────────────

    # The visible rows, in run order. Rebuilt per call rather than cached: the
    # tree changes on almost every event, and a cache would have to be
    # invalidated from the executor's fiber for no measurable gain on a list
    # this size.
    def rows(failures_only : Bool = false) : Array(Node)
      result = [] of Node
      @phases.each do |phase|
        steps = failures_only ? phase.steps.select(&.failed?) : phase.steps
        next if failures_only && steps.empty?

        result << Node.new(phase, nil, nil)
        next if phase.collapsed?

        steps.each do |step|
          result << Node.new(phase, step, nil)
          next if step.collapsed?

          items = failures_only ? step.items.select(&.state.failed?) : step.items
          items.each { |item| result << Node.new(phase, step, item) }
        end
      end
      result
    end

    def completed_items : Int32
      @phases.sum { |phase| phase.steps.sum(&.finished) }
    end

    # Where a group's own heading row sits, so a key can move out of a nested
    # row onto the thing that contains it. Compared by identity rather than by
    # name: two phases may legitimately contain steps of the same name.
    def index_of(phase : PhaseGroup, step : StepGroup?, failures_only : Bool = false) : Int32?
      rows(failures_only).index do |node|
        next false unless node.item.nil?
        next false unless node.phase.same?(phase)
        candidate = node.step
        step.nil? ? candidate.nil? : !candidate.nil? && candidate.same?(step)
      end
    end

    # ── Folding ──────────────────────────────────────────────────────────────

    def fold_every(collapsed : Bool) : Nil
      @phases.each do |phase|
        phase.collapsed = collapsed
        phase.steps.each(&.collapsed=(collapsed))
      end
    end
  end
end
