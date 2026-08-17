require "../spec_helper"

private def empty_profile : Fluxion::Profile
  Fluxion::Profile.new("demo", Fluxion::TargetOs.new(Fluxion::Distribution::Fedora), [] of Fluxion::Phase)
end

private def screenshot(gallery : Fluxion::TUI::SpinnerGallery, width = 100, height = 30) : Array(String)
  buffer = CryTUI::Buffer.new(CryTUI::Rect.new(0, 0, width, height))
  gallery.render(CryTUI::Frame.new(buffer.area, buffer))
  buffer.lines
end

describe Fluxion::TUI::SpinnerGallery do
  it "names every page it can show" do
    Fluxion::TUI::SpinnerGallery::Page.names.size.should eq(4)
  end

  it "lists every frame preset on the frames page" do
    lines = screenshot(Fluxion::TUI::SpinnerGallery.new).join('\n')
    CryTUI::Widgets::FluxFrames.names.each { |preset| lines.should contain(preset) }
  end

  it "shows every bar glyph set and motion on the bars page" do
    lines = screenshot(Fluxion::TUI::SpinnerGallery.new(Fluxion::TUI::SpinnerGallery::Page::Bars)).join('\n')
    %w[braille block shade dot diamond square star heart arrow circle spark cross progress thick wave pip]
      .each { |style| lines.should contain(style) }
    %w[bounce loop squeeze radiate].each { |motion| lines.should contain(motion) }
  end

  it "draws the ring spinners at the size they report" do
    lines = screenshot(Fluxion::TUI::SpinnerGallery.new(Fluxion::TUI::SpinnerGallery::Page::Rings))
    lines.join('\n').should contain("circle 8")
    # The rings themselves should be on screen, not just their labels.
    lines.count(&.matches?(/[⠁-⣿]/)).should be > 1
  end

  it "wraps round the pages in both directions" do
    gallery = Fluxion::TUI::SpinnerGallery.new
    gallery.handle(CryTUI::KeyEvent.new(CryTUI::KeyCode::Left))
    gallery.page.should eq(Fluxion::TUI::SpinnerGallery::Page::Rings)
    gallery.handle(CryTUI::KeyEvent.new(CryTUI::KeyCode::Right))
    gallery.page.should eq(Fluxion::TUI::SpinnerGallery::Page::Frames)
    gallery.handle(CryTUI::KeyEvent.character(' '))
    gallery.page.should eq(Fluxion::TUI::SpinnerGallery::Page::Bars)
  end

  it "quits on q, escape and ctrl-c" do
    gallery = Fluxion::TUI::SpinnerGallery.new
    gallery.handle(CryTUI::KeyEvent.character('q')).quit?.should be_true
    gallery.handle(CryTUI::KeyEvent.new(CryTUI::KeyCode::Escape)).quit?.should be_true
    gallery.handle(CryTUI::KeyEvent.character('c', CryTUI::KeyModifiers::Control)).quit?.should be_true
    gallery.handle(CryTUI::KeyEvent.character('x')).continue?.should be_true
  end

  it "renders on a terminal too small to hold a page without raising" do
    Fluxion::TUI::SpinnerGallery::Page.each do |page|
      screenshot(Fluxion::TUI::SpinnerGallery.new(page), 20, 6)
      screenshot(Fluxion::TUI::SpinnerGallery.new(page), 4, 3)
    end
  end
end

describe Fluxion::TUI::ExecutionScreen do
  it "animates the marker beside a running item" do
    profile = empty_profile
    screen = Fluxion::TUI::ExecutionScreen.new(profile, "live")
    screen.on_event(Fluxion::ExecutionEvent.item_started("packages", "git"))

    markers = (0..3).map do
      buffer = CryTUI::Buffer.new(CryTUI::Rect.new(0, 0, 60, 16))
      screen.render(CryTUI::Frame.new(buffer.area, buffer))
      buffer.lines.compact_map(&.match(/(\S) git\b/)).first[1]
    end

    markers.uniq.size.should be > 1
    markers.each { |marker| CryTUI::Widgets::FluxFrames::BRAILLE.should contain(marker) }
  end

  it "stops animating once the run is finished" do
    # A finished run must not keep a spinner turning beside it: motion on a
    # screen nothing is happening on reads as a run that has hung.
    screen = Fluxion::TUI::ExecutionScreen.new(empty_profile, "live")
    screen.finish

    frames = (0..3).map do
      buffer = CryTUI::Buffer.new(CryTUI::Rect.new(0, 0, 60, 16))
      screen.render(CryTUI::Frame.new(buffer.area, buffer))
      buffer.lines.join("\n")
    end

    frames.uniq.size.should eq(1)
    frames.first.should contain("done")
  end
end
