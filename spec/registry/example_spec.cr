require "../spec_helper"

# The shipped example registry is the format's end-to-end check: it proves the
# documented layout is one the parser actually accepts, and that every entry
# points at a profile that exists and validates.
describe "the example registry" do
  root = File.join(__DIR__, "..", "..", "examples", "registry")

  it "parses its manifest without errors" do
    manifest, diagnostics = Fluxion::Registry::Manifest.parse(
      File.read(File.join(root, Fluxion::Registry::Manifest::FILE_NAME)))

    diagnostics.select(&.error?).map(&.to_s).should be_empty
    manifest.not_nil!.entries.should_not be_empty
  end

  manifest, _ = Fluxion::Registry::Manifest.parse(
    File.read(File.join(root, Fluxion::Registry::Manifest::FILE_NAME)))

  manifest.not_nil!.entries.each do |entry|
    it "ships #{entry.id} as a profile that validates" do
      path = File.join(root, entry.path)
      File.exists?(path).should be_true

      document = Fluxion::Config::Loader.read(path)
      context = Fluxion::Config::Context.new(File.dirname(path), ProfileHelpers.fedora_host)
      profile = Fluxion::Config::Loader.parse(context, document, path)

      context.diagnostics.errors.map(&.to_s).should be_empty
      profile.name.should_not be_empty
    end
  end

  it "names only entries that exist for its requirements" do
    ids = manifest.not_nil!.ids
    manifest.not_nil!.entries.each do |entry|
      entry.requires.each { |required| ids.should contain(required) }
    end
  end
end
