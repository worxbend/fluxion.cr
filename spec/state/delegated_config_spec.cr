require "../spec_helper"

# A delegated step's item key is the path to another tool's config, so nothing
# the fingerprint or the item record looked at changed when the work behind
# that path changed. Once such a step succeeded it stayed "done" forever.
private def with_config(body : String, & : String -> T) : T forall T
  directory = File.tempname("fluxion-delegated")
  Dir.mkdir_p(directory)
  path = File.join(directory, "binstaller.yaml")
  File.write(path, body)
  begin
    yield path
  ensure
    FileUtils.rm_rf(directory)
  end
end

private def phase_for(path : String) : Fluxion::Phase
  Fluxion::Phase.new("tools",
    [Fluxion::BinstallerProfileStep.new("portable", path)] of Fluxion::Step)
end

describe "delegated config change detection" do
  describe Fluxion::Step do
    it "reports no digest for a step that describes its own work" do
      step = Fluxion::PackagesStep.new("tools", Fluxion::PackageManager::Dnf, ["git"])
      step.content_digest.should be_nil
    end

    it "digests the referenced file's bytes for the delegated kinds" do
      with_config("apiVersion: binstaller.io/v1alpha1\n") do |path|
        digest = Fluxion::BinstallerProfileStep.new("portable", path).content_digest
        File.write(path, "apiVersion: binstaller.io/v1alpha2\n")
        digest.should_not eq(Fluxion::BinstallerProfileStep.new("portable", path).content_digest)
      end
    end

    it "tells opposite profiles apart instead of collapsing them" do
      # `only: [docker]` installs docker and nothing else; `skip: [docker]`
      # installs everything except docker. A digest over an unlabelled, flat
      # list of tool names hashed both as ["docker"], so switching one for the
      # other left the completed phase looking unchanged and it never ran.
      with_config("versions:\n  docker: 27.0.0\n") do |path|
        only = Fluxion::BinstallerProfileStep.new("portable", path, only: ["docker"])
        skip = Fluxion::BinstallerProfileStep.new("portable", path, skip: ["docker"])
        only.content_digest.should_not eq(skip.content_digest)

        # Same names, different split between the two lists.
        both = Fluxion::BinstallerProfileStep.new("portable", path, only: ["git", "vim"])
        split = Fluxion::BinstallerProfileStep.new("portable", path, only: ["git"], skip: ["vim"])
        both.content_digest.should_not eq(split.content_digest)

        # A tool literally named "locked" is not the `locked:` flag, and is not
        # a lock file path either.
        named = Fluxion::BinstallerProfileStep.new("portable", path, only: ["locked"])
        flag = Fluxion::BinstallerProfileStep.new("portable", path, locked: true)
        file = Fluxion::BinstallerProfileStep.new("portable", path, lock_file: "locked")
        [named, flag, file].map(&.content_digest).uniq.size.should eq(3)
      end
    end

    it "keeps the config's bytes from spilling into the step's knobs" do
      # Unframed concatenation let a config ending in the separator plus a
      # value impersonate that value being passed as a knob.
      with_config("only=docker") do |path|
        Fluxion::BinstallerProfileStep.new("portable", path).content_digest
          .should_not eq(Fluxion::BinstallerProfileStep.new("portable", "/nope/absent.yaml",
            only: ["docker"]).content_digest)
      end
    end

    it "digests a missing config as absent rather than reporting no digest" do
      # Nil would make `Recorder#recorded` skip the comparison and report the
      # step still installed, which is the opposite of what a vanished config
      # means. It must also differ from any real content.
      absent = Fluxion::BinstallerProfileStep.new("portable", "/nope/absent.yaml").content_digest
      absent.should_not be_nil

      with_config("apiVersion: binstaller.io/v1alpha1\n") do |path|
        absent.should_not eq(Fluxion::BinstallerProfileStep.new("portable", path).content_digest)
      end
    end

    it "changes when only, skip, locked or lockFile change" do
      # These live on the step, not in the item key (the config path) and not
      # in the file, so a digest over the file alone left them invisible.
      with_config("versions:\n  lazygit: 0.61.0\n") do |path|
        plain = Fluxion::BinstallerProfileStep.new("portable", path).content_digest

        Fluxion::BinstallerProfileStep.new("portable", path, only: ["yazi"])
          .content_digest.should_not eq(plain)
        Fluxion::BinstallerProfileStep.new("portable", path, skip: ["zig"])
          .content_digest.should_not eq(plain)
        Fluxion::BinstallerProfileStep.new("portable", path, locked: true, lock_file: "/tmp/l.json")
          .content_digest.should_not eq(plain)
      end
    end

    it "covers dotbot too, which delegates the same way" do
      with_config("- link: {}\n") do |path|
        Fluxion::DotbotStep.new("dots", path).content_digest.should_not be_nil
      end
    end
  end

  describe Fluxion::State::Fingerprint do
    it "changes when the referenced config changes" do
      # The whole point: identical profile YAML, different config behind it.
      with_config("versions:\n  lazygit: 0.61.0\n") do |path|
        before = Fluxion::State::Fingerprint.of(phase_for(path))
        File.write(path, "versions:\n  lazygit: 0.62.0\n")
        after = Fluxion::State::Fingerprint.of(phase_for(path))

        after.should_not eq(before)
      end
    end

    it "is stable when nothing changed" do
      with_config("versions:\n  lazygit: 0.61.0\n") do |path|
        Fluxion::State::Fingerprint.of(phase_for(path))
          .should eq(Fluxion::State::Fingerprint.of(phase_for(path)))
      end
    end
  end
end

describe "Recorder#recorded" do
  it "stops counting a delegated step as installed once its config changes" do
    # This is the branch the whole change exists for, and it had no spec.
    directory = File.tempname("fluxion-recorded")
    begin
      store = Fluxion::State::Store.new(directory)
      config = File.tempname("fluxion-recorded-config")
      File.write(config, "versions:\n  lazygit: 0.61.0\n")

      profile = Fluxion::Profile.new("test",
        Fluxion::TargetOs.new(Fluxion::Distribution::Fedora), [phase_for(config)])
      options = Fluxion::Executor::RunOptions.new(
        mode: Fluxion::Executor::RunMode::SkipInstalled)
      runner = Fluxion::Executor::FakeShellRunner.new.available("binstaller")

      orchestrator = Fluxion::Executor::Orchestrator.new(runner, state: store)
      orchestrator.run(profile, options, Fluxion::NullExecutionListener.new)
      first = runner.commands.size
      first.should be > 0

      # Same profile, edited config: the step must run again.
      File.write(config, "versions:\n  lazygit: 0.62.0\n")
      runner2 = Fluxion::Executor::FakeShellRunner.new.available("binstaller")
      Fluxion::Executor::Orchestrator.new(runner2, state: store)
        .run(profile, options, Fluxion::NullExecutionListener.new)

      runner2.commands.size.should be > 0
    ensure
      FileUtils.rm_rf(directory)
    end
  end
end
