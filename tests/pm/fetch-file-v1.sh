#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
TOOL=$ROOT/scripts/fetch-file-v1.sh
SENTINEL=$ROOT/tests/pm/curl-sentinel.sh
WORK=$(mktemp -d "${TMPDIR:-/tmp}/kofun-pm-fetch-file-test.XXXXXX")
trap 'rm -rf "$WORK"' 0 1 2 15

fail() {
    printf 'pm: FAIL: fetch-file-v1: %s\n' "$*" >&2
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

write_metadata() {
    metadata_output=$1
    metadata_path=$2
    metadata_kind=$3
    metadata_blob=$4
    metadata_bytes=$(wc -c <"$metadata_blob" | tr -d ' ')
    metadata_hash=$(sha256 "$metadata_blob")
    {
        printf 'kofun-metadata/v1\n'
        printf 'identity\t%s\n' "$ID"
        printf 'version\t%s\n' "$VERSION"
        printf 'file\t%s\t%s\t%s\t%s\n' "$metadata_path" \
            "$metadata_kind" "$metadata_bytes" "$metadata_hash"
    } >"$metadata_output"
}

write_catalog() {
    catalog_metadata=$1
    catalog_output=$2
    catalog_version=${3:-$VERSION}
    catalog_bytes=$(wc -c <"$catalog_metadata" | tr -d ' ')
    catalog_hash=$(sha256 "$catalog_metadata")
    {
        printf 'kofun-catalog/v1\n'
        printf '%s\t%s\t%s\n' "$catalog_version" "$catalog_bytes" \
            "$catalog_hash"
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
    cp "$RESPONSE_BLOB" "$FIXTURE/body"
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
        npm_lifecycle_event=postinstall npm_lifecycle_script="sh $LOGICAL_PATH" \
        KPM_LIFECYCLE_MARKER="$LIFECYCLE_MARKER" \
        KPM_FILE_IDENTITY=https://ambient.invalid/ KPM_FILE_VERSION=9.9.9 \
        KPM_FILE_PATH=ambient/path \
        "$TOOL" acquire "$ID" "$VERSION" "$LOGICAL_PATH" "$METADATA" \
        --catalog "$CATALOG" --authority "$AUTHORITY" --ipv4 "$IPV4" \
        --ca-file "$CA" --store "$STORE" "$@"
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
    if grep -Eq 'pinned HTTPS response verified|reused verified store object|store: (published|adopted|snapshotted)|metadata-bound .* blob admitted' \
        "$WORK/refusal.out" "$WORK/refusal.err"
    then
        fail "$refusal_label leaked child or top-level success"
    fi
    test ! -e "$LIFECYCLE_MARKER" ||
        fail "$refusal_label executed lifecycle-looking source bytes"
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
LIFECYCLE_MARKER=$WORK/lifecycle-ran
mkdir -p "$FAKE_BIN" "$TMP_ROOT" "$HOSTILE_HOME" "$HOSTILE_XDG" \
    "$HOSTILE_CURL_HOME"
cp "$SENTINEL" "$FAKE_BIN/curl"
chmod +x "$FAKE_BIN/curl"

test -x "$TOOL" || fail "missing executable $TOOL"

ID=https://fixture.example/pkg/
VERSION=1.2.0
LOGICAL_PATH=scripts/postinstall.sh
IPV4=93.184.216.34
CA=$WORK/roots.pem
AUTHORITY=$WORK/authority
CATALOG=$WORK/catalog
METADATA=$WORK/metadata
STORE=$WORK/store-default
RESPONSE_BLOB=$WORK/lifecycle-looking-source
printf 'test-only CA bytes\n' >"$CA"
printf 'kofun-fetch-authority/v1\norigin\thttps://fixture.example\n' >"$AUTHORITY"
{
    printf '#!/bin/sh\n'
    printf 'printf owned > "$KPM_LIFECYCLE_MARKER"\n'
} >"$RESPONSE_BLOB"
chmod 755 "$RESPONSE_BLOB"
write_metadata "$METADATA" "$LOGICAL_PATH" source "$RESPONSE_BLOB"
write_catalog "$METADATA" "$CATALOG"
BLOB_SIZE=$(wc -c <"$RESPONSE_BLOB" | tr -d ' ')
BLOB_DIGEST=$(sha256 "$RESPONSE_BLOB")

# Request grammar and the closed option surface precede every supplied file
# and every network-capable child.
reset_fixture
expect_refusal 'unknown digest override' 'usage:' 0 --digest "$BLOB_DIGEST"
reset_fixture
expect_refusal 'duplicate catalog' 'usage:' 0 --catalog "$CATALOG"
saved_path=$LOGICAL_PATH
LOGICAL_PATH=../postinstall.sh
reset_fixture
expect_refusal 'invalid logical path' \
    'requested identity/version/logical-path grammar is invalid' 0
LOGICAL_PATH=$saved_path

# Authority and exact catalog membership are complete before blob selection or
# transfer. Metadata must be the exact catalog-described document and must
# publish exactly the requested path with a source/data kind.
printf 'kofun-fetch-authority/v1\norigin\thttps://other.example\n' \
    >"$WORK/unapproved.authority"
saved_authority=$AUTHORITY
AUTHORITY=$WORK/unapproved.authority
reset_fixture
expect_refusal 'unapproved origin' 'identity origin is not explicitly approved' 0
AUTHORITY=$saved_authority
printf 'kofun-catalog/v1\n1.10.0\t0\t%s\n' \
    0000000000000000000000000000000000000000000000000000000000000000 \
    >"$WORK/other-version.catalog"
saved_catalog=$CATALOG
CATALOG=$WORK/other-version.catalog
reset_fixture
expect_refusal 'exact version absence' \
    "required version $ID@$VERSION is not published" 0
CATALOG=$saved_catalog

cp "$METADATA" "$WORK/wrong.metadata"
printf 'unknown\tpostinstall\n' >>"$WORK/wrong.metadata"
saved_metadata=$METADATA
METADATA=$WORK/wrong.metadata
write_catalog "$METADATA" "$WORK/wrong.catalog"
CATALOG=$WORK/wrong.catalog
reset_fixture
expect_refusal 'grammar-invalid supplied metadata' \
    'supplied metadata failed its exact catalog descriptor or strict grammar' 0
METADATA=$saved_metadata
CATALOG=$saved_catalog

cp "$METADATA" "$WORK/lifecycle-row.metadata"
printf 'lifecycle\tpostinstall\t/bin/sh\n' >>"$WORK/lifecycle-row.metadata"
write_catalog "$WORK/lifecycle-row.metadata" "$WORK/lifecycle-row.catalog"
METADATA=$WORK/lifecycle-row.metadata
CATALOG=$WORK/lifecycle-row.catalog
reset_fixture
expect_refusal 'lifecycle metadata row' \
    'supplied metadata failed its exact catalog descriptor or strict grammar' 0

{
    printf 'kofun-metadata/v1\nidentity\t%s\nversion\t%s\n' "$ID" "$VERSION"
    printf 'file\t%s\texecutable\t%s\t%s\n' "$LOGICAL_PATH" \
        "$BLOB_SIZE" "$BLOB_DIGEST"
} >"$WORK/executable-kind.metadata"
write_catalog "$WORK/executable-kind.metadata" "$WORK/executable-kind.catalog"
METADATA=$WORK/executable-kind.metadata
CATALOG=$WORK/executable-kind.catalog
reset_fixture
expect_refusal 'executable metadata kind' \
    'supplied metadata failed its exact catalog descriptor or strict grammar' 0
METADATA=$saved_metadata
CATALOG=$saved_catalog

{
    printf 'kofun-metadata/v1\nversion\t%s\nidentity\t%s\n' "$VERSION" "$ID"
    printf 'file\t%s\tsource\t%s\t%s\n' "$LOGICAL_PATH" \
        "$BLOB_SIZE" "$BLOB_DIGEST"
} >"$WORK/bad-order.metadata"
write_catalog "$WORK/bad-order.metadata" "$WORK/bad-order.catalog"
METADATA=$WORK/bad-order.metadata
CATALOG=$WORK/bad-order.catalog
reset_fixture
expect_refusal 'metadata row order' \
    'supplied metadata failed its exact catalog descriptor or strict grammar' 0

{
    printf 'kofun-metadata/v1\nidentity\thttps://fixture.example/other/\n'
    printf 'version\t%s\n' "$VERSION"
    printf 'file\t%s\tsource\t%s\t%s\n' "$LOGICAL_PATH" \
        "$BLOB_SIZE" "$BLOB_DIGEST"
} >"$WORK/wrong-identity.metadata"
write_catalog "$WORK/wrong-identity.metadata" "$WORK/wrong-identity.catalog"
METADATA=$WORK/wrong-identity.metadata
CATALOG=$WORK/wrong-identity.catalog
reset_fixture
expect_refusal 'metadata document identity' \
    'supplied metadata failed its exact catalog descriptor or strict grammar' 0

{
    printf 'kofun-metadata/v1\nidentity\t%s\nversion\t1.2.1\n' "$ID"
    printf 'file\t%s\tsource\t%s\t%s\n' "$LOGICAL_PATH" \
        "$BLOB_SIZE" "$BLOB_DIGEST"
} >"$WORK/wrong-version.metadata"
write_catalog "$WORK/wrong-version.metadata" "$WORK/wrong-version.catalog"
METADATA=$WORK/wrong-version.metadata
CATALOG=$WORK/wrong-version.catalog
reset_fixture
expect_refusal 'metadata document version' \
    'supplied metadata failed its exact catalog descriptor or strict grammar' 0

METADATA=$saved_metadata
metadata_size=$(wc -c <"$METADATA" | tr -d ' ')
metadata_digest=$(sha256 "$METADATA")
{
    printf 'kofun-catalog/v1\n'
    printf '%s\t%s\t%s\n' "$VERSION" "$((metadata_size + 1))" \
        "$metadata_digest"
} >"$WORK/wrong-metadata-size.catalog"
CATALOG=$WORK/wrong-metadata-size.catalog
reset_fixture
expect_refusal 'catalog-described metadata size' \
    'supplied metadata failed its exact catalog descriptor or strict grammar' 0
{
    printf 'kofun-catalog/v1\n'
    printf '%s\t%s\t%s\n' "$VERSION" "$metadata_size" \
        0000000000000000000000000000000000000000000000000000000000000000
} >"$WORK/wrong-metadata-digest.catalog"
CATALOG=$WORK/wrong-metadata-digest.catalog
reset_fixture
expect_refusal 'catalog-described metadata digest' \
    'supplied metadata failed its exact catalog descriptor or strict grammar' 0
METADATA=$saved_metadata
CATALOG=$saved_catalog

write_metadata "$WORK/missing.metadata" README.md data "$RESPONSE_BLOB"
write_catalog "$WORK/missing.metadata" "$WORK/missing.catalog"
METADATA=$WORK/missing.metadata
CATALOG=$WORK/missing.catalog
reset_fixture
expect_refusal 'missing requested path' \
    'logical path is not published by the exact metadata document' 0
METADATA=$saved_metadata
CATALOG=$saved_catalog

# A cold success derives the target and descriptor, admits immutable bytes,
# re-snapshots them, validates source UTF-8, and never executes an executable,
# lifecycle-looking input.
reset_fixture
fetch_current >"$WORK/cold.out" 2>"$WORK/cold.err" ||
    fail "cold blob acquisition failed: $(tr '\n' ' ' <"$WORK/cold.err")"
grep -Fq 'metadata-bound source blob admitted and independently reverified' \
    "$WORK/cold.out" || fail 'cold success omitted the top-level sentinel'
test "$(wc -l <"$WORK/cold.out" | tr -d ' ')" -eq 2 ||
    fail 'cold success leaked child output'
test ! -s "$WORK/cold.err" ||
    fail "cold success leaked child stderr: $(tr '\n' ' ' <"$WORK/cold.err")"
test "$(transfer_count)" -eq 1 || fail 'cold success did not make one transfer'
curl_argv=$(find "$FIXTURE" -name 'argv.*')
test "$(argv_value "$curl_argv" --url)" = \
    "https://fixture.example/pkg/@kofun/v1/blobs/sha256/$BLOB_DIGEST" ||
    fail 'metadata-selected blob URL is not byte-exact'
test "$(argv_value "$curl_argv" --max-filesize)" = "$BLOB_SIZE" ||
    fail 'metadata-selected blob size did not reach curl'
entry=$(entry_for "$STORE" "$BLOB_DIGEST")
test -f "$entry" && test "$(sha256 "$entry")" = "$BLOB_DIGEST" &&
    test ! -w "$entry" && test ! -x "$entry" ||
    fail 'cold success did not retain exact immutable non-executable CAS bytes'
test ! -e "$LIFECYCLE_MARKER" ||
    fail 'acquisition executed lifecycle-looking source bytes'
assert_private_cleanup

# A warm hit performs no transfer, but still selects the descriptor,
# independently snapshots the store object, and checks source UTF-8.
reset_fixture
fetch_current >"$WORK/warm.out" 2>"$WORK/warm.err" ||
    fail "warm blob acquisition failed: $(tr '\n' ' ' <"$WORK/warm.err")"
test "$(transfer_count)" -eq 0 || fail 'warm blob hit reached network transfer'
grep -Fq 'independently reverified' "$WORK/warm.out" ||
    fail 'warm hit omitted the outer store boundary'
test ! -s "$WORK/warm.err" && test ! -e "$LIFECYCLE_MARKER" ||
    fail 'warm success leaked child stderr or executed source bytes'
assert_private_cleanup

# A private tool root fixes exact child argv and the order catalog -> metadata
# -> fetch/admit -> independent snapshot -> UTF-8. Each planner is called once.
SPY_ROOT=$WORK/spy-root
mkdir -p "$SPY_ROOT/scripts"
for runtime in authority-v1-validate.awk catalog-v1-validate.awk \
    fetch-artifact-v1-validate.awk fetch-file-v1.sh \
    file-request-v1-validate.awk metadata-descriptor-v1-validate.awk \
    metadata-v1-validate.awk protocol-v1-validate.awk
do
    cp "$ROOT/scripts/$runtime" "$SPY_ROOT/scripts/$runtime"
done
for adapter in catalog-v1-plan fetch-artifact-v1 metadata-v1-plan store; do
    cp "$ROOT/scripts/$adapter.sh" "$SPY_ROOT/scripts/$adapter-real.sh"
done
{
    printf '#!/bin/sh\nset -eu\n'
    printf 'printf "catalog\\n" >>"%s"\n' "$SPY_ROOT/scripts/events"
    printf 'printf "call\\n" >>"%s"\n' "$SPY_ROOT/scripts/catalog.calls"
    printf 'printf "%%s\\n" "$@" >"%s"\n' "$SPY_ROOT/scripts/catalog.args"
    printf 'exec /bin/sh "%s" "$@"\n' "$SPY_ROOT/scripts/catalog-v1-plan-real.sh"
} >"$SPY_ROOT/scripts/catalog-v1-plan.sh"
{
    printf '#!/bin/sh\nset -eu\n'
    printf 'printf "metadata\\n" >>"%s"\n' "$SPY_ROOT/scripts/events"
    printf 'printf "call\\n" >>"%s"\n' "$SPY_ROOT/scripts/metadata.calls"
    printf 'printf "%%s\\n" "$@" >"%s"\n' "$SPY_ROOT/scripts/metadata.args"
    printf 'exec /bin/sh "%s" "$@"\n' "$SPY_ROOT/scripts/metadata-v1-plan-real.sh"
} >"$SPY_ROOT/scripts/metadata-v1-plan.sh"
{
    printf '#!/bin/sh\nset -eu\n'
    printf 'printf "fetch\\n" >>"%s"\n' "$SPY_ROOT/scripts/events"
    printf 'printf "call\\n" >>"%s"\n' "$SPY_ROOT/scripts/fetch.calls"
    printf 'printf "%%s\\n" "$@" >"%s"\n' "$SPY_ROOT/scripts/fetch.args"
    printf 'exec /bin/sh "%s" "$@"\n' "$SPY_ROOT/scripts/fetch-artifact-v1-real.sh"
} >"$SPY_ROOT/scripts/fetch-artifact-v1.sh"
{
    printf '#!/bin/sh\nset -eu\n'
    printf 'command=${3:-missing}\n'
    printf 'printf "store-%%s\\n" "$command" >>"%s"\n' "$SPY_ROOT/scripts/events"
    printf 'printf "%%s\\n" "$@" >"%s/store.$command.args"\n' "$SPY_ROOT/scripts"
    printf 'exec /bin/sh "%s" "$@"\n' "$SPY_ROOT/scripts/store-real.sh"
} >"$SPY_ROOT/scripts/store.sh"
chmod +x "$SPY_ROOT/scripts/"*.sh
REAL_TOOL=$TOOL
TOOL=$SPY_ROOT/scripts/fetch-file-v1.sh
STORE=$WORK/store-spy
reset_fixture
fetch_current >"$WORK/spy.out" 2>"$WORK/spy.err" ||
    fail "child-order acquisition failed: $(tr '\n' ' ' <"$WORK/spy.err")"
test "$(wc -l <"$SPY_ROOT/scripts/catalog.calls" | tr -d ' ')" -eq 1 &&
    test "$(wc -l <"$SPY_ROOT/scripts/metadata.calls" | tr -d ' ')" -eq 1 &&
    test "$(wc -l <"$SPY_ROOT/scripts/fetch.calls" | tr -d ' ')" -eq 1 ||
    fail 'one request invoked a planner or fetch child more than once'
{
    printf '%s\n' catalog metadata fetch store-admit store-snapshot
} >"$WORK/expected.events"
cmp "$WORK/expected.events" "$SPY_ROOT/scripts/events" ||
    fail 'child calls did not preserve plan/fetch/admit/snapshot order'
{
    printf '%s\n' inspect "$ID" "$CATALOG" --authority "$AUTHORITY"
} >"$WORK/expected.catalog.args"
cmp "$WORK/expected.catalog.args" "$SPY_ROOT/scripts/catalog.args" ||
    fail 'catalog planner did not receive the exact supplied inputs'
metadata_size=$(wc -c <"$METADATA" | tr -d ' ')
metadata_digest=$(sha256 "$METADATA")
{
    printf '%s\n' inspect "$ID" "$VERSION" "$METADATA" \
        --size "$metadata_size" --digest "$metadata_digest"
} >"$WORK/expected.metadata.args"
cmp "$WORK/expected.metadata.args" "$SPY_ROOT/scripts/metadata.args" ||
    fail 'metadata planner did not receive the exact supplied file and descriptor'
{
    printf '%s\n' --class blob --origin https://fixture.example \
        --target "/pkg/@kofun/v1/blobs/sha256/$BLOB_DIGEST" \
        --ipv4 "$IPV4" --ca-file "$CA" --size "$BLOB_SIZE" \
        --digest "$BLOB_DIGEST" --store "$STORE"
} >"$WORK/expected.fetch.args"
cmp "$WORK/expected.fetch.args" "$SPY_ROOT/scripts/fetch.args" ||
    fail 'fetch child did not receive the exact derived/caller scalar split'
test "$(sed -n '4p' "$SPY_ROOT/scripts/store.snapshot.args")" = "$BLOB_DIGEST" &&
    test "$(sed -n '5p' "$SPY_ROOT/scripts/store.snapshot.args")" = "$BLOB_SIZE" ||
    fail 'outer snapshot did not retain the exact metadata-selected descriptor'
TOOL=$REAL_TOOL
assert_private_cleanup

# The supplied authority, catalog, and metadata pathnames cannot be reopened
# after their planners return. These planner doubles replace all three inputs
# after producing private plans; the retained descriptor must still succeed.
cp "$AUTHORITY" "$WORK/authority.read-once"
cp "$CATALOG" "$WORK/catalog.read-once"
cp "$METADATA" "$WORK/metadata.read-once"
{
    printf '#!/bin/sh\nset -eu\n'
    printf 'plan=$(mktemp "$TMPDIR/catalog-plan.XXXXXX")\n'
    printf '/bin/sh "%s" "$@" >"$plan"\n' \
        "$SPY_ROOT/scripts/catalog-v1-plan-real.sh"
    printf 'cp "%s" "$3"\n' "$WORK/other-version.catalog"
    printf 'cp "%s" "$5"\n' "$WORK/unapproved.authority"
    printf 'cat "$plan"\nrm -f "$plan"\n'
} >"$SPY_ROOT/scripts/catalog-v1-plan.sh"
{
    printf '#!/bin/sh\nset -eu\n'
    printf 'plan=$(mktemp "$TMPDIR/metadata-plan.XXXXXX")\n'
    printf '/bin/sh "%s" "$@" >"$plan"\n' \
        "$SPY_ROOT/scripts/metadata-v1-plan-real.sh"
    printf 'cp "%s" "$4"\n' "$WORK/missing.metadata"
    printf 'cat "$plan"\n'
} >"$SPY_ROOT/scripts/metadata-v1-plan.sh"
chmod +x "$SPY_ROOT/scripts/catalog-v1-plan.sh" \
    "$SPY_ROOT/scripts/metadata-v1-plan.sh"
TOOL=$SPY_ROOT/scripts/fetch-file-v1.sh
AUTHORITY=$WORK/authority.read-once
CATALOG=$WORK/catalog.read-once
METADATA=$WORK/metadata.read-once
STORE=$WORK/store-read-once
reset_fixture
fetch_current >"$WORK/read-once.out" 2>"$WORK/read-once.err" ||
    fail "post-plan input swaps changed the retained request: $(tr '\n' ' ' <"$WORK/read-once.err")"
test "$(transfer_count)" -eq 1 ||
    fail 'post-plan input swaps skipped or duplicated the transfer'
cmp -s "$AUTHORITY" "$WORK/unapproved.authority" &&
    cmp -s "$CATALOG" "$WORK/other-version.catalog" &&
    cmp -s "$METADATA" "$WORK/missing.metadata" ||
    fail 'a read-once swap double did not replace its original pathname'
TOOL=$REAL_TOOL
AUTHORITY=$saved_authority
CATALOG=$saved_catalog
METADATA=$saved_metadata
{
    printf '#!/bin/sh\nexec /bin/sh "%s" "$@"\n' \
        "$SPY_ROOT/scripts/catalog-v1-plan-real.sh"
} >"$SPY_ROOT/scripts/catalog-v1-plan.sh"
{
    printf '#!/bin/sh\nexec /bin/sh "%s" "$@"\n' \
        "$SPY_ROOT/scripts/metadata-v1-plan-real.sh"
} >"$SPY_ROOT/scripts/metadata-v1-plan.sh"
chmod +x "$SPY_ROOT/scripts/catalog-v1-plan.sh" \
    "$SPY_ROOT/scripts/metadata-v1-plan.sh"
assert_private_cleanup

# Invalid UTF-8 source bytes may remain as immutable unreferenced CAS, but
# cannot produce success. The same bytes explicitly described as data are
# opaque and do succeed. Warm source failure still performs no transfer.
printf '\377' >"$WORK/invalid-utf8"
RESPONSE_BLOB=$WORK/invalid-utf8
METADATA=$WORK/invalid-source.metadata
CATALOG=$WORK/invalid-source.catalog
STORE=$WORK/store-invalid-source
write_metadata "$METADATA" "$LOGICAL_PATH" source "$RESPONSE_BLOB"
write_catalog "$METADATA" "$CATALOG"
invalid_digest=$(sha256 "$RESPONSE_BLOB")
reset_fixture
expect_refusal 'invalid UTF-8 source' 'metadata-bound source is not valid UTF-8' 1
invalid_entry=$(entry_for "$STORE" "$invalid_digest")
test -f "$invalid_entry" && test ! -w "$invalid_entry" ||
    fail 'invalid UTF-8 source did not remain as immutable unreferenced CAS'
reset_fixture
expect_refusal 'warm invalid UTF-8 source' \
    'metadata-bound source is not valid UTF-8' 0

METADATA=$WORK/opaque-data.metadata
CATALOG=$WORK/opaque-data.catalog
STORE=$WORK/store-opaque-data
write_metadata "$METADATA" "$LOGICAL_PATH" data "$RESPONSE_BLOB"
write_catalog "$METADATA" "$CATALOG"
reset_fixture
fetch_current >"$WORK/data.out" 2>"$WORK/data.err" ||
    fail "opaque data acquisition failed: $(tr '\n' ' ' <"$WORK/data.err")"
grep -Fq 'metadata-bound data blob admitted' "$WORK/data.out" ||
    fail 'opaque data success did not name its metadata kind'
test ! -s "$WORK/data.err" || fail 'opaque data success leaked child stderr'
assert_private_cleanup

# Transport truncation/digest errors do not admit, and a corrupt warm object
# is neither repaired nor replaced.
RESPONSE_BLOB=$WORK/lifecycle-looking-source
METADATA=$WORK/metadata
CATALOG=$WORK/catalog
STORE=$WORK/store-short
reset_fixture
head -c "$((BLOB_SIZE - 1))" <"$RESPONSE_BLOB" >"$FIXTURE/body"
expect_refusal 'short blob response' 'metadata-bound blob fetch failed' 1
test ! -e "$(entry_for "$STORE" "$BLOB_DIGEST")" ||
    fail 'short blob response reached store admission'

STORE=$WORK/store-wrong-digest
reset_fixture
cp "$RESPONSE_BLOB" "$FIXTURE/body"
printf X | dd of="$FIXTURE/body" bs=1 count=1 conv=notrunc status=none
expect_refusal 'same-size wrong blob digest' 'metadata-bound blob fetch failed' 1
test ! -e "$(entry_for "$STORE" "$BLOB_DIGEST")" ||
    fail 'wrong blob digest reached store admission'

STORE=$WORK/store-corrupt-warm
reset_fixture
fetch_current >"$WORK/corrupt-prime.out" 2>"$WORK/corrupt-prime.err" ||
    fail 'could not prime corrupt-warm fixture'
corrupt_entry=$(entry_for "$STORE" "$BLOB_DIGEST")
corrupt_inode=$(stat -c %i "$corrupt_entry")
chmod 644 "$corrupt_entry"
printf X | dd of="$corrupt_entry" bs=1 count=1 conv=notrunc status=none
chmod 444 "$corrupt_entry"
corrupt_digest=$(sha256 "$corrupt_entry")
reset_fixture
expect_refusal 'corrupt warm blob' 'metadata-bound blob fetch failed' 0
test "$(stat -c %i "$corrupt_entry")" = "$corrupt_inode" &&
    test "$(sha256 "$corrupt_entry")" = "$corrupt_digest" ||
    fail 'corrupt warm object was repaired or replaced'

# Corruption after child admission but before the wrapper snapshot is caught
# by that independent use-boundary snapshot.
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
chmod +x "$SPY_ROOT/scripts/store.sh"
TOOL=$SPY_ROOT/scripts/fetch-file-v1.sh
STORE=$WORK/store-post-admit-corrupt
reset_fixture
expect_refusal 'post-admission blob corruption' \
    'admitted blob could not be reverified from the store' 1
post_entry=$(entry_for "$STORE" "$BLOB_DIGEST")
test -f "$post_entry" && test "$(sha256 "$post_entry")" != "$BLOB_DIGEST" ||
    fail 'post-admission corruption fixture did not persist'
TOOL=$REAL_TOOL

# Root and major-v2 identities preserve the exact slash boundary in the
# digest URL. Explicit paths with spaces remain byte-exact inputs.
run_identity_case() {
    identity_label=$1
    ID=$2
    VERSION=$3
    identity_target=$4
    LOGICAL_PATH=src/main.kofun
    METADATA=$WORK/$identity_label.metadata
    CATALOG=$WORK/$identity_label.catalog
    STORE=$WORK/store-$identity_label
    write_metadata "$METADATA" "$LOGICAL_PATH" source "$RESPONSE_BLOB"
    write_catalog "$METADATA" "$CATALOG" "$VERSION"
    reset_fixture
    fetch_current >"$WORK/$identity_label.out" 2>"$WORK/$identity_label.err" ||
        fail "$identity_label identity acquisition failed: $(tr '\n' ' ' <"$WORK/$identity_label.err")"
    identity_argv=$(find "$FIXTURE" -name 'argv.*')
    test "$(argv_value "$identity_argv" --url)" = \
        "https://fixture.example$identity_target$BLOB_DIGEST" ||
        fail "$identity_label identity derived the wrong blob target"
    assert_private_cleanup
}
run_identity_case root https://fixture.example/ 1.2.0 \
    /@kofun/v1/blobs/sha256/
run_identity_case major-v2 https://fixture.example/pkg/v2/ 2.3.4 \
    /pkg/v2/@kofun/v1/blobs/sha256/

ID=https://fixture.example/pkg/
VERSION=1.2.0
LOGICAL_PATH=scripts/postinstall.sh
mkdir "$WORK/hostile explicit paths"
cp "$WORK/metadata" "$WORK/hostile explicit paths/-metadata [v1]"
cp "$WORK/catalog" "$WORK/hostile explicit paths/-catalog [v1]"
cp "$WORK/authority" "$WORK/hostile explicit paths/-authority [v1]"
cp "$WORK/roots.pem" "$WORK/hostile explicit paths/-ca [v1].pem"
METADATA="$WORK/hostile explicit paths/-metadata [v1]"
CATALOG="$WORK/hostile explicit paths/-catalog [v1]"
AUTHORITY="$WORK/hostile explicit paths/-authority [v1]"
CA="$WORK/hostile explicit paths/-ca [v1].pem"
STORE="$WORK/hostile explicit paths/store with spaces"
reset_fixture
fetch_current >"$WORK/hostile-path.out" 2>"$WORK/hostile-path.err" ||
    fail "hostile explicit paths were not preserved: $(tr '\n' ' ' <"$WORK/hostile-path.err")"
test "$(transfer_count)" -eq 1 ||
    fail 'hostile explicit paths skipped or duplicated transfer'
assert_private_cleanup
AUTHORITY=$saved_authority
CA=$WORK/roots.pem

# Concurrent cold callers may all transfer, but no replacement occurs and
# each emits exactly one top-level success over the same immutable object.
METADATA=$WORK/metadata
CATALOG=$WORK/catalog
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
test "$race_failures" -eq 0 || fail "$race_failures concurrent blob fetch(es) failed"
test "$(transfer_count)" -eq 4 ||
    fail 'not every concurrent cold caller transferred once'
for race_out in "$WORK/race"/*.out; do
    test "$(wc -l <"$race_out" | tr -d ' ')" -eq 2 &&
        test "$(grep -Fc 'metadata-bound source blob admitted and independently reverified' "$race_out")" -eq 1 ||
        fail "concurrent caller leaked or duplicated success: $race_out"
    race_err=${race_out%.out}.err
    test ! -s "$race_err" || fail "concurrent caller leaked child stderr: $race_err"
done
race_entry=$(entry_for "$STORE" "$BLOB_DIGEST")
test "$(find "$STORE" -type f | wc -l | tr -d ' ')" -eq 1 &&
    test "$(sha256 "$race_entry")" = "$BLOB_DIGEST" ||
    fail 'concurrent acquisition exposed more than one exact CAS object'
test "$(find "$STORE" -type f -name '*.incoming.*' | wc -l | tr -d ' ')" -eq 0 ||
    fail 'concurrent acquisition left store admission temporaries'
test ! -e "$LIFECYCLE_MARKER" ||
    fail 'concurrent acquisition executed lifecycle-looking source bytes'
assert_private_cleanup

printf 'pm: one supplied metadata descriptor derives one pinned blob request: PASS\n'
printf 'pm: source UTF-8, opaque data, warm/corrupt, and concurrent boundaries: PASS\n'
printf 'pm: lifecycle-looking bytes are acquired into CAS and never executed: PASS\n'
