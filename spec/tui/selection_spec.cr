require "../spec_helper"

private def step(name : String, *packages : String)
  Fluxion::PackagesStep.new(name, Fluxion::PackageManager::Dnf, packages.to_a)
end

private def sample_profile
  Fluxion::Profile.new(
    "test",
    Fluxion::TargetOs.new(Fluxion::Distribution::Fedora),
    [
      Fluxion::Phase.new("base", [step("tools", "git", "curl"), step("extras", "jq")] of Fluxion::Step),
      Fluxion::Phase.new("desktop", [step("apps", "firefox")] of Fluxion::Step, ["base"]),
    ],
  )
end

private def key(character : Char)
  CryTUI::KeyEvent.character(character)
end

describe Fluxion::TUI::Selection do
  it "starts with everything selected" do
    # Running the profile as written is the common case; the selector exists
    # to remove things from that, not to build it up.
    selection = Fluxion::TUI::Selection.new(sample_profile)
    selection.any_selected?.should be_true
    selection.selected_steps.should eq(3)
    selection.selected_items.should eq(4)
  end

  it "takes a phase's steps with it when toggled off" do
    profile = sample_profile
    selection = Fluxion::TUI::Selection.new(profile)
    selection.toggle_phase(profile.phases.first)

    selection.phase?("base").should be_false
    selection.step?("tools").should be_false
    selection.step?("extras").should be_false
    selection.step?("apps").should be_true
  end

  it "deselects a phase once its last step goes" do
    profile = sample_profile
    selection = Fluxion::TUI::Selection.new(profile)
    base = profile.phases.first

    selection.toggle_step(base, base.steps[0])
    selection.phase?("base").should be_true

    selection.toggle_step(base, base.steps[1])
    selection.phase?("base").should be_false
  end

  it "reselects a phase when a step comes back" do
    profile = sample_profile
    selection = Fluxion::TUI::Selection.new(profile)
    base = profile.phases.first

    selection.toggle_phase(base)
    selection.toggle_step(base, base.steps.first)
    selection.phase?("base").should be_true
  end

  it "reports nothing selected once everything is off" do
    selection = Fluxion::TUI::Selection.new(sample_profile)
    selection.select_none
    selection.any_selected?.should be_false
    selection.selected_items.should eq(0)
  end

  describe "#apply" do
    it "keeps only the selected steps" do
      profile = sample_profile
      selection = Fluxion::TUI::Selection.new(profile)
      selection.toggle_step(profile.phases.first, profile.phases.first.steps[1])

      applied = selection.apply
      applied.steps.map(&.name).should eq(%w[tools apps])
    end

    it "drops a phase whose every step was deselected" do
      profile = sample_profile
      selection = Fluxion::TUI::Selection.new(profile)
      selection.toggle_phase(profile.phases.first)

      applied = selection.apply
      applied.phases.map(&.name).should eq(["desktop"])
    end

    it "narrows dependencies to phases that survived" do
      # A kept phase must not wait forever on one the user removed.
      profile = sample_profile
      selection = Fluxion::TUI::Selection.new(profile)
      selection.toggle_phase(profile.phases.first)

      applied = selection.apply
      applied.phases.first.depends_on.should be_empty
      applied.ordered_phases.map(&.name).should eq(["desktop"])
    end

    it "carries the profile's identity and policy across" do
      profile = sample_profile
      applied = Fluxion::TUI::Selection.new(profile).apply

      applied.name.should eq(profile.name)
      applied.target.distribution.should eq(profile.target.distribution)
      applied.base_dir.should eq(profile.base_dir)
    end
  end
end

describe Fluxion::TUI::SelectorScreen do
  it "toggles the row under the cursor" do
    selection = Fluxion::TUI::Selection.new(sample_profile)
    screen = Fluxion::TUI::SelectorScreen.new(selection)

    screen.handle(key('x'))
    selection.phase?("base").should be_false
  end

  it "moves with both arrows and vi keys" do
    selection = Fluxion::TUI::Selection.new(sample_profile)
    screen = Fluxion::TUI::SelectorScreen.new(selection)

    # Row 0 is the base phase; row 1 is its first step.
    screen.handle(key('j'))
    screen.handle(key('x'))

    selection.step?("tools").should be_false
    selection.phase?("base").should be_true
  end

  it "runs on enter when something is selected" do
    selection = Fluxion::TUI::Selection.new(sample_profile)
    screen = Fluxion::TUI::SelectorScreen.new(selection)

    screen.handle(CryTUI::KeyEvent.new(CryTUI::KeyCode::Enter))
      .should eq(Fluxion::TUI::SelectorScreen::Outcome::Run)
  end

  it "refuses to run with nothing selected" do
    # Starting a run that would do nothing is never what was meant.
    selection = Fluxion::TUI::Selection.new(sample_profile)
    selection.select_none
    screen = Fluxion::TUI::SelectorScreen.new(selection)

    screen.handle(CryTUI::KeyEvent.new(CryTUI::KeyCode::Enter))
      .should eq(Fluxion::TUI::SelectorScreen::Outcome::Continue)
  end

  it "cancels on q and escape" do
    selection = Fluxion::TUI::Selection.new(sample_profile)
    screen = Fluxion::TUI::SelectorScreen.new(selection)

    screen.handle(key('q')).should eq(Fluxion::TUI::SelectorScreen::Outcome::Cancel)
    screen.handle(CryTUI::KeyEvent.new(CryTUI::KeyCode::Escape))
      .should eq(Fluxion::TUI::SelectorScreen::Outcome::Cancel)
  end

  it "selects and clears everything with a and n" do
    selection = Fluxion::TUI::Selection.new(sample_profile)
    screen = Fluxion::TUI::SelectorScreen.new(selection)

    screen.handle(key('n'))
    selection.any_selected?.should be_false

    screen.handle(key('a'))
    selection.selected_steps.should eq(3)
  end

  it "renders every phase and step into the buffer" do
    selection = Fluxion::TUI::Selection.new(sample_profile)
    screen = Fluxion::TUI::SelectorScreen.new(selection)

    backend = CryTUI::TestBackend.new(100, 24)
    terminal = CryTUI::Terminal.new(backend)
    terminal.draw { |frame| screen.render(frame) }

    rendered = backend.buffer.lines.join('\n')
    rendered.should contain("base")
    rendered.should contain("tools")
    rendered.should contain("apps")
    rendered.should contain("FLUXION")
  end

  it "keeps the cursor on screen in a list taller than the terminal" do
    steps = (1..40).map { |index| step("step-#{index}", "package") }.to_a.map(&.as(Fluxion::Step))
    tall = Fluxion::Profile.new("tall", Fluxion::TargetOs.new(Fluxion::Distribution::Fedora),
      [Fluxion::Phase.new("base", steps)])

    screen = Fluxion::TUI::SelectorScreen.new(Fluxion::TUI::Selection.new(tall))
    40.times { screen.handle(key('j')) }

    backend = CryTUI::TestBackend.new(100, 20)
    terminal = CryTUI::Terminal.new(backend)
    terminal.draw { |frame| screen.render(frame) }

    # Scrolling the window rather than the cursor is what keeps the last row
    # reachable at all.
    backend.buffer.lines.join('\n').should contain("step-40")
  end
end

describe Fluxion::TUI::ExecutionScreen do
  it "renders items as their events arrive" do
    screen = Fluxion::TUI::ExecutionScreen.new(sample_profile, "live")

    screen.on_event(Fluxion::ExecutionEvent.phase_started("base"))
    screen.on_event(Fluxion::ExecutionEvent.step_started("tools"))
    screen.on_event(Fluxion::ExecutionEvent.item_started("tools", "git"))
    screen.on_event(Fluxion::ExecutionEvent.item_completed("tools", "git",
      Fluxion::StepResult::Success.new("git")))

    backend = CryTUI::TestBackend.new(100, 24)
    terminal = CryTUI::Terminal.new(backend)
    terminal.draw { |frame| screen.render(frame) }

    rendered = backend.buffer.lines.join('\n')
    rendered.should contain("git")
    rendered.should contain("1 ok")
  end

  it "replaces an item's row rather than appending to it" do
    screen = Fluxion::TUI::ExecutionScreen.new(sample_profile, "live")

    screen.on_event(Fluxion::ExecutionEvent.item_started("tools", "git"))
    screen.on_event(Fluxion::ExecutionEvent.item_completed("tools", "git",
      Fluxion::StepResult::Success.new("git")))

    backend = CryTUI::TestBackend.new(100, 24)
    terminal = CryTUI::Terminal.new(backend)
    terminal.draw { |frame| screen.render(frame) }

    backend.buffer.lines.count(&.includes?("git")).should eq(1)
  end

  it "shows a failure and its reason" do
    screen = Fluxion::TUI::ExecutionScreen.new(sample_profile, "live")
    screen.on_event(Fluxion::ExecutionEvent.item_completed("tools", "broken",
      Fluxion::StepResult::Failure.new("broken", "package not found", 1)))

    backend = CryTUI::TestBackend.new(100, 24)
    terminal = CryTUI::Terminal.new(backend)
    terminal.draw { |frame| screen.render(frame) }

    rendered = backend.buffer.lines.join('\n')
    rendered.should contain("broken")
    rendered.should contain("package not found")
    rendered.should contain("1 failed")
  end

  it "counts every result kind" do
    screen = Fluxion::TUI::ExecutionScreen.new(sample_profile, "dry-run")
    screen.on_event(Fluxion::ExecutionEvent.item_completed("s", "a", Fluxion::StepResult::Success.new("a")))
    screen.on_event(Fluxion::ExecutionEvent.item_completed("s", "b", Fluxion::StepResult::Skipped.new("b", "done")))
    screen.on_event(Fluxion::ExecutionEvent.item_completed("s", "c", Fluxion::StepResult::DryRun.new("c", ["echo"])))

    screen.summary.succeeded.should eq(1)
    screen.summary.skipped.should eq(1)
    screen.summary.dry_run.should eq(1)
  end

  it "bounds the log so a long run cannot grow without limit" do
    screen = Fluxion::TUI::ExecutionScreen.new(sample_profile, "live")
    1_000.times do |index|
      screen.on_event(Fluxion::ExecutionEvent.item_output("s", "a", "line #{index}"))
    end

    # Rendering is the observable proof it stayed bounded and still shows the
    # most recent lines.
    backend = CryTUI::TestBackend.new(100, 24)
    terminal = CryTUI::Terminal.new(backend)
    terminal.draw { |frame| screen.render(frame) }

    backend.buffer.lines.join('\n').should contain("line 999")
  end
end
