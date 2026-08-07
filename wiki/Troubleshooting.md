# Troubleshooting

## "Refusing to apply as root"

Run it as yourself. Fluxion escalates per step, and there is no safe way to
drop back to your account for the steps that must not be root-owned — a
dotfiles checkout or a `~/.cargo` created by root is a mess to unpick.

```bash
fluxion apply          # yes
sudo fluxion apply     # no
```

## "explicit confirmation required; re-run with --yes"

A step declared `confirm`. Fluxion does not prompt for these in either mode: a
run that waits for input is a run that hangs unattended in CI or under a
timeout.

```bash
fluxion apply --yes
```

Read the dry run first — `confirm` is there because someone thought the step
warranted it.

## "Checksum mismatch"

The bytes served are not the bytes your profile pinned. Either upstream
republished the artifact, or something is wrong.

Fluxion fails closed on purpose. Download the artifact yourself, check it
against the project's published checksum, and update the profile only once you
have satisfied yourself the new bytes are the ones you want.

## "Signature was not made by the configured allowed signer"

`gpg` verified a signature, but from a different key than your profile trusts.

This is exactly the case a bare `gpg --verify` misses: it exits zero for a
signature made by any key it happens to have. Check whether the project rotated
its signing key, and update `allowedSignerFingerprint` deliberately.

## An item shows as "unknown"

Fluxion could not answer whether it is installed — usually the probe command is
missing, or the step has no observable footprint.

Unknown is not missing. Fluxion will not reinstall on the strength of a failed
check. Add a `probeCommand` to make it answerable:

```yaml
- name: cargo-tools
  kind: commands
  spec:
    commands: ["cargo install --locked eza"]
    probeCommand: "command -v eza"
```

`fluxion lint` flags steps that need one.

## "no executor for step kind"

The profile uses a step kind this build does not implement. Check `fluxion
kinds` and your Fluxion version.

## A phase is "blocked"

One of its dependencies failed. Fluxion does not run a phase whose prerequisites
did not complete, because the result would be misleading.

```bash
fluxion status --failed
```

Fix the failing phase, then rerun with `--skip-already-installed`; the work that
succeeded is not repeated.

## The TUI does not appear

It needs a real terminal on both stdin and stdout. In CI, a pipe, or a build
tool, Fluxion falls back to plain output automatically — a UI nobody can see
would just be a hang.

Force plain output with `--no-tui`.

## Colours in a log file

There should not be any: colour is disabled automatically when stdout is not a
terminal. `NO_COLOR=1` disables it everywhere, and `--no-color` does it for one
run.

## State looks wrong

```bash
fluxion state show           # what was recorded
fluxion state forget --item git --step core-tools --type package
fluxion state reset --force  # start over
```

Resetting state does not uninstall anything. It only forgets, so the next run
re-probes.

## "\<name\> has not been synced yet"

The registry is configured but has never been cloned — usually because it was
added with `--no-sync`, or the first clone failed.

```bash
fluxion registry sync <name>
```

If the clone itself fails, test the URL directly with `git ls-remote <url>`.
Fluxion disables terminal prompting for every git call, so an authentication
problem fails immediately instead of hanging; the fix is in your ssh agent or
credential helper, not in Fluxion.

## "Several registries are configured and none is the default"

With more than one registry, commands refuse to guess:

```bash
fluxion registry list
fluxion remote-ls work                 # name one for a single command
fluxion registry install x --registry work
```

Adding a registry with `--default` marks it permanently. The first registry you
add becomes the default automatically.

## "\<file\> has local edits"

You edited an installed configuration, and the registry has a different version.
Nothing is overwritten until you choose:

```bash
fluxion registry status                   # which side moved
fluxion registry publish                  # keep yours, send it upstream
fluxion registry install <id> --force     # take theirs, losing your edits
```

## "changed both locally and upstream"

Both copies moved, and Fluxion will not merge them for you:

```bash
fluxion registry show <id> > /tmp/upstream.yaml
diff /tmp/upstream.yaml ~/.config/fluxion/registries/<registry>/<id>.yaml
```

Fold one into the other, then publish or force-install. See
**[Registries](Registries)**.

## "resolves outside the registry"

An entry in the manifest points at a symlink leading out of the repository.
Confinement is re-checked against the resolved path, because the manifest
cannot see where a symlink goes. This is the registry's problem to fix: entries
must be real files inside `profiles/`.
