# Command reference

Fluxion is built around a read-first workflow. The safe commands come first
and the one that changes anything comes last:

```bash
fluxion generate --output ~/.config/fluxion/default.yaml
fluxion validate                 # would this run at all?
fluxion lint                     # is it a good profile?
fluxion doctor                   # is this host ready?
fluxion plan                     # what would happen, in order?
fluxion diff                     # what differs from this machine?
fluxion dry-run                  # the real traversal, mutation off
fluxion apply                    # do it
```

## Global options

```text
-c, --config=FILE   Profile path [default: ~/.config/fluxion/default.yaml]
    --no-tui        Plain stdout instead of the terminal UI
-v, --verbose       More detail, including backtraces on unexpected errors
    --color         Force colour
    --no-color      Disable colour
-h, --help          Help for a command
-V, --version       Version
```

Colour is decided from whether stdout is a terminal, honouring `NO_COLOR` and
`FORCE_COLOR`. Output piped into a file or a pager is plain automatically, so
it is safe to parse without passing a flag.

## Exit codes

Scripts branch on these, so they are fixed:

| Code | Meaning |
|---:|---|
| 0 | Success |
| 1 | Unexpected failure (a bug) |
| 2 | Bad arguments, or a selector matching nothing |
| 3 | The profile could not be loaded or did not validate |
| 4 | Local filesystem or stream failure |
| 5 | Something outside Fluxion failed |
| 75 | Stopped at an explicit checkpoint — not a failure |
| 130 | Stopped at a safe boundary after an interrupt |

---

## `apply`

Executes a profile.

```bash
fluxion apply -c workstation.yaml
fluxion apply --phase base --phase desktop
fluxion apply --from-phase development --skip-already-installed
```

```text
--dry-run                 Show what would happen, change nothing
--phase=NAME              Run only these phases (repeatable, or comma-separated)
--from-phase=NAME         Start from this phase, skipping earlier ones
-y, --yes                 Approve items that declared confirm
--skip-already-installed  Skip work state or a probe says is done
--re-probe                Ignore saved state; trust only live probes
--probe-only              Probe and report, install nothing
--show-output             Echo each command's own output
--profile=NAME            State profile name [default: default]
```

With a real terminal on both ends, `apply` opens the selector first. Use
`--no-tui` for plain output, which happens automatically in CI or a pipe.

`apply` refuses to run as root: there is no safe way to drop back to your
account for the steps that must not be root-owned.

Items marked `confirm` need `--yes`. Fluxion does not prompt for them in
either mode — a run that waits for input is a run that hangs unattended.

The first Ctrl-C asks for a clean stop at the next item boundary and records
where to resume; the second exits immediately.

## `dry-run`

The same traversal as `apply` with mutation switched off.

```bash
fluxion dry-run -c workstation.yaml
```

A separate command rather than a flag alias, because it is the one people
reach for first and it should not be one character away from a real run.

## `plan`

The execution plan, without touching the host.

```bash
fluxion plan --format tree
fluxion plan --format json | jq '.phases[].name'
```

```text
--show-commands   Show the command preview for each item
--format=FORMAT   text (default), table, tree, json
```

## `status`

What is installed, missing, unknown, or drifted.

```bash
fluxion status
fluxion status --missing
fluxion status --summary --format json
```

```text
--summary         Only the aggregate counts
--missing         Only configured items that are missing
--state-only      Only state entries the profile no longer declares
--version-drift   Only items whose live version differs from state
--failed          Missing, unknown, and version-drift together
--format=FORMAT   text (default), json
```

The filters are not combinable: each answers one question, and intersecting
them produces a set nobody asked for.

An item Fluxion could not check is reported as **unknown**, not missing.
Absence of evidence is not evidence of absence, and reinstalling on that basis
would be wrong.

## `diff`

Only what differs from this host, grouped by what would happen.

```bash
fluxion diff
fluxion diff --format json
```

## `explain`

Why one phase or item would run or skip.

```bash
fluxion explain --phase development
fluxion explain --item git
```

Exactly one of `--phase` or `--item`. Items match on either their key or their
display name, so whichever one another command printed will work.

## `doctor`

Whether this host can run this profile.

```bash
fluxion doctor
fluxion doctor --skip-network
```

Checks the config, host detection, the state directory, `sudo`, every command
the profile's steps require, configured shells, and the reachability of remote
artifacts. Any failing check exits 5.

Answering before a run rather than during one matters: a missing `flatpak`
found halfway through an apply has already left the machine half-configured.

## `lint`

Profile quality and safety advice. Never fails.

```bash
fluxion lint
fluxion lint --format json
```

Flags downloads piped into a shell, commands that look destructive, embedded
`sudo`, steps with no observable footprint and no `probeCommand`, and manual
checkpoints that can never be marked complete.

Separate from `validate` on purpose: that answers "would this run", which is a
yes/no with an exit code. This is advice.

## `validate`

Loads, maps, and checks the profile.

```bash
fluxion validate
fluxion validate --strict
fluxion validate --format json
```

Every diagnostic names the config path that caused it, and all of them are
reported at once. `--strict` also fails on warnings.

## `list`

The steps a profile declares, with item counts.

```bash
fluxion list
fluxion list --format json
```

## `graph`

The phase dependency graph.

```bash
fluxion graph                    # Mermaid, for pasting into Markdown
fluxion graph --format dot | dot -Tpng > phases.png
fluxion graph --format json
```

## `kinds`

The kinds a phase step may declare, with the pre-install actions each package
kind accepts.

```bash
fluxion kinds
fluxion kinds --format json
```

Takes no config file: the answer is a property of the build. It reads the same
registry `validate` checks against, so the documented list cannot drift from
the accepted one.

## `state`

What previous runs recorded, under `~/.local/share/fluxion`.

```bash
fluxion state show
fluxion state show --format json
fluxion state path
fluxion state reset --force
fluxion state forget --item git --step core-tools --type package
fluxion state forget --phase base
```

`forget` refuses an ambiguous key rather than deleting several entries; qualify
it with `--step` and `--type`.

`reset` requires `--force` rather than prompting, so it stays usable from a
script without being one keystroke from disaster.

State files written by the Java implementation are read directly.

## `report`

A report from the recorded state.

```bash
fluxion report
fluxion report --format html > report.html
fluxion report --format json
```

## `tools`

The external tools Fluxion delegates to — `dotbot`, `nerd-fonts-installer`,
`binstaller`.

```bash
fluxion tools list
fluxion tools install binstaller
```

`list` shows each tool's pinned version and where it would come from: a copy
already on `PATH`, Fluxion's cache, or a download.

A tool already on `PATH` is used as-is and never replaced. Fluxion is a
bootstrapper, not a package manager for other people's tools.

## `generate`

A starter profile for this machine.

```bash
fluxion generate --output ~/.config/fluxion/default.yaml
fluxion generate --os fedora --preset developer --output starter.yaml
```

```text
--os=NAME         auto (default), fedora, arch, opensuse, debian
--preset=NAME     minimal (default), developer, desktop
--profile=NAME    Profile name [default: starter]
--output=PATH     Where to write it (required)
--force           Overwrite an existing file
```

Deliberately free of personal defaults: it produces something to read and
edit, not something to run unexamined.

## `snapshot`

A read-only inventory of this host.

```bash
fluxion snapshot --output snapshot.json
```

Records `/etc/os-release` fields, detected package managers, installed package
names, Flatpak apps, the default shell, and which common tools are present.

It does not read shell history, dotfile contents, or credentials: a snapshot is
something people paste into issues.

## `import`

Turns what is installed into a profile.

```bash
fluxion import packages --from-host --output packages.yaml
fluxion import flatpaks --from-host --output flatpaks.yaml
```

The output is a complete, valid profile — so it can be validated and previewed
immediately — and the phase inside it lifts straight into an existing profile.

Review it before applying. On Arch it lists explicitly installed packages only,
because a fragment enumerating every transitive dependency is unusable.

## `registry`

Profiles shared through a git repository, installed by id.

```bash
fluxion registry add https://github.com/you/fluxion-profiles
fluxion remote-ls
fluxion registry install workstation --with-requires
fluxion registry status
fluxion registry sync
```

| Subcommand | What it does |
|---|---|
| `add <url>` | Configure a registry and clone it |
| `list` | The configured registries |
| `remove <name>` | Forget one (`--purge` also deletes what it installed) |
| `sync [name]` | Fetch the latest, and say what changed upstream |
| `ls [name]` | What the registry offers |
| `show <id>` | One configuration in detail, including the profile itself |
| `install <id>` | Install it to `~/.config/fluxion/registries/<registry>/<id>.yaml` |
| `uninstall <id>` | Remove an installed configuration |
| `edit <id>` | Open the installed copy in `$EDITOR`, then validate it |
| `status` | How installed configurations compare to the registry |
| `publish` | Send local edits back to the registry |
| `init [dir]` | Scaffold a registry repository |

The git clone lives in the cache directory and is disposable; installed
configurations live under the config directory and are yours. `sync` refreshes
the first and never touches the second.

Installing never applies anything. It writes a file and stops.

Full reference, including the manifest format: [docs/registry.md](registry.md).

## `remote-ls`

The top-level spelling of `registry ls`, because it is the first thing anyone
reaches for.

```bash
fluxion remote-ls
fluxion remote-ls --search editor
fluxion remote-ls --all --format json
```

```text
--registry=NAME  Which registry to use
--search=TEXT    Match id, name, description, or tag
--installed      Only what is already installed
--all            Include entries written for other distributions
--format=FORMAT  text (default), json
```
