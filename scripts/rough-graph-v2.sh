#!/bin/sh
set -eu

# Prove one supplied canonical requirements document and one supplied strict
# lock/store describe exactly the same rough graph and MVS selection.
#
#   scripts/rough-graph-v2.sh inspect REQUIREMENTS LOCK --store ABSOLUTE_STORE

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
REQUIREMENTS_TOOL=$ROOT/scripts/requirements-v2-plan.sh
LOCK_TOOL=$ROOT/scripts/lock-v2.sh
VALIDATOR=$ROOT/scripts/rough-graph-v2-validate.awk

fail() {
    printf 'rough-graph-v2: %s\n' "$*" >&2
    exit 1
}

test "${1:-}" = inspect && test "$#" -eq 5 && test "${4:-}" = --store ||
    fail 'usage: scripts/rough-graph-v2.sh inspect REQUIREMENTS LOCK --store ABSOLUTE_STORE'
INPUT_REQUIREMENTS=$2
INPUT_LOCK=$3
STORE=$5

test -x "$REQUIREMENTS_TOOL" ||
    fail "requirements-v2 plan adapter is missing: $REQUIREMENTS_TOOL"
test -x "$LOCK_TOOL" || fail "lock-v2 adapter is missing: $LOCK_TOOL"
test -f "$VALIDATOR" || fail "rough-graph validator is missing: $VALIDATOR"

work=$(mktemp -d "${TMPDIR:-/tmp}/kofun-pm-rough-graph-v2.XXXXXX")
trap 'rm -rf "$work"' 0 1 2 15

sh "$REQUIREMENTS_TOOL" inspect "$INPUT_REQUIREMENTS" \
    >"$work/requirements.plan"
tab=$(printf '\t')
requirements_digest=$(LC_ALL=C awk -F "$tab" \
    '$1 == "requirements" { print $7 }' "$work/requirements.plan")
test -n "$requirements_digest" ||
    fail 'requirements plan did not retain its exact digest'

sh "$LOCK_TOOL" graph-plan "$INPUT_LOCK" --store "$STORE" \
    --requirements-digest "$requirements_digest" >"$work/lock.plan"

LC_ALL=C awk -f "$VALIDATOR" "$work/requirements.plan" "$work/lock.plan" \
    >"$work/summary" || fail 'supplied requirements/lock/store rough graph is inconsistent'
IFS="$tab" read -r record roots members remote_pairs selected edges <"$work/summary"
test "$record" = summary || fail 'rough-graph validator returned no complete summary'

printf 'rough-graph-v2: exact current tool closure and supplied requirements/lock/store rough graph passed: %s root requirement(s), %s workspace member(s), %s reachable remote identity/version pair(s), %s selected remote identity(ies), %s total requirement/dependency edge row(s)\n' \
    "$roots" "$members" "$remote_pairs" "$selected" "$edges"
printf 'rough-graph-v2: supplied offline graph inputs and current local tool closure only; manifest parsing, catalog authenticity/history/non-equivocation, acquisition, store publication, lock writer/migration/replacement, fetch, atomic global inventory, project build execution, and affine same-handle consumption remain outside this slice\n'
