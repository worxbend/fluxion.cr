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

## Conventions

- `crystal spec`, `./lib/ameba/bin/ameba src spec`, and
  `crystal tool format --check src spec` must all be clean.
- Commit gradually, Conventional Commits, no co-author trailer.
- The four spec documents here are the behavioural reference; consult them
  before changing anything user-visible.
