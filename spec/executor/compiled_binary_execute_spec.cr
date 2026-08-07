require "../spec_helper"

# The download -> verify -> install path, end to end, with no network.
#
# docs/architecture.md calls this ordering mandatory — "nothing hands an
# unverified path to anything that executes or installs it" — but until the
# transport became injectable no spec could reach `execute` at all, because
# every call made a real HTTPS request. This is the check that was missing.

# The executor with its transport substituted, exactly as a caller would do it.
private class FakeFetchingExecutor < Fluxion::Executor::CompiledBinaryExecutor
  def initialize(@transport : Fluxion::Executor::FakeHttpTransport)
    super()
  end

  protected def http_transport : Fluxion::Executor::HttpTransport
    @transport
  end
end

private def sha256(text : String) : String
  Digest::SHA256.hexdigest(text)
end

private def binary_step(install_path : String, digest : String,
                        url : String = "https://example.test/rg")
  Fluxion::CompiledBinaryStep.new(
    name: "ripgrep",
    binary_name: "rg",
    url: url,
    trust: Fluxion::TrustAnchor::Digest.new(
      Fluxion::Checksum.new(Fluxion::ChecksumAlgorithm::Sha256, digest)),
    install_path: install_path,
    format: Fluxion::ArtifactFormat::PlainBinary,
  )
end

private def run_execute(step, transport)
  executor = FakeFetchingExecutor.new(transport)
  item = executor.items(step).first
  executor.execute(step, item, Fluxion::Executor::FakeShellRunner.new) { }
end

private def with_tempdir(& : String -> T) : T forall T
  directory = File.tempname("fluxion-install")
  Dir.mkdir_p(directory, 0o700)
  begin
    yield directory
  ensure
    FileUtils.rm_rf(directory)
  end
end

describe Fluxion::Executor::CompiledBinaryExecutor do
  it "downloads, verifies, and installs a raw binary" do
    with_tempdir do |directory|
      body = "#!/bin/sh\necho rg\n"
      transport = Fluxion::Executor::FakeHttpTransport.new.on("https://example.test/rg", body)
      destination = File.join(directory, "rg")

      result = run_execute(binary_step(destination, sha256(body)), transport)

      result.should be_a(Fluxion::StepResult::Success)
      File.read(destination).should eq(body)
      File.info(destination).permissions.owner_execute?.should be_true
    end
  end

  it "records the digest of what it installed" do
    with_tempdir do |directory|
      body = "bytes"
      transport = Fluxion::Executor::FakeHttpTransport.new.on("https://example.test/rg", body)

      result = run_execute(binary_step(File.join(directory, "rg"), sha256(body)), transport)

      result.as(Fluxion::StepResult::Success).checksum.should eq(sha256(body))
    end
  end

  it "installs nothing when the digest does not match" do
    # The whole point of the ordering: a mismatch must fail before anything is
    # placed at the install path.
    with_tempdir do |directory|
      transport = Fluxion::Executor::FakeHttpTransport.new.on("https://example.test/rg", "tampered")
      destination = File.join(directory, "rg")

      result = run_execute(binary_step(destination, sha256("expected")), transport)

      result.should be_a(Fluxion::StepResult::Failure)
      result.as(Fluxion::StepResult::Failure).error_message.should match(/Checksum mismatch/)
      File.exists?(destination).should be_false
    end
  end

  it "leaves an existing binary untouched when the download fails" do
    # Installation renames into place last, so a failed fetch must not disturb
    # whatever was already there.
    with_tempdir do |directory|
      destination = File.join(directory, "rg")
      File.write(destination, "the previous version")

      transport = Fluxion::Executor::FakeHttpTransport.new # serves nothing: 404
      result = run_execute(binary_step(destination, sha256("whatever")), transport)

      result.should be_a(Fluxion::StepResult::Failure)
      File.read(destination).should eq("the previous version")
    end
  end

  it "follows a redirect to the real asset" do
    with_tempdir do |directory|
      body = "bytes"
      transport = Fluxion::Executor::FakeHttpTransport.new
        .redirect("https://example.test/rg", "https://cdn.example.test/rg")
      transport.on("https://cdn.example.test/rg", body)

      result = run_execute(binary_step(File.join(directory, "rg"), sha256(body)), transport)

      result.should be_a(Fluxion::StepResult::Success)
      transport.requested.last.should eq("https://cdn.example.test/rg")
    end
  end

  it "refuses a redirect that downgrades to HTTP" do
    with_tempdir do |directory|
      transport = Fluxion::Executor::FakeHttpTransport.new
        .redirect("https://example.test/rg", "http://cdn.example.test/rg")
      destination = File.join(directory, "rg")

      result = run_execute(binary_step(destination, sha256("bytes")), transport)

      result.should be_a(Fluxion::StepResult::Failure)
      result.as(Fluxion::StepResult::Failure).error_message.should match(/must use https/)
      File.exists?(destination).should be_false
    end
  end

  it "fails the item rather than the run when the host is unreachable" do
    with_tempdir do |directory|
      transport = Fluxion::Executor::FakeHttpTransport.new
      destination = File.join(directory, "rg")

      result = run_execute(binary_step(destination, sha256("bytes")), transport)

      # A Failure, not a raised exception: the orchestrator decides what one
      # failed item means for the rest of the run.
      result.should be_a(Fluxion::StepResult::Failure)
    end
  end
end
