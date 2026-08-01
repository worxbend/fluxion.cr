# Example registry

The layout `fluxion registry init` scaffolds, filled in with three entries.

```text
fluxion-registry.yaml     the manifest, at the root, under this name
profiles/                 every entry lives in here
├── base-fedora.yaml
├── base-arch.yaml
└── developer.yaml
```

Try it without a remote. A registry is always a git repository, so copy this
directory somewhere and make one:

```bash
cp -r examples/registry /tmp/example-registry
git -C /tmp/example-registry init -q -b main
git -C /tmp/example-registry add -A
git -C /tmp/example-registry commit -qm "Example registry"

fluxion registry add file:///tmp/example-registry --name example
fluxion remote-ls --all
fluxion registry show developer
fluxion registry install developer --with-requires
fluxion registry remove example --purge
```

It is a copy, so publishing back to it is safe to experiment with.

The full format is documented in [docs/registry.md](../../docs/registry.md).
