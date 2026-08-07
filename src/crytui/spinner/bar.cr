module CryTUI
  module Widgets
    # What the arc does when it reaches the end of the bar.
    enum BarMotion
      # Reverses at each edge — ping-pong.
      Bounce
      # Wraps: leaves one edge and re-enters from the other.
      Loop
      # Two arcs converge on the centre, then travel back out.
      Squeeze
      # Two arcs travel outward from the centre and restart there.
      Radiate
    end

    # The glyph pair a BarSpinner draws its arc and track with.
    #
    # Braille is the only style with intermediate densities, so it is the only
    # one that can render the fade ramp; the rest are a single filled glyph and
    # a single hollow one.
    enum BarStyle
      Braille
      Block
      Shade
      Dot
      Diamond
      Square
      Star
      Heart
      Arrow
      Circle
      Spark
      Cross
      Progress
      Thick
      Wave
      Pip

      # Nil for Braille, which is drawn from raw braille bytes instead.
      def chars : Tuple(String, String)?
        case self
        in .braille?  then nil
        in .block?    then {"█", "░"}
        in .shade?    then {"▓", "░"}
        in .dot?      then {"●", "·"}
        in .diamond?  then {"◆", "◇"}
        in .square?   then {"■", "□"}
        in .star?     then {"★", "☆"}
        in .heart?    then {"♥", "♡"}
        in .arrow?    then {"▶", "▷"}
        in .circle?   then {"◉", "○"}
        in .spark?    then {"✦", "✧"}
        in .cross?    then {"✚", "✛"}
        in .progress? then {"▰", "▱"}
        in .thick?    then {"━", "─"}
        in .wave?     then {"≈", "˜"}
        in .pip?      then {"▪", "·"}
        end
      end
    end

    # The background the arc travels over, as a braille byte.
    struct BarTrack
      getter byte : Int32

      def initialize(byte : Int)
        @byte = byte.to_i & 0xFF
      end

      # `⣀` — a bottom-two-dot baseline that shows the bar's extent without
      # competing with the arc.
      RAIL = new(0xC0)
      # `⣿` — a full-density track in the dim style.
      FULL = new(0xFF)
      # `⠀` — nothing at all, so the arc floats.
      EMPTY = new(0x00)

      def self.custom(byte : Int) : BarTrack
        new(byte)
      end
    end

    module Spinner
      # Density ramp for the arc edges, outermost first: `⠉ ⠛ ⠿ ⣿`.
      FADE = [0x09, 0x1B, 0x3F, 0xFF]

      # Maps a distance from the arc edge onto the ramp.
      def fade(from_edge : Int32, fade_width : Int32, arc_byte : Int32) : Int32
        return arc_byte if fade_width <= 0 || from_edge >= fade_width
        FADE[{ceil_div(from_edge * 3, fade_width), 2}.min]
      end

      # The bar arc in character-column space.
      #
      # Positions are whole cells rather than braille dots, so the arc never
      # lands halfway through a glyph and there is nothing to round.
      class BarEngine
        getter char_w : Int32
        getter char_h : Int32
        getter arc_cols : Int32
        getter anchor : Int32

        def initialize(char_w : Int32, char_h : Int32, arc_width : Int32, spin : Spin, @motion : BarMotion)
          @char_w = {char_w, 3}.max
          @char_h = {char_h, 1}.max
          @arc_cols = if arc_width > 0
                        {arc_width, {@char_w - 1, 1}.max}.min
                      else
                        {Spinner.ceil_div(@char_w, 3), 4}.max
                      end

          # The two-armed motions always start from their symmetric position,
          # so spin only decides which way the single-armed ones set off.
          symmetric = @motion.squeeze? || @motion.radiate?
          @forward = symmetric || spin.clockwise?
          @anchor = symmetric || @forward ? 0 : travel
        end

        # How far the anchor can move before it has to turn or wrap.
        def travel : Int32
          {@char_w - @arc_cols, 0}.max
        end

        # A bounce spends one step at each end changing its mind, which is why
        # the period is two longer than the round trip.
        def period : Int32
          case @motion
          in .bounce?  then 2 * (travel + 1)
          in .loop?    then @char_w
          in .squeeze? then 2 * ((travel // 2) + 1)
          in .radiate? then (travel // 2) + 1
          end
        end

        def advance(steps : Int64) : Nil
          Spinner.fold(steps, 0, period).times { walk }
        end

        def walk : Nil
          case @motion
          in .bounce?  then bounce(travel)
          in .squeeze? then bounce(travel // 2)
          in .loop?
            @anchor = @forward ? (@anchor + 1) % @char_w : (@anchor + @char_w - 1) % @char_w
          in .radiate?
            @anchor = (@anchor + 1) % ((travel // 2) + 1)
          end
        end

        # Turning costs a step: the arc holds position for one frame while the
        # direction flips, which is what makes the ends of a bounce read.
        private def bounce(limit : Int32) : Nil
          if @forward
            @anchor < limit ? (@anchor += 1) : (@forward = false)
          else
            @anchor > 0 ? (@anchor -= 1) : (@forward = true)
          end
        end

        def lines(arc_style : Style, dim_style : Style, fade_width : Int32, track_byte : Int32,
                  arc_byte : Int32, glyphs : Tuple(String, String)?, alignment : Alignment) : Array(Line)
          spans = (0...@char_w).map do |column|
            inside, from_edge = coverage(column)
            if glyphs
              inside ? Span.new(glyphs[0], arc_style) : Span.new(glyphs[1], dim_style)
            elsif inside
              Span.new(Spinner.braille(Spinner.fade(from_edge, fade_width, arc_byte)), arc_style)
            else
              Span.new(Spinner.braille(track_byte), dim_style)
            end
          end

          # Every row of a horizontal bar is identical, so the row is built
          # once and repeated.
          Array.new(@char_h) { Line.new(spans, alignment) }
        end

        # Whether a column falls under the arc and, if so, how far it is from
        # the nearer arc edge — which is what the fade ramp is indexed by.
        private def coverage(column : Int32) : Tuple(Bool, Int32)
          case @motion
          in .bounce?
            window(column, @anchor, @anchor + @arc_cols)
          in .loop?
            offset = (column + @char_w - @anchor) % @char_w
            offset < @arc_cols ? {true, {offset, @arc_cols - 1 - offset}.min} : {false, 0}
          in .squeeze?
            trailing = {@char_w - @anchor, 0}.max
            left = window(column, @anchor, @anchor + @arc_cols)
            left[0] ? left : window(column, {trailing - @arc_cols, 0}.max, trailing)
          in .radiate?
            centre = @char_w // 2
            right = window(column, centre + @anchor, {centre + @anchor + @arc_cols, @char_w}.min)
            return right if right[0]
            up = {centre - @anchor, 0}.max
            window(column, {up - @arc_cols, 0}.max, up)
          end
        end

        private def window(column : Int32, start : Int32, finish : Int32) : Tuple(Bool, Int32)
          return {false, 0} unless column >= start && column < finish
          {true, {column - start, finish - 1 - column}.min}
        end
      end

      # The same arc travelling down rows instead of across columns.
      class VerticalBarEngine
        getter char_w : Int32
        getter char_h : Int32
        getter arc_rows : Int32
        getter anchor : Int32

        def initialize(char_w : Int32, char_h : Int32, arc_height : Int32, spin : Spin, @motion : BarMotion)
          @char_w = {char_w, 1}.max
          @char_h = {char_h, 3}.max
          @arc_rows = if arc_height > 0
                        {arc_height, {@char_h - 1, 1}.max}.min
                      else
                        {Spinner.ceil_div(@char_h, 3), 2}.max
                      end

          symmetric = @motion.squeeze? || @motion.radiate?
          @forward = symmetric || spin.clockwise?
          @anchor = symmetric || @forward ? 0 : travel
        end

        def travel : Int32
          {@char_h - @arc_rows, 0}.max
        end

        def period : Int32
          case @motion
          in .bounce?  then 2 * (travel + 1)
          in .loop?    then @char_h
          in .squeeze? then 2 * ((travel // 2) + 1)
          in .radiate? then (travel // 2) + 1
          end
        end

        def advance(steps : Int64) : Nil
          Spinner.fold(steps, 0, period).times { walk }
        end

        def walk : Nil
          case @motion
          in .bounce?  then bounce(travel)
          in .squeeze? then bounce(travel // 2)
          in .loop?
            @anchor = @forward ? (@anchor + 1) % @char_h : (@anchor + @char_h - 1) % @char_h
          in .radiate?
            @anchor = (@anchor + 1) % ((travel // 2) + 1)
          end
        end

        private def bounce(limit : Int32) : Nil
          if @forward
            @anchor < limit ? (@anchor += 1) : (@forward = false)
          else
            @anchor > 0 ? (@anchor -= 1) : (@forward = true)
          end
        end

        def lines(arc_style : Style, dim_style : Style, track_byte : Int32, arc_byte : Int32,
                  glyphs : Tuple(String, String)?, alignment : Alignment) : Array(Line)
          (0...@char_h).map do |row|
            inside = covered?(row)
            symbol, style = if glyphs
                              inside ? {glyphs[0], arc_style} : {glyphs[1], dim_style}
                            elsif inside
                              {Spinner.braille(arc_byte), arc_style}
                            else
                              {Spinner.braille(track_byte), dim_style}
                            end
            Line.new(Array.new(@char_w) { Span.new(symbol, style) }, alignment)
          end
        end

        # There is no fade vertically: a braille density ramp stacked down the
        # rows reads as a stepped edge rather than a glow.
        private def covered?(row : Int32) : Bool
          case @motion
          in .bounce?
            row >= @anchor && row < @anchor + @arc_rows
          in .loop?
            (row + @char_h - @anchor) % @char_h < @arc_rows
          in .squeeze?
            trailing = {@char_h - @anchor, 0}.max
            (row >= @anchor && row < @anchor + @arc_rows) ||
              (row >= {trailing - @arc_rows, 0}.max && row < trailing)
          in .radiate?
            centre = @char_h // 2
            up = {centre - @anchor, 0}.max
            (row >= centre + @anchor && row < {centre + @anchor + @arc_rows, @char_h}.min) ||
              (row >= {up - @arc_rows, 0}.max && row < up)
          end
        end
      end
    end

    # A solid bar with a glowing arc sliding over it.
    #
    # Unlike the other spinners a bar has no intrinsic length — leave `width`
    # at 0 and it fills whatever area it is given.
    struct BarSpinner
      getter tick : Int64
      getter width : Int32
      getter height : Int32
      getter arc_width : Int32
      getter spin : Spin
      getter ticks_per_step : Int32
      getter arc_style : Style
      getter dim_style : Style
      getter track : BarTrack
      getter fade_width : Int32
      getter arc_byte : Int32
      getter bar_style : BarStyle
      getter motion : BarMotion
      getter orientation : Direction
      getter thickness : Int32
      getter style : Style
      getter block : Block?
      getter alignment : Alignment

      def initialize(tick : Int = 0,
                     width : Int = 0,
                     height : Int = 1,
                     arc_width : Int = 0,
                     @spin : Spin = Spin::Clockwise,
                     ticks_per_step : Int = 1,
                     @arc_style : Style = Style.new(Color::CYAN),
                     @dim_style : Style = Style.new(Color::DARK_GRAY),
                     @track : BarTrack = BarTrack::RAIL,
                     fade_width : Int = 3,
                     arc_byte : Int = 0xFF,
                     @bar_style : BarStyle = BarStyle::Braille,
                     @motion : BarMotion = BarMotion::Bounce,
                     @orientation : Direction = Direction::Horizontal,
                     thickness : Int = 0,
                     @style : Style = Style.new,
                     @block : Block? = nil,
                     @alignment : Alignment = Alignment::Left)
        @tick = tick.to_i64
        @width = {width.to_i, 0}.max
        @height = {height.to_i, 1}.max
        @arc_width = {arc_width.to_i, 0}.max
        @ticks_per_step = {ticks_per_step.to_i, 1}.max
        @fade_width = {fade_width.to_i, 0}.max
        @arc_byte = arc_byte.to_i & 0xFF
        @thickness = {thickness.to_i, 0}.max
      end

      # One row, cyan, over a subtle rail.
      def self.zed(tick : Int = 0) : BarSpinner
        new(tick: tick, height: 1, arc_style: Style.new(Color::CYAN), dim_style: Style.new(Color::DARK_GRAY))
      end

      # Two rows, warm orange, over a subtle rail.
      def self.claude(tick : Int = 0) : BarSpinner
        new(tick: tick, height: 2, arc_style: Style.new(Color.rgb(255, 165, 0)), dim_style: Style.new(Color::DARK_GRAY))
      end

      # One row, white, with no track at all — the arc floats.
      def self.minimal(tick : Int = 0) : BarSpinner
        new(tick: tick, height: 1, arc_style: Style.new(Color::WHITE),
          dim_style: Style.new(Color::BLACK), track: BarTrack::EMPTY)
      end

      # One row, cyan, full track and hard arc edges.
      def self.solid(tick : Int = 0) : BarSpinner
        new(tick: tick, height: 1, arc_style: Style.new(Color::CYAN),
          dim_style: Style.new(Color::DARK_GRAY), track: BarTrack::FULL, fade_width: 0)
      end

      # The fixed size, or nil when the width is left on auto.
      def char_size : Tuple(Int32, Int32)?
        return if @width.zero?
        { {@width, 3}.max, @height }
      end

      # The current frame laid out for the given size. A bar has no intrinsic
      # length, so unlike the other spinners it has to be told one.
      def lines(width : Int32, height : Int32) : Array(Line)
        steps = @tick // @ticks_per_step

        case @orientation
        in .horizontal?
          rows = @thickness > 0 ? @thickness : @height
          # A density ramp stacked across several rows reads as a diagonal
          # staircase, so multi-row bars get a hard edge instead.
          fade = rows > 1 ? 0 : @fade_width
          engine = Spinner::BarEngine.new({width, 3}.max, rows, @arc_width, @spin, @motion)
          engine.advance(steps)
          engine.lines(@arc_style, @dim_style, fade, @track.byte, @arc_byte, @bar_style.chars, @alignment)
        in .vertical?
          columns = if @thickness > 0
                      @thickness
                    else
                      @width.zero? ? width : @width
                    end
          engine = Spinner::VerticalBarEngine.new({columns, 1}.max, {height, 3}.max, @arc_width, @spin, @motion)
          engine.advance(steps)
          engine.lines(@arc_style, @dim_style, @track.byte, @arc_byte, @bar_style.chars, @alignment)
        end
      end

      def render(area : Rect, buffer : Buffer) : Nil
        return if area.empty?
        inner = @block.try(&.inner(area)) || area
        return if inner.empty?
        width = @width.zero? ? inner.width : @width
        Spinner.paint(lines(width, inner.height), area, buffer, @style, @block)
      end
    end
  end
end
