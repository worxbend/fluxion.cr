# Registries

Sharing profiles between machines, using a git repository you control.

The format reference is
[docs/registry.md](https://github.com/worxbend/fluxion.cr/blob/main/docs/registry.md).
This page is the practical side: how to set one up, and what to do when the
two copies disagree.

## Setting one up

```bash
mkdir ~/src/fluxion-profiles && cd ~/src/fluxion-profiles
fluxion registry init --name my-profiles
git init -b main && git add -A && git commit -m "Initial registry"
gh repo create you/fluxion-profiles --private --source=. --push
```

`init` writes two things: `fluxion-registry.yaml` at the root, and a
`profiles/` folder. Those paths are fixed — a manifest that could name any file
in the repository could name any file at all, and this is a file that tells a
machine what to install.

Then, from any machine:

```bash
fluxion registry add git@github.com:you/fluxion-profiles.git
fluxion remote-ls
```

## Filling it in

Start from what you already run:

```bash
cp ~/.config/fluxion/default.yaml ~/src/fluxion-profiles/profiles/workstation.yaml
```

and add an entry:

```yaml
entries:
  - id: workstation
    name: Developer workstation
    description: Editors, toolchains, and the shell setup I expect everywhere
    path: profiles/workstation.yaml
    distributions: [fedora]
    tags: [developer]
```

The id becomes the filename when someone installs it, so it is lowercase and
free of separators. Everything else is optional; `path` defaults to
`profiles/<id>.yaml`.

## The base-plus-role pattern

The shape most people converge on: one entry every machine installs, and
per-role entries that require it.

```yaml
entries:
  - id: base
    name: Base tools
    path: profiles/base.yaml
    tags: [core]

  - id: workstation
    name: Developer workstation
    path: profiles/workstation.yaml
    requires: [base]

  - id: server
    name: Headless server
    path: profiles/server.yaml
    requires: [base]
    distributions: [debian]
```

```bash
fluxion registry install workstation --with-requires
```

`requires` is followed in order, so `base` lands before the profile that builds
on it. Without `--with-requires` Fluxion installs only what you asked for and
mentions what it did not.

## One registry, several distributions

Two options, and they compose.

**Separate entries.** Clearest when the profiles genuinely differ:

```yaml
entries:
  - id: base-fedora
    path: profiles/base-fedora.yaml
    distributions: [fedora]
  - id: base-arch
    path: profiles/base-arch.yaml
    distributions: [arch]
```

`remote-ls` hides entries written for other distributions, so each machine sees
a short list of things that can actually work on it. Pass `--all` to see
everything.

**One profile with `when` rules.** Better when the difference is a handful of
package names — see the
[config schema](https://github.com/worxbend/fluxion.cr/blob/main/docs/config-schema.md),
which selects each phase and step from host facts. Leave `distributions` off the
registry entry so it is offered everywhere.

## Where things live

```text
~/.cache/fluxion/registries/<name>     the git clone     — disposable
~/.config/fluxion/registries/<name>    what you installed — yours
```

`sync` only ever touches the first. That is the whole reason there are two: if
the clone were the install destination, every sync would silently overwrite
files you had edited.

`fluxion registry remove <name>` deletes the clone and leaves your installed
configurations alone. `--purge` deletes those too.

## Keeping machines in step

```bash
fluxion registry sync
```

```text
demo … updated @ 33ba356
  1 installed configuration changed upstream:
    → workstation
  fluxion registry install <id> --force  to take the update
```

Sync does not install anything. It tells you what moved and stops, because
overwriting a machine's configuration as a side effect of fetching would be the
wrong default.

To take the update:

```bash
fluxion registry install workstation      # no --force needed if you have not edited it
fluxion dry-run -c ~/.config/fluxion/registries/my-profiles/workstation.yaml
fluxion apply  -c ~/.config/fluxion/registries/my-profiles/workstation.yaml
```

## Changing something

Edit the installed copy, then publish it:

```bash
fluxion registry edit workstation
fluxion registry publish --message "Switch to helix"
```

`edit` validates on save, so a typo becomes a message immediately rather than a
failure on your next apply. `publish` copies the file into the clone, commits,
and pushes.

Check first if you like:

```bash
fluxion registry publish --dry-run
```

## When both sides changed

`fluxion registry status` names four states:

| State | What it means |
|---|---|
| `current` | Installed and identical to the registry |
| `update available` | The registry moved; your copy is untouched |
| `locally edited` | You changed it; the registry has not |
| `edited, update available` | Both moved |

The last one is the only awkward case, and Fluxion refuses to resolve it:

```text
Error: workstation changed both locally and upstream. Reconcile them first —
`fluxion registry show <id>` prints the registry's version.
```

Neither answer is safe to guess at. To reconcile:

```bash
fluxion registry show workstation > /tmp/upstream.yaml
diff /tmp/upstream.yaml ~/.config/fluxion/registries/my-profiles/workstation.yaml
```

Then either keep yours (`publish` once the upstream change is folded in) or
take theirs (`install --force`, losing your edits).

Fluxion knows which side moved because it records the digest of what it
installed. Without that record the two look identical — the bytes differ — and
it could not tell you which of your changes it was about to discard.

## Private registries

ssh URLs use whatever key your agent already has:

```bash
fluxion registry add git@github.com:you/private-profiles.git
```

Terminal prompting is disabled for every git call, so a registry you have no
credentials for fails immediately rather than hanging on a username prompt in a
script nobody is watching. If `add` fails with an authentication error, test the
same URL with `git ls-remote` — the problem is in your ssh setup, not in
Fluxion.

`http://` URLs are refused outright. A registry decides what a machine will be
told to install; it has to arrive over something authenticated.

## Several registries

```bash
fluxion registry add https://github.com/you/profiles --name mine --default
fluxion registry add git@github.com:acme/profiles.git --name work

fluxion remote-ls work
fluxion registry install onboarding --registry work
```

With more than one configured and no default marked, commands refuse to guess
rather than picking the first. Mark one with `--default`.

## Trying it without a remote

The repository ships an example registry. A registry is always a git
repository, so copy it somewhere and make one — then everything, including
`publish`, works against a throwaway:

```bash
cp -r examples/registry /tmp/example-registry
git -C /tmp/example-registry init -q -b main
git -C /tmp/example-registry add -A
git -C /tmp/example-registry commit -qm "Example registry"
git -C /tmp/example-registry config receive.denyCurrentBranch updateInstead

fluxion registry add file:///tmp/example-registry --name example
fluxion remote-ls --all
fluxion registry show developer
fluxion registry install developer --with-requires
fluxion registry edit developer
fluxion registry publish --message "Try publishing"
fluxion registry remove example --purge
```

`receive.denyCurrentBranch updateInstead` is only needed because the push
target here has a working tree checked out; a repository on a git host does
not need it.
