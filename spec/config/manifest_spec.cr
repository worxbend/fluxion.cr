require "../spec_helper"

private SHA = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

private def context_for(path : String) : Fluxion::Config::Context
  Fluxion::Config::Context.new(File.dirname(path), ProfileHelpers.fedora_host)
end

describe Fluxion::Config::Manifest do
  it "maps a profile into phases of steps" do
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
        phases:
          - name: base-cli
            description: The handful of things every machine needs
            steps:
              - name: core-cli
                kind: dnf-packages
                spec:
                  packages: [git, curl, ripgrep]
      YAML

    result.errors.should be_empty
    result.profile.name.should eq("developer-workstation")
    result.profile.target.distribution.should eq(Fluxion::Distribution::Fedora)
    result.profile.target.release.should eq("44")

    phase = result.profile.phases.first
    phase.name.should eq("base-cli")
    phase.description.should eq("The handful of things every machine needs")

    step = result.step("core-cli").as(Fluxion::PackagesStep)
    step.package_manager.should eq(Fluxion::PackageManager::Dnf)
    step.packages.should eq(%w[git curl ripgrep])
    step.items.map(&.key).should eq(%w[git curl ripgrep])
  end

  it "reads an unquoted release as a string" do
    result = ProfileHelpers.parse(<<-YAML, ProfileHelpers.fedora_host)
      apiVersion: initkit.io/v1alpha1
      kind: WorkstationProfile
      metadata:
        name: test
      spec:
        target:
          os:
            distribution: fedora
            release: 44
        phases:
          - name: base
            steps:
              - name: tools
                kind: dnf-packages
                spec:
                  packages: [git]
      YAML

    result.errors.should be_empty
    result.profile.target.release.should eq("44")
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
        phases:
          - name: base
            steps:
              - name: tools
                kind: apt-packages
                spec:
                  packages: [git]
      YAML

    result.errors.should be_empty
    result.profile.target.release.should eq("noble")
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
          phases: []
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
          phases: []
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
          phases: []
        YAML

      result.error_messages.any?(&.includes?("must not be blank")).should be_true
    end

    it "rejects an unsupported target distribution" do
      result = ProfileHelpers.parse(<<-YAML)
        apiVersion: initkit.io/v1alpha1
        kind: WorkstationProfile
        metadata:
          name: test
        spec:
          target:
            os:
              distribution: plan9
          phases: []
        YAML

      result.error_messages.any?(&.includes?("unsupported target OS distribution: plan9")).should be_true
    end
  end

  describe "phases" do
    it "requires at least one phase" do
      result = ProfileHelpers.parse(<<-YAML)
        apiVersion: initkit.io/v1alpha1
        kind: WorkstationProfile
        metadata:
          name: test
        spec:
          target:
            os:
              distribution: fedora
          phases: []
        YAML

      result.error_messages.any?(&.includes?("at least one phase is required")).should be_true
    end

    it "names spec.phases when a document declares nothing there" do
      # `spec.plan` is gone, so a profile written against it has to be pointed
      # at the field that replaced it rather than silently parsing as empty.
      result = ProfileHelpers.parse(<<-YAML)
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
              spec:
                packages: [git]
        YAML

      result.errors.find!(&.message.includes?("at least one phase is required")).path
        .should eq("spec.phases")
      result.profile.steps.should be_empty
    end

    it "requires at least one step in a phase" do
      result = ProfileHelpers.parse(ProfileHelpers.manifest_phases(<<-PHASES))
        - name: base
          steps: []
        PHASES

      result.error_messages.any?(&.includes?("at least one step is required")).should be_true
    end

    it "reports a duplicate phase name with the first declaration site" do
      result = ProfileHelpers.parse(ProfileHelpers.manifest_phases(<<-PHASES))
        - name: base
          steps:
            - name: tools
              kind: dnf-packages
              spec:
                packages: [git]
        - name: base
          steps:
            - name: more-tools
              kind: dnf-packages
              spec:
                packages: [curl]
        PHASES

      message = result.error_messages.find!(&.includes?("duplicates phase 'base'"))
      message.should contain("first declared at spec.phases[0].name")
    end

    it "reports a dependency on a phase that does not exist" do
      result = ProfileHelpers.parse(ProfileHelpers.manifest_phases(<<-PHASES))
        - name: base
          dependsOn: [missing]
          steps:
            - name: tools
              kind: dnf-packages
              spec:
                packages: [git]
        PHASES

      message = result.error_messages.find!(&.includes?("unknown phase 'missing'"))
      message.should contain("spec.phases[0].dependsOn")
    end

    it "reports a dependency cycle" do
      result = ProfileHelpers.parse(ProfileHelpers.manifest_phases(<<-PHASES))
        - name: a
          dependsOn: [b]
          steps:
            - name: a-tools
              kind: dnf-packages
              spec:
                packages: [git]
        - name: b
          dependsOn: [a]
          steps:
            - name: b-tools
              kind: dnf-packages
              spec:
                packages: [curl]
        PHASES

      result.error_messages.any?(&.includes?("Circular dependency")).should be_true
    end

    it "orders phases by their dependencies rather than by declaration" do
      result = ProfileHelpers.parse(ProfileHelpers.manifest_phases(<<-PHASES))
        - name: desktop
          dependsOn: [base]
          steps:
            - name: apps
              kind: dnf-packages
              spec:
                packages: [firefox]
        - name: base
          steps:
            - name: tools
              kind: dnf-packages
              spec:
                packages: [git]
        PHASES

      result.errors.should be_empty
      result.profile.phases.map(&.name).should eq(%w[desktop base])
      result.profile.ordered_phases.map(&.name).should eq(%w[base desktop])
      result.profile.phase?("desktop").not_nil!.depends_on.should eq(["base"])
    end

    it "reports a duplicate step name across phases with the first declaration site" do
      # Step names are the handle for `state forget` and `explain`, so they are
      # unique profile-wide rather than only within their phase.
      result = ProfileHelpers.parse(ProfileHelpers.manifest_phases(<<-PHASES))
        - name: base
          steps:
            - name: tools
              kind: dnf-packages
              spec:
                packages: [git]
        - name: desktop
          steps:
            - name: tools
              kind: dnf-packages
              spec:
                packages: [curl]
        PHASES

      message = result.error_messages.find!(&.includes?("duplicates step 'tools'"))
      message.should contain("first declared at spec.phases[0].steps[0].name")
    end

    it "continues past a failed step by default" do
      result = ProfileHelpers.parse(ProfileHelpers.manifest(<<-STEPS))
        - name: tools
          kind: dnf-packages
          spec:
            packages: [git]
        STEPS

      result.profile.phases.first.continue_on_step_error?.should be_true
    end

    it "lets a phase stop at its first failed step" do
      result = ProfileHelpers.parse(ProfileHelpers.manifest_phases(<<-PHASES))
        - name: base
          execution:
            continueOnError: false
          steps:
            - name: tools
              kind: dnf-packages
              spec:
                packages: [git]
        PHASES

      result.errors.should be_empty
      result.profile.phases.first.continue_on_step_error?.should be_false
    end
  end

  describe "phase conditions" do
    it "keeps a phase whose condition matches the host" do
      result = ProfileHelpers.parse(ProfileHelpers.manifest_phases(<<-PHASES), ProfileHelpers.fedora_host)
        - name: base
          when:
            distribution: fedora
          steps:
            - name: tools
              kind: dnf-packages
              spec:
                packages: [git]
        PHASES

      result.profile.steps.map(&.name).should eq(["tools"])
      result.profile.skipped_plan_entries.should be_empty
    end

    it "records every step of an unmet phase as skipped rather than dropping it" do
      # A step that vanishes from `plan` looks like it was never in the
      # profile, which is exactly the confusion skipped entries exist to avoid.
      result = ProfileHelpers.parse(ProfileHelpers.manifest_phases(<<-PHASES), ProfileHelpers.fedora_host)
        - name: arch-only
          when:
            distribution: arch
          steps:
            - name: tools
              kind: pacman-packages
              spec:
                packages: [git]
            - name: aur
              kind: aur-packages
              spec:
                packageManager: paru
                packages: [yay-bin]
        PHASES

      result.profile.steps.should be_empty
      result.profile.phases.map(&.name).should eq(["arch-only"])

      skipped = result.profile.skipped_plan_entries
      skipped.map(&.name).should eq(%w[tools aur])
      skipped.map(&.kind).should eq(%w[pacman-packages aur-packages])
      skipped.first.reason.should contain("phase arch-only when.")
      skipped.first.reason.should contain("distribution is fedora, needs arch")
    end

    it "drops the restart policy of a phase that ran nothing" do
      # There is nothing to log out of when every step was skipped.
      result = ProfileHelpers.parse(ProfileHelpers.manifest_phases(<<-PHASES), ProfileHelpers.fedora_host)
        - name: arch-only
          when:
            distribution: arch
          restartPolicy:
            type: prompt-logout
          steps:
            - name: tools
              kind: pacman-packages
              spec:
                packages: [git]
        PHASES

      result.profile.phases.first.restart_policy.should be_a(Fluxion::RestartPolicy::None)
      result.profile.phases.first.halts?.should be_false
    end
  end

  describe "restart policies" do
    it "defaults to none" do
      result = ProfileHelpers.parse(ProfileHelpers.manifest(<<-STEPS))
        - name: hello
          kind: manual
          spec:
            message: hi
            probeCommand: "true"
        STEPS

      result.profile.phases.first.restart_policy.should be_a(Fluxion::RestartPolicy::None)
    end

    it "parses prompt-logout with a custom message" do
      result = ProfileHelpers.parse(ProfileHelpers.manifest_phases(<<-PHASES))
        - name: base
          restartPolicy:
            type: prompt-logout
            message: "Log out, then re-run."
          steps:
            - name: tools
              kind: dnf-packages
              spec:
                packages: [zsh]
        PHASES

      policy = result.profile.phases.first.restart_policy.as(Fluxion::RestartPolicy::PromptLogout)
      policy.message.should eq("Log out, then re-run.")
      result.profile.phases.first.halts?.should be_true
    end

    it "parses requires-new-shell" do
      result = ProfileHelpers.parse(ProfileHelpers.manifest_phases(<<-PHASES))
        - name: base
          restartPolicy:
            type: requires-new-shell
            shell: bash
          steps:
            - name: tools
              kind: dnf-packages
              spec:
                packages: [zsh]
        PHASES

      policy = result.profile.phases.first.restart_policy.as(Fluxion::RestartPolicy::RequiresNewShell)
      policy.shell.should eq(Fluxion::ShellKind::Bash)
    end

    it "rejects an unsupported restart policy and lists the accepted ones" do
      result = ProfileHelpers.parse(ProfileHelpers.manifest_phases(<<-PHASES))
        - name: base
          restartPolicy:
            type: reboot
          steps:
            - name: tools
              kind: dnf-packages
              spec:
                packages: [zsh]
        PHASES

      message = result.error_messages.find!(&.includes?("unsupported restart policy"))
      message.should contain("prompt-logout")
    end
  end

  describe "step kinds" do
    it "suggests the closest kind for a typo" do
      result = ProfileHelpers.parse(ProfileHelpers.manifest(<<-STEPS))
        - name: core
          kind: apt-package
          spec:
            packages: [git]
        STEPS

      message = result.error_messages.find!(&.includes?("unsupported step kind"))
      message.should contain("Did you mean 'apt-packages'?")
    end

    it "offers no suggestion for something entirely unrelated" do
      result = ProfileHelpers.parse(ProfileHelpers.manifest(<<-STEPS))
        - name: core
          kind: ansible-playbook
          spec: {}
        STEPS

      message = result.error_messages.find!(&.includes?("unsupported step kind"))
      message.should_not contain("Did you mean")
    end

    it "requires a spec for installer kinds" do
      result = ProfileHelpers.parse(ProfileHelpers.manifest(<<-STEPS))
        - name: fonts
          kind: nerd-fonts
        STEPS

      result.error_messages.any?(&.includes?("spec is required for step 'fonts'")).should be_true
    end

    it "lets a control kind carry nothing but a name" do
      # Control kinds describe an interaction rather than an installation, so
      # demanding a payload from them would be demanding an empty mapping.
      result = ProfileHelpers.parse(ProfileHelpers.manifest(<<-STEPS))
        - name: reload
          kind: shell-reload
        STEPS

      result.errors.should be_empty
      result.step("reload").as(Fluxion::ShellReloadStep).shell.should eq(Fluxion::ShellKind::Zsh)
    end

    it "picks the AUR helper from the spec" do
      result = ProfileHelpers.parse(ProfileHelpers.manifest(<<-STEPS, distribution: "arch"), ProfileHelpers.arch_host)
        - name: aur
          kind: aur-packages
          spec:
            packageManager: paru
            packages: [yay-bin]
        STEPS

      result.errors.should be_empty
      result.step("aur").as(Fluxion::PackagesStep).package_manager
        .should eq(Fluxion::PackageManager::Paru)
    end

    it "rejects an unsupported AUR helper" do
      result = ProfileHelpers.parse(ProfileHelpers.manifest(<<-STEPS, distribution: "arch"), ProfileHelpers.arch_host)
        - name: aur
          kind: aur-packages
          spec:
            packageManager: pikaur
            packages: [x]
        STEPS

      result.error_messages.any?(&.includes?("unsupported AUR helper 'pikaur'")).should be_true
    end

    it "rejects a package action the manager does not have" do
      result = ProfileHelpers.parse(ProfileHelpers.manifest(<<-STEPS), ProfileHelpers.fedora_host)
        - name: core
          kind: dnf-packages
          spec:
            actions:
              - action: dist-upgrade
            packages: [git]
        STEPS

      message = result.error_messages.find!(&.includes?("unsupported action"))
      message.should contain("check-update")
    end

    it "refuses a tool package that would be read as an option" do
      # `npm install -g --force` is not an install of something called
      # "--force". The system package kinds have refused this since the check
      # was written; tool-packages and flatpak were simply never wired to it,
      # even though their names land in argv positions the same way.
      result = ProfileHelpers.parse(ProfileHelpers.manifest(<<-STEPS), ProfileHelpers.fedora_host)
        - name: tools
          kind: tool-packages
          spec:
            backend: npm-global
            packages:
              - "--force"
        STEPS

      result.error_messages.any?(&.includes?("must not be interpreted as an option")).should be_true
    end

    it "refuses a blank tool package name" do
      result = ProfileHelpers.parse(ProfileHelpers.manifest(<<-STEPS), ProfileHelpers.fedora_host)
        - name: tools
          kind: tool-packages
          spec:
            backend: npm-global
            packages:
              - ""
        STEPS

      result.error_messages.any?(&.includes?("must not be blank")).should be_true
    end

    it "still accepts the shapes real tool package names take" do
      # A scoped npm name and a go module path both contain characters the
      # check must not object to, or the guard would break legitimate profiles.
      result = ProfileHelpers.parse(ProfileHelpers.manifest(<<-STEPS), ProfileHelpers.fedora_host)
        - name: tools
          kind: tool-packages
          spec:
            backend: npm-global
            packages:
              - "@angular/cli"
              - "typescript@5.4.5"
        STEPS

      result.errors.should be_empty
    end

    it "refuses a flatpak app id that would be read as an option" do
      result = ProfileHelpers.parse(ProfileHelpers.manifest(<<-STEPS), ProfileHelpers.fedora_host)
        - name: apps
          kind: flatpak-packages
          spec:
            apps:
              - "--assumeyes"
        STEPS

      result.error_messages.any?(&.includes?("must not be interpreted as an option")).should be_true
    end

    it "accepts sdkman candidates as strings or objects" do
      result = ProfileHelpers.parse(ProfileHelpers.manifest(<<-STEPS), ProfileHelpers.fedora_host)
        - name: sdks
          kind: sdkman-packages
          spec:
            packages:
              - maven
              - candidate: java
                version: 21.0.2-tem
        STEPS

      result.errors.should be_empty
      candidates = result.step("sdks").as(Fluxion::SdkmanPackagesStep).candidates
      candidates.map(&.to_s).should eq(["maven", "java 21.0.2-tem"])
    end

    it "rejects shell metacharacters in a sdkman candidate" do
      result = ProfileHelpers.parse(ProfileHelpers.manifest(<<-STEPS), ProfileHelpers.fedora_host)
        - name: sdks
          kind: sdkman-packages
          spec:
            packages:
              - candidate: "java; rm -rf /"
        STEPS

      result.error_messages.any?(&.includes?("unsafe shell characters")).should be_true
    end

    it "rejects shell metacharacters in the shorthand candidate form too" do
      # The shorthand and the object form describe the same thing, so they must
      # be guarded the same way. `SdkmanExecutor` interpolates the candidate
      # into a script it hands to `bash -lc`, so a shorthand entry that skipped
      # the check would run whatever it contained.
      result = ProfileHelpers.parse(ProfileHelpers.manifest(<<-STEPS), ProfileHelpers.fedora_host)
        - name: sdks
          kind: sdkman-packages
          spec:
            packages:
              - "maven; rm -rf /"
        STEPS

      result.error_messages.any?(&.includes?("unsafe shell characters")).should be_true
    end

    it "reads an interrupt's resume mode and exit code" do
      result = ProfileHelpers.parse(ProfileHelpers.manifest(<<-STEPS), ProfileHelpers.fedora_host)
        - name: relogin
          kind: interrupt
          spec:
            message: Log out and back in before continuing.
            resumeFrom: current
            exitCode: 42
        STEPS

      step = result.step("relogin").as(Fluxion::InterruptStep)
      step.resume_from.should eq(Fluxion::InterruptStep::ResumeMode::Current)
      step.exit_code.should eq(42)
      step.halts?.should be_true
    end

    it "rejects an interrupt exit code outside the process range" do
      result = ProfileHelpers.parse(ProfileHelpers.manifest(<<-STEPS), ProfileHelpers.fedora_host)
        - name: relogin
          kind: interrupt
          spec:
            message: hi
            exitCode: 999
        STEPS

      result.error_messages.any?(&.includes?("between 0 and 255")).should be_true
    end

    # The kinds the `type:` frontend used to own. Each has to reach the same
    # builder it always did, otherwise deleting that frontend lost a capability.
    it "builds the kinds carried over from the deleted step frontend" do
      result = ProfileHelpers.parse(ProfileHelpers.manifest(<<-STEPS), ProfileHelpers.fedora_host)
        - name: rust
          kind: toolchain
          spec:
            kind: rustup
            installScriptUrl: https://sh.rustup.rs
            sha256: #{SHA}
        - name: omz
          kind: oh-my-zsh
          spec:
            revision: #{"a" * 40}
            sha256: #{SHA}
        - name: login-shell
          kind: default-shell
          spec:
            shell: /usr/bin/zsh
        - name: reload
          kind: shell-reload
          spec:
            shell: bash
        - name: has-git
          kind: assert
          spec:
            command: command -v git
            message: git is missing
        - name: sign-in
          kind: manual
          spec:
            message: Run gh auth login
            probeCommand: "gh auth status"
        - name: docker-repo
          kind: rpm-repository
          spec:
            id: docker
            baseUrl: https://download.docker.com/linux/fedora/stable
            gpgCheck: false
            enabled: false
        - name: flathub
          kind: flatpak-remote
          spec:
            remote: flathub
            url: https://flathub.org/repo/flathub.flatpakrepo
            checksum:
              algorithm: sha256
              value: #{SHA}
        STEPS

      result.errors.should be_empty
      result.step("rust").should be_a(Fluxion::ToolchainStep)
      result.step("omz").should be_a(Fluxion::OhMyZshStep)
      result.step("login-shell").should be_a(Fluxion::DefaultShellStep)
      result.step("reload").as(Fluxion::ShellReloadStep).shell.should eq(Fluxion::ShellKind::Bash)
      result.step("has-git").as(Fluxion::AssertStep).command.should eq("command -v git")
      result.step("sign-in").should be_a(Fluxion::ManualStep)
      result.step("docker-repo").as(Fluxion::RpmRepositoryStep).id.should eq("docker")
      result.step("flathub").as(Fluxion::FlatpakRemoteStep).remote.should eq("flathub")
    end

    it "lists every carried-over kind so nothing became unreachable" do
      %w[apt-repository rpm-repository pacman-repository flatpak-remote default-shell
        oh-my-zsh toolchain shell-reload assert manual].each do |id|
        Fluxion::Config::PlanKinds.find(id).should_not be_nil
      end
    end
  end

  describe "package managers" do
    it "rejects a package manager that does not match the target" do
      result = ProfileHelpers.parse(ProfileHelpers.manifest(<<-STEPS, distribution: "debian"))
        - name: tools
          kind: dnf-packages
          spec:
            packages: [git]
        STEPS

      diagnostic = result.errors.find!(&.message.includes?("is not valid for target"))
      diagnostic.path.should eq("spec.phases[0].steps[0].kind")
      diagnostic.to_s.should contain("dnf")
      diagnostic.to_s.should contain("debian")
      diagnostic.to_s.should contain("expected apt")
    end

    it "allows a mismatched manager when a when rule narrows the distribution" do
      # One profile bootstrapping several distributions is the pattern the
      # schema exists for: the guard says this step is for an Arch machine, so
      # checking it against the Fedora target would reject it on exactly the
      # hosts where it is the branch that runs.
      result = ProfileHelpers.parse(ProfileHelpers.manifest(<<-STEPS, distribution: "fedora"), ProfileHelpers.arch_host)
        - name: arch-tools
          kind: pacman-packages
          when:
            distribution: arch
          spec:
            packages: [git]
        STEPS

      result.error_messages.any?(&.includes?("is not valid for target")).should be_false
    end

    it "allows it when the narrowing rule sits in a oneOf branch" do
      result = ProfileHelpers.parse(ProfileHelpers.manifest(<<-STEPS, distribution: "fedora"), ProfileHelpers.arch_host)
        - name: arch-tools
          kind: pacman-packages
          when:
            oneOf:
              - distribution: arch
        STEPS

      result.error_messages.any?(&.includes?("is not valid for target")).should be_false
    end

    it "still rejects a mismatched manager when the when rule narrows something else" do
      # An architecture guard says nothing about which distribution this runs
      # on, so the target is still the best evidence available and a typo here
      # is still worth catching.
      # The host must satisfy the guard, or the step is skipped before it is
      # ever built and the check under test never runs.
      result = ProfileHelpers.parse(ProfileHelpers.manifest(<<-STEPS, distribution: "fedora"), ProfileHelpers.fedora_host)
        - name: tools
          kind: pacman-packages
          when:
            architecture: amd64
          spec:
            packages: [git]
        STEPS

      result.error_messages.any?(&.includes?("is not valid for target fedora")).should be_true
    end

    it "rejects a mismatched system-update manager too" do
      result = ProfileHelpers.parse(ProfileHelpers.manifest(<<-STEPS, distribution: "arch"), ProfileHelpers.arch_host)
        - name: update
          kind: system-update
          spec:
            packageManager: zypper
        STEPS

      result.error_messages.any?(&.includes?("is not valid for target arch")).should be_true
    end

    it "accepts pacman and either AUR helper on Arch" do
      result = ProfileHelpers.parse(ProfileHelpers.manifest(<<-STEPS, distribution: "arch"), ProfileHelpers.arch_host)
        - name: core
          kind: pacman-packages
          spec:
            packages: [git]
        - name: aur-paru
          kind: aur-packages
          spec:
            packageManager: paru
            packages: [yay-bin]
        - name: aur-yay
          kind: aur-packages
          spec:
            packageManager: yay
            packages: [paru-bin]
        STEPS

      result.errors.should be_empty
    end

    it "leaves a language manager alone, since no distribution ships it" do
      result = ProfileHelpers.parse(ProfileHelpers.manifest(<<-STEPS), ProfileHelpers.fedora_host)
        - name: crates
          kind: cargo-packages
          spec:
            packages: [ripgrep]
        STEPS

      result.errors.should be_empty
      result.step("crates").as(Fluxion::PackagesStep).package_manager
        .should eq(Fluxion::PackageManager::Cargo)
    end
  end

  describe "diagnostics" do
    it "collects every problem in one pass" do
      result = ProfileHelpers.parse(ProfileHelpers.manifest(<<-STEPS))
        - name: a
          kind: apt-packages
          spec:
            packages: []
        - name: b
          kind: manual
          spec: {}
        STEPS

      # Wrong manager, empty package list, and a missing manual message should
      # all be reported together rather than one per run.
      result.errors.size.should be >= 3
    end

    it "anchors diagnostics to the config path that caused them" do
      result = ProfileHelpers.parse(ProfileHelpers.manifest(<<-STEPS))
        - name: tools
          kind: dnf-packages
          spec:
            packages: ["bad name"]
        STEPS

      diagnostic = result.errors.find!(&.message.includes?("unsafe shell characters"))
      diagnostic.path.should eq("spec.phases[0].steps[0].spec.packages[0]")
    end
  end

  describe "when conditions" do
    it "selects a step whose distribution matches the host" do
      result = ProfileHelpers.parse(ProfileHelpers.manifest(<<-STEPS), ProfileHelpers.fedora_host)
        - name: core
          kind: dnf-packages
          when:
            distribution: fedora
          spec:
            packages: [git]
        STEPS

      result.profile.steps.map(&.name).should eq(["core"])
      result.profile.skipped_plan_entries.should be_empty
    end

    it "skips a non-matching step and records why" do
      result = ProfileHelpers.parse(ProfileHelpers.manifest(<<-STEPS), ProfileHelpers.fedora_host)
        - name: arch-only
          kind: pacman-packages
          when:
            distribution: arch
          spec:
            packages: [git]
        STEPS

      result.profile.steps.should be_empty
      skipped = result.profile.skipped_plan_entries.first
      skipped.name.should eq("arch-only")
      skipped.kind.should eq("pacman-packages")
      skipped.reason.should contain("distribution is fedora, needs arch")
    end

    it "matches any listed distribution" do
      result = ProfileHelpers.parse(ProfileHelpers.manifest(<<-STEPS), ProfileHelpers.fedora_host)
        - name: core
          kind: dnf-packages
          when:
            distribution:
              oneOf: [debian, fedora]
          spec:
            packages: [git]
        STEPS

      result.profile.steps.map(&.name).should eq(["core"])
    end

    it "rejects the reserved guard fields rather than treating them as true" do
      result = ProfileHelpers.parse(ProfileHelpers.manifest(<<-STEPS), ProfileHelpers.fedora_host)
        - name: core
          kind: dnf-packages
          when:
            expression: "1 == 1"
          spec:
            packages: [git]
        STEPS

      message = result.error_messages.find!(&.includes?("unsupported when conditions"))
      message.should contain("expression")
    end

    it "rejects a when block with no recognised matcher" do
      result = ProfileHelpers.parse(ProfileHelpers.manifest(<<-STEPS), ProfileHelpers.fedora_host)
        - name: core
          kind: dnf-packages
          when:
            nonsense: true
          spec:
            packages: [git]
        STEPS

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
            editor: neovim
          phases:
            - name: base
              steps:
                - name: tools
                  kind: dnf-packages
                  spec:
                    packages: ["${editor}"]
        YAML

      result.errors.should be_empty
      step = result.step("tools").as(Fluxion::PackagesStep)
      step.packages.should eq(["neovim"])
    end

    it "reports an unresolved variable with its config path and owning step" do
      result = ProfileHelpers.parse(ProfileHelpers.manifest(<<-STEPS), ProfileHelpers.fedora_host)
        - name: fonts
          kind: nerd-fonts
          spec:
            config:
              release: v3.4.0
              families: ["${nope}"]
        STEPS

      message = result.error_messages.find!(&.includes?("unresolved variable"))
      message.should contain("${nope}")
      message.should contain("in step 'fonts'")
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
          phases: []
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
          phases:
            - name: base
              steps:
                - name: run
                  kind: commands
                  spec:
                    commands:
                      - "ls ${target}"
        YAML

      message = result.error_messages.find!(&.includes?("shell expression"))
      message.should contain("pass data through env")
    end

    it "refuses to interpolate into a probe command" do
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
            tool: git
          phases:
            - name: base
              steps:
                - name: core
                  kind: dnf-packages
                  spec:
                    probeCommand: "command -v ${tool}"
                    packages: [git]
        YAML

      result.error_messages.any?(&.includes?("shell expression")).should be_true
    end

    it "leaves non-braced shell syntax alone" do
      result = ProfileHelpers.parse(ProfileHelpers.manifest(<<-STEPS), ProfileHelpers.fedora_host)
        - name: run
          kind: commands
          spec:
            commands:
              - "echo $HOME and $(date)"
        STEPS

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
          phases:
            - name: base
              steps:
                - name: core
                  kind: dnf-packages
                  spec:
                    packages: [git]
        YAML

      result.errors.should be_empty
      result.profile.source_setups.size.should eq(1)
      result.profile.source_setups.first.package_manager.should eq(Fluxion::PackageManager::Dnf)
    end

    it "reports a source section no selected step needs" do
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
          phases:
            - name: base
              steps:
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
    it "carries profile-wide execution defaults" do
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
          phases:
            - name: base
              steps:
                - name: core
                  kind: dnf-packages
                  spec:
                    packages: [git]
        YAML

      result.profile.policy.dry_run.should be_true
      result.profile.policy.continue_on_error.should be_false
      result.profile.policy.require_sudo.should be_nil
    end

    it "lets a step override continueOnError" do
      result = ProfileHelpers.parse(ProfileHelpers.manifest(<<-STEPS), ProfileHelpers.fedora_host)
        - name: core
          kind: dnf-packages
          execution:
            continueOnError: false
          spec:
            packages: [git]
        STEPS

      result.step("core").continue_on_error?.should be_false
    end
  end
end

describe Fluxion::Config::Loader do
  it "refuses a document with no profile header" do
    ProfileHelpers.with_profile("something: else\n") do |path|
      document = Fluxion::Config::Loader.read(path)
      expect_raises(Fluxion::ConfigError, /missing profile header/) do
        Fluxion::Config::Loader.parse(context_for(path), document, path)
      end
    end
  end

  it "names the header it expected" do
    ProfileHelpers.with_profile("profile: p\nos:\n  type: arch\n") do |path|
      document = Fluxion::Config::Loader.read(path)
      error = expect_raises(Fluxion::ConfigError) do
        Fluxion::Config::Loader.parse(context_for(path), document, path)
      end
      error.message.not_nil!.should contain("apiVersion: initkit.io/v1alpha1")
      error.message.not_nil!.should contain("kind: WorkstationProfile")
    end
  end

  it "refuses an empty config" do
    ProfileHelpers.with_profile("") do |path|
      document = Fluxion::Config::Loader.read(path)
      expect_raises(Fluxion::ConfigError, /config file is empty/) do
        Fluxion::Config::Loader.parse(context_for(path), document, path)
      end
    end
  end

  it "refuses a config root that is not a mapping" do
    ProfileHelpers.with_profile("- a\n- b\n") do |path|
      document = Fluxion::Config::Loader.read(path)
      expect_raises(Fluxion::ConfigError, /must be a YAML mapping/) do
        Fluxion::Config::Loader.parse(context_for(path), document, path)
      end
    end
  end

  it "reports a missing file without a stack trace's worth of noise" do
    expect_raises(Fluxion::ConfigError, /File does not exist/) do
      Fluxion::Config::Loader.read("/definitely/missing/fluxion.yaml")
    end
  end
end
