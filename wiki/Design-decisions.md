# Design decisions

Things Fluxion refuses to do, and why. Each of these has been asked about.

## Why will it not run as root?

Because a bootstrap writes into your home directory. A dotfiles checkout, a
`~/.cargo`, a shell history file — created by root, those are a mess to unpick,
and the failure is silent until something else breaks.

There is no safe general way to drop back to the invoking user for exactly the
steps that need it. Refusing at the start is honest; escalating per step is
what Fluxion does instead.

## Why does a checksum failure stop everything?

Because the alternative is running bytes nobody vouched for, as root.

Upstream republishing an artifact under the same URL is a real and ordinary
event. It is also indistinguishable, from where Fluxion sits, from a
compromised mirror. Fail closed, let a human look, update the pin.

## Why is a `checksumUrl` not enough on its own?

It is served by the same host as the artifact. An attacker who can replace one
can replace both, so the pair proves only internal consistency.

It is useful *alongside* a signature — it catches a mismatched release asset
early — which is exactly how the schema allows it.

## Why parse gpg's status output instead of trusting its exit code?

`gpg --verify` exits zero for a valid signature made by **any** key in the
keyring. That is not the question. The question is whether it was made by the
key your profile named, and only the machine-readable status output answers it.

SHA-1 signatures are rejected for the same reason: a signature is a claim about
bytes, and a broken hash makes the claim meaningless.

## Why does an unknown probe not count as missing?

Reinstalling because a check failed is acting on absence of evidence. If
`flatpak` is not on `PATH`, Fluxion does not know whether an app is installed —
and installing it is not the safe default, saying so is.

`fluxion status --failed` shows these alongside genuine misses.

## Why one process per package?

So one bad name loses one package. A single transaction installing twenty
packages fails entirely on the first typo, and you get nothing — including the
nineteen that were fine.

The cost is some process overhead. The benefit is that a bootstrap makes
progress even when the profile is imperfect, which it usually is on the first
run.

## Why refuse an ambiguous archive member?

Two members with the same post-strip path means the profile did not say which
one it meant. Picking one is a guess about which binary to install, and a
wrong guess is silent.

Matching by basename would be worse: it is exactly how you end up installing a
documentation file that happens to share a name.

## Why bound the decompressed stream rather than the download?

A compressed file's size says nothing about what it expands to. A few hundred
kilobytes can become gigabytes.

Bounding the download would catch a large file; bounding the decompressed
stream catches a bomb.

## Why does `state forget` refuse an ambiguous key?

Because deleting several entries when the user named one is doing more than
they asked. `--step` and `--type` narrow it, and the error says so.

## Why no interactive prompts during a run?

A run that waits for input hangs in CI, under a timeout, in a container, and in
a terminal the user has walked away from — and a bootstrap is exactly the kind
of thing people walk away from.

Approval happens up front with `--yes`, where the decision is visible next to
the dry run that motivated it.

## Why is there only one config schema?

Two shapes were drafted before either shipped: a `jobs`/`steps` document and a
`WorkstationProfile` manifest. They described the same work, so the cost was
paid three times over — two words for every concept (jobs and phases, modules
and steps, `type` and `kind`), two validation paths that had to be kept in
agreement, and a reference that had to explain both and then explain when to
choose which.

The manifest shape won because it carries a version header and keeps each
kind's payload in its own `spec`, which is what lets a new kind be added without
touching the envelope. The phase DAG, `dependsOn`, and `restartPolicy` came
across from the other side, so nothing was lost with it.

## Why is state fingerprinted?

Otherwise "this phase completed" would mean "this phase completed once, ever",
and adding a package to a completed phase would be silently ignored.

The fingerprint covers what actually changes what runs, so editing a profile
makes the affected phases run again and leaves the rest alone.

## Why is the TUI optional?

Because half of Fluxion's uses have no terminal: CI, image builds, containers,
provisioning scripts. The plain path is not a fallback, it is a first-class
mode — and both consume the same event stream, so they cannot drift.
