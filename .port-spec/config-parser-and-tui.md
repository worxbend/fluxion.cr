# Java `config-parser` + `tui` modules — porting reference

# Part A — config-parser

## A.0 Loader and schema detection

`MAX_CONFIG_BYTES = 8 MiB`. YAML parsed with **strict duplicate-key detection** (a repeated
mapping key is a parse error).

`load(path)`:
1. Not present (no symlink follow) → `ConfigLoadException(path, "File does not exist")`
2. Not a regular file, or is a symlink → `Config must be a regular non-symbolic file`
3. Larger than the cap → `Config exceeds maximum size of 8388608 bytes`
4. Not readable → `Config file is not readable`
5. Detect schema, then dispatch.

Wrapping prefix is always `Failed to load config from <path>: `, then
`YAML parse error: <msg>` for IO errors or `Validation error: <msg>` for validation errors.

`detect_schema(root)`, in order:
1. empty/nil → `Config file is empty`
2. not a mapping → `Config root must be a YAML mapping`
3. has `apiVersion` or `kind` → **WorkstationProfile**
4. has `profile`, `os`, `jobs`, `phases`, `modules`, or `schemaVersion` → **legacy**
5. else →
   `Unknown config schema; expected Fluxion profile/os/jobs/phases/modules fields or apiVersion: initkit.io/v1alpha1 with kind: WorkstationProfile`

Legacy path: deserialize, map. **No interpolation.**
Manifest path: **interpolate the raw tree first**, then deserialize, then map.

## A.1 DTO defaults

All list/map accessors default to empty, never nil.

**Only two aliases exist in the whole module**: `refreshFontCache` ← `refresh_font_cache`, and
binstaller `config` ← `configPath`.

### Legacy root
`schemaVersion: Int?`, `profile: String?`, `os: {type, release}`, `modules: [Module]?`,
`jobs: [Phase]?`, `phases: [Phase]?` (legacy alias for `jobs`).

`Phase`: `name`, `description`, `dependsOn: [String]`, `restartPolicy`,
`continueOnModuleError: Bool = true`, `modules: [Module]?`, `steps: [Module]?` (preferred).

`restartPolicy.type`: `none` | `prompt-logout {message}` | `requires-new-shell {shell}`.

### Legacy step discriminator (`type`), 27 kinds in declaration order
`packages, apt-repository, rpm-repository, pacman-repository, flatpak, flatpak-remote,
shell-script, compiled-binary, dotbot, default-shell, oh-my-zsh, toolchain, nerd-fonts,
shell-reload, shell-command, assert, manual, binstaller-profile, user-groups, git-config,
git-repo, systemd-unit, system-setting, system-update, gpg-key, tool-packages,
zypper-repository`

Notable defaults:
```
packages          continueOnError = true
shell-script      continueOnError = false
zypper-repository enabled/gpgCheck/autoRefresh = true
flatpak           remote = "flathub"
dotbot            installerVersion = "v0.4.2", dotbotBinary = "dotbot"
toolchain         continueOnError = true
nerd-fonts        installerVersion = "v1.0.7", nerdfontBinary = "nerd-fonts-installer"
shell-reload      shell = "zsh", description = ""
shell-command     shell = "/bin/bash", continueOnError = false
assert            shell = "/bin/bash"
binstaller        installerVersion = "v0.2.0", binstallerBinary = "binstaller", locked = false
user-groups       createMissing = false, logoutCheckpoint = true, continueOnError = false
git-config        scope = "global"
git-repo          repo.submodules = false, repo.update = "none"
systemd-unit      scope = "system", unit.enabled = true, unit.state = "unchanged", unit.mask = false
system-update     distUpgrade = false, refreshOnly = false
tool-packages     continueOnError = true
nerd font config  release = "latest", refreshFontCache = true
```
`compiled-binary` accepts both `mode`/`installMode` and `symlink`/`symlinkPath`.
`default-shell` accepts `shell` with `shellPath` as a deprecated alias.
`toolchain` accepts `installScriptUrl` with `installScript` as a deprecated alias.

### Manifest DTOs
`apiVersion`, `kind`, `metadata{name, namespace, labels, annotations}`,
`spec{target, policy, vars, sources, plan}`.
`target{os{family, distribution, release, version, codename}, architecture}`.
`policy{dryRun, continueOnError, requireSudo, statePath}`.
`plan[]{name, kind, description, dependsOn, when, execution, spec}`.
`execution{continueOnError, requireSudo, parallelism, timeoutSeconds, shell, workingDir, env}`.
`sources{entries, apt, dnf, rpm, pacman, zypper, flatpak}`.

`when` matcher fields are raw nodes so scalar/list/object forms all parse:
`os, osFamily, distribution, distributions, version, codename, architecture, architectures,
commands, commandExists`, plus `oneOf: [When]`, and the **rejected** `files`, `vars`,
`expression` (reported in that order).

Plan spec derived-accessor semantics that must be replicated:
```
packages()            non-array -> []; array elements textual ? text : ""
packageItems()        nil -> []; non-array -> [node]; array -> elements
installMode()         installMode || mode
symlinkPath()         symlinkPath || symlink
workingDir()          workingDir || cwd
fileWriteItems()      items of `files`; if empty, items of `writes`
config()              only when textual
dotfilesConfig()      config() || configPath()
nerdFontConfig()      only when `config` is an object
gpgCheck/autoRefresh/repoEnabled/logoutCheckpoint   default true
distUpgrade/refreshOnly/createMissing/locked        default false
```
`PackageActionDocument` from a node: textual → `{action: text, args: []}`; object →
`action` (nil/null → nil, non-textual → `""`), `args` (missing → `[]`, non-array → `[""]`,
array → textual ? text : `""`); anything else → `{action: nil, args: []}`.

## A.2 Mapping

### Legacy
1. `schemaVersion` nil or 1, else `Unsupported schemaVersion: <v>`
2. `profile` required
3. `os` required
4. phase source = `jobs` when non-nil **and non-empty**, else `phases` (or `[]`); when the
   phase list is empty, top-level `modules` are used instead
5. step source per phase = `steps` when non-nil and non-empty, else `modules`

`Required field '<name>' is missing` for every missing required field. Field names used
verbatim in those messages: `profile`, `os`, `os.type`, `phase.name`, `name`,
`packageManager`, `packages`, `apt-repository.name`, `apt-repository.source`,
`rpm-repository.baseUrl`, `pacman-repository.server`, `zypper-repository.baseUrl`, `appIds`,
`flatpak-remote.remote`, `flatpak-remote.url`, `dotbot.config`, `dotbot.installerVersion`,
`default-shell.shell`, `oh-my-zsh.revision`, `oh-my-zsh.sha256`, `toolchain.kind`,
`toolchain.installScriptUrl`, `toolchain.sha256`, `nerd-fonts.config`,
`nerd-fonts.installerVersion`, `shell-command.commands`, `assert.command`, `manual.message`,
`binstaller-profile.config`, `binstaller-profile.installerVersion`,
`binstaller-profile.binstallerBinary`, `user-groups.groups`, `git-config.scope`,
`git-config.entries`, `git-repo.repos`, `git-repo.url`, `git-repo.dest`, `git-repo.update`,
`systemd-unit.units`, `systemd-unit.units[].name`, `systemd-unit.state`,
`systemd-unit.scope`, `system-update.packageManager`, `gpg-key.keys`, `gpg-key.keys[].url`,
`gpg-key.keys[].fingerprint`, `tool-packages.backend`, `tool-packages.packages`,
`checksum.algorithm`, `checksum.value`.

Other legacy messages:
```
Unsupported OS type: <type>
Unsupported requires-new-shell value: <shell>
Unsupported tool-packages backend: <b>
<field> must be a valid SHA-256 checksum
Required field '<field>' must be absolute
Unsupported value for <field>: <raw>
```
`os.type` mapping: `fedora`, `arch`, `opensuse`, `debian`/`ubuntu`.
`requires-new-shell` shell: nil → zsh; `zsh|bash|sh`.

Defaults filled during legacy mapping:
```
apt sourceList     /etc/apt/sources.list.d/<name>.list
apt keyring        /etc/apt/keyrings/<name>.gpg   (only when signingKeyUrl present)
rpm id             <name>;  repoFile /etc/yum.repos.d/<name>.repo
pacman repository  <name>;  config /etc/pacman.conf
zypper id          <name>;  repoFile /etc/zypp/repos.d/<name>.repo
flatpak remote     flathub
flatpak-remote system  true
compiled-binary    stripComponents 0, mode installMode||mode||"0755"
oh-my-zsh dir      ~/.oh-my-zsh
nerd fonts dest    ~/.local/share/fonts/NerdFonts
shell-command      shell /bin/bash
assert message     "Assertion failed: <name>"
enabled/gpgCheck   nil counts as true
```
Legacy `~` handling for dotbot/oh-my-zsh/nerd-fonts destination replaces **every** `~`, not
just a leading one. `expandHome` used elsewhere only expands `~` alone or a leading `~/`.
Legacy `system-update.timeout` is parsed as **ISO-8601 only**; the manifest path additionally
accepts `<digits>`, `<n>ms`, `<n>s`, `<n>m`.

`toolPackage(raw)`: split at the **last** `@`; index ≤ 0 means unpinned.

### Manifest
Order in `map`:
1. validate (all errors joined with `"; "` and raised at once)
2. `metadata` and `spec` required
3. map policy
4. evaluate `when` over `spec.plan`
5. map sources against the selected entries
6. manifest directory = parent of the normalized absolute manifest path; nil →
   `Workstation manifest must have a directory`
7. build config with **exactly one phase**: name `manifest-plan`, description
   `WorkstationProfile plan`, no deps, restart `none`, `continueOnModuleError = false`
8. map each selected entry through the plan-kind registry; entries whose mapper returns
   nothing (only `file-writes` can) are dropped

`skippedPlanEntries` = when-skipped (kind stripped + lowercased) **then** source-skipped.

Target: `spec.target.os.distribution` required, stripped + lowercased.
`fedora | arch | opensuse | debian | ubuntu`, else
`Unsupported target OS distribution: <d>`.
Release = `release || version || ""`; Debian release = `codename || release || version || ""`.

`continueOnError(entry) = entry.execution.continueOnError || policy.continueOnErrorDefault || true`
`source checksum must be valid SHA-256`
`Required field 'installPath' must be absolute` (hard-coded field name regardless of caller)

Manifest-specific mapping notes:
- structured items resolve relative paths against the **manifest directory**; when no working
  directory is declared, the manifest directory is used
- an empty item-node list yields exactly one synthetic item built from the module-level spec
  at index 0; otherwise each node is included **only if its own `when` matches** (a fresh host
  facts lookup per item)
- item name fallback `<planName>[<index>]`; a textual command node falls back to its own text
- env merge: module env first, then item env, item wins per key, insertion-ordered
- `env` value shapes: textual → sensitive flag from the name heuristic; object requires a
  textual `value`, may override `sensitive`. Errors: `env.<name>.value must be a string`,
  `env.<name> must be a string or object`, `env must be an object`
- `confirm`: textual value, or boolean `true` → the literal string `"confirm"`
- default item timeout 30 minutes
- flatpak app ids come from `apps` **then** `appIds`
- interrupt defaults: message `Execution paused by interrupt entry: <name>`,
  `resumeFrom` `next`, `exitCode` 75; bad resume → `Unsupported interrupt resumeFrom: <v>`
- AUR helper: `paru`/`yay`, else `Unsupported AUR helper: <v>`
- nerd fonts `configPath` only applies when `config` is **not** an object

Source sections map **only when a matching package-manager kind was selected**:
`apt-packages→apt`, `dnf-packages→dnf`, `pacman-packages→pacman`, `zypper-packages→zypper`,
`flatpak-packages→flatpak`.
Section→manager: `apt`→APT, `dnf`→DNF, **`rpm`→DNF**, `zypper`→ZYPPER, `flatpak`→FLATPAK.
**`pacman` and `entries` never produce setups.**
Unselected sections produce
`SkippedPlanEntry(name || "<unnamed>", "<section>-source", "source section <section> is not relevant to selected host package managers")`.

## A.3 Plan-kind registry

25 ids in declaration order (this order is also the tie-break for suggestions):
`apt-packages, aur-packages, cargo-packages, dnf-packages, pacman-packages, zypper-packages,
sdkman-packages, flatpak-packages, binary-downloads, shell-scripts, commands, file-writes,
nerd-fonts, dotfiles-apply, binstaller-profile, user-groups, git-config, git-repo,
systemd-unit, system-setting, system-update, gpg-key, tool-packages, zypper-repository,
interrupt`

Summaries (verbatim, surfaced by `fluxion kinds`):
```
apt-packages       Install packages with apt.
aur-packages       Install AUR packages with paru or yay.
cargo-packages     Install crates with cargo.
dnf-packages       Install packages with dnf.
pacman-packages    Install packages with pacman.
zypper-packages    Install packages with zypper.
sdkman-packages    Install SDKMAN candidates such as java or maven.
flatpak-packages   Install Flatpak applications.
binary-downloads   Download and install a compiled binary or archive.
shell-scripts      Run local or HTTPS-fetched shell scripts.
commands           Run shell or direct argv commands.
file-writes        Write files from inline content or a source path.
nerd-fonts         Install Nerd Font families via nerd-fonts-installer.
dotfiles-apply     Apply a Dotbot configuration via dotbot.
binstaller-profile Install binaries from a binstaller BinaryDistributionProfile.
user-groups        Add the user to groups. Append-only; never removes membership.
git-config         Set git config entries at global, system or local scope.
git-repo           Clone git repositories, and optionally update existing clones.
systemd-unit       Enable, mask, start or stop systemd units.
system-setting     Set timezone, hostname, locale, NTP and the RTC mode.
system-update      Refresh package metadata or upgrade every installed package.
gpg-key            Import repository signing keys into a keyring.
tool-packages      Install via a language tool: cargo-binstall, pipx, snap, uv, npm, go.
zypper-repository  Add an openSUSE repository, with its signing key.
interrupt          Write a resumable checkpoint and stop cleanly.
```
Catalog entries expose the category lowercased and `packageActions` **sorted**.
Lookup is on the already-normalized id — `find("APT-PACKAGES")` finds nothing.

## A.4 Validation

All manifest errors collect into one list and are raised together, joined with `"; "`.

### Top-level order
1. `apiVersion` then `kind`
   - blank → `<path> is required and must be '<expected>'`
   - mismatch (compared after strip) → `<path> must be '<expected>' but was '<value>'`
   - expected `initkit.io/v1alpha1` and `WorkstationProfile`
2. metadata: absent → `metadata is required` (skip the name check); blank name →
   `metadata.name must not be blank`
3. `spec.policy.statePath` when present: blank → `spec.policy.statePath must not be blank`;
   equal to the normalized manifest path → `spec.policy.statePath must not equal the manifest path`;
   unparseable → `spec.policy.statePath is not a valid path: <input>`
4. sources
5. plan entries in index order

### Per plan entry (`spec.plan[<i>]`) — name first, then kind
- blank name → `<path>.name must not be blank` (kind still checked)
- duplicate (keyed on stripped name, first wins) →
  `<path>.name duplicates plan entry '<n>' first declared at <firstPath>.name`
- kind absent → `<path>.kind is required`
- kind blank → `<path>.kind must not be blank`
- unknown → `<path>.kind unsupported plan kind '<raw>'` plus, when a suggestion exists,
  `. Did you mean '<id>'?` concatenated directly
- known → category shape check, then the kind's spec check, then (packages only) action
  check, then `spec.checksum`

Category shapes:
- PACKAGES → non-empty `<path>.spec.packages`
- APPS → app items
- SDKMAN → sdkman items
- INSTALLER → `spec` nil → `<path>.spec is required for plan entry '<name>'` and **return
  early** (the checksum check is skipped)
- CONTROL → nothing

`entryName` in messages is the **unstripped** name or `<unnamed>`.

### Shared primitives
```
SHA_256_HEX = [0-9a-fA-F]{64}
FILE_MODE   = [0-7]{3,4}
```
```
<path> must contain at least one item
<path>[<i>] must not be blank
<path> for plan entry '<name>' must not be blank
<path> is required
<path> must be absolute
<path> must be normalized
<path> is not a valid path: <input>
<path> must use https
<path> must include a host
<path> must not include user-info          (all three can fire together)
<path> is not a valid URI: <publicUrl>
<path>.algorithm is required
<path>.algorithm unsupported checksum algorithm '<a>'
<path>.value is required
<path>.value must be a 64-character hexadecimal SHA-256 digest
<path> must be a 3 or 4 digit octal mode
<path> must not be blank
<path> must be a normalized relative POSIX path
<path>[<i>] must be a non-blank string
```
Archive URL detection: path (lowercased) ends `.tar.gz`, `.tgz`, `.tar.xz`, `.zip`.

### Source validation
Section order `entries` (checksum only), `apt`, `dnf`, `rpm`, `pacman`, `zypper`, `flatpak`.
Path prefix `spec.sources.<section>[<i>]`.
```
<path>.name is required
<path>.spec is required
<path> must be an absolute HTTPS URL without user-info
<path> must be a valid HTTPS URL without user-info
<path> must be an absolute path
<path> must be a valid path
<path>.checksum is required for the remote signing key
<path>.checksum has no remote signing-key artifact to verify
```
apt order: `.source` required → apt source entry parse (failure →
`.source must contain an HTTPS repository URL without user-info`) → `.sourceList` absolute →
`.signingKeyUrl` https → `.keyring` absolute → checksum → artifact pairing.
rpm/dnf/zypper order: `.id` → `.baseUrl` → `.repoFile` → `.gpgKeyUrl` →
`<path>.gpgKeyUrl is required when gpgCheck is true` →
`<path>.gpgCheck must be true for an enabled repository` → checksum → pairing.
flatpak: `.remote` → `.url` → checksum →
`<path>.checksum is required for the Flatpak repository descriptor`.
pacman: `.server` → `.config` → `.include` → sig-level trust (`<path>.sigLevel <policy msg>`)
→ checksum → `<path>.checksum has no finite Pacman source artifact to verify`.

### Per-kind spec checks

**sdkman** — `<path>.spec.packages must contain at least one item`; per item
`<itemPath> must be a candidate string or object`, then
`<p> SDKMAN <candidate|version> must not be blank` /
`<p> SDKMAN <candidate|version> contains unsafe shell characters`
(safe value `[A-Za-z0-9._+-]+`).

**apps** — both `apps` and `appIds` empty → `<path>.spec.apps must contain at least one item`.

**package actions** — per index at `<path>.spec.actions[<i>]`:
`<actionPath>.action for plan entry '<name>' must not be blank`, then
`<actionPath>.action for plan entry '<name>' unsupported action '<a>' for <kindId>`, then
non-blank args.

**aur** — `<path>.spec.packageManager must be one of paru, yay` /
`<path>.spec.packageManager unsupported AUR helper '<v>'`.

**binary-downloads**, in order: `binaryName` → `url` https → `installPath` absolute →
`checksumUrl` https → `signatureUrl` https → trust block → archive/archivePath → archivePath
shape → `symlinkPath` absolute → `mode` octal (path always says `.mode`) →
`<path>.spec.stripComponents must not be negative`.
Trust block order:
```
<path>.spec must declare either checksum or checksumUrl, not both
<path>.spec must declare a literal SHA-256 checksum or a detached signature with allowedSignerFingerprint
<path>.spec.signatureUrl and .spec.allowedSignerFingerprint must be configured together
<path>.spec.allowedSignerFingerprint must contain exactly 40 or 64 hexadecimal characters
<path>.spec.archivePath is required for archive downloads
```

**file-writes** — per item at `<path>.spec.files[<i>]`:
```
<itemPath> for plan entry '<name>' must be an object
<itemPath> must define exactly one of content or source
<itemPath>.content must be a string
```
then destination absolute, source absolute, mode octal, owner present, group present.

**shell-scripts** — duplicate-name pass first, then per item. Duplicate message:
`<declarationPath> duplicates script item '<n>' first declared at <previousPath>`
(key = declared name stripped, else `<entryName>[<i>]`; declaration path is
`<itemPath>.name` when declared, else `<itemPath>`).
```
<itemPath> must be a script path string or object
<itemPath> for plan entry '<name>' must define exactly one of script or url
<itemPath>.sha256 is required for a remote script
<itemPath>.sha256 must be a 64-character hexadecimal SHA-256 digest
<itemPath>.sha256 is only valid for a remote URL
```

**commands** — `<path>.spec.commands must contain at least one item`; duplicate pass with
kind word `command`; per item:
```
<itemPath> must be a command string, argv array, or object
<itemPath> must define exactly one shell string or direct argv command
```
then `<path>.spec.shell` present and `<path>.spec.workingDir` valid.
(shell form = textual `run` or `shellCommand`; argv form = non-empty array `run`, `argv`, or
textual `command`.)

Shared item checks:
```
<itemPath>.allowedExitCodes must contain non-negative integers
<itemPath>.timeout is not a supported duration
<itemPath>.timeout must be positive
<itemPath>.timeoutSeconds must be a positive integer
<itemPath>.confirm must be a boolean or non-blank string
<p> must be an object                       (env)
<p>.<key> must be a string or object
<p>.<key>.value is required
<p>.<key>.value must be a string
<p>.<key>.sensitive must be a boolean
<path>.allowedExitCodes must not contain negative values
```
Validator duration grammar is lowercased first, unlike the mapper's.

**nerd-fonts**, order config shape → installer version → binary → families:
```
<path>.spec.config must be an object for nerd-fonts
<path>.spec.destination for plan entry 'nerd-fonts' must not be blank
<path>.spec.release must pin an exact release such as v3.4.0
<path>.spec.config.release must pin an exact release such as v3.4.0
<path>.spec.config.destination for plan entry 'nerd-fonts' must not be blank
<path>.spec.installerVersion must pin an exact release such as v1.2.3
<path>.spec.nerdfontBinary for plan entry '<name>' must not be blank
```
Families checked at `<path>.spec.config.families` when an inline config exists, else
`<path>.spec.families`. Exact release pattern `v\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?`.

**dotfiles-apply**:
```
<path>.spec.config for plan entry '<name>' must be a path string
<path>.spec.installerVersion must pin an exact release such as v1.2.3
```

**binstaller-profile**:
```
<path>.spec.config for plan entry '<name>' must be a path to a BinaryDistributionProfile, not an inline object
<path>.spec.lockFile is required for plan entry '<name>' because locked is true
```

**gpg-key**:
```
<path>.spec.keys is required for plan entry '<name>'
<path>.spec.keys[].url for plan entry '<name>' must be HTTPS without user-info or an absolute file URI
<path>.spec.keys[].url for plan entry '<name>' is not a valid trusted key URL
<path>.spec.keys[].fingerprint for plan entry '<name>' must be a full 40-character hexadecimal OpenPGP fingerprint
```

**tool-packages**:
```
<path>.spec.backend for plan entry '<name>' is not a supported backend: <b>
<path>.spec.packages is required for plan entry '<name>'
```

**zypper-repository**, order baseUrl present → baseUrl https → gpgKeyUrl https → checksum →
```
<path>.spec.gpgKeyUrl is required for plan entry '<name>' because gpgCheck is enabled
<path>.spec.gpgCheck must be true for enabled plan entry '<name>'
<path>.spec.gpgKeyUrl and checksum must be configured together for plan entry '<name>'
```

**interrupt** (nil spec → no checks):
```
<path>.spec.message for plan entry 'interrupt' must not be blank
<path>.spec.resumeFrom must be either current or next
<path>.spec.exitCode must be between 0 and 255
```

**user-groups**:
```
<path>.spec.groups is required for plan entry '<name>'
<path>.spec.groups for plan entry '<name>' repeats a group
<path>.spec.groups for plan entry '<name>' contains '<g>'. Group membership is append-only; Fluxion never removes a user from a group. Use gpasswd -d by hand.
```

**git-config**:
```
<path>.spec.entries is required for plan entry '<name>'
<path>.spec.entries for plan entry '<name>' has key '<k>'; git config keys are section.key, for example user.email
```

**git-repo**: `<path>.spec.repos is required for plan entry '<name>'`, then per repo
`.spec.repos[].url` and `.spec.repos[].dest`.

**systemd-unit**:
```
<path>.spec.units is required for plan entry '<name>'
<path>.spec.units[] for plan entry '<name>' cannot both mask and enable '<u>'
```

**system-setting**:
`<path>.spec for plan entry '<name>' declares no system setting to apply`

**system-update**:
```
<path>.spec.packageManager does not support system-update: <m>
<path>.spec for plan entry '<name>' cannot be both distUpgrade and refreshOnly
```

### Golden ordering example
Header `apiVersion: bad-version`, `kind: WrongKind`, blank name, plan
`[{duplicate, commands, spec.commands: []}, {duplicate, apt-package}]` →
```
apiVersion must be 'initkit.io/v1alpha1' but was 'bad-version'; kind must be 'WorkstationProfile' but was 'WrongKind'; metadata.name must not be blank; spec.plan[0].spec.commands must contain at least one item; spec.plan[1].name duplicates plan entry 'duplicate' first declared at spec.plan[0].name; spec.plan[1].kind unsupported plan kind 'apt-package'. Did you mean 'apt-packages'?
```

## A.5 Variable interpolation (manifest only, on the raw tree, before deserialization)

Token pattern `\$\{([^}]+)}` — **only braced syntax**. `$(...)`, backticks, globs, and bare
`$VAR` stay literal.

Sources: environment (all env vars, then `HOME` and `USER` filled in when absent), then
`spec.vars`, then host facts `host.os.name`, `host.os.arch`, `host.user`, `host.home`.
**Precedence: environment > spec.vars > host facts** (later sources only fill gaps).

Algorithm:
1. collect `spec.vars` — **only textual values are kept**, non-strings silently dropped
2. resolve spec vars recursively with an explicit stack; errors here are raised **before** any
   document interpolation
3. deep-copy the tree and interpolate every **textual value** anywhere; numbers, booleans and
   nulls are untouched; **object keys are never interpolated**

Path construction: a field name matching `[A-Za-z_][A-Za-z0-9_]*` appends `.name`, otherwise
`.['name']`; array elements append `[<i>]`.

Plan context: while iterating the array at path exactly `spec.plan`, an object child with a
textual `name` establishes `(resolvedName, strippedLoweredKind)` which propagates to all
descendants.

**Excluded shell-expression fields** — only inside a plan entry:
- path ends `.unless`
- path ends `.probeCommand`
- kind `assert` and path ends `.spec.command`
- kind `commands` and (path matches `.*\.spec\.commands\[\d+]` or ends `.run` or ends
  `.shellCommand`)

Any `${…}` in an excluded field is an error and the literal token is left in place:
```
<path> in plan entry '<name>' cannot interpolate <token> inside a shell expression; use env or structured argv
<path> cannot interpolate <token> inside a shell expression; use env or structured argv
```

Unresolved (empty name or missing key):
```
<path> in plan entry '<name>' references unresolved variable <variable>
<path> references unresolved variable <variable>
```
where `variable` is the raw token when the name is empty, else `${name}`. The original token
is substituted back so the document stays well-formed. Names are stripped before lookup, and
replacement values are inserted literally (`$` and `\` are not re-interpreted).

Cycle:
```
<specVarPath(key)> contains a cyclic variable reference '${<key>}'
```
The raw uninterpolated value is returned for that reference and resolution continues.

## A.6 `when` evaluation and host facts

Host facts are fetched **once** for the plan-level pass; per-item `when` guards inside
`scripts`/`commands`/`files` fetch **fresh facts per item**.

Missing `when` → selected. Non-matching → `SkippedPlanEntry(name || "<unnamed>",
kind || "<unknown>", reason)`.

Evaluation order, first failure wins:
1. reject `files`/`vars`/`expression` →
   **raises** `Unsupported when conditions: <joined in the order files, vars, expression>`
2. scalar facts in this order: `os`→osFamily, `osFamily`, `distribution`, `distributions`,
   `version`, `codename`, `architecture`, `architectures`
3. `commands` — ALL must exist
4. `commandExists` — ANY must exist
5. `oneOf`

Matcher extraction: nil → `[]`; textual → `[stripped]`; array → non-blank textual elements
stripped; object → first present of `oneOf`, `equals`, `value`, recursively; else `[]`.
Comparison is stripped + lowercased on both sides; an unknown actual never matches.

Skip reasons (verbatim):
```
when.<label> has no supported matcher
when.<label> expected one of [a, b] but was <actual|<unknown>>
when.<label> expected '<command>' on PATH
when.<label> expected one of [a, b] on PATH
when.oneOf no branch matched
```
`oneOf` with an empty list selects. Each branch is a full evaluation including its own
unsupported-field rejection.

### Host fact detection (Linux)
```
osFamily      literal "linux"
distribution  os-release ID, stripped + lowercased
version       os-release VERSION_ID
codename      os-release VERSION_CODENAME, else UBUNTU_CODENAME
architecture  normalized machine arch
```
`/etc/os-release` parsing: not a regular file or any IO error → `{}`. Per line: strip; skip
blank and `#`; split at the first `=` with the key non-empty; unquote the value — strip, and
if it is at least two characters wrapped in matching `"` or `'`, drop the quotes and apply
`\"`→`"` then `\\`→`\`. Later duplicate keys overwrite earlier ones.

Architecture normalization: `x86_64|amd64`→`amd64`; `aarch64|arm64`→`arm64`;
`armv7l|armv7|armhf`→`armv7`; `i386|i486|i586|i686|x86`→`386`; blank→`unknown`; anything else
passes through stripped + lowercased.

`commandExists`: nil/blank → false; contains `/` or `\` → false; otherwise scan `PATH`
segments (blanks dropped) for a regular executable file.

## A.7 "Did you mean" suggestions

1. candidate = raw stripped + lowercased; empty → no suggestion
2. `budget = max(2, candidate.size // 3)`
3. plain Levenshtein (insert/delete/substitute, cost 1) against every registered id
4. keep distance ≤ budget
5. return the minimum; **ties resolve to the first in registry declaration order**

Pinned: `apt-package`→`apt-packages`; `APT-Packages`→`apt-packages`;
`systemd-units`→`systemd-unit`; `gitconfig`→`git-config`; `helm`, `ansible-playbook`, `""`,
nil → none.

# Part B — tui

## B.0 Types

`ItemResult`: `PENDING RUNNING SUCCESS FAILED INTERRUPTED SKIPPED DRY_RUN`
`ItemStatus(name, module, result, elapsed?, detail?)`

`AppState` variants: `Dashboard(profiles, selectedIndex)`,
`ModuleList(config, moduleEnabled, selectedIndex)`,
`ProbePhase(config, totalItems, probedSoFar, currentItem)`, `Executing(screen, config)`,
`Logs(screen)`, `SudoPrompt(previousState, prompt)`, `Completed(finalScreen)`,
`Error(message, cause)`

`ExecutionScreenState(profileName, currentModule, totalModules, completedModules, items,
logLines, planEntryNames, paused, showLogs)`:
- from a config: when a phase named `manifest-plan` exists, `totalModules` is that phase's
  module count, items are one PENDING item per module (name and module both the module name;
  `detail = "interrupt"` for interrupt modules) followed by one SKIPPED item per skipped plan
  entry with detail `<kind> skipped: <reason>`, and `planEntryNames` are the module names
- `progressPercent = totalModules == 0 ? 0 : completedModules * 100 // totalModules`
- log ring capped at **200** lines
- merging an item by `(name, module)` carries over the existing detail when the replacement
  has none

## B.1 Screens

The **only** ANSI sequence in the whole TUI is `\e[H\e[2J` (home + erase), printed before each
full repaint. **No colour, no cursor hiding, no alternate screen.** All text passes through
the display sanitizer. Box-drawing characters used: `┌ ─ ┐ │ └ ┘`.

Dashboard:
```
sysboot
Detected OS: %s

Profiles:
%s
```
Profiles joined by newline, each sanitized; empty → the literal `  (no profiles found)`.
OS detection: first `/etc/os-release` line starting `PRETTY_NAME=`, take the substring after
`PRETTY_NAME=` and remove **all** `"`; absent or unreadable → `Unknown Linux`.

Probe phase (bar width 40):
```
┌─ Probe Phase ──────────────────────────────────┐
│  [%s] %3d/%3d │
│  Checking: %-36s │
└────────────────────────────────────────────────┘
```
`filled = total == 0 ? 40 : (done / total * 40).to_i`; bar is `=` × filled then spaces.
Truncate at 36: cut to 33 and append `...`.

Execution:
```
sysboot - <profileName> [<percent>%]
Current module: <currentModule>

%-36s %-12s %s%s
```
per item: sanitized name, `ItemResult` name, `"%.1fs"` elapsed or empty, then
`"  " + detail` or empty.

Completed:
```
┌─ Bootstrap Complete ───────────────────────────┐
│  Selected: %-4d  Completed: %-4d  Failed: %-4d │
│  Interrupted: %-4d  Skipped: %-4d                  │
└────────────────────────────────────────────────┘
```
`Selected` = plan-entry count when > 0, else the number of non-SKIPPED items.
When anything failed or was interrupted:
```

Failed items (retry with: fluxion apply --skip-already-installed):
  - <name> [<module>]
```

Sudo prompt: `Sudo password required: <prompt>` (single line, no trailing newline).

## B.2 Pre-run selector

Line-oriented, three levels. **No console → the config is returned unfiltered with no prompt
at all.** Initial selection has every phase, module, and entry selected.

Parsing: strip and split on whitespace into at most 2 tokens; a missing or non-numeric second
token yields index `-1`. Indices are 1-based and silently ignored when out of range. Word
commands are case-insensitive:
- **run** = the literal `run` **or an empty/blank line**
- **quit** = `q` or `quit`
- **back** = `b` or `back` (steps and entries levels only)

Level 1, prompt `jobs> `:
```

Select jobs for profile '<profileName>'
Commands: j N toggle job, s N select steps, run, q
%2d. [%s] %s  (%d step(s))
```
Mark is `x` when selected, else a space. `j N` toggles a phase — selecting re-selects **all**
its modules and **all** their entries; deselecting clears them. `s N` descends.

Level 2, prompt `steps> `:
```

Job '<phaseName>' steps
Commands: t N toggle step, e N select entries, b, run, q
%2d. [%s] %s  (%d entr%s)
```
Trailing word is `entry` for 1 and `entries` otherwise. When the phase is exactly
`manifest-plan`, skipped plan entries are appended as
`    [-] <name>  (<kind> skipped: <reason>)`.
`run` here accepts the **whole current selection** immediately.

Level 3, prompt `entries> `:
```

Step '<moduleName>' entries
Commands: t N toggle entry, b, run, q
%2d. [%s] %s
```
Toggling an entry makes the module selected when its set is non-empty and **deselects the
module when the set becomes empty**.

Result: cancelled → the run raises "cancelled". Accepted → filter the config:
- empty phase list after filtering → `Select at least one job before running.`
- profile name, target, policy, skipped entries and source setups are preserved
- phase `dependsOn` is filtered to surviving phases
- a module with an empty selected-entry set is dropped
- entry-filterable modules: packages/zypper by package value, file-writes by destination,
  flatpak by app id, shell-command/shell-script by item name, nerd-fonts by family (config
  rebuilt), sdkman by item key, user-groups by item key, git-config by sorted key, git-repo by
  destination, systemd-unit by qualified name, gpg-key by item key, tool-packages by name
- everything else passes through whole: apt/rpm/pacman/zypper repository, flatpak-remote,
  compiled-binary, dotbot, default-shell, oh-my-zsh, toolchain, shell-reload, assert, manual,
  interrupt, binstaller, system-setting, system-update

## B.3 Sudo prompting

- No console → return nothing immediately, publish no prompt.
- Otherwise publish the prompt, read the password with the format `"%s "` (**trailing space**),
  return nothing on empty input, else a defensive copy. Always zero-fill the source buffer and
  clear the published prompt afterwards.
- During execution the render loop polls the published prompt each tick. While one is pending
  it renders the sudo screen **once**, then only sleeps a frame and continues — no event
  draining, no execution repaint — until the prompt clears, at which point the previous state
  is restored and the latch resets.
- Privilege preflight runs on its own thread with the same polling, restores the previous
  state in an ensure block, and rethrows failures (wrapping unknown ones as
  `TUI privilege preflight failed` / `TUI privilege preflight interrupted`).

## B.4 Event listener and live progress

```
MAX_DRAIN_PER_TICK       = 50
EVENT_QUEUE_CAPACITY     = 512
STRUCTURAL_EVENT_RESERVE = 64
```
Command output display is **off by default**.

- `ITEM_OUTPUT` events are **droppable**: enqueued only when output display is on, the line is
  non-blank, and remaining capacity is above the reserve.
- `ITEM_STARTED` installs a fresh streaming sanitizer for the `(module, item)` key;
  `ITEM_COMPLETED` flushes its trailing text as one more output event, enqueues the structural
  event, then removes the sanitizer.
- **Structural events are never lost**: on a full queue, evict the first queued `ITEM_OUTPUT`
  and retry; if none can be evicted, block.
- The app drains **one** event per tick so it repaints once per event, and keeps the loop
  alive while events remain pending after the worker exits.

Log line prefixes (note the alignment spaces):
```
[PHASE] <module>
[PHASE DONE] <module>
[PHASE FAILED] <module>
[PHASE BLOCKED] <module>
[RESTART REQUIRED] <item>
[START] Module: <module>
[DONE]  Module: <module>
[RUN]   <item>
[CANCELLED] stopped before <item or module>
[ERROR] <item> in <module>
[OK]    %s (%.1fs)
[FAIL]  %s (exit %d): %s
[SKIP]  %s: %s
[DRY]   %s: %s
[PAUSE] %s: %s
```
Result mapping: Success→SUCCESS, Failure→FAILED, Skipped→SKIPPED, DryRun→DRY_RUN,
Paused→INTERRUPTED. Elapsed comes from Success/Failure, otherwise zero.

Manifest-plan mode (when the module name is a known plan entry):
- `ITEM_STARTED` does **not** overwrite an item already holding FAILED or INTERRUPTED
- `ITEM_COMPLETED` merges with precedence `FAILED > INTERRUPTED > DRY_RUN > SKIPPED > incoming`
- `MODULE_COMPLETED` bumps the counter, first writing SUCCESS with zero elapsed when the item
  has no terminal result yet

Render loop, default interval 100 ms:
```
while worker alive || events pending
  sudo prompt pending? render once, sleep, next
  drain one event
    present -> update state, repaint, next (no sleep)
    absent  -> update state, repaint, sleep one frame
join worker
```

Run sequence:
1. no selectable config → print the dashboard and return
2. selection prompt; cancelled → cancel the run
3. `effective_dry_run = dry_run || policy.dryRunDefault`
4. state = executing with the initial screen
5. worker thread runs dry-run or execute with the selected phases
6. render until complete; rethrow any captured failure — **the completed screen is not
   printed when the run failed**
7. state = completed; clear; print the completed screen
