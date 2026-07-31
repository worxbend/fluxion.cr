module Fluxion
  # Everything that happens during a run is reported as one of these.
  #
  # The CLI renderer, the TUI, and the JSON writers all consume the same
  # stream, which is what keeps `apply` and `apply --no-tui` describing the
  # same run rather than drifting apart.
  enum EventKind
    PhaseStarted
    PhaseCompleted
    PhaseFailed
    PhaseBlocked
    RestartRequired
    ModuleStarted
    ItemStarted
    ItemOutput
    ItemCompleted
    ModuleCompleted
    Cancelled
    Error

    # True for events that describe the shape of the run rather than its
    # output. These are never dropped under queue pressure.
    def structural? : Bool
      !item_output?
    end
  end

  # One event on the execution stream.
  struct ExecutionEvent
    # For phase events this holds the phase name — phases and steps share one
    # channel so listeners need only one switch.
    getter step_name : String

    getter item : String
    getter kind : EventKind
    getter result : StepResult?
    getter timestamp : Time
    getter phase_context : String?

    # Present only on `ItemOutput`.
    getter output_line : String?

    def initialize(
      @step_name : String,
      @item : String,
      @kind : EventKind,
      @result : StepResult? = nil,
      @timestamp : Time = Time.utc,
      @phase_context : String? = nil,
      @output_line : String? = nil,
    )
    end

    def self.phase_started(phase : String) : self
      new(phase, "", EventKind::PhaseStarted, phase_context: phase)
    end

    def self.phase_completed(phase : String) : self
      new(phase, "", EventKind::PhaseCompleted, phase_context: phase)
    end

    def self.phase_failed(phase : String) : self
      new(phase, "", EventKind::PhaseFailed, phase_context: phase)
    end

    # `blocked_by` names the failed dependency, so the user learns which
    # earlier failure is responsible rather than just that this phase skipped.
    def self.phase_blocked(phase : String, blocked_by : String) : self
      new(phase, blocked_by, EventKind::PhaseBlocked, phase_context: phase)
    end

    def self.restart_required(phase : String, message : String) : self
      new(phase, message, EventKind::RestartRequired, phase_context: phase)
    end

    def self.step_started(step : String) : self
      new(step, "", EventKind::ModuleStarted)
    end

    def self.step_completed(step : String) : self
      new(step, "", EventKind::ModuleCompleted)
    end

    def self.item_started(step : String, item : String) : self
      new(step, item, EventKind::ItemStarted)
    end

    def self.item_output(step : String, item : String, line : String) : self
      new(step, item, EventKind::ItemOutput, output_line: line)
    end

    def self.item_completed(step : String, item : String, result : StepResult) : self
      new(step, item, EventKind::ItemCompleted, result: result)
    end

    def self.cancelled(phase : String, next_plan_entry : String? = nil) : self
      new(phase, next_plan_entry || "", EventKind::Cancelled, phase_context: phase)
    end

    def self.error(step : String, item : String, result : StepResult) : self
      new(step, item, EventKind::Error, result: result)
    end
  end

  # Anything that wants to watch a run implements this.
  module ExecutionListener
    abstract def on_event(event : ExecutionEvent) : Nil
  end

  # Discards everything. Useful for probe-only runs and specs.
  class NullExecutionListener
    include ExecutionListener

    def on_event(event : ExecutionEvent) : Nil
    end
  end

  # Collects events in order. The backbone of the executor specs.
  class RecordingExecutionListener
    include ExecutionListener

    getter events : Array(ExecutionEvent)

    def initialize
      @events = [] of ExecutionEvent
    end

    def on_event(event : ExecutionEvent) : Nil
      @events << event
    end

    def results : Array(StepResult)
      @events.compact_map(&.result)
    end
  end

  # A single tracked unit of work as the executor sees it: the step that owns
  # it, its stable key, and enough type information to pick a probe and a state
  # entry for it.
  struct ModuleItem
    getter step_name : String
    getter key : String
    getter display_name : String
    getter item_type : ItemType
    getter package_manager : PackageManager?

    # The step this item came from, when the executor needs more than the key
    # to act — a compiled-binary probe needs the checksum, a shell-script probe
    # needs the configured probe command.
    getter step : Step?

    def initialize(
      @step_name : String,
      @key : String,
      @item_type : ItemType,
      display_name : String? = nil,
      @package_manager : PackageManager? = nil,
      @step : Step? = nil,
    )
      @display_name = display_name || @key
    end

    # Unique across the whole profile: the same key can legitimately appear in
    # two steps, which is why `state forget` asks for `--module` when it does.
    def qualified_key : String
      "#{@step_name}/#{@key}"
    end

    def to_s(io : IO) : Nil
      io << qualified_key
    end
  end

  # Cooperative cancellation. Checked between items, so the item in flight
  # finishes, state is flushed, and a resume hint is produced — rather than
  # leaving a half-installed package behind.
  class CancellationSignal
    def initialize
      @cancelled = false
      @mutex = Mutex.new
    end

    # A signal that is never triggered.
    def self.never : self
      new
    end

    # Returns true the first time only, so callers can print the
    # "press Ctrl-C again" notice exactly once.
    def cancel : Bool
      @mutex.synchronize do
        return false if @cancelled
        @cancelled = true
        true
      end
    end

    def cancelled? : Bool
      @mutex.synchronize { @cancelled }
    end
  end
end
