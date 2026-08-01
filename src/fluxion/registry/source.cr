module Fluxion::Registry
  # A registry the user has configured.
  #
  # Two locations, deliberately separate:
  #
  # * The **mirror**, a git clone under the cache directory. It is disposable —
  #   deleting it costs a re-clone and nothing else.
  # * The **installed** directory under the config directory, holding the
  #   configurations the user actually chose. That is theirs: `sync` never
  #   overwrites it without being asked.
  #
  # Keeping them apart is what makes "installed" mean something. If the clone
  # were the install destination, every `sync` would silently change files the
  # user had edited.
  struct Source
    # `github.com/worxbend/x` and `git@github.com:worxbend/x.git` are the same
    # registry, so the name is derived from the repository rather than the URL.
    getter name : String
    getter url : String

    # Branch or tag to track. Nil follows the repository's default branch.
    getter ref : String?

    getter? default : Bool

    def initialize(@name : String, @url : String, @ref : String? = nil, @default : Bool = false)
    end

    # Where the git mirror lives. Under the cache directory because it is
    # reconstructible from the URL alone.
    def mirror_path : String
      File.join(Source.mirror_root, @name)
    end

    # Where installed configurations land.
    def install_path : String
      File.join(Source.install_root, @name)
    end

    def manifest_path : String
      File.join(mirror_path, Manifest::FILE_NAME)
    end

    def cloned? : Bool
      Dir.exists?(File.join(mirror_path, ".git"))
    end

    def self.mirror_root : String
      base = ENV["XDG_CACHE_HOME"]?.presence || File.join(Host.home, ".cache")
      File.join(base, "fluxion", "registries")
    end

    def self.install_root : String
      base = ENV["XDG_CONFIG_HOME"]?.presence || File.join(Host.home, ".config")
      File.join(base, "fluxion", "registries")
    end

    def self.settings_path : String
      base = ENV["XDG_CONFIG_HOME"]?.presence || File.join(Host.home, ".config")
      File.join(base, "fluxion", "registries.yaml")
    end

    # Names become directory names, so they are constrained rather than escaped.
    NAME_PATTERN = /\A[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?\z/

    def self.valid_name?(name : String) : Bool
      name.matches?(NAME_PATTERN) && !name.includes?("..")
    end

    # Derives a name from a repository URL: the last path segment, minus `.git`.
    #
    #     https://github.com/worxbend/fluxion-profiles.git  ->  fluxion-profiles
    #     git@github.com:worxbend/fluxion-profiles          ->  fluxion-profiles
    def self.derive_name(url : String) : String?
      trimmed = url.strip.rstrip('/')
      return if trimmed.empty?

      # An scp-style URL has no scheme, so splitting on ':' finds the path.
      tail = trimmed.includes?("://") ? trimmed : trimmed.split(':').last
      segment = tail.split('/').last.presence
      return unless segment

      name = segment.chomp(".git")
      valid_name?(name) ? name : nil
    end

    # Accepted transports.
    #
    # A registry decides what a machine will be told to install, so it has to
    # come over something authenticated. `file:` is allowed because a local
    # registry is genuinely useful — for testing, and for a private one on a
    # shared filesystem — and it is not reachable by anyone who is not already
    # on the machine.
    def self.validate_url(url : String) : String?
      value = url.strip
      return "registry URL must not be blank" if value.empty?

      return if value.starts_with?("https://")
      return if value.starts_with?("file://") || value.starts_with?('/')
      # scp-style ssh, as GitHub and GitLab hand out.
      return if value.matches?(/\A[A-Za-z0-9._-]+@[A-Za-z0-9._-]+:.+\z/)
      return if value.starts_with?("ssh://")

      if value.starts_with?("http://")
        return "registry URL must use https, not http"
      end

      "registry URL must be https, ssh, or a local path"
    end

    def to_s(io : IO) : Nil
      io << @name
    end
  end

  # The configured registries, at `~/.config/fluxion/registries.yaml`.
  class Settings
    getter sources : Array(Source)

    def initialize(@sources : Array(Source) = [] of Source)
    end

    def self.load(path : String = Source.settings_path) : self
      return new unless File.exists?(path)

      document = begin
        YAML.parse(File.read(path))
      rescue error : YAML::ParseException
        raise ConfigError.new("Failed to read #{path}: #{error.message}")
      end

      root = Config::Node.root(document)
      sources = root["registries"].items.compact_map do |item|
        name = item["name"].string?.try(&.strip)
        url = item["url"].string?.try(&.strip)
        next unless name && url && Source.valid_name?(name)

        Source.new(
          name: name,
          url: url,
          ref: item["ref"].string?.try(&.strip).presence,
          default: item["default"].bool? || false,
        )
      end

      new(sources)
    end

    def save(path : String = Source.settings_path) : Nil
      Dir.mkdir_p(File.dirname(path), 0o700)

      body = String.build do |io|
        io << "# Registries fluxion can install configurations from.\n"
        io << "# Managed by `fluxion registry add` and `fluxion registry remove`.\n"
        io << "registries:\n"
        if @sources.empty?
          io << "  []\n"
        else
          @sources.each do |source|
            io << "  - name: " << source.name << '\n'
            io << "    url: " << source.url << '\n'
            source.ref.try { |ref| io << "    ref: " << ref << '\n' }
            io << "    default: true\n" if source.default?
          end
        end
      end

      # Written beside the destination and renamed, so an interrupted write
      # never leaves the user with a truncated registry list.
      temporary = "#{path}.#{Random::Secure.hex(6)}.tmp"
      begin
        File.write(temporary, body)
        File.chmod(temporary, 0o600)
        File.rename(temporary, path)
      rescue error
        File.delete(temporary) rescue nil
        raise ExecutionError.new("Failed to write #{path}: #{error.message}")
      end
    end

    def find(name : String) : Source?
      @sources.find { |source| source.name == name }
    end

    # The registry a command should act on when none was named: the one marked
    # default, or the only one configured.
    def resolve(name : String? = nil) : Source
      if name
        found = find(name)
        return found if found
        raise ExecutionError.new(
          "Unknown registry '#{name}'. Configured: #{describe_configured}")
      end

      marked = @sources.find(&.default?)
      return marked if marked
      return @sources.first if @sources.size == 1

      if @sources.empty?
        raise ExecutionError.new(
          "No registries configured. Add one with: fluxion registry add <url>")
      end

      raise ExecutionError.new(
        "Several registries are configured and none is the default. " \
        "Name one, or mark a default with --default. Configured: #{describe_configured}")
    end

    def add(source : Source) : self
      if find(source.name)
        raise ExecutionError.new(
          "A registry named '#{source.name}' is already configured. " \
          "Remove it first, or pass --name to choose another.")
      end

      # Only one default, so `resolve` never has to guess.
      sources = source.default? ? @sources.map { |existing| undefault(existing) } : @sources
      Settings.new(sources + [source])
    end

    def remove(name : String) : self
      unless find(name)
        raise ExecutionError.new("Unknown registry '#{name}'. Configured: #{describe_configured}")
      end
      Settings.new(@sources.reject { |source| source.name == name })
    end

    # Not `default=`: this returns new settings rather than mutating, and an
    # assignment method in Crystal returns its argument, so the result would be
    # unreachable.
    # ameba:disable Naming/AccessorMethodName
    def set_default(name : String) : self
      unless find(name)
        raise ExecutionError.new("Unknown registry '#{name}'. Configured: #{describe_configured}")
      end

      Settings.new(@sources.map do |source|
        Source.new(source.name, source.url, source.ref, source.name == name)
      end)
    end

    private def undefault(source : Source) : Source
      Source.new(source.name, source.url, source.ref, false)
    end

    private def describe_configured : String
      return "(none)" if @sources.empty?
      @sources.map(&.name).join(", ")
    end
  end
end
