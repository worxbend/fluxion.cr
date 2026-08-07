require "uri"

module Fluxion::Config
  # Shared state and field helpers for one parse.
  #
  # Parsing collects diagnostics instead of raising, so a profile with five
  # mistakes takes one run to fix rather than five. Helpers therefore return a
  # usable placeholder on failure and record the problem; the caller checks the
  # collector once at the end.
  class Context
    getter diagnostics : DiagnosticCollector

    # Directory containing the profile. Relative script, working-directory, and
    # `creates` paths resolve against this so a profile stays portable
    # regardless of where it is run from.
    getter base_dir : String

    getter host : HostFacts

    def initialize(@base_dir : String, @host : HostFacts = HostFacts.new, @diagnostics : DiagnosticCollector = DiagnosticCollector.new)
    end

    def error(path : String, message : String, hint : String? = nil) : Nil
      @diagnostics.error(path, message, hint)
    end

    def warning(path : String, message : String, hint : String? = nil) : Nil
      @diagnostics.warning(path, message, hint)
    end

    # A required string field. Records a diagnostic and returns "" when absent,
    # so the surrounding parse can keep going and report everything else too.
    def require_string(node : Node, subject : String? = nil) : String
      value = node.string?
      if value.nil? || value.strip.empty?
        error(node.path, "#{subject || "value"} is required")
        return ""
      end
      value
    end

    def optional_string(node : Node) : String?
      value = node.string?
      return if value.nil? || value.strip.empty?
      value
    end

    # Note the explicit nil check: `node.bool? || default` would quietly turn
    # an explicit `false` into the default, which is exactly backwards for
    # fields like `gpgCheck` where `false` is the dangerous value.
    def bool(node : Node, default : Bool) : Bool
      value = node.bool?
      value.nil? ? default : value
    end

    # Tri-state: nil when the key is absent, so "not stated" stays distinct
    # from "explicitly false".
    def bool?(node : Node) : Bool?
      node.missing? ? nil : node.bool?
    end

    def int(node : Node, default : Int32) : Int32
      node.int? || default
    end

    # Parses an enum-style field, reporting the accepted spellings when it does
    # not match. Returns nil after recording the error.
    def enum_value(node : Node, subject : String, accepted : Array(String), & : String -> T?) : T? forall T
      raw = node.string?
      return if raw.nil? || raw.strip.empty?
      value = yield raw
      return value if value
      error(node.path, "unsupported #{subject} '#{raw.strip}'", "expected one of #{accepted.join(", ")}")
      nil
    end

    # A `{algorithm, value}` checksum block.
    def checksum(node : Node) : Checksum?
      return unless node.present?

      algorithm_node = node["algorithm"]
      algorithm = ChecksumAlgorithm.from_config?(algorithm_node.string?)
      unless algorithm
        raw = algorithm_node.string?
        if raw.nil? || raw.strip.empty?
          error(algorithm_node.path, "checksum algorithm is required")
        else
          error(algorithm_node.path, "unsupported checksum algorithm '#{raw.strip}'", "only sha256 is supported")
        end
        return
      end

      value_node = node["value"]
      raw_value = value_node.string?
      if raw_value.nil? || raw_value.strip.empty?
        error(value_node.path, "checksum value is required")
        return
      end

      case parsed = Checksum.parse(algorithm, raw_value)
      in Checksum then parsed
      in String
        error(value_node.path, "checksum value #{parsed}")
        nil
      end
    end

    # A bare `sha256: <hex>` field.
    def sha256(node : Node) : Checksum?
      raw = node.string?
      return if raw.nil? || raw.strip.empty?
      case parsed = Checksum.parse(ChecksumAlgorithm::Sha256, raw)
      in Checksum then parsed
      in String
        error(node.path, "sha256 #{parsed}")
        nil
      end
    end

    def fingerprint(node : Node) : Fingerprint?
      raw = node.string?
      return if raw.nil? || raw.strip.empty?
      case parsed = Fingerprint.parse(raw)
      in Fingerprint then parsed
      in String
        error(node.path, "fingerprint #{parsed}")
        nil
      end
    end

    # Requires an absolute HTTPS URL with a host and no embedded credentials.
    #
    # All three are checked and reported together rather than one per run,
    # because a URL that is wrong in two ways should not take two attempts to
    # fix. Credentials in a URL are rejected outright: they end up in process
    # listings, and Fluxion would have to redact them everywhere afterwards.
    def https_url(node : Node, required : Bool = true) : String?
      raw = node.string?
      if raw.nil? || raw.strip.empty?
        error(node.path, "URL is required") if required
        return
      end

      value = raw.strip
      uri = begin
        URI.parse(value)
      rescue URI::Error
        error(node.path, "is not a valid URL", PublicUrl.from(value))
        return
      end

      ok = true
      unless uri.scheme.try(&.downcase) == "https"
        error(node.path, "must use https")
        ok = false
      end
      if uri.host.nil? || uri.host.try(&.empty?)
        error(node.path, "must include a host")
        ok = false
      end
      if uri.user || uri.password
        error(node.path, "must not include user-info")
        ok = false
      end

      ok ? value : nil
    end

    # An absolute, normalized filesystem path, after `~` expansion.
    def absolute_path(node : Node, required : Bool = true) : String?
      raw = node.string?
      if raw.nil? || raw.strip.empty?
        error(node.path, "path is required") if required
        return
      end

      expanded = expand_home(raw.strip)
      unless expanded.starts_with?('/')
        error(node.path, "must be absolute")
        return
      end

      normalized = Path.posix(expanded).normalize.to_s
      unless normalized == expanded.chomp('/').presence || normalized == expanded
        # A path that changes under normalization contains `.` or `..`
        # segments, which make the destination depend on resolution order.
        error(node.path, "must be normalized")
        return
      end
      normalized
    end

    # A path that may be relative, resolved against the profile directory.
    def local_path(node : Node, required : Bool = true) : String?
      raw = node.string?
      if raw.nil? || raw.strip.empty?
        error(node.path, "path is required") if required
        return
      end
      resolve_local(raw.strip)
    end

    def resolve_local(raw : String) : String
      expanded = expand_home(raw)
      return Path.posix(expanded).normalize.to_s if expanded.starts_with?('/')
      Path.posix(@base_dir, expanded).normalize.to_s
    end

    # Expands a leading `~` only. A `~` in the middle of a path is a literal
    # character, and replacing every occurrence would corrupt real filenames.
    def expand_home(raw : String) : String
      # `Host.home` rather than a bare `ENV["HOME"]?`: with the variable unset
      # this used to expand `~` to the empty string, turning `~/bin` into
      # `/bin`. Falling back to the passwd entry is both safer and what every
      # other home lookup in the codebase does.
      home = Host.home
      return home if raw == "~"
      return home + raw[1..] if raw.starts_with?("~/")
      raw
    end

    # A normalized relative POSIX path, used for archive member selection.
    def archive_path(node : Node) : String?
      raw = node.string?
      return if raw.nil? || raw.strip.empty?

      value = raw.strip
      invalid = value.starts_with?('/') || value.starts_with?("..") ||
                value.includes?('\\') || Path.posix(value).normalize.to_s != value
      if invalid
        error(node.path, "must be a normalized relative POSIX path")
        return
      end
      value
    end

    OCTAL_MODE = /\A[0-7]{3,4}\z/

    def file_mode(node : Node) : String?
      raw = node.string?
      return if raw.nil? || raw.strip.empty?
      value = raw.strip
      unless value.matches?(OCTAL_MODE)
        error(node.path, "must be a 3 or 4 digit octal mode")
        return
      end
      value
    end

    # Durations accept the ISO-8601 form as well as the compact ones
    # (`30m`, `90s`, `500ms`, `120`), because profiles use both.
    def duration(node : Node, default : Time::Span) : Time::Span
      raw = node.string?
      return default if raw.nil? || raw.strip.empty?

      value = raw.strip
      parsed = parse_duration(value)
      unless parsed
        error(node.path, "is not a supported duration", "use 30m, 90s, 500ms, or an ISO-8601 duration like PT2H")
        return default
      end
      unless parsed > Time::Span.zero
        error(node.path, "must be positive")
        return default
      end
      parsed
    end

    ISO_DURATION = /\AP(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+(?:\.\d+)?)S)?)?\z/i

    def parse_duration(value : String) : Time::Span?
      lowered = value.downcase
      return lowered.to_i64.seconds if lowered.matches?(/\A\d+\z/)
      if match = lowered.match(/\A(\d+)ms\z/)
        return match[1].to_i64.milliseconds
      end
      if match = lowered.match(/\A(\d+)([smhd])\z/)
        amount = match[1].to_i64
        return case match[2]
        when "s" then amount.seconds
        when "m" then amount.minutes
        when "h" then amount.hours
        else          amount.days
        end
      end
      iso_duration(value)
    end

    private def iso_duration(value : String) : Time::Span?
      match = value.match(ISO_DURATION)
      return unless match
      return if match[0].size <= 1

      span = Time::Span.zero
      span += match[1].to_i64.days if match[1]?
      span += match[2].to_i64.hours if match[2]?
      span += match[3].to_i64.minutes if match[3]?
      span += match[4].to_f64.seconds if match[4]?
      span
    end
  end
end
