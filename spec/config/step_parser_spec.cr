require "../spec_helper"

private SHA = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

private def parse_step(yaml : String, os : String = "fedora")
  ProfileHelpers.parse(ProfileHelpers.jobs_profile(yaml, os))
end

describe Fluxion::Config::StepParser do
  describe "unknown kinds" do
    it "suggests the closest supported type" do
      result = parse_step("- type: package\n  name: x\n")
      message = result.error_messages.find!(&.includes?("unsupported step type"))
      message.should contain("Did you mean 'packages'?")
    end

    it "offers no suggestion for something entirely unrelated" do
      result = parse_step("- type: ansible-playbook\n  name: x\n")
      message = result.error_messages.find!(&.includes?("unsupported step type"))
      message.should_not contain("Did you mean")
    end
  end

  describe "compiled-binary trust" do
    it "accepts a literal checksum" do
      result = parse_step(<<-STEP)
        - type: compiled-binary
          name: kubectl
          binaryName: kubectl
          url: https://dl.k8s.io/release/v1.30.2/bin/linux/amd64/kubectl
          checksum:
            algorithm: sha256
            value: #{SHA}
          installPath: /usr/local/bin/kubectl
        STEP

      result.errors.should be_empty
      step = result.step("kubectl").as(Fluxion::CompiledBinaryStep)
      step.trust.should be_a(Fluxion::TrustAnchor::Digest)
      step.format.should eq(Fluxion::ArtifactFormat::PlainBinary)
    end

    it "accepts a signer-bound detached signature" do
      result = parse_step(<<-STEP)
        - type: compiled-binary
          name: nvim
          binaryName: nvim
          url: https://example.test/nvim
          signatureUrl: https://example.test/nvim.asc
          allowedSignerFingerprint: BC528686B50D79E339D3721CEB3E94ADBE1229CF
          installPath: /usr/local/bin/nvim
        STEP

      result.errors.should be_empty
      result.step("nvim").as(Fluxion::CompiledBinaryStep).trust
        .should be_a(Fluxion::TrustAnchor::Signature)
    end

    it "refuses a download with no trust anchor at all" do
      result = parse_step(<<-STEP)
        - type: compiled-binary
          name: nvim
          binaryName: nvim
          url: https://example.test/nvim
          installPath: /usr/local/bin/nvim
        STEP

      message = result.error_messages.find!(&.includes?("must declare a literal SHA-256"))
      message.should contain("checksumUrl is supplemental metadata")
    end

    it "refuses a checksum URL standing in for a checksum" do
      result = parse_step(<<-STEP)
        - type: compiled-binary
          name: nvim
          binaryName: nvim
          url: https://example.test/nvim
          checksumUrl: https://example.test/checksums.txt
          installPath: /usr/local/bin/nvim
        STEP

      result.error_messages.any?(&.includes?("must declare a literal SHA-256")).should be_true
    end

    it "refuses a signature without a signer" do
      result = parse_step(<<-STEP)
        - type: compiled-binary
          name: nvim
          binaryName: nvim
          url: https://example.test/nvim
          signatureUrl: https://example.test/nvim.asc
          installPath: /usr/local/bin/nvim
        STEP

      result.error_messages.any?(&.includes?("must be configured together")).should be_true
    end

    it "rejects a plain-HTTP artifact URL" do
      result = parse_step(<<-STEP)
        - type: compiled-binary
          name: nvim
          binaryName: nvim
          url: http://example.test/nvim
          checksum:
            algorithm: sha256
            value: #{SHA}
          installPath: /usr/local/bin/nvim
        STEP

      result.error_messages.any?(&.includes?("must use https")).should be_true
    end

    it "rejects credentials embedded in the URL" do
      result = parse_step(<<-STEP)
        - type: compiled-binary
          name: nvim
          binaryName: nvim
          url: https://user:pw@example.test/nvim
          checksum:
            algorithm: sha256
            value: #{SHA}
          installPath: /usr/local/bin/nvim
        STEP

      result.error_messages.any?(&.includes?("must not include user-info")).should be_true
    end

    it "requires an archive member path for archive URLs" do
      result = parse_step(<<-STEP)
        - type: compiled-binary
          name: rg
          binaryName: rg
          url: https://example.test/ripgrep.tar.gz
          checksum:
            algorithm: sha256
            value: #{SHA}
          installPath: /usr/local/bin/rg
        STEP

      message = result.error_messages.find!(&.includes?("archivePath"))
      message.should contain("never guesses by basename")
    end

    it "refuses delegation when stripComponents would change the selection" do
      result = parse_step(<<-STEP)
        - type: compiled-binary
          name: rg
          binaryName: rg
          url: https://example.test/ripgrep.zip
          archivePath: ripgrep/rg
          stripComponents: 1
          checksum:
            algorithm: sha256
            value: #{SHA}
          installPath: /usr/local/bin/rg
        STEP

      result.error_messages.any?(&.includes?("no stripComponents equivalent")).should be_true
    end

    it "rejects an install path the symlink would shadow" do
      result = parse_step(<<-STEP)
        - type: compiled-binary
          name: nvim
          binaryName: nvim
          url: https://example.test/nvim
          checksum:
            algorithm: sha256
            value: #{SHA}
          installPath: /usr/local/bin/nvim
          symlinkPath: /usr/local/bin/nvim
        STEP

      result.error_messages.any?(&.includes?("must differ from install path")).should be_true
    end

    it "requires an absolute install path" do
      result = parse_step(<<-STEP)
        - type: compiled-binary
          name: nvim
          binaryName: nvim
          url: https://example.test/nvim
          checksum:
            algorithm: sha256
            value: #{SHA}
          installPath: bin/nvim
        STEP

      result.error_messages.any?(&.includes?("must be absolute")).should be_true
    end
  end

  describe "repository kinds" do
    it "requires a key URL and its checksum together" do
      result = parse_step(<<-STEP)
        - type: rpm-repository
          name: docker
          baseUrl: https://download.docker.com/linux/fedora/stable
          gpgKeyUrl: https://download.docker.com/linux/fedora/gpg
        STEP

      message = result.error_messages.find!(&.includes?("configured together"))
      message.should contain("the digest is what makes the key trustworthy")
    end

    it "refuses an enabled repository that disables gpgCheck" do
      result = parse_step(<<-STEP)
        - type: rpm-repository
          name: docker
          baseUrl: https://download.docker.com/linux/fedora/stable
          enabled: true
          gpgCheck: false
        STEP

      result.error_messages.any?(&.includes?("must enforce gpgCheck")).should be_true
    end

    it "confines the repo file to the manager's directory" do
      result = parse_step(<<-STEP)
        - type: rpm-repository
          name: docker
          baseUrl: https://download.docker.com/linux/fedora/stable
          repoFile: /tmp/docker.repo
          gpgCheck: false
          enabled: false
        STEP

      result.error_messages.any?(&.includes?("/etc/yum.repos.d")).should be_true
    end

    it "rejects an APT source option that bypasses verification" do
      result = parse_step(<<-STEP, os: "debian")
        - type: apt-repository
          name: docker
          source: "deb [trusted=yes] https://download.docker.com/linux/debian bookworm stable"
        STEP

      result.error_messages.any?(&.includes?("option is not allowed: trusted")).should be_true
    end

    it "rejects an APT source whose signed-by disagrees with the keyring" do
      result = parse_step(<<-STEP, os: "debian")
        - type: apt-repository
          name: docker
          source: "deb [arch=amd64 signed-by=/etc/apt/keyrings/other.gpg] https://download.docker.com/linux/debian bookworm stable"
          keyring: /etc/apt/keyrings/docker.gpg
          signingKeyUrl: https://download.docker.com/linux/debian/gpg
          checksum:
            algorithm: sha256
            value: #{SHA}
        STEP

      result.error_messages.any?(&.includes?("signed-by option must match")).should be_true
    end

    it "requires a checksum for a Flatpak descriptor" do
      result = parse_step(<<-STEP)
        - type: flatpak-remote
          name: flathub
          remote: flathub
          url: https://flathub.org/repo/flathub.flatpakrepo
        STEP

      result.error_messages.any?(&.includes?("required for the Flatpak repository descriptor")).should be_true
    end

    it "requires a signed and trusted SigLevel on an enabled pacman repository" do
      result = parse_step(<<-STEP, os: "arch")
        - type: pacman-repository
          name: chaotic-aur
          server: https://cdn-mirror.chaotic.cx/chaotic-aur/x86_64
          sigLevel: Optional TrustAll
        STEP

      result.error_messages.any?(&.includes?("signed, trusted packages and databases")).should be_true
    end

    it "accepts Required TrustedOnly" do
      result = parse_step(<<-STEP, os: "arch")
        - type: pacman-repository
          name: chaotic-aur
          server: https://cdn-mirror.chaotic.cx/chaotic-aur/x86_64
          sigLevel: Required TrustedOnly
        STEP

      result.errors.should be_empty
    end

    it "tracks package and database trust independently" do
      # Databases are left at the default, so this must still be refused.
      result = parse_step(<<-STEP, os: "arch")
        - type: pacman-repository
          name: chaotic-aur
          server: https://cdn-mirror.chaotic.cx/chaotic-aur/x86_64
          sigLevel: PackageRequired PackageTrustedOnly
        STEP

      result.error_messages.any?(&.includes?("signed, trusted packages and databases")).should be_true
    end

    it "requires a full fingerprint for every imported key" do
      result = parse_step(<<-STEP)
        - type: gpg-key
          name: keys
          keys:
            - url: https://packages.microsoft.com/keys/microsoft.asc
              fingerprint: BE1229CF
        STEP

      result.error_messages.any?(&.includes?("fingerprint")).should be_true
    end
  end

  describe "shell kinds" do
    it "requires exactly one of script or url" do
      result = parse_step("- type: shell-script\n  name: setup\n")
      result.error_messages.any?(&.includes?("exactly one of script or url")).should be_true
    end

    it "requires a digest for a remote script" do
      result = parse_step(<<-STEP)
        - type: shell-script
          name: setup
          url: https://example.org/install.sh
        STEP

      message = result.error_messages.find!(&.includes?("required for a remote script"))
      message.should contain("verifies the digest before executing")
    end

    it "refuses a digest on a local script" do
      ProfileHelpers.with_profile("echo hi\n", "setup.sh") do |script|
        result = ProfileHelpers.parse(ProfileHelpers.jobs_profile(<<-STEP))
          - type: shell-script
            name: setup
            script: #{script}
            sha256: #{SHA}
          STEP

        result.error_messages.any?(&.includes?("only valid for a remote URL")).should be_true
      end
    end

    it "keeps a shell string and a direct argv distinct" do
      result = parse_step(<<-STEP)
        - type: shell-command
          name: git-defaults
          commands:
            - "git config --global init.defaultBranch main"
            - argv: [git, config, --global, pull.rebase, "false"]
        STEP

      result.errors.should be_empty
      commands = result.step("git-defaults").as(Fluxion::ShellCommandStep).commands
      commands[0].direct?.should be_false
      commands[0].command.should eq(["/bin/bash", "-lc", "git config --global init.defaultBranch main"])
      commands[1].direct?.should be_true
      commands[1].command.should eq(["git", "config", "--global", "pull.rebase", "false"])
    end

    it "treats an empty allowedExitCodes list as the default" do
      result = parse_step(<<-STEP)
        - type: shell-command
          name: c
          commands:
            - run: "true"
              allowedExitCodes: []
        STEP

      result.step("c").as(Fluxion::ShellCommandStep).commands.first.allowed_exit_codes.should eq([0])
    end

    it "infers sensitivity from the environment variable name" do
      result = parse_step(<<-STEP)
        - type: shell-command
          name: c
          commands:
            - run: "true"
              env:
                GITHUB_TOKEN: abc
                EDITOR: vim
        STEP

      env = result.step("c").as(Fluxion::ShellCommandStep).commands.first.environment
      env.find! { |v| v.name == "GITHUB_TOKEN" }.sensitive?.should be_true
      env.find! { |v| v.name == "EDITOR" }.sensitive?.should be_false
    end

    it "warns about a manual step with no probe" do
      result = parse_step("- type: manual\n  name: login\n  message: 'Run gh auth login'\n")
      result.errors.should be_empty
      result.warnings.any?(&.message.includes?("can never be marked complete")).should be_true
    end
  end

  describe "system kinds" do
    it "rejects group-removal syntax" do
      result = parse_step("- type: user-groups\n  name: g\n  groups: ['-docker']\n")
      message = result.error_messages.find!(&.includes?("append-only"))
      message.should contain("gpasswd -d")
    end

    it "rejects a bare git config key" do
      result = parse_step(<<-STEP)
        - type: git-config
          name: identity
          entries:
            email: me@example.test
        STEP

      result.error_messages.any?(&.includes?("section.key")).should be_true
    end

    it "requires an immutable commit for a cloned repo" do
      result = parse_step(<<-STEP)
        - type: git-repo
          name: plugins
          repos:
            - url: https://github.com/tmux-plugins/tpm.git
              dest: ~/.tmux/plugins/tpm
              ref: main
        STEP

      message = result.error_messages.find!(&.includes?("40-hex commit"))
      message.should contain("can move")
    end

    it "rejects a repo URL carrying query data" do
      result = parse_step(<<-STEP)
        - type: git-repo
          name: plugins
          repos:
            - url: https://github.com/a/b.git?token=1
              dest: ~/x
              ref: #{"a" * 40}
        STEP

      result.error_messages.any?(&.includes?("query or fragment")).should be_true
    end

    it "refuses a unit that is both masked and enabled" do
      result = parse_step(<<-STEP)
        - type: systemd-unit
          name: services
          units:
            - name: sshd
              enabled: true
              mask: true
        STEP

      result.error_messages.any?(&.includes?("cannot both mask and enable")).should be_true
    end

    it "appends .service to a bare unit name" do
      result = parse_step(<<-STEP)
        - type: systemd-unit
          name: services
          units:
            - docker
        STEP

      result.step("services").as(Fluxion::SystemdUnitStep).units.first.qualified_name
        .should eq("docker.service")
    end

    it "refuses a system-setting step that sets nothing" do
      result = parse_step("- type: system-setting\n  name: s\n")
      result.error_messages.any?(&.includes?("declares no system setting")).should be_true
    end

    it "orders system-setting items predictably" do
      result = parse_step(<<-STEP)
        - type: system-setting
          name: s
          hostname: workstation
          ntp: true
          locale:
            LC_ALL: C
            LANG: en_US.UTF-8
        STEP

      result.step("s").as(Fluxion::SystemSettingStep).item_keys
        .should eq(["ntp", "hostname", "locale:LANG", "locale:LC_ALL"])
    end

    it "refuses distUpgrade together with refreshOnly" do
      result = parse_step(<<-STEP)
        - type: system-update
          name: u
          packageManager: dnf
          distUpgrade: true
          refreshOnly: true
        STEP

      result.error_messages.any?(&.includes?("cannot be both distUpgrade and refreshOnly")).should be_true
    end

    it "parses an ISO-8601 timeout" do
      result = parse_step(<<-STEP)
        - type: system-update
          name: u
          packageManager: dnf
          timeout: PT2H
        STEP

      result.step("u").as(Fluxion::SystemUpdateStep).timeout.should eq(2.hours)
    end

    it "parses a compact timeout" do
      result = parse_step(<<-STEP)
        - type: system-update
          name: u
          packageManager: dnf
          timeout: 30m
        STEP

      result.step("u").as(Fluxion::SystemUpdateStep).timeout.should eq(30.minutes)
    end
  end

  describe "pinned installers" do
    it "requires an exact Nerd Fonts release" do
      result = parse_step(<<-STEP)
        - type: nerd-fonts
          name: fonts
          config:
            release: latest
            families: [JetBrainsMono]
        STEP

      message = result.error_messages.find!(&.includes?("exact release"))
      message.should contain("different bytes on different days")
    end

    it "requires a full commit for oh-my-zsh" do
      result = parse_step(<<-STEP)
        - type: oh-my-zsh
          name: omz
          revision: master
          sha256: #{SHA}
        STEP

      result.error_messages.any?(&.includes?("40-character commit")).should be_true
    end

    it "requires a lock file when locked is set" do
      result = parse_step(<<-STEP)
        - type: binstaller-profile
          name: binaries
          config: ~/.config/binstaller/config.yaml
          locked: true
        STEP

      result.error_messages.any?(&.includes?("locked is true")).should be_true
    end

    it "rejects an inline binstaller profile" do
      result = parse_step(<<-STEP)
        - type: binstaller-profile
          name: binaries
          config:
            apiVersion: binstaller.io/v1alpha1
        STEP

      message = result.error_messages.find!(&.includes?("not an inline object"))
      message.should contain("binstaller owns that schema")
    end
  end
end
