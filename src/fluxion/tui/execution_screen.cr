module Fluxion::TUI
  # Live progress while a profile runs.
  #
  # Collects events on one side and renders on the other, so a slow terminal
  # never becomes back-pressure on the run itself. The left pane is the answer
  # to "what is happening": the same phase-and-step tree the selector showed,
  # filling in as the run walks it. The right pane is the answer to "why": the
  # command output, either the live tail of the whole run or the output of one
  # step you pinned.
  #
  # Every event arrives on the executor's fiber and every read happens on the
  # drawing fiber, so all of the mutable state below is behind one mutex.
  class ExecutionScreen
    include ExecutionListener

    # Enough output to explain a failure without keeping an entire
    # distribution upgrade in memory. Older lines are dropped from the front,
    # so what survives is always the part nearest whatever went wrong.
    MAX_LOG_LINES = 2_000

    # The width below which the output pane is not worth the columns it would
    # cost the tree, and so is dropped until `o` asks for it back.
    MIN_SPLIT_WIDTH = 80

    # Structural notes — a blocked phase, a restart request — kept only long
    # enough to be read off the header. The tree is where the run's shape
    # lives; this is a ticker, not a record.
    MAX_NOTICES = 8

    enum Outcome
      Continue
      # Stop the run at the next item boundary.
      Cancel
      # The run is over and the user has read the summary.
      Exit
    end

    enum Pane
      Tree
      Output

      def next : Pane
        tree? ? Output : Tree
      end
    end

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

    # One line of command output, tagged with where it came from so the output
    # pane can show either the whole run or one step of it without keeping two
    # copies of the same text.
    record OutputLine, phase : String, step : String, item : String, text : String

    # A row of the tree, flattened so cursor movement is a single index.
    record Node, phase : PhaseGroup, step : StepGroup?, item : ItemRow?

    # The phase events are filed under before any phase has started — a run
    # that fails in its first step still has to put that output somewhere.
    UNGROUPED = "run"

    getter summary : Executor::RunSummary

    # The node whose output the right-hand pane is showing, or nil for the
    # live tail of the whole run.
    @pinned : Node? = nil

    # How many items the run will touch in total, counted once from the
    # profile the selector produced.
    @planned_items : Int32 = 0

    def initialize(@profile : Profile, @mode : String)
      @summary = Executor::RunSummary.new
      @phases = [] of PhaseGroup
      @log = Deque(OutputLine).new
      @notices = Deque(String).new
      @current_phase = ""
      @current_step = ""
      @finished = false
      @cancelling = false
      @started_at = Time.instant

      # Every item the selected profile declares. Known before the first event
      # because the selector has already narrowed the profile, which is what
      # lets the progress bar state a fraction instead of only saying "busy".
      @planned_items = @profile.phases.sum(0) { |phase| phase.steps.sum(0, &.items.size) }

      @cursor = 0
      @pane = Pane::Tree
      @output_scroll = 0
      @follow = true
      @pinned = nil
      @failures_only = false
      @show_output = true
      @help = false
      @frame = 0
      @pending = PendingSequence.new
      @list_state = CryTUI::Widgets::ListState.new(0, 0)
      @mutex = Mutex.new
    end

    def finished? : Bool
      @mutex.synchronize { @finished }
    end

    def finish : Nil
      @mutex.synchronize { @finished = true }
    end

    # Records that a stop was asked for, so the footer can say the run is
    # winding down rather than looking as though the key did nothing — a
    # cancellation only takes effect at the next item boundary, which during a
    # long package install is a noticeable wait.
    def cancelling : Nil
      @mutex.synchronize { @cancelling = true }
    end

    # ── Events ───────────────────────────────────────────────────────────────

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
          phase(event.step_name)
        in .phase_failed?
          notice("#{event.step_name} failed")
        in .phase_blocked?
          group = phase(event.step_name)
          group.blocked = true
          group.blocked_by = event.item
          notice("#{event.step_name} blocked by #{event.item}")
        in .restart_required?
          notice("restart required: #{event.item}")
        in .step_started?
          @current_step = event.step_name
          step(event.step_name)
        in .item_started?
          item(event.step_name, event.item).state = ItemState::Running
        in .item_output?
          event.output_line.try { |line| record_output(event.step_name, event.item, line) }
        in .item_completed?
          event.result.try { |result| complete(event, result) }
        in .cancelled?
          @cancelling = true
          notice("stopped at your request")
        in .phase_completed?
          # The tree already shows the outcome of everything in the phase.
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
                      when StepResult::Success then {ItemState::Succeeded, nil}
                      when StepResult::Failure then {ItemState::Failed, result.error_message}
                      when StepResult::Skipped then {ItemState::Skipped, result.reason}
                      when StepResult::DryRun  then {ItemState::Preview, result.would_execute.join(' ')}
                      when StepResult::Paused  then {ItemState::Paused, result.message}
                      else                          {ItemState::Succeeded, nil}
                      end

      row = item(event.step_name, event.item)
      row.state = state
      row.detail = detail || row.detail
      row.finished_at = Time.instant
    end

    private def phase(name : String) : PhaseGroup
      name = UNGROUPED if name.empty?
      @phases.find { |group| group.name == name } || begin
        group = PhaseGroup.new(name)
        @phases << group
        group
      end
    end

    private def step(name : String) : StepGroup
      phase(@current_phase).find_or_add(name)
    end

    private def item(step_name : String, key : String) : ItemRow
      step(step_name).find_or_add(key)
    end

    private def record_output(step_name : String, item_key : String, text : String) : Nil
      @log << OutputLine.new(@current_phase.empty? ? UNGROUPED : @current_phase, step_name, item_key, text)
      while @log.size > MAX_LOG_LINES
        @log.shift
      end
    end

    private def notice(text : String) : Nil
      @notices << text
      while @notices.size > MAX_NOTICES
        @notices.shift
      end
    end

    # ── Input ────────────────────────────────────────────────────────────────

    def handle(event : CryTUI::KeyEvent) : Outcome
      @mutex.synchronize do
        return handle_help(event) if @help

        case @pending.feed(event)
        when .resolved?
          @pending.action.try { |action| return perform(action) }
          return Outcome::Continue
        when .pending?
          return Outcome::Continue
        end

        handle_key(event)
      end
    end

    private def handle_key(event : CryTUI::KeyEvent) : Outcome
      case event.code
      when .up?        then move(-1)
      when .down?      then move(1)
      when .left?      then collapse
      when .right?     then expand
      when .page_up?   then move(-page)
      when .page_down? then move(page)
      when .home?      then move_to(0)
      when .end?       then move_to({nodes.size - 1, 0}.max)
      when .tab?       then @pane = @pane.next
      when .enter?     then pin
      when .escape?    then return escape
      when .character? then return handle_character(event)
      end

      Outcome::Continue
    end

    private def handle_character(event : CryTUI::KeyEvent) : Outcome
      return stop_or_exit if event.character == 'c' && event.modifiers.control?

      case event.character
      when 'j' then move(1)
      when 'k' then move(-1)
      when 'h' then collapse
      when 'l' then expand
      when 'f' then toggle_follow
      when 'e' then toggle_failures
      when 'o' then @show_output = !@show_output
      when '?' then @help = true
      when 'q' then return stop_or_exit
      end

      Outcome::Continue
    end

    # ameba:disable Metrics/CyclomaticComplexity
    private def perform(action : ActionKind) : Outcome
      case action
      when .navigate_up?             then move(-1)
      when .navigate_down?           then move(1)
      when .navigate_top?            then move_to(0)
      when .navigate_bottom?         then move_to({nodes.size - 1, 0}.max)
      when .navigate_half_page_down? then move(page // 2)
      when .navigate_half_page_up?   then move(-(page // 2))
      when .navigate_next_group?     then jump_group(1)
      when .navigate_previous_group? then jump_group(-1)
      when .expand?                  then expand
      when .collapse?                then collapse
      when .toggle_fold?             then toggle_fold
      when .expand_all?              then fold_every(false)
      when .collapse_all?            then fold_every(true)
      when .focus_pane_left?         then @pane = Pane::Tree
      when .focus_pane_right?        then @pane = Pane::Output
      when .focus_next_pane?         then @pane = @pane.next
      when .toggle_output?           then @show_output = !@show_output
      when .toggle_follow?           then toggle_follow
      when .toggle_filter_failures?  then toggle_failures
      when .toggle_help?             then @help = !@help
      when .cycle_palette?           then Theme.cycle_palette
      when .quit?                    then return stop_or_exit
      end

      Outcome::Continue
    end

    private def handle_help(event : CryTUI::KeyEvent) : Outcome
      case event.code
      when .escape?, .enter? then @help = false
      when .character?
        return stop_or_exit if event.character == 'c' && event.modifiers.control?
        @help = false if event.character.in?('?', 'q')
      end
      Outcome::Continue
    end

    # `q` means two different things either side of the finish line, and both
    # are what the word means at the time: stop the work while it is running,
    # close the report once there is no work left.
    private def stop_or_exit : Outcome
      return Outcome::Exit if @finished
      @cancelling = true
      Outcome::Cancel
    end

    private def escape : Outcome
      if @pinned
        @pinned = nil
        @follow = true
        return Outcome::Continue
      end
      @finished ? Outcome::Exit : Outcome::Continue
    end

    # ── Navigation ───────────────────────────────────────────────────────────

    private def move(delta : Int32) : Nil
      if @pane.output?
        # Scrolling the output by hand is a statement that you want to look at
        # something, so it stops the tail dragging it away underneath you.
        @follow = false if delta != 0
        @output_scroll = {@output_scroll + delta, 0}.max
        return
      end

      rows = nodes
      return if rows.empty?
      move_to((@cursor + delta).clamp(0, rows.size - 1))
    end

    # Puts the cursor somewhere on purpose.
    #
    # Every deliberate move stops the tree following the run, because the two
    # cannot both own the cursor: while following, the newest row is selected
    # on every frame, so a cursor moved anywhere else would be dragged back
    # before it was ever drawn. `f` starts the follow again.
    private def move_to(index : Int32) : Nil
      @follow = false
      @cursor = index
    end

    private def jump_group(direction : Int32) : Nil
      rows = nodes
      return if rows.empty?
      index = @cursor + direction
      while index >= 0 && index < rows.size
        if rows[index].step.nil?
          move_to(index)
          return
        end
        index += direction
      end
      move_to(direction > 0 ? rows.size - 1 : 0)
    end

    private def current : Node?
      nodes[@cursor]?
    end

    private def collapse : Nil
      node = current
      return unless node

      if node.item
        # `h` on an item moves out to its step rather than doing nothing,
        # which is what a Neovim user expects from a tree: collapse where you
        # can, move outward where you cannot.
        move_to(index_of(node.phase, node.step) || @cursor)
      elsif step = node.step
        @follow = false
        step.collapsed = true
      else
        @follow = false
        node.phase.collapsed = true
      end
      clamp_cursor
    end

    private def expand : Nil
      node = current
      return unless node

      @follow = false
      if step = node.step
        step.collapsed = false if node.item.nil?
      else
        node.phase.collapsed = false
      end
      clamp_cursor
    end

    private def toggle_fold : Nil
      node = current
      return unless node
      @follow = false

      if (step = node.step) && node.item.nil?
        step.collapsed = !step.collapsed?
      elsif node.step.nil?
        node.phase.collapsed = !node.phase.collapsed?
      end
      clamp_cursor
    end

    private def fold_every(collapsed : Bool) : Nil
      @follow = false
      @phases.each do |phase|
        phase.collapsed = collapsed
        phase.steps.each(&.collapsed=(collapsed))
      end
      clamp_cursor
    end

    # Where a group's own heading row sits, so a key can move out of a nested
    # row onto the thing that contains it. Compared by identity rather than by
    # name: two phases may legitimately contain steps of the same name.
    private def index_of(phase : PhaseGroup, step : StepGroup?) : Int32?
      nodes.index do |node|
        next false unless node.item.nil?
        next false unless node.phase.same?(phase)
        candidate = node.step
        step.nil? ? candidate.nil? : !candidate.nil? && candidate.same?(step)
      end
    end

    private def clamp_cursor : Nil
      @cursor = @cursor.clamp(0, {nodes.size - 1, 0}.max)
    end

    private def pin : Nil
      node = current
      return unless node
      @pinned = node
      @follow = false
      @output_scroll = 0
      @pane = Pane::Output
    end

    private def toggle_follow : Nil
      @follow = !@follow
      @output_scroll = 0 if @follow
    end

    private def toggle_failures : Nil
      @failures_only = !@failures_only
      clamp_cursor
    end

    @page = 10

    private def page : Int32
      {@page, 1}.max
    end

    # ── Tree ─────────────────────────────────────────────────────────────────

    # The visible rows, in run order. Rebuilt per frame rather than cached: the
    # tree changes on almost every event, and a cache would have to be
    # invalidated from the executor's fiber for no measurable gain on a list
    # this size.
    private def nodes : Array(Node)
      rows = [] of Node
      @phases.each do |phase|
        steps = @failures_only ? phase.steps.select(&.failed?) : phase.steps
        next if @failures_only && steps.empty?

        rows << Node.new(phase, nil, nil)
        next if phase.collapsed?

        steps.each do |step|
          rows << Node.new(phase, step, nil)
          next if step.collapsed?

          items = @failures_only ? step.items.select(&.state.failed?) : step.items
          items.each { |item| rows << Node.new(phase, step, item) }
        end
      end
      rows
    end

    private def completed_items : Int32
      @phases.sum { |phase| phase.steps.sum(&.finished) }
    end

    # How much of the run is behind us, from 0 to 1.
    #
    # Measured against the item count the profile declares, not against the
    # items seen so far — a bar whose denominator grows as the run discovers
    # work would spend the whole run near the same number and mean nothing. A
    # profile that declares no items at all is reported as complete rather than
    # dividing by zero.
    private def ratio : Float64
      return 1.0 if @planned_items.zero?
      (completed_items.to_f / @planned_items).clamp(0.0, 1.0)
    end

    private def elapsed : Time::Span
      Time.instant - @started_at
    end

    # Time left, extrapolated from the rate so far. Withheld until a tenth of
    # the run is done, because an estimate drawn from two packages is a number
    # that will be wrong by minutes and read as though it were not.
    private def remaining : Time::Span?
      progress = ratio
      return if progress < 0.1 || progress >= 1.0
      elapsed * ((1.0 - progress) / progress)
    end

    # ── Rendering ────────────────────────────────────────────────────────────

    def render(frame : CryTUI::Frame) : Nil
      area = frame.area
      buffer = frame.buffer

      @mutex.synchronize do
        @frame += 1
        buffer.set_style(area, Theme.canvas)

        header_height = {5, area.height}.min
        footer_height = {4, {area.height - header_height, 0}.max}.min
        header = CryTUI::Rect.new(area.x, area.y, area.width, header_height)
        footer = CryTUI::Rect.new(area.x, area.bottom - footer_height, area.width, footer_height)
        body = CryTUI::Rect.new(area.x, area.y + header_height, area.width,
          {area.height - header_height - footer_height, 0}.max)

        render_header(buffer, header)
        render_body(buffer, body)
        render_footer(buffer, footer)

        Chrome::WhichKey.render(buffer, area, @pending.pending, @frame)
        Chrome::Help.render(buffer, area, help_sections, @frame) if @help
      end
    end

    private def render_header(buffer : CryTUI::Buffer, area : CryTUI::Rect) : Nil
      return if area.empty?
      theme = Theme.palette

      title = " #{Theme.symbol("◈", "*")} FLUXION // #{@mode.upcase} "
      spans = if Theme.rich?
                Anim.gradient_spans(title, theme.accent, theme.accent_alt, @frame, true)
              else
                [CryTUI::Span.new(title, Theme.title)]
              end
      spans << CryTUI::Span.new(" #{@profile.name}", Theme.heading)
      spans << CryTUI::Span.new(Theme.symbol("  │  ", "  |  "), Theme.border)
      spans << CryTUI::Span.new(activity, activity_style)

      block = Chrome.panel(Theme.symbol("⚡", "#"), "progress", "", nil, false, @frame)
      block.render(area, buffer)
      inner = block.inner(area)
      return if inner.empty?

      CryTUI::Line.new(spans).render(buffer, CryTUI::Rect.new(inner.x, inner.y, inner.width, 1))
      render_progress(buffer, inner)
    end

    # The bar itself, with its numbers on the line underneath: how many items
    # are done, how long it has taken, and how long is left.
    private def render_progress(buffer : CryTUI::Buffer, inner : CryTUI::Rect) : Nil
      return if inner.height < 2

      percent = "#{(ratio * 100).round.to_i}%".rjust(4)
      label = " #{percent} "
      bar_row = inner.y + 1
      bar = CryTUI::Rect.new(inner.x + label.size, bar_row, {inner.width - label.size, 0}.max, 1)

      buffer.set_string(inner.x, bar_row, label, Theme.heading)
      Chrome.progress_bar(buffer, bar, ratio, @frame, active: !@finished)

      return if inner.height < 3
      counts = "#{completed_items}/#{@planned_items} items"
      timing = "elapsed #{Chrome.duration(elapsed)}"
      remaining.try do |left|
        timing += " · about #{Chrome.duration(left)} left" if !@finished && left.total_seconds >= 1
      end

      spans = [
        CryTUI::Span.new(" #{counts}", Theme.info),
        CryTUI::Span.new(Theme.symbol("  │  ", "  |  "), Theme.border),
        CryTUI::Span.new(timing, Theme.hint),
      ]
      @notices.last?.try do |text|
        spans << CryTUI::Span.new(Theme.symbol("  │  ", "  |  "), Theme.border)
        spans << CryTUI::Span.new(text, Theme.warning)
      end
      CryTUI::Line.new(spans).render(buffer, CryTUI::Rect.new(inner.x, inner.y + 2, inner.width, 1))
    end

    private def activity : String
      return "done" if @finished
      return "#{Theme.spinner_glyph(@frame)} stopping after this item" if @cancelling

      where = @current_phase.empty? ? "starting" : @current_phase
      where += " · #{@current_step}" unless @current_step.empty?
      "#{Theme.spinner_glyph(@frame)} #{where}"
    end

    private def activity_style : CryTUI::Style
      return Theme.warning if @cancelling
      return @summary.failed > 0 ? Theme.failure : Theme.success if @finished
      Theme.running
    end

    private def render_body(buffer : CryTUI::Buffer, area : CryTUI::Rect) : Nil
      return if area.empty?

      output_width = @show_output && area.width >= MIN_SPLIT_WIDTH ? area.width // 2 : 0
      tree = CryTUI::Rect.new(area.x, area.y, area.width - output_width, area.height)
      @page = {tree.height - 2, 1}.max

      render_tree(buffer, tree)
      return if output_width.zero?
      render_output(buffer, CryTUI::Rect.new(area.right - output_width, area.y, output_width, area.height))
    end

    private def render_tree(buffer : CryTUI::Buffer, area : CryTUI::Rect) : Nil
      rows = nodes
      # The tree follows the run while the cursor has not been moved off the
      # end, so an unattended run always shows its newest work — and stops
      # following the moment the user scrolls up to read something.
      @cursor = {rows.size - 1, 0}.max if @follow && @pane.tree?
      @cursor = @cursor.clamp(0, {rows.size - 1, 0}.max)

      hint = @failures_only ? "failures only" : (@follow ? "following" : "paused")
      block = Chrome.panel(Theme.symbol("❖", "+"), "run", hint, rows.size, @pane.tree?, @frame)

      items = rows.map { |node| CryTUI::Widgets::ListItem.new(node_lines(node)) }
      if items.empty?
        text = @failures_only ? "no failures" : "waiting for the first step"
        items = [CryTUI::Widgets::ListItem.new([CryTUI::Line.from("  #{text}", Theme.hint)])]
      end

      @list_state.selected = rows.empty? ? nil : @cursor
      CryTUI::Widgets::List.new(items,
        style: Theme.base,
        highlight_style: Theme.selected,
        block: block
      ).render(area, buffer, @list_state)
    end

    # A row is usually one line. A failed item is two: the reason it failed is
    # the single most useful thing on the screen, and squeezing it onto the end
    # of the item's own line is how it ends up truncated to "package n" on a
    # split pane.
    private def node_lines(node : Node) : Array(CryTUI::Line)
      if item = node.item
        lines = [item_line(item)]
        item.detail.try do |detail|
          lines << CryTUI::Line.new([
            CryTUI::Span.new("        #{Theme.symbol("└", "`")} ", Theme.hint),
            CryTUI::Span.new(detail, item.state.failed? ? Theme.failure : Theme.hint),
          ])
        end
        lines
      elsif step = node.step
        [step_line(step)]
      else
        [phase_line(node.phase)]
      end
    end

    private def phase_line(phase : PhaseGroup) : CryTUI::Line
      arrow = phase.collapsed? ? Theme.symbol("▸", ">") : Theme.symbol("▾", "v")
      spans = [
        CryTUI::Span.new("#{arrow} ", Theme.hint),
        CryTUI::Span.new(phase.name, Theme.heading),
      ]
      spans << CryTUI::Span.new("  #{Theme.spinner_glyph(@frame)}", Theme.running) if phase.running?
      spans << CryTUI::Span.new("  #{Theme.symbol("✘", "x")} failed", Theme.failure) if phase.failed?
      if phase.blocked?
        spans << CryTUI::Span.new("  #{Theme.symbol("⦸", "/")} blocked by #{phase.blocked_by}", Theme.warning)
      end
      CryTUI::Line.new(spans)
    end

    private def step_line(step : StepGroup) : CryTUI::Line
      arrow = step.collapsed? ? Theme.symbol("▸", ">") : Theme.symbol("▾", "v")
      done = step.finished
      total = step.items.size
      spans = [
        CryTUI::Span.new("  #{arrow} ", Theme.hint),
        CryTUI::Span.new(step.name.ljust(24), step.failed? ? Theme.failure : Theme.base),
        CryTUI::Span.new(" #{done}/#{total}", Theme.info),
      ]
      spans << CryTUI::Span.new("  #{Theme.spinner_glyph(@frame)}", Theme.running) if step.running?
      CryTUI::Line.new(spans)
    end

    private def item_line(item : ItemRow) : CryTUI::Line
      spans = [
        CryTUI::Span.new("      #{glyph(item.state)} ", style(item.state)),
        CryTUI::Span.new(item.key.ljust(30), style(item.state)),
      ]
      item.duration.try do |span|
        spans << CryTUI::Span.new(" #{Chrome.duration(span)}", Theme.hint) if span.total_seconds >= 1
      end
      CryTUI::Line.new(spans)
    end

    private def glyph(state : ItemState) : String
      case state
      in ItemState::Pending   then Theme.symbol("·", ".")
      in ItemState::Running   then Theme.spinner_glyph(@frame)
      in ItemState::Succeeded then Theme.symbol("✔", "+")
      in ItemState::Failed    then Theme.symbol("✘", "x")
      in ItemState::Skipped   then Theme.symbol("○", "-")
      in ItemState::Preview   then Theme.symbol("~", "~")
      in ItemState::Paused    then Theme.symbol("⏸", "=")
      end
    end

    private def style(state : ItemState) : CryTUI::Style
      case state
      in ItemState::Pending   then Theme.hint
      in ItemState::Running   then Theme.running
      in ItemState::Succeeded then Theme.success
      in ItemState::Failed    then Theme.failure
      in ItemState::Skipped   then Theme.hint
      in ItemState::Preview   then Theme.info
      in ItemState::Paused    then Theme.warning
      end
    end

    # The output pane: the live tail of the whole run, or one node's own output
    # once something has been pinned with enter.
    private def render_output(buffer : CryTUI::Buffer, area : CryTUI::Rect) : Nil
      lines = visible_output
      title, hint = output_title

      block = Chrome.panel(Theme.symbol("▤", "|"), title, hint, lines.size, @pane.output?, @frame)
      block.render(area, buffer)
      inner = block.inner(area)
      return if inner.empty?

      if lines.empty?
        # An empty pane looks like a pane that is broken. Saying which kind of
        # empty it is costs one line: a preview runs no commands at all, and a
        # step can legitimately be quiet.
        CryTUI::Line.from(" #{empty_output_text}", Theme.hint)
          .render(buffer, CryTUI::Rect.new(inner.x, inner.y, inner.width, 1))
        return
      end

      # Anchored to the end while following, so the newest output is always on
      # screen; a package manager with hundreds of lines would otherwise scroll
      # past unattended.
      window = if @follow || lines.size <= inner.height
                 lines.last(inner.height)
               else
                 start = {lines.size - inner.height - @output_scroll, 0}.max
                 lines[start, inner.height]? || lines.last(inner.height)
               end

      window.each_with_index do |line, offset|
        CryTUI::Line.new(output_spans(line)).render(
          buffer, CryTUI::Rect.new(inner.x, inner.y + offset, inner.width, 1))
      end
    end

    private def visible_output : Array(OutputLine)
      pinned = @pinned
      return @log.to_a unless pinned

      @log.select do |line|
        next false unless line.phase == pinned.phase.name
        if step = pinned.step
          next false unless line.step == step.name
        end
        if item = pinned.item
          next false unless line.item == item.key
        end
        true
      end
    end

    private def empty_output_text : String
      return "this one produced no output" if @pinned
      return "a preview runs no commands, so there is none" if @mode != "live"
      "nothing has printed yet"
    end

    private def output_title : Tuple(String, String)
      pinned = @pinned
      return {"output", @follow ? "live tail · enter pins a step" : "paused · f follows"} unless pinned

      name = pinned.item.try(&.key) || pinned.step.try(&.name) || pinned.phase.name
      {"output · #{name}", "esc unpins"}
    end

    # Command output is other people's text, so it is not re-coloured by
    # keyword — a `dnf` line that happens to contain the word "error" in a
    # package description should not be painted red. Only the item prefix,
    # which Fluxion owns, is styled.
    private def output_spans(line : OutputLine) : Array(CryTUI::Span)
      return [CryTUI::Span.new(line.text, Theme.base)] if @pinned

      # The live tail mixes several items together, so each line says which one
      # it came from. A pinned view does not need the prefix — every line in it
      # is from the same place — and dropping it there gives the output back
      # the columns it was written for.
      [
        CryTUI::Span.new("#{line.item} ", Theme.hint),
        CryTUI::Span.new(line.text, Theme.base),
      ]
    end

    private def render_footer(buffer : CryTUI::Buffer, area : CryTUI::Rect) : Nil
      return if area.empty?

      parts = [] of CryTUI::Span
      parts << count_span("#{@summary.succeeded} ok", Theme.success)
      parts << count_span("#{@summary.failed} failed", @summary.failed > 0 ? Theme.failure : Theme.hint)
      parts << count_span("#{@summary.skipped} skipped", Theme.hint)
      parts << count_span("#{@summary.dry_run} would run", Theme.info) if @summary.dry_run > 0
      parts << count_span("#{@summary.paused} paused", Theme.warning) if @summary.paused > 0

      hints = if @finished
                "  q or esc to leave · j/k read the run · enter pins a step's output · ? keys"
              elsif @cancelling
                "  stopping after the current item…"
              else
                "  j/k move · h/l fold · enter pin output · f follow · e failures · o output · " \
                "? keys · q stop"
              end

      block = Chrome.panel(Theme.symbol("▸", ">"), "summary", "", nil, false, @frame)
      CryTUI::Widgets::StyledText.new(
        [CryTUI::Line.new(parts), CryTUI::Line.from(hints, Theme.hint)],
        block: block
      ).render(area, buffer)
    end

    private def count_span(text : String, style : CryTUI::Style) : CryTUI::Span
      CryTUI::Span.new("  #{text}", style)
    end

    private def help_sections : Array(Chrome::Help::Section)
      [
        Chrome::Help::Section.new("move", [
          {"j / k, ↓ / ↑", "next and previous row"},
          {"gg / G", "first and last row"},
          {"gj / gk", "next and previous phase"},
          {"<C-d> / <C-u>", "half page down and up"},
          {"tab, <C-w>w", "swap between tree and output"},
        ]),
        Chrome::Help::Section.new("fold", [
          {"h / l, ← / →", "close and open a group"},
          {"za", "toggle the fold under the cursor"},
          {"zR / zM", "open and close every fold"},
        ]),
        Chrome::Help::Section.new("output", [
          {"enter", "pin this step's output"},
          {"esc", "back to the live tail"},
          {"f", "follow the newest output"},
          {"e", "show failures only"},
          {"o", "hide or show the output pane"},
        ]),
        Chrome::Help::Section.new("run", [
          {"q, <C-c>", "stop after the current item"},
          {"<leader>ut", "next theme"},
          {"?", "this list"},
        ]),
      ]
    end
  end
end
