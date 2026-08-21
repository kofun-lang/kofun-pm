#!/bin/sh
set -eu

# Test-only handoff corruption. Let the exact-name rename finish, then alter
# the private copy at its destination so the caller's final rehash must catch
# the change.
: "${KPM_REAL_MV:?KPM_REAL_MV is required}"
: "${KPM_MV_CORRUPT_DEST:?KPM_MV_CORRUPT_DEST is required}"

"$KPM_REAL_MV" "$@"
chmod 644 "$KPM_MV_CORRUPT_DEST"
printf 'changed after handoff\n' >"$KPM_MV_CORRUPT_DEST"
chmod 444 "$KPM_MV_CORRUPT_DEST"
