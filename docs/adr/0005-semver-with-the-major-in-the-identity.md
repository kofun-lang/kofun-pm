# 5. Semantic versioning, with the major version in the identity

Date: 2026-08-02 · Status: accepted · Closes the open question in ADR 1

## Context

[ADR 1](0001-minimal-version-selection.md) chose minimal version selection and
left one thing open: MVS assumes backward compatibility within a major line,
because it will select a higher version to satisfy someone else. Something has
to say where that assumption stops.

Semantic versioning is the version *scheme* — `major.minor.patch`, where a
major bump means a breaking change. It is the right scheme and it is what this
repository uses.

But semver alone does not stop MVS, and this is the part that is easy to miss.
Given two requirements, `>= 1.5.0` and `>= 2.0.0`, the maximum is `2.0.0` —
and MVS would hand `2.0.0` to the package that asked for `1.5.0`, which is
precisely the breaking change the major bump was announcing. The rule "take
the maximum" has no idea that `2.0.0` is not a bigger `1.x`.

Two answers exist.

**Cargo's:** the resolver understands compatibility ranges and may select two
majors at once, linking both into the build. This works, and it costs a
resolver that reasons about ranges — which is the solver ADR 1 declined.

**Go's:** the major version is part of the module's identity. `.../mod` and
`.../mod/v2` are different modules. MVS never compares them because it never
sees them as the same thing, and both may be present because they *are* two
dependencies.

## Decision

Semantic versioning for versions. The major version is part of the identity.

A module at major 2 is a different module from the same code at major 1, and
they may coexist in one build. Within a major line, MVS selects the maximum
required `minor.patch` and its assumption — that a higher one is compatible —
is exactly what semver promises.

This falls out of [ADR 3](0003-url-identity.md) rather than being bolted on: a
package is identified by where it lives, and a major bump changes where it
lives. There is nothing new to teach the resolver, which is the point — the
resolver stays a maximum.

## Consequences

**The resolver does not grow.** No ranges, no compatibility reasoning, no
second selection mode. `seed/resolver/` gains a comparison over
`(major, minor, patch)` and a refusal when two requirements name different
majors of one module, and nothing else.

**A major bump is a rename, and is felt as one.** Every dependent must edit
its manifest to move. That is more friction than Cargo's automatic
range-widening, and it is the friction of a breaking change being breaking —
under MVS the alternative is not less friction but a silent upgrade across a
boundary the author declared.

**Two majors can be live at once.** `mod` v1 and `mod/v2` are two
dependencies, so a graph mid-migration builds. Their types are unrelated, so
passing a value from one to the other does not compile — which is correct and
is the same thing the major bump said.

**`0.x` is not covered by semver's promise** and is not covered here either. A
`0.x` version claims no compatibility, so MVS's assumption does not hold
inside it. The conservative reading — every `0.x` minor is its own
compatibility boundary — is the one to take, and it needs its own child before
`0.x` dependencies are supported rather than being decided by whatever the
comparison happens to do.

## What this does not settle

Whether a *published* version may ever be changed or withdrawn. Immutability
is a separate decision and belongs with publishing.
