module CryTUI
  module Widgets
    # The frame sequences a FluxSpinner can cycle through.
    #
    # Any array of single-cell strings works; these are the ones worth having
    # a name. Sequences that visibly bounce or pulse repeat a frame on the way
    # back, which is deliberate — it is the return step.
    module FluxFrames
      extend self

      # `⣾ ⣷ ⣯ ⣟ ⡿ ⢿ ⣽ ⣻` — a full cell with one dot missing, the gap rotating.
      BRAILLE = %w[⣾ ⣷ ⣯ ⣟ ⡿ ⢿ ⣽ ⣻]
      # `⠁ ⠈ ⠐ ⠠ ⢀ ⡀ ⠄ ⠂` — a single dot orbiting; the inverse of BRAILLE.
      ORBIT = %w[⠁ ⠈ ⠐ ⠠ ⢀ ⡀ ⠄ ⠂]
      # `⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏` — the classic ten-frame braille spinner.
      CLASSIC = %w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏]
      # `│ ╱ ─ ╲` — a rotating line.
      LINE = %w[│ ╱ ─ ╲]
      # `▖ ▘ ▝ ▗` — a quarter block moving round the corners.
      BLOCK = %w[▖ ▘ ▝ ▗]
      # `◜ ◝ ◞ ◟` — a quarter arc.
      ARC = %w[◜ ◝ ◞ ◟]
      # `◷ ◶ ◵ ◴` — a quarter-circle pie slice.
      CLOCK = %w[◷ ◶ ◵ ◴]
      # `◓ ◑ ◒ ◐` — half-circle moon phases.
      MOON = %w[◓ ◑ ◒ ◐]
      # `▲ ▶ ▼ ◀` — a filled triangle facing each direction in turn.
      TRIANGLES = %w[▲ ▶ ▼ ◀]
      # `⣀ ⣤ ⣶ ⣾ ⣿ ⣾ ⣶ ⣤` — braille density pulsing up and back down.
      PULSE = %w[⣀ ⣤ ⣶ ⣾ ⣿ ⣾ ⣶ ⣤]
      # `⠉ ⠒ ⣀ ⠒` — a braille row bouncing top to bottom.
      BOUNCE = %w[⠉ ⠒ ⣀ ⠒]
      # `▀ ▐ ▄ ▌` — a half block rotating.
      HALF = %w[▀ ▐ ▄ ▌]
      # `◰ ◳ ◲ ◱` — a square with one quadrant filled.
      SQUARE = %w[◰ ◳ ◲ ◱]
      # `⚀ ⚁ ⚂ ⚃ ⚄ ⚅` — dice faces one through six.
      DICE = %w[⚀ ⚁ ⚂ ⚃ ⚄ ⚅]
      # `▁ ▂ ▃ ▄ ▅ ▆ ▇ █` — a bar growing an eighth at a time.
      BAR = %w[▁ ▂ ▃ ▄ ▅ ▆ ▇ █]
      # `┌ ┐ ┘ └` — box corners rotating.
      CORNERS = %w[┌ ┐ ┘ └]
      # `○ ◔ ◑ ◕ ●` — a circle filling.
      CIRCLE_FILL = %w[○ ◔ ◑ ◕ ●]
      # `▁ ▃ ▅ ▇ █ ▇ ▅ ▃` — a bar bouncing to full height and back.
      PISTON = %w[▁ ▃ ▅ ▇ █ ▇ ▅ ▃]
      # `✶ ✷ ✸ ✹` — a star through four densities.
      STAR = %w[✶ ✷ ✸ ✹]
      # `⠉ ⠘ ⠰ ⢠ ⣀ ⡄ ⠆ ⠃` — two adjacent dots rotating together.
      PAIR = %w[⠉ ⠘ ⠰ ⢠ ⣀ ⡄ ⠆ ⠃]
      # `◇ ◈ ◆ ◈` — a diamond pulsing from hollow to solid.
      DIAMOND = %w[◇ ◈ ◆ ◈]

      # Every preset by name, so a spinner can be chosen from configuration
      # rather than only from code.
      PRESETS = {
        "braille"     => BRAILLE,
        "orbit"       => ORBIT,
        "classic"     => CLASSIC,
        "line"        => LINE,
        "block"       => BLOCK,
        "arc"         => ARC,
        "clock"       => CLOCK,
        "moon"        => MOON,
        "triangles"   => TRIANGLES,
        "pulse"       => PULSE,
        "bounce"      => BOUNCE,
        "half"        => HALF,
        "square"      => SQUARE,
        "dice"        => DICE,
        "bar"         => BAR,
        "corners"     => CORNERS,
        "circle-fill" => CIRCLE_FILL,
        "piston"      => PISTON,
        "star"        => STAR,
        "pair"        => PAIR,
        "diamond"     => DIAMOND,
      }

      # Nil rather than an exception for an unknown name: choosing a spinner is
      # decoration, and no run should fail over it.
      def named?(name : String?) : Array(String)?
        return unless name
        PRESETS[name.strip.downcase]?
      end

      def names : Array(String)
        PRESETS.keys.sort!
      end
    end

    # A glyph cycling through a frame sequence.
    #
    # At 1×1 this is the ordinary status-line spinner. Scaled up, each cell is
    # offset from its neighbour by `phase_step` frames, which turns the same
    # sequence into a wave travelling across the block.
    struct FluxSpinner
      getter tick : Int64
      getter frames : Array(String)
      getter width : Int32
      getter height : Int32
      getter spin : Spin
      getter ticks_per_step : Int32
      getter phase_step : Int32
      getter glyph_style : Style
      getter style : Style
      getter block : Block?
      getter alignment : Alignment

      def initialize(tick : Int = 0,
                     @frames : Array(String) = FluxFrames::BRAILLE,
                     width : Int = 1,
                     height : Int = 1,
                     @spin : Spin = Spin::Clockwise,
                     ticks_per_step : Int = 1,
                     phase_step : Int = 1,
                     @glyph_style : Style = Style.new(Color::CYAN),
                     @style : Style = Style.new,
                     @block : Block? = nil,
                     @alignment : Alignment = Alignment::Left)
        @tick = tick.to_i64
        @width = {width.to_i, 1}.max
        @height = {height.to_i, 1}.max
        @ticks_per_step = {ticks_per_step.to_i, 1}.max
        @phase_step = {phase_step.to_i, 0}.max
      end

      def char_size : Tuple(Int32, Int32)
        {@width, @height}
      end

      # The single glyph for this tick — what a one-line reporter needs.
      def frame : String
        frame_at(0)
      end

      def lines : Array(Line)
        (0...@height).map do |row|
          spans = (0...@width).map { |col| Span.new(frame_at(row * @width + col), @glyph_style) }
          Line.new(spans, @alignment)
        end
      end

      def render(area : Rect, buffer : Buffer) : Nil
        Spinner.paint(lines, area, buffer, @style, @block)
      end

      private def frame_at(cell : Int32) : String
        count = @frames.size
        return " " if count.zero?
        raw = (@tick // @ticks_per_step) + cell.to_i64 * @phase_step
        index = (raw % count).to_i32
        # Anticlockwise walks the sequence backwards, which also reverses the
        # direction the wave travels.
        index = (count - index) % count if @spin.counter_clockwise?
        @frames[index]
      end
    end
  end
end
