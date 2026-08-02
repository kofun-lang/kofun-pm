# kofun-pm

Package manager for the [Kofun](https://github.com/hjosugi/kofun) language.

The language already has the pieces: `kofun.toml` selects a package root,
`kofun.packages.lock` pins artifacts by `sha256`, re-locking is idempotent, and
offline use is tested. This repository is the resolver, the store, and the
verification discipline built on top — and the decisions it makes are the point
of it.

## Five decisions, each with what it costs

A package is identified by **where it lives** — a URL, as in Go. There is no
registry and none is planned; the question "who owns this name" has the same
answer as "who controls this host". [ADR 3](docs/adr/0003-url-identity.md)
records what that costs, including the one it does not solve: revocation has
nowhere to live.

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

### 3. A build output is named by its complete inputs

Go stops at fetch reproducibility: `go.sum` pins the bytes that arrived, and
what happens next is the build system's business. Nix goes further — a build
output is named by a hash of *every* input, so a binary cache hit is only
possible when every input matched, and there is nothing to trust.

**We get Nix's property without Nix's mechanism.** Nix needs a sandbox because
C builds read the clock, the environment, `/usr`, and the network, so it must
construct a place where they cannot. Kofun has no ambient authority: there is
no `now()`, no ambient file handle, no global allocator. A build cannot reach
what a sandbox exists to hide, because nothing in the language can name it.

The sandbox's job is already done by the type system.

`seed/derivation/` proves the three properties this rests on — order
independence, completeness, and transitivity — in the language's own slice.
Breaking each one fails the test named for it: dropping the toolchain from the
closure fails `test_changing_the_toolchain_changes_the_identity`, folding
inputs unsorted fails the two order tests, and letting a dependency contribute
its source instead of its derivation fails three at once.

**The cost:** everything must be in the closure, including the toolchain and
the build settings, which is more bookkeeping than a conventional build needs.
And input-addressing rebuilds more than content-addressing would — a comment
change in a dependency rebuilds its dependents even though the output is
identical. Nix has the same issue; the successor is content-addressed
derivations, which is a later and harder decision, named in
[ADR 4](docs/adr/0004-input-addressed-derivations.md) rather than ignored.

### 4. Everything is pinned by digest, including the resolution

`go.sum` pins artifacts. The lock here pins the artifacts *and* the resolution
that produced them, so re-resolving from the same manifest is a check rather
than a hope: same manifest → same lock, byte-identical, which the gate proves
by doing it twice.

**The cost:** a lock is bigger and more boring to read. Both are fine.

### 5. No install scripts. Ever.

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

Two seeds are executable evidence, both in the language's Stage 2 slice and
both running identically on the reference executor and the C11 backend, under
a hostile `TZ`, locale, and `env -i`:

- `seed/resolver/` — minimal version selection, with order-independence read
  out of the recorded output rather than asserted;
- `seed/derivation/` — input-addressed identity, with the three properties a
  safe binary cache rests on.

It is the algorithm, not the plumbing — the store, the fetcher, and the CLI
are the lanes in [docs/ROADMAP.md](docs/ROADMAP.md), each saying what it is
blocked on. Nothing here claims a network is implemented.

```sh
git clone --recurse-submodules https://github.com/hjosugi/kofun-pm
cd kofun-pm
sh scripts/dev.sh          # 21 unit tests across two seeds, and the gate
```

## Learning from, and the line drawn

| source | taken | left |
|---|---|---|
| [Go modules](https://go.dev/ref/mod) | minimal version selection; URL-as-identity; a checksum file | stopping at fetch reproducibility — the build's inputs are hashed too |
| [Nix](https://nixos.org/) | a build output named by its complete input closure; reproducibility as an identity, not a promise | the sandbox, which the language makes unnecessary |
| [pnpm](https://pnpm.io/) | the content-addressed store; strict layout with no phantom dependencies | a `node_modules` shape to be strict *about* |
| [Cargo](https://doc.rust-lang.org/cargo/) | the manifest and lock ergonomics; workspaces; `test`/`bench`/`doc` as first-class | resolution by solver |
| [npm](https://www.npmjs.com/) | the ecosystem's lesson about what one wrong default costs | lifecycle scripts, in every form |
| [bun](https://bun.sh/) | install speed as a real feature, not a nicety | a binary lockfile a human cannot read in a review |

## License

Apache-2.0 OR MIT, matching the language.
