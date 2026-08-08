require "../spec_helper"

# The rules Downloader exists to enforce — the streaming size ceiling, the
# truncation check, the digest over what was actually written, the refusal to
# leave a partial file, and redirect re-validation — could not be reached
# before the transport became injectable, because every one of them needs a
# response body. docs/architecture.md calls these mandatory; this is what
# checks them.
private alias Downloader = Fluxion::Executor::Downloader
private alias FakeTransport = Fluxion::Executor::FakeHttpTransport

private def with_tempdir(& : String -> T) : T forall T
  directory = File.tempname("fluxion-download")
  Dir.mkdir_p(directory, 0o700)
  begin
    yield directory
  ensure
    FileUtils.rm_rf(directory)
  end
end

private def sha256(text : String) : String
  Digest::SHA256.hexdigest(text)
end

describe "Downloader over an injected transport" do
  describe "#download" do
    it "writes the body and returns its digest" do
      with_tempdir do |directory|
        transport = FakeTransport.new.on("https://example.test/rg", "ripgrep-bytes")
        destination = File.join(directory, "rg")

        digest = Downloader.new(transport: transport).download("https://example.test/rg", destination)

        File.read(destination).should eq("ripgrep-bytes")
        digest.should eq(sha256("ripgrep-bytes"))
      end
    end

    it "refuses a body larger than the ceiling, and leaves no file behind" do
      # Enforced while streaming rather than after, so a hostile server cannot
      # exhaust the disk before the check runs.
      with_tempdir do |directory|
        transport = FakeTransport.new.on("https://example.test/big", "x" * 5_000)
        destination = File.join(directory, "big")

        expect_raises(Fluxion::TrustError, /exceeds the maximum size/) do
          Downloader.new(max_bytes: 1_000_i64, transport: transport)
            .download("https://example.test/big", destination)
        end

        File.exists?(destination).should be_false
      end
    end

    it "refuses a declared length larger than the ceiling before reading a byte" do
      with_tempdir do |directory|
        transport = FakeTransport.new.on("https://example.test/big", "small", declared: 5_000_i64)

        expect_raises(Fluxion::TrustError, /exceeds the maximum size/) do
          Downloader.new(max_bytes: 1_000_i64, transport: transport)
            .download("https://example.test/big", File.join(directory, "big"))
        end
      end
    end

    it "treats a short read as truncation rather than a small file" do
      # A truncated response would otherwise digest cleanly as whatever arrived.
      with_tempdir do |directory|
        transport = FakeTransport.new.on("https://example.test/rg", "half", declared: 99_i64)
        destination = File.join(directory, "rg")

        expect_raises(Fluxion::TrustError, /truncated/) do
          Downloader.new(transport: transport).download("https://example.test/rg", destination)
        end

        File.exists?(destination).should be_false
      end
    end
  end

  describe "#download_verified" do
    it "keeps a file whose digest matches" do
      with_tempdir do |directory|
        transport = FakeTransport.new.on("https://example.test/rg", "bytes")
        destination = File.join(directory, "rg")
        checksum = Fluxion::Checksum.new(Fluxion::ChecksumAlgorithm::Sha256, sha256("bytes"))

        Downloader.new(transport: transport)
          .download_verified("https://example.test/rg", destination, checksum)

        File.read(destination).should eq("bytes")
      end
    end

    it "deletes the file when the digest does not match" do
      # There must be no code path that leaves an unverified artifact on disk.
      with_tempdir do |directory|
        transport = FakeTransport.new.on("https://example.test/rg", "tampered")
        destination = File.join(directory, "rg")
        checksum = Fluxion::Checksum.new(Fluxion::ChecksumAlgorithm::Sha256, sha256("expected"))

        expect_raises(Fluxion::TrustError, /Checksum mismatch/) do
          Downloader.new(transport: transport)
            .download_verified("https://example.test/rg", destination, checksum)
        end

        File.exists?(destination).should be_false
      end
    end
  end

  describe "redirects" do
    it "follows a redirect and re-validates the hop" do
      with_tempdir do |directory|
        transport = FakeTransport.new
          .redirect("https://example.test/rg", "https://cdn.example.test/rg")
        transport.on("https://cdn.example.test/rg", "bytes")

        Downloader.new(transport: transport)
          .download("https://example.test/rg", File.join(directory, "rg"))

        transport.requested.should eq([
          "https://example.test/rg",
          "https://cdn.example.test/rg",
        ])
      end
    end

    it "refuses a redirect that downgrades to HTTP" do
      # A redirect is an attacker-controllable hop, so each one is re-checked
      # against the same rules as the original URL.
      with_tempdir do |directory|
        transport = FakeTransport.new
          .redirect("https://example.test/rg", "http://cdn.example.test/rg")

        expect_raises(Fluxion::TrustError, /must use https/) do
          Downloader.new(transport: transport)
            .download("https://example.test/rg", File.join(directory, "rg"))
        end
      end
    end

    it "refuses a redirect that grows credentials" do
      with_tempdir do |directory|
        transport = FakeTransport.new
          .redirect("https://example.test/rg", "https://user:hunter2@cdn.example.test/rg")

        error = expect_raises(Fluxion::TrustError, /must not include user-info/) do
          Downloader.new(transport: transport)
            .download("https://example.test/rg", File.join(directory, "rg"))
        end
        error.message.to_s.should_not contain("hunter2")
      end
    end

    it "gives up rather than following a redirect loop" do
      with_tempdir do |directory|
        transport = FakeTransport.new
          .redirect("https://example.test/rg", "https://example.test/rg")

        expect_raises(Fluxion::TrustError, /Too many redirects/) do
          Downloader.new(transport: transport)
            .download("https://example.test/rg", File.join(directory, "rg"))
        end

        transport.requested.size.should eq(Downloader::MAX_REDIRECTS)
      end
    end
  end
end
