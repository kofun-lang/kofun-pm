# Roadmap

The unit of work is a bounded child: one reviewable change, one gate, one
honest boundary statement. Every lane names what it is blocked on.

| lane | first epics | blocked on |
|---|---|---|
| P1 resolution | MVS core, transitive requirements, the major-version boundary decision, `why`, and workspace members — **complete** | — |
| P2 manifest & lock | dependency surface, lock format v1 pinning the resolution, re-lock idempotence and the three refusals — **landed**; artifacts wait on P4, which is what there is to pin | the language's `kofun.packages.lock` already pins by sha256 — this extends it |
| P3 store | content-addressed layout, links with a copy fallback, and `verify` as a gate — **landed**; "every lock entry is present" waits on P4, which is what puts entries there | — |
| P4 fetch | source identity (URL, the Go move) vs a registry; integrity on arrival; offline as the default rather than a flag | the identity decision, which is its own ADR |
| P5 cli | `kpm add/lock/verify/tree/why`; the explanation itself is **landed** in `seed/resolver/`, so P5 binds a command to it rather than deciding what it should say | P1, P2 |
| P6 publishing | who may publish a name; signing; immutability of a published version | P4's identity decision |
| P7 build integration | dependencies reaching `kofun build`; the build-target answer to what install scripts used to do | the language's build system contract |

## Sequencing

```
now ──► P1 resolution + P2 manifest/lock     (pure, unblocked, the identity of the tool)
     ──► P3 store + P4 fetch                 (once identity is decided)
     ──► P5 cli
later ─► P6, P7
```

## What is deliberately not here

No registry service. Whether Kofun needs one, or whether source identity by
URL is enough as it was for Go, is an open decision — and building a registry
before making it would answer it by accident.
