#!/bin/sh
set -eu

# Inspect exactly one supplied identity/catalog snapshot against one explicit
# authority snapshot and, optionally, the exact descriptors in one supplied
# strict lock v2. This has no network, acquisition, or persistence path.
#
#   scripts/catalog-v1.sh inspect IDENTITY CATALOG --authority AUTHORITY
#   scripts/catalog-v1.sh inspect IDENTITY CATALOG --authority AUTHORITY --history-lock LOCK

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PLAN_TOOL=$ROOT/scripts/catalog-v1-plan.sh
LOCK_STRUCTURE_TOOL=$ROOT/scripts/lock-v2-structure.sh

fail() {
    printf 'catalog-v1: %s\n' "$*" >&2
    exit 1
}

usage() {
    fail 'usage: scripts/catalog-v1.sh inspect IDENTITY CATALOG --authority AUTHORITY [--history-lock LOCK]'
}

test "${1:-}" = inspect || usage
case $# in
    5)
        test "${4:-}" = --authority || usage
        HISTORY_LOCK=
        ;;
    7)
        test "${4:-}" = --authority && test "${6:-}" = --history-lock || usage
        HISTORY_LOCK=$7
        ;;
    *) usage ;;
esac
IDENTITY=$2
INPUT_CATALOG=$3
INPUT_AUTHORITY=$5

test -x "$PLAN_TOOL" || fail "catalog-v1 plan adapter is missing: $PLAN_TOOL"
test -z "$HISTORY_LOCK" || test -x "$LOCK_STRUCTURE_TOOL" ||
    fail "lock-v2 structure adapter is missing: $LOCK_STRUCTURE_TOOL"

work=$(mktemp -d "${TMPDIR:-/tmp}/kofun-pm-catalog-v1.XXXXXX")
trap 'rm -rf "$work"' 0 1 2 15

sh "$PLAN_TOOL" inspect "$IDENTITY" "$INPUT_CATALOG" --authority \
    "$INPUT_AUTHORITY" >"$work/catalog.plan"

if test -n "$HISTORY_LOCK"; then
    sh "$LOCK_STRUCTURE_TOOL" inspect "$HISTORY_LOCK" >"$work/history.plan"
else
    : >"$work/history.plan"
fi

tab=$(printf '\t')
origin=$(LC_ALL=C awk -F "$tab" '$1 == "identity" { print $3 }' "$work/catalog.plan")
test -n "$origin" || fail 'validated catalog plan did not retain the identity origin'

if test -z "$HISTORY_LOCK"; then
    versions=$(LC_ALL=C awk -F "$tab" '$1 == "catalog" { count++ } END { print count + 0 }' \
        "$work/catalog.plan")
    printf 'catalog-v1: first observation passed for %s: origin %s is explicitly approved and %s catalog version(s) passed supplied-byte structure\n' \
        "$IDENTITY" "$origin" "$versions"
    printf 'catalog-v1: supplied identity, catalog, and authority bytes only; no observation ledger was read or written, and catalog authenticity/non-equivocation, HTTPS/TLS/DNS/redirect/peer checks, acquisition, metadata/blob parsing, whole-fetch bounds, graph/MVS, persistence, writer/migration/fetch, and same-handle consumption remain outside this slice\n'
else
    if ! KPM_CATALOG_IDENTITY=$IDENTITY LC_ALL=C awk -F "$tab" '
        BEGIN { expected_identity = ENVIRON["KPM_CATALOG_IDENTITY"] }
        NR == FNR {
            if ($1 == "catalog") {
                current_size[$2] = $3
                current_digest[$2] = $4
            }
            next
        }
        $1 == "metadata" && $2 == expected_identity {
            compared++
            release = $3
            old_size = $6
            old_digest = $7
            if (!(release in current_size)) {
                printf "catalog-v1: withdrawal/history violation\n  identity %s\n  version  %s\n  locked   size=%s sha256=%s\n  catalog  missing\n", expected_identity, release, old_size, old_digest > "/dev/stderr"
                bad = 1
                next
            }
            if (current_size[release] != old_size || current_digest[release] != old_digest) {
                printf "catalog-v1: immutability violation: descriptor changed\n  identity %s\n  version  %s\n  locked   size=%s sha256=%s\n  catalog  size=%s sha256=%s\n", expected_identity, release, old_size, old_digest, current_size[release], current_digest[release] > "/dev/stderr"
                bad = 1
            }
        }
        END {
            if (bad) exit 1
            print compared + 0
        }
    ' "$work/catalog.plan" "$work/history.plan" >"$work/history-count"
    then
        fail 'supplied lock descriptor continuity failed'
    fi
    compared=$(sed -n '1p' "$work/history-count")
    versions=$(LC_ALL=C awk -F "$tab" '$1 == "catalog" { count++ } END { print count + 0 }' \
        "$work/catalog.plan")
    if test "$compared" -eq 0; then
        printf 'catalog-v1: first observation passed for %s against the supplied lock: origin %s is explicitly approved, that lock records no metadata descriptor for this identity, and %s catalog version(s) passed structure\n' \
            "$IDENTITY" "$origin" "$versions"
    else
        printf 'catalog-v1: supplied-lock continuity passed for %s: origin %s is explicitly approved, %s prior metadata descriptor(s) matched, and %s catalog version(s) passed structure\n' \
            "$IDENTITY" "$origin" "$compared" "$versions"
    fi
    printf 'catalog-v1: supplied identity, catalog, authority, and one supplied lock\047s recorded descriptors only; full catalog history, catalog authenticity/non-equivocation, HTTPS/TLS/DNS/redirect/peer checks, acquisition, metadata/blob parsing, whole-fetch bounds, graph/MVS, persistence, writer/migration/fetch, and same-handle consumption remain outside this slice\n'
fi
