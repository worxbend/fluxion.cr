require "../spec_helper"

# `ConditionParser` decides which steps run on which host — it is the logic
# behind every `when:` in every profile — and had no direct coverage.
private def parse(yaml : String)
  context = Fluxion::Config::Context.new(Dir.current)
  node = Fluxion::Config::Node.new(YAML.parse(yaml), "when")
  {Fluxion::Config::ConditionParser.parse(context, node), context.diagnostics}
end

private def facts(distribution : Fluxion::Distribution? = nil,
                  family : Fluxion::OsFamily? = nil,
                  version : String? = nil,
                  codename : String? = nil,
                  architecture : Fluxion::Architecture? = nil)
  Fluxion::HostFacts.new(distribution, family, distribution.try(&.config_name),
    version, codename, architecture)
end

describe Fluxion::Config::ConditionParser do
  describe "absent and malformed input" do
    it "returns no condition when the step declared no when block" do
      context = Fluxion::Config::Context.new(Dir.current)
      absent = Fluxion::Config::Node.new(nil, "when")

      Fluxion::Config::ConditionParser.parse(context, absent).should be_nil
      context.diagnostics.empty?.should be_true
    end

    it "treats an empty when block as matching every host" do
      # Distinct from an unrecognised one: `when: {}` declares no constraint
      # rather than a constraint Fluxion failed to understand, so it selects
      # everything without complaint.
      condition, diagnostics = parse("{}")

      diagnostics.empty?.should be_true
      condition.not_nil!.empty?.should be_true
      condition.not_nil!.matches?(facts(Fluxion::Distribution::Fedora)) { true }.should be_true
    end

    it "rejects a when block that is not an object" do
      condition, diagnostics = parse("[a, b]")

      condition.should be_nil
      diagnostics.empty?.should be_false
    end

    it "rejects a when block whose fields are all unrecognised" do
      # A guard that matches everything is the opposite of a guard, so this
      # fails rather than silently selecting every host.
      condition, diagnostics = parse("somethingElse: true")

      condition.should be_nil
      diagnostics.empty?.should be_false
    end

    it "refuses the reserved condition fields rather than guessing" do
      %w[files vars expression].each do |field|
        condition, diagnostics = parse("#{field}: whatever")

        condition.should be_nil
        diagnostics.empty?.should be_false
      end
    end
  end

  describe "matcher shapes" do
    it "accepts a scalar" do
      condition, _ = parse("distribution: fedora")

      condition.should_not be_nil
      condition.not_nil!.matches?(facts(Fluxion::Distribution::Fedora)) { true }.should be_true
      condition.not_nil!.matches?(facts(Fluxion::Distribution::Arch)) { true }.should be_false
    end

    it "accepts a list" do
      condition, _ = parse("distributions: [fedora, arch]")

      subject = condition.not_nil!
      subject.matches?(facts(Fluxion::Distribution::Fedora)) { true }.should be_true
      subject.matches?(facts(Fluxion::Distribution::Arch)) { true }.should be_true
      subject.matches?(facts(Fluxion::Distribution::Debian)) { true }.should be_false
    end

    it "accepts the object forms the schema allows" do
      %w[oneOf equals value].each do |key|
        condition, diagnostics = parse("distribution:\n  #{key}: fedora")

        diagnostics.empty?.should be_true
        condition.not_nil!.matches?(facts(Fluxion::Distribution::Fedora)) { true }.should be_true
      end
    end

    it "treats os and osFamily as the same field" do
      %w[os osFamily].each do |key|
        condition, _ = parse("#{key}: debian")

        condition.not_nil!
          .matches?(facts(family: Fluxion::OsFamily::Debian)) { true }
          .should be_true
      end
    end
  end

  describe "command matchers" do
    it "requires every command in commands" do
      condition, _ = parse("commands: [git, curl]")
      subject = condition.not_nil!

      subject.matches?(facts) { |name| %w[git curl].includes?(name) }.should be_true
      subject.matches?(facts) { |name| name == "git" }.should be_false
    end

    it "requires only one of commandExists" do
      condition, _ = parse("commandExists: [paru, yay]")
      subject = condition.not_nil!

      subject.matches?(facts) { |name| name == "yay" }.should be_true
      subject.matches?(facts) { false }.should be_false
    end
  end

  describe "oneOf" do
    it "matches when any branch matches" do
      condition, diagnostics = parse(<<-YAML)
        oneOf:
          - distribution: fedora
          - distribution: arch
        YAML

      diagnostics.empty?.should be_true
      subject = condition.not_nil!
      subject.matches?(facts(Fluxion::Distribution::Fedora)) { true }.should be_true
      subject.matches?(facts(Fluxion::Distribution::Arch)) { true }.should be_true
      subject.matches?(facts(Fluxion::Distribution::Debian)) { true }.should be_false
    end

    it "combines a top-level matcher with its branches" do
      # Both have to hold: the architecture gate and one of the distributions.
      condition, _ = parse(<<-YAML)
        architecture: amd64
        oneOf:
          - distribution: fedora
          - distribution: arch
        YAML

      subject = condition.not_nil!
      subject.matches?(facts(Fluxion::Distribution::Fedora,
        architecture: Fluxion::Architecture::Amd64)) { true }.should be_true
      subject.matches?(facts(Fluxion::Distribution::Fedora,
        architecture: Fluxion::Architecture::Arm64)) { true }.should be_false
    end
  end

  describe "version and codename" do
    it "matches a version" do
      condition, _ = parse("version: \"41\"")
      subject = condition.not_nil!

      subject.matches?(facts(version: "41")) { true }.should be_true
      subject.matches?(facts(version: "40")) { true }.should be_false
    end

    it "matches a codename" do
      condition, _ = parse("codename: bookworm")
      subject = condition.not_nil!

      subject.matches?(facts(codename: "bookworm")) { true }.should be_true
      subject.matches?(facts(codename: "trixie")) { true }.should be_false
    end
  end
end
