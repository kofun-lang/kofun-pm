#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
TOOL=$ROOT/scripts/fetch-artifact-v1.sh
STORE_TOOL=$ROOT/scripts/store.sh
SENTINEL=$ROOT/tests/pm/curl-sentinel.sh
STORE_SENTINEL=$ROOT/tests/pm/store-sentinel.sh
WORK=$(mktemp -d "${TMPDIR:-/tmp}/kofun-pm-fetch-artifact-test.XXXXXX")
trap 'rm -rf "$WORK"' 0 1 2 15

fail() {
    printf 'pm: FAIL: fetch-artifact-v1: %s\n' "$*" >&2
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
    : >"$FIXTURE/body"
}

assert_no_object() {
    absent_store=$1
    absent_digest=$2
    test ! -e "$(entry_for "$absent_store" "$absent_digest")" ||
        fail "a refused fetch exposed trusted object $absent_digest"
    if test -d "$absent_store"; then
        incoming=$(find "$absent_store" -type f -name '*.incoming.*' |
            wc -l | tr -d ' ')
        test "$incoming" -eq 0 ||
            fail "a refused fetch left $incoming store admission temporary file(s)"
    fi
}

assert_private_cleanup() {
    leftovers=$(find "$TMP_ROOT" -mindepth 1 | wc -l | tr -d ' ')
    test "$leftovers" -eq 0 ||
        fail "fetch left $leftovers private work path(s) under TMPDIR"
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
reset_fixture

test -x "$TOOL" || fail "missing executable $TOOL"
test -x "$STORE_TOOL" || fail "missing executable $STORE_TOOL"
test -x "$SENTINEL" || fail "missing executable $SENTINEL"
test -x "$STORE_SENTINEL" || fail "missing executable $STORE_SENTINEL"

CA=$WORK/roots.pem
printf '%s\n' 'test-only CA bytes; the curl double does not prove TLS' >"$CA"
printf 'immutable artifact bytes\n' >"$WORK/artifact"
ARTIFACT_SIZE=$(wc -c <"$WORK/artifact" | tr -d ' ')
ARTIFACT_DIGEST=$(sha256 "$WORK/artifact")
ZERO_DIGEST=$(sha256 /dev/null)
ORIGIN=https://fixture.example
IPV4=93.184.216.34
CLASS=blob
TARGET=/objects/$ARTIFACT_DIGEST
BYTES=$ARTIFACT_SIZE
DIGEST=$ARTIFACT_DIGEST
STORE=$WORK/store-default
CA_INPUT=$CA

# Deliberately hostile ambient values.  Only the outer test command receives
# these; curl-sentinel records the production curl subprocess environment.
fetch_current() {
    env -i PATH="$FAKE_BIN:$BASE_PATH" TMPDIR="$TMP_ROOT" LC_ALL=ja_JP.UTF-8 \
        HOME="$HOSTILE_HOME" XDG_CONFIG_HOME="$HOSTILE_XDG" \
        CURL_HOME="$HOSTILE_CURL_HOME" \
        http_proxy=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9 \
        HTTP_PROXY=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 \
        ALL_PROXY=socks5://127.0.0.1:9 NO_PROXY=fixture.example \
        SSL_CERT_FILE="$WORK/ambient-ca.pem" \
        SSL_CERT_DIR="$WORK/ambient-ca-dir" \
        SSLKEYLOGFILE="$WORK/ssl-key-log" QLOGDIR="$WORK/qlog" \
        OPENSSL_CONF="$WORK/openssl.cnf" NETRC="$WORK/netrc" \
        "$TOOL" \
        --class "$CLASS" --origin "$ORIGIN" --target "$TARGET" \
        --ipv4 "$IPV4" --ca-file "$CA_INPUT" --size "$BYTES" \
        --digest "$DIGEST" --store "$STORE" "$@"
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
    if grep -Eq 'reused verified|verified and admitted' \
        "$WORK/refusal.out" "$WORK/refusal.err"
    then
        fail "$refusal_label emitted a success sentinel"
    fi
    assert_private_cleanup
}

seed_store() {
    seed_store_path=$1
    seed_file=$2
    seed_digest=$(sha256 "$seed_file")
    seed_size=$(wc -c <"$seed_file" | tr -d ' ')
    env -i PATH=/usr/bin:/bin LC_ALL=C /bin/sh "$STORE_TOOL" \
        --store "$seed_store_path" admit "$seed_digest" "$seed_size" \
        "$seed_file" >"$WORK/seed.out" 2>"$WORK/seed.err" ||
        fail "could not seed store $seed_store_path"
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

assert_argv_value() {
    argv_file=$1
    argv_option=$2
    argv_expected=$3
    argv_actual=$(argv_value "$argv_file" "$argv_option") ||
        fail "curl argv omitted $argv_option"
    test "$argv_actual" = "$argv_expected" ||
        fail "curl argv gave $argv_option '$argv_actual', expected '$argv_expected'"
}

# Option/scalar/store/tool/CA precedence.  A curl version probe is local tool
# qualification; transfer.calls is the network-reachability sentinel.
reset_fixture
expect_refusal 'unknown option' 'usage:' 0 --unknown value

reset_fixture
saved_class=$CLASS
saved_ca=$CA_INPUT
CLASS=package
CA_INPUT=$WORK/missing-ca
expect_refusal 'scalar before missing CA' \
    'class is not exactly metadata or blob' 0
CLASS=$saved_class
CA_INPUT=$saved_ca

reset_fixture
saved_store=$STORE
saved_ca=$CA_INPUT
STORE=relative-store
CA_INPUT=$WORK/missing-ca
expect_refusal 'store boundary before missing CA' \
    '--store must be an absolute path' 0
STORE=$saved_store
CA_INPUT=$saved_ca

reset_fixture
saved_store=$STORE
STORE="$WORK/store-control
"
expect_refusal 'control byte in store authority' \
    '--store path contains a control byte' 0
test ! -e "$STORE" && test ! -L "$STORE" ||
    fail 'control-byte store authority mutated the exact refused path'
test ! -e "$WORK/store-control" ||
    fail 'control-byte store authority mutated its stripped sibling path'
STORE=$saved_store

reset_fixture
saved_store=$STORE
cr=$(printf '\r')
STORE=$WORK/store-control-cr$cr
expect_refusal 'CR in store authority' \
    '--store path contains a control byte' 0
test ! -e "$STORE" && test ! -L "$STORE" ||
    fail 'CR store authority mutated the exact refused path'
test ! -e "$WORK/store-control-cr" ||
    fail 'CR store authority mutated its control-stripped sibling path'
STORE=$saved_store

reset_fixture
saved_store=$STORE
control_tab=$(printf '\t')
STORE=$WORK/store-control-tab$control_tab
expect_refusal 'tab in store authority' \
    '--store path contains a control byte' 0
test ! -e "$STORE" && test ! -L "$STORE" ||
    fail 'tab store authority mutated the exact refused path'
test ! -e "$WORK/store-control-tab" ||
    fail 'tab store authority mutated its control-stripped sibling path'
STORE=$saved_store

reset_fixture
saved_store=$STORE
printf 'not a store directory\n' >"$WORK/store-file"
STORE=$WORK/store-file
expect_refusal 'existing file as store boundary' \
    'store entry is below a non-directory or symlink path' 0
STORE=$saved_store

reset_fixture
saved_store=$STORE
printf 'not a parent directory\n' >"$WORK/store-parent-file"
STORE=$WORK/store-parent-file/child
expect_refusal 'non-directory store ancestor' \
    'store entry is below a non-directory or symlink path' 0
STORE=$saved_store

reset_fixture
saved_store=$STORE
STORE=$WORK/store-shard-file
mkdir "$STORE"
printf 'not a digest shard\n' >"$STORE/$(printf '%s' "$DIGEST" | cut -c1-2)"
expect_refusal 'non-directory digest shard' \
    'store entry is below a non-directory or symlink path' 0
STORE=$saved_store

reset_fixture
saved_store=$STORE
STORE=$WORK/store-shard-symlink
outside_store=$WORK/store-shard-outside
mkdir "$STORE" "$outside_store"
ln -s "$outside_store" "$STORE/$(printf '%s' "$DIGEST" | cut -c1-2)"
expect_refusal 'symlink digest shard' \
    'store entry is below a non-directory or symlink path' 0
test "$(find "$outside_store" -mindepth 1 | wc -l | tr -d ' ')" -eq 0 ||
    fail 'symlink digest shard wrote outside the explicit store boundary'
STORE=$saved_store

reset_fixture
printf '8.3.0\n' >"$FIXTURE/version"
saved_ca=$CA_INPUT
CA_INPUT=$WORK/missing-ca
expect_refusal 'curl version before missing CA' \
    'curl and linked libcurl 8.4.0 or newer with HTTPS/SSL support are required' 0
CA_INPUT=$saved_ca

reset_fixture
printf '8.3.0\n' >"$FIXTURE/libcurl-version"
expect_refusal 'linked libcurl version before transfer' \
    'curl and linked libcurl 8.4.0 or newer with HTTPS/SSL support are required' 0

reset_fixture
printf 'http\n' >"$FIXTURE/protocols"
expect_refusal 'curl HTTPS support before transfer' \
    'curl and linked libcurl 8.4.0 or newer with HTTPS/SSL support are required' 0

reset_fixture
printf 'AsynchDNS\n' >"$FIXTURE/features"
expect_refusal 'curl SSL support before transfer' \
    'curl and linked libcurl 8.4.0 or newer with HTTPS/SSL support are required' 0

reset_fixture
saved_class=$CLASS
saved_bytes=$BYTES
CLASS=metadata
BYTES=1048577
expect_refusal 'metadata class cap before transfer' \
    'metadata byte size exceeds its bound' 0
CLASS=$saved_class
BYTES=$saved_bytes

# CA qualification precedes even a valid warm hit.  Neither symlink nor
# oversized CA input may be bypassed because the object happens to be cached.
WARM_STORE=$WORK/store-warm
seed_store "$WARM_STORE" "$WORK/artifact"
STORE=$WARM_STORE
ln -s "$CA" "$WORK/roots.link"
CA_INPUT=$WORK/roots.link
reset_fixture
expect_refusal 'CA symlink before warm-store reuse' \
    'CA input is not a regular non-symlink file' 0

head -c 1048577 /dev/zero >"$WORK/roots.large"
CA_INPUT=$WORK/roots.large
reset_fixture
expect_refusal 'CA byte cap before warm-store reuse' \
    'CA snapshot exceeds the 1048576-byte input bound' 0

# A valid warm hit is snapshotted/rehashed through store.sh and performs no
# transfer.  The store inode and bytes remain unchanged.
CA_INPUT=$CA
reset_fixture
warm_entry=$(entry_for "$WARM_STORE" "$ARTIFACT_DIGEST")
warm_before=$(stat -c '%d %i %h %a %s' "$warm_entry")
fetch_current >"$WORK/warm.out" 2>"$WORK/warm.err" ||
    fail "valid warm hit failed: $(tr '\n' ' ' <"$WORK/warm.err")"
grep -Fq 'reused verified store object without network' "$WORK/warm.out" ||
    fail 'warm hit did not emit its post-verification success sentinel'
test "$(transfer_count)" -eq 0 || fail 'warm hit reached curl transfer'
test "$(stat -c '%d %i %h %a %s' "$warm_entry")" = "$warm_before" ||
    fail 'warm hit mutated the trusted store entry'
test "$(sha256 "$warm_entry")" = "$ARTIFACT_DIGEST" ||
    fail 'warm hit changed the trusted bytes'
assert_private_cleanup

# A valid warm entry is read-only input. Reuse must not demand mutation
# permission merely because a later cold miss would need it.
chmod 555 "$WARM_STORE" "$(dirname -- "$warm_entry")"
warm_readonly_before=$(find "$WARM_STORE" -printf '%P\t%y\t%m\t%i\t%s\n' |
    LC_ALL=C sort)
warm_readonly_digest_before=$(sha256 "$warm_entry")
reset_fixture
fetch_current >"$WORK/warm-readonly.out" 2>"$WORK/warm-readonly.err" ||
    fail "read-only warm hit failed: $(tr '\n' ' ' <"$WORK/warm-readonly.err")"
grep -Fq 'reused verified store object without network' "$WORK/warm-readonly.out" ||
    fail 'read-only warm hit did not emit its verified reuse sentinel'
test "$(transfer_count)" -eq 0 || fail 'read-only warm hit reached curl transfer'
warm_readonly_after=$(find "$WARM_STORE" -printf '%P\t%y\t%m\t%i\t%s\n' |
    LC_ALL=C sort)
test "$warm_readonly_after" = "$warm_readonly_before" ||
    fail 'read-only warm reuse changed store paths, modes, inodes, or sizes'
test "$(sha256 "$warm_entry")" = "$warm_readonly_digest_before" ||
    fail 'read-only warm reuse changed the verified entry bytes'
chmod 755 "$WARM_STORE" "$(dirname -- "$warm_entry")"
assert_private_cleanup

# A digest-shaped corrupt warm object wins precedence over every configured
# network success and is neither replaced nor refetched.
CORRUPT_STORE=$WORK/store-corrupt-warm
corrupt_entry=$(entry_for "$CORRUPT_STORE" "$ARTIFACT_DIGEST")
mkdir -p "$(dirname -- "$corrupt_entry")"
head -c "$ARTIFACT_SIZE" /dev/zero >"$corrupt_entry"
chmod 444 "$corrupt_entry"
corrupt_before=$(stat -c '%d %i %h %a %s' "$corrupt_entry")
STORE=$CORRUPT_STORE
reset_fixture
cp "$WORK/artifact" "$FIXTURE/body"
expect_refusal 'corrupt warm-store object' \
    'store entry changed while snapshotting' 0
test "$(stat -c '%d %i %h %a %s' "$corrupt_entry")" = "$corrupt_before" ||
    fail 'corrupt warm refusal replaced its inode or mode'
test "$(sha256 "$corrupt_entry")" != "$ARTIFACT_DIGEST" ||
    fail 'corrupt warm refusal repaired bytes instead of refusing loudly'

# One cold success is the argv/environment fixture.  The sentinel demonstrates
# profile confinement and response handling, not real certificate validation.
COLD_STORE=$WORK/store-cold
STORE=$COLD_STORE
reset_fixture
cp "$WORK/artifact" "$FIXTURE/body"
fetch_current >"$WORK/cold.out" 2>"$WORK/cold.err" ||
    fail "cold qualification failed: $(tr '\n' ' ' <"$WORK/cold.err")"
grep -Fq 'pinned HTTPS response verified and admitted' "$WORK/cold.out" ||
    fail 'cold success was not emitted after store admission'
grep -Fq 'exact HTTP header/Content-Length bounds' "$WORK/cold.out" ||
    fail 'success output omitted the deliberately unproved HTTP-bound claim'
test "$(transfer_count)" -eq 1 || fail 'cold success did not make one transfer'
cold_entry=$(entry_for "$COLD_STORE" "$ARTIFACT_DIGEST")
test -f "$cold_entry" && test ! -L "$cold_entry" ||
    fail 'cold success did not create one regular store entry'
test ! -w "$cold_entry" || fail 'cold success left a writable store entry'
test "$(sha256 "$cold_entry")" = "$ARTIFACT_DIGEST" ||
    fail 'cold success store entry does not hash to its name'
test "$(find "$COLD_STORE" -type f | wc -l | tr -d ' ')" -eq 1 ||
    fail 'one cold artifact produced more than one store file'

argv_logs=$(find "$FIXTURE" -type f -name 'argv.*' | wc -l | tr -d ' ')
env_logs=$(find "$FIXTURE" -type f -name 'env.*' | wc -l | tr -d ' ')
test "$argv_logs" -eq 1 && test "$env_logs" -eq 1 ||
    fail "one transfer produced $argv_logs argv and $env_logs env records"
ARGV=$(find "$FIXTURE" -type f -name 'argv.*')
ENV_LOG=$(find "$FIXTURE" -type f -name 'env.*')
test "$(sed -n '1p' "$ARGV")" = -q ||
    fail 'curl config disable was not the first transfer argument'
for required_flag in --globoff --silent --show-error --http1.1 --tlsv1.2 \
    --ipv4 --no-netrc
do
    grep -Fxq -- "$required_flag" "$ARGV" ||
        fail "fixed curl profile omitted $required_flag"
done
assert_argv_value "$ARGV" --request GET
assert_argv_value "$ARGV" --proto '=https'
assert_argv_value "$ARGV" --resolve "fixture.example:443:$IPV4"
assert_argv_value "$ARGV" --proxy '<EMPTY>'
assert_argv_value "$ARGV" --noproxy '*'
assert_argv_value "$ARGV" --retry 0
assert_argv_value "$ARGV" --max-redirs 0
assert_argv_value "$ARGV" --max-filesize "$ARTIFACT_SIZE"
assert_argv_value "$ARGV" --connect-timeout 10
assert_argv_value "$ARGV" --speed-limit 1
assert_argv_value "$ARGV" --speed-time 30
assert_argv_value "$ARGV" --max-time 600
assert_argv_value "$ARGV" --header 'Accept-Encoding: identity'
assert_argv_value "$ARGV" --url "$ORIGIN$TARGET"
grep -Eq '^(-L|--location|--insecure|--compressed|--netrc|--user|--cert|--cookie)$' \
    "$ARGV" && fail 'fixed curl profile enabled forbidden ambient/redirect behavior'

snapshot_arg=$(argv_value "$ARGV" --cacert) || fail 'curl omitted --cacert'
test "$snapshot_arg" != "$CA" || fail 'curl consumed mutable CA pathname directly'
test ! -e "$snapshot_arg" || fail 'private CA snapshot survived command cleanup'
observed_ca=$(find "$FIXTURE" -type f -name 'observed-ca.*')
cmp "$CA" "$observed_ca" || fail 'curl did not receive the one bounded CA snapshot'
capath_arg=$(argv_value "$ARGV" --capath) || fail 'curl omitted explicit empty --capath'
test ! -e "$capath_arg" || fail 'private empty capath survived command cleanup'
header_arg=$(argv_value "$ARGV" --dump-header) ||
    fail 'curl omitted its private complete-header snapshot'
test ! -e "$header_arg" || fail 'private response headers survived command cleanup'

for forbidden_env in http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY \
    NO_PROXY CURL_HOME SSL_CERT_FILE SSL_CERT_DIR SSLKEYLOGFILE QLOGDIR \
    OPENSSL_CONF NETRC
do
    if grep -Eq "^${forbidden_env}=" "$ENV_LOG"; then
        fail "curl inherited hostile $forbidden_env"
    fi
done
grep -Fq "HOME=$HOSTILE_HOME" "$ENV_LOG" &&
    fail 'curl inherited hostile HOME'
grep -Fq "XDG_CONFIG_HOME=$HOSTILE_XDG" "$ENV_LOG" &&
    fail 'curl inherited hostile XDG_CONFIG_HOME'
test ! -e "$WORK/ssl-key-log" && test ! -e "$WORK/qlog" ||
    fail 'hostile TLS/QUIC logging state was created'
assert_private_cleanup

# Protocol gates precede body qualification.  Each response is deliberately
# short as well; the named protocol failure must win and no digest/store work
# may become visible.
protocol_refusal() {
    protocol_label=$1
    protocol_key=$2
    protocol_value=$3
    protocol_needle=$4
    STORE=$WORK/store-protocol-$protocol_key
    reset_fixture
    printf x >"$FIXTURE/body"
    printf '%s\n' "$protocol_value" >"$FIXTURE/$protocol_key"
    expect_refusal "$protocol_label" "$protocol_needle" 1
    assert_no_object "$STORE" "$ARTIFACT_DIGEST"
}
protocol_refusal 'non-HTTPS final scheme before size' scheme http \
    'curl final scheme was not HTTPS'
protocol_refusal 'peer mismatch before size' peer 203.0.113.8 \
    'connected peer does not match'
protocol_refusal 'non-200 status before size' status 404 \
    'HTTPS response status is not 200'
protocol_refusal 'reported redirect before size' redirects 1 \
    'curl followed a redirect'
protocol_refusal 'content encoding before size' encoding gzip \
    'Content-Encoding is not absent or identity'

# curl's %header{name} exposes only one matching field.  The production gate
# must inspect the complete private header snapshot and reject a second coding
# even when the first field says identity.
STORE=$WORK/store-duplicate-encoding
reset_fixture
printf x >"$FIXTURE/body"
printf 'HTTP/1.1 200 test fixture\r\nContent-Encoding: identity\r\nContent-Encoding: gzip\r\n\r\n' \
    >"$FIXTURE/headers"
expect_refusal 'duplicate content encoding before size' \
    'Content-Encoding is not absent or identity' 1
assert_no_object "$STORE" "$ARTIFACT_DIGEST"

STORE=$WORK/store-duplicate-identity-encoding
reset_fixture
printf x >"$FIXTURE/body"
printf 'HTTP/1.1 200 test fixture\r\nContent-Encoding: identity\r\nContent-Encoding: identity\r\n\r\n' \
    >"$FIXTURE/headers"
expect_refusal 'duplicate identity content encoding before size' \
    'Content-Encoding is not absent or identity' 1
assert_no_object "$STORE" "$ARTIFACT_DIGEST"

# Body size precedes digest; exact size precedes the digest mismatch; curl
# errors and over-limit bodies never reach either post-response success gate.
STORE=$WORK/store-short
reset_fixture
printf x >"$FIXTURE/body"
expect_refusal 'short body before digest' \
    'response size does not match its supplied descriptor' 1
grep -Fq 'actual digest not computed' "$WORK/refusal.err" ||
    fail 'short body refusal did not state size-before-digest precedence'
assert_no_object "$STORE" "$ARTIFACT_DIGEST"

STORE=$WORK/store-wrong-digest
reset_fixture
cp "$WORK/artifact" "$FIXTURE/body"
DIGEST=0000000000000000000000000000000000000000000000000000000000000000
TARGET=/objects/$DIGEST
expect_refusal 'wrong digest after exact size' \
    'response digest does not match its supplied descriptor' 1
assert_no_object "$STORE" "$DIGEST"
DIGEST=$ARTIFACT_DIGEST
TARGET=/objects/$DIGEST

STORE=$WORK/store-timeout
reset_fixture
cp "$WORK/artifact" "$FIXTURE/body"
printf '28\n' >"$FIXTURE/exit"
expect_refusal 'curl timeout/error before response gates' \
    'pinned HTTPS GET failed' 1
assert_no_object "$STORE" "$ARTIFACT_DIGEST"

STORE=$WORK/store-ca-failure
reset_fixture
cp "$WORK/artifact" "$FIXTURE/body"
printf '60\n' >"$FIXTURE/exit"
expect_refusal 'curl CA/issuer verification failure' \
    'pinned HTTPS GET failed' 1
assert_no_object "$STORE" "$ARTIFACT_DIGEST"

STORE=$WORK/store-hostname-failure
reset_fixture
cp "$WORK/artifact" "$FIXTURE/body"
printf '51\n' >"$FIXTURE/exit"
expect_refusal 'curl certificate hostname verification failure' \
    'pinned HTTPS GET failed' 1
assert_no_object "$STORE" "$ARTIFACT_DIGEST"

# A private tool-root copy replaces only store.sh with an observable wrapper.
# Size/digest/transport failures must not reach admission; one exact success
# must reach it exactly once and only after all response gates.
PROBE_ROOT=$WORK/store-sentinel-root
mkdir -p "$PROBE_ROOT/scripts"
cp "$TOOL" "$PROBE_ROOT/scripts/fetch-artifact-v1.sh"
cp "$ROOT/scripts/fetch-artifact-v1-validate.awk" \
    "$PROBE_ROOT/scripts/fetch-artifact-v1-validate.awk"
cp "$ROOT/scripts/protocol-v1-validate.awk" \
    "$PROBE_ROOT/scripts/protocol-v1-validate.awk"
cp "$STORE_TOOL" "$PROBE_ROOT/scripts/store-real.sh"
cp "$STORE_SENTINEL" "$PROBE_ROOT/scripts/store.sh"
chmod +x "$PROBE_ROOT/scripts/fetch-artifact-v1.sh" \
    "$PROBE_ROOT/scripts/store.sh" "$PROBE_ROOT/scripts/store-real.sh"
REAL_TOOL=$TOOL
TOOL=$PROBE_ROOT/scripts/fetch-artifact-v1.sh
STORE_CALLS=$PROBE_ROOT/scripts/store.calls

probe_gate_before_store() {
    probe_label=$1
    probe_key=$2
    probe_value=$3
    probe_needle=$4
    STORE=$WORK/store-admission-$probe_key
    reset_fixture
    cp "$WORK/artifact" "$FIXTURE/body"
    printf '%s\n' "$probe_value" >"$FIXTURE/$probe_key"
    rm -f "$STORE_CALLS"
    expect_refusal "$probe_label" "$probe_needle" 1
    test ! -e "$STORE_CALLS" ||
        fail "$probe_label reached store admission"
    assert_no_object "$STORE" "$ARTIFACT_DIGEST"
}

probe_gate_before_store 'scheme before store sentinel' scheme http \
    'curl final scheme was not HTTPS'
probe_gate_before_store 'peer before store sentinel' peer 203.0.113.8 \
    'connected peer does not match'
probe_gate_before_store 'status before store sentinel' status 404 \
    'HTTPS response status is not 200'
probe_gate_before_store 'redirect before store sentinel' redirects 1 \
    'curl followed a redirect'
probe_gate_before_store 'encoding before store sentinel' encoding gzip \
    'Content-Encoding is not absent or identity'
probe_gate_before_store 'CA failure before store sentinel' exit 60 \
    'pinned HTTPS GET failed'
probe_gate_before_store 'hostname failure before store sentinel' exit 51 \
    'pinned HTTPS GET failed'
probe_gate_before_store 'TLS handshake before store sentinel' exit 35 \
    'pinned HTTPS GET failed'

STORE=$WORK/store-admission-duplicate-encoding
reset_fixture
cp "$WORK/artifact" "$FIXTURE/body"
printf 'HTTP/1.1 200 test fixture\r\nContent-Encoding: identity\r\nContent-Encoding: identity\r\n\r\n' \
    >"$FIXTURE/headers"
rm -f "$STORE_CALLS"
expect_refusal 'duplicate encoding before store sentinel' \
    'Content-Encoding is not absent or identity' 1
test ! -e "$STORE_CALLS" ||
    fail 'duplicate encoding reached store admission'
assert_no_object "$STORE" "$ARTIFACT_DIGEST"

STORE=$WORK/store-admission-short
reset_fixture
printf x >"$FIXTURE/body"
rm -f "$STORE_CALLS"
expect_refusal 'short response before store sentinel' \
    'response size does not match its supplied descriptor' 1
test ! -e "$STORE_CALLS" || fail 'short response reached store admission'

STORE=$WORK/store-admission-digest
reset_fixture
cp "$WORK/artifact" "$FIXTURE/body"
rm -f "$STORE_CALLS"
DIGEST=0000000000000000000000000000000000000000000000000000000000000000
TARGET=/objects/$DIGEST
expect_refusal 'wrong digest before store sentinel' \
    'response digest does not match its supplied descriptor' 1
test ! -e "$STORE_CALLS" || fail 'wrong digest reached store admission'
DIGEST=$ARTIFACT_DIGEST
TARGET=/objects/$DIGEST

STORE=$WORK/store-admission-success
reset_fixture
cp "$WORK/artifact" "$FIXTURE/body"
rm -f "$STORE_CALLS"
fetch_current >"$WORK/store-sentinel-success.out" \
    2>"$WORK/store-sentinel-success.err" ||
    fail "store sentinel success failed: $(tr '\n' ' ' <"$WORK/store-sentinel-success.err")"
test "$(wc -l <"$STORE_CALLS" | tr -d ' ')" -eq 1 &&
    grep -Fq ' admit ' "$STORE_CALLS" ||
    fail 'exact verified success did not reach one store admit call'
TOOL=$REAL_TOOL

STORE=$WORK/store-long
reset_fixture
{
    sed -n '1,$p' "$WORK/artifact"
    printf x
} >"$FIXTURE/body"
expect_refusal 'over-limit body at curl guard' 'pinned HTTPS GET failed' 1
assert_argv_value "$(find "$FIXTURE" -name 'argv.*')" \
    --max-filesize "$ARTIFACT_SIZE"
assert_no_object "$STORE" "$ARTIFACT_DIGEST"

# Zero bytes retain a positive curl transfer limit, followed by an exact zero
# post-check.  A one-byte body must therefore be refused without ever using
# curl's dangerous "--max-filesize 0 means unlimited" spelling.
CLASS=blob
BYTES=0
DIGEST=$ZERO_DIGEST
TARGET=/objects/$ZERO_DIGEST
STORE=$WORK/store-zero
reset_fixture
fetch_current >"$WORK/zero.out" 2>"$WORK/zero.err" ||
    fail "zero-byte object failed: $(tr '\n' ' ' <"$WORK/zero.err")"
ZERO_ARGV=$(find "$FIXTURE" -name 'argv.*')
assert_argv_value "$ZERO_ARGV" --max-filesize 1
test ! -e "$FIXTURE/max-filesize-zero.called" ||
    fail 'zero-byte object disabled curl max-filesize'
zero_entry=$(entry_for "$STORE" "$ZERO_DIGEST")
test -f "$zero_entry" && test "$(wc -c <"$zero_entry" | tr -d ' ')" -eq 0 ||
    fail 'zero-byte success did not admit an empty object'

STORE=$WORK/store-zero-one-byte
reset_fixture
printf x >"$FIXTURE/body"
expect_refusal 'one-byte response for zero descriptor' \
    'response size does not match its supplied descriptor' 1
assert_argv_value "$(find "$FIXTURE" -name 'argv.*')" --max-filesize 1
test ! -e "$FIXTURE/max-filesize-zero.called" ||
    fail 'zero-byte refusal passed --max-filesize 0'
assert_no_object "$STORE" "$ZERO_DIGEST"

CLASS=blob
BYTES=$ARTIFACT_SIZE
DIGEST=$ARTIFACT_DIGEST
TARGET=/objects/$ARTIFACT_DIGEST

# A corrupt object installed after the warm-miss check but before admission is
# a corrupt concurrent winner.  The verified download must not replace it.
STORE=$WORK/store-corrupt-winner
reset_fixture
cp "$WORK/artifact" "$FIXTURE/body"
: >"$FIXTURE/block-until-release"
fetch_current >"$WORK/corrupt-winner.out" \
    2>"$WORK/corrupt-winner.err" &
corrupt_pid=$!
attempt=0
while ! test -f "$FIXTURE/block.ready"; do
    attempt=$((attempt + 1))
    test "$attempt" -lt 50 || {
        kill -TERM "$corrupt_pid" 2>/dev/null || :
        wait "$corrupt_pid" 2>/dev/null || :
        fail 'curl sentinel never reached corrupt-winner insertion point'
    }
    sleep 0.1
done
corrupt_winner=$(entry_for "$STORE" "$ARTIFACT_DIGEST")
mkdir -p "$(dirname -- "$corrupt_winner")"
head -c "$ARTIFACT_SIZE" /dev/zero >"$corrupt_winner"
chmod 444 "$corrupt_winner"
corrupt_winner_inode=$(stat -c %i "$corrupt_winner")
: >"$FIXTURE/block.release"
if wait "$corrupt_pid"; then
    fail 'fetch replaced or accepted a corrupt concurrent winner'
fi
grep -Fq 'store: CORRUPT' "$WORK/corrupt-winner.err" ||
    fail 'corrupt concurrent winner was not rehashed and named'
test ! -s "$WORK/corrupt-winner.out" ||
    fail 'corrupt concurrent winner emitted partial success'
test "$(stat -c %i "$corrupt_winner")" = "$corrupt_winner_inode" ||
    fail 'corrupt concurrent winner inode was replaced'
test "$(sha256 "$corrupt_winner")" != "$ARTIFACT_DIGEST" ||
    fail 'corrupt concurrent winner was silently repaired'
assert_private_cleanup

# Every caller crosses a curl barrier after observing a warm miss.  Store
# admission must still publish exactly one object; all other callers rehash and
# adopt that winner without replacement or leftover incoming files.
STORE=$WORK/store-race
reset_fixture
cp "$WORK/artifact" "$FIXTURE/body"
printf '6\n' >"$FIXTURE/barrier-expected"
mkdir "$WORK/race"
race_pids=
n=1
while test "$n" -le 6; do
    fetch_current >"$WORK/race/$n.out" 2>"$WORK/race/$n.err" &
    race_pids="$race_pids $!"
    n=$((n + 1))
done
race_failures=0
for race_pid in $race_pids; do
    wait "$race_pid" || race_failures=$((race_failures + 1))
done
test "$race_failures" -eq 0 ||
    fail "$race_failures concurrent fetch qualification(s) failed"
test "$(transfer_count)" -eq 6 ||
    fail 'not every concurrent warm miss reached exactly one transfer'
test "$(find "$FIXTURE/barrier" -name 'caller.*' | wc -l | tr -d ' ')" -eq 6 ||
    fail 'not every concurrent caller reached the post-warm-miss barrier'
published=$(grep -l 'published .*create-if-absent' "$WORK/race"/*.err |
    wc -l | tr -d ' ')
adopted=$(grep -l 'adopted .*winner' "$WORK/race"/*.err |
    wc -l | tr -d ' ')
test "$published" -eq 1 && test "$adopted" -eq 5 ||
    fail "concurrent admission produced $published publisher(s) and $adopted adopter(s)"
for race_out in "$WORK/race"/*.out; do
    grep -Fq 'pinned HTTPS response verified and admitted' "$race_out" ||
        fail "concurrent caller omitted success-after-admission: $race_out"
done
race_entry=$(entry_for "$STORE" "$ARTIFACT_DIGEST")
test "$(sha256 "$race_entry")" = "$ARTIFACT_DIGEST" ||
    fail 'concurrent winner does not hash to its final name'
test "$(find "$STORE" -type f | wc -l | tr -d ' ')" -eq 1 ||
    fail 'concurrent fetches exposed more than one trusted object'
test "$(find "$STORE" -type f -name '*.incoming.*' | wc -l | tr -d ' ')" -eq 0 ||
    fail 'concurrent fetches left store admission temporaries'
assert_private_cleanup

# TERM in the curl subprocess cannot produce a trusted entry or a success
# sentinel.  This is a deterministic fake-process interruption, not a real
# socket/TLS interruption test.
STORE=$WORK/store-interrupted
reset_fixture
cp "$WORK/artifact" "$FIXTURE/body"
printf 'TERM\n' >"$FIXTURE/signal"
expect_refusal 'interrupted curl subprocess' 'pinned HTTPS GET failed' 1
assert_no_object "$STORE" "$ARTIFACT_DIGEST"

printf 'pm: one fake pinned HTTPS response reaches success-only verified store admission: PASS\n'
printf 'pm: warm, corrupt, concurrent, zero-byte, protocol, and interruption gates preserve precedence: PASS\n'
printf 'pm: curl argv/env sentinel is hermetic qualification evidence, not a real TLS claim: PASS\n'
