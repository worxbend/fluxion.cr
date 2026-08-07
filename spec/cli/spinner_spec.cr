require "../spec_helper"

describe Fluxion::CLI::Spinner do
  it "leaves a non-terminal transcript free of carriage returns and repeated frames" do
    output = IO::Memory.new
    spinner = Fluxion::CLI::Spinner.new(output)
    spinner.start("git")
    spinner.stop

    output.to_s.should eq("    #{Fluxion::CLI::Symbols.running} git ... ")
    output.to_s.should_not contain('\r')
  end

  it "does not animate an IO that cannot be rewritten" do
    Fluxion::CLI::Spinner.animate?(IO::Memory.new).should be_false
  end
end

describe Fluxion::CLI::Reporter do
  it "reports an item on one line, opened by the spinner and closed by the outcome" do
    output = IO::Memory.new
    reporter = Fluxion::CLI::Reporter.new(output)

    Fluxion::CLI::Style.with_color(false) do
      reporter.on_event(Fluxion::ExecutionEvent.item_started("packages", "git"))
      reporter.on_event(Fluxion::ExecutionEvent.item_completed(
        "packages", "git", Fluxion::StepResult::Success.new("git")))
    end

    output.to_s.lines.first.should eq("    #{Fluxion::CLI::Symbols.running} git ... #{Fluxion::CLI::Symbols.success} ok")
  end
end

describe Fluxion::Spinners do
  it "falls back to the default rather than failing on an unknown preset" do
    with_spinner("nonsense") do
      Fluxion::Spinners.name.should eq(Fluxion::Spinners::DEFAULT)
      Fluxion::Spinners.frames.should eq(CryTUI::Widgets::FluxFrames::BRAILLE)
    end
  end

  it "resolves a preset by name, case and spacing aside" do
    with_spinner(" MoOn ") do
      Fluxion::Spinners.name.should eq("moon")
      Fluxion::Spinners.frames.should eq(CryTUI::Widgets::FluxFrames::MOON)
    end
  end
end

private def with_spinner(value : String?, &)
  previous = ENV[Fluxion::Spinners::VARIABLE]?
  if value
    ENV[Fluxion::Spinners::VARIABLE] = value
  else
    ENV.delete(Fluxion::Spinners::VARIABLE)
  end
  yield
ensure
  if previous
    ENV[Fluxion::Spinners::VARIABLE] = previous
  else
    ENV.delete(Fluxion::Spinners::VARIABLE)
  end
end
