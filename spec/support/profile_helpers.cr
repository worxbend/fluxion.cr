require "file_utils"

# Writes a profile to a temporary directory and parses it, so specs can state
# the YAML they mean instead of maintaining fixture files.
module ProfileHelpers
  extend self

  record Parsed,
    profile : Fluxion::Profile,
    diagnostics : Array(Fluxion::Diagnostic) do
    def errors : Array(Fluxion::Diagnostic)
      diagnostics.select(&.error?)
    end

    def warnings : Array(Fluxion::Diagnostic)
      diagnostics.select(&.warning?)
    end

    def error_messages : Array(String)
      errors.map(&.to_s)
    end

    def step(name : String) : Fluxion::Step
      profile.steps.find! { |step| step.name == name }
    end
  end

  def parse(yaml : String, host : Fluxion::HostFacts = Fluxion::HostFacts.new, filename : String = "profile.yaml") : Parsed
    with_profile(yaml, filename) do |path|
      document = Fluxion::Config::Loader.read(path)
      context = Fluxion::Config::Context.new(File.dirname(path), host)
      profile = Fluxion::Config::Loader.parse(context, document, path)
      Parsed.new(profile, context.diagnostics.diagnostics)
    end
  end

  def with_profile(yaml : String, filename : String = "profile.yaml", & : String -> T) : T forall T
    directory = File.tempname("fluxion-spec")
    Dir.mkdir_p(directory)
    begin
      path = File.join(directory, filename)
      File.write(path, yaml)
      yield path
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  # A host that matches nothing, so `when` behaviour is deterministic in specs
  # rather than depending on the machine running them.
  def unknown_host : Fluxion::HostFacts
    Fluxion::HostFacts.new
  end

  def fedora_host : Fluxion::HostFacts
    Fluxion::HostFacts.new(
      distribution: Fluxion::Distribution::Fedora,
      family: Fluxion::OsFamily::Fedora,
      distribution_id: "fedora",
      version: "44",
      architecture: Fluxion::Architecture::Amd64,
    )
  end

  def arch_host : Fluxion::HostFacts
    Fluxion::HostFacts.new(
      distribution: Fluxion::Distribution::Arch,
      family: Fluxion::OsFamily::Arch,
      distribution_id: "arch",
      architecture: Fluxion::Architecture::Amd64,
    )
  end

  # A minimal valid jobs/steps profile with `body` spliced in as the step list.
  #
  # Built line by line rather than from a heredoc: the body arrives already
  # indented for readability at the call site, and re-indenting it inside a
  # heredoc makes both halves fragile.
  def jobs_profile(body : String, os : String = "fedora") : String
    header = [
      "profile: test",
      "os:",
      "  type: #{os}",
      "jobs:",
      "  - name: base",
      "    steps:",
    ]
    (header + indent(body, 6)).join('\n') + '\n'
  end

  # A minimal valid manifest with `body` spliced in as the plan list.
  def manifest(body : String, distribution : String = "fedora") : String
    header = [
      "apiVersion: initkit.io/v1alpha1",
      "kind: WorkstationProfile",
      "metadata:",
      "  name: test",
      "spec:",
      "  target:",
      "    os:",
      "      distribution: #{distribution}",
      "  plan:",
    ]
    (header + indent(body, 4)).join('\n') + '\n'
  end

  # Re-indents a fragment to `spaces`, normalising whatever indentation the
  # call site used so specs can lay their YAML out however reads best.
  private def indent(body : String, spaces : Int32) : Array(String)
    lines = body.lines.map(&.rstrip).reject(&.empty?)
    return lines if lines.empty?

    common = lines.min_of { |line| line.size - line.lstrip.size }
    lines.map { |line| (" " * spaces) + line[common..] }
  end
end
