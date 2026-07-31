require "../spec_helper"

describe Fluxion::Distribution do
  it "maps Arch derivatives onto Arch" do
    %w[endeavouros manjaro cachyos garuda].each do |id|
      Fluxion::Distribution.from_config?(id).should eq(Fluxion::Distribution::Arch)
    end
  end

  it "maps Ubuntu derivatives onto Ubuntu" do
    Fluxion::Distribution.from_config?("pop").should eq(Fluxion::Distribution::Ubuntu)
    Fluxion::Distribution.from_config?("linuxmint").should eq(Fluxion::Distribution::Ubuntu)
  end

  it "reports opensuse without an underscore" do
    Fluxion::Distribution::OpenSuse.config_name.should eq("opensuse")
  end

  it "returns nil for an unknown id rather than raising" do
    Fluxion::Distribution.from_config?("plan9").should be_nil
    Fluxion::Distribution.from_config?(nil).should be_nil
  end

  it "groups Ubuntu and Debian into one family" do
    Fluxion::Distribution::Ubuntu.family.should eq(Fluxion::OsFamily::Debian)
    Fluxion::Distribution::Debian.family.should eq(Fluxion::OsFamily::Debian)
  end

  it "accepts every AUR helper on Arch" do
    managers = Fluxion::Distribution::Arch.package_managers
    managers.should contain(Fluxion::PackageManager::Pacman)
    managers.should contain(Fluxion::PackageManager::Paru)
    managers.should contain(Fluxion::PackageManager::Yay)
  end

  it "does not accept dnf on Debian" do
    Fluxion::Distribution::Debian.package_managers.should_not contain(Fluxion::PackageManager::Dnf)
  end
end

describe Fluxion::Architecture do
  it "normalizes the common uname spellings" do
    Fluxion::Architecture.from_config?("x86_64").should eq(Fluxion::Architecture::Amd64)
    Fluxion::Architecture.from_config?("aarch64").should eq(Fluxion::Architecture::Arm64)
  end
end
