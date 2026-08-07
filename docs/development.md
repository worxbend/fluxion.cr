# Development

## Getting set up

```bash
git clone https://github.com/worxbend/fluxion.cr
cd fluxion.cr
shards install
```

Crystal 1.21 or newer. The only runtime dependency is `kiwi` (a Cassowary
solver, used by the vendored TUI toolkit for layout).

## The loop

```bash
crystal spec                    # tests
./lib/ameba/bin/ameba src spec  # lints
crystal tool format src spec    # formatting
shards build                    # ./bin/fluxion
```

All three must be clean before a commit. The suite runs in seconds because
nothing in it spawns a package manager.

The linter binary is built once with `shards build ameba` from `lib/ameba`; the
command above assumes it is there.

## Trying it

```bash
./bin/fluxion validate -c examples/example-fedora.yaml
./bin/fluxion dry-run  -c examples/example-arch.yaml
./bin/fluxion status   -c examples/example-arch.yaml
```

`dry-run`, `plan`, `status`, `diff`, and `doctor` never mutate anything, so
they are safe to run against a real profile on your own machine.

`apply --probe-only` runs every probe and reports what it found without
installing.

## How the tests are written

`Executor::FakeShellRunner` records the argv a step executor builds and replays
canned results:

```crystal
runner = Fluxion::Executor::FakeShellRunner.new.on("install -y broken", 1)
summary, _, _ = run(profile, runner)

summary.succeeded.should eq(2)
runner.ran?("install -y curl").should be_true
```

A step executor's real contract is the argv it builds and how it reads a
result, and both are observable here. That is what lets the suite pass on a
machine with no `dnf`, no `flatpak`, and no network.

`ProfileHelpers` writes a profile to a temporary directory and parses it, so a
spec states the YAML it means rather than referring to a fixture file:

```crystal
result = ProfileHelpers.parse(<<-YAML)
  apiVersion: initkit.io/v1alpha1
  kind: WorkstationProfile
  metadata:
    name: p
  spec:
    target:
      os:
        distribution: fedora
    phases:
      - name: base
        steps:
          - name: tools
            kind: dnf-packages
            spec:
              packages: [git]
  YAML

result.errors.should be_empty
```

The shipped example profiles are the end-to-end check: `spec/config/examples_spec.cr`
parses every one of them, so a regression in any parser surfaces there first.

## Adding a step kind

Six places, in order:

1. **`core/steps/`** — the validated data. No IO.
2. **`config/step_parser/`** — YAML in, that type out.
3. **`config/plan_kinds.cr`** — the kind id, its category, and its entry in
   `STEP_TYPES`. `fluxion kinds`, `validate`, the did-you-mean suggester, and
   the mapper all read that one table, so they cannot drift apart.
4. **`core/item_type.cr`** and **`executor/item_types.cr`** — the `ItemType`
   member and the arm that maps the step onto it. This is the discriminator
   written to the state file and the key probes dispatch on, so getting it
   wrong misreports the item rather than failing.
5. **`executor/step_executor.cr`** or **`executor/executors/`** — the commands.
   Register it in `ExecutorRegistry.default`.
6. **`executor/probe.cr`** — how to tell whether it is already there, if it has
   an observable footprint. Register it in `ProbeRegistry.default`.

Then document it in `docs/config-schema.md`, in the same order the table
declares it.

Steps 3 and 4 are the ones that used to fail silently — a kind missing from
`STEP_TYPES` vanished from the profile while `validate` still reported success,
and a kind missing from the `ItemType` table recorded its items under the wrong
discriminator. Both now fail loudly, and `spec/config/kind_tables_spec.cr`
checks the tables against each other and against every `Step` subclass.

## Adding a command

One file under `cli/commands/`, subclassing `Command`, plus a line in
`App#commands`. Each command owns its own option parsing, so `fluxion plan
--help` describes plan rather than a merged surface.

Write to `@output` and `@error_output` rather than `STDOUT`/`STDERR` — the
specs assert on rendered output without spawning the binary.

## Conventions

**Comments say why, not what.** The code already says what it does. A comment
earns its place by explaining a decision that is not obvious from reading it —
usually a trade-off, a failure mode, or a rule that exists because the
alternative is worse.

**Errors accumulate where a human is reading them.** Config parsing collects
diagnostics rather than raising at the first problem, because a profile with
five typos should take one run to fix.

**Refuse rather than guess.** An unverifiable download, an ambiguous archive
member, a `state forget` matching several entries — each of these is refused
with an explanation. Picking one is a guess, and a guess about what to install
as root is the wrong kind of convenience.

**Commit gradually,** with [Conventional Commits](https://www.conventionalcommits.org)
messages, one self-contained change at a time.

## The port reference

`.port-spec/` holds four documents extracted from the Java implementation: the
core domain model, the config parser and TUI, the CLI surface, and the
executor. They pin exact enum spellings, argv vectors, validation messages, and
the state file format.

Consult them before changing anything user-visible. They are the reason this
implementation can claim parity rather than merely resemblance.

## Releasing

Tag a version and push it. The release workflow builds a static Linux binary
and publishes it with a SHA-256 checksum file and a copy of the install script.

```bash
git tag -a v0.2.0 -m "v0.2.0"
git push origin v0.2.0
```

Update `version:` in `shard.yml` first — `fluxion --version` reads it at
compile time.

## Publishing the site and the wiki

Both live in this repository so a change to behaviour and the page describing
it land in the same commit. Each is published to somewhere GitHub serves from.

**The site** is `site/` — a self-contained `index.html` with no external
fonts, scripts, or stylesheets. GitHub Pages serves the `gh-pages` branch, and
`.github/workflows/pages.yml` rewrites that branch on any push to `main` that
touches `site/`. The branch is a single orphan commit each time: the site is
build output, not history.

Nothing needs doing by hand. To publish out of band — testing a change, or
after editing the workflow itself:

```bash
./scripts/publish-site.sh --dry-run   # what would go live
./scripts/publish-site.sh             # push gh-pages yourself
gh workflow run Pages                 # or let Actions do it
```

Preview locally first; it is a static page, so anything serving a directory
will do:

```bash
python3 -m http.server -d site 8000
```

**The wiki** is `wiki/`, published to the separate `fluxion.cr.wiki.git`
repository:

```bash
./scripts/sync-wiki.sh --dry-run
./scripts/sync-wiki.sh
```

This one is manual. A wiki repository only materialises once its first page has
been created through the web UI, and there is no API for that step, so the
script checks and says what to do rather than failing obscurely.

`wiki/README.md` documents the source and is deliberately not published.
