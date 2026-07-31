require "compress/gzip"

module Fluxion::Executor
  # Extracts one named member from a gzipped tar archive.
  #
  # Written rather than delegated because the safety properties are the point.
  # A release tarball is attacker-influenced input, so this reader:
  #
  # * bounds the decompressed stream, not just the compressed file, which is
  #   what stops a decompression bomb;
  # * bounds each entry individually;
  # * selects by an exact post-strip path match, never by basename, because two
  #   members can share one;
  # * refuses symlinks, hardlinks, and device nodes, so nothing can redirect
  #   the extraction outside the destination.
  #
  # Only tar.gz is handled in-process. `.zip` and `.tar.xz` are delegated,
  # rather than growing two more parsers with the same obligations.
  module Archive
    extend self

    # Header fields, at their fixed USTAR offsets.
    BLOCK_SIZE    = 512
    NAME_OFFSET   =   0
    NAME_LENGTH   = 100
    SIZE_OFFSET   = 124
    SIZE_LENGTH   =  12
    TYPE_OFFSET   = 156
    PREFIX_OFFSET = 345
    PREFIX_LENGTH = 155

    # Regular files. `\0` is the pre-POSIX spelling of `0`.
    REGULAR_TYPES = {'0', '\0'}

    # GNU long-name records: the following header's name comes from this
    # entry's body rather than its own name field.
    LONG_NAME_TYPE = 'L'

    MAX_ENTRY_BYTES  = 1_i64 * 1024 * 1024 * 1024
    MAX_STREAM_BYTES = 2_i64 * 1024 * 1024 * 1024

    # What was found inside an archive.
    record Member, path : String, size : Int64

    # Extracts the member at `archive_path` (after stripping `strip_components`
    # leading path segments) into `destination`. Returns its SHA-256.
    def extract(archive : String, archive_path : String, destination : String,
                strip_components : Int32 = 0) : String
      matches = 0
      digest = nil.as(String?)

      each_entry(archive) do |name, type, size, body|
        next unless REGULAR_TYPES.includes?(type)
        next unless strip(name, strip_components) == archive_path

        matches += 1
        # Two members with the same post-strip path means picking one would be
        # a guess about which the profile meant.
        raise TrustError.new("Archive member selection is ambiguous for #{archive_path}") if matches > 1

        digest = write_entry(body, size, destination)
      end

      return digest if digest
      raise TrustError.new("Archive member not found: #{archive_path}")
    end

    # Lists the regular-file members, for diagnostics when a path does not
    # match. Bounded like everything else here.
    def members(archive : String, limit : Int32 = 50) : Array(Member)
      found = [] of Member
      each_entry(archive) do |name, type, size, body|
        skip(body, size)
        next unless REGULAR_TYPES.includes?(type)
        found << Member.new(normalize(name), size)
        break if found.size >= limit
      end
      found
    end

    private def write_entry(body : IO, size : Int64, destination : String) : String
      digest = Digest::SHA256.new
      remaining = size
      buffer = Bytes.new(64 * 1024)

      File.open(destination, "w") do |file|
        while remaining > 0
          wanted = Math.min(remaining, buffer.size.to_i64).to_i
          read = body.read(buffer[0, wanted])
          raise TrustError.new("Archive entry ended early") if read.zero?

          chunk = buffer[0, read]
          digest << chunk
          file.write(chunk)
          remaining -= read
        end
      end

      digest.hexfinal
    end

    # Walks the archive, yielding each header and a body reader positioned at
    # its content. The caller must consume or skip the body.
    private def each_entry(archive : String, & : String, Char, Int64, IO ->) : Nil
      total = 0_i64
      pending_long_name = nil.as(String?)

      File.open(archive) do |file|
        Compress::Gzip::Reader.open(file) do |gzip|
          loop do
            header = Bytes.new(BLOCK_SIZE)
            read = gzip.read_fully?(header)
            break unless read

            # Two consecutive zero blocks end the archive.
            break if header.all?(&.zero?)

            total += BLOCK_SIZE
            check_stream(total)

            size = parse_octal(header, SIZE_OFFSET, SIZE_LENGTH)
            if size > MAX_ENTRY_BYTES
              raise TrustError.new("Archive entry exceeds the maximum size of #{MAX_ENTRY_BYTES} bytes")
            end

            type = header[TYPE_OFFSET].chr
            name = pending_long_name || parse_name(header)
            pending_long_name = nil

            if type == LONG_NAME_TYPE
              pending_long_name = read_string(gzip, size)
              # The body is padded to a block boundary like any other entry, so
              # the padding has to come off before the next header is read.
              skip(gzip, padding(size))
              total += padded(size)
              check_stream(total)
              next
            end

            body = IO::Sized.new(gzip, size)
            yield name, type, size, body
            # Whatever the caller left unread still has to come off the stream
            # before the next header is aligned.
            skip(body, body.read_remaining.to_i64)
            skip(gzip, padding(size))

            total += padded(size)
            check_stream(total)
          end
        end
      end
    end

    # The decompressed total, including headers and padding — the compressed
    # size says nothing about how much a bomb expands to.
    private def check_stream(total : Int64) : Nil
      return if total <= MAX_STREAM_BYTES
      raise TrustError.new("Expanded archive exceeds the maximum size of #{MAX_STREAM_BYTES} bytes")
    end

    private def padded(size : Int64) : Int64
      size + padding(size)
    end

    private def padding(size : Int64) : Int64
      remainder = size % BLOCK_SIZE
      remainder.zero? ? 0_i64 : (BLOCK_SIZE - remainder).to_i64
    end

    private def skip(io : IO, count : Int64) : Nil
      return if count <= 0
      buffer = Bytes.new(Math.min(count, 64 * 1024).to_i)
      remaining = count
      while remaining > 0
        wanted = Math.min(remaining, buffer.size.to_i64).to_i
        read = io.read(buffer[0, wanted])
        break if read.zero?
        remaining -= read
      end
    end

    private def read_string(io : IO, size : Int64) : String
      buffer = Bytes.new(Math.min(size, 4096).to_i)
      io.read_fully(buffer)
      skip(io, size - buffer.size)
      String.new(buffer).rstrip('\0')
    end

    # USTAR splits long names across a prefix and a name field.
    private def parse_name(header : Bytes) : String
      name = read_field(header, NAME_OFFSET, NAME_LENGTH)
      prefix = read_field(header, PREFIX_OFFSET, PREFIX_LENGTH)
      prefix.empty? ? name : "#{prefix}/#{name}"
    end

    private def read_field(header : Bytes, offset : Int32, length : Int32) : String
      slice = header[offset, length]
      terminator = slice.index(0_u8) || slice.size
      String.new(slice[0, terminator]).strip
    end

    private def parse_octal(header : Bytes, offset : Int32, length : Int32) : Int64
      text = read_field(header, offset, length)
      return 0_i64 if text.empty?
      text.to_i64(base: 8)
    rescue ArgumentError
      raise TrustError.new("Archive header has an unreadable size field")
    end

    # Drops `count` leading path segments. A path with too few segments can
    # never match, which is the honest answer rather than falling back to the
    # unstripped name.
    def strip(path : String, count : Int32) : String
      normalized = normalize(path)
      return normalized if count <= 0
      segments = normalized.split('/')
      return "" if segments.size <= count
      segments[count..].join('/')
    end

    # GNU tar writes `./bin/rg` when archiving a directory's contents, but a
    # profile author writes `bin/rg`. The prefix carries no meaning, so it is
    # removed rather than made the user's problem.
    def normalize(path : String) : String
      path.starts_with?("./") ? path[2..] : path
    end
  end
end
