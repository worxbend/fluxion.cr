module Fluxion
  # Distributions Fluxion knows how to bootstrap. The stable `jobs`/`steps`
  # schema calls this `os.type`; WorkstationProfile manifests call it
  # `spec.target.os.distribution` and additionally accept `ubuntu`.
  enum Distribution
    Fedora
    Arch
    OpenSuse
    Debian
    Ubuntu

    # Parses a config or `/etc/os-release` value. Returns nil rather than
    # raising so callers can attach the offending config path to the error.
    def self.from_config?(value : String?) : self?
      return unless value
      case value.strip.downcase
      when "fedora"                          then Fedora
      when "arch", "archlinux", "arch-linux" then Arch
      when "endeavouros", "manjaro", "cachyos", "garuda"
        # Arch derivatives share pacman and the Arch package namespace, so
        # treating them as Arch is right for every decision Fluxion makes.
        Arch
      when "opensuse", "opensuse-tumbleweed", "opensuse-leap", "suse", "sles"
        OpenSuse
      when "debian"                     then Debian
      when "ubuntu", "pop", "linuxmint" then Ubuntu
      end
    end

    # The config spelling, which is also what error messages and JSON output
    # print. `OpenSuse` is `opensuse`, not `open_suse`.
    def config_name : String
      case self
      in .fedora?    then "fedora"
      in .arch?      then "arch"
      in .open_suse? then "opensuse"
      in .debian?    then "debian"
      in .ubuntu?    then "ubuntu"
      end
    end

    def family : OsFamily
      case self
      in .fedora?           then OsFamily::Fedora
      in .arch?             then OsFamily::Arch
      in .open_suse?        then OsFamily::Suse
      in .debian?, .ubuntu? then OsFamily::Debian
      end
    end

    # The package manager a profile is expected to use on this distribution.
    # `validate` reports a mismatch, because installing with the wrong manager
    # fails late and confusingly rather than at parse time.
    def package_managers : Array(PackageManager)
      case self
      in .fedora?           then [PackageManager::Dnf]
      in .arch?             then [PackageManager::Pacman, PackageManager::Paru, PackageManager::Yay]
      in .open_suse?        then [PackageManager::Zypper]
      in .debian?, .ubuntu? then [PackageManager::Apt]
      end
    end

    def to_s(io : IO) : Nil
      io << config_name
    end
  end

  # Coarser grouping used by manifest `when.osFamily` rules, where "any Debian
  # derivative" is the useful predicate rather than a specific distribution.
  enum OsFamily
    Debian
    Fedora
    Arch
    Suse

    def self.from_config?(value : String?) : self?
      return unless value
      case value.strip.downcase
      when "debian"                   then Debian
      when "fedora", "rhel", "redhat" then Fedora
      when "arch"                     then Arch
      when "suse", "opensuse"         then Suse
      end
    end

    def config_name : String
      to_s.downcase
    end

    def to_s(io : IO) : Nil
      io << config_name
    end
  end

  # CPU architectures Fluxion can select release assets for.
  enum Architecture
    Amd64
    Arm64

    def self.from_config?(value : String?) : self?
      return unless value
      case value.strip.downcase
      when "amd64", "x86_64", "x64" then Amd64
      when "arm64", "aarch64"       then Arm64
      end
    end

    def config_name : String
      case self
      in .amd64? then "amd64"
      in .arm64? then "arm64"
      end
    end

    def to_s(io : IO) : Nil
      io << config_name
    end
  end

  # The OS a profile declares it targets.
  #
  # For the stable `jobs`/`steps` schema this drives package-manager validation.
  # For WorkstationProfile manifests it is informational metadata only: host
  # facts and per-entry `when` rules decide what actually runs.
  struct TargetOs
    getter distribution : Distribution
    getter release : String?

    def initialize(@distribution : Distribution, @release : String? = nil)
    end

    def to_s(io : IO) : Nil
      io << @distribution
      release = @release
      io << ' ' << release if release
    end
  end

  # What Fluxion detected about the machine it is running on. Manifest `when`
  # rules match against this, never against the declared target.
  struct HostFacts
    getter distribution : Distribution?
    getter family : OsFamily?

    # Raw `ID` from /etc/os-release, kept even when it maps to no known
    # `Distribution`, so error messages can name what was actually found.
    getter distribution_id : String?
    getter version : String?
    getter codename : String?
    getter architecture : Architecture?
    getter pretty_name : String?

    def initialize(
      @distribution : Distribution? = nil,
      @family : OsFamily? = nil,
      @distribution_id : String? = nil,
      @version : String? = nil,
      @codename : String? = nil,
      @architecture : Architecture? = nil,
      @pretty_name : String? = nil,
    )
    end

    def to_s(io : IO) : Nil
      io << (@pretty_name || @distribution_id || "unknown host")
      architecture = @architecture
      io << " (" << architecture << ')' if architecture
    end
  end
end
