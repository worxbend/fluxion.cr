require "../spec_helper"

private alias RunTree = Fluxion::TUI::RunTree

describe RunTree do
  it "files a step under whichever phase is running" do
    tree = RunTree.new
    tree.phase_started("base")
    tree.step_started("tools")
    tree.item("tools", "git")

    tree.phases.map(&.name).should eq(["base"])
    tree.phases.first.steps.map(&.name).should eq(["tools"])
    tree.phases.first.steps.first.items.map(&.key).should eq(["git"])
  end

  it "has somewhere to put work that arrives before any phase starts" do
    tree = RunTree.new
    tree.item("tools", "git")

    tree.phases.map(&.name).should eq([RunTree::UNGROUPED])
  end

  it "returns the same row for a key it has already seen" do
    tree = RunTree.new
    tree.phase_started("base")
    first = tree.item("tools", "git")
    first.state = RunTree::ItemState::Running

    tree.item("tools", "git").should be(first)
    tree.phases.first.steps.first.items.size.should eq(1)
  end

  it "records a blocked phase without making it the current one" do
    tree = RunTree.new
    tree.phase_started("base")
    blocked = tree.phase("desktop")
    blocked.blocked = true

    tree.current_phase.should eq("base")
    tree.phases.map(&.name).should eq(["base", "desktop"])
  end

  describe "#rows" do
    it "flattens phases, steps, and items into one list" do
      tree = RunTree.new
      tree.phase_started("base")
      tree.step_started("tools")
      tree.item("tools", "git")
      tree.item("tools", "curl")

      tree.rows.size.should eq(4)
      tree.rows.first.step.should be_nil
      tree.rows[1].item.should be_nil
      tree.rows.last.item.try(&.key).should eq("curl")
    end

    it "stops at a collapsed group" do
      tree = RunTree.new
      tree.phase_started("base")
      tree.step_started("tools")
      tree.item("tools", "git")

      tree.phases.first.steps.first.collapsed = true
      tree.rows.size.should eq(2)

      tree.phases.first.collapsed = true
      tree.rows.size.should eq(1)
    end

    it "drops a phase whose every step passed, when only failures are wanted" do
      tree = RunTree.new
      tree.phase_started("base")
      tree.step_started("tools")
      tree.item("tools", "git").state = RunTree::ItemState::Succeeded
      tree.item("tools", "curl").state = RunTree::ItemState::Failed

      failing = tree.rows(failures_only: true)
      failing.compact_map(&.item).map(&.key).should eq(["curl"])

      tree.item("tools", "curl").state = RunTree::ItemState::Succeeded
      tree.rows(failures_only: true).should be_empty
    end
  end

  it "counts only the items that have finished" do
    tree = RunTree.new
    tree.phase_started("base")
    tree.item("tools", "git").state = RunTree::ItemState::Succeeded
    tree.item("tools", "curl").state = RunTree::ItemState::Running
    tree.item("tools", "jq").state = RunTree::ItemState::Skipped

    tree.completed_items.should eq(2)
  end

  it "finds a group's heading row by identity, not by name" do
    tree = RunTree.new
    tree.phase_started("base")
    tree.step_started("tools")
    tree.phase_started("desktop")
    tree.step_started("tools")

    first, second = tree.phases
    tree.index_of(first, first.steps.first).should eq(1)
    tree.index_of(second, second.steps.first).should eq(3)
    tree.index_of(second, nil).should eq(2)
  end
end
