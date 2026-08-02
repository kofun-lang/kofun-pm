#!/bin/sh
set -eu

# The inner loop.
#
#   scripts/dev.sh          the unit suite, a build, and the gate
#   scripts/dev.sh --test   the unit suite alone
#   scripts/dev.sh --watch  re-run on every save
#   scripts/dev.sh --check  exactly what CI runs, in CI's order
#
# A developer's green and a pipeline's green are the same commands, so they
# cannot come to mean different things.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
KOTEST="$ROOT/vendor/kofun/tooling/kotest/run.sh"

case "${1:-}" in
    --test)
        shift
        sh "$KOTEST" "$ROOT/seed/resolver/core_test.kofun" \
            "$ROOT/seed/derivation/core_test.kofun" "$@"
        ;;
    --watch)
        shift
        sh "$KOTEST" --watch "$ROOT/seed/resolver/core_test.kofun" \
            "$ROOT/seed/derivation/core_test.kofun" "$@"
        ;;
    --check|"")
        sh "$KOTEST" "$ROOT/seed/resolver/core_test.kofun" \
            "$ROOT/seed/derivation/core_test.kofun"
        sh "$ROOT/tests/pm/check.sh"
        ;;
    *)
        sed -n '3,9p' "$0" | sed 's/^# \{0,1\}//'
        exit 2
        ;;
esac
