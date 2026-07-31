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
- type: shell-command
  name: cargo-tools
  commands: ["cargo install --locked eza"]
  probeCommand: "command -v eza"
```

`fluxion lint` flags steps that need one.

## "no executor for step kind"

The profile uses a step kind this build does not implement. Check `fluxion
kinds` and your Fluxion version.

## A job is "blocked"

One of its dependencies failed. Fluxion does not run a job whose prerequisites
did not complete, because the result would be misleading.

```bash
fluxion status --failed
```

Fix the failing job, then rerun with `--skip-already-installed`; the work that
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
