require "../spec_helper"

# Adding a step kind touches several hand-maintained tables that nothing forces
# into agreement. These specs are that force. Both failure modes they guard were
# silent: a kind missing from `STEP_TYPES` made the step vanish from the profile
# while `validate` reported success.
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

  it "covers every Step subclass, and there are more than a handful" do
    # Guards the tables above: if `all_subclasses` ever resolved to nothing, a
    # compiler-driven check over the step hierarchy would pass while checking
    # no kinds at all. Deliberately a floor rather than the exact count — kinds
    # are added and retired, and a spec that has to be edited for each is noise
    # rather than a check.
    #
    # `item_type` needs no spec of its own any more. It used to be a `case`
    # over the step hierarchy, which Crystal cannot check for exhaustiveness,
    # so a spec had to walk every subclass and catch an "unmapped" error, and a
    # fixture step deliberately left out of the table stood in for the mistake.
    # It is now an abstract method on `Step`: a subclass that omits it does not
    # compile, so neither the spec nor the fixture can be written any more. The
    # guard moved out of this file and into the type system.
    count = {{ Fluxion::Step.all_subclasses.reject(&.abstract?).size }}
    count.should be >= 20
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
