# Performance

What the hot paths are, what was measured, and the invariants that keep the
current numbers true. Every figure below came from a benchmark or a timed run
on this repository, not from estimation.

Fluxion has no database. The JSON state file under `$XDG_DATA_HOME/fluxion` is
its analogue, and it is where the one genuine N+1 lived.

## The four paths that matter

Almost all of Fluxion's time is spent in four places. Everything else —
including config parsing — runs once per invocation over a bounded input and
does not repay optimisation.

| Path | Runs | Dominated by |
|---|---|---|
| Probe sweep (`status`, `diff`, `plan`) | once per item | subprocess latency |
| Output redaction | once per output line | regex scans and rebuilds |
| TUI redraw | once per frame | cell allocation |
| State bookkeeping | once per item | file reads and JSON parsing |

## Probes are subprocesses, so they run concurrently

A probe asks a package manager whether one item is installed. It spends nearly
all of its life waiting on that subprocess rather than on Fluxion, so running
probes one after another makes a sweep cost *items × query latency*.

`Executor::ProbeSweep` runs them across a bounded pool of fibers instead.
Measured on `examples/example-arch.yaml` (34 items):

```
serial     1.624s    65% CPU
concurrent 0.294s   461% CPU     5.5x, byte-identical output
```

Two invariants make this safe, and both must survive any change here:

- **Results are returned in the order the items were given.** Completion order
  must never leak into a report, or the output would reshuffle itself between
  runs for no reason a reader could see.
- **Only read-only sweeps use it.** Execution stays strictly sequential: a step
  may depend on what an earlier one installed, and per-item ordering is part of
  what makes a run followable.

`SystemShellRunner` is safe to share across fibers because it holds no mutable
state — every call builds its own pipe, capture buffer, and sanitizer. Adding
mutable state to it would silently break the sweep.

Still serial: the read-only sweep inside `Orchestrator` (`plan`, `dry-run`).
Parallelising it means reordering the per-item events the reporter and TUI
consume, which is a presentation decision rather than a mechanical one.

## Redaction runs on every line, so it avoids work it does not need

`Redaction.redact_output` is called for every line every command emits — tens of
thousands of lines for a large install. Two changes, together **3.96x faster and
29x less garbage** (9.67 kB/op to 336 B/op) with byte-identical output:

- **Strip once, not twice.** `redact_output` stripped control characters, then
  called `sanitize_line`, which stripped them again. The second pass was
  provably a no-op: `mask_values` only ever substitutes `<redacted>`, which
  contains no control characters.
- **A fast path for plain ASCII.** Command output is overwhelmingly printable
  ASCII, and for such a string `strip_controls` is the identity — ESC, newline,
  backspace and every control byte are below `0x20`, and the format characters
  and line separators are all multi-byte. A byte scan short-circuits three
  regex passes and a per-character rebuild: **64x faster on a typical line, and
  it allocates nothing**.

### Interpolated regex literals recompile on every evaluation

This is a Crystal-specific trap worth stating plainly, because it is invisible
at the call site:

```crystal
NAME = "(?:api[._-]?key|token|secret)"

/(^|[^a-z0-9])#{NAME}($|[^a-z0-9])/   # rebuilt and recompiled by PCRE2 every time
```

Measured against the same pattern hoisted into a constant: **10.33 µs vs
362 ns, 28.5x**. A regex literal *without* interpolation is hoisted by the
compiler and costs nothing, so only interpolated ones need this treatment.

Any interpolated regex evaluated more than once belongs in a constant.

## The TUI reuses its buffers

`Cell` is a class, so `Buffer.new` heap-allocates `width × height` objects —
10,000 on an ordinary terminal. Allocating a fresh back buffer every frame
turned all of them into garbage on the next frame.

`Terminal#draw` now clears a spare buffer in place and swaps it with the front
buffer: **391 kB/frame to 0 B, 10.2x faster**. `synchronize_area` must replace
*both* buffers on a resize, because `diff` refuses to compare buffers whose
areas differ and they trade places every frame.

## State is loaded once per run, never once per item

`Orchestrator#skip_decision` used to call a store method that re-read and
re-parsed the whole state file to answer a question about a single item —
a file read and a JSON parse **per package**, quadratic in the size of the
state file over a run.

It now reads the `Document` the `Recorder` already holds. The `Recorder` buffers
writes for the same reason: writing per item would multiply a large profile's
run by hundreds of fsyncs.

The per-item store lookup was deleted rather than left available, and there is a
comment in `State::Store` saying why, because the method looked perfectly
reasonable at its call site. If you find yourself wanting it back, load a
`Document` once and use `Document#find`.

Known and deliberately left alone: `Document#find` and `Document#record` are
linear scans, so recording a run is O(items × records). For a 300-item profile
that is ~90,000 string comparisons — under a millisecond, far below the file
I/O it sits next to. Indexing it would be complexity without a payoff. Revisit
if profiles grow by an order of magnitude.

## Host facts are cached; PATH lookups are not

`Host.facts` re-read and re-parsed `/etc/os-release` on every call, and
`generate` alone asked four times. It is now cached — but only for the real
file. Specs pass an explicit path to describe a host they are not running on,
and caching those would leak one spec's fixture into the next.

`Host.command_exists?` is **deliberately not cached**, and this is worth
recording because it looks like an obvious win. A probe sweep does ask the same
question once per item, and each answer costs a stat per PATH entry. Caching it
was tried and reverted, for two reasons:

- PATH is ambient state a step can change by installing something, so the cache
  has to be invalidated mid-run — correctness work in exchange for a small gain.
- As module-level state it outlived a spec example. It broke four specs that
  passed individually and failed in suite, which is the worst failure mode to
  leave behind.

The stats it saved were noise next to the subprocess each probe spawns. That
cost was real, and it went to `ProbeSweep` instead.

The general rule: before caching anything about the host, answer *what
invalidates this, and who else can see it?* If the answer to the second question
is "the next spec example", it is module-level state and it does not belong here.

## Timeouts wait once, not twice

Abandoning a hung command sent `SIGTERM`, slept the full grace period, sent
`SIGKILL`, and only then waited for the exit — so giving up took twice
`TERMINATION_GRACE`, and a process that honoured `SIGTERM` promptly was killed
anyway.

The grace period is now spent waiting on the exit channel. A process that stops
is reaped the moment it does; only one that ignores `SIGTERM` is escalated.
`spec/executor/shell_runner_spec.cr` went from **5.25s to 250ms** as a direct
result — a suite that slow to run is itself a performance problem.

## What was measured and left alone

- **Config parsing.** `Node#child_path` builds a path string for every node
  access, including the overwhelming majority that never produce a diagnostic.
  Parsing happens once per run over a file capped at 8 MB; making paths lazy
  would complicate the type for no measurable gain. The double hash lookup in
  `Node#[]` was collapsed into one because that was free.
- **`Buffer#diff`.** O(cells) per frame is inherent to double buffering.
- **Download and archive I/O.** Bounded by the network and the filesystem.

## Adding to this

Measure first, in this repository, and put the number in the commit message. A
change that cannot be shown to matter is a change that makes the code harder to
read for nothing.
