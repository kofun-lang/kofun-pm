# Validate one requested remote identity/version using the shared protocol-v1
# grammar. Values arrive through the environment so awk command-line escape
# processing cannot normalize hostile backslashes before validation.

BEGIN {
    max_component = 2147483647
    requested_identity = ENVIRON["KPM_METADATA_IDENTITY"]
    requested_version = ENVIRON["KPM_METADATA_VERSION"]
    if (!identity_version(requested_identity, requested_version,
        "requested metadata"))
        exit 1
    exit 0
}

function reject(message) {
    if (!bad)
        printf "metadata-v1: %s\n", message > "/dev/stderr"
    bad = 1
}
