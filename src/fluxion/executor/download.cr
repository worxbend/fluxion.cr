require "http/client"
require "uri"
require "digest/sha256"

module Fluxion::Executor
  # Performs one HTTP request. No redirect following, and no policy.
  #
  # An interface for the same reason `ShellRunner` is one: every rule
  # `Downloader` enforces — the streaming size ceiling, the digest over the
  # bytes actually written, the refusal to keep a partial file — is worth
  # testing, and none of it could be reached without a real network while the
  # `HTTP::Client` call was inline.
  #
  # Redirects are reported rather than followed, because deciding whether a hop
  # is acceptable is policy and belongs with the rest of it.
  abstract class HttpTransport
    # Yields the response body and its declared length, and returns nil. For a
    # redirect, yields nothing and returns the `Location` header instead.
    abstract def get(uri : URI, connect_timeout : Time::Span, read_timeout : Time::Span,
                     & : IO, Int64? ->) : String?
  end

  # The real one.
  class SystemHttpTransport < HttpTransport
    def get(uri : URI, connect_timeout : Time::Span, read_timeout : Time::Span,
            & : IO, Int64? ->) : String?
      client = HTTP::Client.new(uri)
      client.connect_timeout = connect_timeout
      client.read_timeout = read_timeout

      redirect = nil.as(String?)
      begin
        client.get(uri.request_target) do |response|
          if response.status.redirection?
            location = response.headers["Location"]?
            raise TrustError.new("Redirect without a Location header: #{PublicUrl.from(uri.to_s)}") unless location
            redirect = location
            next
          end

          unless response.status.success?
            raise TrustError.new(
              "Download failed with HTTP #{response.status_code} for #{PublicUrl.from(uri.to_s)}")
          end

          declared = response.headers["Content-Length"]?.try(&.to_i64?)
          yield response.body_io, declared
        end
      rescue error : File::Error
        # Raised by the caller's block writing the artifact, not by the
        # transport. Left alone so it keeps mapping to the filesystem exit code
        # rather than being described as a fetch failure.
        raise error
      rescue error : IO::Error
        # A refused connection, a DNS failure, or a read timeout. Without this
        # the stdlib error escaped the closed error set, so it slipped past
        # every executor's per-item `rescue error : Error` boundary, killed the
        # whole run, and was then reported as exit 0 by the CLI.
        raise ExecutionError.new(
          "Could not fetch #{PublicUrl.from(uri.to_s)}: #{error.message}")
      ensure
        client.close rescue nil
      end

      redirect
    end
  end

  # Fetches remote artifacts and refuses to hand back anything unverified.
  #
  # Every rule here exists because the alternative is running someone else's
  # bytes as root:
  #
  # * HTTPS only, host required, no credentials in the URL — and re-checked
  #   after redirects, since a redirect is an attacker-controllable hop.
  # * A hard byte ceiling, enforced while streaming rather than after, so a
  #   hostile or broken server cannot exhaust memory or the disk.
  # * The digest is computed over the bytes actually written, and a mismatch
  #   deletes the file before raising. There is no code path that returns a
  #   downloaded file whose digest was not checked.
  class Downloader
    # Artifacts and signatures.
    MAX_ARTIFACT_BYTES = 1_i64 * 1024 * 1024 * 1024

    # Checksum documents and repository keys — small by nature, so a large one
    # means something is wrong.
    MAX_TEXT_BYTES = 1_i64 * 1024 * 1024
    MAX_KEY_BYTES  = 16_i64 * 1024 * 1024

    CONNECT_TIMEOUT = 30.seconds
    READ_TIMEOUT    = 10.minutes

    # Read in chunks rather than whole so the ceiling is enforced continuously.
    CHUNK_BYTES = 64 * 1024

    def initialize(@max_bytes : Int64 = MAX_ARTIFACT_BYTES,
                   @transport : HttpTransport = SystemHttpTransport.new)
    end

    # Downloads to `destination` and returns the SHA-256 of what was written.
    def download(url : String, destination : String) : String
      uri = validate(url)
      digest = Digest::SHA256.new

      begin
        File.open(destination, "w") do |file|
          fetch(uri) { |body, declared| stream_to(file, body, declared, digest, url) }
        end
      rescue error
        # No code path returns a file whose digest was not checked, so a failure
        # anywhere above takes the partial download with it.
        File.delete(destination) rescue nil
        raise error
      end

      digest.hexfinal
    end

    # Copies the body to `file`, digesting as it goes and enforcing the ceiling
    # continuously rather than after the fact.
    #
    # Extracted from `download`, which was five block levels deep — the deepest
    # nesting in src/fluxion — with the trust rules buried at the bottom.
    private def stream_to(file : IO, body : IO, declared : Int64?,
                          digest : Digest::SHA256, url : String) : Nil
      if declared && declared > @max_bytes
        raise TrustError.new(
          "Download exceeds the maximum size of #{@max_bytes} bytes: #{PublicUrl.from(url)}")
      end

      buffer = Bytes.new(CHUNK_BYTES)
      written = 0_i64

      loop do
        read = body.read(buffer)
        break if read.zero?

        written += read
        if written > @max_bytes
          raise TrustError.new(
            "Download exceeds the maximum size of #{@max_bytes} bytes: #{PublicUrl.from(url)}")
        end

        chunk = buffer[0, read]
        digest << chunk
        file.write(chunk)
      end

      # A truncated response would otherwise digest cleanly as whatever
      # arrived, so a short read is a failure rather than a small file.
      return unless declared && written != declared
      raise TrustError.new(
        "Download was truncated: expected #{declared} bytes but received #{written}")
    end

    # Downloads and verifies against `expected`, deleting the file on mismatch.
    def download_verified(url : String, destination : String, expected : Checksum) : String
      actual = download(url, destination)
      return actual if expected.matches?(actual)

      File.delete(destination) rescue nil
      raise TrustError.new(
        "Checksum mismatch for #{PublicUrl.from(url)}: expected #{expected.value} but got #{actual}")
    end

    # Fetches a small text document, such as a checksums file.
    def download_text(url : String) : String
      uri = validate(url)
      body = String.build do |io|
        fetch(uri) do |stream, _|
          buffer = Bytes.new(CHUNK_BYTES)
          written = 0_i64
          loop do
            read = stream.read(buffer)
            break if read.zero?
            written += read
            if written > MAX_TEXT_BYTES
              raise TrustError.new("Response exceeds the maximum size of #{MAX_TEXT_BYTES} bytes: #{PublicUrl.from(url)}")
            end
            io.write(buffer[0, read])
          end
        end
      end
      body
    end

    # Validates transport rules. Applied to the request URL and again to the
    # final URL after redirects.
    def validate(url : String) : URI
      uri = begin
        URI.parse(url)
      rescue URI::Error
        raise TrustError.new("Not a valid URL: #{PublicUrl.from(url)}")
      end

      unless uri.scheme.try(&.downcase) == "https"
        raise TrustError.new("Download URL must use https: #{PublicUrl.from(url)}")
      end
      if uri.host.nil? || uri.host.try(&.empty?)
        raise TrustError.new("Download URL must include a host: #{PublicUrl.from(url)}")
      end
      if uri.user || uri.password
        # Credentials in a URL end up in process listings and error text, so
        # they are refused rather than redacted after the fact.
        raise TrustError.new("Download URL must not include user-info: #{PublicUrl.from(url)}")
      end

      uri
    end

    # Follows redirects manually so each hop is re-validated. A redirect that
    # downgrades to HTTP, or grows credentials, is refused rather than followed.
    MAX_REDIRECTS = 5

    private def fetch(uri : URI, & : IO, Int64? ->) : Nil
      current = uri

      MAX_REDIRECTS.times do
        redirect = @transport.get(current, CONNECT_TIMEOUT, READ_TIMEOUT) do |body, declared|
          yield body, declared
        end
        return unless redirect

        # Re-validated rather than merely resolved: a redirect that downgrades
        # to HTTP, or that grows credentials, is refused rather than followed.
        current = validate(current.resolve(redirect).to_s)
      end

      raise TrustError.new("Too many redirects for #{PublicUrl.from(uri.to_s)}")
    end
  end

  # Verifies a detached OpenPGP signature against an explicitly trusted signer.
  #
  # A zero exit from gpg is deliberately not sufficient. gpg reports success
  # for a signature made by any key it happens to have, so the machine-readable
  # status output is parsed and every VALIDSIG must name the configured signer.
  module SignatureVerifier
    extend self

    VERIFY_TIMEOUT = 1.minute

    # Statuses that mean the signature is bad, expired, revoked, or unknown.
    REJECTED = %w[BADSIG ERRSIG EXPSIG EXPKEYSIG REVKEYSIG KEYEXPIRED SIGEXPIRED NODATA NO_PUBKEY]

    # RSA-encrypt-or-sign, RSA-sign, ECDSA, legacy EdDSA, Ed25519, Ed448.
    ALLOWED_PUBLIC_KEY_ALGORITHMS = Set{1, 3, 19, 22, 27, 28}

    # SHA-256, SHA-384, SHA-512. SHA-1 is deliberately absent.
    ALLOWED_HASH_ALGORITHMS = Set{8, 9, 10}

    def verify(artifact : String, signature : String, signer : Fingerprint, runner : ShellRunner) : Nil
      unless runner.command_exists?("gpg")
        raise TrustError.new("gpg is not on PATH, so the signature cannot be verified")
      end

      result = runner.run(Command.new(
        ["gpg", "--batch", "--no-tty", "--status-fd=1", "--verify", signature, artifact],
        timeout: VERIFY_TIMEOUT))

      statuses = result.stdout.lines.compact_map do |line|
        next unless line.starts_with?("[GNUPG:] ")
        line.lchop("[GNUPG:] ").strip.split(/\s+/)
      end

      unless result.success?
        raise TrustError.new("Signature verification failed: #{result.detail.presence || "gpg exited #{result.exit_code}"}")
      end

      if rejected = statuses.find { |fields| REJECTED.includes?(fields.first?) }
        raise TrustError.new("Signature verification reported #{rejected.first}")
      end

      valid = statuses.select { |fields| fields.first? == "VALIDSIG" }
      raise TrustError.new("Signature status is missing VALIDSIG") if valid.empty?

      valid.each { |fields| check_valid_signature(fields, signer) }
    end

    # GnuPG's documented VALIDSIG layout, after the status keyword:
    #
    #   1 fingerprint      2 creation date   3 timestamp   4 expiry
    #   5 version          6 reserved        7 pubkey-algo 8 hash-algo
    #   9 sig-class       10 primary key fingerprint
    #
    # The primary fingerprint is the last field and may be absent on very old
    # gpg, which is the only reason 10 fields is accepted alongside 11.
    private def check_valid_signature(fields : Array(String), signer : Fingerprint) : Nil
      unless fields.size == 10 || fields.size == 11
        raise TrustError.new("Signature reported a malformed VALIDSIG status")
      end

      # Three distinct causes, reported separately and naming the value seen.
      # They shared one message, which fired at exactly the moment a real user
      # needs to know whether the problem is their key algorithm, their digest
      # algorithm, or a gpg that wrote something unparseable — and the numbers
      # were already in scope.
      public_key = fields[7]?.try(&.to_i?)
      hash = fields[8]?.try(&.to_i?)

      unless public_key && hash
        raise TrustError.new(
          "VALIDSIG algorithm fields are not integers: " \
          "pubkey=#{fields[7]?.inspect} hash=#{fields[8]?.inspect}")
      end

      unless ALLOWED_PUBLIC_KEY_ALGORITHMS.includes?(public_key)
        raise TrustError.new(
          "Signature uses public-key algorithm #{public_key}, which is not accepted " \
          "(allowed: #{ALLOWED_PUBLIC_KEY_ALGORITHMS.to_a.sort!.join(", ")})")
      end

      unless ALLOWED_HASH_ALGORITHMS.includes?(hash)
        raise TrustError.new(
          "Signature uses hash algorithm #{hash}, which is not accepted " \
          "(allowed: #{ALLOWED_HASH_ALGORITHMS.to_a.sort!.join(", ")}; SHA-1 is deliberately absent)")
      end

      # The signing key, and the primary key it belongs to when reported.
      # A profile may legitimately pin either.
      signing = fields[1]
      primary = fields[10]?

      return if signer.matches?(signing)
      return if primary && signer.matches?(primary)

      raise TrustError.new("Signature was not made by the configured allowed signer #{signer}")
    end
  end

  # Parses a `sha256sum`-style checksum document.
  #
  # A checksum document is never a trust anchor on its own — it is served by
  # the same host as the artifact — so this only ever supplements a
  # signer-bound signature.
  module ChecksumDocument
    extend self

    def digest_for(body : String, asset : String) : String
      lines = body.lines.map(&.strip).reject(&.empty?)

      # A document containing exactly one bare digest names its asset by
      # context rather than in the file.
      if lines.size == 1 && lines.first.matches?(/\A[0-9a-fA-F]{64}\z/)
        return lines.first.downcase
      end

      matches = lines.compact_map do |line|
        fields = line.split(/\s+/, 2)
        next unless fields.size == 2
        next unless normalize(fields[1]) == asset
        fields[0].downcase
      end

      case matches.size
      when 0 then raise TrustError.new("Checksum document has no entry for #{asset}")
      when 1
        digest = matches.first
        unless digest.matches?(/\A[0-9a-f]{64}\z/)
          raise TrustError.new("Malformed SHA-256 entry for #{asset}")
        end
        digest
      else
        # Two different digests for one name means the document is either
        # corrupt or crafted, and picking one would be a guess.
        raise TrustError.new("Checksum document has duplicate entries for #{asset}")
      end
    end

    # `sha256sum` writes a leading `*` for binary mode; some tools prefix `./`.
    private def normalize(name : String) : String
      cleaned = name.strip.lchop('*').lchop("./")
      File.basename(cleaned)
    end
  end

  # Replays canned responses, the way `FakeShellRunner` replays canned results.
  #
  # Shipped beside the real transport rather than kept in the specs because it
  # is what makes the download-verify-install path reachable at all: without it
  # every `execute` on a fetching executor would make a real HTTPS request, so
  # none of them had a spec.
  class FakeHttpTransport < HttpTransport
    # Every URL requested, in order, including each redirect hop — which is how
    # a spec asserts that a redirect was actually re-validated and followed.
    getter requested : Array(String)

    def initialize
      @requested = [] of String
      @bodies = {} of String => String
      @redirects = {} of String => String
      @declared = {} of String => Int64?
    end

    # Serves `body` for `url`. By default the declared length matches what is
    # served; pass `declared` to simulate a truncated or lying response.
    def on(url : String, body : String, declared : Int64? = nil) : self
      @bodies[url] = body
      @declared[url] = declared || body.bytesize.to_i64
      self
    end

    # Serves a redirect from `url` to `location`.
    def redirect(url : String, location : String) : self
      @redirects[url] = location
      self
    end

    def get(uri : URI, connect_timeout : Time::Span, read_timeout : Time::Span,
            & : IO, Int64? ->) : String?
      url = uri.to_s
      @requested << url

      if location = @redirects[url]?
        return location
      end

      body = @bodies[url]?
      unless body
        raise TrustError.new("Download failed with HTTP 404 for #{PublicUrl.from(url)}")
      end

      yield IO::Memory.new(body), @declared[url]
      nil
    end
  end
end
