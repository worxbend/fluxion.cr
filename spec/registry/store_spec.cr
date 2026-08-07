require "../spec_helper"

private alias Drift = Fluxion::Registry::Store::Drift

describe Fluxion::Registry::Store do
  it "reads the manifest out of the mirror" do
    RegistryHelpers.with_sandbox do |sandbox|
      manifest, diagnostics = sandbox.store.manifest

      diagnostics.select(&.error?).should be_empty
      manifest.not_nil!.ids.should eq(["base", "workstation"])
    end
  end

  it "says which registry is missing a manifest rather than failing obscurely" do
    RegistryHelpers.with_sandbox do |sandbox|
      File.delete(sandbox.mirror_file(Fluxion::Registry::Manifest::FILE_NAME))

      manifest, diagnostics = sandbox.store.manifest
      manifest.should be_nil
      diagnostics.map(&.to_s).any?(&.includes?("has no fluxion-registry.yaml")).should be_true
    end
  end

  describe "#install" do
    it "writes the profile under the install directory" do
      RegistryHelpers.with_sandbox do |sandbox|
        store = sandbox.store
        entry = store.manifest!.entry?("base").not_nil!

        path = store.install(entry)

        path.should eq(sandbox.installed_file("base"))
        File.read(path).should eq(File.read(sandbox.mirror_file("profiles/base.yaml")))
        store.installed?(entry).should be_true
        store.installed_ids.should eq(["base"])
      end
    end

    it "does not touch the mirror" do
      RegistryHelpers.with_sandbox do |sandbox|
        store = sandbox.store
        entry = store.manifest!.entry?("base").not_nil!
        before = File.read(sandbox.mirror_file("profiles/base.yaml"))

        store.install(entry)

        File.read(sandbox.mirror_file("profiles/base.yaml")).should eq(before)
      end
    end

    # A registry describes what to install on a machine, so a profile that
    # cannot be parsed is refused before it lands rather than at the first run.
    it "refuses a profile that does not validate" do
      RegistryHelpers.with_sandbox do |sandbox|
        sandbox.publish_upstream("profiles/base.yaml", RegistryHelpers.invalid_profile)
        store = sandbox.store
        entry = store.manifest!.entry?("base").not_nil!

        expect_raises(Fluxion::ExecutionError, /not a valid profile/) { store.install(entry) }
        store.installed?(entry).should be_false
      end
    end

    it "refuses to overwrite local edits without force" do
      RegistryHelpers.with_sandbox do |sandbox|
        store = sandbox.store
        entry = store.manifest!.entry?("base").not_nil!
        path = store.install(entry)
        File.write(path, File.read(path) + "\n# mine\n")

        expect_raises(Fluxion::ExecutionError, /local edits/) { store.install(entry) }
        File.read(path).should contain("# mine")

        store.install(entry, force: true)
        File.read(path).should_not contain("# mine")
      end
    end

    it "takes an upstream change without needing force" do
      RegistryHelpers.with_sandbox do |sandbox|
        store = sandbox.store
        entry = store.manifest!.entry?("base").not_nil!
        store.install(entry)

        sandbox.publish_upstream("profiles/base.yaml", RegistryHelpers.profile("base", "ripgrep"))
        store.install(entry)

        File.read(sandbox.installed_file("base")).should contain("ripgrep")
        store.drift(entry).should eq(Drift::Current)
      end
    end

    it "is a no-op when nothing has changed" do
      RegistryHelpers.with_sandbox do |sandbox|
        store = sandbox.store
        entry = store.manifest!.entry?("base").not_nil!
        path = store.install(entry)
        stamp = File.info(path).modification_time

        store.install(entry).should eq(path)
        File.info(path).modification_time.should eq(stamp)
      end
    end
  end

  describe "#drift" do
    it "distinguishes a local edit from an upstream change" do
      RegistryHelpers.with_sandbox do |sandbox|
        store = sandbox.store
        entry = store.manifest!.entry?("base").not_nil!

        store.drift(entry).should eq(Drift::Absent)

        store.install(entry)
        store.drift(entry).should eq(Drift::Current)

        File.write(sandbox.installed_file("base"), File.read(sandbox.installed_file("base")) + "# mine\n")
        store.drift(entry).should eq(Drift::Local)

        sandbox.publish_upstream("profiles/base.yaml", RegistryHelpers.profile("base", "ripgrep"))
        store.drift(entry).should eq(Drift::Both)
      end
    end

    it "reports an upstream change on an untouched install" do
      RegistryHelpers.with_sandbox do |sandbox|
        store = sandbox.store
        entry = store.manifest!.entry?("base").not_nil!
        store.install(entry)

        sandbox.publish_upstream("profiles/base.yaml", RegistryHelpers.profile("base", "ripgrep"))
        store.drift(entry).should eq(Drift::Upstream)
      end
    end
  end

  describe "#source_path" do
    it "refuses a symlink pointing outside the registry" do
      RegistryHelpers.with_sandbox do |sandbox|
        secret = File.join(sandbox.root, "secret.yaml")
        File.write(secret, RegistryHelpers.profile("secret"))

        link = sandbox.mirror_file("profiles/base.yaml")
        File.delete(link)
        File.symlink(secret, link)

        store = sandbox.store
        entry = store.manifest!.entry?("base").not_nil!

        expect_raises(Fluxion::TrustError, /outside the registry/) { store.source_path(entry) }
      end
    end

    it "refuses something that is not a regular file" do
      RegistryHelpers.with_sandbox do |sandbox|
        path = sandbox.mirror_file("profiles/base.yaml")
        File.delete(path)
        Dir.mkdir_p(path)

        store = sandbox.store
        entry = store.manifest!.entry?("base").not_nil!

        expect_raises(Fluxion::TrustError, /not a regular file/) { store.source_path(entry) }
      end
    end

    it "says which entry the registry does not actually ship" do
      RegistryHelpers.with_sandbox do |sandbox|
        File.delete(sandbox.mirror_file("profiles/base.yaml"))
        store = sandbox.store
        entry = store.manifest!.entry?("base").not_nil!

        expect_raises(Fluxion::ExecutionError, /not in the registry/) { store.source_path(entry) }
      end
    end
  end

  describe "#stage" do
    it "copies an installed configuration back into the mirror" do
      RegistryHelpers.with_sandbox do |sandbox|
        store = sandbox.store
        entry = store.manifest!.entry?("base").not_nil!
        store.install(entry)

        edited = RegistryHelpers.profile("base", "ripgrep")
        File.write(sandbox.installed_file("base"), edited)
        store.stage(entry)

        File.read(sandbox.mirror_file("profiles/base.yaml")).should eq(edited)
      end
    end

    it "refuses to stage something that is not installed" do
      RegistryHelpers.with_sandbox do |sandbox|
        store = sandbox.store
        entry = store.manifest!.entry?("base").not_nil!

        expect_raises(Fluxion::ExecutionError, /not installed/) { store.stage(entry) }
      end
    end

    it "refuses to stage a profile that no longer validates" do
      RegistryHelpers.with_sandbox do |sandbox|
        store = sandbox.store
        entry = store.manifest!.entry?("base").not_nil!
        store.install(entry)
        File.write(sandbox.installed_file("base"), RegistryHelpers.invalid_profile)

        expect_raises(Fluxion::ExecutionError, /not a valid profile/) { store.stage(entry) }
      end
    end
  end

  describe "#uninstall" do
    it "removes the file and forgets the recorded digest" do
      RegistryHelpers.with_sandbox do |sandbox|
        store = sandbox.store
        entry = store.manifest!.entry?("base").not_nil!
        store.install(entry)

        store.uninstall(entry).should be_true
        File.exists?(sandbox.installed_file("base")).should be_false
        store.installed_ids.should be_empty
        store.drift(entry).should eq(Drift::Absent)
      end
    end

    it "reports when there was nothing to remove" do
      RegistryHelpers.with_sandbox do |sandbox|
        store = sandbox.store
        entry = store.manifest!.entry?("base").not_nil!

        store.uninstall(entry).should be_false
      end
    end
  end

  it "keeps its bookkeeping out of the installed listing" do
    RegistryHelpers.with_sandbox do |sandbox|
      store = sandbox.store
      store.install(store.manifest!.entry?("base").not_nil!)

      store.installed_ids.should eq(["base"])
      Dir.children(sandbox.source.install_path).should contain(".fluxion")
    end
  end
end
