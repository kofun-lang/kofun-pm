#!/bin/sh
set -eu

# Produce the normalized object plan for one strict lock-v2 envelope without
# opening its store objects. Both the store inspector and supplied catalog
# history comparison use this one parser so the canonical lock grammar cannot
# drift between them.
#
#   scripts/lock-v2-structure.sh inspect LOCK

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PROTOCOL_VALIDATOR=$ROOT/scripts/protocol-v1-validate.awk
VALIDATOR=$ROOT/scripts/lock-v2-validate.awk
FORMAT='kofun-pm.lock/v2'
COLUMNS='typed rows: package identity state version | metadata identity version size sha256 | file identity version path kind size sha256'
MAX_LOCK_BYTES=268435456
MAX_BODY_ROWS=82944
MAX_LINE_BYTES=4096

fail() {
    printf 'lock-v2: %s\n' "$*" >&2
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

is_digest() {
    case $1 in
        *[!0-9a-f]* | '') return 1 ;;
    esac
    test "${#1}" -eq 64
}

test "${1:-}" = inspect && test "$#" -eq 2 ||
    fail 'usage: scripts/lock-v2-structure.sh inspect LOCK'
INPUT_LOCK=$2
test ! -L "$INPUT_LOCK" && test -f "$INPUT_LOCK" ||
    fail "lock is not a regular non-symlink file: $INPUT_LOCK"
test -f "$PROTOCOL_VALIDATOR" ||
    fail "shared protocol validator is missing: $PROTOCOL_VALIDATOR"
test -f "$VALIDATOR" || fail "lock-v2 validator is missing: $VALIDATOR"

work=$(mktemp -d "${TMPDIR:-/tmp}/kofun-pm-lock-v2-structure.XXXXXX")
trap 'rm -rf "$work"' 0 1 2 15

# Read the explicit lock once into a private bounded snapshot. The +1 byte
# distinguishes an input exactly at the limit from an overrun without first
# consuming an unbounded pathname stream.
LOCK=$work/lock.snapshot
head -c "$((MAX_LOCK_BYTES + 1))" <"$INPUT_LOCK" >"$LOCK" ||
    fail "could not read the lock snapshot: $INPUT_LOCK"
lock_bytes=$(wc -c <"$LOCK" | tr -d ' ')
test "$lock_bytes" -le "$MAX_LOCK_BYTES" ||
    fail "lock exceeds the $MAX_LOCK_BYTES-byte input bound: $lock_bytes"
chmod 400 "$LOCK"

LC_ALL=C tr -d '\011\012\040-\176' <"$LOCK" >"$work/non-ascii"
test ! -s "$work/non-ascii" ||
    fail 'lock contains a byte outside ASCII, HT, and LF'
last_byte=$(tail -c 1 "$LOCK" | od -An -tu1 | tr -d ' ')
test "$last_byte" = 10 || fail 'lock must end in exactly one LF'

first_header=$(sed -n '1p' "$LOCK")
test "$first_header" != '# format: kofun-pm.lock/v1' ||
    fail 'lock v1 remains frozen; use scripts/lock.sh verify, and explicit fetch for any future v2 migration'
test "$first_header" = "# format: $FORMAT" ||
    fail "first header is not '# format: $FORMAT'"
test "$(sed -n '2p' "$LOCK")" = "# columns: $COLUMNS" ||
    fail 'columns header does not match the lock-v2 grammar'

tool_line=$(sed -n '3p' "$LOCK")
tool=${tool_line#\# tool: }
test "$tool_line" = "# tool: $tool" && is_digest "$tool" ||
    fail 'tool header is not one canonical sha256 digest'
requirements_line=$(sed -n '4p' "$LOCK")
requirements=${requirements_line#\# requirements: }
test "$requirements_line" = "# requirements: $requirements" &&
    is_digest "$requirements" ||
    fail 'requirements header is not one canonical sha256 digest'

digest_lines=$(grep -c '^# digest: ' "$LOCK" || :)
test "$digest_lines" -eq 1 ||
    fail "lock must contain exactly one digest line, found $digest_lines"
digest_line=$(tail -n 1 "$LOCK")
recorded=${digest_line#\# digest: }
test "$digest_line" = "# digest: $recorded" && is_digest "$recorded" ||
    fail 'the final line is not one canonical lock digest'

sed '$d' "$LOCK" >"$work/covered"
actual=$(sha256 <"$work/covered")
test "$actual" = "$recorded" ||
    fail "the lock digest does not cover its preceding bytes
  header says $recorded
  contents are $actual"

longest_line=$(LC_ALL=C wc -L <"$LOCK" | tr -d ' ')
test "$longest_line" -le "$MAX_LINE_BYTES" ||
    fail "lock line exceeds the $MAX_LINE_BYTES-byte structural bound: $longest_line"
sed '1,4d;$d' "$LOCK" >"$work/body"
body_rows=$(wc -l <"$work/body" | tr -d ' ')
test "$body_rows" -le "$MAX_BODY_ROWS" ||
    fail "lock body exceeds the $MAX_BODY_ROWS-row structural bound: $body_rows"
LC_ALL=C awk -f "$PROTOCOL_VALIDATOR" -f "$VALIDATOR" "$work/body" \
    >"$work/objects" || fail 'the lock-v2 envelope is invalid'
cat "$work/objects"
