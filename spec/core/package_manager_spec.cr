require "../spec_helper"

describe Fluxion::PackageManager do
  it "installs one package per invocation, non-interactively" do
    Fluxion::PackageManager::Dnf.install_argv("git")
      .should eq(["sudo", "dnf", "install", "-y", "git"])
    Fluxion::PackageManager::Apt.install_argv("git")
      .should eq(["sudo", "apt-get", "install", "-y", "git"])
    Fluxion::PackageManager::Pacman.install_argv("git")
      .should eq(["sudo", "pacman", "-S", "--noconfirm", "git"])
    Fluxion::PackageManager::Zypper.install_argv("git")
      .should eq(["sudo", "zypper", "install", "-y", "git"])
  end

  it "does not wrap AUR helpers in sudo, since they escalate themselves" do
    Fluxion::PackageManager::Paru.install_argv("yay-bin").first.should eq("paru")
    Fluxion::PackageManager::Yay.install_argv("yay-bin").first.should eq("yay")
    Fluxion::PackageManager::Paru.aur?.should be_true
    Fluxion::PackageManager::Pacman.aur?.should be_false
  end

  it "treats dnf check-update's exit 100 as success, not failure" do
    argv, ok = Fluxion::PackageManager::Dnf.action_argv(Fluxion::PackageAction.new("check-update"))
    argv.should eq(["sudo", "dnf", "check-update"])
    ok.should contain(100)
    ok.should contain(0)
  end

  it "passes configured arguments through to the action" do
    argv, _ = Fluxion::PackageManager::Apt.action_argv(
      Fluxion::PackageAction.new("upgrade", ["--no-remove"]))
    argv.should eq(["sudo", "apt-get", "upgrade", "-y", "--no-remove"])
  end

  it "puts --non-interactive before every zypper action" do
    argv, _ = Fluxion::PackageManager::Zypper.action_argv(Fluxion::PackageAction.new("dup"))
    argv.should eq(["sudo", "zypper", "--non-interactive", "dup", "-y"])
  end

  it "rejects an action the manager does not have" do
    expect_raises(Fluxion::ExecutionError, /Unsupported dnf action: dist-upgrade/) do
      Fluxion::PackageManager::Dnf.action_argv(Fluxion::PackageAction.new("dist-upgrade"))
    end
  end

  it "rejects actions entirely for cargo and flatpak" do
    expect_raises(Fluxion::ExecutionError, /not supported/) do
      Fluxion::PackageManager::Cargo.action_argv(Fluxion::PackageAction.new("update"))
    end
  end

  it "knows which managers can update the whole system" do
    Fluxion::PackageManager::Dnf.supports_system_update?.should be_true
    Fluxion::PackageManager::Cargo.supports_system_update?.should be_false
    Fluxion::PackageManager::Flatpak.supports_system_update?.should be_false
  end

  it "does not shadow the built-in enum parser" do
    # `from_config?` exists precisely so a config spelling like apt-get cannot
    # be silently swallowed by Enum.parse?.
    Fluxion::PackageManager.from_config?("DNF").should eq(Fluxion::PackageManager::Dnf)
    Fluxion::PackageManager.from_config?("nix").should be_nil
  end
end

describe Fluxion::ToolBackend do
  it "names the install strategy, not always the binary" do
    Fluxion::ToolBackend::UvTool.config_name.should eq("uv-tool")
    Fluxion::ToolBackend::UvTool.command.should eq("uv")
    Fluxion::ToolBackend::NpmGlobal.command.should eq("npm")
  end

  it "pins versions using each registry's own syntax" do
    pinned = Fluxion::ToolPackage.new("ripgrep", "14.1.0")
    Fluxion::ToolBackend::CargoBinstall.install_argv(pinned)
      .should eq(["cargo-binstall", "--no-confirm", "ripgrep@14.1.0"])
    Fluxion::ToolBackend::Cargo.install_argv(pinned)
      .should eq(["cargo", "install", "--locked", "--version", "14.1.0", "ripgrep"])
    Fluxion::ToolBackend::Pipx.install_argv(pinned)
      .should eq(["pipx", "install", "ripgrep==14.1.0"])
    Fluxion::ToolBackend::Snap.install_argv(pinned)
      .should eq(["sudo", "snap", "install", "ripgrep", "--channel", "14.1.0"])
  end

  it "falls back to @latest for go, which has no unpinned form" do
    Fluxion::ToolBackend::GoInstall.install_argv(Fluxion::ToolPackage.new("github.com/a/b"))
      .should eq(["go", "install", "github.com/a/b@latest"])
  end

  it "only escalates for snap" do
    Fluxion::ToolBackend::Snap.install_argv(Fluxion::ToolPackage.new("code")).first.should eq("sudo")
    Fluxion::ToolBackend::Pipx.install_argv(Fluxion::ToolPackage.new("black")).first.should eq("pipx")
  end
end
