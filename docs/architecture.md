# Architecture

Fluxion is a Crystal CLI for bootstrapping Linux workstations. The source is
layered, and the dependency direction is strict:

```
cli ─┬─> tui ──────┐
     ├─> registry ─┤
     │             ├──> executor ──> state
     └─────────────┴──> config ────> core
                                     ▲
                             host ───┘
```

Nothing points back up. `core` depends on nothing; `cli` depends on everything.

## Layers

### `core` — the domain model

Validated data describing what a profile asks for. No processes, no terminal,
no YAML, no network. Everything above depends on it.

This is what lets `plan`, `dry-run`, `explain`, and `apply` share one
description of the work and disagree only about whether to carry it out. A
`Step` knows what it wants installed; it has no idea how.

### `host` — what machine is this?

`/etc/os-release` parsing, architecture, `PATH` lookup, and the target user
under `sudo`. Separate from `core` because it reads the world, and separate
from `executor` because `plan` needs it without constructing one.

### `config` — YAML in, domain model out

One document shape lands on one `Profile`: a `WorkstationProfile` manifest whose
`spec.phases[]` is the phase DAG and whose steps are selected by host facts and
`when` rules. There is one schema on purpose: a second document shape would mean
a second vocabulary for the same concept and a second validation path to keep in
agreement with the first.

The document is walked by hand rather than deserialized into DTOs. That buys
two things worth the extra code: every diagnostic names the exact config path
that caused it (`spec.phases[1].steps[0].spec.packages[2]`), and one field can
accept the several shapes the schema allows without a separate type per shape.

Diagnostics accumulate rather than raising, so a profile with five mistakes
takes one run to fix.

### `executor` — everything that touches the world

Processes, the filesystem, the network, and the trust checks that guard them.

- **Redaction** has two jobs, both mandatory: secrets must not reach the
  terminal or state, and untrusted text must not be able to drive the terminal.
  Package output gets printed, so escape sequences, backspace overprinting, and
  bidi overrides are stripped before anything is displayed.
- **`ShellRunner`** is an interface. `SystemShellRunner` spawns real processes;
  `FakeShellRunner` records argv and replays canned results, which is how every
  step executor is tested without a package manager present.
- **Step executors** produce commands. `dry-run` prints them and `apply` runs
  them from the same method, so a preview cannot describe something other than
  what runs.
- **Probes** answer "is this already here" without changing anything.
- **The orchestrator** owns ordering, skip decisions, failure propagation, and
  cancellation, leaving each executor ignorant of everything but its own
  commands.

### `state` — what previous runs recorded

Successful items with their versions and checksums, completed phases with a
fingerprint of their configuration, and where to resume.

A completed phase is skipped only while its fingerprint still matches, so
editing a package list makes the phase run again rather than being silently
considered done.

### `registry` — profiles shared through a git repository

Reads a manifest out of a git clone and installs the profiles it names. It sits
beside `executor` rather than inside it: a registry moves files, never
processes, and installing is deliberately not applying.

Two locations, deliberately separate. The **mirror** is a shallow clone under
the cache directory and is disposable. The **installed** directory under the
config directory holds what the user chose, and a sync never overwrites it. If
the clone were the install destination, "installed" would mean nothing.

Git runs through `Executor::ShellRunner` rather than a direct spawn, so the
commands are observable in specs and inherit the same redaction and timeout
handling as every other process Fluxion starts. Installing goes through
`Config::Loader`, so a profile that cannot be parsed is refused before it lands
rather than at the first `apply`.

### `tui` and `cli` — the two front ends

Both consume the same `ExecutionEvent` stream. The CLI reporter opens a line
per item and closes it with the outcome; the TUI keeps a live item list and a
bounded log. Neither knows anything about how work is performed.

## Trust boundaries

The rules that matter, and why each exists:

**Downloads.** HTTPS only, host required, no URL credentials — re-checked after
every redirect, because a redirect is an attacker-controllable hop. The size
ceiling is enforced while streaming, not after. A declared `Content-Length`
that does not match what arrived is a truncation, not a small file. On any
failure the partial file is deleted before raising, so no code path can return
an unverified download.

**Delegated installers.** Binaries and fonts are installed by `binstaller` and
`nerd-fonts-installer`, each from its own config. Fluxion verifies *the tool*:
the release asset must match a digest in `KnownTools`, or it is not installed,
and a copy already on `PATH` is used as-is rather than replaced. It does not
verify what the tool then installs — those checksums live in the tool's own
profile, which is the file Fluxion points at. `binstaller`'s
`spec.policy.mode: strict` is what makes that an even trade: it refuses missing
checksums, mutable URLs, sudo symlinks and `tar.xz`. Fluxion hashes the
referenced config's bytes so editing it re-runs the step, but never parses it —
those schemas belong to those tools.

This is a deliberate narrowing. Fluxion used to carry a `binary-downloads` kind
with its own download, signature and archive handling; one bootstrapper
reimplementing a package manager badly is worse than delegating to a tool whose
whole job it is.

**Privileged commands.** A `sudo` step becomes
`sudo -n -- <resolved target> …`. The `-n` means it can never sit waiting for a
password on a terminal nobody is watching. The target is resolved to a real
path under a root-owned system directory with no group- or other-writable
ancestor, because a writable parent means the file can be swapped.

**Privileged installs.** Staged under a root-owned anchor, digest re-verified
*there*, then moved into place. A world-writable temp directory is exactly
where a swap would happen. Without a digest to re-verify, the privileged path
refuses to run at all.

**Archives.** Only `tar.gz` is extracted in-process, and only to unpack a
delegated tool's own release asset. The reader bounds the *decompressed* stream
rather than the compressed file, which is what stops a decompression bomb;
selection is by exact post-strip path, never basename, and two members sharing
one is refused. Everything a profile installs is unpacked by the tool that
installs it, so Fluxion needs no `.zip` or `.tar.xz` parser.

**Running as root.** `apply` refuses. There is no safe way to drop back to the
user's account for the steps that must not be root-owned, and a half-root home
directory is worse than not starting.

## Failure model

Errors are a closed set (`ConfigError`, `ValidationError`, `ExecutionError`,
`TrustError`, `HostError`, `CancelledError`), each mapping to a stable exit
code. Anything else escaping is a bug.

The CLI prints one sanitized line and never a stack trace: a profile with a
typo is a normal outcome, and burying the message under a backtrace helps
nobody.

## Testing

`FakeShellRunner` is the backbone. A step executor's real contract is the argv
it builds and how it reads a result, and both are observable without spawning
anything. Specs run in milliseconds and pass on a machine with no package
manager at all.

The shipped example profiles are the end-to-end check: they exercise every step
kind against the real schema, so a regression in any parser shows up there
first. The example registry under `examples/registry/` does the same for the
registry format, and its specs run the whole add/sync/install/publish loop
against a real git repository served over `file://`.

## Layout

```
src/fluxion/
  core/          domain model, no IO
  host.cr        host detection
  config/        YAML → domain model
  executor/      processes, downloads, trust, orchestration
    executors/   one file per family of step kinds
  state/         what previous runs recorded
  registry/      manifest, git mirror, and installed configurations
  cli/           commands, colour, the plain reporter
  tui/           screens, built on the vendored CryTUI
src/crytui/      vendored TUI toolkit (see VENDORED.md)
  spinner/       animated spinner widgets, ported from tui-spinner
```
