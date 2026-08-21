#!/bin/sh
set -eu

# Parse one metadata document against an already approved exact descriptor.
# The caller owns catalog/authority binding; this adapter owns one bounded
# metadata snapshot, size-before-digest precedence, framing, and strict rows.
#
#   scripts/metadata-v1-plan.sh inspect IDENTITY VERSION METADATA \
#     --size BYTES --digest SHA256

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PROTOCOL_VALIDATOR=$ROOT/scripts/protocol-v1-validate.awk
DESCRIPTOR_VALIDATOR=$ROOT/scripts/metadata-descriptor-v1-validate.awk
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
    test "${5:-}" = --size && test "${7:-}" = --digest ||
    fail 'usage: scripts/metadata-v1-plan.sh inspect IDENTITY VERSION METADATA --size BYTES --digest SHA256'
IDENTITY=$2
VERSION=$3
INPUT_METADATA=$4
EXPECTED_SIZE=$6
EXPECTED_DIGEST=$8

for required in "$PROTOCOL_VALIDATOR" "$DESCRIPTOR_VALIDATOR" "$METADATA_VALIDATOR"; do
    test -f "$required" || fail "validator is missing: $required"
done
descriptor_plan=$(KPM_METADATA_IDENTITY=$IDENTITY \
    KPM_METADATA_VERSION=$VERSION \
    KPM_METADATA_SIZE=$EXPECTED_SIZE KPM_METADATA_DIGEST=$EXPECTED_DIGEST \
    LC_ALL=C awk -f "$PROTOCOL_VALIDATOR" -f "$DESCRIPTOR_VALIDATOR" /dev/null) ||
    fail 'requested identity/version or metadata descriptor grammar is invalid'
tab=$(printf '\t')
IFS="$tab" read -r descriptor_kind validated_size validated_digest <<EOF
$descriptor_plan
EOF
test "$descriptor_kind" = descriptor && test "$validated_size" = "$EXPECTED_SIZE" &&
    test "$validated_digest" = "$EXPECTED_DIGEST" ||
    fail 'metadata descriptor validation did not retain the exact scalar values'

work=$(mktemp -d "${TMPDIR:-/tmp}/kofun-pm-metadata-v1-plan.XXXXXX")
trap 'rm -rf "$work"' 0 1 2 15

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
  expected $EXPECTED_SIZE
  actual   at least $actual_size
  actual digest not computed"
fi
if test "$actual_size" != "$EXPECTED_SIZE"; then
    fail "metadata size does not match its catalog descriptor
  identity $IDENTITY
  version  $VERSION
  expected $EXPECTED_SIZE
  actual   $actual_size
  actual digest not computed"
fi

actual_digest=$(sha256 <"$METADATA")
if test "$actual_digest" != "$EXPECTED_DIGEST"; then
    fail "metadata digest does not match its catalog descriptor
  identity $IDENTITY
  version  $VERSION
  expected $EXPECTED_DIGEST
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
    "$METADATA" >"$work/metadata.unchecked.plan" ||
    fail "metadata grammar is invalid
  identity $IDENTITY
  version  $VERSION"
cat "$work/metadata.unchecked.plan"
