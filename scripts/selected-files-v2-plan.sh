#!/bin/sh
set -eu

# Derive one canonical pre-acquisition inventory from supplied requirements,
# strict lock v2, and its retained metadata CAS objects. Selected file objects
# are outputs of this plan, so this adapter neither opens nor requires them.
#
#   scripts/selected-files-v2-plan.sh inspect REQUIREMENTS LOCK \
#     --store ABSOLUTE_STORE

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
REQUIREMENTS_TOOL=$ROOT/scripts/requirements-v2-plan.sh
LOCK_TOOL=$ROOT/scripts/lock-v2.sh
GRAPH_VALIDATOR=$ROOT/scripts/rough-graph-v2-validate.awk

fail() {
    printf 'selected-files-v2-plan: %s\n' "$*" >&2
    exit 1
}

test "${1:-}" = inspect && test "$#" -eq 5 && test "${4:-}" = --store ||
    fail 'usage: scripts/selected-files-v2-plan.sh inspect REQUIREMENTS LOCK --store ABSOLUTE_STORE'
INPUT_REQUIREMENTS=$2
INPUT_LOCK=$3
STORE=$5

test -x "$REQUIREMENTS_TOOL" ||
    fail "requirements-v2 plan adapter is missing: $REQUIREMENTS_TOOL"
test -x "$LOCK_TOOL" || fail "lock-v2 adapter is missing: $LOCK_TOOL"
test -f "$GRAPH_VALIDATOR" ||
    fail "rough-graph validator is missing: $GRAPH_VALIDATOR"

work=$(mktemp -d "${TMPDIR:-/tmp}/kofun-pm-selected-files-v2-plan.XXXXXX")
trap 'rm -rf "$work"' 0 1 2 15

/bin/sh "$REQUIREMENTS_TOOL" inspect "$INPUT_REQUIREMENTS" \
    >"$work/requirements.plan"
tab=$(printf '\t')
requirements_digest=$(LC_ALL=C awk -F "$tab" \
    '$1 == "requirements" { print $7 }' "$work/requirements.plan")
test -n "$requirements_digest" ||
    fail 'requirements plan did not retain its exact digest'

/bin/sh "$LOCK_TOOL" graph-prefetch-plan "$INPUT_LOCK" --store "$STORE" \
    --requirements-digest "$requirements_digest" >"$work/lock.plan"
lock_tool=$(LC_ALL=C awk -F "$tab" '$1 == "lock" { print $5 }' \
    "$work/lock.plan")
lock_self=$(LC_ALL=C awk -F "$tab" '$1 == "lock" { print $7 }' \
    "$work/lock.plan")
test -n "$lock_tool" && test -n "$lock_self" ||
    fail 'normalized lock plan did not retain its tool and self digests'

if ! LC_ALL=C awk -f "$GRAPH_VALIDATOR" \
    "$work/requirements.plan" "$work/lock.plan" >"$work/graph.summary"
then
    fail 'supplied requirements/lock/metadata rough graph is inconsistent'
fi
IFS="$tab" read -r summary roots members remote_pairs selected edges \
    <"$work/graph.summary"
test "$summary" = summary ||
    fail 'rough-graph validator returned no complete summary'

LC_ALL=C awk -F "$tab" -v OFS="$tab" '
    $1 == "metadata" {
        metadata++
        if ($8 == "selected") selected_metadata++
        print "metadata", $2, $3, $6, $7, $8
    }
    $1 == "file" {
        files++
        file_bytes += $6
        print "file", $2, $3, $4, $5, $6, $7
    }
    END {
        print "inventory", metadata + 0, selected_metadata + 0, files + 0,
            file_bytes + 0
    }
' "$work/lock.plan" >"$work/inventory"
tail -n 1 "$work/inventory" >"$work/inventory.summary"
IFS="$tab" read -r inventory metadata selected_metadata files file_bytes \
    <"$work/inventory.summary"
test "$inventory" = inventory ||
    fail 'normalized lock plan returned no complete inventory'
test "$metadata" -eq "$remote_pairs" ||
    fail 'retained metadata count disagrees with the reachable exact-pair count'
test "$selected_metadata" -eq "$selected" ||
    fail 'selected metadata count disagrees with the MVS-selected identity count'

{
    printf 'prefetch-plan\t%s\t%s\t%s\n' \
        "$lock_self" "$lock_tool" "$requirements_digest"
    sed '$d' "$work/inventory"
    printf 'summary\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$roots" "$members" "$remote_pairs" "$selected" "$edges" \
        "$metadata" "$files" "$file_bytes"
} >"$work/complete.plan"
cat "$work/complete.plan"
