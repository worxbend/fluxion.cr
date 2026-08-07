require "../spec_helper"

private alias Downloader = Fluxion::Executor::Downloader
private alias ChecksumDocument = Fluxion::Executor::ChecksumDocument

describe Fluxion::Executor::Downloader do
  describe "#validate" do
    downloader = Downloader.new

    it "accepts an ordinary HTTPS URL" do
      downloader.validate("https://example.test/rg.tar.gz").host.should eq("example.test")
    end

    it "refuses plain HTTP" do
      expect_raises(Fluxion::TrustError, /must use https/) do
        downloader.validate("http://example.test/rg")
      end
    end

    it "refuses a URL with no host" do
      expect_raises(Fluxion::TrustError, /must include a host/) do
        downloader.validate("https:///rg")
      end
    end

    it "refuses credentials in the URL" do
      # They would end up in process listings and error text, so they are
      # rejected outright rather than redacted afterwards.
      expect_raises(Fluxion::TrustError, /must not include user-info/) do
        downloader.validate("https://user:hunter2@example.test/rg")
      end
    end

    it "keeps the password out of its own error message" do
      error = expect_raises(Fluxion::TrustError) do
        downloader.validate("https://user:hunter2@example.test/rg")
      end
      error.message.not_nil!.should_not contain("hunter2")
    end

    it "refuses something that is not a URL at all" do
      expect_raises(Fluxion::TrustError, /must use https/) do
        downloader.validate("not a url")
      end
    end
  end
end

describe Fluxion::Executor::ChecksumDocument do
  digest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

  it "reads a bare single-digest document" do
    ChecksumDocument.digest_for("#{digest}\n", "rg.tar.gz").should eq(digest)
  end

  it "finds the entry naming the asset" do
    body = <<-BODY
      1111111111111111111111111111111111111111111111111111111111111111  other.tar.gz
      #{digest}  rg.tar.gz
      BODY
    ChecksumDocument.digest_for(body, "rg.tar.gz").should eq(digest)
  end

  it "handles the binary-mode asterisk sha256sum writes" do
    ChecksumDocument.digest_for("#{digest} *rg.tar.gz\n", "rg.tar.gz").should eq(digest)
  end

  it "handles a ./ prefix" do
    ChecksumDocument.digest_for("#{digest}  ./rg.tar.gz\n", "rg.tar.gz").should eq(digest)
  end

  it "matches on the basename so a path prefix does not hide the entry" do
    ChecksumDocument.digest_for("#{digest}  dist/rg.tar.gz\n", "rg.tar.gz").should eq(digest)
  end

  it "refuses a document with no matching entry" do
    expect_raises(Fluxion::TrustError, /no entry for rg.tar.gz/) do
      ChecksumDocument.digest_for("#{digest}  other.tar.gz\n", "rg.tar.gz")
    end
  end

  it "refuses two different digests for one asset rather than guessing" do
    body = <<-BODY
      #{digest}  rg.tar.gz
      1111111111111111111111111111111111111111111111111111111111111111  rg.tar.gz
      BODY
    expect_raises(Fluxion::TrustError, /duplicate entries/) do
      ChecksumDocument.digest_for(body, "rg.tar.gz")
    end
  end

  it "refuses a malformed digest" do
    expect_raises(Fluxion::TrustError, /Malformed SHA-256/) do
      ChecksumDocument.digest_for("notahex  rg.tar.gz\n", "rg.tar.gz")
    end
  end
end

private def runner_with(stdout : String, exit_code : Int32 = 0)
  Fluxion::Executor::FakeShellRunner.new
    .available("gpg")
    .default(Fluxion::ProcessResult.new(exit_code, stdout))
end

describe Fluxion::Executor::SignatureVerifier do
  signer = Fluxion::Fingerprint.new("BC528686B50D79E339D3721CEB3E94ADBE1229CF")

  it "accepts a signature from the configured signer" do
    status = "[GNUPG:] VALIDSIG BC528686B50D79E339D3721CEB3E94ADBE1229CF 2026-08-01 1754000000 0 4 0 1 8 00 " \
             "BC528686B50D79E339D3721CEB3E94ADBE1229CF\n"
    Fluxion::Executor::SignatureVerifier.verify("a", "a.asc", signer, runner_with(status))
  end

  it "refuses a valid signature from a different key" do
    # gpg exits zero for any key it happens to have, which is exactly why the
    # status output is parsed rather than the exit code trusted.
    status = "[GNUPG:] VALIDSIG AAAA5686B50D79E339D3721CEB3E94ADBE1229CF 2026-08-01 1754000000 0 4 0 1 8 00 " \
             "AAAA5686B50D79E339D3721CEB3E94ADBE1229CF\n"
    expect_raises(Fluxion::TrustError, /not made by the configured allowed signer/) do
      Fluxion::Executor::SignatureVerifier.verify("a", "a.asc", signer, runner_with(status))
    end
  end

  it "refuses a run with no VALIDSIG at all" do
    expect_raises(Fluxion::TrustError, /missing VALIDSIG/) do
      Fluxion::Executor::SignatureVerifier.verify("a", "a.asc", signer, runner_with("[GNUPG:] NEWSIG\n"))
    end
  end

  it "refuses a reported bad signature" do
    expect_raises(Fluxion::TrustError, /BADSIG/) do
      Fluxion::Executor::SignatureVerifier.verify("a", "a.asc", signer,
        runner_with("[GNUPG:] BADSIG AAAA nobody\n"))
    end
  end

  it "refuses a weak hash algorithm, naming it" do
    # The hash algorithm is the eighth field; 2 is SHA-1.
    status = "[GNUPG:] VALIDSIG BC528686B50D79E339D3721CEB3E94ADBE1229CF 2026-08-01 1754000000 0 4 0 1 2 00 " \
             "BC528686B50D79E339D3721CEB3E94ADBE1229CF\n"
    error = expect_raises(Fluxion::TrustError, /hash algorithm 2, which is not accepted/) do
      Fluxion::Executor::SignatureVerifier.verify("a", "a.asc", signer, runner_with(status))
    end
    # Reported separately from the public-key case, so the reader knows which
    # of the two was the problem.
    error.message.to_s.should_not contain("public-key algorithm")
  end

  it "refuses an unaccepted public-key algorithm, naming it" do
    # The seventh field is the public-key algorithm; 20 is ElGamal sign+encrypt.
    status = "[GNUPG:] VALIDSIG BC528686B50D79E339D3721CEB3E94ADBE1229CF 2026-08-01 1754000000 0 4 0 20 8 00 " \
             "BC528686B50D79E339D3721CEB3E94ADBE1229CF\n"
    expect_raises(Fluxion::TrustError, /public-key algorithm 20, which is not accepted/) do
      Fluxion::Executor::SignatureVerifier.verify("a", "a.asc", signer, runner_with(status))
    end
  end

  it "distinguishes an unparseable algorithm field from a rejected one" do
    status = "[GNUPG:] VALIDSIG BC528686B50D79E339D3721CEB3E94ADBE1229CF 2026-08-01 1754000000 0 4 0 x 8 00 " \
             "BC528686B50D79E339D3721CEB3E94ADBE1229CF\n"
    expect_raises(Fluxion::TrustError, /algorithm fields are not integers/) do
      Fluxion::Executor::SignatureVerifier.verify("a", "a.asc", signer, runner_with(status))
    end
  end

  it "reports a nonzero gpg exit" do
    expect_raises(Fluxion::TrustError, /Signature verification failed/) do
      Fluxion::Executor::SignatureVerifier.verify("a", "a.asc", signer, runner_with("", 2))
    end
  end

  it "refuses when gpg is not installed rather than skipping verification" do
    runner = Fluxion::Executor::FakeShellRunner.new
    expect_raises(Fluxion::TrustError, /gpg is not on PATH/) do
      Fluxion::Executor::SignatureVerifier.verify("a", "a.asc", signer, runner)
    end
  end
end
