module Fluxion::TUI
  # Every spinner animation and widget, side by side and moving.
  #
  # Four pages rather than one screen: the frame presets alone need twenty-one
  # rows, and a gallery that only fits on a maximised terminal is a gallery
  # nobody looks at.
  class SpinnerGallery
    alias W = CryTUI::Widgets

    enum Page
      Frames
      Bars
      Linear
      Rings

      def title : String
        case self
        in .frames? then "frame presets"
        in .bars?   then "bar spinner"
        in .linear? then "linear spinner"
        in .rings?  then "ring spinners"
        end
      end
    end

    enum Outcome
      Continue
      Quit
    end

    FRAME_INTERVAL = 80.milliseconds

    getter page : Page

    def initialize(@page : Page = Page::Frames)
      @tick = 0_i64
    end

    # Draws until the user quits.
    #
    # Input and animation cannot both own the loop, so keys are read on their
    # own fiber and the draw loop waits on whichever arrives first — a key or
    # the next frame deadline.
    def self.run(page : Page = Page::Frames) : Nil
      gallery = new(page)
      keys = Channel(CryTUI::KeyEvent).new(16)

      spawn do
        parser = CryTUI::InputParser.new
        buffer = Bytes.new(1024)
        loop do
          read = STDIN.read(buffer)
          break if read.zero?
          parser.feed(String.new(buffer[0, read])).each do |event|
            keys.send(event) if event.is_a?(CryTUI::KeyEvent)
          end
        end
      rescue IO::Error
      end

      App.terminal do |terminal|
        loop do
          terminal.draw { |frame| gallery.render(frame) }
          select
          when event = keys.receive
            break if gallery.handle(event).quit?
          when timeout(FRAME_INTERVAL)
            # Nothing pressed; redraw the next animation frame.
          end
        end
      end
    end

    def handle(event : CryTUI::KeyEvent) : Outcome
      case event.code
      when .escape?        then return Outcome::Quit
      when .right?, .down? then @page = next_page(1)
      when .left?, .up?    then @page = next_page(-1)
      when .character?
        case event.character
        when 'q'      then return Outcome::Quit
        when 'c'      then return Outcome::Quit if event.modifiers.control?
        when 'l', 'j' then @page = next_page(1)
        when 'h', 'k' then @page = next_page(-1)
        when ' '      then @page = next_page(1)
        end
      end
      Outcome::Continue
    end

    def render(frame : CryTUI::Frame) : Nil
      area = frame.area
      buffer = frame.buffer
      @tick += 1

      header = CryTUI::Rect.new(area.x, area.y, area.width, 2)
      footer = CryTUI::Rect.new(area.x, area.bottom - 1, area.width, 1)
      body = CryTUI::Rect.new(area.x, area.y + 2, area.width, Math.max(0, area.height - 3))

      Theme.line(buffer, header, header.y, " Fluxion — spinners · #{@page.title}", Theme.title)
      Theme.line(buffer, header, header.y + 1,
        "  #{@page.to_s.downcase} (#{@page.value + 1}/#{Page.names.size})", Theme.dim)

      inner = Theme.frame(buffer, body, @page.title)
      case @page
      in .frames? then render_frames(buffer, inner)
      in .bars?   then render_bars(buffer, inner)
      in .linear? then render_linear(buffer, inner)
      in .rings?  then render_rings(buffer, inner)
      end

      Theme.line(buffer, footer, footer.y,
        "  ←/→ or space to change page · q to quit · FLUXION_SPINNER=#{Spinners.name}", Theme.hint)
    end

    private def next_page(step : Int32) : Page
      count = Page.names.size
      Page.new((@page.value + step + count) % count)
    end

    # Every preset, one per row, spilling into further columns only when the
    # terminal is too short to hold them all.
    private def render_frames(buffer : CryTUI::Buffer, area : CryTUI::Rect) : Nil
      return if area.empty?
      names = W::FluxFrames.names
      label_width = names.max_of(&.size)
      glyphs = 8
      column_width = label_width + glyphs + 3

      rows = Math.min(area.height, names.size)
      columns = Math.min((names.size + rows - 1) // rows, Math.max(1, area.width // column_width))
      rows = (names.size + columns - 1) // columns

      names.each_with_index do |name, index|
        row = index % rows
        next if row >= area.height
        x = area.x + (index // rows) * column_width
        break if x + label_width + glyphs > area.right

        frames = W::FluxFrames.named?(name) || W::FluxFrames::BRAILLE
        buffer.set_string(x, area.y + row, name.ljust(label_width + 1), Theme.dim, area.right - x)
        W::FluxSpinner.new(tick: @tick, frames: frames, width: glyphs, glyph_style: Theme.running)
          .render(CryTUI::Rect.new(x + label_width + 1, area.y + row, glyphs, 1), buffer)
      end
    end

    # One row per glyph set on the left, the four motions on the right, so the
    # two independent choices can be compared without flipping pages.
    private def render_bars(buffer : CryTUI::Buffer, area : CryTUI::Rect) : Nil
      return if area.empty?
      styles = [
        {"braille", W::BarStyle::Braille}, {"block", W::BarStyle::Block},
        {"shade", W::BarStyle::Shade}, {"dot", W::BarStyle::Dot},
        {"diamond", W::BarStyle::Diamond}, {"square", W::BarStyle::Square},
        {"star", W::BarStyle::Star}, {"heart", W::BarStyle::Heart},
        {"arrow", W::BarStyle::Arrow}, {"circle", W::BarStyle::Circle},
        {"spark", W::BarStyle::Spark}, {"cross", W::BarStyle::Cross},
        {"progress", W::BarStyle::Progress}, {"thick", W::BarStyle::Thick},
        {"wave", W::BarStyle::Wave}, {"pip", W::BarStyle::Pip},
      ]
      motions = [
        {"bounce", W::BarMotion::Bounce}, {"loop", W::BarMotion::Loop},
        {"squeeze", W::BarMotion::Squeeze}, {"radiate", W::BarMotion::Radiate},
      ]

      # The vertical bar is the one thing here that needs full height, so its
      # strip is carved off first and the two horizontal halves share the rest.
      label_width = 9
      vertical_width = area.width >= 60 ? 8 : 0
      usable = area.width - vertical_width
      half = usable // 2

      styles.each_with_index do |(name, style), index|
        break if index >= area.height
        buffer.set_string(area.x, area.y + index, name.ljust(label_width), Theme.dim, area.width)
        bar = CryTUI::Rect.new(area.x + label_width, area.y + index,
          Math.max(0, half - label_width - 1), 1)
        next if bar.empty?
        W::BarSpinner.new(tick: @tick, bar_style: style, arc_style: Theme.running, dim_style: Theme.hint)
          .render(bar, buffer)
      end

      right = area.x + half
      motions.each_with_index do |(name, motion), index|
        row = area.y + index * 2
        break if row + 1 >= area.y + area.height
        buffer.set_string(right, row, name, Theme.dim, Math.max(0, usable - half))
        bar = CryTUI::Rect.new(right, row + 1, Math.max(0, usable - half - 1), 1)
        next if bar.empty?
        W::BarSpinner.new(tick: @tick, motion: motion, arc_style: Theme.running, dim_style: Theme.hint)
          .render(bar, buffer)
      end

      return if vertical_width.zero? || area.height < 4
      column = area.x + usable + 2
      buffer.set_string(column, area.y, "vert", Theme.dim, 4)
      W::BarSpinner.new(tick: @tick, orientation: CryTUI::Direction::Vertical, width: 2,
        arc_style: Theme.running, dim_style: Theme.hint)
        .render(CryTUI::Rect.new(column, area.y + 1, 2, area.height - 1), buffer)
    end

    private def render_linear(buffer : CryTUI::Buffer, area : CryTUI::Rect) : Nil
      return if area.empty?
      styles = [
        {"classic", W::LinearStyle::Classic}, {"square", W::LinearStyle::Square},
        {"diamond", W::LinearStyle::Diamond}, {"bar", W::LinearStyle::Bar},
        {"braille", W::LinearStyle::Braille}, {"arrow", W::LinearStyle::Arrow},
      ]

      styles.each_with_index do |(name, style), index|
        break if index >= area.height
        row = area.y + index
        buffer.set_string(area.x, row, name.ljust(9), Theme.dim, area.width)

        # Forwards and backwards on the same row: the difference between them
        # is only visible when they are next to each other.
        W::LinearSpinner.new(tick: @tick, linear_style: style, total_slots: 6, lit_slots: 2,
          active_style: Theme.running, inactive_style: Theme.hint)
          .render(CryTUI::Rect.new(area.x + 9, row, 6, 1), buffer)
        W::LinearSpinner.new(tick: @tick, linear_style: style, total_slots: 6, lit_slots: 2,
          flow: W::Flow::Backwards, active_style: Theme.warning, inactive_style: Theme.hint)
          .render(CryTUI::Rect.new(area.x + 17, row, 6, 1), buffer)
      end

      column = area.x + 27
      slots = Math.min(5, area.height - 1)
      return if column + styles.size * 3 > area.right || slots < 2
      buffer.set_string(column, area.y, "vertical", Theme.dim, area.right - column)
      styles.each_with_index do |(_, style), index|
        # Exactly `slots` rows: a vertical spinner pins itself to the bottom of
        # whatever area it is handed, so a taller one would sit off on its own.
        W::LinearSpinner.new(tick: @tick, linear_style: style, direction: CryTUI::Direction::Vertical,
          total_slots: slots, active_style: Theme.running, inactive_style: Theme.hint)
          .render(CryTUI::Rect.new(column + index * 3, area.y + 1, 1, slots), buffer)
      end
    end

    private def render_rings(buffer : CryTUI::Buffer, area : CryTUI::Rect) : Nil
      return if area.empty?
      cursor = area.x

      cursor = place(buffer, area, cursor, "square 2", W::SquareSpinner.new(tick: @tick, size: 2,
        arc_style: Theme.running, dim_style: Theme.hint))
      cursor = place(buffer, area, cursor, "square 4", W::SquareSpinner.new(tick: @tick, size: 4,
        arc_style: Theme.running, dim_style: Theme.hint))
      cursor = place(buffer, area, cursor, "hollow 4", W::SquareSpinner.new(tick: @tick, size: 4,
        centre: W::Centre::Empty, arc_style: Theme.running, dim_style: Theme.hint))
      cursor = place(buffer, area, cursor, "ccw 4", W::SquareSpinner.new(tick: @tick, size: 4,
        spin: W::Spin::CounterClockwise, arc_style: Theme.warning, dim_style: Theme.hint))
      cursor = place(buffer, area, cursor, "circle 4", W::CircleSpinner.new(tick: @tick, radius: 4,
        arc_style: Theme.running, dim_style: Theme.hint))
      cursor = place(buffer, area, cursor, "circle 8", W::CircleSpinner.new(tick: @tick, radius: 8,
        arc_style: Theme.running, dim_style: Theme.hint))
      place(buffer, area, cursor, "circle ccw", W::CircleSpinner.new(tick: @tick, radius: 8,
        spin: W::Spin::CounterClockwise, arc_style: Theme.warning, dim_style: Theme.hint))
    end

    # Draws one labelled ring and returns the column the next one starts at.
    private def place(buffer : CryTUI::Buffer, area : CryTUI::Rect, x : Int32, label : String,
                      spinner : W::SquareSpinner | W::CircleSpinner) : Int32
      columns, rows = spinner.char_size
      width = Math.max(columns, label.size)
      return x if x + width > area.right || rows + 1 > area.height

      buffer.set_string(x, area.y, label, Theme.dim, area.right - x)
      spinner.render(CryTUI::Rect.new(x, area.y + 1, columns, rows), buffer)
      x + width + 2
    end
  end
end
