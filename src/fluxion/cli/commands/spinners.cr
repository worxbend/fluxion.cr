module Fluxion::CLI
  # `fluxion spinners` — show the animations the CLI and TUI draw with.
  #
  # It exists so the setting is discoverable: FLUXION_SPINNER takes a preset
  # name, and picking one from a table of static glyphs is guesswork. On a
  # terminal this runs the animated gallery; anywhere else it prints the list,
  # so the command is still useful over a pipe.
  class SpinnersCommand < Command
    def name : String
      "spinners"
    end

    def summary : String
      "Preview the spinner animations and widgets"
    end

    def usage : String
      "fluxion spinners [--list] [--page frames|bars|linear|rings]"
    end

    @list = false
    @page = TUI::SpinnerGallery::Page::Frames

    def register(parser : OptionParser) : Nil
      parser.on("--list", "Print the frame presets instead of animating them") { @list = true }
      parser.on("--page=NAME", "Open on this gallery page: frames, bars, linear, rings") do |value|
        page = TUI::SpinnerGallery::Page.parse?(value.strip)
        raise Failure.invalid_input("Unknown page '#{value}'. Expected: frames, bars, linear, rings") unless page
        @page = page
      end
    end

    def run(arguments : Array(String)) : ExitCode
      parse(arguments)

      if @list || !@globals.use_tui?
        render_list
      else
        TUI::SpinnerGallery.run(@page)
      end

      ExitCode::Success
    end

    private def render_list : Nil
      puts "#{Style.bold("Frame presets")} #{Style.dim("— set #{Spinners::VARIABLE} to one of these")}"
      puts

      width = Spinners.names.max_of(&.size)
      Spinners.names.each do |preset|
        frames = CryTUI::Widgets::FluxFrames.named?(preset) || CryTUI::Widgets::FluxFrames::BRAILLE
        marker = preset == Spinners.name ? Style.green(Symbols.success) : " "
        puts "  #{marker} #{Style.cyan(preset.ljust(width))}  #{Style.dim(frames.join(' '))}"
      end

      puts
      puts "#{Style.bold("Widgets")} #{Style.dim("— shown animated by 'fluxion spinners' on a terminal")}"
      puts
      WIDGETS.each { |name, description| puts "  #{Style.cyan(name.ljust(8))}  #{description}" }

      puts
      puts Style.dim("Current: #{Spinners::VARIABLE}=#{Spinners.name}")
      return if @globals.use_tui? || @list
      puts Style.dim("A terminal is needed for the animated gallery.")
    end

    WIDGETS = {
      "flux"   => "A glyph cycling through a frame sequence, or a wave when widened",
      "bar"    => "A glowing arc bouncing, looping, converging or radiating along a bar",
      "linear" => "A window of lit symbols scrolling, or one bouncing down a column",
      "square" => "A braille arc rotating around a square ring",
      "rect"   => "The same arc around a configurable rectangle",
      "circle" => "A braille arc rotating around a circular ring",
    }
  end
end
