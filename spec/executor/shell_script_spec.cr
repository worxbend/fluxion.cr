require "../spec_helper"

# `shell-scripts` gained an explicit interpreter, an inline body, and a remote
# path that actually runs. The interpreter used to be sniffed from the file's
# shebang with no way to state it.
private def script_step(scripts : Array(Fluxion::ShellScriptItem),
                        shell : Fluxion::ShellKind? = nil) : Fluxion::ShellScriptStep
  Fluxion::ShellScriptStep.new("setup", scripts, shell: shell)
end

private def argv_for(step : Fluxion::ShellScriptStep) : Array(String)
  executor = Fluxion::Executor::ShellScriptExecutor.new
  executor.commands(step, executor.items(step).first).first.preview
end

private def run(step : Fluxion::ShellScriptStep,
                runner = Fluxion::Executor::FakeShellRunner.new) : Fluxion::StepResult
  executor = Fluxion::Executor::ShellScriptExecutor.new
  executor.execute(step, executor.items(step).first, runner) { }
end

describe Fluxion::Executor::ShellScriptExecutor do
  describe "interpreter selection" do
    it "uses the item's shell when it names one" do
      step = script_step([Fluxion::ShellScriptItem.new(
        name: "s", script: "/tmp/s.sh", shell: Fluxion::ShellKind::Zsh)])

      argv_for(step).first.should eq("zsh")
    end

    it "falls back to the step's shell" do
      step = script_step([Fluxion::ShellScriptItem.new(name: "s", script: "/tmp/s.sh")],
        shell: Fluxion::ShellKind::Sh)

      argv_for(step).first.should eq("sh")
    end

    it "lets an item override the step" do
      step = script_step([Fluxion::ShellScriptItem.new(
        name: "s", script: "/tmp/s.sh", shell: Fluxion::ShellKind::Bash)],
        shell: Fluxion::ShellKind::Zsh)

      argv_for(step).first.should eq("bash")
    end

    it "passes the bare name, not an absolute path" do
      # Under `sudo`, `Sudo.resolve` scans the root-owned system directories
      # itself; hardcoding /bin/zsh fails on a host where zsh lives elsewhere.
      step = script_step([Fluxion::ShellScriptItem.new(
        name: "s", script: "/tmp/s.sh", shell: Fluxion::ShellKind::Zsh)])

      argv_for(step).first.should_not contain("/")
    end

    it "reads the shebang when no shell is declared" do
      ProfileHelpers.with_profile("#!/usr/bin/env python3\nprint('hi')\n", "s.py") do |path|
        step = script_step([Fluxion::ShellScriptItem.new(name: "s", script: path)])
        argv_for(step).first.should contain("env")
      end
    end

    it "falls back to bash when there is no shebang and no declaration" do
      ProfileHelpers.with_profile("echo hi\n", "s.sh") do |path|
        step = script_step([Fluxion::ShellScriptItem.new(name: "s", script: path)])
        argv_for(step).first.should eq("/bin/bash")
      end
    end
  end

  describe "inline content" do
    it "writes the body and runs it as a file" do
      # Never `[shell, "-lc", body]`: a body passed as an argument shows up in
      # process listings, and `$0`/`$@` would not behave as a script.
      runner = Fluxion::Executor::FakeShellRunner.new
      step = script_step([Fluxion::ShellScriptItem.new(
        name: "linger", content: "echo hi\n", shell: Fluxion::ShellKind::Bash)])

      run(step, runner).should be_a(Fluxion::StepResult::Success)
      argv = runner.argv.first
      argv.first.should eq("bash")
      argv[1].should end_with(".sh")
      argv.should_not contain("-lc")
    end

    it "names the body in the preview rather than a path that does not exist yet" do
      step = script_step([Fluxion::ShellScriptItem.new(
        name: "linger", content: "echo hi\n", shell: Fluxion::ShellKind::Bash)])

      argv_for(step).should contain("<inline linger>")
    end

    it "passes args through to the body" do
      runner = Fluxion::Executor::FakeShellRunner.new
      step = script_step([Fluxion::ShellScriptItem.new(
        name: "linger", content: "echo \"$1\"\n", shell: Fluxion::ShellKind::Bash,
        args: ["someone"])])

      run(step, runner)
      runner.argv.first.last.should eq("someone")
    end

    it "changes the phase fingerprint when the body is edited" do
      # The body lives in the profile but in no item key, so nothing else in
      # the fingerprint would see it change.
      before = Fluxion::State::Fingerprint.of(Fluxion::Phase.new("p",
        [script_step([Fluxion::ShellScriptItem.new(name: "s", content: "echo one\n",
          shell: Fluxion::ShellKind::Bash)])] of Fluxion::Step))
      after = Fluxion::State::Fingerprint.of(Fluxion::Phase.new("p",
        [script_step([Fluxion::ShellScriptItem.new(name: "s", content: "echo two\n",
          shell: Fluxion::ShellKind::Bash)])] of Fluxion::Step))

      after.should_not eq(before)
    end
  end

  describe "guards" do
    it "skips before writing or fetching anything" do
      # `creates` used to be checked after the remote branch, so an already
      # satisfied script still paid for the download.
      ProfileHelpers.with_profile("", "present") do |existing|
        runner = Fluxion::Executor::FakeShellRunner.new
        step = script_step([Fluxion::ShellScriptItem.new(
          name: "s", content: "echo hi\n", shell: Fluxion::ShellKind::Bash,
          creates: existing)])

        run(step, runner).should be_a(Fluxion::StepResult::Skipped)
        runner.commands.should be_empty
      end
    end
  end

  describe "sudo" do
    it "puts sudo ahead of the interpreter" do
      step = script_step([Fluxion::ShellScriptItem.new(
        name: "s", script: "/tmp/s.sh", shell: Fluxion::ShellKind::Bash, sudo: true)])

      argv_for(step).first(2).should eq(["sudo", "bash"])
    end
  end
end

describe "preview and run agree on the interpreter" do
  it "does not read a remote script's shebang" do
    # The bytes do not exist when `plan` runs, so reading them at execute time
    # would make the preview describe a different command than the run — the
    # one thing this codebase says it will not do.
    remote = Fluxion::ShellScriptItem.new(
      name: "vendor", url: "https://example.test/install.sh",
      sha256: Fluxion::Checksum.new(Fluxion::ChecksumAlgorithm::Sha256, "0" * 64))
    step = Fluxion::ShellScriptStep.new("setup", [remote])

    argv_for(step).first.should eq("/bin/bash")
  end

  it "uses a remote script's declared shell in the preview" do
    remote = Fluxion::ShellScriptItem.new(
      name: "vendor", url: "https://example.test/install.sh",
      shell: Fluxion::ShellKind::Sh,
      sha256: Fluxion::Checksum.new(Fluxion::ChecksumAlgorithm::Sha256, "0" * 64))
    step = Fluxion::ShellScriptStep.new("setup", [remote])

    argv_for(step).first.should eq("sh")
  end
end

# The remote path became reachable once `DownloadSupport` gave it an injectable
# transport; before that no spec could execute it without a network.
private class FakeFetchingScriptExecutor < Fluxion::Executor::ShellScriptExecutor
  def initialize(@transport : Fluxion::Executor::FakeHttpTransport)
    super()
  end

  protected def http_transport : Fluxion::Executor::HttpTransport
    @transport
  end
end

private def run_remote(step : Fluxion::ShellScriptStep,
                       transport : Fluxion::Executor::FakeHttpTransport,
                       runner = Fluxion::Executor::FakeShellRunner.new) : Fluxion::StepResult
  executor = FakeFetchingScriptExecutor.new(transport)
  executor.execute(step, executor.items(step).first, runner) { }
end

private def remote_step(body : String, digest : String,
                        shell : Fluxion::ShellKind? = nil) : Fluxion::ShellScriptStep
  Fluxion::ShellScriptStep.new("setup", [Fluxion::ShellScriptItem.new(
    name: "vendor", url: "https://example.test/install.sh", shell: shell,
    sha256: Fluxion::Checksum.new(Fluxion::ChecksumAlgorithm::Sha256, digest))])
end

describe "remote scripts" do
  it "downloads, verifies, and runs the fetched file" do
    body = "#!/bin/sh\necho hi\n"
    transport = Fluxion::Executor::FakeHttpTransport.new.on("https://example.test/install.sh", body)
    runner = Fluxion::Executor::FakeShellRunner.new

    result = run_remote(remote_step(body, Digest::SHA256.hexdigest(body)), transport, runner)

    result.should be_a(Fluxion::StepResult::Success)
    runner.argv.first.last.should end_with(".sh")
  end

  it "refuses to run bytes whose digest does not match" do
    # The pin is the whole reason a remote script is allowed at all.
    transport = Fluxion::Executor::FakeHttpTransport.new
      .on("https://example.test/install.sh", "tampered")
    runner = Fluxion::Executor::FakeShellRunner.new

    result = run_remote(remote_step("expected", Digest::SHA256.hexdigest("expected")),
      transport, runner)

    result.should be_a(Fluxion::StepResult::Failure)
    result.as(Fluxion::StepResult::Failure).error_message.should contain("Checksum mismatch")
    runner.commands.should be_empty
  end

  it "reports an unreachable host as a failed item rather than raising" do
    result = run_remote(remote_step("x", Digest::SHA256.hexdigest("x")),
      Fluxion::Executor::FakeHttpTransport.new)

    result.should be_a(Fluxion::StepResult::Failure)
  end

  it "re-runs when the pin changes" do
    # The item key is the URL, so re-pinning to a new release would otherwise
    # leave the step looking unchanged.
    one = Fluxion::State::Fingerprint.of(Fluxion::Phase.new("p",
      [remote_step("a", Digest::SHA256.hexdigest("a"))] of Fluxion::Step))
    two = Fluxion::State::Fingerprint.of(Fluxion::Phase.new("p",
      [remote_step("b", Digest::SHA256.hexdigest("b"))] of Fluxion::Step))

    two.should_not eq(one)
  end
end

describe "failure paths" do
  it "reports a local script that is not there" do
    step = Fluxion::ShellScriptStep.new("setup",
      [Fluxion::ShellScriptItem.new(name: "s", script: "/nope/absent.sh")])
    result = run(step)

    result.should be_a(Fluxion::StepResult::Failure)
    result.as(Fluxion::StepResult::Failure).error_message.should contain("/nope/absent.sh")
  end

  it "reports a non-zero exit with the command that produced it" do
    runner = Fluxion::Executor::FakeShellRunner.new.default(Fluxion::ProcessResult.new(3, "boom"))
    step = script_step([Fluxion::ShellScriptItem.new(
      name: "s", content: "exit 3\n", shell: Fluxion::ShellKind::Bash)])

    result = run(step, runner)
    failure = result.as(Fluxion::StepResult::Failure)
    failure.exit_code.should eq(3)
    failure.error_message.should contain("exited 3")
  end

  it "honours allowedExitCodes" do
    runner = Fluxion::Executor::FakeShellRunner.new.default(Fluxion::ProcessResult.new(1, ""))
    step = script_step([Fluxion::ShellScriptItem.new(
      name: "s", content: "exit 1\n", shell: Fluxion::ShellKind::Bash,
      allowed_exit_codes: [0, 1])])

    run(step, runner).should be_a(Fluxion::StepResult::Success)
  end
end
