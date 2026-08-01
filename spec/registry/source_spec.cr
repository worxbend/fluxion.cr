require "../spec_helper"

private alias Source = Fluxion::Registry::Source
private alias Settings = Fluxion::Registry::Settings

describe Fluxion::Registry::Source do
  describe ".derive_name" do
    it "takes the last path segment of an https URL" do
      Source.derive_name("https://github.com/worxbend/fluxion-profiles.git").should eq("fluxion-profiles")
      Source.derive_name("https://github.com/worxbend/fluxion-profiles").should eq("fluxion-profiles")
      Source.derive_name("https://github.com/worxbend/fluxion-profiles/").should eq("fluxion-profiles")
    end

    it "handles an scp-style ssh URL" do
      Source.derive_name("git@github.com:worxbend/profiles.git").should eq("profiles")
    end

    it "handles a local path" do
      Source.derive_name("/srv/git/team-profiles").should eq("team-profiles")
    end

    it "returns nil when the segment would not be a safe directory name" do
      Source.derive_name("https://example.com/..").should be_nil
      Source.derive_name("").should be_nil
      Source.derive_name("/").should be_nil
    end
  end

  describe ".validate_url" do
    it "accepts https, ssh, and local paths" do
      Source.validate_url("https://github.com/a/b").should be_nil
      Source.validate_url("ssh://git@github.com/a/b").should be_nil
      Source.validate_url("git@github.com:a/b.git").should be_nil
      Source.validate_url("file:///srv/git/b").should be_nil
      Source.validate_url("/srv/git/b").should be_nil
    end

    # A registry decides what a machine will be told to install, so plain http
    # is refused rather than merely discouraged.
    it "refuses http" do
      Source.validate_url("http://example.com/a").should eq("registry URL must use https, not http")
    end

    it "refuses anything else" do
      Source.validate_url("ftp://example.com/a").should_not be_nil
      Source.validate_url("   ").should eq("registry URL must not be blank")
    end
  end

  describe ".valid_name?" do
    it "accepts names usable as a directory" do
      Source.valid_name?("profiles").should be_true
      Source.valid_name?("team.profiles-2_0").should be_true
    end

    it "refuses traversal and separators" do
      Source.valid_name?("..").should be_false
      Source.valid_name?("a/b").should be_false
      Source.valid_name?("a..b").should be_false
      Source.valid_name?("-leading").should be_false
      Source.valid_name?("").should be_false
    end
  end

  it "keeps the mirror and the installed configurations apart" do
    RegistryHelpers.with_sandbox do |sandbox|
      source = sandbox.source
      source.mirror_path.should_not eq(source.install_path)
      source.mirror_path.should contain("cache")
      source.install_path.should contain("config")
      source.manifest_path.should eq(File.join(source.mirror_path, "fluxion-registry.yaml"))
    end
  end
end

describe Fluxion::Registry::Settings do
  it "round-trips through the settings file" do
    RegistryHelpers.with_sandbox do |_|
      path = Source.settings_path
      Settings.new
        .add(Source.new("one", "https://example.com/one", "main", true))
        .add(Source.new("two", "https://example.com/two"))
        .save(path)

      loaded = Settings.load(path)
      loaded.sources.map(&.name).should eq(["one", "two"])
      loaded.find("one").not_nil!.ref.should eq("main")
      loaded.find("one").not_nil!.default?.should be_true
      loaded.find("two").not_nil!.default?.should be_false
    end
  end

  it "writes the settings file readable only by its owner" do
    RegistryHelpers.with_sandbox do |_|
      path = Source.settings_path
      Settings.new.add(Source.new("one", "https://example.com/one")).save(path)

      File.info(path).permissions.should eq(File::Permissions.new(0o600))
    end
  end

  it "returns empty settings when nothing is configured" do
    Settings.load(File.join(File.tempname("fluxion-missing"), "registries.yaml")).sources.should be_empty
  end

  it "keeps only one default" do
    settings = Settings.new
      .add(Source.new("one", "https://example.com/one", nil, true))
      .add(Source.new("two", "https://example.com/two", nil, true))

    settings.sources.count(&.default?).should eq(1)
    settings.resolve.name.should eq("two")
  end

  it "moves the default with set_default" do
    settings = Settings.new
      .add(Source.new("one", "https://example.com/one", nil, true))
      .add(Source.new("two", "https://example.com/two"))
      .set_default("two")

    settings.resolve.name.should eq("two")
    settings.find("one").not_nil!.default?.should be_false
  end

  describe "#resolve" do
    it "uses the only registry when just one is configured" do
      settings = Settings.new.add(Source.new("only", "https://example.com/only"))
      settings.resolve.name.should eq("only")
    end

    it "refuses to guess between several undefaulted registries" do
      settings = Settings.new
        .add(Source.new("one", "https://example.com/one"))
        .add(Source.new("two", "https://example.com/two"))

      expect_raises(Fluxion::ExecutionError, /none is the default/) { settings.resolve }
    end

    it "explains that nothing is configured" do
      expect_raises(Fluxion::ExecutionError, /No registries configured/) { Settings.new.resolve }
    end

    it "names the configured registries when asked for an unknown one" do
      settings = Settings.new.add(Source.new("one", "https://example.com/one"))
      expect_raises(Fluxion::ExecutionError, /Unknown registry 'other'.*one/) { settings.resolve("other") }
    end
  end

  it "refuses to add a duplicate name" do
    settings = Settings.new.add(Source.new("one", "https://example.com/one"))
    expect_raises(Fluxion::ExecutionError, /already configured/) do
      settings.add(Source.new("one", "https://example.com/other"))
    end
  end

  it "refuses to remove an unknown registry" do
    expect_raises(Fluxion::ExecutionError, /Unknown registry/) { Settings.new.remove("ghost") }
  end
end
