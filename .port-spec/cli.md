# Java `cli` + `app` modules — porting reference

## Entry point

- Root command `fluxion`, description
  `Bootstrap your Linux system from a declarative YAML config`.
- Bare invocation prints `Run 'fluxion --help' for usage.`
- `--version` prints exactly `fluxion 1.0.3\n` (one line).
- Enum option values are **case-insensitive** (`--format json` == `--format JSON`).
- `-h/--help` and `-V/--version` exist on the root **and every subcommand at every depth**.
- All logging goes to **stderr**; stdout is reserved for reports and JSON.
  `-v/--verbose` raises the log level to DEBUG, otherwise WARN.

## Global options mixin

| Short | Long | Type | Default | Label | Help |
|---|---|---|---|---|---|
| `-c` | `--config` | Path | `~/.config/fluxion/default.yaml` | `FILE` | `Config file path [default: ~/.config/fluxion/default.yaml]` |
| | `--no-tui` | bool | false | | `Disable TUI, use plain stdout` |
| `-v` | `--verbose` | bool | false | | `Verbose logging` |

`use_tui? = !no_tui && stdout is a real console`.
Mixed into: root, apply, dry-run, validate, lint, plan, diff, explain, list, status, graph,
doctor, `state`, `state show`, `report last`.
**Not** mixed into: generate, snapshot, import(+subs), kinds, tools(+subs), `state reset`,
`state forget`, `state path`.

## Subcommand registration order (help lists them in this order)

`apply, dry-run, validate, lint, plan, graph, diff, explain, list, status, state, report,
generate, snapshot, import, doctor, kinds, tools`

## Command options

### `apply` (alias `run`) — "Apply a bootstrap profile"
```
--phase PHASE[,...]        Run only these phases (comma-separated)
--from-phase PHASE         Start from this phase (skip earlier, regardless of state)
--dry-run                  Show what would be executed without changes
--yes, -y                  Approve confirmation-protected items for unattended execution
--skip-already-installed   Skip items/phases in state or confirmed by live probe
--re-probe                 Ignore state file; always live-probe (implies --skip-already-installed)
--reset-state              Delete saved state before applying this profile
--probe-only               Run probes and print status without installing
--profile PROFILE          Profile name for state tracking     [default: default]
```
`--parallel-phases` must NOT exist (regression: unknown option → exit 2 with
`Unknown option: '--parallel-phases'` + `Usage: fluxion apply`).

Control-flow order (pinned by tests):
1. `effective_skip = skip_already_installed || re_probe`
2. approval = `--yes ? approve_all : deny_all`
3. load config
4. **semantic validation before any filtering or state mutation**
5. apply `--phase` filter, else `--from-phase` slice
6. `effective_dry_run = dry_run || policy.dryRunDefault`
7. reject unapproved confirmations (skipped when `--yes`, dry-run, or `--probe-only`)
8. **privilege preflight runs before `--reset-state` deletion**, and only when
   `!dry_run && !probe_only`
9. `--reset-state` reset under a global mutation lock, only when `!effective_dry_run`
10. probe-only / plain / TUI branch

`--probe-only` output:
```
Probe-only mode: checking installation status...
  Probed: <item>
  <qualifiedKey> → <InstallationStatus variant name>
```
First Ctrl-C prints:
`\nStopping after the current step; press Ctrl-C again to force quit.`

### `dry-run` — "Show what would be executed without making any changes"
`--profile PROFILE` (default `default`, no description)

### `validate` — "Validate a config file"
```
--strict            Return a configuration error when warnings are present
--format TEXT|JSON  Output format: TEXT, JSON     [default: text]
```
Fails exit 3 with `Config validation failed` when errors, or warnings under `--strict`
— **after** printing the report.

### `lint` — "Score profile quality and safety guardrails"
`--format TEXT|JSON`. Never fails on findings.

### `plan` — "Show the execution plan without making any changes"
```
--skip-already-installed   Show which items would be skipped by probe/state
--profile PROFILE          [default: default]
--format TEXT|TABLE|TREE|JSON   [default: text]
--show-commands            Show executor command previews when available
```

### `graph` — "Render the phase dependency graph"
`--format MERMAID|DOT|JSON` — **default mermaid**

### `diff` — "Show what would change on this host"
`--profile PROFILE`, `--format TEXT|JSON`. Changes = every status item not
`CONFIGURED_INSTALLED`.

### `explain` — "Explain why a phase or item would run or skip"
`--profile`, `--phase`, `--item`, `--format`.
Exactly one of `--phase`/`--item` (blank counts as absent); violation → exit 2
`Specify exactly one of --phase or --item`.
Item lookup matches `key == k || displayName == k || moduleName == k`, first match in
phase→module→item order.

### `list` — "List modules in a config file"
`--format TEXT|JSON`

### `status` — "Show installation status for all items in a profile"
```
--profile PROFILE      Profile name
--resume-command       Print the command that resumes the next incomplete phase
--format TEXT|JSON     Output format
--summary              Print only aggregate status counts
--missing              Show configured items that are missing
--state-only           Show state entries absent from the config
--failed               Show missing, unknown, and version-drift items
--version-drift        Show only items whose live version differs
```
Filter precedence, first match wins, not combinable:
`--missing` → `--state-only` → `--failed` → `--version-drift` → all.
`--resume-command` short-circuits before probing.

### `state` — "Manage the fluxion state file"
Bare: `Run 'fluxion state --help' for subcommands.`

- `state show [profile=default] [--format]` — "Print all entries in the state file for a profile".
  `Next phase:` line only when `-c` was explicitly given **and** readable.
- `state reset [profile=default] [--force]` — "Delete the entire state file for a profile".
  Deletes both the current and the legacy state path.
- `state forget --profile P [--phase|--item] [--module] [--type]` —
  "Remove a phase or item entry from the state file". `--profile` required.
  Validation order:
  1. neither `--phase` nor `--item` → exit 2 `Specify --phase or --item`
  2. `--module`/`--type` without `--item` → exit 2 `--module and --type require --item`
  3. no state file → `No state file found for profile: <p>`, exit 0
  4. `--type` parsed as upper + `-`→`_`; failure → exit 2 `Unknown item type: <t>`
  5. zero matches → exit 2 `No matching state item found: <itemKey>`
  6. >1 match → exit 2 `Item key '<k>' is ambiguous; qualify it with --module and --type`
- `state path [profile=default]` — prints the absolute path only.

### `report` → `report last` — "Render persisted run reports"
Bare: `Run 'fluxion report --help' for subcommands.`
`report last --profile PROFILE --format markdown|html` (raw string, default `markdown`).
Unsupported → exit 2 `Unsupported report format: <f>`.
Missing state → exit 3 `No state file found for profile: <p>`.
Resume phase resolution: `state.nextPlanEntry` → phase containing that module → else first
phase not completed.

### `generate` — "Generate a starter Fluxion config"
```
--os auto|fedora|arch|opensuse|debian   [default: auto]
--profile NAME                          [default: starter]
--preset minimal|developer|desktop|dotfiles  [default: minimal]
--output PATH                           REQUIRED
--force
```
Errors: `Unsupported generator OS: <os>` (3), `Cannot detect OS: /etc/os-release not found` (3),
`Unsupported detected OS: <id>` (3), `Failed to read /etc/os-release` (4),
`Unsupported generator preset: <p>` (2),
`Output file already exists. Use --force to overwrite.` (2),
`Failed to write config: <abs>` (4). Success: `Generated config: <abs>`.
Flathub descriptor sha256 constant:
`3371dd250e61d9e1633630073fefda153cd4426f72f4afa0c3373ae2e8fea03a`

### `snapshot` — "Write a review-required host inventory snapshot"
`--output PATH` (required), `--force`. 5 s per host command, max 20 000 lines.
Success: `Snapshot written: <abs>`. `Failed to write snapshot: <abs>` (4).

### `import` → `import packages` / `import flatpaks`
Bare: `Run 'fluxion import --help' for subcommands.`
Both: `--from-host` (required), `--output PATH` (required), `--force`.
- packages: detection order `rpm` → `pacman` → `dpkg-query`; rpm's label resolves
  `dnf` → `zypper` → `dnf`. None → exit 5 `No supported host package database found`.
  Success `Imported packages: <abs>`.
- flatpaks: no flatpak → exit 5 `Flatpak command not found`; empty → exit 5
  `No installed Flatpak apps found`. Remote: `flathub` if present, else first, else `flathub`.
  Success `Imported Flatpaks: <abs>`.
Shared: `Specify --from-host` (2), `Output file already exists. Use --force to overwrite.` (2),
`Failed to write import fragment: <abs>` (4).

Emitted fragments (verbatim):
```yaml
# Review required. Generated from this host's package database.
# Remove machine-specific, transient, or unwanted packages before applying.
jobs:
  - name: imported-packages
    restartPolicy:
      type: none
    steps:
      - type: packages
        name: imported-packages
        packageManager: %s
        packages:
          - <name>
```
```yaml
# Review required. Generated from this host's Flatpak installation.
# Remove machine-specific, transient, or unwanted apps before applying.
jobs:
  - name: imported-flatpaks
    restartPolicy:
      type: none
    steps:
      - type: flatpak
        name: imported-flatpaks
        remote: %s
        appIds:
          - <appId>
```
Empty list renders `          []`. Names bare when matching `[A-Za-z0-9_.+:-]+`, else
double-quoted with `"` → `\"`.

### `doctor` — "Check host readiness for a Fluxion profile"
`--profile PROFILE`, `--skip-network`. HEAD timeout 3 s.
Fails exit 5 `Doctor found <n> failing check(s)` **after** printing all lines.
Check order: config file → host os → state directory → sudo command → target os →
one package manager check per required kind → per-module checks in config order.
Line format `[%s] %-18s %s`, statuses lowercase `pass`/`warn`/`fail`.
`supportedOs` = `fedora arch archlinux opensuse-tumbleweed opensuse-leap debian ubuntu`.
Package manager commands: `DNF→dnf PACMAN→pacman PARU→paru YAY→yay APT→apt-get
FLATPAK→flatpak ZYPPER→zypper CARGO→cargo`.

### `kinds` — "List the plan kinds a WorkstationProfile can use"
`--format TEXT|JSON`. No config needed.

### `tools` → `tools list` / `tools install`
Bare: `Run 'fluxion tools --help' for subcommands.`
Selector = last path segment of the repository, compared case-insensitively.
- `tools list [--format]` — "Show every delegated tool, where it would come from, and its
  pinned version"
- `tools install <tool> [--release TAG]` — "Download and verify a delegated tool into the
  Fluxion tool cache"
  Errors: exit 2 `Unknown tool '<sel>'. Known tools: <sorted, comma-joined>`;
  exit 2 `Invalid tool version: <cause>`; exit 5 resolution failure.

## Exit codes

| Name | Value |
|---|---|
| SUCCESS | 0 |
| GENERAL_FAILURE | 1 |
| INVALID_INPUT | 2 |
| CONFIGURATION_ERROR | 3 |
| IO_ERROR | 4 |
| EXTERNAL_DEPENDENCY_ERROR | 5 |
| PAUSED | 75 |
| CANCELLED | 130 |

Exception mapping, **first match wins**:
1. CliFailure → its own code
2. ExecutionPaused → **the pause's own exitCode** (a profile `interrupt` may set e.g. 42)
3. ExecutionCancelled → 130
4. BootstrapExecution → 5
5. ConfigLoad → 3
6. PhasePlanning → 3
7. Parameter | IllegalArgument | InvalidPath | StaleState → 2
8. IO | UncheckedIO | StateRead | StateWrite → 4
9. ShellExecution | UnsupportedPackageManager → 5
10. anything else → 1

Parse errors always 2.

## Output renderers

Every human-readable field goes through the display sanitizer then the secret redactor
(mask `<redacted>`). Multi-line values collapse to one line in `sanitizeLine`.

### Shared plain header (apply / dry-run / plan text)
```
Operation: <operation>
Mode: <mode>
Manifest/Profile: <profileName>
Host: os=<osFamily> distribution=<d|unknown> version=<v|unknown> codename=<c|unknown> arch=<a>
State: <statePath>                       <- only when present
Source setup entries:                    <- omitted when empty
  - <name> type=<type> items=<a, b>
Selected WorkstationProfile entries:     <- omitted when empty; only the "manifest-plan" phase
  - <name> type=<type> items=<a, b>
Skipped WorkstationProfile entries:      <- omitted when empty
  - <name> type=<kind> reason=<reason>
Planned counts: source_setups=%d selected=%d skipped=%d items=%d
<blank>
```
Plan adds at the end:
`Final counts: source_setups=%d selected=%d skipped=%d items=%d`

### `validate`
text:
```
<severity-lowercase> <path>: <message>
```
then exactly one of
```
Config has %d issue(s): profile '%s' with %d job(s), %d step(s)
Config is valid: profile '%s' with %d job(s), %d step(s)
```
(args order: issue count, profile, phaseCount labelled **job(s)**, moduleCount labelled
**step(s)**.)

json (hand-written, single line):
```json
{"profileName":"...","phaseCount":N,"moduleCount":N,"valid":true,"issues":[{"severity":"ERROR","path":"...","message":"..."}]}
```
`valid` = no errors (ignores `--strict`). **Severity is UPPERCASE in JSON, lowercase in text.**
Escaping covers only `\ " \b \f \n \r \t`.

### `lint`
text:
```
Profile: <name>
Quality score: <int>

<severity-lower> <category padded to 16> <path>: <message>
```
or `No lint findings.`
json: `{"profileName":..,"score":N,"issues":[{"severity":"..","category":"..","path":"..","message":".."}]}`
(severity lowercase here).

### `plan`
**text** — shared header, then:
```
Execution plan for: <profileName>

Source setup:                                    <- only when non-empty
  • <displayName %-35s> <skipLabel>
    $ <redacted command>                         <- only with --show-commands

Phase 1: <name %-25s> [<no deps | after: a, b>]
  • <displayName %-35s> <skipLabel>
    $ <command>
  → After this phase: RESTART REQUIRED           <- prompt-logout
  → After this phase: new-shell wrapper          <- requires-new-shell

Skipped WorkstationProfile entries:              <- only when non-empty
  • <name %-35s> <reason>

Final counts: source_setups=%d selected=%d skipped=%d items=%d
```
Phase index is 1-based.

**table** — header `%-22s %-24s %-35s %s`, separator exactly **100** `-`:
```
PHASE                  MODULE                   ITEM                                STATUS
```
Rows `%-22s %-24s %-35s %s`; `--show-commands` continuation `%-22s %-24s %-35s $ %s` with the
first three cells blank. Source setups use the literal phase cell `source-setup` and come
first. Skipped entries last with phase cell `manifest-plan` and status `skipped: <reason>`.

**tree** — `└─` at every level (no `├─`), indents 0/3/6/9:
```
Execution plan for: <profileName>
└─ source setup
   └─ <module> (<type>)
      └─ <displayName> - <skipLabel>
         $ <command>
└─ <phase> [<no deps | after: …>]
   └─ <module> (<type>)
      └─ <displayName> - <skipLabel>
└─ skipped WorkstationProfile entries
   └─ <name> (<kind>) - <reason>
```

**Skip labels**:
- no `--skip-already-installed`, no probe result, or NotInstalled → `would run`
- InstalledByProbe → `○ would skip (probe: installed <version>)`, version part omitted when nil
- InstalledFromState → `○ would skip (state: YYYY-MM-DD)` (first 10 chars of the instant)
- Unknown → `would run (probe unknown)`

**json**:
```json
{"profileName":"..","sourceSetups":[<module>],
 "phases":[{"name":"..","dependsOn":[..],"restartEffect":"none|prompt_logout|requires_new_shell","modules":[<module>]}],
 "skippedEntries":[{"name":"..","kind":"..","status":"skipped","reason":".."}]}
```
`<module>` = `{"name":"..","type":"..","items":[<item>]}`
`<item>` = `{"key":"..","displayName":"..","type":"<lower>","packageManager":"<lower>|null","status":"<skipLabel>","commandPreview":[..]}`

### `graph`
mermaid (default):
```
flowchart TD
  p_<sanitizedId>["<escapedName>"]
  p_<dep> --> p_<phase>
```
All node lines first, then all edges. `mermaidId(v) = "p_" + v.gsub(/[^A-Za-z0-9_]/, "_")`.
Label escaping: `\`→`\\`, `"`→`\"`.

dot:
```
digraph fluxion {
  rankdir=LR;
  "<name>";
  "<dep>" -> "<phase>";
}
```
json: `{"profileName":..,"phases":[{"name":..,"dependsOn":[..],"moduleCount":N,"restartEffect":".."}],"edges":[{"from":"..","to":".."}]}`

### `diff`
text:
```
Diff for profile: <name>

<Title>:
  - <displayName> (<type>): <detail>

```
or `No changes detected.`
Group order = classification declaration order:
`CONFIGURED_INSTALLED, CONFIGURED_MISSING, STATE_ONLY, UNKNOWN, VERSION_DRIFT`
Titles: `Already installed`, `Would install`, `Only in state`, `Needs review`, `Version drift`.
json status kinds: `configured-installed configured-missing state-only unknown version-drift`
```json
{"profileName":..,"summary":{"total":N,"configuredInstalled":N,"configuredMissing":N,"stateOnly":N,"unknown":N,"versionDrift":N},
 "changes":[{"moduleName":..,"key":..,"displayName":..,"type":..,"status":..,"detail":..,"stateVersion":..,"liveVersion":..}]}
```

### `explain`
text:
```
Explain <phase|item>: <displayName>
Phase: <phaseName>
Module: <moduleName>            <- item kind only
Depends on: <(none) | [base, tools]>
Restart effect: <none|prompt_logout|requires_new_shell>
Status: <status kind>           <- item kind only
Reason: <detail>
Command preview: <args joined by space>   <- only when non-empty
```
For a phase: key = displayName = phaseName, no module, no status,
detail = `phase contains <n> item(s)`, empty command preview.
json adds an `items` array of per-item objects.

### `list`
text:
```
Profile: <name>  OS: <target>

MODULE                         TYPE                COUNT  DETAILS
<90 dashes>
```
Header `%-30s %-18s %5s  %s`, rows `%-30s %-18s %5d  %s`. Source setups first with TYPE
`📦 source setup`.

TYPE labels (emoji, exact):
```
packages 📦 packages          apt-repository 📦 apt repo     rpm-repository 📦 rpm repo
pacman-repository 📦 pacman repo   file write                 flatpak 🗃 flatpak
flatpak-remote 🗃 remote       shell-script 📜 script         compiled-binary ⬇ binary
zypper 📦 zypper              dotbot 🔗 dotbot               default-shell 🐚 shell
oh-my-zsh 🐚 oh-my-zsh        toolchain 🧰 toolchain         nerd-font 🔤 nerd-font
shell-reload 🔄 reload        shell-command 📜 command       assert ✓ assert
manual ☐ manual               interrupt ⏸ interrupt          sdkman 🧰 sdkman
binstaller 📥 binstaller      user-groups 👤 groups          zypper-repo 📦 zypper-repo
git-config 🔧 git-config      git-repo 🌿 git-repo           systemd ⚙️ systemd
system-setting 🖥️ setting     system-update ⬆️ update        gpg-key 🔑 gpg-key
tool-packages 🧰 tool-pkgs    source setup 📦 source setup
```

JSON `type` values: `packages apt-repository rpm-repository pacman-repository file-writes
flatpak flatpak-remote shell-script compiled-binary zypper dotbot default-shell oh-my-zsh
toolchain nerd-font shell-reload shell-command assert manual interrupt sdkman-packages
binstaller-profile user-groups zypper-repository git-config git-repo systemd-unit
system-setting system-update gpg-key`, plus `<backend-id>-packages` for tool packages, and
`source-setup` for source setups.

DETAILS strings:
```
packages           <n> packages (<mgr>)
apt-repository     <sourceListPath> <- <sourceEntry>
rpm-repository     <repoFilePath> <- <baseUrl>
pacman-repository  <repositoryName> <- <server>
file-writes        <first destination>
flatpak            <n> apps from <remote>
flatpak-remote     <remote> -> <url>
shell-script       <first item key>
compiled-binary    <binaryName> from <publicUrl>
zypper             <n> packages (zypper)
dotbot/default-shell/oh-my-zsh   <config> / <shellPath> / <installDir>
toolchain          <kind lowercase>
nerd-font          <n> families
shell-reload       <shell name>
shell-command      <n> commands
assert/manual/interrupt   <command> / <message> / <message>
sdkman             <n> SDKMAN packages
binstaller         <config>[ (only a, b)]
zypper-repository  <repoFilePath> <- <baseUrl>
git-config         <n> git config entries
git-repo           <n> repositories
systemd-unit       <n> units (<scope>)
system-setting     host settings
system-update      full update (<mgr>)
gpg-key            <n> signing keys
tool-packages      <n> packages (<backend-id>)
```
Source setup details: apt `<sourceListPath> <- <sourceEntry>`; rpm/zypper
`<repoFilePath> <- <baseUrl>`; pacman `<configPath> [<repositoryName>]`; flatpak
`<remote> -> <url>`.

json:
```json
{"profileName":..,"target":..,"sourceSetups":[{"name":..,"type":"source-setup","description":..,"itemCount":N}],
 "modules":[{"name":..,"type":..,"description":..,"itemCount":N}]}
```
`itemCount` comes from the **expanded execution plan**, not the raw module (a `dnf-packages`
kind with one action + one package yields 2).

### `status`
text table — header `%-45s  %-15s  %-20s  %s` (two spaces between columns), separator
exactly **80** `-`:
```
Item                                           Type             Status                Detail
```
Empty → `(no items found)`. Cell 1 = `truncate(module + "/" + key, 45)` where truncate cuts
at 42 and appends `...`.

`--summary`:
```
Profile: <name>
Total: <n>
Configured installed: <n>
Configured missing: <n>
State-only: <n>
Unknown: <n>
Version drift: <n>
```
`--resume-command`: the command, or exactly `Profile is complete; no resume command.`

json: `{"profileName":..,"summary":{...},"items":[...]}` — `items` is `[]` under `--summary`.
json + `--resume-command`: `{"profileName":..,"nextPhase":"..|null","command":"..|null"}`

### `state show`
text:
```
Profile: <name>  (last run: <lastRunAt>)
Next phase: <phase>              <- only when -c given and readable and a phase is incomplete

Phases:
  (none)
  <phaseName %-30s>  <status %-10s>  <completedAt>

Items:
  (none)
  <moduleName %-24s>  <itemKey %-40s>  <itemType %-15s>  <completedAt>
```
Two spaces between padded columns; two-space leading indent. **status/itemType print the raw
UPPERCASE enum name here.**
No state → `No state file found for profile: <p>`.

json (present):
```json
{"profileName":..,"lastRunAt":"<ISO>","nextPhase":"..|null",
 "phases":[{"name":..,"status":"<lower>","completedAt":"<ISO>","fingerprint":..,"reason":..}],
 "items":[{"moduleName":..,"key":..,"type":"<lower>","completedAt":"<ISO>","version":..,"checksum":..,"sourceUrl":"<publicUrl>|null"}]}
```
json (absent): `{"profileName":"<p>","lastRunAt":null,"nextPhase":null,"phases":[],"items":[]}`

### `state reset` / `forget` / `path`
```
No state file found for profile: <p>
Delete state for profile '<p>'? [y/N]        <- print, no newline; reads one stdin line
Aborted.                                     <- when the stripped answer is not "y" (any case)
State reset for profile: <p>
Forgot phase '<phase>' from profile '<p>'
Forgot item '<module>/<key>' (<TYPE>) from profile '<p>'
```

### `report last`
markdown:
```markdown
# Fluxion Run Report

- Profile: `<name>`
- Last run: `<lastRunAt>`
- State version: `<version>`
- Config: `<resolvedConfigFile>`      <- only when -c given

## Resume

`<resume command>`
No resume command available from the current state and config.

## Phases

_No phase state recorded._

| Phase | Status | Completed at | Reason |
| --- | --- | --- | --- |
| <name> | <status lower> | <completedAt> | <reason or ""> |

## Items

_No item state recorded._

| Module | Item | Type | Completed at | Version | Checksum | Source |
| --- | --- | --- | --- | --- | --- | --- |
```
Markdown escaping: `|` → `\|`, newline → space.

html:
```html
<!doctype html>
<html><head><meta charset="utf-8"><title>Fluxion Run Report</title></head>
<body>
<h1>Fluxion Run Report</h1>
<p><strong>Profile:</strong> <name></p>
<p><strong>Last run:</strong> <lastRunAt></p>
<p><strong>State version:</strong> <version></p>
<p><strong>Resume:</strong> <code><command></code></p>
<h2>Phases</h2><table><tr><th>Phase</th><th>Status</th><th>Completed</th><th>Reason</th></tr>
<tr><td colspan="4">No phase state recorded.</td></tr>
</table>
<h2>Items</h2><table><tr><th>Module</th><th>Item</th><th>Type</th><th>Completed</th><th>Version</th><th>Checksum</th><th>Source</th></tr>
<tr><td colspan="7">No item state recorded.</td></tr>
</table>
</body></html>
```
HTML escaping covers only `& < >`.

### `doctor`
`[%s] %-18s %s` with lowercase `pass`/`warn`/`fail`.

### `kinds`
text (dynamic `idWidth = max id length, min 4`):
```
KIND  DESCRIPTION
<'-' * (idWidth + 2 + 60)>
<id padded>  <summary>
<padding>    actions: a, b, c        <- only when non-empty

Reference: sysboot/docs/workstation-profile.md
```
json: `{"kinds":[{"id":..,"summary":..,"category":..,"packageActions":[..]}]}`

### `tools list`
text (per-column width = max(longest cell, header length), two spaces between):
```
Platform: <os/arch>

TOOL       BINARY   VERSION  SOURCE
dotbot-go  dotbot   v0.4.2   on PATH: /usr/bin/dotbot

Tools already on PATH are used as-is; Fluxion never replaces them.
Run 'fluxion tools install <tool>' to fetch a missing one into the cache.
```
SOURCE variants: `on PATH: <path>` / `cached: <path>` / `missing, would download <assetUrl>`
json: `{"platform":..,"tools":[{"tool":..,"executable":..,"repository":..,"version":..,"source":"path|cache|download","path":..,"checksumPolicy":"<ENUM NAME, not lowercased>","assetCandidates":[..]}]}`

`tools install`:
```
<tool> is already on PATH at <path>; Fluxion will use it and installs nothing.
<tool> <version> installed at <path>
```

## Live run output (plain apply/dry-run)

Colour comes from picocli `Ansi.AUTO` markup — auto-stripped when stdout is not a TTY or
`NO_COLOR` is set. **This is the only place in cli/app that emits colour.**

| Event | Line |
|---|---|
| PHASE_STARTED | `[PHASE ]` bold blue + module |
| PHASE_COMPLETED | `[DONE  ]` bold blue + `phase ` + module |
| PHASE_FAILED | `[FAILED]` bold red + `phase ` + module |
| PHASE_BLOCKED | `[BLOCK ]` yellow + module + ` waits for ` + item |
| MODULE_STARTED | `[MODULE]` bold blue + module |
| MODULE_COMPLETED | `[DONE  ]` bold blue + module |
| ERROR | `[ERROR ]` bold red + item |
| RESTART_REQUIRED | `[RESTART]` bold yellow + module, each message line indented two spaces, then optional `  Resume with: <cmd>` |
| ITEM_STARTED | `  ` + `-->` yellow + `  ` + item + ` ... ` — **line stays open** |
| ITEM_OUTPUT | only when streaming output is on and the line is non-blank: close the open line, then 8 spaces + line |
| CANCELLED | close line, `[CANCEL]` bold yellow + `stopped at your request; state was saved`, then `  Next plan entry: <item>` and `  Resume with: <cmd>` |

Result suffixes appended to the open item line:
```
OK (green) (%.1fs)
FAILED (red) (exit <n>): <message>
SKIPPED (yellow): <reason>
DRY-RUN (cyan): <redacted command joined by space>
PAUSED (bold yellow): <message>
  State: <path>
  Next plan entry: <next>
  Resume with: <cmd>
```
Always printed at the end:
`Final counts: ok=%d failed=%d skipped=%d dry_run=%d paused=%d`

Colour markup inventory:
```
bold,blue   [PHASE ] [DONE  ] [MODULE]
bold,red    [FAILED] [ERROR ]
yellow      [BLOCK ]  -->  SKIPPED:
bold,yellow [RESTART] [CANCEL] PAUSED:
green       OK
red         FAILED
cyan        DRY-RUN
```

## Resume command format
```
fluxion apply --no-tui -c <config> --profile <profile> --skip-already-installed [--from-phase <phase>]
```
Each token shell-quoted: bare when matching `[A-Za-z0-9_./:=@%+,-]+`, else single-quoted with
`'` → `'"'"'`.

## stderr error format
- Execution failure: one line `Error: <sanitized message>`; when the message is blank, the
  exception's class name is used. **Never a stack trace.**
- Parse failure: `Error: <sanitized message>`, blank line, full usage message, exit 2.

Command-constructed messages:
```
Unknown phase '<p>'. Valid phases: <a, b, c>
Cycle in phase graph: <msg>
Cycle detected: <msg>
Explicit confirmation required for <module/item, …>. Re-run with --yes; guarded items are not prompted interactively.
TUI error: <msg>
Config validation failed: <path>: <message>; <path>: <message>
Could not render JSON output
Output path has no parent
Output path must not traverse symbolic links: <path>
[fluxion] ⚠ Phase FAILED: <phaseName>
[fluxion] Cannot prompt for sudo password in non-interactive mode. Re-run in a terminal.
```

## Composition (app module)

Context exposes: orchestrator, config loader, TUI app (optional), parallel probe runner,
execution plan builder, host facts provider, `preflight(config)`. Closing zeroes the cached
sudo password and stops its keepalive.

CLI path: no-op sudo provider, default shell runner, JSON state repo (read-only flag),
Linux host facts, probe registry, run-state mode from `(skip_already_installed, re_probe)`,
skip evaluator, executor registry, once-only privilege gate with a **non-interactive** sudo
preflight, policy-privilege orchestrator wrapper, YAML config loader, no TUI, no sudo session.

TUI path differs: interactive sudo provider wrapped in a session (one prompt per run, shared
across privileged commands), a PTY shell runner for effects (the plain runner is still used
for probes), the TUI event listener, an **interactive** sudo preflight, and a TUI app.

Probe registry order: dnf, pacman, apt, apt-repository, rpm-repository, pacman-repository,
zypper-repository, zypper, flatpak, flatpak-remote, compiled-binary, shell-script, dotbot,
default-shell, nerd-font.

Executor registry order: dnf, pacman, paru, yay, apt, zypper, cargo.

State is loaded **only** when the run-state mode is "skip recorded". Under read-only state a
read error is swallowed and the run falls back to live probes — it must never repair or
mutate state layout, permissions, or mtimes just to read it.

## Cross-cutting behaviours

- **SIGINT**: cooperative. First Ctrl-C sets a cancellation flag and drains for up to 30 s,
  then interrupts, then allows 5 s to terminate. A second Ctrl-C kills immediately.
- **Atomic output writes**: write to `.<name>-XXXX.tmp` in the target's parent, verify **no
  ancestor component is a symlink**, then atomic rename (with `--force`) or hard-link +
  delete (without). Refuses to follow a pre-positioned symlink; `--force` replaces the link
  entry without touching its referent.
- **Host command runner** (snapshot/import): PATH-based existence check, stderr discarded,
  line cap, lines stripped, blanks dropped, **sorted**; on timeout the whole process tree is
  terminated (2 s drain grace, 2 s termination grace).
- JSON output is compact (no pretty-printing), one line, with insertion-ordered keys exactly
  as listed above.
