require "../spec_helper"

# Display width decides where every glyph after it lands. Getting one
# character wrong does not mis-draw that character — it shifts the whole rest
# of the line, including the panel border, one cell sideways. These pin the
# classification so a change to the ranges or the emoji rules cannot quietly
# move it.
#
# The sequences below are written as `\u{...}` escapes rather than pasted in
# literally. Several of them differ only by an invisible character — a
# variation selector, a zero-width joiner — and a spec whose meaning depends on
# bytes nobody can see in a diff is a spec that gets "tidied" into a different
# test.
describe CryTUI::TextWidth do
  describe "#width" do
    it "counts ASCII as one cell each" do
      CryTUI::TextWidth.width("fluxion").should eq(7)
      CryTUI::TextWidth.width("").should eq(0)
    end

    it "counts CJK as two cells each" do
      CryTUI::TextWidth.width("日本語").should eq(6)
    end

    it "sums a mixed string" do
      CryTUI::TextWidth.width("ok 日本").should eq(7)
    end

    it "counts a combining mark as part of the character it modifies" do
      # "e" followed by a combining acute: one grapheme, one cell, not two.
      CryTUI::TextWidth.width("e\u{0301}").should eq(1)
    end
  end

  describe "#grapheme_width" do
    it "gives control characters no width" do
      CryTUI::TextWidth.grapheme_width("\u{0001}").should eq(0)
      CryTUI::TextWidth.grapheme_width("\n").should eq(0)
      CryTUI::TextWidth.grapheme_width("\r").should eq(0)
    end

    it "gives an empty grapheme no width" do
      CryTUI::TextWidth.grapheme_width("").should eq(0)
    end

    it "keeps ambiguous-width symbols narrow" do
      # Deliberate: these default to one cell, matching Ratatui and most
      # terminal configurations. The TUI uses ▶ and ⚠ in its own chrome, so
      # widening them would shift every label that follows.
      CryTUI::TextWidth.grapheme_width("\u{25B6}").should eq(1) # ▶
      CryTUI::TextWidth.grapheme_width("\u{26A0}").should eq(1) # ⚠
      CryTUI::TextWidth.grapheme_width("\u{2588}").should eq(1) # █
      CryTUI::TextWidth.grapheme_width("\u{2591}").should eq(1) # ░
    end

    it "counts emoji with default emoji presentation as two cells" do
      CryTUI::TextWidth.grapheme_width("\u{1F680}").should eq(2) # 🚀
      CryTUI::TextWidth.grapheme_width("\u{2705}").should eq(2)  # ✅
    end

    it "counts a supplementary-plane pictograph as two cells" do
      # Emoji_Presentation=No, so a width table would call these one cell, but
      # the astral plane has no narrow text glyph and terminals draw them as
      # emoji anyway. One cell would let the glyph overrun its column.
      CryTUI::TextWidth.grapheme_width("\u{1F39A}").should eq(2) # 🎚
      CryTUI::TextWidth.grapheme_width("\u{1F5C2}").should eq(2) # 🗂
    end

    it "honours an explicit presentation selector in both directions" do
      # The same heart, twice, differing only in the selector that follows it.
      CryTUI::TextWidth.grapheme_width("\u{2764}\u{FE0E}").should eq(1) # text
      CryTUI::TextWidth.grapheme_width("\u{2764}\u{FE0F}").should eq(2) # emoji
    end

    it "counts a keycap sequence as two cells" do
      # "1" + emoji selector + combining keycap.
      CryTUI::TextWidth.grapheme_width("1\u{FE0F}\u{20E3}").should eq(2)
    end

    it "counts a regional-indicator flag as two cells" do
      # Two regional indicators combine into one flag glyph.
      CryTUI::TextWidth.grapheme_width("\u{1F1F5}\u{1F1F1}").should eq(2)
    end

    it "counts a ZWJ sequence as a single two-cell grapheme" do
      # A family emoji is several pictographs joined by zero-width joiners. The
      # joiners and the joined parts contribute nothing of their own; the whole
      # sequence occupies the two cells the terminal draws it in.
      family = "\u{1F469}\u{200D}\u{1F469}\u{200D}\u{1F467}"
      CryTUI::TextWidth.width(family).should eq(2)
    end
  end

  describe "the ASCII fast path" do
    it "agrees with the general path for every ASCII character" do
      # `width` counts bytes when a string is ASCII-only, skipping grapheme
      # segmentation entirely. That shortcut is only safe while it returns
      # exactly what the general path would, so this checks all 128 of them
      # against `grapheme_width` rather than trusting the reasoning.
      (0..127).each do |codepoint|
        text = codepoint.unsafe_chr.to_s
        CryTUI::TextWidth.width(text).should eq(CryTUI::TextWidth.grapheme_width(text))
      end
    end

    it "agrees with the general path for a realistic line" do
      line = "Installing glibc-2.39-1.fc40.x86_64 [==>  ] 42% (done)"
      expected = line.each_grapheme.sum { |grapheme| CryTUI::TextWidth.grapheme_width(grapheme.to_s) }
      CryTUI::TextWidth.width(line).should eq(expected)
      CryTUI::TextWidth.width(line).should eq(line.size)
    end

    it "still measures a string that is only partly ASCII the general way" do
      CryTUI::TextWidth.width("cd /srv/日本").should eq(12)
    end
  end

  describe "WIDE_RANGES" do
    it "is sorted and disjoint" do
      # Not cosmetic: `wide_codepoint?` binary-searches this table, which is
      # only correct while the ranges are in ascending order and do not
      # overlap. A range added in the wrong place would make the lookup miss.
      CryTUI::TextWidth::WIDE_RANGES.each_cons(2).all? { |(a, b)| a.end < b.begin }.should be_true
    end

    it "agrees with a direct scan across the whole table" do
      # Guards the binary search against the linear scan it replaced, and does
      # it where an off-by-one would hide: both ends of every range, and the
      # codepoint immediately either side of each.
      CryTUI::TextWidth::WIDE_RANGES.each do |range|
        [range.begin - 1, range.begin, range.end, range.end + 1].each do |codepoint|
          next if codepoint < 0
          expected = CryTUI::TextWidth::WIDE_RANGES.any?(&.includes?(codepoint))
          CryTUI::TextWidth.wide_codepoint?(codepoint).should eq(expected)
        end
      end
    end
  end
end
