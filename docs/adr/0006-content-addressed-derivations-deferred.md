# 6. Content-addressed derivations, deferred

Date: 2026-08-08 · Status: deferred, with the conditions below

## Context

[ADR 4](0004-input-addressed-derivations.md) named a build output by the digest
of its complete input closure, and named its own cost:

> Changing a comment in a dependency changes its derivation digest and rebuilds
> everything downstream, even though the output is identical.

Content-addressed derivations are the answer to that. The *output's* digest
names the result, so when a rebuilt dependency produces byte-identical output
the cascade stops there — Nix calls this early cutoff, and for a deep graph it
is the difference between rebuilding one package and rebuilding everything that
depends on it.

[P8](https://github.com/kofun-lang/kofun-pm/issues/6) asks for the reasoning to
be written before any of it is built. This is that, and it concludes: **not
yet**, for reasons that are about sequencing rather than about the idea.

## What content-addressing actually requires

The output digest is not knowable from the inputs. That is the whole point —
if it were derivable, it would carry no information input-addressing does not
already have. So it has to be *recorded*: a mapping from an input closure to
the output digest it produced.

```
realisation:  digest(input closure)  ->  digest(output)
```

That mapping is the entire difficulty, and it is worth being exact about why.
It cannot be computed without building, so anyone who has not built must either

- **trust** someone's claim that this closure realises to that output, or
- **verify** it by building — which is the work early cutoff exists to avoid.

Trusting it reintroduces precisely what ADR 4 removed. Under input-addressing a
cache hit *means* every input matched; there is nothing to sign for
correctness, and signing is reduced to a question about who may publish. Under
content-addressing a cache hit means someone asserted a realisation, and the
assertion is a thing that can be wrong.

## Why the trade is different here than in Nix

Two ways, pulling in opposite directions.

**In our favour: verification is sound.** Nix cannot fully lean on "verify by
rebuilding" because its builds are not reliably bit-reproducible — C compilers
embed paths and timestamps, and Nix's sandbox reduces that rather than
eliminating it. Kofun has no ambient authority, so a rebuild is bit-identical
by construction; this repository already proves that discipline for the
resolver under a hostile `TZ`, a hostile locale and `env -i`. A realisation
claim here is *checkable by anyone, exactly*, which is a materially stronger
position than Nix's and means the trust could be made optional rather than
structural.

**Against: the benefit is proportional to a graph we do not have.** Early
cutoff pays when a cascade is expensive. There is no fetch, no build
integration ([P7](https://github.com/kofun-lang/kofun-pm/issues/6)), no cache
and no dependency graph deeper than the fixtures in `seed/derivation/`. The
cost ADR 4 accepted is currently zero, because there is nothing downstream to
rebuild.

Adopting content-addressing now would add a mapping that must be stored,
invalidated, and reasoned about — to remove a cost nobody has yet paid.

## Decision

Deferred. Input-addressing stands, and this ADR exists so that the successor is
a decision rather than a drift.

It becomes worth revisiting when **all four** of these hold. Fewer than four is
not a partial case for it; each one removes a specific reason this is premature.

1. **There is a cascade.** P7 lands and dependencies reach `kofun build`, so a
   rebuild propagates through something deeper than a fixture.

2. **The cascade has been measured.** This repository does not publish a number
   it has not measured, and the same rule applies to a cost. "Input-addressing
   rebuilds too much" is a claim, and until someone records how often an
   unchanged output follows a changed input, it is an unmeasured one. If the
   answer is "rarely", the mapping is complexity bought for nothing.

3. **The realisation is verified, not trusted.** The design must let any party
   confirm a claimed realisation by rebuilding and comparing bytes, and must
   treat an unverified claim as unverified — not as a hit. Kofun's determinism
   is what makes this possible; a design that reaches for signatures instead
   has given back what ADR 4 bought.

4. **The digest is real.** `seed/derivation/` folds with a modular polynomial
   because `Bytes` is not usable in the executable slice. That fold is honestly
   labelled a projection, and it is adequate for proving order-independence,
   completeness and transitivity — but a realisation mapping keyed on it would
   be a cache keyed on a projection. sha256 first.

## Consequences

**The known cost stays.** A comment in a dependency rebuilds its dependents.
That is the price of a cache hit meaning what it says, and it is paid until the
four conditions hold.

**The successor is named twice now.** ADR 4 named it rather than pretending the
issue was absent; this names what would have to be true. Neither is a
commitment to build it.

**If the conditions are met and the answer is still no, that is a decision
too,** and it supersedes this file rather than leaving it silently stale. The
measurement in condition 2 is the most likely source of that outcome, which is
why it is a condition rather than a step during implementation.
