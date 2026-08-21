#!/bin/sh
set -eu

# Bind one supplied metadata document to the exact descriptor in one supplied
# catalog. Authority approval and complete catalog validation happen before
# the metadata pathname is opened. The metadata bytes then pass size, digest,
# and strict grammar in that order.
#
#   scripts/metadata-v1.sh inspect IDENTITY VERSION METADATA \
#     --catalog CATALOG --authority AUTHORITY

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CATALOG_PLAN_TOOL=$ROOT/scripts/catalog-v1-plan.sh
METADATA_PLAN_TOOL=$ROOT/scripts/metadata-v1-plan.sh
PROTOCOL_VALIDATOR=$ROOT/scripts/protocol-v1-validate.awk
REQUEST_VALIDATOR=$ROOT/scripts/metadata-request-v1-validate.awk

fail() {
    printf 'metadata-v1: %s\n' "$*" >&2
    exit 1
}

test "${1:-}" = inspect && test "$#" -eq 8 &&
    test "${5:-}" = --catalog && test "${7:-}" = --authority ||
    fail 'usage: scripts/metadata-v1.sh inspect IDENTITY VERSION METADATA --catalog CATALOG --authority AUTHORITY'
IDENTITY=$2
VERSION=$3
INPUT_METADATA=$4
INPUT_CATALOG=$6
INPUT_AUTHORITY=$8

for tool in "$CATALOG_PLAN_TOOL" "$METADATA_PLAN_TOOL"; do
    test -x "$tool" || fail "plan adapter is missing: $tool"
done
for required in "$PROTOCOL_VALIDATOR" "$REQUEST_VALIDATOR"; do
    test -f "$required" || fail "validator is missing: $required"
done
KPM_METADATA_IDENTITY=$IDENTITY KPM_METADATA_VERSION=$VERSION LC_ALL=C awk \
    -f "$PROTOCOL_VALIDATOR" -f "$REQUEST_VALIDATOR" /dev/null ||
    fail 'requested identity/version grammar is invalid'

work=$(mktemp -d "${TMPDIR:-/tmp}/kofun-pm-metadata-v1.XXXXXX")
trap 'rm -rf "$work"' 0 1 2 15

sh "$CATALOG_PLAN_TOOL" inspect "$IDENTITY" "$INPUT_CATALOG" --authority \
    "$INPUT_AUTHORITY" >"$work/catalog.plan"
tab=$(printf '\t')
if ! KPM_METADATA_VERSION=$VERSION LC_ALL=C awk -F "$tab" -v OFS="$tab" '
    BEGIN { requested = ENVIRON["KPM_METADATA_VERSION"] }
    $1 == "catalog" && $2 == requested {
        found++
        print $3, $4
    }
    END { exit found == 1 ? 0 : 1 }
' "$work/catalog.plan" >"$work/descriptor"
then
    fail "required version $IDENTITY@$VERSION is not published"
fi
IFS="$tab" read -r expected_size expected_digest <"$work/descriptor"
test -n "$expected_size" && test -n "$expected_digest" ||
    fail 'catalog plan did not retain the exact metadata descriptor'

sh "$METADATA_PLAN_TOOL" inspect "$IDENTITY" "$VERSION" "$INPUT_METADATA" \
    --size "$expected_size" --digest "$expected_digest" \
    >"$work/metadata.plan" || exit $?
dependencies=$(LC_ALL=C awk -F "$tab" \
    '$1 == "dependency" { count++ } END { print count + 0 }' \
    "$work/metadata.plan")
files=$(LC_ALL=C awk -F "$tab" \
    '$1 == "descriptor" { count++ } END { print count + 0 }' \
    "$work/metadata.plan")

printf 'metadata-v1: exact catalog descriptor matched one private metadata snapshot for %s@%s; strict metadata parsed %s dependency and %s file descriptor row(s)\n' \
    "$IDENTITY" "$VERSION" "$dependencies" "$files"
printf 'metadata-v1: supplied authority, catalog, and metadata bytes for one exact identity/version only; catalog authenticity/history/non-equivocation, HTTPS/TLS/DNS/redirect/peer checks, acquisition/persistence, file blob bytes/source UTF-8, whole-fetch bounds, graph/MVS, store publication, lock writer/migration/fetch, and same-handle consumption remain outside this slice\n'
