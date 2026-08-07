# kofun-pm

Package manager for the [Kofun](https://github.com/kofun-lang/kofun) language.

The language already has the pieces: `kofun.toml` selects a package root,
`kofun.packages.lock` pins artifacts by `sha256`, re-locking is idempotent, and
offline use is tested. This repository is the resolver, the store, and the
verification discipline built on top — and the decisions it makes are the point
of it.

## kpm is one file

The language's CLI framework writes a Linux x86-64 ELF **directly** — no C
compiler, no assembler, no linker and no shell in the application build, and
no libc or dynamic loader at run time. Measured, and asserted by the gate on
every run:

```
size: 4721 bytes
ELF 64-bit LSB executable, x86-64, statically linked
not a dynamic executable
```

That matters more for a package manager than for most tools. It is the first
thing a person installs and the thing they install everything else with; one
that is a single dependency-free file can be fetched by digest, mirrored
anywhere, and run on a machine with nothing else on it. Compare what the
alternatives need before they can resolve one dependency: cargo is a
multi-megabyte toolchain component, npm needs a Node runtime, bun ships around
ninety megabytes.

**The commands are not bound yet.** `contracts/kpm-cli.kofun` declares the
surface and the gate requires it to keep failing at the compiler boundary,
because the framework's action set is four fixed contracts and its reference
says so plainly. The restriction is tighter than it reads: an action fixes its
option *names*, so a surface cannot be declared even around placeholder
actions. That is issue #7. This repository does not ship a CLI whose commands
do nothing.

## Seven decisions, each with what it costs

A package is identified by **where it lives** — a URL, as in Go. There is no
registry and none is planned; the question "who owns this name" has the same
answer as "who controls this host". [ADR 3](docs/adr/0003-url-identity.md)
records what that costs, including the one it does not solve: revocation has
nowhere to live.

### 1. Semantic versioning, with the major in the identity

`major.minor.patch`, and a major bump changes where the package lives — Go's
answer, which falls out of URL identity rather than being bolted on.

This is needed because **semver alone does not stop MVS**. Given `>= 1.5.0`
and `>= 2.0.0` the maximum is `2.0.0`, and MVS would hand that to the package
that asked for `1.5.0` — precisely the breaking change the major bump was
announcing. Putting the major in the identity means the resolver never
compares them, so it stays a maximum instead of growing a compatibility mode.

**The cost:** a major bump is a rename and is felt as one. Every dependent
edits its manifest to move. Under MVS the alternative is not less friction but
a silent upgrade across a boundary the author declared.
[ADR 5](docs/adr/0005-semver-with-the-major-in-the-identity.md), including why
`0.x` needs its own decision.

### 2. Minimal version selection, not a solver

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

**What it buys, beyond reproducibility:** the selection is explainable, and the
explanation is checkable against the answer.

These are lines 170 and 171 of `seed/resolver/resolver.stdout`, written by the
resolver rather than composed for this page:

```
why 10: v5, because 20 requires >= 5
  1 bound agreed; 1 other bound did not decide the answer
```

That distinction is newer than it looks. The wording used to be assembled by
the gate, in `awk`, out of the seven integers a `Why` was printed as — because
the language's executable slice took `Int` in and gave `Int` out. A gate cannot
check a sentence it wrote itself, so the one output a user actually reads was
the one thing here that nothing pinned. `Text` results and `to_text(Int)` are
in the slice now, so `render_why` is an ordinary function of a `Why`, the unit
suite asserts it byte for byte, and the gate reads it. Both recordings are kept
and held against each other: a sentence that drifted from the fields it renders
would be a confident wrong answer to the question a lock diff asks.

The gain is not only tidiness. Two refusals used to share one integer — kind 3
covered both "nobody publishes it" and "you asked above everything published",
which send a reader to two different fixes. Words tell them apart; a kind
cannot.

A solver's answer to "why this version?" is a history — these constraints were
tried, this one was relaxed, this assignment survived — so explaining it means
replaying the search, and the explanation is as long as the work was. Under MVS
the selection *is* one of the inputs, so the explanation is a lookup, and it is
complete: every other bound is below the one named, which is what "maximum"
means.

Two details keep it honest. **Ties are reported**, because an explanation naming
one of two equal bounds would imply that removing it lowers the selection.
And **the named requirer does not depend on slot order** — it is the smallest
requirer code among those at the maximum, not the first one found, so the
explanation is a function of the requirement set exactly as the selection is.
The gate has a tie arranged with the larger code first, which is the only
arrangement in which those two rules disagree.

### 3. A workspace member is a package, and is not a dependency

Two rules that pull in opposite directions, so both are stated:

**A member's requirements join the set.** As far as its own dependencies go a
member is an ordinary package, so a bound it states raises the selection for
whatever it names. This needs no new algorithm — `max` is associative, so one
more set is one more `larger`. A solver would need the members in its search
space.

**A member is never fetched.** As a *dependency* it is not a package at all: it
is the source tree on disk. So `Member` is its own outcome rather than a
`Selected` with a special version — a member has no selected version, and
reporting one would invite a lock to pin a local path, which is a lock that is
wrong on every other machine.

Membership is decided **before the registry is consulted**, and that ordering is
the rule rather than an implementation detail: a member that shares a name with
something published must resolve to the local tree. Were the registry asked
first, publishing a package could quietly take over a name the workspace owns.
The gate checks a member that *is* published (and must not resolve to v3) and
one that is published nowhere (and must not be `Unpublished`).

### 4. One copy on disk, addressed by content

pnpm's insight: a package version is immutable, so its bytes are its name.
Every artifact lands in a store under its `sha256`, and a project's dependency
directory is links into that store.

Ten projects on one machine sharing a dependency store ten copies of nothing.
More importantly, a store keyed by digest makes "is this the artifact the lock
promised" a question you can answer without a network.

**The cost:** the store is global state, so it needs its own integrity check.
`kpm verify` is that check, and it is a gate rather than a subcommand nobody
runs.

### 5. A build output is named by its complete inputs

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

### 6. Everything is pinned by digest, including the resolution

`go.sum` pins artifacts. The lock here pins the artifacts *and* the resolution
that produced them, so re-resolving from the same manifest is a check rather
than a hope: same manifest → same lock, byte-identical, which the gate proves
by doing it twice.

**The cost:** a lock is bigger and more boring to read. Both are fine.

### 7. No install scripts. Ever.

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

- `seed/resolver/` — minimal version selection over semver, with
  order-independence, transitive monotonicity, and the major-mismatch refusal
  read out of the recorded output rather than asserted; and `why`'s
  explanation now written in Kofun rather than assembled by the gate;
- `seed/derivation/` — input-addressed identity, with the three properties a
  safe binary cache rests on.

It is the algorithm, not the plumbing — the store, the fetcher, and the CLI
are the lanes in [docs/ROADMAP.md](docs/ROADMAP.md), each saying what it is
blocked on. Nothing here claims a network is implemented.

The tooling around the seeds is still shell, and that is a boundary the
language sets rather than a preference: each piece moves into Kofun as the
slice widens, and the explanation is the first piece to have moved. The gate
checks the property rather than the implementation, so a move does not change
what the gate claims — only who is making the claim.

```sh
git clone --recurse-submodules https://github.com/kofun-lang/kofun-pm
cd kofun-pm
sh scripts/dev.sh          # 52 unit tests across two seeds, and the gate
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
