module Fluxion::TUI
  # The furniture every screen is built from: panels, the progress bar, and the
  # overlays that float above both screens.
  #
  # Described once so the two screens cannot drift apart — a panel on the
  # selector and a panel on the execution screen are the same panel, and the
  # which-key menu looks the same whichever screen opened it.
  module Chrome
    extend self

    alias W = CryTUI::Widgets

    # A titled panel. The title carries a gradient and a count badge, and the
    # border thickens and brightens when the pane has focus — which is the only
    # thing distinguishing the pane your keys are talking to from the one
    # beside it.
    def panel(icon : String, label : String, hint : String, count : Int32?, focused : Bool,
              frame : Int) : W::Block
      theme = Theme.palette
      heading = " #{icon}  #{label} "
      spans = if Theme.rich?
                Anim.gradient_spans(heading, theme.accent, theme.accent_alt, frame, true)
              else
                [CryTUI::Span.new(heading, Theme.title)]
              end

      count.try do |value|
        spans << CryTUI::Span.new(" #{value.to_s.rjust(2, '0')} ", Theme.badge)
      end
      spans << CryTUI::Span.new("  #{hint} ", Theme.hint) unless hint.empty?

      border_color = if focused && Theme.rich?
                       Anim.blend(theme.border_focus, theme.accent_alt, Anim.pulse(frame, 40) * 0.4)
                     elsif focused
                       theme.border_focus
                     else
                       theme.border
                     end

      W::Block.new(
        title: CryTUI::Line.new(spans),
        style: CryTUI::Style.new(background: theme.background),
        border_style: CryTUI::Style.new(foreground: border_color),
        border_set: focused ? Theme.focused_border_set : Theme.border_set
      )
    end

    def status_dot(active : Bool) : String
      active ? Theme.symbol("●", "*") : Theme.symbol("○", "-")
    end

    # How long something has been running. `mm:ss` until the first hour so the
    # common case stays narrow.
    def duration(span : Time::Span?) : String
      return "--:--" unless span
      total = span.total_seconds.to_i64
      hours = total // 3600
      minutes = (total % 3600) // 60
      seconds = total % 60
      hours > 0 ? "%02d:%02d:%02d" % {hours, minutes, seconds} : "%02d:%02d" % {minutes, seconds}
    end

    # The progress bar: a determinate fraction of the run, drawn as a gradient
    # that travels from `accent` to `accent_alt` across the filled part.
    #
    # A fraction rather than a sweep, because by the time this is on screen the
    # work has already been chosen — the selector counted every item the run
    # will touch — so the bar can honestly say how much of it is behind us. The
    # leading cell is a partial block, so the bar advances smoothly instead of
    # jumping a whole cell at a time on a wide terminal.
    EIGHTHS = ["", "▏", "▎", "▍", "▌", "▋", "▊", "▉"]

    def progress_bar(buffer : CryTUI::Buffer, area : CryTUI::Rect, ratio : Float64, frame : Int,
                     active : Bool = true) : Nil
      return if area.empty? || area.width <= 0
      theme = Theme.palette
      ratio = ratio.clamp(0.0, 1.0)

      unless Theme.rich?
        filled = (area.width * ratio).round.to_i
        (0...area.width).each do |column|
          symbol = column < filled ? "#" : "."
          buffer.set_string(area.x + column, area.y, symbol,
            column < filled ? Theme.running : Theme.hint)
        end
        return
      end

      exact = area.width * ratio
      full = exact.floor.to_i
      remainder = ((exact - full) * 8).round.to_i.clamp(0, 7)

      (0...area.width).each do |column|
        position = area.width <= 1 ? 0.0 : column.to_f / (area.width - 1)
        if column < full
          # A slow shimmer along the filled part while work is in flight, so a
          # bar that has stopped advancing still looks different from a bar
          # attached to a wedged install.
          shimmer = active ? Anim.pulse(frame - column * 2, 36) * 0.25 : 0.0
          color = Anim.blend(Anim.blend(theme.accent, theme.accent_alt, position), theme.foreground, shimmer)
          buffer.set_string(area.x + column, area.y, "█", CryTUI::Style.new(foreground: color))
        elsif column == full && remainder > 0
          color = Anim.blend(theme.accent, theme.accent_alt, position)
          buffer.set_string(area.x + column, area.y, EIGHTHS[remainder],
            CryTUI::Style.new(foreground: color, background: theme.border))
        else
          buffer.set_string(area.x + column, area.y, "░", CryTUI::Style.new(foreground: theme.border))
        end
      end
    end

    # Clears a rectangle to the palette's own background.
    #
    # An overlay inherits whatever the panels underneath already painted, so
    # without this the menu would be legible only where the screen behind it
    # happened to be empty.
    def clear(buffer : CryTUI::Buffer, area : CryTUI::Rect) : Nil
      style = CryTUI::Style.new(Theme.palette.foreground, Theme.palette.background)
      blank = " " * area.width
      (area.y...area.bottom).each { |row| buffer.set_string(area.x, row, blank, style) }
    end

    # A box centred in `area`, clamped so it always fits.
    def centred(area : CryTUI::Rect, width : Int32, height : Int32) : CryTUI::Rect
      width = width.clamp(0, area.width)
      height = height.clamp(0, area.height)
      CryTUI::Rect.new(
        area.x + (area.width - width) // 2,
        area.y + (area.height - height) // 2,
        width,
        height
      )
    end

    # The menu that opens while a key sequence is half typed, listing what can
    # be pressed next.
    #
    # Drawn last so it floats over the screen, and anchored to the bottom
    # because that is where a Neovim user's eye already goes for it.
    module WhichKey
      extend self

      COLUMN_GAP =  2
      MAX_HEIGHT = 12

      def render(buffer : CryTUI::Buffer, area : CryTUI::Rect, pending : String, frame : Int) : Nil
        return if pending.empty?
        entries = Keymap.continuations(pending)
        return if entries.empty? || area.width < 20 || area.height < 5

        width = {entry_width(entries) + 2, area.width - 4}.min
        columns = {(area.width - 4) // {width, 1}.max, 1}.max
        rows = {(entries.size + columns - 1) // columns, MAX_HEIGHT}.min
        columns = {(entries.size + rows - 1) // rows, columns}.min

        box = CryTUI::Rect.new(
          area.x + 2,
          {area.bottom - rows - 4, area.y}.max,
          {columns * width + 2, area.width - 4}.min,
          {rows + 2, area.height}.min
        )
        return if box.empty?

        Chrome.clear(buffer, box)
        block = Chrome.panel(Theme.symbol("⌨", "keys"), Keymap.title(pending), "", nil, true, frame)
        block.render(box, buffer)
        inner = block.inner(box)

        entries.each_with_index do |entry, index|
          column = index // rows
          row = index % rows
          break if row >= inner.height
          x = inner.x + column * width
          next if x >= inner.right
          CryTUI::Line.new(spans(entry)).render(
            buffer, CryTUI::Rect.new(x, inner.y + row, {width - COLUMN_GAP, inner.right - x}.min, 1))
        end
      end

      private def spans(entry : Keymap::Entry) : Array(CryTUI::Span)
        label_style = entry.group ? CryTUI::Style.new(Theme.palette.accent_alt) : Theme.base
        [
          CryTUI::Span.new(entry.token, Theme.title),
          CryTUI::Span.new("  ", Theme.hint),
          CryTUI::Span.new("#{entry.group ? "+" : ""}#{entry.label}", label_style),
        ]
      end

      private def entry_width(entries : Array(Keymap::Entry)) : Int32
        entries.max_of { |entry| entry.token.size + entry.label.size + 5 }
      end
    end

    # The full keybinding reference, on `?`.
    #
    # Every binding the screen understands, in one place, because a keyboard-
    # driven interface that hides its keys is a keyboard-driven interface
    # nobody drives.
    module Help
      extend self

      # Wide enough for the longest sequence any section lists, so a key and
      # its description never run together.
      KEY_COLUMN = 21

      record Section, title : String, rows : Array(Tuple(String, String))

      def render(buffer : CryTUI::Buffer, area : CryTUI::Rect, sections : Array(Section), frame : Int) : Nil
        lines = [] of CryTUI::Line
        sections.each_with_index do |section, index|
          lines << CryTUI::Line.new([] of CryTUI::Span) if index > 0
          lines << CryTUI::Line.new([CryTUI::Span.new(section.title.upcase, Theme.heading)])
          section.rows.each do |keys, description|
            lines << CryTUI::Line.new([
              CryTUI::Span.new("  #{keys.ljust(KEY_COLUMN)}", Theme.title),
              CryTUI::Span.new(description, Theme.base),
            ])
          end
        end

        width = {lines.max_of(&.width) + 6, area.width - 4}.min
        box = Chrome.centred(area, width, {lines.size + 4, area.height - 2}.min)
        return if box.empty?

        Chrome.clear(buffer, box)
        block = Chrome.panel(Theme.symbol("◈", "?"), "keybindings", "? or esc to close", nil, true, frame)
        W::StyledText.new(lines, block: block).render(box, buffer)
      end
    end
  end
end
