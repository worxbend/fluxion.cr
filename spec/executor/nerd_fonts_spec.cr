require "../spec_helper"

# `NerdFontsExecutor` was rewritten when the inline config was removed and had
# no spec at all.
private def fonts_step(config : String = "/tmp/nerd-fonts.yaml") : Fluxion::NerdFontsStep
  Fluxion::NerdFontsStep.new("fonts", config)
end

private def preview(step : Fluxion::NerdFontsStep) : Array(String)
  executor = Fluxion::Executor::NerdFontsExecutor.new
  executor.commands(step, executor.items(step).first).first.preview
end

private def run(step : Fluxion::NerdFontsStep) : Fluxion::StepResult
  executor = Fluxion::Executor::NerdFontsExecutor.new
  executor.execute(step, executor.items(step).first, Fluxion::Executor::FakeShellRunner.new) { }
end

describe Fluxion::Executor::NerdFontsExecutor do
  it "previews the installer's own dry run" do
    # A preview must not be able to install anything.
    preview(fonts_step).should eq(
      ["nerd-fonts-installer", "--config", "/tmp/nerd-fonts.yaml", "--dry-run"])
  end

  it "yields one item for the whole config" do
    # Not one per family: the executor applies the config as a whole, so a
    # profile naming 42 families used to invoke the installer 42 times.
    executor = Fluxion::Executor::NerdFontsExecutor.new
    executor.items(fonts_step).size.should eq(1)
  end

  it "fails with a message naming the path when the config is absent" do
    result = run(fonts_step("/nope/absent.yaml"))

    result.should be_a(Fluxion::StepResult::Failure)
    result.as(Fluxion::StepResult::Failure).error_message.should contain("/nope/absent.yaml")
  end

  it "hashes the config into the fingerprint like the other delegated kinds" do
    directory = File.tempname("fluxion-fonts")
    Dir.mkdir_p(directory)
    path = File.join(directory, "nerd-fonts.yaml")
    begin
      File.write(path, "families: [Hack]\n")
      before = fonts_step(path).content_digest
      File.write(path, "families: [Hack, FiraCode]\n")

      fonts_step(path).content_digest.should_not eq(before)
    ensure
      FileUtils.rm_rf(directory)
    end
  end
end

describe Fluxion::Executor::DotbotExecutor do
  it "previews and runs the same flag spelling" do
    # The preview used `-c` where the run used `--config`, and took its
    # executable from a `dotbotBinary` field the run ignored — so the two could
    # name a different program with a different flag.
    step = Fluxion::DotbotStep.new("dots", "/tmp/install.conf.yaml")
    executor = Fluxion::Executor::DotbotExecutor.new
    argv = executor.commands(step, executor.items(step).first).first.preview

    argv.should eq(["dotbot", "--config", "/tmp/install.conf.yaml", "--dry-run"])
  end
end
