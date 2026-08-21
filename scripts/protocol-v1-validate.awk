# Canonical protocol-v1 scalar and path validators shared by lock-v2 and
# metadata-v1 parsers. Each caller supplies reject(message), max_component,
# and a fresh awk process/global namespace.

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

function identity_version(value, release, label, parts, major, suffix,
                          without_slash, slash_count, path_parts, tail) {
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

function check_path_collision(scope, path, segments, count, i, prefix,
                              folded, key) {
    folded = tolower(path)
    key = scope SUBSEP folded
    if (key in protocol_file_seen) {
        reject("file path duplicates after ASCII case folding: " path)
        return 0
    }
    if (key in protocol_directory_seen) {
        reject("file path is a prefix of another file path: " path)
        return 0
    }
    count = split(folded, segments, "/")
    prefix = ""
    for (i = 1; i < count; i++) {
        prefix = (prefix == "" ? segments[i] : prefix "/" segments[i])
        if ((scope SUBSEP prefix) in protocol_file_seen) {
            reject("file path descends through another file: " path)
            return 0
        }
        protocol_directory_seen[scope SUBSEP prefix] = 1
    }
    protocol_file_seen[key] = 1
    return 1
}
