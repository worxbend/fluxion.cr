require "../spec_helper"

private def packages_step(name : String, *packages : String)
  Fluxion::PackagesStep.new(name, Fluxion::PackageManager::Dnf, packages.to_a)
end

private def phase(name : String, depends_on : Array(String) = [] of String)
  Fluxion::Phase.new(name, [packages_step("#{name}-tools", "git")] of Fluxion::Step, depends_on)
end

private def profile(phases : Array(Fluxion::Phase))
  Fluxion::Profile.new(
    "test",
    Fluxion::TargetOs.new(Fluxion::Distribution::Fedora, "44"),
    phases,
  )
end

describe Fluxion::Profile do
  describe "#ordered_phases" do
    it "puts dependencies before dependents" do
      subject = profile([
        phase("desktop", ["base"]),
        phase("base"),
        phase("dev", ["base"]),
      ])
      subject.ordered_phases.map(&.name).first.should eq("base")
    end

    it "breaks ties on declaration order so plans are reproducible" do
      subject = profile([phase("b"), phase("a"), phase("c")])
      subject.ordered_phases.map(&.name).should eq(%w[b a c])
    end

    it "keeps a phase nothing depends on, in its declared position" do
      subject = profile([phase("desktop", ["base"]), phase("base"), phase("loose")])
      subject.ordered_phases.map(&.name).should eq(%w[base loose desktop])
    end

    it "reports a cycle with the phases involved" do
      subject = profile([phase("a", ["b"]), phase("b", ["a"])])
      expect_raises(Fluxion::ConfigError, /Circular dependency detected among phases: a, b/) do
        subject.ordered_phases
      end
    end

    it "treats an unknown dependency as unsatisfiable" do
      # Validation reports the missing name with its config path; ordering only
      # needs to refuse to invent an order for it.
      subject = profile([phase("a", ["nope"])])
      expect_raises(Fluxion::ConfigError, /Circular dependency/) { subject.ordered_phases }
    end
  end

  it "looks a phase up by name" do
    subject = profile([phase("base"), phase("desktop")])
    subject.phase?("desktop").not_nil!.name.should eq("desktop")
    subject.phase?("nope").should be_nil
  end

  it "flattens items across every phase" do
    subject = profile([
      Fluxion::Phase.new("a", [packages_step("a-tools", "git", "curl")] of Fluxion::Step),
      Fluxion::Phase.new("b", [packages_step("b-tools", "jq")] of Fluxion::Step),
    ])
    subject.items.map(&.key).should eq(%w[git curl jq])
  end
end

describe Fluxion::Phase do
  it "continues past a failed step by default" do
    phase("base").continue_on_step_error?.should be_true
  end

  it "halts when its restart policy stops the run" do
    halting = Fluxion::Phase.new(
      "shell",
      [packages_step("tools", "zsh")] of Fluxion::Step,
      restart_policy: Fluxion::RestartPolicy::PromptLogout.new,
    )
    halting.halts?.should be_true
    phase("base").halts?.should be_false
  end

  it "halts when it contains an interrupt step" do
    interrupting = Fluxion::Phase.new(
      "relogin",
      [Fluxion::InterruptStep.new("relogin", "Log out and back in.")] of Fluxion::Step,
    )
    interrupting.halts?.should be_true
  end
end
