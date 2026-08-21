# Strict parser for one bounded canonical kofun-pm.requirements/v2 snapshot.
# Run with LC_ALL=C and the shared protocol-v1 validator. The shell caller
# owns byte framing, the final LF, line/row/byte bounds, and SHA-256.

BEGIN {
    FS = "\t"
    OFS = "\t"
    phase = 1
    max_component = 2147483647
    max_roots = 1024
    max_members = 1024
    max_edges = 16384
}

function reject(message) {
    if (!bad)
        printf "requirements-v2: row %d: %s\n", NR, message > "/dev/stderr"
    else
        suppressed++
    bad = 1
}

NR == 1 {
    if (NF != 1 || $1 != "kofun-pm.requirements/v2")
        reject("first line is not exactly kofun-pm.requirements/v2")
    header_seen = 1
    next
}

$1 == "root" {
    if (phase != 1) reject("root row appears after another row section")
    root_count++
    edge_count++
    if (root_count > max_roots) reject("root requirement count exceeds 1024")
    if (NF != 3) {
        reject("root row must have three fields")
        next
    }
    id = $2
    release = $3
    identity_version(id, release, "root requirement")
    if (root_count > 1 && id <= previous_root)
        reject("root rows are not in strict identity-byte order: " id)
    previous_root = id
    print "root", id, release, "-", "-", "-", "-", "edge"
    next
}

$1 == "member" {
    if (phase == 3) reject("member row appears after member-requirement rows")
    phase = 2
    member_count++
    if (member_count > max_members) reject("workspace member count exceeds 1024")
    if (NF != 2) {
        reject("member row must have two fields")
        next
    }
    id = $2
    identity(id, "workspace member")
    if (member_count > 1 && id <= previous_member)
        reject("member rows are not in strict identity-byte order: " id)
    previous_member = id
    member_seen[id] = 1
    print "member", id, "-", "-", "-", "-", "-", "workspace"
    next
}

$1 == "member-requirement" {
    phase = 3
    member_requirement_count++
    edge_count++
    if (NF != 4) {
        reject("member-requirement row must have four fields")
        next
    }
    owner = $2
    id = $3
    release = $4
    identity(owner, "member-requirement owner")
    identity_version(id, release, "member requirement")
    if (!(owner in member_seen))
        reject("member-requirement owner is not a declared workspace member: " owner)
    if (member_requirement_count > 1 &&
        (owner < previous_owner ||
         (owner == previous_owner && id <= previous_member_requirement)))
        reject("member-requirement rows are not in strict member/identity-byte order: " owner " -> " id)
    previous_owner = owner
    previous_member_requirement = id
    print "member-requirement", owner, "-", id, release, "-", "-", "edge"
    next
}

NR > 1 {
    reject("unknown or blank requirements row kind: " $1)
}

END {
    if (!header_seen) reject("requirements header is missing")
    if (edge_count > max_edges)
        reject("root and member requirement edges exceed 16384")
    if (suppressed)
        printf "requirements-v2: %d additional violation(s) suppressed\n", suppressed > "/dev/stderr"
    exit bad ? 1 : 0
}
