#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
TOOL=$ROOT/scripts/lock-tool-v2.sh
MANIFEST=$ROOT/contracts/lock-tool-v2.files
WORK=$(mktemp -d "${TMPDIR:-/tmp}/kofun-pm-lock-tool-test.XXXXXX")
trap 'rm -rf "$WORK"' 0 1 2 15

MAX_INPUT_BYTES=8388608
MAX_TOTAL_INPUT_BYTES=67108864

fail() {
    printf 'pm: FAIL: lock-tool-v2: %s\n' "$*" >&2
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

fixture_state() {
    fixture=$1
    output=$2
    {
        find "$fixture" "$HOSTILE_HOME" "$HOSTILE_XDG" \
            -printf '%p %D %i %n %y %m %s\n' | LC_ALL=C sort
        find "$fixture" "$HOSTILE_HOME" "$HOSTILE_XDG" -type f \
            -exec sha256sum '{}' ';' | LC_ALL=C sort
    } >"$output"
}

expect_refusal() {
    label=$1
    needle=$2
    fixture=$3
    fixture_state "$fixture" "$WORK/refusal.before"
    rm -f "$WORK/network.called" "$WORK/ambient-store" \
        "$WORK/git.trace" "$WORK/git-trace2.event"
    if env -i PATH="$HOSTILE_BIN:$BASE_PATH" HOME="$HOSTILE_HOME" \
        XDG_CACHE_HOME="$HOSTILE_XDG" KPM_NETWORK_SENTINEL="$WORK/network.called" \
        KPM_REAL_GIT="$REAL_GIT" KPM_GIT_ROOT="$fixture" \
        KPM_STORE="$WORK/ambient-store" \
        GIT_DIR="$WORK/hostile.git" GIT_WORK_TREE="$WORK/hostile.worktree" \
        GIT_INDEX_FILE=/dev/null GIT_OBJECT_DIRECTORY="$WORK/hostile.objects" \
        GIT_ALTERNATE_OBJECT_DIRECTORIES="$WORK/hostile.alternates" \
        GIT_COMMON_DIR="$WORK/hostile.common" GIT_CONFIG_COUNT=1 \
        GIT_CONFIG_KEY_0=core.fileMode GIT_CONFIG_VALUE_0=false \
        GIT_NO_LAZY_FETCH=0 GIT_NO_REPLACE_OBJECTS=0 GIT_OPTIONAL_LOCKS=1 \
        GIT_TRACE="$WORK/git.trace" GIT_TRACE2_EVENT="$WORK/git-trace2.event" \
        http_proxy=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 \
        ALL_PROXY=socks5://127.0.0.1:9 \
        "$fixture/scripts/lock-tool-v2.sh" digest \
        >"$WORK/refusal.out" 2>&1
    then
        fail "$label was accepted"
    fi
    grep -Fq -- "$needle" "$WORK/refusal.out" ||
        fail "$label did not say '$needle': $(sed -n '1,8p' "$WORK/refusal.out" | tr '\n' ' ')"
    if grep -Eq '^[0-9a-f]{64}$' "$WORK/refusal.out"; then
        fail "$label emitted a partial tool identity"
    fi
    test ! -e "$WORK/network.called" && test ! -e "$WORK/ambient-store" &&
        test ! -e "$WORK/git.trace" && test ! -e "$WORK/git-trace2.event" ||
        fail "$label used network, ambient store, or ambient Git tracing"
    fixture_state "$fixture" "$WORK/refusal.after"
    cmp "$WORK/refusal.before" "$WORK/refusal.after" ||
        fail "$label mutated fixture repository or ambient HOME/XDG state"
}

init_fixture() {
    fixture=$1
    mkdir -p "$fixture/contracts" "$fixture/scripts" "$fixture/vendor/kofun"
    cp "$TOOL" "$fixture/scripts/lock-tool-v2.sh"
    chmod +x "$fixture/scripts/lock-tool-v2.sh"
    {
        printf 'contracts/lock-tool-v2.files\n'
        printf 'scripts/lock-tool-v2.sh\n'
    } >"$fixture/contracts/lock-tool-v2.files"

    git -C "$fixture/vendor/kofun" init -q
    printf 'vendor base\n' >"$fixture/vendor/kofun/source"
    git -C "$fixture/vendor/kofun" add source
    git -C "$fixture/vendor/kofun" -c user.name=test \
        -c user.email=test@example.invalid commit -qm base
    fixture_gitlink=$(git -C "$fixture/vendor/kofun" rev-parse HEAD)
    git -C "$fixture" init -q
    git -C "$fixture" update-index --add --cacheinfo \
        160000 "$fixture_gitlink" vendor/kofun
}

write_expected_manifest() {
    {
        printf 'contracts/kpm-cli.kofun\n'
        printf 'contracts/lock-tool-v2.files\n'
        printf 'scripts/authority-v1-validate.awk\n'
        printf 'scripts/build-seed.sh\n'
        printf 'scripts/catalog-v1-plan.sh\n'
        printf 'scripts/catalog-v1-validate.awk\n'
        printf 'scripts/catalog-v1.sh\n'
        printf 'scripts/lock-tool-v2.sh\n'
        printf 'scripts/lock-v2-structure.sh\n'
        printf 'scripts/lock-v2-validate.awk\n'
        printf 'scripts/lock-v2.sh\n'
        printf 'scripts/lock.sh\n'
        printf 'scripts/metadata-request-v1-validate.awk\n'
        printf 'scripts/metadata-v1-validate.awk\n'
        printf 'scripts/metadata-v1.sh\n'
        printf 'scripts/protocol-v1-validate.awk\n'
        printf 'scripts/requirements-v2-plan.sh\n'
        printf 'scripts/requirements-v2-validate.awk\n'
        printf 'scripts/rough-graph-v2-validate.awk\n'
        printf 'scripts/rough-graph-v2.sh\n'
        printf 'scripts/store.sh\n'
        printf 'seed/resolver/core.kofun\n'
        printf 'seed/resolver/shell.kofun\n'
    } >"$WORK/expected.manifest"
}

test -x "$TOOL" && test -f "$MANIFEST" ||
    fail 'tool identity adapter or closure manifest is missing'
write_expected_manifest
cmp -s "$WORK/expected.manifest" "$MANIFEST" ||
    fail 'the production closure manifest does not name the exact reviewed implementation set'
LC_ALL=C sort -cu "$MANIFEST" ||
    fail 'the production closure manifest is not in strict identity-byte order'

tool_digest=$("$TOOL" digest) || fail 'the production tool identity did not compute'
case $tool_digest in
    *[!0-9a-f]* | '') fail 'the production tool identity is not lowercase hexadecimal' ;;
esac
test "${#tool_digest}" -eq 64 ||
    fail 'the production tool identity is not one sha256 digest'
test "$("$TOOL" digest)" = "$tool_digest" ||
    fail 'the same local tool closure produced two identities'

# The adapter opens the manifest once, and every other named input once, into
# bounded private snapshots. Audit every production pathname rather than only
# one representative fixture.
real_head=$(command -v head)
mkdir -p "$WORK/head-audit"
{
    printf '#!/bin/sh\nset -eu\n'
    printf 'input=$(readlink "/proc/$$/fd/0" 2>/dev/null || :)\n'
    printf 'case "$input" in /*) printf "%%s\\n" "$input" >>"$KPM_HEAD_LOG" ;; esac\n'
    printf 'exec "%s" "$@"\n' "$real_head"
} >"$WORK/head-audit/head"
chmod +x "$WORK/head-audit/head"
PATH="$WORK/head-audit:$PATH" KPM_HEAD_LOG="$WORK/head-audit.log" \
    "$TOOL" digest >"$WORK/head-audit.out"
{
    printf '%s\n' "$MANIFEST"
    while IFS= read -r relative; do
        test "$relative" = contracts/lock-tool-v2.files ||
            printf '%s/%s\n' "$ROOT" "$relative"
    done <"$MANIFEST"
} >"$WORK/head-audit.expected"
cmp "$WORK/head-audit.expected" "$WORK/head-audit.log" ||
    fail 'the production manifest or a named input was not snapshotted exactly once'
test "$(sed -n '1p' "$WORK/head-audit.out")" = "$tool_digest" ||
    fail 'snapshot auditing changed the tool identity'

# Reconstruct the specified framing independently. This pins the domain, row
# order, exact sizes/digests, and final gitlink rather than trusting the adapter
# to test itself with its own output.
printf 'kofun-pm.lock-tool/v2\n' >"$WORK/expected.framing"
while IFS= read -r relative; do
    bytes=$(wc -c <"$ROOT/$relative" | tr -d ' ')
    digest=$(sha256 <"$ROOT/$relative")
    printf 'file\t%s\t%s\t%s\n' "$relative" "$bytes" "$digest" \
        >>"$WORK/expected.framing"
done <"$MANIFEST"
gitlink=$(git -C "$ROOT" ls-files --stage -- vendor/kofun |
    awk '$1 == 160000 && $3 == 0 && $4 == "vendor/kofun" { print $2 }')
test -n "$gitlink" || fail 'the production gitlink could not be reconstructed'
printf 'gitlink\tvendor/kofun\t%s\n' "$gitlink" >>"$WORK/expected.framing"
test "$(sha256 <"$WORK/expected.framing")" = "$tool_digest" ||
    fail 'tool identity did not match the independently reconstructed canonical framing'

# Manifest grammar and structural exact/+1 limits precede named inputs.
fixture=$WORK/order
init_fixture "$fixture"
{
    printf 'scripts/lock-tool-v2.sh\n'
    printf 'contracts/lock-tool-v2.files\n'
} >"$fixture/contracts/lock-tool-v2.files"
expect_refusal 'manifest order' 'paths are not unique and in strict identity-byte order' "$fixture"

fixture=$WORK/duplicate
init_fixture "$fixture"
printf 'scripts/lock-tool-v2.sh\n' >>"$fixture/contracts/lock-tool-v2.files"
expect_refusal 'manifest duplicate' 'paths are not unique and in strict identity-byte order' "$fixture"

fixture=$WORK/missing-self
init_fixture "$fixture"
printf 'scripts/lock-tool-v2.sh\n' >"$fixture/contracts/lock-tool-v2.files"
expect_refusal 'manifest self omission' 'must name itself exactly once' "$fixture"

fixture=$WORK/missing-tool
init_fixture "$fixture"
printf 'payload\n' >"$fixture/payload"
{
    printf 'contracts/lock-tool-v2.files\n'
    printf 'payload\n'
} >"$fixture/contracts/lock-tool-v2.files"
expect_refusal 'tool adapter omission' \
    'must name the tool adapter exactly once' "$fixture"

fixture=$WORK/blank
init_fixture "$fixture"
printf '\n' >>"$fixture/contracts/lock-tool-v2.files"
expect_refusal 'manifest blank row' 'contains a blank row' "$fixture"

fixture=$WORK/noncanonical-path
init_fixture "$fixture"
{
    printf 'contracts/lock-tool-v2.files\n'
    printf 'payload/\n'
    printf 'scripts/lock-tool-v2.sh\n'
} >"$fixture/contracts/lock-tool-v2.files"
expect_refusal 'manifest noncanonical path' \
    'path is not canonical repository-relative form: payload/' "$fixture"

fixture=$WORK/manifest-intermediate-symlink
init_fixture "$fixture"
mv "$fixture/contracts" "$WORK/manifest-contracts"
ln -s "$WORK/manifest-contracts" "$fixture/contracts"
expect_refusal 'manifest intermediate symlink' \
    'tool input path contains a symlink component: contracts/lock-tool-v2.files' \
    "$fixture"

fixture=$WORK/rows-64
init_fixture "$fixture"
mkdir -p "$fixture/inputs"
{
    printf 'contracts/lock-tool-v2.files\n'
    row=0
    while test "$row" -lt 62; do
        printf 'inputs/%02d\n' "$row"
        : >"$fixture/inputs/$(printf '%02d' "$row")"
        row=$((row + 1))
    done
    printf 'scripts/lock-tool-v2.sh\n'
} >"$fixture/contracts/lock-tool-v2.files"
"$fixture/scripts/lock-tool-v2.sh" digest >"$WORK/rows-64.out" ||
    fail 'an exact 64-row closure manifest was refused'
printf 'z-extra\n' >>"$fixture/contracts/lock-tool-v2.files"
expect_refusal 'manifest row bound +1' 'exceeds the 64-row bound: 65' "$fixture"

fixture=$WORK/line-bound
init_fixture "$fixture"
long_path=$(awk 'BEGIN {
    printf "inputs/"
    for (i = 0; i < 250; i++) printf "a"
    printf "/"
    for (i = 0; i < 250; i++) printf "b"
    printf "/ccc"
}')
test "${#long_path}" -eq 512 || fail 'the exact manifest line fixture is not 512 bytes'
{
    printf 'contracts/lock-tool-v2.files\n'
    printf '%s\n' "$long_path"
    printf 'scripts/lock-tool-v2.sh\n'
} >"$fixture/contracts/lock-tool-v2.files"
expect_refusal 'exact manifest line bound reaches named input' \
    'tool input is not a regular non-symlink file' "$fixture"
long_path=${long_path}d
{
    printf 'contracts/lock-tool-v2.files\n'
    printf '%s\n' "$long_path"
    printf 'scripts/lock-tool-v2.sh\n'
} >"$fixture/contracts/lock-tool-v2.files"
expect_refusal 'manifest line bound +1' 'line exceeds the 512-byte bound: 513' "$fixture"

fixture=$WORK/no-lf
init_fixture "$fixture"
printf 'contracts/lock-tool-v2.files\nscripts/lock-tool-v2.sh' \
    >"$fixture/contracts/lock-tool-v2.files"
expect_refusal 'manifest final LF' 'must end in exactly one LF' "$fixture"

fixture=$WORK/symlink
init_fixture "$fixture"
ln -s scripts/lock-tool-v2.sh "$fixture/payload"
{
    printf 'contracts/lock-tool-v2.files\n'
    printf 'payload\n'
    printf 'scripts/lock-tool-v2.sh\n'
} >"$fixture/contracts/lock-tool-v2.files"
expect_refusal 'symlink tool input' \
    'tool input path contains a symlink component: payload' "$fixture"

fixture=$WORK/intermediate-symlink
init_fixture "$fixture"
mkdir -p "$WORK/outside-inputs"
printf 'outside\n' >"$WORK/outside-inputs/payload"
ln -s "$WORK/outside-inputs" "$fixture/inputs"
{
    printf 'contracts/lock-tool-v2.files\n'
    printf 'inputs/payload\n'
    printf 'scripts/lock-tool-v2.sh\n'
} >"$fixture/contracts/lock-tool-v2.files"
expect_refusal 'intermediate symlink tool input' \
    'tool input path contains a symlink component: inputs/payload' "$fixture"

# Each input and the complete input closure have independent exact byte bounds.
fixture=$WORK/input-bound
init_fixture "$fixture"
head -c "$MAX_INPUT_BYTES" </dev/zero >"$fixture/payload"
{
    printf 'contracts/lock-tool-v2.files\n'
    printf 'payload\n'
    printf 'scripts/lock-tool-v2.sh\n'
} >"$fixture/contracts/lock-tool-v2.files"
"$fixture/scripts/lock-tool-v2.sh" digest >"$WORK/input-exact.out" ||
    fail 'an exact 8 MiB tool input was refused'
printf x >>"$fixture/payload"
expect_refusal 'tool input byte bound +1' \
    'tool input exceeds the 8388608-byte bound' "$fixture"

fixture=$WORK/aggregate-bound
init_fixture "$fixture"
mkdir -p "$fixture/inputs"
{
    printf 'contracts/lock-tool-v2.files\n'
    input=0
    while test "$input" -lt 8; do
        printf 'inputs/%02d\n' "$input"
        input=$((input + 1))
    done
    printf 'scripts/lock-tool-v2.sh\n'
} >"$fixture/contracts/lock-tool-v2.files"
small_bytes=$((
    $(wc -c <"$fixture/contracts/lock-tool-v2.files" | tr -d ' ') +
    $(wc -c <"$fixture/scripts/lock-tool-v2.sh" | tr -d ' ')
))
input=0
while test "$input" -lt 7; do
    head -c "$MAX_INPUT_BYTES" </dev/zero \
        >"$fixture/inputs/$(printf '%02d' "$input")"
    input=$((input + 1))
done
last_bytes=$((MAX_TOTAL_INPUT_BYTES - (7 * MAX_INPUT_BYTES) - small_bytes))
test "$last_bytes" -gt 0 && test "$last_bytes" -le "$MAX_INPUT_BYTES" ||
    fail 'the aggregate exact-bound fixture could not be constructed'
head -c "$last_bytes" </dev/zero >"$fixture/inputs/07"
"$fixture/scripts/lock-tool-v2.sh" digest >"$WORK/aggregate-exact.out" ||
    fail 'the exact 64 MiB aggregate tool closure was refused'
printf x >>"$fixture/inputs/07"
expect_refusal 'tool aggregate byte bound +1' \
    'tool inputs exceed the 67108864-byte aggregate bound' "$fixture"

# The canonical identity moves with included bytes and the recorded gitlink,
# refuses a dirty or mismatched checkout, and ignores unrelated repository data.
fixture=$WORK/identity
init_fixture "$fixture"
printf 'included\n' >"$fixture/payload"
{
    printf 'contracts/lock-tool-v2.files\n'
    printf 'payload\n'
    printf 'scripts/lock-tool-v2.sh\n'
} >"$fixture/contracts/lock-tool-v2.files"
identity_before=$("$fixture/scripts/lock-tool-v2.sh" digest)
printf 'unrelated\n' >"$fixture/unrelated"
test "$("$fixture/scripts/lock-tool-v2.sh" digest)" = "$identity_before" ||
    fail 'an unrelated repository file moved the tool identity'
printf 'included changed\n' >"$fixture/payload"
identity_included=$("$fixture/scripts/lock-tool-v2.sh" digest)
test "$identity_included" != "$identity_before" ||
    fail 'an included file mutation left the tool identity unchanged'

printf 'vendor next\n' >"$fixture/vendor/kofun/source"
expect_refusal 'tracked vendor change' \
    'vendor/kofun has tracked changes' "$fixture"
git -C "$fixture/vendor/kofun" add source
expect_refusal 'staged vendor change' \
    'vendor/kofun has tracked changes' "$fixture"
git -C "$fixture/vendor/kofun" -c user.name=test \
    -c user.email=test@example.invalid commit -qm next
expect_refusal 'vendor HEAD mismatch' \
    'checkout does not match the recorded gitlink' "$fixture"
next_gitlink=$(git -C "$fixture/vendor/kofun" rev-parse HEAD)
git -C "$fixture" update-index --cacheinfo \
    160000 "$next_gitlink" vendor/kofun
identity_gitlink=$("$fixture/scripts/lock-tool-v2.sh" digest)
test "$identity_gitlink" != "$identity_included" ||
    fail 'a recorded clean gitlink mutation left the tool identity unchanged'
chmod +x "$fixture/vendor/kofun/source"
expect_refusal 'mode-only vendor change' \
    'vendor/kofun has tracked changes' "$fixture"
chmod 644 "$fixture/vendor/kofun/source"
git -C "$fixture/vendor/kofun" update-index --assume-unchanged source
chmod +x "$fixture/vendor/kofun/source"
expect_refusal 'assume-unchanged vendor index flag' \
    'index carries assume-unchanged, skip-worktree, or non-canonical tracked flags' \
    "$fixture"
git -C "$fixture/vendor/kofun" update-index --no-assume-unchanged source
chmod 644 "$fixture/vendor/kofun/source"
git -C "$fixture/vendor/kofun" update-index --skip-worktree source
chmod +x "$fixture/vendor/kofun/source"
expect_refusal 'skip-worktree vendor index flag' \
    'index carries assume-unchanged, skip-worktree, or non-canonical tracked flags' \
    "$fixture"
git -C "$fixture/vendor/kofun" update-index --no-skip-worktree source
chmod 644 "$fixture/vendor/kofun/source"

# Repository-local attributes and clean filters are untrusted. The clean-tree
# proof uses plumbing status comparisons that never expand file content through
# a configured filter.
printf '* filter=spy\n' >"$fixture/hostile.attributes"
git -C "$fixture/vendor/kofun" config core.attributesFile \
    "$fixture/hostile.attributes"
git -C "$fixture/vendor/kofun" config filter.spy.clean \
    "touch '$WORK/filter.called'; cat"
printf 'filter attack\n' >"$fixture/vendor/kofun/source"
rm -f "$WORK/filter.called"
expect_refusal 'hostile local Git clean filter' \
    'vendor/kofun has tracked changes' "$fixture"
test ! -e "$WORK/filter.called" ||
    fail 'the local tool identity executed a repository-configured clean filter'

fixture=$WORK/replace-ref
init_fixture "$fixture"
original_gitlink=$(git -C "$fixture/vendor/kofun" rev-parse HEAD)
printf 'replacement tree\n' >"$fixture/vendor/kofun/source"
git -C "$fixture/vendor/kofun" add source
git -C "$fixture/vendor/kofun" -c user.name=test \
    -c user.email=test@example.invalid commit -qm replacement
replacement_commit=$(git -C "$fixture/vendor/kofun" rev-parse HEAD)
git -C "$fixture/vendor/kofun" replace \
    "$original_gitlink" "$replacement_commit"
git -C "$fixture/vendor/kofun" reset -q --hard "$original_gitlink"
test "$(git -C "$fixture/vendor/kofun" rev-parse HEAD)" = "$original_gitlink" ||
    fail 'the replace-ref fixture lost its original HEAD object id'
expect_refusal 'repository replace-ref tree spoof' \
    'vendor/kofun has tracked changes' "$fixture"

# A promisor checkout can otherwise turn an apparently read-only object lookup
# into an implicit fetch and object-database mutation. Remove the current
# commit object only after a no-hardlink bare copy can supply it, then require a
# refusal without restoring the object or changing any other fixture state.
fixture=$WORK/promisor-object
init_fixture "$fixture"
printf 'lazy-fetch proof\n' >"$fixture/vendor/kofun/lazy-proof"
git -C "$fixture/vendor/kofun" add lazy-proof
git -C "$fixture/vendor/kofun" -c user.name=test \
    -c user.email=test@example.invalid commit -qm lazy-fetch-proof
lazy_oid=$(git -C "$fixture/vendor/kofun" rev-parse HEAD)
git -C "$fixture" update-index --cacheinfo \
    160000 "$lazy_oid" vendor/kofun
git clone -q --bare --no-hardlinks "$fixture/vendor/kofun" \
    "$fixture/promisor.git"
git -C "$fixture/vendor/kofun" config remote.origin.url \
    "$fixture/promisor.git"
git -C "$fixture/vendor/kofun" config remote.origin.promisor true
git -C "$fixture/vendor/kofun" config \
    remote.origin.partialclonefilter blob:none
git -C "$fixture/vendor/kofun" config extensions.partialClone origin
lazy_object_dir=$(git -C "$fixture/vendor/kofun" rev-parse \
    --absolute-git-dir)/objects
lazy_object=$lazy_object_dir/${lazy_oid%${lazy_oid#??}}/${lazy_oid#??}
test -f "$lazy_object" ||
    fail 'the promisor fixture did not create a loose HEAD commit object'
mv "$lazy_object" "$WORK/lazy-commit.saved"
expect_refusal 'promisor checkout missing HEAD object' \
    'vendor/kofun has tracked changes' "$fixture"
test ! -e "$lazy_object" ||
    fail 'the local tool identity lazily fetched a missing promisor object'

# Each manifest and named-input pathname is opened once into a private bounded
# snapshot. A same-path replacement after head returns cannot affect framing.
fixture=$WORK/read-once
init_fixture "$fixture"
printf 'first bytes\n' >"$fixture/payload"
printf 'other bytes\n' >"$fixture/replacement"
{
    printf 'contracts/lock-tool-v2.files\n'
    printf 'payload\n'
    printf 'scripts/lock-tool-v2.sh\n'
} >"$fixture/contracts/lock-tool-v2.files"
read_once_expected=$("$fixture/scripts/lock-tool-v2.sh" digest)
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
cp "$fixture/payload" "$WORK/payload.saved"
PATH="$WORK/head-spy:$PATH" KPM_SWAP_TARGET="$fixture/payload" \
KPM_SWAP_BYTES="$fixture/replacement" KPM_SWAP_COUNT="$WORK/payload.count" \
    "$fixture/scripts/lock-tool-v2.sh" digest >"$WORK/payload-swap.out"
test "$(sed -n '1p' "$WORK/payload.count")" = 1 ||
    fail 'a named tool input pathname was not read exactly once'
test "$(sed -n '1p' "$WORK/payload-swap.out")" = "$read_once_expected" ||
    fail 'a post-snapshot tool input swap changed the computed identity'
cp "$WORK/payload.saved" "$fixture/payload"

cp "$fixture/contracts/lock-tool-v2.files" "$WORK/manifest.saved"
printf 'wrong\n' >"$WORK/manifest-replacement"
PATH="$WORK/head-spy:$PATH" \
KPM_SWAP_TARGET="$fixture/contracts/lock-tool-v2.files" \
KPM_SWAP_BYTES="$WORK/manifest-replacement" \
KPM_SWAP_COUNT="$WORK/manifest.count" \
    "$fixture/scripts/lock-tool-v2.sh" digest >"$WORK/manifest-swap.out"
test "$(sed -n '1p' "$WORK/manifest.count")" = 1 ||
    fail 'the closure manifest pathname was not read exactly once'
test "$(sed -n '1p' "$WORK/manifest-swap.out")" = "$read_once_expected" ||
    fail 'a post-snapshot closure manifest swap changed the computed identity'
cp "$WORK/manifest.saved" "$fixture/contracts/lock-tool-v2.files"

# The production closure remains offline and read-only under hostile ambient
# configuration. Git is restricted to the five exact local read operations.
state() {
    for path do
        stat -c '%n %d %i %h %F %a %s' "$path"
        test ! -f "$path" || sha256 <"$path"
    done
}
root_index=$(git -C "$ROOT" rev-parse --git-path index)
case $root_index in /*) ;; *) root_index=$ROOT/$root_index ;; esac
vendor_index=$(git -C "$ROOT/vendor/kofun" rev-parse --git-path index)
case $vendor_index in
    /*) ;;
    *) vendor_index=$ROOT/vendor/kofun/$vendor_index ;;
esac
{
    while IFS= read -r relative; do state "$ROOT/$relative"; done <"$MANIFEST"
    state "$root_index" "$vendor_index"
    GIT_OPTIONAL_LOCKS=0 git -C "$ROOT" status --porcelain=v1 --untracked-files=all
} >"$WORK/repository.before"
state "$HOSTILE_HOME/marker" "$HOSTILE_XDG/marker" \
    >"$WORK/ambient.before"
env -i PATH="$HOSTILE_BIN:$BASE_PATH" HOME="$HOSTILE_HOME" \
XDG_CACHE_HOME="$HOSTILE_XDG" KPM_NETWORK_SENTINEL="$WORK/network.called" \
KPM_REAL_GIT="$REAL_GIT" KPM_GIT_ROOT="$ROOT" \
GIT_DIR="$WORK/hostile.git" GIT_WORK_TREE="$WORK/hostile.worktree" \
GIT_INDEX_FILE=/dev/null GIT_OBJECT_DIRECTORY="$WORK/hostile.objects" \
GIT_ALTERNATE_OBJECT_DIRECTORIES="$WORK/hostile.alternates" \
GIT_COMMON_DIR="$WORK/hostile.common" GIT_CONFIG_COUNT=1 \
GIT_CONFIG_KEY_0=core.fileMode GIT_CONFIG_VALUE_0=false \
GIT_NO_LAZY_FETCH=0 GIT_NO_REPLACE_OBJECTS=0 GIT_OPTIONAL_LOCKS=1 \
GIT_TRACE="$WORK/git.trace" GIT_TRACE2_EVENT="$WORK/git-trace2.event" \
http_proxy=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 \
ALL_PROXY=socks5://127.0.0.1:9 \
    "$TOOL" digest >"$WORK/hostile.out"
test "$(sed -n '1p' "$WORK/hostile.out")" = "$tool_digest" ||
    fail 'hostile ambient state changed the tool identity'
test ! -e "$WORK/network.called" ||
    fail 'the tool identity adapter attempted network or a forbidden Git operation'
test ! -e "$WORK/git.trace" && test ! -e "$WORK/git-trace2.event" ||
    fail 'ambient Git tracing mutated an external trace pathname'
{
    while IFS= read -r relative; do state "$ROOT/$relative"; done <"$MANIFEST"
    state "$root_index" "$vendor_index"
    GIT_OPTIONAL_LOCKS=0 git -C "$ROOT" status --porcelain=v1 --untracked-files=all
} >"$WORK/repository.after"
state "$HOSTILE_HOME/marker" "$HOSTILE_XDG/marker" \
    >"$WORK/ambient.after"
cmp "$WORK/repository.before" "$WORK/repository.after" ||
    fail 'tool identity success mutated repository bytes, topology, modes, or Git indices'
cmp "$WORK/ambient.before" "$WORK/ambient.after" ||
    fail 'tool identity success mutated ambient HOME/XDG state'

printf 'pm: lock tool v2 canonical closure, exact framing, and local gitlink: PASS\n'
printf 'pm: lock tool v2 bounds, read-once snapshots, hostile env, and read-only state: PASS\n'
