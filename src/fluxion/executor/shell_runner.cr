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
      Host.command_exists?(name)
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

    # How long to wait after asking a process to stop before killing it.
    TERMINATION_GRACE = 5.seconds

    getter? dry_run : Bool

    def initialize(@dry_run : Bool = false)
    end

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
      pump = spawn_pump(reader, capture, sanitizer, sink)
      exit_code = await(process, command.timeout)
      reader.close rescue nil
      pump.receive

      if trailing = sanitizer.finish.presence
        sink.call(trailing)
        capture << trailing
      end

      elapsed = Time.instant - started
      if exit_code.nil?
        return ProcessResult.new(TIMEOUT_EXIT_CODE, capture.to_s,
          "Process timed out after #{command.timeout}", elapsed)
      end

      ProcessResult.new(exit_code, capture.to_s, "", elapsed)
    end

    # Conventional exit code for "killed by a timeout", matching `timeout(1)`.
    TIMEOUT_EXIT_CODE = 124

    private def process_env(command : Command) : Hash(String, String)
      env = command.env.dup
      # Communicated through the environment as well as chdir, because a shell
      # started by the command reads PWD rather than asking the kernel.
      command.working_dir.try { |directory| env["PWD"] = directory }
      env
    end

    # Reads output on its own fiber so a process that writes more than a pipe
    # buffer cannot deadlock against a parent waiting on exit.
    private def spawn_pump(reader : IO, capture : BoundedCapture, sanitizer : Redaction::StreamingSanitizer, sink : Proc(String, Nil)) : Channel(Nil)
      done = Channel(Nil).new

      spawn do
        reader.each_line do |raw|
          line = raw.bytesize > MAX_LINE_BYTES ? TRUNCATED_LINE : sanitizer.line(raw)
          next if line.empty?
          capture << line
          sink.call(line)
        end
      rescue IO::Error
        # The pipe closed because the process was killed; whatever was read
        # before that is still worth reporting.
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
        terminate(process)
        select
        when result.receive
        when timeout(TERMINATION_GRACE)
        end
        nil
      end
    end

    # Signals the whole process group: a package manager that spawned children
    # would otherwise leave them running after Fluxion gave up on it.
    private def terminate(process : Process) : Nil
      process.signal(Signal::TERM) rescue nil
      sleep TERMINATION_GRACE
      process.signal(Signal::KILL) rescue nil
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
