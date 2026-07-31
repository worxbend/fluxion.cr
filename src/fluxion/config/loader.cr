module Fluxion::Config
  # Reads a profile off disk and turns it into a `Profile`.
  #
  # The two frontends are detected rather than declared, because asking the
  # user to say which schema they wrote would be asking them to repeat
  # something the document already makes obvious.
  module Loader
    extend self

    # A profile is a hand-written config file. Anything this large is either a
    # mistake or an attempt to exhaust memory before parsing even starts.
    MAX_CONFIG_BYTES = 8_i64 * 1024 * 1024

    enum Schema
      # `profile` / `os` / `jobs`
      JobsSteps
      # `apiVersion` / `kind: WorkstationProfile`
      WorkstationProfile
    end

    # Loads and validates a profile. Raises `ValidationError` carrying every
    # diagnostic, so the caller can print them all at once.
    def load(path : String, host : HostFacts = HostFacts.new, strict : Bool = false) : Profile
      document = read(path)
      context = Context.new(File.dirname(File.expand_path(path)), host)
      profile = parse(context, document, path)
      context.diagnostics.raise_if_failed!(strict)
      profile
    end

    # Loads without raising, returning the profile alongside its diagnostics.
    # `validate` and `lint` need the findings even when the profile is usable.
    def load_with_diagnostics(path : String, host : HostFacts = HostFacts.new) : {Profile, Array(Diagnostic)}
      document = read(path)
      context = Context.new(File.dirname(File.expand_path(path)), host)
      profile = parse(context, document, path)
      {profile, context.diagnostics.diagnostics}
    end

    def parse(context : Context, document : YAML::Any, path : String) : Profile
      root = Node.root(document)

      case detect(root, path)
      in Schema::JobsSteps
        JobsSchema.parse(context, root)
      in Schema::WorkstationProfile
        Manifest.parse(context, root, path)
      end
    end

    # Reads the file with the checks that have to happen before parsing: a
    # symlinked or oversized config is refused rather than followed.
    def read(path : String) : YAML::Any
      info = begin
        File.info(path, follow_symlinks: false)
      rescue File::NotFoundError
        raise ConfigError.new("Failed to load config from #{path}: File does not exist")
      end

      unless info.file?
        raise ConfigError.new("Failed to load config from #{path}: config must be a regular non-symbolic file")
      end
      if info.size > MAX_CONFIG_BYTES
        raise ConfigError.new("Failed to load config from #{path}: config exceeds maximum size of #{MAX_CONFIG_BYTES} bytes")
      end

      content = begin
        File.read(path)
      rescue error : File::Error
        raise ConfigError.new("Failed to load config from #{path}: #{error.message}")
      end

      begin
        YAML.parse(content)
      rescue error : YAML::ParseException
        raise ConfigError.new("Failed to load config from #{path}: YAML parse error: #{error.message}")
      end
    end

    def detect(root : Node, path : String = "config") : Schema
      if root.null?
        raise ConfigError.new("Failed to load config from #{path}: config file is empty")
      end
      unless root.mapping?
        raise ConfigError.new("Failed to load config from #{path}: config root must be a YAML mapping")
      end

      return Schema::WorkstationProfile if root.has_key?("apiVersion") || root.has_key?("kind")
      return Schema::JobsSteps if %w[profile os jobs phases modules schemaVersion].any? { |key| root.has_key?(key) }

      raise ConfigError.new(
        "Failed to load config from #{path}: unknown config schema; " \
        "expected Fluxion profile/os/jobs/phases/modules fields or " \
        "apiVersion: #{Manifest::SUPPORTED_API_VERSION} with kind: #{Manifest::SUPPORTED_KIND}"
      )
    end

    # The default profile location, used when `-c` is not given.
    def default_path : String
      File.join(ENV["HOME"]? || ".", ".config", "fluxion", "default.yaml")
    end
  end
end
