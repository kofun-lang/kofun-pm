# Validate one requested identity/version plus an exact catalog-derived
# metadata descriptor. Values arrive through the environment so awk argv
# escape processing cannot normalize hostile backslashes.

BEGIN {
    max_component = 2147483647
    requested_identity = ENVIRON["KPM_METADATA_IDENTITY"]
    requested_version = ENVIRON["KPM_METADATA_VERSION"]
    requested_size = ENVIRON["KPM_METADATA_SIZE"]
    requested_digest = ENVIRON["KPM_METADATA_DIGEST"]
    if (!identity_version(requested_identity, requested_version,
        "requested metadata"))
        bad = 1
    if (!canonical_uint(requested_size, 1048576,
        "metadata descriptor size"))
        bad = 1
    if (!digest(requested_digest, "metadata descriptor digest"))
        bad = 1
    if (!bad)
        print "descriptor\t" requested_size "\t" requested_digest
    exit bad ? 1 : 0
}

function reject(message) {
    if (!bad)
        printf "metadata-v1: %s\n", message > "/dev/stderr"
    bad = 1
}
