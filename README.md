# kofun-pm

Package manager for the [Kofun](https://github.com/hjosugi/kofun) language.

The language already has the pieces: `kofun.toml` selects a package root,
`kofun.packages.lock` pins artifacts by `sha256`, re-locking is idempotent, and
offline use is tested. This repository is the resolver, the store, and the
verification discipline built on top — and the decisions it makes are the point
of it.

## Four decisions, each with what it costs

### 1. Minimal version selection, not a solver

npm and Cargo resolve by search: a solver explores the version space, and when
it fails you get a conflict report that requires understanding the solver.
Go selects the **maximum of the required versions**, per module, and stops.

There is no backtracking, no conflict, and no heuristic. The answer is a
function of the requirement set, so the same inputs give the same output on
every machine and in every order — and the algorithm is small enough to be
written in the language's own executable slice and proven by a gate, which is
exactly what `seed/resolver/` does.

**The cost:** you get the *lowest* version that satisfies everyone, so a
project does not silently drift onto a newer dependency the day it is
published. That is a cost only if you wanted the drift.

### 2. One copy on disk, addressed by content

pnpm's insight: a package version is immutable, so its bytes are its name.
Every artifact lands in a store under its `sha256`, and a project's dependency
directory is links into that store.

Ten projects on one machine sharing a dependency store ten copies of nothing.
More importantly, a store keyed by digest makes "is this the artifact the lock
promised" a question you can answer without a network.

**The cost:** the store is global state, so it needs its own integrity check.
`kpm verify` is that check, and it is a gate rather than a subcommand nobody
runs.

### 3. Everything is pinned by digest, including the resolution

`go.sum` pins artifacts. The lock here pins the artifacts *and* the resolution
that produced them, so re-resolving from the same manifest is a check rather
than a hope: same manifest → same lock, byte-identical, which the gate proves
by doing it twice.

**The cost:** a lock is bigger and more boring to read. Both are fine.

### 4. No install scripts. Ever.

This is the one that is not a trade-off.

npm's `postinstall` is how a package runs arbitrary code on your machine
because you typed a name. It is the mechanism behind essentially every
JavaScript supply-chain incident, and every mitigation since has been a way to
partially disable it.

kofun-pm has no hook that runs during install, because there is nothing to
disable. A package is source and data. Building it is `kofun build`, which the
language already gates, and which happens when *you* build — not when you add
a dependency.

**The cost:** a package cannot do native setup at install time. Packages that
need a compiled artifact declare it as a build target, so the work happens
inside the build system that already has a contract, instead of inside a shell
script that has none.

## What exists today, honestly

`seed/resolver/` is the executable evidence: minimal version selection in the
language's Stage 2 slice, running identically on the reference executor and
the C11 backend, under a hostile `TZ`, locale, and `env -i`.

It is the algorithm, not the plumbing — the store, the fetcher, and the CLI
are the lanes in [docs/ROADMAP.md](docs/ROADMAP.md), each saying what it is
blocked on. Nothing here claims a network is implemented.

```sh
git clone --recurse-submodules https://github.com/hjosugi/kofun-pm
cd kofun-pm
sh scripts/dev.sh          # the resolver's unit suite and its gate
```

## Learning from, and the line drawn

| source | taken | left |
|---|---|---|
| [Go modules](https://go.dev/ref/mod) | minimal version selection; URL-as-identity; a checksum file | the module proxy as a required intermediary |
| [pnpm](https://pnpm.io/) | the content-addressed store; strict layout with no phantom dependencies | a `node_modules` shape to be strict *about* |
| [Cargo](https://doc.rust-lang.org/cargo/) | the manifest and lock ergonomics; workspaces; `test`/`bench`/`doc` as first-class | resolution by solver |
| [npm](https://www.npmjs.com/) | the ecosystem's lesson about what one wrong default costs | lifecycle scripts, in every form |
| [bun](https://bun.sh/) | install speed as a real feature, not a nicety | a binary lockfile a human cannot read in a review |

## License

Apache-2.0 OR MIT, matching the language.
