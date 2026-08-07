module CryTUI
  module Widgets
    # The outline a RectSpinner traces.
    enum RectShape
      Square
    end

    module Spinner
      # A braille arc travelling around a square ring.
      #
      # Two runs of `size` dots walk the perimeter: the head lights dots ahead
      # of it, the tail clears them `size` steps behind, so the lit arc keeps a
      # constant length. Movement is table-driven — the corner maps turn the
      # run through ninety degrees and straight travel is inferred from the
      # shape of the run itself.
      class SquareEngine
        getter cells : Array(Array(Bool))
        getter size : Int32
        getter offset : Int32

        # The character rows and columns the filled centre spans, as
        # {top_row, left_col} and {bottom_row, right_col}.
        @centre_bounds : Tuple(Tuple(Int32, Int32), Tuple(Int32, Int32))
        @head : Array(Coord)
        @tail : Array(Coord)
        @head_map : Hash(Coord, Coord)
        @tail_map : Hash(Coord, Coord)

        # Cycle detection is deterministic per configuration and only pays for
        # itself once, so the answer is kept for the life of the process.
        @@cycles = {} of Tuple(Int32, Centre) => Tuple(Int32, Int32)

        def self.dimension(size : Int32) : Int32
          8 + 5 * {size - 2, 0}.max
        end

        # Size 2 is the one configuration whose ring does not land on a braille
        # row boundary; two blank dot rows above it fix the packing.
        def self.vertical_offset(size : Int32) : Int32
          size == 2 ? 2 : 0
        end

        def self.char_size(size : Int32) : Tuple(Int32, Int32)
          size = size.clamp(2, 8)
          dimension = dimension(size)
          {Spinner.ceil_div(dimension, 2), Spinner.ceil_div(dimension + vertical_offset(size), 4)}
        end

        def initialize(size : Int32, @centre : Centre)
          @size = size.clamp(2, 8)
          dimension = SquareEngine.dimension(@size)
          @offset = SquareEngine.vertical_offset(@size)
          @cells = Array.new(dimension + @offset) { Array.new(dimension, false) }

          middle = dimension // 2
          inset = @size // 2
          centre_start = Coord.new(middle - inset, middle - inset)
          centre_end = Coord.new(centre_start.row + @size - 1, centre_start.col + @size - 1)
          @centre_bounds = {
            {(centre_start.row + @offset) // 4, (centre_start.col // 2) - 1},
            {(centre_end.row + @offset) // 4, centre_end.col // 2},
          }

          ring = (dimension // 2) + (dimension % 2) + ((@size - 2) // 2)
          @head = Array.new(@size) { |n| Coord.new(n, ring) }
          @tail = Array.new(@size) { |n| Coord.new(ring, n) }
          @head_map = SquareEngine.head_map(dimension, dimension, @size)
          @tail_map = SquareEngine.tail_map(dimension, dimension, @size)

          # The opening frame is the L-shaped run between tail and head; the
          # tail erases it over the first lap.
          @size.times { |index| fill(@tail[index], @head[index]) }

          if @centre.filled?
            @size.times do |row|
              @size.times { |col| set(centre_start.row + row, centre_start.col + col, true) }
            end
          end
        end

        def self.head_map(width : Int32, height : Int32, size : Int32) : Hash(Coord, Coord)
          map = {} of Coord => Coord
          last_col = width - 1
          last_row = height - 1
          size.times { |n| map[Coord.new(n, last_col)] = Coord.new(size, last_col - n) }
          size.times { |n| map[Coord.new(last_row, last_col - n)] = Coord.new(last_row - n, last_col - size) }
          size.times { |n| map[Coord.new(last_row - n, 0)] = Coord.new(last_col - size, n) }
          size.times { |n| map[Coord.new(0, n)] = Coord.new(n, size) }
          map
        end

        def self.tail_map(width : Int32, height : Int32, size : Int32) : Hash(Coord, Coord)
          map = {} of Coord => Coord
          last_col = width - 1
          last_row = height - 1
          size.times { |n| map[Coord.new(size, n)] = Coord.new(n, 0) }
          size.times { |n| map[Coord.new(n, last_col - size)] = Coord.new(0, last_col - n) }
          size.times { |n| map[Coord.new(last_row - size, last_col - n)] = Coord.new(last_row - n, last_col) }
          size.times { |n| map[Coord.new(last_row - n, size)] = Coord.new(last_row, n) }
          map
        end

        # The run-up length and loop length of the animation, found by walking
        # until the whole engine state repeats.
        def self.cycle(size : Int32, centre : Centre) : Tuple(Int32, Int32)
          key = {size.clamp(2, 8), centre}
          cached = @@cycles[key]?
          return cached if cached

          engine = new(key[0], centre)
          seen = {} of String => Int32
          index = 0
          result = {0, 1}
          while true
            state = engine.state_key
            previous = seen[state]?
            if previous
              result = {previous, index - previous}
              break
            end
            seen[state] = index
            engine.walk
            index += 1
          end

          @@cycles[key] = result
        end

        def advance(steps : Int64) : Nil
          lead, period = SquareEngine.cycle(@size, @centre)
          Spinner.fold(steps, lead, period).times { walk }
        end

        def walk : Nil
          @head = advance_nodes(@head, @head_map)
          @head.each { |position| set(position.row, position.col, true) }
          @tail.each { |position| set(position.row, position.col, false) }
          @tail = advance_nodes(@tail, @tail_map)
        end

        def state_key : String
          String.build do |io|
            @cells.each { |row| row.each { |on| io << (on ? '1' : '0') } }
            io << '|'
            @head.each { |dot| io << dot.row << ',' << dot.col << ';' }
            io << '|'
            @tail.each { |dot| io << dot.row << ',' << dot.col << ';' }
          end
        end

        def lines(arc_style : Style, dim_style : Style, alignment : Alignment) : Array(Line)
          char_rows = Spinner.ceil_div(@cells.size, 4)
          char_cols = Spinner.ceil_div(@cells[0].size, 2)
          screen = Array.new(char_rows) { Array.new(char_cols, 0) }

          @cells.each_with_index do |row_cells, row|
            row_cells.each_with_index do |on, col|
              next unless on
              screen[row // 4][col // 2] |= 1 << Spinner::BRAILLE_BITS[row % 4][col % 2]
            end
          end

          # The centre is painted by flipping colour as the scan crosses its
          # bounding columns, which costs nothing extra per cell.
          active = arc_style
          (0...char_rows).map do |row|
            spans = (0...char_cols).map do |col|
              span = Span.new(Spinner.braille(screen[row][col]), active)
              if @centre.filled? && crosses_centre?(row, col)
                active = active == arc_style ? dim_style : arc_style
              end
              span
            end
            Line.new(spans, alignment)
          end
        end

        # A run turns at a corner when every one of its dots has a mapping;
        # otherwise it is travelling straight and slides one dot along.
        private def advance_nodes(nodes : Array(Coord), rotation : Hash(Coord, Coord)) : Array(Coord)
          turned = nodes.map { |node| rotation[node]? }
          return turned.map(&.not_nil!) unless turned.any?(&.nil?)

          moved = nodes
          if moved.all? { |node| node.col == moved[0].col }
            direction = moved.any? { |node| node.row == 0 } ? 1 : -1
            moved = moved.map { |node| Coord.new(node.row, node.col + direction) }
          end
          if moved.all? { |node| node.row == moved[0].row }
            direction = moved.any? { |node| node.col == 0 } ? -1 : 1
            moved = moved.map { |node| Coord.new(node.row + direction, node.col) }
          end
          moved
        end

        private def set(row : Int32, col : Int32, value : Bool) : Nil
          shifted = row + @offset
          return unless shifted >= 0 && shifted < @cells.size && col >= 0 && col < @cells[0].size
          @cells[shifted][col] = value
        end

        # Walks an L-shaped path from `start` to `finish`, lighting every dot.
        private def fill(start : Coord, finish : Coord) : Nil
          horizontal = finish.col < start.col ? -1 : 1
          vertical = finish.row < start.row ? -1 : 1
          row = start.row
          col = start.col
          set(row, col, true)
          while row != finish.row
            row += vertical
            set(row, col, true)
          end
          while col != finish.col
            col += horizontal
            set(row, col, true)
          end
        end

        private def crosses_centre?(row : Int32, col : Int32) : Bool
          top, bottom = @centre_bounds
          return false unless row >= top[0] && row <= bottom[0]
          col == top[1] || col == bottom[1]
        end
      end
    end

    # A braille arc rotating around a rectangle, with an optional filled centre.
    struct RectSpinner
      getter tick : Int64
      getter shape : RectShape
      getter size : Int32
      getter spin : Spin
      getter centre : Centre
      getter ticks_per_step : Int32
      getter arc_style : Style
      getter dim_style : Style
      getter style : Style
      getter block : Block?
      getter alignment : Alignment

      def initialize(tick : Int = 0,
                     @shape : RectShape = RectShape::Square,
                     size : Int = 2,
                     @spin : Spin = Spin::Clockwise,
                     @centre : Centre = Centre::Filled,
                     ticks_per_step : Int = 1,
                     @arc_style : Style = Style.new(Color::CYAN),
                     @dim_style : Style = Style.new(Color::DARK_GRAY),
                     @style : Style = Style.new,
                     @block : Block? = nil,
                     @alignment : Alignment = Alignment::Left)
        @tick = tick.to_i64
        @size = size.to_i.clamp(2, 8)
        @ticks_per_step = {ticks_per_step.to_i, 1}.max
      end

      def char_size : Tuple(Int32, Int32)
        Spinner::SquareEngine.char_size(@size)
      end

      def lines : Array(Line)
        engine = Spinner::SquareEngine.new(@size, @centre)
        engine.advance(@tick // @ticks_per_step)
        rendered = engine.lines(@arc_style, @dim_style, @alignment)
        return rendered if @spin.clockwise?
        # Mirroring the columns is what reverses the arc: the ring is
        # symmetric, so a horizontal flip turns clockwise into anticlockwise.
        rendered.map { |line| Line.new(line.spans.reverse, line.alignment, line.style) }
      end

      def render(area : Rect, buffer : Buffer) : Nil
        Spinner.paint(lines, area, buffer, @style, @block)
      end
    end

    # A RectSpinner fixed to a square, kept because it is the shape most
    # callers want and it reads better at the call site.
    struct SquareSpinner
      getter tick : Int64
      getter size : Int32
      getter spin : Spin
      getter centre : Centre
      getter ticks_per_step : Int32
      getter arc_style : Style
      getter dim_style : Style
      getter style : Style
      getter block : Block?
      getter alignment : Alignment

      def initialize(tick : Int = 0,
                     size : Int = 2,
                     @spin : Spin = Spin::Clockwise,
                     @centre : Centre = Centre::Filled,
                     ticks_per_step : Int = 1,
                     @arc_style : Style = Style.new(Color::WHITE),
                     @dim_style : Style = Style.new(Color::DARK_GRAY),
                     @style : Style = Style.new,
                     @block : Block? = nil,
                     @alignment : Alignment = Alignment::Left)
        @tick = tick.to_i64
        @size = size.to_i.clamp(2, 8)
        @ticks_per_step = {ticks_per_step.to_i, 1}.max
      end

      def char_size : Tuple(Int32, Int32)
        Spinner::SquareEngine.char_size(@size)
      end

      def lines : Array(Line)
        rect.lines
      end

      def render(area : Rect, buffer : Buffer) : Nil
        rect.render(area, buffer)
      end

      private def rect : RectSpinner
        RectSpinner.new(
          tick: @tick,
          shape: RectShape::Square,
          size: @size,
          spin: @spin,
          centre: @centre,
          ticks_per_step: @ticks_per_step,
          arc_style: @arc_style,
          dim_style: @dim_style,
          style: @style,
          block: @block,
          alignment: @alignment
        )
      end
    end
  end
end
