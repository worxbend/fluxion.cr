module Fluxion::Registry
  # Reads a synced mirror and installs configurations out of it.
  class Store
    # A profile is a hand-written file. Anything larger is either a mistake or
    # an attempt to exhaust memory before parsing starts.
    MAX_PROFILE_BYTES = 8_i64 * 1024 * 1024

    getter source : Source

    def initialize(@source : Source)
    end

    # The registry's manifest, with any diagnostics it produced.
    def manifest : {Manifest?, Array(Diagnostic)}
      path = @source.manifest_path

      unless File.exists?(path)
        return {nil, [Diagnostic.error(Manifest::FILE_NAME,
          "#{@source.name} has no #{Manifest::FILE_NAME} at its root",
          "a registry must publish one; run `fluxion registry sync` if it is out of date")]}
      end

      Manifest.parse(File.read(path), "#{@source.name}/#{Manifest::FILE_NAME}")
    end

    # The manifest, raising if it is unusable. For commands that cannot proceed
    # without it.
    def manifest! : Manifest
      parsed, diagnostics = manifest
      return parsed if parsed

      raise ValidationError.new(diagnostics)
    end

    # Where an entry's profile sits inside the mirror.
    #
    # Re-checks confinement against the *resolved* path rather than trusting
    # the manifest's own validation: a symlink inside the repository could
    # otherwise point anywhere, and the manifest cannot see that.
    def source_path(entry : Entry) : String
      candidate = File.join(@source.mirror_path, entry.path)

      unless File.exists?(candidate)
        raise ExecutionError.new(
          "#{@source.name} lists '#{entry.id}' at #{entry.path}, but that file is not in the registry")
      end

      root = File.realpath(@source.mirror_path)
      resolved = File.realpath(candidate)
      unless resolved == root || resolved.starts_with?("#{root}#{File::SEPARATOR}")
        raise TrustError.new(
          "'#{entry.id}' resolves outside the registry (#{entry.path}); refusing to read it")
      end

      info = File.info(resolved, follow_symlinks: false)
      unless info.file?
        raise TrustError.new("'#{entry.id}' is not a regular file")
      end
      if info.size > MAX_PROFILE_BYTES
        raise TrustError.new("'#{entry.id}' is larger than #{MAX_PROFILE_BYTES} bytes")
      end

      resolved
    end

    # Where an installed entry lives.
    def installed_path(entry : Entry) : String
      File.join(@source.install_path, "#{entry.id}.yaml")
    end

    def installed?(entry : Entry) : Bool
      File.exists?(installed_path(entry))
    end

    # Every id currently installed from this registry.
    def installed_ids : Array(String)
      directory = @source.install_path
      return [] of String unless Dir.exists?(directory)

      Dir.children(directory).compact_map do |name|
        next unless name.ends_with?(".yaml")
        name.chomp(".yaml")
      end.sort!
    end

    enum Drift
      # Installed and byte-identical to the registry.
      Current
      # Installed, and the registry has changed since.
      Upstream
      # Installed and edited locally.
      Local
      # Installed, edited locally, *and* changed upstream.
      Both
      # Not installed.
      Absent

      # Whether the installed copy has been changed since it was installed.
      #
      # Named rather than left as `local? || both?` at each call site: three
      # commands ask this question, and spelling it as a pair of enum tests
      # made adding `Both` a hunt for every place that had only asked about
      # `Local`.
      def locally_edited? : Bool
        local? || both?
      end

      # Whether the registry's copy has moved on since it was installed.
      def upstream_changed? : Bool
        upstream? || both?
      end
    end

    # How an installed copy compares to the registry.
    #
    # The record of what was installed is kept beside the file, so a local edit
    # is distinguishable from an upstream change. Without it the two look
    # identical — the bytes differ — and `sync` could not tell the user which
    # of their changes it was about to discard.
    def drift(entry : Entry) : Drift
      return Drift::Absent unless installed?(entry)

      installed = File.read(installed_path(entry))
      upstream = File.read(source_path(entry))
      recorded = recorded_digest(entry)

      edited = recorded ? digest(installed) != recorded : false
      moved = recorded ? digest(upstream) != recorded : digest(installed) != digest(upstream)

      case {edited, moved}
      when {false, false} then Drift::Current
      when {false, true}  then Drift::Upstream
      when {true, false}  then Drift::Local
      else                     Drift::Both
      end
    end

    # Installs an entry, validating it first.
    #
    # A registry describes what to install on a machine, so a profile that
    # cannot even be parsed is refused here rather than at the first `apply`.
    # Nothing is ever applied as a side effect of installing.
    def install(entry : Entry, force : Bool = false) : String
      destination = installed_path(entry)

      if File.exists?(destination) && !force
        state = drift(entry)
        return destination if state.current?
        if state.locally_edited?
          raise ExecutionError.new(
            "#{destination} has local edits. Pass --force to overwrite them, " \
            "or `fluxion registry publish` to send them upstream.")
        end
      end

      body = File.read(source_path(entry))
      validate!(entry, body)

      Dir.mkdir_p(@source.install_path, 0o700)
      write_atomically(destination, body)
      record_digest(entry, digest(body))

      destination
    end

    # Copies an installed file back into the mirror, ready to publish.
    def stage(entry : Entry) : Nil
      unless installed?(entry)
        raise ExecutionError.new("'#{entry.id}' is not installed, so there is nothing to publish")
      end

      body = File.read(installed_path(entry))
      validate!(entry, body)

      target = File.join(@source.mirror_path, entry.path)
      Dir.mkdir_p(File.dirname(target))
      write_atomically(target, body)
    end

    # Removes an installed entry.
    def uninstall(entry : Entry) : Bool
      path = installed_path(entry)
      return false unless File.exists?(path)

      File.delete(path)
      File.delete(digest_path(entry)) rescue nil
      true
    end

    # Parses the profile to prove it is usable, discarding the result.
    private def validate!(entry : Entry, body : String) : Nil
      directory = File.tempname("fluxion-registry")
      Dir.mkdir_p(directory)
      begin
        path = File.join(directory, "#{entry.id}.yaml")
        File.write(path, body)
        Config::Loader.load(path, Host.facts)
      rescue error : ValidationError
        raise ExecutionError.new(
          "'#{entry.id}' is not a valid profile, so it was not installed:\n#{error.message}")
      rescue error : ConfigError
        raise ExecutionError.new("'#{entry.id}' could not be read: #{error.message}")
      ensure
        FileUtils.rm_rf(directory) rescue nil
      end
    end

    # The digest of what was installed, kept in a sibling directory so it never
    # appears among the profiles a user browses.
    private def digest_path(entry : Entry) : String
      File.join(@source.install_path, ".fluxion", "#{entry.id}.sha256")
    end

    private def recorded_digest(entry : Entry) : String?
      path = digest_path(entry)
      return unless File.exists?(path)
      File.read(path).strip.presence
    end

    private def record_digest(entry : Entry, value : String) : Nil
      path = digest_path(entry)
      Dir.mkdir_p(File.dirname(path), 0o700)
      File.write(path, value + "\n")
    end

    private def digest(body : String) : String
      Digest::SHA256.hexdigest(body)
    end

    private def write_atomically(path : String, body : String) : Nil
      temporary = "#{path}.#{Random::Secure.hex(6)}.tmp"
      begin
        File.write(temporary, body)
        File.rename(temporary, path)
      rescue error
        File.delete(temporary) rescue nil
        raise ExecutionError.new("Failed to write #{path}: #{error.message}")
      end
    end
  end
end
