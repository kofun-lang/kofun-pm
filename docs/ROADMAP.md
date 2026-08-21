# Roadmap

The unit of work is a bounded child: one reviewable change, one gate, one
honest boundary statement. Every lane names what it is blocked on.

| lane | first epics | blocked on |
|---|---|---|
| P1 resolution | MVS core, transitive requirements, the major-version boundary decision, `why`, and workspace members — **complete** | — |
| P2 manifest & lock | dependency surface, lock format v1 pinning the resolution, re-lock idempotence and four named refusals — **landed**; artifact rows remain | [#14](https://github.com/kofun-lang/kofun-pm/issues/14), which defines what there is to pin |
| P3 store | content-addressed layout, links with a copy fallback, and `verify` as a gate — **landed**; "every lock entry is present" remains | [#14](https://github.com/kofun-lang/kofun-pm/issues/14), which puts artifacts in the store |
| P4 fetch | URL identity is **decided** in ADR 3; the version-to-artifact contract, integrity on arrival, atomic visibility, and offline-by-default gate remain | [#14](https://github.com/kofun-lang/kofun-pm/issues/14); Kofun inputs are [#1258](https://github.com/kofun-lang/kofun/issues/1258) and [#1499](https://github.com/kofun-lang/kofun/issues/1499) upstream |
| P5 cli | `kpm add/lock/verify/tree/why`; the explanation itself is **landed** in `seed/resolver/`, so P5 binds a command to it rather than deciding what it should say | [kofun#1551](https://github.com/kofun-lang/kofun/issues/1551), general native CLI action binding |
| P6 publishing | what a URL host publishes; signing; immutability of a published version | P4's artifact contract in #14 |
| P7 build integration | dependencies reaching `kofun build`; the build-target answer to what install scripts used to do | the language's build system contract |

## Sequencing

```
now ──► P1 resolution + P2 manifest/lock + P3 store   (landed foundations)
     ├─► P4 fetch contract and implementation         (#14)
     └─► P5 cli binding                               (upstream #1551)
later ─► P6, P7
```

## What is deliberately not here

No registry service. ADR 3 chose URL identity and records its cost: discovery,
deprecation, and revocation have no central authority. P4 defines how a version
at that identity yields immutable metadata and bytes without quietly creating
a registry under another name.
