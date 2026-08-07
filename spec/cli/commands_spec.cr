require "../spec_helper"

# Runs a command against a temporary profile and captures what it rendered.
private record Run, exit_code : Fluxion::CLI::ExitCode, stdout : String, stderr : String do
  def success? : Bool
    exit_code.success?
  end

  def json : JSON::Any
    JSON.parse(stdout)
  end
end

private def invoke(*arguments : String, profile : String? = nil) : Run
  invoke_all(arguments.to_a, profile)
end

private def invoke_all(arguments : Array(String), profile : String? = nil) : Run
  output = IO::Memory.new
  errors = IO::Memory.new

  run = ->(args : Array(String)) do
    # Colour is forced off so assertions read against plain text; the styling
    # itself is covered by the Style specs.
    code = Fluxion::CLI::Style.with_color(false) do
      Fluxion::CLI::App.new(Fluxion::CLI::GlobalOptions.new, output, errors).run(args)
    end
    Run.new(code, output.to_s, errors.to_s)
  end

  if profile
    ProfileHelpers.with_profile(profile) do |path|
      run.call(arguments + ["-c", path])
    end
  else
    run.call(arguments)
  end
end

private VALID_PROFILE = <<-YAML
  apiVersion: initkit.io/v1alpha1
  kind: WorkstationProfile
  metadata:
    name: workstation
  spec:
    target:
      os:
        distribution: fedora
        release: "44"
    phases:
      - name: base
        steps:
          - name: core-tools
            kind: dnf-packages
            spec:
              packages: [git, curl]
      - name: desktop
        dependsOn: [base]
        steps:
          - name: apps
            kind: flatpak-packages
            spec:
              apps: [com.spotify.Client]
  YAML

describe Fluxion::CLI::App do
  it "prints usage and exits cleanly with no arguments" do
    result = invoke_all([] of String)
    result.success?.should be_true
    result.stdout.should contain("fluxion <command>")
    result.stdout.should contain("validate")
  end

  it "prints the version" do
    invoke("--version").stdout.strip.should eq("fluxion #{Fluxion::VERSION}")
  end

  it "rejects an unknown command with usage on stderr" do
    result = invoke("summon")
    result.exit_code.should eq(Fluxion::CLI::ExitCode::InvalidInput)
    result.stderr.should contain("Unknown command 'summon'")
    result.stderr.should contain("Usage:")
  end

  it "reports a missing profile without a stack trace" do
    result = invoke("validate", "-c", "/definitely/missing/fluxion.yaml")
    result.exit_code.should eq(Fluxion::CLI::ExitCode::ConfigurationError)
    result.stderr.should contain("File does not exist")
    result.stderr.should_not contain("Exception")
  end
end

describe Fluxion::CLI::ValidateCommand do
  it "accepts a valid profile" do
    result = invoke("validate", profile: VALID_PROFILE)
    result.success?.should be_true
    result.stdout.should contain("Config is valid")
    result.stdout.should contain("workstation")
    result.stdout.should contain("2 phases")
    result.stdout.should contain("2 steps")
  end

  it "reports every problem at once with its config path" do
    result = invoke("validate", profile: <<-YAML)
      apiVersion: initkit.io/v1alpha1
      kind: WorkstationProfile
      metadata:
        name: broken
      spec:
        target:
          os:
            distribution: debian
        phases:
          - name: base
            dependsOn: [missing]
            steps:
              - name: tools
                kind: dnf-packages
                spec:
                  packages: ["bad name"]
      YAML

    result.exit_code.should eq(Fluxion::CLI::ExitCode::ConfigurationError)
    result.stderr.should contain("Config validation failed")
    result.stdout.should contain("spec.phases[0].steps[0].spec.packages[0]")
    result.stdout.should contain("unsafe shell characters")
    result.stdout.should contain("unknown phase 'missing'")
    result.stdout.should contain("not valid for target debian")
  end

  it "suggests the closest step kind for a typo" do
    result = invoke("validate", profile: <<-YAML)
      apiVersion: initkit.io/v1alpha1
      kind: WorkstationProfile
      metadata:
        name: p
      spec:
        target:
          os:
            distribution: fedora
        phases:
          - name: base
            steps:
              - name: tools
                kind: dnf-package
                spec:
                  packages: [git]
      YAML

    result.stdout.should contain("Did you mean 'dnf-packages'?")
  end

  it "renders JSON with a stable shape" do
    result = invoke("validate", "--format", "json", profile: VALID_PROFILE)
    result.success?.should be_true

    json = result.json
    json["profileName"].as_s.should eq("workstation")
    json["phaseCount"].as_i.should eq(2)
    json["stepCount"].as_i.should eq(2)
    json["valid"].as_bool.should be_true
    json["issues"].as_a.should be_empty
  end

  it "keeps a profile valid under --strict when it only has warnings" do
    # A duplicate package is wasteful, not wrong, so it warns rather than
    # failing — but --strict is exactly the flag for treating it as failure.
    warned = <<-YAML
      apiVersion: initkit.io/v1alpha1
      kind: WorkstationProfile
      metadata:
        name: p
      spec:
        target:
          os:
            distribution: fedora
        phases:
          - name: base
            steps:
              - name: tools
                kind: dnf-packages
                spec:
                  packages: [git, git]
      YAML

    invoke("validate", profile: warned).success?.should be_true
    invoke("validate", "--strict", profile: warned)
      .exit_code.should eq(Fluxion::CLI::ExitCode::ConfigurationError)
  end

  it "rejects an unsupported format" do
    result = invoke("validate", "--format", "yaml", profile: VALID_PROFILE)
    result.exit_code.should eq(Fluxion::CLI::ExitCode::InvalidInput)
    result.stderr.should contain("Unsupported format 'yaml'")
  end
end

describe Fluxion::CLI::KindsCommand do
  it "lists every registered plan kind" do
    result = invoke("kinds")
    result.success?.should be_true
    Fluxion::Config::PlanKinds.ids.each { |id| result.stdout.should contain(id) }
  end

  it "shows the pre-install actions a package kind accepts" do
    invoke("kinds").stdout.should contain("check-update")
  end

  it "renders JSON that matches the registry" do
    json = invoke("kinds", "--format", "json").json
    ids = json["kinds"].as_a.map(&.["id"].as_s)
    ids.should eq(Fluxion::Config::PlanKinds.ids)

    dnf = json["kinds"].as_a.find! { |kind| kind["id"].as_s == "dnf-packages" }
    dnf["category"].as_s.should eq("packages")
    dnf["packageActions"].as_a.map(&.as_s).should contain("check-update")
  end

  it "needs no config file" do
    invoke("kinds").success?.should be_true
  end
end

describe Fluxion::CLI::ListCommand do
  it "lists steps with their kind and item count" do
    result = invoke("list", profile: VALID_PROFILE)
    result.success?.should be_true
    result.stdout.should contain("core-tools")
    result.stdout.should contain("packages")
    result.stdout.should contain("apps")
    result.stdout.should contain("flatpak")
  end

  it "renders JSON with item counts" do
    json = invoke("list", "--format", "json", profile: VALID_PROFILE).json
    json["profileName"].as_s.should eq("workstation")

    steps = json["steps"].as_a
    steps.size.should eq(2)
    steps.first["itemCount"].as_i.should eq(2)
  end
end

describe Fluxion::CLI::PlanCommand do
  it "orders phases by their dependencies" do
    result = invoke("plan", profile: VALID_PROFILE)
    result.success?.should be_true
    result.stdout.index!("base").should be < result.stdout.index!("desktop")
  end

  it "lists the items each step would install" do
    result = invoke("plan", profile: VALID_PROFILE)
    result.stdout.should contain("git")
    result.stdout.should contain("curl")
    result.stdout.should contain("would run")
  end

  it "reports counts" do
    invoke("plan", profile: VALID_PROFILE).stdout.should contain("steps=2")
  end

  it "renders a table" do
    result = invoke("plan", "--format", "table", profile: VALID_PROFILE)
    result.stdout.should contain("PHASE")
    result.stdout.should contain("STEP")
    result.stdout.should contain("ITEM")
  end

  it "renders a tree" do
    result = invoke("plan", "--format", "tree", profile: VALID_PROFILE)
    result.stdout.should contain("Execution plan for: workstation")
    result.stdout.should contain("core-tools")
  end

  it "renders JSON with phases, steps, and items" do
    json = invoke("plan", "--format", "json", profile: VALID_PROFILE).json
    phases = json["phases"].as_a
    phases.map(&.["name"].as_s).should eq(%w[base desktop])
    phases[1]["dependsOn"].as_a.map(&.as_s).should eq(["base"])
    phases[0]["steps"].as_a.first["items"].as_a.map(&.["key"].as_s).should eq(%w[git curl])
  end

  it "flags a phase that requires a logout" do
    result = invoke("plan", profile: <<-YAML)
      apiVersion: initkit.io/v1alpha1
      kind: WorkstationProfile
      metadata:
        name: p
      spec:
        target:
          os:
            distribution: fedora
        phases:
          - name: shell
            restartPolicy:
              type: prompt-logout
            steps:
              - name: tools
                kind: dnf-packages
                spec:
                  packages: [zsh]
      YAML

    result.stdout.should contain("RESTART REQUIRED")
  end

  it "reports steps the host excluded" do
    result = invoke("plan", profile: <<-YAML)
      apiVersion: initkit.io/v1alpha1
      kind: WorkstationProfile
      metadata:
        name: workstation
      spec:
        target:
          os:
            distribution: fedora
        phases:
          - name: base
            steps:
              - name: nowhere
                kind: dnf-packages
                when:
                  distribution: plan9
                spec:
                  packages: [git]
      YAML

    result.success?.should be_true
    result.stdout.should contain("Skipped entries:")
    result.stdout.should contain("nowhere")
  end
end

describe Fluxion::CLI::GraphCommand do
  it "renders Mermaid by default" do
    result = invoke("graph", profile: VALID_PROFILE)
    result.success?.should be_true
    result.stdout.should contain("flowchart TD")
    result.stdout.should contain(%(p_base["base"]))
    result.stdout.should contain("p_base --> p_desktop")
  end

  it "renders Graphviz dot" do
    result = invoke("graph", "--format", "dot", profile: VALID_PROFILE)
    result.stdout.should contain("digraph fluxion {")
    result.stdout.should contain(%("base" -> "desktop";))
  end

  it "renders JSON edges" do
    json = invoke("graph", "--format", "json", profile: VALID_PROFILE).json
    edge = json["edges"].as_a.first
    edge["from"].as_s.should eq("base")
    edge["to"].as_s.should eq("desktop")
  end

  it "sanitizes phase names into valid Mermaid identifiers" do
    result = invoke("graph", profile: <<-YAML)
      apiVersion: initkit.io/v1alpha1
      kind: WorkstationProfile
      metadata:
        name: p
      spec:
        target:
          os:
            distribution: fedora
        phases:
          - name: base-cli.tools
            steps:
              - name: tools
                kind: dnf-packages
                spec:
                  packages: [git]
      YAML

    result.stdout.should contain("p_base_cli_tools")
  end
end

describe Fluxion::CLI::Style do
  it "emits no escape sequences when colour is off" do
    Fluxion::CLI::Style.with_color(false) do
      Fluxion::CLI::Style.green("ok").should eq("ok")
      Fluxion::CLI::Style.bold("ok").should eq("ok")
    end
  end

  it "wraps text when colour is on" do
    Fluxion::CLI::Style.with_color(true) do
      Fluxion::CLI::Style.green("ok").should eq("\e[32mok\e[0m")
    end
  end

  it "measures width ignoring styling, so columns stay aligned" do
    Fluxion::CLI::Style.with_color(true) do
      styled = Fluxion::CLI::Style.red("abc")
      styled.size.should be > 3
      Fluxion::CLI::Style.width(styled).should eq(3)
      Fluxion::CLI::Style.pad(styled, 5).should end_with("  ")
    end
  end

  it "truncates on visible width" do
    Fluxion::CLI::Style.with_color(false) do
      Fluxion::CLI::Style.truncate("abcdefgh", 4).should eq("abc…")
      Fluxion::CLI::Style.truncate("abc", 10).should eq("abc")
    end
  end
end
