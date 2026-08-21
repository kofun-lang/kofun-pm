# Roadmap

The unit of work is a bounded child: one reviewable change, one gate, one
honest boundary statement. Every lane names what it is blocked on.

| lane | first epics | blocked on |
|---|---|---|
| P1 resolution | MVS over known requirements, transitive requirements, the major-version boundary decision, `why`, and workspace members — **complete**; exact sparse-catalog membership and rough-graph acquisition are P4 | — |
| P2 manifest & lock | dependency surface, lock format v1 pinning the resolution, re-lock idempotence and four named refusals — **landed**; artifact rows remain | [#14](https://github.com/kofun-lang/kofun-pm/issues/14), which defines what there is to pin |
| P3 store | content-addressed layout, links/copy fallback, integrity verification, verified no-replace admission, concurrent winner rehash, and corrupt-winner non-overwrite — **landed**; lock completeness and affine same-handle use remain | [#14](https://github.com/kofun-lang/kofun-pm/issues/14), which puts lock v2 metadata/files in the store; native no-replace is [kofun#1578](https://github.com/kofun-lang/kofun/issues/1578) |
| P4 fetch | static URL catalog/metadata/blob protocol, lock v2, explicit-fetch-only network authority, and no-replace store semantics are **decided** in ADR 7; the store-admission sub-slice is **landed** in v0.4.0, while acquisition, lock v2, same-handle handoff, and offline gate remain | [#14](https://github.com/kofun-lang/kofun-pm/issues/14); Kofun inputs are [#1258](https://github.com/kofun-lang/kofun/issues/1258), [#1264](https://github.com/kofun-lang/kofun/issues/1264), [#1499](https://github.com/kofun-lang/kofun/issues/1499), [#1551](https://github.com/kofun-lang/kofun/issues/1551), [#1577](https://github.com/kofun-lang/kofun/issues/1577), and [#1578](https://github.com/kofun-lang/kofun/issues/1578) upstream |
| P5 cli | `kpm add/fetch/lock/verify/tree/why`; the explanation itself is **landed** in `seed/resolver/`, so P5 binds commands to native actions rather than deciding what they should say | [kofun#1551](https://github.com/kofun-lang/kofun/issues/1551), general native CLI action binding |
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
deprecation, and revocation have no central authority. ADR 7 defines how a
version at that identity yields digest-pinned metadata and bytes without
quietly creating a registry under another name; P4 now has to implement and
gate that contract.
