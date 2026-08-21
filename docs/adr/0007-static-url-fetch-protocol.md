# 7. Static URL metadata, file blobs, and explicit fetch

Date: 2026-08-21 · Status: accepted · Resolves the wire decision in issue #14

## Context

[ADR 3](0003-url-identity.md) says a package is identified by its URL and that
there is no registry. That answers *who names a package*, but not what a host
serves for a version, how transitive requirements arrive, or when a command may
use the network.

The protocol has to preserve four decisions already made here:

- minimal version selection consumes exact lower bounds, not a solver search;
- a major version is part of the package identity;
- the store names one immutable byte string by SHA-256;
- fetching source and data never executes an install hook.

The [Go module proxy protocol](https://go.dev/ref/mod#goproxy-protocol) shows
that versioned metadata and bytes can be ordinary static HTTP resources. It
also notes that its version list and `.info` responses are not authenticated.
That is not sufficient here: a catalog row must name the digest and size of
the metadata it advertises. The
[OCI descriptor](https://github.com/opencontainers/image-spec/blob/main/descriptor.md)
provides the smaller useful idea — type, byte size, and digest are checked
before content is consumed — without importing the OCI registry or image
model.

## Decision

### 1. The identity is an exact HTTPS base URL

A remote package identity is the exact ASCII string declared in the manifest,
at most 2,048 bytes. Protocol v1 accepts only this canonical subset:

- the literal lowercase prefix `https://`;
- a lowercase DNS A-label host, without user information, IP literal, trailing
  dot, or explicit port (v1 is always port 443); a host made entirely of
  decimal or `0x` hexadecimal numeric labels is refused so legacy one- through
  four-part IPv4 forms cannot be reinterpreted by the platform resolver;
- path segments matching `[A-Za-z0-9._~-]+`, with neither `.` nor `..` as a
  segment, and exactly one trailing `/`;
- no percent escape, backslash, whitespace, control byte, query, or fragment.

The major-version boundary from
[ADR 5](0005-semver-with-the-major-in-the-identity.md) is part of that URL:
major 1 has no suffix and major 2 or later ends in `/v<MAJOR>/`, for example:

```text
https://packages.example/http/
https://packages.example/http/v2/
```

Anything outside the subset is refused rather than normalized. A transport
implementation may parse the URL, but the identity compared with metadata and
written to the lock remains the declared byte string. Authors publish one
canonical spelling and consumers lock those exact bytes. Workspace members
remain local and are never mapped to this protocol.

### 2. Three static endpoint families

For identity `P`, concatenation is literal because `P` ends in `/`:

```text
catalog:   P@kofun/v1/catalog
metadata:  P@kofun/v1/versions/<version>.meta
blob:      P@kofun/v1/blobs/sha256/<64-lowercase-hex>
```

There is no discovery request, HTML parsing, registry fallback, query
parameter, content negotiation, or ambient mirror list. A static file server
can implement the complete protocol.

Protocol v1 accepts canonical release versions `MAJOR.MINOR.PATCH` with no
leading `v`, leading zero, pre-release, or build suffix. Each component is an
unsigned decimal integer from 0 through 2,147,483,647. `MAJOR` must be positive
and match the major carried by `P`. `0.x` remains unsupported as ADR 5 requires;
a fetcher must name that refusal rather than guess a compatibility boundary.

### 3. The HTTPS catalog binds version metadata

The catalog is UTF-8 with LF endings and this exact tab-separated grammar:

```text
kofun-catalog/v1
<version>\t<metadata-byte-size>\t<metadata-sha256>
```

The file has one final LF and no other blank line. Rows are sorted by semantic
version and a version occurs once. The metadata
size is canonical unsigned decimal without a leading zero; the digest is 64
lowercase hexadecimal bytes with no `sha256:` prefix. Blank lines, comments,
unknown columns, CR, duplicate versions, hostile order, or a row outside the
identity's major are refused.

A catalog may grow by adding versions. During one fetch and against every
metadata descriptor already recorded in the input v2 lock, the same
identity/version with another metadata size or digest is an immutability
violation and is refused loudly. A previously locked identity/version missing
from the new catalog is a withdrawal/history violation, not an ordinary "not
published" result. One fetch obtains exactly one catalog snapshot per identity
and reuses those bytes for every exact-version lookup; it cannot observe two
catalog histories for one identity in one operation. There is no client-wide
observation ledger: a new project still trusts its first HTTPS catalog, and a
host can equivocate between clients. Publishing authority, signing,
withdrawal, and transparency remain P6 rather than being falsely attributed
to SHA-256.

### 4. Metadata is strict and describes every dependency and file

The metadata response is checked against its catalog size and digest *before*
it is parsed. It is UTF-8 containing only ASCII and has this complete
tab-separated byte grammar:

```text
kofun-metadata/v1
identity\t<identity>
version\t<version>
dependency\t<identity>\t<minimum-version>
file\t<path>\t<kind>\t<size>\t<sha256>
```

The header, identity, and version are the first three lines exactly once.
Zero or more dependency rows follow, sorted by identity bytes, then one or
more file rows sorted by path bytes. The file ends with exactly one LF. Blank
lines, comments, CR, escape syntax, unknown row kinds, wrong field counts,
duplicates, or hostile order are refused. Metadata identity and version must
equal the request and catalog row; a redirect cannot change either.
Dependency identity order is strict: one metadata document cannot repeat an
identity with the same or a different minimum version.

A dependency is only a canonical identity and exact minimum version, matching
`contracts/manifest.toml`. A file descriptor is only a path, kind, unsigned
canonical byte size, and 64-lowercase-hex SHA-256. Path segments match
`[A-Za-z0-9._-]+`, are at most 255 bytes, and are neither `.` nor `..`; the
whole relative path is at most 1,024 bytes. Exact duplicates and file/directory
prefix collisions such as `a` with `a/b` are refused both byte-exactly and
after ASCII case folding. A segment may not end in `.`. For each segment, the
ASCII-case-folded part before its first `.` may not be a Windows device
basename: `CON`, `PRN`, `AUX`, `NUL`, `COM1`–`COM9`, or `LPT1`–`LPT9`; this also
refuses names such as `CON.txt`. `kind` is exactly `source` or `data`; source
bytes must be valid UTF-8 after integrity verification, while data bytes are
opaque.

There are no archives, symlinks, permissions, executable bits, target-specific
prebuilt libraries, conditional features, scripts, or hooks. Directories are
implied by file paths. Every listed file is acquired; P7 decides how source and
data become build inputs. A future bundle or target-specific artifact needs a
new protocol version instead of growing an extraction language inside v1.

### 5. MVS traverses exact published minima and retains the rough graph

A requirement `P >= V` means the exact version `V` must have a catalog row.
If it does not, fetch reports `required version P@V is not published` even when
a higher version exists. It never rounds to the next or newest publication;
publishing a version alone therefore cannot move selection.

Fetch builds the transitive rough graph with this deterministic work queue:

1. Validate every declared workspace member, then expand all members exactly
   once in identity-byte order with a separate workspace-identity visited set.
   A member is never fetched and carries no version; every member requirement
   joins the root requirements even when no root or remote package refers to
   that member. Workspace cycles terminate at this visited set.
2. Put every non-workspace root and member requirement pair `(identity,
   minimum)` into one queue in identity and semantic-version order. A
   requirement whose identity is a workspace member adds no remote pair: that
   member was already expanded once in step 1.
3. Pop the smallest remote pair. If that exact pair was visited, skip it.
   Otherwise require its exact catalog row, verify and retain its metadata, and
   enqueue every non-workspace dependency pair in metadata order. A remote
   dependency on a workspace identity likewise adds no remote pair.
4. Stop when the queue is empty or a closure bound is exceeded. Remote cycles
   terminate because the remote visited key is the exact `(identity, version)`
   pair; workspace cycles terminate independently in step 1.
5. Select the maximum visited required version per non-workspace identity.
   Metadata for superseded visited versions remains a resolution input; only
   file blobs for the final selected versions are acquired.

Thus root→A1 and root→B1 with B1→A2 retains A1, B1, and A2 metadata, selects
A2, and includes requirements learned from A1 as Go-style MVS does. The current
bounded seed proves the maximum over known requirements; exact sparse-catalog
membership and this traversal are P4 adapter work, not a property already
claimed by `highest_published`.

### 6. Only `kpm fetch` has network authority

`kpm fetch MANIFEST --authority AUTHORITY --store STORE` reads the manifest and
explicit authority file defined below and receives the store path rather than
inventing a hidden default. Both options are required and have no default. If
its `--out` path already contains a lock, that lock is the input history for
immutability checks and v1 migration. Fetch constructs the rough graph,
verifies every selected file blob, publishes every visited metadata document
and selected file blob to that content-addressed store, and atomically writes a
complete lock v2. Metadata is bytes under its digest path, not a trusted side
file.
Fetch may reuse an existing entry only after hashing it. A failed fetch may
leave verified, unreferenced content-addressed bytes, but never a partial
trusted entry or a partial replacement lock.

`kpm lock MANIFEST --store STORE`, `kpm verify LOCK STORE`, `kpm why MODULE
--manifest MANIFEST --lock LOCK --store STORE`, ordinary resolution, and `kofun
build` never contact a host. Fetch and lock require `--store`; fetch also
requires `--authority`; why requires `--manifest`, `--lock`, and `--store`.
Those required input options have no default. `lock` reads the effective
`--out` path — either the explicit value or its documented
`kofun.packages.lock` default — as its metadata history before atomically
replacing that same path. The lock maps every rough-graph identity/version to
its metadata digest, so offline re-resolution and explanation have the whole
input closure. A first lock therefore starts with explicit `kpm fetch`; later
`kpm lock` rehashes and parses those exact metadata entries offline and must
reproduce the same lock bytes. A manifest change that needs an unrecorded
identity/version fails and asks for a separate fetch. There is no `--offline`
flag because offline is not a mode to remember.

A missing or corrupt offline input fails with package identity, version, path,
and expected digest. It reports expected and actual size first; when those
match and digest comparison is reached, it also reports the actual digest. A
size mismatch explicitly reports that the actual digest was not computed, so
the size bound is enforced before hashing. It never upgrades itself to a
network request.

The present CLI DSL cannot express authority-bearing action signatures and all
commands remain intentionally bound to the failing `greet` placeholder. After
kofun#1551, the gate must prove that only the fetch action accepts Network,
TLS-root, DNS, and deadline/cancellation authority; lock, verify, why, and build
must have no such parameter. Command spelling alone is not that proof.

### 7. Lock v2 pins the rough metadata graph and selected file blobs

The released `kofun-pm.lock/v1` grammar remains resolution-only. Artifact rows
are not a compatible extension, so fetch writes `kofun-pm.lock/v2`.

The complete byte grammar is UTF-8 ASCII with LF endings:

```text
# format: kofun-pm.lock/v2
# columns: typed rows: package identity state version | metadata identity version size sha256 | file identity version path kind size sha256
# tool: <64-lowercase-hex>
# requirements: <64-lowercase-hex>
package\t<identity>\tselected\t<version>
package\t<identity>\tworkspace\t-
metadata\t<identity>\t<version>\t<size>\t<sha256>
file\t<identity>\t<version>\t<path>\t<kind>\t<size>\t<sha256>
# digest: <64-lowercase-hex>
```

The four headers occur once in that order. Then come all package rows sorted by
identity, all metadata rows sorted by identity then semantic version, and all
file rows sorted by identity, version, and path. One package row exists per
identity. Every visited rough-graph pair has exactly one metadata row and
content-addressed metadata entry, including superseded versions. For every
selected version, its parsed metadata file descriptors and lock file rows are
a bijection: each descriptor has exactly one row with byte-identical identity,
version, path, kind, size, and digest, and there is no other file row. Workspace
rows have neither metadata nor file rows. Decimal and digest fields use the
canonical forms above.

Unknown headers/rows, comments, blanks, wrong field counts, duplicates,
orphan metadata/files, missing selected metadata, missing selected file,
descriptor/row mismatch, hostile order, CR, missing final LF, or bytes after
the digest line are refused. The final self-digest is SHA-256 over every
preceding byte, including its final LF. The v2 tool identity uses domain
`kofun-pm.lock-tool/v2` and covers resolver, graph traversal, URL, catalog,
metadata and lock parsers, store admission, build wiring, and the exact clean
Kofun gitlink.

The requirements digest is SHA-256 over this complete canonical byte framing:

```text
kofun-pm.requirements/v2
root\t<identity>\t<minimum-version>
member\t<workspace-identity>
member-requirement\t<workspace-identity>\t<identity>\t<minimum-version>
```

The header occurs once. Zero or more root rows follow sorted by required
identity, then one member row per declared workspace identity sorted by member
identity, then member-requirement rows sorted by member identity and required
identity. Rows use the canonical identity and version
forms above, and the framing ends with exactly one LF. Root identity keys,
member identity keys, and `(member identity, required identity)` keys are each
unique; their minimum version is the value rather than part of a duplicate
key. Different root/member/remote sources may still impose different minima on
the same required identity, and every such edge counts before exact-pair
reachability deduplicates it.

The requirements document is at most 67 MiB (70,254,592 bytes), 17,409 rows
including its header, and 8,192 bytes per line. Those rounded structural
ceilings contain the maximum 1,024 members and 16,384 root/member edge rows at
the canonical identity/version scalar maxima below; the semantic collection
limits remain authoritative.

A supplied offline graph checkpoint validates in this order: requirements
framing/grammar/bounds; lock framing/self-digest/complete row grammar; exact
requirements digest; every retained metadata snapshot and selected-file
relation; workspace package equality; missing reachable exact pairs;
unreachable retained pairs; and selected package/max-version equality. It
emits no graph plan or counts until all stages pass. Success counts root and
member rows, distinct reachable non-workspace `(identity, version)` pairs,
selected non-workspace identities, and every root/member/remote dependency
edge row before reachability deduplication.
Workspace paths and the network authority file are not included: neither is a
resolution input or lock identity. Member identities and requirements are.

A v2-capable tool retains the v1 reader and its four existing checks, but v1
cannot prove metadata or artifact presence. Because v1 has no authenticated
identity/version-to-metadata mapping, migration always requires explicit
`kpm fetch`; arbitrary local bytes are insufficient. The writer never edits v1
in place, silently drops rows, or writes a v1 downgrade.

### 8. HTTP transport is a bounded byte source, not an ambient client

Every request is `GET` with no body and `Accept-Encoding: identity`. The client
sends no cookies, credentials, or authorization. It ignores environment proxy
variables, `.netrc`, credential helpers, automatic client certificates, and
other ambient network configuration. It makes no automatic retry: each request
has one connection attempt, and a redirect starts a new counted request. After
zero to five redirects, the only successful final status is 200. Redirect
statuses are exactly 301, 302, 303, 307, and 308; every other
1xx/2xx/3xx/4xx/5xx response is refused. `Content-Encoding` must be absent or
`identity`. Size and digest cover the response body after HTTP transfer framing
and before any interpretation; there is no content decompression path.

Redirection follows [RFC 9110](https://www.rfc-editor.org/rfc/rfc9110.html) as
transport with stricter bounds: HTTPS at every hop, loop detection, no
userinfo, and a 2,048-byte maximum raw and resolved `Location`. A cross-origin
HTTPS CDN redirect is allowed, but the declared `P`, metadata identity, and
lock identity never change. TLS 1.2 or newer, chain verification, and hostname
verification against the explicitly supplied platform trust roots are
mandatory and have no disable switch.

The required `AUTHORITY` file is ASCII with exactly this grammar:

```text
kofun-fetch-authority/v1
origin\t<https-origin>
```

An origin is the literal lowercase `https://` plus a canonical lowercase DNS
A-label host and nothing else: no userinfo, IP literal, trailing dot, port,
path, query, or fragment. The host is at most 253 bytes, each label is at most
63 bytes, and the complete origin is at most 261 bytes. Rows are sorted by
origin bytes, unique, and end with exactly one final LF; comments, blanks, CR,
unknown rows, and more than the file or origin bound are refused. A transitive
dependency or redirect to an unapproved origin stops and names the exact origin
to add before an explicit retry; it is never auto-approved. Authority changes
only whether a request may occur and is therefore not a requirements or lock
digest input.

DNS returns at most the answer bound and every answer is checked before a
connection; exceeding the bound or seeing any non-public answer refuses the
request. Allowed answers are sorted by address bytes and the first is the one
connection attempt. The connected peer is checked again. Protocol v1 refuses
loopback, link-local, private-use, carrier-grade NAT, multicast, unspecified,
documentation, and other non-public/special-purpose addresses, including
IPv4-mapped IPv6. This deliberately excludes private package hosts and prevents
a public package from turning fetch into an internal-network request.

A different mirror base URL is a different package identity under ADR 3.
Protocol v1 has no mirror aliases or fallback list. Operators may copy already
verified blobs into a store because digest identity is independent of origin;
that does not rename the package. An alias policy, if ever added, must be
explicit and lock-recorded.

### 9. Store publication is verify, then create-if-absent

Fetched bytes are streamed into a unique temporary on the final entry's
filesystem while enforcing the declared size bound. The completed candidate's
size and SHA-256 are checked before publication.

Publication MUST use atomic create-if-absent semantics: an existing final name
is never replaced. Plain overwriting `rename` or `mv` is not sufficient.

The same admission and publication algorithm applies to metadata and file
bytes. An `EEXIST` result is a normal concurrent race. The loser removes its
temporary, rehashes the winner, and adopts it only when size and digest match.
Every later add, lookup, link/copy, or build handoff rehashes the existing
entry; lock/verify also rehash metadata before parsing it. Existence and
read-only mode alone are not evidence.

Verification returns an affine read handle to the same open file description
whose bytes were hashed, not a pathname that can be swapped before use. When a
consumer requires a materialized path, it copies from that handle into a
private destination and rehashes the destination immediately before handing it
to the parser, linker, or build. A check-then-open pathname API does not satisfy
this contract.

A corrupt existing entry is never used and must not wedge the store forever.
The operation reports package, version, entry path, expected digest, and
recovery action. It reports the actual digest only after expected and actual
size match; on size mismatch it reports both sizes and that digest computation
was skipped. An offline operation stops with recovery instructions. A
network-authorized fetch may quarantine or remove an entry in the store it
manages, report that action, and acquire it again. It never silently overwrites
or silently refetches corruption.

### 10. Every untrusted collection and operation is bounded

Protocol v1 fixes these maxima before allocation or parsing:

| input | maximum |
|---|---:|
| package identity bytes | 2,048 |
| complete request-target bytes | 4,096 |
| raw or resolved redirect `Location` bytes | 2,048 |
| semantic-version component | 2,147,483,647 |
| redirect hops per request | 5 |
| approved public origins | 2,048 |
| authority file bytes | 512 KiB |
| DNS answers per resolution | 64 |
| HTTP response status line plus headers | 64 KiB |
| HTTP response header fields | 256 |
| one HTTP header name | 256 bytes |
| one HTTP header field line | 8 KiB |
| catalog bytes | 1 MiB |
| catalog versions | 4,096 |
| metadata bytes per version | 1 MiB |
| direct dependencies per version | 256 |
| files per version | 4,096 |
| path bytes | 1,024 |
| one file blob | 64 MiB |
| all file blobs in one package version | 512 MiB |
| root requirements | 1,024 |
| declared workspace members | 1,024 |
| requirements file bytes | 67 MiB |
| requirements rows including header | 17,409 |
| requirements line bytes | 8,192 |
| package identities in one closure, including workspace | 1,024 |
| distinct identity/version pairs in one rough graph | 16,384 |
| root, member, and remote dependency edges in one closure | 16,384 |
| file descriptors in one closure | 65,536 |
| catalog bytes in one fetch | 64 MiB |
| metadata bytes in one fetch | 64 MiB |
| file blob bytes in one fetch | 8 GiB |
| one lock v2 file | 256 MiB |
| HTTP request/connection attempts in one fetch, including redirects and failures | 70,000 |
| DNS + connect + TLS establishment per attempt | 10 seconds |
| response idle interval | 30 seconds |
| complete fetch operation | 10 minutes |

`Content-Length`, when present, is checked first, but the streaming limit is
authoritative because a response can omit or lie about that header. Size is
checked before digest to reject truncation and overrun by name. A repeated
input row, dependency edge, HTTP acquisition, metadata response, or file
response counts against its work total before content or queue deduplication,
so an attacker cannot spend unbounded work by repeating one small object. The
distinct rough-graph pair limit still counts the exact visited `(identity,
version)` set once; every queue occurrence that led to that set is separately
charged to the 16,384 edge limit.
The 65,536 file-descriptor closure limit counts descriptors in every parsed
selected and superseded metadata document, even though only selected-version
file blobs are acquired. The 16,384 edge limit includes remote dependency rows
from every such document as well as root and member edges; a checkpoint that
does not yet have manifest/requirements bytes may conservatively apply the
same 16,384 ceiling to remote metadata rows alone, but cannot claim the full
closure-edge proof.

Cancellation is an explicit fetch authority, checked between bounded I/O
steps. Cancellation or deadline leaves the previous lock unchanged and can
leave only verified unreferenced entries and untrusted temporary files. It is
never inferred from ambient process state.

## Consequences

**Static hosting is enough.** The protocol takes Go's filesystem-shaped
endpoints without creating a proxy service or central namespace.

**Metadata is part of the integrity chain.** Transitive requirements and file
descriptors cannot be parsed from bytes that failed their catalog descriptor.
The first observation still trusts the package's HTTPS authority; signing and
transparency remain publishing decisions, not claims smuggled into SHA-256.

**Offline is structural.** Only one command owns network authority. A build
cannot start fetching because a flag was forgotten.

**No archive means more requests.** A package with many files costs more HTTP
requests and metadata rows than a zip or tarball. In return v1 has no archive
traversal, symlink, permission, decompression, or extraction-bomb semantics.
HTTP caches and the content-addressed store remove that cost after the first
explicit fetch.

**The format is deliberately narrow.** ASCII paths and no pre-release, `0.x`,
bundle, or target-specific artifacts exclude real packages. Each absence keeps
the first fetcher bounded and makes the future change visible as a protocol
version rather than an accidental parser feature.

## Evidence required by implementation

Issue #14 remains open for executable evidence. Its gate must cover at least:
catalog and metadata order, descriptor size and digest, transitive acquisition,
five-hop and loop redirect boundaries, identity preservation across redirect,
duplicate content under two identities, wrong/truncated bytes, interruption,
concurrent no-replace publication, corrupt-winner recovery, v1/v2 migration,
and a network-denied lock/verify/build after one successful fetch.

## Current Kofun implementation boundary

The contract is implementable first as the shell gate/adapter allowed by
#14. Moving it into Kofun remains blocked on more than a byte carrier:

- kofun#1258 is the bounded byte carrier;
- kofun#1499 is authority-derived file byte input and streaming;
- kofun#1264 covers the scripted HTTP core, not yet live DNS/socket/TLS and the
  bounded redirect transport specified here; kofun#1577 owns that live adapter;
- kofun#1480 covers filesystem operations, but not yet the atomic
  create-if-absent primitive this store requires; kofun#1578 owns that primitive;
- kofun#1551 is the arbitrary native CLI action binding.

Landing any one of these does not authorize silently emulating the others.
The shell adapter proves the property until each capability has an explicit
Kofun contract.
