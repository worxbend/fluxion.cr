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
        digest.should eq(Digest::SHA256.hexdigest(File.read(path)))
      end
    end

    it "reports nil rather than raising when the config is missing" do
      # The fingerprint is bookkeeping; a missing config is the executor's
      # problem to report with a message naming the path.
      Fluxion::BinstallerProfileStep.new("portable", "/nope/absent.yaml")
        .content_digest.should be_nil
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
