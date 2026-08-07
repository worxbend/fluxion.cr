# Migrating from the Java version

The Crystal implementation is the same product: same command surface, same trust
rules, same recorded state. The profile is written differently.

## Your state carries over

State files written by the Java version are read directly. The vocabulary the
file uses is the vocabulary Fluxion still uses — phases and their modules map
onto phases and their steps — so the recorded work is the same work.

```bash
fluxion state show
```

You should see what previous runs recorded. Nothing needs reinstalling.

## Your profile needs rewriting

Fluxion reads one document: a `WorkstationProfile` with an `apiVersion`/`kind`
header and `spec.phases[].steps[]`. The Java `profile`/`os`/`phases` YAML is not
accepted, and `fluxion validate` says so at the header rather than half way
down.

The rewrite is mechanical. Before:

```yaml
profile: workstation
os:
  type: fedora
  release: "44"

phases:
  - name: base
    continueOnModuleError: true
    modules:
      - type: packages
        name: core-tools
        packageManager: dnf
        packages: [git, curl]
```

After:

```yaml
apiVersion: initkit.io/v1alpha1
kind: WorkstationProfile
metadata:
  name: workstation
spec:
  target:
    os:
      distribution: fedora
      release: "44"
  phases:
    - name: base
      execution:
        continueOnError: true
      steps:
        - name: core-tools
          kind: dnf-packages
          spec:
            packages: [git, curl]
```

| Java | Fluxion |
|---|---|
| `profile:` | `metadata.name` |
| `os.type` | `spec.target.os.distribution` |
| `os.release` | `spec.target.os.release` (Debian and Ubuntu prefer `codename`) |
| `phases[]` | `spec.phases[]` |
| `phases[].modules[]` | `spec.phases[].steps[]` |
| `continueOnModuleError` | `phases[].execution.continueOnError` |
| `type:` on a module | `kind:` on a step, from the kind table |
| the module's own fields | `spec:` on the step |

`name`, `description`, and `when` stay on the step itself; everything else the
module declared moves inside `spec:`, `probeCommand` included.

Module types that changed name: `packages` became the six per-manager kinds
(`dnf-packages`, `apt-packages`, `pacman-packages`, `zypper-packages`,
`aur-packages`, `cargo-packages`), so the manager comes from the kind rather
than a field. `shell-script` became `shell-scripts`, `shell-command` became
`commands`, `compiled-binary` became `binary-downloads`, `dotbot` became
`dotfiles-apply`, and `flatpak` became `flatpak-packages`. Everything else keeps
its name.

The full list is in the
[config schema reference](https://github.com/worxbend/fluxion.cr/blob/main/docs/config-schema.md),
and `fluxion kinds` prints it from the table the parser actually uses.

Check the result before running it:

```bash
fluxion validate -c your-profile.yaml
fluxion dry-run  -c your-profile.yaml
```

## What else changed

**`import` produces a complete profile.** The Java version emitted a bare
fragment that could not be validated or previewed without hand-editing a header
onto it. The phase inside it still lifts straight into an existing profile.

**Colour is automatic.** Output piped into a file or a pager is plain without
passing a flag, and `NO_COLOR` is honoured.

**There is no JVM.** A single static binary, no runtime to install.

## What has not changed

The rules that matter are identical, and deliberately so:

- Downloads are HTTPS-only, size-bounded, and digest-checked before use
- A detached signature must name a signer the profile explicitly trusts
- Privileged commands resolve their target under a root-owned system directory
- `apply` refuses to run as root
- Items marked `confirm` need `--yes`; nothing prompts mid-run
- An unanswerable probe reports unknown, never missing

## If something differs

That is a bug worth reporting. The Crystal implementation was written against a
behavioural specification extracted from the Java sources — exact enum
spellings, argv vectors, validation messages, and the state file format — and
that specification is in the repository under `.port-spec/`.

Include the profile, the command, and what you expected.
