require "../spec_helper"

private def facts(**options)
  Fluxion::HostFacts.new(**options)
end

private def no_commands
  ->(_command : String) { false }
end

describe Fluxion::Condition do
  fedora = facts(
    distribution: Fluxion::Distribution::Fedora,
    family: Fluxion::OsFamily::Fedora,
    distribution_id: "fedora",
    version: "44",
    architecture: Fluxion::Architecture::Amd64,
  )

  it "selects an entry when nothing is declared" do
    condition = Fluxion::Condition.new
    condition.empty?.should be_true
    condition.matches?(fedora) { false }.should be_true
  end

  it "ORs the values inside one field" do
    condition = Fluxion::Condition.new(distribution: Fluxion::Matcher.new(%w[debian fedora]))
    condition.matches?(fedora) { false }.should be_true
  end

  it "ANDs across fields" do
    condition = Fluxion::Condition.new(
      distribution: Fluxion::Matcher.of("fedora"),
      architecture: Fluxion::Matcher.of("arm64"),
    )
    condition.matches?(fedora) { false }.should be_false
  end

  it "never matches an undetected fact" do
    unknown = facts(distribution: Fluxion::Distribution::Debian)
    condition = Fluxion::Condition.new(codename: Fluxion::Matcher.of("bookworm"))
    condition.matches?(unknown) { false }.should be_false
  end

  it "falls back to the raw os-release id for an unmapped distribution" do
    exotic = facts(distribution_id: "nixos")
    condition = Fluxion::Condition.new(distribution: Fluxion::Matcher.of("nixos"))
    condition.matches?(exotic) { false }.should be_true
  end

  it "requires every command in `commands`" do
    condition = Fluxion::Condition.new(required_commands: %w[git curl])
    condition.matches?(fedora) { |c| c == "git" }.should be_false
    condition.matches?(fedora) { true }.should be_true
  end

  it "requires only one command in `commandExists`" do
    condition = Fluxion::Condition.new(any_commands: %w[apt dnf])
    condition.matches?(fedora) { |c| c == "dnf" }.should be_true
    condition.matches?(fedora) { false }.should be_false
  end

  it "selects when any oneOf branch matches" do
    condition = Fluxion::Condition.new(branches: [
      Fluxion::Condition.new(distribution: Fluxion::Matcher.of("debian")),
      Fluxion::Condition.new(distribution: Fluxion::Matcher.of("fedora")),
    ])
    condition.matches?(fedora) { false }.should be_true
  end

  describe "#unmet_reason" do
    it "is nil exactly when the condition matches" do
      condition = Fluxion::Condition.new(distribution: Fluxion::Matcher.of("fedora"))
      condition.unmet_reason(fedora, &no_commands).should be_nil
    end

    it "names the field, the host value, and the requirement" do
      condition = Fluxion::Condition.new(distribution: Fluxion::Matcher.new(%w[arch debian]))
      reason = condition.unmet_reason(fedora, &no_commands)
      reason.should eq("distribution is fedora, needs one of [arch, debian]")
    end

    it "says which fact was undetected rather than showing a blank" do
      condition = Fluxion::Condition.new(codename: Fluxion::Matcher.of("noble"))
      condition.unmet_reason(fedora, &no_commands).should eq("codename is unknown, needs noble")
    end

    it "names the first missing required command" do
      condition = Fluxion::Condition.new(required_commands: %w[git curl])
      condition.unmet_reason(fedora) { |c| c == "git" }.should eq("curl is not on PATH")
    end

    it "reports the whole set when no optional command is present" do
      condition = Fluxion::Condition.new(any_commands: %w[apt dnf])
      condition.unmet_reason(fedora, &no_commands).should eq("none of [apt, dnf] is on PATH")
    end

    it "reports an exhausted oneOf" do
      condition = Fluxion::Condition.new(branches: [
        Fluxion::Condition.new(distribution: Fluxion::Matcher.of("debian")),
      ])
      condition.unmet_reason(fedora, &no_commands).should eq("no oneOf branch matched")
    end

    it "checks facts in schema order" do
      condition = Fluxion::Condition.new(
        os_family: Fluxion::Matcher.of("debian"),
        distribution: Fluxion::Matcher.of("debian"),
      )
      condition.unmet_reason(fedora, &no_commands).not_nil!.should start_with("os family")
    end
  end
end

describe Fluxion::Matcher do
  it "drops blank entries and normalizes case" do
    matcher = Fluxion::Matcher.new(["  Fedora ", "", "ARCH"])
    matcher.values.should eq(%w[fedora arch])
  end

  it "renders a single value bare and several as a set" do
    Fluxion::Matcher.of("fedora").to_s.should eq("fedora")
    Fluxion::Matcher.new(%w[a b]).to_s.should eq("one of [a, b]")
  end
end
