module Fluxion::Executor
  # One process Fluxion intends to run.
  struct Command
    getter argv : Array(String)
    getter env : Hash(String, String)
    getter working_dir : String?
    getter timeout : Time::Span

    # Exit codes that count as success. Defaults to `{0}`; `dnf check-update`
    # and friends override it.
    getter success_codes : Set(Int32)

    # Sensitive values to mask out of anything this command emits.
    getter sensitive : Array(ShellEnvironmentVariable)

    def initialize(
      @argv : Array(String),
      @env : Hash(String, String) = {} of String => String,
      @working_dir : String? = nil,
      @timeout : Time::Span = 10.minutes,
      @success_codes : Set(Int32) = Set{0},
      @sensitive : Array(ShellEnvironmentVariable) = [] of ShellEnvironmentVariable,
    )
    end

    def success?(exit_code : Int32) : Bool
      @success_codes.includes?(exit_code)
    end

    # Safe for display: control sequences stripped, secrets masked.
    def preview : Array(String)
      Redaction.redact_command(@argv, @sensitive)
    end

    def to_s(io : IO) : Nil
      io << preview.join(' ')
    end
  end

  # Rewrites privileged commands and resolves their targets.
  #
  # Two rules, both about not trusting `PATH` for anything that runs as root:
  #
  # * A privileged effect always becomes `sudo -n -- <target> ...`. `-n` means
  #   it can never sit waiting for a password on a terminal nobody is watching:
  #   with no cached credential the command fails immediately instead of
  #   hanging.
  # * The target is resolved to a real path under a root-owned system
  #   directory. Otherwise a writable directory earlier on `PATH` would decide
  #   what runs as root.
  module Sudo
    extend self

    SUDO_PATHS = ["/usr/bin/sudo", "/bin/sudo"]

    # Directories trusted to hold executables Fluxion will run as root.
    SYSTEM_DIRECTORIES = ["/usr/bin", "/usr/sbin", "/bin", "/sbin"]

    def invocation?(argv : Array(String)) : Bool
      first = argv.first?
      return false unless first
      first == "sudo" || SUDO_PATHS.includes?(first)
    end

    # Turns a `sudo ...` marker into the command actually executed.
    def for_effect(argv : Array(String)) : Array(String)
      return argv unless invocation?(argv)

      target_index = effect_target_index(argv)
      unless target_index
        raise ExecutionError.new(
          "Privileged command has no executable target: #{argv.join(' ')}")
      end

      target = resolve(argv[target_index])
      [executable, "-n", "--", target] + argv[(target_index + 1)..]
    end

    private def effect_target_index(argv : Array(String)) : Int32?
      # Already normalized.
      return 3 if argv.size >= 4 && argv[1] == "-n" && argv[2] == "--"
      return 1 if argv.size >= 2 && !argv[1].starts_with?('-')
      nil
    end

    def executable : String
      resolve("sudo")
    end

    def available? : Bool
      !!find_trusted("sudo")
    end

    # Resolves an executable to a real path Fluxion is willing to run as root.
    #
    # The name must be an entry of a system directory. That entry may be a
    # symlink into another tree (Ubuntu 26.04 ships coreutils as
    # `/usr/bin/install -> ../lib/cargo/bin/coreutils/install`), so trust is
    # judged on what it leads to: a regular file owned by root that neither
    # group nor others can write, under directories that are all the same,
    # since a writable parent means the file can be swapped. The entry itself
    # and the directories above it must be root-owned too, or the link could
    # be re-pointed.
    def resolve(name : String) : String
      if name.starts_with?('/')
        found = trusted_entry(Path[name].normalize.to_s)
        return found if found
        raise ExecutionError.new("#{name} is not a trusted root-owned system executable")
      end

      found = find_trusted(name)
      return found if found
      raise ExecutionError.new("#{name} is not available from a trusted root-owned system directory")
    end

    private def find_trusted(name : String) : String?
      return if name.empty? || name.includes?('/') || name == "." || name == ".."

      SYSTEM_DIRECTORIES.each do |directory|
        candidate = trusted_entry(File.join(directory, name))
        return candidate if candidate
      end
      nil
    end

    # The real path behind `path` when `path` is a root-owned entry of a system
    # directory leading to a trusted file; nil otherwise.
    private def trusted_entry(path : String) : String?
      directory = File.dirname(path)
      return unless SYSTEM_DIRECTORIES.includes?(directory)
      return unless secure_ancestors?(directory)

      entry = File.info?(path, follow_symlinks: false)
      # A symlink's own mode bits mean nothing on Linux; its owner does.
      return unless entry && entry.owner_id == "0"

      real = real_path(path)
      real if real && trusted?(real)
    end

    private def real_path(path : String) : String?
      File.realpath(path)
    rescue File::Error
      nil
    end

    private def trusted?(path : String) : Bool
      info = File.info?(path)
      return false unless info && info.file?
      return false unless secure_entry?(info)
      secure_ancestors?(File.dirname(path))
    end

    # Walks from `directory` back to the root: a writable ancestor is as good
    # as a writable file, because the whole subtree can be replaced.
    private def secure_ancestors?(directory : String) : Bool
      while directory != "/"
        parent = File.info?(directory)
        return false unless parent && parent.directory? && secure_entry?(parent)
        directory = File.dirname(directory)
      end
      true
    end

    private def secure_entry?(info : File::Info) : Bool
      return false unless info.owner_id == "0"
      permissions = info.permissions
      !permissions.group_write? && !permissions.other_write?
    end
  end
end
