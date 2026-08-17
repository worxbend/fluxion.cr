module Fluxion::TUI
  # A named set of colours the whole interface is drawn from.
  #
  # Every screen asks the palette for a role — `accent`, `danger`, `muted` —
  # rather than naming a colour, so switching palettes recolours the entire UI
  # and no screen can drift into a red that means something slightly different
  # from another screen's red.
  #
  # Chosen with `FLUXION_THEME`, or cycled at runtime with `<leader>ut`.
  record Palette,
    id : String,
    label : String,
    background : CryTUI::Color,
    accent : CryTUI::Color,
    accent_alt : CryTUI::Color,
    foreground : CryTUI::Color,
    muted : CryTUI::Color,
    border : CryTUI::Color,
    border_focus : CryTUI::Color,
    success : CryTUI::Color,
    warning : CryTUI::Color,
    danger : CryTUI::Color,
    info : CryTUI::Color,
    highlight_background : CryTUI::Color,
    highlight_foreground : CryTUI::Color do
    # The environment variable that picks the palette. Read from the
    # environment rather than a flag for the same reason the spinner is: it is
    # a taste setting that belongs in a shell profile, not on every invocation.
    VARIABLE = "FLUXION_THEME"

    # Colours for a count badge: the small inverse chip in a panel title, like
    # the " 03 " next to "phases".
    #
    # Deliberately not the highlight pair. The two look superficially alike —
    # both are "text on a coloured block" — but they want opposite things. A
    # selection bar is a dim wash that has to sit behind a whole row of text
    # without drowning it; a badge is a small bright chip that has to stand out
    # from the panel title beside it.
    def badge_background : CryTUI::Color
      accent
    end

    # :ditto:
    def badge_foreground : CryTUI::Color
      background
    end

    # How much of the accent survives in a selection bar, from 0 (invisible) to
    # 1 (a solid slab of accent). A terminal cell has no alpha channel — there
    # is no way to ask it for "30% opaque" — so the see-through look is baked
    # into the colour instead: the accent is mixed into the background at this
    # ratio and the result stored, which is exactly what the terminal would
    # have shown had it been able to composite the two itself. 0.28 is enough
    # for the selected row to read as selected at a glance, and little enough
    # that the row's own text stays legible on it.
    HIGHLIGHT_TINT = 0.28

    EMBER            = palette("ember", "Ember", %w[1B1916 D97757 E8C59E ECE8E1 8A867D 4A4640 D97757 87B37B E0B44C E06C5F 7BA9C7])
    TOKYO_NIGHT      = palette("tokyo-night", "Tokyo Night", %w[1A1B26 7AA2F7 BB9AF7 C0CAF5 565F89 24283B 7AA2F7 9ECE6A E0AF68 F7768E 7DCFFF])
    CATPPUCCIN_MOCHA = palette("catppuccin-mocha", "Catppuccin Mocha", %w[1E1E2E CBA6F7 89B4FA CDD6F4 A6ADC8 313244 CBA6F7 A6E3A1 F9E2AF F38BA8 89DCEB])
    GRUVBOX          = palette("gruvbox", "Gruvbox", %w[282828 FE8019 D3869B EBDBB2 928374 3C3836 FE8019 B8BB26 FABD2F FB4934 83A598])
    NORD             = palette("nord", "Nord", %w[2E3440 88C0D0 81A1C1 E5E9F0 616E88 3B4252 88C0D0 A3BE8C EBCB8B BF616A 81A1C1])
    DRACULA          = palette("dracula", "Dracula", %w[282A36 BD93F9 FF79C6 F8F8F2 6272A4 3A3D52 BD93F9 50FA7B F1FA8C FF5555 8BE9FD])
    ONE_DARK         = palette("one-dark", "One Dark", %w[282C34 61AFEF C678DD ABB2BF 5C6370 3E4451 61AFEF 98C379 E5C07B E06C75 56B6C2])
    ROSE_PINE        = palette("rose-pine", "Rose Pine", %w[191724 C4A7E7 EBBCBA E0DEF4 6E6A86 26233A C4A7E7 9CCFD8 F6C177 EB6F92 9CCFD8])
    KANAGAWA_WAVE    = palette("kanagawa-wave", "Kanagawa Wave", %w[1F1F28 7E9CD8 957FB8 DCD7BA 727169 2A2A37 7E9CD8 98BB6C E6C384 E82424 7FB4CA])
    EVERFOREST_DARK  = palette("everforest-dark", "Everforest Dark", %w[2D353B A7C080 D699B6 D3C6AA 859289 475258 A7C080 A7C080 DBBC7F E67E80 7FBBB3])
    GITHUB_DARK      = palette("github-dark", "GitHub Dark", %w[0D1117 58A6FF BC8CFF C9D1D9 8B949E 30363D 58A6FF 3FB950 D29922 F85149 58A6FF])
    SOLARIZED_LIGHT  = palette("solarized-light", "Solarized Light", %w[FDF6E3 268BD2 2AA198 657B83 93A1A1 EEE8D5 268BD2 859900 B58900 DC322F 2AA198])
    CATPPUCCIN_LATTE = palette("catppuccin-latte", "Catppuccin Latte", %w[EFF1F5 8839EF 1E66F5 4C4F69 9CA0B0 CCD0DA 8839EF 40A02B DF8E1D D20F39 04A5E5])

    # Near-black grounds under a vibrant two-colour gradient. The header title
    # and the panel headings blend `accent` into `accent_alt`, so in this group
    # those two are picked to travel across a hue rather than to shade one.
    TOXIC_VIOLET = palette("toxic-violet", "Toxic Violet", %w[0A0713 A855F7 7CFF3D EDE4FF 7A6B99 2B2046 A855F7 5CFF8F FFC53D FF3B6B 4DD8FF])
    ACID_RAIN    = palette("acid-rain", "Acid Rain", %w[040B08 A6FF00 00E5C0 E4FFF2 5F8A79 143028 A6FF00 66FF8F E8E24D FF4D5E 4DE8FF])
    HYPERDRIVE   = palette("hyperdrive", "Hyperdrive", %w[04080E 00F0FF FF5FD2 E0F7FF 5F8299 12303D 00F0FF 4DFFB0 FFD24D FF476F 00F0FF])
    MAGMA_CORE   = palette("magma-core", "Magma Core", %w[0D0503 FF6A00 FF1E56 FFE9DC 9E6E52 3D1C0D FF6A00 5FE08A FFB800 FF1E56 5FA8FF])

    # The one palette that keeps a solid selection bar. `mono` is the fallback
    # for terminals that may only have the 16 ANSI colours, where "dark grey"
    # is whatever the terminal decided it is — on the ones that render it as
    # plain black a tinted bar would vanish, taking the only sign of which row
    # is selected with it. Reversed white-on-black survives everywhere.
    MONO = new("mono", "Mono (TTY-safe)", CryTUI::Color::RESET, CryTUI::Color::WHITE, CryTUI::Color::GRAY,
      CryTUI::Color::WHITE, CryTUI::Color::DARK_GRAY, CryTUI::Color::DARK_GRAY, CryTUI::Color::WHITE,
      CryTUI::Color::GREEN, CryTUI::Color::YELLOW, CryTUI::Color::RED, CryTUI::Color::CYAN,
      CryTUI::Color::WHITE, CryTUI::Color::BLACK)

    # `mono` closes the catalogue rather than sitting in the middle of it: it
    # is what a terminal without colour falls back to, not a palette anyone
    # cycles looking for.
    ALL = [EMBER, TOKYO_NIGHT, CATPPUCCIN_MOCHA, GRUVBOX, NORD, DRACULA, ONE_DARK, ROSE_PINE,
           KANAGAWA_WAVE, EVERFOREST_DARK, GITHUB_DARK, SOLARIZED_LIGHT, CATPPUCCIN_LATTE,
           TOXIC_VIOLET, ACID_RAIN, HYPERDRIVE, MAGMA_CORE, MONO]

    def self.default : Palette
      EMBER
    end

    def self.by_id(id : String) : Palette
      wanted = id.strip.downcase
      return default if wanted.empty? || wanted == "default"
      ALL.find { |palette| palette.id == wanted } || default
    end

    # The palette the environment asks for, falling back to the default. An
    # unrecognised name never fails a run — no bootstrap should stop over
    # decoration.
    def self.from_environment : Palette
      by_id(ENV[VARIABLE]? || "")
    end

    def self.ids : Array(String)
      ALL.map(&.id)
    end

    # The palette after this one in the catalogue, wrapping at the end.
    def self.after(current : Palette) : Palette
      index = ALL.index { |palette| palette.id == current.id } || -1
      ALL[(index + 1) % ALL.size]
    end

    def self.parse_hex(value : String) : CryTUI::Color?
      hex = value.lstrip('#')
      return unless hex.matches?(/\A[0-9a-fA-F]{6}\z/)
      CryTUI::Color.rgb(hex[0, 2].to_i(16), hex[2, 2].to_i(16), hex[4, 2].to_i(16))
    end

    # The eleven colours a palette spells out, in order: background, accent,
    # accent_alt, foreground, muted, border, border_focus, success, warning,
    # danger, info.
    #
    # The highlight pair is not among them, because it is not an independent
    # choice: the selection bar is the accent tinted into the background, and
    # the text on it is the ordinary foreground. Deriving both means a palette
    # cannot end up with a selection bar that disagrees with the colours around
    # it, and it means the tint is defined once instead of eighteen times.
    #
    # The count is checked rather than assumed, so a palette left one colour
    # short fails loudly at startup instead of silently shifting every role
    # after the gap by one.
    PALETTE_COLOR_COUNT = 11

    private def self.palette(id : String, label : String, colors : Array(String)) : Palette
      unless colors.size == PALETTE_COLOR_COUNT
        raise "built-in palette #{id} needs #{PALETTE_COLOR_COUNT} colors, got #{colors.size}"
      end
      parsed = colors.map { |color| parse_hex(color) || raise "invalid built-in palette color: #{color}" }
      background, accent, foreground = parsed[0], parsed[1], parsed[3]
      new(
        id, label,
        background, accent, parsed[2], foreground, parsed[4], parsed[5], parsed[6],
        parsed[7], parsed[8], parsed[9], parsed[10],
        Anim.blend(background, accent, HIGHLIGHT_TINT), foreground
      )
    end
  end
end
