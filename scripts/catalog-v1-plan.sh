#!/bin/sh
set -eu

# Produce the normalized plan for one strict supplied identity, authority, and
# catalog. Policy approval deliberately precedes opening the catalog pathname.
# Both catalog-history and metadata-descriptor inspection consume this one
# adapter so input bounds, snapshot order, and canonical catalog grammar do
# not drift.
#
#   scripts/catalog-v1-plan.sh inspect IDENTITY CATALOG --authority AUTHORITY

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PROTOCOL_VALIDATOR=$ROOT/scripts/protocol-v1-validate.awk
CATALOG_VALIDATOR=$ROOT/scripts/catalog-v1-validate.awk
AUTHORITY_VALIDATOR=$ROOT/scripts/authority-v1-validate.awk
MAX_CATALOG_BYTES=1048576
MAX_CATALOG_ROWS=4097
MAX_AUTHORITY_BYTES=524288
MAX_AUTHORITY_ROWS=2049
MAX_LINE_BYTES=4096

fail() {
    printf 'catalog-v1: %s\n' "$*" >&2
    exit 1
}

snapshot() {
    snapshot_label=$1
    snapshot_input=$2
    snapshot_maximum=$3
    snapshot_output=$4
    test ! -L "$snapshot_input" && test -f "$snapshot_input" ||
        fail "$snapshot_label is not a regular non-symlink file: $snapshot_input"
    head -c "$((snapshot_maximum + 1))" <"$snapshot_input" >"$snapshot_output" ||
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

test "${1:-}" = inspect && test "$#" -eq 5 && test "${4:-}" = --authority ||
    fail 'usage: scripts/catalog-v1-plan.sh inspect IDENTITY CATALOG --authority AUTHORITY'
IDENTITY=$2
INPUT_CATALOG=$3
INPUT_AUTHORITY=$5

for required in "$PROTOCOL_VALIDATOR" "$CATALOG_VALIDATOR" "$AUTHORITY_VALIDATOR"; do
    test -f "$required" || fail "validator is missing: $required"
done
identity_plan=$(KPM_CATALOG_IDENTITY=$IDENTITY LC_ALL=C awk \
    -v identity_environment=KPM_CATALOG_IDENTITY -v identity_only=1 \
    -f "$PROTOCOL_VALIDATOR" -f "$CATALOG_VALIDATOR" /dev/null) ||
        fail 'identity grammar is invalid'
tab=$(printf '\t')
origin=${identity_plan##*"$tab"}
test -n "$origin" || fail 'validated identity did not retain its exact origin'

work=$(mktemp -d "${TMPDIR:-/tmp}/kofun-pm-catalog-v1-plan.XXXXXX")
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
catalog_origin=$(LC_ALL=C awk -F "$tab" '$1 == "identity" { print $3 }' "$work/catalog.plan")
test "$catalog_origin" = "$origin" ||
    fail 'catalog validation did not retain the exact approved identity origin'
cat "$work/catalog.plan"
