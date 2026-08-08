require "json"
require "file_utils"

module Fluxion::State
  # What a prior run recorded about one item.
  struct ItemRecord
    include JSON::Serializable

    getter profile : String
    getter step : String

    @[JSON::Field(key: "itemKey")]
    getter item_key : String

    @[JSON::Field(key: "itemType")]
    getter item_type : String

    @[JSON::Field(key: "completedAt")]
    getter completed_at : Time

    getter version : String?
    getter checksum : String?

    # Where the artifact came from, with credentials and query parameters
    # stripped — a state file is read by humans and copied into bug reports.
    @[JSON::Field(key: "sourceUrl")]
    getter source_url : String?

    def initialize(@profile, @step, @item_key, @item_type, @completed_at,
                   @version = nil, @checksum = nil, @source_url = nil)
    end

    def matches?(step : String, key : String, type : String) : Bool
      @step == step && @item_key == key && @item_type == type
    end
  end

  # What a prior run recorded about one phase.
  struct PhaseRecord
    include JSON::Serializable

    getter phase : String
    getter status : String

    @[JSON::Field(key: "completedAt")]
    getter completed_at : Time

    # Digest of the phase's configuration at the time it completed. A completed
    # phase is only skipped while this still matches, so editing a package list
    # makes the phase run again rather than being silently considered done.
    getter fingerprint : String?

    getter reason : String?

    def initialize(@phase, @status, @completed_at, @fingerprint = nil, @reason = nil)
    end

    def completed? : Bool
      @status == "completed"
    end
  end

  # The persisted record of what a profile has already done.
  class Document
    include JSON::Serializable

    # Bumped when the shape changes. A file from a newer Fluxion is refused
    # rather than misread.
    #
    # Numbering continues from the Java implementation, which reached 7, so a
    # machine that has run both never sees a version go backwards.
    SCHEMA_VERSION = 8

    # The last schema the Java implementation wrote. Files at or below this are
    # read through the migration below rather than refused: someone upgrading
    # should not have to reinstall everything they already have.
    LEGACY_SCHEMA_VERSION = 7

    @[JSON::Field(key: "schemaVersion")]
    property schema_version : Int32

    @[JSON::Field(key: "profileName")]
    property profile_name : String

    @[JSON::Field(key: "lastRunAt")]
    property last_run_at : Time

    @[JSON::Field(key: "fluxionVersion")]
    property fluxion_version : String

    property items : Array(ItemRecord)
    property phases : Array(PhaseRecord)

    # Where a stopped run should pick up.
    @[JSON::Field(key: "nextPhase")]
    property next_phase : String?

    def initialize(@profile_name : String,
                   @schema_version : Int32 = SCHEMA_VERSION,
                   @last_run_at : Time = Time.utc,
                   @fluxion_version : String = VERSION,
                   @items : Array(ItemRecord) = [] of ItemRecord,
                   @phases : Array(PhaseRecord) = [] of PhaseRecord,
                   @next_phase : String? = nil)
    end

    def find(step : String, key : String, type : String) : ItemRecord?
      @items.find(&.matches?(step, key, type))
    end

    def record(item : ItemRecord) : Nil
      @items.reject! { |existing| existing.matches?(item.step, item.item_key, item.item_type) }
      @items << item
    end

    def record(phase : PhaseRecord) : Nil
      @phases.reject! { |existing| existing.phase == phase.phase }
      @phases << phase
    end

    def phase_completed?(name : String, fingerprint : String?) : Bool
      record = @phases.find { |phase| phase.phase == name }
      return false unless record && record.completed?
      # No fingerprint recorded means the phase predates fingerprinting, and
      # trusting it would risk skipping work the user has since changed.
      return false unless recorded = record.fingerprint
      recorded == fingerprint
    end

    def forget_item(key : String, step : String? = nil, type : String? = nil) : Int32
      before = @items.size
      @items.reject! do |item|
        next false unless item.item_key == key
        next false if step && item.step != step
        next false if type && item.item_type != type
        true
      end
      before - @items.size
    end

    def forget_phase(name : String) : Bool
      before = @phases.size
      @phases.reject! { |phase| phase.phase == name }
      before != @phases.size
    end

    def any_recorded? : Bool
      !@items.empty? || !@phases.empty? || !@next_phase.nil?
    end
  end

  # Reads and writes state under the user's data directory.
  #
  # Two properties matter more than speed here: a partially written state file
  # must never exist, and a state file must never be readable or writable by
  # another account — it records what is installed on the machine, and a
  # writable one could make Fluxion skip work that was never done.
  class Store
    DIRECTORY_MODE = 0o700
    FILE_MODE      = 0o600

    # Profile names become filenames, so they are constrained rather than
    # escaped: a name that needs escaping is a name that will surprise someone.
    SAFE_PROFILE = /\A[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?\z/

    getter root : String

    def initialize(@root : String = Store.default_root)
    end

    def self.default_root : String
      Paths.data_root
    end

    def path(profile : String) : String
      File.join(@root, "#{safe_profile(profile)}.state.json")
    end

    def exists?(profile : String) : Bool
      File.exists?(path(profile))
    end

    def load(profile : String) : Document
      file = path(profile)
      return Document.new(profile) unless File.exists?(file)

      info = File.info(file, follow_symlinks: false)
      unless info.file?
        raise ExecutionError.new("State file must be a regular file: #{file}")
      end
      permissions = info.permissions
      if permissions.group_write? || permissions.other_write?
        raise ExecutionError.new("State file is writable by another account: #{file}")
      end

      parse(File.read(file), profile, file)
    rescue error : JSON::ParseException | File::Error
      # Both shapes are translated: a malformed file and an unreadable one are
      # equally the state layer's problem to describe. `File::Error` used to
      # escape untranslated from `File.info`/`File.read`, and because it is an
      # `IO::Error` subclass the CLI's top-level rescue turned it into exit 0.
      raise ExecutionError.new("Failed to read state file #{file}: #{error.message}")
    end

    # Reads either the current shape or the one the Java implementation wrote.
    def parse(body : String, profile : String, file : String = "<memory>") : Document
      raw = JSON.parse(body)
      version = raw["schemaVersion"]?.try(&.as_i?) || 0

      if version > Document::SCHEMA_VERSION
        raise ExecutionError.new(
          "State file was written by a newer Fluxion (schema #{version}): #{file}")
      end

      return migrate(raw, profile) if version <= Document::LEGACY_SCHEMA_VERSION
      Document.from_json(body)
    end

    # Maps the Java layout onto this one.
    #
    # The vocabulary changed (`modules` became `steps`) but the meaning did
    # not, so the records carry over. `sysbootVersion` is kept as the recorded
    # version: it says which build did the work, and rewriting it would lose
    # that.
    private def migrate(raw : JSON::Any, profile : String) : Document
      items = (raw["entries"]?.try(&.as_a?) || [] of JSON::Any).compact_map do |entry|
        key = entry["itemKey"]?.try(&.as_s?)
        next unless key
        ItemRecord.new(
          profile: entry["profileName"]?.try(&.as_s?) || profile,
          step: entry["moduleName"]?.try(&.as_s?) || "",
          item_key: key,
          item_type: (entry["itemType"]?.try(&.as_s?) || "").downcase,
          completed_at: timestamp(entry["completedAt"]?),
          version: entry["version"]?.try(&.as_s?),
          checksum: entry["checksum"]?.try(&.as_s?),
          source_url: entry["sourceUrl"]?.try(&.as_s?),
        )
      end

      phases = (raw["phaseEntries"]?.try(&.as_a?) || [] of JSON::Any).compact_map do |entry|
        name = entry["phaseName"]?.try(&.as_s?)
        next unless name
        PhaseRecord.new(
          phase: name,
          status: (entry["status"]?.try(&.as_s?) || "").downcase,
          completed_at: timestamp(entry["completedAt"]?),
          fingerprint: entry["fingerprint"]?.try(&.as_s?),
          reason: entry["reason"]?.try(&.as_s?),
        )
      end

      Document.new(
        profile_name: raw["profileName"]?.try(&.as_s?) || profile,
        last_run_at: timestamp(raw["lastRunAt"]?),
        fluxion_version: raw["sysbootVersion"]?.try(&.as_s?) || "unknown",
        items: items,
        phases: phases,
        next_phase: raw["nextPlanEntry"]?.try(&.as_s?),
      )
    end

    private def timestamp(value : JSON::Any?) : Time
      text = value.try(&.as_s?)
      return Time.unix(0) unless text
      Time.parse_rfc3339(text)
    rescue Time::Format::Error
      Time.unix(0)
    end

    # Writes through a private temporary file and an atomic rename, so a
    # crash mid-write leaves the previous state intact rather than a truncated
    # file that would be read as "nothing is installed".
    def save(document : Document) : Nil
      document.last_run_at = Time.utc
      document.fluxion_version = VERSION

      file = path(document.profile_name)
      prepare_directory

      temporary = "#{file}.#{Random::Secure.hex(8)}.tmp"
      begin
        File.write(temporary, document.to_pretty_json)
        File.chmod(temporary, FILE_MODE)
        File.rename(temporary, file)
      rescue error
        File.delete(temporary) rescue nil
        raise ExecutionError.new("Failed to write state file #{file}: #{error.message}")
      end
    end

    def update(profile : String, & : Document -> _) : Document
      document = load(profile)
      yield document
      save(document)
      document
    end

    def reset(profile : String) : Bool
      file = path(profile)
      return false unless File.exists?(file)
      File.delete(file)
      true
    rescue error : File::Error
      raise ExecutionError.new("Failed to delete state file #{file}: #{error.message}")
    end

    # Deliberately absent: a per-item lookup that takes a profile name.
    #
    # Such a method has to `load` before it can answer, so calling it once per
    # item costs a file read and a JSON parse per package — quadratic in the
    # size of the state file over a run. Callers load a `Document` once and use
    # `Document#find`, which is the same answer without the re-read.
    private def prepare_directory : Nil
      return if Dir.exists?(@root)
      Dir.mkdir_p(@root, DIRECTORY_MODE)
    rescue error : File::Error
      raise ExecutionError.new("Failed to create state directory #{@root}: #{error.message}")
    end

    private def safe_profile(profile : String) : String
      return profile if profile.matches?(SAFE_PROFILE) && !profile.includes?("..")
      raise ExecutionError.new(
        "Profile name must be a safe slug (letters, digits, '.', '_', '-'): #{profile}")
    end
  end

  # Digests a phase's configuration so a completed phase is only skipped while
  # it still describes the same work.
  #
  # Every field that changes what runs contributes. Values are length-prefixed
  # so that `["a", "bc"]` and `["ab", "c"]` cannot collide.
  module Fingerprint
    extend self

    def of(phase : Phase) : String
      digest = Digest::SHA256.new
      append(digest, "phase", phase.name)
      append(digest, "continueOnStepError", phase.continue_on_step_error?.to_s)
      phase.depends_on.each { |dependency| append(digest, "dependsOn", dependency) }
      append(digest, "restart", phase.restart_policy.to_s)

      phase.steps.each do |step|
        append(digest, "step", step.name)
        append(digest, "kind", step.kind)
        append(digest, "continueOnError", step.continue_on_error?.to_s)
        step.probe_command.try { |probe| append(digest, "probe", probe) }
        # Item keys capture the packages, paths, and units a step will act on,
        # which is what actually changes when a profile is edited.
        step.items.each { |item| append(digest, "item", "#{item.type}/#{item.key}") }

        # A delegated step's item key is the path to someone else's config, so
        # everything above is blind to the work actually changing. Without this
        # a completed binstaller or dotbot phase stayed completed no matter what
        # was edited behind that path.
        step.external_config_digest.try { |config| append(digest, "config", config) }
      end

      digest.hexfinal
    end

    private def append(digest : Digest::SHA256, key : String, value : String) : Nil
      digest << key.bytesize.to_s << ":" << key << value.bytesize.to_s << ":" << value
    end
  end
end
