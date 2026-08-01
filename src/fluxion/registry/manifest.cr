module Fluxion::Registry
  # One configuration a registry offers.
  struct Entry
    # Used as a filename when installed, so it is constrained rather than
    # escaped: an id that needs escaping is an id that will surprise someone.
    ID_PATTERN = /\A[a-z0-9](?:[a-z0-9._-]*[a-z0-9])?\z/

    getter id : String
    getter name : String
    getter description : String?

    # Where the profile lives inside the registry repository. Always a
    # normalized relative path — see `Manifest.parse`.
    getter path : String

    # Distributions this configuration is written for. Advisory: it drives the
    # listing and a warning on install, not a refusal, because a profile may
    # legitimately be run somewhere its author did not anticipate.
    getter distributions : Array(Distribution)

    getter tags : Array(String)

    # Other entries this one expects alongside it.
    getter requires : Array(String)

    def initialize(
      @id : String,
      @path : String,
      @name : String,
      @description : String? = nil,
      @distributions : Array(Distribution) = [] of Distribution,
      @tags : Array(String) = [] of String,
      @requires : Array(String) = [] of String,
    )
    end

    def self.valid_id?(id : String) : Bool
      id.matches?(ID_PATTERN)
    end

    # Whether this entry says it targets the given host.
    def targets?(distribution : Distribution?) : Bool
      return true if @distributions.empty?
      return false unless distribution
      @distributions.includes?(distribution)
    end

    def to_s(io : IO) : Nil
      io << @id
    end
  end

  # What a registry repository publishes.
  #
  # The structure is deliberately strict: one manifest at a known path, one
  # dedicated folder for the profiles it names. A registry whose layout is
  # discovered rather than declared cannot be checked, and this is a file that
  # tells a machine what to install.
  class Manifest
    # The manifest's filename at the repository root.
    FILE_NAME = "fluxion-registry.yaml"

    # The folder entries must live under. Confining them means a manifest
    # cannot name a path elsewhere in the repository — or outside it.
    PROFILE_DIRECTORY = "profiles"

    SUPPORTED_API_VERSION = "fluxion.dev/registry/v1"
    SUPPORTED_KIND        = "Registry"

    getter name : String
    getter description : String?
    getter maintainer : String?
    getter entries : Array(Entry)

    def initialize(@name : String, @entries : Array(Entry),
                   @description : String? = nil, @maintainer : String? = nil)
    end

    def entry?(id : String) : Entry?
      @entries.find { |entry| entry.id == id }
    end

    def ids : Array(String)
      @entries.map(&.id)
    end

    # Entries matching a free-text query across id, name, description, and tags.
    def search(query : String) : Array(Entry)
      needle = query.strip.downcase
      return @entries if needle.empty?

      @entries.select do |entry|
        entry.id.downcase.includes?(needle) ||
          entry.name.downcase.includes?(needle) ||
          entry.description.try(&.downcase.includes?(needle)) ||
          entry.tags.any?(&.downcase.includes?(needle))
      end
    end

    # Parses a manifest, collecting every problem rather than stopping at the
    # first — the same contract as profile parsing, and for the same reason.
    def self.parse(body : String, source : String = Manifest::FILE_NAME) : {Manifest?, Array(Diagnostic)}
      diagnostics = DiagnosticCollector.new

      document = begin
        YAML.parse(body)
      rescue error : YAML::ParseException
        diagnostics.error(source, "not valid YAML: #{error.message}")
        return {nil, diagnostics.diagnostics}
      end

      root = Config::Node.root(document)
      unless root.mapping?
        diagnostics.error(source, "registry manifest must be a YAML mapping")
        return {nil, diagnostics.diagnostics}
      end

      check_header(diagnostics, root["apiVersion"], "apiVersion", SUPPORTED_API_VERSION)
      check_header(diagnostics, root["kind"], "kind", SUPPORTED_KIND)

      metadata = root["metadata"]
      name = metadata["name"].string?.try(&.strip).presence
      unless name
        diagnostics.error(metadata["name"].path, "metadata.name is required")
      end

      entries = parse_entries(diagnostics, root["entries"])

      return {nil, diagnostics.diagnostics} if diagnostics.errors?

      manifest = new(
        name.not_nil!,
        entries,
        description: metadata["description"].string?.try(&.strip).presence,
        maintainer: metadata["maintainer"].string?.try(&.strip).presence,
      )
      {manifest, diagnostics.diagnostics}
    end

    private def self.check_header(diagnostics : DiagnosticCollector, node : Config::Node,
                                  field : String, expected : String) : Nil
      value = node.string?.try(&.strip)
      if value.nil? || value.empty?
        diagnostics.error(node.path.presence || field, "is required and must be '#{expected}'")
        return
      end
      return if value == expected
      diagnostics.error(node.path, "must be '#{expected}' but was '#{value}'")
    end

    private def self.parse_entries(diagnostics : DiagnosticCollector, node : Config::Node) : Array(Entry)
      entries = [] of Entry
      seen = {} of String => String

      unless node.present?
        diagnostics.error(node.path.presence || "entries", "entries is required")
        return entries
      end

      node.each_item do |item, _|
        id = item["id"].string?.try(&.strip)
        if id.nil? || id.empty?
          diagnostics.error(item["id"].path, "id is required")
          next
        end

        unless Entry.valid_id?(id)
          diagnostics.error(item["id"].path,
            "id must be lowercase letters, digits, '.', '_', or '-'",
            "it becomes a filename when installed")
          next
        end

        if previous = seen[id]?
          diagnostics.error(item["id"].path,
            "duplicates entry '#{id}' first declared at #{previous}")
          next
        end
        seen[id] = item["id"].path

        path = entry_path(diagnostics, item["path"], id)
        next unless path

        entries << Entry.new(
          id: id,
          path: path,
          name: item["name"].string?.try(&.strip).presence || id,
          description: item["description"].string?.try(&.strip).presence,
          distributions: parse_distributions(diagnostics, item["distributions"]),
          tags: item["tags"].string_list.map(&.strip.downcase).reject(&.empty?),
          requires: item["requires"].string_list.map(&.strip).reject(&.empty?),
        )
      end

      entries
    end

    # A path is only usable if it stays inside the registry's profile folder.
    #
    # A manifest is fetched from a remote repository and its paths are used to
    # read files, so `../../.ssh/id_ed25519` has to be impossible rather than
    # merely unlikely.
    private def self.entry_path(diagnostics : DiagnosticCollector, node : Config::Node, id : String) : String?
      raw = node.string?.try(&.strip)
      # Defaulting keeps the common case free of ceremony while still landing
      # inside the confined folder.
      raw = File.join(PROFILE_DIRECTORY, "#{id}.yaml") if raw.nil? || raw.empty?

      if raw.starts_with?('/') || raw.includes?('\\')
        diagnostics.error(node.path, "path must be relative to the registry root")
        return nil
      end

      normalized = Path.posix(raw).normalize.to_s
      unless normalized == raw
        diagnostics.error(node.path, "path must be normalized", "no '.' or '..' segments")
        return nil
      end

      unless normalized == PROFILE_DIRECTORY || normalized.starts_with?("#{PROFILE_DIRECTORY}/")
        diagnostics.error(node.path,
          "path must be inside #{PROFILE_DIRECTORY}/",
          "a registry may only publish files from its profile folder")
        return nil
      end

      normalized
    end

    private def self.parse_distributions(diagnostics : DiagnosticCollector, node : Config::Node) : Array(Distribution)
      node.string_list.compact_map do |value|
        distribution = Distribution.from_config?(value)
        unless distribution
          diagnostics.warning(node.path, "unknown distribution '#{value}'")
        end
        distribution
      end
    end

    # A starter manifest, for `registry init`.
    def self.template(name : String) : String
      <<-YAML
      apiVersion: #{SUPPORTED_API_VERSION}
      kind: Registry

      metadata:
        name: #{name}
        description: Bootstrap configurations for my machines

      # Every entry names a profile inside #{PROFILE_DIRECTORY}/.
      # The id becomes the filename when someone installs it.
      entries:
        - id: workstation
          name: Developer workstation
          description: Editors, toolchains, and the shell setup I expect everywhere
          path: #{PROFILE_DIRECTORY}/workstation.yaml
          distributions: [fedora, arch]
          tags: [developer]

      YAML
    end
  end
end
