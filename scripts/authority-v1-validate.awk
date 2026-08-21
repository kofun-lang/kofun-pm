# Strict parser for one bounded private kofun-fetch-authority/v1 snapshot.
# The shell caller checks byte grammar, framing, line length, and row count.

BEGIN {
    FS = "\t"
    OFS = "\t"
    max_component = 2147483647
    max_origins = 2048
}

function reject(message) {
    if (!bad)
        printf "catalog-v1: authority row %d: %s\n", NR, message > "/dev/stderr"
    else
        suppressed++
    bad = 1
}

NR == 1 {
    if (NF != 1 || $1 != "kofun-fetch-authority/v1")
        reject("first line is not exactly kofun-fetch-authority/v1")
    header_seen = 1
    next
}

{
    origin_count++
    if (origin_count > max_origins)
        reject("approved origin count exceeds 2048")
    if (NF != 2 || $1 != "origin") {
        reject("authority row is not exactly origin<TAB>HTTPS_ORIGIN")
        next
    }
    candidate = $2
    origin(candidate, "approved origin")
    if (origin_count > 1 && candidate <= previous_origin)
        reject("approved origins are not in strict byte order: " candidate)
    previous_origin = candidate
    approved[origin_count] = candidate
}

END {
    if (!header_seen) reject("authority is empty")
    if (suppressed)
        printf "catalog-v1: %d additional authority violation(s) suppressed\n", suppressed > "/dev/stderr"
    if (bad) exit 1
    for (i = 1; i <= origin_count; i++)
        print "origin", approved[i]
}
