module Fluxion::TUI
  # Live progress while a profile runs.
  #
  # Collects events on one side and renders on the other, so a slow terminal
  # never becomes back-pressure on the run itself. The item list shows what is
  # happening now; the log keeps the last few lines of detail, because a
  # scrolling wall of package-manager output is what the plain reporter is for.
  class ExecutionScreen
    include ExecutionListener

    # Enough to see what led to a failure without turning the screen into a
    # transcript.
    MAX_LOG_LINES = 200

    record Item, step : String, key : String, state : State, detail : String? do
      enum State
        Pending
        Running
        Succeeded
        Failed
        Skipped
        Preview
        Paused
      end

      def terminal? : Bool
        !state.pending? && !state.running?
      end
    end

    getter summary : Executor::RunSummary

    def initialize(@profile : Profile, @mode : String)
      @summary = Executor::RunSummary.new
      @items = [] of Item
      @index = {} of String => Int32
      @log = Deque(String).new
      @current_phase = ""
      @current_step = ""
      @finished = false
      # The app redraws on a fixed interval, so one increment per frame is one
      # animation step. The spinners derive everything else from it.
      @tick = 0_i64
      @mutex = Mutex.new
    end

    def finished? : Bool
      @mutex.synchronize { @finished }
    end

    def finish : Nil
      @mutex.synchronize { @finished = true }
    end

    def on_event(event : ExecutionEvent) : Nil
      @mutex.synchronize do
        # Exhaustive `in`, matching `CLI::Reporter`. With `when`, a new
        # `EventKind` broke the build for the plain reporter and was silently
        # dropped here — so the two front ends could disagree about a run
        # without anything saying so. The kinds this screen ignores say so
        # explicitly.
        case event.kind
        in .phase_started?
          @current_phase = event.step_name
          log("▸ #{event.step_name}")
        in .phase_failed?
          log("✘ #{event.step_name} failed")
        in .phase_blocked?
          log("⦸ #{event.step_name} blocked by #{event.item}")
        in .restart_required?
          log("⚠ restart required: #{event.item}")
        in .step_started?
          @current_step = event.step_name
        in .item_started?
          upsert(event.step_name, event.item, Item::State::Running, nil)
        in .item_output?
          event.output_line.try { |line| log("  #{line}") }
        in .item_completed?
          event.result.try { |result| complete(event, result) }
        in .cancelled?
          log("⚠ stopped at your request")
        in .phase_completed?
          # The item list already shows the outcome of everything in the phase.
          nil
        in .step_completed?
          nil
        in .error?
          # Already surfaced by the ItemCompleted that carries the failure.
          nil
        end
      end
    end

    private def complete(event : ExecutionEvent, result : StepResult) : Nil
      @summary.record(result)

      state, detail = case result
                      when StepResult::Success then {Item::State::Succeeded, nil}
                      when StepResult::Failure then {Item::State::Failed, result.error_message}
                      when StepResult::Skipped then {Item::State::Skipped, result.reason}
                      when StepResult::DryRun  then {Item::State::Preview, result.would_execute.join(' ')}
                      when StepResult::Paused  then {Item::State::Paused, result.message}
                      else                          {Item::State::Succeeded, nil}
                      end

      upsert(event.step_name, event.item, state, detail)
      log("✘ #{event.item}: #{detail}") if state.failed?
    end

    private def upsert(step : String, key : String, state : Item::State, detail : String?) : Nil
      identity = "#{step}\u0000#{key}"
      if position = @index[identity]?
        existing = @items[position]
        @items[position] = Item.new(step, key, state, detail || existing.detail)
        return
      end

      @index[identity] = @items.size
      @items << Item.new(step, key, state, detail)
    end

    private def log(line : String) : Nil
      @log << line
      while @log.size > MAX_LOG_LINES
        @log.shift
      end
    end

    def render(frame : CryTUI::Frame) : Nil
      area = frame.area
      buffer = frame.buffer

      @mutex.synchronize do
        @tick += 1

        header = CryTUI::Rect.new(area.x, area.y, area.width, 3)
        footer = CryTUI::Rect.new(area.x, area.bottom - 2, area.width, 2)
        body = CryTUI::Rect.new(area.x, area.y + 3, area.width, Math.max(0, area.height - 5))

        # The item list gets two thirds: it is the answer to "what is
        # happening", and the log is the answer to "why".
        split = Math.max(4, (body.height * 2) // 3)
        items = CryTUI::Rect.new(body.x, body.y, body.width, split)
        logs = CryTUI::Rect.new(body.x, body.y + split, body.width, Math.max(0, body.height - split))

        render_header(buffer, header)
        render_items(buffer, items)
        render_log(buffer, logs)
        render_footer(buffer, footer)
      end
    end

    private def render_header(buffer : CryTUI::Buffer, area : CryTUI::Rect) : Nil
      Theme.line(buffer, area, area.y, " Fluxion — #{@profile.name} (#{@mode})", Theme.title)
      Theme.line(buffer, area, area.y + 1,
        "  #{@current_phase.empty? ? "starting" : @current_phase}#{@current_step.empty? ? "" : " · #{@current_step}"}",
        Theme.dim)

      # A sweeping bar rather than a percentage: the item count is not known
      # until the run reaches each phase, so any bar claiming to be a fraction
      # of the work would be lying. This one only says "still going", and
      # stops the moment there is nothing left to wait for.
      return if @finished || area.height < 3
      Theme.activity_bar(buffer, CryTUI::Rect.new(area.x + 2, area.y + 2, Math.max(0, area.width - 4), 1), @tick)
    end

    private def render_items(buffer : CryTUI::Buffer, area : CryTUI::Rect) : Nil
      inner = Theme.frame(buffer, area, "items")
      return if inner.height <= 0

      # Anchored to the end so the newest work is always on screen; a run with
      # hundreds of packages would otherwise scroll past unattended.
      window = @items.size > inner.height ? @items[(@items.size - inner.height)..] : @items

      window.each_with_index do |item, offset|
        Theme.line(buffer, inner, inner.y + offset,
          "#{glyph(item.state)} #{item.key.ljust(40)} #{item.detail || ""}", style(item.state))
      end
    end

    private def glyph(state : Item::State) : String
      case state
      in Item::State::Pending   then "·"
      in Item::State::Running   then Theme.spinner_glyph(@tick)
      in Item::State::Succeeded then "✔"
      in Item::State::Failed    then "✘"
      in Item::State::Skipped   then "○"
      in Item::State::Preview   then "~"
      in Item::State::Paused    then "⏸"
      end
    end

    private def style(state : Item::State) : CryTUI::Style
      case state
      in Item::State::Pending   then Theme.dim
      in Item::State::Running   then Theme.running
      in Item::State::Succeeded then Theme.success
      in Item::State::Failed    then Theme.failure
      in Item::State::Skipped   then Theme.dim
      in Item::State::Preview   then Theme.running
      in Item::State::Paused    then Theme.warning
      end
    end

    private def render_log(buffer : CryTUI::Buffer, area : CryTUI::Rect) : Nil
      inner = Theme.frame(buffer, area, "output")
      return if inner.height <= 0

      lines = @log.to_a
      window = lines.size > inner.height ? lines[(lines.size - inner.height)..] : lines
      window.each_with_index do |line, offset|
        Theme.line(buffer, inner, inner.y + offset, line, Theme.dim)
      end
    end

    private def render_footer(buffer : CryTUI::Buffer, area : CryTUI::Rect) : Nil
      parts = [
        "#{@summary.succeeded} ok",
        "#{@summary.failed} failed",
        "#{@summary.skipped} skipped",
      ]
      parts << "#{@summary.dry_run} would run" if @summary.dry_run > 0
      parts << "#{@summary.paused} paused" if @summary.paused > 0

      style = @summary.failed > 0 ? Theme.failure : Theme.success
      Theme.line(buffer, area, area.y, "  #{parts.join(" · ")}", style)
      Theme.line(buffer, area, area.y + 1,
        @finished ? "  done — press any key to exit" : "  ctrl-c to stop after the current step",
        Theme.hint)
    end
  end
end
