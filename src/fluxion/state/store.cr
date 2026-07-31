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

  # What a prior run recorded about one job.
  struct JobRecord
    include JSON::Serializable

    getter job : String
    getter status : String

    @[JSON::Field(key: "completedAt")]
    getter completed_at : Time

    # Digest of the job's configuration at the time it completed. A completed
    # job is only skipped while this still matches, so editing a package list
    # makes the job run again rather than being silently considered done.
    getter fingerprint : String?

    getter reason : String?

    def initialize(@job, @status, @completed_at, @fingerprint = nil, @reason = nil)
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
    SCHEMA_VERSION = 1

    @[JSON::Field(key: "schemaVersion")]
    property schema_version : Int32

    @[JSON::Field(key: "profileName")]
    property profile_name : String

    @[JSON::Field(key: "lastRunAt")]
    property last_run_at : Time

    @[JSON::Field(key: "fluxionVersion")]
    property fluxion_version : String

    property items : Array(ItemRecord)
    property jobs : Array(JobRecord)

    # Where a stopped run should pick up.
    @[JSON::Field(key: "nextJob")]
    property next_job : String?

    def initialize(@profile_name : String,
                   @schema_version : Int32 = SCHEMA_VERSION,
                   @last_run_at : Time = Time.utc,
                   @fluxion_version : String = VERSION,
                   @items : Array(ItemRecord) = [] of ItemRecord,
                   @jobs : Array(JobRecord) = [] of JobRecord,
                   @next_job : String? = nil)
    end

    def find(step : String, key : String, type : String) : ItemRecord?
      @items.find(&.matches?(step, key, type))
    end

    def record(item : ItemRecord) : Nil
      @items.reject! { |existing| existing.matches?(item.step, item.item_key, item.item_type) }
      @items << item
    end

    def record(job : JobRecord) : Nil
      @jobs.reject! { |existing| existing.job == job.job }
      @jobs << job
    end

    def job_completed?(name : String, fingerprint : String?) : Bool
      record = @jobs.find { |job| job.job == name }
      return false unless record && record.completed?
      # No fingerprint recorded means the job predates fingerprinting, and
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

    def forget_job(name : String) : Bool
      before = @jobs.size
      @jobs.reject! { |job| job.job == name }
      before != @jobs.size
    end

    def any_recorded? : Bool
      !@items.empty? || !@jobs.empty? || !@next_job.nil?
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
      base = ENV["XDG_DATA_HOME"]?.presence || File.join(Host.home, ".local", "share")
      File.join(base, "fluxion")
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

      document = Document.from_json(File.read(file))
      if document.schema_version > Document::SCHEMA_VERSION
        raise ExecutionError.new(
          "State file was written by a newer Fluxion (schema #{document.schema_version}): #{file}")
      end
      document
    rescue error : JSON::ParseException
      raise ExecutionError.new("Failed to read state file #{file}: #{error.message}")
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
    end

    # What a prior run recorded about this item, if anything.
    def find(profile : String, item : ModuleItem) : InstallationStatus::InstalledFromState?
      document = load(profile)
      record = document.find(item.step_name, item.key, item.item_type.json_name)
      return unless record
      InstallationStatus::InstalledFromState.new(item.key, record.completed_at, record.version)
    rescue ExecutionError
      # A state file that cannot be read is not evidence that work was done, so
      # the run falls back to live probes rather than failing outright.
      nil
    end

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

  # Digests a job's configuration so a completed job is only skipped while it
  # still describes the same work.
  #
  # Every field that changes what runs contributes. Values are length-prefixed
  # so that `["a", "bc"]` and `["ab", "c"]` cannot collide.
  module Fingerprint
    extend self

    def of(job : Job) : String
      digest = Digest::SHA256.new
      append(digest, "job", job.name)
      append(digest, "continueOnStepError", job.continue_on_step_error?.to_s)
      job.depends_on.each { |dependency| append(digest, "dependsOn", dependency) }
      append(digest, "restart", job.restart_policy.to_s)

      job.steps.each do |step|
        append(digest, "step", step.name)
        append(digest, "kind", step.kind)
        append(digest, "continueOnError", step.continue_on_error?.to_s)
        step.probe_command.try { |probe| append(digest, "probe", probe) }
        # Item keys capture the packages, paths, and units a step will act on,
        # which is what actually changes when a profile is edited.
        step.items.each { |item| append(digest, "item", "#{item.type}/#{item.key}") }
      end

      digest.hexfinal
    end

    private def append(digest : Digest::SHA256, key : String, value : String) : Nil
      digest << key.bytesize.to_s << ":" << key << value.bytesize.to_s << ":" << value
    end
  end
end
