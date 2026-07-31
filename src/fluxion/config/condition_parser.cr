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
        os_family: matcher(node["os", "osFamily"]),
        distribution: matcher(node["distribution", "distributions"]),
        version: matcher(node["version"]),
        codename: matcher(node["codename"]),
        architecture: matcher(node["architecture", "architectures"]),
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
    private def matcher(node : Node) : Matcher?
      return unless node.present?

      values = if node.mapping?
                 %w[oneOf equals value].each do |key|
                   child = node[key]
                   break child.string_list if child.present?
                 end || [] of String
               else
                 node.string_list
               end

      matcher = Matcher.new(values)
      matcher.empty? ? nil : matcher
    end
  end
end
