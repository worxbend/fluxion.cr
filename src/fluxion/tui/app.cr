module Fluxion::TUI
  # Drives the terminal UI: select, then run, then report.
  #
  # The terminal is put into raw mode and the alternate screen only while a
  # screen is actually being drawn, and always restored — including on an
  # exception — so a crash never leaves the user with an invisible cursor and
  # no echo.
  class App
    FRAME_INTERVAL = 80.milliseconds

    def initialize(@profile : Profile, @options : Executor::RunOptions)
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

    # Returns false when the user cancelled.
    private def choose(selection : Selection) : Bool
      screen = SelectorScreen.new(selection)
      outcome = SelectorScreen::Outcome::Continue

      terminal do |terminal|
        parser = CryTUI::InputParser.new
        buffer = Bytes.new(1024)

        loop do
          terminal.draw { |frame| screen.render(frame) }

          read = STDIN.read(buffer)
          break if read.zero?

          events = parser.feed(String.new(buffer[0, read]))
          events.each do |event|
            next unless event.is_a?(CryTUI::KeyEvent)
            outcome = screen.handle(event)
          end

          break unless outcome.continue?
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

      terminal do |terminal|
        until screen.finished?
          terminal.draw { |frame| screen.render(frame) }
          sleep FRAME_INTERVAL
        end

        done.receive
        terminal.draw { |frame| screen.render(frame) }
        # Held on screen until acknowledged: a summary that vanished the
        # instant the run ended would be useless.
        wait_for_key
      end

      raise failure.not_nil! if failure

      Outcome.new(summary, cancellation.cancelled?)
    end

    private def wait_for_key : Nil
      buffer = Bytes.new(16)
      STDIN.read(buffer)
    rescue IO::Error
    end

    # Enters the alternate screen in raw mode and always restores both.
    def self.terminal(& : CryTUI::Terminal ->) : Nil
      backend = CryTUI::AnsiBackend.for_terminal(STDOUT, STDOUT)
      terminal = CryTUI::Terminal.new(backend)
      terminal.run(STDIN) { |active| yield active }
    end

    private def terminal(& : CryTUI::Terminal ->) : Nil
      App.terminal { |active| yield active }
    end
  end
end
