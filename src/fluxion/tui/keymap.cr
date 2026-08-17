module Fluxion::TUI
  # Everything a key can ask for, on either screen.
  #
  # Named intentions rather than key names, so a binding can move without any
  # screen changing, and so the which-key menu can describe a key without
  # knowing what will happen when it is pressed.
  enum ActionKind
    # Motion, shared by both screens.
    NavigateUp
    NavigateDown
    NavigateTop
    NavigateBottom
    NavigateHalfPageDown
    NavigateHalfPageUp
    NavigateNextGroup
    NavigatePreviousGroup

    # Tree shape.
    Expand
    Collapse
    ToggleFold
    ExpandAll
    CollapseAll

    # Selection, on the selector.
    ToggleSelection
    SelectAll
    SelectNone
    InvertSelection
    SelectOnlyThis
    ResumeFromState
    ResetSelection

    # Panes and overlays, on both screens.
    FocusPaneLeft
    FocusPaneRight
    FocusNextPane
    ToggleOutput
    ToggleHelp
    CyclePalette
    ToggleFollow
    ToggleFilterFailures
    StartSearch

    # Leaving.
    Run
    Quit
  end

  # The multi-key half of the keymap, in the shape an AstroNvim user already
  # has in their fingers: a leader key that opens a which-key menu, `g` for
  # goto motions, `z` for folds, and `Ctrl-w` for pane moves.
  #
  # Single-key bindings stay in each screen's own resolver because they resolve
  # without any pending state. Everything here is a sequence, so it lives in
  # one table that both the resolver and the which-key panel read — a binding
  # cannot be dispatchable but missing from the menu, or listed but unbound.
  module Keymap
    # Space, the AstroNvim leader. Written as a token so sequences read the way
    # they do in a Neovim config rather than starting with a space.
    LEADER = "<leader>"

    record Binding, sequence : String, kind : ActionKind, description : String

    # A key that can be pressed next, given what has been pressed so far.
    record Entry, token : String, label : String, sequence : String, group : Bool

    BINDINGS = [
      # Space is the leader, so it cannot also be the checkbox key the rest of
      # the world uses. `<leader><leader>` is how AstroNvim resolves exactly
      # this kind of collision, and `x` toggles without any sequence at all for
      # anyone who never opens the menu.
      Binding.new("#{LEADER}#{LEADER}", ActionKind::ToggleSelection, "toggle this row"),
      Binding.new("gg", ActionKind::NavigateTop, "first row"),
      Binding.new("G", ActionKind::NavigateBottom, "last row"),
      Binding.new("gj", ActionKind::NavigateNextGroup, "next phase"),
      Binding.new("gk", ActionKind::NavigatePreviousGroup, "previous phase"),
      Binding.new("<C-d>", ActionKind::NavigateHalfPageDown, "half page down"),
      Binding.new("<C-u>", ActionKind::NavigateHalfPageUp, "half page up"),
      Binding.new("za", ActionKind::ToggleFold, "toggle fold"),
      Binding.new("zR", ActionKind::ExpandAll, "open all folds"),
      Binding.new("zM", ActionKind::CollapseAll, "close all folds"),
      Binding.new("<C-w>h", ActionKind::FocusPaneLeft, "pane left"),
      Binding.new("<C-w>l", ActionKind::FocusPaneRight, "pane right"),
      Binding.new("<C-w>w", ActionKind::FocusNextPane, "next pane"),
      Binding.new("#{LEADER}q", ActionKind::Quit, "quit"),
      Binding.new("#{LEADER}r", ActionKind::Run, "run selection"),
      Binding.new("#{LEADER}?", ActionKind::ToggleHelp, "keybindings"),
      Binding.new("#{LEADER}sa", ActionKind::SelectAll, "select all"),
      Binding.new("#{LEADER}sn", ActionKind::SelectNone, "select none"),
      Binding.new("#{LEADER}si", ActionKind::InvertSelection, "invert selection"),
      Binding.new("#{LEADER}so", ActionKind::SelectOnlyThis, "only this one"),
      Binding.new("#{LEADER}sr", ActionKind::ResumeFromState, "resume from saved state"),
      Binding.new("#{LEADER}sx", ActionKind::ResetSelection, "reset to profile"),
      Binding.new("#{LEADER}ff", ActionKind::StartSearch, "find"),
      Binding.new("#{LEADER}fe", ActionKind::ToggleFilterFailures, "failures only"),
      Binding.new("#{LEADER}uo", ActionKind::ToggleOutput, "output pane"),
      Binding.new("#{LEADER}ut", ActionKind::CyclePalette, "next theme"),
      Binding.new("#{LEADER}uf", ActionKind::ToggleFollow, "follow output"),
      Binding.new("#{LEADER}ze", ActionKind::ExpandAll, "expand every group"),
      Binding.new("#{LEADER}zc", ActionKind::CollapseAll, "collapse every group"),
    ]

    # Titles for the prefixes that are groups rather than commands.
    GROUPS = {
      LEADER       => "fluxion",
      "#{LEADER}s" => "selection",
      "#{LEADER}f" => "find",
      "#{LEADER}u" => "ui",
      "#{LEADER}z" => "folds",
      "g"          => "goto",
      "z"          => "fold",
      "<C-w>"      => "pane",
    }

    extend self

    # The action a completed sequence runs, or nil when it is not a binding.
    def [](sequence : String) : ActionKind?
      BINDINGS.find { |binding| binding.sequence == sequence }.try(&.kind)
    end

    # True when at least one binding continues past `sequence`, which is what
    # makes a key worth holding onto instead of discarding.
    def prefix?(sequence : String) : Bool
      BINDINGS.any? { |binding| binding.sequence.starts_with?(sequence) && binding.sequence != sequence }
    end

    # The key token for a press, or nil for keys that never start a sequence.
    def token(key : CryTUI::KeyEvent) : String?
      character = key.character
      return unless character && key.code.character?
      return "<C-#{character.downcase}>" if key.modifiers.control?
      return LEADER if character == ' '
      character.to_s
    end

    # Every key that can follow `pending`, for the which-key panel. Sorted so
    # the menu order is stable between frames.
    def continuations(pending : String) : Array(Entry)
      prefix = tokens(pending)
      depth = prefix.size
      seen = Set(String).new
      entries = [] of Entry
      BINDINGS.each do |binding|
        parts = tokens(binding.sequence)
        next unless parts.size > depth && parts.first(depth) == prefix
        token = parts[depth]
        next unless seen.add?(token)

        sequence = pending + token
        group = parts.size > depth + 1
        entries << Entry.new(token, group ? (GROUPS[sequence]? || "more") : binding.description, sequence, group)
      end
      entries.sort_by!(&.token.downcase)
    end

    # What the which-key panel calls the sequence being typed.
    def title(pending : String) : String
      group = GROUPS[pending]?
      group ? "#{pending}  #{group}" : pending
    end

    # Splits a sequence into keys, keeping `<...>` tokens whole.
    def tokens(sequence : String) : Array(String)
      result = [] of String
      index = 0
      while index < sequence.size
        if sequence[index] == '<' && (close = sequence.index('>', index))
          result << sequence[index..close]
          index = close + 1
        else
          result << sequence[index].to_s
          index += 1
        end
      end
      result
    end
  end

  # Holds the half-typed key sequence between presses.
  #
  # A sequence resolver is the one piece of a modal keymap that cannot live in
  # a screen: `g` on its own means nothing, so something has to remember it was
  # pressed, decide whether the next key completes a binding, and give up if it
  # does not. Both screens keep one of these and ask it first.
  class PendingSequence
    getter pending : String = ""

    # What feeding a key produced.
    enum Verdict
      # The key was swallowed; a sequence is now half typed.
      Pending
      # The key completed a binding, available from `#action`.
      Resolved
      # Nothing here wanted the key; the screen should handle it itself.
      Passed
    end

    getter action : ActionKind? = nil

    def active? : Bool
      !@pending.empty?
    end

    def clear : Nil
      @pending = ""
      @action = nil
    end

    # Escape always abandons a half-typed sequence, exactly as it does in Vim,
    # which is what makes an accidental leader press harmless.
    def feed(event : CryTUI::KeyEvent) : Verdict
      @action = nil

      if event.code.escape?
        return Verdict::Passed unless active?
        clear
        return Verdict::Pending
      end

      token = Keymap.token(event)
      return Verdict::Passed unless token

      candidate = @pending + token
      if kind = Keymap[candidate]
        clear
        @action = kind
        return Verdict::Resolved
      end

      if Keymap.prefix?(candidate)
        @pending = candidate
        return Verdict::Pending
      end

      # A dead end. The keys typed so far are dropped rather than replayed: a
      # `g` followed by an unrelated key should not also perform whatever that
      # key means on its own, or a mistyped motion silently mutates the
      # selection.
      was_active = active?
      clear
      was_active ? Verdict::Pending : Verdict::Passed
    end
  end
end
