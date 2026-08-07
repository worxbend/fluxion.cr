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
