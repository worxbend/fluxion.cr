module Fluxion::Executor
  # Removes secrets and terminal control sequences from anything Fluxion is
  # about to show, log, or persist.
  #
  # Two independent responsibilities, both mandatory:
  #
  # * Secrets must not reach the terminal, the state file, or a plan. A profile
  #   legitimately carries tokens in `env`, and package managers echo URLs, so
  #   the leak paths are ordinary rather than exotic.
  # * Untrusted text must not be able to drive the terminal. Package names,
  #   command output, and remote error messages all end up on screen; without
  #   stripping, any of them could move the cursor, clear the display, or forge
  #   a line of Fluxion's own output.
  module Redaction
    extend self

    MASK = "<redacted>"

    # Names that almost always hold a secret. Written once and reused for
    # environment variables, `--flag value` pairs, and `name=value` text.
    SENSITIVE_NAME = "(?:api[._-]?key|access[._-]?key|private[._-]?key|" \
                     "key[._-]?passphrase|passphrase|authorization|token|" \
                     "secret|password|passwd|credentials?)"

    # A quoted string or a bare token. Used as the value half of every
    # assignment pattern so `--token "a b"` masks the whole quoted value.
    QUOTED_OR_TOKEN = "(?:\"[^\"]*\"?|'[^']*'?|[^\\s,;\\]}]+)"

    # Applied in order. Sequence matters: URL credentials are removed before
    # anything else so a token inside a URL is not partially matched by a later
    # rule, and the PEM sweep runs last so it cannot be broken up by them.
    private PATTERNS = [
      # scheme://user:password@host
      {/(?<![a-zA-Z0-9+.-])([a-zA-Z][a-zA-Z0-9+.-]*:\/\/)[^\s\/@:]+(?::[^\s\/@]*)?@/, "\\1#{MASK}@"},
      # Authorization: Basic <base64> / Bearer <token>
      {/(?i)((?:["']?authorization["']?)\s*[=:]\s*["']?basic\s+)[a-z0-9+\/]+={0,2}/, "\\1#{MASK}"},
      {/(?i)((?:["']?authorization["']?)\s*[=:]\s*["']?bearer\s+)[a-z0-9._~+\/=-]+/, "\\1#{MASK}"},
      # A bare `Basic <base64>` long enough to be a real credential.
      {/(?i)(\bbasic\s+)[a-z0-9+\/]{8,}={0,2}/, "\\1#{MASK}"},
      # curl --user / -u
      {/(?i)(?<!\S)(--user(?:=|\s+)|-u\s+)#{QUOTED_OR_TOKEN}/, "\\1#{MASK}"},
      # token=..., "secret": ..., PASSWORD = ...
      {/(?i)(?<![a-z0-9])(["']?#{SENSITIVE_NAME}["']?)(\s*[=:]\s*)(?!["']?(?:basic|bearer)\b)#{QUOTED_OR_TOKEN}/, "\\1\\2#{MASK}"},
      # --token <value> / --token=<value>
      {/(?i)(?<![a-z0-9])(-{1,2}#{SENSITIVE_NAME})(\s+|=)#{QUOTED_OR_TOKEN}/, "\\1\\2#{MASK}"},
      # A bare bearer token anywhere.
      {/(?i)bearer\s+[a-z0-9._~+\/=-]+/, "Bearer #{MASK}"},
      # A whole PEM private key block, however long.
      {/-----BEGIN ([A-Z0-9 ]*PRIVATE KEY)-----.*?(?:-----END \1-----|\z)/im, MASK},
    ]

    # Masks anything that looks like a credential.
    def redact(text : String) : String
      PATTERNS.reduce(text) { |result, (pattern, replacement)| result.gsub(pattern, replacement) }
    end

    # Hoisted out of `sensitive_name?` because a regex literal with
    # interpolation is rebuilt — and so recompiled by PCRE2 — on every
    # evaluation, which measured 28x the cost of matching against a constant.
    # `sensitive_name?` runs once per argv element, so that recompilation was
    # dominating the check it exists to perform.
    private CAMEL_BOUNDARY         = /([a-z0-9])([A-Z])/
    private SENSITIVE_NAME_PATTERN = /(^|[^a-z0-9])#{SENSITIVE_NAME}($|[^a-z0-9])/

    # True when a name suggests its value is a secret. Splits camelCase first
    # so `githubToken` is caught as well as `GITHUB_TOKEN`.
    def sensitive_name?(name : String) : Bool
      normalized = name.gsub(CAMEL_BOUNDARY, "\\1_\\2").downcase
      normalized.matches?(SENSITIVE_NAME_PATTERN)
    end

    # Strips everything that could steer the terminal.
    #
    # Escape sequences are removed in order — OSC, then CSI, then anything else
    # introduced by ESC — because an OSC payload can legitimately contain bytes
    # that look like the start of a CSI sequence.
    def strip_controls(text : String, preserve_newlines : Bool = false) : String
      # Command output is overwhelmingly plain printable ASCII, and for such a
      # string every branch below is the identity: ESC, newline, backspace and
      # every control byte are all under 0x20, and the format characters and
      # line separators are all multi-byte. Checking that up front skips three
      # regex scans plus a per-character rebuild, which measured 64x faster on
      # a typical line and, more importantly, allocates nothing at all.
      return text if plain_ascii?(text)

      stripped = text
        .gsub(/\e\][^\a\e]*(?:\a|\e\\)/, "") # OSC (window title, hyperlinks)
        .gsub(/\e\[[0-?]*[ -\/]*[@-~]/, "")  # CSI (colour, cursor movement)
        .gsub(/\e(?:[@-_]|.)/, "")           # anything else after ESC

      # Collected into an array rather than an IO because backspace has to be
      # able to remove a character that was already accepted.
      output = [] of Char
      stripped.each_char do |char|
        case
        when char == '\n'
          output << char if preserve_newlines
        when char == '\u2028' || char == '\u2029'
          # Unicode line separators move the cursor in some terminals.
          output << ' '
        when char == '\b'
          # Backspace can overprint earlier text to forge a line of output, so
          # it is applied here and never reaches the terminal.
          output.pop?
        when format_character?(char)
          # Bidirectional overrides can visually reorder a command so that what
          # is shown is not what would run. Dropped outright.
        when char.control?
          output << ' '
        else
          output << char
        end
      end
      output.join
    end

    # Every byte printable ASCII, so nothing `strip_controls` removes can be
    # present. Deliberately byte-wise rather than character-wise: a multi-byte
    # codepoint has every byte >= 0x80 and so fails the test, which sends the
    # string down the full path where the format characters are handled.
    private def plain_ascii?(text : String) : Bool
      text.to_slice.all? { |byte| byte >= 0x20 && byte < 0x7F }
    end

    # Unicode format characters, notably the bidi overrides.
    private def format_character?(char : Char) : Bool
      ordinal = char.ord
      (0x200B..0x200F).includes?(ordinal) ||
        (0x202A..0x202E).includes?(ordinal) ||
        (0x2060..0x2064).includes?(ordinal) ||
        (0x2066..0x2069).includes?(ordinal) ||
        ordinal == 0xFEFF
    end

    # A single line safe to print: no control sequences, no secrets, no
    # embedded newlines that could forge a second line of output.
    def sanitize_line(text : String) : String
      redact(strip_controls(text, preserve_newlines: false))
    end

    # Multi-line text safe to print, keeping the line structure.
    def sanitize(text : String) : String
      redact(strip_controls(text, preserve_newlines: true))
    end

    # Sanitizes an argv vector for display.
    #
    # Handled per argument rather than on the joined string so an argument
    # following a sensitive flag is masked whole — `--password hunter2` hides
    # the value even though `hunter2` looks like nothing in particular.
    def sanitize_command(command : Array(String)) : Array(String)
      curl = command.first?.try { |argv0| File.basename(argv0.gsub('\\', '/')).downcase == "curl" }
      mask_next = false

      command.map do |argument|
        normalized = strip_controls(argument, preserve_newlines: false)

        if mask_next
          mask_next = false
          next MASK
        end

        mask_next = sensitive_option?(normalized)

        # curl accepts `-uuser:pass` with the value attached.
        if curl && normalized.starts_with?("-u") && !normalized.starts_with?("--") && normalized.size > 2
          next "-u#{MASK}"
        end

        redact(normalized)
      end
    end

    private def sensitive_option?(argument : String) : Bool
      return true if argument == "-u"
      return false unless argument.starts_with?('-')

      name = argument.lstrip('-')
      # A `--flag=value` form carries its value inline, so the *next* argument
      # is unrelated and must not be masked.
      return false if name.includes?('=')
      name.compare("user", case_insensitive: true) == 0 || sensitive_name?(name)
    end

    # Masks the literal values of sensitive environment variables.
    #
    # Pattern matching cannot catch a token that looks like an ordinary word,
    # so when Fluxion knows the actual secret it replaces it directly.
    def mask_values(text : String, environment : Enumerable(ShellEnvironmentVariable)) : String
      result = text
      environment.each do |variable|
        next unless variable.sensitive?
        value = variable.value
        next if value.empty? || !result.includes?(value)

        # A secret this short would match everywhere and produce a redaction
        # that reveals its length. Masking the whole line is the safe answer.
        return MASK if value.size < MIN_MASKABLE_SECRET

        result = result.gsub(value, MASK)
      end
      result
    end

    MIN_MASKABLE_SECRET = 4

    # Full treatment for a line of command output.
    #
    # `redact` rather than `sanitize_line` on the way out: the text has already
    # been stripped, and `mask_values` only ever substitutes MASK, which
    # contains no control characters. Stripping a second time was provably a
    # no-op that cost three regex scans and a rebuild on every line of output.
    def redact_output(text : String, environment : Enumerable(ShellEnvironmentVariable)) : String
      redact(mask_values(strip_controls(text, preserve_newlines: false), environment))
    end

    def redact_command(command : Array(String), environment : Enumerable(ShellEnvironmentVariable)) : Array(String)
      sanitize_command(command.map { |argument| mask_values(argument, environment) })
    end

    # Keeps a multi-line private key masked across separate output lines.
    #
    # Process output arrives a line at a time, so a PEM block spans many calls
    # and the single-line patterns would only ever see base64 that looks like
    # noise. This tracks whether it is inside a key block, and carries a
    # partial marker across the boundary.
    class StreamingSanitizer
      BEGIN_MARKER = /-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----/i
      END_MARKER   = /-----END [A-Z0-9 ]*PRIVATE KEY-----/i

      # A marker split across a read must still be recognised, but an unbounded
      # carry would let a stream with no newline consume memory forever.
      MAX_CARRY = 128

      def initialize(@environment : Array(ShellEnvironmentVariable) = [] of ShellEnvironmentVariable)
        @in_key = false
        @pending = ""
      end

      def line(text : String) : String
        combined = @pending + text
        @pending = ""

        if @in_key
          @in_key = false if combined.matches?(END_MARKER)
          return MASK
        end

        if match = combined.match(BEGIN_MARKER)
          @in_key = !combined.matches?(END_MARKER)
          prefix = combined[0...match.begin(0)]
          return Redaction.redact_output(prefix, @environment) + MASK
        end

        if carry = partial_marker(combined)
          @pending = carry
          combined = combined[0...(combined.size - carry.size)]
        end

        Redaction.redact_output(combined, @environment)
      end

      # Anything left over when the stream ends.
      def finish : String
        return "" if @in_key
        pending = @pending
        @pending = ""
        pending.empty? ? "" : Redaction.redact_output(pending, @environment)
      end

      # The longest suffix that could still turn into a BEGIN marker.
      #
      # Every proper prefix of the marker ends in one of these, so a line
      # ending in anything else cannot be a split marker. Checking that first
      # costs one character comparison and spares the common line the handful
      # of substring allocations the search below would otherwise make.
      MARKER_TAILS = {'-', 'B', 'E', 'G', 'I'}

      private def partial_marker(text : String) : String?
        return if text.empty? || !MARKER_TAILS.includes?(text[-1])

        marker = "-----BEGIN"
        (1...Math.min(marker.size, Math.min(text.size, MAX_CARRY))).reverse_each do |length|
          suffix = text[(text.size - length)..]
          return suffix if marker.starts_with?(suffix)
        end
        nil
      end
    end
  end
end
