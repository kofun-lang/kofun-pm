#!/bin/sh
set -eu

# Snapshot and normalize one canonical requirements-v2 document. The byte
# bound is the rounded ceiling implied by 1,024 maximum members plus 16,384
# maximum root/member edges at their maximum canonical identity/version sizes.
#
#   scripts/requirements-v2-plan.sh inspect REQUIREMENTS

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PROTOCOL_VALIDATOR=$ROOT/scripts/protocol-v1-validate.awk
VALIDATOR=$ROOT/scripts/requirements-v2-validate.awk
MAX_REQUIREMENTS_BYTES=70254592
MAX_REQUIREMENTS_ROWS=17409
MAX_LINE_BYTES=8192

fail() {
    printf 'requirements-v2: %s\n' "$*" >&2
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

test "${1:-}" = inspect && test "$#" -eq 2 ||
    fail 'usage: scripts/requirements-v2-plan.sh inspect REQUIREMENTS'
INPUT_REQUIREMENTS=$2
test -f "$PROTOCOL_VALIDATOR" ||
    fail "shared protocol validator is missing: $PROTOCOL_VALIDATOR"
test -f "$VALIDATOR" || fail "validator is missing: $VALIDATOR"
test ! -L "$INPUT_REQUIREMENTS" && test -f "$INPUT_REQUIREMENTS" ||
    fail "requirements is not a regular non-symlink file: $INPUT_REQUIREMENTS"

work=$(mktemp -d "${TMPDIR:-/tmp}/kofun-pm-requirements-v2.XXXXXX")
trap 'rm -rf "$work"' 0 1 2 15

REQUIREMENTS=$work/requirements.snapshot
head -c "$((MAX_REQUIREMENTS_BYTES + 1))" <"$INPUT_REQUIREMENTS" \
    >"$REQUIREMENTS" ||
    fail "could not read the requirements snapshot: $INPUT_REQUIREMENTS"
requirements_bytes=$(wc -c <"$REQUIREMENTS" | tr -d ' ')
test "$requirements_bytes" -le "$MAX_REQUIREMENTS_BYTES" ||
    fail "requirements exceeds the $MAX_REQUIREMENTS_BYTES-byte input bound: $requirements_bytes"
chmod 400 "$REQUIREMENTS"

LC_ALL=C tr -d '\011\012\040-\176' <"$REQUIREMENTS" >"$work/non-ascii"
test ! -s "$work/non-ascii" ||
    fail 'requirements contains a byte outside ASCII, HT, and LF'
last_byte=$(tail -c 1 "$REQUIREMENTS" | od -An -tu1 | tr -d ' ')
test "$last_byte" = 10 || fail 'requirements must end in exactly one LF'
longest_line=$(LC_ALL=C wc -L <"$REQUIREMENTS" | tr -d ' ')
test "$longest_line" -le "$MAX_LINE_BYTES" ||
    fail "requirements line exceeds the $MAX_LINE_BYTES-byte structural bound: $longest_line"
requirements_rows=$(wc -l <"$REQUIREMENTS" | tr -d ' ')
test "$requirements_rows" -le "$MAX_REQUIREMENTS_ROWS" ||
    fail "requirements exceeds the $MAX_REQUIREMENTS_ROWS-row structural bound: $requirements_rows"

LC_ALL=C awk -f "$PROTOCOL_VALIDATOR" -f "$VALIDATOR" "$REQUIREMENTS" \
    >"$work/requirements.plan" || fail 'requirements-v2 grammar is invalid'
requirements_digest=$(sha256 <"$REQUIREMENTS")
printf 'requirements\t-\t-\t-\t-\t-\t%s\tframing\n' "$requirements_digest"
cat "$work/requirements.plan"
