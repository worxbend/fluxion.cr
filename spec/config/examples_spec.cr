require "../spec_helper"

# The shipped example profiles are the port's end-to-end check: they exercise
# every step kind against the real schema rather than a hand-written fragment,
# so a regression in any parser shows up here first.
describe "example profiles" do
  examples = Dir.glob(File.join(__DIR__, "..", "..", "examples", "*.yaml")).sort

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
    end
  end

  it "selects different manifest work on different hosts" do
    path = File.join(__DIR__, "..", "..", "examples", "workstation-fedora.yaml")
    pending! "workstation-fedora.yaml is not present" unless File.exists?(path)

    document = Fluxion::Config::Loader.read(path)

    on_fedora = Fluxion::Config::Context.new(File.dirname(path), ProfileHelpers.fedora_host)
    fedora = Fluxion::Config::Loader.parse(on_fedora, document, path)

    on_arch = Fluxion::Config::Context.new(File.dirname(path), ProfileHelpers.arch_host)
    arch = Fluxion::Config::Loader.parse(on_arch, document, path)

    # A Fedora manifest run on Arch should select strictly less work, and say
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
end
