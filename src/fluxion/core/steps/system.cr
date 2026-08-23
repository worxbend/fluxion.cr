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
    )
      super(name, description, continue_on_error, probe_command)
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

    # Inverse of `item_key`: splits "alice:docker" into {"alice", "docker"}.
    # A key with no user is all group, and a key with no group after the
    # separator falls back to the whole key.
    def self.split_item_key(item_key : String) : {String, String}
      user, _, group = item_key.rpartition(':')
      group = item_key if group.empty?
      {user, group}
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
    )
      super(name, description, continue_on_error, probe_command)
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

    # An item key is `global:user.email` — the setting's name, never the value
    # it is being set to. Correcting a mistyped address therefore changed
    # nothing the phase fingerprint could see, so a completed phase stayed
    # completed and the old address stayed in `~/.gitconfig`.
    #
    # Each entry carries its role for the reason `DelegatedConfig` documents:
    # the digest sees one flat list, so an unlabelled value could be read as
    # the scope beside it.
    def content_digest : String?
      return if @entries.empty?
      inputs = ["scope=#{@scope}"]
      sorted_keys.each { |key| inputs << "entry=#{key}=#{@entries[key]}" }
      Step.digest_of(inputs)
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
    )
      super(name, description, continue_on_error, probe_command)
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

    # An item key is the destination directory — where the clone lands, not
    # what is meant to be in it. Bumping the pinned `ref` is the one edit this
    # kind exists for, and it left the phase fingerprint identical, so a
    # completed phase was skipped and the old commit stayed checked out.
    def content_digest : String?
      return if @repos.empty?
      inputs = [] of String
      @repos.each do |repo|
        inputs << "url=#{repo.url}"
        inputs << "destination=#{repo.destination}"
        inputs << "ref=#{repo.ref}"
        inputs << "depth=#{repo.depth}"
        inputs << "submodules=#{repo.submodules?}"
      end
      Step.digest_of(inputs)
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
    )
      super(name, description, continue_on_error, probe_command)
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

    # An item key is the unit's name, and every field that says what should
    # happen to that unit — enabled, masked, started or stopped — lives beside
    # it and reached no digest. Turning `enabled: true` into `masked: true` is
    # the opposite instruction under an unchanged key, so a completed phase was
    # skipped and the unit kept running.
    def content_digest : String?
      return if @units.empty?
      inputs = ["scope=#{@scope}"]
      @units.each do |unit|
        inputs << "unit=#{unit.qualified_name}"
        inputs << "enabled=#{unit.enabled?}"
        inputs << "state=#{unit.state}"
        inputs << "masked=#{unit.masked?}"
      end
      Step.digest_of(inputs)
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
    )
      super(name, description, continue_on_error, probe_command)
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

    # The item keys are the bare setting names — `timezone`, `hostname`,
    # `locale:LANG` — so moving the machine from `UTC` to `Europe/Warsaw`
    # produced an identical fingerprint and the completed phase was skipped
    # with the old zone still set.
    def content_digest : String?
      return if empty?
      inputs = [] of String
      @local_rtc.try { |value| inputs << "localRtc=#{value}" }
      @ntp.try { |value| inputs << "ntp=#{value}" }
      @timezone.try { |value| inputs << "timezone=#{value}" }
      @hostname.try { |value| inputs << "hostname=#{value}" }
      @locale.keys.sort!.each { |key| inputs << "locale:#{key}=#{@locale[key]}" }
      Step.digest_of(inputs)
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
    getter condition : Condition?

    def initialize(
      @name : String,
      @destination : String,
      @content : String? = nil,
      @source : String? = nil,
      @owner : String? = nil,
      @group : String? = nil,
      @mode : String? = nil,
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
    )
      super(name, description, continue_on_error, probe_command)
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

    # The item key is the destination — where the file lands, not what it should
    # contain. Everything that decides the contents is in no key at all, and
    # unlike the other kinds there is no file-write probe to catch the drift on
    # a second pass: `ProbeRegistry.default` registers none, so a completed
    # phase whose inline content was edited would be skipped forever.
    #
    # `source` is hashed as the path it names rather than the bytes at that
    # path. Reading it here would put IO in a step, which this layer does not
    # do; the executor compares the real contents before writing anything, so
    # the cost of missing an edit to a source file is one command that decides
    # nothing needs doing.
    def content_digest : String?
      Step.digest_of(@files.flat_map do |file|
        values = ["destination=#{file.destination}"]
        file.content.try { |body| values << "content=#{body}" }
        file.source.try { |path| values << "source=#{path}" }
        file.owner.try { |owner| values << "owner=#{owner}" }
        file.group.try { |group| values << "group=#{group}" }
        file.mode.try { |mode| values << "mode=#{mode}" }
        values
      end)
    end

    def summary : String
      Text.pluralize(@files.size, "file")
    end
  end
end
