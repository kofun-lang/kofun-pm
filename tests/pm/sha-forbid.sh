#!/bin/sh
set -eu

# Test-only proof that a size mismatch is refused before hashing.
: "${KPM_SHA_MARKER:?KPM_SHA_MARKER is required}"
printf 'sha256 was called\n' >"$KPM_SHA_MARKER"
exit 97
