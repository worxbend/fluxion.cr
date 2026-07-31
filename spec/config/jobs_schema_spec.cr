require "../spec_helper"

describe Fluxion::Config::JobsSchema do
  it "parses a minimal profile" do
    result = ProfileHelpers.parse(<<-YAML)
      profile: my-laptop
      os:
        type: fedora
        release: "44"
      jobs:
        - name: base-cli
          steps:
            - type: packages
              name: core-tools
              packageManager: dnf
              packages: [git, curl, jq]
      YAML

    result.errors.should be_empty
    result.profile.name.should eq("my-laptop")
    result.profile.target.distribution.should eq(Fluxion::Distribution::Fedora)
    result.profile.target.release.should eq("44")

    step = result.step("core-tools").as(Fluxion::PackagesStep)
    step.packages.should eq(%w[git curl jq])
    step.items.map(&.key).should eq(%w[git curl jq])
  end

  it "reads an unquoted release as a string" do
    result = ProfileHelpers.parse(<<-YAML)
      profile: p
      os:
        type: fedora
        release: 44
      jobs:
        - name: base
          steps:
            - type: packages
              name: tools
              packageManager: dnf
              packages: [git]
      YAML

    result.errors.should be_empty
    result.profile.target.release.should eq("44")
  end

  it "accepts phases as an alias for jobs and modules as an alias for steps" do
    result = ProfileHelpers.parse(<<-YAML)
      profile: legacy
      os:
        type: arch
      phases:
        - name: base
          modules:
            - type: packages
              name: tools
              packageManager: pacman
              packages: [git]
      YAML

    result.errors.should be_empty
    result.profile.jobs.map(&.name).should eq(["base"])
    result.profile.steps.size.should eq(1)
  end

  it "wraps a bare top-level module list in one implicit job" do
    result = ProfileHelpers.parse(<<-YAML)
      profile: flat
      os:
        type: arch
      modules:
        - type: packages
          name: tools
          packageManager: pacman
          packages: [git]
      YAML

    result.errors.should be_empty
    result.profile.jobs.map(&.name).should eq(["default"])
  end

  it "ignores top-level modules when jobs are present" do
    result = ProfileHelpers.parse(<<-YAML)
      profile: both
      os:
        type: arch
      jobs:
        - name: base
          steps:
            - type: packages
              name: from-jobs
              packageManager: pacman
              packages: [git]
      modules:
        - type: packages
          name: from-modules
          packageManager: pacman
          packages: [curl]
      YAML

    result.errors.should be_empty
    result.profile.steps.map(&.name).should eq(["from-jobs"])
  end

  describe "validation" do
    it "requires a profile name" do
      result = ProfileHelpers.parse("os:\n  type: fedora\njobs: []\n")
      result.error_messages.any?(&.includes?("profile is required")).should be_true
    end

    it "requires at least one job, phase, or module" do
      result = ProfileHelpers.parse("profile: p\nos:\n  type: fedora\n")
      result.error_messages.any?(&.includes?("at least one job, phase, or module")).should be_true
    end

    it "rejects an unknown OS type and lists the accepted ones" do
      result = ProfileHelpers.parse("profile: p\nos:\n  type: plan9\njobs: []\n")
      message = result.error_messages.find!(&.includes?("unsupported OS type"))
      message.should contain("plan9")
      message.should contain("fedora, arch, opensuse, debian")
    end

    it "rejects a package manager that does not match the target" do
      result = ProfileHelpers.parse(ProfileHelpers.jobs_profile(<<-STEPS, os: "debian"))
        - type: packages
          name: tools
          packageManager: dnf
          packages: [git]
        STEPS

      message = result.error_messages.find!(&.includes?("is not valid for target"))
      message.should contain("dnf")
      message.should contain("debian")
      message.should contain("expected apt")
    end

    it "accepts any AUR helper on Arch" do
      %w[pacman paru yay].each do |manager|
        result = ProfileHelpers.parse(ProfileHelpers.jobs_profile(<<-STEPS, os: "arch"))
          - type: packages
            name: tools
            packageManager: #{manager}
            packages: [git]
          STEPS
        result.errors.should be_empty
      end
    end

    it "reports an unknown job dependency" do
      result = ProfileHelpers.parse(<<-YAML)
        profile: p
        os:
          type: fedora
        jobs:
          - name: base
            dependsOn: [missing]
            steps: []
        YAML

      result.error_messages.any?(&.includes?("unknown job 'missing'")).should be_true
    end

    it "reports a dependency cycle" do
      result = ProfileHelpers.parse(<<-YAML)
        profile: p
        os:
          type: fedora
        jobs:
          - name: a
            dependsOn: [b]
            steps: []
          - name: b
            dependsOn: [a]
            steps: []
        YAML

      result.error_messages.any?(&.includes?("Circular dependency")).should be_true
    end

    it "reports duplicate job and step names" do
      result = ProfileHelpers.parse(<<-YAML)
        profile: p
        os:
          type: fedora
        jobs:
          - name: base
            steps:
              - type: packages
                name: tools
                packageManager: dnf
                packages: [git]
              - type: packages
                name: tools
                packageManager: dnf
                packages: [curl]
        YAML

      result.error_messages.any?(&.includes?("duplicate step name: tools")).should be_true
    end

    it "collects every problem in one pass" do
      result = ProfileHelpers.parse(<<-YAML)
        profile: p
        os:
          type: fedora
        jobs:
          - name: base
            steps:
              - type: packages
                name: a
                packageManager: apt
                packages: []
              - type: manual
                name: b
        YAML

      # Wrong manager, empty package list, and a missing manual message should
      # all be reported together rather than one per run.
      result.errors.size.should be >= 3
    end

    it "anchors diagnostics to the config path that caused them" do
      result = ProfileHelpers.parse(<<-YAML)
        profile: p
        os:
          type: fedora
        jobs:
          - name: base
            steps:
              - type: packages
                name: tools
                packageManager: dnf
                packages: ["bad name"]
        YAML

      diagnostic = result.errors.find!(&.message.includes?("unsafe shell characters"))
      diagnostic.path.should eq("jobs[0].steps[0].packages[0]")
    end
  end

  describe "restart policies" do
    it "defaults to none" do
      result = ProfileHelpers.parse(ProfileHelpers.jobs_profile(<<-STEPS))
        - type: manual
          name: hello
          message: hi
          probeCommand: "true"
        STEPS
      result.profile.jobs.first.restart_policy.should be_a(Fluxion::RestartPolicy::None)
    end

    it "parses prompt-logout with a custom message" do
      result = ProfileHelpers.parse(<<-YAML)
        profile: p
        os:
          type: fedora
        jobs:
          - name: base
            restartPolicy:
              type: prompt-logout
              message: "Log out, then re-run."
            steps: []
        YAML

      policy = result.profile.jobs.first.restart_policy.as(Fluxion::RestartPolicy::PromptLogout)
      policy.message.should eq("Log out, then re-run.")
      result.profile.jobs.first.halts?.should be_true
    end

    it "parses requires-new-shell" do
      result = ProfileHelpers.parse(<<-YAML)
        profile: p
        os:
          type: fedora
        jobs:
          - name: base
            restartPolicy:
              type: requires-new-shell
              shell: bash
            steps: []
        YAML

      policy = result.profile.jobs.first.restart_policy.as(Fluxion::RestartPolicy::RequiresNewShell)
      policy.shell.should eq(Fluxion::ShellKind::Bash)
    end
  end
end
