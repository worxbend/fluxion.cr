module Fluxion::Executor
  # Repository and signing-key kinds.
  #
  # These decide what the machine will install as root, so they share one
  # sequence: fetch the key unprivileged, verify it unprivileged, and only then
  # cross the privilege boundary with a file that has already been checked.
  # Nothing here passes a remote URL to a privileged tool and lets it fetch.
  module RepositorySupport
    include DownloadSupport

    KEY_TIMEOUT     = 2.minutes
    REFRESH_TIMEOUT = 10.minutes

    # Downloads and verifies a signing key, returning its local path.
    protected def fetch_key(key : SigningKey, workspace : String) : String
      path = File.join(workspace, "signing.key")
      downloader(Downloader::MAX_KEY_BYTES).download_verified(key.url, path, key.checksum)
      path
    end

    # Where a verified key is installed so a repository file can point at a
    # local path rather than a URL the package manager would refetch.
    protected def installed_key_path(directory : String, id : String) : String
      File.join(directory, "fluxion-#{id.gsub(/[^A-Za-z0-9._-]/, "_")}.key")
    end

    protected def refresh(runner : ShellRunner, argv : Array(String), sink : Proc(String, Nil)) : ProcessResult
      runner.run(Command.new(argv, timeout: REFRESH_TIMEOUT)) { |line| sink.call(line) }
    end
  end

  # `apt-repository` — a Debian/Ubuntu source with its keyring.
  class AptRepositoryExecutor < StepExecutor
    include RepositorySupport

    def supports?(step : Step) : Bool
      step.is_a?(AptRepositoryStep)
    end

    def commands(step : Step, item : StepItem) : Array(Command)
      repository = step.as(AptRepositoryStep)
      preview = [] of String
      repository.signing_key.try do |key|
        preview.concat(["download", PublicUrl.from(key.url), "verify", key.checksum.value,
                        "dearmor", "->", repository.keyring || "<keyring>"])
      end
      preview.concat(["write", repository.source_list, "then", "apt-get", "update"])
      [Command.new(preview)]
    end

    def execute(step : Step, item : StepItem, runner : ShellRunner, &sink : String ->) : StepResult
      repository = step.as(AptRepositoryStep)
      started = Time.instant
      installer = Installer.new(runner)

      with_workspace do |workspace|
        if key = repository.signing_key
          keyring = repository.keyring
          unless keyring
            return StepResult::Failure.new(item.key, "a signing key requires a keyring path", 1)
          end

          sink.call("fetching signing key")
          source = fetch_key(key, workspace)

          # Dearmoring happens unprivileged, on a file already verified, so the
          # privileged step only ever moves bytes Fluxion has checked.
          dearmored = File.join(workspace, "keyring.gpg")
          result = runner.run(Command.new(["gpg", "--batch", "--yes", "--dearmor",
                                           "--output", dearmored, source], timeout: KEY_TIMEOUT))
          unless result.success?
            return StepResult::Failure.new(item.key,
              "could not dearmor the signing key: #{result.detail}", result.exit_code)
          end

          installer.install(dearmored, keyring, "0644",
            Digest::SHA256.hexdigest(File.read(dearmored)))
        end

        installer.write(repository.source + "\n", repository.source_list, "0644")

        sink.call("refreshing apt metadata")
        result = refresh(runner, ["sudo", "apt-get", "update"], ->(line : String) { sink.call(line) })
        outcome(item, result, started, "apt-get update")
      end
    rescue error : Error
      StepResult::Failure.new(item.key, error.message || error.class.name, 1)
    end
  end

  # `rpm-repository` and `zypper-repository`.
  #
  # One executor for both: the generated file differs only by the repo
  # directory, the `autorefresh` key, and which command refreshes metadata.
  class RpmStyleRepositoryExecutor < StepExecutor
    include RepositorySupport

    RPM_KEY_DIRECTORY    = "/etc/pki/rpm-gpg"
    ZYPPER_KEY_DIRECTORY = "/etc/zypp/keys"

    def supports?(step : Step) : Bool
      step.is_a?(RpmStyleRepository)
    end

    def commands(step : Step, item : StepItem) : Array(Command)
      repository = repository(step)
      preview = [] of String
      repository.signing_key.try do |key|
        preview.concat(["download", PublicUrl.from(key.url), "verify", key.checksum.value])
      end
      preview.concat(["write", repository.repo_file, "then"] + refresh_argv(step))
      [Command.new(preview)]
    end

    def execute(step : Step, item : StepItem, runner : ShellRunner, &sink : String ->) : StepResult
      repository = repository(step)
      started = Time.instant
      installer = Installer.new(runner)

      with_workspace do |workspace|
        key_path = nil.as(String?)

        if key = repository.signing_key
          sink.call("fetching signing key")
          source = fetch_key(key, workspace)
          key_path = installed_key_path(key_directory(step), repository.id)
          installer.install(source, key_path, "0644", Digest::SHA256.hexdigest(File.read(source)))
        end

        installer.write(render(step, key_path), repository.repo_file, "0644")

        sink.call("refreshing repository metadata")
        result = refresh(runner, refresh_argv(step), ->(line : String) { sink.call(line) })
        outcome(item, result, started, "metadata refresh")
      end
    rescue error : Error
      StepResult::Failure.new(item.key, error.message || error.class.name, 1)
    end

    # The generated file points at the *installed local* key, never the remote
    # URL: the package manager must not be able to refetch something Fluxion
    # has not verified.
    private def render(step : Step, key_path : String?) : String
      repository = repository(step)
      String.build do |io|
        io << '[' << repository.id << "]\n"
        io << "name=" << repository.id << '\n'
        io << "baseurl=" << repository.base_url << '\n'
        io << "enabled=" << (repository.enabled? ? 1 : 0) << '\n'
        # The one field only one of the two kinds has, so it keeps its own test.
        io << "autorefresh=" << (step.auto_refresh? ? 1 : 0) << '\n' if step.is_a?(ZypperRepositoryStep)
        io << "gpgcheck=" << (repository.gpg_check? ? 1 : 0) << '\n'
        io << "gpgkey=file://" << key_path << '\n' if key_path
      end
    end

    # One narrowing, where six per-field type tests used to be. Their safety
    # rested entirely on `supports?` admitting exactly two classes: adding a
    # third rpm-style kind there — the obvious way to reuse this executor —
    # would have made every `.as(ZypperRepositoryStep)` a crash.
    private def repository(step : Step) : RpmStyleRepository
      step.as(RpmStyleRepository)
    end

    # These two stay per-kind: they are the differences this executor exists to
    # absorb, not shared fields read through a type test.
    private def key_directory(step : Step) : String
      step.is_a?(RpmRepositoryStep) ? RPM_KEY_DIRECTORY : ZYPPER_KEY_DIRECTORY
    end

    private def refresh_argv(step : Step) : Array(String)
      step.is_a?(RpmRepositoryStep) ? ["sudo", "dnf", "makecache", "--refresh"] : ["sudo", "zypper", "refresh"]
    end
  end

  # `pacman-repository` — a section inside the shared /etc/pacman.conf.
  #
  # Unlike the other three this edits a file it does not own, so the whole
  # replacement is staged and installed atomically rather than appended in
  # place: a partial append would leave pacman with a malformed config.
  class PacmanRepositoryExecutor < StepExecutor
    include RepositorySupport

    MAX_CONFIG_BYTES = 4 * 1024 * 1024

    def supports?(step : Step) : Bool
      step.is_a?(PacmanRepositoryStep)
    end

    def commands(step : Step, item : StepItem) : Array(Command)
      repository = step.as(PacmanRepositoryStep)
      [Command.new(["append", "[#{repository.repository}]", "to", repository.config,
                    "then", "sudo", "pacman", "-Sy"])]
    end

    def execute(step : Step, item : StepItem, runner : ShellRunner, &sink : String ->) : StepResult
      repository = step.as(PacmanRepositoryStep)
      started = Time.instant

      present = runner.run(Command.new(
        ["grep", "-Fqx", "--", "[#{repository.repository}]", repository.config],
        timeout: 30.seconds))

      unless {0, 1}.includes?(present.exit_code)
        return StepResult::Failure.new(item.key,
          "could not read #{repository.config}: #{present.detail}", present.exit_code)
      end

      if present.exit_code == 1
        current = read_config(repository.config)
        separator = current.empty? || current.ends_with?('\n') ? "" : "\n"
        Installer.new(runner).write(current + separator + block(repository), repository.config, "0644")
      end

      sink.call("synchronising pacman databases")
      result = refresh(runner, ["sudo", "pacman", "-Sy"], ->(line : String) { sink.call(line) })
      outcome(item, result, started, "pacman -Sy")
    rescue error : Error
      StepResult::Failure.new(item.key, error.message || error.class.name, 1)
    end

    private def read_config(path : String) : String
      info = File.info?(path)
      return "" unless info && info.file?
      if info.size > MAX_CONFIG_BYTES
        raise ExecutionError.new("#{path} is larger than #{MAX_CONFIG_BYTES} bytes; refusing to rewrite it")
      end
      File.read(path)
    end

    private def block(step : PacmanRepositoryStep) : String
      # A disabled repository is written commented out rather than omitted, so
      # the profile's intent stays visible in the file.
      prefix = step.enabled? ? "" : "# "
      String.build do |io|
        io << "\n[" << step.repository << "]\n"
        step.server.try { |server| io << prefix << "Server = " << server << '\n' }
        step.sig_level.try { |level| io << prefix << "SigLevel = " << level << '\n' }
        step.include_path.try { |path| io << prefix << "Include = " << path << '\n' }
      end
    end
  end

  # `flatpak-remote` — add a remote from a verified descriptor.
  class FlatpakRemoteExecutor < StepExecutor
    include RepositorySupport

    def supports?(step : Step) : Bool
      step.is_a?(FlatpakRemoteStep)
    end

    def commands(step : Step, item : StepItem) : Array(Command)
      remote = step.as(FlatpakRemoteStep)
      preview = ["download", PublicUrl.from(remote.url), "verify", remote.checksum.value,
                 "then", "flatpak"]
      preview << "--user" unless remote.system?
      preview.concat(["remote-add", "--if-not-exists", remote.remote, "<verified descriptor>"])
      [Command.new(preview)]
    end

    def execute(step : Step, item : StepItem, runner : ShellRunner, &sink : String ->) : StepResult
      remote = step.as(FlatpakRemoteStep)
      started = Time.instant

      with_workspace do |workspace|
        descriptor = File.join(workspace, "remote.flatpakrepo")
        sink.call("fetching #{PublicUrl.from(remote.url)}")
        downloader(Downloader::MAX_KEY_BYTES).download_verified(remote.url, descriptor, remote.checksum)

        # The verified local path is handed to flatpak, never the URL — so
        # flatpak cannot fetch a different document than the one checked.
        argv = ["flatpak"]
        argv << "--user" unless remote.system?
        argv.concat(["remote-add", "--if-not-exists", remote.remote, descriptor])

        result = runner.run(Command.new(argv, timeout: 5.minutes)) { |line| sink.call(line) }
        outcome(item, result, started, "flatpak remote-add")
      end
    rescue error : Error
      StepResult::Failure.new(item.key, error.message || error.class.name, 1)
    end
  end

  # `gpg-key` — import repository signing keys.
  #
  # The fingerprint is checked against what gpg reads out of the downloaded
  # file *before* anything imports it. A key that arrives over HTTPS from the
  # right host is still not the key the profile asked for until that matches.
  class GpgKeyExecutor < StepExecutor
    include RepositorySupport

    def supports?(step : Step) : Bool
      step.is_a?(GpgKeyStep)
    end

    def commands(step : Step, item : StepItem) : Array(Command)
      key = find(step, item)
      return [] of Command unless key

      preview = ["download", PublicUrl.from(key.url), "verify fingerprint", key.fingerprint.value]
      preview.concat(key.rpm_import? ? ["sudo", "rpm", "--import"] : ["install", key.keyring.not_nil!])
      [Command.new(preview)]
    end

    def execute(step : Step, item : StepItem, runner : ShellRunner, &sink : String ->) : StepResult
      key = find(step, item)
      return StepResult::Success.new(item.key) unless key
      started = Time.instant

      with_workspace do |workspace|
        source = File.join(workspace, "key.asc")
        sink.call("fetching #{PublicUrl.from(key.url)}")
        fetch_key_file(key.url, source)

        if problem = fingerprint_mismatch(source, key.fingerprint, runner)
          return StepResult::Failure.new(item.key, problem, 1, Time.instant - started)
        end

        if keyring = key.keyring
          dearmored = File.join(workspace, "keyring.gpg")
          result = runner.run(Command.new(
            ["gpg", "--batch", "--yes", "--dearmor", "--output", dearmored, source],
            timeout: KEY_TIMEOUT))
          unless result.success?
            return StepResult::Failure.new(item.key,
              "could not dearmor the key: #{result.detail}", result.exit_code)
          end
          Installer.new(runner).install(dearmored, keyring, "0644",
            Digest::SHA256.hexdigest(File.read(dearmored)))
        else
          result = runner.run(Command.new(["sudo", "rpm", "--import", source], timeout: KEY_TIMEOUT))
          unless result.success?
            return StepResult::Failure.new(item.key,
              "rpm --import exited #{result.exit_code}: #{result.detail}", result.exit_code)
          end
        end

        StepResult::Success.new(item.key, Time.instant - started)
      end
    rescue error : Error
      StepResult::Failure.new(item.key, error.message || error.class.name, 1)
    end

    # A `file:` key is an operator-controlled local input; anything else has to
    # come over HTTPS.
    private def fetch_key_file(url : String, destination : String) : Nil
      if url.starts_with?("file:")
        source = URI.parse(url).path
        raise TrustError.new("Local key not found: #{source}") unless File.exists?(source)
        info = File.info(source, follow_symlinks: false)
        unless info.file? && info.size <= Downloader::MAX_KEY_BYTES
          raise TrustError.new("Local key must be a regular file under #{Downloader::MAX_KEY_BYTES} bytes")
        end
        File.copy(source, destination)
        return
      end

      # Through the shared helper rather than a direct `Downloader.new`: this
      # class already includes `DownloadSupport`, and bypassing it meant this
      # one fetch could not be substituted even once every other could.
      downloader(Downloader::MAX_KEY_BYTES).download(url, destination)
    end

    # Reads the key without importing it, and requires exactly the fingerprint
    # the profile named. A bundle containing an extra key is refused: importing
    # it would trust something nobody asked for.
    private def fingerprint_mismatch(path : String, expected : Fingerprint, runner : ShellRunner) : String?
      unless runner.command_exists?("gpg")
        return "gpg is not on PATH, so the key fingerprint cannot be verified"
      end

      result = runner.run(Command.new(
        ["gpg", "--batch", "--no-options", "--show-keys", "--with-colons", path],
        timeout: KEY_TIMEOUT))
      return "could not read the key: #{result.detail}" unless result.success?

      fingerprints = primary_fingerprints(result.stdout)
      return if fingerprints == [expected.value]

      "key fingerprint mismatch: expected #{expected} but found #{fingerprints.join(", ").presence || "none"}"
    end

    # In gpg's colon output an `fpr` record directly after a `pub` gives that
    # primary key's fingerprint; subkeys follow their own `sub` records.
    private def primary_fingerprints(output : String) : Array(String)
      found = [] of String
      awaiting = false

      output.each_line do |line|
        fields = line.split(':')
        case fields.first?
        when "pub"
          awaiting = true
        when "fpr"
          next unless awaiting
          awaiting = false
          fields[9]?.try { |value| found << value.gsub(/\s/, "").upcase }
        end
      end

      found
    end

    private def find(step : Step, item : StepItem) : GpgKeyEntry?
      step.as(GpgKeyStep).keys.find { |key| key.item_key == item.key }
    end
  end
end
