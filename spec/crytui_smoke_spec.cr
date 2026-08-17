require "./spec_helper"

describe CryTUI::Buffer do
  it "writes styled text and measures wide graphemes" do
    buffer = CryTUI::Buffer.new(CryTUI::Rect.new(0, 0, 20, 1))
    buffer.set_string(0, 0, "fluxion ✔", CryTUI::Style.new(CryTUI::Color::GREEN))
    buffer.lines.first.should start_with("fluxion ✔")
    buffer[0, 0].style.foreground.should eq(CryTUI::Color::GREEN)
  end
end

describe CryTUI::Color do
  it "measures contrast between two colours" do
    black = CryTUI::Color.rgb(0, 0, 0)
    white = CryTUI::Color.rgb(255, 255, 255)

    CryTUI::Color.contrast_ratio(black, white).not_nil!.should be_close(21.0, 0.01)
    CryTUI::Color.contrast_ratio(black, black).not_nil!.should be_close(1.0, 0.01)
    # An indexed colour is whatever the terminal's palette says it is, so there
    # is nothing to measure.
    CryTUI::Color.contrast_ratio(CryTUI::Color::RED, white).should be_nil
  end
end

describe CryTUI::ForegroundGuard do
  it "rescues only the spans that would be unreadable" do
    background = CryTUI::Color.rgb(40, 40, 40)
    guard = CryTUI::ForegroundGuard.new(CryTUI::Color.rgb(255, 255, 255), background, 3.0)

    guard.insufficient?(CryTUI::Color.rgb(50, 50, 50)).should be_true
    guard.insufficient?(CryTUI::Color.rgb(255, 255, 255)).should be_false
    # A nil foreground already inherits the row's colour, and an indexed one
    # has no measurable luminance; neither is second-guessed.
    guard.insufficient?(nil).should be_false
    guard.insufficient?(CryTUI::Color::RED).should be_false
  end
end

describe CryTUI::Widgets::List do
  it "still draws an item taller than the pane it has to fit in" do
    # Scrolling to fit an over-tall item used to run the offset past it, and
    # the renderer then started after the only row it was asked to show.
    items = (1..3).map do |index|
      CryTUI::Widgets::ListItem.new([
        CryTUI::Line.from("row #{index}"),
        CryTUI::Line.from("detail #{index}"),
      ])
    end

    buffer = CryTUI::Buffer.new(CryTUI::Rect.new(0, 0, 20, 1))
    CryTUI::Widgets::List.new(items).render(buffer.area, buffer,
      CryTUI::Widgets::ListState.new(selected: 2))

    buffer.lines.first.should start_with("row 3")
  end
end
