require "../spec_helper"

# The probes had no direct coverage at all, which is how three of them came to
# report an answer they had never been given. The rule they all owe the user is
# the one stated at the top of `probe.cr`: a probe that could not find out says
# `Unknown`, never `NotInstalled` and never "installed".

private def package_item(key : String, manager : Fluxion::PackageManager) : Fluxion::StepItem
  Fluxion::StepItem.new("tools", key, Fluxion::ItemType::Package, package_manager: manager)
end

private def git_config_item(key : String, value : String) : Fluxion::StepItem
  step = Fluxion::GitConfigStep.new("identity", {key => value})
  Fluxion::StepItem.new("identity", step.item_key(key), Fluxion::ItemType::GitConfig, step: step)
end

private def systemd_item(unit : Fluxion::SystemdUnit) : Fluxion::StepItem
  step = Fluxion::SystemdUnitStep.new("services", [unit])
  Fluxion::StepItem.new("services", unit.qualified_name, Fluxion::ItemType::SystemdUnit, step: step)
end

# What `cargo install --list` prints: one line per crate at column 0, the
# binaries it provides indented under it, and a source in parentheses when the
# crate came from a git checkout or a local path instead of crates.io.
private CARGO_LISTING = <<-LISTING
  fd-find v10.2.0:
      fd
  ripgrep v14.1.0:
      rg
  mycrate v0.1.0 (/home/me/src):
      mycrate

  LISTING

private def cargo_runner(exit_code : Int32 = 0,
                         stdout : String = CARGO_LISTING) : Fluxion::Executor::FakeShellRunner
  Fluxion::Executor::FakeShellRunner.new
    .available("cargo")
    .on("cargo install --list", exit_code, stdout)
end

describe Fluxion::Executor::PackageProbe do
  describe "cargo" do
    # `cargo install --list` ignores the name it was asked about and always
    # exits 0, so before this the probe read that exit code as proof of
    # installation and reported every crate in every profile as present.
    it "reports a crate the listing does not mention as absent" do
      status = Fluxion::Executor::PackageProbe.new.probe(
        package_item("bat", Fluxion::PackageManager::Cargo), cargo_runner)

      status.should be_a(Fluxion::InstallationStatus::NotInstalled)
    end

    it "reports a listed crate as installed, with its version" do
      status = Fluxion::Executor::PackageProbe.new.probe(
        package_item("ripgrep", Fluxion::PackageManager::Cargo), cargo_runner)

      status.should be_a(Fluxion::InstallationStatus::InstalledByProbe)
      status.as(Fluxion::InstallationStatus::InstalledByProbe).detected_version.should eq("14.1.0")
    end

    it "reads the version of a crate installed from a local path" do
      status = Fluxion::Executor::PackageProbe.new.probe(
        package_item("mycrate", Fluxion::PackageManager::Cargo), cargo_runner)

      # The source in parentheses moves the colon off the version token, which
      # a stricter match on "name vX.Y.Z:" would have read as absence.
      status.as(Fluxion::InstallationStatus::InstalledByProbe).detected_version.should eq("0.1.0")
    end

    it "does not mistake a binary name for the crate that provides it" do
      # "rg" appears in the listing, indented, as one of ripgrep's binaries.
      status = Fluxion::Executor::PackageProbe.new.probe(
        package_item("rg", Fluxion::PackageManager::Cargo), cargo_runner)

      status.should be_a(Fluxion::InstallationStatus::NotInstalled)
    end

    it "reports Unknown when cargo could not produce a listing" do
      status = Fluxion::Executor::PackageProbe.new.probe(
        package_item("ripgrep", Fluxion::PackageManager::Cargo), cargo_runner(101, ""))

      status.should be_a(Fluxion::InstallationStatus::Unknown)
      status.as(Fluxion::InstallationStatus::Unknown).reason.should contain("exited 101")
    end
  end

  describe "rpm" do
    # `rpm -q` answers with the full "name-version-release.arch", and the name
    # half may contain hyphens of its own. Splitting on the first one reported
    # "compose-2.29.7-1.fc41.x86_64" as docker-compose's version, which then
    # showed up in `status` and counted as drift against recorded state.
    it "keeps a hyphenated package name out of the version" do
      runner = Fluxion::Executor::FakeShellRunner.new
        .available("rpm")
        .on("rpm -q", 0, "docker-compose-2.29.7-1.fc41.x86_64\n")

      status = Fluxion::Executor::PackageProbe.new.probe(
        package_item("docker-compose", Fluxion::PackageManager::Dnf), runner)

      status.as(Fluxion::InstallationStatus::InstalledByProbe).detected_version
        .should eq("2.29.7-1.fc41.x86_64")
    end

    it "still reads the version of a package whose name has no hyphen" do
      runner = Fluxion::Executor::FakeShellRunner.new
        .available("rpm")
        .on("rpm -q", 0, "git-2.45.2-1.fc44.x86_64\n")

      status = Fluxion::Executor::PackageProbe.new.probe(
        package_item("git", Fluxion::PackageManager::Dnf), runner)

      status.as(Fluxion::InstallationStatus::InstalledByProbe).detected_version
        .should eq("2.45.2-1.fc44.x86_64")
    end

    it "falls back to the first hyphen when rpm answered about another name" do
      # A capability or file-path query resolves to a package whose name is not
      # the key, so there is no prefix to remove and the old split is the best
      # remaining guess.
      runner = Fluxion::Executor::FakeShellRunner.new
        .available("rpm")
        .on("rpm -q", 0, "bash-5.2.26-1.fc41.x86_64\n")

      status = Fluxion::Executor::PackageProbe.new.probe(
        package_item("/bin/sh", Fluxion::PackageManager::Dnf), runner)

      status.as(Fluxion::InstallationStatus::InstalledByProbe).detected_version
        .should eq("5.2.26-1.fc41.x86_64")
    end
  end

  describe "apt" do
    # What dpkg-query prints for the probe's own format string, once it has
    # been through the same sanitizing the real runner applies to everything it
    # captures. Built from `query_argv` rather than written out so the spec
    # follows the format wherever it goes.
    it "recognises an installed package in output the runner has sanitized" do
      format = Fluxion::PackageManager::Apt.query_argv("coreutils")
        .find!(&.starts_with?("-f="))
        .lchop("-f=")
      printed = format
        .gsub("${Status}", "install ok installed")
        .gsub("${Version}", "9.4-3ubuntu6.1")
        .gsub("\\n", "\n")

      # The runner replaces every control character but a newline with a
      # space, so a tab separator reached the probe as a space and the status
      # never matched: every apt package read as absent.
      runner = Fluxion::Executor::FakeShellRunner.new
        .available("dpkg-query")
        .on("dpkg-query", 0, Fluxion::Executor::Redaction.strip_controls(printed, preserve_newlines: true))

      status = Fluxion::Executor::PackageProbe.new.probe(
        package_item("coreutils", Fluxion::PackageManager::Apt), runner)

      status.should be_a(Fluxion::InstallationStatus::InstalledByProbe)
      status.as(Fluxion::InstallationStatus::InstalledByProbe).detected_version.should eq("9.4-3ubuntu6.1")
    end

    it "reads a multi-arch package, which dpkg-query answers once per architecture" do
      runner = Fluxion::Executor::FakeShellRunner.new
        .available("dpkg-query")
        .on("dpkg-query", 0, "install ok installed|2.39-0ubuntu8\ninstall ok installed|2.39-0ubuntu8\n")

      status = Fluxion::Executor::PackageProbe.new.probe(
        package_item("libc6", Fluxion::PackageManager::Apt), runner)

      status.as(Fluxion::InstallationStatus::InstalledByProbe).detected_version.should eq("2.39-0ubuntu8")
    end

    it "reports a package that was removed but left its configuration as absent" do
      runner = Fluxion::Executor::FakeShellRunner.new
        .available("dpkg-query")
        .on("dpkg-query", 0, "deinstall ok config-files|1.0-1\n")

      Fluxion::Executor::PackageProbe.new.probe(
        package_item("oldpkg", Fluxion::PackageManager::Apt), runner)
        .should be_a(Fluxion::InstallationStatus::NotInstalled)
    end

    it "reports a package dpkg has never heard of as absent" do
      runner = Fluxion::Executor::FakeShellRunner.new
        .available("dpkg-query")
        .on("dpkg-query", 1, "dpkg-query: no packages found matching nosuch\n")

      Fluxion::Executor::PackageProbe.new.probe(
        package_item("nosuch", Fluxion::PackageManager::Apt), runner)
        .should be_a(Fluxion::InstallationStatus::NotInstalled)
    end
  end

  describe "flatpak" do
    # Pinned alongside cargo because the two are the scanning probes: both are
    # handed a listing that never mentions the item, so both have to read the
    # output rather than the exit code.
    it "matches an application id in the listing" do
      runner = Fluxion::Executor::FakeShellRunner.new
        .available("flatpak")
        .on("flatpak list", 0, "org.gimp.GIMP\ncom.spotify.Client\n")

      probe = Fluxion::Executor::PackageProbe.new
      probe.probe(package_item("org.gimp.GIMP", Fluxion::PackageManager::Flatpak), runner)
        .should be_a(Fluxion::InstallationStatus::InstalledByProbe)
      probe.probe(package_item("org.inkscape.Inkscape", Fluxion::PackageManager::Flatpak), runner)
        .should be_a(Fluxion::InstallationStatus::NotInstalled)
    end
  end
end

describe Fluxion::Executor::GitConfigProbe do
  it "reports a key that is genuinely unset as absent" do
    runner = Fluxion::Executor::FakeShellRunner.new
      .available("git")
      .on("git config", 1, "")

    Fluxion::Executor::GitConfigProbe.new
      .probe(git_config_item("user.email", "me@example.test"), runner)
      .should be_a(Fluxion::InstallationStatus::NotInstalled)
  end

  it "reports Unknown when git could not answer the question" do
    # Exit 128 is what `git config --local --get` returns outside a work tree,
    # along with the "fatal:" line the runner folds into stdout. Reading that
    # as absence would tell the user a key is missing that may well be set.
    runner = Fluxion::Executor::FakeShellRunner.new
      .available("git")
      .on("git config", 128, "fatal: --local can only be used inside a git repository\n")

    status = Fluxion::Executor::GitConfigProbe.new
      .probe(git_config_item("user.email", "me@example.test"), runner)

    status.should be_a(Fluxion::InstallationStatus::Unknown)
    status.as(Fluxion::InstallationStatus::Unknown).reason.should contain("exited 128")
  end

  it "reports Unknown when git is not on PATH" do
    runner = Fluxion::Executor::FakeShellRunner.new.on("git config", 127, "")

    Fluxion::Executor::GitConfigProbe.new
      .probe(git_config_item("user.email", "me@example.test"), runner)
      .should be_a(Fluxion::InstallationStatus::Unknown)
  end

  it "reports a matching value as installed" do
    runner = Fluxion::Executor::FakeShellRunner.new
      .available("git")
      .on("git config", 0, "me@example.test\n")

    status = Fluxion::Executor::GitConfigProbe.new
      .probe(git_config_item("user.email", "me@example.test"), runner)

    status.as(Fluxion::InstallationStatus::InstalledByProbe).detected_version
      .should eq("me@example.test")
  end
end

describe Fluxion::Executor::SystemdUnitProbe do
  unchanged_unit = Fluxion::SystemdUnit.new("docker", enabled: true,
    state: Fluxion::SystemdState::Unchanged)

  it "reports Unknown when systemctl is present but refuses to answer" do
    # The runner merges stderr into stdout, so inside a container the first
    # line of `is-enabled` is systemd's refusal, not a state word. Recording it
    # as the unit's state made the probe claim the unit was installed and put
    # that whole sentence in the version column.
    runner = Fluxion::Executor::FakeShellRunner.new
      .available("systemctl")
      .on("is-enabled", 1,
        "System has not been booted with systemd as init system (PID 1). Can't operate.\n")

    status = Fluxion::Executor::SystemdUnitProbe.new.probe(systemd_item(unchanged_unit), runner)

    status.should be_a(Fluxion::InstallationStatus::Unknown)
    # The reason quotes what systemctl said, not just its exit code: `disabled`
    # exits 1 legitimately, so only the text tells a user why the probe gave up.
    reason = status.as(Fluxion::InstallationStatus::Unknown).reason
    reason.should contain("System has not been booted with systemd")
    reason.should contain("exit 1")
  end

  it "still reads a real state word that exits non-zero" do
    # `disabled` also exits 1, so the exit code alone cannot separate the two;
    # the word is the signal, and this unit is genuinely not enabled.
    runner = Fluxion::Executor::FakeShellRunner.new
      .available("systemctl")
      .on("is-enabled", 1, "disabled\n")

    Fluxion::Executor::SystemdUnitProbe.new.probe(systemd_item(unchanged_unit), runner)
      .should be_a(Fluxion::InstallationStatus::NotInstalled)
  end

  it "still treats a unit that cannot be enabled as satisfied" do
    runner = Fluxion::Executor::FakeShellRunner.new
      .available("systemctl")
      .on("is-enabled", 1, "static\n")

    Fluxion::Executor::SystemdUnitProbe.new.probe(systemd_item(unchanged_unit), runner)
      .should be_a(Fluxion::InstallationStatus::InstalledByProbe)
  end

  it "reports Unknown when systemctl refuses to answer is-active" do
    started = Fluxion::SystemdUnit.new("docker", enabled: true,
      state: Fluxion::SystemdState::Started)
    runner = Fluxion::Executor::FakeShellRunner.new
      .available("systemctl")
      .on("is-enabled", 0, "enabled\n")
      .on("is-active", 1, "Failed to connect to bus: No such file or directory\n")

    status = Fluxion::Executor::SystemdUnitProbe.new.probe(systemd_item(started), runner)

    status.should be_a(Fluxion::InstallationStatus::Unknown)
    reason = status.as(Fluxion::InstallationStatus::Unknown).reason
    reason.should contain("Failed to connect to bus")
    reason.should contain("exit 1")
  end

  it "still treats a stopped unit as satisfied when it asked to be stopped" do
    stopped = Fluxion::SystemdUnit.new("docker", enabled: true,
      state: Fluxion::SystemdState::Stopped)
    runner = Fluxion::Executor::FakeShellRunner.new
      .available("systemctl")
      .on("is-enabled", 0, "enabled\n")
      .on("is-active", 3, "inactive\n")

    Fluxion::Executor::SystemdUnitProbe.new.probe(systemd_item(stopped), runner)
      .should be_a(Fluxion::InstallationStatus::InstalledByProbe)
  end
end
