module Fluxion
  # `type: user-groups` — add a user to supplementary groups.
  #
  # `usermod -aG` exits 0 while the running session still lacks the group, so
  # this step compares the process's own credentials against the group database
  # and raises a logout checkpoint when they disagree. Without that, `docker ps`
  # keeps saying permission denied and nothing explains why.
  class UserGroupsStep < Step
    getter groups : Array(String)

    # Defaults to the invoking user; under sudo that means `SUDO_USER`, not root.
    getter user : String?

    getter? create_missing : Bool
    getter? logout_checkpoint : Bool
    getter checkpoint_message : String?

    def initialize(
      name : String,
      @groups : Array(String),
      @user : String? = nil,
      @create_missing : Bool = false,
      @logout_checkpoint : Bool = true,
      @checkpoint_message : String? = nil,
      description : String? = nil,
      continue_on_error : Bool = false,
      probe_command : String? = nil,
      condition : Condition? = nil,
    )
      super(name, description, continue_on_error, probe_command, condition)
    end

    def kind : String
      "user-groups"
    end

    def item_type : ItemType
      ItemType::UserGroup
    end

    def items : Array(ItemRef)
      @groups.map { |group| item(item_key(group), "user-group", group) }
    end

    def item_key(group : String) : String
      user = @user
      user ? "#{user}:#{group}" : group
    end

    def default_checkpoint_message : String
      "Log out and back in so the new group membership (#{@groups.join(", ")}) takes effect."
    end

    def summary : String
      "groups #{@groups.join(", ")}"
    end
  end

  # Where a git setting is written.
  enum GitConfigScope
    Global
    System
    Local

    def self.from_config?(value : String?) : self?
      return unless value
      case value.strip.downcase
      when "global" then Global
      when "system" then System
      when "local"  then Local
      end
    end

    def flag : String
      "--#{config_name}"
    end

    # `system` writes /etc/gitconfig.
    def privileged? : Bool
      system?
    end

    def config_name : String
      to_s.downcase
    end

    def to_s(io : IO) : Nil
      io << config_name
    end
  end

  # `type: git-config` — set git configuration.
  #
  # Each key is set and probed individually so a key that already holds the
  # desired value is left alone and `diff` can report drift per key.
  class GitConfigStep < Step
    getter scope : GitConfigScope
    getter entries : Hash(String, String)

    def initialize(
      name : String,
      @entries : Hash(String, String),
      @scope : GitConfigScope = GitConfigScope::Global,
      description : String? = nil,
      continue_on_error : Bool = false,
      probe_command : String? = nil,
      condition : Condition? = nil,
    )
      super(name, description, continue_on_error, probe_command, condition)
    end

    def kind : String
      "git-config"
    end

    def item_type : ItemType
      ItemType::GitConfig
    end

    def required_commands : Array(String)
      ["git"]
    end

    # Sorted so plans, state, and fingerprints do not depend on YAML ordering.
    def sorted_keys : Array(String)
      @entries.keys.sort!
    end

    def items : Array(ItemRef)
      sorted_keys.map { |key| item(item_key(key), "git-config", key) }
    end

    def item_key(key : String) : String
      "#{@scope}:#{key}"
    end

    def summary : String
      "#{@entries.size} git config entr#{@entries.size == 1 ? "y" : "ies"}"
    end
  end

  # One repository inside a `git-repo` step.
  #
  # `ref` is a full commit rather than a branch or tag on purpose: a bootstrap
  # profile that installs different code on different days is not reproducible,
  # and a moving tag is indistinguishable from a compromised one.
  struct GitRepo
    COMMIT_PATTERN = /\A[0-9a-fA-F]{40}\z/

    getter url : String

    # Supports shell-style `${VAR:-default}` and `~` so paths can be copied
    # straight out of an existing shell script.
    getter destination : String

    getter ref : String
    getter depth : Int32?
    getter? submodules : Bool

    def initialize(@url : String, @destination : String, ref : String, @depth : Int32? = nil, @submodules : Bool = false)
      @ref = ref.downcase
    end

    def self.commit?(ref : String) : Bool
      ref.matches?(COMMIT_PATTERN)
    end
  end

  # `type: git-repo` — clone repositories that are not packaged.
  class GitRepoStep < Step
    getter repos : Array(GitRepo)

    def initialize(
      name : String,
      @repos : Array(GitRepo),
      description : String? = nil,
      continue_on_error : Bool = false,
      probe_command : String? = nil,
      condition : Condition? = nil,
    )
      super(name, description, continue_on_error, probe_command, condition)
    end

    def kind : String
      "git-repo"
    end

    def item_type : ItemType
      ItemType::GitRepo
    end

    def required_commands : Array(String)
      ["git"]
    end

    def items : Array(ItemRef)
      @repos.map { |repo| item(repo.destination, "git-repo") }
    end

    def summary : String
      "#{@repos.size} repositor#{@repos.size == 1 ? "y" : "ies"}"
    end
  end

  # Which systemd manager a unit belongs to.
  enum SystemdScope
    System
    User

    def self.from_config?(value : String?) : self?
      return unless value
      case value.strip.downcase
      when "system" then System
      when "user"   then User
      end
    end

    def flag : String
      "--#{config_name}"
    end

    def privileged? : Bool
      system?
    end

    def config_name : String
      to_s.downcase
    end

    def to_s(io : IO) : Nil
      io << config_name
    end
  end

  # Desired runtime state for a unit.
  enum SystemdState
    Started
    Stopped
    Unchanged

    def self.from_config?(value : String?) : self?
      return unless value
      case value.strip.downcase
      when "started"   then Started
      when "stopped"   then Stopped
      when "unchanged" then Unchanged
      end
    end

    def config_name : String
      to_s.downcase
    end

    def to_s(io : IO) : Nil
      io << config_name
    end
  end

  # One unit inside a `systemd-unit` step.
  struct SystemdUnit
    # Unit states that have no `[Install]` section and are therefore reachable
    # only as a dependency. Passing one to `enable` is an error, so Fluxion
    # treats an already-correct unit as satisfied instead.
    NOT_ENABLEABLE = %w[static indirect generated transient alias]

    ALREADY_ENABLED = %w[enabled enabled-runtime]

    getter unit : String
    getter? enabled : Bool
    getter state : SystemdState

    # Masking is a refusal to start, so it cannot coexist with enabling.
    getter? masked : Bool

    def initialize(@unit : String, @enabled : Bool = true, @state : SystemdState = SystemdState::Unchanged, @masked : Bool = false)
    end

    # A bare name is a `.service`.
    def qualified_name : String
      @unit.includes?('.') ? @unit : "#{@unit}.service"
    end
  end

  # `type: systemd-unit` — enable, start, stop, or mask units.
  class SystemdUnitStep < Step
    getter scope : SystemdScope
    getter units : Array(SystemdUnit)

    def initialize(
      name : String,
      @units : Array(SystemdUnit),
      @scope : SystemdScope = SystemdScope::System,
      description : String? = nil,
      continue_on_error : Bool = false,
      probe_command : String? = nil,
      condition : Condition? = nil,
    )
      super(name, description, continue_on_error, probe_command, condition)
    end

    def kind : String
      "systemd-unit"
    end

    def item_type : ItemType
      ItemType::SystemdUnit
    end

    def required_commands : Array(String)
      ["systemctl"]
    end

    def items : Array(ItemRef)
      @units.map { |unit| item(unit.qualified_name, "systemd-unit") }
    end

    def summary : String
      "#{Text.pluralize(@units.size, "unit")} (#{@scope})"
    end
  end

  # `type: system-setting` — timedatectl / hostnamectl / localectl.
  #
  # Every setting is probed with the matching `show --property` first, so only
  # what actually differs is applied and a rerun is a no-op.
  class SystemSettingStep < Step
    getter? local_rtc : Bool?
    getter? ntp : Bool?
    getter timezone : String?
    getter hostname : String?
    getter locale : Hash(String, String)

    def initialize(
      name : String,
      @local_rtc : Bool? = nil,
      @ntp : Bool? = nil,
      @timezone : String? = nil,
      @hostname : String? = nil,
      @locale : Hash(String, String) = {} of String => String,
      description : String? = nil,
      continue_on_error : Bool = false,
      probe_command : String? = nil,
      condition : Condition? = nil,
    )
      super(name, description, continue_on_error, probe_command, condition)
    end

    def kind : String
      "system-setting"
    end

    def item_type : ItemType
      ItemType::SystemSetting
    end

    def empty? : Bool
      @local_rtc.nil? && @ntp.nil? && @timezone.nil? && @hostname.nil? && @locale.empty?
    end

    # Fixed order, with locale keys sorted, so plans and fingerprints are stable.
    def item_keys : Array(String)
      keys = [] of String
      keys << "localRtc" unless @local_rtc.nil?
      keys << "ntp" unless @ntp.nil?
      keys << "timezone" if @timezone
      keys << "hostname" if @hostname
      @locale.keys.sort!.each { |key| keys << "locale:#{key}" }
      keys
    end

    def items : Array(ItemRef)
      item_keys.map { |key| item(key, "system-setting") }
    end

    def summary : String
      "host settings"
    end
  end

  # One file inside a `file-writes` entry.
  struct FileWriteItem
    getter name : String
    getter destination : String

    # Exactly one of these two.
    getter content : String?
    getter source : String?

    getter owner : String?
    getter group : String?
    getter mode : String?
    getter? sudo : Bool
    getter condition : Condition?

    def initialize(
      @name : String,
      @destination : String,
      @content : String? = nil,
      @source : String? = nil,
      @owner : String? = nil,
      @group : String? = nil,
      @mode : String? = nil,
      @sudo : Bool = false,
      @condition : Condition? = nil,
    )
    end

    def item_key : String
      @destination
    end
  end

  # `kind: file-writes` — write files from inline content or a source path.
  class FileWriteStep < Step
    getter files : Array(FileWriteItem)

    def initialize(
      name : String,
      @files : Array(FileWriteItem),
      description : String? = nil,
      continue_on_error : Bool = false,
      probe_command : String? = nil,
      condition : Condition? = nil,
    )
      super(name, description, continue_on_error, probe_command, condition)
    end

    def kind : String
      "file-writes"
    end

    def item_type : ItemType
      ItemType::FileWrite
    end

    def items : Array(ItemRef)
      @files.map { |file| item(file.item_key, "file-write", file.name) }
    end

    def summary : String
      Text.pluralize(@files.size, "file")
    end
  end
end
