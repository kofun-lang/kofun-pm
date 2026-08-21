#!/bin/sh
set -eu

# Test-only link(2) barrier. Every concurrent publisher reaches the real ln
# call before any one is allowed to create the final name, so a check-then-
# overwrite implementation cannot pass by scheduler luck.
: "${KPM_REAL_LN:?KPM_REAL_LN is required}"

# A second mode installs a directory symlink at the exact publication target
# immediately before the real ln. The production command must refuse that
# target, never reinterpret it as a directory and create a nested hard link.
if test -n "${KPM_LN_ATTACK_TARGET:-}"; then
    : "${KPM_LN_ATTACK_OUTSIDE:?KPM_LN_ATTACK_OUTSIDE is required}"
    "$KPM_REAL_LN" -s "$KPM_LN_ATTACK_OUTSIDE" "$KPM_LN_ATTACK_TARGET"
    exec "$KPM_REAL_LN" "$@"
fi

: "${KPM_LN_BARRIER:?KPM_LN_BARRIER is required}"
: "${KPM_LN_EXPECTED:?KPM_LN_EXPECTED is required}"

mktemp "$KPM_LN_BARRIER/caller.XXXXXX" >/dev/null
attempt=0
while :; do
    arrived=$(find "$KPM_LN_BARRIER" -type f -name 'caller.*' |
        wc -l | tr -d ' ')
    test "$arrived" -ge "$KPM_LN_EXPECTED" && break
    attempt=$((attempt + 1))
    test "$attempt" -lt 30 || {
        printf 'ln barrier: only %s of %s publishers arrived\n' \
            "$arrived" "$KPM_LN_EXPECTED" >&2
        exit 1
    }
    sleep 1
done

exec "$KPM_REAL_LN" "$@"
