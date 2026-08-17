module Fluxion::TUI
  # Drives the terminal UI: select, then run, then report.
  #
  # The terminal is put into raw mode and the alternate screen only while a
  # screen is actually being drawn, and always restored — including on an
  # exception — so a crash never leaves the user with an invisible cursor and
  # no echo.
  class App
    # 20 frames a second. Fast enough that a spinner reads as a spinner and a
    # gradient as a slide rather than a stutter, slow enough that a full-screen
    # diff is nowhere near the cost of the run it is describing.
    FRAME_INTERVAL = 50.milliseconds

    def initialize(@profile : Profile, @options : Executor::RunOptions, @resume : Resume = Resume.none)
    end

    # True when the terminal can support the UI at all.
    def self.available? : Bool
      STDOUT.tty? && STDIN.tty?
    end

    record Outcome, summary : Executor::RunSummary, cancelled : Bool

    def run(orchestrator : Executor::Orchestrator, cancellation : CancellationSignal) : Outcome?
      selection = Selection.new(@profile)

      return unless choose(selection)
      profile = selection.apply

      execute(profile, orchestrator, cancellation)
    end

    # Keys, read on their own fiber, for every screen this app shows.
    #
    # Input and animation cannot both own the loop: a screen that blocks on
    # `read` stops animating between keypresses, and one that polls with a
    # timeout burns the CPU. Keys arrive on a channel instead, and each screen
    # waits for whichever comes first — a key or the next frame deadline.
    #
    # One reader for the whole run, not one per screen. A fiber blocked in
    # `STDIN.read` cannot be called off, so a second reader started for the
    # execution screen left two fibers racing for the same keyboard — and the
    # one still holding the selector's channel won often enough that keys
    # pressed during the run simply vanished.
    private def keys : Channel(CryTUI::KeyEvent)
      @keys ||= start_key_reader
    end

    @keys : Channel(CryTUI::KeyEvent)? = nil

    private def start_key_reader : Channel(CryTUI::KeyEvent)
      keys = Channel(CryTUI::KeyEvent).new(64)

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
        # The terminal went away mid-run. The draw loop notices when the
        # channel stops producing and carries on animating, which is the same
        # thing that happens when nobody is typing.
      end

      keys
    end

    # Returns false when the user cancelled.
    private def choose(selection : Selection) : Bool
      screen = SelectorScreen.new(selection, @resume)
      outcome = SelectorScreen::Outcome::Continue

      terminal do |terminal|
        loop do
          terminal.draw { |frame| screen.render(frame) }

          select
          when event = keys.receive
            outcome = screen.handle(event)
            break unless outcome.continue?
          when timeout(FRAME_INTERVAL)
            # Nothing pressed; redraw the next animation frame.
          end
        end
      end

      outcome.run?
    end

    private def execute(profile : Profile, orchestrator : Executor::Orchestrator,
                        cancellation : CancellationSignal) : Outcome
      mode = @options.dry_run? ? "dry-run" : @options.probe_only? ? "probe-only" : "live"
      screen = ExecutionScreen.new(profile, mode)
      summary = Executor::RunSummary.new
      failure = nil.as(Exception?)

      # The run happens on its own fiber so the UI keeps repainting while a
      # long package install blocks.
      done = Channel(Nil).new
      spawn do
        summary = orchestrator.run(profile, @options, screen, cancellation)
      rescue error
        failure = error
      ensure
        screen.finish
        done.send(nil)
      end

      drive(screen, cancellation, done)

      raise failure.not_nil! if failure

      Outcome.new(summary, cancellation.cancelled?)
    end

    # Draws the execution screen until the run ends and the user has read the
    # summary.
    #
    # The screen is held after the run finishes rather than torn down with it:
    # a summary that vanished the instant the last item completed would be
    # useless, and the output of every step is still there to be read.
    private def drive(screen : ExecutionScreen, cancellation : CancellationSignal,
                      done : Channel(Nil)) : Nil
      leaving = false

      terminal do |terminal|
        until leaving
          terminal.draw { |frame| screen.render(frame) }

          select
          when event = keys.receive
            case screen.handle(event)
            when .cancel?
              # Cooperative: the executor stops at the next item boundary, and
              # the screen says so meanwhile.
              cancellation.cancel
              screen.cancelling
            when .exit?
              # Only once there is nothing left to stop. Before that the same
              # key means "stop the run", which the branch above handled.
              leaving = screen.finished?
            end
          when done.receive
            # The run is over. The screen stays up until it is dismissed.
          when timeout(FRAME_INTERVAL)
            # Nothing pressed; redraw the next animation frame.
          end
        end

        # One last frame, so what is left on screen is the final state rather
        # than whatever was drawn just before the key that dismissed it.
        terminal.draw { |frame| screen.render(frame) }
      end
    end

    # Enters the alternate screen in raw mode and always restores both.
    # The terminal currently in the alternate screen, if any. Only ever one:
    # screens are entered and left one at a time.
    @@entered : CryTUI::Terminal? = nil
    @@restore_installed = false

    def self.terminal(& : CryTUI::Terminal ->) : Nil
      backend = CryTUI::AnsiBackend.for_terminal(STDOUT, STDOUT)
      terminal = CryTUI::Terminal.new(backend)

      install_emergency_restore
      @@entered = terminal
      begin
        terminal.run(STDIN) { |active| yield active }
      ensure
        @@entered = nil
      end
    end

    # `Terminal#run` and `IO::FileDescriptor#raw` both restore through `ensure`,
    # which covers a normal return and an exception but not `exit` — and a
    # second Ctrl-C during `apply` exits straight from the signal-handling
    # fiber. That left the user in the alternate screen with echo off and the
    # cursor hidden, having to type `reset` blind, which is exactly what this
    # class's header comment promises never happens.
    #
    # Registered once per process; `Terminal#stop` and `cooked!` are both
    # no-ops when there is nothing to undo.
    private def self.install_emergency_restore : Nil
      return if @@restore_installed
      @@restore_installed = true

      at_exit do
        @@entered.try(&.stop)
        STDIN.cooked! rescue nil
      end
    end

    private def terminal(& : CryTUI::Terminal ->) : Nil
      App.terminal { |active| yield active }
    end
  end
end
