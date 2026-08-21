#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
TOOL=$ROOT/scripts/fetch-metadata-v1.sh
PLAN_TOOL=$ROOT/scripts/metadata-v1-plan.sh
STORE_TOOL=$ROOT/scripts/store.sh
SENTINEL=$ROOT/tests/pm/curl-sentinel.sh
WORK=$(mktemp -d "${TMPDIR:-/tmp}/kofun-pm-fetch-metadata-test.XXXXXX")
trap 'rm -rf "$WORK"' 0 1 2 15

fail() {
    printf 'pm: FAIL: fetch-metadata-v1: %s\n' "$*" >&2
    exit 1
}

sha256() {
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

catalog_for() {
    catalog_metadata=$1
    catalog_output=$2
    catalog_version=${3:-$VERSION}
    catalog_size=$(wc -c <"$catalog_metadata" | tr -d ' ')
    catalog_digest=$(sha256 "$catalog_metadata")
    {
        printf 'kofun-catalog/v1\n'
        printf '%s\t%s\t%s\n' "$catalog_version" "$catalog_size" "$catalog_digest"
    } >"$catalog_output"
}

transfer_count() {
    if test -f "$FIXTURE/transfer.calls"; then
        wc -l <"$FIXTURE/transfer.calls" | tr -d ' '
    else
        printf '0\n'
    fi
}

reset_fixture() {
    rm -rf "$FIXTURE"
    mkdir "$FIXTURE"
    cp "$RESPONSE_METADATA" "$FIXTURE/body"
}

assert_private_cleanup() {
    leftovers=$(find "$TMP_ROOT" -mindepth 1 | wc -l | tr -d ' ')
    test "$leftovers" -eq 0 ||
        fail "fetch left $leftovers private work path(s) under TMPDIR"
}

fetch_current() {
    env -i PATH="$FAKE_BIN:$BASE_PATH" TMPDIR="$TMP_ROOT" LC_ALL=ja_JP.UTF-8 \
        HOME="$HOSTILE_HOME" XDG_CONFIG_HOME="$HOSTILE_XDG" \
        CURL_HOME="$HOSTILE_CURL_HOME" \
        http_proxy=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9 \
        HTTP_PROXY=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 \
        ALL_PROXY=socks5://127.0.0.1:9 NO_PROXY=fixture.example \
        SSL_CERT_FILE="$WORK/ambient-ca.pem" \
        SSL_CERT_DIR="$WORK/ambient-ca-dir" \
        SSLKEYLOGFILE="$WORK/ssl-key-log" OPENSSL_CONF="$WORK/openssl.cnf" \
        KPM_SWAP_TARGET="${KPM_SWAP_TARGET:-$WORK/no-swap-target}" \
        KPM_SWAP_BYTES="${KPM_SWAP_BYTES:-$WORK/no-swap-bytes}" \
        KPM_SWAP_COUNT="${KPM_SWAP_COUNT:-$WORK/no-swap-count}" \
        KPM_METADATA_DESCRIPTOR=1 KPM_METADATA_SIZE=ambient-invalid \
        KPM_METADATA_DIGEST=ambient-invalid \
        "$TOOL" acquire "$ID" "$VERSION" --catalog "$CATALOG" \
        --authority "$AUTHORITY" --ipv4 "$IPV4" --ca-file "$CA" \
        --store "$STORE" "$@"
}

expect_refusal() {
    refusal_label=$1
    refusal_needle=$2
    refusal_transfers=$3
    shift 3
    if fetch_current "$@" >"$WORK/refusal.out" 2>"$WORK/refusal.err"; then
        fail "$refusal_label was accepted"
    fi
    grep -Fq -- "$refusal_needle" "$WORK/refusal.err" ||
        fail "$refusal_label did not say '$refusal_needle': $(sed -n '1,8p' "$WORK/refusal.err" | tr '\n' ' ')"
    test ! -s "$WORK/refusal.out" ||
        fail "$refusal_label emitted partial success: $(tr '\n' ' ' <"$WORK/refusal.out")"
    actual_transfers=$(transfer_count)
    test "$actual_transfers" -eq "$refusal_transfers" ||
        fail "$refusal_label made $actual_transfers transfer call(s), expected $refusal_transfers"
    if grep -Eq 'pinned HTTPS response verified|reused verified store object|store: (published|adopted|snapshotted)|strict metadata parsed|catalog-bound metadata admitted' \
        "$WORK/refusal.out" "$WORK/refusal.err"
    then
        fail "$refusal_label leaked a child or top-level success sentinel"
    fi
    assert_private_cleanup
}

argv_value() {
    argv_file=$1
    argv_option=$2
    LC_ALL=C awk -v wanted="$argv_option" '
        $0 == wanted {
            if (getline > 0) { print; found = 1; exit }
        }
        index($0, wanted "=") == 1 {
            print substr($0, length(wanted) + 2); found = 1; exit
        }
        END { if (!found) exit 1 }
    ' "$argv_file"
}

BASE_PATH=$PATH
FAKE_BIN=$WORK/fake-bin
FIXTURE=$FAKE_BIN/curl-fixture
TMP_ROOT=$WORK/tmp
HOSTILE_HOME=$WORK/hostile-home
HOSTILE_XDG=$WORK/hostile-xdg
HOSTILE_CURL_HOME=$WORK/hostile-curl-home
mkdir -p "$FAKE_BIN" "$TMP_ROOT" "$HOSTILE_HOME" "$HOSTILE_XDG" \
    "$HOSTILE_CURL_HOME"
cp "$SENTINEL" "$FAKE_BIN/curl"
chmod +x "$FAKE_BIN/curl"

test -x "$TOOL" || fail "missing executable $TOOL"
test -x "$PLAN_TOOL" || fail "missing executable $PLAN_TOOL"
test -x "$STORE_TOOL" || fail "missing executable $STORE_TOOL"

ID=https://fixture.example/pkg/
VERSION=1.2.0
IPV4=93.184.216.34
CA=$WORK/roots.pem
AUTHORITY=$WORK/authority
CATALOG=$WORK/catalog
STORE=$WORK/store-default
RESPONSE_METADATA=$WORK/metadata
ZERO=0000000000000000000000000000000000000000000000000000000000000000
printf 'test-only CA bytes\n' >"$CA"
printf 'kofun-fetch-authority/v1\norigin\thttps://fixture.example\n' >"$AUTHORITY"
{
    printf 'kofun-metadata/v1\n'
    printf 'identity\t%s\n' "$ID"
    printf 'version\t%s\n' "$VERSION"
    printf 'dependency\thttps://deps.example/a/\t1.0.0\n'
    printf 'file\tsrc.kofun\tsource\t3\t%s\n' "$ZERO"
} >"$RESPONSE_METADATA"
catalog_for "$RESPONSE_METADATA" "$CATALOG"
METADATA_SIZE=$(wc -c <"$RESPONSE_METADATA" | tr -d ' ')
METADATA_DIGEST=$(sha256 "$RESPONSE_METADATA")

# The public surface cannot accept caller-supplied request or descriptor
# fields. Request grammar also precedes every explicit pathname and transfer.
reset_fixture
expect_refusal 'unknown origin override' 'usage:' 0 --origin https://evil.example
reset_fixture
expect_refusal 'duplicate catalog' 'usage:' 0 --catalog "$CATALOG"
saved_id=$ID
ID=https://127.0.0.1/pkg/
reset_fixture
expect_refusal 'invalid identity before supplied paths' \
    'requested identity/version grammar is invalid' 0
ID=$saved_id
saved_version=$VERSION
VERSION=1.02.0
reset_fixture
expect_refusal 'invalid version before supplied paths' \
    'requested identity/version grammar is invalid' 0
VERSION=$saved_version

# Authority and exact catalog membership are complete before curl is reached.
printf 'kofun-fetch-authority/v1\norigin\thttps://other.example\n' \
    >"$WORK/unapproved.authority"
saved_authority=$AUTHORITY
AUTHORITY=$WORK/unapproved.authority
reset_fixture
expect_refusal 'unapproved origin' 'identity origin is not explicitly approved' 0
AUTHORITY=$saved_authority
printf 'kofun-catalog/v1\n1.10.0\t0\t%s\n' "$ZERO" >"$WORK/higher.catalog"
saved_catalog=$CATALOG
CATALOG=$WORK/higher.catalog
reset_fixture
expect_refusal 'exact version absence' \
    "required version $ID@$VERSION is not published" 0
CATALOG=$saved_catalog

# One cold request derives every transport scalar from the private catalog
# plan, then exposes success only after store revalidation and strict parsing.
reset_fixture
fetch_current >"$WORK/cold.out" 2>"$WORK/cold.err" ||
    fail "cold metadata acquisition failed: $(tr '\n' ' ' <"$WORK/cold.err")"
grep -Fq 'catalog-bound metadata admitted, reverified, and strictly parsed' \
    "$WORK/cold.out" || fail 'cold success omitted the top-level sentinel'
grep -Fq '1 dependency and 1 file descriptor row(s)' "$WORK/cold.out" ||
    fail 'cold success omitted strict row counts'
test "$(wc -l <"$WORK/cold.out" | tr -d ' ')" -eq 2 ||
    fail 'cold success leaked child stdout'
test ! -s "$WORK/cold.err" || fail 'cold success leaked child stderr'
test "$(transfer_count)" -eq 1 || fail 'cold success did not make one transfer'
curl_argv=$(find "$FIXTURE" -name 'argv.*')
test "$(argv_value "$curl_argv" --url)" = \
    "https://fixture.example/pkg/@kofun/v1/versions/$VERSION.meta" ||
    fail 'derived metadata request URL is not byte-exact'
test "$(argv_value "$curl_argv" --max-filesize)" = "$METADATA_SIZE" ||
    fail 'derived catalog size did not reach curl'
grep -Fxq -- '--resolve' "$curl_argv" &&
    grep -Fxq -- "fixture.example:443:$IPV4" "$curl_argv" ||
    fail 'derived origin host and explicit IPv4 did not reach curl resolve'
entry=$(entry_for "$STORE" "$METADATA_DIGEST")
test -f "$entry" && test "$(sha256 "$entry")" = "$METADATA_DIGEST" ||
    fail 'cold success did not retain the exact metadata object'
assert_private_cleanup

# A private tool-root spy proves one catalog-plan invocation and the exact
# derived fetch child surface, including fields the curl argv no longer names.
SPY_ROOT=$WORK/fetch-child-spy-root
mkdir -p "$SPY_ROOT/scripts"
for runtime in authority-v1-validate.awk catalog-v1-validate.awk \
    fetch-artifact-v1-validate.awk fetch-metadata-v1.sh \
    metadata-descriptor-v1-validate.awk metadata-request-v1-validate.awk \
    metadata-v1-validate.awk protocol-v1-validate.awk
do
    cp "$ROOT/scripts/$runtime" "$SPY_ROOT/scripts/$runtime"
done
cp "$ROOT/scripts/catalog-v1-plan.sh" "$SPY_ROOT/scripts/catalog-v1-plan-real.sh"
cp "$ROOT/scripts/fetch-artifact-v1.sh" "$SPY_ROOT/scripts/fetch-artifact-v1-real.sh"
cp "$ROOT/scripts/metadata-v1-plan.sh" "$SPY_ROOT/scripts/metadata-v1-plan-real.sh"
cp "$ROOT/scripts/store.sh" "$SPY_ROOT/scripts/store-real.sh"
{
    printf '#!/bin/sh\nset -eu\n'
    printf 'printf "catalog\\n" >>"%s"\n' "$SPY_ROOT/scripts/events"
    printf 'printf "call\\n" >>"%s"\n' "$SPY_ROOT/scripts/catalog.calls"
    printf 'printf "%%s\\n" "$@" >"%s"\n' "$SPY_ROOT/scripts/catalog.args"
    printf 'exec /bin/sh "%s" "$@"\n' "$SPY_ROOT/scripts/catalog-v1-plan-real.sh"
} >"$SPY_ROOT/scripts/catalog-v1-plan.sh"
{
    printf '#!/bin/sh\nset -eu\n'
    printf 'printf "fetch\\n" >>"%s"\n' "$SPY_ROOT/scripts/events"
    printf 'printf "call\\n" >>"%s"\n' "$SPY_ROOT/scripts/fetch.calls"
    printf 'printf "%%s\\n" "$@" >"%s"\n' "$SPY_ROOT/scripts/fetch.args"
    printf 'exec /bin/sh "%s" "$@"\n' "$SPY_ROOT/scripts/fetch-artifact-v1-real.sh"
} >"$SPY_ROOT/scripts/fetch-artifact-v1.sh"
{
    printf '#!/bin/sh\nset -eu\n'
    printf 'printf "metadata\\n" >>"%s"\n' "$SPY_ROOT/scripts/events"
    printf 'printf "%%s\\n" "$@" >"%s"\n' "$SPY_ROOT/scripts/metadata.args"
    printf 'exec /bin/sh "%s" "$@"\n' "$SPY_ROOT/scripts/metadata-v1-plan-real.sh"
} >"$SPY_ROOT/scripts/metadata-v1-plan.sh"
{
    printf '#!/bin/sh\nset -eu\n'
    printf 'command=${3:-missing}\n'
    printf 'printf "store-%%s\\n" "$command" >>"%s"\n' "$SPY_ROOT/scripts/events"
    printf 'printf "%%s\\n" "$@" >"%s/store.$command.args"\n' \
        "$SPY_ROOT/scripts"
    printf 'exec /bin/sh "%s" "$@"\n' "$SPY_ROOT/scripts/store-real.sh"
} >"$SPY_ROOT/scripts/store.sh"
chmod +x "$SPY_ROOT/scripts/"*.sh
REAL_TOOL=$TOOL
TOOL=$SPY_ROOT/scripts/fetch-metadata-v1.sh
STORE=$WORK/store-child-spy
reset_fixture
fetch_current >"$WORK/child-spy.out" 2>"$WORK/child-spy.err" ||
    fail "derived child spy failed: $(tr '\n' ' ' <"$WORK/child-spy.err")"
test "$(wc -l <"$SPY_ROOT/scripts/catalog.calls" | tr -d ' ')" -eq 1 ||
    fail 'metadata wrapper invoked the supplied catalog planner more than once'
test "$(wc -l <"$SPY_ROOT/scripts/fetch.calls" | tr -d ' ')" -eq 1 ||
    fail 'metadata wrapper invoked the artifact fetch child more than once'
{
    printf '%s\n' --class metadata
    printf '%s\n' --origin https://fixture.example
    printf '%s\n' --target "/pkg/@kofun/v1/versions/$VERSION.meta"
    printf '%s\n' --ipv4 "$IPV4"
    printf '%s\n' --ca-file "$CA"
    printf '%s\n' --size "$METADATA_SIZE"
    printf '%s\n' --digest "$METADATA_DIGEST"
    printf '%s\n' --store "$STORE"
} >"$WORK/expected-fetch.args"
cmp "$WORK/expected-fetch.args" "$SPY_ROOT/scripts/fetch.args" ||
    fail 'fetch child did not receive only the exact planned/caller scalar split'
{
    printf '%s\n' catalog fetch store-admit store-snapshot metadata
} >"$WORK/expected-events"
cmp "$WORK/expected-events" "$SPY_ROOT/scripts/events" ||
    fail 'child calls did not preserve catalog, fetch/admit, snapshot, parse order'
{
    printf '%s\n' inspect "$ID" "$CATALOG" --authority "$AUTHORITY"
} >"$WORK/expected-catalog.args"
cmp "$WORK/expected-catalog.args" "$SPY_ROOT/scripts/catalog.args" ||
    fail 'catalog planner did not receive the exact supplied identity/path inputs'
snapshot_path=$(sed -n '6p' "$SPY_ROOT/scripts/store.snapshot.args")
test "$(sed -n '1p' "$SPY_ROOT/scripts/store.snapshot.args")" = --store &&
    test "$(sed -n '2p' "$SPY_ROOT/scripts/store.snapshot.args")" = "$STORE" &&
    test "$(sed -n '3p' "$SPY_ROOT/scripts/store.snapshot.args")" = snapshot &&
    test "$(sed -n '4p' "$SPY_ROOT/scripts/store.snapshot.args")" = "$METADATA_DIGEST" &&
    test "$(sed -n '5p' "$SPY_ROOT/scripts/store.snapshot.args")" = "$METADATA_SIZE" ||
    fail 'post-fetch store snapshot did not retain the exact planned descriptor'
metadata_input=$(sed -n '4p' "$SPY_ROOT/scripts/metadata.args")
test "$metadata_input" = "$snapshot_path" ||
    fail 'strict parser did not consume the exact private store snapshot destination'
{
    printf '%s\n' inspect "$ID" "$VERSION" "$snapshot_path" \
        --size "$METADATA_SIZE" --digest "$METADATA_DIGEST"
} >"$WORK/expected-metadata.args"
cmp "$WORK/expected-metadata.args" "$SPY_ROOT/scripts/metadata.args" ||
    fail 'strict parser did not receive only the private snapshot and planned descriptor'
TOOL=$REAL_TOOL
assert_private_cleanup

# A warm hit performs no transfer but still snapshots and parses the bytes.
STORE=$WORK/store-default
reset_fixture
fetch_current >"$WORK/warm.out" 2>"$WORK/warm.err" ||
    fail "warm metadata acquisition failed: $(tr '\n' ' ' <"$WORK/warm.err")"
test "$(transfer_count)" -eq 0 || fail 'warm metadata hit reached curl transfer'
grep -Fq 'strictly parsed' "$WORK/warm.out" ||
    fail 'warm hit omitted post-store strict parsing'
test ! -s "$WORK/warm.err" || fail 'warm success leaked child stderr'
assert_private_cleanup

# A corrupt warm object is never repaired or replaced and does not reach
# network or strict parsing success.
warm_inode=$(stat -c %i "$entry")
chmod 644 "$entry"
sed '1s/kofun/Kofun/' "$RESPONSE_METADATA" >"$entry"
chmod 444 "$entry"
warm_corrupt_digest=$(sha256 "$entry")
test "$warm_corrupt_digest" != "$METADATA_DIGEST" ||
    fail 'corrupt warm fixture still matches its digest-shaped pathname'
reset_fixture
expect_refusal 'corrupt warm metadata object' 'catalog-bound metadata fetch failed' 0
test "$(stat -c %i "$entry")" = "$warm_inode" &&
    test "$(sha256 "$entry")" = "$warm_corrupt_digest" ||
    fail 'corrupt warm metadata object was repaired or replaced'

# Authority and catalog pathnames are each snapshotted once. Replacing either
# original after head returns cannot change the retained private plan.
real_head=$(command -v head)
{
    printf '#!/bin/sh\nset -eu\n'
    printf 'input=$(readlink "/proc/$$/fd/0" 2>/dev/null || :)\n'
    printf '"%s" "$@"\nstatus=$?\n' "$real_head"
    printf 'if test "$input" = "$KPM_SWAP_TARGET"; then\n'
    printf '  count=0\n  test ! -f "$KPM_SWAP_COUNT" || read -r count <"$KPM_SWAP_COUNT"\n'
    printf '  count=$((count + 1))\n  printf "%%s\\n" "$count" >"$KPM_SWAP_COUNT"\n'
    printf '  cp "$KPM_SWAP_BYTES" "$KPM_SWAP_TARGET"\nfi\nexit "$status"\n'
} >"$FAKE_BIN/head"
chmod +x "$FAKE_BIN/head"

cp "$AUTHORITY" "$WORK/authority.read-once"
AUTHORITY=$WORK/authority.read-once
STORE=$WORK/store-authority-read-once
reset_fixture
KPM_SWAP_TARGET="$AUTHORITY" KPM_SWAP_BYTES="$WORK/unapproved.authority" \
KPM_SWAP_COUNT="$WORK/authority.count" fetch_current \
    >"$WORK/authority-read-once.out" 2>"$WORK/authority-read-once.err" ||
    fail 'authority replacement changed the private plan'
test "$(sed -n '1p' "$WORK/authority.count")" = 1 ||
    fail 'authority pathname was not read exactly once'
AUTHORITY=$saved_authority

cp "$CATALOG" "$WORK/catalog.read-once"
CATALOG=$WORK/catalog.read-once
STORE=$WORK/store-catalog-read-once
reset_fixture
KPM_SWAP_TARGET="$CATALOG" KPM_SWAP_BYTES="$WORK/higher.catalog" \
KPM_SWAP_COUNT="$WORK/catalog.count" fetch_current \
    >"$WORK/catalog-read-once.out" 2>"$WORK/catalog-read-once.err" ||
    fail 'catalog replacement changed the private plan'
test "$(sed -n '1p' "$WORK/catalog.count")" = 1 ||
    fail 'catalog pathname was not read exactly once'
CATALOG=$saved_catalog
rm -f "$FAKE_BIN/head"
assert_private_cleanup

# Root and major-versioned identities retain the exact slash boundary in the
# derived request target. One hostile explicit-path case proves byte-exact argv
# preservation through both planner and fetch composition.
run_identity_case() {
    identity_label=$1
    ID=$2
    VERSION=$3
    identity_target=$4
    RESPONSE_METADATA=$WORK/$identity_label.metadata
    CATALOG=$WORK/$identity_label.catalog
    STORE=$WORK/store-$identity_label
    {
        printf 'kofun-metadata/v1\nidentity\t%s\nversion\t%s\n' "$ID" "$VERSION"
        printf 'file\tsrc.kofun\tsource\t3\t%s\n' "$ZERO"
    } >"$RESPONSE_METADATA"
    catalog_for "$RESPONSE_METADATA" "$CATALOG" "$VERSION"
    reset_fixture
    fetch_current >"$WORK/$identity_label.out" 2>"$WORK/$identity_label.err" ||
        fail "$identity_label identity acquisition failed: $(tr '\n' ' ' <"$WORK/$identity_label.err")"
    identity_argv=$(find "$FIXTURE" -name 'argv.*')
    test "$(argv_value "$identity_argv" --url)" = \
        "https://fixture.example$identity_target" ||
        fail "$identity_label identity derived the wrong request target"
    assert_private_cleanup
}
run_identity_case root https://fixture.example/ 1.2.0 \
    /@kofun/v1/versions/1.2.0.meta
run_identity_case major-v2 https://fixture.example/pkg/v2/ 2.3.4 \
    /pkg/v2/@kofun/v1/versions/2.3.4.meta

ID=https://fixture.example/pkg/
VERSION=1.2.0
RESPONSE_METADATA=$WORK/metadata
mkdir "$WORK/hostile explicit paths"
cp "$WORK/catalog" "$WORK/hostile explicit paths/-catalog [v1]"
cp "$WORK/authority" "$WORK/hostile explicit paths/-authority [v1]"
cp "$WORK/roots.pem" "$WORK/hostile explicit paths/-ca [v1].pem"
CATALOG="$WORK/hostile explicit paths/-catalog [v1]"
AUTHORITY="$WORK/hostile explicit paths/-authority [v1]"
CA="$WORK/hostile explicit paths/-ca [v1].pem"
STORE="$WORK/hostile explicit paths/store with spaces"
reset_fixture
fetch_current >"$WORK/hostile-path.out" 2>"$WORK/hostile-path.err" ||
    fail "hostile explicit paths were not preserved: $(tr '\n' ' ' <"$WORK/hostile-path.err")"
test "$(transfer_count)" -eq 1 || fail 'hostile explicit paths skipped or duplicated transfer'
assert_private_cleanup
AUTHORITY=$saved_authority
CATALOG=$saved_catalog
CA=$WORK/roots.pem

# Descriptor-valid but grammar-invalid bytes remain only as unreferenced CAS.
# No child admission/store success or row count escapes either cold or warm.
cp "$RESPONSE_METADATA" "$WORK/bad.metadata"
printf 'unknown\tafter-valid-rows\n' >>"$WORK/bad.metadata"
RESPONSE_METADATA=$WORK/bad.metadata
CATALOG=$WORK/bad.catalog
catalog_for "$RESPONSE_METADATA" "$CATALOG"
bad_digest=$(sha256 "$RESPONSE_METADATA")
STORE=$WORK/store-bad-grammar
reset_fixture
expect_refusal 'descriptor-valid bad metadata grammar' \
    'descriptor-valid metadata bytes failed strict parsing' 1
bad_entry=$(entry_for "$STORE" "$bad_digest")
test -f "$bad_entry" && test ! -w "$bad_entry" &&
    test "$(sha256 "$bad_entry")" = "$bad_digest" ||
    fail 'grammar-invalid admitted CAS bytes were absent, writable, or changed'
reset_fixture
expect_refusal 'warm descriptor-valid bad metadata grammar' \
    'descriptor-valid metadata bytes failed strict parsing' 0

# A late strict-parser failure cannot leak a partial normalized plan when the
# factored planner is invoked directly.
bad_size=$(wc -c <"$RESPONSE_METADATA" | tr -d ' ')
if "$PLAN_TOOL" inspect "$ID" "$VERSION" "$RESPONSE_METADATA" \
    --size "$bad_size" --digest "$bad_digest" \
    >"$WORK/bad-plan.out" 2>"$WORK/bad-plan.err"
then
    fail 'factored planner accepted grammar-invalid metadata'
fi
test ! -s "$WORK/bad-plan.out" || fail 'factored planner leaked partial rows'

# Transport size/digest failures never admit an object and never reach parse.
RESPONSE_METADATA=$WORK/metadata
CATALOG=$WORK/catalog
STORE=$WORK/store-short
reset_fixture
head -c "$((METADATA_SIZE - 1))" <"$RESPONSE_METADATA" >"$FIXTURE/body"
expect_refusal 'short metadata response' 'catalog-bound metadata fetch failed' 1
test ! -e "$(entry_for "$STORE" "$METADATA_DIGEST")" ||
    fail 'short metadata response reached store admission'

STORE=$WORK/store-wrong-digest
reset_fixture
sed '1s/kofun/Kofun/' "$RESPONSE_METADATA" >"$FIXTURE/body"
expect_refusal 'same-size wrong metadata digest' \
    'catalog-bound metadata fetch failed' 1
test ! -e "$(entry_for "$STORE" "$METADATA_DIGEST")" ||
    fail 'wrong metadata digest reached store admission'

# Corrupting an admitted winner after the fetch child returns cannot expose
# that held child success: the wrapper's independent store snapshot catches it.
{
    printf '#!/bin/sh\nset -eu\n'
    printf 'if test "${3:-}" = admit; then\n'
    printf '  admitted=$(/bin/sh "%s" "$@") || exit $?\n' \
        "$SPY_ROOT/scripts/store-real.sh"
    printf '  store=$2\n  digest=$4\n'
    printf '  entry=$store/$(printf "%%s" "$digest" | cut -c1-2)/$(printf "%%s" "$digest" | cut -c3-)\n'
    printf '  chmod 644 "$entry"\n'
    printf '  printf X | /bin/dd of="$entry" bs=1 count=1 conv=notrunc status=none\n'
    printf '  chmod 444 "$entry"\n  printf "%%s\\n" "$admitted"\n  exit 0\nfi\n'
    printf 'exec /bin/sh "%s" "$@"\n' "$SPY_ROOT/scripts/store-real.sh"
} >"$SPY_ROOT/scripts/store.sh"
chmod +x "$SPY_ROOT/scripts/store.sh" "$SPY_ROOT/scripts/store-real.sh"
TOOL=$SPY_ROOT/scripts/fetch-metadata-v1.sh
STORE=$WORK/store-post-admit-corrupt
reset_fixture
expect_refusal 'post-admission metadata corruption' \
    'admitted metadata could not be reverified from the store' 1
post_admit_entry=$(entry_for "$STORE" "$METADATA_DIGEST")
test -f "$post_admit_entry" &&
    test "$(sha256 "$post_admit_entry")" != "$METADATA_DIGEST" ||
    fail 'post-admission corruption fixture did not persist for recovery evidence'
TOOL=$REAL_TOOL

# Four cold callers may race through transport; create-if-absent admission is
# still singular, and each caller parses its own verified post-store snapshot.
STORE=$WORK/store-race
reset_fixture
printf '4\n' >"$FIXTURE/barrier-expected"
mkdir "$WORK/race"
race_pids=
n=1
while test "$n" -le 4; do
    fetch_current >"$WORK/race/$n.out" 2>"$WORK/race/$n.err" &
    race_pids="$race_pids $!"
    n=$((n + 1))
done
race_failures=0
for race_pid in $race_pids; do
    wait "$race_pid" || race_failures=$((race_failures + 1))
done
test "$race_failures" -eq 0 || fail "$race_failures concurrent metadata fetch(es) failed"
test "$(transfer_count)" -eq 4 || fail 'not every concurrent cold caller transferred once'
for race_out in "$WORK/race"/*.out; do
    test "$(wc -l <"$race_out" | tr -d ' ')" -eq 2 ||
        fail "concurrent caller leaked or duplicated success output: $race_out"
    test "$(grep -Fc 'catalog-bound metadata admitted, reverified, and strictly parsed' "$race_out")" -eq 1 ||
        fail "concurrent caller omitted or duplicated final success: $race_out"
    grep -Fq '1 dependency and 1 file descriptor row(s)' "$race_out" ||
        fail "concurrent caller omitted strict row counts: $race_out"
    race_err=${race_out%.out}.err
    test ! -s "$race_err" ||
        fail "concurrent caller leaked child stderr: $race_err"
done
race_entry=$(entry_for "$STORE" "$METADATA_DIGEST")
test "$(find "$STORE" -type f | wc -l | tr -d ' ')" -eq 1 &&
    test "$(sha256 "$race_entry")" = "$METADATA_DIGEST" ||
    fail 'concurrent acquisition exposed more than one exact CAS object'
test "$(find "$STORE" -type f -name '*.incoming.*' | wc -l | tr -d ' ')" -eq 0 ||
    fail 'concurrent acquisition left store admission temporaries'
assert_private_cleanup

printf 'pm: one supplied catalog plan derives one pinned metadata request: PASS\n'
printf 'pm: cold, warm, refusal, unreferenced-CAS, and concurrent metadata parsing: PASS\n'
printf 'pm: metadata acquisition withholds child and top-level success until strict parse: PASS\n'
