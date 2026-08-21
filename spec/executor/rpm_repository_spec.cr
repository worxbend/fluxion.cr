require "../spec_helper"

# The generated repository file had no coverage, so nothing pinned the bytes
# that decide what the package manager will trust and install as root.
private class ExposedRpmExecutor < Fluxion::Executor::RpmStyleRepositoryExecutor
  # `render` is private; a subclass may still call it, which is enough to pin
  # the output without making it part of the executor's public surface.
  def rendered(step : Fluxion::Step, key_path : String? = nil) : String
    render(step, key_path)
  end
end

private def rpm_step(enabled : Bool = true, gpg_check : Bool = true)
  Fluxion::RpmRepositoryStep.new(
    name: "docker",
    id: "docker-ce",
    base_url: "https://download.docker.com/linux/fedora/$releasever/$basearch/stable",
    repo_file: "/etc/yum.repos.d/docker.repo",
    enabled: enabled,
    gpg_check: gpg_check,
  )
end

private def zypper_step(auto_refresh : Bool = true)
  Fluxion::ZypperRepositoryStep.new(
    name: "packman",
    id: "packman",
    base_url: "https://ftp.gwdg.de/pub/linux/misc/packman/suse/",
    repo_file: "/etc/zypp/repos.d/packman.repo",
    auto_refresh: auto_refresh,
  )
end

# Nothing exercised `execute` on this executor, so the sequence it exists to
# enforce — fetch the key unprivileged, verify it, install it locally, and only
# then point the generated file at the *local* copy — was asserted by nothing.
#
# The key directory is a constant naming a root-owned path, so the spec
# overrides it to a temp directory. That is the only production behaviour bent
# here: the fetch, the digest verification, the `Installer` privilege decision,
# and the rendered bytes are all the real ones.
# A scratch directory that always goes away, matching spec/executor/archive_spec.cr.
private def with_directory(& : String ->) : Nil
  directory = File.tempname("fluxion-repo-spec")
  Dir.mkdir_p(directory)
  begin
    yield directory
  ensure
    FileUtils.rm_rf(directory) rescue nil
  end
end

private class ExecutingRpmExecutor < Fluxion::Executor::RpmStyleRepositoryExecutor
  def initialize(@transport : Fluxion::Executor::FakeHttpTransport, @key_dir : String)
    super()
  end

  protected def http_transport : Fluxion::Executor::HttpTransport
    @transport
  end

  private def key_directory(step : Fluxion::Step) : String
    @key_dir
  end
end

private KEY_BODY = "-----BEGIN PGP PUBLIC KEY BLOCK-----\nnot really a key\n"

private def signing_key(url : String, body : String = KEY_BODY) : Fluxion::SigningKey
  Fluxion::SigningKey.new(url,
    Fluxion::Checksum.new(Fluxion::ChecksumAlgorithm::Sha256, Digest::SHA256.hexdigest(body)))
end

describe Fluxion::Executor::RpmStyleRepositoryExecutor do
  executor = ExposedRpmExecutor.new

  it "handles both rpm-style kinds through one shared contract" do
    executor.supports?(rpm_step).should be_true
    executor.supports?(zypper_step).should be_true
  end

  it "does not claim the pacman kind, which edits a file it does not own" do
    pacman = Fluxion::PacmanRepositoryStep.new(
      name: "multilib", repository: "multilib", include_path: "/etc/pacman.d/mirrorlist")
    executor.supports?(pacman).should be_false
  end

  describe "the generated file" do
    it "renders a dnf repository" do
      executor.rendered(rpm_step).should eq(<<-REPO
        [docker-ce]
        name=docker-ce
        baseurl=https://download.docker.com/linux/fedora/$releasever/$basearch/stable
        enabled=1
        gpgcheck=1

        REPO
      )
    end

    it "renders a zypper repository, which adds autorefresh" do
      # The one field only one of the two kinds has.
      executor.rendered(zypper_step).should contain("autorefresh=1\n")
      executor.rendered(rpm_step).should_not contain("autorefresh")
    end

    it "carries enabled and gpgcheck through" do
      executor.rendered(rpm_step(enabled: false, gpg_check: false))
        .should contain("enabled=0\ngpgcheck=0\n")
    end

    it "reflects autorefresh being switched off" do
      executor.rendered(zypper_step(auto_refresh: false)).should contain("autorefresh=0\n")
    end

    it "points at the installed local key, never the remote URL" do
      # The package manager must not be able to refetch something Fluxion has
      # not verified.
      rendered = executor.rendered(rpm_step, "/etc/pki/rpm-gpg/fluxion-docker-ce.key")

      rendered.should contain("gpgkey=file:///etc/pki/rpm-gpg/fluxion-docker-ce.key\n")
      # `baseurl` is legitimately remote; it is the key line that must never be.
      key_line = rendered.lines.find!(&.starts_with?("gpgkey="))
      key_line.should start_with("gpgkey=file://")
    end

    it "omits gpgkey entirely when no key was installed" do
      executor.rendered(rpm_step).should_not contain("gpgkey")
    end
  end

  describe "execute" do
    it "installs the key locally and points the repository file at that copy" do
      with_directory do |directory|
        url = "https://download.docker.com/linux/fedora/gpg"
        repo_file = File.join(directory, "docker.repo")
        key_dir = File.join(directory, "keys")
        Dir.mkdir_p(key_dir)

        transport = Fluxion::Executor::FakeHttpTransport.new.on(url, KEY_BODY)
        step = Fluxion::RpmRepositoryStep.new(
          name: "docker", id: "docker-ce",
          base_url: "https://download.docker.com/linux/fedora/$releasever/$basearch/stable",
          repo_file: repo_file, signing_key: signing_key(url))

        runner = Fluxion::Executor::FakeShellRunner.new
        subject = ExecutingRpmExecutor.new(transport, key_dir)
        result = subject.execute(step, subject.items(step).first, runner) { }

        result.should be_a(Fluxion::StepResult::Success)

        installed_key = File.join(key_dir, "fluxion-docker-ce.key")
        File.exists?(installed_key).should be_true
        File.read(installed_key).should eq(KEY_BODY)

        # The point of the whole sequence: the package manager is handed a
        # local path to bytes Fluxion verified, never the URL it fetched them
        # from.
        File.read(repo_file).should contain("gpgkey=file://#{installed_key}\n")
        File.read(repo_file).should_not contain("gpgkey=https://")

        runner.ran?("dnf makecache").should be_true
      end
    end

    it "refuses the key when the digest does not match, and writes nothing" do
      with_directory do |directory|
        url = "https://download.docker.com/linux/fedora/gpg"
        repo_file = File.join(directory, "docker.repo")
        key_dir = File.join(directory, "keys")
        Dir.mkdir_p(key_dir)

        # The digest is of the body we expected; the transport serves another.
        transport = Fluxion::Executor::FakeHttpTransport.new.on(url, "substituted key")
        step = Fluxion::RpmRepositoryStep.new(
          name: "docker", id: "docker-ce", base_url: "https://example.com/repo",
          repo_file: repo_file, signing_key: signing_key(url))

        runner = Fluxion::Executor::FakeShellRunner.new
        subject = ExecutingRpmExecutor.new(transport, key_dir)
        result = subject.execute(step, subject.items(step).first, runner) { }

        result.should be_a(Fluxion::StepResult::Failure)
        # Verification comes before anything is installed or refreshed, so a
        # bad key leaves the machine exactly as it was.
        Dir.children(key_dir).should be_empty
        File.exists?(repo_file).should be_false
        runner.ran?("makecache").should be_false
      end
    end

    it "uses zypper's refresh command and writes autorefresh for a zypper repository" do
      with_directory do |directory|
        repo_file = File.join(directory, "packman.repo")
        step = Fluxion::ZypperRepositoryStep.new(
          name: "packman", id: "packman",
          base_url: "https://ftp.gwdg.de/pub/linux/misc/packman/suse/",
          repo_file: repo_file, auto_refresh: true)

        runner = Fluxion::Executor::FakeShellRunner.new
        subject = ExecutingRpmExecutor.new(Fluxion::Executor::FakeHttpTransport.new, directory)
        subject.execute(step, subject.items(step).first, runner) { }

        File.read(repo_file).should contain("autorefresh=1")
        runner.ran?("zypper refresh").should be_true
      end
    end
  end

  describe "the preview" do
    it "names the download, the verification, and the refresh command" do
      preview = executor.commands(rpm_step, executor.items(rpm_step).first).first.preview

      preview.should contain("write")
      preview.should contain("/etc/yum.repos.d/docker.repo")
      preview.should contain("dnf")
    end

    it "uses zypper's own refresh command for a zypper repository" do
      preview = executor.commands(zypper_step, executor.items(zypper_step).first).first.preview
      preview.should contain("zypper")
    end
  end
end
