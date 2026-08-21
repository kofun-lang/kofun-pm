# Strict parser for one already size- and digest-verified
# kofun-metadata/v1 private snapshot. Run with LC_ALL=C. The shell caller
# checks the byte grammar, final LF, row count, and line length first.

BEGIN {
    FS = "\t"
    OFS = "\t"
    phase = 0
    max_component = 2147483647
    max_dependencies = 256
    max_files = 4096
    max_file_size = 67108864
    max_package_file_size = 536870912
    if (expected_identity_environment != "")
        expected_identity = ENVIRON[expected_identity_environment]
    if (expected_version_environment != "")
        expected_version = ENVIRON[expected_version_environment]
}

function reject(message) {
    if (!bad)
        printf "metadata-v1: %s@%s row %d: %s\n", expected_identity,
            expected_version, NR, message > "/dev/stderr"
    else
        suppressed++
    bad = 1
}

NR == 1 {
    if (NF != 1 || $1 != "kofun-metadata/v1")
        reject("first line is not exactly kofun-metadata/v1")
    header_seen = 1
    next
}

NR == 2 {
    if (NF != 2 || $1 != "identity") {
        reject("second line is not exactly identity<TAB>IDENTITY")
        next
    }
    document_identity = $2
    identity(document_identity, "metadata identity")
    if (document_identity != expected_identity)
        reject("identity does not match its expected descriptor: " document_identity)
    identity_seen = 1
    next
}

NR == 3 {
    if (NF != 2 || $1 != "version") {
        reject("third line is not exactly version<TAB>VERSION")
        next
    }
    document_version = $2
    identity_version(document_identity, document_version, "metadata")
    if (document_version != expected_version)
        reject("version does not match its expected descriptor: " document_version)
    version_seen = 1
    next
}

NR > 3 && $1 == "dependency" {
    if (phase == 2) reject("dependency row appears after file rows")
    phase = 1
    dependency_count++
    if (dependency_count > max_dependencies)
        reject("direct dependency count exceeds 256")
    if (NF != 3) {
        reject("dependency row must have three fields")
        next
    }
    dependency_identity = $2
    dependency_version = $3
    identity_version(dependency_identity, dependency_version, "dependency")
    if (dependency_identity in dependency_seen)
        reject("duplicate dependency identity: " dependency_identity)
    if (dependency_count > 1 && dependency_identity <= previous_dependency)
        reject("dependency rows are not in strict identity-byte order: " dependency_identity)
    previous_dependency = dependency_identity
    dependency_seen[dependency_identity] = 1
    print "dependency", expected_identity, expected_version,
        dependency_identity, dependency_version
    next
}

NR > 3 && $1 == "file" {
    phase = 2
    file_count++
    if (file_count > max_files) reject("file descriptor count exceeds 4096")
    if (NF != 5) {
        reject("file row must have five fields")
        next
    }
    path = $2
    kind = $3
    size = $4
    hash = $5
    file_path(path, "file path")
    if (kind != "source" && kind != "data")
        reject("file kind is neither source nor data: " kind)
    canonical_uint(size, max_file_size, "file size")
    digest(hash, "file digest")
    if (path in exact_path_seen) reject("duplicate file path: " path)
    if (file_count > 1 && ("path:" path) <= ("path:" previous_path))
        reject("file rows are not in strict path-byte order: " path)
    previous_path = path
    exact_path_seen[path] = 1
    check_path_collision(expected_identity SUBSEP expected_version, path)
    if (hash in digest_size && digest_size[hash] != size)
        reject("one metadata digest carries conflicting file sizes: " hash)
    digest_size[hash] = size
    package_file_size += size + 0
    if (package_file_size > max_package_file_size)
        reject("metadata file bytes exceed 512 MiB")
    descriptor_kind = (emit_files ? "file" : "descriptor")
    print descriptor_kind, expected_identity, expected_version, path, kind, size, hash
    next
}

NR > 3 {
    reject("unknown or blank metadata row kind: " $1)
}

END {
    if (!header_seen) reject("metadata header is missing")
    if (!identity_seen) reject("metadata identity line is missing")
    if (!version_seen) reject("metadata version line is missing")
    if (!file_count) reject("metadata has no file row")
    if (suppressed)
        printf "metadata-v1: %d additional violation(s) suppressed\n", suppressed > "/dev/stderr"
    exit bad ? 1 : 0
}
