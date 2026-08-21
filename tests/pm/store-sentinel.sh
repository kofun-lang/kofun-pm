#!/bin/sh
set -eu

# Test-only wrapper placed beside a private copy of the real store tool.  It
# makes every snapshot/admit attempt observable without granting the production
# fetch command an environment-variable injection point.
case $0 in
    */*) sentinel_dir=${0%/*} ;;
    *) sentinel_dir=. ;;
esac
printf '%s\n' "$*" >>"$sentinel_dir/store.calls"
exec /bin/sh "$sentinel_dir/store-real.sh" "$@"
