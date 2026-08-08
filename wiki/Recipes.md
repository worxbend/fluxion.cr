# Recipes

Patterns worth copying, and why they are shaped the way they are.

## One profile, several distributions

Let host facts choose, with a `when` rule on each step:

```yaml
apiVersion: initkit.io/v1alpha1
kind: WorkstationProfile
metadata:
  name: workstation
spec:
  target:
    os:
      distribution: fedora
  phases:
    - name: core
      steps:
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

Steps that do not match are reported as skipped with the reason, so the output
shows what the host excluded rather than quietly omitting it. A `when` on the
phase itself skips everything inside it, and each of those steps is still
listed.

`spec.target.os` still names one distribution, and `validate` measures package
kinds against it — but a step whose `when` narrows the distribution is exempt.
The guard already says which machine that step is for, so `core-arch` above is
accepted even though the target is Fedora. A step with no such guard is still
checked, which is what catches a genuine mistake like an `apt` step in a profile
targeting Fedora.

## A binary that is not packaged

Binaries are installed by [binstaller](https://github.com/worxbend/binstaller),
which reads its own profile. Fluxion points at it:

```yaml
- name: portable-tools
  kind: binstaller-profile
  spec:
    config: ./binstaller.yaml
```

```yaml
# binstaller.yaml
apiVersion: binstaller.io/v1alpha1
kind: BinaryDistributionProfile
spec:
  policy:
    # strict refuses missing checksums, mutable URLs, sudo symlinks and tar.xz.
    mode: strict
    appsDir: "${HOME}/.apps"
  plan:
    - name: kubectl
      kind: binary-tool
      spec:
        installDir: "${HOME}/.local/bin"
        download:
          url: https://dl.k8s.io/release/v1.30.2/bin/linux/amd64/kubectl
          checksum:
            algorithm: sha256
            value: c6e9c45ce3f82c90663e3c30db3b27c167e8b19d83ed4048b61c1013f6a7c66e
        executables:
          - path: kubectl

    # From an archive, name the exact member.
    - name: ripgrep
      kind: binary-tool
      spec:
        installDir: "${HOME}/.local/bin"
        download:
          url: https://github.com/BurntSushi/ripgrep/releases/download/14.1.0/ripgrep-14.1.0-x86_64-unknown-linux-musl.tar.gz
          checksum:
            algorithm: sha256
            value: 4cf9f2741e6c465ffdb7c26f38056a59e2a2544b51f7cc128ef28337eeae4d8e
          archive:
            type: tar.gz
            stripComponents: 1
            extract:
              files:
                - from: rg
                  to: rg
        executables:
          - path: rg
```

Fluxion hashes that file, so editing it re-runs the step. `fluxion lint` warns
if it is not in strict mode or if an entry declares no checksum.

## Docker, without hiding the repository in a shell step

Declare the repository and its key as typed data, so both are verified before
anything privileged happens:

```yaml
- name: docker-repo
  kind: rpm-repository
  spec:
    baseUrl: https://download.docker.com/linux/fedora/$releasever/$basearch/stable
    gpgKeyUrl: https://download.docker.com/linux/fedora/gpg
    checksum:
      algorithm: sha256
      value: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef

- name: docker
  kind: dnf-packages
  spec:
    packages: [docker-ce, docker-ce-cli, containerd.io]

- name: docker-service
  kind: systemd-unit
  spec:
    units:
      - { name: docker, enabled: true, state: started }

- name: docker-group
  kind: user-groups
  spec:
    groups: [docker]
```

Declaring the repository under `spec.sources` instead runs it as a prelude,
before any dnf step in any phase. Use a step, as here, when the ordering has to
be yours.

The `user-groups` step raises a logout checkpoint on its own: `usermod -aG`
exits zero while your current session still lacks the group, which is why
`docker ps` keeps saying permission denied until you log out.

## A step that should only run once

Give it something observable:

```yaml
- name: rustup
  kind: commands
  spec:
    commands:
      - "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y"
    probeCommand: "test -x $HOME/.cargo/bin/rustup"
```

Better still, use the typed kind, which pins the installer:

```yaml
- name: rustup
  kind: toolchain
  spec:
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
phases:
  - name: shell
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
```

Fluxion records what completed, prints the resume command, and stops cleanly.

## Secrets in a step's environment

Mark them, and Fluxion masks them everywhere — previews, live output, failure
text, and state:

```yaml
- name: private-registry
  kind: commands
  spec:
    commands:
      - run: "npm install -g @acme/tool"
        env:
          NPM_TOKEN:
            value: "${NPM_TOKEN}"
            sensitive: true
```

Names that look like secrets (`*_TOKEN`, `*_KEY`, `PASSWORD`, …) are treated as
sensitive without being marked.

`${NPM_TOKEN}` is resolved from the environment when the profile is read, so the
variable has to be exported before `validate` or `apply` — an unresolved one is
an error rather than an empty string.

## Ordering work

```yaml
phases:
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
fluxion graph --format dot | dot -Tpng > phases.png
```
