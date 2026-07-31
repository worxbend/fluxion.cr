module Fluxion::CLI
  # Terminal styling.
  #
  # Colour is decided once, here, from whether stdout is a terminal and whether
  # the user asked for it to be off. Every renderer then styles unconditionally
  # and gets plain text automatically when it is piped into a file, a pager, or
  # CI — which is what makes the output safe to parse without a `--no-color`
  # flag on every command.
  module Style
    extend self

    # https://no-color.org — set to anything, colour goes away.
    NO_COLOR = "NO_COLOR"

    # The conventional override for the opposite case: colour in a pipe.
    FORCE_COLOR = "FORCE_COLOR"

    @@enabled : Bool? = nil

    def enabled? : Bool
      enabled = @@enabled
      return enabled unless enabled.nil?
      @@enabled = detect
    end

    def enabled=(value : Bool?) : Nil
      @@enabled = value
    end

    # Runs a block with colour forced on or off, restoring it afterwards.
    def with_color(value : Bool, &)
      previous = @@enabled
      @@enabled = value
      begin
        yield
      ensure
        @@enabled = previous
      end
    end

    private def detect : Bool
      return false if ENV[NO_COLOR]?
      return true if ENV[FORCE_COLOR]?
      return false if ENV["TERM"]? == "dumb"
      STDOUT.tty?
    end

    RESET = "\e[0m"

    # A named palette rather than raw codes at the call sites, so the meaning
    # of a colour is stated once and stays consistent across commands.
    COLORS = {
      black:   30,
      red:     31,
      green:   32,
      yellow:  33,
      blue:    34,
      magenta: 35,
      cyan:    36,
      white:   37,
      gray:    90,
    }

    {% for name, code in COLORS %}
      def {{ name.id }}(text) : String
        paint(text, {{ code }})
      end
    {% end %}

    def bold(text) : String
      wrap(text, "1")
    end

    def dim(text) : String
      wrap(text, "2")
    end

    def italic(text) : String
      wrap(text, "3")
    end

    def underline(text) : String
      wrap(text, "4")
    end

    def bold_red(text) : String
      wrap(text, "1;31")
    end

    def bold_green(text) : String
      wrap(text, "1;32")
    end

    def bold_yellow(text) : String
      wrap(text, "1;33")
    end

    def bold_blue(text) : String
      wrap(text, "1;34")
    end

    def bold_cyan(text) : String
      wrap(text, "1;36")
    end

    private def paint(text, code : Int32) : String
      wrap(text, code.to_s)
    end

    private def wrap(text, code : String) : String
      return text.to_s unless enabled?
      "\e[#{code}m#{text}#{RESET}"
    end

    # Display width, ignoring the escape sequences styling added.
    #
    # Column alignment has to measure what the user sees, not what is in the
    # string, or every styled table drifts.
    def width(text : String) : Int32
      CryTUI::TextWidth.width(strip(text))
    end

    def strip(text : String) : String
      text.gsub(/\e\[[0-9;]*m/, "")
    end

    # Pads to `size` columns using the visible width.
    def pad(text : String, size : Int32) : String
      padding = size - width(text)
      padding > 0 ? text + (" " * padding) : text
    end

    # Truncates to `size` columns, marking that something was cut.
    def truncate(text : String, size : Int32) : String
      return text if width(text) <= size
      return text[0, size] if size <= 1

      plain = strip(text)
      plain[0, size - 1] + "…"
    end
  end

  # The symbols Fluxion uses to mark status.
  #
  # Kept beside the colours because they carry the same meaning and have to
  # agree: a green check and a red cross should never disagree about whether
  # something worked. ASCII fallbacks are used when the terminal cannot be
  # trusted with UTF-8, so the output stays readable over a bare serial console.
  module Symbols
    extend self

    def unicode? : Bool
      encoding = ENV["LC_ALL"]? || ENV["LC_CTYPE"]? || ENV["LANG"]? || ""
      encoding.downcase.includes?("utf")
    end

    def success : String
      unicode? ? "✔" : "+"
    end

    def failure : String
      unicode? ? "✘" : "x"
    end

    def skipped : String
      unicode? ? "○" : "-"
    end

    def pending : String
      unicode? ? "·" : "."
    end

    def running : String
      unicode? ? "▸" : ">"
    end

    def warning : String
      unicode? ? "⚠" : "!"
    end

    def paused : String
      unicode? ? "⏸" : "="
    end

    def bullet : String
      unicode? ? "•" : "*"
    end

    def arrow : String
      unicode? ? "→" : "->"
    end

    def branch : String
      unicode? ? "└─" : "\\-"
    end
  end
end
