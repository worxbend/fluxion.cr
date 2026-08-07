require "../spec_helper"

private def with_store(& : Fluxion::State::Store -> T) : T forall T
  directory = File.tempname("fluxion-store")
  begin
    yield Fluxion::State::Store.new(directory)
  ensure
    FileUtils.rm_rf(directory)
  end
end

describe Fluxion::State::Store do
  it "returns an empty document for a profile with no state" do
    with_store do |store|
      document = store.load("default")
      document.profile_name.should eq("default")
      document.items.should be_empty
      document.any_recorded?.should be_false
    end
  end

  it "round-trips items and phases" do
    with_store do |store|
      document = store.load("default")
      document.record(Fluxion::State::ItemRecord.new(
        profile: "default", step: "tools", item_key: "git", item_type: "package",
        completed_at: Time.utc, version: "2.45.2"))
      document.record(Fluxion::State::PhaseRecord.new("base", "completed", Time.utc, "abc"))
      store.save(document)

      reloaded = store.load("default")
      reloaded.find("tools", "git", "package").not_nil!.version.should eq("2.45.2")
      reloaded.phases.first.phase.should eq("base")
    end
  end

  it "replaces an item rather than duplicating it" do
    with_store do |store|
      document = store.load("default")
      2.times do |index|
        document.record(Fluxion::State::ItemRecord.new(
          profile: "default", step: "tools", item_key: "git", item_type: "package",
          completed_at: Time.utc, version: "1.#{index}"))
      end

      document.items.size.should eq(1)
      document.items.first.version.should eq("1.1")
    end
  end

  it "writes the state file privately" do
    # It records what is installed on the machine; a writable one could make
    # Fluxion skip work that was never done.
    with_store do |store|
      store.save(store.load("default"))
      permissions = File.info(store.path("default")).permissions
      permissions.other_read?.should be_false
      permissions.group_write?.should be_false
    end
  end

  it "leaves no temporary file behind" do
    with_store do |store|
      store.save(store.load("default"))
      Dir.children(store.root).should eq(["default.state.json"])
    end
  end

  it "refuses a profile name that is not a safe slug" do
    # Profile names become filenames, so a name needing escaping is a name that
    # will surprise someone.
    with_store do |store|
      expect_raises(Fluxion::ExecutionError, /safe slug/) { store.path("../escape") }
      expect_raises(Fluxion::ExecutionError, /safe slug/) { store.path("a/b") }
    end
  end

  it "refuses a state file from a newer Fluxion rather than misreading it" do
    with_store do |store|
      expect_raises(Fluxion::ExecutionError, /newer Fluxion/) do
        store.parse(%({"schemaVersion": 99}), "default")
      end
    end
  end

  describe "phase fingerprints" do
    it "treats a phase as complete only while its fingerprint matches" do
      with_store do |store|
        document = store.load("default")
        document.record(Fluxion::State::PhaseRecord.new("base", "completed", Time.utc, "abc"))

        document.phase_completed?("base", "abc").should be_true
        document.phase_completed?("base", "different").should be_false
      end
    end

    it "does not treat a failed phase as complete" do
      with_store do |store|
        document = store.load("default")
        document.record(Fluxion::State::PhaseRecord.new("base", "failed", Time.utc, "abc"))
        document.phase_completed?("base", "abc").should be_false
      end
    end

    it "does not trust a record with no fingerprint" do
      # Without one there is no way to tell whether the configuration changed,
      # and skipping on that basis could miss work the user has since added.
      with_store do |store|
        document = store.load("default")
        document.record(Fluxion::State::PhaseRecord.new("base", "completed", Time.utc, nil))
        document.phase_completed?("base", "abc").should be_false
      end
    end
  end

  describe "forgetting" do
    it "removes one item" do
      with_store do |store|
        document = store.load("default")
        document.record(Fluxion::State::ItemRecord.new(
          profile: "default", step: "tools", item_key: "git", item_type: "package",
          completed_at: Time.utc))

        document.forget_item("git").should eq(1)
        document.items.should be_empty
      end
    end

    it "narrows by step and type when a key appears twice" do
      with_store do |store|
        document = store.load("default")
        %w[tools extras].each do |step|
          document.record(Fluxion::State::ItemRecord.new(
            profile: "default", step: step, item_key: "git", item_type: "package",
            completed_at: Time.utc))
        end

        document.forget_item("git", "tools", "package").should eq(1)
        document.items.map(&.step).should eq(["extras"])
      end
    end

    it "removes a phase" do
      with_store do |store|
        document = store.load("default")
        document.record(Fluxion::State::PhaseRecord.new("base", "completed", Time.utc, "abc"))

        document.forget_phase("base").should be_true
        document.forget_phase("base").should be_false
      end
    end
  end

  describe "migration from the Java implementation" do
    legacy = <<-JSON
      {
        "schemaVersion" : 7,
        "profileName" : "default",
        "lastRunAt" : "2026-07-31T21:54:18.535561794Z",
        "sysbootVersion" : "1.0.3",
        "entries" : [ {
          "profileName" : "default",
          "moduleName" : "core-cli-tools",
          "itemKey" : "git",
          "itemType" : "PACKAGE",
          "completedAt" : "2026-07-31T21:50:00Z",
          "version" : "2.45.2",
          "checksum" : null,
          "sourceUrl" : null
        } ],
        "phaseEntries" : [ {
          "phaseName" : "base",
          "status" : "COMPLETED",
          "completedAt" : "2026-07-31T21:54:18.535548154Z",
          "fingerprint" : "41fb3f8c",
          "reason" : null
        } ],
        "planEntryEntries" : [ ],
        "nextPlanEntry" : "desktop",
        "manifestIdentity" : null,
        "manifestFingerprint" : null
      }
      JSON

    it "reads a file the Java version wrote" do
      # Someone upgrading should not have to reinstall everything they have.
      with_store do |store|
        document = store.parse(legacy, "default")
        document.profile_name.should eq("default")
        document.next_phase.should eq("desktop")
      end
    end

    it "carries item records across the rename from modules to steps" do
      with_store do |store|
        document = store.parse(legacy, "default")
        item = document.find("core-cli-tools", "git", "package").not_nil!
        item.version.should eq("2.45.2")
      end
    end

    it "lowercases the item type so it matches what this version records" do
      with_store do |store|
        store.parse(legacy, "default").items.first.item_type.should eq("package")
      end
    end

    it "carries phase records the Java version wrote" do
      with_store do |store|
        phase = store.parse(legacy, "default").phases.first
        phase.phase.should eq("base")
        phase.completed?.should be_true
        phase.fingerprint.should eq("41fb3f8c")
      end
    end

    it "keeps the version that did the work rather than claiming this one did" do
      with_store do |store|
        store.parse(legacy, "default").fluxion_version.should eq("1.0.3")
      end
    end

    it "survives a legacy file with fields missing" do
      with_store do |store|
        document = store.parse(%({"schemaVersion": 7, "profileName": "default"}), "default")
        document.items.should be_empty
        document.phases.should be_empty
      end
    end
  end
end
