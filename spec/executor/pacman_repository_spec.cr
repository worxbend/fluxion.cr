require "../spec_helper"

# This is the one repository executor that edits a file it does not own —
# /etc/pacman.conf, which the distribution and the user also write to. It reads
# the whole file, appends one section, and installs the result atomically, and
# none of that was covered. The risks it has to avoid are appending twice and
# running the two sections together on one line.
private def with_config(body : String?, & : String ->) : Nil
  directory = File.tempname("fluxion-pacman-spec")
  Dir.mkdir_p(directory)
  path = File.join(directory, "pacman.conf")
  File.write(path, body) if body
  begin
    yield path
  ensure
    FileUtils.rm_rf(directory) rescue nil
  end
end

private def multilib(config : String, enabled : Bool = true) : Fluxion::PacmanRepositoryStep
  Fluxion::PacmanRepositoryStep.new(
    name: "multilib", repository: "multilib", config: config,
    include_path: "/etc/pacman.d/mirrorlist", enabled: enabled)
end

# `grep -Fqx` exits 1 when the section is absent, which is what makes the
# executor decide to append. The fake's default of 0 would mean "already there".
private def absent_runner : Fluxion::Executor::FakeShellRunner
  Fluxion::Executor::FakeShellRunner.new.on("grep", 1)
end

private def execute(step : Fluxion::PacmanRepositoryStep,
                    runner : Fluxion::Executor::FakeShellRunner) : Fluxion::StepResult
  executor = Fluxion::Executor::PacmanRepositoryExecutor.new
  executor.execute(step, executor.items(step).first, runner) { }
end

describe Fluxion::Executor::PacmanRepositoryExecutor do
  it "appends the section and synchronises the databases" do
    with_config("[options]\nHoldPkg = pacman\n") do |config|
      runner = absent_runner
      execute(multilib(config), runner).should be_a(Fluxion::StepResult::Success)

      body = File.read(config)
      body.should start_with("[options]\nHoldPkg = pacman\n")
      body.should contain("[multilib]\nInclude = /etc/pacman.d/mirrorlist\n")
      runner.ran?("pacman -Sy").should be_true
    end
  end

  it "leaves the file alone when the section is already there" do
    original = "[options]\n\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n"
    with_config(original) do |config|
      # grep exiting 0 means the section was found.
      runner = Fluxion::Executor::FakeShellRunner.new
      execute(multilib(config), runner)

      File.read(config).should eq(original)
      # The databases are still synchronised: the repository is meant to be
      # usable when the step finishes, whether or not this run added it.
      runner.ran?("pacman -Sy").should be_true
    end
  end

  it "starts the new section on its own line when the file has no trailing newline" do
    with_config("[options]\nHoldPkg = pacman") do |config|
      execute(multilib(config), absent_runner)

      # Without the separator the appended section would land as
      # "HoldPkg = pacman[multilib]", which pacman cannot parse.
      File.read(config).should contain("HoldPkg = pacman\n\n[multilib]")
    end
  end

  it "writes a disabled repository commented out rather than leaving it out" do
    with_config("[options]\n") do |config|
      execute(multilib(config, enabled: false), absent_runner)

      body = File.read(config)
      body.should contain("[multilib]")
      body.should contain("# Include = /etc/pacman.d/mirrorlist")
    end
  end

  it "fails without touching the file when the config cannot be read" do
    with_config("[options]\n") do |config|
      # Any grep exit code other than 0 or 1 means grep itself failed, which is
      # not evidence that the section is absent.
      runner = Fluxion::Executor::FakeShellRunner.new.on("grep", 2)

      execute(multilib(config), runner).should be_a(Fluxion::StepResult::Failure)

      File.read(config).should eq("[options]\n")
      runner.ran?("pacman -Sy").should be_false
    end
  end
end
