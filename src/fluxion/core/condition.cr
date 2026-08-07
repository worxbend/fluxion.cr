module Fluxion
  # A single `when` field's expected value(s).
  #
  # The manifest schema lets a matcher be written three ways — `distribution:
  # fedora`, `distribution: [fedora, arch]`, and `distribution: {oneOf: [...]}`
  # — which all mean "any of these". They are normalized here so evaluation has
  # one shape to reason about.
  struct Matcher
    getter values : Array(String)

    def initialize(values : Enumerable(String))
      @values = values.map(&.strip.downcase).reject(&.empty?).to_a
    end

    def self.of(value : String) : self
      new([value])
    end

    def empty? : Bool
      @values.empty?
    end

    # An unknown host fact never matches. Fluxion cannot detect a codename on
    # every distribution, and guessing "probably fine" would run Debian-only
    # work on a host it failed to identify.
    def matches?(actual : String?) : Bool
      return false unless actual
      normalized = actual.strip.downcase
      @values.any? { |value| value == normalized }
    end

    def to_s(io : IO) : Nil
      if @values.size == 1
        io << @values.first
      else
        io << "one of [" << @values.join(", ") << ']'
      end
    end
  end

  # A `when` guard on a plan entry or on an item inside `commands`,
  # `shell-scripts`, or `file-writes`.
  #
  # Every declared field must match — fields are ANDed — while the values
  # inside one field are ORed. `oneOf` nests whole conditions and is ORed
  # against its siblings' AND.
  class Condition
    getter os_family : Matcher?
    getter distribution : Matcher?
    getter version : Matcher?
    getter codename : Matcher?
    getter architecture : Matcher?

    # `commands`: every one of these must be on PATH.
    getter required_commands : Array(String)

    # `commandExists`: at least one of these must be on PATH.
    getter any_commands : Array(String)

    # `oneOf`: at least one nested condition must match.
    getter branches : Array(Condition)

    def initialize(
      @os_family : Matcher? = nil,
      @distribution : Matcher? = nil,
      @version : Matcher? = nil,
      @codename : Matcher? = nil,
      @architecture : Matcher? = nil,
      @required_commands : Array(String) = [] of String,
      @any_commands : Array(String) = [] of String,
      @branches : Array(Condition) = [] of Condition,
    )
    end

    # A condition that declares nothing always selects its entry.
    def empty? : Bool
      fact_checks_empty? && @required_commands.empty? && @any_commands.empty? && @branches.empty?
    end

    # True when this condition restricts which distribution or family the entry
    # runs on, directly or inside a `oneOf` branch.
    #
    # Such an entry is the author saying "this one is for Arch" in a profile
    # that may target something else, so the declared target is the wrong thing
    # to validate its package manager against — see `Manifest`.
    def narrows_distribution? : Bool
      return true if @distribution || @os_family
      @branches.any?(&.narrows_distribution?)
    end

    # Evaluates against detected host facts. The PATH lookup is injected so
    # `plan` can evaluate conditions without an executor and so specs can drive
    # it deterministically.
    def matches?(facts : HostFacts, &command_exists : String -> Bool) : Bool
      matches?(facts, command_exists)
    end

    def matches?(facts : HostFacts, command_exists : Proc(String, Bool)) : Bool
      unmet_reason(facts, command_exists).nil?
    end

    # Explains the first unmet requirement, for the skip reason printed in
    # `plan`, `dry-run`, and the TUI. Nil when the condition matches.
    #
    # Evaluation and explanation share one implementation so a condition can
    # never report "matched" while also producing a reason, or vice versa.
    def unmet_reason(facts : HostFacts, &command_exists : String -> Bool) : String?
      unmet_reason(facts, command_exists)
    end

    # Takes a `Proc` rather than a block because `oneOf` recurses, and Crystal
    # always inlines yielding calls.
    def unmet_reason(facts : HostFacts, command_exists : Proc(String, Bool)) : String?
      fact_checks(facts).each do |label, matcher, actual|
        next unless matcher
        next if matcher.matches?(actual)
        return "#{label} is #{actual || "unknown"}, needs #{matcher}"
      end

      if missing = @required_commands.find { |command| !command_exists.call(command) }
        return "#{missing} is not on PATH"
      end

      unless @any_commands.empty? || @any_commands.any? { |command| command_exists.call(command) }
        return "none of [#{@any_commands.join(", ")}] is on PATH"
      end

      unless @branches.empty? || @branches.any?(&.matches?(facts, command_exists))
        return "no oneOf branch matched"
      end

      nil
    end

    # The declared fact matchers paired with the host values they check, in the
    # order the manifest schema documents them.
    private def fact_checks(facts : HostFacts) : Array({String, Matcher?, String?})
      [
        {"os family", @os_family, facts.family.try(&.config_name)},
        {"distribution", @distribution, distribution_value(facts)},
        {"version", @version, facts.version},
        {"codename", @codename, facts.codename},
        {"architecture", @architecture, facts.architecture.try(&.config_name)},
      ] of {String, Matcher?, String?}
    end

    private def fact_checks_empty? : Bool
      @os_family.nil? && @distribution.nil? && @version.nil? &&
        @codename.nil? && @architecture.nil?
    end

    # Prefer the mapped distribution so `ubuntu` matches a host whose ID is
    # `pop`, but fall back to the raw ID so an unmapped distro can still be
    # matched literally.
    private def distribution_value(facts : HostFacts) : String?
      facts.distribution.try(&.config_name) || facts.distribution_id
    end
  end
end
