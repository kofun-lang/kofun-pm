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
actions. Binding them is [P5](https://github.com/kofun-lang/kofun-pm/issues/5),
and it waits on the framework's
[arbitrary-action contract](https://github.com/kofun-lang/kofun/issues/1551)
rather than on this repository. `kpm` does not ship a CLI whose commands do
nothing.

## Nine decisions, each with what it costs

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
runs — a store whose integrity is only checked when someone remembers is a
store whose integrity is unknown.

The path is the digest and nothing else — no name, no version, no registry:

```
<store>/a5/bc10ba19896ce54253d4facc8b60237311bad53c9434f03049a7232179046f
```

so the same bytes under two names are one entry, and the store's integrity does
not depend on metadata the bytes do not carry.

**Entries are read-only, and that is not tidiness.** A hard link is the same
inode, so a writable entry is a file any project can edit *in place* —
corrupting the dependency for every other project on the machine, silently,
with no copy left to compare against. `verify` reports a writable entry before
it has become corruption, because that is the condition under which corruption
happens without anyone doing anything wrong.

Corruption is **named**, not counted:

```
store: CORRUPT <store>/a5/bc10ba…
  expected a5bc10ba19896ce54253d4facc8b60237311bad53c9434f03049a7232179046f
  actual   92e78d0b032962f47792a9fa95fd981ef63e1e3ef074d536d6304c75eddbe29f
```

"The store is corrupt" tells an operator to delete all of it. This tells them
which artifact to fetch again.

Links are hard links; the copy is the path taken across filesystems and on
filesystems without hard links at all. `KPM_NO_HARDLINK=1` forces it, because a
fallback that is never exercised is a fallback nobody knows is broken — the
gate takes both paths on every run.

Store location is explicit: the shell adapter requires `--store` and does not
derive mutation authority from `HOME`, `XDG_CACHE_HOME`, or `KPM_STORE`.
Admission copies into a unique temporary beside the final entry, checks the
declared size and SHA-256, and uses a hard link for atomic create-if-absent
publication. One of eight barrier-synchronized publishers wins; every loser
rehashes and adopts that winner. A corrupt winner is named and never replaced.
Lookup, link, and copy paths rehash before use, and a materialized destination
is rehashed again.

v0.7.0 composes the two released read-only directions for one explicit lock
and store without calling the result complete `kpm verify`:

```
scripts/lock-v2.sh audit-store LOCK --store /absolute/store
```

It first runs the lock-scoped inspection so a named failure retains package,
version, and logical-path context. Only after that succeeds does it enumerate
the whole explicit store, rejecting malformed, corrupt, writable, special, or
interrupted entries. The first pass's success is withheld until the second
passes. A valid unreferenced object is allowed: a global content-addressed
store is shared by locks rather than an exact projection of one lock. The gate
also runs this action with network-command sentinels and hostile proxy/home
state, and proves that neither input's bytes, paths, types, links, or modes
change.

v0.8.0 adds the first catalog-side read-only checkpoint for one explicitly
supplied identity:

```
scripts/catalog-v1.sh inspect IDENTITY CATALOG --authority AUTHORITY
scripts/catalog-v1.sh inspect IDENTITY CATALOG --authority AUTHORITY --history-lock LOCK
```

It snapshots one bounded catalog and authority file, derives the identity's
exact HTTPS origin with the shared URL grammar, validates every strict sorted
row, and requires that origin to be explicitly listed. With a history lock it
reuses the complete lock-v2 envelope/body parser and compares every selected
and superseded metadata descriptor for that identity. A missing locked version
is a withdrawal/history violation; changed size or digest is an immutability
violation; a catalog row not represented in that one lock is allowed. Without
a matching lock row, success is named first observation rather than history.
The action remains offline and read-only under hostile proxy and home state.

**What is not here yet:** a *complete* lock that enumerates every required
rough-graph input still needs the lock v2 writer, live catalog/metadata/blob
acquisition and authentication, graph binding, and fetch. For a supplied
structurally valid v2 lock, the
inspector proves that every metadata and selected-file object directly named
by its rows exists with the declared bytes; `audit-store` additionally proves,
in a later sequential pass, that every enumerated store entry hashes to its
name. Neither proves that the rough graph omitted no row, exact lock/store set
equality, a bounded or atomic global snapshot, or the affine handoff of the
same open file description. This is not a claim that the complete store/fetch
boundary is finished.

### 5. Fetch is explicit; everything after it is offline

A package URL serves a bounded static catalog, digest-pinned metadata, and
source/data file blobs. `kpm fetch` is the only operation allowed to contact
those endpoints, and it requires an explicit approved-origin authority file.
It verifies metadata and every file before writing lock v2;
`lock`, `verify`, resolution, and build have no network mode at all.

The P4 implementation will make files arrive individually by digest rather
than inside an archive. This makes the first fetch chattier, but removes
archive traversal, symlinks, executable
bits, decompression bombs, and install hooks from the protocol. ADR 7 requires
no-replace store publication, winner rehash, and a same-handle handoff; the
v0.4.0 shell store now gates descriptor verification, no-replace publication,
concurrent winner rehash, and corrupt-winner non-overwrite. Same-handle handoff,
fetch, the lock v2 writer, dependency-closure/re-resolution binding, and offline
build evidence remain, so #14 stays open. The v0.8.0 catalog checkpoint covers
only supplied policy/catalog bytes and descriptors retained by one supplied
lock: it does not prove that bytes came from that HTTPS origin, authenticate a
publisher, prevent equivocation, or retain a complete catalog ledger.

**The cost:** protocol v1 is narrow — release semver only, ASCII paths, source
and data files only, and explicit size/count bounds. Supporting bundles,
pre-releases, `0.x`, or target-specific artifacts requires a visible protocol
revision rather than an unknown field that old clients misread.
[ADR 7](docs/adr/0007-static-url-fetch-protocol.md) fixes the endpoints, strict
metadata, redirect boundary, lock v2 migration, and recovery semantics.

### 6. A build output is named by its complete inputs

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
its source instead of its derivation fails three at once. Build settings are
not one opaque digest: output kind, target, backend, foreign ABI, framework,
and debug-info mode each have a domain and a mutation test. The gate reads that
inventory, so adding a setting without carrying and folding it fails before a
cache can ignore it.

**The cost:** everything must be in the closure, including the toolchain and
the build settings, which is more bookkeeping than a conventional build needs.
And input-addressing rebuilds more than content-addressing would — a comment
change in a dependency rebuilds its dependents even though the output is
identical. Nix has the same issue; the successor is content-addressed
derivations, which is a later and harder decision, named in
[ADR 4](docs/adr/0004-input-addressed-derivations.md) rather than ignored.

### 7. The lock pins the resolution, not only an output

```
# format: kofun-pm.lock/v1
# columns: module selection value
# tool: 6d4f0d92…
# requirements: a0fd5e88…
10	selected	6
20	workspace	-
# digest: 28cb369b…
```

The current lock v1 pins **what was resolved and what it was resolved from** —
which is only worth doing because MVS is a function. Re-resolving the same
requirements must give the same answer, so `kpm verify` is a check rather than
a hope. A lock over a *search* cannot make that claim, which is why locks over
searches pin outputs only. ADR 7's lock v2 adds every visited rough-graph
metadata descriptor and every selected file digest.

v0.5.0 landed a deliberately narrow read-only structural inspector for that
future format:

```
scripts/lock-v2.sh inspect LOCK --store /absolute/store
```

It copies at most 256 MiB into a private lock snapshot, verifies the exact four
headers and final self-digest, and parses package, metadata, and file sections
in byte/semantic-version/path order. Canonical URL identities, versions,
decimals, digests, paths, kinds, duplicates, workspace artifact absence,
selected metadata, the maximum recorded metadata version, and digest/size
consistency are all named checks. Every metadata/file digest is then copied
from the explicit store into a private snapshot through the rehashing store
adapter. The declared size is checked before digest work, and copying is capped
at that size plus one byte before the snapshot is rehashed; source files must
also be UTF-8. Hosts made entirely of decimal or `0x` hexadecimal labels,
including legacy compact IPv4 spellings, are refused rather than left to
platform resolver reinterpretation. The inspector does not mutate the lock or
store and has no network path.

v0.6.0 extends that same `inspect` command without renaming it to `verify`.
Every selected and superseded metadata snapshot is now parsed as exact
`kofun-metadata/v1`: fixed header/identity/version lines, sorted unique
dependencies, one or more sorted file descriptors, ASCII/LF framing, and the
same canonical URL, version, path, size, digest, case-fold, prefix, and device
rules used by the lock parser. The metadata identity/version must equal its
lock row. Remote metadata dependencies and file descriptors are counted across
all parsed versions before deduplication. The selected metadata descriptor plan
must then be byte-identical in both directions to the lock file rows across
identity, version, path, kind, size, and digest before snapshot or validation
is initiated from any selected file row.

v0.7.0 adds `audit-store`, which performs that same lock-scoped pass first and
then the existing whole-store reverse scan. It emits no partial success when
the global direction fails and still deliberately avoids the complete
`verify` name. Its store-wide work is proportional to the explicitly supplied
global store rather than to one lock, and the two passes are sequential rather
than an atomic snapshot.

v0.8.0 factors the full lock-v2 envelope and body parser into one shared
structural adapter and adds `scripts/catalog-v1.sh`. The new action validates
one private bounded catalog snapshot and authority snapshot, then optionally
uses every metadata descriptor for the same identity in one private bounded
lock snapshot. It distinguishes withdrawal from changed descriptors and
states first observation when the supplied lock carries no matching remote
descriptor. It does not read store objects or claim a complete historical
catalog.

The two store actions intentionally do **not** prove catalog authenticity/history,
dependency reachability or the complete rough graph, recompute the tool or
requirements identity, re-resolve MVS, write a lock, migrate v1, fetch, prove
exact lock/store set equality, or prove the affine same-handle consumer
boundary. Their success text states those absences. The hostile gate installs
and re-signs semantic metadata mutations so framing, header binding, order,
counts, canonical fields, selected/superseded parsing, and every descriptor
mismatch reach the intended check beyond both outer digests.

For the released v1 verifier, that buys four failures where other tools have
one, and "the lock is wrong"
sends a reader nowhere. The tool identity is the SHA-256 of a domain-framed
closure: resolver core and shell, build wiring, lock tool, and the exact Kofun
toolchain gitlink. It is not the repository commit, so an unrelated change
does not make every project re-lock:

| what happened | what the lock says | what to do |
|---|---|---|
| someone edited the file | its own digest no longer covers its contents | restore it |
| the requirements changed | written against a different requirement set | re-lock |
| the resolver inputs changed | tool identity no longer matches | review the resolver change, then re-lock |
| same requirements and resolver, different answer | the same tool changed its answer | file a bug |

The fourth **cannot happen** while the rule is a maximum. It is checked anyway,
because "cannot happen" is the state every silent corruption was in first.

The digest covers the headers as well as the rows, deliberately: a digest over
the rows alone would let someone move the requirements digest and keep the
selection — the edit worth making, and the one nobody would notice.

A workspace member is recorded as a member and carries no version. Pinning one
would pin a local path, which is a lock that is wrong on every other machine.

### 8. Every lock identity is a digest

Lock v1 digests the requirements, the resolver/tool input closure, and its own
complete body. Lock v2 also records the catalog-authenticated metadata digest
and every source/data file digest. Re-resolving from the same manifest and
pinned inputs is therefore a check rather than a hope: same inputs → same lock,
byte-identical. The gate proves that property for v1 today; the v0.6.0 inspector
proves the strict v2 envelope, every strict metadata snapshot, the selected
descriptor bijection, and sequential integrity of every lock-named store
snapshot. v0.7.0 composes that with a subsequent reverse scan of the explicit
store, while allowing valid unreferenced objects. v0.8.0 separately validates
one supplied authority/catalog pair and the continuity of descriptors actually
retained by one supplied lock. P4 still has to connect those checks to live
authenticated acquisition, a complete rough graph, the manifest, a writer,
and offline re-resolution before making the complete v2 claim.

**The cost:** a lock is bigger and more boring to read. Both are fine.

### 9. No install scripts. Ever.

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
sh scripts/dev.sh          # 57 unit tests across two seeds, and the gate
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
