require "../spec_helper"

VALID_SHA256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

describe Fluxion::Checksum do
  it "accepts a 64-character lowercase digest" do
    result = Fluxion::Checksum.parse(Fluxion::ChecksumAlgorithm::Sha256, VALID_SHA256)
    result.should be_a(Fluxion::Checksum)
    result.as(Fluxion::Checksum).value.should eq(VALID_SHA256)
  end

  it "normalizes case and surrounding whitespace" do
    result = Fluxion::Checksum.parse(Fluxion::ChecksumAlgorithm::Sha256, "  #{VALID_SHA256.upcase}  ")
    result.as(Fluxion::Checksum).value.should eq(VALID_SHA256)
  end

  it "rejects a truncated digest with a length-specific message" do
    result = Fluxion::Checksum.parse(Fluxion::ChecksumAlgorithm::Sha256, VALID_SHA256[0, 63])
    result.should be_a(String)
    result.as(String).should contain("64 hex characters")
    result.as(String).should contain("got 63")
  end

  it "rejects non-hexadecimal characters" do
    result = Fluxion::Checksum.parse(Fluxion::ChecksumAlgorithm::Sha256, "z" * 64)
    result.as(String).should contain("hexadecimal")
  end

  it "compares digests case-insensitively" do
    checksum = Fluxion::Checksum.new(Fluxion::ChecksumAlgorithm::Sha256, VALID_SHA256)
    checksum.matches?(VALID_SHA256.upcase).should be_true
    checksum.matches?(VALID_SHA256.sub("0", "1")).should be_false
  end

  it "does not match a digest of a different length" do
    checksum = Fluxion::Checksum.new(Fluxion::ChecksumAlgorithm::Sha256, VALID_SHA256)
    checksum.matches?("abc").should be_false
  end
end

describe Fluxion::ChecksumAlgorithm do
  it "accepts the separator spellings a profile might use" do
    %w[sha256 SHA-256 SHA_256 Sha256].each do |spelling|
      Fluxion::ChecksumAlgorithm.from_config?(spelling).should eq(Fluxion::ChecksumAlgorithm::Sha256)
    end
  end

  it "rejects weaker algorithms" do
    Fluxion::ChecksumAlgorithm.from_config?("sha1").should be_nil
    Fluxion::ChecksumAlgorithm.from_config?("md5").should be_nil
  end
end

describe Fluxion::Fingerprint do
  v4 = "BC528686B50D79E339D3721CEB3E94ADBE1229CF"

  it "accepts a v4 fingerprint" do
    Fluxion::Fingerprint.parse(v4).should be_a(Fluxion::Fingerprint)
  end

  it "accepts a v5 fingerprint" do
    Fluxion::Fingerprint.parse("A" * 64).should be_a(Fluxion::Fingerprint)
  end

  it "strips the spacing GPG prints fingerprints with" do
    spaced = "BC52 8686 B50D 79E3 39D3  721C EB3E 94AD BE12 29CF"
    Fluxion::Fingerprint.parse(spaced).as(Fluxion::Fingerprint).value.should eq(v4)
  end

  it "rejects a short fingerprint, which is what makes collisions cheap" do
    result = Fluxion::Fingerprint.parse("BE1229CF")
    result.should be_a(String)
    result.as(String).should contain("40-hex")
  end

  it "matches case-insensitively and ignores separators" do
    fingerprint = Fluxion::Fingerprint.new(v4)
    fingerprint.matches?(v4.downcase).should be_true
    fingerprint.matches?("BC52:8686:B50D:79E3:39D3:721C:EB3E:94AD:BE12:29CF").should be_true
  end
end
