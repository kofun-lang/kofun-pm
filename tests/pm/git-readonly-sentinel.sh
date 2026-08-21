#!/bin/sh
set -eu

test "${GIT_OPTIONAL_LOCKS:-}" = 0 &&
    test "${GIT_NO_REPLACE_OBJECTS:-}" = 1 &&
    test "${GIT_NO_LAZY_FETCH:-}" = 1 || {
    printf 'required read-only Git environment was not fixed\n' >&2
    : >"$KPM_NETWORK_SENTINEL"
    exit 97
}

prefix="-c core.fsmonitor=false -c core.untrackedCache=false -c core.fileMode=true -c core.ignoreStat=false"
root_index="$prefix -C $KPM_GIT_ROOT ls-files --stage -- vendor/kofun"
vendor_head="$prefix -C $KPM_GIT_ROOT/vendor/kofun rev-parse HEAD"
vendor_flags="$prefix -C $KPM_GIT_ROOT/vendor/kofun ls-files -v --"
vendor_staged="$prefix -C $KPM_GIT_ROOT/vendor/kofun diff-index --cached --quiet HEAD --"
vendor_worktree="$prefix -C $KPM_GIT_ROOT/vendor/kofun diff-files --quiet --"
case "$*" in
    "$root_index"|"$vendor_head"|"$vendor_flags"|"$vendor_staged"|"$vendor_worktree")
        exec "$KPM_REAL_GIT" "$@"
        ;;
esac

printf 'forbidden Git operation attempted: %s\n' "$*" >&2
: >"$KPM_NETWORK_SENTINEL"
exit 97
