# Port status

Tracks what the Crystal implementation covers against the Java behavioural
spec in this directory. Update it as work lands.

## Done

**Core domain** (`src/fluxion/core/`) — validated data with no IO. All 30 step
kinds, trust anchors, `when` conditions, restart policies, execution events and
results, the job/profile aggregate with dependency ordering.

**Config** (`src/fluxion/config/`) — both frontends onto one `Profile`:

- stable `profile`/`os`/`jobs` DAG schema, with `phases`/`modules` aliases
- `WorkstationProfile` manifest: 25 plan kinds, `${}` interpolation, `when`
  selection, `spec.sources`, did-you-mean suggestions
- diagnostics carry the exact config path and accumulate rather than raising

**Host detection** (`src/fluxion/host.cr`) — `/etc/os-release` parsing,
architecture, PATH lookup, target user under sudo.

**Executor** (`src/fluxion/executor/`):

- redaction: secret patterns, terminal-control stripping, streaming PEM masking
- process execution: merged streams, fiber pump, bounded capture, timeout kill
- sudo: `sudo -n -- <trust-resolved target>`, root-owned ancestry checks
- probes for packages, flatpak, remotes, repo files, paths, shells, git repos,
  git config, systemd units, groups, fonts, and `probeCommand`
- step executors for packages, flatpak, tool-packages, sdkman, system-update,
  user-groups, git-config, git-repo, systemd-unit, system-setting,
  default-shell, shell-reload, shell-command, shell-script (local), assert,
  manual
- orchestrator: ordering, blocking on failed dependencies, skip decisions,
  cancellation, interrupt checkpoints
- verified downloads: HTTPS-only with per-redirect revalidation, streaming
  byte ceiling, truncation detection, digest checked before the file is
  returned
- signature verification: gpg status output parsed rather than its exit code
  trusted; every VALIDSIG must name the configured signer; SHA-1 rejected
- checksum documents, treated as supplemental metadata only

**State** (`src/fluxion/state/`) — atomic private writes, schema versioning,
per-item and per-job records, job fingerprints.

**CLI** (`src/fluxion/cli/`) — `apply`, `dry-run`, `plan`, `validate`, `list`,
`graph`, `kinds`, with the colour layer and the live reporter.

## Remaining

### Executor

- **Step executors that download** (the download layer itself is done): `compiled-binary` (plus tar.gz extraction,
  atomic install, binstaller delegation), `gpg-key`, the four repository kinds,
  `flatpak-remote`, `oh-my-zsh`, `toolchain`, `nerd-fonts`, `dotbot`,
  `binstaller-profile`, `file-writes`, remote `shell-script`.
  Until these land the orchestrator reports `no executor for step kind '<k>'`
  and fails the step, which is deliberate — silently skipping trust-bearing
  work would be worse than failing.
- **Privileged atomic publication** (`executor.md` §6.8): stage under a
  root-owned anchor, verify the digest there, then `mv -fT` into place.
- **Sudo session**: one prompt per run, keepalive, `sudo -k` on exit.

### State

- Wire the orchestrator to record successes and job completions (the store is
  written but `apply` does not yet call it).
- Resume: `--from-job` from the recorded `nextJob`, and stale-state detection
  against the manifest fingerprint.

### CLI

Remaining commands from `cli.md`: `status`, `diff`, `explain`, `doctor`,
`lint`, `generate`, `snapshot`, `import`, `tools`, `report`, `state`
(show/path/reset/forget).

### TUI

`src/fluxion/tui/` is empty. CryTUI is vendored and verified. Needs the pre-run
selector (job → step → entry), the live execution screen, and the sudo prompt.

### Docs and repo

`docs/`, the GitHub Pages site with `install.sh`, the wiki, and CI/release
workflows for Crystal builds.

## Conventions

- `crystal spec` and `./lib/ameba/bin/ameba src spec` must both be clean.
- Commit gradually, Conventional Commits, no co-author trailer.
- The four spec documents here are the behavioural reference; consult them
  before changing anything user-visible.
