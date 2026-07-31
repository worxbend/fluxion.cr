module Fluxion::Config
  # Downloaded-artifact kinds: compiled binaries and the delegated installers.
  module StepParser
    private def compiled_binary(context, node, name, description, probe) : Step?
      binary_name = context.require_string(node["binaryName"], "binaryName")
      if binary_name.includes?('/') || binary_name.includes?('\\') || binary_name == "." || binary_name == ".."
        context.error(node["binaryName"].path, "must be a file name, not a path")
      end

      url = context.https_url(node["url"])
      install_path = context.absolute_path(node["installPath"])
      trust = compiled_binary_trust(context, node)
      return unless url && install_path && trust

      format = ArtifactFormat.detect(url)
      archive_path = context.archive_path(node["archivePath"])
      if format.archive? && archive_path.nil?
        context.error(node["archivePath"].path,
          "is required for archive downloads",
          "an exact member path; Fluxion never guesses by basename")
      end

      strip_components = context.int(node["stripComponents"], 0)
      if strip_components < 0
        context.error(node["stripComponents"].path, "must not be negative")
        strip_components = 0
      end

      symlink_path = context.absolute_path(node["symlinkPath", "symlink"], required: false)
      if symlink_path
        if symlink_path == install_path
          context.error(node["symlinkPath"].path, "must differ from install path")
        elsif symlink_path.starts_with?(install_path + "/") || install_path.starts_with?(symlink_path + "/")
          context.error(node["symlinkPath"].path, "install path and symlink path must not contain one another")
        end
      end

      step = CompiledBinaryStep.new(
        name, binary_name, url, trust, install_path, format,
        archive_path: archive_path,
        strip_components: strip_components,
        mode: context.file_mode(node["mode", "installMode"]) || CompiledBinaryStep::DEFAULT_MODE,
        symlink_path: symlink_path,
        checksum_url: context.https_url(node["checksumUrl"], required: false),
        description: description,
        continue_on_error: context.bool(node["continueOnError"], false),
        probe_command: probe,
      )

      if step.delegation_refused?
        context.error(node["stripComponents"].path,
          "#{format} archives are installed by binstaller, which has no stripComponents equivalent",
          "flatten the archivePath instead")
      end

      step
    end

    # Establishes how the artifact earns the right to be executed.
    #
    # `checksumUrl` is deliberately not sufficient on its own: it is served by
    # the same host as the artifact, so an attacker who can replace one can
    # replace both. It is supplemental metadata that must accompany a
    # signer-bound signature.
    private def compiled_binary_trust(context : Context, node : Node) : TrustAnchor?
      checksum = context.checksum(node["checksum"])
      signature_url = context.https_url(node["signatureUrl"], required: false)
      signer = context.fingerprint(node["allowedSignerFingerprint"])

      has_signature = node["signatureUrl"].present?
      has_signer = node["allowedSignerFingerprint"].present?

      if node["checksum"].present? && node["checksumUrl"].present?
        context.error(node["checksumUrl"].path,
          "declare either checksum or checksumUrl, not both")
      end

      if has_signature != has_signer
        context.error(
          has_signature ? node["allowedSignerFingerprint"].path : node["signatureUrl"].path,
          "signatureUrl and allowedSignerFingerprint must be configured together",
          "a valid signature from an unknown key is not trust",
        )
        return
      end

      return TrustAnchor::Digest.new(checksum) if checksum
      if signature_url && signer
        return TrustAnchor::Signature.new(signature_url, signer)
      end

      context.error(node.path,
        "must declare a literal SHA-256 checksum or a detached signature with allowedSignerFingerprint",
        "checksumUrl is supplemental metadata and never establishes trust by itself")
      nil
    end

    EXACT_RELEASE = /\Av\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?\z/

    private def exact_release(context : Context, node : Node, value : String, subject : String) : String
      return value if value.matches?(EXACT_RELEASE)
      context.error(node.path, "#{subject} must pin an exact release such as v1.2.3")
      value
    end

    private def binstaller(context, node, name, description, probe) : Step?
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

      version = context.optional_string(node["installerVersion"]) ||
                BinstallerProfileStep::DEFAULT_INSTALLER_VERSION
      exact_release(context, node["installerVersion"], version, "installerVersion")

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

    private def nerd_fonts(context, node, name, description, probe) : Step?
      version = context.optional_string(node["installerVersion"]) ||
                NerdFontsStep::DEFAULT_INSTALLER_VERSION
      exact_release(context, node["installerVersion"], version, "installerVersion")
      binary = context.optional_string(node["nerdfontBinary"]) || NerdFontsStep::DEFAULT_BINARY

      config_node = node["config"]
      config_path = context.local_path(node["configPath"], required: false)

      # A textual `config` names an installer config the user maintains; an
      # object is one Fluxion renders. Either is fine, but not both shapes at
      # once for the same field.
      if config_node.scalar?
        config_path ||= context.resolve_local(config_node.string?.not_nil!)
        config_node = Node.new(nil, config_node.path)
      end

      config = nil.as(NerdFontsConfig?)
      if config_node.present?
        release = context.require_string(config_node["release"], "release")
        unless release.empty? || NerdFontsConfig.pinned_release?(release)
          context.error(config_node["release"].path,
            "must pin an exact release such as v3.4.0",
            "a mutable selector would install different bytes on different days")
        end

        families_node = config_node["families"]
        families = families_node.string_list
        context.error(families_node.path, "must contain at least one font family") if families.empty?

        config = NerdFontsConfig.new(
          release, families,
          destination: context.optional_string(config_node["destination"]).try { |dest| context.expand_home(dest) },
          refresh_font_cache: context.bool(config_node["refreshFontCache", "refresh_font_cache"], true),
        )
      elsif config_path.nil?
        context.error(node["config"].path, "either config or configPath is required")
        return
      end

      NerdFontsStep.new(
        name,
        config: config,
        config_path: config_path,
        installer_version: version,
        binary: binary,
        description: description,
        continue_on_error: context.bool(node["continueOnError"], false),
        probe_command: probe,
      )
    end

    private def dotbot(context, node, name, description, probe) : Step?
      config_node = node["config", "configPath"]
      if config_node.mapping?
        context.error(config_node.path, "must be a path string")
        return
      end
      config = context.local_path(config_node)
      return unless config

      version = context.optional_string(node["installerVersion"]) || DotbotStep::DEFAULT_INSTALLER_VERSION
      exact_release(context, node["installerVersion"], version, "installerVersion")

      DotbotStep.new(
        name, config,
        installer_version: version,
        binary: context.optional_string(node["dotbotBinary"]) || DotbotStep::DEFAULT_BINARY,
        description: description,
        continue_on_error: context.bool(node["continueOnError"], false),
        probe_command: probe,
      )
    end

    private def toolchain(context, node, name, description, probe) : Step?
      kind_node = node["kind"]
      toolchain = ToolchainKind.from_config?(kind_node.string?)
      unless toolchain
        context.error(kind_node.path, "toolchain kind is required",
          "one of RUSTUP, JULIAUP, SDKMAN, GENERIC")
        return
      end

      url = context.https_url(node["installScriptUrl", "installScript"])
      sha256 = context.sha256(node["sha256"])
      if sha256.nil? && node["sha256"].missing?
        context.error(node["sha256"].path,
          "is required",
          "installer updates are fail-closed on purpose: review the new script and update the digest")
      end
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

    private def oh_my_zsh(context, node, name, description, probe) : Step?
      revision = context.require_string(node["revision"], "revision")
      unless revision.empty? || OhMyZshStep.commit?(revision)
        context.error(node["revision"].path,
          "must be a full 40-character commit",
          "a branch or mutable tag would make the sha256 meaningless")
      end

      sha256 = context.sha256(node["sha256"])
      if sha256.nil? && node["sha256"].missing?
        context.error(node["sha256"].path, "is required to verify the installer at that revision")
      end
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
