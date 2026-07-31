# Java `executor` module — porting reference

168 files, ~18.7k LOC. This is the operationally critical spec: exact argv vectors, probe
commands, state format, and the trust machinery.

## 1. Orchestration

### BootstrapOrchestrator.execute(config, executionPhases, listener, cancellation)
Everything runs inside a **global apply lock**. Inside, in order:
1. `stateRecorder.prepare(config)` — writes manifest identity + fingerprint; may raise stale-state
2. emit skipped plan entries: per entry `itemStarted(name, name)` then
   `itemCompleted(name, name, Skipped(name, reason))`
3. `continue_on_failure = policy.continueOnErrorDefault || false`
4. select relevant source setups for the execution phases
5. run source setups
   - cancelled → still run the phase runner (which then raises cancelled)
   - failed → raise `Bootstrap failed while configuring sources`
   - completed → run the phase runner
The phase runner receives **manifest phases** (for topological order) *and* the selected
**execution phases**.

`dryRun`: no lock, no state writes — emit skipped entries, preview source setups, preview phases.

**Relevant source setups**: collect the package-manager kinds required by the phases
(`PackageModule.packageManager`, `SystemUpdateModule.packageManager`, `ZypperModule`→ZYPPER,
`FlatpakModule`→FLATPAK), map PARU/YAY→PACMAN, and keep setups whose manager is in that set.

### Source setup runner
```
for setup in setups:
  cancelled? -> CANCELLED
  failed = execute(setup)
  if failed: any_failed = true; return FAILED unless continue_on_failure
cancelled? -> CANCELLED
any_failed ? FAILED : COMPLETED
```
Per setup: emit `moduleStarted`, run the item non-streaming, ensure `moduleCompleted`.

### Phase execution runner
`PHASE_FAILURE_REASON = "Phase stopped after a module failure"`
```
for manifest_phase in topological_order(manifest_phases):
    phase = selected[manifest_phase.name] or next
    stop? -> break
raise cancelled if cancelled
raise "Bootstrap failed in phase(s): <sorted names joined ', '>" if any failed
```
Per phase:
1. cancelled → record resume point = first module name (or empty), emit `cancelled(phase, entry)`, STOP
2. blocked (any dependency is unavailable) → record phase BLOCKED with reason
   `Blocked by failed phase: <firstFailedDependency>` (or `unknown`), emit `phaseBlocked`, mark
   unavailable, CONTINUE
3. otherwise: if the fingerprint matches a completed phase in state → emit `phaseStarted` +
   `phaseCompleted` and return; else `phaseStarted`, run modules, finish

Module loop:
```
start_index = resume_start_index(modules)   # consumes the nextPlanEntry marker
shell_runner = requires_new_shell ? LoginShellWrapping(runner, shell) : runner
for index from start_index:
    cancelled? -> record resume = THIS module, CANCELLED
    result = execute_module(...)
    result.stopped_at_boundary? -> record resume = THIS module, CANCELLED
    cancelled? -> record resume = NEXT module (or this), CANCELLED
    result.failed && !continue_on_module_error -> HARD_FAILURE
    failed |= result.failed
failed ? HARD_FAILURE : COMPLETED
```
Finish: CANCELLED→STOP; HARD_FAILURE→record FAILED with the reason, emit `phaseFailed`,
CONTINUE; COMPLETED→record COMPLETED, emit `phaseCompleted`, and for prompt-logout also emit
`restartRequired(phase, message)` and STOP.

**Interrupt module** (handled by the phase runner, never the dispatcher):
```
next_entry = resumeFrom == CURRENT ? module.name : following_module_name
message    = base + (next_entry ? " Next plan entry: <e>" : " No next plan entry.")
                  + (instructions.empty? ? "" : " " + instructions.join(" "))
emit itemStarted; emit itemCompleted(Paused(itemKey, message, next_entry, exit_code))
record interrupt (status INTERRUPTED when resumeFrom == CURRENT, else COMPLETED)
raise ExecutionPaused(itemKey, message, next_entry, exit_code)
```

### Topological planning
Unknown dependency → `Phase '<a>' declares dependency on unknown phase '<b>'`.
Cycle → `Circular dependency detected among phases: <set>`.
**Seed the ready queue in declaration order** (the Java version seeds from a hash map and is
non-deterministic — fix this in the port).

### Item execution
```
emit itemStarted(module, key)
decision = skip_evaluator.evaluate(item)
Skip -> emit itemCompleted(Skipped(key, reason)); return false     # skipped is NOT a failure
result = action.call                                               # optionally with an output sink
emit itemCompleted(result)
record_success(...)                                                # only persists Success
return result.is_a?(Failure)
```
Preview: `itemStarted`; skipped → `Skipped`; else `itemCompleted(DryRun(key, command))`.

### Continue-on-error return values — **deliberately inconsistent, replicate exactly**
| Loop | Return |
|---|---|
| file-writes | `any_failed && !continue_on_error` |
| flatpak | `any_failed && !continue_on_error` |
| gpg-key | **`any_failed`** (ignores continue_on_error) |
| shell-script | short-circuits `return true` on the first failure without continue_on_error |
| shell-command | same short-circuit |
| all list-module kinds | `any_failed && !continue_on_error` |

`user-groups` additionally, after the loop and when not cancelled and not hard-failed, emits
`restartRequired(PhaseName(module.name), checkpointMessage || defaultCheckpointMessage)` when
any group is pending logout.

### Cancellation
Two ambient values: a signal and a boundary. `isCancelled()` reads the signal and, when a
boundary is bound, marks it stopped as a side effect. Model as a fiber-local stack in Crystal.

## 2. Executor argv vectors

### Package managers (install timeout 10 min)
| Kind | install |
|---|---|
| APT | `["sudo","apt-get","install","-y",pkg]` |
| DNF | `["sudo","dnf","install","-y",pkg]` |
| PACMAN | `["sudo","pacman","-S","--noconfirm",pkg]` |
| PARU | `["paru","-S","--noconfirm",pkg]` (no sudo) |
| YAY | `["yay","-S","--noconfirm",pkg]` (no sudo) |
| ZYPPER | `["sudo","zypper","install","-y",pkg]` — **no `--non-interactive` here** |
| CARGO | `["cargo","install",pkg]` |

Actions:
```
apt  update        ["sudo","apt-get","update", *args]
apt  upgrade       ["sudo","apt-get","upgrade","-y", *args]
apt  dist-upgrade  ["sudo","apt-get","dist-upgrade","-y", *args]
dnf  check-update  ["sudo","dnf","check-update", *args]        success codes {0,100}
dnf  upgrade       ["sudo","dnf","upgrade","-y", *args]
dnf  swap          ["sudo","dnf","swap","-y", *args]
dnf  groupupdate   ["sudo","dnf","groupupdate","-y", *args]     (also group-update)
pacman sync-upgrade|syu|upgrade   ["sudo","pacman","-Syu","--noconfirm", *args]
zypper refresh     ["sudo","zypper","--non-interactive","refresh", *args]
zypper update      ["sudo","zypper","--non-interactive","update","-y", *args]
zypper dup         ["sudo","zypper","--non-interactive","dup","-y", *args]
zypper dup-from    ["sudo","zypper","--non-interactive","dup","-y","--from", *args]
```
Unsupported → `Unsupported <mgr> action: <action>`. PARU/YAY/CARGO have no actions →
`Package manager action is not supported`.
Result: exit in success codes → Success; else `Failure(item, stdout + stderr, exit, elapsed)`.

### SDKMAN (10 min)
```
["/bin/bash","-lc",
 "source \"$HOME/.sdkman/bin/sdkman-init.sh\" && sdk install <candidate>[ <version>]"]
```

### Flatpak apps (15 min)
`["flatpak","install","-y", remote, appId]`

### Source setups
Preview for every kind:
```
["sysboot-source-setup", <manager lowercase>, <setup name>,
 checksum ? "verify-sha256=<digest>" : "no-remote-artifact"]
```
Missing checksum where one is required →
`Failure(item, "Remote source artifact requires a SHA-256 checksum", 1, 0)`.
Download/verify failure →
`Failure(item, "Remote source artifact download or SHA-256 verification failed", 1, 0)`.

**APT** (5 min): write `<sourceEntry>\n` to a temp file; publish the verified key (when one is
configured) to the keyring; publish the source file to `sourceListPath` mode `0644`; then
`["sudo","apt-get","update"]`.
IO failure → `Cannot prepare trusted APT source configuration`.

**RPM/DNF** (5 min): installed key path
`/etc/pki/rpm-gpg/sysboot-<repoId with [^A-Za-z0-9._-] → _>.key`
```
[<id>]
name=<id>
baseurl=<baseUrl>
enabled=<1|0>
gpgcheck=<1|0>
gpgkey=<installedKey file URI>      # only when a key is configured
```
Then `["sudo","dnf","makecache","--refresh"]`.
IO failure → `Cannot prepare trusted RPM source configuration`.

**Zypper** (5 min): installed key `/etc/zypp/keys/sysboot-<safeName>.key`
```
[<id>]
name=<id>
baseurl=<baseUrl>
enabled=<1|0>
autorefresh=<1|0>
gpgcheck=<1|0>
gpgkey=<installedKey file URI>
```
Then `["sudo","zypper","refresh"]`.
IO failure → `Cannot prepare trusted Zypper source configuration`.

**Pacman** (5 min): read the config with a bounded, root-ownership-checked reader (max 4 MiB;
every ancestor must be a root-owned non-symlink directory without group/other write).
Probe `["grep","-Fqx","--","[<repo>]",<configPath>]` — exit not in {0,1} → failure; exit 1 →
append the block and publish the whole file at mode `0644`; exit 0 → skip the write.
```
\n[<repo>]\n
[# ]Server = <server>\n
[# ]SigLevel = <sigLevel>\n     # only when present
[# ]Include = <include>\n       # only when present
```
(`# ` prefix when disabled.) Separator before the block is `""` when the current content is
empty or already ends in a newline, else `"\n"`. Then `["sudo","pacman","-Sy"]`.
IO failure → `Refusing unsafe Pacman repository configuration`.

**Flatpak remote** (5 min): stage the verified descriptor at `/run/sysboot/source-artifact`
mode `0644`, then
```
["flatpak"] + (system ? [] : ["--user"]) + ["remote-add","--if-not-exists", remote, <staged path>]
```
The remote URL is never passed to flatpak.
IO failure → `Cannot stage verified Flatpak remote descriptor`.

### Shell scripts
`CHECK_TIMEOUT = 30s`, `MAX_SCRIPT_BYTES = 64 MiB`, `MAX_SHEBANG_BYTES = 4 KiB`,
privileged anchor `/run/fluxion-script`.
1. confirm gate → `Failure(name, "Explicit confirmation required; rerun apply with --yes", 2, 0)`
2. `creates` exists or `unless` succeeds → `Skipped(name, "idempotency guard matched")`
   (`unless` runs `["/bin/bash","-lc",<unless>]` with the item env and working dir, 30 s)
3. remote script → download + verify; failure →
   `Failure(name, "Remote script download or SHA-256 verification failed", 1, 0)`
4. sudo + remote → stage at `/run/fluxion-script` mode `0555` and run the staged copy; if the
   consumer never ran →
   `Failure(name, "Script preparation failed: trusted root stage was rejected", 1, 0)`
5. argv: `["sudo"]? + [interpreter, scriptPath] + args`
6. interpreter from the shebang (first line, ≤4 KiB, strip `#!`, first token); no shebang →
   `/bin/bash`; not a bounded regular file → `Script is not a bounded regular file`; empty
   shebang → `Script shebang does not name an interpreter`
7. allowed exit → Success; else `Failure(name, redact(stdout+stderr, env), exit, elapsed)`
8. preparation failure → `Failure(name, "Script preparation failed: unsafe or unreadable script", 1, 0)`
Preview never opens the file: `["sudo"]? + ["<interpreter>", item.key, *args]`, redacted.

### Shell commands
1. confirm gate (same message, exit 2)
2. `creates` exists → `Skipped(name, "creates path already exists")`
3. `unless` matches → `Skipped(name, "unless guard matched")`; argv `[shell,"-lc",<unless>]`, 30 s
4. run `item.command()` = argv, else `[shell,"-lc",shellCommand]`, prefixed with `sudo` when set
5. allowed exit → Success; else
   ```
   description = "<name> exited <exit>: " + redactCommand(preview).join(" ")
   detail      = output.blank? ? description : description + ": " + output
   ```

### File writes
Non-sudo: validate the destination (no symlink ancestors, regular file if it exists), create
parents, re-validate, stage a temp file beside the destination, populate from content or a
source copy, preserve the existing mode, apply the configured mode, `chown` when owner/group
are set, re-validate, atomic move.
Sudo: stage in the system temp at `0600`, validate the destination as **privileged** (every
non-final ancestor must be root-owned with no group/other write), then publish through the
privileged publisher using the approved digest (SHA-256 of the content string, or of the source
file capped at 32 MiB), `sudo chown` the root stage when needed, re-validate, and
`sudo mv -f -T -- <stage> <destination>`.
Failure → `Privileged file publication failed`.
Dry-run vector:
```
["file-write", <destination>, ("content"|"source"), [<source>],
 "mode", <mode or "<unchanged>">, "owner", <owner or "<unchanged>">,
 "group", <group or "<unchanged>">, "sudo", <"true"|"false">]
```
Messages: `File write destination must not traverse symbolic links: <p>`,
`File write destination ancestor must be a directory: <p>`,
`Privileged file destination ancestor must be root-owned and non-writable: <p>`,
`File write destination must be a regular file: <p>`.

### GPG keys (2 min, 16 MiB)
Inspect: `[<realpath gpg>,"--batch","--no-options","--show-keys","--with-colons",<file>]`.
Parse colon records: on a `pub` record expect the **immediately following** record to be `fpr`;
collect field 9 normalized (spaces removed, uppercased), else an empty string. The resulting
list must be **exactly** `[expected]`, else
`fingerprint mismatch for <displayName>: expected <fp> but found <list>`.
Flow: existing keyring → stage a bounded copy and verify; missing → download (HTTPS or absolute
`file:`), stage under the keyring path (or `/run/sysboot/gpg-import.key`), verify, then either
dearmor + publish the keyring at `0644`, or `["sudo","rpm","--import",<staged>]`.
Preview (pseudo-argv, three elements):
```
["download <publicUrl>",
 "verify OpenPGP fingerprint <fp>",
 keyring ? "install verified keyring <path>" : "sudo rpm --import <verified-key>"]
```
Failure text is passed through a URL-parameter stripper and the secret redactor.

### git-config (30 s)
Read `[..."git","config",<scopeFlag>,"--get",key]`; set
`[..."git","config",<scopeFlag>,key,value]`; prefixed with `sudo` for system scope.
Current == desired → Success with zero elapsed and **no command run**.

### git-repo (10 min)
```
init      ["git","init","--quiet","--",<dest>]
remote    ["git","-C",<dest>,"remote","add","origin",<url>]
fetch     ["git","-c","protocol.file.allow=never","-C",<dest>,"fetch"]
          + (["--depth",<n>] when depth set) + ["origin",<commit>]
checkout  ["git","-C",<dest>,"checkout","--detach","FETCH_HEAD"]
submodule ["git","-c","protocol.allow=never","-c","protocol.https.allow=always",
           "-C",<dest>,"submodule","update","--init","--recursive"]
verify    ["git","-C",<dest>,"remote","get-url","origin"]
          ["git","-C",<dest>,"rev-parse","--verify","HEAD"]
          ["git","-c","core.fsmonitor=false","-C",<dest>,"status","--porcelain=v1",
           "--untracked-files=all","--ignore-submodules=none"]
```
Verification env: `{"GIT_OPTIONAL_LOCKS" => "0"}`.
New repos are staged at `<parent>/.<name>.sysboot-stage-<uuid>` and moved into place only after
every verification passes; existing destinations are inspection-only.
Messages:
```
git-repo destination must resolve to an absolute path
git-repo destination must not be a filesystem root
git-repo destination exists but is not a regular Git worktree
git-repo could not prepare a staged destination
git-repo <operation> failed: <detail>
   operations: repository initialization, origin configuration, exact commit fetch,
               detached checkout, submodule checkout
git-repo could not verify the destination origin
git-repo destination origin does not match the configured HTTPS URL
git-repo could not verify the destination HEAD
git-repo destination HEAD does not match the configured commit      (compared case-insensitively)
git-repo could not verify the destination worktree
git-repo destination has tracked or untracked modifications
git-repo could not install the verified staged checkout
destination appeared during staging
```
Preview uses the literal placeholder `<staged-destination>` and omits the submodule step.

### systemd-unit (2 min)
```
[..."systemctl", <scopeFlag>, <verb>, <unit>]     # "sudo" prefix for system scope, except is-* verbs
["systemctl","--version"]                          # availability probe, never privileged
```
Unavailable → `Skipped(<key>, "systemctl is not available")`.
Order: masked → `mask` only. Else if enabled and not already enabled, read `is-enabled`; when
the word is one of `static indirect generated transient alias` treat as a no-op success;
otherwise `enable`. Then runtime state from `is-active`: `active`→ACTIVE,
`inactive`/`failed`→INACTIVE, anything else→UNKNOWN →
`could not determine runtime state for <qualifiedName>`. STARTED→`start` when not active;
STOPPED→`stop` when active; UNCHANGED→nothing.
Already-enabled words: `enabled`, `enabled-runtime`.
Step failure → `<verb> <qualifiedName>: <detail>`.

### system-setting (60 s)
| key | apply | probe | comparison |
|---|---|---|---|
| localRtc | `["sudo","timedatectl","set-local-rtc", "1"\|"0"]` | `["timedatectl","show","--property=LocalRTC","--value"]` | value in {yes,true} |
| ntp | `["sudo","timedatectl","set-ntp","true"\|"false"]` | `["timedatectl","show","--property=NTP","--value"]` | same |
| timezone | `["sudo","timedatectl","set-timezone",tz]` | `["timedatectl","show","--property=Timezone","--value"]` | string equality |
| hostname | `["sudo","hostnamectl","set-hostname",h]` | `["hostnamectl","show","--property=StaticHostname","--value"]` | string equality |
| locale:K | `["sudo","localectl","set-locale","K=v"]` | `["localectl","status"]` | any whitespace token equals `K=v` |
Satisfied → Success with zero elapsed and no command.
Bad key → `unknown system-setting item key: <k>`

### system-update (default 2 h)
| PM | refreshOnly | full |
|---|---|---|
| ZYPPER | `[["sudo","zypper","--non-interactive","refresh"]]` | refresh, then `["sudo","zypper","--non-interactive", dup\|update]` |
| DNF | `[["sudo","dnf","check-update","--refresh"]]` | `[["sudo","dnf","upgrade","-y","--refresh"]]` |
| PACMAN/PARU/YAY | `[["sudo","pacman","-Sy","--noconfirm"]]` | `[["sudo","pacman","-Syu","--noconfirm"]]` |
| APT | `[["sudo","apt-get","update"]]` | update, then `["sudo","apt-get", full-upgrade\|upgrade, "-y"]` |
| CARGO/FLATPAK | raise `system-update does not apply to <pm>; use tool-packages or a flatpak step instead` | |
Success when the command succeeds, **or** refreshOnly + DNF + exit 100.
Failure → `Failure(itemKey, "<command joined> : <detail>", exit, elapsed)`.
Cancelled mid-list →
`Paused(itemKey, "System update cancelled before every command completed", nil, 130)`.

### user-groups (30 s)
```
["getent","group",<g>]                    exists?
["sudo","groupadd","-f",<g>]              create
["sudo","usermod","-aG",<g>,<user>]       add
["id","-nG",<user>]                       DB groups
["id","-nG"]                              session groups
```
Already a member → Success with zero elapsed.
Missing group without createMissing →
`group '<g>' does not exist; install the package that provides it or set createMissing: true`
Add failure → `failed to add <user> to <group>: <detail>`
Pending logout = groups in the DB list but not the session list (only when logoutCheckpoint is
on and the target user is the invoking user).
Target user: configured value, else `$SUDO_USER` when euid is 0 and it matches
`[a-z_][a-z0-9_-]{0,31}` and the account exists, else the current user. Non-matching →
`target username is not a safe Linux account name`.
Module preview: `groupadd -f` per group (when createMissing) then one
`["sudo","usermod","-aG", groups.join(","), user]`.

### tool-packages (30 min)
Availability probe (15 s):
`["/bin/sh","-c","command -v -- \"$1\" >/dev/null 2>&1","sysboot-path-lookup",<binary>]`
Unavailable →
`<binary> is not on PATH; install it before this step (see docs/config-schema.md)`
| Backend | with version | without |
|---|---|---|
| cargo-binstall | `["cargo-binstall","--no-confirm","<n>@<v>"]` | `["cargo-binstall","--no-confirm","<n>"]` |
| cargo | `["cargo","install","--locked","--version","<v>","<n>"]` | `["cargo","install","--locked","<n>"]` |
| snap | `["sudo","snap","install","<n>","--channel","<v>"]` | `["sudo","snap","install","<n>"]` |
| pipx | `["pipx","install","<n>==<v>"]` | `["pipx","install","<n>"]` |
| uv-tool | `["uv","tool","install","<n>==<v>"]` | `["uv","tool","install","<n>"]` |
| npm-global | `["npm","install","-g","<n>@<v>"]` | `["npm","install","-g","<n>"]` |
| go-install | `["go","install","<n>@<v>"]` | `["go","install","<n>@latest"]` |

### dotbot (5 min)
apply `[<resolved dotbot>,"--config",<config>]`
preview `[<binary>,"-c",<config>,"--dry-run"]`
plan `[<resolved dotbot>,"plan","-c",<config>,"--output","json"]`
failure `dotbot exited with code <n>: <stderr or stdout, stripped>`
prep failure `Failed to prepare dotbot: <msg>`

### default-shell (30 s), item key `default-shell`
`["sudo","chsh","-s",<shellPath>,<targetUser>]`
`Shell path must be absolute: <p>` / `Shell binary not found or executable: <p>`

### oh-my-zsh (5 min), item key `oh-my-zsh`
URL `https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/<revision>/tools/install.sh`
argv `["sh",<downloaded>]`, env exactly:
`RUNZSH=no`, `CHSH=no`, `ZSH=<installDir>`, `HOME=<user home>`
Download failure → `Failed to download OMZ installer: <msg>`

### toolchain (15 min)
argv `["sh",<script>] + installArgs`
env: RUSTUP → `RUSTUP_INIT_SKIP_PATH_CHECK=yes`, `CARGO_HOME=$HOME/.cargo`,
`RUSTUP_HOME=$HOME/.rustup`; SDKMAN → `SDKMAN_DIR=$HOME/.sdkman`; else `{}`
Download failure → `Failed to prepare install script: <msg>`

### nerd-fonts (15 min), item key `nerd-fonts`
argv `[<resolved installer>,"--config",<config path>]`
Generated config YAML:
```yaml
release: <release>
destination: <destination>
refresh_font_cache: <bool>
families: [<families>]
```
preview `[<binary>,"--config", <configPath or "<generated from profile">, "--dry-run"]`
`Nerd Fonts config not readable: <p>` / `Failed to prepare Nerd Font installer: <msg>` /
`nerd-fonts-installer exited with code <n>`

### shell-reload (30 s), item key `shell-reload`
execute `[<shell>,"--login","-i","-c","echo 'Shell environment OK'; exit 0"]`
**preview differs**: `[<shell>,"--login","-i","-c","exit"]`
failure `Shell init failed. Check your .<shell>rc for errors.\n<stderr>`

### binstaller (apply 30 min, read-only 5 min)
```
plan     [bin,"plan"]  + ["--config",cfg] + only/skip flags
apply    [bin,"apply"] + ["--config",cfg] + only/skip flags
         + (["--locked"] + (["--lock-file",lf] if set)) when locked
versions [bin,"versions"] + config + selection
```
Selection flags: `--only <t>` per entry, then `--skip <t>` per entry.
**Preview is always the plan command, never apply.**
`binstaller exited with code <n>[: <stderr or stdout>]` / `Failed to prepare binstaller: <msg>`

### compiled-binary
Trust policy first:
```
Refusing untrusted binary download: checksum must use SHA-256 with a 64-character hexadecimal digest
Refusing untrusted binary download: configure a literal SHA-256 checksum or a signature with an allowed signer fingerprint; checksumUrl is supplemental metadata only
Refusing detached signature without a matching allowed signer fingerprint
```
Then: try delegation → if the format requires delegation and it was refused,
`Cannot install <path> without binstaller; Fluxion cannot extract this archive format locally[; <refusal reason>]`
→ else install locally.

Local order: download with digest → download the detached signature → if the destination needs
root, stage privileged and verify there; else verify signature, verify checksum, extract, and
install. Always delete temp files.

Delegated argv:
`[<resolved binstaller>,"apply","--config",<temp profile yaml>,"--only",<module name>]`
Preview: `["binstaller","apply","--only",<name>,"#",<publicUrl>,"->",<installPath>]`

Local dry-run vector:
```
["download",<publicUrl>,"->",<installPath>]
+ (tar.gz ? ["extract",<archivePath>,"strip-components",<n>] : ["direct-binary"])
+ (["mode",<mode>] when set)
+ (["symlink",<symlinkPath>,"->",<installPath>] when set)
```
Delegation-refused vector: `["refuse",<publicUrl>,"requires","binstaller"]`

Checksum mismatch → `Checksum mismatch: expected <a> but got <b>`;
unknown algorithm → `Unknown checksum algorithm: <alg>`;
read error → `Failed to read file for checksum verification`.

Install transaction privileged primitives (1 min each; non-zero exit →
`Command failed: <joined>`):
```
hardlink ["sudo",<realpath ln>,"--",<existing>,<link>]
symlink  ["sudo","ln","-s","--",<target>,<staged>]
move     ["sudo",<realpath mv>,"-fT","--",<source>,<destination>]
delete   ["sudo","rm","-f","--",<path>]
```
Destination privilege: parent writable → user path; else parent must be root-owned and secure,
otherwise `Refusing unsafe or untrusted destination parent: <p>`.
`Refusing to replace non-file binary destination: <p>`,
`Install path and symlink path resolve to overlapping destinations`,
`Privileged binary installation requires a checksum-bound artifact`,
`Privileged binary publication failed: <detail>`.

Artifact formats:
```
NATIVE      .tar.gz .tgz          (extracted in process)
DELEGATED   .zip .tar.xz          (binstaller only)
UNSUPPORTED .tar.bz2 .tar .gz .xz .bz2 .7z .rar
supportedFormats() = ".tar.gz, .tgz, .zip, .tar.xz, or a plain binary URL"
```

Binstaller profile translation refusals, in order:
```
binstaller cannot verify a detached GPG signature
binstaller supports only SHA-256 checksums
tool and binary names must be safe path segments
an archive step needs archivePath so the member can be mapped
stripComponents has no binstaller equivalent
binstaller delegation cannot perform privileged symlinks through Fluxion's authenticated runner
```
Canonical delegated target: `$HOME/.apps/<tool>/bin/<binaryName>`.
Delegated output verification requires that canonical file to exist, to be regular, to have
**changed** during the invocation, to match the configured direct-download digest (for
non-archive downloads), and every declared non-canonical output to be a symlink resolving
exactly to it:
```
canonical apps binary was not produced
canonical apps binary did not change
canonical apps binary SHA-256 does not match the configured direct-download digest
<path> is not a symlink to the canonical apps binary
binstaller output verification failed: <msg>
```
Before delegating, snapshot prior regular files, symlinks, and absent paths; restore on failure
(`; rollback was incomplete: <msg>` appended when restore itself fails).

## 3. Probes

First registered probe whose `supports(item)` matches wins. None →
`No probe registered for <itemType>[ using <packageManager>]`.
A shell execution error becomes `Unknown(key, "Probe command could not be executed")`.

| Probe | Item type | argv | Timeout | Verdict |
|---|---|---|---|---|
| apt package | PACKAGE, pm APT (default **false** when absent) | `["dpkg-query","-W","-f=${Status}\t${Version}",pkg]` | 10 s | split stdout on tab; `install ok installed` → installed with version |
| dnf package | PACKAGE, pm DNF (default **true** when absent) | `["rpm","-q",pkg]` | 10 s | 0 → installed, version = text after the first `-`; 1 → not; else `rpm -q exited %d: %s` |
| pacman package | PACKAGE, pm PACMAN/PARU/YAY (default false) | `["pacman","-Q",pkg]` | 10 s | 0 → installed, version after the first space; 1 → not; else `pacman -Q exited %d: %s` |
| zypper package | PACKAGE, pm ZYPPER (default false) | `["rpm","-q",pkg]` | 10 s | as dnf |
| apt repository | APT_REPOSITORY | key-only `["test","-s",<sourceList>]`; configured `["cat","--",<sourceList>]` | 15 s | **configured trust match is hardcoded false → always NotInstalled** |
| rpm repository | RPM_REPOSITORY | `["test","-s",<repoFile>]` / `["cat","--",<repoFile>]` | 15 s | ini section must match name/baseurl/enabled/gpgcheck and have exactly 4 (or 5 with gpgkey) values |
| zypper repository | ZYPPER_REPOSITORY | same | 15 s | plus autorefresh; 5 (or 6) values |
| pacman repository | PACMAN_REPOSITORY | `["grep","-Fqx","--","[<repo>]","/etc/pacman.conf"]` / `["cat","--",<config>]` | 15 s | section lines must equal exactly the generated ones |
| flatpak | FLATPAK | `["flatpak","list","--app","--columns=application"]` | 15 s | any line equals the app id |
| flatpak remote | FLATPAK_REMOTE | `["flatpak","remotes","--columns=name"]` / `["flatpak",<--system\|--user>,"remotes","--columns=name,url"]` | 15 s | configured needs exactly 2 fields matching (remote, url) |
| compiled binary | COMPILED_BINARY | version command or `[<path>,"--version"]` | 3 s | see below |
| shell script | SHELL_SCRIPT | `["/bin/sh","-c",<probeCommand>]` | 30 s | no probe → `No probeCommand configured for this script. Add a 'probeCommand' field to the shell-script module in your config.` |
| dotbot | DOTBOT | `["/bin/sh","-c",<probeCommand>]` | 10 s | no probe → `No probeCommand configured for dotbot module` |
| default shell | DEFAULT_SHELL | `["getent","passwd",<user>]` | 5 s | field 7 equals the shell path |
| nerd font | NERD_FONT | `["fc-list",":","family"]` | 15 s | split each line on `,`, lowercase, contains the family |

Compiled-binary probe: item key must equal the install path
(`Compiled binary item does not match its configured install path`); missing → not installed;
not a regular executable → `Installed path is not a regular executable file`; an `archivePath`
means the checksum covers the archive → `Configured checksum covers an archive, not the installed binary`;
no valid SHA-256 → `No configured final-byte SHA-256 is available`; digest mismatch → not
installed; digest error → `Unable to verify installed binary: <msg>`.
Version regex `(\d+\.\d+[\w.\-]*)` against the first stdout line; when an expected version is
configured and the detected one is absent or does not start with it → not installed.

Parallel probe runner: 16 concurrent, 60 s deadline, results keyed by `<module>/<key>`;
missing → `Probe deadline exceeded` / `Probe failed without a result` / `Probe interrupted`.

### Skip evaluation
```
run_state_mode not probing            -> Run
mode == SKIP_RECORDED
  && item has no source setup
  && item's module is not a compiled binary
  && state has an entry                -> Skip(InstalledFromState)
status = probe(item)
status installed?                      -> Skip(status)
else                                   -> Run
```
Source setups and compiled binaries **always** re-probe and never trust state.
```
fromOptions(skip, reprobe) = reprobe ? LIVE_REPROBE : (skip ? SKIP_RECORDED : RECORD_ONLY)
skipsRecordedWork       = SKIP_RECORDED
probesInstalledItems    = != RECORD_ONLY
startsFreshState        = != SKIP_RECORDED
validatesStoredManifest = != LIVE_REPROBE
```

## 4. State

### Paths
```
base        $HOME/.local/share/fluxion
legacy base $HOME/.local/share/sysboot
state file  <base>/<profile>.state.json
profile lock <base>/.<profile>.state.json.lock
global lock  <base>/.apply.lock
temp write   <base>/.<profile>.state.json-<random>.tmp
tool cache   $HOME/.cache/fluxion/tools/<tool>/<version>/<executable>
tool lock    .../.<executable>.install.lock
tool proof   .../.<executable>.sha256
```
Profile names must match `[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?`, must not contain `..`,
and must resolve under the root → `Profile state path escapes the configured state root`.
Directories `0700`, files `0600`.

### JSON schema, version 7 (earliest compatible 2)
```jsonc
{
  "schemaVersion": 7,
  "profileName": "...",
  "lastRunAt": "<ISO instant>",
  "sysbootVersion": "...",
  "entries": [{"profileName","moduleName","itemKey","itemType","completedAt","version","checksum","sourceUrl"}],
  "phaseEntries": [{"phaseName","status","completedAt","fingerprint","reason"}],
  "planEntryEntries": [{"entryName","status","updatedAt","message"}],
  "nextPlanEntry": null,
  "manifestIdentity": null,
  "manifestFingerprint": null
}
```
Load validation:
```
State document must be a JSON object
Unsupported state schemaVersion: <n>
State profile does not match requested profile: <p>
State entry profile does not match requested profile: <p>
Current state schema requires lastRunAt and sysbootVersion      (v7 only)
```
Fallbacks: blank version → `legacy-state-v<n>`; missing `lastRunAt` → the max of all recorded
timestamps, else epoch. Any load failure → `Failed to read state file: <path>`.

### Atomic write
1. verify the state's profile identity matches
2. prepare the directory (no symlink components anywhere on the path, `0700`)
3. prepare the existing file (`State file must not be a symbolic link: <p>`,
   `State file escapes the configured state root: <p>`)
4. temp file beside it at `0600`
5. serialize, chmod, re-verify the root, atomic move, always delete the temp

Read security: regular non-symlink file; owner must equal the parent directory owner
(`State file owner differs from state directory owner: <p>`); group/other write →
`State file was writable by another account: <p>`; permissions must end up exactly `0600`
(`State file permissions are not private: <p>`); the file identity must be unchanged between
stat and open (`State file changed while being opened: <p>`).
Directory: `State root must be a directory: <d>`, `State path was writable by another account: <p>`,
`State path permissions are not private: <p>`, `State root must not contain symbolic links: <root>`.
Reads fall back to the legacy path when the new one is absent. Read-only mode swallows read
errors and must never repair permissions or mutate layout.

### Locking
In-process reentrant lock keyed by path (a nested acquire skips file locking entirely), plus an
exclusive blocking `flock` on the lock file. `State lock was not acquired: <p>` /
`State lock must be a regular file: <p>` / `Failed to lock state for <label>`.
`reset`/`forget` take the **global** apply lock first, then the profile lock.

### Run state recorder
`prepare`: when the mode validates the stored manifest and state has recorded work, both the
identity and the fingerprint must match, else
```
Saved state is stale: <manifest identity|manifest fingerprint> differs. Reset state with `fluxion state reset <profile> --force` or re-run apply with --reset-state.
```
When the mode starts fresh state, replace it entirely; otherwise merge the manifest metadata.
`resumeStartIndex`: only under SKIP_RECORDED; matches `nextPlanEntry` against module names and
**clears the marker** (a separate write) on a hit.
`recordSuccess` persists **only** on Success. Every update also refreshes the run metadata and
then refreshes the skip evaluator's cached state.

### Phase fingerprint
Encoding primitive — every record is
```
<key.size>":"<key><value.size>":"<value>
```
concatenated with no separator; nil optionals become `""`; booleans become `"true"`/`"false"`.
Digest = lowercase-hex SHA-256 of the UTF-8 bytes.
**Sizes are Java `String.length()` (UTF-16 code units)** — reproduce exactly or every stored
fingerprint invalidates.

Phase order: `phase`, `description`, `continueOnModuleError`, each `dependsOn`, the restart
policy (`restart` = `none`/`prompt-logout`+`message`/`requires-new-shell`+`shell`), then each
module.
Module order: always `module` = name, then `type` and the per-kind keys (see the Java table —
key names mirror the config field names; URLs are recorded in public form; local file inputs
contribute a `…ContentSha256` digest keyed off the file, or `<missing>`; sensitive environment
values are hashed as
`sha256("fluxion:sensitive-environment:v1\0" + name + "\0" + value)`; environment variables and
locale entries are sorted by name).
Manifest fingerprint: `profile`, `target`, `dryRun`, `continueOnError`, `requireSudo`, each
source setup, then one `phaseFingerprint` per phase.

## 5. Shell execution

### Runner variants
- **Default (CLI)**: transform via the sudo rule, run through the process launcher, use the
  ambient output sink; debug-log the redacted command with each argument truncated to 57 chars
  plus `...` beyond 60.
- **PTY (TUI)**: identical, except it first ensures the sudo session is authenticated
  (`Privileged effect refused because sudo authentication is unavailable`). Despite the name it
  allocates **no PTY**.
- **Login-shell wrapping** (only for `requires-new-shell` phases): sudo invocations pass
  through unchanged; everything else becomes
  `[<shell>, <"-l" for sh else "--login">, "-i", "-c", <POSIX-quoted command string>]`
  where quoting wraps each argument in single quotes with `'` → `'\''`.

### Sudo
```
isInvocation(cmd)  cmd[0] == "sudo" or "/usr/bin/sudo" or "/bin/sudo"
forEffect(cmd)     -> [<real sudo>, "-n", "--", <real target>, *rest]
validateNoPrompt   [<real sudo>, "-n", "-v"]
validateWithPass   [<real sudo>, "-S", "-p", "", "-v"]
invalidate         [<real sudo>, "-k"]
```
Target index: `["sudo","-n","--",X,...]` → 3; `["sudo",X,...]` where X is not a flag → 1; else
`Privileged command has no executable target`.
Every privileged effect is therefore **non-interactive** with a resolved target; no password is
ever piped to an effect process.

**Trusted executable resolution**: absolute paths are real-pathed; bare names are tried in
`/usr/bin`, `/usr/sbin`, `/bin`, `/sbin`. The result must be a regular non-symlink executable
under one of those directories, root-owned, without group/other write, with every ancestor
likewise. Failure →
`<name> is not available from a trusted root-owned system directory`.

**Sudo session**: 30 s validate timeout, 60 s keepalive, 3 attempts.
Availability: `sudo -n -v` fails and the output contains `may not run sudo` → declined
(`This user may not run sudo on this host; privileged steps will fail.`); succeeds → prompt-free;
otherwise password required. After a password is accepted, `sudo -n -v` must also succeed
(`sudo accepted the password but cannot reuse authentication non-interactively`); a validation
timeout (exit 124) → `Could not verify the sudo password; refusing privileged effects`.
Passwords are always zero-filled. Close interrupts the keepalive and runs `sudo -k`.

**Preflight**: interactive → prompt once, then require authentication
(`This profile requires sudo, but interactive authentication was not completed`);
non-interactive → `sudo -n -v`
(`This profile requires sudo, but non-interactive sudo validation failed; authenticate sudo first or use the TUI`).
The gate always runs the **root execution guard** first: read `/proc/self/status`, take the
effective UID from the `Uid:` line;
unreadable → `Cannot determine effective UID; refusing live apply`;
euid 0 → `Refusing live apply as root: Fluxion has no safe user-drop execution path`.
**Dry-run bypasses the privilege gate entirely.**

### Process launcher
```
TIMEOUT_EXIT_CODE  = 124
MAX_LINE_LENGTH    = 64 KiB   -> replaced by "[output line truncated]"
TERMINATION_GRACE  = 5 s
DRAIN_GRACE        = 2 s
```
- **stderr is merged into stdout** (`redirectErrorStream`), so `stderr` is empty except on
  timeout, where it is `Process timed out after <t>`.
- The environment is the parent's, overlaid with the request's.
- Commands are wrapped as `[setsid, "-w", *cmd]` when setsid exists and the request is
  detached (everything except shared-session sudo validation).
- Working directory must exist → `Working directory does not exist: <d>`;
  start failure → `Failed to start process: <argv0>`;
  interruption → `Process interrupted: <argv0>`;
  timeout → `Process timeout must be positive` / `Process timeout is too large` for bad inputs.
- Output capture is bounded: 256 KiB head + 256 KiB tail, joined with
  `\n… [<n> characters omitted] …\n`, never splitting a surrogate pair.
- Termination: TERM the process group, destroy descendants, wait the grace, then KILL the
  group and force-destroy.

### Path expansion
`${VAR}` and `${VAR:-default}` (the env value wins unless nil or blank), then `~` / `~/…` → home.

## 6. Download and verification

| Client | Limits | Notes |
|---|---|---|
| binary download | 10 min / 1 GiB (files), 1 min / 1 MiB (text), 64 KiB buffer, 30 s connect | HTTPS only, no user-info, **re-validated on the final redirect URI**; status must be exactly 200 |
| verified script | 1 MiB, 10 s connect, 30 s request and body deadline | writes `0700`, streaming SHA-256 |
| verified source artifact | 16 MiB | temp file at `0600`, streaming SHA-256 |

Messages:
```
Download URL must be HTTPS without user-info: <url>
Download failed with HTTP <code> for <url>
Download exceeds maximum size of <n> bytes
Download was truncated: expected <n> bytes but received <m>
Download body timed out after <t>
Download body interrupted
Script URL must be HTTPS without user-info
Script download returned HTTP <code>
Script download exceeds maximum size of <n> bytes
Script response body timed out after <t>
Script download was truncated or exceeded its declared Content-Length: expected <n> bytes but received <m>
Script SHA-256 mismatch
Source artifact exceeds maximum size of <n> bytes
Source artifact SHA-256 mismatch
Verified artifact stage is not a regular non-symlink file
Verified artifact stage exceeds the maximum size
Downloaded artifact exceeds maximum hash size of <n> bytes
```
Partial destination files are always deleted on failure.

### Detached signature verification (1 min)
```
[<realpath gpg>,"--batch","--no-tty","--status-fd=1","--verify",<signature>,<artifact>]
```
Parse lines starting `[GNUPG:] `. Reject on any of
`BADSIG ERRSIG EXPSIG EXPKEYSIG REVKEYSIG KEYEXPIRED SIGEXPIRED NODATA NO_PUBKEY`.
Require at least one `VALIDSIG` with exactly 10 or 11 fields; field 1 is the signing
fingerprint, field 10 (when present) the primary; both must be 40 or 64 uppercase hex.
Allowed public-key algorithms `{1, 3, 19, 22, 27, 28}` (RSA-enc, RSA-sign, ECDSA, legacy EdDSA,
Ed25519, Ed448). Allowed hash algorithms `{8, 9, 10}` (SHA-256/384/512).
Every `VALIDSIG` must match the configured allowed signer, as either fingerprint.
```
Detached signature verification failed: <detail>
Detached signature verification reported invalid status
Detached signature status is missing VALIDSIG
Detached signature reported malformed VALIDSIG status
Detached signature uses an unsupported public-key or hash algorithm
Detached signature was not made by the configured allowed signer
```
**A zero gpg exit code alone is never sufficient.**

### OpenPGP dearmoring
Bytes not starting `-----BEGIN PGP PUBLIC KEY BLOCK-----` are already binary and pass through.
Otherwise: pure ASCII, exact begin/end markers, armor headers ended by a blank line, payload
lines matching `[A-Za-z0-9+/]+={0,2}`, an optional trailing CRC line `=[A-Za-z0-9+/]{4}`
verified with OpenPGP CRC-24 (init `0xB704CE`, poly `0x1864CFB`).
```
OpenPGP key stage must be a regular non-symlink file
OpenPGP key exceeds <n> bytes
ASCII-armored OpenPGP key contains non-ASCII bytes
Malformed ASCII-armored OpenPGP public key
ASCII-armored OpenPGP key has no payload
Malformed ASCII-armored OpenPGP payload
Malformed ASCII-armored OpenPGP checksum
ASCII-armored OpenPGP checksum mismatch
```

### Privileged atomic publication (2 min per step)
```
["sudo",<realpath install>,"-d","-m","0755",<parent of anchor>]
["sudo",<realpath install>,"-m",<mode>,"--",<source>,<staged>]
  ... consumer runs against the root-owned stage ...
["sudo",<realpath rm>,"-f","--",<staged>]
```
Verified variant digests the stage first: in-process when the mode is world-readable and not
group/other-writable, otherwise `["sudo",<realpath sha256sum>,"--",<staged>]`.
Publish then runs `["sudo",<realpath mv>,"-f","-T","--",<staged>,<destination>]`.
```
Root-owned artifact stage exceeds the maximum size
Root-owned artifact stage failed SHA-256 verification
Privileged destination escapes its trusted root
Privileged destination has unsafe no-follow ancestry
Failed to remove root-owned artifact stage: <…>
Additionally failed to remove root-owned artifact stage: <detail>
```

### Archive extraction
tar.gz / tgz only, in process:
```
MAX_EXPANDED_ARCHIVE_BYTES = 2 GiB   (counts the whole decompressed TAR stream:
                                      headers, padding, GNU long names, PAX metadata)
MAX_EXTRACTED_ENTRY_BYTES  = 1 GiB
```
Strip-components: split the entry name on `/`; when there are not more components than the
strip count the entry can never match; otherwise rejoin from the strip index and require an
**exact** match with `archivePath`. Never match by basename.
```
Archive entry has an unknown expanded size: <name>
Archive entry exceeds maximum size of <n> bytes
Expanded archive exceeds maximum size of <n> bytes
Archive member selection is ambiguous for <archivePath>
Binary '<binaryName>' not found in archive
```
Tool archives (managed tool binaries) cap executables at 32 MiB, match
`name == exe || name.ends_with("/" + exe) || name == "./" + exe`, reject non-regular entries,
and stage at `0700` before an atomic move.

### Checksum documents
Literal checksum wins. Otherwise fetch the document and parse: a single 64-hex line, or a line
with two whitespace fields whose second field's normalized basename equals the asset name.
Normalization strips a leading `*` or `./`, rejects blanks, leading `/`, `\`, `//`, and control
characters, and requires every component to match `[A-Za-z0-9][A-Za-z0-9._+-]*`.
```
Binary URL does not identify an asset name
Checksum document contains duplicate entries for <a>
Malformed SHA-256 entry for <a>
Checksum document does not contain a SHA-256 entry for <a>
Cannot verify <a>: checksum entry names a different asset
Cannot verify <a>: checksum sidecar is empty
Cannot verify <a>: SHA-256 digest is malformed
Cannot verify <a>: checksum entry is missing
Cannot verify <a>: checksum entry is duplicated
```

### Tool acquisition
Resolution order: PATH (unless the spec requires a managed copy — binstaller does), then the
cache, then install under both an in-process lock and a file lock.
Every candidate asset must be present in the **trusted release-digest catalog**; the published
checksum must agree with the catalog, and the downloaded bytes must match it.
```
<asset> (not present in the trusted release-digest catalog)
Published checksum for <n> <v> disagrees with the trusted release-digest catalog
Checksum mismatch for <n> <v>: expected <x> but downloaded <y>
Failed to install <n> <v>. Tried: <joined with '; '>
Tool cache path escapes the configured cache root
```

## 7. Redaction (three layers, mask `<redacted>`)

Layer 1 — semantic patterns, applied in a fixed order (URL credentials, Authorization Basic,
Authorization Bearer, bare Basic, curl `--user`/`-u`, token assignment, sensitive `--flag`,
bare Bearer, PEM private keys). See `core-domain.md` for the exact expressions.

Layer 2 — terminal-control stripping (OSC, CSI, generic escapes; format characters dropped;
backspace deletes the previous code point; other controls become spaces) with a streaming
sanitizer that keeps multi-line PEM blocks masked across sink calls (128-char marker carry).

Layer 3 — exact secret-value masking from the item's environment:
```
MIN_EXACT_SECRET_LENGTH = 4      # a sensitive value shorter than this masks the WHOLE text
MAX_EXACT_SECRET_CARRY  = 4096   # a sensitive value longer than this masks EVERY line
```
Streaming redaction carries a tail that is a proper prefix of any secret into the next line.

Applied at: the shell-runner debug log, the live output sink, shell-script and shell-command
failure details and previews, SDKMAN output, GPG key failure detail (plus URL-parameter
stripping), compiled-binary failure text (public URL substitution), and fingerprinting
(public URLs; sensitive env values hashed).

## 8. Behavioural gotchas

1. The configured APT repository probe hardcodes "trust does not match", so a configured APT
   source is **always** reported as not installed and re-runs every time. Intentional —
   dearmored keyrings cannot be attested.
2. The DNF package probe defaults `supports` to **true** when the item records no package
   manager, while every other package probe defaults to false. Registration order therefore
   matters.
3. Continue-on-error return values differ per module kind (see the table above).
4. stderr is merged into stdout, so every `stdout + stderr` concatenation is effectively stdout.
5. The zypper install command omits `--non-interactive` while every zypper action includes it.
6. The binary install transaction mixes resolved and literal executables (`ln -s` and `rm` are
   passed bare and resolved later by the sudo transform).
7. Shell-reload's execute and preview commands disagree.
8. Phase planning seeds its ready queue from a hash map — use declaration order in the port.
9. The fingerprint length prefix counts UTF-16 code units.
