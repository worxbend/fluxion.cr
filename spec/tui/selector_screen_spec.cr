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

# The detail pane lists a phase's steps too, so assertions about what the tree
# shows are taken at a width where the detail pane is not drawn at all.
private def tree(screen) : String
  screenshot(screen, 70, 24)
end

private def screenshot(screen, width = 100, height = 24) : String
  backend = CryTUI::TestBackend.new(width, height)
  terminal = CryTUI::Terminal.new(backend)
  terminal.draw { |frame| screen.render(frame) }
  backend.buffer.lines.join('\n')
end

describe Fluxion::TUI::SelectorScreen do
  describe "folds" do
    it "hides a phase's steps when it is closed, and brings them back" do
      screen = Fluxion::TUI::SelectorScreen.new(Fluxion::TUI::Selection.new(sample_profile))

      press(screen, 'h')
      rendered = tree(screen)
      rendered.should contain("base")
      rendered.should_not contain("tools")

      press(screen, 'l')
      tree(screen).should contain("tools")
    end

    it "closes and opens every fold at once" do
      screen = Fluxion::TUI::SelectorScreen.new(Fluxion::TUI::Selection.new(sample_profile))

      # `zM` and `zR`, the Vim fold bindings.
      press(screen, 'z', 'M')
      tree(screen).should_not contain("tools")

      press(screen, 'z', 'R')
      tree(screen).should contain("tools")
    end

    it "moves out to the phase when there is nothing left to close" do
      # `h` on a step is a move outward, not a key that does nothing.
      selection = Fluxion::TUI::Selection.new(sample_profile)
      screen = Fluxion::TUI::SelectorScreen.new(selection)

      press(screen, 'j', 'h', 'x')
      selection.phase?("base").should be_false
    end
  end

  describe "selection" do
    it "toggles with x and with the leader sequence" do
      selection = Fluxion::TUI::Selection.new(sample_profile)
      screen = Fluxion::TUI::SelectorScreen.new(selection)

      press(screen, 'x')
      selection.phase?("base").should be_false

      # Space is the leader, so the checkbox lives at `<leader><leader>`.
      press(screen, ' ', ' ')
      selection.phase?("base").should be_true
    end

    it "inverts the selection" do
      selection = Fluxion::TUI::Selection.new(sample_profile)
      screen = Fluxion::TUI::SelectorScreen.new(selection)

      press(screen, 'j', 'x') # tools off
      press(screen, 'i')

      selection.step?("tools").should be_true
      selection.step?("extras").should be_false
      selection.step?("apps").should be_false
    end

    it "narrows the run to the row under the cursor" do
      selection = Fluxion::TUI::Selection.new(sample_profile)
      screen = Fluxion::TUI::SelectorScreen.new(selection)

      press(screen, 'j', 'o')

      selection.step?("tools").should be_true
      selection.step?("extras").should be_false
      selection.phase?("desktop").should be_false
    end

    it "will not start a run with nothing selected, and says why" do
      selection = Fluxion::TUI::Selection.new(sample_profile)
      screen = Fluxion::TUI::SelectorScreen.new(selection)
      press(screen, 'n')

      screen.handle(key('r')).should eq(Fluxion::TUI::SelectorScreen::Outcome::Continue)
      screenshot(screen).should contain("nothing selected")
    end
  end

  describe "resume" do
    it "offers what a previous run finished, and skips it on request" do
      selection = Fluxion::TUI::Selection.new(sample_profile)
      resume = Fluxion::TUI::Resume.new(Set{"base"}, "desktop")
      screen = Fluxion::TUI::SelectorScreen.new(selection, resume)

      screenshot(screen).should contain("saved state")

      press(screen, 'R')
      selection.phase?("base").should be_false
      selection.phase?("desktop").should be_true
    end

    it "says so when there is nothing to resume from" do
      screen = Fluxion::TUI::SelectorScreen.new(Fluxion::TUI::Selection.new(sample_profile))

      press(screen, 'R')
      screenshot(screen).should contain("no saved state")
    end
  end

  describe "search" do
    it "keeps only what matches, and restores the tree on escape" do
      screen = Fluxion::TUI::SelectorScreen.new(Fluxion::TUI::Selection.new(sample_profile))

      press(screen, '/', 'a', 'p', 'p')
      rendered = tree(screen)
      rendered.should contain("apps")
      rendered.should_not contain("extras")
      # A phase with no surviving steps goes too, rather than leaving an empty
      # heading to scroll past — `base` keeps only its dependency mention.
      rendered.should_not contain("tools")

      screen.handle(CryTUI::KeyEvent.new(CryTUI::KeyCode::Escape))
      tree(screen).should contain("extras")
    end

    it "matches on item names, not only on step names" do
      screen = Fluxion::TUI::SelectorScreen.new(Fluxion::TUI::Selection.new(sample_profile))

      press(screen, '/', 'c', 'u', 'r', 'l')
      tree(screen).should contain("tools")
    end

    it "types text rather than running commands while the search is open" do
      # `n` means "select none" outside a search and "the letter n" inside one.
      selection = Fluxion::TUI::Selection.new(sample_profile)
      screen = Fluxion::TUI::SelectorScreen.new(selection)

      press(screen, '/', 'n')
      selection.any_selected?.should be_true
    end
  end

  describe "overlays" do
    it "opens the which-key menu on the leader key" do
      screen = Fluxion::TUI::SelectorScreen.new(Fluxion::TUI::Selection.new(sample_profile))

      press(screen, ' ')
      screenshot(screen).should contain("selection")

      screen.handle(CryTUI::KeyEvent.new(CryTUI::KeyCode::Escape))
      screenshot(screen).should_not contain("+selection")
    end

    it "opens and closes the keybinding list" do
      screen = Fluxion::TUI::SelectorScreen.new(Fluxion::TUI::Selection.new(sample_profile))

      press(screen, '?')
      screenshot(screen).should contain("keybindings")

      press(screen, '?')
      screenshot(screen).should_not contain("keybindings")
    end

    it "swallows keys while the keybinding list is open" do
      # A list you are reading must not also be a list you are editing.
      selection = Fluxion::TUI::Selection.new(sample_profile)
      screen = Fluxion::TUI::SelectorScreen.new(selection)

      press(screen, '?', 'n')
      selection.any_selected?.should be_true
    end
  end

  it "renders at any terminal size without raising" do
    screen = Fluxion::TUI::SelectorScreen.new(Fluxion::TUI::Selection.new(sample_profile))
    { {120, 40}, {80, 24}, {40, 12}, {20, 6}, {4, 3} }.each do |width, height|
      screenshot(screen, width, height)
    end
  end
end

# The right-hand pane, sliced out of the screenshot so an assertion about it
# cannot accidentally be satisfied by the tree on the left — both show step
# names.
private def detail(screen, width = 100) : String
  screenshot(screen, width, 24).lines.map { |line| line.size > 67 ? line[67..] : "" }.join('\n')
end

private def scrollable_profile
  Fluxion::Profile.new(
    "test",
    Fluxion::TargetOs.new(Fluxion::Distribution::Fedora),
    [
      # Long enough that scrolling the detail pane pushes the step's own
      # heading off the top of it.
      Fluxion::Phase.new("base",
        [step("tools", "git", "curl", "jq", "ripgrep", "fd", "bat")] of Fluxion::Step),
      Fluxion::Phase.new("desktop", [step("apps", "firefox")] of Fluxion::Step, ["base"]),
    ],
  )
end

# Puts the cursor on the long step, focuses the detail pane, and scrolls it far
# enough that the step's own name is no longer visible.
private def scrolled_screen
  screen = Fluxion::TUI::SelectorScreen.new(Fluxion::TUI::Selection.new(scrollable_profile))
  press(screen, 'j')
  screen.handle(CryTUI::KeyEvent.new(CryTUI::KeyCode::Tab))
  press(screen, 'j', 'j', 'j', 'j')
  screen.handle(CryTUI::KeyEvent.new(CryTUI::KeyCode::Tab))

  detail(screen).should_not contain("tools")
  screen
end

# Putting the cursor on a row is a request to read that row, so the detail pane
# has to go back to the top. `j`/`k` and the group jumps always did; the four
# keys that set the cursor directly did not, and left the new row rendered from
# wherever the previous one had been scrolled to.
describe "the detail pane's scroll position" do
  it "returns to the top when G jumps to the last row" do
    screen = scrolled_screen
    press(screen, 'G')

    # The last row is the `apps` step, whose detail begins with its own name.
    detail(screen).should contain("apps")
    detail(screen).should contain("firefox")
  end

  it "returns to the top when End jumps to the last row" do
    screen = scrolled_screen
    screen.handle(CryTUI::KeyEvent.new(CryTUI::KeyCode::End))

    detail(screen).should contain("apps")
  end

  it "returns to the top when gg jumps to the first row" do
    screen = scrolled_screen
    press(screen, 'g', 'g')

    # The first row is the `base` phase, whose detail begins with its name and
    # then lists its steps.
    detail(screen).should contain("base")
  end

  it "returns to the top when Home jumps to the first row" do
    screen = scrolled_screen
    screen.handle(CryTUI::KeyEvent.new(CryTUI::KeyCode::Home))

    detail(screen).should contain("base")
  end
end
