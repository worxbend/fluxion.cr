require "../spec_helper"

private alias Downloader = Fluxion::Executor::Downloader

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

private def runner_with(stdout : String, exit_code : Int32 = 0)
  Fluxion::Executor::FakeShellRunner.new
    .available("gpg")
    .default(Fluxion::ProcessResult.new(exit_code, stdout))
end
