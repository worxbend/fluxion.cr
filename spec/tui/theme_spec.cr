require "../spec_helper"

# The palette is process-wide, so a spec that changes it puts it back.
private def with_palette(palette : Fluxion::TUI::Palette, &)
  previous = Fluxion::TUI::Theme.palette
  Fluxion::TUI::Theme.palette = palette
  begin
    yield
  ensure
    Fluxion::TUI::Theme.palette = previous
  end
end

describe Fluxion::TUI::Palette do
  it "resolves a palette by id and falls back rather than failing" do
    Fluxion::TUI::Palette.by_id("nord").id.should eq("nord")
    Fluxion::TUI::Palette.by_id("NORD").id.should eq("nord")
    # No run should ever stop over decoration.
    Fluxion::TUI::Palette.by_id("no-such-palette").should eq(Fluxion::TUI::Palette.default)
    Fluxion::TUI::Palette.by_id("").should eq(Fluxion::TUI::Palette.default)
  end

  it "cycles through the catalogue and wraps at the end" do
    first = Fluxion::TUI::Palette::ALL.first
    last = Fluxion::TUI::Palette::ALL.last

    Fluxion::TUI::Palette.after(first).should eq(Fluxion::TUI::Palette::ALL[1])
    Fluxion::TUI::Palette.after(last).should eq(first)
  end

  it "derives a selection bar that sits between the background and the accent" do
    # The bar is the accent composited onto the background, because a terminal
    # cell has no alpha channel to do it with.
    palette = Fluxion::TUI::Palette::EMBER
    bar = palette.highlight_background

    bar.kind.rgb?.should be_true
    bar.red.should be > palette.background.red
    bar.red.should be < palette.accent.red
  end

  it "keeps the text on a selection bar readable" do
    # 3:1 is the WCAG floor for large text and interface elements, which is the
    # right bar for a row of short labels.
    Fluxion::TUI::Palette::ALL.each do |palette|
      ratio = CryTUI::Color.contrast_ratio(palette.highlight_foreground, palette.highlight_background)
      next unless ratio # `mono` is indexed, so it has no measurable luminance.
      ratio.should be >= 3.0
    end
  end

  it "parses hex colours and rejects anything else" do
    Fluxion::TUI::Palette.parse_hex("#FF8800").should eq(CryTUI::Color.rgb(255, 136, 0))
    Fluxion::TUI::Palette.parse_hex("FF8800").should eq(CryTUI::Color.rgb(255, 136, 0))
    Fluxion::TUI::Palette.parse_hex("nope").should be_nil
    Fluxion::TUI::Palette.parse_hex("#FFF").should be_nil
  end
end

describe Fluxion::TUI::Theme do
  it "recolours every role when the palette changes" do
    with_palette(Fluxion::TUI::Palette::NORD) do
      Fluxion::TUI::Theme.title.foreground.should eq(Fluxion::TUI::Palette::NORD.accent)
      Fluxion::TUI::Theme.failure.foreground.should eq(Fluxion::TUI::Palette::NORD.danger)
    end
  end

  it "cycles to the next palette" do
    with_palette(Fluxion::TUI::Palette::ALL.first) do
      Fluxion::TUI::Theme.cycle_palette.should eq(Fluxion::TUI::Palette::ALL[1])
      Fluxion::TUI::Theme.palette.should eq(Fluxion::TUI::Palette::ALL[1])
    end
  end

  it "drops to plain characters on a terminal that cannot draw the rest" do
    # Mojibake is worse than ASCII, so the mono palette takes the plain glyphs.
    with_palette(Fluxion::TUI::Palette::MONO) do
      Fluxion::TUI::Theme.rich?.should be_false
      Fluxion::TUI::Theme.symbol("✔", "+").should eq("+")
      Fluxion::TUI::Theme.border_set.should eq(CryTUI::Widgets::BorderSet::ASCII)
    end

    with_palette(Fluxion::TUI::Palette::EMBER) do
      Fluxion::TUI::Theme.rich?.should be_true
      Fluxion::TUI::Theme.symbol("✔", "+").should eq("✔")
    end
  end
end

describe Fluxion::TUI::Anim do
  it "blends between two colours" do
    black = CryTUI::Color.rgb(0, 0, 0)
    white = CryTUI::Color.rgb(255, 255, 255)

    Fluxion::TUI::Anim.blend(black, white, 0.0).should eq(black)
    Fluxion::TUI::Anim.blend(black, white, 1.0).should eq(white)
    Fluxion::TUI::Anim.blend(black, white, 0.5).red.should be_close(128, 1)
    # Out-of-range amounts are clamped rather than wrapping to a colour from
    # the other end of the ramp.
    Fluxion::TUI::Anim.blend(black, white, 4.0).should eq(white)
  end

  it "leaves colours it cannot mix alone" do
    # An indexed colour is whatever the terminal's palette says it is, so there
    # are no channels to interpolate.
    Fluxion::TUI::Anim.blend(CryTUI::Color::RED, CryTUI::Color.rgb(0, 0, 0), 0.5)
      .should eq(CryTUI::Color::RED)
  end

  it "keeps a pulse inside its range and moving" do
    values = (0..40).map { |frame| Fluxion::TUI::Anim.pulse(frame, 20) }
    values.min.should be >= 0.0
    values.max.should be <= 1.0
    values.uniq.size.should be > 1
  end

  it "gives every character of a gradient its own colour" do
    line = Fluxion::TUI::Anim.gradient_line("fluxion", CryTUI::Color.rgb(0, 0, 0),
      CryTUI::Color.rgb(255, 255, 255), 0)

    line.spans.size.should eq(7)
    line.spans.map(&.style.foreground).uniq!.size.should be > 1
  end

  it "slides the gradient as the frame advances" do
    first = Fluxion::TUI::Anim.gradient_line("fluxion", CryTUI::Color.rgb(0, 0, 0),
      CryTUI::Color.rgb(255, 255, 255), 0)
    later = Fluxion::TUI::Anim.gradient_line("fluxion", CryTUI::Color.rgb(0, 0, 0),
      CryTUI::Color.rgb(255, 255, 255), 8)

    first.spans.map(&.style.foreground).should_not eq(later.spans.map(&.style.foreground))
  end
end

describe Fluxion::TUI::Chrome do
  it "fills the progress bar in proportion to the ratio" do
    buffer = CryTUI::Buffer.new(CryTUI::Rect.new(0, 0, 20, 1))
    Fluxion::TUI::Chrome.progress_bar(buffer, buffer.area, 0.5, 0)

    line = buffer.lines.first
    line.count('█').should eq(10)
    line.size.should eq(20)
  end

  it "draws an empty and a full bar without spilling over either end" do
    buffer = CryTUI::Buffer.new(CryTUI::Rect.new(0, 0, 10, 1))

    Fluxion::TUI::Chrome.progress_bar(buffer, buffer.area, 0.0, 0)
    buffer.lines.first.count('█').should eq(0)

    Fluxion::TUI::Chrome.progress_bar(buffer, buffer.area, 1.0, 0)
    buffer.lines.first.count('█').should eq(10)

    # A ratio outside 0..1 is clamped, not trusted.
    Fluxion::TUI::Chrome.progress_bar(buffer, buffer.area, 2.5, 0)
    buffer.lines.first.count('█').should eq(10)
  end

  it "formats a duration, and says so when there is none" do
    Fluxion::TUI::Chrome.duration(nil).should eq("--:--")
    Fluxion::TUI::Chrome.duration(90.seconds).should eq("01:30")
    Fluxion::TUI::Chrome.duration(3_723.seconds).should eq("01:02:03")
  end

  it "renders the which-key menu for a half-typed sequence" do
    buffer = CryTUI::Buffer.new(CryTUI::Rect.new(0, 0, 80, 20))
    Fluxion::TUI::Chrome::WhichKey.render(buffer, buffer.area, "<leader>", 0)

    rendered = buffer.lines.join('\n')
    rendered.should contain("fluxion")
    rendered.should contain("quit")
  end

  it "draws nothing when no sequence is pending" do
    buffer = CryTUI::Buffer.new(CryTUI::Rect.new(0, 0, 80, 20))
    Fluxion::TUI::Chrome::WhichKey.render(buffer, buffer.area, "", 0)

    buffer.lines.join.strip.should be_empty
  end
end
