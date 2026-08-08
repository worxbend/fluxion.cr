require "../spec_helper"

# A step executor's contract is the argv it builds and how it reads a result.
# Both are observable through the fake runner, which is why these specs pass on
# a machine with no package manager, no systemd, and no network.

private def registry
  Fluxion::Executor::ExecutorRegistry.default
end

# Erases the concrete step type. Without this, Crystal specialises every
# executor's `commands` for whichever subclass the spec happened to pass, and
# the `.as(...)` inside an unrelated executor becomes a compile error.
private def erase(step : Fluxion::Step) : Fluxion::Step
  ([step] of Fluxion::Step).first
end

private def executor_for(step : Fluxion::Step)
  registry.for(step).not_nil!
end

private def argv_for(raw : Fluxion::Step, key : String? = nil) : Array(Array(String))
  step = erase(raw)
  executor = executor_for(step)
  items = executor.items(step)
  item = key ? items.find! { |candidate| candidate.key == key } : items.first
  executor.commands(step, item).map(&.argv)
end

private def run_item(raw : Fluxion::Step, runner : Fluxion::Executor::FakeShellRunner,
                     key : String? = nil) : Fluxion::StepResult
  step = erase(raw)
  executor = executor_for(step)
  items = executor.items(step)
  item = key ? items.find! { |candidate| candidate.key == key } : items.first
  executor.execute(step, item, runner) { }
end

describe "packages" do
  it "installs one package per invocation" do
    step = Fluxion::PackagesStep.new("tools", Fluxion::PackageManager::Dnf, ["git", "curl"])
    argv_for(step, "git").should eq([["sudo", "dnf", "install", "-y", "git"]])
    argv_for(step, "curl").should eq([["sudo", "dnf", "install", "-y", "curl"]])
  end

  it "tracks a pre-install action as its own item" do
    # A failed metadata refresh is visible rather than folded into the first
    # package's failure.
    step = Fluxion::PackagesStep.new("tools", Fluxion::PackageManager::Dnf, ["git"],
      actions: [Fluxion::PackageAction.new("check-update")])

    items = executor_for(step).items(step)
    items.map(&.key).should eq(["action[0]", "git"])
    argv_for(step, "action[0]").should eq([["sudo", "dnf", "check-update"]])
  end

  it "treats dnf check-update's exit 100 as success" do
    step = Fluxion::PackagesStep.new("tools", Fluxion::PackageManager::Dnf, [] of String,
      actions: [Fluxion::PackageAction.new("check-update")])
    runner = Fluxion::Executor::FakeShellRunner.new.default(Fluxion::ProcessResult.new(100))

    run_item(step, runner, "action[0]").should be_a(Fluxion::StepResult::Success)
  end

  it "does not escalate for an AUR helper" do
    step = Fluxion::PackagesStep.new("aur", Fluxion::PackageManager::Paru, ["yay-bin"])
    argv_for(step).first.first.should eq("paru")
  end
end

describe "tool-packages" do
  it "uses each backend's own pin syntax" do
    step = Fluxion::ToolPackagesStep.new("rust", Fluxion::ToolBackend::CargoBinstall,
      [Fluxion::ToolPackage.new("ripgrep", "14.1.0")])
    argv_for(step).should eq([["cargo-binstall", "--no-confirm", "ripgrep@14.1.0"]])
  end

  it "fails with an actionable message when the backend is absent" do
    # Better than twenty command-not-found failures in a row.
    step = Fluxion::ToolPackagesStep.new("rust", Fluxion::ToolBackend::Pipx,
      [Fluxion::ToolPackage.new("black")])
    result = run_item(step, Fluxion::Executor::FakeShellRunner.new)

    result.should be_a(Fluxion::StepResult::Failure)
    result.as(Fluxion::StepResult::Failure).error_message.should contain("pipx is not on PATH")
  end
end

describe "system-update" do
  it "refreshes then upgrades for apt" do
    step = Fluxion::SystemUpdateStep.new("update", Fluxion::PackageManager::Apt)
    argv_for(step).should eq([
      ["sudo", "apt-get", "update"],
      ["sudo", "apt-get", "upgrade", "-y"],
    ])
  end

  it "uses full-upgrade for a distribution upgrade" do
    step = Fluxion::SystemUpdateStep.new("update", Fluxion::PackageManager::Apt, dist_upgrade: true)
    argv_for(step).last.should eq(["sudo", "apt-get", "full-upgrade", "-y"])
  end

  it "stops at the refresh when only that was asked for" do
    step = Fluxion::SystemUpdateStep.new("update", Fluxion::PackageManager::Zypper, refresh_only: true)
    argv_for(step).should eq([["sudo", "zypper", "--non-interactive", "refresh"]])
  end
end

describe "user-groups" do
  it "adds without removing" do
    step = Fluxion::UserGroupsStep.new("groups", ["docker"], user: "alice")
    argv_for(step).should eq([["sudo", "usermod", "-aG", "docker", "alice"]])
  end

  it "creates the group first when asked" do
    step = Fluxion::UserGroupsStep.new("groups", ["docker"], user: "alice", create_missing: true)
    argv_for(step).first.should eq(["sudo", "groupadd", "-f", "docker"])
  end

  it "refuses a missing group rather than inventing one" do
    # A group that does not exist usually means a typo or an uninstalled
    # package, and creating a real but useless group would hide that.
    step = Fluxion::UserGroupsStep.new("groups", ["docker"], user: "alice")
    runner = Fluxion::Executor::FakeShellRunner.new.on("getent group docker", 2)

    result = run_item(step, runner)
    result.should be_a(Fluxion::StepResult::Failure)
    result.as(Fluxion::StepResult::Failure).error_message.should contain("does not exist")
  end
end

describe "git-config" do
  it "sets one key at a time so drift is reportable per key" do
    step = Fluxion::GitConfigStep.new("identity", {"user.email" => "me@example.test"})
    argv_for(step).should eq([["git", "config", "--global", "user.email", "me@example.test"]])
  end

  it "escalates for system scope" do
    step = Fluxion::GitConfigStep.new("identity", {"user.email" => "a@b.test"},
      scope: Fluxion::GitConfigScope::System)
    argv_for(step).first.first.should eq("sudo")
  end
end

describe "git-repo" do
  commit = "a" * 40

  it "fetches the exact commit rather than a branch" do
    # The pin stays reachable even after the upstream default branch has moved
    # past a shallow depth.
    repo = Fluxion::GitRepo.new("https://github.com/a/b.git", "/tmp/fluxion-spec-repo", commit, 1)
    step = Fluxion::GitRepoStep.new("repos", [repo])

    argv = argv_for(step)
    argv.map(&.first).should eq(%w[git git git git])
    argv[2].should contain("--depth")
    argv[2].last.should eq(commit)
    argv[3].should eq(["git", "-C", "/tmp/fluxion-spec-repo", "checkout", "--detach", "FETCH_HEAD"])
  end

  it "inspects an existing checkout instead of resetting it" do
    directory = File.tempname("fluxion-repo")
    Dir.mkdir_p(File.join(directory, ".git"))

    begin
      repo = Fluxion::GitRepo.new("https://github.com/a/b.git", directory, commit)
      step = Fluxion::GitRepoStep.new("repos", [repo])

      runner = Fluxion::Executor::FakeShellRunner.new
        .on("remote get-url origin", Fluxion::ProcessResult.new(0, "https://github.com/a/b.git\n"))
        .on("rev-parse --verify HEAD", Fluxion::ProcessResult.new(0, "#{commit}\n"))

      run_item(step, runner).should be_a(Fluxion::StepResult::Success)
      # Overwriting a checkout the user has been working in would lose it.
      runner.ran?("checkout").should be_false
      runner.ran?("fetch").should be_false
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "fails an existing checkout whose origin does not match" do
    directory = File.tempname("fluxion-repo")
    Dir.mkdir_p(File.join(directory, ".git"))

    begin
      repo = Fluxion::GitRepo.new("https://github.com/a/b.git", directory, commit)
      step = Fluxion::GitRepoStep.new("repos", [repo])

      runner = Fluxion::Executor::FakeShellRunner.new
        .on("remote get-url origin", Fluxion::ProcessResult.new(0, "https://evil.test/x.git\n"))

      result = run_item(step, runner)
      result.as(Fluxion::StepResult::Failure).error_message.should contain("origin does not match")
    ensure
      FileUtils.rm_rf(directory)
    end
  end
end

describe "systemd-unit" do
  it "enables and starts" do
    unit = Fluxion::SystemdUnit.new("docker", true, Fluxion::SystemdState::Started)
    step = Fluxion::SystemdUnitStep.new("services", [unit])

    argv_for(step).should eq([
      ["sudo", "systemctl", "--system", "enable", "docker.service"],
      ["sudo", "systemctl", "--system", "start", "docker.service"],
    ])
  end

  it "masks instead of enabling, since the two contradict" do
    unit = Fluxion::SystemdUnit.new("sshd", false, Fluxion::SystemdState::Unchanged, true)
    step = Fluxion::SystemdUnitStep.new("services", [unit])

    argv_for(step).should eq([["sudo", "systemctl", "--system", "mask", "sshd.service"]])
  end

  it "does not escalate for the user scope" do
    unit = Fluxion::SystemdUnit.new("syncthing")
    step = Fluxion::SystemdUnitStep.new("services", [unit], scope: Fluxion::SystemdScope::User)
    argv_for(step).first.first.should eq("systemctl")
  end

  it "skips rather than fails where systemd is absent" do
    # The same profile stays usable in a container or an image build.
    unit = Fluxion::SystemdUnit.new("docker")
    step = Fluxion::SystemdUnitStep.new("services", [unit])

    result = run_item(step, Fluxion::Executor::FakeShellRunner.new)
    result.should be_a(Fluxion::StepResult::Skipped)
  end
end

describe "system-setting" do
  it "probes and sets each setting individually" do
    step = Fluxion::SystemSettingStep.new("clock", ntp: true, timezone: "Europe/Warsaw",
      locale: {"LANG" => "en_US.UTF-8"})

    argv_for(step, "ntp").should eq([["sudo", "timedatectl", "set-ntp", "true"]])
    argv_for(step, "timezone").should eq([["sudo", "timedatectl", "set-timezone", "Europe/Warsaw"]])
    argv_for(step, "locale:LANG").should eq([["sudo", "localectl", "set-locale", "LANG=en_US.UTF-8"]])
  end
end

describe "shell-command" do
  it "keeps a shell string and a direct argv distinct" do
    step = Fluxion::ShellCommandStep.new("setup", [
      Fluxion::ShellCommandItem.new(name: "a", shell_command: "echo hi"),
      Fluxion::ShellCommandItem.new(name: "b", argv: ["git", "status"]),
    ])

    argv_for(step, "a").should eq([["/bin/bash", "-lc", "echo hi"]])
    argv_for(step, "b").should eq([["git", "status"]])
  end

  it "skips when the creates path already exists" do
    existing = File.tempname("fluxion-creates")
    File.write(existing, "")

    begin
      step = Fluxion::ShellCommandStep.new("setup", [
        Fluxion::ShellCommandItem.new(name: "a", shell_command: "true", creates: existing),
      ])
      runner = Fluxion::Executor::FakeShellRunner.new

      run_item(step, runner).should be_a(Fluxion::StepResult::Skipped)
      runner.commands.should be_empty
    ensure
      File.delete(existing)
    end
  end

  it "skips when the unless guard succeeds" do
    step = Fluxion::ShellCommandStep.new("setup", [
      Fluxion::ShellCommandItem.new(name: "a", shell_command: "install", unless_command: "already"),
    ])
    runner = Fluxion::Executor::FakeShellRunner.new.on("already", 0)

    run_item(step, runner).should be_a(Fluxion::StepResult::Skipped)
    runner.ran?("-lc install").should be_false
  end

  it "runs when the unless guard fails" do
    step = Fluxion::ShellCommandStep.new("setup", [
      Fluxion::ShellCommandItem.new(name: "a", shell_command: "install", unless_command: "already"),
    ])
    runner = Fluxion::Executor::FakeShellRunner.new.on("already", 1)

    run_item(step, runner).should be_a(Fluxion::StepResult::Success)
    runner.ran?("install").should be_true
  end

  it "honours a non-zero allowed exit code" do
    step = Fluxion::ShellCommandStep.new("setup", [
      Fluxion::ShellCommandItem.new(name: "a", shell_command: "check", allowed_exit_codes: [0, 2]),
    ])
    runner = Fluxion::Executor::FakeShellRunner.new.default(Fluxion::ProcessResult.new(2))

    run_item(step, runner).should be_a(Fluxion::StepResult::Success)
  end
end

describe "assert" do
  it "reports the configured message rather than the command output" do
    # The message is written for someone who has to go fix the machine.
    step = Fluxion::AssertStep.new("secure-boot", "mokutil --sb-state | grep -qi disabled",
      "Disable Secure Boot before installing this graphics stack.")
    runner = Fluxion::Executor::FakeShellRunner.new.default(Fluxion::ProcessResult.new(1, "no match"))

    result = run_item(step, runner)
    result.as(Fluxion::StepResult::Failure).error_message
      .should eq("Disable Secure Boot before installing this graphics stack.")
  end
end

describe "manual" do
  it "fails with its message when there is no probe" do
    # Without one there is no way to know the human did the thing.
    step = Fluxion::ManualStep.new("login", "Run gh auth login, then continue.")
    result = run_item(step, Fluxion::Executor::FakeShellRunner.new)

    result.as(Fluxion::StepResult::Failure).error_message.should contain("gh auth login")
  end

  it "succeeds once the probe passes" do
    step = Fluxion::ManualStep.new("login", "Run gh auth login.", probe_command: "gh auth status")
    runner = Fluxion::Executor::FakeShellRunner.new.on("gh auth status", 0)

    run_item(step, runner).should be_a(Fluxion::StepResult::Success)
  end
end

describe "flatpak" do
  it "installs from the declared remote" do
    step = Fluxion::FlatpakStep.new("apps", ["com.spotify.Client"], "flathub")
    argv_for(step).should eq([["flatpak", "install", "-y", "flathub", "com.spotify.Client"]])
  end
end

describe "sdkman" do
  it "goes through a login shell, since SDKMAN has no argv interface" do
    step = Fluxion::SdkmanPackagesStep.new("sdks",
      [Fluxion::SdkmanCandidate.new("java", "21.0.2-tem")])

    argv = argv_for(step).first
    argv[0, 2].should eq(["/bin/bash", "-lc"])
    argv.last.should contain("sdk install java 21.0.2-tem")
    argv.last.should contain("sdkman-init.sh")
  end
end

describe "default-shell" do
  it "refuses a shell that is not executable" do
    # Setting a login shell that does not exist locks the user out of their
    # own account.
    step = Fluxion::DefaultShellStep.new("zsh", "/definitely/missing/zsh")
    result = run_item(step, Fluxion::Executor::FakeShellRunner.new)

    result.as(Fluxion::StepResult::Failure).error_message.should contain("not an executable file")
  end

  it "uses chsh for the target user" do
    step = Fluxion::DefaultShellStep.new("sh", "/bin/sh")
    argv_for(step).first[0, 4].should eq(["sudo", "chsh", "-s", "/bin/sh"])
  end
end

describe "shell-reload" do
  it "reports success explicitly rather than just exiting" do
    # A shell whose rc file swallows errors would otherwise look fine.
    step = Fluxion::ShellReloadStep.new("reload", Fluxion::ShellKind::Zsh)
    argv = argv_for(step).first

    argv[0, 4].should eq(["zsh", "--login", "-i", "-c"])
    argv.last.should contain("Shell environment OK")
  end

  it "points at the rc file when the shell fails to start" do
    step = Fluxion::ShellReloadStep.new("reload", Fluxion::ShellKind::Zsh)
    runner = Fluxion::Executor::FakeShellRunner.new.default(Fluxion::ProcessResult.new(1, "parse error"))

    result = run_item(step, runner)
    result.as(Fluxion::StepResult::Failure).error_message.should contain(".zshrc")
  end
end
