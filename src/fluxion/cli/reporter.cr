module Fluxion::CLI
  # Renders execution events to a terminal as the run happens.
  #
  # Each item opens a line and closes it with its outcome, so progress is
  # visible on one screen rather than scrolling past. Output from a command is
  # indented under the item that produced it, which is what makes a failure
  # readable without scrolling back to find what was running.
  class Reporter
    include ExecutionListener

    getter summary : Executor::RunSummary

    # Whether to echo each command's own output. Off by default: a package
    # manager's progress bars bury Fluxion's structure.
    property? stream_output : Bool

    def initialize(@output : IO = STDOUT, @stream_output : Bool = false)
      @summary = Executor::RunSummary.new
      @open_item = false
      @spinner = Spinner.new(@output)
    end

    def on_event(event : ExecutionEvent) : Nil
      case event.kind
      in .phase_started?    then phase_started(event)
      in .phase_completed?  then phase_completed(event)
      in .phase_failed?     then phase_failed(event)
      in .phase_blocked?    then phase_blocked(event)
      in .restart_required? then restart_required(event)
      in .module_started?   then step_started(event)
      in .module_completed? then nil
      in .item_started?     then item_started(event)
      in .item_output?      then item_output(event)
      in .item_completed?   then item_completed(event)
      in .cancelled?        then cancelled(event)
      in .error?            then nil # already reported by ItemCompleted
      end
    end

    private def phase_started(event : ExecutionEvent) : Nil
      close_item
      @output.puts
      @output.puts "#{Style.bold_blue("[PHASE]")} #{Style.bold(event.step_name)}"
    end

    private def phase_completed(event : ExecutionEvent) : Nil
      close_item
      @output.puts "#{Style.bold_blue("[DONE]")} #{event.step_name}"
    end

    private def phase_failed(event : ExecutionEvent) : Nil
      close_item
      @output.puts "#{Style.bold_red("[FAIL]")} phase #{event.step_name}"
    end

    private def phase_blocked(event : ExecutionEvent) : Nil
      close_item
      @output.puts "#{Style.yellow("[BLOCK]")} #{event.step_name} #{Style.dim("waits for #{event.item}")}"
    end

    private def restart_required(event : ExecutionEvent) : Nil
      close_item
      @output.puts
      @output.puts Style.bold_yellow("#{Symbols.warning} Restart required")
      event.item.each_line { |line| @output.puts "  #{line}" }
    end

    private def step_started(event : ExecutionEvent) : Nil
      close_item
      @output.puts "  #{Style.cyan(event.step_name)}"
    end

    private def item_started(event : ExecutionEvent) : Nil
      close_item
      # Left open so the outcome lands on the same line; the spinner animates
      # that line in place until it does.
      @spinner.start(event.item)
      @open_item = true
    end

    private def item_output(event : ExecutionEvent) : Nil
      return unless @stream_output
      line = event.output_line
      return if line.nil? || line.strip.empty?
      close_item
      @output.puts "        #{Style.dim(line)}"
    end

    private def item_completed(event : ExecutionEvent) : Nil
      result = event.result
      return unless result

      @summary.record(result)

      case result
      when StepResult::Success
        finish "#{Style.green(Symbols.success)} #{Style.green("ok")}#{elapsed(result.elapsed)}"
      when StepResult::Failure
        finish "#{Style.red(Symbols.failure)} #{Style.red("failed")} #{Style.dim("(exit #{result.exit_code})")}"
        @output.puts "        #{Style.red(result.error_message)}"
      when StepResult::Skipped
        finish "#{Style.dim(Symbols.skipped)} #{Style.dim("skipped: #{result.reason}")}"
      when StepResult::DryRun
        finish Style.cyan("would run")
        preview = result.would_execute
        @output.puts "        #{Style.dim("$ #{preview.join(' ')}")}" unless preview.empty?
      when StepResult::Paused
        finish "#{Style.bold_yellow(Symbols.paused)} #{Style.bold_yellow("paused")}"
        @output.puts "        #{result.message}"
      end
    end

    private def cancelled(event : ExecutionEvent) : Nil
      close_item
      @output.puts
      @output.puts Style.bold_yellow("#{Symbols.warning} Stopped at your request; state was saved")
      @output.puts "  #{Style.dim("Next phase: #{event.item}")}" unless event.item.empty?
    end

    # Prints the closing half of an open item line.
    private def finish(text : String) : Nil
      if @open_item
        @spinner.stop
        @output.puts text
        @open_item = false
      else
        @output.puts "      #{text}"
      end
    end

    private def close_item : Nil
      return unless @open_item
      @spinner.stop
      @output.puts
      @open_item = false
    end

    private def elapsed(span : Time::Span) : String
      return "" if span < 100.milliseconds
      Style.dim(" (#{"%.1f" % span.total_seconds}s)")
    end

    # The closing tally, printed whether or not the run succeeded.
    def print_summary : Nil
      close_item
      @output.puts

      parts = [
        Style.green("#{@summary.succeeded} ok"),
        @summary.failed > 0 ? Style.red("#{@summary.failed} failed") : Style.dim("0 failed"),
        Style.dim("#{@summary.skipped} skipped"),
      ]
      parts << Style.cyan("#{@summary.dry_run} would run") if @summary.dry_run > 0
      parts << Style.bold_yellow("#{@summary.paused} paused") if @summary.paused > 0

      @output.puts "#{Style.bold("Summary:")} #{parts.join(Style.dim(" · "))}"

      unless @summary.failed_phases.empty?
        @output.puts Style.red("Failed phases: #{@summary.failed_phases.join(", ")}")
      end
      unless @summary.blocked_phases.empty?
        @output.puts Style.yellow("Blocked phases: #{@summary.blocked_phases.join(", ")}")
      end
    end
  end
end
