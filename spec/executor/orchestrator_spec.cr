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

# The fingerprint of a phase holding one step, which is how the "editing this
# field has to be visible" cases below are stated.
private def fingerprint_of(step : Fluxion::Step) : String
  Fluxion::State::Fingerprint.of(phase("base", [step] of Fluxion::Step))
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

# Trips the cancellation signal as soon as a matching command has run, standing
# in for Ctrl-C arriving while a step is part-way through its items.
private class CancellingRunner < Fluxion::Executor::FakeShellRunner
  def initialize(@trigger : String, @cancellation : Fluxion::CancellationSignal)
    super()
  end

  def run(command : Fluxion::Executor::Command, &sink : String ->) : Fluxion::ProcessResult
    result = super(command, &sink)
    @cancellation.cancel if command.argv.join(' ').includes?(@trigger)
    result
  end
end

private def run(subject : Fluxion::Profile,
                runner : Fluxion::Executor::FakeShellRunner = Fluxion::Executor::FakeShellRunner.new,
                options : Fluxion::Executor::RunOptions = Fluxion::Executor::RunOptions.new,
                store : Fluxion::State::Store? = nil,
                cancellation : Fluxion::CancellationSignal = Fluxion::CancellationSignal.new)
  listener = Fluxion::RecordingExecutionListener.new
  orchestrator = Fluxion::Executor::Orchestrator.new(runner, state: store)
  summary = orchestrator.run(subject, options, listener, cancellation)
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
    # One transaction for the list; see "package batching" below.
    runner.argv.should eq([["sudo", "dnf", "install", "-y", "git", "curl"]])
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
    # not lose the rest of the list. The name fails the batch as well as its
    # own install, as it would for a real package manager.
    runner = Fluxion::Executor::FakeShellRunner.new.on("broken", 1)
    summary, _, _ = run(profile([phase("base", [packages("tools", "git", "broken", "curl")] of Fluxion::Step)]),
      runner)

    summary.succeeded.should eq(2)
    summary.failed.should eq(1)
    runner.ran?("install -y curl").should be_true
  end

  it "stops a step at the first failure when continueOnError is off" do
    runner = Fluxion::Executor::FakeShellRunner.new.on("broken", 1)
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

  describe "package batching" do
    # On Debian and Ubuntu every dpkg run fires the man-db, desktop and icon
    # triggers and the update-notifier `apt-check` hook, so one process per
    # package cost 10-180 s each and a 180-package list took an hour. The same
    # list in one `apt-get install` pays that once.
    it "installs every package a step needs in one process" do
      step = Fluxion::PackagesStep.new("tools", Fluxion::PackageManager::Apt, %w[git curl jq])
      summary, listener, runner = run(profile([phase("base", [step] of Fluxion::Step)]))

      runner.argv.should eq([["sudo", "apt-get", "install", "-y", "git", "curl", "jq"]])
      summary.succeeded.should eq(3)
      listener.results.map(&.item).should eq(%w[git curl jq])
    end

    it "falls back to one process per package when the batch fails" do
      # One bad name fails the whole transaction, so the batch is only the fast
      # path: the isolation that keeps a typo from losing the rest of the list
      # is still there when it is needed.
      runner = Fluxion::Executor::FakeShellRunner.new.on("broken", 100)
      step = Fluxion::PackagesStep.new("tools", Fluxion::PackageManager::Apt, %w[git broken curl])
      summary, _, _ = run(profile([phase("base", [step] of Fluxion::Step)]), runner)

      runner.argv.should eq([
        ["sudo", "apt-get", "install", "-y", "git", "broken", "curl"],
        ["sudo", "apt-get", "install", "-y", "git"],
        ["sudo", "apt-get", "install", "-y", "broken"],
        ["sudo", "apt-get", "install", "-y", "curl"],
      ])
      summary.succeeded.should eq(2)
      summary.failed.should eq(1)
    end

    it "leaves out what a probe says is already installed" do
      runner = Fluxion::Executor::FakeShellRunner.new
        .available("dpkg-query")
        .on("\\n git", 0, "install ok installed|1:2.43.0-1ubuntu7\n")
      step = Fluxion::PackagesStep.new("tools", Fluxion::PackageManager::Apt, %w[git curl jq])
      options = Fluxion::Executor::RunOptions.new(mode: Fluxion::Executor::RunMode::LiveReprobe)
      summary, _, _ = run(profile([phase("base", [step] of Fluxion::Step)]), runner, options: options)

      runner.argv.reject(&.first.==("dpkg-query"))
        .should eq([["sudo", "apt-get", "install", "-y", "curl", "jq"]])
      summary.skipped.should eq(1)
      summary.succeeded.should eq(2)
      # Each item is probed once, not again after the batch installed it.
      runner.argv.count(&.first.==("dpkg-query")).should eq(3)
    end

    it "runs the pre-install actions first, each on its own" do
      step = Fluxion::PackagesStep.new("tools", Fluxion::PackageManager::Apt, %w[git curl],
        actions: [Fluxion::PackageAction.new("update")])
      summary, _, runner = run(profile([phase("base", [step] of Fluxion::Step)]))

      runner.argv.should eq([
        ["sudo", "apt-get", "update"],
        ["sudo", "apt-get", "install", "-y", "git", "curl"],
      ])
      summary.succeeded.should eq(3)
    end

    it "records every package the batch installed" do
      directory = File.tempname("fluxion-state")
      store = Fluxion::State::Store.new(directory)

      begin
        step = Fluxion::PackagesStep.new("tools", Fluxion::PackageManager::Apt, %w[git curl])
        run(profile([phase("base", [step] of Fluxion::Step)]), store: store)

        document = store.load("default")
        document.find("tools", "git", "package").should_not be_nil
        document.find("tools", "curl", "package").should_not be_nil
      ensure
        FileUtils.rm_rf(directory)
      end
    end

    it "previews the batch it would run" do
      step = Fluxion::PackagesStep.new("tools", Fluxion::PackageManager::Apt, %w[git curl])
      options = Fluxion::Executor::RunOptions.new(dry_run: true)
      summary, listener, runner = run(profile([phase("base", [step] of Fluxion::Step)]), options: options)

      runner.commands.should be_empty
      summary.dry_run.should eq(2)
      previews = listener.results.compact_map(&.as?(Fluxion::StepResult::DryRun))
      previews.first.would_execute.should eq(["sudo", "apt-get", "install", "-y", "git", "curl"])
      previews.last.would_execute.should be_empty
    end

    it "keeps cargo to one crate per process" do
      # Each crate is its own build, so there is no shared cost to save, and
      # `cargo install a b` stops at the first crate that fails to compile.
      step = Fluxion::PackagesStep.new("crates", Fluxion::PackageManager::Cargo, %w[ripgrep fd-find])
      _, _, runner = run(profile([phase("base", [step] of Fluxion::Step)]))

      runner.argv.should eq([["cargo", "install", "ripgrep"], ["cargo", "install", "fd-find"]])
    end
  end

  describe "cancellation" do
    it "announces a cancellation that arrived while a phase was running" do
      # The interrupt almost always lands while a step is mid-flight rather than
      # in the gap between two phases, and the `Cancelled` event is the only
      # thing that makes the reporter say the stop was clean and where to
      # resume. That path used to save the resume point and say nothing.
      cancellation = Fluxion::CancellationSignal.new
      runner = CancellingRunner.new("install -y git", cancellation)
      subject = profile([phase("base", [packages("tools", "git", "curl")] of Fluxion::Step)])

      summary, listener, _ = run(subject, runner, cancellation: cancellation)

      cancelled = listener.events.select(&.kind.cancelled?)
      cancelled.size.should eq(1)
      cancelled.first.step_name.should eq("base")
      summary.next_phase.should eq("base")
      # The signal is cooperative: the item in flight finishes, the next does
      # not start.
      runner.ran?("install -y curl").should be_false
    end

    it "announces a cancellation that arrived during a step that also failed" do
      # A phase that stops on the first failing step used to return `Failed`
      # before anything looked at the signal, so interrupting a run whose
      # current step happened to have a failed item was reported as a failure
      # and recorded no resume point — the user asked to stop and was told
      # something broke.
      cancellation = Fluxion::CancellationSignal.new
      runner = CancellingRunner.new("install -y broken", cancellation)
      runner.on("install -y broken", 1)
      subject = profile([
        phase("base", [packages("tools", "broken", "curl", continue_on_error: false)] of Fluxion::Step,
          continue_on_step_error: false),
      ])

      summary, listener, _ = run(subject, runner, cancellation: cancellation)

      cancelled = listener.events.select(&.kind.cancelled?)
      cancelled.size.should eq(1)
      summary.next_phase.should eq("base")
      summary.failed_phases.should be_empty
    end

    it "announces a cancellation that arrived during a failing source setup" do
      # Same shape one layer up: a source setup that both failed and was
      # interrupted answered "the setups did not succeed", and the traversal
      # returned before the cancellation could be recorded.
      cancellation = Fluxion::CancellationSignal.new
      runner = CancellingRunner.new("epel-release", cancellation)
      runner.on("epel-release", 1)
      setup = packages("epel", "epel-release", continue_on_error: false)
      subject = Fluxion::Profile.new("test", Fluxion::TargetOs.new(Fluxion::Distribution::Fedora),
        [phase("base", [packages("tools", "git")] of Fluxion::Step)],
        source_setups: [Fluxion::SourceSetup.new(setup, Fluxion::PackageManager::Dnf)])

      summary, listener, _ = run(subject, runner, cancellation: cancellation)

      listener.events.count(&.kind.cancelled?).should eq(1)
      summary.next_phase.should eq("base")
    end

    it "announces a cancellation that arrived during the source setups" do
      # Cancelling here used to hand "the setups did not succeed" back to the
      # traversal, which returned at once — the one interruption that recorded
      # no resume point and told the user nothing.
      cancellation = Fluxion::CancellationSignal.new
      runner = CancellingRunner.new("install -y epel-release", cancellation)
      subject = Fluxion::Profile.new("test", Fluxion::TargetOs.new(Fluxion::Distribution::Fedora),
        [phase("base", [packages("tools", "git")] of Fluxion::Step)],
        source_setups: [
          Fluxion::SourceSetup.new(packages("epel", "epel-release"), Fluxion::PackageManager::Dnf),
          Fluxion::SourceSetup.new(packages("extras", "rpmfusion-free"), Fluxion::PackageManager::Dnf),
        ])

      summary, listener, _ = run(subject, runner, cancellation: cancellation)

      listener.events.count(&.kind.cancelled?).should eq(1)
      summary.next_phase.should eq("base")
      # Neither the remaining setup nor the phase it prepared may run.
      runner.ran?("install -y rpmfusion-free").should be_false
      runner.ran?("install -y git").should be_false
    end

    it "does not treat a phase cancelled during its last step as completed" do
      # Recording it as completed, fingerprint and all, made the next
      # `--skip-already-installed` run skip the items that never ran.
      directory = File.tempname("fluxion-state")
      store = Fluxion::State::Store.new(directory)

      begin
        cancellation = Fluxion::CancellationSignal.new
        runner = CancellingRunner.new("install -y git", cancellation)
        subject = profile([phase("base", [packages("tools", "git", "curl")] of Fluxion::Step)])

        run(subject, runner, cancellation: cancellation, store: store)

        document = store.load("default")
        document.phases.should be_empty
        document.next_phase.should eq("base")
      ensure
        FileUtils.rm_rf(directory)
      end
    end

    it "does not report a cancelled phase as completed to the listener" do
      cancellation = Fluxion::CancellationSignal.new
      runner = CancellingRunner.new("install -y git", cancellation)
      subject = profile([phase("base", [packages("tools", "git", "curl")] of Fluxion::Step)])

      _, listener, _ = run(subject, runner, cancellation: cancellation)

      listener.events.any?(&.kind.phase_completed?).should be_false
    end
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

    it "ignores what state recorded when the run mode says to reprobe" do
      # A characterization test, not a regression one: this passed before the
      # guard moved into `Recorder#recorded` as well. It is here because nothing
      # pinned the rule at all — `RunMode::LiveReprobe` was not constructed
      # anywhere in the suite — and the guard is now the recorder's to keep.
      # `--reprobe` exists for the case where the state file and the machine
      # have drifted apart, so a recorded item must not skip anything: the only
      # evidence that counts is a live probe.
      directory = File.tempname("fluxion-state")
      store = Fluxion::State::Store.new(directory)

      begin
        subject = profile([phase("base", [packages("tools", "git")] of Fluxion::Step)])
        run(subject, store: store)
        store.load("default").find("tools", "git", "package").should_not be_nil

        reprobing = Fluxion::Executor::RunOptions.new(mode: Fluxion::Executor::RunMode::LiveReprobe)
        _, _, second = run(subject, options: reprobing, store: store)

        second.ran?("install -y git").should be_true
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

  it "changes when a named shell command's body is edited" do
    # A shell-command item's key is its `name`. A command that hides behind a
    # stable name — `name: setup` — could be rewritten from `echo one` to
    # anything at all and the phase still hashed the same, so a completed phase
    # was skipped and the new command never ran.
    before = fingerprint_of(Fluxion::ShellCommandStep.new("s",
      [Fluxion::ShellCommandItem.new(name: "setup", shell_command: "echo one")]))
    after = fingerprint_of(Fluxion::ShellCommandStep.new("s",
      [Fluxion::ShellCommandItem.new(name: "setup", shell_command: "echo two")]))

    before.should_not eq(after)
  end

  it "changes when a named shell command's argv is edited" do
    before = fingerprint_of(Fluxion::ShellCommandStep.new("s",
      [Fluxion::ShellCommandItem.new(name: "setup", argv: ["mkdir", "-p", "/a"])]))
    after = fingerprint_of(Fluxion::ShellCommandStep.new("s",
      [Fluxion::ShellCommandItem.new(name: "setup", argv: ["rm", "-rf", "/a"])]))

    before.should_not eq(after)
  end

  it "is unchanged for a bare shell string that is its own item key" do
    # The command is already in the item key, so hashing it again would hand
    # every such profile — which is nearly all of them — a digest where it had
    # none and invalidate completed phases for no gain.
    bare_string = Fluxion::ShellCommandStep.new("s", [Fluxion::ShellCommandItem.shell("true")])

    bare_string.content_digest.should be_nil
  end

  it "changes when an argv vector is re-split without changing its item key" do
    # An argv item always contributes, even when its auto-generated name is the
    # joined command, because the name keeps only the joined text and the text
    # is exactly what loses the vector's boundaries.
    one_word = Fluxion::ShellCommandStep.new("s",
      [Fluxion::ShellCommandItem.new(name: "echo hello world", argv: ["echo", "hello world"])])
    two_words = Fluxion::ShellCommandStep.new("s",
      [Fluxion::ShellCommandItem.new(name: "echo hello world", argv: ["echo hello", "world"])])

    one_word.items.map(&.key).should eq(two_words.items.map(&.key))
    one_word.content_digest.should_not eq(two_words.content_digest)
  end

  it "changes when a bare string is rewritten as the equivalent argv vector" do
    # The two run differently — one through a shell, one exec'd directly — and
    # the parser names them identically, so the fingerprint is the only place
    # that crossing can show up.
    as_string = Fluxion::ShellCommandStep.new("s", [Fluxion::ShellCommandItem.shell("mkdir -p /a")])
    as_argv = Fluxion::ShellCommandStep.new("s",
      [Fluxion::ShellCommandItem.new(name: "mkdir -p /a", argv: ["mkdir", "-p", "/a"])])

    as_string.content_digest.should_not eq(as_argv.content_digest)
  end

  it "changes when a written file's inline content is edited" do
    # The item key is the destination, and nothing else about the file reaches
    # the fingerprint. There is no file-write probe either, so an edited body
    # would have been skipped on every later run rather than caught on the next
    # one.
    with_body = ->(body : String) do
      fingerprint_of(Fluxion::FileWriteStep.new("files",
        [Fluxion::FileWriteItem.new("conf", "/etc/tool.conf", content: body)]))
    end

    with_body.call("enabled=true").should_not eq(with_body.call("enabled=false"))
  end

  it "changes when a written file's mode or owner is edited" do
    with_mode = ->(mode : String) do
      fingerprint_of(Fluxion::FileWriteStep.new("files",
        [Fluxion::FileWriteItem.new("conf", "/etc/tool.conf", content: "x", mode: mode)]))
    end

    with_mode.call("0644").should_not eq(with_mode.call("0600"))
  end

  it "changes when a git config value is edited" do
    # The item key is `global:user.email`, which is the setting's name and not
    # the address it holds, so correcting a mistyped address was invisible.
    with_email = ->(address : String) do
      fingerprint_of(Fluxion::GitConfigStep.new("git", {"user.email" => address}))
    end

    with_email.call("a@example.com").should_not eq(with_email.call("b@example.com"))
  end

  it "changes when a repository's pinned commit is bumped" do
    # The item key is the destination directory, so the one edit this kind
    # exists for — moving `ref` to a newer commit — hashed identically.
    with_ref = ->(ref : String) do
      fingerprint_of(Fluxion::GitRepoStep.new("repos",
        [Fluxion::GitRepo.new("https://example.com/x.git", "/opt/x", ref)]))
    end

    with_ref.call("a" * 40).should_not eq(with_ref.call("b" * 40))
  end

  it "changes when a unit is masked instead of enabled" do
    # The item key is the unit name, so `enabled: true` and `masked: true` —
    # opposite instructions for the same unit — used to hash alike.
    enabled = fingerprint_of(Fluxion::SystemdUnitStep.new("units",
      [Fluxion::SystemdUnit.new("docker", enabled: true, state: Fluxion::SystemdState::Started)]))
    masked = fingerprint_of(Fluxion::SystemdUnitStep.new("units",
      [Fluxion::SystemdUnit.new("docker", enabled: false, state: Fluxion::SystemdState::Stopped, masked: true)]))

    enabled.should_not eq(masked)
  end

  it "changes when a host setting's value is edited" do
    # The item keys are the bare setting names — `timezone`, `hostname` — so
    # moving the machine to another zone left the phase looking unchanged.
    with_timezone = ->(zone : String) do
      fingerprint_of(Fluxion::SystemSettingStep.new("host", timezone: zone))
    end

    with_timezone.call("UTC").should_not eq(with_timezone.call("Europe/Warsaw"))
  end

  it "reports no digest for the host settings a profile left unset" do
    Fluxion::SystemSettingStep.new("host").content_digest.should be_nil
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
      # Two steps rather than one list, because a list is installed as one
      # batch and would explode before anything succeeded.
      subject = profile([
        phase("base", [packages("tools", "git"), packages("more", "boom")] of Fluxion::Step),
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
