require "../spec_helper"

# Characterization specs for the layout solver.
#
# `Layout#split` decides the size of every pane in the TUI: the selector's
# tree and its help line, the execution screen's split between the phase tree
# and the command output, every bordered box inside those. It is also the most
# intricate code in the project — a port of Ratatui's constraint layout, which
# hands the hard cases to a Cassowary solver and keeps fast paths for the easy
# ones — and it had no tests at all.
#
# These do not assert what the layout *should* do in the abstract. They record
# what it does today, so that anyone changing the solver finds out immediately
# which arrangements they moved. The expected values were produced by running
# the current implementation and checking each against Ratatui's documented
# behaviour, not by reasoning about the constraint strengths.
private AREA = CryTUI::Rect.new(0, 0, 100, 30)

private def widths(constraints, spacing = 0, area = AREA)
  CryTUI::Layout.new(CryTUI::Direction::Horizontal, constraints, spacing)
    .split(area).map(&.width)
end

private def starts(constraints, spacing = 0, area = AREA)
  CryTUI::Layout.new(CryTUI::Direction::Horizontal, constraints, spacing)
    .split(area).map(&.x)
end

describe CryTUI::Layout do
  describe "percentage constraints" do
    it "divides the area in the requested proportions" do
      widths([CryTUI::Constraint.percentage(50), CryTUI::Constraint.percentage(50)]).should eq([50, 50])
      widths([CryTUI::Constraint.percentage(30), CryTUI::Constraint.percentage(70)]).should eq([30, 70])
    end

    it "leaves the remainder unused rather than inflating a pane" do
      # Three 33% panes cover 99 of 100 columns. The layout defaults to
      # Ratatui's Flex::Start, which packs panes at the start and lets the
      # leftover trail — so the last pane stays 33 wide and column 99 is
      # simply not allocated. Growing one pane to absorb the remainder would
      # make identical constraints produce different sizes.
      widths([CryTUI::Constraint.percentage(33)] * 3).should eq([33, 33, 33])
      starts([CryTUI::Constraint.percentage(33)] * 3).should eq([0, 33, 66])
    end
  end

  describe "ratio constraints" do
    it "divides by the denominator and rounds the remainder into the last pane" do
      widths([CryTUI::Constraint.ratio(1, 3), CryTUI::Constraint.ratio(2, 3)]).should eq([33, 67])
    end
  end

  describe "fill constraints" do
    it "splits the area evenly between equal weights" do
      widths([CryTUI::Constraint.fill(1), CryTUI::Constraint.fill(1)]).should eq([50, 50])
    end

    it "gives a heavier weight proportionally more room" do
      widths([CryTUI::Constraint.fill(1), CryTUI::Constraint.fill(2)]).should eq([33, 67])
    end

    it "takes spacing out of the fillable room, not out of the panes' share" do
      # Two columns of spacing between the panes, so 98 columns are shared
      # evenly and the second pane starts two past the end of the first.
      widths([CryTUI::Constraint.fill(1), CryTUI::Constraint.fill(1)], spacing: 2).should eq([49, 49])
      starts([CryTUI::Constraint.fill(1), CryTUI::Constraint.fill(1)], spacing: 2).should eq([0, 51])
    end
  end

  describe "length, min and max constraints" do
    it "gives a length pane exactly its size and the rest to fill" do
      widths([CryTUI::Constraint.length(20), CryTUI::Constraint.fill(1)]).should eq([20, 80])
    end

    it "treats min as a floor a fill pane may exceed" do
      # Min asks for at least 30 but also, more weakly, for the whole area, so
      # against an equally greedy fill pane it settles at half rather than
      # stopping at its floor. This is the constraint that sizes the execution
      # screen's tree pane, so the even split is the behaviour being pinned.
      widths([CryTUI::Constraint.min(30), CryTUI::Constraint.fill(1)]).should eq([50, 50])
    end

    it "treats max as a ceiling the pane settles at" do
      widths([CryTUI::Constraint.max(20), CryTUI::Constraint.fill(1)]).should eq([20, 80])
    end

    it "shrinks lengths that cannot all fit rather than overflowing the area" do
      # Two 80-wide panes in 100 columns cannot both be satisfied. They give up
      # equally instead of the first winning and the second being pushed off
      # the edge of the screen.
      widths([CryTUI::Constraint.length(80), CryTUI::Constraint.length(80)]).should eq([50, 50])
    end

    it "places spacing between fixed lengths" do
      starts([CryTUI::Constraint.length(20), CryTUI::Constraint.length(30)], spacing: 5).should eq([0, 25])
    end
  end

  describe "direction and origin" do
    it "splits heights rather than widths when vertical" do
      parts = CryTUI::Layout.new(CryTUI::Direction::Vertical,
        [CryTUI::Constraint.length(3), CryTUI::Constraint.fill(1)]).split(AREA)
      parts.map(&.height).should eq([3, 27])
      parts.map(&.y).should eq([0, 3])
      # The cross axis is passed through untouched.
      parts.map(&.width).should eq([100, 100])
    end

    it "offsets panes by the origin of the area it was given" do
      area = CryTUI::Rect.new(5, 7, 100, 30)
      parts = CryTUI::Layout.new(CryTUI::Direction::Horizontal,
        [CryTUI::Constraint.percentage(50), CryTUI::Constraint.percentage(50)]).split(area)
      parts.map(&.x).should eq([5, 55])
      parts.map(&.y).should eq([7, 7])
    end
  end

  describe "degenerate input" do
    it "returns nothing when there are no constraints" do
      widths([] of CryTUI::Constraint).should eq([] of Int32)
    end

    it "returns empty panes for an empty area instead of negative sizes" do
      # A terminal can genuinely report a zero dimension mid-resize, and a
      # negative width would index outside the buffer when a widget drew into
      # it.
      parts = CryTUI::Layout.new(CryTUI::Direction::Horizontal,
        [CryTUI::Constraint.percentage(50), CryTUI::Constraint.percentage(50)]).split(CryTUI::Rect.new)
      parts.map(&.width).should eq([0, 0])
    end
  end
end

describe CryTUI::Rect do
  it "clamps negative dimensions to zero" do
    CryTUI::Rect.new(0, 0, -5, -5).width.should eq(0)
    CryTUI::Rect.new(0, 0, -5, -5).height.should eq(0)
  end

  it "reports the edges of the area" do
    rect = CryTUI::Rect.new(2, 3, 10, 5)
    {rect.left, rect.top, rect.right, rect.bottom}.should eq({2, 3, 12, 8})
  end

  it "is empty when either dimension is zero" do
    CryTUI::Rect.new(0, 0, 0, 5).empty?.should be_true
    CryTUI::Rect.new(0, 0, 5, 0).empty?.should be_true
    CryTUI::Rect.new(0, 0, 5, 5).empty?.should be_false
  end

  describe "#inner" do
    it "insets on every side" do
      CryTUI::Rect.new(0, 0, 10, 10).inner(2).should eq(CryTUI::Rect.new(2, 2, 6, 6))
    end

    it "never insets past the middle, so a thin area collapses instead of inverting" do
      CryTUI::Rect.new(0, 0, 4, 10).inner(5).should eq(CryTUI::Rect.new(2, 2, 0, 6))
    end
  end

  describe "#intersection" do
    it "returns the overlapping region" do
      left = CryTUI::Rect.new(0, 0, 10, 10)
      right = CryTUI::Rect.new(5, 5, 10, 10)
      left.intersection(right).should eq(CryTUI::Rect.new(5, 5, 5, 5))
    end

    it "returns an empty rect when the areas do not overlap" do
      left = CryTUI::Rect.new(0, 0, 5, 5)
      right = CryTUI::Rect.new(20, 20, 5, 5)
      left.intersection(right).empty?.should be_true
    end
  end
end
