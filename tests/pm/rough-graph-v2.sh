#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
TOOL=$ROOT/scripts/rough-graph-v2.sh
REQUIREMENTS_TOOL=$ROOT/scripts/requirements-v2-plan.sh
TOOL_IDENTITY_TOOL=$ROOT/scripts/lock-tool-v2.sh
STORE_TOOL=$ROOT/scripts/store.sh
WORK=$(mktemp -d "${TMPDIR:-/tmp}/kofun-pm-rough-graph-test.XXXXXX")
trap 'rm -rf "$WORK"' 0 1 2 15

fail() {
    printf 'pm: FAIL: rough-graph-v2: %s\n' "$*" >&2
    exit 1
}

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | cut -d' ' -f1
    else
        shasum -a 256 | cut -d' ' -f1
    fi
}

BASE_PATH=$PATH
REAL_GIT=$(command -v git)
HOSTILE_BIN=$WORK/network-bin
HOSTILE_HOME=$WORK/hostile-home
HOSTILE_XDG=$WORK/hostile-xdg
mkdir -p "$HOSTILE_BIN" "$HOSTILE_HOME" "$HOSTILE_XDG"
printf 'home\n' >"$HOSTILE_HOME/marker"
printf 'xdg\n' >"$HOSTILE_XDG/marker"
for network_command in curl wget fetch ftp sftp ssh nc ncat netcat telnet \
    openssl host dig nslookup getent
do
    cp "$ROOT/tests/pm/network-sentinel.sh" "$HOSTILE_BIN/$network_command"
done
cp "$ROOT/tests/pm/git-readonly-sentinel.sh" "$HOSTILE_BIN/git"
chmod +x "$HOSTILE_BIN"/*

ROOT_INDEX=$(git -C "$ROOT" rev-parse --git-path index)
case $ROOT_INDEX in /*) ;; *) ROOT_INDEX=$ROOT/$ROOT_INDEX ;; esac
VENDOR_INDEX=$(git -C "$ROOT/vendor/kofun" rev-parse --git-path index)
case $VENDOR_INDEX in
    /*) ;;
    *) VENDOR_INDEX=$ROOT/vendor/kofun/$VENDOR_INDEX ;;
esac
CLOSURE_MANIFEST=$ROOT/contracts/lock-tool-v2.files

state() {
    for path do
        stat -c '%n %d %i %h %F %a %s' "$path"
        test ! -f "$path" || sha256 <"$path"
    done
}

tree_state() {
    find "$@" -printf '%p %D %i %n %y %m %s\n' | LC_ALL=C sort
    find "$@" -type f -exec sha256sum '{}' ';' | LC_ALL=C sort
}

scope_state() {
    requirements_path=$1
    lock_path=$2
    store_path=$3
    output=$4
    {
        for path in "$requirements_path" "$lock_path"; do
            test -e "$path" || test -L "$path" || continue
            state "$path"
        done
        test ! -d "$store_path" || tree_state "$store_path"
        while IFS= read -r relative; do
            state "$ROOT/$relative"
        done <"$CLOSURE_MANIFEST"
        state "$ROOT_INDEX" "$VENDOR_INDEX"
        tree_state "$HOSTILE_HOME" "$HOSTILE_XDG"
    } >"$output"
}

hostile_rough() {
    hostile_path=$HOSTILE_BIN:$BASE_PATH
    test -z "${KPM_EXTRA_PATH:-}" ||
        hostile_path=$KPM_EXTRA_PATH:$hostile_path
    env -i PATH="$hostile_path" HOME="$HOSTILE_HOME" \
    XDG_CACHE_HOME="$HOSTILE_XDG" KPM_STORE="$WORK/ambient-store" \
    KPM_NETWORK_SENTINEL="$WORK/network.called" \
    KPM_WATCH_STORE="${KPM_WATCH_STORE:-}" \
    KPM_STORE_CALLED="${KPM_STORE_CALLED:-}" \
    KPM_REAL_GIT="$REAL_GIT" KPM_GIT_ROOT="$ROOT" \
    GIT_DIR="$WORK/hostile.git" GIT_WORK_TREE="$WORK/hostile.worktree" \
    GIT_INDEX_FILE=/dev/null GIT_OBJECT_DIRECTORY="$WORK/hostile.objects" \
    GIT_ALTERNATE_OBJECT_DIRECTORIES="$WORK/hostile.alternates" \
    GIT_COMMON_DIR="$WORK/hostile.common" GIT_CONFIG_COUNT=1 \
    GIT_CONFIG_KEY_0=core.fileMode GIT_CONFIG_VALUE_0=false \
    GIT_TRACE="$WORK/git.trace" GIT_TRACE2_EVENT="$WORK/git-trace2.event" \
    http_proxy=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 \
    ALL_PROXY=socks5://127.0.0.1:9 \
        "$TOOL" "$@"
}

hostile_requirements() {
    env -i PATH="$HOSTILE_BIN:$BASE_PATH" HOME="$HOSTILE_HOME" \
    XDG_CACHE_HOME="$HOSTILE_XDG" KPM_STORE="$WORK/ambient-store" \
    KPM_NETWORK_SENTINEL="$WORK/network.called" \
    http_proxy=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 \
    ALL_PROXY=socks5://127.0.0.1:9 \
        "$REQUIREMENTS_TOOL" "$@"
}

store() {
    sh "$STORE_TOOL" --store "$STORE" "$@"
}

add_object() {
    store add "$1" 2>/dev/null
}

write_lock() {
    body=$1
    requirements=$2
    output=$3
    tool=${4:-$TOOL_DIGEST}
    covered=$output.covered
    {
        printf '# format: kofun-pm.lock/v2\n'
        printf '# columns: typed rows: package identity state version | metadata identity version size sha256 | file identity version path kind size sha256\n'
        printf '# tool: %s\n' "$tool"
        printf '# requirements: %s\n' "$(sha256 <"$requirements")"
        sed -n '1,$p' "$body"
    } >"$covered"
    {
        sed -n '1,$p' "$covered"
        printf '# digest: %s\n' "$(sha256 <"$covered")"
    } >"$output"
    rm -f "$covered"
}

expect_refusal() {
    label=$1
    needle=$2
    requirements=$3
    lock=$4
    store_path=$5
    scope_state "$requirements" "$lock" "$store_path" \
        "$WORK/refusal.before"
    rm -f "$WORK/network.called" "$WORK/git.trace" "$WORK/git-trace2.event"
    if hostile_rough inspect "$requirements" "$lock" --store "$store_path" \
        >"$WORK/refusal.out" 2>&1
    then
        fail "$label was accepted"
    fi
    grep -Fq -- "$needle" "$WORK/refusal.out" ||
        fail "$label did not say '$needle': $(sed -n '1,12p' "$WORK/refusal.out" | tr '\n' ' ')"
    if grep -Eq '^rough-graph-v2: exact |root requirement\(s\)|reachable remote identity/version pair\(s\)' \
        "$WORK/refusal.out"
    then
        fail "$label emitted partial success or graph counts"
    fi
    test ! -e "$WORK/network.called" && test ! -e "$WORK/ambient-store" &&
        test ! -e "$WORK/git.trace" && test ! -e "$WORK/git-trace2.event" ||
        fail "$label used network, ambient store, or ambient Git tracing"
    scope_state "$requirements" "$lock" "$store_path" \
        "$WORK/refusal.after"
    cmp "$WORK/refusal.before" "$WORK/refusal.after" ||
        fail "$label mutated repository, requirements, lock, store, or HOME/XDG state"
}

expect_requirements_refusal() {
    label=$1
    needle=$2
    requirements=$3
    scope_state "$requirements" "$WORK/no-lock" "$WORK/no-store" \
        "$WORK/requirements-refusal.before"
    rm -f "$WORK/network.called"
    if hostile_requirements inspect "$requirements" \
        >"$WORK/requirements-refusal.out" 2>&1
    then
        fail "$label was accepted"
    fi
    grep -Fq -- "$needle" "$WORK/requirements-refusal.out" ||
        fail "$label did not say '$needle': $(sed -n '1,8p' "$WORK/requirements-refusal.out" | tr '\n' ' ')"
    if grep -q '^requirements[[:space:]]' "$WORK/requirements-refusal.out"; then
        fail "$label emitted a partial normalized plan"
    fi
    test ! -e "$WORK/network.called" && test ! -e "$WORK/ambient-store" ||
        fail "$label used network or an ambient store"
    scope_state "$requirements" "$WORK/no-lock" "$WORK/no-store" \
        "$WORK/requirements-refusal.after"
    cmp "$WORK/requirements-refusal.before" \
        "$WORK/requirements-refusal.after" ||
        fail "$label mutated repository, requirements, or HOME/XDG state"
}

expect_pre_tool_refusal() {
    label=$1
    needle=$2
    requirements=$3
    lock=$4
    store_path=$5
    scope_state "$requirements" "$lock" "$store_path" \
        "$WORK/pre-tool-refusal.before"
    rm -f "$WORK/tool-git.called" "$WORK/network.called"
    if env -i PATH="$WORK/git-forbid:$HOSTILE_BIN:$BASE_PATH" HOME="$HOSTILE_HOME" \
        XDG_CACHE_HOME="$HOSTILE_XDG" KPM_STORE="$WORK/ambient-store" \
        KPM_NETWORK_SENTINEL="$WORK/tool-git.called" \
        http_proxy=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 \
        ALL_PROXY=socks5://127.0.0.1:9 \
        "$TOOL" inspect "$requirements" "$lock" --store "$store_path" \
        >"$WORK/pre-tool-refusal.out" 2>&1
    then
        fail "$label was accepted"
    fi
    grep -Fq -- "$needle" "$WORK/pre-tool-refusal.out" ||
        fail "$label did not preserve its earlier diagnostic: $(sed -n '1,8p' "$WORK/pre-tool-refusal.out" | tr '\n' ' ')"
    test ! -e "$WORK/tool-git.called" && test ! -e "$WORK/network.called" ||
        fail "$label invoked the local tool/Git identity or network before its precedence point"
    if grep -Eq '^rough-graph-v2: exact |root requirement\(s\)|reachable remote identity/version pair\(s\)' \
        "$WORK/pre-tool-refusal.out"
    then
        fail "$label emitted a partial graph plan, count, or success boundary"
    fi
    test ! -e "$WORK/ambient-store" ||
        fail "$label used an ambient store"
    scope_state "$requirements" "$lock" "$store_path" \
        "$WORK/pre-tool-refusal.after"
    cmp "$WORK/pre-tool-refusal.before" "$WORK/pre-tool-refusal.after" ||
        fail "$label mutated repository, requirements, lock, store, or HOME/XDG state"
}

test -x "$TOOL" && test -x "$REQUIREMENTS_TOOL" &&
    test -x "$TOOL_IDENTITY_TOOL" ||
    fail 'rough-graph/requirements/tool-identity adapters are not executable'

TAB=$(printf '\t')
D0=0000000000000000000000000000000000000000000000000000000000000000
TOOL_DIGEST=$(sh "$TOOL_IDENTITY_TOOL" digest) ||
    fail 'the current lock-v2 tool identity could not be computed'
ID_A=https://a.example/pkg/
ID_B=https://b.example/pkg/
ID_C=https://c.example/pkg/
ID_W=https://workspace.example/tool/
V_A=1.2.0
V_B=1.0.0
STORE=$WORK/store
mkdir -p "$STORE" "$WORK/objects"
mkdir -p "$WORK/git-forbid"
cp "$ROOT/tests/pm/network-sentinel.sh" "$WORK/git-forbid/git"
chmod +x "$WORK/git-forbid/git"

printf 'alpha bytes\n' >"$WORK/objects/a.bin"
printf 'beta bytes\n' >"$WORK/objects/b.bin"
file_a=$(add_object "$WORK/objects/a.bin")
file_b=$(add_object "$WORK/objects/b.bin")
size_file_a=$(wc -c <"$WORK/objects/a.bin" | tr -d ' ')
size_file_b=$(wc -c <"$WORK/objects/b.bin" | tr -d ' ')

{
    printf 'kofun-metadata/v1\n'
    printf 'identity\t%s\n' "$ID_A"
    printf 'version\t%s\n' "$V_A"
    printf 'dependency\t%s\t%s\n' "$ID_B" "$V_B"
    printf 'file\ta.bin\tdata\t%s\t%s\n' "$size_file_a" "$file_a"
} >"$WORK/objects/meta-a"
{
    printf 'kofun-metadata/v1\n'
    printf 'identity\t%s\n' "$ID_B"
    printf 'version\t%s\n' "$V_B"
    printf 'file\tb.bin\tdata\t%s\t%s\n' "$size_file_b" "$file_b"
} >"$WORK/objects/meta-b"
meta_a=$(add_object "$WORK/objects/meta-a")
meta_b=$(add_object "$WORK/objects/meta-b")
size_meta_a=$(wc -c <"$WORK/objects/meta-a" | tr -d ' ')
size_meta_b=$(wc -c <"$WORK/objects/meta-b" | tr -d ' ')

{
    printf 'kofun-pm.requirements/v2\n'
    printf 'root\t%s\t%s\n' "$ID_A" "$V_A"
    printf 'member\t%s\n' "$ID_W"
    printf 'member-requirement\t%s\t%s\t%s\n' "$ID_W" "$ID_B" "$V_B"
} >"$WORK/requirements"
{
    printf 'package\t%s\tselected\t%s\n' "$ID_A" "$V_A"
    printf 'package\t%s\tselected\t%s\n' "$ID_B" "$V_B"
    printf 'package\t%s\tworkspace\t-\n' "$ID_W"
    printf 'metadata\t%s\t%s\t%s\t%s\n' "$ID_A" "$V_A" "$size_meta_a" "$meta_a"
    printf 'metadata\t%s\t%s\t%s\t%s\n' "$ID_B" "$V_B" "$size_meta_b" "$meta_b"
    printf 'file\t%s\t%s\ta.bin\tdata\t%s\t%s\n' "$ID_A" "$V_A" "$size_file_a" "$file_a"
    printf 'file\t%s\t%s\tb.bin\tdata\t%s\t%s\n' "$ID_B" "$V_B" "$size_file_b" "$file_b"
} >"$WORK/body"
write_lock "$WORK/body" "$WORK/requirements" "$WORK/lock"

# Requirements grammar, lock structure/self-digest, and the exact requirements
# digest all precede invocation of the current local tool/Git closure.
printf 'wrong\n' >"$WORK/pre-tool-bad.requirements"
expect_pre_tool_refusal 'malformed requirements before tool identity' \
    'first line is not exactly kofun-pm.requirements/v2' \
    "$WORK/pre-tool-bad.requirements" "$WORK/missing.lock" "$WORK/missing-store"
printf 'wrong\n' >"$WORK/pre-tool-bad.lock"
expect_pre_tool_refusal 'malformed lock before tool identity' \
    "first header is not '# format: kofun-pm.lock/v2'" \
    "$WORK/requirements" "$WORK/pre-tool-bad.lock" "$STORE"
sed 's/^# tool: ./# tool: f/' "$WORK/lock" >"$WORK/pre-tool-self.lock"
expect_pre_tool_refusal 'lock self-digest before tool identity' \
    'lock digest does not cover its preceding bytes' \
    "$WORK/requirements" "$WORK/pre-tool-self.lock" "$STORE"

"$TOOL" inspect "$WORK/requirements" "$WORK/lock" --store "$STORE" \
    >"$WORK/valid.out"
grep -Fq '1 root requirement(s), 1 workspace member(s), 2 reachable remote identity/version pair(s), 2 selected remote identity(ies), 3 total requirement/dependency edge row(s)' \
    "$WORK/valid.out" || fail 'valid graph did not report exact complete counts'
grep -Fq 'exact current tool closure and supplied requirements/lock/store rough graph passed' \
    "$WORK/valid.out" || fail 'valid graph omitted its exact tool-closure binding'
grep -Fq 'supplied offline graph inputs and current local tool closure only' \
    "$WORK/valid.out" || fail 'valid graph omitted its supplied/offline boundary'
grep -Fq 'manifest parsing, catalog authenticity/history/non-equivocation' \
    "$WORK/valid.out" || fail 'valid graph overstated its boundary'

# Requirements grammar is complete before lock/store work. Logical map keys
# are unique even when a repeated key changes only its minimum value.
printf 'kofun-pm.requirements/v2\n' >"$WORK/empty.requirements"
: >"$WORK/empty.body"
write_lock "$WORK/empty.body" "$WORK/empty.requirements" "$WORK/empty.lock"
"$TOOL" inspect "$WORK/empty.requirements" "$WORK/empty.lock" --store "$STORE" \
    >"$WORK/empty.out"
grep -Fq '0 root requirement(s), 0 workspace member(s), 0 reachable remote identity/version pair(s), 0 selected remote identity(ies), 0 total requirement/dependency edge row(s)' \
    "$WORK/empty.out" || fail 'empty rough graph did not report exact zero counts'
printf 'wrong\n' >"$WORK/bad-header.requirements"
expect_refusal 'requirements header' 'first line is not exactly kofun-pm.requirements/v2' \
    "$WORK/bad-header.requirements" "$WORK/missing.lock" "$WORK/missing-store"
{
    printf 'kofun-pm.requirements/v2\nmember\t%s\n' "$ID_W"
    printf 'root\t%s\t%s\n' "$ID_A" "$V_A"
} >"$WORK/order.requirements"
expect_refusal 'requirements section order' 'root row appears after another row section' \
    "$WORK/order.requirements" "$WORK/missing.lock" "$WORK/missing-store"
{
    printf 'kofun-pm.requirements/v2\n'
    printf 'member-requirement\t%s\t%s\t%s\n' "$ID_W" "$ID_A" "$V_A"
} >"$WORK/orphan-member.requirements"
expect_refusal 'orphan member requirement' 'owner is not a declared workspace member' \
    "$WORK/orphan-member.requirements" "$WORK/missing.lock" "$WORK/missing-store"
{
    printf 'kofun-pm.requirements/v2\n'
    printf 'root\t%s\t1.2.0\nroot\t%s\t1.10.0\n' "$ID_A" "$ID_A"
} >"$WORK/duplicate-root.requirements"
expect_refusal 'duplicate root logical key' 'not in strict identity-byte order' \
    "$WORK/duplicate-root.requirements" "$WORK/missing.lock" "$WORK/missing-store"
{
    printf 'kofun-pm.requirements/v2\n'
    printf 'root\t%s\t%s\textra\n' "$ID_A" "$V_A"
} >"$WORK/root-fields.requirements"
expect_requirements_refusal 'root field count' 'root row must have three fields' \
    "$WORK/root-fields.requirements"
printf 'kofun-pm.requirements/v2\n# comment\n' \
    >"$WORK/comment.requirements"
expect_requirements_refusal 'requirements comment' \
    'unknown or blank requirements row kind' "$WORK/comment.requirements"
printf 'kofun-pm.requirements/v2\n\n' >"$WORK/blank.requirements"
expect_requirements_refusal 'requirements blank row' \
    'unknown or blank requirements row kind' "$WORK/blank.requirements"
{
    printf 'kofun-pm.requirements/v2\n'
    printf 'member\thttps://z.example/member/\n'
    printf 'member\thttps://a.example/member/\n'
} >"$WORK/member-order.requirements"
expect_requirements_refusal 'member byte order' \
    'member rows are not in strict identity-byte order' \
    "$WORK/member-order.requirements"
{
    printf 'kofun-pm.requirements/v2\nmember\t%s\n' "$ID_W"
    printf 'member-requirement\t%s\t%s\t1.0.0\n' "$ID_W" "$ID_A"
    printf 'member-requirement\t%s\t%s\t1.1.0\n' "$ID_W" "$ID_A"
} >"$WORK/member-key.requirements"
expect_requirements_refusal 'member-requirement logical key duplicate' \
    'not in strict member/identity-byte order' "$WORK/member-key.requirements"
{
    printf 'kofun-pm.requirements/v2\n'
    printf 'root\thttps://127.0.0.1/pkg/\t1.0.0\n'
} >"$WORK/numeric-id.requirements"
expect_requirements_refusal 'requirements numeric identity' \
    'forbidden numeric IP literal form' "$WORK/numeric-id.requirements"
{
    printf 'kofun-pm.requirements/v2\n'
    printf 'root\t%s\t1.02.0\n' "$ID_A"
} >"$WORK/version.requirements"
expect_requirements_refusal 'requirements canonical version' \
    'not canonical unsigned decimal' "$WORK/version.requirements"
printf 'kofun-pm.requirements/v2\r\n' >"$WORK/cr.requirements"
expect_refusal 'requirements CR' 'byte outside ASCII, HT, and LF' \
    "$WORK/cr.requirements" "$WORK/missing.lock" "$WORK/missing-store"
printf 'kofun-pm.requirements/v2\n\000' >"$WORK/nul.requirements"
expect_requirements_refusal 'requirements NUL' 'byte outside ASCII, HT, and LF' \
    "$WORK/nul.requirements" "$WORK/missing.lock" "$WORK/missing-store"
printf 'kofun-pm.requirements/v2\n\377' >"$WORK/non-ascii.requirements"
expect_requirements_refusal 'requirements non-ASCII' \
    'byte outside ASCII, HT, and LF' \
    "$WORK/non-ascii.requirements" "$WORK/missing.lock" "$WORK/missing-store"
printf 'kofun-pm.requirements/v2' >"$WORK/no-lf.requirements"
expect_refusal 'requirements final LF' 'must end in exactly one LF' \
    "$WORK/no-lf.requirements" "$WORK/missing.lock" "$WORK/missing-store"
printf 'kofun-pm.requirements/v2\n\n' >"$WORK/double-lf.requirements"
expect_requirements_refusal 'requirements double final LF' \
    'unknown or blank requirements row kind' \
    "$WORK/double-lf.requirements" "$WORK/missing.lock" "$WORK/missing-store"
ln -s "$WORK/requirements" "$WORK/requirements.symlink"
expect_refusal 'requirements symlink' 'not a regular non-symlink file' \
    "$WORK/requirements.symlink" "$WORK/missing.lock" "$WORK/missing-store"
mkfifo "$WORK/requirements.fifo"
expect_refusal 'requirements FIFO' 'not a regular non-symlink file' \
    "$WORK/requirements.fifo" "$WORK/missing.lock" "$WORK/missing-store"

# A same-size valid requirements mutation reaches the exact lock header
# comparison before any missing/corrupt store object can be observed.
sed 's/1\.2\.0/1.2.1/' "$WORK/requirements" >"$WORK/digest-mismatch.requirements"
test "$(wc -c <"$WORK/digest-mismatch.requirements" | tr -d ' ')" = \
    "$(wc -c <"$WORK/requirements" | tr -d ' ')" ||
    fail 'requirements digest fixture changed size'
mkdir -p "$WORK/empty-store"
expect_pre_tool_refusal 'requirements digest mismatch does not invoke tool identity' \
    'lock requirements digest does not match the supplied requirements bytes' \
    "$WORK/digest-mismatch.requirements" "$WORK/lock" "$WORK/empty-store"
expect_refusal 'requirements digest mismatch before store' \
    'lock requirements digest does not match the supplied requirements bytes' \
    "$WORK/digest-mismatch.requirements" "$WORK/lock" "$WORK/empty-store"
grep -Fq "  expected $(sha256 <"$WORK/requirements")" "$WORK/refusal.out" &&
    grep -Fq "  actual   $(sha256 <"$WORK/digest-mismatch.requirements")" \
        "$WORK/refusal.out" || fail 'digest mismatch omitted exact recorded/supplied values'
if grep -Fq 'metadata object is missing or corrupt' "$WORK/refusal.out"; then
    fail 'requirements digest mismatch opened a store object'
fi

# The current local tool closure is bound after the exact requirements digest
# and before any lock-named store object is opened. Re-sign the outer lock so a
# wrong canonical tool digest reaches that distinct check.
write_lock "$WORK/body" "$WORK/requirements" "$WORK/tool-mismatch.lock" "$D0"
mkdir -p "$WORK/store-head-spy"
real_store_head=$(command -v head)
{
    printf '#!/bin/sh\nset -eu\n'
    printf 'input=$(readlink "/proc/$$/fd/0" 2>/dev/null || :)\n'
    printf 'case "$input" in "$KPM_WATCH_STORE"/*) : >"$KPM_STORE_CALLED" ;; esac\n'
    printf 'exec "%s" "$@"\n' "$real_store_head"
} >"$WORK/store-head-spy/head"
chmod +x "$WORK/store-head-spy/head"
rm -f "$WORK/store.called"
KPM_EXTRA_PATH="$WORK/store-head-spy" KPM_STORE_CALLED="$WORK/store.called" \
KPM_WATCH_STORE="$STORE" \
expect_refusal 'tool digest mismatch before store' \
    'lock tool digest does not match the current local tool closure' \
    "$WORK/requirements" "$WORK/tool-mismatch.lock" "$STORE"
grep -Fq "  expected $D0" "$WORK/refusal.out" &&
    grep -Fq "  actual   $TOOL_DIGEST" "$WORK/refusal.out" ||
    fail 'tool mismatch omitted exact recorded/current values'
if grep -Fq 'metadata object is missing or corrupt' "$WORK/refusal.out"; then
    fail 'tool digest mismatch opened a store object'
fi
test ! -e "$WORK/store.called" ||
    fail 'tool digest mismatch invoked the store snapshot adapter'

# Missing reachable pairs and unreachable retained metadata are distinct. A
# higher retained version never substitutes for an exact missing minimum.
{
    printf 'kofun-pm.requirements/v2\n'
    printf 'root\t%s\t%s\n' "$ID_A" "$V_A"
    printf 'root\t%s\t1.0.0\n' "$ID_C"
    printf 'member\t%s\n' "$ID_W"
    printf 'member-requirement\t%s\t%s\t%s\n' "$ID_W" "$ID_B" "$V_B"
} >"$WORK/missing.requirements"
write_lock "$WORK/body" "$WORK/missing.requirements" "$WORK/missing.lock"
expect_refusal 'missing reachable root pair' \
    "reachable metadata is missing from lock: $ID_C@1.0.0" \
    "$WORK/missing.requirements" "$WORK/missing.lock" "$STORE"

{
    printf 'kofun-metadata/v1\nidentity\t%s\nversion\t1.0.0\n' "$ID_A"
    printf 'file\ta.bin\tdata\t%s\t%s\n' "$size_file_a" "$file_a"
} >"$WORK/objects/meta-a-old"
meta_a_old=$(add_object "$WORK/objects/meta-a-old")
size_meta_a_old=$(wc -c <"$WORK/objects/meta-a-old" | tr -d ' ')
{
    sed -n '1,3p' "$WORK/body"
    printf 'metadata\t%s\t1.0.0\t%s\t%s\n' "$ID_A" "$size_meta_a_old" "$meta_a_old"
    sed -n '4,$p' "$WORK/body"
} >"$WORK/extra.body"
write_lock "$WORK/extra.body" "$WORK/requirements" "$WORK/extra.lock"
expect_refusal 'unreachable retained metadata' \
    "lock metadata is unreachable from supplied requirements: $ID_A@1.0.0" \
    "$WORK/requirements" "$WORK/extra.lock" "$STORE"

{
    printf 'kofun-metadata/v1\nidentity\t%s\nversion\t1.1.0\n' "$ID_C"
    printf 'file\tc.bin\tdata\t%s\t%s\n' "$size_file_a" "$file_a"
} >"$WORK/objects/meta-c-high"
meta_c_high=$(add_object "$WORK/objects/meta-c-high")
size_meta_c_high=$(wc -c <"$WORK/objects/meta-c-high" | tr -d ' ')
{
    printf 'package\t%s\tselected\t%s\n' "$ID_A" "$V_A"
    printf 'package\t%s\tselected\t%s\n' "$ID_B" "$V_B"
    printf 'package\t%s\tselected\t1.1.0\n' "$ID_C"
    printf 'package\t%s\tworkspace\t-\n' "$ID_W"
    printf 'metadata\t%s\t%s\t%s\t%s\n' "$ID_A" "$V_A" "$size_meta_a" "$meta_a"
    printf 'metadata\t%s\t%s\t%s\t%s\n' "$ID_B" "$V_B" "$size_meta_b" "$meta_b"
    printf 'metadata\t%s\t1.1.0\t%s\t%s\n' "$ID_C" "$size_meta_c_high" "$meta_c_high"
    printf 'file\t%s\t%s\ta.bin\tdata\t%s\t%s\n' "$ID_A" "$V_A" "$size_file_a" "$file_a"
    printf 'file\t%s\t%s\tb.bin\tdata\t%s\t%s\n' "$ID_B" "$V_B" "$size_file_b" "$file_b"
    printf 'file\t%s\t1.1.0\tc.bin\tdata\t%s\t%s\n' "$ID_C" "$size_file_a" "$file_a"
} >"$WORK/higher.body"
write_lock "$WORK/higher.body" "$WORK/missing.requirements" "$WORK/higher.lock"
expect_refusal 'higher retained version is no exact substitute' \
    "reachable metadata is missing from lock: $ID_C@1.0.0" \
    "$WORK/missing.requirements" "$WORK/higher.lock" "$STORE"

# Roots and member requirements enter one identity/semantic-version priority
# queue. Section order must not decide which missing pair is diagnosed first.
{
    printf 'kofun-pm.requirements/v2\n'
    printf 'root\thttps://z.example/pkg/\t1.0.0\n'
    printf 'member\t%s\n' "$ID_W"
    printf 'member-requirement\t%s\t%s\t1.0.0\n' "$ID_W" "$ID_A"
} >"$WORK/priority.requirements"
printf 'package\t%s\tworkspace\t-\n' "$ID_W" >"$WORK/priority.body"
write_lock "$WORK/priority.body" "$WORK/priority.requirements" \
    "$WORK/priority.lock"
expect_refusal 'cross-section priority queue' \
    "reachable metadata is missing from lock: $ID_A@1.0.0" \
    "$WORK/priority.requirements" "$WORK/priority.lock" "$STORE"
if grep -Fq 'https://z.example/pkg/@1.0.0' "$WORK/refusal.out"; then
    fail 'root section order overrode the smallest pending remote pair'
fi
{
    printf 'kofun-pm.requirements/v2\n'
    printf 'root\t%s\t1.10.0\n' "$ID_A"
    printf 'member\t%s\n' "$ID_W"
    printf 'member-requirement\t%s\t%s\t1.2.0\n' "$ID_W" "$ID_A"
} >"$WORK/semantic-priority.requirements"
write_lock "$WORK/priority.body" "$WORK/semantic-priority.requirements" \
    "$WORK/semantic-priority.lock"
expect_refusal 'semantic-version priority queue' \
    "reachable metadata is missing from lock: $ID_A@1.2.0" \
    "$WORK/semantic-priority.requirements" "$WORK/semantic-priority.lock" "$STORE"
if grep -Fq "$ID_A@1.10.0" "$WORK/refusal.out"; then
    fail 'lexical version order overrode the semantic pending-pair order'
fi

# Workspace targets never create remote pairs. Exact workspace package-set
# equality still holds, including for an otherwise unreferenced member.
{
    printf 'kofun-pm.requirements/v2\n'
    printf 'root\t%s\t1.0.0\n' "$ID_W"
    printf 'member\t%s\n' "$ID_W"
} >"$WORK/workspace.requirements"
printf 'package\t%s\tworkspace\t-\n' "$ID_W" >"$WORK/workspace.body"
write_lock "$WORK/workspace.body" "$WORK/workspace.requirements" \
    "$WORK/workspace.lock"
"$TOOL" inspect "$WORK/workspace.requirements" "$WORK/workspace.lock" \
    --store "$STORE" >"$WORK/workspace.out"
grep -Fq '1 root requirement(s), 1 workspace member(s), 0 reachable remote identity/version pair(s), 0 selected remote identity(ies), 1 total requirement/dependency edge row(s)' \
    "$WORK/workspace.out" || fail 'workspace exclusion counts are wrong'

ID_W1=https://w1.example/member/
ID_W2=https://w2.example/member/
{
    printf 'kofun-pm.requirements/v2\n'
    printf 'member\t%s\nmember\t%s\n' "$ID_W1" "$ID_W2"
    printf 'member-requirement\t%s\t%s\t1.0.0\n' "$ID_W1" "$ID_W2"
    printf 'member-requirement\t%s\t%s\t1.0.0\n' "$ID_W2" "$ID_W1"
} >"$WORK/workspace-pure-cycle.requirements"
{
    printf 'package\t%s\tworkspace\t-\n' "$ID_W1"
    printf 'package\t%s\tworkspace\t-\n' "$ID_W2"
} >"$WORK/workspace-pure-cycle.body"
write_lock "$WORK/workspace-pure-cycle.body" \
    "$WORK/workspace-pure-cycle.requirements" "$WORK/workspace-pure-cycle.lock"
"$TOOL" inspect "$WORK/workspace-pure-cycle.requirements" \
    "$WORK/workspace-pure-cycle.lock" --store "$STORE" \
    >"$WORK/workspace-pure-cycle.out"
grep -Fq '0 root requirement(s), 2 workspace member(s), 0 reachable remote identity/version pair(s), 0 selected remote identity(ies), 2 total requirement/dependency edge row(s)' \
    "$WORK/workspace-pure-cycle.out" || fail 'pure workspace cycle did not remain entirely local'

{
    printf 'kofun-metadata/v1\nidentity\t%s\nversion\t%s\n' "$ID_A" "$V_A"
    printf 'dependency\t%s\t1.0.0\n' "$ID_W"
    printf 'file\ta.bin\tdata\t%s\t%s\n' "$size_file_a" "$file_a"
} >"$WORK/objects/meta-workspace-cycle"
meta_workspace_cycle=$(add_object "$WORK/objects/meta-workspace-cycle")
size_meta_workspace_cycle=$(wc -c <"$WORK/objects/meta-workspace-cycle" | tr -d ' ')
{
    printf 'kofun-pm.requirements/v2\nmember\t%s\n' "$ID_W"
    printf 'member-requirement\t%s\t%s\t%s\n' "$ID_W" "$ID_A" "$V_A"
} >"$WORK/workspace-cycle.requirements"
{
    printf 'package\t%s\tselected\t%s\n' "$ID_A" "$V_A"
    printf 'package\t%s\tworkspace\t-\n' "$ID_W"
    printf 'metadata\t%s\t%s\t%s\t%s\n' "$ID_A" "$V_A" \
        "$size_meta_workspace_cycle" "$meta_workspace_cycle"
    printf 'file\t%s\t%s\ta.bin\tdata\t%s\t%s\n' "$ID_A" "$V_A" \
        "$size_file_a" "$file_a"
} >"$WORK/workspace-cycle.body"
write_lock "$WORK/workspace-cycle.body" "$WORK/workspace-cycle.requirements" \
    "$WORK/workspace-cycle.lock"
"$TOOL" inspect "$WORK/workspace-cycle.requirements" \
    "$WORK/workspace-cycle.lock" --store "$STORE" \
    >"$WORK/workspace-cycle.out"
grep -Fq '0 root requirement(s), 1 workspace member(s), 1 reachable remote identity/version pair(s), 1 selected remote identity(ies), 2 total requirement/dependency edge row(s)' \
    "$WORK/workspace-cycle.out" || fail 'mixed workspace/remote cycle was not excluded exactly'

# Semantic maximum selection is driven by reachable minima, not lexical order,
# and an exact-pair cycle terminates without dropping superseded metadata.
{
    printf 'kofun-metadata/v1\nidentity\t%s\nversion\t1.10.0\n' "$ID_A"
    printf 'dependency\t%s\t%s\n' "$ID_B" "$V_B"
    printf 'file\ta.bin\tdata\t%s\t%s\n' "$size_file_a" "$file_a"
} >"$WORK/objects/meta-a-new"
{
    printf 'kofun-metadata/v1\nidentity\t%s\nversion\t%s\n' "$ID_B" "$V_B"
    printf 'dependency\t%s\t1.10.0\n' "$ID_A"
    printf 'file\tb.bin\tdata\t%s\t%s\n' "$size_file_b" "$file_b"
} >"$WORK/objects/meta-b-cycle"
meta_a_new=$(add_object "$WORK/objects/meta-a-new")
meta_b_cycle=$(add_object "$WORK/objects/meta-b-cycle")
size_meta_a_new=$(wc -c <"$WORK/objects/meta-a-new" | tr -d ' ')
size_meta_b_cycle=$(wc -c <"$WORK/objects/meta-b-cycle" | tr -d ' ')
{
    printf 'package\t%s\tselected\t1.10.0\n' "$ID_A"
    printf 'package\t%s\tselected\t%s\n' "$ID_B" "$V_B"
    printf 'package\t%s\tworkspace\t-\n' "$ID_W"
    printf 'metadata\t%s\t%s\t%s\t%s\n' "$ID_A" "$V_A" "$size_meta_a" "$meta_a"
    printf 'metadata\t%s\t1.10.0\t%s\t%s\n' "$ID_A" "$size_meta_a_new" "$meta_a_new"
    printf 'metadata\t%s\t%s\t%s\t%s\n' "$ID_B" "$V_B" "$size_meta_b_cycle" "$meta_b_cycle"
    printf 'file\t%s\t1.10.0\ta.bin\tdata\t%s\t%s\n' "$ID_A" "$size_file_a" "$file_a"
    printf 'file\t%s\t%s\tb.bin\tdata\t%s\t%s\n' "$ID_B" "$V_B" "$size_file_b" "$file_b"
} >"$WORK/cycle.body"
write_lock "$WORK/cycle.body" "$WORK/requirements" "$WORK/cycle.lock"
"$TOOL" inspect "$WORK/requirements" "$WORK/cycle.lock" --store "$STORE" \
    >"$WORK/cycle.out"
grep -Fq '3 reachable remote identity/version pair(s), 2 selected remote identity(ies), 5 total requirement/dependency edge row(s)' \
    "$WORK/cycle.out" || fail 'semantic maximum/cycle graph counts are wrong'

# Exact '-' operands are literal files, never ambient stdin.
mkdir -p "$WORK/option-requirements" "$WORK/option-lock"
cp "$WORK/requirements" "$WORK/option-requirements/-"
(cd "$WORK/option-requirements" && "$TOOL" inspect - "$WORK/lock" \
    --store "$STORE" </dev/null) >"$WORK/option-requirements.out" ||
    fail "requirements pathname '-' was replaced by stdin"
cp "$WORK/lock" "$WORK/option-lock/-"
(cd "$WORK/option-lock" && "$TOOL" inspect "$WORK/requirements" - \
    --store "$STORE" </dev/null) >"$WORK/option-lock.out" ||
    fail "lock pathname '-' was replaced by stdin"

# Requirements structural and semantic collection bounds have exact positive
# edges. These plan-only fixtures must finish before any lock/store pathname.
{
    printf 'kofun-pm.requirements/v2\n'
    n=0
    while test "$n" -lt 1024; do
        printf 'root\thttps://r%04d.example/pkg/\t1.0.0\n' "$n"
        n=$((n + 1))
    done
} >"$WORK/roots-1024.requirements"
"$REQUIREMENTS_TOOL" inspect "$WORK/roots-1024.requirements" \
    >"$WORK/roots-1024.plan"
{
    sed -n '1,$p' "$WORK/roots-1024.requirements"
    printf 'root\thttps://r1024.example/pkg/\t1.0.0\n'
} >"$WORK/roots-1025.requirements"
expect_requirements_refusal 'root requirement count +1' \
    'root requirement count exceeds 1024' "$WORK/roots-1025.requirements"

{
    printf 'kofun-pm.requirements/v2\n'
    member=0
    while test "$member" -lt 1024; do
        printf 'member\thttps://w%04d.example/member/\n' "$member"
        member=$((member + 1))
    done
    member=0
    while test "$member" -lt 1024; do
        edge=0
        while test "$edge" -lt 16; do
            printf 'member-requirement\thttps://w%04d.example/member/\thttps://t%04d-%02d.example/pkg/\t1.0.0\n' \
                "$member" "$member" "$edge"
            edge=$((edge + 1))
        done
        member=$((member + 1))
    done
} >"$WORK/rows-17409.requirements"
test "$(wc -l <"$WORK/rows-17409.requirements" | tr -d ' ')" = 17409 ||
    fail 'exact requirements row-bound fixture has the wrong row count'
"$REQUIREMENTS_TOOL" inspect "$WORK/rows-17409.requirements" \
    >"$WORK/rows-17409.plan"
{
    sed -n '1,$p' "$WORK/rows-17409.requirements"
    printf 'unknown\n'
} >"$WORK/rows-17410.requirements"
expect_requirements_refusal 'requirements row bound +1' \
    'exceeds the 17409-row structural bound' "$WORK/rows-17410.requirements"

{
    printf 'kofun-pm.requirements/v2\n'
    n=0
    while test "$n" -lt 1025; do
        printf 'member\thttps://m%04d.example/member/\n' "$n"
        n=$((n + 1))
    done
} >"$WORK/members-1025.requirements"
expect_requirements_refusal 'workspace member count +1' \
    'workspace member count exceeds 1024' "$WORK/members-1025.requirements"

{
    head -c 8192 /dev/zero | tr '\000' x
    printf '\n'
} >"$WORK/line-8192.requirements"
expect_requirements_refusal 'exact requirements line bound reaches grammar' \
    'first line is not exactly kofun-pm.requirements/v2' \
    "$WORK/line-8192.requirements"
grep -Fq 'first line is not exactly kofun-pm.requirements/v2' \
    "$WORK/requirements-refusal.out" || fail 'exact line bound did not reach later grammar'
if grep -Fq 'line exceeds the 8192-byte structural bound' \
    "$WORK/requirements-refusal.out"
then
    fail 'exact 8192-byte requirements line was treated as overbound'
fi
{
    head -c 8193 /dev/zero | tr '\000' x
    printf '\n'
} >"$WORK/line-8193.requirements"
expect_requirements_refusal 'requirements line bound +1' \
    'line exceeds the 8192-byte structural bound' \
    "$WORK/line-8193.requirements"
dd if=/dev/zero of="$WORK/bytes-exact.requirements" bs=1 count=0 \
    seek=70254592 2>/dev/null
expect_requirements_refusal 'exact requirements byte bound reaches grammar' \
    'byte outside ASCII, HT, and LF' "$WORK/bytes-exact.requirements"
if grep -Fq 'exceeds the 70254592-byte input bound' \
    "$WORK/requirements-refusal.out"
then
    fail 'exact requirements byte bound was treated as overbound'
fi
dd if=/dev/zero of="$WORK/bytes-over.requirements" bs=1 count=0 \
    seek=70254593 2>/dev/null
expect_requirements_refusal 'requirements byte bound +1' \
    'exceeds the 70254592-byte input bound: 70254593' \
    "$WORK/bytes-over.requirements"

# The closure edge limit is additive across root, member, and every parsed
# remote dependency row. At exactly 16,384 it proceeds to graph comparison;
# the next edge refuses before any missing-pair diagnostic.
{
    printf 'kofun-metadata/v1\nidentity\t%s\nversion\t%s\n' "$ID_A" "$V_A"
    n=0
    while test "$n" -lt 256; do
        printf 'dependency\thttps://d%03d.example/pkg/\t1.0.0\n' "$n"
        n=$((n + 1))
    done
    printf 'file\ta.bin\tdata\t%s\t%s\n' "$size_file_a" "$file_a"
} >"$WORK/objects/meta-edge-bound"
meta_edge_bound=$(add_object "$WORK/objects/meta-edge-bound")
size_meta_edge_bound=$(wc -c <"$WORK/objects/meta-edge-bound" | tr -d ' ')
{
    printf 'kofun-pm.requirements/v2\nroot\t%s\t%s\n' "$ID_A" "$V_A"
    member=0
    while test "$member" -lt 1023; do
        printf 'member\thttps://w%04d.example/member/\n' "$member"
        member=$((member + 1))
    done
    member=0
    while test "$member" -lt 1007; do
        edge=0
        while test "$edge" -lt 16; do
            printf 'member-requirement\thttps://w%04d.example/member/\thttps://t%04d-%02d.example/pkg/\t1.0.0\n' \
                "$member" "$member" "$edge"
            edge=$((edge + 1))
        done
        member=$((member + 1))
    done
    edge=0
    while test "$edge" -lt 15; do
        printf 'member-requirement\thttps://w1007.example/member/\thttps://t1007-%02d.example/pkg/\t1.0.0\n' "$edge"
        edge=$((edge + 1))
    done
} >"$WORK/edges-16384.requirements"
{
    printf 'package\t%s\tselected\t%s\n' "$ID_A" "$V_A"
    member=0
    while test "$member" -lt 1023; do
        printf 'package\thttps://w%04d.example/member/\tworkspace\t-\n' "$member"
        member=$((member + 1))
    done
    printf 'metadata\t%s\t%s\t%s\t%s\n' "$ID_A" "$V_A" \
        "$size_meta_edge_bound" "$meta_edge_bound"
    printf 'file\t%s\t%s\ta.bin\tdata\t%s\t%s\n' "$ID_A" "$V_A" \
        "$size_file_a" "$file_a"
} >"$WORK/edge-bound.body"
write_lock "$WORK/edge-bound.body" "$WORK/edges-16384.requirements" \
    "$WORK/edges-16384.lock"
expect_refusal 'exact closure edge bound reaches graph comparison' \
    'package identities including workspace exceed 1024: 17407' \
    "$WORK/edges-16384.requirements" "$WORK/edges-16384.lock" "$STORE"
if grep -Fq 'edges exceed 16384' "$WORK/refusal.out"; then
    fail 'exact closure edge bound was refused as an overrun'
fi
{
    sed -n '1,$p' "$WORK/edges-16384.requirements"
    printf 'member-requirement\thttps://w1007.example/member/\thttps://t1007-15.example/pkg/\t1.0.0\n'
} >"$WORK/edges-16385.requirements"
write_lock "$WORK/edge-bound.body" "$WORK/edges-16385.requirements" \
    "$WORK/edges-16385.lock"
expect_refusal 'closure edge bound +1' \
    'root, member, and remote dependency edges exceed 16384: 16385' \
    "$WORK/edges-16385.requirements" "$WORK/edges-16385.lock" "$STORE"

# Workspace set differences are named before graph reachability.
write_lock "$WORK/empty.body" "$WORK/workspace.requirements" \
    "$WORK/missing-workspace.lock"
expect_refusal 'missing workspace package' \
    "workspace member is missing from lock packages: $ID_W" \
    "$WORK/workspace.requirements" "$WORK/missing-workspace.lock" "$STORE"
write_lock "$WORK/workspace.body" "$WORK/empty.requirements" \
    "$WORK/extra-workspace.lock"
expect_refusal 'extra workspace package' \
    "lock workspace package is not a declared member: $ID_W" \
    "$WORK/empty.requirements" "$WORK/extra-workspace.lock" "$STORE"
{
    printf 'kofun-pm.requirements/v2\n'
    printf 'root\t%s\t1.0.0\n' "$ID_C"
    printf 'member\t%s\n' "$ID_W"
} >"$WORK/workspace-precedence.requirements"
write_lock "$WORK/empty.body" "$WORK/workspace-precedence.requirements" \
    "$WORK/workspace-precedence.lock"
expect_refusal 'workspace equality before missing remote pair' \
    "workspace member is missing from lock packages: $ID_W" \
    "$WORK/workspace-precedence.requirements" \
    "$WORK/workspace-precedence.lock" "$STORE"
if grep -Fq "reachable metadata is missing from lock: $ID_C@1.0.0" \
    "$WORK/refusal.out"
then
    fail 'missing pair overrode workspace equality precedence'
fi

# Each explicit requirements and lock pathname is consumed once into the
# adapter-owned private snapshot. Swapping the original after head returns
# cannot change any later digest, parse, or graph decision.
real_head=$(command -v head)
mkdir -p "$WORK/head-spy"
{
    printf '#!/bin/sh\nset -eu\n'
    printf 'input=$(readlink "/proc/$$/fd/0" 2>/dev/null || :)\n'
    printf '"%s" "$@"\nstatus=$?\n' "$real_head"
    printf 'if test "$input" = "$KPM_SWAP_TARGET"; then\n'
    printf '  count=0\n  test ! -f "$KPM_SWAP_COUNT" || read -r count <"$KPM_SWAP_COUNT"\n'
    printf '  count=$((count + 1))\n  printf "%%s\\n" "$count" >"$KPM_SWAP_COUNT"\n'
    printf '  cp "$KPM_SWAP_BYTES" "$KPM_SWAP_TARGET"\nfi\nexit "$status"\n'
} >"$WORK/head-spy/head"
chmod +x "$WORK/head-spy/head"
cp "$WORK/requirements" "$WORK/requirements.saved"
PATH="$WORK/head-spy:$PATH" KPM_SWAP_TARGET="$WORK/requirements" \
KPM_SWAP_BYTES="$WORK/bad-header.requirements" \
KPM_SWAP_COUNT="$WORK/requirements.count" \
    "$TOOL" inspect "$WORK/requirements" "$WORK/lock" --store "$STORE" \
    >"$WORK/requirements-swap.out"
test "$(sed -n '1p' "$WORK/requirements.count")" = 1 ||
    fail 'requirements pathname was not read exactly once'
cp "$WORK/requirements.saved" "$WORK/requirements"
cp "$WORK/lock" "$WORK/lock.saved"
printf 'wrong\n' >"$WORK/bad.lock"
PATH="$WORK/head-spy:$PATH" KPM_SWAP_TARGET="$WORK/lock" \
KPM_SWAP_BYTES="$WORK/bad.lock" KPM_SWAP_COUNT="$WORK/lock.count" \
    "$TOOL" inspect "$WORK/requirements" "$WORK/lock" --store "$STORE" \
    >"$WORK/lock-swap.out"
test "$(sed -n '1p' "$WORK/lock.count")" = 1 ||
    fail 'lock pathname was not read exactly once'
cp "$WORK/lock.saved" "$WORK/lock"

# Success is covered separately; every refusal above already runs under the
# same hostile env-i helpers and checks its complete in-scope state before and
# after the call.
scope_state "$WORK/requirements" "$WORK/lock" "$STORE" \
    "$WORK/offline.before"
rm -f "$WORK/network.called" "$WORK/git.trace" "$WORK/git-trace2.event"
hostile_rough inspect "$WORK/requirements" "$WORK/lock" --store "$STORE" \
    >"$WORK/offline.out"
test ! -e "$WORK/network.called" && test ! -e "$WORK/ambient-store" &&
    test ! -e "$WORK/git.trace" && test ! -e "$WORK/git-trace2.event" ||
    fail 'rough-graph inspector used network, ambient store, or ambient Git tracing'
scope_state "$WORK/requirements" "$WORK/lock" "$STORE" \
    "$WORK/offline.after"
cmp "$WORK/offline.before" "$WORK/offline.after" ||
    fail 'rough-graph success mutated repository, explicit inputs, store, or HOME/XDG state'

printf 'pm: requirements v2 grammar, digest precedence, and literal paths: PASS\n'
printf 'pm: exact rough-graph reachability, workspace exclusion, and missing/extra pairs: PASS\n'
printf 'pm: semantic MVS maximum, repeated-edge accounting, and exact-pair cycles: PASS\n'
printf 'pm: rough-graph bounds, read-once snapshots, offline and read-only: PASS\n'
