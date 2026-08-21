require "../spec_helper"

# The closed error set is only closed if stdlib IO failures are translated on
# their way out of each layer. These specs pin the three places where an
# `IO::Error` used to escape untranslated and be reported as a successful run.
describe "IO error boundaries" do
  describe Fluxion::CLI::App do
    it "swallows a broken pipe, because the reader is already gone" do
      broken = IO::Error.from_os_error("write", Errno::EPIPE)

      Fluxion::CLI::App.broken_pipe?(broken).should be_true
    end

    it "does not treat a missing file or a refused connection as a broken pipe" do
      denied = File::Error.from_os_error("open", Errno::EACCES, file: "/etc/x")
      refused = IO::Error.from_os_error("connect", Errno::ECONNREFUSED)

      Fluxion::CLI::App.broken_pipe?(denied).should be_false
      Fluxion::CLI::App.broken_pipe?(refused).should be_false
      Fluxion::CLI::App.broken_pipe?(IO::TimeoutError.new("read timed out")).should be_false
    end

    it "classifies an untranslated filesystem error as the filesystem exit code" do
      # Reachable again now that `run` re-raises everything but EPIPE. While the
      # blanket rescue stood, this branch of `exit_code_for` was dead code.
      denied = File::Error.from_os_error("open", Errno::EACCES, file: "/etc/x")
      Fluxion::CLI.exit_code_for(denied).should eq(Fluxion::CLI::ExitCode::IoError)
    end
  end

  describe Fluxion::State::Store do
    it "translates an unreadable state file into the state layer's vocabulary" do
      # The premise is a file the process cannot read, and `chmod 000` does not
      # make a file unreadable to root. CI runs as root in a container, where
      # the read simply succeeds and there is no error to translate.
      pending! "already root" if Fluxion::Host.root?

      directory = File.tempname("fluxion-unreadable")
      Dir.mkdir_p(directory)
      file = File.join(directory, "default.state.json")
      File.write(file, %({"schemaVersion":1,"profile":"default"}))
      File.chmod(file, 0o000)

      begin
        # Without the translation this raised `File::Error`, which is an
        # `IO::Error` and so was swallowed by the CLI as exit 0.
        expect_raises(Fluxion::ExecutionError, /Failed to read state file/) do
          Fluxion::State::Store.new(directory).load("default")
        end
      ensure
        File.chmod(file, 0o600)
        FileUtils.rm_rf(directory)
      end
    end
  end

  describe Fluxion::Executor::Downloader do
    it "translates a refused connection into an ExecutionError" do
      # Port 1 on loopback refuses immediately, so this stays fast and needs no
      # network. The point is the error type: executors rescue `Fluxion::Error`,
      # so an untranslated `Socket::ConnectError` bypassed the per-item failure
      # boundary and aborted the whole run.
      expect_raises(Fluxion::ExecutionError, /Could not fetch/) do
        Fluxion::Executor::Downloader.new.download("https://127.0.0.1:1/nothing", File.tempname("fluxion-refused"))
      end
    end

    it "keeps the redacted URL in the message" do
      error = expect_raises(Fluxion::ExecutionError) do
        Fluxion::Executor::Downloader.new.download("https://127.0.0.1:1/secret-path", File.tempname("fluxion-refused"))
      end
      error.message.to_s.should contain("127.0.0.1")
    end
  end
end
