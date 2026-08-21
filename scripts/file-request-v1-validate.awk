# Validate one requested remote identity/version/logical file path. Values
# arrive through the environment so awk argv escape processing cannot
# normalize hostile backslashes before validation.

BEGIN {
    max_component = 2147483647
    requested_identity = ENVIRON["KPM_FILE_IDENTITY"]
    requested_version = ENVIRON["KPM_FILE_VERSION"]
    requested_path = ENVIRON["KPM_FILE_PATH"]
    if (!identity_version(requested_identity, requested_version,
        "requested file"))
        bad = 1
    if (!file_path(requested_path, "requested file path"))
        bad = 1
    if (!bad)
        print "request\t" requested_identity "\t" requested_version \
            "\t" requested_path
    exit bad ? 1 : 0
}

function reject(message) {
    if (!bad)
        printf "fetch-file-v1: %s\n", message > "/dev/stderr"
    bad = 1
}
