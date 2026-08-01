---
layout: default
title: Fluxion
description: Turn a fresh Linux machine into your machine.
---

# Fluxion

**Turn a fresh Linux machine into your machine.**
One YAML file. One preview. One run. CLI or TUI.

```bash
curl --proto '=https' --tlsv1.2 -sSfL https://worxbend.github.io/fluxion.cr/install.sh | sh
```

The installer verifies the release's published SHA-256 before writing anything,
installs to `~/.local/bin/fluxion`, and leaves your shell startup files alone.

[Read it first](install.sh) if you would rather not pipe a script to a shell —
that is a reasonable instinct, and the script is short.

---

## The idea

Describe the machine you want. See exactly what Fluxion would do. Then let it.

```yaml
profile: my-laptop
os:
  type: fedora
  release: "44"

jobs:
  - name: base
    steps:
      - type: packages
        name: core-tools
        packageManager: dnf
        packages: [git, curl, jq, zsh]
```

```bash
fluxion validate    # is this profile sound?
fluxion dry-run     # what would it do?
fluxion apply       # do it
```

Preview and run are the same traversal with one flag different, so what you
review is what executes.

---

## What makes it different

**Nothing runs unverified.** Every download is HTTPS-only with no URL
credentials, re-validated after each redirect, size-bounded while streaming,
and digest-checked before use. A detached signature must name a signer your
profile explicitly trusts — a valid signature from an unknown key is not trust.

**Failures stay small.** Packages install one process each, so one bad name
never loses the rest of the list. A job whose dependency failed is reported as
blocked, not silently skipped.

**It tells you what it does not know.** A probe that cannot answer reports
*unknown*, never *missing*. Absence of evidence is not evidence of absence, and
reinstalling on that basis would be wrong.

**It refuses rather than guesses.** An ambiguous archive member, an
unverifiable download, a `state forget` matching several entries — each is
refused with an explanation. Guessing about what to install as root is the
wrong kind of convenience.

**It will not run as root.** There is no safe way to drop back to your account
for the steps that must not be root-owned.

---

## Reruns are cheap

Fluxion records what worked, with versions and checksums, and fingerprints each
job's configuration. A completed job is skipped only while that fingerprint
still matches — so editing a package list makes the job run again rather than
being quietly considered done.

```bash
fluxion status      # what is installed, missing, unknown, or drifted
fluxion diff        # only what differs from this machine
fluxion explain --item git
```

---

## Share profiles between machines

Keep the profiles you want everywhere in a git repository, and install them by
id:

```bash
fluxion registry add https://github.com/you/fluxion-profiles
fluxion remote-ls
fluxion registry install workstation
```

The clone lives in your cache directory and is disposable. What you install
lives in your config directory and is yours — a `sync` refreshes the first and
never touches the second, and tells you which of your configurations changed
upstream.

Installing writes a file and stops. Running it stays a separate, deliberate
step.

---

## Two schemas

The stable **jobs/steps** schema gives you an explicit dependency graph.

The **WorkstationProfile** manifest gives you one ordered plan, selected by
host facts and per-entry `when` rules — the same profile does the right thing
on Fedora and on Arch.

Both land on the same model, so every command works with either.

---

## Documentation

- [Command reference](https://github.com/worxbend/fluxion.cr/blob/main/docs/commands.md)
- [Config schema](https://github.com/worxbend/fluxion.cr/blob/main/docs/config-schema.md)
- [WorkstationProfile manifests](https://github.com/worxbend/fluxion.cr/blob/main/docs/workstation-profile.md)
- [Registries](https://github.com/worxbend/fluxion.cr/blob/main/docs/registry.md)
- [Architecture](https://github.com/worxbend/fluxion.cr/blob/main/docs/architecture.md)
- [Development](https://github.com/worxbend/fluxion.cr/blob/main/docs/development.md)

Example profiles for Fedora, Arch, openSUSE, and Ubuntu are in the
[repository](https://github.com/worxbend/fluxion.cr/tree/main/examples).

---

## Upgrading from the Java version

Fluxion was a Java 25 / GraalVM project. This is a ground-up Crystal
reimplementation of the same product: same schemas, same commands, same trust
rules.

State files written by the Java version are read directly, so upgrading does
not mean reinstalling everything you already have.

---

<p align="center">
  <a href="https://github.com/worxbend/fluxion.cr">GitHub</a> ·
  <a href="https://github.com/worxbend/fluxion.cr/issues">Issues</a> ·
  MIT licensed
</p>
