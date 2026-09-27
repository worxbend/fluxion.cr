require "../spec_helper"

# Both readers of a key file — the executor checking a download and the probe
# checking an installed keyring — ran `gpg --no-options --show-keys` against
# the account's own gpg home. `--no-options` stops gpg creating a missing
# `~/.gnupg`, so on a fresh account every `gpg-key` step failed with "could
# not read the key: … directory does not exist!" and every probe said
# unknown. Listing a key needs no keyring at all, so each read gets a
# throwaway home of its own.

private FINGERPRINT = "BC528686B50D79E339D3721CEB3E94ADBE1229CF"

private def listing(primary : String) : String
  <<-COLONS
    pub:-:2048:1:EB3E94ADBE1229CF:1446074508:::-:::scSC::::::23::0:
    fpr:::::::::#{primary}:

    COLONS
end

# Records, at the moment gpg runs, which home it was pointed at and whether
# that directory was there and private — a FakeShellRunner cannot see either
# after the fact, because the home is gone by then.
private class HomedirRecordingRunner < Fluxion::Executor::FakeShellRunner
  getter homes = [] of NamedTuple(path: String, existed: Bool, mode: Int32)

  def run(command : Fluxion::Executor::Command, &sink : String ->) : Fluxion::ProcessResult
    argv = command.argv
    if argv.first? == "gpg" && argv.includes?("--show-keys")
      if index = argv.index("--homedir")
        path = argv[index + 1]
        info = File.info?(path)
        mode = info ? info.permissions.value.to_i & 0o777 : 0
        @homes << {path: path, existed: !info.nil? && info.directory?, mode: mode}
      end
    end
    super(command, &sink)
  end
end

private def with_gpg_dir(& : String -> T) : T forall T
  directory = File.tempname("fluxion-gpg-spec")
  Dir.mkdir_p(directory, 0o700)
  begin
    yield directory
  ensure
    FileUtils.rm_rf(directory) rescue nil
  end
end

private def assert_private_throwaway_home(runner : HomedirRecordingRunner) : Nil
  runner.homes.size.should eq(1)
  home = runner.homes.first
  home[:existed].should be_true
  home[:mode].should eq(0o700)
  home[:path].should_not start_with(File.join(Path.home.to_s, ".gnupg"))
  # Nothing is left behind once the key has been read.
  Dir.exists?(home[:path]).should be_false
end

describe "gpg-key executor" do
  it "reads a downloaded key with a gpg home of its own" do
    with_gpg_dir do |directory|
      key_file = File.join(directory, "microsoft.asc")
      File.write(key_file, "armoured key")
      entry = Fluxion::GpgKeyEntry.new("file://#{key_file}", Fluxion::Fingerprint.new(FINGERPRINT))
      step = Fluxion::GpgKeyStep.new("repository-keys", [entry])

      runner = HomedirRecordingRunner.new
      runner.available("gpg").on("--show-keys", 0, listing(FINGERPRINT))
      subject = Fluxion::Executor::GpgKeyExecutor.new
      result = subject.execute(step, subject.items(step).first, runner) { }

      result.should be_a(Fluxion::StepResult::Success)
      assert_private_throwaway_home(runner)
      runner.ran?("sudo rpm --import").should be_true
    end
  end

  it "still refuses a key whose fingerprint differs" do
    with_gpg_dir do |directory|
      key_file = File.join(directory, "other.asc")
      File.write(key_file, "armoured key")
      entry = Fluxion::GpgKeyEntry.new("file://#{key_file}", Fluxion::Fingerprint.new(FINGERPRINT))
      step = Fluxion::GpgKeyStep.new("repository-keys", [entry])

      runner = HomedirRecordingRunner.new
      runner.available("gpg").on("--show-keys", 0, listing("0123456789ABCDEF0123456789ABCDEF01234567"))
      subject = Fluxion::Executor::GpgKeyExecutor.new
      result = subject.execute(step, subject.items(step).first, runner) { }

      result.should be_a(Fluxion::StepResult::Failure)
      result.as(Fluxion::StepResult::Failure).error_message.should contain("fingerprint mismatch")
      runner.ran?("rpm --import").should be_false
    end
  end
end

describe "gpg-key keyring probe homedir" do
  it "reads an installed keyring with a gpg home of its own" do
    with_gpg_dir do |directory|
      keyring = File.join(directory, "microsoft.gpg")
      File.write(keyring, "keyring bytes")
      entry = Fluxion::GpgKeyEntry.new("https://packages.microsoft.com/keys/microsoft.asc",
        Fluxion::Fingerprint.new(FINGERPRINT), keyring)
      step = Fluxion::GpgKeyStep.new("repository-keys", [entry])
      item = Fluxion::StepItem.new("repository-keys", entry.item_key, Fluxion::ItemType::GpgKey, step: step)

      runner = HomedirRecordingRunner.new
      runner.available("gpg").on("--show-keys", 0, listing(FINGERPRINT))

      Fluxion::Executor::ProbeRegistry.default.probe(item, runner)
        .should be_a(Fluxion::InstallationStatus::InstalledByProbe)
      assert_private_throwaway_home(runner)
    end
  end
end

# Creating the throwaway home touches the filesystem outside the runner, so an
# unusable TMPDIR used to raise a bare `File::Error` that aborted the whole
# apply instead of answering one probe or failing one item.
private def with_missing_tmpdir(& : ->) : Nil
  saved = ENV["TMPDIR"]?
  ENV["TMPDIR"] = File.join(Dir.tempdir, "fluxion-no-such-tmpdir-#{Random.new.hex(4)}")
  begin
    yield
  ensure
    saved ? (ENV["TMPDIR"] = saved) : ENV.delete("TMPDIR")
  end
end

describe "gpg-key with an unusable TMPDIR" do
  it "answers the keyring probe as unknown" do
    with_gpg_dir do |directory|
      keyring = File.join(directory, "microsoft.gpg")
      File.write(keyring, "keyring bytes")
      entry = Fluxion::GpgKeyEntry.new("https://packages.microsoft.com/keys/microsoft.asc",
        Fluxion::Fingerprint.new(FINGERPRINT), keyring)
      step = Fluxion::GpgKeyStep.new("repository-keys", [entry])
      item = Fluxion::StepItem.new("repository-keys", entry.item_key, Fluxion::ItemType::GpgKey, step: step)
      runner = Fluxion::Executor::FakeShellRunner.new.available("gpg")

      with_missing_tmpdir do
        Fluxion::Executor::ProbeRegistry.default.probe(item, runner)
          .should be_a(Fluxion::InstallationStatus::Unknown)
      end
      runner.ran?("--show-keys").should be_false
    end
  end

  it "raises the one error an executor turns into a failed item" do
    # The executor's own workspace is made with `mkdir_p`, which would create
    # the missing TMPDIR first; the listing is asked directly so the spec is
    # about the listing and leaves nothing behind.
    runner = Fluxion::Executor::FakeShellRunner.new.available("gpg")

    with_missing_tmpdir do
      expect_raises(Fluxion::ExecutionError, /temporary gpg home/) do
        Fluxion::Executor::GpgKeyListing.run(runner, "/nonexistent/key.asc", 5.seconds)
      end
    end
    runner.ran?("--show-keys").should be_false
  end
end
