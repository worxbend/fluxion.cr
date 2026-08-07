require "../spec_helper"

private record Run, exit_code : Fluxion::CLI::ExitCode, stdout : String, stderr : String do
  def success? : Bool
    exit_code.success?
  end

  def json : JSON::Any
    JSON.parse(stdout)
  end
end

private def invoke(*arguments : String) : Run
  output = IO::Memory.new
  errors = IO::Memory.new

  code = Fluxion::CLI::Style.with_color(false) do
    Fluxion::CLI::App.new(Fluxion::CLI::GlobalOptions.new, output, errors).run(arguments.to_a)
  end

  Run.new(code, output.to_s, errors.to_s)
end

# The registry is a git repository, so these run against a real one over
# file://. Without git there is nothing meaningful left to assert.
private def with_registry(&block : RegistryHelpers::Sandbox ->)
  pending!("git is not available") unless RegistryHelpers.git_available?
  RegistryHelpers.with_git_registry(&block)
end

private def add_registry(sandbox : RegistryHelpers::Sandbox) : Run
  invoke("registry", "add", "file://#{sandbox.repository}", "--name", "demo")
end

describe "fluxion registry" do
  it "adds, syncs, and lists a registry in one step" do
    with_registry do |sandbox|
      result = add_registry(sandbox)

      result.success?.should be_true
      result.stdout.should contain("Registered demo")
      result.stdout.should contain("2 configurations available")

      listed = invoke("registry", "list")
      listed.stdout.should contain("demo")
      listed.stdout.should contain("synced @")
    end
  end

  it "refuses a plain http URL" do
    RegistryHelpers.with_sandbox do |_|
      result = invoke("registry", "add", "http://example.com/profiles")

      result.exit_code.should eq(Fluxion::CLI::ExitCode::InvalidInput)
      result.stderr.should contain("must use https")
    end
  end

  it "explains that nothing is configured yet" do
    RegistryHelpers.with_sandbox do |_|
      invoke("registry", "list").stdout.should contain("No registries configured")
      invoke("remote-ls").exit_code.success?.should be_false
    end
  end

  it "lists what a registry offers" do
    with_registry do |sandbox|
      add_registry(sandbox)

      result = invoke("remote-ls", "--all")
      result.success?.should be_true
      result.stdout.should contain("demo-profiles")
      result.stdout.should contain("base")
      result.stdout.should contain("workstation")
      result.stdout.should contain("not installed")
    end
  end

  it "filters the listing by a search term" do
    with_registry do |sandbox|
      add_registry(sandbox)

      result = invoke("registry", "ls", "--all", "--search", "developer")
      result.stdout.should contain("workstation")
      result.stdout.should_not contain("Base tools")
    end
  end

  it "renders the listing as JSON" do
    with_registry do |sandbox|
      add_registry(sandbox)

      entries = invoke("remote-ls", "--all", "--format", "json").json["entries"].as_a
      entries.map(&.["id"].as_s).should eq(["base", "workstation"])
      entries.first["installed"].as_bool.should be_false
      entries.first["state"].as_s.should eq("absent")
    end
  end

  it "installs a configuration by id" do
    with_registry do |sandbox|
      add_registry(sandbox)

      result = invoke("registry", "install", "base")
      result.success?.should be_true
      result.stdout.should contain("Installed base")

      File.exists?(sandbox.installed_file("base")).should be_true
      invoke("registry", "status").stdout.should contain("current")
    end
  end

  it "installs what an entry requires when asked" do
    with_registry do |sandbox|
      add_registry(sandbox)

      result = invoke("registry", "install", "workstation", "--with-requires")

      result.stdout.should contain("Installed base")
      result.stdout.should contain("Installed workstation")
      # The review hint points at what was asked for, not at its requirement.
      result.stdout.should contain("dry-run -c #{sandbox.installed_file("workstation")}")
    end
  end

  it "mentions requirements it did not install" do
    with_registry do |sandbox|
      add_registry(sandbox)

      result = invoke("registry", "install", "workstation")
      result.stdout.should contain("it expects alongside it: base")
      File.exists?(sandbox.installed_file("base")).should be_false
    end
  end

  it "names the available entries when the id is unknown" do
    with_registry do |sandbox|
      add_registry(sandbox)

      result = invoke("registry", "install", "ghost")
      result.exit_code.should eq(Fluxion::CLI::ExitCode::InvalidInput)
      result.stderr.should contain("has no entry 'ghost'")
      result.stderr.should contain("base")
    end
  end

  it "shows one configuration in detail" do
    with_registry do |sandbox|
      add_registry(sandbox)

      result = invoke("registry", "show", "base")
      result.success?.should be_true
      result.stdout.should contain("Base tools")
      result.stdout.should contain("profiles/base.yaml")
      result.stdout.should contain("kind: pacman-packages")
    end
  end

  it "asks for a sync before reading a registry that was added with --no-sync" do
    RegistryHelpers.with_sandbox do |_|
      invoke("registry", "add", "https://example.invalid/profiles", "--name", "later", "--no-sync")

      result = invoke("remote-ls")
      result.exit_code.should eq(Fluxion::CLI::ExitCode::InvalidInput)
      result.stderr.should contain("has not been synced yet")
    end
  end

  describe "sync" do
    it "reports which installed configurations changed upstream" do
      with_registry do |sandbox|
        add_registry(sandbox)
        invoke("registry", "install", "base")

        File.write(File.join(sandbox.repository, "profiles", "base.yaml"),
          RegistryHelpers.profile("base", "ripgrep"))
        RegistryHelpers.git(sandbox.repository, "commit", "-qam", "change base")

        result = invoke("registry", "sync")
        result.success?.should be_true
        result.stdout.should contain("1 installed configuration changed upstream")
        result.stdout.should contain("base")

        # Syncing refreshes the mirror and leaves the installed copy alone.
        File.read(sandbox.installed_file("base")).should_not contain("ripgrep")
        invoke("registry", "status").stdout.should contain("update available")
      end
    end

    it "says when there was nothing new" do
      with_registry do |sandbox|
        add_registry(sandbox)
        invoke("registry", "sync").stdout.should contain("already current")
      end
    end
  end

  describe "local edits" do
    it "refuses to overwrite them without --force" do
      with_registry do |sandbox|
        add_registry(sandbox)
        invoke("registry", "install", "base")
        File.write(sandbox.installed_file("base"), RegistryHelpers.profile("base", "fd"))

        result = invoke("registry", "install", "base")
        result.success?.should be_false
        result.stderr.should contain("local edits")

        invoke("registry", "install", "base", "--force").success?.should be_true
        File.read(sandbox.installed_file("base")).should_not contain("fd")
      end
    end

    it "publishes them back to the registry" do
      with_registry do |sandbox|
        add_registry(sandbox)
        invoke("registry", "install", "base")
        File.write(sandbox.installed_file("base"), RegistryHelpers.profile("base", "fd"))

        preview = invoke("registry", "publish", "--dry-run")
        preview.stdout.should contain("nothing was staged")
        RegistryHelpers.git?(sandbox.repository, "log", "--oneline").lines.size.should eq(1)

        result = invoke("registry", "publish", "--message", "spec change")
        result.success?.should be_true
        result.stdout.should contain("Published 1 configuration")

        RegistryHelpers.git?(sandbox.repository, "log", "--oneline").should contain("spec change")
        File.read(File.join(sandbox.repository, "profiles", "base.yaml")).should contain("fd")
        invoke("registry", "status").stdout.should contain("current")
      end
    end

    it "refuses to publish something that also changed upstream" do
      with_registry do |sandbox|
        add_registry(sandbox)
        invoke("registry", "install", "base")
        File.write(sandbox.installed_file("base"), RegistryHelpers.profile("base", "fd"))

        File.write(File.join(sandbox.repository, "profiles", "base.yaml"),
          RegistryHelpers.profile("base", "ripgrep"))
        RegistryHelpers.git(sandbox.repository, "commit", "-qam", "upstream change")
        invoke("registry", "sync")

        result = invoke("registry", "publish")
        result.success?.should be_false
        result.stderr.should contain("changed both locally and upstream")
      end
    end

    it "says when there is nothing to publish" do
      with_registry do |sandbox|
        add_registry(sandbox)
        invoke("registry", "install", "base")

        invoke("registry", "publish").stdout.should contain("Nothing to publish")
      end
    end
  end

  describe "uninstall and remove" do
    it "removes an installed configuration" do
      with_registry do |sandbox|
        add_registry(sandbox)
        invoke("registry", "install", "base")

        invoke("registry", "uninstall", "base").stdout.should contain("Removed base")
        File.exists?(sandbox.installed_file("base")).should be_false
      end
    end

    it "keeps installed configurations unless --purge is given" do
      with_registry do |sandbox|
        add_registry(sandbox)
        invoke("registry", "install", "base")

        invoke("registry", "remove", "demo").stdout.should contain("still at")
        File.exists?(sandbox.installed_file("base")).should be_true
        Dir.exists?(sandbox.source.mirror_path).should be_false
        invoke("registry", "list").stdout.should contain("No registries configured")
      end
    end

    it "deletes them with --purge" do
      with_registry do |sandbox|
        add_registry(sandbox)
        invoke("registry", "install", "base")

        invoke("registry", "remove", "demo", "--purge").success?.should be_true
        Dir.exists?(sandbox.source.install_path).should be_false
      end
    end
  end

  describe "init" do
    it "scaffolds a registry that its own commands can read" do
      RegistryHelpers.with_sandbox do |sandbox|
        directory = File.join(sandbox.root, "new-registry")
        Dir.mkdir_p(directory)

        result = invoke("registry", "init", directory, "--name", "my-profiles")
        result.success?.should be_true

        manifest_path = File.join(directory, Fluxion::Registry::Manifest::FILE_NAME)
        File.exists?(manifest_path).should be_true
        File.exists?(File.join(directory, "profiles", "workstation.yaml")).should be_true

        manifest, diagnostics = Fluxion::Registry::Manifest.parse(File.read(manifest_path))
        diagnostics.select(&.error?).should be_empty
        manifest.not_nil!.name.should eq("my-profiles")
      end
    end

    it "refuses to overwrite an existing manifest" do
      RegistryHelpers.with_sandbox do |sandbox|
        directory = File.join(sandbox.root, "new-registry")
        Dir.mkdir_p(directory)
        invoke("registry", "init", directory)

        result = invoke("registry", "init", directory)
        result.exit_code.should eq(Fluxion::CLI::ExitCode::InvalidInput)
        result.stderr.should contain("already exists")
      end
    end
  end

  it "lists its subcommands when invoked bare" do
    result = invoke("registry")
    result.success?.should be_true
    %w[add list remove sync ls show install uninstall edit status publish init].each do |verb|
      result.stdout.should contain(verb)
    end
  end
end
