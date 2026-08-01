# Example registry

The layout `fluxion registry init` scaffolds, filled in with three entries.

```text
fluxion-registry.yaml     the manifest, at the root, under this name
profiles/                 every entry lives in here
├── base-fedora.yaml
├── base-arch.yaml
└── developer.yaml
```

Try it against this directory, without a remote:

```bash
fluxion registry add "file://$PWD/examples/registry" --name example
fluxion remote-ls --all
fluxion registry show developer
fluxion registry install developer --with-requires
fluxion registry remove example --purge
```

A real registry is a git repository — `sync` and `publish` need one. Reading
works from a plain directory, which is enough to see the shape.

The full format is documented in [docs/registry.md](../../docs/registry.md).
