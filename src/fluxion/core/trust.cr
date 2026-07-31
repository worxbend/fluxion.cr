module Fluxion
  # Digest algorithms accepted for pinning remote artifacts. SHA-256 is the
  # only one currently supported: adding weaker digests would let a profile
  # opt into a trust level Fluxion cannot honestly claim to enforce.
  enum ChecksumAlgorithm
    Sha256

    def self.from_config?(value : String?) : self?
      return unless value
      case value.strip.downcase.delete('-').delete('_')
      when "sha256" then Sha256
      end
    end

    def config_name : String
      case self
      in .sha256? then "sha256"
      end
    end

    def hex_length : Int32
      case self
      in .sha256? then 64
      end
    end

    def to_s(io : IO) : Nil
      io << config_name
    end
  end

  # A digest a profile pins a remote artifact to. Constructing one normalizes
  # the hex to lowercase; `parse` rejects anything that is not exactly the
  # right number of hex digits so a truncated paste fails at validation rather
  # than at download time.
  struct Checksum
    HEX_PATTERN = /\A[0-9a-f]+\z/

    getter algorithm : ChecksumAlgorithm
    getter value : String

    def initialize(@algorithm : ChecksumAlgorithm, value : String)
      @value = value.strip.downcase
    end

    # Returns the checksum, or a message explaining why the literal is not a
    # usable digest. Callers turn that message into a `Diagnostic`.
    def self.parse(algorithm : ChecksumAlgorithm, value : String) : Checksum | String
      normalized = value.strip.downcase
      unless normalized.matches?(HEX_PATTERN)
        return "must be a lowercase hexadecimal digest"
      end
      unless normalized.size == algorithm.hex_length
        return "must be #{algorithm.hex_length} hex characters for #{algorithm}, got #{normalized.size}"
      end
      new(algorithm, normalized)
    end

    def matches?(digest : String) : Bool
      # Length is fixed and both sides are normalized hex, so a constant-time
      # compare is cheap insurance against timing oracles in future callers.
      other = digest.strip.downcase
      return false unless other.bytesize == @value.bytesize
      difference = 0_u8
      @value.to_slice.each_with_index { |byte, index| difference |= byte ^ other.to_slice[index] }
      difference == 0
    end

    def to_s(io : IO) : Nil
      io << @algorithm << ':' << @value
    end
  end

  # An OpenPGP primary or signing key fingerprint a profile explicitly trusts.
  # Stored uppercase without separators, which is how GPG's machine-readable
  # status channel reports it.
  struct Fingerprint
    V4_LENGTH = 40
    V5_LENGTH = 64

    getter value : String

    def initialize(value : String)
      @value = normalize(value)
    end

    def self.parse(value : String) : Fingerprint | String
      normalized = value.gsub(/[\s:]/, "").upcase
      unless normalized.matches?(/\A[0-9A-F]+\z/)
        return "must be a hexadecimal OpenPGP fingerprint"
      end
      unless normalized.size == V4_LENGTH || normalized.size == V5_LENGTH
        return "must be a #{V4_LENGTH}-hex (OpenPGP v4) or #{V5_LENGTH}-hex (OpenPGP v5) fingerprint, got #{normalized.size}"
      end
      new(normalized)
    end

    def matches?(other : String) : Bool
      @value == normalize(other)
    end

    def to_s(io : IO) : Nil
      io << @value
    end

    private def normalize(value : String) : String
      value.gsub(/[\s:]/, "").upcase
    end
  end

  # How a downloaded artifact earns the right to be executed or installed.
  #
  # A `checksumUrl` alone is deliberately not a member: fetching the expected
  # digest from the same host that serves the artifact proves nothing, so it is
  # supplemental metadata that must accompany one of these modes.
  abstract struct TrustAnchor
    # A literal SHA-256 pinned in the profile.
    struct Digest < TrustAnchor
      getter checksum : Checksum

      def initialize(@checksum : Checksum)
      end

      def to_s(io : IO) : Nil
        io << @checksum
      end
    end

    # A detached OpenPGP signature bound to a specific signer. Both halves are
    # required: a valid signature from an unknown key is not trust.
    struct Signature < TrustAnchor
      getter signature_url : String
      getter signer : Fingerprint

      def initialize(@signature_url : String, @signer : Fingerprint)
      end

      def to_s(io : IO) : Nil
        io << "signature by " << @signer
      end
    end
  end
end
