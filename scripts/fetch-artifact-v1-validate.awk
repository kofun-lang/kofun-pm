# Validate the deliberately narrow scalar surface of the pinned single-object
# HTTPS qualification. protocol-v1-validate.awk supplies origin() and digest().

function reject(message) {
    if (!bad)
        printf "fetch-artifact-v1: %s\n", message > "/dev/stderr"
    bad = 1
}

function bounded_decimal(value, maximum, label) {
    if (value == "" || value ~ /[^0-9]/ ||
        (length(value) > 1 && substr(value, 1, 1) == "0")) {
        reject(label " is not canonical unsigned decimal: " value)
        return 0
    }
    if (length(value) > length(maximum) ||
        (length(value) == length(maximum) && value > maximum)) {
        reject(label " exceeds its bound: " value)
        return 0
    }
    return 1
}

function request_target(value, parts, count, i) {
    if (value == "" || length(value) > 4096 ||
        substr(value, 1, 1) != "/" || value ~ /^\/\// ||
        value ~ /[^A-Za-z0-9._~@\/-]/) {
        reject("request target is not one bounded canonical absolute path: " value)
        return 0
    }
    count = split(substr(value, 2), parts, "/")
    for (i = 1; i <= count; i++) {
        if (parts[i] == "" || parts[i] == "." || parts[i] == "..") {
            reject("request target has an empty or dot segment: " value)
            return 0
        }
    }
    return 1
}

function canonical_ipv4(value, parts, count, i) {
    if (value == "" || length(value) > 15 || value ~ /[^0-9.]/) {
        reject("pinned peer is not canonical IPv4 text: " value)
        return 0
    }
    count = split(value, parts, "\\.")
    if (count != 4) {
        reject("pinned peer is not four IPv4 components: " value)
        return 0
    }
    for (i = 1; i <= 4; i++) {
        if (parts[i] == "" || parts[i] ~ /[^0-9]/ ||
            (length(parts[i]) > 1 && substr(parts[i], 1, 1) == "0") ||
            length(parts[i]) > 3 || (parts[i] + 0) > 255) {
            reject("pinned peer has a non-canonical IPv4 component: " value)
            return 0
        }
    }
    return 1
}

BEGIN {
    max_component = 2147483647
    artifact_class = ENVIRON["KPM_FETCH_CLASS"]
    requested_origin = ENVIRON["KPM_FETCH_ORIGIN"]
    requested_target = ENVIRON["KPM_FETCH_TARGET"]
    requested_ipv4 = ENVIRON["KPM_FETCH_IPV4"]
    requested_size = ENVIRON["KPM_FETCH_SIZE"]
    requested_digest = ENVIRON["KPM_FETCH_DIGEST"]

    if (artifact_class != "metadata" && artifact_class != "blob")
        reject("class is not exactly metadata or blob: " artifact_class)
    origin(requested_origin, "origin")
    request_target(requested_target)
    canonical_ipv4(requested_ipv4)
    maximum = artifact_class == "metadata" ? "1048576" : "67108864"
    bounded_decimal(requested_size, maximum, artifact_class " byte size")
    digest(requested_digest, artifact_class " digest")

    if (bad) exit 1
    print "host\t" substr(requested_origin, 9)
}
