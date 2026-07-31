require "../spec_helper"

private def packages_step(name : String, *packages : String)
  Fluxion::PackagesStep.new(name, Fluxion::PackageManager::Dnf, packages.to_a)
end

private def job(name : String, depends_on : Array(String) = [] of String)
  Fluxion::Job.new(name, [packages_step("#{name}-tools", "git")] of Fluxion::Step, depends_on)
end

private def profile(jobs : Array(Fluxion::Job))
  Fluxion::Profile.new(
    "test",
    Fluxion::TargetOs.new(Fluxion::Distribution::Fedora, "44"),
    jobs,
  )
end

describe Fluxion::Profile do
  describe "#ordered_jobs" do
    it "puts dependencies before dependents" do
      subject = profile([
        job("desktop", ["base"]),
        job("base"),
        job("dev", ["base"]),
      ])
      subject.ordered_jobs.map(&.name).first.should eq("base")
    end

    it "breaks ties on declaration order so plans are reproducible" do
      subject = profile([job("b"), job("a"), job("c")])
      subject.ordered_jobs.map(&.name).should eq(%w[b a c])
    end

    it "reports a cycle with the jobs involved" do
      subject = profile([job("a", ["b"]), job("b", ["a"])])
      expect_raises(Fluxion::ConfigError, /Circular dependency detected among jobs: a, b/) do
        subject.ordered_jobs
      end
    end

    it "treats an unknown dependency as unsatisfiable" do
      # Validation reports the missing name with its config path; ordering only
      # needs to refuse to invent an order for it.
      subject = profile([job("a", ["nope"])])
      expect_raises(Fluxion::ConfigError, /Circular dependency/) { subject.ordered_jobs }
    end
  end

  it "recognises a manifest profile by its single reserved job" do
    manifest = profile([job(Fluxion::Profile::MANIFEST_JOB_NAME)])
    manifest.manifest?.should be_true
    profile([job("base")]).manifest?.should be_false
  end

  it "flattens items across every job" do
    subject = profile([
      Fluxion::Job.new("a", [packages_step("a-tools", "git", "curl")] of Fluxion::Step),
      Fluxion::Job.new("b", [packages_step("b-tools", "jq")] of Fluxion::Step),
    ])
    subject.items.map(&.key).should eq(%w[git curl jq])
  end
end

describe Fluxion::Job do
  it "continues past a failed step by default" do
    job("base").continue_on_step_error?.should be_true
  end

  it "halts when its restart policy stops the run" do
    halting = Fluxion::Job.new(
      "shell",
      [packages_step("tools", "zsh")] of Fluxion::Step,
      restart_policy: Fluxion::RestartPolicy::PromptLogout.new,
    )
    halting.halts?.should be_true
    job("base").halts?.should be_false
  end

  it "halts when it contains an interrupt step" do
    interrupting = Fluxion::Job.new(
      "relogin",
      [Fluxion::InterruptStep.new("relogin", "Log out and back in.")] of Fluxion::Step,
    )
    interrupting.halts?.should be_true
  end
end
