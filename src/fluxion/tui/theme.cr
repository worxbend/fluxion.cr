module Fluxion::TUI
  # Colours and glyphs for the terminal UI.
  #
  # Kept in one place so a status means the same thing on every screen: the
  # selector's checkmark and the execution screen's are the same green, and a
  # failure is the same red in both.
  module Theme
    extend self

    def base : CryTUI::Style
      CryTUI::Style.new
    end

    def dim : CryTUI::Style
      CryTUI::Style.new(CryTUI::Color::DARK_GRAY)
    end

    def title : CryTUI::Style
      CryTUI::Style.new(CryTUI::Color::CYAN, modifiers: CryTUI::Modifier::Bold)
    end

    def heading : CryTUI::Style
      CryTUI::Style.new(modifiers: CryTUI::Modifier::Bold)
    end

    def selected : CryTUI::Style
      # Reversed rather than coloured: it survives any terminal palette, which
      # a background colour does not.
      CryTUI::Style.new(modifiers: CryTUI::Modifier::Reversed)
    end

    def success : CryTUI::Style
      CryTUI::Style.new(CryTUI::Color::GREEN)
    end

    def failure : CryTUI::Style
      CryTUI::Style.new(CryTUI::Color::RED, modifiers: CryTUI::Modifier::Bold)
    end

    def warning : CryTUI::Style
      CryTUI::Style.new(CryTUI::Color::YELLOW)
    end

    def running : CryTUI::Style
      CryTUI::Style.new(CryTUI::Color::CYAN)
    end

    def hint : CryTUI::Style
      CryTUI::Style.new(CryTUI::Color::DARK_GRAY)
    end

    # Box drawing, so a panel is described once.
    def frame(buffer : CryTUI::Buffer, area : CryTUI::Rect, label : String, style : CryTUI::Style = dim) : CryTUI::Rect
      return area if area.width < 2 || area.height < 2

      top = "┌" + ("─" * (area.width - 2)) + "┐"
      bottom = "└" + ("─" * (area.width - 2)) + "┘"

      buffer.set_string(area.x, area.y, top, style)
      buffer.set_string(area.x, area.bottom - 1, bottom, style)

      (area.top + 1...area.bottom - 1).each do |row|
        buffer.set_string(area.x, row, "│", style)
        buffer.set_string(area.right - 1, row, "│", style)
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
