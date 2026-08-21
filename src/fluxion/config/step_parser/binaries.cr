module Fluxion::Config
  # Downloaded-artifact kinds: compiled binaries and the delegated installers.
  module StepParser
    EXACT_RELEASE = /\Av\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?\z/

    private def exact_release(context : Context, node : Node, value : String, subject : String) : String
      return value if value.matches?(EXACT_RELEASE)
      context.error(node.path, "#{subject} must pin an exact release such as v1.2.3")
      value
    end

    # `installerVersion` is an assertion, not a choice.
    #
    # Fluxion resolves each delegated tool through `ToolBroker`, which holds
    # digests for exactly one release, so naming any other version could never
    # be honoured. It was parsed, range-checked, stored on the step and then
    # never read — a field that looked like a knob and turned nothing. Rather
    # than delete it and silently ignore what a profile already says, a
    # mismatch now names both versions.
    private def pinned_installer_version(context : Context, node : Node,
                                         pinned : String, subject : String) : String
      declared = context.optional_string(node)
      return pinned unless declared

      exact_release(context, node, declared, subject)
      return declared if declared == pinned

      context.error(node.path,
        "#{subject} #{declared} is not the release Fluxion has a verified digest for",
        "Fluxion pins #{pinned}; remove the field to use it")
      pinned
    end

    private def binstaller(context : Context, node : Node, name : String, description : String?, probe : String?) : Step?
      config_node = node["config", "configPath"]
      if config_node.mapping?
        context.error(config_node.path,
          "must be a path to a BinaryDistributionProfile, not an inline object",
          "binstaller owns that schema")
        return
      end

      config = context.local_path(config_node)
      return unless config

      locked = context.bool(node["locked"], false)
      lock_file = context.local_path(node["lockFile"], required: false)
      if locked && lock_file.nil?
        context.error(node["lockFile"].path, "is required because locked is true",
          "a lock without a lock file pins nothing")
      end

      version = pinned_installer_version(context, node["installerVersion"],
        BinstallerProfileStep::DEFAULT_INSTALLER_VERSION, "installerVersion")

      BinstallerProfileStep.new(
        name, config,
        only: node["only"].string_list,
        skip: node["skip"].string_list,
        locked: locked,
        lock_file: lock_file,
        installer_version: version,
        description: description,
        continue_on_error: context.bool(node["continueOnError"], false),
        probe_command: probe,
      )
    end

    private def nerd_fonts(context : Context, node : Node, name : String, description : String?, probe : String?) : Step?
      version = pinned_installer_version(context, node["installerVersion"],
        NerdFontsStep::DEFAULT_INSTALLER_VERSION, "installerVersion")

      # A path, never an inline object. Fluxion used to accept a font list and
      # render it into the installer's format at run time, which made Fluxion
      # the owner of a schema it does not control and cannot validate.
      config_node = node["config", "configPath"]
      if config_node.mapping?
        context.error(config_node.path,
          "must be a path to a nerd-fonts-installer config, not an inline object",
          "the installer owns that schema; move release, destination and families into that file")
        return
      end

      config = context.local_path(config_node)
      return unless config

      NerdFontsStep.new(
        name, config,
        installer_version: version,
        description: description,
        continue_on_error: context.bool(node["continueOnError"], false),
        probe_command: probe,
      )
    end

    private def dotbot(context : Context, node : Node, name : String, description : String?, probe : String?) : Step?
      config_node = node["config", "configPath"]
      if config_node.mapping?
        context.error(config_node.path, "must be a path string")
        return
      end
      config = context.local_path(config_node)
      return unless config

      version = pinned_installer_version(context, node["installerVersion"],
        DotbotStep::DEFAULT_INSTALLER_VERSION, "installerVersion")

      DotbotStep.new(
        name, config,
        installer_version: version,
        description: description,
        continue_on_error: context.bool(node["continueOnError"], false),
        probe_command: probe,
      )
    end

    private def toolchain(context : Context, node : Node, name : String, description : String?, probe : String?) : Step?
      kind_node = node["kind"]
      toolchain = ToolchainKind.from_config?(kind_node.string?)
      unless toolchain
        context.error(kind_node.path, "toolchain kind is required",
          "one of RUSTUP, JULIAUP, SDKMAN, GENERIC")
        return
      end

      url = context.https_url(node["installScriptUrl", "installScript"])
      sha256 = required_sha256(context, node, "is required",
        "installer updates are fail-closed on purpose: review the new script and update the digest")
      return unless url && sha256

      ToolchainStep.new(
        name, toolchain, url, sha256,
        install_args: node["installArgs"].string_list,
        post_install_env_source: context.optional_string(node["postInstallEnvSource"]),
        description: description,
        continue_on_error: context.bool(node["continueOnError"], true),
        probe_command: probe,
      )
    end

    # The digest for a kind that downloads one fixed artifact, complaining when
    # the field is absent.
    #
    # Both callers had this pair of statements written out, including the
    # `.missing?` half — which is there so that a digest that IS present but
    # malformed produces one complaint rather than two: `Context#sha256` has
    # already said the value is not a digest, and "is required" on top of that
    # reads as a second, different fault. That is exactly the kind of
    # non-obvious detail that goes wrong when it is copied, so it is written
    # once.
    #
    # The wording stays per-caller: each kind explains its own reason for
    # insisting, and the two happen to spell it differently — toolchain puts
    # the explanation in a hint, oh-my-zsh in the message. Folding those into
    # one phrasing would be a change to what users read, which is not what this
    # helper is for.
    private def required_sha256(context : Context, node : Node,
                                message : String, hint : String? = nil) : Checksum?
      digest = context.sha256(node["sha256"])
      if digest.nil? && node["sha256"].missing?
        context.error(node["sha256"].path, message, hint)
      end
      digest
    end

    private def oh_my_zsh(context : Context, node : Node, name : String, description : String?, probe : String?) : Step?
      revision = context.require_string(node["revision"], "revision")
      unless revision.empty? || OhMyZshStep.commit?(revision)
        context.error(node["revision"].path,
          "must be a full 40-character commit",
          "a branch or mutable tag would make the sha256 meaningless")
      end

      sha256 = required_sha256(context, node, "is required to verify the installer at that revision")
      return if revision.empty? || sha256.nil?

      install_dir = context.optional_string(node["installDir"]) || OhMyZshStep::DEFAULT_INSTALL_DIR

      OhMyZshStep.new(
        name, revision, sha256,
        install_dir: context.expand_home(install_dir),
        description: description,
        continue_on_error: context.bool(node["continueOnError"], false),
        probe_command: probe,
      )
    end
  end
end
