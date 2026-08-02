# 2. No install scripts. Ever.

Date: 2026-08-02 · Status: accepted

## Context

npm packages may declare `preinstall`, `install`, and `postinstall` hooks that
run arbitrary code on the machine of anyone who adds a dependency — including
transitively, for packages nobody chose. It is the mechanism behind
essentially every JavaScript supply-chain incident, and every mitigation since
has been a way to partially disable it: `--ignore-scripts`, allow-lists,
sandboxes, "only for direct dependencies".

Each of those is evidence that the default was wrong and could not be removed.

## Decision

There is no hook that runs during install, because there is nothing to
disable.

A package is source and data. Adding a dependency copies bytes into a store
and links them; it does not execute anything. Building is `kofun build`, which
happens when the developer builds, inside a build system that already has a
contract and a gate.

## Consequences

`kpm add` cannot compromise a machine, which means it does not need a
sandbox, an allow-list, or a flag to make it safe. The absence is the feature,
and it is worth more than any mitigation of the presence.

**The cost:** a package cannot do native setup at install time. A package that
needs a compiled artifact declares it as a build target, so the work happens
where the build system can see it rather than inside a shell script that runs
before anyone has looked at the package.

This forecloses a real convenience. Native bindings that "just work" after
`npm install` do so because something ran; here the equivalent is a build
target that the build system schedules, caches, and can refuse. That is more
work for a package author and less risk for everyone downstream, and the trade
is deliberate.

**What this ADR does not claim:** that kofun-pm is therefore secure. It closes
one mechanism. Fetch integrity, publishing identity, and what a *build* is
permitted to reach are separate decisions with their own ADRs to write.
