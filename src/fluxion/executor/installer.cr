module Fluxion::Executor
  # Puts a verified file at its destination.
  #
  # Two paths, chosen by whether the destination's parent is writable:
  #
  # * Unprivileged — stage beside the destination, set the mode, then rename.
  #   The rename is atomic, so a reader either sees the old file or the new
  #   one, never a half-written binary.
  # * Privileged — stage under a root-owned anchor with `install`, re-verify
  #   the digest *there* (a file staged in a world-writable temp directory
  #   could be swapped between verification and the move), then `mv -fT`.
  #
  # A destination whose parent is neither writable nor safely root-owned is
  # refused rather than forced, because writing through a directory someone
  # else can replace is not an install, it is a hope.
  class Installer
    SUDO_TIMEOUT = 1.minute

    # Where privileged staging happens. Under /run so it is on a tmpfs, and
    # created root-owned with restrictive permissions before use.
    STAGING_ROOT = "/run/fluxion"

    def initialize(@runner : ShellRunner)
    end

    enum Privilege
      User
      Root
    end

    # Decides how the destination has to be written, refusing unsafe parents.
    def privilege_for(destination : String) : Privilege
      parent = File.dirname(destination)
      info = File.info?(parent)
      raise ExecutionError.new("Destination directory does not exist: #{parent}") unless info

      return Privilege::User if writable?(parent)
      return Privilege::Root if secure_root_directory?(info)

      raise ExecutionError.new(
        "Refusing to install into #{parent}: not writable, and not a secure root-owned directory")
    end

    # Installs `source` at `destination`.
    #
    # `digest` is required for the privileged path: without it there is nothing
    # to re-verify after staging, and staging is exactly where a swap would
    # happen.
    def install(source : String, destination : String, mode : String = "0755",
                digest : String? = nil, symlink : String? = nil) : Nil
      case privilege_for(destination)
      in Privilege::User then install_unprivileged(source, destination, mode, symlink)
      in Privilege::Root then install_privileged(source, destination, mode, digest, symlink)
      end
    end

    private def install_unprivileged(source : String, destination : String,
                                     mode : String, symlink : String?) : Nil
      staged = "#{destination}.fluxion-#{Random::Secure.hex(8)}"
      begin
        File.copy(source, staged)
        File.chmod(staged, mode.to_i(8))
        # Rename last: until this line the destination still holds whatever was
        # there before.
        File.rename(staged, destination)
      rescue error
        File.delete(staged) rescue nil
        raise ExecutionError.new("Failed to install #{destination}: #{error.message}")
      end

      link(destination, symlink)
    end

    private def install_privileged(source : String, destination : String, mode : String,
                                   digest : String?, symlink : String?) : Nil
      unless digest
        raise TrustError.new(
          "Privileged installation requires a verified digest for #{destination}")
      end

      anchor = File.join(STAGING_ROOT, "#{File.basename(destination)}.#{Random::Secure.hex(8)}")

      run!(["sudo", "install", "-d", "-m", "0700", STAGING_ROOT],
        "prepare the privileged staging directory")
      begin
        run!(["sudo", "install", "-m", mode, "--", source, anchor],
          "stage #{destination}")

        verify_staged(anchor, digest)

        run!(["sudo", "mv", "-f", "-T", "--", anchor, destination],
          "install #{destination}")
      rescue error
        run(["sudo", "rm", "-f", "--", anchor])
        raise error
      end

      link(destination, symlink)
    end

    # Re-digests the file where it now sits, root-owned.
    #
    # `sha256sum` is used rather than reading the file in-process because the
    # staged file may not be readable by this user, and shelling out is what
    # the privileged path is already doing anyway.
    private def verify_staged(anchor : String, expected : String) : Nil
      result = @runner.run(Command.new(["sudo", "sha256sum", "--", anchor], timeout: SUDO_TIMEOUT))
      unless result.success?
        raise TrustError.new("Could not verify the staged artifact at #{anchor}")
      end

      actual = result.stdout.split(/\s+/).first?.try(&.downcase)
      return if actual == expected.downcase

      raise TrustError.new(
        "Staged artifact failed verification: expected #{expected} but got #{actual}")
    end

    private def link(destination : String, symlink : String?) : Nil
      return unless symlink

      case privilege_for(symlink)
      in Privilege::User
        staged = "#{symlink}.fluxion-#{Random::Secure.hex(8)}"
        File.symlink(destination, staged)
        File.rename(staged, symlink)
      in Privilege::Root
        run!(["sudo", "ln", "-sfn", "--", destination, symlink], "link #{symlink}")
      end
    rescue error : File::Error
      raise ExecutionError.new("Failed to create symlink #{symlink}: #{error.message}")
    end

    # Writes text to a destination, honouring the same privilege split.
    def write(content : String, destination : String, mode : String = "0644",
              owner : String? = nil, group : String? = nil) : Nil
      temporary = File.tempname("fluxion-write")
      begin
        File.write(temporary, content)
        File.chmod(temporary, mode.to_i(8))

        case privilege_for(destination)
        in Privilege::User
          install_unprivileged(temporary, destination, mode, nil)
          chown_unprivileged(destination, owner, group)
        in Privilege::Root
          run!(["sudo", "install", "-m", mode, "--", temporary, destination],
            "write #{destination}")
          chown_privileged(destination, owner, group)
        end
      ensure
        File.delete(temporary) rescue nil
      end
    end

    private def chown_unprivileged(destination : String, owner : String?, group : String?) : Nil
      spec = ownership(owner, group)
      return unless spec
      run!(["chown", spec, destination], "set ownership of #{destination}")
    end

    private def chown_privileged(destination : String, owner : String?, group : String?) : Nil
      spec = ownership(owner, group)
      return unless spec
      run!(["sudo", "chown", spec, destination], "set ownership of #{destination}")
    end

    private def ownership(owner : String?, group : String?) : String?
      return unless owner || group
      group ? "#{owner}:#{group}" : owner
    end

    private def run(argv : Array(String)) : ProcessResult
      @runner.run(Command.new(argv, timeout: SUDO_TIMEOUT))
    end

    private def run!(argv : Array(String), description : String) : Nil
      result = run(argv)
      return if result.success?
      raise ExecutionError.new("Failed to #{description}: #{result.detail.presence || "exit #{result.exit_code}"}")
    end

    private def writable?(path : String) : Bool
      probe = File.join(path, ".fluxion-write-probe-#{Random::Secure.hex(6)}")
      File.write(probe, "")
      File.delete(probe)
      true
    rescue File::Error
      false
    end

    # Root-owned, and not writable by anyone else — a group-writable system
    # directory is as good as a writable one for an attacker in that group.
    private def secure_root_directory?(info : File::Info) : Bool
      return false unless info.directory?
      return false unless info.owner_id == "0"
      permissions = info.permissions
      !permissions.group_write? && !permissions.other_write?
    end
  end
end
