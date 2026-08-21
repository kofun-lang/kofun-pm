# Strict parser for one bounded private kofun-catalog/v1 snapshot. The caller
# supplies expected_identity and checks byte grammar, framing, line length,
# and row count before invoking this parser.

BEGIN {
    FS = "\t"
    OFS = "\t"
    max_component = 2147483647
    max_versions = 4096
    max_metadata_size = 1048576
    if (identity_environment != "")
        expected_identity = ENVIRON[identity_environment]
    if (!identity(expected_identity, "catalog identity"))
        bad = 1
    expected_origin = identity_origin(expected_identity)
    if (identity_only) exit bad ? 1 : 0
}

function reject(message) {
    if (!bad)
        printf "catalog-v1: %s row %d: %s\n", expected_identity, NR,
            message > "/dev/stderr"
    else
        suppressed++
    bad = 1
}

NR == 1 {
    if (NF != 1 || $1 != "kofun-catalog/v1")
        reject("first line is not exactly kofun-catalog/v1")
    header_seen = 1
    next
}

{
    version_count++
    if (version_count > max_versions)
        reject("catalog version count exceeds 4096")
    if (NF != 3) {
        reject("catalog row must have version, metadata size, and metadata digest")
        next
    }
    release = $1
    size = $2
    hash = $3
    valid_release = identity_version(expected_identity, release, "catalog release")
    canonical_uint(size, max_metadata_size, "catalog metadata size")
    digest(hash, "catalog metadata digest")
    if (valid_release && version_count > 1 &&
        version_compare(release, previous_version) <= 0)
        reject("catalog versions are not in strict semantic order: " release)
    previous_version = release
    releases[version_count] = release
    sizes[version_count] = size
    hashes[version_count] = hash
    if (hash in digest_size && digest_size[hash] != size)
        reject("one metadata digest carries conflicting sizes: " hash)
    digest_size[hash] = size
}

END {
    if (identity_only) {
        if (!bad) print "identity", expected_identity, expected_origin
        exit bad ? 1 : 0
    }
    if (!header_seen) reject("catalog is empty")
    if (suppressed)
        printf "catalog-v1: %d additional catalog violation(s) suppressed\n", suppressed > "/dev/stderr"
    if (bad) exit 1
    print "identity", expected_identity, expected_origin
    for (i = 1; i <= version_count; i++)
        print "catalog", releases[i], sizes[i], hashes[i]
}
