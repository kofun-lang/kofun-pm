#!/bin/sh
set -eu

# Inspect the bounded lock-v2 envelope and every store object it names, or
# compose that inspection with the store's reverse inventory scan.
#
#   scripts/lock-v2.sh inspect LOCK --store /abs/path
#   scripts/lock-v2.sh audit-store LOCK --store /abs/path
#   scripts/lock-v2.sh graph-plan LOCK --store /abs/path \
#     --requirements-digest DIGEST
#
# Neither public action is named plain `verify`: catalog/history binding,
# dependency reachability and re-resolution, tool/requirements identity, and
# the v2 writer/migration/fetch path are later slices. `audit-store` is sequential,
# not an atomic snapshot or same-open-file-description handoff. A partial
# verifier must say which boundary it proves instead of returning success
# under the complete command name. `graph-plan` is an internal composition
# adapter: it also binds the supplied requirements and current local tool
# closure, withholds machine rows until the full lock-scoped inspection passes,
# and is consumed only by rough-graph-v2.sh.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
STORE_TOOL=$ROOT/scripts/store.sh
STRUCTURE_TOOL=$ROOT/scripts/lock-v2-structure.sh
TOOL_IDENTITY_TOOL=$ROOT/scripts/lock-tool-v2.sh
PROTOCOL_VALIDATOR=$ROOT/scripts/protocol-v1-validate.awk
METADATA_VALIDATOR=$ROOT/scripts/metadata-v1-validate.awk
MAX_LINE_BYTES=4096
MAX_METADATA_ROWS=4355
MAX_REMOTE_DEPENDENCY_EDGES=16384
MAX_METADATA_FILE_DESCRIPTORS=65536

fail() {
    printf 'lock-v2: %s\n' "$*" >&2
    exit 1
}

ACTION=${1:-}
case $ACTION in
    inspect | audit-store)
        test "$#" -eq 4 && test "${3:-}" = --store ||
            fail 'usage: scripts/lock-v2.sh {inspect|audit-store} LOCK --store ABSOLUTE_STORE'
        EXPECTED_REQUIREMENTS=
        ;;
    graph-plan)
        test "$#" -eq 6 && test "${3:-}" = --store &&
            test "${5:-}" = --requirements-digest ||
            fail 'usage: scripts/lock-v2.sh graph-plan LOCK --store ABSOLUTE_STORE --requirements-digest DIGEST'
        EXPECTED_REQUIREMENTS=${6:-}
        case $EXPECTED_REQUIREMENTS in
            *[!0-9a-f]* | '') fail 'graph-plan requirements digest is not one lowercase sha256 digest' ;;
        esac
        test "${#EXPECTED_REQUIREMENTS}" -eq 64 ||
            fail 'graph-plan requirements digest is not one lowercase sha256 digest'
        ;;
    *) fail 'usage: scripts/lock-v2.sh {inspect|audit-store} LOCK --store ABSOLUTE_STORE' ;;
esac
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
test -x "$STRUCTURE_TOOL" ||
    fail "lock-v2 structure adapter is missing: $STRUCTURE_TOOL"
test -f "$PROTOCOL_VALIDATOR" ||
    fail "shared protocol validator is missing: $PROTOCOL_VALIDATOR"
test -f "$METADATA_VALIDATOR" ||
    fail "metadata validator is missing: $METADATA_VALIDATOR"

work=$(mktemp -d "${TMPDIR:-/tmp}/kofun-pm-lock-v2.XXXXXX")
trap 'rm -rf "$work"' 0 1 2 15

sh "$STRUCTURE_TOOL" inspect "$INPUT_LOCK" >"$work/objects"

tab=$(printf '\t')
if test "$ACTION" = graph-plan; then
    lock_requirements=$(LC_ALL=C awk -F "$tab" '$1 == "lock" { print $6 }' \
        "$work/objects")
    test -n "$lock_requirements" || fail 'lock plan did not retain its requirements digest'
    test "$lock_requirements" = "$EXPECTED_REQUIREMENTS" ||
        fail "lock requirements digest does not match the supplied requirements bytes
  expected $lock_requirements
  actual   $EXPECTED_REQUIREMENTS"
    test -x "$TOOL_IDENTITY_TOOL" ||
        fail "lock-v2 tool identity adapter is missing: $TOOL_IDENTITY_TOOL"
    lock_tool=$(LC_ALL=C awk -F "$tab" '$1 == "lock" { print $5 }' \
        "$work/objects")
    test -n "$lock_tool" || fail 'lock plan did not retain its tool digest'
    current_tool=$(sh "$TOOL_IDENTITY_TOOL" digest) ||
        fail 'could not compute the current local lock-v2 tool closure identity'
    test "$lock_tool" = "$current_tool" ||
        fail "lock tool digest does not match the current local tool closure
  expected $lock_tool
  actual   $current_tool"
fi
objects=0
metadata_objects=0
file_objects=0
metadata_dependency_edges=0
metadata_file_descriptors=0
: >"$work/lock-files"
: >"$work/metadata-files"
: >"$work/graph-plan"

# Pass one parses every metadata snapshot, including superseded versions, and
# builds both sides of the selected descriptor relation. No snapshot or
# validation is initiated from a file row until that relation is proven.
while IFS="$tab" read -r object identity version path kind size digest selection; do
    test -n "$object" || continue
    case $object in
        lock | package)
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$object" "$identity" "$version" "$path" "$kind" "$size" \
                "$digest" "$selection" >>"$work/graph-plan"
            continue
            ;;
        metadata | file) ;;
        *) fail "lock structure plan returned an unknown row: $object" ;;
    esac
    objects=$((objects + 1))
    if test "$object" != metadata; then
        file_objects=$((file_objects + 1))
        printf 'file\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$identity" "$version" "$path" "$kind" "$size" "$digest" \
            >>"$work/lock-files"
        continue
    fi

    metadata_objects=$((metadata_objects + 1))
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$object" "$identity" "$version" "$path" "$kind" "$size" \
        "$digest" "$selection" >>"$work/graph-plan"
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

    LC_ALL=C awk -F '\t' -v OFS='\t' '
        $1 == "dependency" {
            print "dependency", $2, $3, $4, $5, "-", "-", "edge"
        }
    ' "$work/metadata-plan.$metadata_objects" >>"$work/graph-plan"

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
if test "$ACTION" = graph-plan; then
    LC_ALL=C awk -F "$tab" '$1 == "file" { print }' "$work/objects" \
        >>"$work/graph-plan"
    cat "$work/graph-plan"
    exit 0
fi
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
