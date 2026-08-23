module Fluxion::Executor
  # Runs processes on behalf of the executors.
  #
  # An interface rather than a concrete class so specs can drive every module
  # executor without spawning anything, and so `plan` and `dry-run` can share
  # the same code path as `apply` while never touching the host.
  abstract class ShellRunner
    # Runs `command`, yielding each output line as it arrives.
    abstract def run(command : Command, &sink : String ->) : ProcessResult

    def run(command : Command) : ProcessResult
      run(command) { }
    end

    # Convenience for probes and one-off checks.
    def capture(argv : Array(String), timeout : Time::Span = 30.seconds) : ProcessResult
      run(Command.new(argv, timeout: timeout))
    end

    # Whether the command exists and can be executed at all.
    def command_exists?(name : String) : Bool
      !resolve_command(name).nil?
    end

    # Where the command would be found, or nil. Part of the seam so a caller
    # that needs the path gets it from the same place as the existence check,
    # rather than agreeing with a fake about one and the real host about the
    # other.
    def resolve_command(name : String) : String?
      Host.resolve_command(name)
    end
  end

  # The real runner.
  class SystemShellRunner < ShellRunner
    # Output is captured for failure messages, but a runaway process must not
    # be able to exhaust memory. The head and tail are what a human reads, so
    # the middle is what gets dropped.
    MAX_CAPTURE_HEAD = 256 * 1024
    MAX_CAPTURE_TAIL = 256 * 1024

    # A single line longer than this is almost certainly binary output or an
    # attempt to flood the terminal.
    MAX_LINE_BYTES = 64 * 1024

    TRUNCATED_LINE = "[output line truncated]"

    # Written into the output when the drain below gave up with the pipe still
    # open, so a truncated tail is never mistaken for the end of the story.
    TRUNCATED_DRAIN = "[output truncated: the pipe was still open when the drain budget ran out]"

    # How long to wait after asking a process to stop before killing it.
    TERMINATION_GRACE = 5.seconds

    # How long to keep the output pipe open after the process has exited so the
    # reading fiber can finish what is still sitting in it.
    #
    # The wait is idle-based rather than a flat budget. A command that leaves a
    # descendant holding the write end — a script that backgrounds a daemon, a
    # login shell that starts an ssh-agent — keeps the pipe open indefinitely,
    # and charging every such command a fixed five seconds would be paid by the
    # common case to serve the rare one. So the drain continues only while the
    # pump is still delivering lines: one quiet interval means nothing more is
    # coming and the reader can be taken away. `DRAIN_LIMIT` caps the total in
    # case something keeps writing forever, and hitting that cap is reported in
    # the output rather than passed off as the whole of it.
    DRAIN_IDLE  = 200.milliseconds
    DRAIN_LIMIT = 5.seconds

    def run(command : Command, &sink : String ->) : ProcessResult
      argv = Sudo.for_effect(command.argv)
      started = Time.instant

      capture = BoundedCapture.new
      sanitizer = Redaction::StreamingSanitizer.new(command.sensitive)

      reader, writer = IO.pipe

      process = begin
        Process.new(
          argv.first,
          argv[1..],
          env: process_env(command),
          # The parent's environment is inherited so package managers find
          # their configuration; the command's own values overlay it.
          clear_env: false,
          chdir: command.working_dir,
          input: Process::Redirect::Close,
          output: writer,
          # Merged into one stream: interleaving matters more for diagnosing a
          # failure than knowing which descriptor a line came from.
          error: writer,
        )
      rescue error : File::Error | RuntimeError
        writer.close
        reader.close
        return ProcessResult.new(127, "", "Failed to start process: #{argv.first}: #{error.message}",
          Time.instant - started)
      end

      writer.close

      # The block is captured in the signature rather than yielded through:
      # the pump runs on its own fiber, and Crystal cannot forward a block
      # across that boundary.
      progress = Progress.new
      pump = spawn_pump(reader, capture, sanitizer, sink, progress)
      exit_code = await(process, command.timeout)

      # Measured before the drain below, so a command that leaves a daemon
      # holding the pipe is not reported as having taken the drain's time.
      elapsed = Time.instant - started

      # The pump is allowed to reach the end of the stream before the reader is
      # taken away from it. A process can exit with output still in the pipe the
      # pump has not read yet; closing the reader at that point raises inside
      # the pump and those bytes are lost, which is precisely the tail of the
      # output a failure message exists to show.
      unless drain(pump, progress, reader)
        sink.call(TRUNCATED_DRAIN)
        capture << TRUNCATED_DRAIN
      end

      # Unconditional: reaching the end of the stream does not close the reader,
      # so without this the read end of every command's pipe would leak. Closing
      # twice on the path above is harmless, as closing a file descriptor that is
      # already closed does nothing.
      reader.close rescue nil

      if trailing = sanitizer.finish.presence
        sink.call(trailing)
        capture << trailing
      end

      if exit_code.nil?
        return ProcessResult.new(TIMEOUT_EXIT_CODE, capture.to_s,
          "Process timed out after #{command.timeout}", elapsed)
      end

      ProcessResult.new(exit_code, capture.to_s, "", elapsed)
    end

    # Conventional exit code for "killed by a timeout", matching `timeout(1)`.
    TIMEOUT_EXIT_CODE = 124

    # Waits for the pump to finish reading, for as long as it keeps making
    # progress. Returns true when the stream ended on its own.
    #
    # Returns false when the reader had to be taken away instead: either the
    # pump went quiet for `DRAIN_IDLE` with the pipe still held open by
    # something that outlived the process, or it was still delivering when
    # `DRAIN_LIMIT` ran out. Only the second of those loses anything, and the
    # caller says so in the output.
    private def drain(pump : Channel(Nil), progress : Progress, reader : IO) : Bool
      deadline = Time.instant + DRAIN_LIMIT
      truncated = false

      loop do
        delivered = progress.count

        select
        when pump.receive
          return true
        when timeout(DRAIN_IDLE)
        end

        break if progress.count == delivered

        if Time.instant >= deadline
          truncated = true
          break
        end
      end

      reader.close rescue nil
      pump.receive
      !truncated
    end

    # A line counter shared with the pump fiber, so the drain above can tell
    # "still arriving" from "nothing more is coming". Fibers are cooperatively
    # scheduled and neither side yields mid-increment, so a plain counter is
    # enough; it never needs to be exact, only to change when work happens.
    private class Progress
      getter count = 0

      def hit : Nil
        @count += 1
      end
    end

    private def process_env(command : Command) : Hash(String, String)
      env = command.env.dup
      # Communicated through the environment as well as chdir, because a shell
      # started by the command reads PWD rather than asking the kernel.
      command.working_dir.try { |directory| env["PWD"] = directory }
      env
    end

    # Reads output on its own fiber so a process that writes more than a pipe
    # buffer cannot deadlock against a parent waiting on exit.
    private def spawn_pump(reader : IO, capture : BoundedCapture, sanitizer : Redaction::StreamingSanitizer,
                           sink : Proc(String, Nil), progress : Progress) : Channel(Nil)
      done = Channel(Nil).new

      spawn do
        reader.each_line do |raw|
          progress.hit
          line = raw.bytesize > MAX_LINE_BYTES ? TRUNCATED_LINE : sanitizer.line(raw)
          next if line.empty?
          capture << line
          sink.call(line)
        end
      rescue IO::Error
        # Most often the reader was closed to break this fiber out of a pipe
        # that something outliving the command is still holding open. A genuine
        # read error on the pipe, or one raised by the caller's own sink, lands
        # here too; in every case whatever was read before it is still worth
        # reporting, and the exit code is what decides the step's outcome.
      ensure
        done.send(nil)
      end

      done
    end

    # Waits for exit, returning nil on timeout after stopping the process.
    private def await(process : Process, timeout : Time::Span) : Int32?
      result = Channel(Process::Status).new(1)
      spawn { result.send(process.wait) rescue nil }

      select
      when status = result.receive
        status.exit_code
      when timeout(timeout)
        terminate(process, result)
        nil
      end
    end

    # Signals the whole process group: a package manager that spawned children
    # would otherwise leave them running after Fluxion gave up on it.
    #
    # The grace period is spent waiting on the exit channel rather than in a
    # `sleep`, for two reasons. A process that honours TERM is reaped the
    # moment it does, instead of being killed several seconds later for no
    # reason; and the caller previously sat out the grace period twice — once
    # sleeping here, once waiting for the exit afterwards — so giving up on a
    # command took twice as long as `TERMINATION_GRACE` claims.
    private def terminate(process : Process, exited : Channel(Process::Status)) : Nil
      process.signal(Signal::TERM) rescue nil

      select
      when exited.receive
        return
      when timeout(TERMINATION_GRACE)
      end

      process.signal(Signal::KILL) rescue nil

      select
      when exited.receive
      when timeout(TERMINATION_GRACE)
      end
    rescue
      # The process already exited between the timeout and the signal.
    end

    # Keeps the first and last of a stream, with a marker for what was dropped.
    private class BoundedCapture
      def initialize
        @head = String::Builder.new
        @head_bytes = 0
        @tail = Deque(String).new
        @tail_bytes = 0
        @dropped = 0
      end

      def <<(line : String) : Nil
        if @head_bytes < MAX_CAPTURE_HEAD
          @head << line << '\n'
          @head_bytes += line.bytesize + 1
          return
        end

        @tail << line
        @tail_bytes += line.bytesize + 1
        while @tail_bytes > MAX_CAPTURE_TAIL && (evicted = @tail.shift?)
          @tail_bytes -= evicted.bytesize + 1
          @dropped += 1
        end
      end

      def to_s : String
        head = @head.to_s
        return head if @tail.empty? && @dropped == 0

        String.build do |io|
          io << head
          io << "… [" << @dropped << " lines omitted] …\n" if @dropped > 0
          @tail.each { |line| io << line << '\n' }
        end
      end
    end
  end

  # A runner that records what it was asked to do and replays canned results.
  #
  # This is what lets the module executors be tested exhaustively: their real
  # contract is the argv they build and how they read a result, and both are
  # observable here without a package manager in sight.
  class FakeShellRunner < ShellRunner
    getter commands : Array(Command)

    # Output lines to emit for a matching command, keyed the same way.
    property output : Hash(String, Array(String))

    def initialize
      @commands = [] of Command
      @results = {} of String => ProcessResult
      @output = {} of String => Array(String)
      @default = ProcessResult.new(0)
      @known_commands = Set(String).new
    end

    # Queues a result for any command whose argv joins to a string containing
    # `matching`.
    def on(matching : String, result : ProcessResult) : self
      @results[matching] = result
      self
    end

    def on(matching : String, exit_code : Int32, stdout : String = "") : self
      on(matching, ProcessResult.new(exit_code, stdout))
    end

    def default(result : ProcessResult) : self
      @default = result
      self
    end

    def available(*names : String) : self
      names.each { |name| @known_commands << name }
      self
    end

    def command_exists?(name : String) : Bool
      @known_commands.includes?(name)
    end

    # A plausible location for anything `available` declared, so a caller that
    # needs the path gets an answer consistent with `command_exists?` rather
    # than falling through to the real `PATH`.
    def resolve_command(name : String) : String?
      return unless command_exists?(name)
      File.join("/usr/bin", name)
    end

    def run(command : Command, &sink : String ->) : ProcessResult
      @commands << command
      joined = command.argv.join(' ')

      @output.each do |matching, lines|
        next unless joined.includes?(matching)
        lines.each { |line| sink.call(line) }
      end

      @results.each { |matching, result| return result if joined.includes?(matching) }
      @default
    end

    # Every argv seen, joined, for concise assertions.
    def argv : Array(Array(String))
      @commands.map(&.argv)
    end

    def ran?(matching : String) : Bool
      @commands.any?(&.argv.join(' ').includes?(matching))
    end
  end
end
