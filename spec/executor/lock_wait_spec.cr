require "../spec_helper"

private APT_LOCKED = "E: Could not get lock /var/lib/dpkg/lock-frontend. It is held by process 80066 (apt-get)\n" \
                     "E: Unable to acquire the dpkg frontend lock (/var/lib/dpkg/lock-frontend), is another process using it?\n"

# Answers a matching command as locked for its first `times` runs, then
# hands it to the usual fake answers.
private class LockedRunner < Fluxion::Executor::FakeShellRunner
  def initialize(@matching : String, @times : Int32, @message : String = APT_LOCKED, @exit_code : Int32 = 100)
    super()
  end

  def run(command : Fluxion::Executor::Command, &sink : String ->) : Fluxion::ProcessResult
    result = super(command, &sink)
    return result unless command.argv.join(' ').includes?(@matching) && @times > 0

    @times -= 1
    Fluxion::ProcessResult.new(@exit_code, @message)
  end
end

private def waiting(inner : Fluxion::Executor::ShellRunner,
                    cancellation : Fluxion::CancellationSignal = Fluxion::CancellationSignal.new,
                    budget : Time::Span = Fluxion::Executor::LockWaitingRunner::BUDGET)
  pauses = [] of Time::Span
  runner = Fluxion::Executor::LockWaitingRunner.new(inner, cancellation, budget,
    ->(span : Time::Span) { pauses << span; nil })
  {runner, pauses}
end

private def install(*packages : String) : Fluxion::Executor::Command
  Fluxion::Executor::Command.new(["sudo", "apt-get", "install", "-y"] + packages.to_a)
end

describe Fluxion::Executor::LockWaitingRunner do
  it "runs a command again once another process lets go of the lock" do
    inner = LockedRunner.new("install -y virt-manager", 2)
    runner, pauses = waiting(inner)
    lines = [] of String

    result = runner.run(install("virt-manager")) { |line| lines << line }

    result.success?.should be_true
    inner.argv.size.should eq(3)
    pauses.should eq([5.seconds, 10.seconds])
    lines.count(&.includes?("apt-get is locked by another process")).should eq(2)
  end

  it "grows the pause up to its cap" do
    inner = LockedRunner.new("apt-get", 6)
    runner, pauses = waiting(inner)
    runner.run(install("vde2")).success?.should be_true

    pauses.should eq([5, 10, 20, 30, 30, 30].map(&.seconds))
  end

  it "gives up with the lock error once the budget is spent" do
    inner = LockedRunner.new("apt-get", 100)
    runner, pauses = waiting(inner, budget: 20.seconds)
    lines = [] of String

    result = runner.run(install("vde2")) { |line| lines << line }

    result.exit_code.should eq(100)
    result.stdout.should contain("Could not get lock")
    pauses.sum(Time::Span.zero).should eq(20.seconds)
    lines.last.should contain("giving up after waiting 20s")
  end

  it "does not wait again for later commands while the same lock is still held" do
    # A batch that gave up falls back to one process per package; each of
    # those would otherwise wait the whole budget again.
    inner = LockedRunner.new("apt-get", 100)
    runner, pauses = waiting(inner, budget: 20.seconds)
    runner.run(install("git", "curl"))
    waited = pauses.size

    runner.run(install("git")).exit_code.should eq(100)
    pauses.size.should eq(waited)
  end

  it "has the whole budget again for the next contention once the lock was released" do
    inner = LockedRunner.new("apt-get", 1)
    runner, _ = waiting(inner, budget: 5.seconds)
    runner.run(install("git")).success?.should be_true
    runner.waited.should eq(Time::Span.zero)
  end

  it "stops waiting when the user cancels" do
    cancellation = Fluxion::CancellationSignal.new
    inner = LockedRunner.new("apt-get", 100)
    runner = Fluxion::Executor::LockWaitingRunner.new(inner, cancellation, pause: ->(_span : Time::Span) { cancellation.cancel; nil })

    runner.run(install("git")).exit_code.should eq(100)
    inner.argv.size.should eq(1)
  end

  it "does not retry a failure that is not the lock" do
    inner = Fluxion::Executor::FakeShellRunner.new.on("apt-get", 100, "E: Unable to locate package nosuch\n")
    runner, pauses = waiting(inner)

    runner.run(install("nosuch")).exit_code.should eq(100)
    inner.argv.size.should eq(1)
    pauses.should be_empty
  end

  it "does not retry a profile's own shell command, which may not be safe to run twice" do
    inner = LockedRunner.new("bash", 1)
    runner, pauses = waiting(inner)

    runner.run(Fluxion::Executor::Command.new(["sudo", "/bin/bash", "-lc", "apt install ./x.deb"]))
      .exit_code.should eq(100)
    pauses.should be_empty
  end

  it "knows the lock messages of the other managers" do
    inner = LockedRunner.new("zypper", 1, "System management is locked by the application with pid 812 (zypper).", 7)
    runner, pauses = waiting(inner)

    runner.run(Fluxion::Executor::Command.new(["sudo", "zypper", "--non-interactive", "install", "git"]))
      .success?.should be_true
    pauses.size.should eq(1)
  end

  it "looks past a normalised sudo marker" do
    Fluxion::Executor::LockWaitingRunner.target(["/usr/bin/sudo", "-n", "--", "/usr/bin/apt-get", "update"])
      .should eq("apt-get")
  end
end

describe Fluxion::Executor::Orchestrator do
  it "waits out a held package lock instead of failing every package" do
    inner = LockedRunner.new("install -y git curl", 2)
    orchestrator = Fluxion::Executor::Orchestrator.new(inner, lock_pause: ->(_span : Time::Span) { nil })
    step = Fluxion::PackagesStep.new("tools", Fluxion::PackageManager::Apt, %w[git curl])
    profile = Fluxion::Profile.new("test", Fluxion::TargetOs.new(Fluxion::Distribution::Ubuntu),
      [Fluxion::Phase.new("base", [step] of Fluxion::Step, [] of String, Fluxion::RestartPolicy::None.new, true)])

    summary = orchestrator.run(profile, Fluxion::Executor::RunOptions.new, Fluxion::RecordingExecutionListener.new)

    summary.succeeded.should eq(2)
    summary.failed.should eq(0)
    inner.argv.size.should eq(3)
  end
end
