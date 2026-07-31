# Migrating from the Java version

The Crystal implementation is the same product: same profile schemas, same
command surface, same trust rules.

## Your profiles work unchanged

Both frontends are supported exactly as documented — the stable
`profile`/`os`/`jobs` schema including the `phases` and `modules` aliases, and
`WorkstationProfile` manifests with `apiVersion: initkit.io/v1alpha1`.

Check before switching:

```bash
fluxion validate -c your-profile.yaml
fluxion dry-run  -c your-profile.yaml
```

## Your state carries over

State files written by the Java version are read directly. The vocabulary
changed internally — phases became jobs, modules became steps — but the
recorded work is the same work, so it maps across.

```bash
fluxion state show
```

You should see what previous runs recorded. Nothing needs reinstalling.

## What changed

**`--phase` is now `--job`.** The old name is not accepted; the docs and the
error messages agree on one word.

**`import` produces a complete profile.** The Java version emitted a bare
fragment that could not be validated or previewed without hand-editing a header
onto it. The job inside still lifts straight into an existing profile.

**Colour is automatic.** Output piped into a file or a pager is plain without
passing a flag, and `NO_COLOR` is honoured.

**There is no JVM.** A single static binary, no runtime to install.

## What has not changed

The rules that matter are identical, and deliberately so:

- Downloads are HTTPS-only, size-bounded, and digest-checked before use
- A detached signature must name a signer the profile explicitly trusts
- Privileged commands resolve their target under a root-owned system directory
- `apply` refuses to run as root
- Items marked `confirm` need `--yes`; nothing prompts mid-run
- An unanswerable probe reports unknown, never missing

## If something differs

That is a bug worth reporting. The Crystal implementation was written against a
behavioural specification extracted from the Java sources — exact enum
spellings, argv vectors, validation messages, and the state file format — and
that specification is in the repository under `.port-spec/`.

Include the profile, the command, and what you expected.
