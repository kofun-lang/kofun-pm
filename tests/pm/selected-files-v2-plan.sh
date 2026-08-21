#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
TOOL=$ROOT/scripts/selected-files-v2-plan.sh
LOCK_TOOL=$ROOT/scripts/lock-v2.sh
TOOL_IDENTITY_TOOL=$ROOT/scripts/lock-tool-v2.sh
STORE_TOOL=$ROOT/scripts/store.sh
WORK=$(mktemp -d "${TMPDIR:-/tmp}/kofun-pm-selected-files-plan-test.XXXXXX")
trap 'rm -rf "$WORK"' 0 1 2 15

fail() {
    printf 'pm: FAIL: selected-files-v2-plan: %s\n' "$*" >&2
    exit 1
}

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum <"$1" | cut -d' ' -f1
    else
        shasum -a 256 <"$1" | cut -d' ' -f1
    fi
}

entry_for() {
    entry_store=$1
    entry_digest=$2
    printf '%s/%s/%s\n' "$entry_store" \
        "$(printf '%s' "$entry_digest" | cut -c1-2)" \
        "$(printf '%s' "$entry_digest" | cut -c3-)"
}

add_object() {
    object_store=$1
    object_input=$2
    /bin/sh "$STORE_TOOL" --store "$object_store" add "$object_input" \
        2>/dev/null
}

write_lock() {
    lock_body=$1
    lock_requirements=$2
    lock_output=$3
    lock_tool=${4:-$TOOL_DIGEST}
    lock_covered=$lock_output.covered
    {
        printf '# format: kofun-pm.lock/v2\n'
        printf '# columns: typed rows: package identity state version | metadata identity version size sha256 | file identity version path kind size sha256\n'
        printf '# tool: %s\n' "$lock_tool"
        printf '# requirements: %s\n' "$(sha256_file "$lock_requirements")"
        sed -n '1,$p' "$lock_body"
    } >"$lock_covered"
    {
        sed -n '1,$p' "$lock_covered"
        printf '# digest: %s\n' "$(sha256_file "$lock_covered")"
    } >"$lock_output"
    rm -f "$lock_covered"
}

tree_state() {
    state_requirements=$1
    state_lock=$2
    state_store=$3
    state_output=$4
    {
        stat -c '%n %d %i %h %F %a %s' "$state_requirements" "$state_lock"
        sha256_file "$state_requirements"
        sha256_file "$state_lock"
        find "$state_store" -printf '%p %D %i %n %y %m %s\n' |
            LC_ALL=C sort
        find "$state_store" -type f -exec sha256sum '{}' ';' |
            LC_ALL=C sort
    } >"$state_output"
}

BASE_PATH=$PATH
HOSTILE_BIN=$WORK/hostile-bin
HOSTILE_HOME=$WORK/hostile-home
HOSTILE_XDG=$WORK/hostile-xdg
mkdir -p "$HOSTILE_BIN" "$HOSTILE_HOME" "$HOSTILE_XDG"
for command_name in curl wget fetch ftp sftp ssh nc ncat netcat telnet \
    openssl host dig nslookup getent
do
    cp "$ROOT/tests/pm/network-sentinel.sh" "$HOSTILE_BIN/$command_name"
done
{
    printf '#!/bin/sh\n'
    printf ': >"$KPM_ICONV_CALLED"\n'
    printf 'exit 97\n'
} >"$HOSTILE_BIN/iconv"
chmod +x "$HOSTILE_BIN"/*

run_plan() {
    env -i PATH="$HOSTILE_BIN:$BASE_PATH" HOME="$HOSTILE_HOME" \
        XDG_CACHE_HOME="$HOSTILE_XDG" KPM_STORE="$WORK/ambient-store" \
        KPM_NETWORK_SENTINEL="$WORK/network.called" \
        KPM_ICONV_CALLED="$WORK/iconv.called" \
        http_proxy=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 \
        ALL_PROXY=socks5://127.0.0.1:9 \
        "$TOOL" inspect "$1" "$2" --store "$3"
}

expect_refusal() {
    refusal_label=$1
    refusal_needle=$2
    refusal_requirements=$3
    refusal_lock=$4
    refusal_store=$5
    tree_state "$refusal_requirements" "$refusal_lock" "$refusal_store" \
        "$WORK/refusal.before"
    rm -f "$WORK/network.called" "$WORK/iconv.called"
    if run_plan "$refusal_requirements" "$refusal_lock" "$refusal_store" \
        >"$WORK/refusal.out" 2>"$WORK/refusal.err"
    then
        fail "$refusal_label was accepted"
    fi
    grep -Fq -- "$refusal_needle" "$WORK/refusal.err" ||
        fail "$refusal_label did not say '$refusal_needle': $(sed -n '1,10p' "$WORK/refusal.err" | tr '\n' ' ')"
    test ! -s "$WORK/refusal.out" ||
        fail "$refusal_label exposed a partial prefetch plan"
    test ! -e "$WORK/network.called" && test ! -e "$WORK/iconv.called" &&
        test ! -e "$WORK/ambient-store" ||
        fail "$refusal_label used network, iconv, or an ambient store"
    tree_state "$refusal_requirements" "$refusal_lock" "$refusal_store" \
        "$WORK/refusal.after"
    cmp "$WORK/refusal.before" "$WORK/refusal.after" ||
        fail "$refusal_label mutated requirements, lock, or store state"
}

test -x "$TOOL" && test -x "$LOCK_TOOL" && test -x "$TOOL_IDENTITY_TOOL" ||
    fail 'selected-plan, lock-v2, or tool-identity adapter is missing'

ID_A=https://a.example/pkg/
ID_B=https://b.example/pkg/
ID_W=https://workspace.example/tool/
V_A_OLD=1.0.0
V_A=1.2.0
V_B=1.0.0
D0=0000000000000000000000000000000000000000000000000000000000000000
TOOL_DIGEST=$(/bin/sh "$TOOL_IDENTITY_TOOL" digest) ||
    fail 'could not compute current tool identity'
STORE=$WORK/store-metadata-only
mkdir -p "$STORE" "$WORK/objects"

printf 'fn main() Int { 0 }\n' >"$WORK/objects/a.bytes"
printf 'opaque\377data\n' >"$WORK/objects/b.bytes"
FILE_A_DIGEST=$(sha256_file "$WORK/objects/a.bytes")
FILE_B_DIGEST=$(sha256_file "$WORK/objects/b.bytes")
FILE_A_SIZE=$(wc -c <"$WORK/objects/a.bytes" | tr -d ' ')
FILE_B_SIZE=$(wc -c <"$WORK/objects/b.bytes" | tr -d ' ')

{
    printf 'kofun-metadata/v1\nidentity\t%s\nversion\t%s\n' \
        "$ID_A" "$V_A_OLD"
    printf 'dependency\t%s\t%s\n' "$ID_B" "$V_B"
    printf 'file\told.bin\tdata\t%s\t%s\n' "$FILE_B_SIZE" "$FILE_B_DIGEST"
} >"$WORK/objects/meta-a-old"
{
    printf 'kofun-metadata/v1\nidentity\t%s\nversion\t%s\n' "$ID_A" "$V_A"
    printf 'dependency\t%s\t%s\n' "$ID_B" "$V_B"
    printf 'file\tdata/a.bin\tdata\t%s\t%s\n' "$FILE_A_SIZE" "$FILE_A_DIGEST"
    printf 'file\tsrc/postinstall.kofun\tsource\t%s\t%s\n' \
        "$FILE_A_SIZE" "$FILE_A_DIGEST"
} >"$WORK/objects/meta-a"
{
    printf 'kofun-metadata/v1\nidentity\t%s\nversion\t%s\n' "$ID_B" "$V_B"
    printf 'dependency\t%s\t%s\n' "$ID_A" "$V_A_OLD"
    printf 'file\tdata/b.bin\tdata\t%s\t%s\n' "$FILE_B_SIZE" "$FILE_B_DIGEST"
} >"$WORK/objects/meta-b"

META_A_OLD=$(add_object "$STORE" "$WORK/objects/meta-a-old")
META_A=$(add_object "$STORE" "$WORK/objects/meta-a")
META_B=$(add_object "$STORE" "$WORK/objects/meta-b")
META_A_OLD_SIZE=$(wc -c <"$WORK/objects/meta-a-old" | tr -d ' ')
META_A_SIZE=$(wc -c <"$WORK/objects/meta-a" | tr -d ' ')
META_B_SIZE=$(wc -c <"$WORK/objects/meta-b" | tr -d ' ')

{
    printf 'kofun-pm.requirements/v2\n'
    printf 'root\t%s\t%s\n' "$ID_A" "$V_A_OLD"
    printf 'member\t%s\n' "$ID_W"
    printf 'member-requirement\t%s\t%s\t%s\n' "$ID_W" "$ID_A" "$V_A"
} >"$WORK/requirements"
{
    printf 'package\t%s\tselected\t%s\n' "$ID_A" "$V_A"
    printf 'package\t%s\tselected\t%s\n' "$ID_B" "$V_B"
    printf 'package\t%s\tworkspace\t-\n' "$ID_W"
    printf 'metadata\t%s\t%s\t%s\t%s\n' "$ID_A" "$V_A_OLD" \
        "$META_A_OLD_SIZE" "$META_A_OLD"
    printf 'metadata\t%s\t%s\t%s\t%s\n' "$ID_A" "$V_A" \
        "$META_A_SIZE" "$META_A"
    printf 'metadata\t%s\t%s\t%s\t%s\n' "$ID_B" "$V_B" \
        "$META_B_SIZE" "$META_B"
    printf 'file\t%s\t%s\tdata/a.bin\tdata\t%s\t%s\n' \
        "$ID_A" "$V_A" "$FILE_A_SIZE" "$FILE_A_DIGEST"
    printf 'file\t%s\t%s\tsrc/postinstall.kofun\tsource\t%s\t%s\n' \
        "$ID_A" "$V_A" "$FILE_A_SIZE" "$FILE_A_DIGEST"
    printf 'file\t%s\t%s\tdata/b.bin\tdata\t%s\t%s\n' \
        "$ID_B" "$V_B" "$FILE_B_SIZE" "$FILE_B_DIGEST"
} >"$WORK/body"
write_lock "$WORK/body" "$WORK/requirements" "$WORK/lock"
LOCK_SELF=$(sed -n '$s/^# digest: //p' "$WORK/lock")
REQUIREMENTS_DIGEST=$(sha256_file "$WORK/requirements")
FILE_BYTES=$((FILE_A_SIZE + FILE_A_SIZE + FILE_B_SIZE))
{
    printf 'prefetch-plan\t%s\t%s\t%s\n' \
        "$LOCK_SELF" "$TOOL_DIGEST" "$REQUIREMENTS_DIGEST"
    printf 'metadata\t%s\t%s\t%s\t%s\tvisited\n' \
        "$ID_A" "$V_A_OLD" "$META_A_OLD_SIZE" "$META_A_OLD"
    printf 'metadata\t%s\t%s\t%s\t%s\tselected\n' \
        "$ID_A" "$V_A" "$META_A_SIZE" "$META_A"
    printf 'metadata\t%s\t%s\t%s\t%s\tselected\n' \
        "$ID_B" "$V_B" "$META_B_SIZE" "$META_B"
    printf 'file\t%s\t%s\tdata/a.bin\tdata\t%s\t%s\n' \
        "$ID_A" "$V_A" "$FILE_A_SIZE" "$FILE_A_DIGEST"
    printf 'file\t%s\t%s\tsrc/postinstall.kofun\tsource\t%s\t%s\n' \
        "$ID_A" "$V_A" "$FILE_A_SIZE" "$FILE_A_DIGEST"
    printf 'file\t%s\t%s\tdata/b.bin\tdata\t%s\t%s\n' \
        "$ID_B" "$V_B" "$FILE_B_SIZE" "$FILE_B_DIGEST"
    printf 'summary\t1\t1\t3\t2\t5\t3\t3\t%s\n' "$FILE_BYTES"
} >"$WORK/expected.plan"

rm -f "$WORK/network.called" "$WORK/iconv.called"
run_plan "$WORK/requirements" "$WORK/lock" "$STORE" >"$WORK/absent.plan"
cmp "$WORK/expected.plan" "$WORK/absent.plan" ||
    fail 'metadata-only store did not produce the exact complete candidate plan'
test ! -e "$(entry_for "$STORE" "$FILE_A_DIGEST")" &&
    test ! -e "$(entry_for "$STORE" "$FILE_B_DIGEST")" ||
    fail 'metadata-only fixture unexpectedly contained a selected file object'
test ! -e "$WORK/network.called" && test ! -e "$WORK/iconv.called" &&
    test ! -e "$WORK/ambient-store" ||
    fail 'successful planning used network, iconv, or an ambient store'

mkdir "$WORK/hostile explicit paths"
cp "$WORK/requirements" "$WORK/hostile explicit paths/-requirements [v2]"
cp "$WORK/lock" "$WORK/hostile explicit paths/-lock [v2]"
cp -R "$STORE" "$WORK/hostile explicit paths/store with spaces"
run_plan "$WORK/hostile explicit paths/-requirements [v2]" \
    "$WORK/hostile explicit paths/-lock [v2]" \
    "$WORK/hostile explicit paths/store with spaces" >"$WORK/hostile.plan"
cmp "$WORK/expected.plan" "$WORK/hostile.plan" ||
    fail 'hostile explicit paths changed the complete candidate plan'

# Existing actions retain their file-snapshot semantics.
if /bin/sh "$LOCK_TOOL" graph-plan "$WORK/lock" --store "$STORE" \
    --requirements-digest "$REQUIREMENTS_DIGEST" \
    >"$WORK/legacy.out" 2>"$WORK/legacy.err"
then
    fail 'legacy graph-plan stopped requiring selected file CAS objects'
fi
grep -Fq 'file object is missing or corrupt' "$WORK/legacy.err" ||
    fail 'legacy graph-plan refusal lost its selected-file diagnostic'

# Warm, corrupt, writable, symlink, and FIFO selected-file states cannot alter
# a descriptor-only prefetch candidate plan.
STORE_WARM=$WORK/store-warm-files
cp -R "$STORE" "$STORE_WARM"
test "$(add_object "$STORE_WARM" "$WORK/objects/a.bytes")" = "$FILE_A_DIGEST" ||
    fail 'warm A file digest fixture drifted'
test "$(add_object "$STORE_WARM" "$WORK/objects/b.bytes")" = "$FILE_B_DIGEST" ||
    fail 'warm B file digest fixture drifted'
warm_a=$(entry_for "$STORE_WARM" "$FILE_A_DIGEST")
warm_b=$(entry_for "$STORE_WARM" "$FILE_B_DIGEST")
chmod 666 "$warm_a"
chmod 644 "$warm_b"
printf X | dd of="$warm_b" bs=1 count=1 conv=notrunc status=none
run_plan "$WORK/requirements" "$WORK/lock" "$STORE_WARM" >"$WORK/warm.plan"
cmp "$WORK/expected.plan" "$WORK/warm.plan" ||
    fail 'warm/corrupt/writable selected-file state changed the plan'

STORE_SPECIAL=$WORK/store-special-files
cp -R "$STORE" "$STORE_SPECIAL"
special_a=$(entry_for "$STORE_SPECIAL" "$FILE_A_DIGEST")
special_b=$(entry_for "$STORE_SPECIAL" "$FILE_B_DIGEST")
mkdir -p "$(dirname -- "$special_a")" "$(dirname -- "$special_b")"
ln -s "$WORK/does-not-exist" "$special_a"
mkfifo "$special_b"
run_plan "$WORK/requirements" "$WORK/lock" "$STORE_SPECIAL" \
    >"$WORK/special.plan"
cmp "$WORK/expected.plan" "$WORK/special.plan" ||
    fail 'symlink/FIFO selected-file state changed the plan'

# Required metadata remains a verified input: absence, corruption, and a
# selected descriptor mismatch all refuse without a partial machine row.
STORE_MISSING=$WORK/store-missing-metadata
cp -R "$STORE" "$STORE_MISSING"
missing_meta=$(entry_for "$STORE_MISSING" "$META_A_OLD")
rm -f "$missing_meta"
expect_refusal 'missing retained metadata' 'metadata object is missing or corrupt' \
    "$WORK/requirements" "$WORK/lock" "$STORE_MISSING"

STORE_CORRUPT=$WORK/store-corrupt-metadata
cp -R "$STORE" "$STORE_CORRUPT"
corrupt_meta=$(entry_for "$STORE_CORRUPT" "$META_A")
chmod 644 "$corrupt_meta"
printf X | dd of="$corrupt_meta" bs=1 count=1 conv=notrunc status=none
chmod 444 "$corrupt_meta"
expect_refusal 'corrupt retained metadata' 'metadata object is missing or corrupt' \
    "$WORK/requirements" "$WORK/lock" "$STORE_CORRUPT"

cp "$WORK/objects/meta-a" "$WORK/objects/meta-a-mismatch"
sed "s/$FILE_A_DIGEST/$D0/" "$WORK/objects/meta-a-mismatch" \
    >"$WORK/objects/meta-a-mismatch.next"
mv "$WORK/objects/meta-a-mismatch.next" "$WORK/objects/meta-a-mismatch"
META_A_MISMATCH=$(add_object "$STORE" "$WORK/objects/meta-a-mismatch")
META_A_MISMATCH_SIZE=$(wc -c <"$WORK/objects/meta-a-mismatch" | tr -d ' ')
sed "s/$META_A_SIZE\t$META_A/$META_A_MISMATCH_SIZE\t$META_A_MISMATCH/" \
    "$WORK/body" >"$WORK/mismatch.body"
write_lock "$WORK/mismatch.body" "$WORK/requirements" "$WORK/mismatch.lock"
expect_refusal 'selected descriptor mismatch' \
    'selected metadata file descriptors do not exactly match lock file rows' \
    "$WORK/requirements" "$WORK/mismatch.lock" "$STORE"

sed 's/1\.2\.0/1.2.1/' "$WORK/requirements" >"$WORK/changed.requirements"
expect_refusal 'requirements digest mismatch' \
    'lock requirements digest does not match the supplied requirements bytes' \
    "$WORK/changed.requirements" "$WORK/lock" "$STORE"
write_lock "$WORK/body" "$WORK/requirements" "$WORK/wrong-tool.lock" "$D0"
expect_refusal 'tool identity mismatch' \
    'lock tool digest does not match the current local tool closure' \
    "$WORK/requirements" "$WORK/wrong-tool.lock" "$STORE"

# A newly reachable exact pair must be present even though all current
# metadata bytes and their selected descriptor relation remain valid.
ID_C=https://c.example/pkg/
{
    sed -n '1,2p' "$WORK/requirements"
    printf 'root\t%s\t1.0.0\n' "$ID_C"
    sed -n '3,$p' "$WORK/requirements"
} >"$WORK/missing-pair.requirements"
write_lock "$WORK/body" "$WORK/missing-pair.requirements" \
    "$WORK/missing-pair.lock"
expect_refusal 'missing reachable metadata pair' \
    "reachable metadata is missing from lock: $ID_C@1.0.0" \
    "$WORK/missing-pair.requirements" "$WORK/missing-pair.lock" "$STORE"

# Private-root spies prove exact direct-child argv and metadata-only CAS
# snapshots. A fake tool identity keeps the copied lock adapter bound to the
# exact production digest without granting it any Git or network path.
SPY_ROOT=$WORK/spy-root
mkdir -p "$SPY_ROOT/scripts"
for copied in lock-v2-structure.sh lock-v2-validate.awk \
    metadata-v1-validate.awk protocol-v1-validate.awk \
    rough-graph-v2-validate.awk selected-files-v2-plan.sh
do
    cp "$ROOT/scripts/$copied" "$SPY_ROOT/scripts/$copied"
done
cp "$ROOT/scripts/lock-v2.sh" "$SPY_ROOT/scripts/lock-v2-real.sh"
{
    printf '#!/bin/sh\nset -eu\nprintf "requirements\\n" >>"%s"\n' \
        "$SPY_ROOT/scripts/events"
    printf 'printf "%%s\\n" "$@" >"%s"\n' \
        "$SPY_ROOT/scripts/requirements.args"
    printf 'exec /bin/sh "%s" "$@"\n' "$ROOT/scripts/requirements-v2-plan.sh"
} >"$SPY_ROOT/scripts/requirements-v2-plan.sh"
{
    printf '#!/bin/sh\nset -eu\nprintf "lock\\n" >>"%s"\n' \
        "$SPY_ROOT/scripts/events"
    printf 'printf "%%s\\n" "$@" >"%s"\n' "$SPY_ROOT/scripts/lock.args"
    printf 'exec /bin/sh "%s" "$@"\n' "$SPY_ROOT/scripts/lock-v2-real.sh"
} >"$SPY_ROOT/scripts/lock-v2.sh"
{
    printf '#!/bin/sh\nset -eu\nprintf "tool\\n" >>"%s"\n' \
        "$SPY_ROOT/scripts/events"
    printf 'test "$#" -eq 1 && test "$1" = digest\n'
    printf 'printf "%%s\\n" "%s"\n' "$TOOL_DIGEST"
} >"$SPY_ROOT/scripts/lock-tool-v2.sh"
{
    printf '#!/bin/sh\nset -eu\n'
    printf 'count=0\ntest ! -f "%s" || read -r count <"%s"\n' \
        "$SPY_ROOT/scripts/store.count" "$SPY_ROOT/scripts/store.count"
    printf 'count=$((count + 1))\nprintf "%%s\\n" "$count" >"%s"\n' \
        "$SPY_ROOT/scripts/store.count"
    printf 'printf "store\\n" >>"%s"\n' "$SPY_ROOT/scripts/events"
    printf 'printf "%%s\\n" "$@" >"%s/store.$count.args"\n' \
        "$SPY_ROOT/scripts"
    printf 'exec /bin/sh "%s" "$@"\n' "$ROOT/scripts/store.sh"
} >"$SPY_ROOT/scripts/store.sh"
chmod +x "$SPY_ROOT/scripts/"*.sh
REAL_TOOL=$TOOL
TOOL=$SPY_ROOT/scripts/selected-files-v2-plan.sh
run_plan "$WORK/requirements" "$WORK/lock" "$STORE" >"$WORK/spy.plan"
cmp "$WORK/expected.plan" "$WORK/spy.plan" ||
    fail 'spied candidate plan changed bytes'
{
    printf '%s\n' requirements lock tool store store store
} >"$WORK/expected.events"
cmp "$WORK/expected.events" "$SPY_ROOT/scripts/events" ||
    fail 'child order was not requirements, lock/tool, then retained metadata only'
{
    printf '%s\n' inspect "$WORK/requirements"
} >"$WORK/expected.requirements.args"
cmp "$WORK/expected.requirements.args" "$SPY_ROOT/scripts/requirements.args" ||
    fail 'requirements child argv was incomplete, reordered, or extended'
{
    printf '%s\n' graph-prefetch-plan "$WORK/lock" --store "$STORE" \
        --requirements-digest "$REQUIREMENTS_DIGEST"
} >"$WORK/expected.lock.args"
cmp "$WORK/expected.lock.args" "$SPY_ROOT/scripts/lock.args" ||
    fail 'lock child argv was incomplete, reordered, or extended'
test "$(cat "$SPY_ROOT/scripts/store.count")" -eq 3 ||
    fail 'prefetch lock path did not snapshot exactly the three metadata objects'
n=1
for descriptor in "$META_A_OLD_SIZE:$META_A_OLD" \
    "$META_A_SIZE:$META_A" "$META_B_SIZE:$META_B"
do
    descriptor_size=${descriptor%%:*}
    descriptor_digest=${descriptor#*:}
    store_args=$SPY_ROOT/scripts/store.$n.args
    snapshot_path=$(sed -n '6p' "$store_args")
    {
        printf '%s\n' --store "$STORE" snapshot "$descriptor_digest" \
            "$descriptor_size" "$snapshot_path"
    } >"$WORK/expected.store.args"
    cmp "$WORK/expected.store.args" "$store_args" ||
        fail "metadata store child $n argv was incomplete, reordered, or extended"
    n=$((n + 1))
done
for forbidden_digest in "$FILE_A_DIGEST" "$FILE_B_DIGEST"; do
    if grep -Fqx "$forbidden_digest" "$SPY_ROOT/scripts/store."*.args; then
        fail "selected file digest reached a store snapshot: $forbidden_digest"
    fi
done
TOOL=$REAL_TOOL

printf 'pm: supplied requirements/lock/metadata derive one complete selected-file prefetch plan: PASS\n'
printf 'pm: absent, warm, corrupt, writable, symlink, and FIFO file CAS states are planning-inert: PASS\n'
printf 'pm: exact graph/MVS and metadata-only child boundaries withhold every partial plan: PASS\n'
