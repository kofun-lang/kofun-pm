#!/bin/sh
set -eu

# Inspect exactly one supplied identity/catalog snapshot against one explicit
# authority snapshot and, optionally, the exact descriptors in one supplied
# strict lock v2. This has no network, acquisition, or persistence path.
#
#   scripts/catalog-v1.sh inspect IDENTITY CATALOG --authority AUTHORITY
#   scripts/catalog-v1.sh inspect IDENTITY CATALOG --authority AUTHORITY --history-lock LOCK

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PROTOCOL_VALIDATOR=$ROOT/scripts/protocol-v1-validate.awk
CATALOG_VALIDATOR=$ROOT/scripts/catalog-v1-validate.awk
AUTHORITY_VALIDATOR=$ROOT/scripts/authority-v1-validate.awk
LOCK_STRUCTURE_TOOL=$ROOT/scripts/lock-v2-structure.sh
MAX_CATALOG_BYTES=1048576
MAX_CATALOG_ROWS=4097
MAX_AUTHORITY_BYTES=524288
MAX_AUTHORITY_ROWS=2049
MAX_LINE_BYTES=4096

fail() {
    printf 'catalog-v1: %s\n' "$*" >&2
    exit 1
}

usage() {
    fail 'usage: scripts/catalog-v1.sh inspect IDENTITY CATALOG --authority AUTHORITY [--history-lock LOCK]'
}

snapshot() {
    snapshot_label=$1
    snapshot_input=$2
    snapshot_maximum=$3
    snapshot_output=$4
    test ! -L "$snapshot_input" && test -f "$snapshot_input" ||
        fail "$snapshot_label is not a regular non-symlink file: $snapshot_input"
    head -c $((snapshot_maximum + 1)) "$snapshot_input" >"$snapshot_output" ||
        fail "could not read the $snapshot_label snapshot: $snapshot_input"
    snapshot_bytes=$(wc -c <"$snapshot_output" | tr -d ' ')
    test "$snapshot_bytes" -le "$snapshot_maximum" ||
        fail "$snapshot_label exceeds the $snapshot_maximum-byte input bound: $snapshot_bytes"
    chmod 400 "$snapshot_output"
}

framing() {
    framing_label=$1
    framing_input=$2
    framing_max_rows=$3
    LC_ALL=C tr -d '\011\012\040-\176' <"$framing_input" >"$work/non-ascii.$framing_label"
    test ! -s "$work/non-ascii.$framing_label" ||
        fail "$framing_label contains a byte outside ASCII, HT, and LF"
    framing_last_byte=$(tail -c 1 "$framing_input" | od -An -tu1 | tr -d ' ')
    test "$framing_last_byte" = 10 || fail "$framing_label must end in exactly one LF"
    framing_longest=$(LC_ALL=C wc -L <"$framing_input" | tr -d ' ')
    test "$framing_longest" -le "$MAX_LINE_BYTES" ||
        fail "$framing_label line exceeds the $MAX_LINE_BYTES-byte structural bound: $framing_longest"
    framing_rows=$(wc -l <"$framing_input" | tr -d ' ')
    test "$framing_rows" -le "$framing_max_rows" ||
        fail "$framing_label exceeds the $framing_max_rows-row structural bound: $framing_rows"
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

for required in "$PROTOCOL_VALIDATOR" "$CATALOG_VALIDATOR" "$AUTHORITY_VALIDATOR"; do
    test -f "$required" || fail "validator is missing: $required"
done
test -z "$HISTORY_LOCK" || test -x "$LOCK_STRUCTURE_TOOL" ||
    fail "lock-v2 structure adapter is missing: $LOCK_STRUCTURE_TOOL"
identity_plan=$(KPM_CATALOG_IDENTITY=$IDENTITY LC_ALL=C awk \
    -v identity_environment=KPM_CATALOG_IDENTITY -v identity_only=1 \
    -f "$PROTOCOL_VALIDATOR" -f "$CATALOG_VALIDATOR" /dev/null) ||
        fail 'identity grammar is invalid'
tab=$(printf '\t')
origin=${identity_plan##*"$tab"}
test -n "$origin" || fail 'validated identity did not retain its exact origin'

work=$(mktemp -d "${TMPDIR:-/tmp}/kofun-pm-catalog-v1.XXXXXX")
trap 'rm -rf "$work"' 0 1 2 15

snapshot authority "$INPUT_AUTHORITY" "$MAX_AUTHORITY_BYTES" "$work/authority.snapshot"
framing authority "$work/authority.snapshot" "$MAX_AUTHORITY_ROWS"

LC_ALL=C awk -f "$PROTOCOL_VALIDATOR" -f "$AUTHORITY_VALIDATOR" \
    "$work/authority.snapshot" >"$work/authority.plan" ||
    fail 'authority grammar is invalid'
LC_ALL=C awk -F "$tab" -v expected="$origin" \
    '$1 == "origin" && $2 == expected { approved = 1 }
     END { exit approved ? 0 : 1 }' "$work/authority.plan" ||
    fail "identity origin is not explicitly approved: $origin"

snapshot catalog "$INPUT_CATALOG" "$MAX_CATALOG_BYTES" "$work/catalog.snapshot"
framing catalog "$work/catalog.snapshot" "$MAX_CATALOG_ROWS"
KPM_CATALOG_IDENTITY=$IDENTITY LC_ALL=C awk \
    -v identity_environment=KPM_CATALOG_IDENTITY -f "$PROTOCOL_VALIDATOR" \
    -f "$CATALOG_VALIDATOR" "$work/catalog.snapshot" >"$work/catalog.plan" ||
    fail 'catalog grammar is invalid'

if test -n "$HISTORY_LOCK"; then
    sh "$LOCK_STRUCTURE_TOOL" inspect "$HISTORY_LOCK" >"$work/history.plan"
else
    : >"$work/history.plan"
fi

catalog_origin=$(LC_ALL=C awk -F "$tab" '$1 == "identity" { print $3 }' "$work/catalog.plan")
test "$catalog_origin" = "$origin" ||
    fail 'catalog validation did not retain the exact approved identity origin'

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
