module CryTUI
  module Widgets
    # Rotation direction for the arc spinners.
    enum Spin
      Clockwise
      CounterClockwise
    end

    # Whether the interior of a ring spinner carries a solid fill.
    enum Centre
      Filled
      Empty
    end

    # Machinery the spinner widgets share.
    #
    # Every spinner is stateless: it is handed a monotonically increasing tick
    # and derives the whole frame from it, so callers keep one counter and no
    # widget state at all.
    module Spinner
      extend self

      BRAILLE_BASE = 0x2800

      # Bit index inside a braille byte, indexed by [dot_row % 4][dot_col % 2].
      BRAILLE_BITS = [[0, 3], [1, 4], [2, 5], [6, 7]]

      def braille(byte : Int) : String
        (BRAILLE_BASE + (byte.to_i & 0xFF)).chr.to_s
      end

      def ceil_div(value : Int32, divisor : Int32) : Int32
        (value + divisor - 1) // divisor
      end

      # Draws one Line per row, honouring the optional block the same way the
      # other widgets in this module do.
      def paint(lines : Array(Line), area : Rect, buffer : Buffer, style : Style, block : Block?) : Nil
        return if area.empty?
        buffer.set_style(area, style)
        content = area
        if block
          block.render(area, buffer)
          content = block.inner(area)
        end
        return if content.empty?
        lines.first(content.height).each_with_index do |line, index|
          line.render(buffer, Rect.new(content.x, content.y + index, content.width, 1), style)
        end
      end

      # Folds an unbounded tick onto the animation's own cycle.
      #
      # Several engines can only reach frame N by walking N times. A spinner
      # that has been on screen for an hour would then cost thousands of steps
      # per redraw, so the step count is reduced to an equivalent one first:
      # `lead` frames of run-up followed by a `period`-long loop.
      def fold(steps : Int64, lead : Int32, period : Int32) : Int32
        return 0 if period <= 0
        return steps.to_i32 if steps < lead
        lead + ((steps - lead) % period).to_i32
      end

      # A dot in spinner space, before braille packing.
      record Coord, row : Int32, col : Int32
    end
  end
end
