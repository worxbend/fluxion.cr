require "./core/errors"

module Fluxion
  # Replacing a file without ever leaving a half-written one behind.
  #
  # Write into a sibling temporary, set the mode on it, then rename over the
  # destination. The rename is atomic within a filesystem, so a concurrent
  # reader — another Fluxion process, an editor, the user's `cat` — sees either
  # the old file or the new one and never a truncated middle. Setting the mode
  # before the rename matters for the same reason: the file is never briefly
  # visible at the destination with the wrong permissions.
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
    # `mode` is applied to the temporary before the rename; nil leaves whatever
    # the process umask produced, which is what a file destined for a git
    # working tree wants. `description` names the file in the error message, so
    # a caller can say "state file /x/y" rather than only the path.
    def write(path : String, body : String, mode : Int32? = nil,
              description : String = path) : Nil
      # A nonce, not a security parameter: it only has to avoid colliding with
      # a concurrent write to the same destination.
      temporary = "#{path}.#{Random::Secure.hex(8)}.tmp"

      begin
        File.write(temporary, body)
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
