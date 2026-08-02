# 3. A package is identified by where it lives

Date: 2026-08-02 · Status: accepted · Closes the decision in issue #4

## Context

Two answers were open. A **registry name** (npm, Cargo): a service owns the
namespace and hands out short names. A **URL** (Go): identity and location are
the same thing, and there is no service.

## Decision

URL identity. There is no registry, and none is planned.

A dependency is named by where it lives. Nothing has to be running for a name
to mean something, nothing can be lost when a service is, and there is no
namespace to squat, transfer, or dispute — the question "who owns this name"
has the same answer as "who controls this host", which is a question the world
already has infrastructure for.

## Consequences

**Mirroring and vendoring stop being special.** Under a registry they are
workarounds for the registry; here they are ordinary, because a mirror is just
another URL and a vendor directory is just a local one.

**Short names are lost.** `serde` becomes something longer. Go traded the same
thing and the trade held; a project that wants short names can alias them in
its own manifest, where the alias is visible to whoever reads it rather than
resolved by a service they cannot see.

**Discovery, deprecation and revocation have nowhere to live.** This is the
real cost and it is not solved by this ADR. A registry is where "this version
is compromised, stop using it" would go, and without one that message travels
the way it travels for any URL — badly. The mitigation is that
[ADR 4](0004-input-addressed-derivations.md) makes every dependency's exact
bytes part of a build's identity, so *finding out* what you built against is
always possible even when *being told* is not. Detection is not prevention and
this ADR does not pretend otherwise.

**Availability becomes the host's problem.** A dependency whose host is gone
is gone, unless it was vendored or is in a store. Because the store is
content-addressed and offline is the default rather than a flag, "still builds
after the host disappeared" is the normal case rather than a recovery
procedure — but only for artifacts already fetched.

## What this forecloses

A cache that quietly becomes authoritative. The failure mode named in issue #4
was a registry sold as "just a cache" that everything ends up depending on;
choosing URL identity outright means there is no service whose outage is
anyone's problem but its own host's.
