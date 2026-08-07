module CryTUI
  module Widgets
    module Spinner
      # A braille arc rotating around a circular ring.
      #
      # The perimeter is plotted with the midpoint circle algorithm at a 1:1
      # dot pitch. That looks wrong on paper and is right on a terminal: a
      # braille cell packs two dots across and four down while a character cell
      # is about twice as tall as it is wide, and the two factors cancel, so
      # equal dot counts produce a visually round circle.
      class CircleEngine
        getter dot_rows : Int32
        getter dot_cols : Int32
        getter arc_len : Int32

        # Shifts a perimeter coordinate, which is centred on the origin, into
        # a grid index.
        @row_offset : Int32
        @col_offset : Int32
        @perimeter : Array(Coord)
        @head : Int32
        @tail : Int32

        @@perimeters = {} of Int32 => Array(Coord)

        def self.perimeter(radius : Int32) : Array(Coord)
          cached = @@perimeters[radius]?
          return cached if cached
          @@perimeters[radius] = compute_perimeter(radius)
        end

        def self.char_size(radius : Int32) : Tuple(Int32, Int32)
          span = {radius, 1}.max * 2 + 1
          {Spinner.ceil_div(span, 2), Spinner.ceil_div(span, 4)}
        end

        def initialize(radius : Int32, arc_len : Int32, spin : Spin)
          @perimeter = CircleEngine.perimeter({radius, 1}.max)
          count = @perimeter.size

          rows = @perimeter.map(&.row)
          cols = @perimeter.map(&.col)
          @row_offset = -rows.min
          @col_offset = -cols.min
          @dot_rows = rows.max - rows.min + 1
          @dot_cols = cols.max - cols.min + 1

          @arc_len = arc_len > 0 ? {arc_len, count}.min : {count // 4, 1}.max
          @head = 0
          @tail = spin.counter_clockwise? ? @arc_len % count : (count - @arc_len) % count
        end

        # Head and tail both travel one dot per step, so the whole animation is
        # a rotation of the perimeter index — no walking required.
        def advance(steps : Int64, spin : Spin) : Nil
          count = @perimeter.size
          shift = (steps % count).to_i32
          shift = (count - shift) % count if spin.counter_clockwise?
          @head = (@head + shift) % count
          @tail = (@tail + shift) % count
        end

        def lines(arc_style : Style, dim_style : Style, alignment : Alignment) : Array(Line)
          char_rows = Spinner.ceil_div(@dot_rows, 4)
          char_cols = Spinner.ceil_div(@dot_cols, 2)
          count = @perimeter.size

          lit = Set(Coord).new
          @arc_len.times { |offset| lit << @perimeter[(@tail + offset) % count] }

          # Two byte grids rather than one: a braille cell can hold dots from
          # both the arc and the dim ring, and a cell can only carry one
          # colour, so the brighter one has to win the whole cell.
          bright = Array.new(char_rows) { Array.new(char_cols, 0) }
          dim = Array.new(char_rows) { Array.new(char_cols, 0) }

          @perimeter.each do |dot|
            row = dot.row + @row_offset
            col = dot.col + @col_offset
            next unless row >= 0 && row < @dot_rows && col >= 0 && col < @dot_cols
            bit = 1 << Spinner::BRAILLE_BITS[row % 4][col % 2]
            if lit.includes?(dot)
              bright[row // 4][col // 2] |= bit
            else
              dim[row // 4][col // 2] |= bit
            end
          end

          (0...char_rows).map do |row|
            spans = (0...char_cols).map do |col|
              byte = bright[row][col]
              if byte.zero?
                Span.new(Spinner.braille(dim[row][col]), dim_style)
              else
                Span.new(Spinner.braille(byte), arc_style)
              end
            end
            Line.new(spans, alignment)
          end
        end

        private def self.compute_perimeter(radius : Int32) : Array(Coord)
          return [Coord.new(0, 0)] if radius <= 0

          points = Set(Coord).new
          x = 0
          y = radius
          decision = 1 - radius

          while x <= y
            [{x, -y}, {y, -x}, {y, x}, {x, y}, {-x, y}, {-y, x}, {-y, -x}, {-x, -y}].each do |octant|
              points << Coord.new(octant[1], octant[0])
            end
            if decision < 0
              decision += 2 * x + 3
            else
              decision += 2 * (x - y) + 5
              y -= 1
            end
            x += 1
          end

          sort_clockwise(points.to_a)
        end

        # The arc has to travel round the ring in order, and the midpoint
        # algorithm emits dots by octant, so they are re-sorted by angle from
        # twelve o'clock.
        private def self.sort_clockwise(dots : Array(Coord)) : Array(Coord)
          return dots if dots.empty?
          count = dots.size.to_f64
          centre_row = dots.sum(&.row) / count
          centre_col = dots.sum(&.col) / count

          dots.sort_by do |dot|
            angle = Math.atan2(dot.col - centre_col, -(dot.row - centre_row))
            angle < 0 ? angle + 2 * Math::PI : angle
          end
        end
      end
    end

    # A comet-like arc rotating around a circular braille ring. There is no
    # centre fill: only the ring is ever drawn.
    struct CircleSpinner
      getter tick : Int64
      getter radius : Int32
      getter arc_len : Int32
      getter spin : Spin
      getter ticks_per_step : Int32
      getter arc_style : Style
      getter dim_style : Style
      getter style : Style
      getter block : Block?
      getter alignment : Alignment

      def initialize(tick : Int = 0,
                     radius : Int = 4,
                     arc_len : Int = 0,
                     @spin : Spin = Spin::Clockwise,
                     ticks_per_step : Int = 1,
                     @arc_style : Style = Style.new(Color::WHITE),
                     @dim_style : Style = Style.new(Color::DARK_GRAY),
                     @style : Style = Style.new,
                     @block : Block? = nil,
                     @alignment : Alignment = Alignment::Left)
        @tick = tick.to_i64
        @radius = {radius.to_i, 1}.max
        @arc_len = {arc_len.to_i, 0}.max
        @ticks_per_step = {ticks_per_step.to_i, 1}.max
      end

      def char_size : Tuple(Int32, Int32)
        Spinner::CircleEngine.char_size(@radius)
      end

      def lines : Array(Line)
        engine = Spinner::CircleEngine.new(@radius, @arc_len, @spin)
        engine.advance(@tick // @ticks_per_step, @spin)
        engine.lines(@arc_style, @dim_style, @alignment)
      end

      def render(area : Rect, buffer : Buffer) : Nil
        Spinner.paint(lines, area, buffer, @style, @block)
      end
    end
  end
end
