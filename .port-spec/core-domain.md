# Java `core` module — porting reference

Extracted from `dev.sysboot.core` (113 types, one flat package). Behavioural fidelity notes for
the Crystal port. Structure is deliberately NOT mirrored — only behaviour, names visible to users,
and validation messages.

## Enums (exact constant lists)

**EventKind** (12) — note: the type is `EventKind`, not `EventType`
```
PHASE_STARTED PHASE_COMPLETED PHASE_FAILED PHASE_BLOCKED RESTART_REQUIRED
MODULE_STARTED ITEM_STARTED ITEM_OUTPUT ITEM_COMPLETED MODULE_COMPLETED
CANCELLED ERROR
```

**ItemType** (31)
```
PACKAGE_ACTION PACKAGE APT_REPOSITORY RPM_REPOSITORY ZYPPER_REPOSITORY
PACMAN_REPOSITORY FILE_WRITE FLATPAK FLATPAK_REMOTE SHELL_SCRIPT
COMPILED_BINARY DOTBOT DEFAULT_SHELL OH_MY_ZSH TOOLCHAIN NERD_FONT
SHELL_RELOAD SHELL_COMMAND ASSERT MANUAL INTERRUPT SDKMAN_PACKAGE
BINSTALLER_PROFILE USER_GROUP GIT_CONFIG GIT_REPO SYSTEMD_UNIT
SYSTEM_SETTING SYSTEM_UPDATE GPG_KEY TOOL_PACKAGE
```

**PackageManagerKind** (8) — includes FLATPAK and CARGO
```
DNF PACMAN PARU YAY APT FLATPAK ZYPPER CARGO
```
`supportsSystemUpdate()` true for DNF PACMAN PARU YAY APT ZYPPER; false for CARGO FLATPAK.

**PhaseStatus** (4): `COMPLETED FAILED BLOCKED SKIPPED`
**PlanEntryStatus** (2): `COMPLETED INTERRUPTED`
**ShellKind** (3): `ZSH BASH SH` — `binaryName()` = lowercase name
**ToolchainKind** (4): `RUSTUP JULIAUP SDKMAN GENERIC`
**InterruptResumeMode** (2): `CURRENT NEXT` — YAML `"current"` / `"next"`
**GitRepoUpdate** (3): `NONE PULL RESET_HARD` — only `NONE` accepted
**SystemdState** (3): `STARTED STOPPED UNCHANGED`

**GitConfigScope**: `GLOBAL(--global, unprivileged)`, `SYSTEM(--system, privileged)`, `LOCAL(--local, unprivileged)`
**SystemdScope**: `SYSTEM(--system, privileged)`, `USER(--user, unprivileged)`

**ToolPackageBackend** (7) — `id` / `binary`:
```
CARGO_BINSTALL cargo-binstall/cargo-binstall   CARGO cargo/cargo
SNAP snap/snap                                 PIPX pipx/pipx
UV_TOOL uv-tool/uv                             NPM_GLOBAL npm-global/npm
GO_INSTALL go-install/go
```

There is **no** `ChecksumAlgorithm` and **no** `ItemStatus` enum.

## Plan kinds (YAML `kind` discriminator) — 25 ids, declaration order

| kind | category | module | allowed `spec.actions` |
|---|---|---|---|
| `apt-packages` | PACKAGES | PackageModule(APT) | update, upgrade, dist-upgrade |
| `aur-packages` | PACKAGES | PackageModule(PARU\|YAY) | — |
| `cargo-packages` | PACKAGES | PackageModule(CARGO) | — |
| `dnf-packages` | PACKAGES | PackageModule(DNF) | check-update, upgrade, swap, groupupdate, group-update |
| `pacman-packages` | PACKAGES | PackageModule(PACMAN) | sync-upgrade, syu, upgrade |
| `zypper-packages` | PACKAGES | PackageModule(ZYPPER) | refresh, update, dup, dup-from |
| `sdkman-packages` | SDKMAN | SdkmanModule | — |
| `flatpak-packages` | APPS | FlatpakModule | — |
| `binary-downloads` | INSTALLER | CompiledBinaryModule | — |
| `shell-scripts` | INSTALLER | ShellScriptModule | — |
| `commands` | INSTALLER | ShellCommandModule | — |
| `file-writes` | INSTALLER | FileWriteModule | — |
| `nerd-fonts` | INSTALLER | NerdFontModule | — |
| `dotfiles-apply` | INSTALLER | DotbotModule | — |
| `binstaller-profile` | INSTALLER | BinstallerModule | — |
| `user-groups` | INSTALLER | UserGroupsModule | — |
| `git-config` | INSTALLER | GitConfigModule | — |
| `git-repo` | INSTALLER | GitRepoModule | — |
| `systemd-unit` | INSTALLER | SystemdUnitModule | — |
| `system-setting` | INSTALLER | SystemSettingModule | — |
| `system-update` | INSTALLER | SystemUpdateModule | — |
| `gpg-key` | INSTALLER | GpgKeyModule | — |
| `tool-packages` | INSTALLER | ToolPackagesModule | — |
| `zypper-repository` | INSTALLER | ZypperRepositoryModule | — |
| `interrupt` | CONTROL | InterruptModule | — |

`Category` enum: `PACKAGES APPS SDKMAN INSTALLER CONTROL`.
Lookup on stripped + lowercased id. `closestId` = Levenshtein, budget `max(2, len/3)`.
`PlanKindCatalog.Entry(id, summary, category, packageActions)`; category lowercased.

Modules with **no** YAML kind (stable schema / `spec.sources` / legacy only):
`AptRepositoryModule RpmRepositoryModule PacmanRepositoryModule FlatpakRemoteModule ZypperModule
DefaultShellModule OhMyZshModule ToolchainModule ShellReloadModule AssertModule ManualModule`

## BootstrapModule variants (31) — declaration order

```
PackageModule AptRepositoryModule RpmRepositoryModule PacmanRepositoryModule FileWriteModule
FlatpakModule FlatpakRemoteModule ShellScriptModule CompiledBinaryModule ZypperModule
DotbotModule DefaultShellModule OhMyZshModule ToolchainModule NerdFontModule ShellReloadModule
ShellCommandModule AssertModule ManualModule InterruptModule SdkmanModule BinstallerModule
UserGroupsModule GitConfigModule GitRepoModule SystemdUnitModule SystemSettingModule
SystemUpdateModule GpgKeyModule ToolPackagesModule ZypperRepositoryModule
```

## Validation messages (user-visible — preserve verbatim)

### Value objects
- ModuleName: `Module name must not be null` / `Module name must not be blank` (stripped)
- ProfileName: `Profile name must not be null` / `Profile name must not be blank` (stripped)
- PhaseName: `Phase name must not be blank` — **not stripped**
- Sha256Digest: `SHA-256 digest must contain exactly 64 hexadecimal characters` (stripped, lowercased)
- Checksum: `Checksum algorithm must not be blank` / `Checksum value must not be blank`;
  algorithm normalized to upper, `SHA256`→`SHA-256`; value lowercased
- BinaryUrl: `Binary download URL must use https scheme, got: <public url>` /
  `Binary download URL must include a host: …` / `Binary download URL must not include user-info: …`

### PackageName
Patterns:
```
UNSAFE_CHARS           [\s$;|&`><"'\\]
URL_SCHEME             (?i)^(?:file|https?|ftp|git|ssh):
SAFE_IDENTIFIER_SYNTAX [A-Za-z0-9@][A-Za-z0-9@._+:/=~-]*
REPOSITORY_QUALIFIED   [A-Za-z0-9][A-Za-z0-9._+-]*/[@A-Za-z0-9][A-Za-z0-9._+:=~-]*
LOCAL_ARTIFACT         (?i).*(?:\.deb|\.rpm|\.apk|\.pkg\.tar(?:\.[a-z0-9]+)+|\.whl|\.tar(?:\.[a-z0-9]+)?|\.tgz|\.zip)$
```
Order of checks and messages:
1. `Package name must not be null`
2. strip; blank → `Package name must not be blank`
3. starts with `-` → `Package name must not be interpreted as an option: <v>`
4. unsafe chars → `Package name contains unsafe shell characters: <v>`
5. alternate source → `Package name must be a registry identifier, not a local or URL artifact: <v>`
6. not safe syntax → `Package name contains unsafe manager syntax: <v>`

`isAlternateSource`: starts `/`, `./`, `../`, `~/`; contains `://`; matches URL_SCHEME;
matches LOCAL_ARTIFACT; **or** contains `/` while not matching REPOSITORY_QUALIFIED.
Accepted by tests: `curl=8.14.1-2`, `@development-tools`, `libc6:amd64`, `extra/bash`, `neovim`.

### Flatpak app ids
`[A-Za-z][A-Za-z0-9_-]*(?:\.[A-Za-z][A-Za-z0-9_-]*){2,}` (≥3 dot segments).
Failure → `Flatpak app must be a registry app ID, not an option, path, URL, or alternate source: <v>`
Blank `remote` is **silently replaced by `flathub`**.
Empty appIds → `Flatpak module '<name>' must declare at least one app ID`
Duplicate → `Flatpak module must not repeat an app ID`

### Modules
- PackageModule empty pkgs+actions → `Package module '<name>' must declare a package or manager action`
- ZypperModule empty → `Zypper module '<name>' must declare at least one package`
- SdkmanModule empty → `SDKMAN module '<name>' must declare at least one package`;
  dup → `SDKMAN module '<name>' contains duplicate canonical packages`
- FileWriteModule empty → `File write module must contain at least one item`;
  dup → `File write module contains duplicate canonical destinations`
- ShellScriptModule empty → `script items must not be empty`; dup → `script item names must be unique: <n>`
- ShellCommandModule empty → `commands must not be empty`; blank shell → `shell must not be blank`;
  dup → `command item names must be unique: <n>`
- AssertModule → `assert command must not be blank` / `assert message must not be blank` / `assert shell must not be blank`
- ManualModule → `manual message must not be blank`
- InterruptModule → `Interrupt message must not be blank` / `Interrupt exit code must be between 0 and 255`
- UserGroupsModule → `user-groups requires at least one group` / `user-groups must not repeat a group` /
  `user-groups must not contain a blank group`;
  default checkpoint message: `Log out and back in so the new group membership (<a, b>) takes effect.`
  itemKey = `user:group` when user present else `group`
- GitConfigModule → `git-config requires at least one entry` /
  `git-config keys must be section.key, for example user.email, but got: <key>`;
  itemKey = `global:user.name` (scope flag minus `--`)
- GitRepoModule → `git-repo requires at least one repository` / `git-repo must not repeat a destination`
  - GitRepo: `git-repo url must not be blank` / `git-repo url must be valid` /
    `git-repo url must not contain query or fragment data` / `git-repo destination must not be blank` /
    `git-repo ref must be an exact immutable 40-hex commit` / `git-repo depth must be at least 1` /
    `git-repo update must be none for an immutable commit checkout`
- SystemdUnitModule → `systemd-unit requires at least one unit` /
  `systemd-unit must not repeat a qualified unit name`;
  unit: `systemd unit name must not be blank` / `systemd unit '<u>' cannot be both masked and enabled`;
  `qualifiedName()` appends `.service` when no `.`
- SystemSettingModule → `system-setting requires at least one setting`;
  itemKeys order: `localRtc`, `ntp`, `timezone`, `hostname` (when present), then sorted `locale:<key>`
- SystemUpdateModule → `system-update does not support <mgr>` /
  `system-update cannot be both distUpgrade and refreshOnly` / `system-update timeout must be positive` /
  `system-update timeout is too large`; itemKey = `<mgr>-system-update`
- GpgKeyModule → `gpg-key requires at least one key` / `gpg-key contains duplicate canonical key identities`
  - GpgKey: `gpg-key url must not be blank` /
    `gpg-key url must be HTTPS without user-info or an absolute file URI` /
    `gpg-key fingerprint must be 40 hex characters, but got: <v>`;
    itemKey = keyring path, else `fingerprint:<FP>`
- ToolPackagesModule → `<backend-id> requires at least one package` / `<backend-id> must not repeat a package name`
  - ToolPackage: `package name must not be blank` /
    `package name must not be an option or contain controls` /
    `package name must not contain shell metacharacters: <n>` /
    `package version must not be blank or contain controls`
- CompiledBinaryModule → `Binary name must not be blank` / `Binary name must be a file name, not a path` /
  `Install path must be absolute` / `Install path must be normalized` /
  `Symlink path must differ from install path` / `Install path and symlink path must not contain one another` /
  `Strip components must not be negative` / `Archive path must be a normalized relative POSIX path` /
  `Archive downloads must declare archivePath` / `Install mode must be octal` /
  `Allowed signer fingerprint must contain exactly 40 or 64 hexadecimal characters`
- OhMyZshModule → `Oh My Zsh installerRevision must be a full 40-character commit`
- ToolchainModule → `installScript must not be blank` / `installScript must be HTTPS without user-info`
- DotbotModule → `dotbotBinary must not be blank`
- NerdFontModule → `nerdfontBinary must not be blank`
- BinstallerModule → `binstallerBinary must not be blank` /
  `locked requires lockFile so the profile pins a specific lock`
- ReleaseTagPolicy → `<field> must pin an exact release such as v1.2.3`, pattern
  `v\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?`

### Repository policies
`SourceUrlPolicy.requireHttps` → `<subject> must be HTTPS without user-info`
APT source parsing:
- `APT source entry must be a single line`
- `APT source entry must start with deb or deb-src`
- `APT source entry has unterminated options`
- `APT source entry must contain a repository URL`
- `APT source repository URL must be valid`
- `APT keyring path must be absolute`
- `APT source entry requires exactly one signed-by option`
- `APT source options must not be empty`
- `APT source option must use name=value syntax`
- `APT source option is not allowed: <name>`
- `APT source option must not be repeated: <name>`
- `APT source signed-by option must match the configured keyring path`
Allowed options: `arch`, `signed-by` only.

`RepositoryDestinationPolicy` directories:
```
/etc/apt/sources.list.d (.list)   /etc/apt/keyrings + /usr/share/keyrings (.gpg .asc)
/etc/yum.repos.d (.repo)          /etc/pki/rpm-gpg (RPM-GPG-KEY-* or .gpg .asc .key)
/etc/zypp/repos.d (.repo)         /etc/zypp/keys (.gpg .asc .key)
/etc/pacman.conf (exact)          /etc/pacman.d (includes, any extension)
```
Messages: `<subject> must not be null` / `<subject> must be an absolute single-line path` /
`<subject> must be directly under <root>` / `<subject> must use one of these extensions: a, b` /
`<subject> must identify a file` /
`APT keyring path must be directly under /etc/apt/keyrings or /usr/share/keyrings` /
`GPG keyring path must be directly under an approved system key directory` /
`Pacman config path must be /etc/pacman.conf`
Subjects: `APT source-list path`, `RPM repository-file path`, `Zypper repository-file path`, `Pacman include path`

`RepositoryIdentifierPolicy` — `[A-Za-z0-9][A-Za-z0-9._-]*`, failure →
`<subject> must start with an alphanumeric character and contain only letters, digits, '.', '_', or '-'`

`PacmanRepositoryPolicy` SigLevel tokens (15):
```
Never Optional Required TrustedOnly TrustAll
PackageNever PackageOptional PackageRequired PackageTrustedOnly PackageTrustAll
DatabaseNever DatabaseOptional DatabaseRequired DatabaseTrustedOnly DatabaseTrustAll
```
- `Pacman SigLevel must contain only supported single-line tokens`
- `Enabled Pacman repositories must declare a signed and trusted SigLevel`
- `Enabled Pacman repositories must require signed, trusted packages and databases`
- `Unsupported Pacman SigLevel token`
Fold algorithm: two independent `{required, trustedOnly}` states (packages, databases), both start
false. `Package*` applies to packages only, `Database*` to databases only, bare to both.
`Never|Optional → required=false`; `Required → required=true`; `TrustAll → trustedOnly=false`;
`TrustedOnly → trustedOnly=true`. Both states must end `required && trustedOnly`.

### Repository / trust pairing messages
- `APT signing-key URL and SHA-256 checksum must be configured together`
- `APT signing-key URL requires a keyring path`
- `APT source requires a configured keyring path`
- `RPM signing-key URL and SHA-256 checksum must be configured together`
- `RPM gpgCheck requires a signing-key URL`
- `Enabled RPM repositories must enforce gpgCheck`
- `Zypper signing-key URL and SHA-256 checksum must be configured together`
- `Zypper gpgCheck requires a signing-key URL`
- `Enabled Zypper repositories must enforce gpgCheck`
- `Flatpak repository descriptor requires a SHA-256 checksum` (checksum effectively mandatory)

### PackageOperandPolicy fixed flags
```
APT    --with-new-pkgs --no-remove --trivial-only --download-only
DNF    --refresh --best --nobest --allowerasing --skip-broken
PACMAN --needed
ZYPPER --allow-vendor-change --no-allow-vendor-change --no-recommends
```
- `apt update does not accept configured arguments`
- `dnf groupupdate requires package operands` (≥1); `swap` needs ≥2 operands
- `zypper dup-from requires exactly one repository id`
- `<mgr> does not support package-manager actions`
- `Unsupported <MGR> action: <action>`
- `<MGR> action argument is not an allowed fixed option: <arg>`

### ToolPackageIdentifierPolicy patterns
```
CARGO_BINSTALL, CARGO  [A-Za-z0-9][A-Za-z0-9_-]*
SNAP                   [a-z0-9][a-z0-9-]{0,39}
PIPX, UV_TOOL          [A-Za-z0-9][A-Za-z0-9._-]*
NPM_GLOBAL             (?:@[a-z0-9][a-z0-9._-]*/)?[a-z0-9][a-z0-9._-]*   (case-insensitive)
GO_INSTALL             (?:[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,}(?:/[A-Za-z0-9][A-Za-z0-9._~-]*)+
VERSION                [A-Za-z0-9][A-Za-z0-9.!+_-]*
SNAP_CHANNEL           [A-Za-z0-9][A-Za-z0-9._-]*(?:/[A-Za-z0-9][A-Za-z0-9._-]*)?
```
- `<backend-id> package must be a registry identifier, not an option, path, URL, or alternate source: <n>`
- `<backend-id> version must be a registry version or channel, not an option, path, URL, or alternate source`
`isAlternateSource`: starts `/ ./ ../ ~/`, contains `://`, or ends `.whl .tar.gz .tgz .zip`

### BootstrapConfig.Builder (IllegalStateException, not IllegalArgument)
- `Profile name is required` / `OS target is required` / `Bootstrap policy is required`
- `Duplicate module name: <n>` / `Duplicate phase name: <n>`
- `At least one phase or module is required`
- Pending top-level modules become an implicit phase `default` / description `Default phase`,
  `dependsOn=[]`, `RestartPolicy.None`, `continueOnModuleError=true`

## Ports

**ShellRunner**
```
run(command, env, timeout) : ProcessResult                                  # abstract
run(command, env, timeout, outputSink)                                      # default: buffered, stdout lines then stderr lines
run(command, env, workingDirectory, timeout)                                # default: run(cmd, withPwd(env, dir), timeout)
run(command, env, workingDirectory, timeout, outputSink)
```
`withPwd` only sets the `PWD` env var — there is **no chdir** in the port contract.

**PackageManagerExecutor**: `supports(kind)`, `actionCommand(action)`, `installCommand(name)`,
`runAction(action)`, `install(name)`. Unsupported action →
`UnsupportedOperationException("Package manager action is not supported")`.

**InstalledProbe**: `supports(ItemType)`, `probe(ModuleItem)`, `probe(String itemKey)`.
Read-only, idempotent, bounded.

**StateRepository**: `load(profile)`, `save(state)`, `update(profile, fn)`,
`recordSuccess(profile, entry)`, `reset(profile)`, `forgetItem(profile, key)`,
`forgetPhase(profile, phase)`.

**BootstrapOrchestrator**: `execute(config, listener)`, `execute(config, listener, cancel)`,
`execute(config, phases, listener, cancel)` — phase subset unsupported →
`This orchestrator does not support phase selection`; `dryRun(config, listener)`.

**HostFactsProvider**: `facts()`, `commandExists(command)`
**ExecutionEventListener**: `onEvent(event)`
**ExecutionApproval**: `approve(ConfirmationRequest(item, prompt))`; `denyAll()`, `approveAll()`;
blank either → `confirmation item and prompt must not be blank`
**PrivilegeGate**: `verify(config)`; **PrivilegePreflight**: `verify()`, `none()`
**SudoPasswordProvider**: `requestPassword(prompt) : char[]?`
**CancellationSignal**: `never()`, `cancel()` (atomic CAS, true first time only), `isCancelled()`.
Cooperative: checked between items; in-flight item finishes, state flushes, resume hint produced.

## Result / status types

**StepResult** (sealed, `item()`)
```
Success(item, elapsed, detectedVersion?, checksum?)
Failure(item, errorMessage, exitCode, elapsed)
Skipped(item, reason)
DryRun(item, wouldExecute : List<String>)
Paused(item, message, nextPlanEntry?, exitCode)
```

**InstallationStatus** (sealed, `item()`)
```
InstalledFromState(item, installedAt, version)   # prior successful install recorded in state
InstalledByProbe(item, detectedVersion)          # live probe confirmed presence now
NotInstalled(item)                               # neither confirms -> treat as absent
Unknown(item, reason)                            # probe itself errored -> conservatively absent
```

**SkipDecision** (sealed, `itemKey()`): `Skip(itemKey, reason : InstallationStatus)`, `Run(itemKey)`

**ExecutionEvent**
```
moduleName, item, kind, result?, timestamp, phaseContext?, outputLine?
```
Phase events use `ModuleName(phase.value())` as the module and set `phaseContext`.
`outputLine` present only on `ITEM_OUTPUT`. `cancelled(phase, nextPlanEntry?)` puts the next entry
in `item` (or `""`). `restartRequired(phase, message)` puts the message in `item`.

**ProcessResult**(exitCode, stdout, stderr, elapsed); `isSuccess()` = exitCode == 0

**ModuleItem**
```
moduleName, key, displayName, itemType, packageManager?, sourceSetup?, configuredModule?
```
`qualifiedKey()` = `<module>/<key>`. Factories: `packageItem`, `packageActionItem`,
`sourceSetupItem`, `configuredModuleItem`.

## State model

**BootstrapState**
```
profileName, lastRunAt, sysbootVersion,
entries : List<StateEntry>, phaseEntries : List<PhaseStateEntry>,
planEntryEntries : List<PlanEntryStateEntry>,
nextPlanEntry?, manifestIdentity?, manifestFingerprint?
```
- `findEntry(module, itemKey, itemType)` — first match on all three
- `isPhaseCompleted(phase)` — status COMPLETED
- `isPhaseCompleted(phase, fingerprint)` — COMPLETED **and** fingerprint present and equal
- `withoutItem(itemKey)` removes **all** matching regardless of module/type;
  `withoutItem(module, key, type)` removes the exact triple
- **Every `with*`/`without*` refreshes `lastRunAt` to now — except `withRunMetadata`**
- `hasRecordedWork()` = any list non-empty or nextPlanEntry present

**StateEntry**: `profileName, moduleName, itemKey, itemType, completedAt, version?, checksum?, sourceUrl?`
**PhaseStateEntry**: `phaseName, status, completedAt, fingerprint?, reason?`
**PlanEntryStateEntry**: `entryName, status, updatedAt, message?` — blank name →
`Plan entry name must not be blank`

## Config aggregate

**Phase**: `name, description, modules, dependsOn, restartPolicy, continueOnModuleError`
— 5-arg ctor defaults `continueOnModuleError = true`
**BootstrapPolicy**: `dryRunDefault?, continueOnErrorDefault?, requireSudoDefault?`
**BootstrapConfig**: `profileName, target, policy, phases, skippedPlanEntries, sourceSetups`;
`modules()` flattens phases.
**SkippedPlanEntry**(name, kind, reason) — blank →
`Skipped plan entry name must not be blank` / `… kind …` / `… reason …`

**OsTarget** sealed: `FedoraTarget(release)`, `ArchTarget()`, `OpenSuseTarget(version)`,
`DebianTarget(codename)`. YAML ids `fedora arch opensuse debian`. No validation.

**HostFacts**: `osFamily, distribution?, version?, codename?, architecture` — required fields
stripped and non-blank (`OS family`, `Architecture`); optional fields stripped, blank → empty.

## Item detail records

**ShellCommandItem**
```
name, shellCommand?, argv?, shell, workingDir?, environment, sudo,
allowedExitCodes, creates?, unless?, confirm?, timeout
```
- empty `allowedExitCodes` silently becomes `[0]`
- `exactly one of shell command or argv is required`
- `command()` = argv, else `[shell, "-lc", shellCommand]`; prepend `sudo` when sudo
- default timeout 30 minutes

**ShellScriptItem**
```
name, script?, url?, args, workingDir?, environment, sudo,
allowedExitCodes, creates?, unless?, confirm?, timeout, sha256?
```
- `exactly one of script or url is required`
- `remote scripts require sha256; local scripts must omit it`
- `remote script URL must be HTTPS without user-info`
- `key()` = script path, else public URL

**FileWriteItem**: `name, destination, content?, source?, owner?, group?, mode?, sudo`
- `File write name must not be blank` / `File write destination must be absolute` /
  `File write destination must not be the filesystem root` /
  `File write must define exactly one of content or source` /
  `File write source must be absolute` / `File write owner must not be blank` /
  `File write group must not be blank` / `File write mode must be octal`

**SdkmanPackage**(candidate, version?) — `SAFE_VALUE = [A-Za-z0-9._+-]+`;
`SDKMAN candidate must not be blank` / `SDKMAN candidate contains unsafe shell characters: <v>` /
same for `SDKMAN version`. `itemKey()` = `candidate@version` or `candidate`.

**PackageManagerAction**(action, args) — `Package manager action must not be blank` /
`Package manager action arg must not be blank` / `Package manager action arg must not contain controls`;
`itemKey(i)` = `action[<i>]`

**ShellEnvironmentVariable**(name, value, sensitive) — `[A-Za-z_][A-Za-z0-9_]*`;
`environment variables must not contain NUL` / `environment variable name must be portable`

## Redaction

`SecretRedactor`, mask `<redacted>`. Sensitive name alternation:
```
(?:api[._-]?key|access[._-]?key|private[._-]?key|key[._-]?passphrase|passphrase
|authorization|token|secret|password|passwd|credentials?)
```
`QUOTED_OR_TOKEN = (?:"[^"]*("|$)|'[^']*('|$)|[^\s,;\]}]+)`

Applied **in this order**:
1. URL credentials `(?<![a-zA-Z0-9+.-])([a-zA-Z](?>[a-zA-Z0-9+.-]*)://)[^\s/@:]+(:[^\s/@]*)?@` → `$1<redacted>@`
2. Authorization Basic → `$1<redacted>`
3. Authorization Bearer → `$1<redacted>`
4. `(?i)(\bbasic\s+)[a-z0-9+/]{8,}={0,2}(?=[\s"'}\],;]|$)` → `$1<redacted>`
5. curl `--user` / `-u` → `$1<redacted>`
6. token assignment (name `=`/`:` value, skipping `basic`/`bearer` values) → `$1$2<redacted>`
7. sensitive `--flag value` / `--flag=value` → `$1$2<redacted>`
8. `(?i)bearer\s+[a-z0-9._~+/=-]+` → `Bearer <redacted>` (fixed capitalisation)
9. PEM `-----BEGIN ([A-Z0-9 ]*PRIVATE KEY)-----.*?(-----END \1-----|\z)` → `<redacted>`

`redactCommand`: detects curl by basename; an argument following a sensitive option is replaced
wholesale; attached `-u…` becomes `-u<redacted>`; otherwise each argument goes through `redact`.
`isSensitiveName`: camelCase→snake, lowercase, match `(^|[^a-z0-9])NAME($|[^a-z0-9])`.

`DisplayTextSanitizer.stripTerminalControls` removes in order: OSC
`\e\][^\a\e]*(?:\a|\e\\)`, CSI `\e\[[0-?]*[ -/]*[@-~]`, generic `\e(?:[@-_]|.)`. Then per code point:
`\n` kept only when preserving newlines; ` `/` ` → space; Unicode FORMAT category dropped
(directional overrides); `\b` deletes the previous code point; other ISO controls → space.
`StreamingLineSanitizer` carries up to 128 chars of a partial PEM marker across lines.

## KnownTools catalog

| spec | name | repository | version | asset template | os naming | checksum policy |
|---|---|---|---|---|---|---|
| DOTBOT_GO | dotbot | worxbend/dotbot-go | v0.4.2 | `dotbot-${os}-${arch}.tar.gz` | GO | SIDECAR_SHA256 |
| DOTBOT_SCALA | dotbot | worxbend/dotbot-scala | v0.1.0 | `dotbot-${os}-${arch}.tar.gz` | GO | SIDECAR_SHA256 |
| NERD_FONTS_INSTALLER | nerd-fonts-installer | worxbend/nerd-fonts-installer | v1.0.7 | `nerd-fonts-installer_${version}_${os}_${arch}.tar.gz` | GO | CHECKSUMS_FILE |
| BINSTALLER | binstaller | worxbend/binstaller | v0.2.0 | `binstaller-${version}-${os}-${arch}.tar.gz` | **MACOS** | SIDECAR_SHA256 |

Pinned digests:
```
dotbot-linux-amd64.tar.gz   a7229b8d098454ffeb2858ddcf1b63602dfc7be06e08b57c39d839c08f9dbd01
dotbot-linux-arm64.tar.gz   21e94e915de43f2cbe086973437ec6a5f81e46ddbc5280707165c0ebb6090b45
dotbot-darwin-amd64.tar.gz  89c22f14929dcb11cc8d1c81086d5d0d9336f89438c6326d00aea7420ea8043c
dotbot-darwin-arm64.tar.gz  f7b970f1b325175b0a16c278050502e45b22541c343f6d4082638197d99dddc4
```
(dotbot-scala) `dotbot-linux-amd64.tar.gz 388f49ab380ddbde153b1fa8ce361237d92e0add0d96df8ef1052093c3b0c673`,
`dotbot-linux-arm64.tar.gz ed87fad6adaee20c63bb9a821f005402c754b713d5e3089909b58ed59e9753e9`
```
nerd-fonts-installer_v1.0.7_linux_amd64.tar.gz   0903de2304b07035794546256cbfbfe117a04c12d1e9ae92c544e8a9ee7bd8b2
nerd-fonts-installer_v1.0.7_linux_arm64.tar.gz   49b30cf173b6a5465dcc7271ae19b5dddf083ba360cc51063121773ad3da6517
nerd-fonts-installer_v1.0.7_darwin_amd64.tar.gz  da47b8301f326b001988caf1fe6a0537fac3f18528b6c3c801a7e14045a70004
nerd-fonts-installer_v1.0.7_darwin_arm64.tar.gz  4c1bbcd01d9d5984d4ad225be9208e7653b4055254c2f55d89b681fd348aeb07
binstaller-v0.2.0-linux-amd64.tar.gz             802bf5da1f6af5f0f00984751f45cb5c0448ee24283729ff21e5ea7f0718f951
binstaller-v0.2.0-linux-arm64.tar.gz             48135498e3973347b6c0f0b843942def56f5dbba22c95d8f75d5272186a74d52
binstaller-v0.2.0-macos-amd64.tar.gz             f54abc96c8bd7270145ecbca2a69767e23a1a4bb616802c767972b2220055dba
binstaller-v0.2.0-macos-arm64.tar.gz             b735fb63bf628302a9b01caa6b589f61785a53d28e219c225699db6771ef6645
```
Release base: `https://github.com/<repo>/releases/download/<version>/<asset>`
Template placeholders: `${name}` `${version}` `${os}` `${arch}`.
`OsNaming.GO` → `linux`/`darwin`; `OsNaming.MACOS` → `linux`/`macos`.
Architecture go names: `amd64`, `arm64`.
`ToolSpec.withVersion` rejects anything but the current version:
`Tool version is not present in the trusted release-digest catalog`.
Cache-segment safety → `<subject> must be a single safe cache-path segment without traversal`
(subjects: `Tool name`, `Tool version`, `Tool binary name`);
`Tool repository must use a safe owner/repository name`;
`Tool asset template must be a single safe release filename`;
`Tool asset SHA-256 must be 64 hexadecimal characters`.

`PublicUrl.from`: truncate at first `?` or `#`, then drop user-info before the **last** `@` in the
authority. Used for state persistence and any displayed URL.

`FluxionVersion.CURRENT = "1.0.3"`, overridable via system property `fluxion.version`.

## Behavioural gotchas

1. Two checksum abstractions coexist: `Checksum(algorithm, value)` (loose, used by
   CompiledBinaryModule) and `Sha256Digest(value)` (strict 64-hex, everywhere else). Not unified.
2. `BootstrapState` mutators refresh `lastRunAt` — except `withRunMetadata`.
3. Empty `allowedExitCodes` silently becomes `[0]`.
4. Blank Flatpak `remote` silently becomes `flathub`.
5. `Phase`'s 5-arg ctor defaults `continueOnModuleError = true`.
6. `PhaseName` does not strip; `ModuleName`/`ProfileName` do.
7. Duplicate-name failures in the config builder are `IllegalStateException`.
8. `ModuleItem.toString()` omits `sourceSetup` and `configuredModule`.
