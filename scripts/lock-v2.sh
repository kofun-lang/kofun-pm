#!/bin/sh
set -eu

# Inspect the bounded lock-v2 envelope and every store object it names.
#
#   scripts/lock-v2.sh inspect LOCK --store /abs/path
#
# This is deliberately not named plain `verify`: metadata parsing, the
# selected-file descriptor bijection, rough-graph re-resolution, and the v2
# writer/migration path are later slices. A partial verifier must say which
# boundary it proves instead of returning success under the complete command
# name.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
STORE_TOOL=$ROOT/scripts/store.sh
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

test "${1:-}" = inspect && test "$#" -eq 4 && test "${3:-}" = --store ||
    fail 'usage: scripts/lock-v2.sh inspect LOCK --store ABSOLUTE_STORE'
INPUT_LOCK=$2
STORE=${4:-}
test -n "$STORE" || fail '--store requires an explicit path'
case $STORE in
    /*) ;;
    *) fail "--store must be an absolute path: $STORE" ;;
esac
test "$STORE" != / || fail '--store refuses the filesystem root'
case $STORE in
    */) fail "--store must not end in '/': $STORE" ;;
esac
STORE=$(realpath -m -- "$STORE") ||
    fail "could not resolve the store boundary: $STORE"
test "$STORE" != / || fail '--store refuses the filesystem root'
test -d "$STORE" || fail "no store at $STORE"

test -x "$STORE_TOOL" || fail "store adapter is missing: $STORE_TOOL"
test -f "$VALIDATOR" || fail "lock-v2 validator is missing: $VALIDATOR"
test ! -L "$INPUT_LOCK" && test -f "$INPUT_LOCK" ||
    fail "lock is not a regular non-symlink file: $INPUT_LOCK"

work=$(mktemp -d "${TMPDIR:-/tmp}/kofun-pm-lock-v2.XXXXXX")
trap 'rm -rf "$work"' 0 1 2 15

# Read the explicit lock once into a private bounded snapshot. The +1 byte
# distinguishes an input exactly at the limit from an overrun without first
# consuming an unbounded pathname stream.
LOCK=$work/lock.snapshot
head -c $((MAX_LOCK_BYTES + 1)) "$INPUT_LOCK" >"$LOCK" ||
    fail "could not read the lock snapshot: $INPUT_LOCK"
lock_bytes=$(wc -c <"$LOCK" | tr -d ' ')
test "$lock_bytes" -le "$MAX_LOCK_BYTES" ||
    fail "lock exceeds the $MAX_LOCK_BYTES-byte input bound: $lock_bytes"
chmod 400 "$LOCK"

# The grammar is ASCII plus HT and LF. Checking before line parsing also names
# CR, NUL, and hostile UTF-8 as byte-grammar failures rather than letting a
# locale or tool silently reinterpret them.
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
LC_ALL=C awk -f "$VALIDATOR" "$work/body" >"$work/objects" ||
    fail 'the lock-v2 envelope is invalid'

tab=$(printf '\t')
objects=0
metadata_objects=0
file_objects=0
while IFS="$tab" read -r object identity version path kind size digest; do
    test -n "$object" || continue
    objects=$((objects + 1))
    if test "$object" = metadata; then
        metadata_objects=$((metadata_objects + 1))
    else
        file_objects=$((file_objects + 1))
    fi
    entry=$work/object.$objects
    if ! sh "$STORE_TOOL" --store "$STORE" snapshot \
        "$digest" "$size" "$entry" >"$work/store-output" 2>"$work/store-error"
    then
        printf 'lock-v2: %s object is missing or corrupt\n' "$object" >&2
        printf '  identity %s\n' "$identity" >&2
        printf '  version  %s\n' "$version" >&2
        if test "$path" != -; then
            printf '  path     %s\n' "$path" >&2
        fi
        sed 's/^/  /' "$work/store-error" >&2
        exit 1
    fi
    actual_size=$(wc -c <"$entry" | tr -d ' ')
    test "$actual_size" = "$size" ||
        fail "$object object size does not match the lock
  identity $identity
  version  $version
  path     $path
  expected $size
  actual   $actual_size"
    if test "$object" = file && test "$kind" = source; then
        command -v iconv >/dev/null 2>&1 ||
            fail 'iconv is required to validate locked source UTF-8'
        iconv -f UTF-8 -t UTF-8 "$entry" >/dev/null 2>"$work/iconv-error" ||
            fail "locked source is not valid UTF-8
  identity $identity
  version  $version
  path     $path"
    fi
done <"$work/objects"

printf 'lock-v2: inspected canonical envelope; %s metadata and %s file reference(s) matched private store snapshots\n' \
    "$metadata_objects" "$file_objects"
printf 'lock-v2: metadata grammar, descriptor bijection, tool/requirements identity, re-resolution, and migration remain outside this slice\n'
