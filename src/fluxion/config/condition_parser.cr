module Fluxion::Config
  # Parses a manifest `when:` block.
  module ConditionParser
    extend self

    # Reserved for future typed semantics. Accepting them now would mean
    # guessing what they mean, and a guard that silently evaluates to true is
    # worse than one that does not exist.
    RESERVED = %w[files vars expression]

    def parse(context : Context, node : Node) : Condition?
      return unless node.present?
      unless node.mapping?
        context.error(node.path, "when must be an object")
        return
      end

      unsupported = RESERVED.select { |field| node.has_key?(field) }
      unless unsupported.empty?
        context.error(node.path, "unsupported when conditions: #{unsupported.join(", ")}",
          "these are reserved until Fluxion has typed, fail-closed semantics for them")
        return
      end

      # Built into a pre-typed array rather than mapped: `parse` recurses here,
      # and Crystal cannot infer the element type mid-resolution.
      branches = [] of Condition
      node["oneOf"].items.each do |branch|
        parsed = parse(context, branch)
        branches << parsed if parsed
      end

      condition = Condition.new(
        os_family: matcher(node["os", "osFamily"], ->OsFamily.canonicalise(String)),
        # Deliberately not canonicalised: `Condition` compares a distribution
        # against the mapped name *and* falls back to the raw os-release ID, so
        # `ubuntu` matches a host reporting `pop` while an unmapped distribution
        # can still be matched by its literal ID.
        distribution: matcher(node["distribution", "distributions"]),
        # Free strings by design — a version or codename is whatever the host
        # reports, and there is no enum that owns their vocabulary.
        version: matcher(node["version"]),
        codename: matcher(node["codename"]),
        architecture: matcher(node["architecture", "architectures"], ->Architecture.canonicalise(String)),
        required_commands: node["commands"].string_list,
        any_commands: node["commandExists"].string_list,
        branches: branches,
      )

      # A `when` that declares only fields Fluxion does not recognise would
      # silently select everything, which is the opposite of a guard.
      if condition.empty? && !node.keys.empty?
        context.error(node.path, "has no supported matcher",
          "recognised: os, osFamily, distribution, version, codename, architecture, commands, commandExists, oneOf")
        return
      end

      condition
    end

    # Accepts the three shapes the schema allows for one matcher: a scalar, a
    # list, or an object with `oneOf` / `equals` / `value`.
    #
    # `canonicalise` maps each written value onto the spelling the host fact
    # will be compared against. Two fields need it because they name facts an
    # enum owns: `spec.target.os` runs the same words through
    # `Architecture.from_config?` and `OsFamily.from_config?`, which accept
    # x86_64 and rhel alongside amd64 and fedora, while a `when:` guard used to
    # compare the raw text — so `architecture: x86_64` never matched an amd64
    # host even though the identical spelling worked one field away.
    #
    # An unrecognised value is kept as written rather than rejected. Turning it
    # into a parse error would make a profile fail to load over a word that
    # merely matches no host, and would break the literal matching that
    # unmapped distributions rely on.
    private def matcher(node : Node, canonicalise : Proc(String, String)? = nil) : Matcher?
      return unless node.present?

      values = if node.mapping?
                 %w[oneOf equals value].each do |key|
                   child = node[key]
                   break child.string_list if child.present?
                 end || [] of String
               else
                 node.string_list
               end

      if canonicalise
        values = values.map { |value| canonicalise.call(value).as(String) }
      end

      matcher = Matcher.new(values)
      matcher.empty? ? nil : matcher
    end
  end
end
