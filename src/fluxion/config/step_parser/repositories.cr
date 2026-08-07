module Fluxion::Config
  # Repository, remote, and signing-key kinds.
  #
  # These share one trust contract: every source URI must be HTTPS without
  # user-info, and a declared remote key must come with a digest over its exact
  # response bytes. A key URL without a checksum means "trust whatever this
  # host serves today to decide what my machine installs as root", which is the
  # decision the typed kinds exist to avoid.
  module StepParser
    # Options an APT source line may carry. Anything else — notably `trusted`
    # and `allow-insecure` — is a trust bypass and is rejected rather than
    # passed through.
    APT_SOURCE_OPTIONS = %w[arch signed-by]

    private def signing_key(context : Context, url_node : Node, checksum_node : Node, subject : String) : SigningKey?
      has_url = url_node.present?
      has_checksum = checksum_node.present?

      if has_url != has_checksum
        context.error(
          has_url ? checksum_node.path : url_node.path,
          "#{subject} signing-key URL and SHA-256 checksum must be configured together",
          "the digest is what makes the key trustworthy; the URL alone is not",
        )
        return
      end
      return unless has_url

      url = context.https_url(url_node)
      checksum = context.checksum(checksum_node)
      return unless url && checksum
      SigningKey.new(url, checksum)
    end

    private def apt_repository(context : Context, node : Node, name : String, description : String?, probe : String?) : Step?
      source_node = node["source"]
      source = context.require_string(source_node, "source")
      validate_apt_source(context, source_node, source) unless source.empty?

      source_list = context.absolute_path(node["sourceList"], required: false) ||
                    AptRepositoryStep.default_source_list(name)
      unless File.dirname(source_list) == AptRepositoryStep::SOURCES_DIRECTORY && source_list.ends_with?(".list")
        context.error(node["sourceList"].path,
          "must be a direct .list file in #{AptRepositoryStep::SOURCES_DIRECTORY}")
      end

      key = signing_key(context, node["signingKeyUrl"], node["checksum"], "APT")
      keyring = context.absolute_path(node["keyring"], required: false)
      keyring ||= AptRepositoryStep.default_keyring(name) if key

      if keyring && !AptRepositoryStep::KEYRING_DIRECTORIES.includes?(File.dirname(keyring))
        context.error(node["keyring"].path,
          "must be directly under #{AptRepositoryStep::KEYRING_DIRECTORIES.join(" or ")}")
      end
      if keyring && !(keyring.ends_with?(".gpg") || keyring.ends_with?(".asc"))
        context.error(node["keyring"].path, "must use one of these extensions: .gpg, .asc")
      end

      if key && keyring
        # The `signed-by` option is what apt actually enforces. If it disagrees
        # with the configured keyring the profile documents one trust root and
        # installs another.
        declared = apt_option(source, "signed-by")
        if declared && declared != keyring
          context.error(source_node.path,
            "signed-by option must match the configured keyring path",
            "source says #{declared}, keyring is #{keyring}")
        end
      end

      AptRepositoryStep.new(
        name, source, source_list, key, keyring,
        description: description,
        continue_on_error: context.bool(node["continueOnError"], false),
        probe_command: probe,
      )
    end

    private def validate_apt_source(context : Context, node : Node, source : String) : Nil
      if source.includes?('\n') || source.includes?('\r')
        context.error(node.path, "must be a single line")
        return
      end

      tokens = source.strip.split(/\s+/)
      unless %w[deb deb-src].includes?(tokens.first?)
        context.error(node.path, "must start with deb or deb-src")
        return
      end

      if source.includes?('[')
        close = source.index(']')
        unless close
          context.error(node.path, "has unterminated options")
          return
        end
        open = source.index!('[')
        options = source[(open + 1)...close].strip
        if options.empty?
          context.error(node.path, "options must not be empty")
        else
          seen = Set(String).new
          options.split(/\s+/).each do |option|
            key, _, value = option.partition('=')
            if value.empty?
              context.error(node.path, "option must use name=value syntax")
              next
            end
            key = key.downcase
            unless APT_SOURCE_OPTIONS.includes?(key)
              context.error(node.path, "option is not allowed: #{key}",
                "only #{APT_SOURCE_OPTIONS.join(" and ")} are accepted")
              next
            end
            context.error(node.path, "option must not be repeated: #{key}") unless seen.add?(key)
          end
        end
      end

      # The repository URI is the part that decides what gets installed, so it
      # gets the same transport rules as any other source URL.
      uri = tokens.find(&.includes?("://"))
      if uri.nil?
        context.error(node.path, "must contain a repository URL")
      elsif !uri.starts_with?("https://")
        context.error(node.path, "repository URL must use https")
      elsif uri.includes?('@')
        context.error(node.path, "repository URL must not include user-info")
      end
    end

    private def apt_option(source : String, name : String) : String?
      open = source.index('[')
      close = source.index(']')
      return unless open && close && close > open
      source[(open + 1)...close].split(/\s+/).each do |option|
        key, _, value = option.partition('=')
        return value if key.downcase == name && !value.empty?
      end
      nil
    end

    private def rpm_repository(context : Context, node : Node, name : String, description : String?, probe : String?) : Step?
      id = context.optional_string(node["id"]) || name
      validate_repository_id(context, node["id"], id)

      base_url = context.https_url(node["baseUrl"]) || ""
      repo_file = context.absolute_path(node["repoFile"], required: false) ||
                  RpmRepositoryStep.default_repo_file(name)
      validate_repo_file(context, node["repoFile"], repo_file, RpmRepositoryStep::REPO_DIRECTORY)

      enabled = context.bool(node["enabled"], true)
      gpg_check = context.bool(node["gpgCheck"], true)
      key = signing_key(context, node["gpgKeyUrl"], node["checksum"], "RPM")

      if gpg_check && key.nil?
        context.error(node["gpgKeyUrl"].path, "gpgCheck requires a signing-key URL")
      end
      if enabled && !gpg_check
        context.error(node["gpgCheck"].path, "enabled repositories must enforce gpgCheck")
      end

      RpmRepositoryStep.new(
        name, id, base_url, repo_file, key,
        enabled: enabled, gpg_check: gpg_check,
        description: description,
        continue_on_error: context.bool(node["continueOnError"], false),
        probe_command: probe,
      )
    end

    private def zypper_repository(context : Context, node : Node, name : String, description : String?, probe : String?) : Step?
      id = context.optional_string(node["id"]) || name
      validate_repository_id(context, node["id"], id)

      base_url = context.https_url(node["baseUrl"]) || ""
      repo_file = context.absolute_path(node["repoFile"], required: false) ||
                  ZypperRepositoryStep.default_repo_file(name)
      validate_repo_file(context, node["repoFile"], repo_file, ZypperRepositoryStep::REPO_DIRECTORY)

      enabled = context.bool(node["enabled"], true)
      gpg_check = context.bool(node["gpgCheck"], true)
      key = signing_key(context, node["gpgKeyUrl"], node["checksum"], "Zypper")

      if gpg_check && key.nil?
        context.error(node["gpgKeyUrl"].path, "gpgCheck requires a signing-key URL")
      end
      if enabled && !gpg_check
        context.error(node["gpgCheck"].path, "enabled repositories must enforce gpgCheck")
      end

      ZypperRepositoryStep.new(
        name, id, base_url, repo_file, key,
        enabled: enabled, gpg_check: gpg_check,
        auto_refresh: context.bool(node["autoRefresh"], true),
        description: description,
        continue_on_error: context.bool(node["continueOnError"], false),
        probe_command: probe,
      )
    end

    private def pacman_repository(context : Context, node : Node, name : String, description : String?, probe : String?) : Step?
      repository = context.optional_string(node["repository"]) || name
      validate_repository_id(context, node["repository"], repository)

      server = context.https_url(node["server"], required: false)
      config = context.absolute_path(node["config"], required: false) || PacmanRepositoryStep::DEFAULT_CONFIG
      unless config == PacmanRepositoryStep::DEFAULT_CONFIG
        context.error(node["config"].path, "must be #{PacmanRepositoryStep::DEFAULT_CONFIG}")
      end

      include_path = context.absolute_path(node["include"], required: false)
      if include_path && File.dirname(include_path) != PacmanRepositoryStep::INCLUDE_DIRECTORY
        context.error(node["include"].path,
          "must be directly under #{PacmanRepositoryStep::INCLUDE_DIRECTORY}")
      end

      enabled = context.bool(node["enabled"], true)
      sig_level = context.optional_string(node["sigLevel"])
      validate_sig_level(context, node["sigLevel"], sig_level, enabled)

      PacmanRepositoryStep.new(
        name, repository, server, config, sig_level, include_path,
        enabled: enabled,
        description: description,
        continue_on_error: context.bool(node["continueOnError"], false),
        probe_command: probe,
      )
    end

    # Pacman's SigLevel is a fold, not a set: later tokens override earlier
    # ones, and `Package`/`Database` prefixes scope an override to one side.
    # An enabled repository has to end up requiring signed, trusted packages
    # *and* databases, so both sides are tracked independently.
    private def validate_sig_level(context : Context, node : Node, sig_level : String?, enabled : Bool) : Nil
      unless sig_level
        if enabled
          context.error(node.path, "enabled repositories must declare a signed and trusted SigLevel",
            "for example: Required TrustedOnly")
        end
        return
      end

      tokens = sig_level.split(/\s+/).reject(&.empty?)
      unknown = tokens.reject { |token| PacmanRepositoryStep::SIG_LEVEL_TOKENS.includes?(token) }
      unless unknown.empty?
        context.error(node.path, "contains unsupported SigLevel tokens: #{unknown.join(", ")}")
        return
      end
      return unless enabled

      package = {required: false, trusted: false}
      database = {required: false, trusted: false}

      tokens.each do |token|
        scope, setting = if token.starts_with?("Package")
                           {:package, token.lchop("Package")}
                         elsif token.starts_with?("Database")
                           {:database, token.lchop("Database")}
                         else
                           {:both, token}
                         end

        apply = ->(state : NamedTuple(required: Bool, trusted: Bool)) do
          case setting
          when "Never", "Optional" then {required: false, trusted: state[:trusted]}
          when "Required"          then {required: true, trusted: state[:trusted]}
          when "TrustAll"          then {required: state[:required], trusted: false}
          when "TrustedOnly"       then {required: state[:required], trusted: true}
          else                          state
          end
        end

        package = apply.call(package) unless scope == :database
        database = apply.call(database) unless scope == :package
      end

      unless package[:required] && package[:trusted] && database[:required] && database[:trusted]
        context.error(node.path,
          "enabled repositories must require signed, trusted packages and databases",
          "'Required TrustedOnly' satisfies both")
      end
    end

    private def flatpak_remote(context : Context, node : Node, name : String, description : String?, probe : String?) : Step?
      remote = context.require_string(node["remote"], "remote")
      url = context.https_url(node["url"])

      # The descriptor is the only artifact here, and it is what tells Flatpak
      # which keys to trust — so unlike the other kinds its checksum is not
      # optional.
      checksum = context.checksum(node["checksum"])
      if checksum.nil? && node["checksum"].missing?
        context.error(node["checksum"].path, "is required for the Flatpak repository descriptor")
      end
      return unless url && checksum

      FlatpakRemoteStep.new(
        name, remote, url, checksum,
        system: context.bool(node["system"], true),
        description: description,
        continue_on_error: context.bool(node["continueOnError"], false),
        probe_command: probe,
      )
    end

    private def gpg_key(context : Context, node : Node, name : String, description : String?, probe : String?) : Step?
      keys_node = node["keys"]
      keys = keys_node.items.compact_map { |entry| gpg_key_entry(context, entry) }

      if keys.empty?
        context.error(keys_node.path, "requires at least one key")
        return
      end
      report_duplicates(context, keys_node.path, keys.map(&.item_key), "key")

      GpgKeyStep.new(
        name, keys,
        description: description,
        continue_on_error: context.bool(node["continueOnError"], false),
        probe_command: probe,
      )
    end

    private def gpg_key_entry(context : Context, entry : Node) : GpgKeyEntry?
      url_node = entry["url"]
      raw_url = context.require_string(url_node, "url")
      return if raw_url.empty?

      # A `file:` source is an operator-controlled local key, which is inside
      # the trust boundary already; anything remote must be HTTPS.
      url = if raw_url.starts_with?("file:")
              raw_url
            else
              context.https_url(url_node)
            end
      return unless url

      fingerprint = context.fingerprint(entry["fingerprint"])
      if fingerprint.nil?
        context.error(entry["fingerprint"].path,
          "a full OpenPGP fingerprint is required",
          "importing a key decides what the machine will install as root")
        return
      end

      keyring = context.absolute_path(entry["keyring"], required: false)
      GpgKeyEntry.new(url, fingerprint, keyring)
    end

    REPOSITORY_ID = /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/

    private def validate_repository_id(context : Context, node : Node, id : String) : Nil
      return if id.matches?(REPOSITORY_ID)
      context.error(node.path,
        "must start with an alphanumeric character and contain only letters, digits, '.', '_', or '-'")
    end

    private def validate_repo_file(context : Context, node : Node, path : String, directory : String) : Nil
      return if File.dirname(path) == directory && path.ends_with?(".repo")
      context.error(node.path, "must be a direct .repo file in #{directory}")
    end
  end
end
