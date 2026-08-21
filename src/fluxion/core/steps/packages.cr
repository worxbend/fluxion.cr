module Fluxion
  # A pre-install action a package entry may run before its own packages, such
  # as refreshing metadata or upgrading the system. Kept as typed data rather
  # than a free-form command so `plan` can preview it and validation can reject
  # a verb the selected manager does not have.
  struct PackageAction
    getter action : String
    getter args : Array(String)

    def initialize(action : String, @args : Array(String) = [] of String)
      @action = action.strip.downcase
    end

    OK        = Set{0}
    OK_OR_100 = Set{0, 100}

    PACMAN_SYU = ["sudo", "pacman", "-Syu", "--noconfirm"]
    ZYPPER     = ["sudo", "zypper", "--non-interactive"]

    PACMAN_ACTIONS = {
      "sync-upgrade" => {PACMAN_SYU, OK},
      "syu"          => {PACMAN_SYU, OK},
      "upgrade"      => {PACMAN_SYU, OK},
    }

    # The actions each manager accepts, mapped to the argv prefix that runs
    # them and the exit codes that count as success.
    SUPPORTED = {
      PackageManager::Apt => {
        "update"       => {["sudo", "apt-get", "update"], OK},
        "upgrade"      => {["sudo", "apt-get", "upgrade", "-y"], OK},
        "dist-upgrade" => {["sudo", "apt-get", "dist-upgrade", "-y"], OK},
      },
      PackageManager::Dnf => {
        "check-update" => {["sudo", "dnf", "check-update"], OK_OR_100},
        "upgrade"      => {["sudo", "dnf", "upgrade", "-y"], OK},
        "swap"         => {["sudo", "dnf", "swap", "-y"], OK},
        "groupupdate"  => {["sudo", "dnf", "groupupdate", "-y"], OK},
        "group-update" => {["sudo", "dnf", "groupupdate", "-y"], OK},
      },
      PackageManager::Pacman => PACMAN_ACTIONS,
      PackageManager::Paru   => PACMAN_ACTIONS,
      PackageManager::Yay    => PACMAN_ACTIONS,
      PackageManager::Zypper => {
        "refresh"  => {ZYPPER + ["refresh"], OK},
        "update"   => {ZYPPER + ["update", "-y"], OK},
        "dup"      => {ZYPPER + ["dup", "-y"], OK},
        "dup-from" => {ZYPPER + ["dup", "-y", "--from"], OK},
      },
    }

    def self.supported?(manager : PackageManager, action : String) : Bool
      !!SUPPORTED[manager]?.try(&.has_key?(action.strip.downcase))
    end

    def self.supported_for(manager : PackageManager) : Array(String)
      SUPPORTED[manager]?.try(&.keys) || [] of String
    end

    # The argv prefix and success codes for this action under `manager`, or nil
    # when the manager does not have the verb.
    def self.entry_for(manager : PackageManager, action : String)
      SUPPORTED[manager]?.try(&.[]?(action))
    end

    def to_s(io : IO) : Nil
      io << @action
      @args.each { |arg| io << ' ' << arg }
    end
  end

  # `type: packages` — install system packages with the host package manager.
  #
  # Each package is installed in its own process. That is the whole point of
  # the kind: if `git` works and `some-wrong-name` does not, the user gets git
  # and one clear error, not a transaction that rolled back everything.
  class PackagesStep < Step
    getter package_manager : PackageManager
    getter packages : Array(String)
    getter actions : Array(PackageAction)

    def initialize(
      name : String,
      @package_manager : PackageManager,
      @packages : Array(String),
      @actions : Array(PackageAction) = [] of PackageAction,
      description : String? = nil,
      continue_on_error : Bool = true,
      probe_command : String? = nil,
      condition : Condition? = nil,
    )
      super(name, description, continue_on_error, probe_command, condition)
    end

    def kind : String
      "packages"
    end

    def item_type : ItemType
      ItemType::Package
    end

    def required_commands : Array(String)
      [@package_manager.command]
    end

    def item_package_manager : PackageManager?
      @package_manager
    end

    def items : Array(ItemRef)
      @packages.map { |package| item(package, "package") }
    end

    # Pre-install actions decide part of what this step does, and nothing else
    # the phase fingerprint reads can see them: they are not packages, so they
    # are in no item key, and the step has no other hashed input. Without this,
    # changing `actions: [update]` to `actions: [upgrade]` left a completed
    # phase's fingerprint identical, the orchestrator skipped the phase, and
    # the new action never ran.
    #
    # nil when there are no actions, so the ordinary packages step — which is
    # nearly all of them — fingerprints exactly as it did before.
    def content_digest : String?
      return if @actions.empty?
      Digest::SHA256.hexdigest(@actions.map(&.to_s).join('\0'))
    end

    def summary : String
      "#{@packages.size} #{@package_manager} #{Text.singular_or_plural(@packages.size, "package")}"
    end
  end

  # `type: flatpak` — install Flatpak applications from a remote.
  class FlatpakStep < Step
    DEFAULT_REMOTE = "flathub"

    getter remote : String
    getter app_ids : Array(String)

    def initialize(
      name : String,
      @app_ids : Array(String),
      @remote : String = DEFAULT_REMOTE,
      description : String? = nil,
      continue_on_error : Bool = true,
      probe_command : String? = nil,
      condition : Condition? = nil,
    )
      super(name, description, continue_on_error, probe_command, condition)
    end

    def kind : String
      "flatpak"
    end

    def item_type : ItemType
      ItemType::Flatpak
    end

    def required_commands : Array(String)
      ["flatpak"]
    end

    def item_package_manager : PackageManager?
      PackageManager::Flatpak
    end

    def items : Array(ItemRef)
      @app_ids.map { |app_id| item(app_id, "flatpak") }
    end

    def summary : String
      "#{Text.pluralize(@app_ids.size, "flatpak app")} from #{@remote}"
    end
  end

  # `type: tool-packages` — install from a language or ecosystem registry.
  #
  # Separate from `packages` because these backends install into the user's
  # home, need no sudo, and have their own name grammars — but they share the
  # one-process-per-package isolation, so a yanked crate does not block the
  # other nineteen.
  class ToolPackagesStep < Step
    getter backend : ToolBackend
    getter packages : Array(ToolPackage)

    def initialize(
      name : String,
      @backend : ToolBackend,
      @packages : Array(ToolPackage),
      description : String? = nil,
      continue_on_error : Bool = true,
      probe_command : String? = nil,
      condition : Condition? = nil,
    )
      super(name, description, continue_on_error, probe_command, condition)
    end

    def kind : String
      "tool-packages"
    end

    def item_type : ItemType
      ItemType::ToolPackage
    end

    def required_commands : Array(String)
      [@backend.command]
    end

    def items : Array(ItemRef)
      @packages.map { |package| item(package.name, @backend.config_name, package.to_s) }
    end

    def summary : String
      "#{@packages.size} #{@backend} #{Text.singular_or_plural(@packages.size, "package")}"
    end
  end

  # A SDKMAN candidate, optionally pinned. SDKMAN has no argv interface — it is
  # a set of shell functions — so this kind is driven through a sourced shell
  # command rather than a direct process.
  struct SdkmanCandidate
    getter candidate : String
    getter version : String?

    def initialize(@candidate : String, @version : String? = nil)
    end

    def to_s(io : IO) : Nil
      io << @candidate
      version = @version
      io << ' ' << version if version
    end
  end

  # `kind: sdkman-packages` — install SDKMAN candidates.
  class SdkmanPackagesStep < Step
    getter candidates : Array(SdkmanCandidate)

    def initialize(
      name : String,
      @candidates : Array(SdkmanCandidate),
      description : String? = nil,
      continue_on_error : Bool = true,
      probe_command : String? = nil,
      condition : Condition? = nil,
    )
      super(name, description, continue_on_error, probe_command, condition)
    end

    def kind : String
      "sdkman-packages"
    end

    def item_type : ItemType
      ItemType::SdkmanPackage
    end

    def items : Array(ItemRef)
      @candidates.map { |candidate| item(candidate.candidate, "sdkman", candidate.to_s) }
    end

    def summary : String
      Text.pluralize(@candidates.size, "SDKMAN candidate")
    end
  end

  # `type: system-update` — refresh metadata and upgrade the whole system.
  class SystemUpdateStep < Step
    DEFAULT_TIMEOUT = 2.hours

    getter package_manager : PackageManager

    # `zypper dup` / `apt full-upgrade`. Required on rolling releases such as
    # Tumbleweed, where a plain `update` is the wrong verb.
    getter? dist_upgrade : Bool

    # Refresh metadata and stop. Mutually exclusive with `dist_upgrade`: one
    # asks for the largest possible upgrade and the other for none at all.
    getter? refresh_only : Bool

    getter timeout : Time::Span

    def initialize(
      name : String,
      @package_manager : PackageManager,
      @dist_upgrade : Bool = false,
      @refresh_only : Bool = false,
      @timeout : Time::Span = DEFAULT_TIMEOUT,
      description : String? = nil,
      continue_on_error : Bool = false,
      probe_command : String? = nil,
      condition : Condition? = nil,
    )
      super(name, description, continue_on_error, probe_command, condition)
    end

    def kind : String
      "system-update"
    end

    def item_type : ItemType
      ItemType::SystemUpdate
    end

    def required_commands : Array(String)
      [@package_manager.command]
    end

    def item_package_manager : PackageManager?
      @package_manager
    end

    def items : Array(ItemRef)
      [item(@package_manager.config_name, "system-update")]
    end

    def summary : String
      return "refresh #{@package_manager} metadata" if @refresh_only
      return "#{@package_manager} distribution upgrade" if @dist_upgrade
      "#{@package_manager} system update"
    end
  end
end
