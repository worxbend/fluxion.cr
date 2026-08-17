require "../spec_helper"

private def key(character : Char, modifiers = CryTUI::KeyModifiers::None)
  CryTUI::KeyEvent.character(character, modifiers)
end

private def leader
  key(' ')
end

describe Fluxion::TUI::Keymap do
  it "resolves a complete sequence to its action" do
    Fluxion::TUI::Keymap["gg"].should eq(Fluxion::TUI::ActionKind::NavigateTop)
    Fluxion::TUI::Keymap["<leader>q"].should eq(Fluxion::TUI::ActionKind::Quit)
  end

  it "knows a sequence that is only half typed" do
    Fluxion::TUI::Keymap.prefix?("<leader>s").should be_true
    # A completed binding is not a prefix of itself: holding onto it would
    # leave the next key resolving against a sequence that already fired.
    Fluxion::TUI::Keymap.prefix?("gg").should be_false
    Fluxion::TUI::Keymap.prefix?("zz").should be_false
  end

  it "names the key a press contributes" do
    Fluxion::TUI::Keymap.token(key('g')).should eq("g")
    Fluxion::TUI::Keymap.token(leader).should eq("<leader>")
    Fluxion::TUI::Keymap.token(key('d', CryTUI::KeyModifiers::Control)).should eq("<C-d>")
    Fluxion::TUI::Keymap.token(CryTUI::KeyEvent.new(CryTUI::KeyCode::Enter)).should be_nil
  end

  it "lists what can be pressed next, groups marked as groups" do
    entries = Fluxion::TUI::Keymap.continuations("<leader>")
    entries.map(&.token).should contain("s")
    entries.find! { |entry| entry.token == "s" }.group.should be_true
    entries.find! { |entry| entry.token == "q" }.group.should be_false

    # Sorted, so the menu does not reshuffle itself between frames.
    tokens = entries.map(&.token.downcase)
    tokens.should eq(tokens.dup.sort!)
  end

  it "titles a group by what it contains" do
    Fluxion::TUI::Keymap.title("<leader>s").should contain("selection")
  end

  it "keeps bracketed tokens whole when splitting a sequence" do
    Fluxion::TUI::Keymap.tokens("<C-w>hl").should eq(["<C-w>", "h", "l"])
  end

  it "describes every binding it can dispatch" do
    # A binding missing from the menu is a binding nobody finds, and one listed
    # but unbound is worse. Both come from this table, so neither can happen —
    # this guards the table itself against an empty description.
    Fluxion::TUI::Keymap::BINDINGS.each do |binding|
      binding.description.should_not be_empty
    end
  end
end

describe Fluxion::TUI::PendingSequence do
  it "holds a key that starts a sequence and fires when it completes" do
    pending = Fluxion::TUI::PendingSequence.new

    pending.feed(key('g')).should eq(Fluxion::TUI::PendingSequence::Verdict::Pending)
    pending.active?.should be_true
    pending.pending.should eq("g")

    pending.feed(key('g')).should eq(Fluxion::TUI::PendingSequence::Verdict::Resolved)
    pending.action.should eq(Fluxion::TUI::ActionKind::NavigateTop)
    pending.active?.should be_false
  end

  it "walks a three-key leader sequence" do
    pending = Fluxion::TUI::PendingSequence.new

    pending.feed(leader).should eq(Fluxion::TUI::PendingSequence::Verdict::Pending)
    pending.feed(key('s')).should eq(Fluxion::TUI::PendingSequence::Verdict::Pending)
    pending.pending.should eq("<leader>s")

    pending.feed(key('a')).should eq(Fluxion::TUI::PendingSequence::Verdict::Resolved)
    pending.action.should eq(Fluxion::TUI::ActionKind::SelectAll)
  end

  it "passes keys nothing is waiting for back to the screen" do
    pending = Fluxion::TUI::PendingSequence.new
    pending.feed(key('j')).should eq(Fluxion::TUI::PendingSequence::Verdict::Passed)
    pending.action.should be_nil
  end

  it "drops a dead end rather than replaying it" do
    # `g` then an unrelated key must not also perform whatever that key means
    # on its own, or a mistyped motion silently mutates the selection.
    pending = Fluxion::TUI::PendingSequence.new
    pending.feed(key('g'))

    pending.feed(key('z')).should eq(Fluxion::TUI::PendingSequence::Verdict::Pending)
    pending.active?.should be_false
    pending.action.should be_nil
  end

  it "abandons a half-typed sequence on escape, and passes escape on otherwise" do
    pending = Fluxion::TUI::PendingSequence.new
    escape = CryTUI::KeyEvent.new(CryTUI::KeyCode::Escape)

    pending.feed(escape).should eq(Fluxion::TUI::PendingSequence::Verdict::Passed)

    pending.feed(leader)
    pending.feed(escape).should eq(Fluxion::TUI::PendingSequence::Verdict::Pending)
    pending.active?.should be_false
  end
end
