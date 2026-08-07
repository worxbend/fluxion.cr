module Fluxion::Config
  # Reads a profile off disk and turns it into a `Profile`.
  module Loader
    extend self

    # A profile is a hand-written config file. Anything this large is either a
    # mistake or an attempt to exhaust memory before parsing even starts.
    MAX_CONFIG_BYTES = 8_i64 * 1024 * 1024

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
      require_header!(root, path)
      Manifest.parse(context, root, path)
    end

    # The header is checked before parsing rather than collected as a
    # diagnostic, because a document without it is not a profile at all and
    # every field-level complaint that followed would be noise.
    private def require_header!(root : Node, path : String) : Nil
      if root.null?
        raise ConfigError.new("Failed to load config from #{path}: config file is empty")
      end
      unless root.mapping?
        raise ConfigError.new("Failed to load config from #{path}: config root must be a YAML mapping")
      end
      return if root.has_key?("apiVersion") || root.has_key?("kind")

      raise ConfigError.new(
        "Failed to load config from #{path}: missing profile header; expected " \
        "apiVersion: #{Manifest::SUPPORTED_API_VERSION} with kind: #{Manifest::SUPPORTED_KIND}"
      )
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

    # The default profile location, used when `-c` is not given.
    def default_path : String
      Paths.default_profile
    end
  end
end
