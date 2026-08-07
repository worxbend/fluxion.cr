module CryTUI
  module Widgets
    # Whether a linear animation plays forwards or in reverse.
    enum Flow
      Forwards
      Backwards
    end

    # The symbol pair a LinearSpinner draws lit and unlit slots with.
    enum LinearStyle
      Classic
      Square
      Diamond
      Bar
      Braille
      Arrow

      # Arrow is the one style that has to know the axis: a right-pointing
      # arrow in a vertical column reads as the wrong direction.
      def symbols(direction : Direction = Direction::Horizontal) : Tuple(String, String)
        case self
        in .classic? then {"●", "·"}
        in .square?  then {"■", "□"}
        in .diamond? then {"◆", "◇"}
        in .bar?     then {"▰", "▱"}
        in .braille? then {"⣿", "⠀"}
        in .arrow?   then direction.horizontal? ? {"▶", "▷"} : {"▼", "▽"}
        end
      end

      # Terminal columns one slot occupies. Every current symbol is narrow;
      # callers sizing a layout multiply the slot count by this.
      def columns_per_slot : Int32
        1
      end
    end

    # A window of lit symbols scrolling along a row, or a single symbol
    # bouncing down a column.
    #
    # ```text
    # Horizontal (Forwards):   ●●·  →  ·●●  →  ··●  →  ●··
    # Vertical:                ●        ·        ·
    #                          ·   →    ●   →    ·   → bounces back
    #                          ·        ·        ●
    # ```
    struct LinearSpinner
      getter tick : Int64
      getter total_slots : Int32
      getter lit_slots : Int32
      getter ticks_per_step : Int32
      getter direction : Direction
      getter flow : Flow
      getter linear_style : LinearStyle
      getter active_style : Style
      getter inactive_style : Style
      getter style : Style
      getter block : Block?
      getter alignment : Alignment

      def initialize(tick : Int = 0,
                     total_slots : Int = 3,
                     lit_slots : Int = 2,
                     ticks_per_step : Int = 3,
                     @direction : Direction = Direction::Horizontal,
                     @flow : Flow = Flow::Forwards,
                     @linear_style : LinearStyle = LinearStyle::Classic,
                     @active_style : Style = Style.new(Color::WHITE, modifiers: Modifier::Bold),
                     @inactive_style : Style = Style.new(Color::DARK_GRAY),
                     @style : Style = Style.new,
                     @block : Block? = nil,
                     @alignment : Alignment = Alignment::Left)
        @tick = tick.to_i64
        @total_slots = {total_slots.to_i, 1}.max
        @lit_slots = {lit_slots.to_i, 1}.max
        @ticks_per_step = {ticks_per_step.to_i, 1}.max
      end

      # Rendered size in terminal cells, as {columns, rows}.
      def char_size : Tuple(Int32, Int32)
        columns = @total_slots * @linear_style.columns_per_slot
        @direction.horizontal? ? {columns, 1} : {@linear_style.columns_per_slot, @total_slots}
      end

      # The current frame, one Line per row. `height` is only consulted in
      # vertical mode, where the column is bottom-aligned inside it.
      def lines(height : Int32 = @total_slots) : Array(Line)
        case @direction
        in .horizontal? then [horizontal_line]
        in .vertical?   then vertical_lines(height)
        end
      end

      def render(area : Rect, buffer : Buffer) : Nil
        return if area.empty?
        inner = @block.try(&.inner(area)) || area
        Spinner.paint(lines(inner.height), area, buffer, @style, @block)
      end

      private def step : Int32
        cycle = @direction.vertical? ? {2 * (@total_slots - 1), 1}.max : @total_slots
        ((@tick // @ticks_per_step) % cycle).to_i32
      end

      private def horizontal_line : Line
        total = @total_slots
        lit = {@lit_slots, total}.min
        raw = step % total
        start = @flow.forwards? ? raw : (total - 1) - raw

        spans = (0...total).map do |index|
          on = if start + lit <= total
                 index >= start && index < start + lit
               else
                 # The window has run off the end and re-entered at the left.
                 index >= start || index < (start + lit) % total
               end
          slot_span(on)
        end

        Line.new(spans, @alignment)
      end

      # `0, 1, …, n-1, n-2, …, 1` — a ping-pong over a cycle of `2 * (n - 1)`.
      private def bounce_index : Int32
        n = @total_slots
        return 0 if n == 1
        cycle = 2 * (n - 1)
        position = step % cycle
        index = position < n ? position : cycle - position
        @flow.forwards? ? index : (n - 1) - index
      end

      private def vertical_lines(height : Int32) : Array(Line)
        height = {height, 1}.max
        active = bounce_index
        rendered = Array.new(height) { Line.new }

        # Pinned to the bottom rows so the column sits beside the newest line
        # when it is used as a side-column activity indicator.
        start = {height - @total_slots, 0}.max
        {@total_slots, height}.min.times do |index|
          rendered[start + index] = Line.new([slot_span(index == active)], @alignment)
        end

        rendered
      end

      private def slot_span(lit : Bool) : Span
        on, off = @linear_style.symbols(@direction)
        lit ? Span.new(on, @active_style) : Span.new(off, @inactive_style)
      end
    end
  end
end
