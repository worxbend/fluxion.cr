module Fluxion::TUI
  # The pre-run selector.
  #
  # Shown before anything mutates the host, because the moment to change your
  # mind about a bootstrap run is before it starts, not during. Rendered as one
  # flat list of phases and their steps rather than a drill-down: the whole
  # profile fits on a screen, and nesting would hide what is about to happen.
  class SelectorScreen
    # One line of the list, flattened so cursor movement is a single index.
    record Row, phase : Phase, step : Step?

    getter selection : Selection

    @rows : Array(Row)
    @cursor = 0
    @scroll = 0

    def initialize(@selection : Selection)
      @rows = build_rows
    end

    private def build_rows : Array(Row)
      rows = [] of Row
      @selection.profile.phases.each do |phase|
        rows << Row.new(phase, nil)
        phase.steps.each { |step| rows << Row.new(phase, step) }
      end
      rows
    end

    enum Outcome
      Continue
      Run
      Cancel
    end

    # One branch per binding. A keymap is a table by nature, and extracting
    # halves of it would only make a reader hunt for where a key is handled.
    #
    # ameba:disable Metrics/CyclomaticComplexity
    def handle(event : CryTUI::KeyEvent) : Outcome
      case event.code
      when .up?        then move(-1)
      when .down?      then move(1)
      when .page_up?   then move(-10)
      when .page_down? then move(10)
      when .home?      then @cursor = 0
      when .end?       then @cursor = Math.max(0, @rows.size - 1)
      when .enter?     then return @selection.any_selected? ? Outcome::Run : Outcome::Continue
      when .escape?    then return Outcome::Cancel
      when .character?
        case event.character
        when ' ' then toggle
        when 'j' then move(1)
        when 'k' then move(-1)
        when 'a' then @selection.select_all
        when 'n' then @selection.select_none
        when 'r' then return @selection.any_selected? ? Outcome::Run : Outcome::Continue
        when 'q' then return Outcome::Cancel
        when 'c' then return Outcome::Cancel if event.modifiers.control?
        end
      end

      Outcome::Continue
    end

    private def move(delta : Int32) : Nil
      return if @rows.empty?
      @cursor = (@cursor + delta).clamp(0, @rows.size - 1)
    end

    private def toggle : Nil
      row = @rows[@cursor]?
      return unless row

      if step = row.step
        @selection.toggle_step(row.phase, step)
      else
        @selection.toggle_phase(row.phase)
      end
    end

    def render(frame : CryTUI::Frame) : Nil
      area = frame.area
      buffer = frame.buffer

      header = CryTUI::Rect.new(area.x, area.y, area.width, 3)
      footer = CryTUI::Rect.new(area.x, area.bottom - 3, area.width, 3)
      list = CryTUI::Rect.new(area.x, area.y + 3, area.width, Math.max(0, area.height - 6))

      render_header(buffer, header)
      render_list(buffer, list)
      render_footer(buffer, footer)
    end

    private def render_header(buffer : CryTUI::Buffer, area : CryTUI::Rect) : Nil
      profile = @selection.profile
      Theme.line(buffer, area, area.y, " Fluxion — choose what to run", Theme.title)
      Theme.line(buffer, area, area.y + 1,
        "  #{profile.name}  ·  #{profile.target}  ·  #{Host.facts}", Theme.dim)
    end

    private def render_list(buffer : CryTUI::Buffer, area : CryTUI::Rect) : Nil
      inner = Theme.frame(buffer, area, "phases and steps")
      return if inner.height <= 0

      # Keep the cursor on screen by scrolling the window, not the cursor.
      @scroll = @cursor if @cursor < @scroll
      @scroll = @cursor - inner.height + 1 if @cursor >= @scroll + inner.height
      @scroll = Math.max(0, @scroll)

      visible = @rows[@scroll, inner.height]? || [] of Row
      visible.each_with_index do |row, offset|
        index = @scroll + offset
        Theme.line(buffer, inner, inner.y + offset, render_row(row), style_for(row, index))
      end
    end

    private def render_row(row : Row) : String
      if step = row.step
        mark = @selection.step?(step.name) ? "✔" : " "
        count = step.items.size
        "    [#{mark}] #{step.name.ljust(28)} #{step.kind.ljust(20)} #{count} item#{"s" if count != 1}"
      else
        mark = @selection.phase?(row.phase.name) ? "✔" : " "
        dependencies = row.phase.depends_on.empty? ? "" : "  after: #{row.phase.depends_on.join(", ")}"
        "[#{mark}] #{row.phase.name}#{dependencies}"
      end
    end

    private def style_for(row : Row, index : Int32) : CryTUI::Style
      return Theme.selected if index == @cursor
      return Theme.heading unless row.step
      enabled = row.step.try { |step| @selection.step?(step.name) } || false
      enabled ? Theme.base : Theme.dim
    end

    private def render_footer(buffer : CryTUI::Buffer, area : CryTUI::Rect) : Nil
      steps = @selection.selected_steps
      items = @selection.selected_items

      summary = "  #{steps} step#{"s" if steps != 1} · #{items} item#{"s" if items != 1} selected"
      Theme.line(buffer, area, area.y, summary,
        @selection.any_selected? ? Theme.success : Theme.warning)

      Theme.line(buffer, area, area.y + 1,
        "  ↑↓/jk move · space toggle · a all · n none · enter/r run · q cancel", Theme.hint)
    end
  end
end
