#!/bin/sh
set -eu

# Compute the current lock-v2 tool identity from one fixed, reviewable local
# implementation closure and the exact clean Kofun gitlink recorded by this
# checkout. This is intentionally a repository-local checkpoint: it performs
# no acquisition, lock writing, or Git mutation.
#
#   scripts/lock-tool-v2.sh digest

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MANIFEST_REL=contracts/lock-tool-v2.files
MANIFEST=$ROOT/$MANIFEST_REL
VENDOR_REL=vendor/kofun
VENDOR=$ROOT/$VENDOR_REL
TOOL_REL=scripts/lock-tool-v2.sh
MAX_MANIFEST_ROWS=64
MAX_MANIFEST_LINE_BYTES=512
MAX_MANIFEST_BYTES=32832
MAX_INPUT_BYTES=8388608
MAX_TOTAL_INPUT_BYTES=67108864
MAX_VENDOR_INDEX_BYTES=8388608

fail() {
    printf 'lock-tool-v2: %s\n' "$*" >&2
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

git_read() (
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
        GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_QUARANTINE_PATH \
        GIT_CONFIG GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_PREFIX \
        GIT_SUPER_PREFIX GIT_CEILING_DIRECTORIES \
        GIT_DISCOVERY_ACROSS_FILESYSTEM GIT_NAMESPACE GIT_SHALLOW_FILE \
        GIT_TRACE GIT_TRACE_FSMONITOR GIT_TRACE_PACK_ACCESS GIT_TRACE_PACKET \
        GIT_TRACE_PERFORMANCE GIT_TRACE_REFS GIT_TRACE_SETUP GIT_TRACE_SHALLOW \
        GIT_TRACE_CURL GIT_TRACE_CURL_NO_DATA GIT_TRACE2 GIT_TRACE2_EVENT \
        GIT_TRACE2_EVENT_NESTING GIT_TRACE2_PERF GIT_TRACE2_BRIEF \
        GIT_TRACE2_CONFIG_PARAMS GIT_TRACE2_ENV_VARS GIT_TRACE2_DST_DEBUG || :
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    GIT_OPTIONAL_LOCKS=0 GIT_NO_REPLACE_OBJECTS=1 GIT_NO_LAZY_FETCH=1 \
    GIT_TERMINAL_PROMPT=0 GIT_PAGER=cat PAGER=cat \
        git -c core.fsmonitor=false -c core.untrackedCache=false \
        -c core.fileMode=true -c core.ignoreStat=false "$@"
)

reject_symlink_components() {
    relative=$1
    prefix=$ROOT
    old_ifs=$IFS
    IFS=/
    set -- $relative
    IFS=$old_ifs
    for component do
        prefix=$prefix/$component
        test ! -L "$prefix" ||
            fail "tool input path contains a symlink component: $relative"
    done
}

test "${1:-}" = digest && test "$#" -eq 1 ||
    fail 'usage: scripts/lock-tool-v2.sh digest'
reject_symlink_components "$MANIFEST_REL"
test ! -L "$MANIFEST" && test -f "$MANIFEST" ||
    fail "closure manifest is not a regular non-symlink file: $MANIFEST_REL"

work=$(mktemp -d "${TMPDIR:-/tmp}/kofun-pm-lock-tool-v2.XXXXXX")
trap 'rm -rf "$work"' 0 1 2 15

# The manifest is itself a named tool input. Snapshot its pathname once here,
# validate and enumerate that private copy, then reuse the same bytes when its
# file row is framed below.
MANIFEST_SNAPSHOT=$work/manifest.snapshot
head -c "$((MAX_MANIFEST_BYTES + 1))" <"$MANIFEST" \
    >"$MANIFEST_SNAPSHOT" ||
    fail "could not read the closure manifest: $MANIFEST_REL"
manifest_bytes=$(wc -c <"$MANIFEST_SNAPSHOT" | tr -d ' ')
test "$manifest_bytes" -le "$MAX_MANIFEST_BYTES" ||
    fail "closure manifest exceeds the $MAX_MANIFEST_BYTES-byte input bound: $manifest_bytes"
chmod 400 "$MANIFEST_SNAPSHOT"

LC_ALL=C tr -d '\012\040-\176' <"$MANIFEST_SNAPSHOT" >"$work/non-ascii"
test ! -s "$work/non-ascii" ||
    fail 'closure manifest contains a byte outside printable ASCII and LF'
last_byte=$(tail -c 1 "$MANIFEST_SNAPSHOT" | od -An -tu1 | tr -d ' ')
test "$last_byte" = 10 || fail 'closure manifest must end in exactly one LF'
manifest_rows=$(wc -l <"$MANIFEST_SNAPSHOT" | tr -d ' ')
test "$manifest_rows" -le "$MAX_MANIFEST_ROWS" ||
    fail "closure manifest exceeds the $MAX_MANIFEST_ROWS-row bound: $manifest_rows"
test "$manifest_rows" -gt 0 || fail 'closure manifest is empty'
longest_line=$(LC_ALL=C wc -L <"$MANIFEST_SNAPSHOT" | tr -d ' ')
test "$longest_line" -le "$MAX_MANIFEST_LINE_BYTES" ||
    fail "closure manifest line exceeds the $MAX_MANIFEST_LINE_BYTES-byte bound: $longest_line"

LC_ALL=C awk -v self="$MANIFEST_REL" -v tool="$TOOL_REL" '
    function reject(message) {
        printf "lock-tool-v2: closure manifest %s\n", message > "/dev/stderr"
        bad = 1
        exit 1
    }
    $0 == "" { reject("contains a blank row") }
    $0 !~ /^[A-Za-z0-9._\/-]+$/ {
        reject("path contains a non-canonical byte: " $0)
    }
    $0 == "." || $0 == ".." || $0 ~ /^\// ||
    $0 ~ /^\.\// || $0 ~ /^\.\.\// ||
    $0 ~ /\/\.\// || $0 ~ /\/\.\.\// ||
    substr($0, length($0), 1) == "/" || $0 ~ /\/\// ||
    $0 ~ /\/\.$/ || $0 ~ /\/\.\.$/ {
        reject("path is not canonical repository-relative form: " $0)
    }
    NR > 1 && !($0 > previous) {
        reject("paths are not unique and in strict identity-byte order: " $0)
    }
    $0 == self { self_rows++ }
    $0 == tool { tool_rows++ }
    { previous = $0 }
    END {
        if (!bad && self_rows != 1) {
            printf "lock-tool-v2: closure manifest must name itself exactly once\n" > "/dev/stderr"
            exit 1
        }
        if (!bad && tool_rows != 1) {
            printf "lock-tool-v2: closure manifest must name the tool adapter exactly once\n" > "/dev/stderr"
            exit 1
        }
    }
' "$MANIFEST_SNAPSHOT" || fail 'closure manifest grammar is invalid'

printf 'kofun-pm.lock-tool/v2\n' >"$work/framing"
total_input_bytes=0
input_count=0
while IFS= read -r relative; do
    input_count=$((input_count + 1))
    input=$ROOT/$relative
    reject_symlink_components "$relative"
    test ! -L "$input" && test -f "$input" ||
        fail "tool input is not a regular non-symlink file: $relative"
    snapshot=$work/input.$input_count
    if test "$relative" = "$MANIFEST_REL"; then
        snapshot=$MANIFEST_SNAPSHOT
    else
        head -c "$((MAX_INPUT_BYTES + 1))" <"$input" >"$snapshot" ||
            fail "could not read tool input snapshot: $relative"
        chmod 400 "$snapshot"
    fi
    input_bytes=$(wc -c <"$snapshot" | tr -d ' ')
    test "$input_bytes" -le "$MAX_INPUT_BYTES" ||
        fail "tool input exceeds the $MAX_INPUT_BYTES-byte bound
  path   $relative
  actual $input_bytes"
    total_input_bytes=$((total_input_bytes + input_bytes))
    test "$total_input_bytes" -le "$MAX_TOTAL_INPUT_BYTES" ||
        fail "tool inputs exceed the $MAX_TOTAL_INPUT_BYTES-byte aggregate bound
  path   $relative
  actual $total_input_bytes"
    input_digest=$(sha256 <"$snapshot")
    printf 'file\t%s\t%s\t%s\n' \
        "$relative" "$input_bytes" "$input_digest" >>"$work/framing"
done <"$MANIFEST_SNAPSHOT"
test "$input_count" -eq "$manifest_rows" ||
    fail 'closure manifest enumeration did not consume every row'

command -v git >/dev/null 2>&1 || fail 'git is required to identify vendor/kofun'
reject_symlink_components "$VENDOR_REL"
test ! -L "$VENDOR" && test -d "$VENDOR" ||
    fail "Kofun checkout is not a directory: $VENDOR_REL"
index_row=$(git_read -C "$ROOT" ls-files --stage -- "$VENDOR_REL") ||
    fail 'could not read the recorded vendor/kofun gitlink'
old_ifs=$IFS
IFS=' 	'
set -- $index_row
IFS=$old_ifs
test "$#" -eq 4 && test "$1" = 160000 && test "$3" = 0 &&
    test "$4" = "$VENDOR_REL" ||
    fail 'vendor/kofun is not exactly one stage-0 mode-160000 gitlink'
gitlink=$2
case $gitlink in
    *[!0-9a-f]* | '') fail 'vendor/kofun gitlink object id is not lowercase hexadecimal' ;;
esac
case ${#gitlink} in
    40 | 64) ;;
    *) fail 'vendor/kofun gitlink object id has a non-canonical length' ;;
esac
vendor_head=$(git_read -C "$VENDOR" rev-parse HEAD 2>/dev/null) ||
    fail 'vendor/kofun is not a checked-out Git repository'
test "$vendor_head" = "$gitlink" ||
    fail "vendor/kofun checkout does not match the recorded gitlink
  gitlink $gitlink
  checkout $vendor_head"
git_read -C "$VENDOR" ls-files -v -- |
    head -c "$((MAX_VENDOR_INDEX_BYTES + 1))" >"$work/vendor-index" ||
    fail 'could not inspect vendor/kofun tracked index flags'
vendor_index_bytes=$(wc -c <"$work/vendor-index" | tr -d ' ')
test "$vendor_index_bytes" -le "$MAX_VENDOR_INDEX_BYTES" ||
    fail "vendor/kofun tracked index exceeds the $MAX_VENDOR_INDEX_BYTES-byte inspection bound: $vendor_index_bytes"
LC_ALL=C awk '
    substr($0, 1, 2) != "H " { bad = 1; exit }
    END { exit bad + 0 }
' "$work/vendor-index" ||
    fail 'vendor/kofun index carries assume-unchanged, skip-worktree, or non-canonical tracked flags'
git_read -C "$VENDOR" diff-index --cached --quiet HEAD -- ||
    fail 'vendor/kofun has tracked changes; the tool identity is not immutable'
git_read -C "$VENDOR" diff-files --quiet -- ||
    fail 'vendor/kofun has tracked changes; the tool identity is not immutable'

printf 'gitlink\t%s\t%s\n' "$VENDOR_REL" "$gitlink" >>"$work/framing"
sha256 <"$work/framing"
