require "../spec_helper"

# Adding a step kind touches several hand-maintained tables that nothing forces
# into agreement. These specs are that force. Both failure modes they guard were
# silent: a kind missing from `STEP_TYPES` made the step vanish from the profile
# while `validate` reported success, and a kind missing from `ItemTypes.for`
# recorded its items under the wrong state-file discriminator.
private def empty_context
  Fluxion::Config::Context.new(Dir.current)
end

private def empty_spec
  Fluxion::Config::Node.new(YAML.parse("{}"), "spec")
end

describe "step kind tables" do
  # The kinds the manifest routes through `STEP_TYPES` rather than handling
  # directly. The package family, `file-writes` and `interrupt` are parsed by
  # dedicated builders, which is why they are absent from that table.
  directly_handled = %w[interrupt file-writes]
  mapped_categories = [
    Fluxion::Config::PlanKinds::Category::Installer,
    Fluxion::Config::PlanKinds::Category::Control,
  ]

  it "maps every kind that routes through STEP_TYPES" do
    missing = Fluxion::Config::PlanKinds::ALL
      .select { |kind| mapped_categories.includes?(kind.category) }
      .reject { |kind| directly_handled.includes?(kind.id) }
      .map(&.id)
      .reject { |id| Fluxion::Config::PlanKinds::STEP_TYPES.has_key?(id) }

    missing.should be_empty
  end

  it "has no STEP_TYPES entry for a kind that does not exist" do
    known = Fluxion::Config::PlanKinds::ALL.map(&.id).to_set
    Fluxion::Config::PlanKinds::STEP_TYPES.keys.reject { |id| known.includes?(id) }.should be_empty
  end

  it "gives every STEP_TYPES value a builder" do
    # A step type with no branch in `StepParser.build` returns nil and records
    # nothing. Every real builder either produces a step or complains about the
    # empty spec it was handed, so "nil and silent" is the signature of a
    # missing branch and nothing else.
    unbuildable = Fluxion::Config::PlanKinds::STEP_TYPES.values.uniq!.reject do |type|
      context = empty_context
      step = Fluxion::Config::StepParser.build_kind(context, empty_spec, type, "probe", nil, nil)
      step || !context.diagnostics.empty?
    end

    unbuildable.should be_empty
  end

  it "gives every Step subclass an ItemType" do
    # Enumerated by the compiler rather than by a list someone has to remember
    # to extend: `all_subclasses` sees a new step kind the moment it is defined.
    # `allocate` skips the constructor because only the class is being
    # dispatched on, which is what lets this cover all 30 kinds instead of the
    # handful that can be built from an empty spec.
    unmapped = [] of String

    {% for type in Fluxion::Step.all_subclasses.reject(&.abstract?) %}
      begin
        Fluxion::Executor::ItemTypes.for({{ type }}.allocate)
      rescue Fluxion::ExecutionError
        unmapped << {{ type.name.stringify }}
      end
    {% end %}

    unmapped.should be_empty
  end

  it "covers every Step subclass, and there are more than a handful" do
    # Guards the guard: if `all_subclasses` ever resolved to nothing the spec
    # above would pass while checking no kinds at all. Deliberately a floor
    # rather than the exact count — kinds are added and retired, and a spec
    # that has to be edited for each is noise rather than a check.
    count = {{ Fluxion::Step.all_subclasses.reject(&.abstract?).size }}
    count.should be >= 20
  end
end

describe Fluxion::Executor::ItemTypes do
  it "refuses to invent an ItemType for an unmapped step kind" do
    # Fails closed: the value is the state-file discriminator and the probe
    # dispatch key, so a plausible-looking guess is worse than a loud failure.
    expect_raises(Fluxion::ExecutionError, /No ItemType mapped for step kind 'unmapped'/) do
      Fluxion::Executor::ItemTypes.for(UnmappedStep.new("newkind"))
    end
  end

  it "maps a known step kind" do
    step = Fluxion::PackagesStep.new("tools", Fluxion::PackageManager::Dnf, ["git"])
    Fluxion::Executor::ItemTypes.for(step).should eq(Fluxion::ItemType::Package)
  end
end

# A step kind that exists but was never added to the mapping table — exactly the
# state a contributor leaves behind by following the checklist and missing one
# entry.
private class UnmappedStep < Fluxion::Step
  def kind : String
    "unmapped"
  end

  def items : Array(Fluxion::ItemRef)
    [] of Fluxion::ItemRef
  end
end

describe "installerVersion" do
  it "refuses a release Fluxion has no digest for, naming the one it has" do
    # It was parsed, range-checked, stored and never read — a knob that turned
    # nothing, because ToolBroker resolves the pinned release regardless.
    result = ProfileHelpers.parse(ProfileHelpers.manifest(<<-STEP))
      - name: portable
        kind: binstaller-profile
        spec:
          config: ./binstaller.yaml
          installerVersion: v9.9.9
      STEP

    message = result.error_messages.find!(&.includes?("verified digest"))
    message.should contain(Fluxion::BinstallerProfileStep::DEFAULT_INSTALLER_VERSION)
  end

  it "accepts the pinned release" do
    result = ProfileHelpers.parse(ProfileHelpers.manifest(<<-STEP))
      - name: portable
        kind: binstaller-profile
        spec:
          config: ./binstaller.yaml
          installerVersion: #{Fluxion::BinstallerProfileStep::DEFAULT_INSTALLER_VERSION}
      STEP

    result.errors.should be_empty
  end
end
