module Fluxion::TUI
  # Colours, glyphs and box drawing for the terminal UI.
  #
  # Kept in one place so a status means the same thing on every screen: the
  # selector's checkmark and the execution screen's are the same green, and a
  # failure is the same red in both.
  #
  # Every style is derived from the active `Palette` rather than naming a
  # colour, which is what lets `<leader>ut` recolour the whole interface
  # between two frames without a single screen knowing it happened.
  module Theme
    extend self

    @@palette : Palette = Palette.from_environment

    def palette : Palette
      @@palette
    end

    def palette=(palette : Palette) : Palette
      @@palette = palette
    end

    # Moves to the next palette in the catalogue and returns it, for the
    # runtime theme switcher.
    def cycle_palette : Palette
      @@palette = Palette.after(@@palette)
    end

    # Whether the interface may use box drawing, gradients and braille.
    #
    # A terminal that cannot render them shows mojibake instead, which is worse
    # than plain ASCII, so `FLUXION_ASCII=1` (or a `mono` palette, which is the
    # palette people pick precisely because their terminal is limited) drops
    # everything back to characters that exist in every font.
    def rich? : Bool
      return false if ENV["FLUXION_ASCII"]?.try { |value| !value.empty? && value != "0" }
      @@palette.id != "mono"
    end

    # Picks between a decorated glyph and its plain-ASCII stand-in.
    def symbol(rich : String, plain : String) : String
      rich? ? rich : plain
    end

    def border_set : CryTUI::Widgets::BorderSet
      rich? ? CryTUI::Widgets::BorderSet::ROUNDED : CryTUI::Widgets::BorderSet::ASCII
    end

    def focused_border_set : CryTUI::Widgets::BorderSet
      rich? ? CryTUI::Widgets::BorderSet::THICK : CryTUI::Widgets::BorderSet::ASCII
    end

    # ── Roles ────────────────────────────────────────────────────────────────

    def base : CryTUI::Style
      CryTUI::Style.new(palette.foreground)
    end

    # The ground the whole screen is painted on. Set on the full frame first so
    # no cell keeps whatever the terminal had behind it, which is what stops a
    # light palette showing through as stripes on a dark terminal.
    def canvas : CryTUI::Style
      CryTUI::Style.new(palette.foreground, palette.background)
    end

    def dim : CryTUI::Style
      CryTUI::Style.new(palette.muted)
    end

    def title : CryTUI::Style
      CryTUI::Style.new(palette.accent, modifiers: CryTUI::Modifier::Bold)
    end

    def heading : CryTUI::Style
      CryTUI::Style.new(palette.foreground, modifiers: CryTUI::Modifier::Bold)
    end

    def selected : CryTUI::Style
      CryTUI::Style.new(palette.highlight_foreground, palette.highlight_background,
        modifiers: CryTUI::Modifier::Bold)
    end

    def success : CryTUI::Style
      CryTUI::Style.new(palette.success)
    end

    def failure : CryTUI::Style
      CryTUI::Style.new(palette.danger, modifiers: CryTUI::Modifier::Bold)
    end

    def warning : CryTUI::Style
      CryTUI::Style.new(palette.warning)
    end

    def running : CryTUI::Style
      CryTUI::Style.new(palette.accent)
    end

    def info : CryTUI::Style
      CryTUI::Style.new(palette.info)
    end

    def hint : CryTUI::Style
      CryTUI::Style.new(palette.muted)
    end

    def border : CryTUI::Style
      CryTUI::Style.new(palette.border)
    end

    def border_focus : CryTUI::Style
      CryTUI::Style.new(palette.border_focus)
    end

    def badge : CryTUI::Style
      CryTUI::Style.new(palette.badge_foreground, palette.badge_background,
        modifiers: CryTUI::Modifier::Bold)
    end

    # ── Drawing ──────────────────────────────────────────────────────────────

    # The glyph for anything in flight, at the given animation tick.
    #
    # One frame of the configured spinner rather than a fixed arrow: a static
    # marker beside a package install that takes two minutes is
    # indistinguishable from a hung run.
    def spinner_glyph(tick : Int) : String
      CryTUI::Widgets::FluxSpinner.new(tick: tick, frames: Spinners.frames).frame
    end

    # A sweeping bar that says work is still happening, without claiming to
    # know how much is left.
    def activity_bar(buffer : CryTUI::Buffer, area : CryTUI::Rect, tick : Int) : Nil
      return if area.empty?
      CryTUI::Widgets::BarSpinner.new(
        tick: tick,
        motion: CryTUI::Widgets::BarMotion::Loop,
        arc_style: running,
        dim_style: hint
      ).render(area, buffer)
    end

    # Box drawing, so a panel is described once.
    def frame(buffer : CryTUI::Buffer, area : CryTUI::Rect, label : String,
              style : CryTUI::Style = border) : CryTUI::Rect
      return area if area.width < 2 || area.height < 2

      set = border_set
      top = set.top_left + (set.horizontal * (area.width - 2)) + set.top_right
      bottom = set.bottom_left + (set.horizontal * (area.width - 2)) + set.bottom_right

      buffer.set_string(area.x, area.y, top, style)
      buffer.set_string(area.x, area.bottom - 1, bottom, style)

      (area.top + 1...area.bottom - 1).each do |row|
        buffer.set_string(area.x, row, set.vertical, style)
        buffer.set_string(area.right - 1, row, set.vertical, style)
      end

      unless label.empty?
        buffer.set_string(area.x + 2, area.y, " #{label} ", title)
      end

      CryTUI::Rect.new(area.x + 2, area.y + 1, Math.max(0, area.width - 4), Math.max(0, area.height - 2))
    end

    # Writes a line clipped to the area, so long content never wraps into the
    # frame it sits inside.
    def line(buffer : CryTUI::Buffer, area : CryTUI::Rect, row : Int32, text : String,
             style : CryTUI::Style = base) : Nil
      return if row < area.top || row >= area.bottom
      buffer.set_string(area.x, row, text, style, area.width)
    end
  end
end
