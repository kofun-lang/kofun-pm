#!/bin/sh
set -eu

# Inspect the bounded lock-v2 envelope and every store object it names, or
# compose that inspection with the store's reverse inventory scan.
#
#   scripts/lock-v2.sh inspect LOCK --store /abs/path
#   scripts/lock-v2.sh audit-store LOCK --store /abs/path
#
# Neither action is named plain `verify`: catalog/history binding, dependency
# reachability and re-resolution, tool/requirements identity, and the v2
# writer/migration/fetch path are later slices. `audit-store` is sequential,
# not an atomic snapshot or same-open-file-description handoff. A partial
# verifier must say which boundary it proves instead of returning success
# under the complete command name.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
STORE_TOOL=$ROOT/scripts/store.sh
PROTOCOL_VALIDATOR=$ROOT/scripts/protocol-v1-validate.awk
VALIDATOR=$ROOT/scripts/lock-v2-validate.awk
METADATA_VALIDATOR=$ROOT/scripts/metadata-v1-validate.awk
FORMAT='kofun-pm.lock/v2'
COLUMNS='typed rows: package identity state version | metadata identity version size sha256 | file identity version path kind size sha256'
MAX_LOCK_BYTES=268435456
MAX_BODY_ROWS=82944
MAX_LINE_BYTES=4096
MAX_METADATA_ROWS=4355
MAX_REMOTE_DEPENDENCY_EDGES=16384
MAX_METADATA_FILE_DESCRIPTORS=65536

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

ACTION=${1:-}
case $ACTION in
    inspect | audit-store) ;;
    *) fail 'usage: scripts/lock-v2.sh {inspect|audit-store} LOCK --store ABSOLUTE_STORE' ;;
esac
test "$#" -eq 4 && test "${3:-}" = --store ||
    fail 'usage: scripts/lock-v2.sh {inspect|audit-store} LOCK --store ABSOLUTE_STORE'
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
test -f "$PROTOCOL_VALIDATOR" ||
    fail "shared protocol validator is missing: $PROTOCOL_VALIDATOR"
test -f "$VALIDATOR" || fail "lock-v2 validator is missing: $VALIDATOR"
test -f "$METADATA_VALIDATOR" ||
    fail "metadata validator is missing: $METADATA_VALIDATOR"
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
LC_ALL=C awk -f "$PROTOCOL_VALIDATOR" -f "$VALIDATOR" "$work/body" \
    >"$work/objects" ||
    fail 'the lock-v2 envelope is invalid'

tab=$(printf '\t')
objects=0
metadata_objects=0
file_objects=0
metadata_dependency_edges=0
metadata_file_descriptors=0
: >"$work/lock-files"
: >"$work/metadata-files"

# Pass one parses every metadata snapshot, including superseded versions, and
# builds both sides of the selected descriptor relation. No snapshot or
# validation is initiated from a file row until that relation is proven.
while IFS="$tab" read -r object identity version path kind size digest selection; do
    test -n "$object" || continue
    objects=$((objects + 1))
    if test "$object" != metadata; then
        file_objects=$((file_objects + 1))
        printf 'file\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$identity" "$version" "$path" "$kind" "$size" "$digest" \
            >>"$work/lock-files"
        continue
    fi

    metadata_objects=$((metadata_objects + 1))
    entry=$work/metadata.$metadata_objects
    if ! sh "$STORE_TOOL" --store "$STORE" snapshot \
        "$digest" "$size" "$entry" >"$work/store-output" 2>"$work/store-error"
    then
        printf 'lock-v2: metadata object is missing or corrupt\n' >&2
        printf '  identity %s\n' "$identity" >&2
        printf '  version  %s\n' "$version" >&2
        sed 's/^/  /' "$work/store-error" >&2
        exit 1
    fi
    actual_size=$(wc -c <"$entry" | tr -d ' ')
    test "$actual_size" = "$size" ||
        fail "metadata object size does not match the lock
  identity $identity
  version  $version
  expected $size
  actual   $actual_size"

    LC_ALL=C tr -d '\011\012\040-\176' <"$entry" \
        >"$work/metadata-non-ascii.$metadata_objects"
    test ! -s "$work/metadata-non-ascii.$metadata_objects" ||
        fail "metadata contains a byte outside ASCII, HT, and LF
  identity $identity
  version  $version"
    metadata_last_byte=$(tail -c 1 "$entry" | od -An -tu1 | tr -d ' ')
    test "$metadata_last_byte" = 10 ||
        fail "metadata must end in exactly one LF
  identity $identity
  version  $version"
    metadata_longest_line=$(LC_ALL=C wc -L <"$entry" | tr -d ' ')
    test "$metadata_longest_line" -le "$MAX_LINE_BYTES" ||
        fail "metadata line exceeds the $MAX_LINE_BYTES-byte structural bound
  identity $identity
  version  $version
  actual   $metadata_longest_line"
    metadata_rows=$(wc -l <"$entry" | tr -d ' ')
    test "$metadata_rows" -le "$MAX_METADATA_ROWS" ||
        fail "metadata exceeds the $MAX_METADATA_ROWS-row structural bound
  identity $identity
  version  $version
  actual   $metadata_rows"

    emit_files=0
    test "$selection" != selected || emit_files=1
    if ! LC_ALL=C awk -v expected_identity="$identity" \
        -v expected_version="$version" -v emit_files="$emit_files" \
        -f "$PROTOCOL_VALIDATOR" -f "$METADATA_VALIDATOR" "$entry" \
        >"$work/metadata-plan.$metadata_objects"
    then
        fail "metadata grammar is invalid
  identity $identity
  version  $version"
    fi

    object_dependency_edges=$(LC_ALL=C awk -F '\t' \
        '$1 == "dependency" { count++ } END { print count + 0 }' \
        "$work/metadata-plan.$metadata_objects")
    metadata_dependency_edges=$((metadata_dependency_edges + object_dependency_edges))
    test "$metadata_dependency_edges" -le "$MAX_REMOTE_DEPENDENCY_EDGES" ||
        fail "remote metadata dependency edges exceed the $MAX_REMOTE_DEPENDENCY_EDGES bound
  identity $identity
  version  $version
  actual   $metadata_dependency_edges"

    object_file_descriptors=$(LC_ALL=C awk -F '\t' \
        '$1 == "file" || $1 == "descriptor" { count++ }
         END { print count + 0 }' "$work/metadata-plan.$metadata_objects")
    metadata_file_descriptors=$((metadata_file_descriptors + object_file_descriptors))
    test "$metadata_file_descriptors" -le "$MAX_METADATA_FILE_DESCRIPTORS" ||
        fail "metadata file descriptors exceed the $MAX_METADATA_FILE_DESCRIPTORS bound
  identity $identity
  version  $version
  actual   $metadata_file_descriptors"

    if test "$selection" = selected; then
        LC_ALL=C awk -F '\t' '$1 == "file" { print }' \
            "$work/metadata-plan.$metadata_objects" >>"$work/metadata-files"
    fi
done <"$work/objects"

if ! cmp -s "$work/metadata-files" "$work/lock-files"; then
    printf 'lock-v2: selected metadata file descriptors do not exactly match lock file rows\n' >&2
    LC_ALL=C diff -u "$work/metadata-files" "$work/lock-files" 2>/dev/null |
        head -n 12 | sed 's/^/  /' >&2 || :
    exit 1
fi

# Pass two consumes only lock rows already proven byte-identical to selected
# metadata descriptors.
verified_file_objects=0
while IFS="$tab" read -r object identity version path kind size digest selection; do
    test "$object" = file || continue
    verified_file_objects=$((verified_file_objects + 1))
    entry=$work/file.$verified_file_objects
    if ! sh "$STORE_TOOL" --store "$STORE" snapshot \
        "$digest" "$size" "$entry" >"$work/store-output" 2>"$work/store-error"
    then
        printf 'lock-v2: file object is missing or corrupt\n' >&2
        printf '  identity %s\n' "$identity" >&2
        printf '  version  %s\n' "$version" >&2
        printf '  path     %s\n' "$path" >&2
        sed 's/^/  /' "$work/store-error" >&2
        exit 1
    fi
    actual_size=$(wc -c <"$entry" | tr -d ' ')
    test "$actual_size" = "$size" ||
        fail "file object size does not match the lock
  identity $identity
  version  $version
  path     $path
  expected $size
  actual   $actual_size"
    if test "$kind" = source; then
        command -v iconv >/dev/null 2>&1 ||
            fail 'iconv is required to validate locked source UTF-8'
        iconv -f UTF-8 -t UTF-8 "$entry" >/dev/null 2>"$work/iconv-error" ||
            fail "locked source is not valid UTF-8
  identity $identity
  version  $version
  path     $path"
    fi
done <"$work/objects"
if test "$ACTION" = inspect; then
    printf 'lock-v2: inspected canonical envelope and strict metadata; selected metadata descriptors exactly matched lock file rows; %s metadata and %s file reference(s) matched private store snapshots\n' \
        "$metadata_objects" "$file_objects"
    printf 'lock-v2: catalog/history, dependency reachability/re-resolution, tool/requirements identity, writer/migration/fetch, and affine same-handle consumption remain outside this slice\n'
    exit 0
fi

# The lock-scoped direction deliberately ran first. It preserves package and
# logical-path context for a named missing or corrupt object. Its success text
# was not printed: a green first direction is not a successful two-way audit
# when an unrelated store entry is malformed or corrupt.
if ! sh "$STORE_TOOL" --store "$STORE" verify \
    >"$work/global-store-output" 2>"$work/global-store-error"
then
    printf 'lock-v2: global store direction failed after lock-scoped inspection\n' >&2
    sed 's/^/  /' "$work/global-store-error" >&2
    exit 1
fi

global_store_summary=$(sed -n '1p' "$work/global-store-output")
test "$(wc -l <"$work/global-store-output" | tr -d ' ')" -eq 1 ||
    fail 'global store direction returned more than one success record'
case $global_store_summary in
    'store: '*" entries, each hashing to its own name") ;;
    *) fail 'global store direction returned an unexpected success record' ;;
esac
printf 'lock-v2: sequential two-way store audit passed: %s metadata and %s selected-file reference(s) matched private snapshots; %s\n' \
    "$metadata_objects" "$file_objects" "$global_store_summary"
printf 'lock-v2: supplied-lock completeness, catalog/history, dependency reachability/re-resolution, tool/requirements identity, exact lock/store set equality, bounded or atomic global inventory, writer/migration/fetch, and affine same-handle consumption remain outside this slice\n'
