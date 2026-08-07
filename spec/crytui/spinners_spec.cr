require "../spec_helper"

# The expected frames here were taken from the Rust original
# (sorinirimies/tui-spinner) rendering the same configuration at the same tick,
# so a change in behaviour shows up as a diff against the reference rather than
# against whatever this port happened to do last.
private def rows(lines : Array(CryTUI::Line)) : Array(String)
  lines.map(&.spans.map(&.content).join)
end

private def draw(spinner, width : Int32, height : Int32) : Array(String)
  buffer = CryTUI::Buffer.new(CryTUI::Rect.new(0, 0, width, height))
  spinner.render(buffer.area, buffer)
  buffer.lines
end

describe CryTUI::Widgets::FluxSpinner do
  it "cycles the frame sequence one step per tick" do
    frames = (0..8).map { |tick| CryTUI::Widgets::FluxSpinner.new(tick: tick).frame }
    frames.should eq(%w[⣾ ⣷ ⣯ ⣟ ⡿ ⢿ ⣽ ⣻ ⣾])
  end

  it "staggers each cell by phase_step to make a wave" do
    rows(CryTUI::Widgets::FluxSpinner.new(tick: 3, width: 8).lines).should eq(["⣟⡿⢿⣽⣻⣾⣷⣯"])
  end

  it "runs the sequence backwards when spinning anticlockwise" do
    spinner = CryTUI::Widgets::FluxSpinner.new(tick: 3, width: 8, spin: CryTUI::Widgets::Spin::CounterClockwise)
    rows(spinner.lines).should eq(["⢿⡿⣟⣯⣷⣾⣻⣽"])
  end

  it "holds each frame for ticks_per_step ticks" do
    held = (0..3).map { |tick| CryTUI::Widgets::FluxSpinner.new(tick: tick, ticks_per_step: 2).frame }
    held.should eq(%w[⣾ ⣾ ⣷ ⣷])
  end

  it "names every preset it ships" do
    CryTUI::Widgets::FluxFrames.names.size.should eq(21)
    CryTUI::Widgets::FluxFrames.named?("MOON").should eq(CryTUI::Widgets::FluxFrames::MOON)
    CryTUI::Widgets::FluxFrames.named?("nonsense").should be_nil
    CryTUI::Widgets::FluxFrames.named?(nil).should be_nil
  end
end

describe CryTUI::Widgets::LinearSpinner do
  it "scrolls a window of lit slots across a row" do
    frames = (0..3).map { |step| rows(CryTUI::Widgets::LinearSpinner.new(tick: step * 3).lines).first }
    frames.should eq(["●●·", "·●●", "●·●", "●●·"])
  end

  it "reverses the scroll when the flow is backwards" do
    spinner = CryTUI::Widgets::LinearSpinner.new(tick: 3, flow: CryTUI::Widgets::Flow::Backwards)
    rows(spinner.lines).first.should eq("·●●")
  end

  it "bounces a single slot down a column" do
    frames = (0..4).map do |step|
      rows(CryTUI::Widgets::LinearSpinner.new(tick: step * 3, direction: CryTUI::Direction::Vertical).lines).join
    end
    frames.should eq(["●··", "·●·", "··●", "·●·", "●··"])
  end

  it "pins the column to the bottom of a taller area" do
    spinner = CryTUI::Widgets::LinearSpinner.new(tick: 0, direction: CryTUI::Direction::Vertical)
    rows(spinner.lines(5)).should eq(["", "", "●", "·", "·"])
  end

  it "turns the arrow to face the axis it travels along" do
    CryTUI::Widgets::LinearStyle::Arrow.symbols(CryTUI::Direction::Horizontal).should eq({"▶", "▷"})
    CryTUI::Widgets::LinearStyle::Arrow.symbols(CryTUI::Direction::Vertical).should eq({"▼", "▽"})
  end
end

describe CryTUI::Widgets::BarSpinner do
  it "fades the arc edges through the braille density ramp" do
    rows(CryTUI::Widgets::BarSpinner.new(tick: 4).lines(24, 1))
      .should eq(["⣀⣀⣀⣀⠉⠛⠿⣿⣿⠿⠛⠉⣀⣀⣀⣀⣀⣀⣀⣀⣀⣀⣀⣀"])
  end

  it "swaps in a symbol pair for the non-braille styles" do
    spinner = CryTUI::Widgets::BarSpinner.new(tick: 4,
      motion: CryTUI::Widgets::BarMotion::Loop, bar_style: CryTUI::Widgets::BarStyle::Star)
    rows(spinner.lines(24, 1)).should eq(["☆☆☆☆★★★★★★★★☆☆☆☆☆☆☆☆☆☆☆☆"])
  end

  it "converges two arcs on the centre when squeezing" do
    spinner = CryTUI::Widgets::BarSpinner.new(tick: 3, motion: CryTUI::Widgets::BarMotion::Squeeze)
    rows(spinner.lines(20, 1)).should eq(["⣀⣀⣀⠉⠛⠿⣿⠿⠛⠉⠉⠛⠿⣿⠿⠛⠉⣀⣀⣀"])
  end

  it "radiates two arcs outward from the centre" do
    spinner = CryTUI::Widgets::BarSpinner.new(tick: 0, motion: CryTUI::Widgets::BarMotion::Radiate)
    rows(spinner.lines(20, 1)).should eq(["⣀⣀⣀⠉⠛⠿⣿⠿⠛⠉⠉⠛⠿⣿⠿⠛⠉⣀⣀⣀"])
  end

  it "drops the fade on multi-row bars, which would otherwise step diagonally" do
    lines = rows(CryTUI::Widgets::BarSpinner.new(tick: 4, height: 2).lines(16, 2))
    lines.size.should eq(2)
    lines.uniq.size.should eq(1)
    lines.first.should_not contain("⠛")
  end

  it "travels down the rows when oriented vertically" do
    spinner = CryTUI::Widgets::BarSpinner.new(tick: 2,
      orientation: CryTUI::Direction::Vertical, width: 2)
    rows(spinner.lines(2, 6)).should eq(["⣀⣀", "⣀⣀", "⣿⣿", "⣿⣿", "⣀⣀", "⣀⣀"])
  end

  it "fills the area it is given when the width is left on auto" do
    draw(CryTUI::Widgets::BarSpinner.new(tick: 0), 12, 1).first.size.should eq(12)
  end

  it "hides the track entirely for the minimal preset" do
    rows(CryTUI::Widgets::BarSpinner.minimal(0).lines(8, 1)).first.count('⠀').should be > 0
  end
end

describe CryTUI::Widgets::SquareSpinner do
  it "walks the arc around the ring" do
    frames = (0..3).map { |tick| rows(CryTUI::Widgets::SquareSpinner.new(tick: tick).lines).first }
    frames.should eq(["⣤⣤⡄⠀", "⣤⣤⣤⠀", "⣤⣤⣤⡄", "⣤⣤⣤⣤"])
  end

  it "mirrors the ring to spin anticlockwise" do
    spinner = CryTUI::Widgets::SquareSpinner.new(tick: 5, spin: CryTUI::Widgets::Spin::CounterClockwise)
    rows(spinner.lines).should eq(["⣤⣤⣤⠀", "⠛⠆⠰⠀", "⠀⠀⠀⠀"])
  end

  it "reports the size it renders at" do
    CryTUI::Widgets::SquareSpinner.new(size: 2).char_size.should eq({4, 3})
    CryTUI::Widgets::SquareSpinner.new(size: 8).char_size.should eq({19, 10})
  end

  it "clamps the size to the range the ring geometry supports" do
    CryTUI::Widgets::SquareSpinner.new(size: 99).size.should eq(8)
    CryTUI::Widgets::SquareSpinner.new(size: 0).size.should eq(2)
  end

  # An unbounded tick is folded onto the animation's own cycle, so a spinner
  # left running for hours costs the same as a fresh one. That shortcut is only
  # safe if it lands on exactly the frame the long walk would have.
  it "renders a far-future tick as the naive walk would" do
    lead, period = CryTUI::Widgets::Spinner::SquareEngine.cycle(3, CryTUI::Widgets::Centre::Filled)
    engine = CryTUI::Widgets::Spinner::SquareEngine.new(3, CryTUI::Widgets::Centre::Filled)
    (lead + period * 7 + 5).times { engine.walk }
    expected = engine.lines(CryTUI::Style.new, CryTUI::Style.new, CryTUI::Alignment::Left)

    folded = CryTUI::Widgets::RectSpinner.new(tick: lead + period * 7 + 5, size: 3,
      arc_style: CryTUI::Style.new, dim_style: CryTUI::Style.new)
    rows(folded.lines).should eq(rows(expected))
  end
end

describe CryTUI::Widgets::CircleSpinner do
  it "rotates the arc around the ring" do
    rows(CryTUI::Widgets::CircleSpinner.new(tick: 5, radius: 4).lines)
      .should eq(["⡰⠈⠉⠲⡀", "⢣⡀⠀⣠⠃", "⠀⠈⠉⠀⠀"])
  end

  it "rotates the other way when spinning anticlockwise" do
    spinner = CryTUI::Widgets::CircleSpinner.new(tick: 5, radius: 4,
      spin: CryTUI::Widgets::Spin::CounterClockwise)
    rows(spinner.lines).should eq(["⡰⠊⠈⠲⡀", "⢣⡀⠀⣠⠁", "⠀⠈⠉⠀⠀"])
  end

  it "reports the size it renders at" do
    CryTUI::Widgets::CircleSpinner.new(radius: 4).char_size.should eq({5, 3})
  end

  it "returns to the same frame after a full lap" do
    perimeter = CryTUI::Widgets::Spinner::CircleEngine.perimeter(4).size
    first = rows(CryTUI::Widgets::CircleSpinner.new(tick: 0, radius: 4).lines)
    rows(CryTUI::Widgets::CircleSpinner.new(tick: perimeter, radius: 4).lines).should eq(first)
  end
end

describe CryTUI::Widgets::Spinner do
  it "wraps a block around the spinner and draws inside it" do
    block = CryTUI::Widgets::Block.new(title: "run")
    lines = draw(CryTUI::Widgets::FluxSpinner.new(tick: 0, width: 3, block: block), 7, 3)
    lines[0].should start_with("┌")
    lines[1].should eq("│⣾⣷⣯  │")
  end

  it "clips a spinner larger than the area it is handed" do
    draw(CryTUI::Widgets::CircleSpinner.new(tick: 0, radius: 8), 3, 1).size.should eq(1)
  end
end
