# Recipes

Patterns worth copying, and why they are shaped the way they are.

## One profile, several distributions

Use a `WorkstationProfile` manifest and let host facts choose:

```yaml
apiVersion: initkit.io/v1alpha1
kind: WorkstationProfile
metadata:
  name: workstation
spec:
  target:
    os:
      distribution: fedora
  plan:
    - name: core-fedora
      kind: dnf-packages
      when:
        distribution: fedora
      spec:
        packages: [git, curl, ripgrep]

    - name: core-arch
      kind: pacman-packages
      when:
        distribution: arch
      spec:
        packages: [git, curl, ripgrep]
```

Entries that do not match are reported as skipped with the reason, so the
output shows what the host excluded rather than quietly omitting it.

## A binary that is not packaged

Pin the digest. Without it Fluxion refuses the download:

```yaml
- type: compiled-binary
  name: kubectl
  binaryName: kubectl
  url: https://dl.k8s.io/release/v1.30.2/bin/linux/amd64/kubectl
  checksum:
    algorithm: sha256
    value: c6e9c45ce3f82c90663e3c30db3b27c167e8b19d83ed4048b61c1013f6a7c66e
  installPath: /usr/local/bin/kubectl
```

From an archive, name the exact member — Fluxion never matches by basename,
because two members can share one:

```yaml
- type: compiled-binary
  name: ripgrep
  binaryName: rg
  url: https://github.com/BurntSushi/ripgrep/releases/download/14.1.0/ripgrep-14.1.0-x86_64-unknown-linux-musl.tar.gz
  archivePath: rg
  stripComponents: 1
  checksum:
    algorithm: sha256
    value: 4cf9f2741e6c465ffdb7c26f38056a59e2a2544b51f7cc128ef28337eeae4d8e
  installPath: ~/.local/bin/rg
```

## Docker, without hiding the repository in a shell step

Declare the repository and its key as typed data, so both are verified before
anything privileged happens:

```yaml
- type: rpm-repository
  name: docker
  baseUrl: https://download.docker.com/linux/fedora/$releasever/$basearch/stable
  gpgKeyUrl: https://download.docker.com/linux/fedora/gpg
  checksum:
    algorithm: sha256
    value: 0000000000000000000000000000000000000000000000000000000000000000

- type: packages
  name: docker
  packageManager: dnf
  packages: [docker-ce, docker-ce-cli, containerd.io]

- type: systemd-unit
  name: docker-service
  units:
    - { name: docker, enabled: true, state: started }

- type: user-groups
  name: docker-group
  groups: [docker]
```

The `user-groups` step raises a logout checkpoint on its own: `usermod -aG`
exits zero while your current session still lacks the group, which is why
`docker ps` keeps saying permission denied until you log out.

## A step that should only run once

Give it something observable:

```yaml
- type: shell-command
  name: rustup
  commands:
    - "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y"
  probeCommand: "test -x $HOME/.cargo/bin/rustup"
```

Better still, use the typed kind, which pins the installer:

```yaml
- type: toolchain
  name: rustup
  kind: RUSTUP
  installScriptUrl: https://sh.rustup.rs
  sha256: 6c30b75a75b28a96fd913a037c8581b580080b6ee9b8169a3c0feb1af7fe8caf
  installArgs: ["-y", "--no-modify-path"]
  probeCommand: "test -x $HOME/.cargo/bin/rustup"
```

When upstream changes the script the run fails rather than executing bytes
nobody reviewed. Read the new script, update the digest, rerun.

## A shell change that needs a logout

```yaml
jobs:
  - name: shell
    restartPolicy:
      type: prompt-logout
      message: "Log out and back in, then re-run fluxion."
    steps:
      - type: packages
        name: shell-tools
        packageManager: dnf
        packages: [zsh]
      - type: default-shell
        name: zsh-default
        shell: /bin/zsh
```

Fluxion records what completed, prints the resume command, and stops cleanly.

## Secrets in a step's environment

Mark them, and Fluxion masks them everywhere — previews, live output, failure
text, and state:

```yaml
- type: shell-command
  name: private-registry
  commands: ["npm install -g @acme/tool"]
  env:
    NPM_TOKEN:
      value: "${NPM_TOKEN}"
      sensitive: true
```

Names that look like secrets (`*_TOKEN`, `*_KEY`, `PASSWORD`, …) are treated as
sensitive without being marked.

## Ordering work

```yaml
jobs:
  - name: base
    steps: [...]

  - name: development
    dependsOn: [base]
    steps: [...]

  - name: desktop
    dependsOn: [base]
    steps: [...]
```

`development` and `desktop` both wait for `base` and are independent of each
other. If `base` fails, both are reported as blocked rather than run against a
machine that is not ready.

```bash
fluxion graph --format dot | dot -Tpng > jobs.png
```
