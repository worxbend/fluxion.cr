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

private def key(character : Char, modifiers = CryTUI::KeyModifiers::None)
  CryTUI::KeyEvent.character(character, modifiers)
end

private def press(screen, *characters : Char)
  characters.each { |character| screen.handle(key(character)) }
end

private def screenshot(screen, width = 100, height = 24) : String
  backend = CryTUI::TestBackend.new(width, height)
  terminal = CryTUI::Terminal.new(backend)
  terminal.draw { |frame| screen.render(frame) }
  backend.buffer.lines.join('\n')
end

# A screen partway through the profile above: `git` done, `curl` in flight.
private def running_screen
  screen = Fluxion::TUI::ExecutionScreen.new(sample_profile, "live")
  screen.on_event(Fluxion::ExecutionEvent.phase_started("base"))
  screen.on_event(Fluxion::ExecutionEvent.step_started("tools"))
  screen.on_event(Fluxion::ExecutionEvent.item_started("tools", "git"))
  screen.on_event(Fluxion::ExecutionEvent.item_output("tools", "git", "Installing git"))
  screen.on_event(Fluxion::ExecutionEvent.item_completed("tools", "git",
    Fluxion::StepResult::Success.new("git")))
  screen.on_event(Fluxion::ExecutionEvent.item_started("tools", "curl"))
  screen
end

describe Fluxion::TUI::ExecutionScreen do
  describe "grouping" do
    it "files items under their step and their phase" do
      rendered = screenshot(running_screen)

      rendered.should contain("base")
      rendered.should contain("tools")
      rendered.should contain("git")
    end

    it "counts a step's finished items against its total" do
      screenshot(running_screen).should contain("1/2")
    end

    it "hides a phase's steps when it is folded" do
      screen = running_screen
      press(screen, 'g', 'g') # up to the phase heading
      press(screen, 'h')

      # The header names the step the run is on, so the tree's own row is what
      # this checks — the fold arrow is part of it.
      rendered = screenshot(screen, 70, 24)
      rendered.should contain("base")
      rendered.should_not contain("▾ tools")
    end

    it "puts a failure's reason on its own line so it is not truncated away" do
      screen = Fluxion::TUI::ExecutionScreen.new(sample_profile, "live")
      screen.on_event(Fluxion::ExecutionEvent.item_completed("tools", "broken",
        Fluxion::StepResult::Failure.new("broken", "no match for argument: broken", 1)))

      screenshot(screen).should contain("no match for argument: broken")
    end

    it "shows only failures on request" do
      screen = running_screen
      screen.on_event(Fluxion::ExecutionEvent.item_completed("tools", "curl",
        Fluxion::StepResult::Failure.new("curl", "mirror unreachable", 1)))

      press(screen, 'e')
      rendered = screenshot(screen)
      rendered.should contain("curl")
      rendered.should_not contain("✔ git")
    end
  end

  describe "progress" do
    it "measures the run against the item count the profile declares" do
      # 4 items in the profile, 1 finished.
      screenshot(running_screen).should contain("1/4 items")
      screenshot(running_screen).should contain("25%")
    end

    it "reports a profile with nothing in it as complete rather than dividing by zero" do
      empty = Fluxion::Profile.new("empty", Fluxion::TargetOs.new(Fluxion::Distribution::Fedora),
        [] of Fluxion::Phase)
      screenshot(Fluxion::TUI::ExecutionScreen.new(empty, "live")).should contain("100%")
    end
  end

  describe "output" do
    it "tails the whole run until a step is pinned" do
      screen = running_screen
      screen.on_event(Fluxion::ExecutionEvent.item_output("tools", "curl", "Downloading curl"))

      rendered = screenshot(screen)
      rendered.should contain("Installing git")
      rendered.should contain("Downloading curl")
    end

    it "narrows to one item's output once it is pinned, and widens again on escape" do
      screen = running_screen
      screen.on_event(Fluxion::ExecutionEvent.item_output("tools", "curl", "Downloading curl"))

      # Rows are: the phase, the step, then its items. Two moves down lands on
      # `git`.
      press(screen, 'g', 'g')
      2.times { press(screen, 'j') }
      screen.handle(CryTUI::KeyEvent.new(CryTUI::KeyCode::Enter))

      rendered = screenshot(screen)
      rendered.should contain("Installing git")
      rendered.should_not contain("Downloading curl")

      screen.handle(CryTUI::KeyEvent.new(CryTUI::KeyCode::Escape))
      screenshot(screen).should contain("Downloading curl")
    end

    it "keeps the newest output on screen and stays bounded" do
      screen = Fluxion::TUI::ExecutionScreen.new(sample_profile, "live")
      3_000.times do |index|
        screen.on_event(Fluxion::ExecutionEvent.item_output("tools", "git", "line #{index}"))
      end

      rendered = screenshot(screen)
      rendered.should contain("line 2999")
      rendered.should_not contain("line 0 ")
    end

    it "can give the whole width back to the tree" do
      screen = running_screen
      screenshot(screen).should contain("output")

      press(screen, 'o')
      screenshot(screen).should_not contain("live tail")
    end
  end

  describe "keys" do
    it "asks for a stop while the run is going and leaves once it is over" do
      screen = running_screen

      screen.handle(key('q')).should eq(Fluxion::TUI::ExecutionScreen::Outcome::Cancel)
      screenshot(screen).should contain("stopping after")

      screen.finish
      screen.handle(key('q')).should eq(Fluxion::TUI::ExecutionScreen::Outcome::Exit)
    end

    it "treats ctrl-c the same as q" do
      screen = running_screen
      screen.handle(key('c', CryTUI::KeyModifiers::Control))
        .should eq(Fluxion::TUI::ExecutionScreen::Outcome::Cancel)
    end

    it "opens the which-key menu and the keybinding list" do
      screen = running_screen

      press(screen, ' ')
      screenshot(screen).should contain("+ui")

      screen.handle(CryTUI::KeyEvent.new(CryTUI::KeyCode::Escape))
      press(screen, '?')
      screenshot(screen).should contain("keybindings")
    end
  end

  it "renders at any terminal size without raising" do
    screen = running_screen
    { {120, 40}, {80, 24}, {40, 12}, {20, 6}, {4, 3} }.each do |width, height|
      screenshot(screen, width, height)
    end
  end
end
