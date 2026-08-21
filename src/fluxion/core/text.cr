module Fluxion
  # Small formatting helpers for the human-readable strings the domain, the
  # CLI, and the TUI all produce.
  #
  # Here rather than in one of them because all three build the same sentences:
  # `plan` prints "3 packages", a step's own `description` says "3 packages",
  # and the TUI's tree draws "3 packages" beside the step. Nothing in this
  # module knows about terminals, colour, or YAML, so `core` can use it without
  # gaining a dependency on the layers above it.
  module Text
    extend self

    # Counts a thing, adding an "s" unless there is exactly one of it.
    #
    #     Text.pluralize(0, "package")  # => "0 packages"
    #     Text.pluralize(1, "package")  # => "1 package"
    #     Text.pluralize(3, "package")  # => "3 packages"
    #
    # Only regular nouns are handled. An irregular plural ("entry"/"entries")
    # still needs writing out, because guessing at English spelling rules would
    # get it wrong more often than it got it right.
    def pluralize(count : Int, noun : String) : String
      "#{count} #{singular_or_plural(count, noun)}"
    end

    # The noun alone, for a sentence that has already stated the number or that
    # puts it somewhere other than immediately in front.
    def singular_or_plural(count : Int, noun : String) : String
      count == 1 ? noun : "#{noun}s"
    end
  end
end
