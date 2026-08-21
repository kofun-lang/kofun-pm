# Roadmap

The unit of work is a bounded child: one reviewable change, one gate, one
honest boundary statement. Every lane names what it is blocked on.

| lane | first epics | blocked on |
|---|---|---|
| P1 resolution | MVS over known requirements, transitive requirements, the major-version boundary decision, `why`, and workspace members — **complete**; exact sparse-catalog membership and rough-graph acquisition are P4 | — |
| P2 manifest & lock | dependency surface, lock v1 resolution pinning, re-lock idempotence, and four named refusals — **landed**; v0.5.0 adds bounded lock-v2/store inspection, v0.6.0 adds strict metadata parsing plus the selected descriptor bijection, v0.8.0 compares one supplied catalog with every same-identity descriptor retained by one supplied lock, v0.10.0 proves one supplied requirements/lock/store rough graph and MVS result, and v0.11.0 binds its tool header to the exact current local tool closure, while the writer, manifest binding, resolver replay, and migration remain | [#14](https://github.com/kofun-lang/kofun-pm/issues/14), which supplies authenticated acquisition and graph construction; manifest binding remains [#5](https://github.com/kofun-lang/kofun-pm/issues/5) |
| P3 store | content-addressed layout, links/copy fallback, integrity verification, verified no-replace admission, concurrent winner rehash, and corrupt-winner non-overwrite — **landed**; v0.7.0 composes lock-named snapshots with the subsequent whole-store reverse scan, while complete-lock proof and affine same-handle use remain | [#14](https://github.com/kofun-lang/kofun-pm/issues/14), which puts lock v2 metadata/files in the store; native no-replace is [kofun#1578](https://github.com/kofun-lang/kofun/issues/1578) |
| P4 fetch | ADR 7 decides the static URL protocol, lock v2, explicit-fetch-only network authority, and no-replace semantics; v0.4.0 lands store admission, v0.5.0 bounded lock/store inspection, v0.6.0 strict metadata/selected-descriptor inspection, v0.7.0 a sequential two-way audit for one supplied lock/store, v0.8.0 strict supplied authority/catalog structure plus continuity against one lock's recorded descriptors, v0.9.0 exact catalog-descriptor binding for one supplied metadata document, v0.10.0 exact supplied requirements/lock/store rough-graph and MVS equality, and v0.11.0 exact current local tool-closure binding, while live authenticated acquisition, file blobs, manifest binding, writer/migration, same-handle handoff, and offline build gate remain | [#14](https://github.com/kofun-lang/kofun-pm/issues/14); Kofun inputs are [#1258](https://github.com/kofun-lang/kofun/issues/1258), [#1264](https://github.com/kofun-lang/kofun/issues/1264), [#1499](https://github.com/kofun-lang/kofun/issues/1499), [#1551](https://github.com/kofun-lang/kofun/issues/1551), [#1577](https://github.com/kofun-lang/kofun/issues/1577), and [#1578](https://github.com/kofun-lang/kofun/issues/1578) upstream |
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
