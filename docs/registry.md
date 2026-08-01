# Registries

A registry is a git repository holding profiles you want on more than one
machine. Fluxion can list what a registry offers, install entries from it by
id, and send your edits back.

```bash
fluxion registry add https://github.com/you/fluxion-profiles
fluxion remote-ls
fluxion registry install workstation
fluxion dry-run -c ~/.config/fluxion/registries/fluxion-profiles/workstation.yaml
```

Nothing is ever applied as a side effect of installing. `install` writes a file
and stops; running it is a separate, deliberate step.

## Two directories, on purpose

| Path | What it is |
|---|---|
| `~/.cache/fluxion/registries/<name>` | The **mirror** — a shallow git clone. Disposable. |
| `~/.config/fluxion/registries/<name>` | **Installed** configurations. Yours. |

`sync` refreshes the mirror and never touches the installed directory. That
separation is what makes "installed" mean something: if the clone were the
install destination, every sync would silently overwrite files you had edited.

The price is that the two can drift apart, so Fluxion records the digest of
what it installed (in `<install dir>/.fluxion/<id>.sha256`) and tells you which
side moved:

```text
base         locally edited
workstation  update available
server       current
```

Without that record a local edit and an upstream change look identical — the
bytes differ — and Fluxion could not tell you which of your changes it was
about to discard.

## Repository layout

The structure is declared, not discovered. A manifest fetched from a remote
repository decides what a machine will be told to install, so what it may name
is fixed:

```text
your-registry/
├── fluxion-registry.yaml     # the manifest, at the root, under this name
└── profiles/                 # every entry lives in here
    ├── base.yaml
    ├── workstation.yaml
    └── team/nested.yaml
```

`fluxion registry init` scaffolds exactly this.

### `fluxion-registry.yaml`

```yaml
apiVersion: fluxion.dev/registry/v1
kind: Registry

metadata:
  name: my-profiles
  description: Bootstrap configurations for my machines
  maintainer: you@example.com

entries:
  - id: base
    name: Base tools
    description: The handful of things every machine needs
    path: profiles/base.yaml
    distributions: [fedora, arch]
    tags: [core]

  - id: workstation
    name: Developer workstation
    path: profiles/workstation.yaml
    distributions: [fedora]
    tags: [developer]
    requires: [base]
```

| Field | Required | Meaning |
|---|---|---|
| `id` | yes | Lowercase letters, digits, `.`, `_`, `-`. It becomes the filename when installed, so it is constrained rather than escaped. |
| `path` | no | Defaults to `profiles/<id>.yaml`. Must be a normalized relative path inside `profiles/`. |
| `name` | no | Display name. Defaults to the id. |
| `description` | no | One line, shown in `remote-ls`. |
| `distributions` | no | Advisory. Drives the listing and a warning on install, never a refusal — a profile may legitimately be run somewhere its author did not anticipate. |
| `tags` | no | Matched by `--search`. |
| `requires` | no | Other ids this one expects alongside it. `install --with-requires` follows them. |

Each entry points at an ordinary Fluxion profile — the same schema as
[docs/config-schema.md](config-schema.md). Nothing about being in a registry
changes what a profile may contain.

### What the format refuses

- `path` outside `profiles/` — including `profiles/../../.ssh/id_ed25519`,
  absolute paths, and anything with `\` in it.
- A symlink in the repository that resolves outside it. Confinement is
  re-checked against the resolved path at read time, because the manifest
  cannot see where a symlink points.
- Files over 8 MiB, or anything that is not a regular file.
- A profile that does not parse. It is refused at install rather than at your
  first `apply`.
- `http://` registry URLs. Use https, ssh, or a local path.

## Commands

### `registry add`

```bash
fluxion registry add https://github.com/you/profiles
fluxion registry add git@github.com:team/profiles.git --name team --default
fluxion registry add https://example.com/profiles --ref stable
fluxion registry add https://example.com/profiles --no-sync
```

```text
--name=NAME    Local name [default: the repository name]
--ref=BRANCH   Branch or tag to track [default: the repository's default]
--default      Use this registry when none is named
--no-sync      Configure without cloning yet
```

Clones immediately unless `--no-sync`. The first registry you add becomes the
default whether or not you asked — with only one configured, every command
resolves to it anyway.

Registries are recorded in `~/.config/fluxion/registries.yaml`, written
`0600`.

### `registry list`, `registry remove`

```bash
fluxion registry list
fluxion registry list --format json
fluxion registry remove team
fluxion registry remove team --purge
```

`remove` always deletes the mirror — it is disposable — and leaves the
configurations installed from it alone unless you pass `--purge`.

### `registry sync`

```bash
fluxion registry sync
fluxion registry sync team
fluxion registry sync --all
```

Fetches and hard-resets the mirror, then reports which installed
configurations have changed upstream:

```text
demo … updated @ 33ba356
  1 installed configuration changed upstream:
    → workstation
  fluxion registry install <id> --force  to take the update
```

The mirror is reset rather than merged: it is a mirror, and a merge conflict in
a directory you never edit is a puzzle with no useful answer.

### `remote-ls` / `registry ls`

```bash
fluxion remote-ls
fluxion remote-ls --search editor
fluxion registry ls team --all
fluxion remote-ls --format json
```

```text
--search=TEXT   Match id, name, description, or tag
--installed     Only what is already installed
--all           Include entries written for other distributions
--format=FORMAT text (default), json
```

Entries written for another distribution are hidden by default — a long list of
things that cannot work here is noise — but anything already installed stays
visible regardless.

### `registry show`

```bash
fluxion registry show workstation
fluxion registry show workstation --format json
```

Prints the metadata, the drift state, and the profile itself. Read it before
installing something you did not write.

### `registry install`, `registry uninstall`

```bash
fluxion registry install workstation
fluxion registry install workstation --with-requires
fluxion registry install workstation --force
fluxion registry uninstall workstation
```

```text
--registry=NAME   Which registry to use
--force           Overwrite local edits
--with-requires   Also install what this entry requires
```

Installs to `~/.config/fluxion/registries/<registry>/<id>.yaml`.

An upstream change installs without ceremony; local edits are refused until you
pass `--force` or publish them. A distribution mismatch is a warning, not a
refusal.

### `registry edit`

```bash
EDITOR=nvim fluxion registry edit workstation
```

Opens the installed copy in `$VISUAL` or `$EDITOR`, then validates it — a typo
becomes a message now rather than a failure on the next apply.

### `registry status`

```bash
fluxion registry status
fluxion registry status --format json
```

Every installed configuration and how it compares to the registry, plus
anything installed that the registry no longer publishes — usually an entry
that was renamed or withdrawn upstream.

### `registry publish`

```bash
fluxion registry publish --dry-run
fluxion registry publish --message "Add ripgrep to base"
fluxion registry publish --id base
```

```text
--registry=NAME   Which registry to use
--message=TEXT    Commit message
--id=ID           Publish only this entry (repeatable)
--dry-run         Show what would be published, change nothing
```

Copies your edited configurations into the mirror, commits, and pushes.
Anything that changed both locally *and* upstream is refused rather than
resolved by guessing — reconcile it first, using `registry show <id>` to see
the registry's version.

Publishing deepens the shallow clone first, so it is slower than every other
registry command. That is the right trade: reading happens constantly, pushing
almost never.

### `registry init`

```bash
fluxion registry init
fluxion registry init ~/src/my-profiles --name my-profiles
```

Writes `fluxion-registry.yaml` and a `profiles/` folder with one example. Push
it to a git host, then `fluxion registry add <url>`.

## Private registries

ssh URLs work with whatever key your ssh agent already has:

```bash
fluxion registry add git@github.com:you/private-profiles.git
```

Terminal prompting is disabled for every git call, so a registry you have no
credentials for fails immediately instead of hanging on a username prompt
nobody is watching.

## Sharing profiles across machines

A common shape: one `base` entry every machine installs, and per-role entries
that require it.

```bash
# on a new machine
fluxion registry add git@github.com:you/profiles.git
fluxion registry install workstation --with-requires
fluxion doctor
fluxion dry-run -c ~/.config/fluxion/registries/profiles/workstation.yaml
fluxion apply  -c ~/.config/fluxion/registries/profiles/workstation.yaml

# after changing something
fluxion registry edit workstation
fluxion registry publish --message "Switch to helix"
```
