<p align="center">
  <b>Fluxion</b><br>
  Turn a fresh Linux machine into your machine.<br>
  One YAML file. One preview. One run. CLI or TUI.
</p>

<p align="center">
  <a href="https://github.com/worxbend/fluxion.cr/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/worxbend/fluxion.cr/actions/workflows/ci.yml/badge.svg"></a>
  <img alt="Crystal" src="https://img.shields.io/badge/Crystal-1.21-000000?logo=crystal&logoColor=white">
  <img alt="Linux" src="https://img.shields.io/badge/Linux-workstation%20bootstrap-2ea44f?logo=linux&logoColor=white">
  <img alt="License" src="https://img.shields.io/badge/license-MIT-blue">
</p>

---

## What it is

You write a YAML profile describing the machine you want. Fluxion shows you
exactly what it would do, then does the parts that make sense for the host it
is running on.

```bash
fluxion validate -c workstation.yaml   # is this profile sound?
fluxion dry-run  -c workstation.yaml   # what would it do?
fluxion apply    -c workstation.yaml   # do it
```

Nothing is guessed. Every remote artifact is pinned and verified before it
runs, every privileged step is explicit, and a preview describes the same
commands the real run executes — because both are produced by the same code.

## Why

Fresh machines are exciting for about five minutes. Then you remember you need
Git, Zsh, Docker, Flatpak apps, `kubectl`, Rust, fonts, dotfiles, shell setup,
and that one command you always forget.

Fluxion makes that repeatable without turning your dotfiles repo into a pile of
shell scripts nobody dares change.

## Install

```bash
curl --proto '=https' --tlsv1.2 -sSfL https://worxbend.github.io/fluxion.cr/install.sh | sh
```

The script resolves the latest release, verifies its published SHA-256 before
writing anything, and installs to `~/.local/bin/fluxion`. It does not touch
your shell startup files.

Piping a script to a shell means trusting whatever served it. Read it first if
you would rather:

```bash
curl --proto '=https' --tlsv1.2 -sSfL https://worxbend.github.io/fluxion.cr/install.sh -o install.sh
less install.sh && sh install.sh
```

### From source

```bash
git clone https://github.com/worxbend/fluxion.cr
cd fluxion.cr
shards install
shards build --release
./bin/fluxion --help
```

Requires Crystal 1.21 or newer.

## A small profile

```yaml
apiVersion: initkit.io/v1alpha1
kind: WorkstationProfile
metadata:
  name: my-laptop
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
            packages: [git, curl, jq, zsh]

    - name: development
      dependsOn: [base]
      steps:
        - name: binaries
          kind: binstaller-profile
          spec:
            config: ./binstaller.yaml
```

Packages install one process each, so one bad name never loses the rest of the
list. Phases run in dependency order, and a phase whose dependency failed is
reported as blocked rather than silently skipped.

Steps carry `when` rules, so one profile can do the right thing on Fedora and on
Arch — see [docs/config-schema.md](docs/config-schema.md).

## Commands

| Command | What it does |
|---|---|
| `apply` | Execute a profile |
| `dry-run` | The same traversal with mutation switched off |
| `plan` | The execution plan, as text, table, tree, or JSON |
| `status` | What is installed, missing, unknown, or drifted |
| `diff` | Only what differs from this host |
| `explain` | Why one phase or item would run or skip |
| `doctor` | Is this host ready for this profile? |
| `lint` | Profile quality and safety advice |
| `validate` | Would this profile run at all? |
| `list` | The steps a profile declares |
| `graph` | The phase dependency graph (Mermaid, DOT, JSON) |
| `kinds` | The kinds a phase step may declare |
| `state` | Inspect and edit what previous runs recorded |
| `report` | Render a report from that state |
| `tools` | The external tools Fluxion delegates to |
| `generate` | A starter profile for this machine |
| `snapshot` | A review-required inventory of this host |
| `import` | Turn what is installed into a profile |
| `registry` | Install profiles shared through a git repository |
| `remote-ls` | List what a registry offers |
| `spinners` | Preview the animations that mark work in flight |

Full reference: [docs/commands.md](docs/commands.md).

### Shared profiles

Profiles you want on more than one machine can live in a git repository and be
installed by id:

```bash
fluxion registry add https://github.com/you/fluxion-profiles
fluxion remote-ls
fluxion registry install workstation
```

Installing writes a file and stops — running it stays a separate, deliberate
step. See [docs/registry.md](docs/registry.md).

## What it will not do

These are deliberate, and each has a reason:

- **It will not run unverified bytes.** Every download is HTTPS-only with no
  URL credentials, re-validated after each redirect, size-bounded while
  streaming, and digest-checked before use. A detached signature must name a
  signer the profile explicitly trusts — a valid signature from an unknown key
  is not trust.
- **It will not trust `PATH` for anything privileged.** A `sudo` step becomes
  `sudo -n -- <resolved target>`, where the target is a real path under a
  root-owned system directory with no writable ancestor.
- **It will not apply as root.** There is no safe way to drop back to your
  account for the steps that must not be root-owned.
- **It will not prompt mid-run.** Items marked `confirm` need `--yes` up front.
  A run that waits for input is a run that hangs unattended.
- **It will not guess.** An unanswerable probe reports *unknown*, not
  *missing*: absence of evidence is not evidence of absence, and reinstalling
  on that basis would be wrong.

## Documentation

- [Command reference](docs/commands.md)
- [Config schema](docs/config-schema.md)
- [Registries](docs/registry.md)
- [Architecture](docs/architecture.md)
- [Development](docs/development.md)

Example profiles live in [`examples/`](examples).

## Relationship to the Java implementation

Fluxion began as a Java 25 / Mill / GraalVM project. This is a ground-up
Crystal reimplementation of the same product: the same command surface, the same
trust rules, and the same idea of what a profile describes.

State files written by the Java version are read directly, so upgrading does
not mean reinstalling everything you already have. Profiles are written
differently — the [migration
page](https://github.com/worxbend/fluxion.cr/wiki/Migrating-from-Java) maps the
old fields onto the current ones.

## Contributing

Small, boring improvements are welcome: clearer docs, more distro examples,
better validation messages, more installer kinds, sharper TUI details, safer
execution edges.

```bash
crystal spec                    # tests
./lib/ameba/bin/ameba src spec  # lints
crystal tool format src spec    # formatting
```

All three must be clean. See [docs/development.md](docs/development.md).

## Licence

MIT.
