module Fluxion
  # Shared by the kinds that hand their work to another tool.
  #
  # Each carries a path to that tool's own config rather than a description of
  # the work, so the item key says nothing about what will actually happen.
  # This is what lets the fingerprint see through the path to the file — and to
  # the step's own knobs — without Fluxion learning a schema it does not own.
  module DelegatedConfig
    def content_digest : String?
      path = config
      digest = Digest::SHA256.new
      # A missing config digests as its absence rather than as "no digest".
      # Returning nil would make `Recorder#recorded` skip the comparison and
      # report the step still installed, which is the opposite of what a
      # vanished config means.
      digest << (File.file?(path) ? File.read(path) : "\0missing")
      # The knobs that change what the delegate is asked to do live on the step,
      # not in the item key (which is the config path) and not in the file. A
      # digest over the file alone left `only:`, `skip:`, `locked:` and
      # `lockFile:` invisible to the fingerprint, so narrowing a profile to two
      # tools left a completed phase looking unchanged.
      delegation_inputs.each { |value| digest << "\0" << value }
      digest.hexfinal
    rescue File::Error
      nil
    end

    # Anything beyond the config path that changes the delegated invocation.
    # Empty for a kind whose only input is the path.
    def delegation_inputs : Array(String)
      [] of String
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

    def delegation_inputs : Array(String)
      inputs = @only + @skip
      inputs << "locked" if @locked
      @lock_file.try { |lock| inputs << lock }
      inputs
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
  # A path to an installer config, never an inline font list: that file is the
  # installer's schema and its trust boundary, not Fluxion's. Fluxion used to
  # accept the list and render it at run time, which made it the owner of a
  # schema it could neither validate nor keep in step with upstream.
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
