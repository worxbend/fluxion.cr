module Fluxion::TUI
  # The pre-run selector.
  #
  # Shown before anything mutates the host, because the moment to change your
  # mind about a bootstrap run is before it starts, not during. The profile is
  # drawn as a fold tree — phases with their steps underneath — so a fifty-step
  # profile can be read a phase at a time, and every phase and every step can
  # be selected or deselected on its own.
  #
  # Nothing here mutates the host or the state file. It produces a `Selection`,
  # and `Selection#apply` turns that into the profile the run will use.
  class SelectorScreen
    # One line of the tree, flattened so cursor movement is a single index.
    # `step` is nil on a phase heading.
    record Row, phase : Phase, step : Step?

    # Which pane the keys are talking to.
    enum Pane
      Tree
      Detail

      def next : Pane
        tree? ? Detail : Tree
      end
    end

    enum Outcome
      Continue
      Run
      Cancel
    end

    getter selection : Selection
    getter resume : Resume

    # How long a confirmation message stays on the footer. Long enough to read
    # at a glance, short enough that it is gone before it becomes furniture.
    NOTICE_FRAMES = 40

    @rows : Array(Row)
    @cursor = 0
    @collapsed = Set(String).new
    @pane = Pane::Tree
    @detail_scroll = 0
    @query = ""
    @searching = false
    @help = false
    @notice : String? = nil
    @notice_frames = 0
    @frame = 0

    def initialize(@selection : Selection, @resume : Resume = Resume.none)
      @pending = PendingSequence.new
      @list_state = CryTUI::Widgets::ListState.new(0, 0)
      @rows = build_rows
    end

    # ── Rows ─────────────────────────────────────────────────────────────────

    # The visible tree: phases always, their steps unless the phase is folded
    # or a search is filtering them out.
    #
    # Rebuilt whenever the shape changes rather than patched, because every
    # other piece of state here is an index into it and keeping those in step
    # with an incremental edit is how off-by-one bugs get in.
    private def build_rows : Array(Row)
      rows = [] of Row
      @selection.profile.phases.each do |phase|
        steps = visible_steps(phase)
        # A phase whose every step was filtered out by a search is dropped
        # entirely, so the tree shows results rather than a list of empty
        # headings to scroll past.
        next if searching? && steps.empty?

        rows << Row.new(phase, nil)
        next if collapsed?(phase.name)
        steps.each { |step| rows << Row.new(phase, step) }
      end
      rows
    end

    private def visible_steps(phase : Phase) : Array(Step)
      return phase.steps unless searching?
      phase.steps.select { |step| matches?(phase, step) }
    end

    private def matches?(phase : Phase, step : Step) : Bool
      needle = @query.downcase
      return true if phase.name.downcase.includes?(needle)
      return true if step.name.downcase.includes?(needle)
      return true if step.kind.downcase.includes?(needle)
      step.items.any?(&.key.downcase.includes?(needle))
    end

    private def searching? : Bool
      !@query.empty?
    end

    private def refresh_rows : Nil
      current = @rows[@cursor]?
      @rows = build_rows
      # Cursor follows the row it was on where that row survived the rebuild,
      # so folding a phase above you does not move you somewhere unrelated.
      if current
        index = @rows.index do |row|
          row.phase.name == current.phase.name && row.step.try(&.name) == current.step.try(&.name)
        end
        @cursor = index || @cursor
      end
      @cursor = @cursor.clamp(0, {@rows.size - 1, 0}.max)
    end

    private def collapsed?(name : String) : Bool
      @collapsed.includes?(name)
    end

    private def current : Row?
      @rows[@cursor]?
    end

    # ── Input ────────────────────────────────────────────────────────────────

    def handle(event : CryTUI::KeyEvent) : Outcome
      return handle_search(event) if @searching
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

    # One branch per binding. A keymap is a table by nature, and extracting
    # halves of it would only make a reader hunt for where a key is handled.
    private def handle_key(event : CryTUI::KeyEvent) : Outcome
      case event.code
      when .up?        then move(-1)
      when .down?      then move(1)
      when .left?      then perform(ActionKind::Collapse)
      when .right?     then perform(ActionKind::Expand)
      when .page_up?   then move(-page)
      when .page_down? then move(page)
      when .home?      then @cursor = 0
      when .end?       then @cursor = {@rows.size - 1, 0}.max
      when .tab?       then perform(ActionKind::FocusNextPane)
      when .enter?     then return run_if_possible
      when .escape?    then return clear_or_cancel
      when .character?
        return handle_character(event)
      end

      Outcome::Continue
    end

    private def handle_character(event : CryTUI::KeyEvent) : Outcome
      return Outcome::Cancel if event.character == 'c' && event.modifiers.control?

      case event.character
      when 'x' then toggle
      when 'j' then move(1)
      when 'k' then move(-1)
      when 'h' then perform(ActionKind::Collapse)
      when 'l' then perform(ActionKind::Expand)
      when 'a' then select_all
      when 'n' then select_none
      when 'i' then perform(ActionKind::InvertSelection)
      when 'o' then perform(ActionKind::SelectOnlyThis)
      when 'R' then perform(ActionKind::ResumeFromState)
      when '/' then start_search
      when '?' then @help = true
      when 'r' then return run_if_possible
      when 'q' then return Outcome::Cancel
      end

      Outcome::Continue
    end

    # ameba:disable Metrics/CyclomaticComplexity
    private def perform(action : ActionKind) : Outcome
      case action
      when .navigate_up?             then move(-1)
      when .navigate_down?           then move(1)
      when .navigate_top?            then @cursor = 0
      when .navigate_bottom?         then @cursor = {@rows.size - 1, 0}.max
      when .navigate_half_page_down? then move(page // 2)
      when .navigate_half_page_up?   then move(-(page // 2))
      when .navigate_next_group?     then jump_group(1)
      when .navigate_previous_group? then jump_group(-1)
      when .expand?                  then expand
      when .collapse?                then collapse
      when .toggle_fold?             then toggle_fold
      when .expand_all?              then unfold_all
      when .collapse_all?            then fold_all
      when .toggle_selection?        then toggle
      when .select_all?              then select_all
      when .select_none?             then select_none
      when .invert_selection?        then invert
      when .select_only_this?        then only_this
      when .resume_from_state?       then apply_resume
      when .reset_selection?         then reset_selection
      when .start_search?            then start_search
      when .focus_pane_left?         then @pane = Pane::Tree
      when .focus_pane_right?        then @pane = Pane::Detail
      when .focus_next_pane?         then @pane = @pane.next
      when .toggle_help?             then @help = !@help
      when .cycle_palette?           then notify("theme: #{Theme.cycle_palette.label}")
      when .run?                     then return run_if_possible
      when .quit?                    then return Outcome::Cancel
      end

      Outcome::Continue
    end

    private def handle_help(event : CryTUI::KeyEvent) : Outcome
      case event.code
      when .escape?, .enter? then @help = false
      when .character?
        return Outcome::Cancel if event.character == 'c' && event.modifiers.control?
        @help = false if event.character.in?('?', 'q')
      end
      Outcome::Continue
    end

    # While a search is open every printable key is text, not a command —
    # otherwise typing the name of a step would toggle half the profile.
    private def handle_search(event : CryTUI::KeyEvent) : Outcome
      case event.code
      when .escape?
        @query = ""
        @searching = false
        refresh_rows
      when .enter?
        @searching = false
      when .backspace?
        @query = @query[0...-1] unless @query.empty?
        refresh_rows
      when .character?
        return Outcome::Cancel if event.character == 'c' && event.modifiers.control?
        event.character.try do |character|
          next unless character.printable?
          @query += character
          @cursor = 0
          refresh_rows
        end
      end
      Outcome::Continue
    end

    private def start_search : Nil
      @searching = true
      @query = ""
      @cursor = 0
      refresh_rows
    end

    private def run_if_possible : Outcome
      return Outcome::Run if @selection.any_selected?
      notify("nothing selected — press a to select everything")
      Outcome::Continue
    end

    private def clear_or_cancel : Outcome
      if searching?
        @query = ""
        refresh_rows
        return Outcome::Continue
      end
      Outcome::Cancel
    end

    # ── Actions ──────────────────────────────────────────────────────────────

    private def move(delta : Int32) : Nil
      if @pane.detail?
        @detail_scroll = {@detail_scroll + delta, 0}.max
        return
      end
      return if @rows.empty?
      @cursor = (@cursor + delta).clamp(0, @rows.size - 1)
      @detail_scroll = 0
    end

    # Moves to the next or previous phase heading, which is the motion you want
    # in a profile whose phases are longer than the screen.
    private def jump_group(direction : Int32) : Nil
      return if @rows.empty?
      index = @cursor + direction
      while index >= 0 && index < @rows.size
        if @rows[index].step.nil?
          @cursor = index
          @detail_scroll = 0
          return
        end
        index += direction
      end
      @cursor = direction > 0 ? @rows.size - 1 : 0
    end

    private def toggle : Nil
      row = current
      return unless row

      if step = row.step
        @selection.toggle_step(row.phase, step)
      else
        @selection.toggle_phase(row.phase)
      end
    end

    # `h` on a step jumps to its phase heading rather than doing nothing, which
    # is what a Neovim user expects from a tree: collapse where you can, move
    # outward where you cannot.
    private def collapse : Nil
      row = current
      return unless row

      if row.step
        @cursor = phase_row_index(row.phase) || @cursor
        return
      end
      @collapsed << row.phase.name
      refresh_rows
    end

    private def expand : Nil
      row = current
      return unless row
      return if row.step

      if collapsed?(row.phase.name)
        @collapsed.delete(row.phase.name)
        refresh_rows
        return
      end
      # Already open: step into it, which makes `l` a descent rather than a
      # key that sometimes does nothing.
      move(1)
    end

    private def toggle_fold : Nil
      row = current
      return unless row
      name = row.phase.name
      collapsed?(name) ? @collapsed.delete(name) : @collapsed.add(name)
      @cursor = phase_row_index(row.phase) || @cursor if row.step
      refresh_rows
    end

    private def fold_all : Nil
      @selection.profile.phases.each { |phase| @collapsed << phase.name }
      refresh_rows
    end

    private def unfold_all : Nil
      @collapsed.clear
      refresh_rows
    end

    private def phase_row_index(phase : Phase) : Int32?
      @rows.index { |row| row.phase.name == phase.name && row.step.nil? }
    end

    private def select_all : Nil
      @selection.select_all
      notify("selected everything")
    end

    private def select_none : Nil
      @selection.select_none
      notify("cleared the selection")
    end

    private def invert : Nil
      @selection.invert
      notify("inverted the selection")
    end

    private def only_this : Nil
      row = current
      return unless row
      @selection.select_only(row.phase, row.step)
      notify("only #{row.step.try(&.name) || row.phase.name}")
    end

    private def reset_selection : Nil
      @selection.reset
      notify("back to the profile as written")
    end

    private def apply_resume : Nil
      unless @resume.available?
        notify("no saved state to resume from")
        return
      end

      turned_off = @selection.resume_from(@resume)
      notify(turned_off.zero? ? "nothing left to skip — the saved phases are already off" : "skipping #{Text.pluralize(turned_off, "phase")} the last run finished")
    end

    private def notify(message : String) : Nil
      @notice = message
      @notice_frames = NOTICE_FRAMES
    end

    # A page is a screenful, but the screen height is only known at render
    # time, so this is the last one drawn. Ten is the fallback for a key
    # pressed before the first frame.
    @page = 10

    private def page : Int32
      {@page, 1}.max
    end

    # ── Rendering ────────────────────────────────────────────────────────────

    def render(frame : CryTUI::Frame) : Nil
      area = frame.area
      buffer = frame.buffer
      @frame += 1
      @notice_frames -= 1 if @notice_frames > 0
      @notice = nil if @notice_frames <= 0

      buffer.set_style(area, Theme.canvas)

      header = CryTUI::Rect.new(area.x, area.y, area.width, {4, area.height}.min)
      # Four rows, not three: two lines of content inside a border. A footer
      # sized for one silently drops the key hints, which are the only place
      # the interface says how to drive it.
      footer_height = {4, area.height}.min
      footer = CryTUI::Rect.new(area.x, area.bottom - footer_height, area.width, footer_height)
      body = CryTUI::Rect.new(area.x, area.y + header.height, area.width,
        {area.height - header.height - footer.height, 0}.max)

      render_header(buffer, header)
      render_body(buffer, body)
      render_footer(buffer, footer)

      Chrome::WhichKey.render(buffer, area, @pending.pending, @frame)
      Chrome::Help.render(buffer, area, help_sections, @frame) if @help
    end

    private def render_header(buffer : CryTUI::Buffer, area : CryTUI::Rect) : Nil
      return if area.empty?
      profile = @selection.profile
      theme = Theme.palette

      title = " #{Theme.symbol("◈", "*")} FLUXION // BOOTSTRAP PLAN "
      spans = if Theme.rich?
                Anim.gradient_spans(title, theme.accent, theme.accent_alt, @frame, true)
              else
                [CryTUI::Span.new(title, Theme.title)]
              end
      spans << CryTUI::Span.new("  #{Theme.spinner_glyph(@frame)} ", Theme.running)
      spans << CryTUI::Span.new(profile.name, Theme.heading)
      spans << CryTUI::Span.new(Theme.symbol("  │  ", "  |  "), Theme.border)
      spans << CryTUI::Span.new(profile.target.to_s, Theme.info)
      spans << CryTUI::Span.new(Theme.symbol("  │  ", "  |  "), Theme.border)
      spans << CryTUI::Span.new(Host.facts.to_s, Theme.hint)

      lines = [CryTUI::Line.new(spans), resume_line]
      block = Chrome.panel(Theme.symbol("⚡", "#"), "profile", "", nil, false, @frame)
      CryTUI::Widgets::StyledText.new(lines, block: block).render(area, buffer)
    end

    private def resume_line : CryTUI::Line
      unless @resume.available?
        return CryTUI::Line.new([CryTUI::Span.new("  no saved state — this will run from the top", Theme.hint)])
      end

      CryTUI::Line.new([
        CryTUI::Span.new("  #{Chrome.status_dot(true)} saved state: ", Theme.info),
        CryTUI::Span.new(@resume.summary, Theme.base),
        CryTUI::Span.new("   R skips it", Theme.warning),
      ])
    end

    private def render_body(buffer : CryTUI::Buffer, area : CryTUI::Rect) : Nil
      return if area.empty?

      # The tree gets roughly two thirds. The detail pane is a confirmation of
      # what the highlighted row will do, not a place to work, so it is the one
      # that gives way on a narrow terminal.
      detail_width = area.width >= 88 ? {area.width // 3, 46}.min : 0
      tree = CryTUI::Rect.new(area.x, area.y, area.width - detail_width, area.height)
      @page = {tree.height - 2, 1}.max

      render_tree(buffer, tree)
      return if detail_width.zero?
      render_detail(buffer, CryTUI::Rect.new(area.right - detail_width, area.y, detail_width, area.height))
    end

    private def render_tree(buffer : CryTUI::Buffer, area : CryTUI::Rect) : Nil
      hint = searching? ? "match: #{@query}" : "x toggles · h/l folds"
      block = Chrome.panel(Theme.symbol("❖", "+"), "phases and steps", hint,
        @selection.profile.phases.size, @pane.tree?, @frame)

      items = @rows.map { |row| CryTUI::Widgets::ListItem.new([row_line(row)]) }
      if items.empty?
        empty = searching? ? "nothing matches #{@query}" : "this profile declares no phases"
        items = [CryTUI::Widgets::ListItem.new([CryTUI::Line.new([CryTUI::Span.new("  #{empty}", Theme.hint)])])]
      end

      @list_state.selected = @rows.empty? ? nil : @cursor
      CryTUI::Widgets::List.new(items,
        style: Theme.base,
        highlight_style: Theme.selected,
        block: block
      ).render(area, buffer, @list_state)
    end

    private def row_line(row : Row) : CryTUI::Line
      spans = [] of CryTUI::Span

      if step = row.step
        selected = @selection.step?(step.name)
        spans << CryTUI::Span.new("    ", Theme.base)
        spans << checkbox(selected)
        spans << CryTUI::Span.new(" #{step.name.ljust(26)}", selected ? Theme.base : Theme.hint)
        spans << CryTUI::Span.new(" #{step.kind.ljust(16)}", Theme.hint)
        count = step.items.size
        spans << CryTUI::Span.new(" #{Text.pluralize(count, "item")}", Theme.info)
      else
        phase = row.phase
        selected = @selection.phase?(phase.name)
        arrow = collapsed?(phase.name) ? Theme.symbol("▸", ">") : Theme.symbol("▾", "v")
        spans << CryTUI::Span.new("#{arrow} ", Theme.hint)
        spans << checkbox(selected, partial: partial?(phase))
        spans << CryTUI::Span.new(" #{phase.name}", Theme.heading)

        steps = @selection.selected_steps(phase)
        items = @selection.selected_items(phase)
        spans << CryTUI::Span.new("  #{steps}/#{phase.steps.size} steps · #{items} items", Theme.hint)

        unless phase.depends_on.empty?
          spans << CryTUI::Span.new("  after #{phase.depends_on.join(", ")}", Theme.info)
        end
        if @resume.completed?(phase.name)
          spans << CryTUI::Span.new("  #{Theme.symbol("✔", "v")} done last run", Theme.success)
        end
      end

      CryTUI::Line.new(spans)
    end

    # A phase with only some of its steps selected. Worth its own mark: `[✔]`
    # on a phase that is really half off is the one thing a selector must never
    # say.
    private def partial?(phase : Phase) : Bool
      selected = @selection.selected_steps(phase)
      selected > 0 && selected < phase.steps.size
    end

    private def checkbox(selected : Bool, partial : Bool = false) : CryTUI::Span
      return CryTUI::Span.new("[#{Theme.symbol("◼", "~")}]", Theme.warning) if partial
      return CryTUI::Span.new("[#{Theme.symbol("✔", "x")}]", Theme.success) if selected
      CryTUI::Span.new("[ ]", Theme.hint)
    end

    private def render_detail(buffer : CryTUI::Buffer, area : CryTUI::Rect) : Nil
      row = current
      lines = row ? detail_lines(row) : [CryTUI::Line.from("nothing to show", Theme.hint)]
      scroll = @detail_scroll.clamp(0, {lines.size - 1, 0}.max)

      block = Chrome.panel(Theme.symbol("≡", "="), "what this does", "j/k scrolls",
        row.try(&.step).try(&.items.size), @pane.detail?, @frame)
      CryTUI::Widgets::StyledText.new(lines, block: block, scroll: scroll).render(area, buffer)
    end

    private def detail_lines(row : Row) : Array(CryTUI::Line)
      lines = [] of CryTUI::Line

      if step = row.step
        lines << CryTUI::Line.new([CryTUI::Span.new(step.name, Theme.heading)])
        lines << CryTUI::Line.new([CryTUI::Span.new(step.kind, Theme.info)])
        lines << CryTUI::Line.new([] of CryTUI::Span)
        step.items.each do |item|
          lines << CryTUI::Line.new([
            CryTUI::Span.new("#{Theme.symbol("·", "-")} ", Theme.hint),
            CryTUI::Span.new(item.key, Theme.base),
          ])
        end
        lines << CryTUI::Line.from("no items", Theme.hint) if step.items.empty?
      else
        phase = row.phase
        lines << CryTUI::Line.new([CryTUI::Span.new(phase.name, Theme.heading)])
        phase.description.try { |text| lines << CryTUI::Line.from(text, Theme.base) }
        lines << CryTUI::Line.new([] of CryTUI::Span)
        phase.steps.each do |child|
          lines << CryTUI::Line.new([
            checkbox(@selection.step?(child.name)),
            CryTUI::Span.new(" #{child.name}", Theme.base),
            CryTUI::Span.new("  #{child.items.size}", Theme.hint),
          ])
        end
      end

      lines
    end

    private def render_footer(buffer : CryTUI::Buffer, area : CryTUI::Rect) : Nil
      return if area.empty?
      steps = @selection.selected_steps
      items = @selection.selected_items

      summary = CryTUI::Line.new([
        CryTUI::Span.new("  #{Chrome.status_dot(@selection.any_selected?)} ",
          @selection.any_selected? ? Theme.success : Theme.warning),
        CryTUI::Span.new(Text.pluralize(steps, "step"), Theme.heading),
        CryTUI::Span.new(" · ", Theme.border),
        CryTUI::Span.new("#{Text.pluralize(items, "item")} selected", Theme.base),
        CryTUI::Span.new(notice_text, Theme.warning),
      ])

      hints = if @searching
                "  /#{@query}#{Theme.symbol("▏", "_")}   enter accepts · esc clears"
              else
                "  x toggle · j/k move · h/l fold · a all · n none · i invert · / find · " \
                "enter run · ? keys · q quit"
              end

      block = Chrome.panel(Theme.symbol("▸", ">"), "selection", "", nil, false, @frame)
      CryTUI::Widgets::StyledText.new(
        [summary, CryTUI::Line.from(hints, Theme.hint)],
        block: block
      ).render(area, buffer)
    end

    private def notice_text : String
      @notice.try { |message| "    #{message}" } || ""
    end

    private def help_sections : Array(Chrome::Help::Section)
      [
        Chrome::Help::Section.new("move", [
          {"j / k, ↓ / ↑", "next and previous row"},
          {"gg / G", "first and last row"},
          {"gj / gk", "next and previous phase"},
          {"<C-d> / <C-u>", "half page down and up"},
          {"<C-w>h / l / w", "move between panes"},
        ]),
        Chrome::Help::Section.new("fold", [
          {"h / l, ← / →", "close and open a phase"},
          {"za", "toggle the fold under the cursor"},
          {"zR / zM", "open and close every fold"},
        ]),
        Chrome::Help::Section.new("select", [
          {"x, <leader><leader>", "toggle the phase or step"},
          {"a / n", "select all and none"},
          {"i", "invert the selection"},
          {"o", "select only this one"},
          {"R", "skip phases the last run finished"},
          {"<leader>sx", "reset to the profile as written"},
        ]),
        Chrome::Help::Section.new("do", [
          {"/", "find phases, steps and items"},
          {"enter / r", "start the run"},
          {"<leader>ut", "next theme"},
          {"?", "this list"},
          {"q / esc", "leave without running"},
        ]),
      ]
    end
  end
end
