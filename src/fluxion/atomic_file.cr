require "./core/errors"

module Fluxion
  # Replacing a file without ever leaving a half-written one behind.
  #
  # Create a sibling temporary already carrying the mode, fill it, then rename
  # over the destination. The rename is atomic within a filesystem, so a
  # concurrent reader — another Fluxion process, an editor, the user's `cat` —
  # sees either the old file or the new one and never a truncated middle. The
  # mode goes on at creation for the same reason: neither the temporary nor the
  # destination is ever visible with the wrong permissions, not even for the
  # moment between writing the body and narrowing it.
  #
  # Here rather than in each caller because three of them had grown their own
  # copy of the sequence — the state file, the registry settings, and the
  # registry's profile writer — and one had quietly lost the `chmod`. `Paths`
  # is next door for the same reason: a rule that has to hold everywhere is
  # easier to keep in one place than to remember at each site.
  module AtomicFile
    extend self

    # Writes `body` to `path`.
    #
    # `mode` is applied to the temporary as it is created; nil leaves whatever
    # the process umask produced, which is what a file destined for a git
    # working tree wants. `description` names the file in the error message, so
    # a caller can say "state file /x/y" rather than only the path.
    def write(path : String, body : String, mode : Int32? = nil,
              description : String = path) : Nil
      # A nonce, not a security parameter: it only has to avoid colliding with
      # a concurrent write to the same destination.
      temporary = "#{path}.#{Random::Secure.hex(8)}.tmp"

      begin
        # The mode goes on at creation, not after: a caller passing one is
        # saying the bytes are not for other accounts, and writing first and
        # narrowing afterwards would leave the whole body readable in between.
        # `perm` is masked by the process umask, so the file can be created
        # narrower than asked for; the chmod restores the exact mode.
        File.write(temporary, body, perm: mode || File::DEFAULT_CREATE_PERMISSIONS)
        mode.try { |permissions| File.chmod(temporary, permissions) }
        # Last, so until this line the destination still holds what was there
        # before.
        File.rename(temporary, path)
      rescue error
        File.delete(temporary) rescue nil
        raise ExecutionError.new("Failed to write #{description}: #{error.message}")
      end
    end
  end
end
