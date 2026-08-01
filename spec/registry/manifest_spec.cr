require "../spec_helper"

private def parse(yaml : String)
  Fluxion::Registry::Manifest.parse(yaml)
end

private def errors(yaml : String) : Array(String)
  _, diagnostics = parse(yaml)
  diagnostics.select(&.error?).map(&.to_s)
end

private def header : String
  <<-YAML
    apiVersion: fluxion.dev/registry/v1
    kind: Registry
    metadata:
      name: demo
    YAML
end

describe Fluxion::Registry::Manifest do
  it "parses a manifest and its entries" do
    manifest, diagnostics = parse(RegistryHelpers::MANIFEST)

    diagnostics.select(&.error?).should be_empty
    manifest = manifest.not_nil!
    manifest.name.should eq("demo-profiles")
    manifest.description.should eq("Demo bootstrap configurations")
    manifest.ids.should eq(["base", "workstation"])

    entry = manifest.entry?("workstation").not_nil!
    entry.name.should eq("Developer workstation")
    entry.path.should eq("profiles/workstation.yaml")
    entry.distributions.should eq([Fluxion::Distribution::Arch, Fluxion::Distribution::Fedora])
    entry.tags.should eq(["developer"])
    entry.requires.should eq(["base"])
  end

  it "defaults the name and the path from the id" do
    manifest, _ = parse(<<-YAML)
      #{header}
      entries:
        - id: minimal
      YAML

    entry = manifest.not_nil!.entry?("minimal").not_nil!
    entry.name.should eq("minimal")
    entry.path.should eq("profiles/minimal.yaml")
  end

  it "rejects an unsupported apiVersion and kind" do
    messages = errors(<<-YAML)
      apiVersion: fluxion.dev/registry/v2
      kind: Profiles
      metadata:
        name: demo
      entries:
        - id: a
      YAML

    messages.any?(&.includes?("fluxion.dev/registry/v1")).should be_true
    messages.any?(&.includes?("'Registry'")).should be_true
  end

  it "requires a name and at least an entries key" do
    messages = errors("apiVersion: fluxion.dev/registry/v1\nkind: Registry\n")
    messages.any?(&.includes?("metadata.name is required")).should be_true
    messages.any?(&.includes?("entries is required")).should be_true
  end

  # A manifest is fetched from a remote repository and its paths are used to
  # read files, so these are the cases that matter most.
  describe "path confinement" do
    it "refuses a path that escapes the profile folder" do
      errors(<<-YAML).any?(&.includes?("normalized")).should be_true
        #{header}
        entries:
          - id: escape
            path: profiles/../../.ssh/id_ed25519
        YAML
    end

    it "refuses an absolute path" do
      errors(<<-YAML).any?(&.includes?("relative")).should be_true
        #{header}
        entries:
          - id: absolute
            path: /etc/shadow
        YAML
    end

    it "refuses a backslash-separated path" do
      errors(<<-YAML).any?(&.includes?("relative")).should be_true
        #{header}
        entries:
          - id: windows
            path: profiles\\\\thing.yaml
        YAML
    end

    it "refuses a path outside the profile folder" do
      errors(<<-YAML).any?(&.includes?("must be inside profiles/")).should be_true
        #{header}
        entries:
          - id: elsewhere
            path: scripts/run.sh
        YAML
    end

    it "accepts a nested path inside the profile folder" do
      manifest, _ = parse(<<-YAML)
        #{header}
        entries:
          - id: nested
            path: profiles/team/nested.yaml
        YAML

      manifest.not_nil!.entry?("nested").not_nil!.path.should eq("profiles/team/nested.yaml")
    end
  end

  describe "ids" do
    it "refuses an id that would not be a safe filename" do
      errors(<<-YAML).any?(&.includes?("id must be lowercase")).should be_true
        #{header}
        entries:
          - id: ../escape
        YAML
    end

    it "refuses an uppercase id" do
      errors(<<-YAML).any?(&.includes?("id must be lowercase")).should be_true
        #{header}
        entries:
          - id: Workstation
        YAML
    end

    it "refuses a duplicate id" do
      errors(<<-YAML).any?(&.includes?("duplicates entry 'base'")).should be_true
        #{header}
        entries:
          - id: base
          - id: base
        YAML
    end

    it "requires an id" do
      errors(<<-YAML).any?(&.includes?("id is required")).should be_true
        #{header}
        entries:
          - name: nameless
        YAML
    end
  end

  it "warns about an unknown distribution without failing" do
    manifest, diagnostics = parse(<<-YAML)
      #{header}
      entries:
        - id: a
          distributions: [arch, plan9]
      YAML

    manifest.should_not be_nil
    diagnostics.select(&.warning?).map(&.to_s).any?(&.includes?("plan9")).should be_true
    manifest.not_nil!.entry?("a").not_nil!.distributions.should eq([Fluxion::Distribution::Arch])
  end

  it "reports invalid YAML rather than raising" do
    manifest, diagnostics = parse("entries: [\n")
    manifest.should be_nil
    diagnostics.select(&.error?).map(&.to_s).any?(&.includes?("not valid YAML")).should be_true
  end

  it "searches across id, name, description, and tags" do
    manifest, _ = parse(RegistryHelpers::MANIFEST)
    manifest = manifest.not_nil!

    manifest.search("developer").map(&.id).should eq(["workstation"])
    manifest.search("HANDFUL").map(&.id).should eq(["base"])
    manifest.search("work").map(&.id).should eq(["workstation"])
    manifest.search("nothing-here").should be_empty
    manifest.search("  ").size.should eq(2)
  end

  it "reports which hosts an entry targets" do
    manifest, _ = parse(RegistryHelpers::MANIFEST)
    entry = manifest.not_nil!.entry?("base").not_nil!

    entry.targets?(Fluxion::Distribution::Arch).should be_true
    entry.targets?(Fluxion::Distribution::Fedora).should be_false
    entry.targets?(nil).should be_false
  end

  it "treats an entry with no distributions as targeting anything" do
    manifest, _ = parse(<<-YAML)
      #{header}
      entries:
        - id: portable
      YAML

    manifest.not_nil!.entry?("portable").not_nil!.targets?(nil).should be_true
  end

  it "produces a template that parses" do
    manifest, diagnostics = parse(Fluxion::Registry::Manifest.template("my-profiles"))

    diagnostics.select(&.error?).should be_empty
    manifest.not_nil!.name.should eq("my-profiles")
  end
end
