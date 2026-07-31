# Contributing

Small, boring improvements are the most welcome kind: clearer docs, more distro
examples, better validation messages, more installer kinds, sharper TUI
details, safer execution edges.

## Before you start

```bash
shards install
crystal spec
```

The suite runs in seconds and needs no package manager, no network, and no
root. If it does not pass on a clean checkout, that is a bug — please say so.

## The bar

```bash
crystal spec                    # tests
./lib/ameba/bin/ameba src spec  # lints
crystal tool format src spec    # formatting
```

All three clean. CI checks the same three, plus that every example profile
still validates and previews.

## What a good change looks like

**Tests that state behaviour, not implementation.** `FakeShellRunner` records
the argv a step builds and replays canned results, so a test can assert what
would actually run:

```crystal
runner.ran?("install -y curl").should be_true
```

**Comments that say why.** The code says what it does. A comment earns its
place by explaining a decision that is not obvious — a trade-off, a failure
mode, or a rule that exists because the alternative is worse.

**Gradual commits** with [Conventional Commits](https://www.conventionalcommits.org)
messages. One self-contained change each.

## Adding a step kind

Four places, in order — `docs/development.md` has the detail:

1. `core/steps/` — the validated data
2. `config/step_parser/` — YAML in, that type out
3. `executor/` — the commands it produces
4. `executor/probe.cr` — how to tell it is already there

Then document it in `docs/config-schema.md`.

## Changing anything user-visible

`.port-spec/` holds the behavioural specification extracted from the Java
implementation: exact enum spellings, argv vectors, validation messages, and
the state file format.

Check it before changing a message, a flag, or an exit code. Where this
implementation deliberately diverges, that belongs in the commit message.

## Reporting a bug

The profile, the command, what you expected, and what happened. `--verbose`
adds a backtrace for anything unexpected.

If a profile behaves differently here than under the Java implementation, that
is worth reporting on its own — parity is the goal.
