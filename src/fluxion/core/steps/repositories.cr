module Fluxion
  # A remote signing key together with the digest that pins it.
  #
  # The pair is inseparable by design: a key URL without a checksum means
  # "trust whatever this host serves today to decide what my machine installs
  # as root", which is exactly the decision Fluxion refuses to make implicitly.
  struct SigningKey
    getter url : String
    getter checksum : Checksum

    def initialize(@url : String, @checksum : Checksum)
    end

    def to_s(io : IO) : Nil
      io << @url
    end
  end

  # `type: apt-repository` — declare a Debian/Ubuntu APT source.
  #
  # Exists so repository setup is auditable typed data instead of a `curl | gpg
  # --dearmor | sudo tee` line buried in a shell step. Fluxion downloads and
  # verifies the key unprivileged, dearmors it unprivileged, and only then uses
  # structured `sudo install` for the keyring and source list.
  class AptRepositoryStep < Step
    KEYRING_DIRECTORIES = ["/etc/apt/keyrings", "/usr/share/keyrings"]
    SOURCES_DIRECTORY   = "/etc/apt/sources.list.d"

    # The full `deb [...] https://... suite component` line.
    getter source : String

    # Absolute path of the `.list` file, confined to /etc/apt/sources.list.d.
    getter source_list : String

    getter signing_key : SigningKey?

    # Absolute keyring path. Must equal the `signed-by` option in `source`,
    # so the declared trust and the effective trust cannot drift apart.
    getter keyring : String?

    def initialize(
      name : String,
      @source : String,
      @source_list : String,
      @signing_key : SigningKey? = nil,
      @keyring : String? = nil,
      description : String? = nil,
      continue_on_error : Bool = false,
      probe_command : String? = nil,
      condition : Condition? = nil,
    )
      super(name, description, continue_on_error, probe_command, condition)
    end

    def self.default_source_list(name : String) : String
      File.join(SOURCES_DIRECTORY, "#{name}.list")
    end

    def self.default_keyring(name : String) : String
      File.join(KEYRING_DIRECTORIES.first, "#{name}.gpg")
    end

    def kind : String
      "apt-repository"
    end

    def item_type : ItemType
      ItemType::AptRepository
    end

    # Keyed by the source list path: it is unique, absolute, and the thing the
    # user would delete to undo the step.
    def items : Array(ItemRef)
      [item(@source_list, "apt-repository", @name)]
    end

    def summary : String
      "apt source #{File.basename(@source_list)}"
    end
  end

  # `type: rpm-repository` — declare a Fedora DNF repository.
  # What the two rpm-style repository kinds genuinely have in common.
  #
  # A module of abstract declarations rather than a shared base class, because
  # the kinds stay distinct on purpose — see the comment on
  # `ZypperRepositoryStep`. This names only the overlap, which is what lets
  # `RpmStyleRepositoryExecutor` read a repository's fields directly instead of
  # running a `step.is_a?(Rpm…) ? … : step.as(Zypper…)` test once per field.
  module RpmStyleRepository
    abstract def id : String
    abstract def base_url : String
    abstract def repo_file : String
    abstract def signing_key : SigningKey?
    abstract def enabled? : Bool
    abstract def gpg_check? : Bool
  end

  class RpmRepositoryStep < Step
    include RpmStyleRepository

    REPO_DIRECTORY = "/etc/yum.repos.d"

    getter id : String
    getter base_url : String
    getter repo_file : String
    getter signing_key : SigningKey?
    getter? enabled : Bool
    getter? gpg_check : Bool

    def initialize(
      name : String,
      @id : String,
      @base_url : String,
      @repo_file : String,
      @signing_key : SigningKey? = nil,
      @enabled : Bool = true,
      @gpg_check : Bool = true,
      description : String? = nil,
      continue_on_error : Bool = false,
      probe_command : String? = nil,
      condition : Condition? = nil,
    )
      super(name, description, continue_on_error, probe_command, condition)
    end

    def self.default_repo_file(name : String) : String
      File.join(REPO_DIRECTORY, "#{name}.repo")
    end

    def kind : String
      "rpm-repository"
    end

    def item_type : ItemType
      ItemType::RpmRepository
    end

    def items : Array(ItemRef)
      [item(@repo_file, "rpm-repository", @id)]
    end

    def summary : String
      "dnf repository #{@id}"
    end
  end

  # `type: zypper-repository` — declare an openSUSE repository.
  #
  # Structurally close to the DNF kind but kept separate: the repo directory,
  # the `autorefresh` key, and the validation messages all differ, and folding
  # them together would make every branch read "unless zypper".
  class ZypperRepositoryStep < Step
    include RpmStyleRepository

    REPO_DIRECTORY = "/etc/zypp/repos.d"

    getter id : String
    getter base_url : String
    getter repo_file : String
    getter signing_key : SigningKey?
    getter? enabled : Bool
    getter? gpg_check : Bool
    getter? auto_refresh : Bool

    def initialize(
      name : String,
      @id : String,
      @base_url : String,
      @repo_file : String,
      @signing_key : SigningKey? = nil,
      @enabled : Bool = true,
      @gpg_check : Bool = true,
      @auto_refresh : Bool = true,
      description : String? = nil,
      continue_on_error : Bool = false,
      probe_command : String? = nil,
      condition : Condition? = nil,
    )
      super(name, description, continue_on_error, probe_command, condition)
    end

    def self.default_repo_file(name : String) : String
      File.join(REPO_DIRECTORY, "#{name}.repo")
    end

    def kind : String
      "zypper-repository"
    end

    def item_type : ItemType
      ItemType::ZypperRepository
    end

    def items : Array(ItemRef)
      [item(@repo_file, "zypper-repository", @id)]
    end

    def summary : String
      "zypper repository #{@id}"
    end
  end

  # `type: pacman-repository` — declare an Arch repository block.
  #
  # Unlike the other three this edits a shared file (/etc/pacman.conf) rather
  # than dropping in its own, so execution stages a complete replacement
  # privately and installs it atomically instead of appending in place.
  class PacmanRepositoryStep < Step
    DEFAULT_CONFIG    = "/etc/pacman.conf"
    INCLUDE_DIRECTORY = "/etc/pacman.d"

    # Pacman's documented trust-policy tokens. Anything else is rejected rather
    # than passed through, because an unrecognized token silently weakens
    # verification.
    SIG_LEVEL_TOKENS = %w[
      Never Optional Required
      TrustedOnly TrustAll
      PackageNever PackageOptional PackageRequired
      PackageTrustedOnly PackageTrustAll
      DatabaseNever DatabaseOptional DatabaseRequired
      DatabaseTrustedOnly DatabaseTrustAll
    ]

    getter repository : String
    getter server : String?
    getter config : String
    getter sig_level : String?
    getter include_path : String?
    getter? enabled : Bool

    def initialize(
      name : String,
      @repository : String,
      @server : String? = nil,
      @config : String = DEFAULT_CONFIG,
      @sig_level : String? = nil,
      @include_path : String? = nil,
      @enabled : Bool = true,
      description : String? = nil,
      continue_on_error : Bool = false,
      probe_command : String? = nil,
      condition : Condition? = nil,
    )
      super(name, description, continue_on_error, probe_command, condition)
    end

    def kind : String
      "pacman-repository"
    end

    def item_type : ItemType
      ItemType::PacmanRepository
    end

    def items : Array(ItemRef)
      [item(@repository, "pacman-repository")]
    end

    def summary : String
      "pacman repository #{@repository}"
    end
  end

  # `type: flatpak-remote` — declare a Flatpak remote.
  #
  # The `.flatpakrepo` descriptor is downloaded and verified first; only the
  # verified local path is handed to `flatpak remote-add`. The remote URL is
  # never passed to Flatpak, so Flatpak cannot fetch a different document than
  # the one Fluxion checked.
  class FlatpakRemoteStep < Step
    getter remote : String
    getter url : String
    getter checksum : Checksum

    # System remote (default) or `--user`.
    getter? system : Bool

    def initialize(
      name : String,
      @remote : String,
      @url : String,
      @checksum : Checksum,
      @system : Bool = true,
      description : String? = nil,
      continue_on_error : Bool = false,
      probe_command : String? = nil,
      condition : Condition? = nil,
    )
      super(name, description, continue_on_error, probe_command, condition)
    end

    def kind : String
      "flatpak-remote"
    end

    def item_type : ItemType
      ItemType::FlatpakRemote
    end

    def required_commands : Array(String)
      ["flatpak"]
    end

    def items : Array(ItemRef)
      [item(@remote, "flatpak-remote")]
    end

    def summary : String
      "flatpak remote #{@remote}#{" (user)" unless @system}"
    end
  end

  # One key inside a `gpg-key` step.
  #
  # `keyring` decides the destination: absent means `rpm --import` into the RPM
  # database, present means write a dearmoured keyring for an apt `signed-by`
  # source. The fingerprint is mandatory either way — importing a key decides
  # what the machine will install as root.
  struct GpgKeyEntry
    getter url : String
    getter fingerprint : Fingerprint
    getter keyring : String?

    def initialize(@url : String, @fingerprint : Fingerprint, @keyring : String? = nil)
    end

    def rpm_import? : Bool
      @keyring.nil?
    end

    # Stable identity for plans and state: the keyring path when there is one,
    # otherwise the fingerprint. Query strings and fragments never appear here.
    def item_key : String
      @keyring || @fingerprint.value
    end

    def to_s(io : IO) : Nil
      io << item_key
    end
  end

  # `type: gpg-key` — import repository signing keys.
  class GpgKeyStep < Step
    MAX_KEY_BYTES = 16 * 1024 * 1024

    getter keys : Array(GpgKeyEntry)

    def initialize(
      name : String,
      @keys : Array(GpgKeyEntry),
      description : String? = nil,
      continue_on_error : Bool = false,
      probe_command : String? = nil,
      condition : Condition? = nil,
    )
      super(name, description, continue_on_error, probe_command, condition)
    end

    def kind : String
      "gpg-key"
    end

    def item_type : ItemType
      ItemType::GpgKey
    end

    def required_commands : Array(String)
      ["gpg"]
    end

    def items : Array(ItemRef)
      @keys.map { |key| item(key.item_key, "gpg-key") }
    end

    def summary : String
      Text.pluralize(@keys.size, "signing key")
    end
  end
end
