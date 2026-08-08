# Config schema reference

A Fluxion profile is a single YAML document: a `WorkstationProfile` manifest
with an `apiVersion`/`kind` header, a target, and a list of phases. Place it in
`~/.config/fluxion/` or pass it with `-c`.

```yaml
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
    - name: core
      steps:
        - name: core-cli
          kind: dnf-packages
          spec:
            packages: [git, curl, ripgrep]
```

The accepted `apiVersion` is `initkit.io/v1alpha1`, kept as a compatibility
identifier. Fluxion is the product and the command name: `fluxion validate`,
`fluxion plan`, `fluxion dry-run`, and `fluxion apply` all read this document.

---

## Top-level fields

| Field | Required | Description |
|---|---:|---|
| `apiVersion` | yes | Must be `initkit.io/v1alpha1`. |
| `kind` | yes | Must be `WorkstationProfile`. |
| `metadata.name` | yes | Profile identity, used for state, reporting, and resume checks. Must not be blank or contain spaces. |
| `metadata.labels` | no | Free-form string map, carried but not interpreted. |
| `spec.target` | yes | Declared target OS. |
| `spec.policy` | no | Profile-level execution defaults. |
| `spec.vars` | no | String variables available to `${...}` interpolation. |
| `spec.sources` | no | Repository and Flatpak remote declarations run as a prelude. |
| `spec.phases` | yes | The phase DAG. At least one phase, each with at least one step. |

The header is the only version signal, and it is checked before anything else. A
document that is empty, is not a mapping, or carries neither `apiVersion` nor
`kind` is refused with a single message naming the header it expected: it is not
a profile at all, and every field-level complaint after that would be noise.

A profile is also refused if it is a symlink or larger than 8 MiB.

---

## `spec.target`

```yaml
spec:
  target:
    os:
      distribution: debian     # required
      codename: bookworm       # debian/ubuntu: preferred over release
      release: "12"            # optional; `version` is accepted as an alias
```

Supported distributions are `fedora`, `arch`, `opensuse`, `debian`, and
`ubuntu`. Common derivatives resolve to their base — CachyOS, EndeavourOS,
Manjaro, and Garuda are `arch`; Pop!\_OS and Linux Mint are `ubuntu` — because
that is the right answer for every decision Fluxion makes from the value.

The target is a declaration, not a selector. It is mapped into the core model so
validation, state, and reports have something to name, and it is what
`validate` checks package managers against, but it does not decide which steps
run. That is settled by host facts and `when` rules.

Debian and Ubuntu identify releases by codename, so `codename` is read first
there; everywhere else `release` (or `version`) is the useful label.

---

## `spec.policy`

```yaml
spec:
  policy:
    dryRun: false
    continueOnError: true
    requireSudo: true
    statePath: ~/.local/share/fluxion/state/developer-workstation.json
```

| Field | Description |
|---|---|
| `dryRun` | Config-level dry-run default. The CLI dry-run modes still force non-mutating execution regardless. |
| `continueOnError` | Default for steps that set neither `execution.continueOnError` nor `spec.continueOnError`. |
| `requireSudo` | Require a successful sudo preflight before any live mutation. TUI runs may authenticate through the shared sudo session; non-interactive runs need `sudo -n -v` to succeed. Dry runs never authenticate. |
| `statePath` | Compatibility field, validated for path safety. Runtime state uses Fluxion's profile state directory. |

---

## `spec.vars`

```yaml
spec:
  vars:
    binDir: ${HOME}/.local/bin
    configDir: ${HOME}/.config/fluxion
```

`${...}` tokens are interpolated across every string in the document before
validation and mapping. Lookup order is:

1. Runtime environment variables, plus a defaulted `HOME` and `USER`.
2. `spec.vars` values, which may reference other variables.
3. Host variables: `host.os.name`, `host.os.arch`, `host.user`, `host.home`.

Cycles and unresolved names are validation errors carrying the field path, and
an unresolved variable inside a step names that step.

Only braced `${name}` syntax is interpreted. Shell syntax — `$(...)`, backticks,
globs, unbraced `$VAR` — stays literal. Interpolation is refused inside shell
expressions (`commands[].run`, `shellCommand`, `unless`, `probeCommand`, an
assertion `command`), because context-free substitution cannot be made safe for
every shell grammar. Pass data through `env`, or use a structured `command` plus
`args`/`argv`.

---

## `spec.phases`

A phase groups steps that belong together and carries the ordering, restart, and
failure policy for that group.

```yaml
spec:
  phases:
    - name: shell-foundation        # required, unique across the profile
      description: "Login shell and its plugins"
      dependsOn: [system-foundation] # optional, defaults to []
      when:                          # optional; same grammar as a step's `when`
        distribution: fedora
      restartPolicy:
        type: prompt-logout
        message: "Log out and back in, then re-run fluxion."
      execution:
        continueOnError: true        # default: true
      steps:
        - name: shell-tools
          kind: dnf-packages
          spec:
            packages: [zsh]
```

| Field | Required | Description |
|---|---:|---|
| `name` | yes | Unique across the profile. It is what `plan`, `explain`, and `state` print. |
| `description` | no | One line, shown in plans and reports. |
| `dependsOn` | no | Phases that must complete first. Targets must exist and must not form a cycle. |
| `when` | no | Host condition for the whole phase. |
| `restartPolicy` | no | What has to happen before later work is meaningful. |
| `execution.continueOnError` | no | Default `true`. |
| `steps` | yes | At least one step. |

Phases are topologically sorted by `dependsOn`, so declaration order is a
convenience rather than the contract. A phase with
`execution.continueOnError: false` hard-fails on its first failed step and
blocks the phases that depend on it. With the default `true`, failures are
reported but the phase completes and its dependents can still run.

A phase whose `when` is unmet contributes no steps, but each of its steps is
still reported as skipped with `phase <name> when.<reason>`. A step that
vanished from `plan` entirely would look like it was never in the profile.

### `restartPolicy`

```yaml
restartPolicy:
  type: none
```

```yaml
restartPolicy:
  type: prompt-logout
  message: "Log out and back in, then re-run fluxion."
```

```yaml
restartPolicy:
  type: requires-new-shell
  shell: zsh                      # zsh | bash | sh
```

`prompt-logout` records completed state, emits a restart-required event, and
stops so the user can log out and resume deterministically.
`requires-new-shell` runs later effects through a fresh login shell wrapper, so
tools installed into shell startup paths are visible to what follows.

A skipped phase never carries a restart policy: a phase that ran nothing has
nothing for the user to log out of. A malformed policy is still reported.

---

## Steps

Every step in `spec.phases[].steps[]` has the same envelope, whatever it
installs:

```yaml
- name: base-packages           # required, unique across the WHOLE profile
  kind: dnf-packages            # required, from the kind table below
  description: "Everything a shell needs"
  when:
    distribution: fedora
  execution:
    continueOnError: false      # overrides the kind's own default
  spec:
    packages: [git, curl]
    probeCommand: "command -v git"
```

| Field | Required | Description |
|---|---:|---|
| `name` | yes | Unique across the whole profile, not merely within the phase. |
| `kind` | yes | One of the ids in the kind table. Surrounding space and case are normalized before lookup. |
| `description` | no | One line, shown in plans and reports. |
| `when` | no | Host condition for this step. |
| `execution.continueOnError` | no | Overrides the kind default and `spec.continueOnError`. |
| `spec` | all but Control | The kind-specific payload. |

Step names are unique profile-wide because they are the handle for
`state forget`, `explain --item`, and the TUI selector — a name that identified
two different things would make each of those ambiguous.

`spec.probeCommand` is accepted by every kind that has an observable footprint.
It answers "is this already here" without changing anything, which is what makes
`--skip-already-installed` and `status` meaningful.

Control kinds may carry nothing but a name: they describe an interaction rather
than an installation, so `spec` is optional for them and required for everything
else.

### Conditions

`when` selects or skips a phase or a step from host facts and `PATH` checks.

```yaml
when:
  distribution:
    oneOf: [debian, ubuntu]
  architecture: amd64
  commandExists: apt
```

| Field | Meaning |
|---|---|
| `os`, `osFamily` | Match the host OS family. |
| `distribution`, `distributions` | Match the host distribution. |
| `version` | Match the host version. |
| `codename` | Match the host codename. |
| `architecture`, `architectures` | Match the host architecture. |
| `commands` | Every listed command must exist on `PATH`. |
| `commandExists` | At least one listed command must exist on `PATH`. |
| `oneOf` | Match when any nested `when` branch matches. |

A matcher may be a string, a list of strings, or an object with `oneOf`,
`equals`, or `value`. The reserved `files`, `vars`, and `expression` fields are
rejected rather than quietly treated as true, until Fluxion has typed,
fail-closed semantics for them.

Skipped work is reported with its reason in `plan`, `dry-run`,
`apply --no-tui`, and the TUI.

---

## `spec.sources`

`spec.sources` declares package repositories and Flatpak remotes that run as a
prelude, before any selected step needs that package manager. Sections for a
manager no selected step uses are reported as skipped rather than applied:
adding a Debian repository on a Fedora host is work the user asked for but the
machine cannot use.

```yaml
spec:
  sources:
    apt:
      - name: docker
        kind: apt-repository
        spec:
          source: deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu noble stable
          sourceList: /etc/apt/sources.list.d/docker.list
          signingKeyUrl: https://download.docker.com/linux/ubuntu/gpg
          keyring: /etc/apt/keyrings/docker.gpg
          checksum:
            algorithm: sha256
            value: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
    dnf:
      - name: docker
        kind: rpm-repository
        spec:
          id: docker
          baseUrl: https://download.docker.com/linux/fedora/$releasever/$basearch/stable
          repoFile: /etc/yum.repos.d/docker.repo
          gpgKeyUrl: https://download.docker.com/linux/fedora/gpg
          checksum:
            algorithm: sha256
            value: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
    zypper:
      - name: packman
        kind: zypper-repository
        spec:
          id: packman
          baseUrl: https://ftp.gwdg.de/pub/linux/misc/packman/suse/openSUSE_Tumbleweed/
          repoFile: /etc/zypp/repos.d/packman.repo
          gpgKeyUrl: https://ftp.gwdg.de/pub/linux/misc/packman/suse/openSUSE_Tumbleweed/repodata/repomd.xml.key
          autoRefresh: true
          checksum:
            algorithm: sha256
            value: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
    flatpak:
      - name: flathub
        kind: flatpak-remote
        spec:
          remote: flathub
          url: https://flathub.org/repo/flathub.flatpakrepo
          system: true
          checksum:
            algorithm: sha256
            value: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
```

The sections are `apt`, `dnf`, `rpm` (an alias for `dnf`), `zypper`, and
`flatpak`, and each entry's `spec` is exactly the corresponding repository
kind's. `pacman` entries are accepted by the schema but generate no setup
operations; their server URL is still transport-validated, and a checksum is
rejected because a mirror base URL is not a finite artifact Fluxion can verify.

The repository and remote kinds these sections use are also available as
ordinary phase steps. Use `sources` when the repository should exist before
anything that needs it, and a phase step when the prelude runs too early — for
example when the repository itself depends on a package installed earlier.

---

## Kinds

`fluxion kinds` prints this list from the same table `validate` accepts and the
executor runs, so the three cannot drift apart. It is reproduced here in the
same order.

| Kind | Category | What it does |
|---|---|---|
| `apt-packages` | Packages | Install packages with apt. |
| `aur-packages` | Packages | Install AUR packages with paru or yay. |
| `cargo-packages` | Packages | Install crates with cargo. |
| `dnf-packages` | Packages | Install packages with dnf. |
| `pacman-packages` | Packages | Install packages with pacman. |
| `zypper-packages` | Packages | Install packages with zypper. |
| `sdkman-packages` | Sdkman | Install SDKMAN candidates such as java or maven. |
| `flatpak-packages` | Apps | Install Flatpak applications. |
| `binary-downloads` | Installer | Download and install a compiled binary or archive. |
| `shell-scripts` | Installer | Run local or HTTPS-fetched shell scripts. |
| `commands` | Installer | Run shell or direct argv commands. |
| `file-writes` | Installer | Write files from inline content or a source path. |
| `nerd-fonts` | Installer | Install Nerd Font families via nerd-fonts-installer. |
| `dotfiles-apply` | Installer | Apply a Dotbot configuration via dotbot. |
| `binstaller-profile` | Installer | Install binaries from a binstaller BinaryDistributionProfile. |
| `user-groups` | Installer | Add the user to groups. Append-only; never removes membership. |
| `git-config` | Installer | Set git config entries at global, system or local scope. |
| `git-repo` | Installer | Clone git repositories at an exact commit. |
| `systemd-unit` | Installer | Enable, mask, start or stop systemd units. |
| `system-setting` | Installer | Set timezone, hostname, locale, NTP and the RTC mode. |
| `system-update` | Installer | Refresh package metadata or upgrade every installed package. |
| `gpg-key` | Installer | Import repository signing keys into a keyring. |
| `tool-packages` | Installer | Install via a language tool: cargo-binstall, pipx, snap, uv, npm, go. |
| `toolchain` | Installer | Install a language toolchain from its official installer script. |
| `oh-my-zsh` | Installer | Install Oh My Zsh at a pinned commit. |
| `default-shell` | Installer | Change the user's login shell. |
| `apt-repository` | Installer | Add an apt repository, with its signing key. |
| `rpm-repository` | Installer | Add a dnf/yum repository, with its signing key. |
| `zypper-repository` | Installer | Add an openSUSE repository, with its signing key. |
| `pacman-repository` | Installer | Add a pacman repository to pacman.conf. |
| `flatpak-remote` | Installer | Add a Flatpak remote from a verified descriptor. |
| `interrupt` | Control | Write a resumable checkpoint and stop cleanly. |
| `shell-reload` | Control | Re-exec the shell so earlier environment changes take effect. |
| `assert` | Control | Fail the run unless a command succeeds. |
| `manual` | Control | Describe a step the user has to carry out by hand. |

An unknown kind is refused with a did-you-mean suggestion drawn from this same
list, so a typo names its own fix.

---

## Package kinds

Every package kind installs each item in a **separate process**, so one bad name
never costs the rest of the list. A single transaction of twenty packages fails
entirely on the first typo and leaves you with nothing, including the nineteen
that were fine.

```yaml
- name: core-cli-tools
  kind: dnf-packages
  spec:
    continueOnError: true        # default: true
    packages:                    # required, at least one item
      - git
      - curl
```

Package names are rejected when they are blank, look like an option (`-x`), or
contain shell metacharacters. Duplicates are reported as warnings — installing
something twice is wasteful rather than wrong, and refusing would block a
profile assembled from two fragments.

`validate` also checks the kind against `spec.target.os.distribution`: Fedora
installs with dnf, Arch with pacman, paru, or yay, Debian and Ubuntu with apt,
openSUSE with zypper. A profile targeting Fedora that installs with apt would
otherwise fail late and confusingly.

A step whose `when` narrows the distribution or OS family is exempt from that
check, because it is explicitly meant for a machine other than the declared
target — that is how one profile bootstraps several distributions. Guards on
anything else, such as `architecture`, do not exempt it: they say nothing about
which distribution the step will run on. `cargo-packages` is never checked,
since cargo owns its own tree rather than the distribution's.

Items may also be objects with a `name`, which is what `fluxion import` emits.

### `apt-packages`, `dnf-packages`, `pacman-packages`, `zypper-packages`

The system package managers. Each takes `packages`, an optional
`continueOnError`, and optional pre-install `actions`:

```yaml
- name: base
  kind: apt-packages
  spec:
    actions:
      - action: update
      - action: upgrade
    packages: [git, curl]
```

| Kind | Accepted actions |
|---|---|
| `apt-packages` | `update`, `upgrade`, `dist-upgrade` |
| `dnf-packages` | `check-update`, `upgrade`, `swap`, `groupupdate`, `group-update` |
| `pacman-packages` | `sync-upgrade`, `syu`, `upgrade` |
| `zypper-packages` | `refresh`, `update`, `dup`, `dup-from` |

An action may be a bare string or an object with `action` and `args`.

### `aur-packages`

```yaml
- name: aur-tools
  kind: aur-packages
  spec:
    packageManager: paru        # required: paru | yay
    packages: [visual-studio-code-bin]
```

This is the one package kind whose manager is a choice rather than a property of
the kind, because paru and yay are interchangeable. AUR helpers refuse to run as
root and escalate themselves for the pacman steps that need it, so Fluxion never
wraps them in `sudo`.

### `cargo-packages`

```yaml
- name: crates
  kind: cargo-packages
  spec:
    packages: [cargo-edit]
```

Prefer `tool-packages` with the `cargo-binstall` backend where a prebuilt binary
exists: it downloads instead of compiling.

### `sdkman-packages`

```yaml
- name: jvm
  kind: sdkman-packages
  spec:
    packages:
      - candidate: java
        version: "21.0.4-tem"
      - maven
```

Items are candidate strings or `{candidate, version}` objects. SDKMAN has no
argv interface — it is a set of shell functions — so its operands are
interpolated into a shell command and are rejected unless they are inert
(letters, digits, `.`, `_`, `+`, `-`).

### `flatpak-packages`

```yaml
- name: desktop-apps
  kind: flatpak-packages
  spec:
    remote: flathub             # default: flathub
    apps:                       # `appIds` is accepted as an alias
      - com.spotify.Client
      - org.telegram.desktop
```

Declare the remote itself with `flatpak-remote`, or under `spec.sources`, rather
than hiding it in a shell command where nothing verifies it.

---

## Installer kinds

### `binary-downloads`

```yaml
- name: install-neovim
  kind: binary-downloads
  spec:
    binaryName: nvim            # required — display name and extracted file name
    url: https://github.com/... # required — https only
    checksum:                   # SHA-256 is the only supported algorithm
      algorithm: sha256
      value: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
    installPath: /usr/local/bin/nvim   # required — absolute, normalized
    archivePath: nvim-linux64/bin/nvim # required for archives — exact post-strip path
    stripComponents: 1          # optional — components stripped before matching
    mode: "0755"                # optional — POSIX install mode; default "0755"
    symlinkPath: /usr/local/bin/vim    # optional
    continueOnError: false      # default: false
```

Every download must use one of two trust modes: a literal SHA-256 `checksum`, or
an HTTPS detached signature naming a signer the profile trusts.

```yaml
- name: install-neovim
  kind: binary-downloads
  spec:
    binaryName: nvim
    url: https://example.org/nvim.tar.gz
    signatureUrl: https://example.org/nvim.tar.gz.asc
    allowedSignerFingerprint: 0123456789ABCDEF0123456789ABCDEF01234567
    checksumUrl: https://example.org/checksums.txt   # supplemental metadata
    installPath: /usr/local/bin/nvim
    archivePath: nvim-linux64/bin/nvim
```

`checksum` and `checksumUrl` are mutually exclusive.

`checksumUrl` never establishes trust by itself: it is served by the same host as
the artifact, so an attacker who can replace one can replace both. Use it only
alongside a signer-bound signature. A checksum document may hold one bare
SHA-256 digest or ordinary `sha256sum` lines; a named entry is accepted only when
its safe relative path's basename matches the artifact URL's final component.

`signatureUrl` and `allowedSignerFingerprint` must be configured together — a
valid signature from an unknown key is not trust. The fingerprint is the 40-hex
OpenPGP v4 or 64-hex v5 primary/signing-key fingerprint. Fluxion runs GPG with a
machine-readable status channel and requires a signature whose signing or
primary-key fingerprint matches; a zero exit code alone is not sufficient,
because `gpg` reports success for a signature made by any key it happens to
hold. Accepted signature hashes are SHA-256, SHA-384, and SHA-512; accepted
public-key algorithms are RSA signing, ECDSA, legacy EdDSA, Ed25519, and Ed448.
DSA and SHA-1 are rejected.

Artifact, checksum, and signature URLs must be absolute HTTPS URLs with a host
and no user-info. A redirect that downgrades to HTTP is rejected. Query strings
stay available to the in-memory request for signed URLs but are stripped from
persisted state.

Supported formats are `.tar.gz`, `.tgz`, `.zip`, `.tar.xz`, and plain binaries.
`.tar.gz` and `.tgz` are extracted in process; `.zip` and `.tar.xz` are
delegated to `binstaller`, and the step fails rather than copying an archive
into place if that delegation is unavailable. Archive URLs require a normalized
relative POSIX `archivePath`, matched exactly after `stripComponents` — never by
basename, because two members can share one. Delegation is refused when
`stripComponents > 0`, since `binstaller` has no equivalent selector.

Downloads are streamed with timeouts. Artifacts and signatures are capped at
1 GiB and checksum documents at 1 MiB; oversized, truncated, or interrupted
downloads are rejected and their partial files removed. Local tar extraction
caps each entry at 1 GiB and the whole decompressed stream at 2 GiB, including
headers, padding, GNU long-name records, and PAX metadata — a compressed file's
size says nothing about what it expands to.

The verified binary is staged beside `installPath`, given its `mode` and
`symlinkPath`, and moved into place atomically only after that succeeds; a
failed commit restores the previous symlink. Privileged staging is allowed only
in a root-owned directory with no symlink components and no group or other write
permission. Dry-run previews the URL, the archive selection, the destination,
the mode, and the symlink without downloading or writing anything.

### `shell-scripts`

```yaml
- name: setup-scripts
  kind: shell-scripts
  spec:
    scripts:
      - name: local
        script: ./scripts/setup.sh
        args: [--quiet]
        cwd: /tmp
        sudo: false
        allowedExitCodes: [0]
        timeout: 10m
      - name: remote
        url: https://example.org/install.sh
        sha256: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
```

Each item defines exactly one of `script` or `url`. A local `script` is an
operator-controlled filesystem input and must not carry `sha256`; a remote `url`
must be HTTPS without user-info and requires the SHA-256 of the exact response
bytes. Fluxion verifies the digest before execution, including under `sudo`, and
removes the temporary file afterwards. Redirects may stay on HTTPS, but the
final URL must not contain user-info.

Item fields are `args`, `cwd` or `workingDir`, `env`, `sudo`,
`allowedExitCodes`, `creates`, `unless`, `confirm`, `timeout`, `timeoutSeconds`,
and `when`. A bare string in `scripts` is a local path.

Relative script, working-directory, and `creates` paths resolve from the
directory holding the profile, which is also the default working directory. The
interpreter comes from the shebang, falling back to `/bin/bash`, and the script
runs in a PTY so sudo prompts are handled by the TUI.

Items with `confirm` require `fluxion apply --yes`. Neither plain nor TUI
execution prompts for them; dry-run, plan, and probe-only need no approval.

A step that runs a single script may put the item's fields directly in `spec`
instead of using a one-element `scripts` list.

### `commands`

```yaml
- name: git-defaults
  kind: commands
  spec:
    shell: /bin/bash            # default: /bin/bash
    workingDir: /tmp            # optional
    continueOnError: true       # default: true
    commands:
      - "git config --global init.defaultBranch main"
      - name: direct-command
        argv: [git, config, --global, pull.rebase, "false"]
    probeCommand: "git config --global --get init.defaultBranch | grep -q main"
```

A string command runs through the configured shell with `-lc`. A bare array, or
an object with `argv`, an array `run`, or `command` plus `args`, stays a direct
argv command. An object with a string `run` or `shellCommand` is a shell
command. The two stay distinct all the way down, so previews and redaction
reflect the real execution boundary.

Use `commands` for work that is genuinely imperative. Declare repositories and
keys with the typed repository and `gpg-key` kinds so their remote artifacts are
verified before anything privileged happens, and keep package installs in
package kinds so Fluxion can still isolate and report individual packages.

### `file-writes`

```yaml
- name: write-tool-config
  kind: file-writes
  spec:
    files:
      - name: tool-config
        destination: /etc/tool/tool.conf
        content: |
          enabled=true
        owner: root
        group: root
        mode: "0644"
        sudo: true
      - name: local-copy
        destination: ~/.config/tool/local.conf
        source: /home/me/dotfiles/tool/local.conf
```

Each item needs an absolute `destination` and exactly one of a string `content`
or an absolute local `source`. Optional fields are `owner`, `group`, `mode`,
`sudo`, and an item-level `when`. `writes` is accepted as an alias for `files`.

An entry whose items are all excluded by their own `when` is dropped rather than
failed.

### `nerd-fonts`

Delegates to [`nerd-fonts-installer`](https://github.com/worxbend/nerd-fonts-installer).
Fluxion resolves the tool from `PATH`, then from its cache under
`~/.cache/fluxion/tools`, then downloads and checksum-verifies the release asset
for this platform.

```yaml
- name: nerd-fonts-install
  kind: nerd-fonts
  spec:
    config: ./nerd-fonts.yaml
    probeCommand: "fc-list | grep -qi JetBrains"
```

`config` — or `configPath`, an accepted alias — must be a path to a
nerd-fonts-installer config. Relative paths resolve against the profile's
directory. An inline object is rejected: the installer owns that schema, and
the file is in its format, not Fluxion's.

```yaml
release: v3.4.0
destination: ~/.local/share/fonts/NerdFonts
refresh_font_cache: true
families: [JetBrainsMono, Hack]
```

Fluxion hashes that file's bytes into the phase fingerprint, so editing it
re-runs the step; it never parses it to decide what runs. Pinning the font
release is the installer config's job now — Fluxion used to refuse a mutable
`latest` here, and that check moved with the work.

The step is one item, not one per family. Fluxion cannot see inside the config
and the installer applies it as a whole, so `probeCommand` is the way to make
the step skippable.

### `dotfiles-apply`

```yaml
- name: dotfiles-core
  kind: dotfiles-apply
  spec:
    config: ~/.dotfiles/install.conf.yaml
    installerVersion: v0.4.2
    probeCommand: "test -f ~/.zshrc && test -f ~/.gitconfig"
```

`config` or `configPath` must be a path string; an object is rejected, because
Dotbot owns that schema. The executor downloads `dotbot-go` from its pinned
release, extracts the configured binary entry, and runs it with `--config`.

`fluxion plan` runs `dotbot plan -c <config> --output json` and `fluxion dry-run`
runs `dotbot -c <config> --dry-run`, so the preview is Dotbot's own per-link plan
rather than an opaque command string. Force-linked entries replace matching
local paths when applied.

### `binstaller-profile`

Delegates binary tool distribution to
[`binstaller`](https://github.com/worxbend/binstaller). Fluxion does not
re-declare your tool list: it points at the `BinaryDistributionProfile` you
already maintain and maps its own verbs onto binstaller's.

| Fluxion | binstaller |
| --- | --- |
| `plan`, `dry-run` | `plan` |
| `apply` | `apply` |
| `status`, `diff` | `versions` |

`dry-run` never invokes `apply`, so a preview cannot touch the machine.

```yaml
- name: developer-binaries
  kind: binstaller-profile
  spec:
    config: ~/.config/binstaller/config.yaml
    only: [yazi, neovim]        # optional; empty means every tool in the profile
    skip: [zig]                 # optional
    locked: true                # optional; requires lockFile
    lockFile: ~/binstaller.lock.json
    installerVersion: v0.2.0    # binstaller release Fluxion installs if it is not on PATH
    continueOnError: false
```

Resolution order is an installation already on `PATH`, then Fluxion's cache
under `~/.cache/fluxion/tools`, then a download whose SHA-256 is verified against
the release's `.sha256` sidecar. Fluxion never shadows a `binstaller` you manage
yourself. `config` must be a path — an inline profile object is rejected — and
`locked: true` requires `lockFile`, since a lock without a lock file pins
nothing.

### `user-groups`

```yaml
- name: container-groups
  kind: user-groups
  spec:
    groups: [docker, libvirt]
    user: bob                 # optional; default is the user running fluxion
    createMissing: false      # optional; groupadd -f before usermod
    logoutCheckpoint: true    # optional; see below
    checkpointMessage: "Log out so the new groups take effect."
    continueOnError: false
```

`usermod -aG` exits 0 while the *running session* still lacks the group —
`docker ps` keeps saying permission denied until the user logs out. Fluxion
detects that by comparing `id -nG` (this process's own credentials, fixed at
login) against `id -nG <user>` (re-read from the group database) and raises a
restart checkpoint when they disagree. Set `logoutCheckpoint: false` for
containers and image builds, where there is no session to log out of.

Membership is append-only. There is no removal syntax, and `-docker` or
`!docker` are rejected rather than ignored: silently dropping a user out of a
group they depend on is a worse failure than having to run `gpasswd -d` by hand.

`createMissing` is off by default. The groups people want here (`docker`,
`libvirt`, `kvm`) are created by their own package, so a missing one usually
means a typo or a package that was not installed — and quietly creating a real
but useless group hides that.

When Fluxion itself runs under `sudo`, `SUDO_USER` is used rather than `root`.

### `git-config`

```yaml
- name: git-identity
  kind: git-config
  spec:
    scope: global            # global | system | local
    entries:
      user.email: you@example.com
      user.name: your-name
      pull.rebase: "true"
```

Every key must be `section.key`; a bare key is rejected here because
`git config` would reject it too, and a config diagnostic is easier to read than
a runtime failure. Each key is set individually and probed with
`git config --get`, so a key already holding the desired value is left alone and
`fluxion diff` can report drift per key. `system` scope writes `/etc/gitconfig`
and uses sudo.

### `git-repo`

```yaml
- name: zsh-plugins
  kind: git-repo
  spec:
    repos:
      - url: https://github.com/tmux-plugins/tpm.git
        dest: ~/.tmux/plugins/tpm
        ref: 0123456789abcdef0123456789abcdef01234567
      - url: https://github.com/zsh-users/zsh-autosuggestions.git
        dest: ~/.oh-my-zsh/custom/plugins/zsh-autosuggestions
        depth: 1
        ref: 89abcdef0123456789abcdef0123456789abcdef
        submodules: false
```

`url`, `dest`, and `ref` are required per repository. A destination may use `~`;
a `${...}` token in it is resolved by the document's own interpolation before
the step sees it, so it must name a variable that exists rather than carrying a
shell-style default. Every URL must be HTTPS without user-info, query
parameters, or a fragment, and every `ref` must be a full immutable 40-hex
commit — a branch or tag can move, so it cannot pin a checkout.

Fluxion initializes a staged repository, fetches the configured commit directly,
checks out `FETCH_HEAD` detached, verifies the exact origin and HEAD, then moves
the checkout into place without overwriting an existing path. The pin stays
fetchable even after the upstream default branch advances past a shallow
`depth`. An existing destination is inspection-only: a mismatched origin or HEAD
fails without pulling, resetting, or overwriting. The legacy `update` field is
accepted only as `none`. Recursive submodule checkout allows HTTPS only.

### `systemd-unit`

```yaml
- name: services
  kind: systemd-unit
  spec:
    scope: system            # system (default) | user
    units:
      - { name: docker, enabled: true, state: started }
      - { name: sshd, enabled: false, state: stopped, mask: true }
```

A bare name is treated as a `.service`, and a bare string is a unit to enable and
leave in its current state. `state` is `started`, `stopped`, or `unchanged`.
`scope: user` acts on your own manager and uses no sudo.

A unit cannot be both masked and enabled: masking is a refusal to start, so the
pair is a contradiction rather than a precedence question.

`systemctl is-enabled` is read by its output word rather than its exit code,
because several non-zero codes mean different things. `static`, `indirect`,
`generated`, and `alias` units are never passed to `enable` — that is an error
for a unit with no `[Install]` section, and it is already reachable as a
dependency. When `systemctl` is absent (containers, image builds) the step is
skipped rather than failed, so the same profile stays usable in CI.

### `system-setting`

```yaml
- name: clock-and-locale
  kind: system-setting
  spec:
    localRtc: false
    ntp: true
    timezone: Europe/Warsaw
    hostname: workstation
    locale:
      LANG: en_US.UTF-8
```

At least one setting must be present; a step that declares none is a
configuration mistake, not a no-op. Every setting is probed with the matching
`show --property` first, so only what actually differs is applied and a rerun is
free.

### `system-update`

```yaml
- name: full-update
  kind: system-update
  spec:
    packageManager: zypper   # dnf | zypper | pacman | apt
    distUpgrade: true        # zypper dup / apt full-upgrade
    refreshOnly: false       # metadata only
    timeout: PT2H            # ISO-8601 or 30m; default 2 hours
```

`packageManager` is required and must own the whole system's packages — Cargo
and Flatpak each own a slice of it, so "upgrade everything" has no meaning for
them. `distUpgrade` and `refreshOnly` are mutually exclusive: one asks for the
largest possible upgrade and the other for none at all. `distUpgrade` is
required on rolling releases such as openSUSE Tumbleweed, where a plain `update`
is the wrong verb.

`dnf check-update` exits **100** when updates are available. That is a successful
outcome and is treated as one — otherwise a refresh step would fail on exactly
the machines that had something to install.

### `gpg-key`

```yaml
- name: repository-keys
  kind: gpg-key
  spec:
    keys:
      - url: https://packages.microsoft.com/keys/microsoft.asc     # rpm --import
        fingerprint: BC528686B50D79E339D3721CEB3E94ADBE1229CF
      - url: https://download.docker.com/linux/debian/gpg          # apt keyring
        keyring: /etc/apt/keyrings/docker.gpg
        fingerprint: 9DC858229FC7DD38854AE2D88D81803C0EBFCD88
```

Omit `keyring` to import into the RPM database; supply it to write a dearmoured
key for an apt `signed-by` source.

Importing a key decides what the machine will trust to install software as root,
so URLs must be HTTPS without user-info or absolute `file:` URIs, and every key
requires its full 40-hex primary `fingerprint`. Fluxion downloads to a temporary
file, requires exactly one primary key with that fingerprint, and only then
installs the keyring or invokes `rpm --import`. Local `file:` sources and
existing keyrings must be regular, non-symlink files no larger than 16 MiB;
Fluxion stages a bounded copy before inspection and accepts an existing keyring
only when that copy still matches. A mismatch or unsafe file fails without
replacing anything or importing the download.

An RPM-imported key is tracked by its fingerprint and a keyring-backed key by
its absolute keyring path. Query parameters and fragments remain available to the
request but are excluded from plans, events, errors, and state.
`continueOnError: true` attempts the remaining keys, but a trust failure still
fails the step; the phase's `execution.continueOnError` then decides whether
later steps run.

Keyring destinations are normalized and confined to approved system key
directories and extensions; APT keyrings use `.gpg` or `.asc` beneath
`/etc/apt/keyrings` or `/usr/share/keyrings`.

### `tool-packages`

```yaml
- name: rust-tools
  kind: tool-packages
  spec:
    backend: cargo-binstall  # cargo-binstall | cargo | snap | pipx | uv-tool | npm-global | go-install
    packages:
      - eza
      - ripgrep
      - "bottom@0.10.2"      # name@version pins
      - name: bat
        version: "0.24.0"
    continueOnError: true    # default: true
```

Prefer `cargo-binstall` over `cargo`: it fetches prebuilt binaries instead of
compiling from source. Items are bare names, `name@version` strings, or objects
with `name` and an optional `version`; a scoped npm name keeps its leading `@`
because the split is at the last one.

Each package installs in its own process, so one yanked crate does not block the
other nineteen. The backend must be on `PATH`; the step fails with an actionable
message rather than a confusing command-not-found. Package names must be
registry identifiers valid for the backend — local paths, URLs, direct
references, and option-shaped names are rejected.

### `toolchain`

```yaml
- name: rustup
  kind: toolchain
  spec:
    kind: RUSTUP             # RUSTUP | JULIAUP | SDKMAN | GENERIC
    installScriptUrl: https://sh.rustup.rs
    sha256: 6c30b75a75b28a96fd913a037c8581b580080b6ee9b8169a3c0feb1af7fe8caf
    installArgs:
      - "-y"
      - "--no-modify-path"
    postInstallEnvSource: ~/.cargo/env
    continueOnError: true
    probeCommand: "test -f ~/.cargo/bin/rustup"
```

The `kind` inside `spec` names the toolchain family and is unrelated to the
step's own `kind: toolchain`. `installScript` is accepted as an alias for
`installScriptUrl`.

`sha256` is required. Installer endpoint updates are fail-closed on purpose:
review the new script, update the digest, and rerun rather than executing changed
upstream bytes implicitly.

### `oh-my-zsh`

```yaml
- name: oh-my-zsh
  kind: oh-my-zsh
  spec:
    revision: c5ba74cf02cce4c342153f79089100194f30940f
    sha256: 95118b50d062198597e2b73d3a57b609fd95ca68cdc86faf4460d955f0172b61
    installDir: ~/.oh-my-zsh    # optional, default: ~/.oh-my-zsh
    probeCommand: "test -d ~/.oh-my-zsh"
```

`revision` must be a full 40-character commit, not `master`, a branch, or a
mutable tag — anything that can move would make the digest meaningless.
`sha256` verifies that revision's `tools/install.sh` before it runs.

### `default-shell`

```yaml
- name: zsh-default
  kind: default-shell
  spec:
    shell: /bin/zsh             # `shellPath` is accepted as an alias
    probeCommand: "getent passwd $USER | cut -d: -f7 | grep -q zsh"
```

The shell must be an absolute path to an executable. Live execution runs
`sudo chsh -s <shell> <target-user>` through the same authenticated runner as
every other privileged effect.

### Repository kinds

The four repository kinds and `flatpak-remote` share one trust contract. Every
source URI must be HTTPS without user-info, including the URI embedded in an APT
`deb` or `deb-src` line. A declared key URL requires a SHA-256 `checksum` over
the exact remote response bytes, and a checksum without its key URL is refused
too: a key URL with no digest means "trust whatever this host serves today to
decide what my machine installs as root", which is the decision these kinds
exist to avoid.

Verification completes before any privileged key, repository, or configuration
mutation, and only the verified local file crosses that boundary. A repository
`baseUrl` is transport-validated but is not itself a finite checksum subject.

#### `apt-repository`

```yaml
- name: docker
  kind: apt-repository
  spec:
    source: deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian bookworm stable
    sourceList: /etc/apt/sources.list.d/docker.list  # default: /etc/apt/sources.list.d/<name>.list
    signingKeyUrl: https://download.docker.com/linux/debian/gpg
    keyring: /etc/apt/keyrings/docker.gpg            # default when signingKeyUrl is set
    checksum:
      algorithm: sha256
      value: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
```

Fluxion downloads and verifies the declared key without privileges, dearmors it
without privileges, then uses structured `sudo install` commands for the keyring
and source list before running `sudo apt-get update`. Plans, `dry-run`,
`status`, `diff`, and `explain` use the source-list path as the item key.

Source options are restricted to `arch` and exactly one `signed-by`, and
`signed-by` must match the absolute `keyring` path — otherwise the profile
documents one trust root and installs another. Trust-bypass syntax such as
`trusted` and `allow-insecure` is rejected. `sourceList` is confined to direct
`.list` files in `/etc/apt/sources.list.d`; keyrings are normalized and confined
to `.gpg` or `.asc` files in `/etc/apt/keyrings` or `/usr/share/keyrings`.
Validation fails when the target OS is not Debian or Ubuntu.

#### `rpm-repository`

```yaml
- name: docker
  kind: rpm-repository
  spec:
    id: docker                             # default: the step name
    baseUrl: https://download.docker.com/linux/fedora/$releasever/$basearch/stable
    repoFile: /etc/yum.repos.d/docker.repo # default: /etc/yum.repos.d/<name>.repo
    gpgKeyUrl: https://download.docker.com/linux/fedora/gpg
    enabled: true                          # default: true
    gpgCheck: true                         # default: true
    checksum:
      algorithm: sha256
      value: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
```

The key is verified and parsed without privileges, then the local key and an
auditable `.repo` file are installed with structured `sudo install` commands and
metadata is refreshed with `sudo dnf makecache --refresh`. The generated
repository refers to the installed local key, never the remote URL. The repo file
path is the item key. An enabled repository may not disable `gpgCheck`, and
`gpgCheck` requires a key URL. `repoFile` must be a direct `.repo` file in
`/etc/yum.repos.d`.

#### `zypper-repository`

```yaml
- name: packman
  kind: zypper-repository
  spec:
    id: packman                             # default: the step name
    baseUrl: https://ftp.gwdg.de/pub/linux/misc/packman/suse/openSUSE_Tumbleweed/
    repoFile: /etc/zypp/repos.d/packman.repo # default: /etc/zypp/repos.d/<name>.repo
    gpgKeyUrl: https://ftp.gwdg.de/pub/linux/misc/packman/suse/gpg-pubkey.asc
    enabled: true
    gpgCheck: true
    autoRefresh: true
    checksum:
      algorithm: sha256
      value: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
```

Behaves like `rpm-repository`, with `autoRefresh` emitted as `autorefresh=1` or
`autorefresh=0`. `repoFile` is confined to direct `.repo` children of
`/etc/zypp/repos.d`.

#### `pacman-repository`

```yaml
- name: chaotic-aur
  kind: pacman-repository
  spec:
    repository: chaotic-aur                  # default: the step name
    server: https://cdn-mirror.chaotic.cx/$repo/$arch
    config: /etc/pacman.conf                 # default and only accepted value
    sigLevel: Required TrustedOnly
    include: /etc/pacman.d/chaotic-mirrorlist
    enabled: true                            # default: true
```

Execution probes the repository header with structured `grep` arguments. When
the repository is missing, Fluxion reads only a bounded, root-owned,
non-symbolic config beneath secure privileged directories, stages the complete
replacement privately, and installs it with a structured `sudo install` command
before `sudo pacman -Sy`. Optional includes are normalized direct children of
`/etc/pacman.d`. The repository name is the item key.

`sigLevel` accepts only Pacman's documented trust-policy tokens. It is a fold
rather than a set — later tokens override earlier ones, and `Package`/`Database`
prefixes scope an override to one side — so an enabled repository must end up
requiring signed, trusted packages *and* databases. `Required TrustedOnly`
satisfies both. Validation fails when the target OS is not Arch, when the server
is not HTTPS or contains user-info, or when an enabled repository omits or
weakens `sigLevel`.

#### `flatpak-remote`

```yaml
- name: flathub
  kind: flatpak-remote
  spec:
    remote: flathub               # required
    url: https://flathub.org/repo/flathub.flatpakrepo  # required
    system: true                  # default: true; false adds the user remote
    checksum:
      algorithm: sha256
      value: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
```

The descriptor is verified and only its local path is passed to
`flatpak remote-add --if-not-exists`; the URL never reaches Flatpak. With
`system: false`, Fluxion adds `--user`. The checksum is not optional here,
unlike the other repository kinds, because the descriptor is what tells Flatpak
which keys to trust. The remote name is the item key.

---

## Control kinds

Control kinds describe an interaction rather than an installation, so their
`spec` may be omitted entirely.

### `interrupt`

```yaml
- name: relogin
  kind: interrupt
  spec:
    message: Log out and back in before continuing.
    instructions:
      - Reopen a terminal.
      - Run the resume command printed by Fluxion.
    resumeFrom: next             # next (default) | current
    exitCode: 75                 # default: 75, between 0 and 255
```

Writes a resumable checkpoint and stops cleanly. `resumeFrom: next` records the
interrupt step as complete; `current` resumes at it.

Fluxion records the profile's identity and a fingerprint of its configuration in
state, so a later apply refuses to resume against state written for something
else. Use `fluxion state reset --force` when discarding it is what you mean.

### `shell-reload`

```yaml
- name: reload-zsh
  kind: shell-reload
  description: "Pick up the toolchains installed above"
  spec:
    shell: zsh                   # zsh | bash | sh
```

Use this when an earlier step writes shell startup files that later commands
need to observe.

### `assert`

```yaml
- name: secure-boot-disabled
  kind: assert
  spec:
    command: "mokutil --sb-state | grep -qi disabled"
    message: "Disable Secure Boot before installing this graphics stack."
    shell: /bin/bash             # optional, default: /bin/bash
    workingDir: /tmp             # optional
```

The command runs with `<shell> -lc`. Exit code `0` passes. Any other exit fails
the step and stops the phase unless the phase allows continuation. A profile
that supplies its own `message` is telling the user how to fix the machine,
which is the point.

### `manual`

```yaml
- name: github-login
  kind: manual
  spec:
    message: "Run `gh auth login`, then continue."
    probeCommand: "gh auth status"
```

Manual steps print their message in plain CLI output. With a `probeCommand`,
Fluxion runs it with `/bin/bash -lc`; exit code `0` marks the checkpoint complete
and persists it. Without one the step fails with the message so the user can do
the work and resume — and `validate` warns, because a manual step with no probe
can never be marked complete.

---

## Validation rules

Every diagnostic names the config path that caused it, and all of them are
reported at once, so a profile with five mistakes takes one run to fix.

- `apiVersion` and `kind` must be present and exact.
- `metadata.name` must not be blank or contain spaces.
- `spec.target.os.distribution` is required and must be a supported value.
- `spec.phases` needs at least one phase, and each phase at least one step.
- Phase names are unique across the profile.
- `dependsOn` must name declared phases and must not form a cycle.
- Step names are unique across the whole profile.
- Every step `kind` must be in the kind table.
- `spec` is required by every kind except the Control ones.
- A package kind must match the target distribution.
- Package names must not be blank, option-shaped, or contain shell
  metacharacters.
- Every remote URL must be HTTPS without user-info.
- A remote script, a signing key, and a Flatpak descriptor each require their
  digest.
- `installPath` and `symlinkPath` must be absolute, normalized paths, and an
  archive download requires a normalized relative POSIX `archivePath`.

---

## Dry-run and safety guarantees

`fluxion plan --show-commands`, `fluxion dry-run`, and `fluxion apply --dry-run`
render selected, skipped, and source-setup work without mutating anything:

- Dry-run does not install packages, write files, download binaries, add remotes
  or repositories, save interrupt state, or run shell commands.
- Package, Flatpak, Cargo, and SDKMAN items are attempted independently within a
  step.
- Source setup runs before the package steps that need it and fails before them
  unless policy allows continuation.
- Sensitive environment values, sudo input, bearer tokens, URL credentials, and
  password-like text are redacted from rendered commands, events, failure text,
  and TUI state.
- Shell strings and direct argv commands stay distinct, so previews and
  redaction reflect the real execution boundary.
- File writes, downloads, and privileged operations are represented by typed
  kinds rather than hidden imperative setup wherever a kind exists for them.

---

## Full example

```yaml
apiVersion: initkit.io/v1alpha1
kind: WorkstationProfile
metadata:
  name: fedora-workstation
  labels:
    distro: fedora
spec:
  target:
    os:
      distribution: fedora
      release: "44"

  policy:
    continueOnError: true
    requireSudo: true

  vars:
    binDir: ${HOME}/.local/bin

  sources:
    flatpak:
      - name: flathub
        kind: flatpak-remote
        spec:
          remote: flathub
          url: https://flathub.org/repo/flathub.flatpakrepo
          checksum:
            algorithm: sha256
            value: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef

  phases:
    - name: system-foundation
      description: "The handful of things everything else assumes"
      steps:
        - name: core-cli-tools
          kind: dnf-packages
          spec:
            continueOnError: true
            packages: [git, curl, neovim]

    - name: development
      dependsOn: [system-foundation]
      steps:
        - name: dev-tools
          kind: dnf-packages
          spec:
            packages: [java-21-openjdk-devel, golang]

        - name: git-defaults
          kind: commands
          spec:
            commands:
              - "git config --global init.defaultBranch main"
            probeCommand: "git config --global --get init.defaultBranch | grep -q main"

        - name: github-login
          kind: manual
          spec:
            message: "Run `gh auth login`, then continue."
            probeCommand: "gh auth status"

    - name: shell
      dependsOn: [system-foundation]
      restartPolicy:
        type: prompt-logout
        message: "Log out and back in, then re-run fluxion."
      steps:
        - name: shell-tools
          kind: dnf-packages
          spec:
            packages: [zsh]

        - name: zsh-default
          kind: default-shell
          spec:
            shell: /bin/zsh
            probeCommand: "getent passwd $USER | cut -d: -f7 | grep -q zsh"

    - name: desktop-apps
      dependsOn: [system-foundation]
      when:
        commandExists: flatpak
      steps:
        - name: desktop-flatpaks
          kind: flatpak-packages
          spec:
            remote: flathub
            apps:
              - com.spotify.Client
              - org.telegram.desktop
```
