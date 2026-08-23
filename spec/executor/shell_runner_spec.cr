require "../spec_helper"

private def command(*argv : String, **options)
  Fluxion::Executor::Command.new(argv.to_a, **options)
end

describe Fluxion::Executor::SystemShellRunner do
  runner = Fluxion::Executor::SystemShellRunner.new

  it "runs a command and captures its output" do
    result = runner.run(command("/bin/echo", "hello"))
    result.success?.should be_true
    result.exit_code.should eq(0)
    result.stdout.should contain("hello")
  end

  it "reports a nonzero exit code" do
    result = runner.run(command("/bin/sh", "-c", "exit 3"))
    result.success?.should be_false
    result.exit_code.should eq(3)
  end

  it "merges stderr into the captured output" do
    # A failure message is worth more with its surrounding output in order, so
    # the two streams are interleaved rather than kept apart.
    result = runner.run(command("/bin/sh", "-c", "echo out; echo err >&2"))
    result.stdout.should contain("out")
    result.stdout.should contain("err")
  end

  it "streams output lines as they arrive" do
    lines = [] of String
    runner.run(command("/bin/sh", "-c", "echo one; echo two")) { |line| lines << line }
    lines.should eq(["one", "two"])
  end

  it "passes environment values through" do
    result = runner.run(command("/bin/sh", "-c", "echo $FLUXION_SPEC",
      env: {"FLUXION_SPEC" => "present"}))
    result.stdout.should contain("present")
  end

  it "runs in the requested working directory" do
    directory = File.tempname("fluxion-cwd")
    Dir.mkdir_p(directory)
    begin
      result = runner.run(command("/bin/sh", "-c", "pwd", working_dir: directory))
      result.stdout.should contain(File.basename(directory))
    ensure
      Dir.delete(directory)
    end
  end

  it "kills a command that outruns its timeout" do
    result = runner.run(command("/bin/sleep", "30", timeout: 200.milliseconds))
    result.success?.should be_false
    result.exit_code.should eq(Fluxion::Executor::SystemShellRunner::TIMEOUT_EXIT_CODE)
    result.stderr.should contain("timed out")
  end

  it "reports a missing executable rather than raising" do
    result = runner.run(command("/definitely/missing/fluxion-binary"))
    result.success?.should be_false
    result.stderr.should contain("Failed to start process")
  end

  it "redacts secrets out of streamed output" do
    secret = [Fluxion::ShellEnvironmentVariable.new("TOKEN", "hunter2seekrit", true)]
    lines = [] of String
    runner.run(command("/bin/echo", "value hunter2seekrit", sensitive: secret)) { |line| lines << line }
    lines.join.should contain("<redacted>")
    lines.join.should_not contain("hunter2seekrit")
  end

  it "strips escape sequences out of streamed output" do
    lines = [] of String
    # Through the shell rather than /bin/printf: on Alpine — which is what CI
    # runs — printf is a builtin and that path does not exist, so the spec
    # would pass by producing no output at all.
    runner.run(command("/bin/sh", "-c", "printf '\\033[31mred\\n'")) { |line| lines << line }
    lines.join.should eq("red")
  end

  it "does not deadlock on output larger than a pipe buffer" do
    result = runner.run(command("/bin/sh", "-c", "seq 1 20000", timeout: 30.seconds))
    result.success?.should be_true
    result.stdout.should contain("20000")
  end

  it "keeps output the process wrote before it exited even when the sink is slow" do
    # Output is read on a fiber of its own, and that fiber only makes progress
    # while the sink lets it. A sink that stalls on its first line parks the
    # reading fiber for long enough that the process finishes and its output is
    # left sitting in the pipe unread — the moment at which closing the pipe
    # would throw that output away instead of reporting it.
    lines = [] of String
    stalled = false

    result = runner.run(command("/bin/sh", "-c", "seq 1 5000", timeout: 30.seconds)) do |line|
      unless stalled
        stalled = true
        sleep 100.milliseconds
      end
      lines << line
    end

    result.success?.should be_true
    lines.size.should eq(5000)
    lines.last.should eq("5000")
    result.stdout.should contain("\n5000\n")
    result.stdout.should_not contain("drain budget ran out")
  end

  it "does not leak the pipe it read the output through" do
    # Not a regression test — the pipe was closed before the drain wait existed
    # too. It pins the new close placement: the drain returns without closing
    # when the stream ended on its own, so the unconditional close after it is
    # now the only one on that path, and counting the process's own descriptors
    # is the way to notice if it is ever dropped.
    pending! "no /proc on this host" unless Dir.exists?("/proc/self/fd")

    runner.run(command("/bin/echo", "warm-up"))
    before = Dir.children("/proc/self/fd").size
    20.times { runner.run(command("/bin/echo", "hi")) }

    Dir.children("/proc/self/fd").size.should be <= before + 2
  end
end

describe Fluxion::Executor::Command do
  it "masks secrets in its preview" do
    secret = [Fluxion::ShellEnvironmentVariable.new("TOKEN", "ghp_abcdef", true)]
    command = Fluxion::Executor::Command.new(["curl", "-H", "Authorization: Bearer ghp_abcdef"],
      sensitive: secret)
    command.preview.join(' ').should_not contain("ghp_abcdef")
  end

  it "treats only its configured codes as success" do
    command = Fluxion::Executor::Command.new(["dnf", "check-update"], success_codes: Set{0, 100})
    command.success?(100).should be_true
    command.success?(1).should be_false
  end
end

describe Fluxion::Executor::Sudo do
  it "recognises a privileged invocation" do
    Fluxion::Executor::Sudo.invocation?(["sudo", "dnf", "install"]).should be_true
    Fluxion::Executor::Sudo.invocation?(["/usr/bin/sudo", "dnf"]).should be_true
    Fluxion::Executor::Sudo.invocation?(["dnf", "install"]).should be_false
    Fluxion::Executor::Sudo.invocation?([] of String).should be_false
  end

  it "leaves an unprivileged command untouched" do
    argv = ["paru", "-S", "--noconfirm", "yay-bin"]
    Fluxion::Executor::Sudo.for_effect(argv).should eq(argv)
  end

  it "rewrites a privileged command to a non-interactive form with a resolved target" do
    pending! "no trusted sudo on this host" unless Fluxion::Executor::Sudo.available?

    effect = Fluxion::Executor::Sudo.for_effect(["sudo", "env", "A=1"])
    effect[0].should end_with("sudo")
    # `-n` is what stops a privileged step from silently waiting for a password
    # on a terminal nobody is watching.
    effect[1].should eq("-n")
    effect[2].should eq("--")
    effect[3].should start_with('/')
    effect[3].should end_with("env")
    effect[4].should eq("A=1")
  end

  it "refuses a privileged command with no target" do
    expect_raises(Fluxion::ExecutionError, /no executable target/) do
      Fluxion::Executor::Sudo.for_effect(["sudo", "-i"])
    end
  end

  it "refuses to resolve an executable outside the trusted system directories" do
    expect_raises(Fluxion::ExecutionError, /trusted root-owned system/) do
      Fluxion::Executor::Sudo.resolve("/tmp/definitely-not-trusted")
    end
  end

  it "refuses a name that is really a path" do
    expect_raises(Fluxion::ExecutionError, /trusted root-owned system directory/) do
      Fluxion::Executor::Sudo.resolve("../../tmp/evil")
    end
  end
end

describe Fluxion::Executor::FakeShellRunner do
  it "records what it was asked to run" do
    runner = Fluxion::Executor::FakeShellRunner.new
    runner.run(Fluxion::Executor::Command.new(["dnf", "install", "-y", "git"]))

    runner.ran?("dnf install").should be_true
    runner.argv.first.should eq(["dnf", "install", "-y", "git"])
  end

  it "replays a queued result for a matching command" do
    runner = Fluxion::Executor::FakeShellRunner.new
    runner.on("rpm -q git", 1)

    runner.run(Fluxion::Executor::Command.new(["rpm", "-q", "git"])).exit_code.should eq(1)
    runner.run(Fluxion::Executor::Command.new(["rpm", "-q", "curl"])).exit_code.should eq(0)
  end

  it "replays queued output lines" do
    runner = Fluxion::Executor::FakeShellRunner.new
    runner.output["flatpak list"] = ["com.spotify.Client"]

    lines = [] of String
    runner.run(Fluxion::Executor::Command.new(["flatpak", "list", "--app"])) { |line| lines << line }
    lines.should eq(["com.spotify.Client"])
  end
end
