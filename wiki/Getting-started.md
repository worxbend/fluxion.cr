# Getting started

## Install

```bash
curl --proto '=https' --tlsv1.2 -sSfL https://worxbend.github.io/fluxion.cr/install.sh | sh
```

If `~/.local/bin` is not on your `PATH`, the installer says so and stops short
of editing your shell startup files. Adding the line yourself is one edit and
keeps Fluxion out of files it has no business touching.

## Your first profile

Start from the machine you are on:

```bash
fluxion generate --output ~/.config/fluxion/default.yaml --preset developer
```

That is deliberately plain — a starting point to edit, not a finished profile.
Open it and change the package list to what you actually want.

## The loop

```bash
fluxion validate   # would this run at all?
fluxion lint       # is it a good profile?
fluxion doctor     # is this host ready?
fluxion dry-run    # what would it do?
```

`validate` reports every problem at once, each anchored to the exact line:

```
error spec.phases[0].steps[0].spec.packages[2]: package name contains unsafe shell characters: bad name
error spec.phases[0].steps[1].kind: unsupported step kind 'dnf-package'
        Did you mean 'dnf-packages'?
```

When the dry run says what you expect:

```bash
fluxion apply
```

## Rerunning

Fluxion records what worked. The second run is cheap:

```bash
fluxion apply --skip-already-installed
```

A completed phase is skipped only while its configuration is unchanged. Add a
package and that phase runs again — it is not marked done forever.

## Seeing where you are

```bash
fluxion status            # everything
fluxion status --missing  # just what is left
fluxion diff              # only what differs from this machine
```

## Starting from an existing machine

If your machine is already set up and you want a profile describing it:

```bash
fluxion import packages --from-host --output packages.yaml
fluxion import flatpaks --from-host --output flatpaks.yaml
```

Both produce complete, valid profiles. Prune them heavily — an import lists
everything, including things you installed once to try and never used again.
