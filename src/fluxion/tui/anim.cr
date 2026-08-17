module Fluxion::TUI
  # The maths behind everything that moves or fades.
  #
  # Every screen derives its motion from one monotonically increasing frame
  # counter, so nothing here holds state: hand it the same frame twice and it
  # draws the same thing twice, which is what makes a redraw after a terminal
  # resize identical to the frame it replaces.
  module Anim
    extend self

    BARS         = ['▁', '▂', '▃', '▄', '▅', '▆', '▇', '█']
    ASCII_LEVELS = ['.', '-', '=', '+', '*', '#']

    # Mixes two colours, `amount` of the way from `from` to `to`.
    #
    # A terminal cell has no alpha channel, so anything that should look
    # translucent — a tinted selection bar, a border that glows as it pulses —
    # has to be composited here and stored as one solid colour. Indexed and
    # reset colours have no numeric channels to mix, so they are returned
    # unchanged rather than guessed at.
    def blend(from : CryTUI::Color, to : CryTUI::Color, amount : Number) : CryTUI::Color
      return from unless from.kind.rgb? && to.kind.rgb?
      t = amount.to_f32.clamp(0.0_f32, 1.0_f32)
      CryTUI::Color.rgb(
        lerp(from.red, to.red, t),
        lerp(from.green, to.green, t),
        lerp(from.blue, to.blue, t)
      )
    end

    # A 0-to-1 value that rises and falls smoothly, one full cycle every
    # `period` frames. Used for anything that breathes: a focused border, a
    # live badge.
    def pulse(frame : Int, period : Int = 30) : Float64
      return 0.0 if period <= 0
      (Math.sin(frame.to_f64 / period * Math::TAU) * 0.5 + 0.5)
    end

    # Text where every character is a slightly different colour, with the
    # gradient sliding along as the frame advances.
    #
    # This is the one flourish the whole interface leans on: it is what makes a
    # title look alive without any of it blinking, which in a terminal is the
    # difference between "designed" and "loud".
    def gradient_line(text : String, from : CryTUI::Color, to : CryTUI::Color, frame : Int,
                      bold = false, alignment = CryTUI::Alignment::Left) : CryTUI::Line
      CryTUI::Line.new(gradient_spans(text, from, to, frame, bold), alignment)
    end

    # :ditto:
    def gradient_spans(text : String, from : CryTUI::Color, to : CryTUI::Color, frame : Int,
                       bold = false) : Array(CryTUI::Span)
      width = {text.size, 1}.max.to_f32
      modifier = bold ? CryTUI::Modifier::Bold : CryTUI::Modifier::None
      text.each_char.map_with_index do |character, index|
        position = index.to_f32 / width
        wave = Math.sin(position * Math::TAU.to_f32 + frame.to_f32 * 0.12_f32)
        CryTUI::Span.new(character.to_s,
          CryTUI::Style.new(foreground: blend(from, to, wave * 0.5 + 0.5), modifiers: modifier))
      end.to_a
    end

    # Splices one row of a spinner into a line the caller is already building.
    #
    # Spinners render themselves into a rectangle, but most of the places this
    # interface wants one are mid-sentence rather than in a pane of their own.
    def spans(lines : Array(CryTUI::Line), row : Int32 = 0) : Array(CryTUI::Span)
      lines[row]?.try(&.spans) || [] of CryTUI::Span
    end

    def sparkline(values : Enumerable(Number), width : Int32) : String
      history(values, width, BARS, normalize_from_zero: true)
    end

    def sparkline_ascii(values : Enumerable(Number), width : Int32) : String
      history(values, width, ASCII_LEVELS, normalize_from_zero: false)
    end

    private def lerp(from : UInt8, to : UInt8, amount : Float32) : Int32
      (from + (to.to_i - from.to_i) * amount).round.to_i
    end

    private def history(values : Enumerable(Number), width : Int32, levels : Array(Char),
                        normalize_from_zero : Bool) : String
      return "" if width <= 0
      samples = values.map(&.to_f64).to_a.last(width)
      return levels.first.to_s * width if samples.empty?
      minimum = normalize_from_zero ? 0.0 : samples.min
      maximum = {samples.max, normalize_from_zero ? 1.0 : samples.min + Float64::EPSILON}.max
      range = {maximum - minimum, Float64::EPSILON}.max
      String.build do |io|
        io << levels.first.to_s * (width - samples.size)
        samples.each do |sample|
          index = (((sample - minimum) / range).clamp(0.0, 1.0) * (levels.size - 1)).round.to_i
          io << levels[index]
        end
      end
    end
  end
end
