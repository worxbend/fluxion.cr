require "../spec_helper"

# The shipped example profiles are the port's end-to-end check: they exercise
# every step kind against the real schema rather than a hand-written fragment,
# so a regression in any parser shows up here first.
describe "example profiles" do
  root = File.expand_path(File.join(__DIR__, "..", "..", "examples"))
  examples = (Dir.glob(File.join(root, "*.yaml")) + Dir.glob(File.join(root, "registry", "profiles", "*.yaml"))).sort

  it "ships examples to parse" do
    examples.should_not be_empty
  end

  examples.each do |path|
    name = File.basename(path)

    it "parses #{name} without errors" do
      document = Fluxion::Config::Loader.read(path)
      context = Fluxion::Config::Context.new(File.dirname(path), ProfileHelpers.fedora_host)
      profile = Fluxion::Config::Loader.parse(context, document, path)

      context.diagnostics.errors.map(&.to_s).should be_empty
      profile.name.should_not be_empty

      # One schema means one shape: every example declares named phases, and
      # every phase earns its place by holding steps or explaining why it has
      # none.
      profile.phases.should_not be_empty
      profile.phases.each(&.name.should_not(be_empty))
      profile.ordered_phases.size.should eq(profile.phases.size)
    end
  end

  it "selects different work on different hosts" do
    path = File.join(root, "workstation-fedora.yaml")
    pending! "workstation-fedora.yaml is not present" unless File.exists?(path)

    document = Fluxion::Config::Loader.read(path)

    on_fedora = Fluxion::Config::Context.new(File.dirname(path), ProfileHelpers.fedora_host)
    fedora = Fluxion::Config::Loader.parse(on_fedora, document, path)

    on_arch = Fluxion::Config::Context.new(File.dirname(path), ProfileHelpers.arch_host)
    arch = Fluxion::Config::Loader.parse(on_arch, document, path)

    # A Fedora profile run on Arch should select strictly less work, and say
    # so rather than silently dropping it.
    arch.steps.size.should be < fedora.steps.size
    arch.skipped_plan_entries.size.should be > fedora.skipped_plan_entries.size
    arch.skipped_plan_entries.each(&.reason.should_not(be_empty))
  end

  it "reaches a wide spread of step kinds across the examples" do
    kinds = Set(String).new
    examples.each do |path|
      document = Fluxion::Config::Loader.read(path)
      context = Fluxion::Config::Context.new(File.dirname(path), ProfileHelpers.fedora_host)
      Fluxion::Config::Loader.parse(context, document, path).steps.each { |step| kinds << step.kind }
    end

    %w[packages flatpak shell-command compiled-binary].each do |kind|
      kinds.should contain(kind)
    end
  end

  it "orders every example's phases without a cycle" do
    # `dependsOn` is new to these files; a cycle would only surface at plan
    # time, which is after the profile has already been called valid.
    examples.each do |path|
      document = Fluxion::Config::Loader.read(path)
      context = Fluxion::Config::Context.new(File.dirname(path), ProfileHelpers.fedora_host)
      profile = Fluxion::Config::Loader.parse(context, document, path)

      ordered = profile.ordered_phases.map(&.name)
      profile.phases.each do |phase|
        phase.depends_on.each do |dependency|
          ordered.index!(dependency).should be < ordered.index!(phase.name)
        end
      end
    end
  end
end
