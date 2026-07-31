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
