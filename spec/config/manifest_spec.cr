require "../spec_helper"

describe Fluxion::Config::Manifest do
  it "maps a manifest into a single ordered job" do
    result = ProfileHelpers.parse(<<-YAML, ProfileHelpers.fedora_host)
      apiVersion: initkit.io/v1alpha1
      kind: WorkstationProfile
      metadata:
        name: developer-workstation
      spec:
        target:
          os:
            distribution: fedora
            release: "44"
        plan:
          - name: core-cli
            kind: dnf-packages
            spec:
              packages: [git, curl, ripgrep]
      YAML

    result.errors.should be_empty
    result.profile.name.should eq("developer-workstation")
    result.profile.manifest?.should be_true
    result.profile.jobs.first.name.should eq("manifest-plan")
    result.profile.jobs.first.continue_on_step_error?.should be_false

    step = result.step("core-cli").as(Fluxion::PackagesStep)
    step.package_manager.should eq(Fluxion::PackageManager::Dnf)
    step.packages.should eq(%w[git curl ripgrep])
  end

  describe "header" do
    it "rejects an unknown apiVersion" do
      result = ProfileHelpers.parse(<<-YAML)
        apiVersion: bad-version
        kind: WorkstationProfile
        metadata:
          name: test
        spec:
          target:
            os:
              distribution: fedora
          plan: []
        YAML

      message = result.error_messages.find!(&.includes?("apiVersion"))
      message.should contain("must be 'initkit.io/v1alpha1' but was 'bad-version'")
    end

    it "rejects an unknown kind" do
      result = ProfileHelpers.parse(<<-YAML)
        apiVersion: initkit.io/v1alpha1
        kind: WrongKind
        metadata:
          name: test
        spec:
          target:
            os:
              distribution: fedora
          plan: []
        YAML

      result.error_messages.any?(&.includes?("must be 'WorkstationProfile' but was 'WrongKind'")).should be_true
    end

    it "requires a metadata name" do
      result = ProfileHelpers.parse(<<-YAML)
        apiVersion: initkit.io/v1alpha1
        kind: WorkstationProfile
        metadata: {}
        spec:
          target:
            os:
              distribution: fedora
          plan: []
        YAML

      result.error_messages.any?(&.includes?("must not be blank")).should be_true
    end
  end

  describe "plan kinds" do
    it "suggests the closest kind for a typo" do
      result = ProfileHelpers.parse(ProfileHelpers.manifest(<<-PLAN))
        - name: core
          kind: apt-package
          spec:
            packages: [git]
        PLAN

      message = result.error_messages.find!(&.includes?("unsupported plan kind"))
      message.should contain("Did you mean 'apt-packages'?")
    end

    it "reports a duplicate entry name with the first declaration site" do
      result = ProfileHelpers.parse(ProfileHelpers.manifest(<<-PLAN))
        - name: duplicate
          kind: dnf-packages
          spec:
            packages: [git]
        - name: duplicate
          kind: dnf-packages
          spec:
            packages: [curl]
        PLAN

      message = result.error_messages.find!(&.includes?("duplicates plan entry"))
      message.should contain("first declared at spec.plan[0].name")
    end

    it "requires a spec for installer kinds" do
      result = ProfileHelpers.parse(ProfileHelpers.manifest(<<-PLAN))
        - name: fonts
          kind: nerd-fonts
        PLAN

      result.error_messages.any?(&.includes?("spec is required for plan entry 'fonts'")).should be_true
    end

    it "picks the AUR helper from the spec" do
      result = ProfileHelpers.parse(ProfileHelpers.manifest(<<-PLAN, distribution: "arch"), ProfileHelpers.arch_host)
        - name: aur
          kind: aur-packages
          spec:
            packageManager: paru
            packages: [yay-bin]
        PLAN

      result.errors.should be_empty
      result.step("aur").as(Fluxion::PackagesStep).package_manager
        .should eq(Fluxion::PackageManager::Paru)
    end

    it "rejects an unsupported AUR helper" do
      result = ProfileHelpers.parse(ProfileHelpers.manifest(<<-PLAN, distribution: "arch"), ProfileHelpers.arch_host)
        - name: aur
          kind: aur-packages
          spec:
            packageManager: pikaur
            packages: [x]
        PLAN

      result.error_messages.any?(&.includes?("unsupported AUR helper 'pikaur'")).should be_true
    end

    it "rejects a package action the manager does not have" do
      result = ProfileHelpers.parse(ProfileHelpers.manifest(<<-PLAN), ProfileHelpers.fedora_host)
        - name: core
          kind: dnf-packages
          spec:
            actions:
              - action: dist-upgrade
            packages: [git]
        PLAN

      message = result.error_messages.find!(&.includes?("unsupported action"))
      message.should contain("check-update")
    end

    it "accepts sdkman candidates as strings or objects" do
      result = ProfileHelpers.parse(ProfileHelpers.manifest(<<-PLAN), ProfileHelpers.fedora_host)
        - name: sdks
          kind: sdkman-packages
          spec:
            packages:
              - maven
              - candidate: java
                version: 21.0.2-tem
        PLAN

      result.errors.should be_empty
      candidates = result.step("sdks").as(Fluxion::SdkmanPackagesStep).candidates
      candidates.map(&.to_s).should eq(["maven", "java 21.0.2-tem"])
    end

    it "rejects shell metacharacters in a sdkman candidate" do
      result = ProfileHelpers.parse(ProfileHelpers.manifest(<<-PLAN), ProfileHelpers.fedora_host)
        - name: sdks
          kind: sdkman-packages
          spec:
            packages:
              - candidate: "java; rm -rf /"
        PLAN

      result.error_messages.any?(&.includes?("unsafe shell characters")).should be_true
    end

    it "reads an interrupt's resume mode and exit code" do
      result = ProfileHelpers.parse(ProfileHelpers.manifest(<<-PLAN), ProfileHelpers.fedora_host)
        - name: relogin
          kind: interrupt
          spec:
            message: Log out and back in before continuing.
            resumeFrom: current
            exitCode: 42
        PLAN

      step = result.step("relogin").as(Fluxion::InterruptStep)
      step.resume_from.should eq(Fluxion::InterruptStep::ResumeMode::Current)
      step.exit_code.should eq(42)
      step.halts?.should be_true
    end

    it "rejects an interrupt exit code outside the process range" do
      result = ProfileHelpers.parse(ProfileHelpers.manifest(<<-PLAN), ProfileHelpers.fedora_host)
        - name: relogin
          kind: interrupt
          spec:
            message: hi
            exitCode: 999
        PLAN

      result.error_messages.any?(&.includes?("between 0 and 255")).should be_true
    end
  end

  describe "when conditions" do
    it "selects an entry whose distribution matches the host" do
      result = ProfileHelpers.parse(ProfileHelpers.manifest(<<-PLAN), ProfileHelpers.fedora_host)
        - name: core
          kind: dnf-packages
          when:
            distribution: fedora
          spec:
            packages: [git]
        PLAN

      result.profile.steps.map(&.name).should eq(["core"])
      result.profile.skipped_plan_entries.should be_empty
    end

    it "skips a non-matching entry and records why" do
      result = ProfileHelpers.parse(ProfileHelpers.manifest(<<-PLAN), ProfileHelpers.fedora_host)
        - name: arch-only
          kind: pacman-packages
          when:
            distribution: arch
          spec:
            packages: [git]
        PLAN

      result.profile.steps.should be_empty
      skipped = result.profile.skipped_plan_entries.first
      skipped.name.should eq("arch-only")
      skipped.kind.should eq("pacman-packages")
      skipped.reason.should contain("distribution is fedora, needs arch")
    end

    it "matches any listed distribution" do
      result = ProfileHelpers.parse(ProfileHelpers.manifest(<<-PLAN), ProfileHelpers.fedora_host)
        - name: core
          kind: dnf-packages
          when:
            distribution:
              oneOf: [debian, fedora]
          spec:
            packages: [git]
        PLAN

      result.profile.steps.map(&.name).should eq(["core"])
    end

    it "rejects the reserved guard fields rather than treating them as true" do
      result = ProfileHelpers.parse(ProfileHelpers.manifest(<<-PLAN), ProfileHelpers.fedora_host)
        - name: core
          kind: dnf-packages
          when:
            expression: "1 == 1"
          spec:
            packages: [git]
        PLAN

      message = result.error_messages.find!(&.includes?("unsupported when conditions"))
      message.should contain("expression")
    end

    it "rejects a when block with no recognised matcher" do
      result = ProfileHelpers.parse(ProfileHelpers.manifest(<<-PLAN), ProfileHelpers.fedora_host)
        - name: core
          kind: dnf-packages
          when:
            nonsense: true
          spec:
            packages: [git]
        PLAN

      result.error_messages.any?(&.includes?("no supported matcher")).should be_true
    end
  end

  describe "variables" do
    it "interpolates spec.vars into string fields" do
      result = ProfileHelpers.parse(<<-YAML, ProfileHelpers.fedora_host)
        apiVersion: initkit.io/v1alpha1
        kind: WorkstationProfile
        metadata:
          name: test
        spec:
          target:
            os:
              distribution: fedora
          vars:
            fontFamily: JetBrainsMono
          plan:
            - name: fonts
              kind: nerd-fonts
              spec:
                config:
                  release: v3.4.0
                  families: ["${fontFamily}"]
        YAML

      result.errors.should be_empty
      config = result.step("fonts").as(Fluxion::NerdFontsStep).config.not_nil!
      config.families.should eq(["JetBrainsMono"])
    end

    it "reports an unresolved variable with its config path" do
      result = ProfileHelpers.parse(ProfileHelpers.manifest(<<-PLAN), ProfileHelpers.fedora_host)
        - name: fonts
          kind: nerd-fonts
          spec:
            config:
              release: v3.4.0
              families: ["${nope}"]
        PLAN

      message = result.error_messages.find!(&.includes?("unresolved variable"))
      message.should contain("${nope}")
      message.should contain("in plan entry 'fonts'")
    end

    it "reports a cyclic variable reference" do
      result = ProfileHelpers.parse(<<-YAML, ProfileHelpers.fedora_host)
        apiVersion: initkit.io/v1alpha1
        kind: WorkstationProfile
        metadata:
          name: test
        spec:
          target:
            os:
              distribution: fedora
          vars:
            a: "${b}"
            b: "${a}"
          plan: []
        YAML

      result.error_messages.any?(&.includes?("cyclic variable reference")).should be_true
    end

    it "refuses to interpolate into a shell expression" do
      result = ProfileHelpers.parse(<<-YAML, ProfileHelpers.fedora_host)
        apiVersion: initkit.io/v1alpha1
        kind: WorkstationProfile
        metadata:
          name: test
        spec:
          target:
            os:
              distribution: fedora
          vars:
            target: /tmp
          plan:
            - name: run
              kind: commands
              spec:
                commands:
                  - "ls ${target}"
        YAML

      message = result.error_messages.find!(&.includes?("shell expression"))
      message.should contain("pass data through env")
    end

    it "leaves non-braced shell syntax alone" do
      result = ProfileHelpers.parse(ProfileHelpers.manifest(<<-PLAN), ProfileHelpers.fedora_host)
        - name: run
          kind: commands
          spec:
            commands:
              - "echo $HOME and $(date)"
        PLAN

      result.errors.should be_empty
      command = result.step("run").as(Fluxion::ShellCommandStep).commands.first
      command.shell_command.should eq("echo $HOME and $(date)")
    end
  end

  describe "sources" do
    it "maps a source section whose package manager is in use" do
      result = ProfileHelpers.parse(<<-YAML, ProfileHelpers.fedora_host)
        apiVersion: initkit.io/v1alpha1
        kind: WorkstationProfile
        metadata:
          name: test
        spec:
          target:
            os:
              distribution: fedora
          sources:
            dnf:
              - name: docker
                kind: rpm-repository
                spec:
                  id: docker
                  baseUrl: https://download.docker.com/linux/fedora/stable
                  gpgCheck: false
                  enabled: false
          plan:
            - name: core
              kind: dnf-packages
              spec:
                packages: [git]
        YAML

      result.errors.should be_empty
      result.profile.source_setups.size.should eq(1)
      result.profile.source_setups.first.package_manager.should eq(Fluxion::PackageManager::Dnf)
    end

    it "reports a source section no selected entry needs" do
      result = ProfileHelpers.parse(<<-YAML, ProfileHelpers.fedora_host)
        apiVersion: initkit.io/v1alpha1
        kind: WorkstationProfile
        metadata:
          name: test
        spec:
          target:
            os:
              distribution: fedora
          sources:
            apt:
              - name: docker
                kind: apt-repository
                spec:
                  source: "deb https://download.docker.com/linux/debian bookworm stable"
          plan:
            - name: core
              kind: dnf-packages
              spec:
                packages: [git]
        YAML

      result.profile.source_setups.should be_empty
      skipped = result.profile.skipped_plan_entries.first
      skipped.kind.should eq("apt-source")
      skipped.reason.should contain("not relevant to selected host package managers")
    end
  end

  describe "policy" do
    it "carries manifest execution defaults" do
      result = ProfileHelpers.parse(<<-YAML, ProfileHelpers.fedora_host)
        apiVersion: initkit.io/v1alpha1
        kind: WorkstationProfile
        metadata:
          name: test
        spec:
          target:
            os:
              distribution: fedora
          policy:
            dryRun: true
            continueOnError: false
          plan: []
        YAML

      result.profile.policy.dry_run.should be_true
      result.profile.policy.continue_on_error.should be_false
      result.profile.policy.require_sudo.should be_nil
    end

    it "lets a plan entry override continueOnError" do
      result = ProfileHelpers.parse(<<-YAML, ProfileHelpers.fedora_host)
        apiVersion: initkit.io/v1alpha1
        kind: WorkstationProfile
        metadata:
          name: test
        spec:
          target:
            os:
              distribution: fedora
          plan:
            - name: core
              kind: dnf-packages
              execution:
                continueOnError: false
              spec:
                packages: [git]
        YAML

      result.step("core").continue_on_error?.should be_false
    end
  end

  it "prefers the codename for a Debian target" do
    result = ProfileHelpers.parse(<<-YAML)
      apiVersion: initkit.io/v1alpha1
      kind: WorkstationProfile
      metadata:
        name: test
      spec:
        target:
          os:
            distribution: ubuntu
            codename: noble
            release: "24.04"
        plan: []
      YAML

    result.profile.target.release.should eq("noble")
  end
end

describe Fluxion::Config::Loader do
  it "detects the manifest frontend from apiVersion" do
    ProfileHelpers.with_profile("apiVersion: x\nkind: y\n") do |path|
      document = Fluxion::Config::Loader.read(path)
      Fluxion::Config::Loader.detect(Fluxion::Config::Node.root(document))
        .should eq(Fluxion::Config::Loader::Schema::WorkstationProfile)
    end
  end

  it "detects the stable frontend from profile" do
    ProfileHelpers.with_profile("profile: p\nos:\n  type: arch\n") do |path|
      document = Fluxion::Config::Loader.read(path)
      Fluxion::Config::Loader.detect(Fluxion::Config::Node.root(document))
        .should eq(Fluxion::Config::Loader::Schema::JobsSteps)
    end
  end

  it "explains what it expected when neither frontend is recognisable" do
    ProfileHelpers.with_profile("something: else\n") do |path|
      document = Fluxion::Config::Loader.read(path)
      expect_raises(Fluxion::ConfigError, /unknown config schema/) do
        Fluxion::Config::Loader.detect(Fluxion::Config::Node.root(document), path)
      end
    end
  end

  it "refuses an empty config" do
    ProfileHelpers.with_profile("") do |path|
      document = Fluxion::Config::Loader.read(path)
      expect_raises(Fluxion::ConfigError, /config file is empty/) do
        Fluxion::Config::Loader.detect(Fluxion::Config::Node.root(document), path)
      end
    end
  end

  it "refuses a config root that is not a mapping" do
    ProfileHelpers.with_profile("- a\n- b\n") do |path|
      document = Fluxion::Config::Loader.read(path)
      expect_raises(Fluxion::ConfigError, /must be a YAML mapping/) do
        Fluxion::Config::Loader.detect(Fluxion::Config::Node.root(document), path)
      end
    end
  end

  it "reports a missing file without a stack trace's worth of noise" do
    expect_raises(Fluxion::ConfigError, /File does not exist/) do
      Fluxion::Config::Loader.read("/definitely/missing/fluxion.yaml")
    end
  end
end
