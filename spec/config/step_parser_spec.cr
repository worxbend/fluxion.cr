require "../spec_helper"

private SHA = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

# Every step reaches the parser through its kind, which is the only entry point
# there is. These specs stay at the field level: what the kind resolves to is
# the manifest spec's business, what each `spec:` payload accepts is this one's.
private def parse_step(yaml : String, distribution : String = "fedora")
  ProfileHelpers.parse(ProfileHelpers.manifest(yaml, distribution))
end

describe Fluxion::Config::StepParser do
  # `binary-downloads` was removed: binstaller owns download, verification and
  # install now. Its trust tests went with it — the guarantees live in the
  # binstaller profile's `spec.policy.mode: strict`.
  describe "retired kinds" do
    it "names what took over rather than guessing at a typo" do
      result = parse_step(<<-STEP)
        - name: kubectl
          kind: binary-downloads
          spec:
            binaryName: kubectl
        STEP

      message = result.error_messages.find!(&.includes?("was removed"))
      message.should contain("binstaller-profile")
    end
  end

  describe "repository kinds" do
    it "requires a key URL and its checksum together" do
      result = parse_step(<<-STEP)
        - name: docker
          kind: rpm-repository
          spec:
            baseUrl: https://download.docker.com/linux/fedora/stable
            gpgKeyUrl: https://download.docker.com/linux/fedora/gpg
        STEP

      message = result.error_messages.find!(&.includes?("configured together"))
      message.should contain("the digest is what makes the key trustworthy")
    end

    it "refuses an enabled repository that disables gpgCheck" do
      result = parse_step(<<-STEP)
        - name: docker
          kind: rpm-repository
          spec:
            baseUrl: https://download.docker.com/linux/fedora/stable
            enabled: true
            gpgCheck: false
        STEP

      result.error_messages.any?(&.includes?("must enforce gpgCheck")).should be_true
    end

    it "confines the repo file to the manager's directory" do
      result = parse_step(<<-STEP)
        - name: docker
          kind: rpm-repository
          spec:
            baseUrl: https://download.docker.com/linux/fedora/stable
            repoFile: /tmp/docker.repo
            gpgCheck: false
            enabled: false
        STEP

      result.error_messages.any?(&.includes?("/etc/yum.repos.d")).should be_true
    end

    it "rejects an APT source option that bypasses verification" do
      result = parse_step(<<-STEP, distribution: "debian")
        - name: docker
          kind: apt-repository
          spec:
            source: "deb [trusted=yes] https://download.docker.com/linux/debian bookworm stable"
        STEP

      result.error_messages.any?(&.includes?("option is not allowed: trusted")).should be_true
    end

    it "rejects an APT source whose signed-by disagrees with the keyring" do
      result = parse_step(<<-STEP, distribution: "debian")
        - name: docker
          kind: apt-repository
          spec:
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
        - name: flathub
          kind: flatpak-remote
          spec:
            remote: flathub
            url: https://flathub.org/repo/flathub.flatpakrepo
        STEP

      result.error_messages.any?(&.includes?("required for the Flatpak repository descriptor")).should be_true
    end

    it "requires a signed and trusted SigLevel on an enabled pacman repository" do
      result = parse_step(<<-STEP, distribution: "arch")
        - name: chaotic-aur
          kind: pacman-repository
          spec:
            server: https://cdn-mirror.chaotic.cx/chaotic-aur/x86_64
            sigLevel: Optional TrustAll
        STEP

      result.error_messages.any?(&.includes?("signed, trusted packages and databases")).should be_true
    end

    it "accepts Required TrustedOnly" do
      result = parse_step(<<-STEP, distribution: "arch")
        - name: chaotic-aur
          kind: pacman-repository
          spec:
            server: https://cdn-mirror.chaotic.cx/chaotic-aur/x86_64
            sigLevel: Required TrustedOnly
        STEP

      result.errors.should be_empty
    end

    it "tracks package and database trust independently" do
      # Databases are left at the default, so this must still be refused.
      result = parse_step(<<-STEP, distribution: "arch")
        - name: chaotic-aur
          kind: pacman-repository
          spec:
            server: https://cdn-mirror.chaotic.cx/chaotic-aur/x86_64
            sigLevel: PackageRequired PackageTrustedOnly
        STEP

      result.error_messages.any?(&.includes?("signed, trusted packages and databases")).should be_true
    end

    it "requires a full fingerprint for every imported key" do
      result = parse_step(<<-STEP)
        - name: keys
          kind: gpg-key
          spec:
            keys:
              - url: https://packages.microsoft.com/keys/microsoft.asc
                fingerprint: BE1229CF
        STEP

      result.error_messages.any?(&.includes?("fingerprint")).should be_true
    end
  end

  describe "shell kinds" do
    it "requires exactly one of script or url" do
      result = parse_step("- name: setup\n  kind: shell-scripts\n  spec: {}\n")
      result.error_messages.any?(&.includes?("exactly one of script, url or content")).should be_true
    end

    it "requires a digest for a remote script" do
      result = parse_step(<<-STEP)
        - name: setup
          kind: shell-scripts
          spec:
            url: https://example.org/install.sh
        STEP

      message = result.error_messages.find!(&.includes?("required for a remote script"))
      message.should contain("verifies the digest before executing")
    end

    it "refuses a digest on a local script" do
      ProfileHelpers.with_profile("echo hi\n", "setup.sh") do |script|
        result = parse_step(<<-STEP)
          - name: setup
            kind: shell-scripts
            spec:
              script: #{script}
              sha256: #{SHA}
          STEP

        result.error_messages.any?(&.includes?("only valid for a remote URL")).should be_true
      end
    end

    it "keeps a shell string and a direct argv distinct" do
      result = parse_step(<<-STEP)
        - name: git-defaults
          kind: commands
          spec:
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
        - name: c
          kind: commands
          spec:
            commands:
              - run: "true"
                allowedExitCodes: []
        STEP

      result.step("c").as(Fluxion::ShellCommandStep).commands.first.allowed_exit_codes.should eq([0])
    end

    it "infers sensitivity from the environment variable name" do
      result = parse_step(<<-STEP)
        - name: c
          kind: commands
          spec:
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

    it "reads a shell for shell-reload and defaults to zsh" do
      result = parse_step(<<-STEP)
        - name: reload
          kind: shell-reload
          spec:
            shell: bash
        - name: reload-default
          kind: shell-reload
        STEP

      result.errors.should be_empty
      result.step("reload").as(Fluxion::ShellReloadStep).shell.should eq(Fluxion::ShellKind::Bash)
      result.step("reload-default").as(Fluxion::ShellReloadStep).shell.should eq(Fluxion::ShellKind::Zsh)
    end

    it "requires an absolute path for the login shell" do
      result = parse_step("- name: login\n  kind: default-shell\n  spec:\n    shell: zsh\n")
      result.error_messages.any?(&.includes?("must be absolute")).should be_true
    end

    it "gives an assert step a default message naming it" do
      result = parse_step(<<-STEP)
        - name: has-git
          kind: assert
          spec:
            command: command -v git
        STEP

      result.errors.should be_empty
      result.step("has-git").as(Fluxion::AssertStep).message.should contain("has-git")
    end

    it "warns about a manual step with no probe" do
      result = parse_step("- name: login\n  kind: manual\n  spec:\n    message: 'Run gh auth login'\n")
      result.errors.should be_empty
      result.warnings.any?(&.message.includes?("can never be marked complete")).should be_true
    end
  end

  describe "system kinds" do
    it "rejects group-removal syntax" do
      result = parse_step("- name: g\n  kind: user-groups\n  spec:\n    groups: ['-docker']\n")
      message = result.error_messages.find!(&.includes?("append-only"))
      message.should contain("gpasswd -d")
    end

    it "rejects a bare git config key" do
      result = parse_step(<<-STEP)
        - name: identity
          kind: git-config
          spec:
            entries:
              email: me@example.test
        STEP

      result.error_messages.any?(&.includes?("section.key")).should be_true
    end

    it "requires an immutable commit for a cloned repo" do
      result = parse_step(<<-STEP)
        - name: plugins
          kind: git-repo
          spec:
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
        - name: plugins
          kind: git-repo
          spec:
            repos:
              - url: https://github.com/a/b.git?token=1
                dest: ~/x
                ref: #{"a" * 40}
        STEP

      result.error_messages.any?(&.includes?("query or fragment")).should be_true
    end

    it "refuses a unit that is both masked and enabled" do
      result = parse_step(<<-STEP)
        - name: services
          kind: systemd-unit
          spec:
            units:
              - name: sshd
                enabled: true
                mask: true
        STEP

      result.error_messages.any?(&.includes?("cannot both mask and enable")).should be_true
    end

    it "appends .service to a bare unit name" do
      result = parse_step(<<-STEP)
        - name: services
          kind: systemd-unit
          spec:
            units:
              - docker
        STEP

      result.step("services").as(Fluxion::SystemdUnitStep).units.first.qualified_name
        .should eq("docker.service")
    end

    it "refuses a system-setting step that sets nothing" do
      result = parse_step("- name: s\n  kind: system-setting\n  spec: {}\n")
      result.error_messages.any?(&.includes?("declares no system setting")).should be_true
    end

    it "orders system-setting items predictably" do
      result = parse_step(<<-STEP)
        - name: s
          kind: system-setting
          spec:
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
        - name: u
          kind: system-update
          spec:
            packageManager: dnf
            distUpgrade: true
            refreshOnly: true
        STEP

      result.error_messages.any?(&.includes?("cannot be both distUpgrade and refreshOnly")).should be_true
    end

    it "parses an ISO-8601 timeout" do
      result = parse_step(<<-STEP)
        - name: u
          kind: system-update
          spec:
            packageManager: dnf
            timeout: PT2H
        STEP

      result.step("u").as(Fluxion::SystemUpdateStep).timeout.should eq(2.hours)
    end

    it "parses a compact timeout" do
      result = parse_step(<<-STEP)
        - name: u
          kind: system-update
          spec:
            packageManager: dnf
            timeout: 30m
        STEP

      result.step("u").as(Fluxion::SystemUpdateStep).timeout.should eq(30.minutes)
    end
  end

  describe "pinned installers" do
    it "refuses an inline Nerd Fonts config and points at the installer's own" do
      # Fluxion used to accept release/families here and render them into the
      # installer's format at run time, which made it the owner of a schema it
      # does not control. Pinning the font release is now the installer config's
      # job — the guarantee moved with the work.
      result = parse_step(<<-STEP)
        - name: fonts
          kind: nerd-fonts
          spec:
            config:
              release: latest
              families: [JetBrainsMono]
        STEP

      message = result.error_messages.find!(&.includes?("not an inline object"))
      message.should contain("nerd-fonts-installer config")
    end

    it "accepts a path to the installer's config" do
      result = parse_step(<<-STEP)
        - name: fonts
          kind: nerd-fonts
          spec:
            config: ./nerd-fonts.yaml
        STEP

      result.errors.should be_empty
      result.step("fonts").as(Fluxion::NerdFontsStep).config.should end_with("nerd-fonts.yaml")
    end

    it "yields one item for the whole config, not one per family" do
      # The executor ignores the item and runs the whole installer, so a
      # profile naming 42 families used to invoke it 42 times.
      result = parse_step(<<-STEP)
        - name: fonts
          kind: nerd-fonts
          spec:
            config: ./nerd-fonts.yaml
        STEP

      result.step("fonts").items.size.should eq(1)
    end

    it "requires a full commit for oh-my-zsh" do
      result = parse_step(<<-STEP)
        - name: omz
          kind: oh-my-zsh
          spec:
            revision: master
            sha256: #{SHA}
        STEP

      result.error_messages.any?(&.includes?("40-character commit")).should be_true
    end

    it "requires a pinned digest for a toolchain installer" do
      result = parse_step(<<-STEP)
        - name: rust
          kind: toolchain
          spec:
            kind: rustup
            installScriptUrl: https://sh.rustup.rs
        STEP

      message = result.error_messages.find!(&.includes?("sha256"))
      message.should contain("fail-closed")
    end

    it "rejects an unknown toolchain and lists the accepted ones" do
      result = parse_step("- name: t\n  kind: toolchain\n  spec:\n    kind: nvm\n")
      message = result.error_messages.find!(&.includes?("toolchain kind is required"))
      message.should contain("RUSTUP")
    end

    it "requires a lock file when locked is set" do
      result = parse_step(<<-STEP)
        - name: binaries
          kind: binstaller-profile
          spec:
            config: ~/.config/binstaller/config.yaml
            locked: true
        STEP

      result.error_messages.any?(&.includes?("locked is true")).should be_true
    end

    it "rejects an inline binstaller profile" do
      result = parse_step(<<-STEP)
        - name: binaries
          kind: binstaller-profile
          spec:
            config:
              apiVersion: binstaller.io/v1alpha1
        STEP

      message = result.error_messages.find!(&.includes?("not an inline object"))
      message.should contain("binstaller owns that schema")
    end
  end
end

# `confirm` decides whether an item needs `apply --yes`. It accepts a boolean
# shorthand or a string carrying its own wording, and no spec parsed it from
# YAML — which is how `confirm: false` came to mean the opposite of what it
# says.
private def command_step(confirm : String) : Fluxion::ShellCommandStep
  result = ProfileHelpers.parse(ProfileHelpers.manifest(<<-STEPS), ProfileHelpers.fedora_host)
    - name: risky
      kind: commands
      spec:
        commands:
          - run: rm -rf /var/cache/thing
            confirm: #{confirm}
    STEPS

  result.errors.should be_empty
  result.step("risky").as(Fluxion::ShellCommandStep)
end

describe "a shell command's confirm field" do
  it "asks with generic wording for `confirm: true`" do
    item = command_step("true").commands.first
    item.confirmation_required?.should be_true
    item.confirm.should eq("confirm")
  end

  it "does not ask for `confirm: false`" do
    # The whole point of writing it is to say "do not stop for this one".
    command_step("false").commands.first.confirmation_required?.should be_false
  end

  it "keeps a string as its own wording" do
    item = command_step(%("really delete the cache?")).commands.first
    item.confirmation_required?.should be_true
    item.confirm.should eq("really delete the cache?")
  end

  it "keeps a string that happens to spell a boolean" do
    # `confirm: "yes"` is a prompt reading "yes", not the shorthand: a quoted
    # scalar is a string and is taken at its word.
    command_step(%("yes")).commands.first.confirm.should eq("yes")
  end

  it "rejects a value that is neither a boolean nor a non-blank string" do
    result = ProfileHelpers.parse(ProfileHelpers.manifest(<<-STEPS), ProfileHelpers.fedora_host)
      - name: risky
        kind: commands
        spec:
          commands:
            - run: rm -rf /var/cache/thing
              confirm: []
      STEPS

    result.error_messages.any?(&.includes?("must be a boolean or non-blank string")).should be_true
  end
end
