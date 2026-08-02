# 4. A build output is named by its complete inputs

Date: 2026-08-02 · Status: accepted

## Context

[ADR 3](0003-url-identity.md) settles what a *package* is. This settles what a
*build* is.

Go stops at fetch reproducibility: `go.sum` pins the bytes that arrived, and
what happens afterwards is the build system's business. Nix goes further — a
derivation is a pure function from its inputs to its outputs, and the output
is named by a hash of *every* input: sources, dependencies, the compiler, the
build settings. Same inputs, same output path, on every machine.

That property is worth much more than a lockfile, because it makes a binary
cache safe by construction: a cache hit is only possible when every input
matched, so there is no way to serve the wrong artifact by accident.

## The reason this is cheaper here than in Nix

Nix needs a sandbox. It builds C, and C builds read the clock, the
environment, `/usr`, the network, and whatever else they find — so Nix has to
construct an environment where they cannot, and its sandbox is a large part of
what Nix *is*.

Kofun does not have that problem. The language has no ambient authority: there
is no `now()`, no ambient file handle, no global allocator; a clock is an
affine handle, time-zone rules are injected bytes, the environment is a
capability. A Kofun build cannot reach the things a sandbox exists to hide,
because nothing in the language can name them.

So we get Nix's central property without Nix's central mechanism. The
sandbox's job is already done by the type system.

## Decision

A build output is identified by the digest of its complete input closure:

```
derivation = digest(
    sorted( source digest, each dependency's derivation digest ),
    toolchain digest,
    build settings digest
)
```

Three properties follow, and `seed/derivation/` proves each of them in the
language's own executable slice rather than asserting them:

1. **Order-independence.** Inputs are put in canonical order before folding —
   by a sorting network, whose comparison count does not depend on the values,
   so the same set in any order gives the same identity. This is the same
   discipline the resolver uses for the same reason.
2. **Completeness.** Changing any input — a source byte, a dependency, the
   toolchain, a setting — changes the identity. An input that could change
   without changing the identity is an input the cache would ignore, which is
   exactly how a cache serves the wrong thing.
3. **Transitivity.** A dependency contributes its *derivation* digest, not its
   source digest, so a change deep in the graph reaches every dependent. A
   scheme that hashed only direct sources would let a rebuilt dependency go
   unnoticed.

## Consequences

**A binary cache is safe without trust.** A cache hit means every input
matched. There is nothing to sign for correctness — signing becomes a question
about *who may publish*, not about whether the artifact is right.

**Builds are diffable.** "Why did this rebuild" is answered by comparing two
input closures, and the answer names the input that moved rather than
describing a heuristic.

**The cost: everything must be in the closure, including the toolchain.** A
build that depends on something unhashed is a build whose cache can be wrong,
so the toolchain digest is not optional and neither are build settings. That
is more bookkeeping than a conventional build system needs, and it is the
whole price of the property.

**The second cost: input-addressing rebuilds more than content-addressing.**
Changing a comment in a dependency changes its derivation digest and rebuilds
everything downstream, even though the output is identical. Nix has the same
issue and answers it with content-addressed derivations, which are a later and
much harder decision; this ADR chooses the simpler scheme and names the
successor rather than pretending the issue is absent.
