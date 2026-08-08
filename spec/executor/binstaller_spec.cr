require "../spec_helper"

# `binstaller-profile` becomes the only way to install a binary, so its
# invocation is now load-bearing rather than a side path.
private def profile_step(**overrides) : Fluxion::BinstallerProfileStep
  Fluxion::BinstallerProfileStep.new("portable", "/tmp/binstaller.yaml", **overrides)
end

private def preview(step : Fluxion::BinstallerProfileStep) : Array(String)
  executor = Fluxion::Executor::BinstallerExecutor.new
  executor.commands(step, executor.items(step).first).first.preview
end

describe Fluxion::Executor::BinstallerExecutor do
  it "previews binstaller's plan, never its apply" do
    # A preview must not be able to install anything.
    preview(profile_step).should eq(["binstaller", "plan", "--config", "/tmp/binstaller.yaml"])
  end

  it "passes only and skip through verbatim" do
    argv = preview(profile_step(only: ["yazi", "neovim"], skip: ["zig"]))

    argv.should eq([
      "binstaller", "plan", "--config", "/tmp/binstaller.yaml",
      "--only", "yazi", "--only", "neovim", "--skip", "zig",
    ])
  end

  it "passes the lock file even when locked is not set" do
    # It used to be appended only inside `if locked?`, so a profile naming a
    # lock file ran unlocked against whatever was current.
    argv = preview(profile_step(lock_file: "/tmp/lock.json"))

    argv.should contain("--lock-file")
    argv.should contain("/tmp/lock.json")
    argv.should_not contain("--locked")
  end

  it "passes both when the profile is locked" do
    argv = preview(profile_step(locked: true, lock_file: "/tmp/lock.json"))

    argv.should contain("--locked")
    argv.should contain("/tmp/lock.json")
  end

  it "describes in the preview exactly what the run will do, apart from the verb" do
    # Both come from one argv builder, so they cannot drift. The preview used
    # to assemble its own and omit the lock flags entirely.
    step = profile_step(only: ["yazi"], locked: true, lock_file: "/tmp/lock.json")
    plan = preview(step)

    plan.first.should eq("binstaller")
    plan[1].should eq("plan")
    plan[2..].should eq([
      "--config", "/tmp/binstaller.yaml", "--only", "yazi", "--locked", "--lock-file", "/tmp/lock.json",
    ])
  end

  it "fails with a message naming the path when the config is absent" do
    step = Fluxion::BinstallerProfileStep.new("portable", "/nope/absent.yaml")
    executor = Fluxion::Executor::BinstallerExecutor.new
    result = executor.execute(step, executor.items(step).first,
      Fluxion::Executor::FakeShellRunner.new) { }

    result.should be_a(Fluxion::StepResult::Failure)
    result.as(Fluxion::StepResult::Failure).error_message.should contain("/nope/absent.yaml")
  end
end

describe "installerVersion" do
  it "is the version Fluxion actually resolves" do
    # KnownTools reads the core constant, so the pinned release and the schema
    # default cannot drift apart.
    Fluxion::Executor::KnownTools::BINSTALLER.version
      .should eq(Fluxion::BinstallerProfileStep::DEFAULT_INSTALLER_VERSION)
    Fluxion::Executor::KnownTools::NERD_FONTS.version
      .should eq(Fluxion::NerdFontsStep::DEFAULT_INSTALLER_VERSION)
    Fluxion::Executor::KnownTools::DOTBOT.version
      .should eq(Fluxion::DotbotStep::DEFAULT_INSTALLER_VERSION)
  end
end
