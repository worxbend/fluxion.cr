module Fluxion
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

    # Argv for a pre-install action such as a metadata refresh, plus the exit
    # codes that count as success. `dnf check-update` exits 100 when updates
    # are available, which is the answer to the question, not a failure.
    def action_argv(action : PackageAction) : {Array(String), Set(Int32)}
      entry = PackageAction.entry_for(self, action.action)
      raise unsupported(action) unless entry
      prefix, ok = entry
      {prefix + action.args, ok}
    end

    # Argv that reports whether a package is already installed, without
    # touching the network.
    def query_argv(package : String) : Array(String)
      case self
      in .dnf?, .zypper?         then ["rpm", "-q", package]
      in .pacman?, .paru?, .yay? then ["pacman", "-Q", package]
      in .apt?                   then ["dpkg-query", "-W", "-f=${Status}\t${Version}", package]
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
