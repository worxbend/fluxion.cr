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

    # An OBS plugin is a runtime ref; `flatpak list --app` never shows it, so a
    # probe that asked for apps only reinstalled it on every run.
    it "lists every installed ref, so an extension installed by the step is found" do
      runner = Fluxion::Executor::FakeShellRunner.new
        .available("flatpak")
        .on("flatpak list", 0, "com.obsproject.Studio\ncom.obsproject.Studio.Plugin.DroidCam\n")
      item = Fluxion::StepItem.new("obs", "com.obsproject.Studio.Plugin.DroidCam", Fluxion::ItemType::Flatpak)

      Fluxion::Executor::FlatpakProbe.new.probe(item, runner)
        .should be_a(Fluxion::InstallationStatus::InstalledByProbe)
      runner.argv.should eq([["flatpak", "list", "--columns=application"]])

      Fluxion::Executor::PackageProbe.new.probe(
        package_item("com.obsproject.Studio.Plugin.DroidCam", Fluxion::PackageManager::Flatpak), runner)
        .should be_a(Fluxion::InstallationStatus::InstalledByProbe)
      runner.argv.last.should_not contain("--app")
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

private def setting_item(key : String, step : Fluxion::SystemSettingStep) : Fluxion::StepItem
  Fluxion::StepItem.new(step.name, key, Fluxion::ItemType::SystemSetting, step: step)
end

# What `localectl status` prints: the locale variables, one per line under the
# "System Locale:" heading, then the keymap and layout lines.
private LOCALECTL_STATUS = <<-STATUS
  System Locale: LANG=en_US.UTF-8
                 LC_TIME=en_GB.UTF-8
      VC Keymap: (unset)
     X11 Layout: us

  STATUS

private def timedatectl_runner(ntp : String = "yes", local_rtc : String = "no",
                               timezone : String = "Europe/Warsaw") : Fluxion::Executor::FakeShellRunner
  Fluxion::Executor::FakeShellRunner.new
    .available("timedatectl", "hostnamectl", "localectl")
    .on("-p NTP", 0, "#{ntp}\n")
    .on("-p LocalRTC", 0, "#{local_rtc}\n")
    .on("-p Timezone", 0, "#{timezone}\n")
    .on("hostnamectl", 0, "workstation\n")
    .on("localectl status", 0, LOCALECTL_STATUS)
end

describe Fluxion::Executor::SystemSettingProbe do
  # There was no probe for this kind at all, so `status` called every setting
  # unknown and `--re-probe` ran timedatectl again on every run, although the
  # schema has always promised that only what differs is applied.
  it "is what the default registry answers system settings with" do
    step = Fluxion::SystemSettingStep.new("clock", ntp: true)

    Fluxion::Executor::ProbeRegistry.default.probe(setting_item("ntp", step), timedatectl_runner)
      .should be_a(Fluxion::InstallationStatus::InstalledByProbe)
  end

  it "reports clock settings the host already has as installed" do
    step = Fluxion::SystemSettingStep.new("clock", ntp: true, local_rtc: false, timezone: "Europe/Warsaw")
    probe = Fluxion::Executor::SystemSettingProbe.new
    runner = timedatectl_runner

    %w[ntp localRtc timezone].each do |key|
      probe.probe(setting_item(key, step), runner).should be_a(Fluxion::InstallationStatus::InstalledByProbe)
    end
  end

  it "reports a clock setting that differs as absent" do
    step = Fluxion::SystemSettingStep.new("clock", ntp: true, local_rtc: false, timezone: "UTC")
    probe = Fluxion::Executor::SystemSettingProbe.new
    runner = timedatectl_runner(ntp: "no", local_rtc: "yes")

    %w[ntp localRtc timezone].each do |key|
      probe.probe(setting_item(key, step), runner).should be_a(Fluxion::InstallationStatus::NotInstalled)
    end
  end

  it "compares the static hostname" do
    probe = Fluxion::Executor::SystemSettingProbe.new
    matching = Fluxion::SystemSettingStep.new("host", hostname: "workstation")
    different = Fluxion::SystemSettingStep.new("host", hostname: "laptop")

    probe.probe(setting_item("hostname", matching), timedatectl_runner)
      .should be_a(Fluxion::InstallationStatus::InstalledByProbe)
    probe.probe(setting_item("hostname", different), timedatectl_runner)
      .should be_a(Fluxion::InstallationStatus::NotInstalled)
  end

  it "reads each locale variable from localectl, not only the first line" do
    step = Fluxion::SystemSettingStep.new("locale",
      locale: {"LANG" => "en_US.UTF-8", "LC_TIME" => "pl_PL.UTF-8", "LC_PAPER" => "en_GB.UTF-8"})
    probe = Fluxion::Executor::SystemSettingProbe.new
    runner = timedatectl_runner

    probe.probe(setting_item("locale:LANG", step), runner)
      .should be_a(Fluxion::InstallationStatus::InstalledByProbe)
    probe.probe(setting_item("locale:LC_TIME", step), runner)
      .should be_a(Fluxion::InstallationStatus::NotInstalled)
    probe.probe(setting_item("locale:LC_PAPER", step), runner)
      .should be_a(Fluxion::InstallationStatus::NotInstalled)
  end

  it "reports Unknown when the tool is not there" do
    step = Fluxion::SystemSettingStep.new("clock", ntp: true)
    runner = Fluxion::Executor::FakeShellRunner.new

    Fluxion::Executor::SystemSettingProbe.new.probe(setting_item("ntp", step), runner)
      .should be_a(Fluxion::InstallationStatus::Unknown)
  end

  it "reports Unknown when timedatectl cannot answer" do
    # Inside a container the runner hands back systemd's complaint, merged into
    # stdout, where a yes or no belongs. That is no answer, not a "no".
    step = Fluxion::SystemSettingStep.new("clock", ntp: false)
    runner = Fluxion::Executor::FakeShellRunner.new
      .available("timedatectl")
      .on("timedatectl", 1, "System has not been booted with systemd as init system (PID 1). Can't operate.\n")

    status = Fluxion::Executor::SystemSettingProbe.new.probe(setting_item("ntp", step), runner)

    status.should be_a(Fluxion::InstallationStatus::Unknown)
    status.as(Fluxion::InstallationStatus::Unknown).reason.should contain("Can't operate")
  end
end

private def with_probe_dir(& : String -> T) : T forall T
  directory = File.tempname("fluxion-probe")
  Dir.mkdir_p(directory, 0o700)
  begin
    yield directory
  ensure
    FileUtils.rm_rf(directory)
  end
end

private def apt_source_item(directory : String, signed : Bool = true) : Fluxion::StepItem
  keyring = File.join(directory, "vendor.gpg")
  step = Fluxion::AptRepositoryStep.new(
    "vendor",
    source: "deb [arch=amd64 signed-by=#{keyring}] https://apt.example.test/stable stable main",
    source_list: File.join(directory, "vendor.list"),
    signing_key: signed ? Fluxion::SigningKey.new("https://apt.example.test/key.asc",
      Fluxion::Checksum.new(Fluxion::ChecksumAlgorithm::Sha256, "0" * 64)) : nil,
    keyring: keyring,
  )
  Fluxion::StepItem.new("vendor", step.source_list, Fluxion::ItemType::AptRepository, step: step)
end

describe Fluxion::Executor::RepositoryFileProbe do
  runner = Fluxion::Executor::FakeShellRunner.new
  probe = Fluxion::Executor::RepositoryFileProbe.new

  it "reports the declared source with its keyring in place as installed" do
    with_probe_dir do |directory|
      item = apt_source_item(directory)
      step = item.step.as(Fluxion::AptRepositoryStep)
      File.write(step.source_list, step.source + "\n")
      File.write(step.keyring.not_nil!, "keyring bytes")

      probe.probe(item, runner).should be_a(Fluxion::InstallationStatus::InstalledByProbe)
    end
  end

  it "reports a source file with another line in it as absent" do
    # What a vendor package or a hand-written line leaves behind: the same
    # path, pointing at a different keyring. Counting it as installed meant
    # the declared source and keyring were never written, on any later run.
    with_probe_dir do |directory|
      item = apt_source_item(directory)
      step = item.step.as(Fluxion::AptRepositoryStep)
      File.write(step.source_list, step.source.sub(".gpg]", ".asc]") + "\n")
      File.write(step.keyring.not_nil!, "keyring bytes")

      probe.probe(item, runner).should be_a(Fluxion::InstallationStatus::NotInstalled)
    end
  end

  it "reports the declared source as absent while the keyring it installs is missing or empty" do
    with_probe_dir do |directory|
      item = apt_source_item(directory)
      step = item.step.as(Fluxion::AptRepositoryStep)
      File.write(step.source_list, step.source + "\n")

      probe.probe(item, runner).should be_a(Fluxion::InstallationStatus::NotInstalled)

      File.write(step.keyring.not_nil!, "")
      probe.probe(item, runner).should be_a(Fluxion::InstallationStatus::NotInstalled)
    end
  end

  it "does not require a keyring the step does not install itself" do
    # Without `signingKeyUrl` the keyring is some other step's job, typically
    # a `gpg-key` entry, and rerunning this one could not create it.
    with_probe_dir do |directory|
      item = apt_source_item(directory, signed: false)
      step = item.step.as(Fluxion::AptRepositoryStep)
      File.write(step.source_list, step.source)

      probe.probe(item, runner).should be_a(Fluxion::InstallationStatus::InstalledByProbe)
    end
  end
end

private GPG_FINGERPRINT = "9DC858229FC7DD38854AE2D88D81803C0EBFCD88"

# What `gpg --show-keys --with-colons` prints for one primary key with a
# subkey: the `fpr` after `pub` is the primary's, the one after `sub` is not.
private def gpg_listing(primary : String) : String
  <<-COLONS
    pub:-:4096:1:8D81803C0EBFCD88:1487788586:::-:::scESA::::::23::0:
    fpr:::::::::#{primary}:
    uid:-::::1487792064::B5FA5F0F1BB1A4C4E3AD7F71A0C4CC39DB76E3EC::Docker Release (CE deb) <docker@docker.com>::::::::::0:
    sub:-:4096:1:7EA0A9C3F273FCD8:1487788586::::::s::::::23:
    fpr:::::::::D3306A018370199E527AE7317EA0A9C3F273FCD8:

    COLONS
end

private def gpg_keyring_item(keyring : String) : Fluxion::StepItem
  entry = Fluxion::GpgKeyEntry.new("https://download.example.test/gpg",
    Fluxion::Fingerprint.new(GPG_FINGERPRINT), keyring)
  step = Fluxion::GpgKeyStep.new("repository-keys", [entry])
  Fluxion::StepItem.new("repository-keys", entry.item_key, Fluxion::ItemType::GpgKey, step: step)
end

describe "gpg-key keyring probe" do
  registry = Fluxion::Executor::ProbeRegistry.default

  it "reports a keyring holding the declared key as installed" do
    with_probe_dir do |directory|
      keyring = File.join(directory, "vendor.gpg")
      File.write(keyring, "keyring bytes")
      runner = Fluxion::Executor::FakeShellRunner.new
        .available("gpg")
        .on("--show-keys", 0, gpg_listing(GPG_FINGERPRINT))

      registry.probe(gpg_keyring_item(keyring), runner)
        .should be_a(Fluxion::InstallationStatus::InstalledByProbe)
      runner.ran?("gpg --batch --no-options --show-keys --with-colons #{keyring}").should be_true
    end
  end

  it "reports a keyring holding some other key as absent" do
    # The same path with a different key in it — a vendor's older key, or one
    # a package's postinst wrote — used to count as installed because only
    # the path was checked, so the declared key was never installed.
    with_probe_dir do |directory|
      keyring = File.join(directory, "vendor.gpg")
      File.write(keyring, "keyring bytes")
      runner = Fluxion::Executor::FakeShellRunner.new
        .available("gpg")
        .on("--show-keys", 0, gpg_listing("0123456789ABCDEF0123456789ABCDEF01234567"))

      registry.probe(gpg_keyring_item(keyring), runner)
        .should be_a(Fluxion::InstallationStatus::NotInstalled)
    end
  end

  it "reports an empty or missing keyring as absent without asking gpg" do
    with_probe_dir do |directory|
      keyring = File.join(directory, "vendor.gpg")
      runner = Fluxion::Executor::FakeShellRunner.new.available("gpg")

      registry.probe(gpg_keyring_item(keyring), runner)
        .should be_a(Fluxion::InstallationStatus::NotInstalled)
      File.write(keyring, "")
      registry.probe(gpg_keyring_item(keyring), runner)
        .should be_a(Fluxion::InstallationStatus::NotInstalled)
      runner.ran?("gpg").should be_false
    end
  end

  it "reports Unknown when the keyring cannot be read" do
    with_probe_dir do |directory|
      keyring = File.join(directory, "vendor.gpg")
      File.write(keyring, "keyring bytes")

      no_gpg = Fluxion::Executor::FakeShellRunner.new
      registry.probe(gpg_keyring_item(keyring), no_gpg)
        .should be_a(Fluxion::InstallationStatus::Unknown)

      failing = Fluxion::Executor::FakeShellRunner.new
        .available("gpg")
        .on("--show-keys", 2, "gpg: no valid OpenPGP data found.\n")
      registry.probe(gpg_keyring_item(keyring), failing)
        .should be_a(Fluxion::InstallationStatus::Unknown)
    end
  end
end

private def tool_package_item(entry : String, backend : Fluxion::ToolBackend = Fluxion::ToolBackend::CargoBinstall,
                              probe_command : String? = nil) : Fluxion::StepItem
  name, _, version = entry.partition('@')
  step = Fluxion::ToolPackagesStep.new("rust-crates", backend,
    [Fluxion::ToolPackage.new(name, version.presence)], probe_command: probe_command)
  Fluxion::StepItem.new("rust-crates", name, Fluxion::ItemType::ToolPackage, entry, step: step)
end

# `tool-packages` had no probe at all, so `status` called every crate unknown
# and `--re-probe` installed every one of them again. cargo-binstall records
# what it installs in cargo's own install list, which is what `cargo install
# --list` reads, so both cargo backends are answered from that listing.
describe "tool-packages probe" do
  registry = Fluxion::Executor::ProbeRegistry.default

  it "reports a crate cargo-binstall installed as installed, with its version" do
    runner = cargo_runner
    status = registry.probe(tool_package_item("fd-find"), runner)

    status.should be_a(Fluxion::InstallationStatus::InstalledByProbe)
    status.as(Fluxion::InstallationStatus::InstalledByProbe).detected_version.should eq("10.2.0")
    runner.ran?("cargo install --list").should be_true
  end

  it "reports a crate the listing does not mention as absent" do
    registry.probe(tool_package_item("bottom"), cargo_runner)
      .should be_a(Fluxion::InstallationStatus::NotInstalled)
    registry.probe(tool_package_item("rg", Fluxion::ToolBackend::Cargo), cargo_runner)
      .should be_a(Fluxion::InstallationStatus::NotInstalled)
  end

  it "answers for the cargo backend from the same listing" do
    registry.probe(tool_package_item("ripgrep", Fluxion::ToolBackend::Cargo), cargo_runner)
      .should be_a(Fluxion::InstallationStatus::InstalledByProbe)
  end

  it "reports a pinned crate installed at another version as absent" do
    # Otherwise changing a pin would never be applied under --re-probe.
    registry.probe(tool_package_item("ripgrep@14.0.3"), cargo_runner)
      .should be_a(Fluxion::InstallationStatus::NotInstalled)
    registry.probe(tool_package_item("ripgrep@14.1.0"), cargo_runner)
      .should be_a(Fluxion::InstallationStatus::InstalledByProbe)
    registry.probe(tool_package_item("ripgrep@14.1"), cargo_runner)
      .should be_a(Fluxion::InstallationStatus::InstalledByProbe)
    registry.probe(tool_package_item("ripgrep@14.10"), cargo_runner)
      .should be_a(Fluxion::InstallationStatus::NotInstalled)
  end

  it "reports Unknown when cargo is not there to ask" do
    status = registry.probe(tool_package_item("fd-find"), Fluxion::Executor::FakeShellRunner.new)

    status.should be_a(Fluxion::InstallationStatus::Unknown)
    status.as(Fluxion::InstallationStatus::Unknown).reason.should contain("cargo")
  end

  it "leaves the other backends to a configured probeCommand" do
    runner = Fluxion::Executor::FakeShellRunner.new.available("pipx")
    registry.probe(tool_package_item("black", Fluxion::ToolBackend::Pipx), runner)
      .should be_a(Fluxion::InstallationStatus::Unknown)

    configured = tool_package_item("black", Fluxion::ToolBackend::Pipx, probe_command: "pipx list --short | grep -q '^black '")
    registry.probe(configured, runner).should be_a(Fluxion::InstallationStatus::InstalledByProbe)
    runner.ran?("pipx list --short").should be_true
  end
end

private def sdkman_item(candidate : String, version : String? = nil) : Fluxion::StepItem
  entry = Fluxion::SdkmanCandidate.new(candidate, version)
  step = Fluxion::SdkmanPackagesStep.new("sdkman-candidates", [entry])
  Fluxion::StepItem.new("sdkman-candidates", candidate, Fluxion::ItemType::SdkmanPackage, entry.to_s, step: step)
end

# Lays out `<SDKMAN_DIR>/candidates/<candidate>/<version>` the way `sdk
# install` leaves it, with `current` linked to the default version.
private def sdkman_candidate(directory : String, candidate : String, versions : Array(String),
                             current : String? = nil) : Nil
  root = File.join(directory, "candidates", candidate)
  versions.each { |version| Dir.mkdir_p(File.join(root, version, "bin")) }
  Dir.mkdir_p(root)
  File.symlink(current, File.join(root, "current")) if current
end

private def with_sdkman_dir(& : String -> T) : T forall T
  with_probe_dir do |directory|
    previous = ENV["SDKMAN_DIR"]?
    ENV["SDKMAN_DIR"] = directory
    begin
      yield directory
    ensure
      previous ? (ENV["SDKMAN_DIR"] = previous) : ENV.delete("SDKMAN_DIR")
    end
  end
end

# `sdkman-packages` had no probe, so `status` called every candidate unknown
# and `--re-probe` ran `sdk install` for each one again.
describe "sdkman-packages probe" do
  registry = Fluxion::Executor::ProbeRegistry.default
  runner = Fluxion::Executor::FakeShellRunner.new

  it "reports a candidate with a current version as installed, with that version" do
    with_sdkman_dir do |directory|
      sdkman_candidate(directory, "java", ["25.0.4-tem"], current: "25.0.4-tem")

      status = registry.probe(sdkman_item("java"), runner)
      status.should be_a(Fluxion::InstallationStatus::InstalledByProbe)
      status.as(Fluxion::InstallationStatus::InstalledByProbe).detected_version.should eq("25.0.4-tem")
    end
  end

  it "reports a candidate that is missing, or whose current link dangles, as absent" do
    with_sdkman_dir do |directory|
      registry.probe(sdkman_item("maven"), runner).should be_a(Fluxion::InstallationStatus::NotInstalled)

      sdkman_candidate(directory, "gradle", [] of String, current: "9.1.0")
      registry.probe(sdkman_item("gradle"), runner).should be_a(Fluxion::InstallationStatus::NotInstalled)
    end
  end

  it "reports a pinned candidate by its version, whatever current points at" do
    with_sdkman_dir do |directory|
      sdkman_candidate(directory, "java", ["21.0.4-tem", "25.0.4-tem"], current: "25.0.4-tem")

      registry.probe(sdkman_item("java", "21.0.4-tem"), runner)
        .should be_a(Fluxion::InstallationStatus::InstalledByProbe)
      registry.probe(sdkman_item("java", "17.0.12-tem"), runner)
        .should be_a(Fluxion::InstallationStatus::NotInstalled)
    end
  end

  it "looks in ~/.sdkman when SDKMAN_DIR is not set, as sdkman-init.sh does" do
    with_probe_dir do |home|
      previous_home, previous_dir = ENV["HOME"]?, ENV["SDKMAN_DIR"]?
      ENV["HOME"] = home
      ENV.delete("SDKMAN_DIR")
      begin
        sdkman_candidate(File.join(home, ".sdkman"), "sbt", ["1.11.7"], current: "1.11.7")
        registry.probe(sdkman_item("sbt"), runner).should be_a(Fluxion::InstallationStatus::InstalledByProbe)
      ensure
        previous_home ? (ENV["HOME"] = previous_home) : ENV.delete("HOME")
        ENV["SDKMAN_DIR"] = previous_dir if previous_dir
      end
    end
  end
end
