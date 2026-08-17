require "../spec_helper"

private def step(name : String, packages : Array(String))
  Fluxion::PackagesStep.new(name, Fluxion::PackageManager::Dnf, packages)
end

private def sample_profile(packages = %w[git curl])
  Fluxion::Profile.new(
    "test",
    Fluxion::TargetOs.new(Fluxion::Distribution::Fedora),
    [
      Fluxion::Phase.new("base", [step("tools", packages)] of Fluxion::Step),
      Fluxion::Phase.new("desktop", [step("apps", ["firefox"])] of Fluxion::Step, ["base"]),
    ],
  )
end

private def with_store(&)
  directory = File.tempname("fluxion-resume-spec")
  begin
    yield Fluxion::State::Store.new(directory)
  ensure
    FileUtils.rm_rf(directory)
  end
end

# Records `phase` as completed against the profile it actually belongs to, the
# same way a real run would.
private def record_completed(store, profile, phase_name : String, next_phase : String? = nil)
  phase = profile.phases.find! { |candidate| candidate.name == phase_name }
  store.update("default") do |document|
    document.record(Fluxion::State::PhaseRecord.new(
      phase: phase.name,
      status: "completed",
      completed_at: Time.utc,
      fingerprint: Fluxion::State::Fingerprint.of(phase),
    ))
    document.next_phase = next_phase
  end
end

describe Fluxion::TUI::Resume do
  it "reports nothing to resume from when the profile has never run" do
    with_store do |store|
      resume = Fluxion::TUI::Resume.load(store, sample_profile, "default")

      resume.available?.should be_false
      resume.summary.should contain("no saved state")
    end
  end

  it "reads the phases a previous run finished" do
    with_store do |store|
      profile = sample_profile
      record_completed(store, profile, "base", next_phase: "desktop")

      resume = Fluxion::TUI::Resume.load(store, profile, "default")
      resume.available?.should be_true
      resume.completed?("base").should be_true
      resume.completed?("desktop").should be_false
      resume.next_phase.should eq("desktop")
      resume.summary.should contain("1 phase already done")
    end
  end

  it "forgets a phase whose configuration has since changed" do
    # The same rule the executor uses: editing a package list makes the phase
    # run again rather than staying quietly "completed".
    with_store do |store|
      record_completed(store, sample_profile, "base")

      edited = sample_profile(%w[git curl ripgrep])
      Fluxion::TUI::Resume.load(store, edited, "default").completed?("base").should be_false
    end
  end

  it "treats an unreadable state file as nothing to resume from" do
    # The offer is a shortcut. If the shortcut is unavailable the run must
    # still be startable.
    with_store do |store|
      Dir.mkdir_p(store.root)
      File.write(store.path("default"), "{ not json")

      Fluxion::TUI::Resume.load(store, sample_profile, "default").available?.should be_false
    end
  end
end

describe Fluxion::TUI::Selection do
  it "turns off the phases a previous run finished, and counts them" do
    profile = sample_profile
    selection = Fluxion::TUI::Selection.new(profile)

    turned_off = selection.resume_from(Fluxion::TUI::Resume.new(Set{"base"}))

    turned_off.should eq(1)
    selection.phase?("base").should be_false
    selection.phase?("desktop").should be_true
  end

  it "counts nothing when the finished phases are already deselected" do
    # An offer that appears to do nothing should be able to say so.
    profile = sample_profile
    selection = Fluxion::TUI::Selection.new(profile)
    selection.select_none

    selection.resume_from(Fluxion::TUI::Resume.new(Set{"base"})).should eq(0)
  end

  it "reports the steps and items a single phase contributes" do
    profile = sample_profile
    selection = Fluxion::TUI::Selection.new(profile)
    base = profile.phases.first

    selection.selected_steps(base).should eq(1)
    selection.selected_items(base).should eq(2)

    selection.toggle_step(base, base.steps.first)
    selection.selected_items(base).should eq(0)
  end

  it "inverts every step and re-derives the phases from what survived" do
    profile = sample_profile
    selection = Fluxion::TUI::Selection.new(profile)
    selection.toggle_step(profile.phases.first, profile.phases.first.steps.first)

    selection.invert

    selection.step?("tools").should be_true
    selection.step?("apps").should be_false
    selection.phase?("base").should be_true
    selection.phase?("desktop").should be_false
  end

  it "narrows to one phase or to one step" do
    profile = sample_profile
    selection = Fluxion::TUI::Selection.new(profile)

    selection.select_only(profile.phases.first)
    selection.step?("tools").should be_true
    selection.step?("apps").should be_false

    selection.select_only(profile.phases.last, profile.phases.last.steps.first)
    selection.step?("apps").should be_true
    selection.step?("tools").should be_false
  end

  it "goes back to the profile as written" do
    profile = sample_profile
    selection = Fluxion::TUI::Selection.new(profile)
    selection.select_none

    selection.reset
    selection.selected_steps.should eq(2)
  end
end
