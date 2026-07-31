module Fluxion::Config
  # Substitutes `${...}` tokens across a WorkstationProfile document.
  #
  # Runs on the raw YAML tree before anything is mapped, so a variable can
  # appear in any string field. Only braced syntax is interpreted: `$(...)`,
  # backticks, globs, and bare `$VAR` stay literal, because those belong to
  # whatever shell eventually sees them.
  class Interpolator
    VARIABLE = /\$\{([^}]*)\}/

    # Fields whose contents are handed to a shell parser. Substituting into
    # them cannot be made safe without reimplementing every shell grammar, so a
    # token here is an error rather than a silent injection point. Pass data
    # through `env`, or use structured `command` plus `args`.
    private SHELL_EXPRESSION_SUFFIXES = %w[.unless .probeCommand]

    getter diagnostics : DiagnosticCollector

    def initialize(@host : HostFacts, @diagnostics : DiagnosticCollector = DiagnosticCollector.new)
      @variables = {} of String => String
    end

    def interpolate(root : Node) : YAML::Any
      @variables = build_variables(resolve_spec_vars(root))
      raw = root.raw
      return YAML::Any.new(nil) unless raw
      walk(raw, "", nil)
    end

    # Environment first, then `spec.vars`, then host facts. Later sources only
    # fill gaps, so a profile cannot shadow the real environment by accident.
    private def build_variables(spec_vars : Hash(String, String)) : Hash(String, String)
      variables = {} of String => String
      ENV.each { |key, value| variables[key] = value }
      variables["HOME"] ||= Path.home.to_s
      variables["USER"] ||= ENV["LOGNAME"]? || ""

      spec_vars.each { |key, value| variables[key] ||= value }

      host_variables.each { |key, value| variables[key] ||= value }
      variables
    end

    private def host_variables : Hash(String, String)
      {
        "host.os.name" => @host.distribution_id || @host.family.try(&.config_name) || "linux",
        "host.os.arch" => @host.architecture.try(&.config_name) || "",
        "host.user"    => ENV["USER"]? || ENV["LOGNAME"]? || "",
        "host.home"    => Path.home.to_s,
      }
    end

    # Resolves `spec.vars` against each other before the document is walked.
    # Only string values participate; anything else is not a variable.
    private def resolve_spec_vars(root : Node) : Hash(String, String)
      declared = root["spec"]["vars"]
      return {} of String => String unless declared.mapping?

      raw = {} of String => String
      declared.each_entry do |key, value|
        text = value.string?
        raw[key] = text if text
      end

      resolved = {} of String => String
      raw.each_key { |key| resolve_var(key, raw, resolved, [] of String, declared.path) }
      resolved
    end

    private def resolve_var(key : String, raw : Hash(String, String), resolved : Hash(String, String), stack : Array(String), base_path : String) : String
      return resolved[key] if resolved.has_key?(key)

      if stack.includes?(key)
        @diagnostics.error("#{base_path}.#{key}", "contains a cyclic variable reference '${#{key}}'")
        return raw[key]? || ""
      end

      value = raw[key]? || ""
      stack.push(key)
      substituted = replace(value) do |token, name|
        if raw.has_key?(name)
          resolve_var(name, raw, resolved, stack, base_path)
        else
          ENV[name]? || host_variables[name]? || token
        end
      end
      stack.pop

      resolved[key] = substituted
      substituted
    end

    private def walk(value : YAML::Any, path : String, plan : PlanContext?) : YAML::Any
      case raw = value.raw
      when Hash(YAML::Any, YAML::Any)
        # Keys are never interpolated: a variable naming a schema field would
        # make the document's shape depend on the environment.
        mapped = {} of YAML::Any => YAML::Any
        raw.each do |key, child|
          name = key.as_s? || key.to_s
          mapped[key] = walk(child, child_path(path, name), plan)
        end
        YAML::Any.new(mapped)
      when Array(YAML::Any)
        entries = raw.map_with_index do |child, index|
          child_plan = path == "spec.plan" ? plan_context(child) : plan
          walk(child, "#{path}[#{index}]", child_plan)
        end
        YAML::Any.new(entries)
      when String
        YAML::Any.new(substitute(raw, path, plan))
      else
        value
      end
    end

    private def substitute(text : String, path : String, plan : PlanContext?) : String
      return text unless text.includes?("${")

      if shell_expression?(path, plan)
        text.scan(VARIABLE) do |match|
          @diagnostics.error(
            describe(path, plan),
            "cannot interpolate #{match[0]} inside a shell expression",
            "pass data through env, or use structured command plus args",
          )
        end
        return text
      end

      replace(text) do |token, name|
        if name.empty?
          @diagnostics.error(describe(path, plan), "references unresolved variable #{token}")
          token
        elsif value = @variables[name]?
          value
        else
          @diagnostics.error(describe(path, plan), "references unresolved variable ${#{name}}")
          token
        end
      end
    end

    # Rewrites every `${name}` in `text`, yielding the whole token and the
    # trimmed name. Written against `MatchData` rather than `gsub` plus `$1`
    # because Crystal scopes `$~` to the enclosing method, so a block passed to
    # `gsub` never sees the match.
    private def replace(text : String, & : String, String -> String) : String
      String.build do |io|
        cursor = 0
        text.scan(VARIABLE) do |match|
          io << text[cursor...match.begin(0)]
          io << yield match[0], (match[1]? || "").strip
          cursor = match.end(0)
        end
        io << text[cursor..]
      end
    end

    private def shell_expression?(path : String, plan : PlanContext?) : Bool
      return false unless plan && path.starts_with?("spec.plan[")
      return true if SHELL_EXPRESSION_SUFFIXES.any? { |suffix| path.ends_with?(suffix) }

      case plan.kind
      when "assert"
        path.ends_with?(".spec.command")
      when "commands"
        path.matches?(/\.spec\.commands\[\d+\]\z/) || path.ends_with?(".run") || path.ends_with?(".shellCommand")
      else
        false
      end
    end

    private def describe(path : String, plan : PlanContext?) : String
      return path unless plan
      "#{path} in plan entry '#{plan.name}'"
    end

    private def plan_context(entry : YAML::Any) : PlanContext?
      mapping = entry.as_h?
      return unless mapping
      name = mapping[YAML::Any.new("name")]?.try(&.as_s?)
      return unless name
      kind = mapping[YAML::Any.new("kind")]?.try(&.as_s?).try(&.strip.downcase)
      PlanContext.new(name, kind || "")
    end

    private def child_path(parent : String, key : String) : String
      return key if parent.empty?
      key.matches?(/\A[A-Za-z_][A-Za-z0-9_]*\z/) ? "#{parent}.#{key}" : "#{parent}.['#{key}']"
    end

    # Which plan entry a node belongs to, so errors can name it and so the
    # shell-expression rules can depend on the entry's kind.
    private record PlanContext, name : String, kind : String
  end
end
