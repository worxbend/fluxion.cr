module Fluxion
  # An environment variable handed to a script or command.
  #
  # `sensitive` drives redaction: the value is masked in previews, live output,
  # failure text, and state fingerprints. It is inferred from the name when the
  # profile does not say, so `GITHUB_TOKEN` is protected without being asked.
  struct ShellEnvironmentVariable
    PORTABLE_NAME = /\A[A-Za-z_][A-Za-z0-9_]*\z/

    getter name : String
    getter value : String
    getter? sensitive : Bool

    def initialize(@name : String, @value : String, @sensitive : Bool = false)
    end

    def self.portable_name?(name : String) : Bool
      name.matches?(PORTABLE_NAME)
    end
  end

  # Fields shared by the two structured item kinds. Both support the same
  # idempotency guards and execution controls; only the thing being run differs.
  module ShellItemFields
    DEFAULT_TIMEOUT = 30.minutes

    getter name : String
    getter working_dir : String?
    getter environment : Array(ShellEnvironmentVariable)
    getter? sudo : Bool

    # Exit codes treated as success. An empty list means `[0]` — a profile that
    # writes `allowedExitCodes: []` means "the default", not "nothing succeeds".
    getter allowed_exit_codes : Array(Int32)

    # Skip when this path already exists.
    getter creates : String?

    # Skip when this shell snippet exits 0.
    getter unless_command : String?

    # Requires `apply --yes`. Fluxion never prompts interactively for these,
    # in either plain or TUI mode.
    getter confirm : String?

    getter timeout : Time::Span
    getter condition : Condition?

    def allows_exit_code?(code : Int32) : Bool
      @allowed_exit_codes.includes?(code)
    end

    def confirmation_required? : Bool
      !@confirm.nil?
    end

    # An empty `allowedExitCodes` means "only zero", not "any code". Both
    # including structs normalise through this in their constructor rather than
    # repeating the conditional, which is what the previous private class-level
    # version was for — except nothing ever called it.
    protected def self.normalize_exit_codes(codes : Array(Int32)) : Array(Int32)
      codes.empty? ? [0] : codes
    end
  end

  # One script inside a `shell-script` step.
  #
  # Exactly one of three sources: `script`, an operator-controlled local file;
  # `url`, a remote artifact that must be pinned by `sha256`; or `content`, a
  # body written inline in the profile. The asymmetry is deliberate — a local
  # path and an inline body are already inside the trust boundary, a URL is
  # not, which is why only the URL carries a digest.
  struct ShellScriptItem
    include ShellItemFields

    getter script : String?
    getter url : String?

    # An inline script body, written into the run's private workspace and
    # executed from there. The third and last source: exactly one of `script`,
    # `url` or `content`.
    getter content : String?

    getter args : Array(String)
    getter sha256 : Checksum?

    # The interpreter this item asked for, if it did. Nil means fall back to
    # the step's, then to the file's shebang, then to bash.
    getter shell : ShellKind?

    def initialize(
      @name : String,
      @script : String? = nil,
      @url : String? = nil,
      @content : String? = nil,
      @shell : ShellKind? = nil,
      @args : Array(String) = [] of String,
      @working_dir : String? = nil,
      @environment : Array(ShellEnvironmentVariable) = [] of ShellEnvironmentVariable,
      @sudo : Bool = false,
      allowed_exit_codes : Array(Int32) = [] of Int32,
      @creates : String? = nil,
      @unless_command : String? = nil,
      @confirm : String? = nil,
      @timeout : Time::Span = ShellItemFields::DEFAULT_TIMEOUT,
      @sha256 : Checksum? = nil,
      @condition : Condition? = nil,
    )
      @allowed_exit_codes = ShellItemFields.normalize_exit_codes(allowed_exit_codes)
    end

    def remote? : Bool
      !@url.nil?
    end

    def inline? : Bool
      !@content.nil?
    end

    # Stable identity for plans and state. A remote script is keyed by its URL
    # with credentials and query parameters stripped.
    def key : String
      script = @script
      return script if script

      return @name if @content

      PublicUrl.from(@url || @name)
    end
  end

  # One command inside a `shell-command` step.
  #
  # A shell string and a direct argv vector stay distinct all the way through:
  # previews, redaction, and the execution boundary all need to know which one
  # they are looking at, because only one of them involves a shell parser.
  struct ShellCommandItem
    include ShellItemFields

    getter shell_command : String?
    getter argv : Array(String)?
    getter shell : String

    def initialize(
      @name : String,
      @shell_command : String? = nil,
      @argv : Array(String)? = nil,
      @shell : String = "/bin/bash",
      @working_dir : String? = nil,
      @environment : Array(ShellEnvironmentVariable) = [] of ShellEnvironmentVariable,
      @sudo : Bool = false,
      allowed_exit_codes : Array(Int32) = [] of Int32,
      @creates : String? = nil,
      @unless_command : String? = nil,
      @confirm : String? = nil,
      @timeout : Time::Span = ShellItemFields::DEFAULT_TIMEOUT,
      @condition : Condition? = nil,
    )
      @allowed_exit_codes = ShellItemFields.normalize_exit_codes(allowed_exit_codes)
    end

    # A convenience for the common case, where every command is a bare shell
    # string and the item name is the command itself.
    def self.shell(command : String, shell : String = "/bin/bash", working_dir : String? = nil) : self
      new(name: command, shell_command: command, shell: shell, working_dir: working_dir)
    end

    def direct? : Bool
      !@argv.nil?
    end

    def command : Array(String)
      argv = @argv
      base = argv ? argv.dup : [@shell, "-lc", @shell_command.not_nil!]
      @sudo ? ["sudo"] + base : base
    end
  end

  # `type: shell-script` — run local or HTTPS-fetched shell scripts.
  class ShellScriptStep < Step
    # Named for what it holds, matching `ShellCommandStep#commands`. It was
    # `@items` with a `getter items` that `Step`'s own `items` override silently
    # shadowed, so the class had two names for one collection and one of them
    # was unreachable.
    getter scripts : Array(ShellScriptItem)
    getter working_dir : String?

    # The interpreter every item in this step uses unless it names its own.
    getter shell : ShellKind?

    def initialize(
      name : String,
      @scripts : Array(ShellScriptItem),
      @working_dir : String? = nil,
      @shell : ShellKind? = nil,
      description : String? = nil,
      continue_on_error : Bool = false,
      probe_command : String? = nil,
      condition : Condition? = nil,
    )
      super(name, description, continue_on_error, probe_command, condition)
    end

    def kind : String
      "shell-script"
    end

    def item_type : ItemType
      ItemType::ShellScript
    end

    def items : Array(ItemRef)
      @scripts.map { |script| item(script.name, "script", script.key) }
    end

    def requires_approval?(item_key : String) : Bool
      @scripts.any? { |script| script.name == item_key && script.confirmation_required? }
    end

    # Which interpreter runs `item`, ignoring the shebang.
    #
    # Precedence is item, then step. The shebang is consulted only by the
    # executor and only for a local `script:` — the one source whose bytes
    # exist when the preview is built, so that `plan` and `apply` cannot name
    # different interpreters.
    def shell_for(item : ShellScriptItem) : ShellKind?
      item.shell || @shell
    end

    # Inline bodies live in the profile but in no item key, so editing one
    # would otherwise leave a completed phase looking unchanged and be skipped.
    def content_digest : String?
      # Inline bodies live in the profile but in no item key. A remote script's
      # `sha256` is the same shape of problem: the item key is the URL, so
      # re-pinning to a new release left the step looking unchanged.
      inputs = @scripts.compact_map do |script|
        digest = script.sha256
        script.content || digest.try(&.value)
      end
      return if inputs.empty?
      Digest::SHA256.hexdigest(inputs.join('\0'))
    end

    def summary : String
      "#{@scripts.size} script#{"s" if @scripts.size != 1}"
    end
  end

  # `type: shell-command` — run inline shell commands or direct argv vectors.
  class ShellCommandStep < Step
    DEFAULT_SHELL = "/bin/bash"

    getter commands : Array(ShellCommandItem)
    getter shell : String
    getter working_dir : String?

    def initialize(
      name : String,
      @commands : Array(ShellCommandItem),
      @shell : String = DEFAULT_SHELL,
      @working_dir : String? = nil,
      description : String? = nil,
      continue_on_error : Bool = false,
      probe_command : String? = nil,
      condition : Condition? = nil,
    )
      super(name, description, continue_on_error, probe_command, condition)
    end

    def kind : String
      "shell-command"
    end

    def item_type : ItemType
      ItemType::ShellCommand
    end

    def items : Array(ItemRef)
      @commands.map { |command| item(command.name, "command") }
    end

    def requires_approval?(item_key : String) : Bool
      @commands.any? { |command| command.name == item_key && command.confirmation_required? }
    end

    def summary : String
      "#{@commands.size} command#{"s" if @commands.size != 1}"
    end
  end

  # `type: shell-reload` — force later work through a fresh login shell.
  #
  # Needed when an earlier step wrote into shell startup files that later
  # commands have to observe; the already-running shell will never see them.
  class ShellReloadStep < Step
    getter shell : ShellKind

    def initialize(
      name : String,
      @shell : ShellKind = ShellKind::Zsh,
      description : String? = nil,
      condition : Condition? = nil,
    )
      super(name, description, false, nil, condition)
    end

    def kind : String
      "shell-reload"
    end

    def item_type : ItemType
      ItemType::ShellReload
    end

    def items : Array(ItemRef)
      [item(@shell.command, "shell-reload", @name)]
    end

    def summary : String
      "reload #{@shell}"
    end

    # The command actually run. It reports success explicitly rather than just
    # exiting, so a shell whose rc file swallows errors still fails the step
    # when it cannot start.
    def reload_argv : Array(String)
      [@shell.command, "--login", "-i", "-c", "echo 'Shell environment OK'; exit 0"]
    end
  end

  # `type: default-shell` — change the user's login shell.
  class DefaultShellStep < Step
    getter shell_path : String

    def initialize(
      name : String,
      @shell_path : String,
      description : String? = nil,
      probe_command : String? = nil,
      condition : Condition? = nil,
    )
      super(name, description, false, probe_command, condition)
    end

    def kind : String
      "default-shell"
    end

    def item_type : ItemType
      ItemType::DefaultShell
    end

    def items : Array(ItemRef)
      [item(@shell_path, "default-shell", @name)]
    end

    def summary : String
      "login shell #{@shell_path}"
    end
  end

  # `type: assert` — require a host condition before continuing.
  #
  # Distinct from a `shell-command` with `continueOnError: false` because the
  # failure message is written for a human who has to go fix something, not
  # for a debugging session.
  class AssertStep < Step
    DEFAULT_SHELL = "/bin/bash"

    getter command : String
    getter message : String
    getter shell : String
    getter working_dir : String?

    def initialize(
      name : String,
      @command : String,
      @message : String,
      @shell : String = DEFAULT_SHELL,
      @working_dir : String? = nil,
      description : String? = nil,
      condition : Condition? = nil,
    )
      super(name, description, false, nil, condition)
    end

    def kind : String
      "assert"
    end

    def item_type : ItemType
      ItemType::Assert
    end

    def items : Array(ItemRef)
      [item(@name, "assert")]
    end

    def summary : String
      "assert #{@name}"
    end

    def mutating? : Bool
      false
    end

    def argv : Array(String)
      [@shell, "-lc", @command]
    end
  end

  # `type: manual` — model a human checkpoint.
  #
  # The probe is what makes this more than a printed reminder: when it passes,
  # the checkpoint is recorded in state and never asked for again.
  class ManualStep < Step
    getter message : String

    def initialize(
      name : String,
      @message : String,
      description : String? = nil,
      probe_command : String? = nil,
      condition : Condition? = nil,
    )
      super(name, description, false, probe_command, condition)
    end

    def kind : String
      "manual"
    end

    def item_type : ItemType
      ItemType::Manual
    end

    def items : Array(ItemRef)
      [item(@name, "manual")]
    end

    def summary : String
      "manual: #{@message}"
    end

    def mutating? : Bool
      false
    end
  end

  # `kind: interrupt` — write a resumable checkpoint and stop cleanly.
  class InterruptStep < Step
    DEFAULT_EXIT_CODE = 75

    enum ResumeMode
      # Record this entry as complete and resume at the next one.
      Next
      # Resume at this entry, so it runs again.
      Current

      def self.from_config?(value : String?) : self?
        return unless value
        case value.strip.downcase
        when "next"    then Next
        when "current" then Current
        end
      end

      def config_name : String
        to_s.downcase
      end

      def to_s(io : IO) : Nil
        io << config_name
      end
    end

    getter message : String
    getter instructions : Array(String)
    getter resume_from : ResumeMode
    getter exit_code : Int32

    def initialize(
      name : String,
      @message : String,
      @instructions : Array(String) = [] of String,
      @resume_from : ResumeMode = ResumeMode::Next,
      @exit_code : Int32 = DEFAULT_EXIT_CODE,
      description : String? = nil,
      condition : Condition? = nil,
    )
      super(name, description, false, nil, condition)
    end

    def kind : String
      "interrupt"
    end

    def item_type : ItemType
      ItemType::Interrupt
    end

    def items : Array(ItemRef)
      [item(@name, "interrupt")]
    end

    def summary : String
      "interrupt: #{@message}"
    end

    def mutating? : Bool
      false
    end

    def halts? : Bool
      true
    end
  end
end
