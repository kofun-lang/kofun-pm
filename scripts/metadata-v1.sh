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
PROTOCOL_VALIDATOR=$ROOT/scripts/protocol-v1-validate.awk
REQUEST_VALIDATOR=$ROOT/scripts/metadata-request-v1-validate.awk
METADATA_VALIDATOR=$ROOT/scripts/metadata-v1-validate.awk
MAX_METADATA_BYTES=1048576
MAX_METADATA_ROWS=4355
MAX_LINE_BYTES=4096

fail() {
    printf 'metadata-v1: %s\n' "$*" >&2
    exit 1
}

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 | cut -d' ' -f1
    else
        fail 'no sha256sum or shasum available'
    fi
}

test "${1:-}" = inspect && test "$#" -eq 8 &&
    test "${5:-}" = --catalog && test "${7:-}" = --authority ||
    fail 'usage: scripts/metadata-v1.sh inspect IDENTITY VERSION METADATA --catalog CATALOG --authority AUTHORITY'
IDENTITY=$2
VERSION=$3
INPUT_METADATA=$4
INPUT_CATALOG=$6
INPUT_AUTHORITY=$8

test -x "$CATALOG_PLAN_TOOL" ||
    fail "catalog-v1 plan adapter is missing: $CATALOG_PLAN_TOOL"
for required in "$PROTOCOL_VALIDATOR" "$REQUEST_VALIDATOR" "$METADATA_VALIDATOR"; do
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

# Only an approved, fully parsed catalog with exact version membership reaches
# this pathname. MAX+1 distinguishes the hard input bound without consuming an
# unbounded stream.
test ! -L "$INPUT_METADATA" && test -f "$INPUT_METADATA" ||
    fail "metadata is not a regular non-symlink file: $INPUT_METADATA"
METADATA=$work/metadata.snapshot
head -c "$((MAX_METADATA_BYTES + 1))" <"$INPUT_METADATA" >"$METADATA" ||
    fail "could not read the metadata snapshot: $INPUT_METADATA"
actual_size=$(wc -c <"$METADATA" | tr -d ' ')
chmod 400 "$METADATA"
if test "$actual_size" -gt "$MAX_METADATA_BYTES"; then
    fail "metadata exceeds the $MAX_METADATA_BYTES-byte input bound
  identity $IDENTITY
  version  $VERSION
  expected $expected_size
  actual   at least $actual_size
  actual digest not computed"
fi
if test "$actual_size" != "$expected_size"; then
    fail "metadata size does not match its catalog descriptor
  identity $IDENTITY
  version  $VERSION
  expected $expected_size
  actual   $actual_size
  actual digest not computed"
fi

actual_digest=$(sha256 <"$METADATA")
if test "$actual_digest" != "$expected_digest"; then
    fail "metadata digest does not match its catalog descriptor
  identity $IDENTITY
  version  $VERSION
  expected $expected_digest
  actual   $actual_digest"
fi

LC_ALL=C tr -d '\011\012\040-\176' <"$METADATA" >"$work/non-ascii"
test ! -s "$work/non-ascii" ||
    fail "metadata contains a byte outside ASCII, HT, and LF
  identity $IDENTITY
  version  $VERSION"
last_byte=$(tail -c 1 "$METADATA" | od -An -tu1 | tr -d ' ')
test "$last_byte" = 10 ||
    fail "metadata must end in exactly one LF
  identity $IDENTITY
  version  $VERSION"
longest_line=$(LC_ALL=C wc -L <"$METADATA" | tr -d ' ')
test "$longest_line" -le "$MAX_LINE_BYTES" ||
    fail "metadata line exceeds the $MAX_LINE_BYTES-byte structural bound
  identity $IDENTITY
  version  $VERSION
  actual   $longest_line"
metadata_rows=$(wc -l <"$METADATA" | tr -d ' ')
test "$metadata_rows" -le "$MAX_METADATA_ROWS" ||
    fail "metadata exceeds the $MAX_METADATA_ROWS-row structural bound
  identity $IDENTITY
  version  $VERSION
  actual   $metadata_rows"

KPM_METADATA_IDENTITY=$IDENTITY KPM_METADATA_VERSION=$VERSION LC_ALL=C awk \
    -v expected_identity_environment=KPM_METADATA_IDENTITY \
    -v expected_version_environment=KPM_METADATA_VERSION \
    -v emit_files=0 -f "$PROTOCOL_VALIDATOR" -f "$METADATA_VALIDATOR" \
    "$METADATA" >"$work/metadata.plan" ||
    fail "metadata grammar is invalid
  identity $IDENTITY
  version  $VERSION"
dependencies=$(LC_ALL=C awk -F "$tab" \
    '$1 == "dependency" { count++ } END { print count + 0 }' \
    "$work/metadata.plan")
files=$(LC_ALL=C awk -F "$tab" \
    '$1 == "descriptor" { count++ } END { print count + 0 }' \
    "$work/metadata.plan")

printf 'metadata-v1: exact catalog descriptor matched one private metadata snapshot for %s@%s; strict metadata parsed %s dependency and %s file descriptor row(s)\n' \
    "$IDENTITY" "$VERSION" "$dependencies" "$files"
printf 'metadata-v1: supplied authority, catalog, and metadata bytes for one exact identity/version only; catalog authenticity/history/non-equivocation, HTTPS/TLS/DNS/redirect/peer checks, acquisition/persistence, file blob bytes/source UTF-8, whole-fetch bounds, graph/MVS, store publication, lock writer/migration/fetch, and same-handle consumption remain outside this slice\n'
