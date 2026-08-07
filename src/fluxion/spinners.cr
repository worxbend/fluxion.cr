require "../crytui"

module Fluxion
  # Which spinner animation the CLI and the TUI draw with.
  #
  # Read from the environment rather than a flag: it is a taste setting that
  # belongs in a shell profile, not on every invocation, and it has to mean the
  # same thing to the plain reporter and the terminal UI. An unrecognised name
  # falls back to the default — no run should fail over decoration.
  module Spinners
    extend self

    VARIABLE = "FLUXION_SPINNER"
    DEFAULT  = "braille"

    def frames : Array(String)
      CryTUI::Widgets::FluxFrames.named?(ENV[VARIABLE]?) || CryTUI::Widgets::FluxFrames::BRAILLE
    end

    # The resolved preset name, which is the default whenever the requested one
    # does not exist.
    def name : String
      requested = ENV[VARIABLE]?
      return DEFAULT unless requested && CryTUI::Widgets::FluxFrames.named?(requested)
      requested.strip.downcase
    end

    def names : Array(String)
      CryTUI::Widgets::FluxFrames.names
    end

    # Whether the requested preset was understood, so a command can say so
    # rather than silently drawing something else.
    def configured? : Bool
      !ENV[VARIABLE]?.nil?
    end
  end
end
