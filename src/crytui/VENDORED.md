# CryTUI (vendored)

This directory is a vendored copy of the `CryTUI` terminal-UI library from
[worxbend/obsctl](https://github.com/worxbend/obsctl) (`src/crytui`).

It is a Ratatui-inspired immutable-buffer TUI toolkit: a cell `Buffer` that is diffed against the
previous frame, a Cassowary-solved `Layout`, `Style`/`Color`/`Modifier` primitives, Unicode-aware
display-width measurement, an incremental VT input parser, and an ANSI backend.

It is vendored rather than depended on because CryTUI is not published as a standalone shard. Keep
this copy in sync by hand; changes made here that are generally useful belong upstream in obsctl
first.

Its only external dependency is [`kiwi`](https://github.com/da1nerd/kiwi.cr), declared in the
top-level `shard.yml`.

`src/fluxion/tui/` builds Fluxion's screens on top of this; nothing under `src/crytui/` should know
anything about Fluxion's domain.

## `spinner/` — ported, not vendored

`spinner/` and `spinners.cr` are a port of
[sorinirimies/tui-spinner](https://github.com/sorinirimies/tui-spinner) 0.4.1 (`f677803`), MIT,
Copyright (c) 2026 Sorin Albu-Irimies. All six widgets and every animation preset are carried over.

It is a port rather than a copy: the original is Rust against Ratatui, and the shape of the API
follows this codebase — keyword-argument constructors instead of builder chains, `Style` instead of
`Color`, `render(area, buffer)` like the other widgets here.

The geometry is a faithful transcription, and `spec/crytui/spinners_spec.cr` pins it with frames
taken from the Rust original rendering the same configuration at the same tick. Change the
arithmetic and those specs are the thing that says so. One behaviour is deliberately not a
transcription: the original replays every step from tick zero on each frame, so a spinner left on
screen for an hour costs thousands of walks per redraw. Here the tick is first folded onto the
animation's own cycle, which is why `SquareEngine.cycle` and the `period` methods exist.
