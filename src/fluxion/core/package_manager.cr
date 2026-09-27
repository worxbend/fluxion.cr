module Fluxion
  # The pre-install actions each manager accepts, mapped to the argv prefix
  # that runs them and the exit codes that count as success.
  #
  # A module rather than constants on `PackageManager` itself, because Crystal
  # reads an uppercase assignment inside an `enum` body as a member and rejects
  # a value that is not an integer. `PackageManager#action_table` is what the
  # rest of the codebase asks; nothing outside this file names these tables.
  module PackageActionTable
    OK        = Set{0}
    OK_OR_100 = Set{0, 100}

    PACMAN_SYU     = ["sudo", "pacman", "-Syu", "--noconfirm"]
    ZYPPER_COMMAND = ["sudo", "zypper", "--non-interactive"]

    # One table per manager, below. Declaration order inside each is the order
    # `fluxion kinds` prints the actions in, so the keys are listed the way
    # they should read.

    NO_ACTIONS = {} of String => {Array(String), Set(Int32)}

    APT_ACTIONS = {
      "update"       => {["sudo", "apt-get", "update"], OK},
      "upgrade"      => {["sudo", "apt-get", "upgrade", "-y"], OK},
      "dist-upgrade" => {["sudo", "apt-get", "dist-upgrade", "-y"], OK},
    }

    DNF_ACTIONS = {
      "check-update" => {["sudo", "dnf", "check-update"], OK_OR_100},
      "upgrade"      => {["sudo", "dnf", "upgrade", "-y"], OK},
      "swap"         => {["sudo", "dnf", "swap", "-y"], OK},
      "groupupdate"  => {["sudo", "dnf", "groupupdate", "-y"], OK},
      "group-update" => {["sudo", "dnf", "groupupdate", "-y"], OK},
    }

    PACMAN_ACTIONS = {
      "sync-upgrade" => {PACMAN_SYU, OK},
      "syu"          => {PACMAN_SYU, OK},
      "upgrade"      => {PACMAN_SYU, OK},
    }

    ZYPPER_ACTIONS = {
      "refresh"  => {ZYPPER_COMMAND + ["refresh"], OK},
      "update"   => {ZYPPER_COMMAND + ["update", "-y"], OK},
      "dup"      => {ZYPPER_COMMAND + ["dup", "-y"], OK},
      "dup-from" => {ZYPPER_COMMAND + ["dup", "-y", "--from"], OK},
    }
  end

  # Every package manager Fluxion can drive.
  #
  # Flatpak and Cargo sit alongside the system managers because profiles select
  # them by the same `packageManager` field, even though neither can perform a
  # system update — see `#supports_system_update?`.
  enum PackageManager
    Dnf
    Pacman
    Paru
    Yay
    Apt
    Flatpak
    Zypper
    Cargo

    def self.from_config?(value : String?) : self?
      return unless value
      case value.strip.downcase
      when "dnf"     then Dnf
      when "pacman"  then Pacman
      when "paru"    then Paru
      when "yay"     then Yay
      when "apt"     then Apt
      when "flatpak" then Flatpak
      when "zypper"  then Zypper
      when "cargo"   then Cargo
      end
    end

    def config_name : String
      to_s.downcase
    end

    # `system-update` needs a manager that owns the whole system's packages.
    # Cargo and Flatpak each own a slice of it, so "upgrade everything" has no
    # meaning for them and the profile is asking for something impossible.
    def supports_system_update? : Bool
      !(cargo? || flatpak?)
    end

    # AUR helpers refuse to run as root and escalate themselves for the pacman
    # steps that need it, so Fluxion must not wrap them in sudo.
    def aur? : Bool
      paru? || yay?
    end

    # Argv that installs one package. Fluxion installs a package per process so
    # a single bad name cannot take the rest of the list down with it.
    #
    # A leading "sudo" is a marker, not the final command: the shell runner
    # rewrites it into a non-interactive invocation with a trust-resolved
    # target before anything is spawned.
    def install_argv(package : String) : Array(String)
      case self
      in .apt?     then ["sudo", "apt-get", "install", "-y", package]
      in .dnf?     then ["sudo", "dnf", "install", "-y", package]
      in .pacman?  then ["sudo", "pacman", "-S", "--noconfirm", package]
      in .paru?    then ["paru", "-S", "--noconfirm", package]
      in .yay?     then ["yay", "-S", "--noconfirm", package]
      in .zypper?  then ["sudo", "zypper", "install", "-y", package]
      in .cargo?   then ["cargo", "install", package]
      in .flatpak? then ["flatpak", "install", "-y", package]
      end
    end

    # The pre-install actions this manager has, keyed by verb.
    #
    # An exhaustive `case`, like the sibling argv methods, so that adding a
    # ninth manager is a compile error here rather than a manager that quietly
    # accepts no actions at all.
    def action_table : Hash(String, {Array(String), Set(Int32)})
      case self
      in .apt?                   then PackageActionTable::APT_ACTIONS
      in .dnf?                   then PackageActionTable::DNF_ACTIONS
      in .pacman?, .paru?, .yay? then PackageActionTable::PACMAN_ACTIONS
      in .zypper?                then PackageActionTable::ZYPPER_ACTIONS
      in .cargo?, .flatpak?      then PackageActionTable::NO_ACTIONS
      end
    end

    def supports_action?(action : String) : Bool
      action_table.has_key?(action.strip.downcase)
    end

    # In declaration order, which is the order `fluxion kinds` prints.
    def supported_actions : Array(String)
      action_table.keys
    end

    # Argv for a pre-install action such as a metadata refresh, plus the exit
    # codes that count as success. `dnf check-update` exits 100 when updates
    # are available, which is the answer to the question, not a failure.
    def action_argv(action : PackageAction) : {Array(String), Set(Int32)}
      entry = action_table[action.action]?
      raise unsupported(action) unless entry
      prefix, ok = entry
      {prefix + action.args, ok}
    end

    # Argv that reports whether a package is already installed, without
    # touching the network.
    #
    # The dpkg-query format separates its fields with `|` rather than a tab.
    # The runner turns every control character in captured output into a
    # space, so a tab reached the probe as a space and no package ever read as
    # installed. `|` cannot occur in either field — a Debian version is limited
    # to alphanumerics and `.+-~:` — and survives sanitizing untouched. The
    # trailing newline (an escape dpkg-query expands itself) keeps a multi-arch
    # package, reported once per architecture, from running into one line.
    def query_argv(package : String) : Array(String)
      case self
      in .dnf?, .zypper?         then ["rpm", "-q", package]
      in .pacman?, .paru?, .yay? then ["pacman", "-Q", package]
      in .apt?                   then ["dpkg-query", "-W", "-f=${Status}|${Version}\\n", package]
      in .flatpak?               then ["flatpak", "list", "--app", "--columns=application"]
      in .cargo?                 then ["cargo", "install", "--list"]
      end
    end

    # The executable `doctor` checks for on PATH.
    def command : String
      case self
      in .dnf?     then "dnf"
      in .pacman?  then "pacman"
      in .paru?    then "paru"
      in .yay?     then "yay"
      in .apt?     then "apt-get"
      in .flatpak? then "flatpak"
      in .zypper?  then "zypper"
      in .cargo?   then "cargo"
      end
    end

    def to_s(io : IO) : Nil
      io << config_name
    end

    private def unsupported(action : PackageAction) : ExecutionError
      ExecutionError.new("Unsupported #{config_name} action: #{action.action}")
    end
  end

  # Language- and ecosystem-level installers used by `tool-packages`.
  #
  # Kept separate from `PackageManager` because these install into the user's
  # home, need no sudo (except snap), and each has its own name grammar.
  enum ToolBackend
    CargoBinstall
    Cargo
    Snap
    Pipx
    UvTool
    NpmGlobal
    GoInstall

    def self.from_config?(value : String?) : self?
      return unless value
      case value.strip.downcase
      when "cargo-binstall" then CargoBinstall
      when "cargo"          then Cargo
      when "snap"           then Snap
      when "pipx"           then Pipx
      when "uv-tool"        then UvTool
      when "npm-global"     then NpmGlobal
      when "go-install"     then GoInstall
      end
    end

    def self.config_names : Array(String)
      values.map(&.config_name)
    end

    def config_name : String
      case self
      in .cargo_binstall? then "cargo-binstall"
      in .cargo?          then "cargo"
      in .snap?           then "snap"
      in .pipx?           then "pipx"
      in .uv_tool?        then "uv-tool"
      in .npm_global?     then "npm-global"
      in .go_install?     then "go-install"
      end
    end

    # The executable that must be on PATH. Note that `uv-tool` runs `uv` and
    # `npm-global` runs `npm` — the backend id names the install strategy, not
    # the binary.
    def command : String
      case self
      in .cargo_binstall? then "cargo-binstall"
      in .cargo?          then "cargo"
      in .snap?           then "snap"
      in .pipx?           then "pipx"
      in .uv_tool?        then "uv"
      in .npm_global?     then "npm"
      in .go_install?     then "go"
      end
    end

    def install_argv(package : ToolPackage) : Array(String)
      name = package.name
      version = package.version
      case self
      in .cargo_binstall?
        ["cargo-binstall", "--no-confirm", version ? "#{name}@#{version}" : name]
      in .cargo?
        version ? ["cargo", "install", "--locked", "--version", version, name] : ["cargo", "install", "--locked", name]
      in .snap?
        version ? ["sudo", "snap", "install", name, "--channel", version] : ["sudo", "snap", "install", name]
      in .pipx?
        ["pipx", "install", version ? "#{name}==#{version}" : name]
      in .uv_tool?
        ["uv", "tool", "install", version ? "#{name}==#{version}" : name]
      in .npm_global?
        ["npm", "install", "-g", version ? "#{name}@#{version}" : name]
      in .go_install?
        # Go has no unpinned install form, so an unpinned package becomes
        # `@latest` rather than an argument Go would reject.
        ["go", "install", "#{name}@#{version || "latest"}"]
      end
    end

    def to_s(io : IO) : Nil
      io << config_name
    end
  end

  # A `tool-packages` item: a registry identifier with an optional pin.
  struct ToolPackage
    getter name : String
    getter version : String?

    def initialize(@name : String, @version : String? = nil)
    end

    def to_s(io : IO) : Nil
      io << @name
      version = @version
      io << '@' << version if version
    end
  end
end
