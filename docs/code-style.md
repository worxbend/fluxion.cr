# Code style

The conventions this codebase actually follows, with the reasoning that makes
them worth following. Written for whoever — human or agent — edits it next.

Formatting is not discussed here: run `crystal tool format` and `./bin/ameba`
and accept what they say.

## Comments carry the *why*, and they stay

This is the convention most likely to be violated by someone applying habits
from elsewhere, so it comes first.

A comment here explains why a rule exists, what constraint forces an awkward
shape, or what breaks if the obvious thing is done instead. It does not restate
the code:

```crystal
# Signals the whole process group: a package manager that spawned children
# would otherwise leave them running after Fluxion gave up on it.
```

```crystal
# Only the real file is cached: specs pass an explicit path to describe a host
# they are not running on, and caching those would leak one spec's fixture
# into the next.
```

Both say something the code cannot. Delete either one and the next edit has to
rediscover it — or, more likely, quietly breaks it.

Comments explaining *what a line does* (`# increment the counter`) are still
noise and should be removed on sight. The distinction is provenance, not length.

**Do not prune these comments as "verbose".** They are the cheapest available
form of context, and stripping them is a net loss even when the code reads
clearly without them.

Two specific obligations:

- When you delete something because it was a trap, leave a note saying so.
  `State::Store` has a comment where a per-item lookup used to be, because the
  method looked entirely reasonable at its call site and would otherwise be
  reintroduced.
- When a comment claims a measurement, the measurement must be real and
  reproducible. See `docs/performance.md`.

## Small units, because attention is the scarce resource

Functions do one thing; 4–20 lines is the target. Files stay under 500 lines and
ideally 200–300, so a reader can hold the whole unit at once instead of
paginating through it and reasoning from fragments.

Currently over the line and worth splitting when next touched:

| File | Lines |
|---|---|
| `src/fluxion/cli/commands/registry.cr` | 931 |

Splitting these is a real improvement, not bookkeeping: each is several
responsibilities sharing a file, and every edit to one loads all of them.

`step_executor.cr` (769) and `commands/state.cr` (521) were the other two. The
first kept the abstraction and gave its sixteen concrete executors to
`executors/packages.cr`, `executors/system.cr` and `executors/shell.cr`, beside
the ones already there. The second was three unrelated command families sharing
a filename — `GroupCommand` moved next to `Command`, and `report` and `tools`
took their own files, which also removed an undocumented require-order
constraint in `cli.cr`: `commands/state` had to precede `commands/generate` and
`commands/registry` because it defined their superclass.

## Names are searchable or they are wrong

The test is mechanical: grep the name. If mostly irrelevant matches come back,
rename it.

`ProbeSweep`, `StreamingSanitizer`, `SkippedPlanEntry`, and `forget_phase` each
land on exactly what they describe. `Manager`, `Handler`, `data`, and `process`
do not, and are absent from this codebase deliberately.

This is also why the config vocabulary and the internal model use the same word.
When configuration said `phases` and the code said `Job`, every reader had to
hold a translation table, and every grep for one term missed the other.

## Types are explicit

Every method signature carries parameter and return types, including `: Nil`.
This is not ceremony — it is the answer key that saves the next reader (and the
compiler) from inferring intent from usage.

Nilability is meaningful: `Node#missing?` and `Node#null?` are different
questions, and the type system is what keeps them apart.

## Guard clauses, not nesting

Return early. Every level of indentation is state a reader has to track:

```crystal
private def partial_marker(text : String) : String?
  return nil if text.empty? || !MARKER_TAILS.includes?(text[-1])
  # ...
end
```

## Errors say what was wrong with what

An error message names the value, the location, and where possible the fix:

```crystal
"unsupported plan kind 'dnf-package'. Did you mean 'dnf-packages'?"
"package manager apt is not valid for target fedora, expected dnf"
```

Config diagnostics carry the exact dotted path (`spec.phases[1].steps[0].kind`)
because a message that makes the user search the file is a message that failed.
This is what `Config::Node` exists for.

## One table, read by everyone

`Config::PlanKinds::ALL` is the single source for the kinds a profile may
declare, the list `fluxion kinds` prints, what `validate` accepts, and what the
docs describe. Duplicating it anywhere would let the documented, accepted, and
executable sets drift apart silently — which is the specific failure mode DRY is
guarding against here.

The same applies to `PackageManager` and `Distribution`. When adding a
capability, add it to the table and let the readers follow.

## Tests run headless, and fast

`crystal spec` is the whole contract: no manual setup, no fixture outside the
repo, no network, no credential. `FakeShellRunner` exists so every executor can
be tested on the argv it builds and how it reads a result, without a package
manager in sight — that is the seam that makes the suite fast and hermetic.

A slow suite is a defect. A spec that took five seconds was hiding a real bug in
the timeout path; fixing the bug took the suite to 250 ms.

Specs must not depend on the machine running them. Pass an explicit
`/etc/os-release` path rather than reading the host's.

## Performance changes come with numbers

Measure in this repository, put the figure in the commit message, and record the
invariant that keeps it true in `docs/performance.md`. An optimisation nobody can
reproduce is just code that is harder to read.
