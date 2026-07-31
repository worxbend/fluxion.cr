require "./spec_helper"

describe CryTUI::Buffer do
  it "writes styled text and measures wide graphemes" do
    buffer = CryTUI::Buffer.new(CryTUI::Rect.new(0, 0, 20, 1))
    buffer.set_string(0, 0, "fluxion ✔", CryTUI::Style.new(CryTUI::Color::GREEN))
    buffer.lines.first.should start_with("fluxion ✔")
    buffer[0, 0].style.foreground.should eq(CryTUI::Color::GREEN)
  end
end
