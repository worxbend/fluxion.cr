# Fluxion wiki

Practical material that does not belong in the reference docs: recipes,
troubleshooting, and the reasoning behind decisions people ask about.

The reference lives in the repository:

- [Command reference](https://github.com/worxbend/fluxion.cr/blob/main/docs/commands.md)
- [Config schema](https://github.com/worxbend/fluxion.cr/blob/main/docs/config-schema.md)
- [WorkstationProfile manifests](https://github.com/worxbend/fluxion.cr/blob/main/docs/workstation-profile.md)
- [Registries](https://github.com/worxbend/fluxion.cr/blob/main/docs/registry.md)
- [Architecture](https://github.com/worxbend/fluxion.cr/blob/main/docs/architecture.md)

## Pages

- **[Getting started](Getting-started)** — from nothing to a working profile
- **[Recipes](Recipes)** — profile patterns worth copying
- **[Registries](Registries)** — sharing profiles between machines
- **[Troubleshooting](Troubleshooting)** — what a message means and what to do
- **[Migrating from the Java version](Migrating-from-Java)**
- **[Design decisions](Design-decisions)** — why Fluxion refuses certain things

## The short version

```bash
fluxion generate --output ~/.config/fluxion/default.yaml
fluxion validate
fluxion dry-run
fluxion apply
```

Read the dry run. Then let it go.
