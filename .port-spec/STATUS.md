# Port status

Tracks the Crystal implementation against the Java behavioural spec in this
directory. Update it as work lands.

## Complete

**Core domain** (`src/fluxion/core/`) — validated data with no IO. All step
kinds, trust anchors, `when` conditions, restart policies, execution events and
results, the job/profile aggregate with dependency ordering.

**Config** (`src/fluxion/config/`) — both frontends onto one `Profile`:

- stable `profile`/`os`/`jobs` DAG schema, with `phases`/`modules` aliases
- `WorkstationProfile` manifest: 25 plan kinds, `${}` interpolation, `when`
  selection, `spec.sources`, did-you-mean suggestions
- diagnostics carry the exact config path and accumulate rather than raising

**Host detection** (`src/fluxion/host.cr`) — `/etc/os-release`, architecture,
PATH lookup, target user under sudo.

**Executor** (`src/fluxion/executor/`):

- redaction: secret patterns, terminal-control stripping, streaming PEM masking
- process execution: merged streams, fiber pump, bounded capture, timeout kill
- sudo: `sudo -n -- <trust-resolved target>`, root-owned ancestry checks
- verified downloads: HTTPS-only with per-redirect revalidation, streaming byte
  ceiling, truncation detection, digest checked before the file is returned
- signature verification: gpg status output parsed rather than its exit code
  trusted; every VALIDSIG must name the configured signer; SHA-1 rejected
- checksum documents, treated as supplemental metadata only
- bounded tar.gz extraction: decompressed stream bounded, exact post-strip
  path matching, ambiguity refused
- atomic installer with a privileged path that re-verifies after staging
- probes for every kind with an observable footprint, plus `probeCommand`
- **every step kind has an executor** — verified by previewing all nine example
  profiles with zero unhandled kinds
- orchestrator: ordering, blocking on failed dependencies, skip decisions,
  cancellation, interrupt checkpoints

**State** (`src/fluxion/state/`) — atomic private writes, schema versioning,
per-item and per-job records, job fingerprints, resume points, and migration
from the Java schema.

**CLI** (`src/fluxion/cli/`) — all eighteen commands: `apply`, `dry-run`,
`plan`, `status`, `diff`, `explain`, `doctor`, `lint`, `state`, `report`,
`tools`, `generate`, `snapshot`, `import`, `validate`, `list`, `graph`,
`kinds`. Colour layer and live reporter.

**TUI** (`src/fluxion/tui/`) — pre-run selector and live execution screen on
the vendored CryTUI.

**Docs** — README, `docs/` (commands, config schema, workstation profiles,
architecture, development), the GitHub Pages site with `install.sh`, and
`wiki/`.

**CI** — formatting, lints, specs, build, then validating and previewing every
example profile. Release builds a static binary per architecture with a
combined checksum file.

## Known gaps

- **Sudo session.** Each privileged command runs `sudo -n` independently. A
  session that authenticates once per run — with a keepalive and `sudo -k` on
  exit — is not implemented, so a host whose sudo timestamp has expired will
  fail privileged steps rather than prompting once up front.
- **`.zip` and `.tar.xz` delegation.** Recognised and refused with an
  explanation. Fluxion does not yet drive `binstaller` for them.
- **TUI sudo prompt.** The selector and execution screens are complete; there
  is no in-TUI password prompt, so privileged steps rely on an existing sudo
  timestamp.
- **Wiki publication.** Pages are written and ready in `wiki/`; GitHub wikis
  are unavailable for this repository while it is private on the free plan.
  See `wiki/README.md`.

## Deliberate divergences from the Java implementation

- `--phase` is `--job`. One vocabulary throughout, matching the docs.
- `import` emits a complete profile rather than a bare fragment, so the output
  validates and previews without hand-editing a header onto it.
- Colour is automatic and honours `NO_COLOR`.
- State schema numbering continues from the Java version's 7, so a machine that
  has run both never sees a version go backwards.
- `file-writes` items have no `sudo` flag. Privilege is derived by
  `Installer#privilege_for` from the destination's parent directory rather than
  declared per item, so a profile cannot ask for a privileged write into a
  directory it can already write, nor opt out of `sudo` for `/etc`.
- **apt probe argv** (`executor.md`, probe table, apt package). The format is
  `${Status}|${Version}\n`, not tab-separated: the shell runner turns every
  control character except a newline into a space, so the tab never reached
  the probe (d26a299). Installed means state `installed`, flag `ok`, and want
  `install` or `hold`, so a package held with `apt-mark hold` counts as
  installed (d6f0caf); the Java version only accepted `install ok installed`.
- **flatpak probe argv** (`executor.md`, probe table, flatpak). It lists every
  installed ref, `["flatpak","list","--columns=application"]`, without
  `--app`, so the runtime refs a flatpak step installs (OBS plugins, GL
  drivers, theme extensions) are found after their install (7430ef4).
- **gpg key inspect argv** (`executor.md`, GPG keys). It adds
  `--homedir <throwaway dir>`: with `--no-options` gpg will not create a
  missing `~/.gnupg`, so every read failed on a fresh account (c34113b).
- **prompt-logout** (`executor.md`, phase finish; `cli.md`, exit mapping). A
  completed prompt-logout phase is recorded as completed and `apply` exits 75,
  the checkpoint code, instead of 0 (4254ceb). The restart event is only
  emitted when an item of the phase ran; a phase whose items were all skipped
  or were only asserts completes like any other and the run carries on
  (d699c4a). The Java version emitted `restartRequired` after every completed
  prompt-logout phase and stopped with exit 0.
- **owed logout** (`executor.md`, phase finish; state schema). A prompt-logout
  phase that changed the host and then failed or was cancelled is listed under
  `pendingLogout` in the state file, still schema 8 because the field is
  optional. The run that completes the phase asks for the logout even when
  every item is skipped by then, and clears the entry; a phase that owes one
  is never skipped whole. The Java version had no such record.
- **probeCommand over new typed probes** (`executor.md`, probe table). The
  cargo `tool-packages`, `sdkman-packages` and `system-setting` probes step
  aside for a step that declares `probeCommand`, which answered for those
  kinds alone before they existed.
- **binstaller pin** (`core-domain.md`, tool pins). binstaller is pinned to
  v0.5.0, not v0.2.0: v0.2.0 aborts on GNU `@LongLink` tar headers, which
  current zig releases carry (8065313).

## Conventions

- `crystal spec`, `./lib/ameba/bin/ameba src spec`, and
  `crystal tool format --check src spec` must all be clean.
- Commit gradually, Conventional Commits, no co-author trailer.
- The four spec documents here are the behavioural reference; consult them
  before changing anything user-visible.
