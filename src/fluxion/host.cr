module Fluxion
  # Crystal exposes no effective-UID accessor, and the distinction matters:
  # under `sudo` the real UID is still the user's while the effective one is
  # root, and it is the effective one that decides what a step can do.
  lib LibCredentials
    fun geteuid : UInt32
  end

  # Detects what machine Fluxion is running on.
  #
  # Manifest `when` rules match against this, never against the profile's
  # declared target — a profile can say it targets Fedora and still be run on
  # Arch, and the entries that survive should reflect the machine, not the
  # aspiration.
  module Host
    extend self

    OS_RELEASE_PATH = "/etc/os-release"

    # Cached because the answer cannot change while Fluxion runs, and several
    # commands ask for it repeatedly — `generate` alone asks four times, each
    # re-reading and re-parsing `/etc/os-release`. Only the real file is
    # cached: specs pass an explicit path to describe a host they are not
    # running on, and caching those would leak one spec's fixture into the next.
    @@facts : HostFacts? = nil

    def facts(os_release_path : String = OS_RELEASE_PATH) : HostFacts
      return read_facts(os_release_path) unless os_release_path == OS_RELEASE_PATH
      @@facts ||= read_facts(os_release_path)
    end

    private def read_facts(os_release_path : String) : HostFacts
      release = read_os_release(os_release_path)
      id = release["ID"]?.try(&.strip.downcase)
      distribution = Distribution.from_config?(id)

      # Prefer the family implied by a recognised distribution; fall back to
      # ID_LIKE, which is how derivatives declare what they are compatible
      # with.
      family = distribution.try(&.family) || family_from_id_like(release["ID_LIKE"]?)

      HostFacts.new(
        distribution: distribution,
        family: family,
        distribution_id: id,
        version: release["VERSION_ID"]?,
        codename: release["VERSION_CODENAME"]? || release["UBUNTU_CODENAME"]?,
        architecture: architecture,
        pretty_name: release["PRETTY_NAME"]?,
      )
    end

    def architecture : Architecture?
      Architecture.from_config?(normalized_machine)
    end

    private def normalized_machine : String
      {% if flag?(:aarch64) %}
        "arm64"
      {% elsif flag?(:x86_64) %}
        "amd64"
      {% else %}
        `uname -m`.strip rescue ""
      {% end %}
    end

    private def family_from_id_like(id_like : String?) : OsFamily?
      return unless id_like
      id_like.split(/\s+/).each do |candidate|
        if family = OsFamily.from_config?(candidate)
          return family
        end
        if distribution = Distribution.from_config?(candidate)
          return distribution.family
        end
      end
      nil
    end

    # Parses the shell-fragment format `/etc/os-release` uses. An unreadable or
    # missing file yields an empty map rather than an error: a host Fluxion
    # cannot identify is a host where every `when` rule simply fails to match,
    # which is the safe outcome.
    def read_os_release(path : String = OS_RELEASE_PATH) : Hash(String, String)
      values = {} of String => String
      info = File.info?(path)
      return values unless info && info.file?

      begin
        File.each_line(path) do |line|
          entry = line.strip
          next if entry.empty? || entry.starts_with?('#')

          separator = entry.index('=')
          next unless separator && separator > 0

          key = entry[0, separator]
          values[key] = unquote(entry[(separator + 1)..])
        end
      rescue File::Error
        return {} of String => String
      end

      values
    end

    private def unquote(value : String) : String
      stripped = value.strip
      return stripped if stripped.size < 2

      first = stripped[0]
      return stripped unless (first == '"' || first == '\'') && stripped[-1] == first

      stripped[1..-2].gsub("\\\"", "\"").gsub("\\\\", "\\")
    end

    # PATH lookup for `when.commands` and `when.commandExists`. A name
    # containing a separator is refused rather than resolved: `when` asks
    # whether a command is available, not whether a specific file exists.
    # Deliberately uncached, though a probe sweep asks the same question once
    # per item. A process-wide cache was tried and reverted: PATH is ambient
    # state that a step can change by installing something, so the cache needs
    # invalidating mid-run, and as module-level state it leaked between spec
    # examples and broke four of them. The stat-per-PATH-entry it saves is
    # noise beside the subprocess each probe spawns anyway — see
    # `Executor::ProbeSweep`, which is where that cost actually went.
    def command_exists?(command : String) : Bool
      return false if command.empty? || command.includes?('/') || command.includes?('\\')

      (ENV["PATH"]? || "").split(Process::PATH_DELIMITER).any? do |directory|
        next false if directory.empty?
        info = File.info?(File.join(directory, command))
        !info.nil? && info.file? && info.permissions.owner_execute?
      end
    end

    # The account whose home and groups Fluxion should act on.
    #
    # Under `sudo` the invoking user is what matters: installing a shell for
    # root when the user ran `sudo fluxion` is never what they meant.
    def target_user(configured : String? = nil) : String
      return configured if configured && !configured.empty?

      if root?
        sudo_user = ENV["SUDO_USER"]?
        return sudo_user if sudo_user && SAFE_USERNAME.matches?(sudo_user)
      end

      ENV["USER"]? || ENV["LOGNAME"]? || ""
    end

    SAFE_USERNAME = /\A[a-z_][a-z0-9_-]{0,31}\z/

    def home : String
      ENV["HOME"]? || Path.home.to_s
    end

    def root? : Bool
      LibCredentials.geteuid == 0
    end
  end
end
