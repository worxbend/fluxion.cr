require "../spec_helper"

private def packages(name : String, *names : String, continue_on_error : Bool = true)
  Fluxion::PackagesStep.new(name, Fluxion::PackageManager::Dnf, names.to_a,
    continue_on_error: continue_on_error)
end

private def job(name : String, steps : Array(Fluxion::Step),
                depends_on : Array(String) = [] of String,
                continue_on_step_error : Bool = true,
                restart : Fluxion::RestartPolicy = Fluxion::RestartPolicy::None.new)
  Fluxion::Job.new(name, steps, depends_on, restart, continue_on_step_error)
end

private def profile(jobs : Array(Fluxion::Job))
  Fluxion::Profile.new("test", Fluxion::TargetOs.new(Fluxion::Distribution::Fedora), jobs)
end

private def run(subject : Fluxion::Profile,
                runner : Fluxion::Executor::FakeShellRunner = Fluxion::Executor::FakeShellRunner.new,
                options : Fluxion::Executor::RunOptions = Fluxion::Executor::RunOptions.new,
                store : Fluxion::State::Store? = nil)
  listener = Fluxion::RecordingExecutionListener.new
  orchestrator = Fluxion::Executor::Orchestrator.new(runner, state: store)
  summary = orchestrator.run(subject, options, listener)
  {summary, listener, runner}
end

describe Fluxion::Executor::Orchestrator do
  it "runs every item of every step" do
    summary, _, runner = run(profile([job("base", [packages("tools", "git", "curl")] of Fluxion::Step)]))

    summary.succeeded.should eq(2)
    summary.ok?.should be_true
    runner.argv.should eq([
      ["sudo", "dnf", "install", "-y", "git"],
      ["sudo", "dnf", "install", "-y", "curl"],
    ])
  end

  it "runs jobs in dependency order" do
    subject = profile([
      job("desktop", [packages("apps", "gnome")] of Fluxion::Step, depends_on: ["base"]),
      job("base", [packages("tools", "git")] of Fluxion::Step),
    ])
    _, listener, _ = run(subject)

    jobs = listener.events.select(&.kind.phase_started?).map(&.step_name)
    jobs.should eq(%w[base desktop])
  end

  it "keeps installing the other packages after one fails" do
    # The isolation is the whole point of a package step: one bad name should
    # not lose the rest of the list.
    runner = Fluxion::Executor::FakeShellRunner.new.on("install -y broken", 1)
    summary, _, _ = run(profile([job("base", [packages("tools", "git", "broken", "curl")] of Fluxion::Step)]),
      runner)

    summary.succeeded.should eq(2)
    summary.failed.should eq(1)
    runner.ran?("install -y curl").should be_true
  end

  it "stops a step at the first failure when continueOnError is off" do
    runner = Fluxion::Executor::FakeShellRunner.new.on("install -y broken", 1)
    step = packages("tools", "broken", "curl", continue_on_error: false)
    _, _, _ = run(profile([job("base", [step] of Fluxion::Step)]), runner)

    runner.ran?("install -y curl").should be_false
  end

  it "blocks a job whose dependency failed, and says which" do
    runner = Fluxion::Executor::FakeShellRunner.new.on("install -y git", 1)
    subject = profile([
      job("base", [packages("tools", "git", continue_on_error: false)] of Fluxion::Step,
        continue_on_step_error: false),
      job("desktop", [packages("apps", "gnome")] of Fluxion::Step, depends_on: ["base"]),
    ])
    summary, listener, _ = run(subject, runner)

    summary.failed_jobs.should eq(["base"])
    summary.blocked_jobs.should eq(["desktop"])

    blocked = listener.events.find!(&.kind.phase_blocked?)
    blocked.step_name.should eq("desktop")
    blocked.item.should eq("base")
    runner.ran?("install -y gnome").should be_false
  end

  it "reports what a dry run would do without running anything" do
    options = Fluxion::Executor::RunOptions.new(dry_run: true)
    summary, listener, runner = run(profile([job("base", [packages("tools", "git")] of Fluxion::Step)]),
      options: options)

    summary.dry_run.should eq(1)
    runner.commands.should be_empty

    preview = listener.results.compact_map(&.as?(Fluxion::StepResult::DryRun)).first
    preview.would_execute.should eq(["sudo", "dnf", "install", "-y", "git"])
  end

  it "halts at an interrupt and records where to resume" do
    subject = profile([
      job("base", [
        packages("tools", "git"),
        Fluxion::InterruptStep.new("relogin", "Log out and back in."),
      ] of Fluxion::Step),
      job("later", [packages("more", "curl")] of Fluxion::Step),
    ])
    summary, _, runner = run(subject)

    summary.paused.should eq(1)
    summary.next_job.should eq("later")
    # The interrupt stops the run, so the later job must not have started.
    runner.ran?("install -y curl").should be_false
  end

  it "halts after a job that requires a logout" do
    subject = profile([
      job("shell", [packages("tools", "zsh")] of Fluxion::Step,
        restart: Fluxion::RestartPolicy::PromptLogout.new("Log out, then re-run.")),
      job("later", [packages("more", "curl")] of Fluxion::Step),
    ])
    _, listener, runner = run(subject)

    restart = listener.events.find!(&.kind.restart_required?)
    restart.item.should eq("Log out, then re-run.")
    runner.ran?("install -y curl").should be_false
  end

  it "refuses to run an unknown job rather than doing nothing quietly" do
    options = Fluxion::Executor::RunOptions.new(only_jobs: ["nope"])
    expect_raises(Fluxion::ExecutionError, /Unknown job: nope/) do
      run(profile([job("base", [packages("tools", "git")] of Fluxion::Step)]), options: options)
    end
  end

  it "runs only the selected job" do
    subject = profile([
      job("base", [packages("tools", "git")] of Fluxion::Step),
      job("desktop", [packages("apps", "gnome")] of Fluxion::Step),
    ])
    options = Fluxion::Executor::RunOptions.new(only_jobs: ["desktop"])
    _, _, runner = run(subject, options: options)

    runner.ran?("install -y gnome").should be_true
    runner.ran?("install -y git").should be_false
  end

  it "resumes from a named job" do
    subject = profile([
      job("base", [packages("tools", "git")] of Fluxion::Step),
      job("desktop", [packages("apps", "gnome")] of Fluxion::Step),
    ])
    options = Fluxion::Executor::RunOptions.new(from_job: "desktop")
    _, _, runner = run(subject, options: options)

    runner.ran?("install -y git").should be_false
    runner.ran?("install -y gnome").should be_true
  end

  it "requires approval for a guarded item, without prompting" do
    # A run that waits for input is a run that hangs unattended, so a guarded
    # item fails rather than asking.
    guarded = Fluxion::ShellCommandStep.new("risky", [
      Fluxion::ShellCommandItem.new(name: "wipe", shell_command: "rm -rf /tmp/x", confirm: "confirm"),
    ])
    summary, _, runner = run(profile([job("base", [guarded] of Fluxion::Step)]))

    summary.failed.should eq(1)
    runner.commands.should be_empty
  end

  it "runs a guarded item once approved" do
    guarded = Fluxion::ShellCommandStep.new("risky", [
      Fluxion::ShellCommandItem.new(name: "wipe", shell_command: "true", confirm: "confirm"),
    ])
    options = Fluxion::Executor::RunOptions.new(approved: true)
    summary, _, _ = run(profile([job("base", [guarded] of Fluxion::Step)]), options: options)

    summary.succeeded.should eq(1)
  end

  describe "state" do
    it "records successful items and completed jobs" do
      directory = File.tempname("fluxion-state")
      store = Fluxion::State::Store.new(directory)

      begin
        subject = profile([job("base", [packages("tools", "git")] of Fluxion::Step)])
        run(subject, store: store)

        document = store.load("default")
        document.find("tools", "git", "package").should_not be_nil
        document.jobs.map(&.job).should eq(["base"])
        document.jobs.first.completed?.should be_true
      ensure
        FileUtils.rm_rf(directory)
      end
    end

    it "records nothing for a dry run" do
      # A dry run that claimed work was done would make the next real run skip
      # it, which is the opposite of what a preview is for.
      directory = File.tempname("fluxion-state")
      store = Fluxion::State::Store.new(directory)

      begin
        subject = profile([job("base", [packages("tools", "git")] of Fluxion::Step)])
        run(subject, options: Fluxion::Executor::RunOptions.new(dry_run: true), store: store)

        store.exists?("default").should be_false
      ensure
        FileUtils.rm_rf(directory)
      end
    end

    it "skips a completed job whose configuration has not changed" do
      directory = File.tempname("fluxion-state")
      store = Fluxion::State::Store.new(directory)

      begin
        subject = profile([job("base", [packages("tools", "git")] of Fluxion::Step)])
        run(subject, store: store)

        skipping = Fluxion::Executor::RunOptions.new(mode: Fluxion::Executor::RunMode::SkipInstalled)
        _, _, second = run(subject, options: skipping, store: store)

        second.commands.should be_empty
      ensure
        FileUtils.rm_rf(directory)
      end
    end

    it "runs a completed job again once its configuration changes" do
      directory = File.tempname("fluxion-state")
      store = Fluxion::State::Store.new(directory)

      begin
        run(profile([job("base", [packages("tools", "git")] of Fluxion::Step)]), store: store)

        # Adding a package changes the fingerprint, so the job is no longer
        # considered done.
        changed = profile([job("base", [packages("tools", "git", "curl")] of Fluxion::Step)])
        skipping = Fluxion::Executor::RunOptions.new(mode: Fluxion::Executor::RunMode::SkipInstalled)
        _, _, second = run(changed, options: skipping, store: store)

        second.ran?("install -y curl").should be_true
      ensure
        FileUtils.rm_rf(directory)
      end
    end

    it "records where to resume after an interrupt" do
      directory = File.tempname("fluxion-state")
      store = Fluxion::State::Store.new(directory)

      begin
        subject = profile([
          job("base", [Fluxion::InterruptStep.new("relogin", "Log out.")] of Fluxion::Step),
          job("later", [packages("more", "curl")] of Fluxion::Step),
        ])
        run(subject, store: store)

        store.load("default").next_job.should eq("later")
      ensure
        FileUtils.rm_rf(directory)
      end
    end
  end
end

describe Fluxion::State::Fingerprint do
  it "is stable for the same job" do
    subject = job("base", [packages("tools", "git")] of Fluxion::Step)
    Fluxion::State::Fingerprint.of(subject).should eq(Fluxion::State::Fingerprint.of(subject))
  end

  it "changes when a package is added" do
    before = Fluxion::State::Fingerprint.of(job("base", [packages("tools", "git")] of Fluxion::Step))
    after = Fluxion::State::Fingerprint.of(job("base", [packages("tools", "git", "curl")] of Fluxion::Step))
    before.should_not eq(after)
  end

  it "changes when a dependency is added" do
    before = Fluxion::State::Fingerprint.of(job("a", [] of Fluxion::Step))
    after = Fluxion::State::Fingerprint.of(job("a", [] of Fluxion::Step, depends_on: ["b"]))
    before.should_not eq(after)
  end

  it "does not collide when adjacent values are rearranged" do
    # Length-prefixing is what stops ["a", "bc"] and ["ab", "c"] hashing alike.
    left = Fluxion::State::Fingerprint.of(job("a", [packages("s", "ab", "c")] of Fluxion::Step))
    right = Fluxion::State::Fingerprint.of(job("a", [packages("s", "a", "bc")] of Fluxion::Step))
    left.should_not eq(right)
  end
end

describe "dry-run and interrupts" do
  it "describes an interrupt instead of obeying it" do
    # Stopping at a checkpoint during a preview would leave everything after
    # it undescribed, which is the opposite of what a dry run is for.
    subject = profile([
      job("base", [
        Fluxion::InterruptStep.new("relogin", "Log out and back in."),
        packages("after", "curl"),
      ] of Fluxion::Step),
    ])

    options = Fluxion::Executor::RunOptions.new(dry_run: true)
    summary, listener, _ = run(subject, options: options)

    summary.paused.should eq(0)
    summary.dry_run.should eq(2)

    previews = listener.results.compact_map(&.as?(Fluxion::StepResult::DryRun))
    previews.map(&.item).should eq(%w[relogin curl])
  end

  it "still halts at an interrupt during a real run" do
    subject = profile([
      job("base", [
        Fluxion::InterruptStep.new("relogin", "Log out and back in."),
        packages("after", "curl"),
      ] of Fluxion::Step),
    ])
    summary, _, runner = run(subject)

    summary.paused.should eq(1)
    runner.ran?("install -y curl").should be_false
  end
end
