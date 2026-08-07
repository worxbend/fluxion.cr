module Fluxion::CLI
  # The activity indicator on an open reporter line.
  #
  # Redrawn from its own fiber, because the thing it reports on is a package
  # manager that can sit silent for a minute; a static marker there is
  # indistinguishable from a hung run.
  #
  # It only animates where the line can be rewritten. Piped into a file, a
  # pager, or CI the label is printed once and no fiber is ever started, so the
  # transcript stays free of carriage returns and repeated frames.
  class Spinner
    FRAME_INTERVAL = 90.milliseconds

    # Matches the reporter's own indentation, so the outcome lands where it
    # always did.
    INDENT = "    "

    def initialize(@output : IO = STDOUT, @frames : Array(String) = Spinners.frames)
      @label = ""
      @tick = 0_i64
      @animating = false
      @halt = Channel(Nil).new(1)
      @stopped = Channel(Nil).new
    end

    # Whether this output can have a line redrawn under it.
    def self.animate?(output : IO) : Bool
      return false unless output.responds_to?(:tty?) && output.tty?
      Style.enabled?
    end

    # Opens a line and, where possible, starts animating it.
    def start(label : String) : Nil
      @label = label
      @tick = 0_i64
      @animating = Spinner.animate?(@output)
      draw(resting: !@animating)
      return unless @animating

      spawn do
        # Waiting on the halt signal rather than sleeping through it: an item
        # that finishes a third of the way into a frame should not hold the run
        # back for the remaining two thirds.
        loop do
          select
          when @halt.receive
            break
          when timeout(FRAME_INTERVAL)
            @tick += 1
            draw
          end
        end
        @stopped.send(nil)
      end
    end

    # Settles the line on the resting marker and leaves the cursor after it, so
    # the caller can print the outcome on the same line.
    def stop : Nil
      return unless @animating
      @halt.send(nil)
      @stopped.receive
      # Drawn while the spinner still counts as animating, so this last frame
      # overwrites the previous one instead of following it.
      draw(resting: true)
      @animating = false
    end

    private def draw(resting : Bool = false) : Nil
      glyph = resting ? Symbols.running : frame
      @output.print '\r' if @animating
      @output.print "#{INDENT}#{Style.dim(glyph)} #{@label} ... "
      @output.flush
    rescue IO::Error
      # The reader went away mid-run — `fluxion apply | head`. Nothing here is
      # worth failing a run over.
      @animating = false
    end

    private def frame : String
      CryTUI::Widgets::FluxSpinner.new(tick: @tick, frames: @frames).frame
    end
  end
end
