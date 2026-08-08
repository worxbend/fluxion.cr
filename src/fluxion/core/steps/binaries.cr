module Fluxion
  # Artifact shapes a `compiled-binary` URL may point at.
  #
  # The split between locally extracted and delegated formats is deliberate:
  # Fluxion implements tar.gz itself with hard bounds, and refuses to guess at
  # zip and tar.xz rather than shipping two more archive parsers that handle
  # traversal, symlinks, and decompression bombs.
  module DelegatedConfig
    def content_digest : String?
      path = config
      return unless File.file?(path)
      Digest::SHA256.hexdigest(File.read(path))
    rescue File::Error
      nil
    end
  end

  class BinstallerProfileStep < Step
    include DelegatedConfig
    DEFAULT_INSTALLER_VERSION = "v0.2.0"

    getter config : String
    getter only : Array(String)
    getter skip : Array(String)
    getter? locked : Bool
    getter lock_file : String?
    getter installer_version : String

    def initialize(
      name : String,
      @config : String,
      @only : Array(String) = [] of String,
      @skip : Array(String) = [] of String,
      @locked : Bool = false,
      @lock_file : String? = nil,
      @installer_version : String = DEFAULT_INSTALLER_VERSION,
      description : String? = nil,
      continue_on_error : Bool = false,
      probe_command : String? = nil,
      condition : Condition? = nil,
    )
      super(name, description, continue_on_error, probe_command, condition)
    end

    def kind : String
      "binstaller-profile"
    end

    def items : Array(ItemRef)
      [item(@config, "binstaller-profile", @name)]
    end

    def summary : String
      return "binstaller profile (#{@only.size} selected)" unless @only.empty?
      "binstaller profile #{File.basename(@config)}"
    end
  end

  # `type: nerd-fonts` — install Nerd Font families via `nerd-fonts-installer`.
  #
  # Either an inline `config` Fluxion renders, or a `configPath` to an
  # installer config the user already maintains — in which case that file, not
  # Fluxion, is the trust boundary.
  class NerdFontsStep < Step
    include DelegatedConfig

    DEFAULT_INSTALLER_VERSION = "v1.0.7"

    # Path to a nerd-fonts-installer config, in that tool's own format.
    getter config : String
    getter installer_version : String

    def initialize(
      name : String,
      @config : String,
      @installer_version : String = DEFAULT_INSTALLER_VERSION,
      description : String? = nil,
      continue_on_error : Bool = false,
      probe_command : String? = nil,
      condition : Condition? = nil,
    )
      super(name, description, continue_on_error, probe_command, condition)
    end

    def kind : String
      "nerd-fonts"
    end

    # One item, not one per family.
    #
    # Fluxion used to expand an inline font list into an item each, but the
    # executor ignores the item and runs the whole installer — so a profile
    # naming 42 families invoked the installer 42 times, each one doing all 42.
    # A config path is opaque by design, and this step either ran the installer
    # or it did not.
    def items : Array(ItemRef)
      [item(@config, "nerd-fonts", @name)]
    end

    def summary : String
      "nerd fonts from #{File.basename(@config)}"
    end
  end

  # `type: dotbot` — apply dotfiles with `dotbot-go`.
  class DotbotStep < Step
    include DelegatedConfig
    DEFAULT_INSTALLER_VERSION = "v0.4.2"
    DEFAULT_BINARY            = "dotbot"

    getter config : String
    getter installer_version : String
    getter binary : String

    def initialize(
      name : String,
      @config : String,
      @installer_version : String = DEFAULT_INSTALLER_VERSION,
      @binary : String = DEFAULT_BINARY,
      description : String? = nil,
      continue_on_error : Bool = false,
      probe_command : String? = nil,
      condition : Condition? = nil,
    )
      super(name, description, continue_on_error, probe_command, condition)
    end

    def kind : String
      "dotbot"
    end

    def items : Array(ItemRef)
      [item(@config, "dotfiles", @name)]
    end

    def summary : String
      "dotfiles from #{@config}"
    end
  end

  # Upstream toolchain installers that ship their own bootstrap script.
  enum ToolchainKind
    Rustup
    Juliaup
    Sdkman
    Generic

    def self.from_config?(value : String?) : self?
      return unless value
      case value.strip.downcase
      when "rustup"  then Rustup
      when "juliaup" then Juliaup
      when "sdkman"  then Sdkman
      when "generic" then Generic
      end
    end

    # The config spelling is uppercase for this kind, unlike every other enum,
    # matching `kind: RUSTUP` in the documented schema.
    def config_name : String
      case self
      in .rustup?  then "RUSTUP"
      in .juliaup? then "JULIAUP"
      in .sdkman?  then "SDKMAN"
      in .generic? then "GENERIC"
      end
    end

    def to_s(io : IO) : Nil
      io << config_name
    end
  end

  # `type: toolchain` — run an upstream toolchain installer script.
  #
  # `sha256` is mandatory and updates are fail-closed on purpose: when upstream
  # changes the script, the run stops so a human reviews the new bytes instead
  # of piping them to a shell because the URL is unchanged.
  class ToolchainStep < Step
    getter toolchain : ToolchainKind
    getter install_script_url : String
    getter sha256 : Checksum
    getter install_args : Array(String)

    # File to source after install so later steps in the same run can see the
    # new toolchain without a full shell reload.
    getter post_install_env_source : String?

    def initialize(
      name : String,
      @toolchain : ToolchainKind,
      @install_script_url : String,
      @sha256 : Checksum,
      @install_args : Array(String) = [] of String,
      @post_install_env_source : String? = nil,
      description : String? = nil,
      continue_on_error : Bool = false,
      probe_command : String? = nil,
      condition : Condition? = nil,
    )
      super(name, description, continue_on_error, probe_command, condition)
    end

    def kind : String
      "toolchain"
    end

    def items : Array(ItemRef)
      [item(@name, "toolchain", @toolchain.config_name)]
    end

    def summary : String
      "#{@toolchain} toolchain"
    end
  end

  # `type: oh-my-zsh` — install Oh My Zsh at an exact commit.
  #
  # `revision` must be a full 40-character commit: `master` and mutable tags
  # would make `sha256` meaningless, since the bytes it pins could change
  # under the same reference.
  class OhMyZshStep < Step
    DEFAULT_INSTALL_DIR = "~/.oh-my-zsh"
    COMMIT_PATTERN      = /\A[0-9a-f]{40}\z/

    getter install_dir : String
    getter revision : String
    getter sha256 : Checksum

    def initialize(
      name : String,
      @revision : String,
      @sha256 : Checksum,
      @install_dir : String = DEFAULT_INSTALL_DIR,
      description : String? = nil,
      continue_on_error : Bool = false,
      probe_command : String? = nil,
      condition : Condition? = nil,
    )
      super(name, description, continue_on_error, probe_command, condition)
    end

    def self.commit?(revision : String) : Bool
      revision.matches?(COMMIT_PATTERN)
    end

    def kind : String
      "oh-my-zsh"
    end

    def items : Array(ItemRef)
      [item(@install_dir, "oh-my-zsh", @name)]
    end

    def summary : String
      "oh-my-zsh @ #{@revision[0, 7]}"
    end
  end
end
