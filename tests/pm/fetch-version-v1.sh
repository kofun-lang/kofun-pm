#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
TOOL=$ROOT/scripts/fetch-version-v1.sh
PLAN_TOOL=$ROOT/scripts/metadata-v1-plan.sh
STORE_TOOL=$ROOT/scripts/store.sh
SENTINEL=$ROOT/tests/pm/curl-sentinel.sh
WORK=$(mktemp -d "${TMPDIR:-/tmp}/kofun-pm-fetch-version-test.XXXXXX")
trap 'rm -rf "$WORK"' 0 1 2 15

fail() {
    printf 'pm: FAIL: fetch-version-v1: %s\n' "$*" >&2
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

register_blob() {
    registered_blob=$1
    registered_digest=$(sha256 "$registered_blob")
    cp "$registered_blob" "$RESPONSE_DIR/$registered_digest"
    printf '%s\n' "$registered_digest"
}

write_base_metadata() {
    metadata_output=$1
    {
        printf 'kofun-metadata/v1\nidentity\t%s\nversion\t%s\n' "$ID" "$VERSION"
        printf 'file\tdata/opaque.bin\tdata\t%s\t%s\n' \
            "$OPAQUE_SIZE" "$OPAQUE_DIGEST"
        printf 'file\tscripts/postinstall.sh\tsource\t%s\t%s\n' \
            "$SCRIPT_SIZE" "$SCRIPT_DIGEST"
        printf 'file\tsrc/main.kofun\tsource\t%s\t%s\n' \
            "$MAIN_SIZE" "$MAIN_DIGEST"
    } >"$metadata_output"
}

write_catalog() {
    catalog_metadata=$1
    catalog_output=$2
    catalog_version=${3:-$VERSION}
    catalog_size=$(wc -c <"$catalog_metadata" | tr -d ' ')
    catalog_digest=$(sha256 "$catalog_metadata")
    {
        printf 'kofun-catalog/v1\n'
        printf '%s\t%s\t%s\n' "$catalog_version" "$catalog_size" \
            "$catalog_digest"
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
    mkdir -p "$FIXTURE/bodies"
    cp "$RESPONSE_METADATA" "$FIXTURE/bodies/$VERSION.meta"
    cp "$RESPONSE_DIR"/* "$FIXTURE/bodies/"
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
        npm_lifecycle_event=postinstall npm_lifecycle_script='sh scripts/postinstall.sh' \
        KPM_LIFECYCLE_MARKER="$LIFECYCLE_MARKER" \
        KPM_METADATA_IDENTITY=https://ambient.invalid/ \
        KPM_METADATA_VERSION=9.9.9 \
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
        fail "$refusal_label made $actual_transfers transfer(s), expected $refusal_transfers"
    if grep -Eq 'pinned HTTPS response verified|reused verified store object|store: (published|adopted|snapshotted)|fetch-version-v1: catalog-bound metadata and all' \
        "$WORK/refusal.out" "$WORK/refusal.err"
    then
        fail "$refusal_label leaked child or version success"
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

wrong_same_size() {
    wrong_input=$1
    wrong_output=$2
    cp "$wrong_input" "$wrong_output"
    printf X | dd of="$wrong_output" bs=1 count=1 conv=notrunc status=none
    test "$(wc -c <"$wrong_output" | tr -d ' ')" = \
        "$(wc -c <"$wrong_input" | tr -d ' ')" ||
        fail 'wrong-byte fixture changed size'
    test "$(sha256 "$wrong_output")" != "$(sha256 "$wrong_input")" ||
        fail 'wrong-byte fixture retained the expected digest'
}

BASE_PATH=$PATH
REAL_ICONV=$(command -v iconv)
FAKE_BIN=$WORK/fake-bin
FIXTURE=$FAKE_BIN/curl-fixture
TMP_ROOT=$WORK/tmp
HOSTILE_HOME=$WORK/hostile-home
HOSTILE_XDG=$WORK/hostile-xdg
HOSTILE_CURL_HOME=$WORK/hostile-curl-home
LIFECYCLE_MARKER=$WORK/lifecycle-ran
RESPONSE_DIR=$WORK/response-blobs
mkdir -p "$FAKE_BIN" "$TMP_ROOT" "$HOSTILE_HOME" "$HOSTILE_XDG" \
    "$HOSTILE_CURL_HOME" "$RESPONSE_DIR"
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
OPAQUE=$WORK/opaque.bin
SCRIPT=$WORK/postinstall.sh
MAIN=$WORK/main.kofun
printf 'test-only CA bytes\n' >"$CA"
printf 'kofun-fetch-authority/v1\norigin\thttps://fixture.example\n' >"$AUTHORITY"
printf '\377opaque-data\n' >"$OPAQUE"
{
    printf '#!/bin/sh\n'
    printf 'printf owned > "$KPM_LIFECYCLE_MARKER"\n'
} >"$SCRIPT"
chmod 755 "$SCRIPT"
printf 'fn main() Int { 0 }\n' >"$MAIN"
OPAQUE_SIZE=$(wc -c <"$OPAQUE" | tr -d ' ')
SCRIPT_SIZE=$(wc -c <"$SCRIPT" | tr -d ' ')
MAIN_SIZE=$(wc -c <"$MAIN" | tr -d ' ')
OPAQUE_DIGEST=$(register_blob "$OPAQUE")
SCRIPT_DIGEST=$(register_blob "$SCRIPT")
MAIN_DIGEST=$(register_blob "$MAIN")
write_base_metadata "$RESPONSE_METADATA"
write_catalog "$RESPONSE_METADATA" "$CATALOG"
METADATA_SIZE=$(wc -c <"$RESPONSE_METADATA" | tr -d ' ')
METADATA_DIGEST=$(sha256 "$RESPONSE_METADATA")

# The public surface has no metadata/file selector or descriptor override.
# Request grammar and exact publication membership precede network.
reset_fixture
expect_refusal 'caller metadata override' 'usage:' 0 --metadata "$RESPONSE_METADATA"
reset_fixture
expect_refusal 'caller logical-path selector' 'usage:' 0 --path src/main.kofun
reset_fixture
expect_refusal 'caller digest override' 'usage:' 0 --digest "$MAIN_DIGEST"
saved_id=$ID
ID=https://127.0.0.1/pkg/
reset_fixture
expect_refusal 'invalid identity' 'requested identity/version grammar is invalid' 0
ID=$saved_id
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

# One cold action fetches metadata first, freezes all three descriptors, then
# acquires every blob in canonical path order before one complete success.
reset_fixture
fetch_current >"$WORK/cold.out" 2>"$WORK/cold.err" ||
    fail "cold exact-version acquisition failed: $(tr '\n' ' ' <"$WORK/cold.err")"
grep -Fq 'catalog-bound metadata and all 3 file blob(s) admitted and independently reverified' \
    "$WORK/cold.out" || fail 'cold success omitted the complete file count'
grep -Fq '2 source and 1 data' "$WORK/cold.out" ||
    fail 'cold success omitted the complete kind counts'
test "$(wc -l <"$WORK/cold.out" | tr -d ' ')" -eq 2 ||
    fail 'cold success leaked child output'
test ! -s "$WORK/cold.err" ||
    fail "cold success leaked child stderr: $(tr '\n' ' ' <"$WORK/cold.err")"
test "$(transfer_count)" -eq 4 ||
    fail 'cold exact-version action did not transfer metadata plus every blob'
{
    printf '%s\n' \
        "https://fixture.example/pkg/@kofun/v1/versions/$VERSION.meta" \
        "https://fixture.example/pkg/@kofun/v1/blobs/sha256/$OPAQUE_DIGEST" \
        "https://fixture.example/pkg/@kofun/v1/blobs/sha256/$SCRIPT_DIGEST" \
        "https://fixture.example/pkg/@kofun/v1/blobs/sha256/$MAIN_DIGEST"
} >"$WORK/expected.urls"
cmp "$WORK/expected.urls" "$FIXTURE/transfer.urls" ||
    fail 'metadata/files were not requested in the one derived canonical order'
for retained_digest in "$METADATA_DIGEST" "$OPAQUE_DIGEST" \
    "$SCRIPT_DIGEST" "$MAIN_DIGEST"
do
    retained_entry=$(entry_for "$STORE" "$retained_digest")
    test -f "$retained_entry" && test ! -w "$retained_entry" &&
        test ! -x "$retained_entry" &&
        test "$(sha256 "$retained_entry")" = "$retained_digest" ||
        fail "cold action did not retain immutable non-executable CAS $retained_digest"
done
test ! -e "$LIFECYCLE_MARKER" ||
    fail 'exact-version acquisition executed lifecycle-looking source bytes'
assert_private_cleanup

# All-warm reuse performs no transfer but repeats metadata parsing, every
# descriptor visit, every outer store snapshot, and source/data validation.
reset_fixture
fetch_current >"$WORK/warm.out" 2>"$WORK/warm.err" ||
    fail "all-warm acquisition failed: $(tr '\n' ' ' <"$WORK/warm.err")"
test "$(transfer_count)" -eq 0 || fail 'all-warm exact version reached transfer'
grep -Fq 'all 3 file blob(s)' "$WORK/warm.out" ||
    fail 'all-warm success omitted completeness'
test ! -s "$WORK/warm.err" && test ! -e "$LIFECYCLE_MARKER" ||
    fail 'all-warm action leaked child stderr or executed source'
assert_private_cleanup

# A mixed store begins with metadata and one data blob. Only the two missing
# source objects transfer; completeness still covers all three descriptors.
STORE=$WORK/store-mixed
/bin/sh "$STORE_TOOL" --store "$STORE" admit "$METADATA_DIGEST" \
    "$METADATA_SIZE" "$RESPONSE_METADATA" >/dev/null
/bin/sh "$STORE_TOOL" --store "$STORE" admit "$OPAQUE_DIGEST" \
    "$OPAQUE_SIZE" "$OPAQUE" >/dev/null
reset_fixture
fetch_current >"$WORK/mixed.out" 2>"$WORK/mixed.err" ||
    fail "mixed warm/cold acquisition failed: $(tr '\n' ' ' <"$WORK/mixed.err")"
test "$(transfer_count)" -eq 2 ||
    fail 'mixed warm/cold action did not transfer only missing source blobs'
test ! -s "$WORK/mixed.err" || fail 'mixed success leaked child stderr'
assert_private_cleanup

# A shared digest at two distinct logical paths is visited twice, but the
# second visit is a verified warm reuse. No path can be omitted by the caller.
RESPONSE_METADATA=$WORK/shared-digest.metadata
{
    printf 'kofun-metadata/v1\nidentity\t%s\nversion\t%s\n' "$ID" "$VERSION"
    printf 'file\tdata/opaque.bin\tdata\t%s\t%s\n' \
        "$OPAQUE_SIZE" "$OPAQUE_DIGEST"
    printf 'file\tdocs/copy.txt\tdata\t%s\t%s\n' "$MAIN_SIZE" "$MAIN_DIGEST"
    printf 'file\tscripts/postinstall.sh\tsource\t%s\t%s\n' \
        "$SCRIPT_SIZE" "$SCRIPT_DIGEST"
    printf 'file\tsrc/main.kofun\tsource\t%s\t%s\n' "$MAIN_SIZE" "$MAIN_DIGEST"
} >"$RESPONSE_METADATA"
CATALOG=$WORK/shared-digest.catalog
write_catalog "$RESPONSE_METADATA" "$CATALOG"
STORE=$WORK/store-shared-digest
reset_fixture
fetch_current >"$WORK/shared.out" 2>"$WORK/shared.err" ||
    fail "shared-digest acquisition failed: $(tr '\n' ' ' <"$WORK/shared.err")"
test "$(transfer_count)" -eq 4 ||
    fail 'shared digest transferred twice instead of verified warm reuse'
grep -Fq 'all 4 file blob(s)' "$WORK/shared.out" ||
    fail 'shared-digest success omitted one descriptor path'
test "$(find "$STORE" -type f | wc -l | tr -d ' ')" -eq 4 ||
    fail 'shared-digest store did not converge metadata plus three unique blobs'
assert_private_cleanup

# Restore the base three-file exact version for refusal and order cases.
RESPONSE_METADATA=$WORK/metadata
CATALOG=$WORK/catalog

# Descriptor-valid but grammar-invalid metadata may remain unreferenced CAS;
# no blob begins and no version success escapes.
cp "$RESPONSE_METADATA" "$WORK/bad.metadata"
printf 'unknown\tafter-files\n' >>"$WORK/bad.metadata"
RESPONSE_METADATA=$WORK/bad.metadata
CATALOG=$WORK/bad.catalog
write_catalog "$RESPONSE_METADATA" "$CATALOG"
bad_metadata_digest=$(sha256 "$RESPONSE_METADATA")
bad_metadata_size=$(wc -c <"$RESPONSE_METADATA" | tr -d ' ')
STORE=$WORK/store-bad-metadata
reset_fixture
expect_refusal 'grammar-invalid acquired metadata' \
    'descriptor-valid metadata bytes failed strict parsing' 1
bad_entry=$(entry_for "$STORE" "$bad_metadata_digest")
test -f "$bad_entry" && test ! -w "$bad_entry" ||
    fail 'grammar-invalid metadata did not remain immutable unreferenced CAS'

# Exact parser limits accept 4,096 zero-byte descriptors and exactly 512 MiB
# without I/O; +1 is then refused by the composed action before any blob.
ZERO=0000000000000000000000000000000000000000000000000000000000000000
ID=https://fixture.example/pkg/
VERSION=1.2.0
RESPONSE_METADATA=$WORK/limit-4096.metadata
{
    printf 'kofun-metadata/v1\nidentity\t%s\nversion\t%s\n' "$ID" "$VERSION"
    n=1
    while test "$n" -le 4096; do
        printf 'file\tf%04d\tdata\t0\t%s\n' "$n" "$ZERO"
        n=$((n + 1))
    done
} >"$RESPONSE_METADATA"
limit_size=$(wc -c <"$RESPONSE_METADATA" | tr -d ' ')
limit_digest=$(sha256 "$RESPONSE_METADATA")
"$PLAN_TOOL" inspect "$ID" "$VERSION" "$RESPONSE_METADATA" \
    --size "$limit_size" --digest "$limit_digest" >"$WORK/limit-4096.plan"
test "$(LC_ALL=C awk -F '	' '$1 == "descriptor" { count++ }
    END { print count + 0 }' "$WORK/limit-4096.plan")" -eq 4096 ||
    fail 'exact 4,096-file metadata plan did not retain every descriptor'
CATALOG=$WORK/limit-4096.catalog
write_catalog "$RESPONSE_METADATA" "$CATALOG"
STORE=$WORK/store-limit-4096
reset_fixture
expect_refusal 'exact 4,096-file plan reaches its first blob' \
    'planned blob fetch failed' 2

RESPONSE_METADATA=$WORK/limit-4097.metadata
cp "$WORK/limit-4096.metadata" "$RESPONSE_METADATA"
printf 'file\tf4097\tdata\t0\t%s\n' "$ZERO" >>"$RESPONSE_METADATA"
CATALOG=$WORK/limit-4097.catalog
write_catalog "$RESPONSE_METADATA" "$CATALOG"
STORE=$WORK/store-limit-4097
reset_fixture
expect_refusal '4,097-file metadata plan' \
    'descriptor-valid metadata bytes failed strict parsing' 1

RESPONSE_METADATA=$WORK/exact-512m.metadata
{
    printf 'kofun-metadata/v1\nidentity\t%s\nversion\t%s\n' "$ID" "$VERSION"
    n=1
    while test "$n" -le 8; do
        printf 'file\tb%02d\tdata\t67108864\t%s\n' "$n" "$ZERO"
        n=$((n + 1))
    done
} >"$RESPONSE_METADATA"
limit_size=$(wc -c <"$RESPONSE_METADATA" | tr -d ' ')
limit_digest=$(sha256 "$RESPONSE_METADATA")
"$PLAN_TOOL" inspect "$ID" "$VERSION" "$RESPONSE_METADATA" \
    --size "$limit_size" --digest "$limit_digest" >"$WORK/exact-512m.plan"
test "$(LC_ALL=C awk -F '	' '$1 == "descriptor" { count++ }
    END { print count + 0 }' "$WORK/exact-512m.plan")" -eq 8 ||
    fail 'exact 512-MiB metadata plan was not accepted'
CATALOG=$WORK/exact-512m.catalog
write_catalog "$RESPONSE_METADATA" "$CATALOG"
STORE=$WORK/store-exact-512m
reset_fixture
expect_refusal 'exact 512-MiB plan reaches its first blob' \
    'planned blob fetch failed' 2

RESPONSE_METADATA=$WORK/overflow-512m.metadata
cp "$WORK/exact-512m.metadata" "$RESPONSE_METADATA"
printf 'file\tb09\tdata\t67108864\t%s\n' "$ZERO" >>"$RESPONSE_METADATA"
CATALOG=$WORK/overflow-512m.catalog
write_catalog "$RESPONSE_METADATA" "$CATALOG"
STORE=$WORK/store-overflow-512m
reset_fixture
expect_refusal 'metadata package byte overflow' \
    'descriptor-valid metadata bytes failed strict parsing' 1

# Base fixtures again. Wrong bytes at the first, middle, or last canonical
# path prove the all-files barrier and leave only earlier verified CAS.
RESPONSE_METADATA=$WORK/metadata
CATALOG=$WORK/catalog
wrong_same_size "$OPAQUE" "$WORK/wrong-opaque"
wrong_same_size "$SCRIPT" "$WORK/wrong-script"
wrong_same_size "$MAIN" "$WORK/wrong-main"
for failure_case in first middle last; do
    STORE=$WORK/store-failure-$failure_case
    reset_fixture
    case $failure_case in
        first)
            cp "$WORK/wrong-opaque" "$FIXTURE/bodies/$OPAQUE_DIGEST"
            expected_transfers=2
            ;;
        middle)
            cp "$WORK/wrong-script" "$FIXTURE/bodies/$SCRIPT_DIGEST"
            expected_transfers=3
            ;;
        last)
            cp "$WORK/wrong-main" "$FIXTURE/bodies/$MAIN_DIGEST"
            expected_transfers=4
            ;;
    esac
    expect_refusal "$failure_case blob digest failure" \
        'planned blob fetch failed' "$expected_transfers"
    test -f "$(entry_for "$STORE" "$METADATA_DIGEST")" ||
        fail "$failure_case failure lost verified metadata CAS"
done

STORE=$WORK/store-short-first
reset_fixture
head -c "$((OPAQUE_SIZE - 1))" <"$OPAQUE" \
    >"$FIXTURE/bodies/$OPAQUE_DIGEST"
expect_refusal 'short first blob' 'planned blob fetch failed' 2

# Invalid UTF-8 data already succeeded above. The same invalid bytes described
# as the middle source are admitted but cannot complete the version.
RESPONSE_METADATA=$WORK/invalid-source.metadata
{
    printf 'kofun-metadata/v1\nidentity\t%s\nversion\t%s\n' "$ID" "$VERSION"
    printf 'file\tdata/opaque.bin\tdata\t%s\t%s\n' \
        "$OPAQUE_SIZE" "$OPAQUE_DIGEST"
    printf 'file\tscripts/postinstall.sh\tsource\t%s\t%s\n' \
        "$OPAQUE_SIZE" "$OPAQUE_DIGEST"
} >"$RESPONSE_METADATA"
CATALOG=$WORK/invalid-source.catalog
write_catalog "$RESPONSE_METADATA" "$CATALOG"
STORE=$WORK/store-invalid-source
reset_fixture
expect_refusal 'invalid UTF-8 source' \
    'metadata-bound source is not valid UTF-8' 2
invalid_entry=$(entry_for "$STORE" "$OPAQUE_DIGEST")
test -f "$invalid_entry" && test ! -w "$invalid_entry" ||
    fail 'invalid source did not retain exact immutable unreferenced CAS'

# A data-only version needs no iconv capability. Give the top-level adapters a
# PATH containing every required utility except iconv and retain invalid UTF-8
# as opaque data.
RESPONSE_METADATA=$WORK/data-only.metadata
{
    printf 'kofun-metadata/v1\nidentity\t%s\nversion\t%s\n' "$ID" "$VERSION"
    printf 'file\tdata/opaque.bin\tdata\t%s\t%s\n' \
        "$OPAQUE_SIZE" "$OPAQUE_DIGEST"
} >"$RESPONSE_METADATA"
CATALOG=$WORK/data-only.catalog
write_catalog "$RESPONSE_METADATA" "$CATALOG"
STORE=$WORK/store-data-only
NO_ICONV_BIN=$WORK/no-iconv-bin
mkdir "$NO_ICONV_BIN"
for utility in awk cat chmod dirname env head mktemp od rm tail tr wc; do
    utility_path=$(command -v "$utility") ||
        fail "could not construct no-iconv PATH: missing $utility"
    ln -s "$utility_path" "$NO_ICONV_BIN/$utility"
done
saved_base_path=$BASE_PATH
BASE_PATH=$NO_ICONV_BIN
reset_fixture
fetch_current >"$WORK/data-only.out" 2>"$WORK/data-only.err" ||
    fail "data-only version required iconv: $(tr '\n' ' ' <"$WORK/data-only.err")"
BASE_PATH=$saved_base_path
test "$(transfer_count)" -eq 2 ||
    fail 'data-only version did not acquire exactly metadata plus one blob'
grep -Fq 'all 1 file blob(s)' "$WORK/data-only.out" ||
    fail 'data-only version did not expose one complete success'
assert_private_cleanup

# A corrupt warm object is neither repaired nor replaced and no network path
# is opened. Metadata and earlier blobs remain independently revalidated.
RESPONSE_METADATA=$WORK/metadata
CATALOG=$WORK/catalog
STORE=$WORK/store-corrupt-warm
reset_fixture
fetch_current >"$WORK/corrupt-prime.out" 2>"$WORK/corrupt-prime.err" ||
    fail 'could not prime corrupt-warm exact version'
corrupt_entry=$(entry_for "$STORE" "$SCRIPT_DIGEST")
corrupt_inode=$(stat -c %i "$corrupt_entry")
chmod 644 "$corrupt_entry"
printf X | dd of="$corrupt_entry" bs=1 count=1 conv=notrunc status=none
chmod 444 "$corrupt_entry"
corrupt_digest=$(sha256 "$corrupt_entry")
reset_fixture
expect_refusal 'corrupt warm middle blob' 'planned blob fetch failed' 0
test "$(stat -c %i "$corrupt_entry")" = "$corrupt_inode" &&
    test "$(sha256 "$corrupt_entry")" = "$corrupt_digest" ||
    fail 'corrupt warm blob was repaired or replaced'

# Private tool-root spies pin exact child argv and the complete order. A fake
# iconv makes source checks visible after each outer blob snapshot.
SPY_ROOT=$WORK/spy-root
mkdir -p "$SPY_ROOT/scripts"
for runtime in authority-v1-validate.awk catalog-v1-validate.awk \
    fetch-artifact-v1-validate.awk fetch-object-v1.sh fetch-version-v1.sh \
    metadata-descriptor-v1-validate.awk metadata-request-v1-validate.awk \
    metadata-v1-validate.awk protocol-v1-validate.awk
do
    cp "$ROOT/scripts/$runtime" "$SPY_ROOT/scripts/$runtime"
done
for adapter in catalog-v1-plan fetch-artifact-v1 metadata-v1-plan store; do
    cp "$ROOT/scripts/$adapter.sh" "$SPY_ROOT/scripts/$adapter-real.sh"
done
cp "$ROOT/scripts/fetch-object-v1.sh" \
    "$SPY_ROOT/scripts/fetch-object-v1-real.sh"
{
    printf '#!/bin/sh\nset -eu\nprintf "catalog\\n" >>"%s"\n' \
        "$SPY_ROOT/scripts/events"
    printf 'printf "%%s\\n" "$@" >"%s"\n' "$SPY_ROOT/scripts/catalog.args"
    printf 'exec /bin/sh "%s" "$@"\n' "$SPY_ROOT/scripts/catalog-v1-plan-real.sh"
} >"$SPY_ROOT/scripts/catalog-v1-plan.sh"
{
    printf '#!/bin/sh\nset -eu\n'
    printf 'count=0\ntest ! -f "%s" || read -r count <"%s"\n' \
        "$SPY_ROOT/scripts/object.count" "$SPY_ROOT/scripts/object.count"
    printf 'count=$((count + 1))\nprintf "%%s\\n" "$count" >"%s"\n' \
        "$SPY_ROOT/scripts/object.count"
    printf 'class=missing\nprevious=\nfor arg do\n  test "$previous" != --class || class=$arg\n  previous=$arg\ndone\n'
    printf 'printf "object-%%s\\n" "$class" >>"%s"\n' "$SPY_ROOT/scripts/events"
    printf 'printf "%%s\\n" "$@" >"%s/object.$count.args"\n' \
        "$SPY_ROOT/scripts"
    printf 'exec /bin/sh "%s" "$@"\n' "$SPY_ROOT/scripts/fetch-object-v1-real.sh"
} >"$SPY_ROOT/scripts/fetch-object-v1.sh"
{
    printf '#!/bin/sh\nset -eu\nclass=missing\nprevious=\n'
    printf 'for arg do\n  test "$previous" != --class || class=$arg\n  previous=$arg\ndone\n'
    printf 'printf "fetch-%%s\\n" "$class" >>"%s"\n' "$SPY_ROOT/scripts/events"
    printf 'exec /bin/sh "%s" "$@"\n' "$SPY_ROOT/scripts/fetch-artifact-v1-real.sh"
} >"$SPY_ROOT/scripts/fetch-artifact-v1.sh"
{
    printf '#!/bin/sh\nset -eu\nprintf "metadata-plan\\n" >>"%s"\n' \
        "$SPY_ROOT/scripts/events"
    printf 'printf "%%s\\n" "$@" >"%s"\n' "$SPY_ROOT/scripts/metadata.args"
    printf 'exec /bin/sh "%s" "$@"\n' "$SPY_ROOT/scripts/metadata-v1-plan-real.sh"
} >"$SPY_ROOT/scripts/metadata-v1-plan.sh"
{
    printf '#!/bin/sh\nset -eu\ncommand=${3:-missing}\n'
    printf 'printf "store-%%s\\n" "$command" >>"%s"\n' "$SPY_ROOT/scripts/events"
    printf 'exec /bin/sh "%s" "$@"\n' "$SPY_ROOT/scripts/store-real.sh"
} >"$SPY_ROOT/scripts/store.sh"
chmod +x "$SPY_ROOT/scripts/"*.sh
{
    printf '#!/bin/sh\nset -eu\nprintf "iconv\\n" >>"%s"\n' \
        "$SPY_ROOT/scripts/events"
    printf 'exec "%s" "$@"\n' "$REAL_ICONV"
} >"$FAKE_BIN/iconv"
chmod +x "$FAKE_BIN/iconv"
REAL_TOOL=$TOOL
TOOL=$SPY_ROOT/scripts/fetch-version-v1.sh
STORE=$WORK/store-spy
reset_fixture
fetch_current >"$WORK/spy.out" 2>"$WORK/spy.err" ||
    fail "child-order acquisition failed: $(tr '\n' ' ' <"$WORK/spy.err")"
{
    printf '%s\n' catalog object-metadata fetch-metadata store-admit \
        store-snapshot metadata-plan \
        object-blob fetch-blob store-admit store-snapshot \
        object-blob fetch-blob store-admit store-snapshot iconv \
        object-blob fetch-blob store-admit store-snapshot iconv
} >"$WORK/expected.events"
cmp "$WORK/expected.events" "$SPY_ROOT/scripts/events" ||
    fail 'children did not preserve catalog/metadata/full-file plan order'
test "$(cat "$SPY_ROOT/scripts/object.count")" -eq 4 ||
    fail 'one exact version did not invoke one metadata plus three blob objects'
{
    printf '%s\n' inspect "$ID" "$CATALOG" --authority "$AUTHORITY"
} >"$WORK/expected.catalog.args"
cmp "$WORK/expected.catalog.args" "$SPY_ROOT/scripts/catalog.args" ||
    fail 'catalog planner did not receive the exact supplied inputs'
private_ca=$(argv_value "$SPY_ROOT/scripts/object.1.args" --ca-file)
metadata_snapshot=$(argv_value "$SPY_ROOT/scripts/object.1.args" --snapshot)
test "$private_ca" != "$CA" ||
    fail 'metadata object child reopened the caller CA path'
{
    printf '%s\n' acquire --class metadata --origin https://fixture.example \
        --target "/pkg/@kofun/v1/versions/$VERSION.meta" \
        --ipv4 "$IPV4" --ca-file "$private_ca" --size "$METADATA_SIZE" \
        --digest "$METADATA_DIGEST" --store "$STORE" \
        --snapshot "$metadata_snapshot"
} >"$WORK/expected.object.args"
cmp "$WORK/expected.object.args" "$SPY_ROOT/scripts/object.1.args" ||
    fail 'metadata object child argv was incomplete, reordered, or extended'
n=2
for planned in "$OPAQUE_SIZE:$OPAQUE_DIGEST" \
    "$SCRIPT_SIZE:$SCRIPT_DIGEST" "$MAIN_SIZE:$MAIN_DIGEST"
do
    planned_size=${planned%%:*}
    planned_digest=${planned#*:}
    object_args=$SPY_ROOT/scripts/object.$n.args
    child_ca=$(argv_value "$object_args" --ca-file)
    child_snapshot=$(argv_value "$object_args" --snapshot)
    test "$child_ca" = "$private_ca" ||
        fail "blob object $n did not receive the one retained private CA"
    {
        printf '%s\n' acquire --class blob --origin https://fixture.example \
            --target "/pkg/@kofun/v1/blobs/sha256/$planned_digest" \
            --ipv4 "$IPV4" --ca-file "$private_ca" --size "$planned_size" \
            --digest "$planned_digest" --store "$STORE" \
            --snapshot "$child_snapshot"
    } >"$WORK/expected.object.args"
    cmp "$WORK/expected.object.args" "$object_args" ||
        fail "blob object $n argv was incomplete, reordered, extended, or outside canonical descriptor order"
    n=$((n + 1))
done
{
    printf '%s\n' inspect "$ID" "$VERSION" "$metadata_snapshot" \
        --size "$METADATA_SIZE" --digest "$METADATA_DIGEST"
} >"$WORK/expected.metadata.args"
cmp "$WORK/expected.metadata.args" "$SPY_ROOT/scripts/metadata.args" ||
    fail 'strict metadata parser argv did not name only the outer object snapshot and exact descriptor'
TOOL=$REAL_TOOL
rm -f "$FAKE_BIN/iconv"
assert_private_cleanup

# Authority, catalog, and original CA paths are each read once. Replacing all
# three immediately after head returns cannot change the retained version plan.
real_head=$(command -v head)
cp "$AUTHORITY" "$WORK/authority.read-once"
cp "$CATALOG" "$WORK/catalog.read-once"
cp "$CA" "$WORK/ca.read-once"
printf 'replacement CA bytes\n' >"$WORK/other-ca"
{
    printf '#!/bin/sh\nset -eu\ninput=$(readlink "/proc/$$/fd/0" 2>/dev/null || :)\n'
    printf 'printf "%%s\\n" "$input" >>"%s"\n' "$WORK/head.inputs"
    printf '"%s" "$@"\nstatus=$?\n' "$real_head"
    printf 'case "$input" in\n'
    printf '  "%s") cp "%s" "$input" ;;\n' \
        "$WORK/authority.read-once" "$WORK/unapproved.authority"
    printf '  "%s") cp "%s" "$input" ;;\n' \
        "$WORK/catalog.read-once" "$WORK/other-version.catalog"
    printf '  "%s") cp "%s" "$input" ;;\n' \
        "$WORK/ca.read-once" "$WORK/other-ca"
    printf 'esac\nexit "$status"\n'
} >"$FAKE_BIN/head"
chmod +x "$FAKE_BIN/head"
AUTHORITY=$WORK/authority.read-once
CATALOG=$WORK/catalog.read-once
CA=$WORK/ca.read-once
STORE=$WORK/store-read-once
reset_fixture
fetch_current >"$WORK/read-once.out" 2>"$WORK/read-once.err" ||
    fail "post-snapshot input swaps changed the plan: $(tr '\n' ' ' <"$WORK/read-once.err")"
for original in "$AUTHORITY" "$CATALOG" "$CA"; do
    test "$(grep -Fxc "$original" "$WORK/head.inputs")" -eq 1 ||
        fail "original input was not snapshotted exactly once: $original"
done
cmp -s "$AUTHORITY" "$WORK/unapproved.authority" &&
    cmp -s "$CATALOG" "$WORK/other-version.catalog" &&
    cmp -s "$CA" "$WORK/other-ca" ||
    fail 'a read-once input replacement did not occur'
rm -f "$FAKE_BIN/head"
AUTHORITY=$saved_authority
CATALOG=$saved_catalog
CA=$WORK/roots.pem
assert_private_cleanup

# Corruption after one blob admission but before the shared outer snapshot is
# caught without exposing metadata or earlier-file child success.
{
    printf '#!/bin/sh\nset -eu\n'
    printf 'if test "${3:-}" = admit && test "${4:-}" = "%s"; then\n' \
        "$SCRIPT_DIGEST"
    printf '  admitted=$(/bin/sh "%s" "$@") || exit $?\n' \
        "$SPY_ROOT/scripts/store-real.sh"
    printf '  store=$2\n  digest=$4\n'
    printf '  entry=$store/$(printf "%%s" "$digest" | cut -c1-2)/$(printf "%%s" "$digest" | cut -c3-)\n'
    printf '  chmod 644 "$entry"\nprintf X | /bin/dd of="$entry" bs=1 count=1 conv=notrunc status=none\nchmod 444 "$entry"\n'
    printf '  printf "%%s\\n" "$admitted"\n  exit 0\nfi\n'
    printf 'exec /bin/sh "%s" "$@"\n' "$SPY_ROOT/scripts/store-real.sh"
} >"$SPY_ROOT/scripts/store.sh"
chmod +x "$SPY_ROOT/scripts/store.sh"
TOOL=$SPY_ROOT/scripts/fetch-version-v1.sh
STORE=$WORK/store-post-admit-corrupt
reset_fixture
expect_refusal 'post-admission middle-blob corruption' \
    'admitted blob could not be reverified from the store' 3
post_entry=$(entry_for "$STORE" "$SCRIPT_DIGEST")
test -f "$post_entry" && test "$(sha256 "$post_entry")" != "$SCRIPT_DIGEST" ||
    fail 'post-admission corruption fixture did not persist'
TOOL=$REAL_TOOL

# Root and major-v2 identities preserve the exact slash boundary for metadata
# and every derived blob target.
run_identity_case() {
    identity_label=$1
    ID=$2
    VERSION=$3
    identity_prefix=$4
    RESPONSE_METADATA=$WORK/$identity_label.metadata
    CATALOG=$WORK/$identity_label.catalog
    STORE=$WORK/store-$identity_label
    {
        printf 'kofun-metadata/v1\nidentity\t%s\nversion\t%s\n' "$ID" "$VERSION"
        printf 'file\tsrc/main.kofun\tsource\t%s\t%s\n' "$MAIN_SIZE" "$MAIN_DIGEST"
    } >"$RESPONSE_METADATA"
    write_catalog "$RESPONSE_METADATA" "$CATALOG" "$VERSION"
    reset_fixture
    fetch_current >"$WORK/$identity_label.out" 2>"$WORK/$identity_label.err" ||
        fail "$identity_label acquisition failed: $(tr '\n' ' ' <"$WORK/$identity_label.err")"
    {
        printf '%s\n' \
            "https://fixture.example${identity_prefix}@kofun/v1/versions/$VERSION.meta" \
            "https://fixture.example${identity_prefix}@kofun/v1/blobs/sha256/$MAIN_DIGEST"
    } >"$WORK/$identity_label.expected.urls"
    cmp "$WORK/$identity_label.expected.urls" "$FIXTURE/transfer.urls" ||
        fail "$identity_label derived a wrong metadata or blob target"
    assert_private_cleanup
}
run_identity_case root https://fixture.example/ 1.2.0 /
run_identity_case major-v2 https://fixture.example/pkg/v2/ 2.3.4 /pkg/v2/

# Hostile literal explicit pathnames and ambient state cannot add an input or
# skip any file in the complete plan.
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
fetch_current >"$WORK/hostile.out" 2>"$WORK/hostile.err" ||
    fail "hostile explicit paths failed: $(tr '\n' ' ' <"$WORK/hostile.err")"
test "$(transfer_count)" -eq 4 ||
    fail 'hostile paths skipped or duplicated a planned request'
assert_private_cleanup
AUTHORITY=$saved_authority
CATALOG=$saved_catalog
CA=$WORK/roots.pem

# Concurrent complete callers may race through transfers, but each validates
# one full plan and all converge on metadata plus three exact CAS objects.
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
test "$race_failures" -eq 0 ||
    fail "$race_failures concurrent exact-version acquisition(s) failed"
race_transfers=$(transfer_count)
test "$race_transfers" -ge 4 && test "$race_transfers" -le 16 ||
    fail "concurrent transfer count escaped bounded cold/warm range: $race_transfers"
for race_out in "$WORK/race"/*.out; do
    test "$(wc -l <"$race_out" | tr -d ' ')" -eq 2 &&
        test "$(grep -Fc 'catalog-bound metadata and all 3 file blob(s)' "$race_out")" -eq 1 ||
        fail "concurrent caller leaked or omitted version success: $race_out"
    race_err=${race_out%.out}.err
    test ! -s "$race_err" || fail "concurrent caller leaked stderr: $race_err"
done
test "$(find "$STORE" -type f | wc -l | tr -d ' ')" -eq 4 ||
    fail 'concurrent exact-version acquisition exposed a wrong CAS set'
test "$(find "$STORE" -type f -name '*.incoming.*' | wc -l | tr -d ' ')" -eq 0 ||
    fail 'concurrent exact-version acquisition left store temporaries'
test ! -e "$LIFECYCLE_MARKER" ||
    fail 'concurrent acquisition executed lifecycle-looking source bytes'
assert_private_cleanup

printf 'pm: one supplied catalog plan acquires metadata and every declared blob: PASS\n'
printf 'pm: complete file-set order, bounds, warm/mixed/refusal/concurrent barriers: PASS\n'
printf 'pm: source/data validation and lifecycle-looking bytes remain inert: PASS\n'
