# Strict structural validator for the lock-v2 rows between the four headers
# and final self-digest. Run with LC_ALL=C so string order and length are byte
# order and byte length.

BEGIN {
    FS = "\t"
    OFS = "\t"
    phase = 1
    max_component = 2147483647
    max_packages = 1024
    max_metadata = 16384
    max_files = 65536
    max_metadata_size = 1048576
    max_total_metadata_size = 67108864
    max_file_size = 67108864
    max_package_file_size = 536870912
    max_total_file_size = 8589934592
}

function reject(message) {
    if (!bad)
        printf "lock-v2: row %d: %s\n", NR, message > "/dev/stderr"
    else
        suppressed++
    bad = 1
}

function canonical_uint(value, maximum, label) {
    if (value == "" || value ~ /[^0-9]/ ||
        (length(value) > 1 && substr(value, 1, 1) == "0")) {
        reject(label " is not canonical unsigned decimal: " value)
        return 0
    }
    if ((value + 0) > maximum) {
        reject(label " exceeds its bound: " value)
        return 0
    }
    return 1
}

function digest(value, label) {
    if (length(value) != 64 || value ~ /[^0-9a-f]/) {
        reject(label " is not one lowercase sha256 digest: " value)
        return 0
    }
    return 1
}

function version(value, label, parts, count, i) {
    count = split(value, parts, "\\.")
    if (count != 3) {
        reject(label " is not MAJOR.MINOR.PATCH: " value)
        return 0
    }
    for (i = 1; i <= 3; i++) {
        if (!canonical_uint(parts[i], max_component, label " component"))
            return 0
    }
    if ((parts[1] + 0) == 0) {
        reject(label " uses unsupported major zero: " value)
        return 0
    }
    return 1
}

function version_compare(left, right, a, b, count_a, count_b, i) {
    count_a = split(left, a, "\\.")
    count_b = split(right, b, "\\.")
    if (count_a != 3 || count_b != 3)
        return 0
    for (i = 1; i <= 3; i++) {
        if ((a[i] + 0) < (b[i] + 0)) return -1
        if ((a[i] + 0) > (b[i] + 0)) return 1
    }
    return 0
}

function identity(value, label, rest, slash, host, path, labels, count, i,
                  numeric_host, segments, segment_count, segment) {
    if (length(value) > 2048) {
        reject(label " exceeds 2048 bytes")
        return 0
    }
    if (substr(value, 1, 8) != "https://" || substr(value, length(value), 1) != "/") {
        reject(label " is not a canonical https base URL: " value)
        return 0
    }
    rest = substr(value, 9)
    slash = index(rest, "/")
    if (slash <= 1) {
        reject(label " has no DNS host: " value)
        return 0
    }
    host = substr(rest, 1, slash - 1)
    path = substr(rest, slash + 1)
    if (length(host) > 253 || host ~ /[^a-z0-9.-]/ ||
        substr(host, 1, 1) == "." || substr(host, length(host), 1) == ".") {
        reject(label " host is not lowercase DNS A-label form: " host)
        return 0
    }
    count = split(host, labels, "\\.")
    numeric_host = 1
    for (i = 1; i <= count; i++) {
        if (labels[i] == "" || length(labels[i]) > 63 ||
            labels[i] ~ /[^a-z0-9-]/ ||
            substr(labels[i], 1, 1) !~ /[a-z0-9]/ ||
            substr(labels[i], length(labels[i]), 1) !~ /[a-z0-9]/) {
            reject(label " host label is not canonical: " labels[i])
            return 0
        }
        if (labels[i] !~ /^[0-9]+$/ && labels[i] !~ /^0x[0-9a-f]+$/)
            numeric_host = 0
    }
    if (numeric_host) {
        reject(label " uses a forbidden numeric IP literal form: " host)
        return 0
    }
    if (path != "") {
        segment_count = split(path, segments, "/")
        if (segments[segment_count] != "") {
            reject(label " is missing its one trailing slash: " value)
            return 0
        }
        for (i = 1; i < segment_count; i++) {
            segment = segments[i]
            if (segment == "" || segment == "." || segment == ".." ||
                segment ~ /[^A-Za-z0-9._~-]/) {
                reject(label " has a non-canonical URL path segment: " segment)
                return 0
            }
        }
    }
    return 1
}

function identity_version(value, release, label, parts, major, suffix, without_slash,
                          slash_count, path_parts, tail) {
    if (!identity(value, label) || !version(release, label " version"))
        return 0
    split(release, parts, "\\.")
    major = parts[1] + 0
    if (major >= 2) {
        suffix = "/v" parts[1] "/"
        if (substr(value, length(value) - length(suffix) + 1) != suffix) {
            reject(label " does not carry major " parts[1] " in its identity: " value)
            return 0
        }
    } else {
        without_slash = substr(value, 1, length(value) - 1)
        slash_count = split(without_slash, path_parts, "/")
        tail = path_parts[slash_count]
        if (tail ~ /^v[0-9]+$/) {
            reject(label " major one identity carries a version suffix: " value)
            return 0
        }
    }
    return 1
}

function file_path(value, label, segments, count, i, segment, lower, base) {
    if (value == "" || length(value) > 1024 || substr(value, 1, 1) == "/" ||
        substr(value, length(value), 1) == "/" || value ~ /[^A-Za-z0-9._\/-]/) {
        reject(label " is not a bounded relative protocol path: " value)
        return 0
    }
    count = split(value, segments, "/")
    for (i = 1; i <= count; i++) {
        segment = segments[i]
        if (segment == "" || segment == "." || segment == ".." ||
            length(segment) > 255 || substr(segment, length(segment), 1) == ".") {
            reject(label " has a forbidden segment: " segment)
            return 0
        }
        lower = tolower(segment)
        base = lower
        sub(/\..*$/, "", base)
        if (base ~ /^(con|prn|aux|nul)$/ || base ~ /^(com|lpt)[1-9]$/) {
            reject(label " has a Windows device segment: " segment)
            return 0
        }
    }
    return 1
}

function check_path_collision(id, release, path, segments, count, i, prefix,
                              scope, folded, key) {
    scope = id SUBSEP release SUBSEP
    folded = tolower(path)
    key = scope folded
    if (key in file_seen) {
        reject("file path duplicates after ASCII case folding: " path)
        return 0
    }
    if (key in directory_seen) {
        reject("file path is a prefix of another file path: " path)
        return 0
    }
    count = split(folded, segments, "/")
    prefix = ""
    for (i = 1; i < count; i++) {
        prefix = (prefix == "" ? segments[i] : prefix "/" segments[i])
        if ((scope prefix) in file_seen) {
            reject("file path descends through another file: " path)
            return 0
        }
        directory_seen[scope prefix] = 1
    }
    file_seen[key] = 1
    return 1
}

$1 == "package" {
    if (phase != 1) reject("package row appears after another row section")
    package_count++
    if (package_count > max_packages) reject("package count exceeds 1024")
    if (NF != 4) {
        reject("package row must have four fields")
        next
    }
    id = $2
    state = $3
    release = $4
    identity(id, "package identity")
    if (id in package_state) reject("duplicate package identity: " id)
    if (package_count > 0 && id <= previous_package)
        reject("package rows are not in strict identity-byte order: " id)
    previous_package = id
    if (state == "selected") {
        identity_version(id, release, "selected package")
    } else if (state == "workspace") {
        if (release != "-") reject("workspace package must carry version -")
    } else {
        reject("package state is neither selected nor workspace: " state)
    }
    package_state[id] = state
    package_version[id] = release
    next
}

$1 == "metadata" {
    if (phase == 3) reject("metadata row appears after file rows")
    phase = 2
    metadata_count++
    if (metadata_count > max_metadata) reject("metadata count exceeds 16384")
    if (NF != 5) {
        reject("metadata row must have five fields")
        next
    }
    id = $2
    release = $3
    size = $4
    hash = $5
    identity_version(id, release, "metadata")
    canonical_uint(size, max_metadata_size, "metadata size")
    digest(hash, "metadata digest")
    if (!(id in package_state)) reject("orphan metadata identity: " id)
    else if (package_state[id] != "selected") reject("workspace has metadata: " id)
    key = id SUBSEP release
    if (key in metadata_seen) reject("duplicate metadata row: " id "@" release)
    if (metadata_count > 0 &&
        (id < previous_metadata_id ||
         (id == previous_metadata_id &&
          version_compare(release, previous_metadata_version) <= 0)))
        reject("metadata rows are not in identity/semantic-version order: " id "@" release)
    previous_metadata_id = id
    previous_metadata_version = release
    metadata_seen[key] = 1
    metadata_versions[id]++
    if (metadata_versions[id] > 4096)
        reject("metadata versions for one identity exceed 4096: " id)
    if (!(id in maximum_metadata_version) ||
        version_compare(release, maximum_metadata_version[id]) > 0)
        maximum_metadata_version[id] = release
    if ((id in package_version) && release == package_version[id])
        selected_metadata[id] = 1
    if (hash in digest_size && digest_size[hash] != size)
        reject("one digest carries conflicting sizes: " hash)
    digest_size[hash] = size
    total_metadata_size += size + 0
    if (total_metadata_size > max_total_metadata_size)
        reject("closure metadata bytes exceed 64 MiB")
    print "metadata", id, release, "-", "-", size, hash
    next
}

$1 == "file" {
    phase = 3
    file_count++
    if (file_count > max_files) reject("file descriptor count exceeds 65536")
    if (NF != 7) {
        reject("file row must have seven fields")
        next
    }
    id = $2
    release = $3
    path = $4
    kind = $5
    size = $6
    hash = $7
    identity_version(id, release, "file")
    file_path(path, "file path")
    if (kind != "source" && kind != "data")
        reject("file kind is neither source nor data: " kind)
    canonical_uint(size, max_file_size, "file size")
    digest(hash, "file digest")
    if (!(id in package_state)) reject("orphan file identity: " id)
    else if (package_state[id] != "selected") reject("workspace has file rows: " id)
    else if (release != package_version[id])
        reject("file row is not for the selected version: " id "@" release)
    if (!((id SUBSEP release) in metadata_seen))
        reject("file row has no corresponding metadata row: " id "@" release)
    key = id SUBSEP release SUBSEP path
    if (key in locked_file_seen) reject("duplicate file row: " path)
    if (file_count > 0 &&
        (id < previous_file_id ||
         (id == previous_file_id &&
          (version_compare(release, previous_file_version) < 0 ||
           (release == previous_file_version &&
            ("path:" path) <= ("path:" previous_file_path))))))
        reject("file rows are not in identity/version/path order: " id "@" release ":" path)
    previous_file_id = id
    previous_file_version = release
    previous_file_path = path
    locked_file_seen[key] = 1
    check_path_collision(id, release, path)
    if (hash in digest_size && digest_size[hash] != size)
        reject("one digest carries conflicting sizes: " hash)
    digest_size[hash] = size
    selected_files[id]++
    if (selected_files[id] > 4096)
        reject("files for one selected version exceed 4096: " id)
    package_file_size[id] += size + 0
    total_file_size += size + 0
    if (package_file_size[id] > max_package_file_size)
        reject("selected package file bytes exceed 512 MiB: " id)
    if (total_file_size > max_total_file_size)
        reject("closure file bytes exceed 8 GiB")
    print "file", id, release, path, kind, size, hash
    next
}

{
    reject("unknown or blank lock row kind: " $1)
}

END {
    for (id in package_state) {
        if (package_state[id] == "selected") {
            if (!(id in selected_metadata))
                reject("selected package has no matching metadata row: " id "@" package_version[id])
            if ((id in maximum_metadata_version) &&
                package_version[id] != maximum_metadata_version[id])
                reject("selected version is not the maximum recorded metadata version: " id "@" package_version[id])
            if (!(id in selected_files))
                reject("selected package has no file row: " id "@" package_version[id])
        }
    }
    if (suppressed)
        printf "lock-v2: %d additional structural violation(s) suppressed\n", suppressed > "/dev/stderr"
    exit bad ? 1 : 0
}
