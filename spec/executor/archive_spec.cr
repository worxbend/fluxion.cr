require "../spec_helper"

private alias Archive = Fluxion::Executor::Archive

# Builds a real gzipped tar so the reader is exercised against actual bytes
# rather than a hand-rolled fixture that might encode the same misreading.
private def with_archive(entries : Hash(String, String), & : String -> T) : T forall T
  directory = File.tempname("fluxion-archive")
  Dir.mkdir_p(directory)
  begin
    content = File.join(directory, "content")
    Dir.mkdir_p(content)

    entries.each do |path, body|
      full = File.join(content, path)
      Dir.mkdir_p(File.dirname(full))
      File.write(full, body)
    end

    archive = File.join(directory, "archive.tar.gz")
    status = Process.run("tar", ["-czf", archive, "-C", content, "."])
    raise "tar failed" unless status.success?

    yield archive
  ensure
    FileUtils.rm_rf(directory)
  end
end

describe Fluxion::Executor::Archive do
  describe ".strip" do
    it "removes leading path segments" do
      Archive.strip("ripgrep-14.1.0/rg", 1).should eq("rg")
      Archive.strip("a/b/c", 2).should eq("c")
    end

    it "leaves the path alone when nothing is stripped" do
      Archive.strip("ripgrep/rg", 0).should eq("ripgrep/rg")
    end

    it "yields nothing matchable when there are too few segments" do
      # Falling back to the unstripped name would silently select a different
      # member than the profile asked for.
      Archive.strip("rg", 2).should eq("")
    end
  end

  describe ".extract" do
    it "extracts the named member and returns its digest" do
      with_archive({"bin/rg" => "binary-content"}) do |archive|
        destination = File.tempname("fluxion-extract")
        begin
          digest = Archive.extract(archive, "bin/rg", destination)
          File.read(destination).should eq("binary-content")
          digest.should eq(Digest::SHA256.hexdigest("binary-content"))
        ensure
          File.delete(destination) rescue nil
        end
      end
    end

    it "applies strip-components before matching" do
      with_archive({"ripgrep-14.1.0/rg" => "stripped"}) do |archive|
        destination = File.tempname("fluxion-extract")
        begin
          Archive.extract(archive, "rg", destination, strip_components: 1)
          File.read(destination).should eq("stripped")
        ensure
          File.delete(destination) rescue nil
        end
      end
    end

    it "matches the exact path, never the basename" do
      # Two members share a basename; only the declared path may be selected.
      entries = {"bin/rg" => "correct", "docs/rg" => "wrong"}
      with_archive(entries) do |archive|
        destination = File.tempname("fluxion-extract")
        begin
          Archive.extract(archive, "bin/rg", destination)
          File.read(destination).should eq("correct")
        ensure
          File.delete(destination) rescue nil
        end
      end
    end

    it "reports a member that is not there rather than guessing" do
      with_archive({"bin/rg" => "x"}) do |archive|
        expect_raises(Fluxion::TrustError, /Archive member not found: bin\/missing/) do
          Archive.extract(archive, "bin/missing", File.tempname("fluxion-extract"))
        end
      end
    end

    it "handles a long member name" do
      long = "a-very-long-directory-name-that-exceeds-the-ustar-name-field-limit/" \
             "and-keeps-going-well-past-one-hundred-characters-in-total/rg"
      with_archive({long => "long"}) do |archive|
        destination = File.tempname("fluxion-extract")
        begin
          Archive.extract(archive, long, destination)
          File.read(destination).should eq("long")
        ensure
          File.delete(destination) rescue nil
        end
      end
    end
  end

  describe ".members" do
    it "lists the regular files" do
      with_archive({"bin/rg" => "a", "README" => "b"}) do |archive|
        paths = Archive.members(archive).map(&.path)
        paths.any?(&.ends_with?("bin/rg")).should be_true
        paths.any?(&.ends_with?("README")).should be_true
      end
    end

    it "reports each member's size" do
      with_archive({"bin/rg" => "12345"}) do |archive|
        member = Archive.members(archive).find!(&.path.ends_with?("bin/rg"))
        member.size.should eq(5)
      end
    end
  end
end

describe Fluxion::Executor::Installer do
  it "installs a file atomically into a writable directory" do
    runner = Fluxion::Executor::FakeShellRunner.new
    directory = File.tempname("fluxion-install")
    Dir.mkdir_p(directory)

    begin
      source = File.join(directory, "source")
      File.write(source, "payload")
      destination = File.join(directory, "installed")

      Fluxion::Executor::Installer.new(runner).install(source, destination, "0755")

      File.read(destination).should eq("payload")
      File.info(destination).permissions.owner_execute?.should be_true
      # Nothing privileged should have been reached for a writable directory.
      runner.commands.should be_empty
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "leaves no staging file behind" do
    runner = Fluxion::Executor::FakeShellRunner.new
    directory = File.tempname("fluxion-install")
    Dir.mkdir_p(directory)

    begin
      source = File.join(directory, "source")
      File.write(source, "payload")
      Fluxion::Executor::Installer.new(runner).install(source, File.join(directory, "installed"))

      Dir.children(directory).sort.should eq(["installed", "source"])
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "writes content with the requested mode" do
    runner = Fluxion::Executor::FakeShellRunner.new
    directory = File.tempname("fluxion-write")
    Dir.mkdir_p(directory)

    begin
      destination = File.join(directory, "tool.conf")
      Fluxion::Executor::Installer.new(runner).write("enabled=true\n", destination, "0600")

      File.read(destination).should eq("enabled=true\n")
      permissions = File.info(destination).permissions
      permissions.other_read?.should be_false
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "refuses a destination whose parent does not exist" do
    runner = Fluxion::Executor::FakeShellRunner.new
    expect_raises(Fluxion::ExecutionError, /does not exist/) do
      Fluxion::Executor::Installer.new(runner).privilege_for("/definitely/missing/tool")
    end
  end

  it "chooses the privileged path for a root-owned system directory" do
    runner = Fluxion::Executor::FakeShellRunner.new
    installer = Fluxion::Executor::Installer.new(runner)
    installer.privilege_for("/usr/local/bin/fluxion-spec-probe")
      .should eq(Fluxion::Executor::Installer::Privilege::Root)
  end

  it "requires a digest before staging anything as root" do
    # Staging is exactly where a swap would happen, so there has to be
    # something to re-verify once the file is root-owned.
    runner = Fluxion::Executor::FakeShellRunner.new
    expect_raises(Fluxion::TrustError, /requires a verified digest/) do
      Fluxion::Executor::Installer.new(runner)
        .install("/tmp/source", "/usr/local/bin/fluxion-spec-probe", "0755", nil)
    end
    runner.commands.should be_empty
  end
end
