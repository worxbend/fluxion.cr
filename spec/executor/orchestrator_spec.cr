require "../spec_helper"

private def packages(name : String, *names : String, continue_on_error : Bool = true)
  Fluxion::PackagesStep.new(name, Fluxion::PackageManager::Dnf, names.to_a,
    continue_on_error: continue_on_error)
end

private def phase(name : String, steps : Array(Fluxion::Step),
                  depends_on : Array(String) = [] of String,
                  continue_on_step_error : Bool = true,
                  restart : Fluxion::RestartPolicy = Fluxion::RestartPolicy::None.new)
  Fluxion::Phase.new(name, steps, depends_on, restart, continue_on_step_error)
end

private def profile(phases : Array(Fluxion::Phase))
  Fluxion::Profile.new("test", Fluxion::TargetOs.new(Fluxion::Distribution::Fedora), phases)
end

# Raises something outside the closed error set, standing in for a genuine bug
# escaping mid-run.
private class ExplodingRunner < Fluxion::Executor::FakeShellRunner
  def initialize(@trigger : String)
    super()
  end

  def run(command : Fluxion::Executor::Command, &sink : String ->) : Fluxion::ProcessResult
    raise "unexpected" if command.argv.join(' ').includes?(@trigger)
    super(command, &sink)
  end
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

# A step of a kind no executor is registered for, standing in for a profile
# built by a newer Fluxion than the one running it.
private class UnknownStep < Fluxion::Step
  def kind : String
    "invented"
  end

  def item_type : Fluxion::ItemType
    Fluxion::ItemType::Package
  end

  def items : Array(Fluxion::ItemRef)
    [Fluxion::ItemRef.new(@name, "package", @name)]
  end
end

describe Fluxion::Executor::Orchestrator do
  it "fails a step whose kind nothing can carry out" do
    summary, listener, _ = run(profile([phase("base", [UnknownStep.new("mystery")] of Fluxion::Step)]))

    summary.failed.should eq(1)
    summary.ok?.should be_false
    listener.results.first.as(Fluxion::StepResult::Failure)
      .error_message.should contain("no executor for step kind 'invented'")
  end

  it "stops the run when a source setup's kind has no executor" do
    # A source setup configures the repository the packages after it install
    # from, so an unusable one is not something to note and carry on past.
    subject = Fluxion::Profile.new("test", Fluxion::TargetOs.new(Fluxion::Distribution::Fedora),
      [phase("base", [packages("tools", "git")] of Fluxion::Step)],
      source_setups: [Fluxion::SourceSetup.new(UnknownStep.new("repo"), Fluxion::PackageManager::Dnf)])

    summary, _, runner = run(subject)

    summary.ok?.should be_false
    runner.argv.should be_empty
  end

  it "runs every item of every step" do
    summary, _, runner = run(profile([phase("base", [packages("tools", "git", "curl")] of Fluxion::Step)]))

    summary.succeeded.should eq(2)
    summary.ok?.should be_true
    runner.argv.should eq([
      ["sudo", "dnf", "install", "-y", "git"],
      ["sudo", "dnf", "install", "-y", "curl"],
    ])
  end

  it "runs phases in dependency order" do
    subject = profile([
      phase("desktop", [packages("apps", "gnome")] of Fluxion::Step, depends_on: ["base"]),
      phase("base", [packages("tools", "git")] of Fluxion::Step),
    ])
    _, listener, _ = run(subject)

    phases = listener.events.select(&.kind.phase_started?).map(&.step_name)
    phases.should eq(%w[base desktop])
  end

  it "keeps installing the other packages after one fails" do
    # The isolation is the whole point of a package step: one bad name should
    # not lose the rest of the list.
    runner = Fluxion::Executor::FakeShellRunner.new.on("install -y broken", 1)
    summary, _, _ = run(profile([phase("base", [packages("tools", "git", "broken", "curl")] of Fluxion::Step)]),
      runner)

    summary.succeeded.should eq(2)
    summary.failed.should eq(1)
    runner.ran?("install -y curl").should be_true
  end

  it "stops a step at the first failure when continueOnError is off" do
    runner = Fluxion::Executor::FakeShellRunner.new.on("install -y broken", 1)
    step = packages("tools", "broken", "curl", continue_on_error: false)
    _, _, _ = run(profile([phase("base", [step] of Fluxion::Step)]), runner)

    runner.ran?("install -y curl").should be_false
  end

  it "blocks a phase whose dependency failed, and says which" do
    runner = Fluxion::Executor::FakeShellRunner.new.on("install -y git", 1)
    subject = profile([
      phase("base", [packages("tools", "git", continue_on_error: false)] of Fluxion::Step,
        continue_on_step_error: false),
      phase("desktop", [packages("apps", "gnome")] of Fluxion::Step, depends_on: ["base"]),
    ])
    summary, listener, _ = run(subject, runner)

    summary.failed_phases.should eq(["base"])
    summary.blocked_phases.should eq(["desktop"])

    blocked = listener.events.find!(&.kind.phase_blocked?)
    blocked.step_name.should eq("desktop")
    blocked.item.should eq("base")
    runner.ran?("install -y gnome").should be_false
  end

  it "reports what a dry run would do without running anything" do
    options = Fluxion::Executor::RunOptions.new(dry_run: true)
    summary, listener, runner = run(profile([phase("base", [packages("tools", "git")] of Fluxion::Step)]),
      options: options)

    summary.dry_run.should eq(1)
    runner.commands.should be_empty

    preview = listener.results.compact_map(&.as?(Fluxion::StepResult::DryRun)).first
    preview.would_execute.should eq(["sudo", "dnf", "install", "-y", "git"])
  end

  it "halts at an interrupt and records where to resume" do
    subject = profile([
      phase("base", [
        packages("tools", "git"),
        Fluxion::InterruptStep.new("relogin", "Log out and back in."),
      ] of Fluxion::Step),
      phase("later", [packages("more", "curl")] of Fluxion::Step),
    ])
    summary, _, runner = run(subject)

    summary.paused.should eq(1)
    summary.next_phase.should eq("later")
    # The interrupt stops the run, so the later phase must not have started.
    runner.ran?("install -y curl").should be_false
  end

  it "halts after a phase that requires a logout" do
    subject = profile([
      phase("shell", [packages("tools", "zsh")] of Fluxion::Step,
        restart: Fluxion::RestartPolicy::PromptLogout.new("Log out, then re-run.")),
      phase("later", [packages("more", "curl")] of Fluxion::Step),
    ])
    _, listener, runner = run(subject)

    restart = listener.events.find!(&.kind.restart_required?)
    restart.item.should eq("Log out, then re-run.")
    runner.ran?("install -y curl").should be_false
  end

  it "refuses to run an unknown phase rather than doing nothing quietly" do
    options = Fluxion::Executor::RunOptions.new(only_phases: ["nope"])
    expect_raises(Fluxion::ExecutionError, /Unknown phase: nope/) do
      run(profile([phase("base", [packages("tools", "git")] of Fluxion::Step)]), options: options)
    end
  end

  it "runs only the selected phase" do
    subject = profile([
      phase("base", [packages("tools", "git")] of Fluxion::Step),
      phase("desktop", [packages("apps", "gnome")] of Fluxion::Step),
    ])
    options = Fluxion::Executor::RunOptions.new(only_phases: ["desktop"])
    _, _, runner = run(subject, options: options)

    runner.ran?("install -y gnome").should be_true
    runner.ran?("install -y git").should be_false
  end

  it "resumes from a named phase" do
    subject = profile([
      phase("base", [packages("tools", "git")] of Fluxion::Step),
      phase("desktop", [packages("apps", "gnome")] of Fluxion::Step),
    ])
    options = Fluxion::Executor::RunOptions.new(from_phase: "desktop")
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
    summary, _, runner = run(profile([phase("base", [guarded] of Fluxion::Step)]))

    summary.failed.should eq(1)
    runner.commands.should be_empty
  end

  it "runs a guarded item once approved" do
    guarded = Fluxion::ShellCommandStep.new("risky", [
      Fluxion::ShellCommandItem.new(name: "wipe", shell_command: "true", confirm: "confirm"),
    ])
    options = Fluxion::Executor::RunOptions.new(approved: true)
    summary, _, _ = run(profile([phase("base", [guarded] of Fluxion::Step)]), options: options)

    summary.succeeded.should eq(1)
  end

  describe "state" do
    it "records successful items and completed phases" do
      directory = File.tempname("fluxion-state")
      store = Fluxion::State::Store.new(directory)

      begin
        subject = profile([phase("base", [packages("tools", "git")] of Fluxion::Step)])
        run(subject, store: store)

        document = store.load("default")
        document.find("tools", "git", "package").should_not be_nil
        document.phases.map(&.phase).should eq(["base"])
        document.phases.first.completed?.should be_true
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
        subject = profile([phase("base", [packages("tools", "git")] of Fluxion::Step)])
        run(subject, options: Fluxion::Executor::RunOptions.new(dry_run: true), store: store)

        store.exists?("default").should be_false
      ensure
        FileUtils.rm_rf(directory)
      end
    end

    it "skips a completed phase whose configuration has not changed" do
      directory = File.tempname("fluxion-state")
      store = Fluxion::State::Store.new(directory)

      begin
        subject = profile([phase("base", [packages("tools", "git")] of Fluxion::Step)])
        run(subject, store: store)

        skipping = Fluxion::Executor::RunOptions.new(mode: Fluxion::Executor::RunMode::SkipInstalled)
        _, _, second = run(subject, options: skipping, store: store)

        second.commands.should be_empty
      ensure
        FileUtils.rm_rf(directory)
      end
    end

    it "runs a completed phase again once its configuration changes" do
      directory = File.tempname("fluxion-state")
      store = Fluxion::State::Store.new(directory)

      begin
        run(profile([phase("base", [packages("tools", "git")] of Fluxion::Step)]), store: store)

        # Adding a package changes the fingerprint, so the phase is no longer
        # considered done.
        changed = profile([phase("base", [packages("tools", "git", "curl")] of Fluxion::Step)])
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
          phase("base", [Fluxion::InterruptStep.new("relogin", "Log out.")] of Fluxion::Step),
          phase("later", [packages("more", "curl")] of Fluxion::Step),
        ])
        run(subject, store: store)

        store.load("default").next_phase.should eq("later")
      ensure
        FileUtils.rm_rf(directory)
      end
    end
  end
end

describe Fluxion::State::Fingerprint do
  it "is stable for the same phase" do
    subject = phase("base", [packages("tools", "git")] of Fluxion::Step)
    Fluxion::State::Fingerprint.of(subject).should eq(Fluxion::State::Fingerprint.of(subject))
  end

  it "changes when a pre-install action is edited" do
    # `actions` are verbs that run before the packages — `update`, `upgrade`.
    # They are not packages, so they appear in no item key, and the step has no
    # other input the fingerprint sees. Without them being hashed, swapping
    # `update` for `upgrade` left a completed phase looking untouched and the
    # new action never ran.
    with_actions = ->(action : String) do
      Fluxion::State::Fingerprint.of(phase("base", [
        Fluxion::PackagesStep.new("tools", Fluxion::PackageManager::Dnf, ["git"],
          [Fluxion::PackageAction.new(action)]),
      ] of Fluxion::Step))
    end

    with_actions.call("upgrade").should_not eq(with_actions.call("check-update"))
  end

  it "changes when a pre-install action's arguments are edited" do
    with_args = ->(args : Array(String)) do
      Fluxion::State::Fingerprint.of(phase("base", [
        Fluxion::PackagesStep.new("tools", Fluxion::PackageManager::Zypper, ["git"],
          [Fluxion::PackageAction.new("dup-from", args)]),
      ] of Fluxion::Step))
    end

    with_args.call(["repo-oss"]).should_not eq(with_args.call(["repo-other"]))
  end

  it "is unchanged for a packages step that declares no actions" do
    # The common case must not churn: a step with no actions has to fingerprint
    # exactly as it did before actions were hashed at all.
    subject = phase("base", [packages("tools", "git")] of Fluxion::Step)
    Fluxion::State::Fingerprint.of(subject).should eq(Fluxion::State::Fingerprint.of(subject))
    packages("tools", "git").content_digest.should be_nil
  end

  it "changes when a package is added" do
    before = Fluxion::State::Fingerprint.of(phase("base", [packages("tools", "git")] of Fluxion::Step))
    after = Fluxion::State::Fingerprint.of(phase("base", [packages("tools", "git", "curl")] of Fluxion::Step))
    before.should_not eq(after)
  end

  it "changes when a dependency is added" do
    before = Fluxion::State::Fingerprint.of(phase("a", [] of Fluxion::Step))
    after = Fluxion::State::Fingerprint.of(phase("a", [] of Fluxion::Step, depends_on: ["b"]))
    before.should_not eq(after)
  end

  it "does not collide when adjacent values are rearranged" do
    # Length-prefixing is what stops ["a", "bc"] and ["ab", "c"] hashing alike.
    left = Fluxion::State::Fingerprint.of(phase("a", [packages("s", "ab", "c")] of Fluxion::Step))
    right = Fluxion::State::Fingerprint.of(phase("a", [packages("s", "a", "bc")] of Fluxion::Step))
    left.should_not eq(right)
  end
end

describe "dry-run and interrupts" do
  it "describes an interrupt instead of obeying it" do
    # Stopping at a checkpoint during a preview would leave everything after
    # it undescribed, which is the opposite of what a dry run is for.
    subject = profile([
      phase("base", [
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
      phase("base", [
        Fluxion::InterruptStep.new("relogin", "Log out and back in."),
        packages("after", "curl"),
      ] of Fluxion::Step),
    ])
    summary, _, runner = run(subject)

    summary.paused.should eq(1)
    runner.ran?("install -y curl").should be_false
  end

  it "writes what it recorded even when an error escapes the run" do
    # `Recorder` buffers every success and writes once, so an escaping error
    # used to discard the whole run's state: fifty installed packages recorded
    # as none, and `--skip-already-installed` useless on the next run.
    directory = File.tempname("fluxion-flush")
    begin
      store = Fluxion::State::Store.new(directory)
      subject = profile([
        phase("base", [packages("tools", "git", "boom")] of Fluxion::Step),
      ])

      expect_raises(Exception, "unexpected") do
        run(subject, runner: ExplodingRunner.new("boom"), store: store)
      end

      # `git` succeeded before the explosion and must have survived it.
      document = store.load("default")
      document.find("tools", "git", Fluxion::ItemType::Package.json_name).should_not be_nil
    ensure
      FileUtils.rm_rf(directory)
    end
  end
end
