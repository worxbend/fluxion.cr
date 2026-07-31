module Fluxion
  # Artifact shapes a `compiled-binary` URL may point at.
  #
  # The split between locally extracted and delegated formats is deliberate:
  # Fluxion implements tar.gz itself with hard bounds, and refuses to guess at
  # zip and tar.xz rather than shipping two more archive parsers that handle
  # traversal, symlinks, and decompression bombs.
  enum ArtifactFormat
    PlainBinary
    TarGz
    Zip
    TarXz

    # Classifies by the URL's final path component. Query strings are ignored,
    # since they never change what the bytes are.
    def self.detect(url : String) : self
      path = begin
        URI.parse(url).path
      rescue URI::Error
        url
      end
      name = File.basename(path).downcase
      return TarGz if name.ends_with?(".tar.gz") || name.ends_with?(".tgz")
      return TarXz if name.ends_with?(".tar.xz") || name.ends_with?(".txz")
      return Zip if name.ends_with?(".zip")
      PlainBinary
    end

    def archive? : Bool
      !plain_binary?
    end

    # True when the format is handled by `binstaller` rather than in-process.
    def delegated? : Bool
      zip? || tar_xz?
    end

    def config_name : String
      case self
      in .plain_binary? then "binary"
      in .tar_gz?       then "tar.gz"
      in .zip?          then "zip"
      in .tar_xz?       then "tar.xz"
      end
    end

    def to_s(io : IO) : Nil
      io << config_name
    end
  end

  # `type: compiled-binary` — download, verify, and install a pre-built binary.
  #
  # This is the kind with the most trust surface, so it carries the most
  # structure: a mandatory `TrustAnchor`, an exact archive member path rather
  # than a basename guess, and an atomic replace that only happens after mode
  # and symlink are staged successfully.
  class CompiledBinaryStep < Step
    DEFAULT_MODE = "0755"

    # Streaming limits. Artifacts and signatures cap at 1 GiB, checksum
    # documents at 1 MiB, and a decompressed tar stream at 2 GiB including
    # headers, padding, GNU long-name records, and PAX metadata.
    MAX_ARTIFACT_BYTES   = 1_i64 * 1024 * 1024 * 1024
    MAX_CHECKSUM_BYTES   = 1_i64 * 1024 * 1024
    MAX_TAR_ENTRY_BYTES  = 1_i64 * 1024 * 1024 * 1024
    MAX_TAR_STREAM_BYTES = 2_i64 * 1024 * 1024 * 1024

    getter binary_name : String
    getter url : String
    getter trust : TrustAnchor

    # Supplemental checksum document. Never a trust anchor on its own — it is
    # served by the same host as the artifact — so it is only meaningful
    # alongside a signer-bound signature.
    getter checksum_url : String?

    getter install_path : String
    getter format : ArtifactFormat

    # Exact post-strip member path inside the archive. Required for archives;
    # Fluxion never falls back to matching by basename, because two members can
    # share one.
    getter archive_path : String?

    getter strip_components : Int32
    getter mode : String
    getter symlink_path : String?

    def initialize(
      name : String,
      @binary_name : String,
      @url : String,
      @trust : TrustAnchor,
      @install_path : String,
      @format : ArtifactFormat,
      @archive_path : String? = nil,
      @strip_components : Int32 = 0,
      @mode : String = DEFAULT_MODE,
      @symlink_path : String? = nil,
      @checksum_url : String? = nil,
      description : String? = nil,
      continue_on_error : Bool = false,
      probe_command : String? = nil,
      condition : Condition? = nil,
    )
      super(name, description, continue_on_error, probe_command, condition)
    end

    def kind : String
      "compiled-binary"
    end

    # Keyed by install path rather than binary name: two steps may both install
    # something called `dotbot`, and the path is what actually collides.
    def items : Array(ItemRef)
      [item(@install_path, "binary", @binary_name)]
    end

    def summary : String
      "#{@binary_name} -> #{@install_path}"
    end

    # `binstaller` has no equivalent of tar's strip-components, so a delegated
    # install with a nonzero value would silently select a different member.
    # Refusing is the only honest answer.
    def delegation_refused? : Bool
      @format.delegated? && @strip_components > 0
    end
  end

  # `type: binstaller-profile` — hand binary distribution to `binstaller`.
  #
  # Fluxion deliberately does not re-declare the tool list: it points at a
  # `BinaryDistributionProfile` the user already maintains, so there is one
  # source of truth. An inline profile object is rejected because binstaller
  # owns that schema.
  class BinstallerProfileStep < Step
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

  # An inline Nerd Fonts installer configuration.
  #
  # `release` must be an exact three-component tag: `latest` would make the
  # same profile install different bytes on different days, which is the
  # opposite of what a bootstrap profile is for.
  struct NerdFontsConfig
    RELEASE_PATTERN = /\Av\d+\.\d+\.\d+\z/

    getter release : String
    getter destination : String?
    getter? refresh_font_cache : Bool
    getter families : Array(String)

    def initialize(
      @release : String,
      @families : Array(String),
      @destination : String? = nil,
      @refresh_font_cache : Bool = true,
    )
    end

    def self.pinned_release?(release : String) : Bool
      release.matches?(RELEASE_PATTERN)
    end
  end

  # `type: nerd-fonts` — install Nerd Font families via `nerd-fonts-installer`.
  #
  # Either an inline `config` Fluxion renders, or a `configPath` to an
  # installer config the user already maintains — in which case that file, not
  # Fluxion, is the trust boundary.
  class NerdFontsStep < Step
    DEFAULT_INSTALLER_VERSION = "v1.0.7"
    DEFAULT_BINARY            = "nerd-fonts-installer"

    # The project renamed its binary and release assets at v1.0.7. Pinning an
    # older release still works because Fluxion tries the current asset name
    # first and the pre-rename name second.
    LEGACY_BINARY = "nerdfont-install"

    getter installer_version : String
    getter binary : String
    getter config : NerdFontsConfig?
    getter config_path : String?

    def initialize(
      name : String,
      @config : NerdFontsConfig? = nil,
      @config_path : String? = nil,
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
      "nerd-fonts"
    end

    def items : Array(ItemRef)
      config = @config
      return [item(@name, "nerd-fonts")] unless config
      config.families.map { |family| item(family, "nerd-font") }
    end

    def summary : String
      config = @config
      return "nerd fonts from #{@config_path}" unless config
      "#{config.families.size} nerd font famil#{config.families.size == 1 ? "y" : "ies"} @ #{config.release}"
    end
  end

  # `type: dotbot` — apply dotfiles with `dotbot-go`.
  class DotbotStep < Step
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
      to_s.upcase
    end

    def to_s(io : IO) : Nil
      io << super.upcase
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
