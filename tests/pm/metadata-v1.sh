#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
TOOL=$ROOT/scripts/metadata-v1.sh
WORK=$(mktemp -d "${TMPDIR:-/tmp}/kofun-pm-metadata-test.XXXXXX")
trap 'rm -rf "$WORK"' 0 1 2 15

fail() {
    printf 'pm: FAIL: metadata-v1: %s\n' "$*" >&2
    exit 1
}

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | cut -d' ' -f1
    else
        shasum -a 256 | cut -d' ' -f1
    fi
}

catalog_for() {
    metadata=$1
    output=$2
    metadata_size=$(wc -c <"$metadata" | tr -d ' ')
    metadata_digest=$(sha256 <"$metadata")
    {
        printf 'kofun-catalog/v1\n'
        printf '1.0.0\t0\t%s\n' "$D0"
        printf '1.2.0\t%s\t%s\n' "$metadata_size" "$metadata_digest"
        printf '1.10.0\t0\t%s\n' "$D1"
    } >"$output"
}

expect_refusal() {
    label=$1
    needle=$2
    shift 2
    if "$TOOL" "$@" >"$WORK/refusal.out" 2>&1; then
        fail "$label was accepted"
    fi
    grep -Fq -- "$needle" "$WORK/refusal.out" ||
        fail "$label did not say '$needle': $(sed -n '1,10p' "$WORK/refusal.out" | tr '\n' ' ')"
    if grep -Eq '^metadata-v1: exact catalog descriptor matched|strict metadata parsed|dependency and [0-9]+ file descriptor row' \
        "$WORK/refusal.out"
    then
        fail "$label emitted partial success or row counts"
    fi
}

state() {
    for path do
        stat -c '%n %d %i %h %F %a %s' "$path"
        sha256 <"$path"
    done
}

tree_state() {
    find "$@" -printf '%p %D %i %n %y %m %s\n' | LC_ALL=C sort
    find "$@" -type f -exec sha256sum '{}' ';' | LC_ALL=C sort
}

test -x "$TOOL" || fail "missing executable $TOOL"

ID=https://example.org/pkg/
VERSION=1.2.0
D0=0000000000000000000000000000000000000000000000000000000000000000
D1=1111111111111111111111111111111111111111111111111111111111111111
FILE_DIGEST=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
printf 'kofun-fetch-authority/v1\norigin\thttps://example.org\n' >"$WORK/authority"
{
    printf 'kofun-metadata/v1\n'
    printf 'identity\t%s\n' "$ID"
    printf 'version\t%s\n' "$VERSION"
    printf 'dependency\thttps://deps.example/a/\t1.0.0\n'
    printf 'file\tdata.bin\tdata\t0\t%s\n' "$D0"
    printf 'file\tsrc.kofun\tsource\t3\t%s\n' "$FILE_DIGEST"
} >"$WORK/metadata"
catalog_for "$WORK/metadata" "$WORK/catalog"

"$TOOL" inspect "$ID" "$VERSION" "$WORK/metadata" \
    --catalog "$WORK/catalog" --authority "$WORK/authority" >"$WORK/valid.out"
grep -Fq 'strict metadata parsed 1 dependency and 2 file descriptor row(s)' \
    "$WORK/valid.out" || fail 'success did not report complete strict row counts'
grep -Fq 'supplied authority, catalog, and metadata bytes for one exact identity/version only' \
    "$WORK/valid.out" || fail 'success omitted its supplied-byte boundary'
grep -Fq 'catalog authenticity/history/non-equivocation' "$WORK/valid.out" ||
    fail 'success overstated catalog authenticity/history'

# Request grammar is checked before any supplied pathname, and exact sparse
# membership never rounds a missing requirement to a higher published row.
expect_refusal 'invalid requested identity' 'requested identity/version grammar is invalid' \
    inspect 'https://127.0.0.1/pkg/' "$VERSION" "$WORK/missing.metadata" \
    --catalog "$WORK/missing.catalog" --authority "$WORK/missing.authority"
expect_refusal 'invalid requested version' 'requested identity/version grammar is invalid' \
    inspect "$ID" 1.02.0 "$WORK/missing.metadata" \
    --catalog "$WORK/missing.catalog" --authority "$WORK/missing.authority"
printf 'kofun-fetch-authority/v1\norigin\thttps://other.example\n' \
    >"$WORK/unapproved.authority"
expect_refusal 'unapproved before catalog/metadata path' \
    'identity origin is not explicitly approved' \
    inspect "$ID" "$VERSION" "$WORK/missing.metadata" \
    --catalog "$WORK/missing.catalog" --authority "$WORK/unapproved.authority"
printf 'wrong\n' >"$WORK/malformed.catalog"
expect_refusal 'catalog grammar before metadata path' \
    'first line is not exactly kofun-catalog/v1' \
    inspect "$ID" "$VERSION" "$WORK/missing.metadata" \
    --catalog "$WORK/malformed.catalog" --authority "$WORK/authority"
printf 'kofun-catalog/v1\n1.10.0\t0\t%s\n' "$D1" >"$WORK/higher.catalog"
expect_refusal 'exact sparse membership' \
    "required version $ID@$VERSION is not published" \
    inspect "$ID" "$VERSION" "$WORK/missing.metadata" \
    --catalog "$WORK/higher.catalog" --authority "$WORK/authority"

# Size mismatch is decided before SHA-256 and parsing. Both fixtures are also
# grammar-invalid, so their parser-specific diagnostics must remain absent.
sed '1s/^k//' "$WORK/metadata" >"$WORK/truncated.metadata"
{
    sed -n '1,$p' "$WORK/metadata"
    printf 'x'
} >"$WORK/overrun.metadata"
mkdir -p "$WORK/hash-sentinel"
for hash_command in sha256sum shasum; do
    {
        printf '#!/bin/sh\n'
        printf 'printf called >"$KPM_HASH_MARKER"\n'
        printf 'exit 97\n'
    } >"$WORK/hash-sentinel/$hash_command"
    chmod +x "$WORK/hash-sentinel/$hash_command"
done
for mismatch in truncated overrun; do
    marker=$WORK/hash-$mismatch.called
    if PATH="$WORK/hash-sentinel:$PATH" KPM_HASH_MARKER="$marker" \
        "$TOOL" inspect "$ID" "$VERSION" "$WORK/$mismatch.metadata" \
        --catalog "$WORK/catalog" --authority "$WORK/authority" \
        >"$WORK/$mismatch.out" 2>&1
    then
        fail "$mismatch metadata size was accepted"
    fi
    grep -Fq 'metadata size does not match its catalog descriptor' \
        "$WORK/$mismatch.out" || fail "$mismatch did not reach size precedence"
    grep -Fq 'actual digest not computed' "$WORK/$mismatch.out" ||
        fail "$mismatch did not state that SHA-256 was skipped"
    expected_size=$(wc -c <"$WORK/metadata" | tr -d ' ')
    actual_size=$(wc -c <"$WORK/$mismatch.metadata" | tr -d ' ')
    grep -Fq "  expected $expected_size" "$WORK/$mismatch.out" ||
        fail "$mismatch did not report the catalog size"
    grep -Fq "  actual   $actual_size" "$WORK/$mismatch.out" ||
        fail "$mismatch did not report the observed size"
    test ! -e "$marker" || fail "$mismatch called SHA-256 before size equality"
    if grep -Eq 'metadata grammar is invalid|first line is not exactly kofun-metadata/v1|unknown or blank metadata row kind' \
        "$WORK/$mismatch.out"
    then
        fail "$mismatch reached the metadata parser after size refusal"
    fi
done
head -c 1048577 /dev/zero >"$WORK/too-large.metadata"
marker=$WORK/hash-too-large.called
if PATH="$WORK/hash-sentinel:$PATH" KPM_HASH_MARKER="$marker" \
    "$TOOL" inspect "$ID" "$VERSION" "$WORK/too-large.metadata" \
    --catalog "$WORK/catalog" --authority "$WORK/authority" \
    >"$WORK/too-large.out" 2>&1
then
    fail 'metadata input byte bound was accepted'
fi
grep -Fq 'exceeds the 1048576-byte input bound' "$WORK/too-large.out" ||
    fail 'metadata input byte overrun did not reach its bound refusal'
grep -Fq "  expected $(wc -c <"$WORK/metadata" | tr -d ' ')" \
    "$WORK/too-large.out" || fail 'metadata byte overrun omitted its catalog size'
grep -Fq '  actual   at least 1048577' "$WORK/too-large.out" ||
    fail 'metadata byte overrun omitted its observed lower bound'
grep -Fq 'actual digest not computed' "$WORK/too-large.out" ||
    fail 'metadata byte overrun did not state the hash boundary'
test ! -e "$marker" || fail 'metadata byte overrun called SHA-256'
if grep -Eq 'metadata grammar is invalid|first line is not exactly kofun-metadata/v1|strict metadata parsed' \
    "$WORK/too-large.out"
then
    fail 'metadata byte overrun reached parsing or emitted row counts'
fi

# Equal-size corruption reaches SHA-256 but never grammar. Rebinding the
# catalog descriptor to malformed bytes reaches the strict shared parser.
sed '1s/kofun/Kofun/' "$WORK/metadata" >"$WORK/same-size-corrupt.metadata"
test "$(wc -c <"$WORK/same-size-corrupt.metadata" | tr -d ' ')" = \
    "$(wc -c <"$WORK/metadata" | tr -d ' ')" || fail 'digest fixture changed size'
expect_refusal 'same-size metadata corruption' \
    'metadata digest does not match its catalog descriptor' \
    inspect "$ID" "$VERSION" "$WORK/same-size-corrupt.metadata" \
    --catalog "$WORK/catalog" --authority "$WORK/authority"
grep -Fq 'expected' "$WORK/refusal.out" && grep -Fq 'actual' "$WORK/refusal.out" ||
    fail 'digest mismatch did not print expected and actual digests'
expected_digest=$(sha256 <"$WORK/metadata")
actual_digest=$(sha256 <"$WORK/same-size-corrupt.metadata")
grep -Fq "  expected $expected_digest" "$WORK/refusal.out" ||
    fail 'digest mismatch did not report the catalog digest'
grep -Fq "  actual   $actual_digest" "$WORK/refusal.out" ||
    fail 'digest mismatch did not report the observed digest'
if grep -Eq 'metadata grammar is invalid|first line is not exactly kofun-metadata/v1|strict metadata parsed' \
    "$WORK/refusal.out"
then
    fail 'digest mismatch reached the metadata parser'
fi

catalog_for "$WORK/same-size-corrupt.metadata" "$WORK/bad-header.catalog"
expect_refusal 'descriptor-matched bad metadata header' \
    'first line is not exactly kofun-metadata/v1' \
    inspect "$ID" "$VERSION" "$WORK/same-size-corrupt.metadata" \
    --catalog "$WORK/bad-header.catalog" --authority "$WORK/authority"
sed "2s#${ID}#https://example.org/other/#" "$WORK/metadata" \
    >"$WORK/wrong-identity.metadata"
catalog_for "$WORK/wrong-identity.metadata" "$WORK/wrong-identity.catalog"
expect_refusal 'descriptor-matched metadata identity' \
    'identity does not match its expected descriptor' \
    inspect "$ID" "$VERSION" "$WORK/wrong-identity.metadata" \
    --catalog "$WORK/wrong-identity.catalog" --authority "$WORK/authority"
sed '3s/1\.2\.0/1.3.0/' "$WORK/metadata" >"$WORK/wrong-version.metadata"
catalog_for "$WORK/wrong-version.metadata" "$WORK/wrong-version.catalog"
expect_refusal 'descriptor-matched metadata version' \
    'version does not match its expected descriptor' \
    inspect "$ID" "$VERSION" "$WORK/wrong-version.metadata" \
    --catalog "$WORK/wrong-version.catalog" --authority "$WORK/authority"

{
    sed -n '1,3p' "$WORK/metadata"
    printf 'file\tsrc.kofun\tsource\t3\t%s\n' "$FILE_DIGEST"
    printf 'dependency\thttps://deps.example/a/\t1.0.0\n'
} >"$WORK/bad-order.metadata"
catalog_for "$WORK/bad-order.metadata" "$WORK/bad-order.catalog"
expect_refusal 'descriptor-matched metadata order' \
    'dependency row appears after file rows' \
    inspect "$ID" "$VERSION" "$WORK/bad-order.metadata" \
    --catalog "$WORK/bad-order.catalog" --authority "$WORK/authority"

# The metadata action owns framing and structural checks before the shared row
# parser. Rebind every hostile byte sequence so size and digest cannot mask it.
sed '1s/$/\r/' "$WORK/metadata" >"$WORK/cr.metadata"
cp "$WORK/metadata" "$WORK/nul.metadata"
printf '\000' >>"$WORK/nul.metadata"
cp "$WORK/metadata" "$WORK/non-ascii.metadata"
printf '\377' >>"$WORK/non-ascii.metadata"
head -c -1 "$WORK/metadata" >"$WORK/no-lf.metadata"
cp "$WORK/metadata" "$WORK/double-lf.metadata"
printf '\n' >>"$WORK/double-lf.metadata"
{
    head -c 4097 /dev/zero | tr '\000' x
    printf '\nidentity\t%s\nversion\t%s\n' "$ID" "$VERSION"
    printf 'file\tdata.bin\tdata\t0\t%s\n' "$D0"
} >"$WORK/long-line.metadata"
{
    printf 'kofun-metadata/v1\nidentity\t%s\nversion\t%s\n' "$ID" "$VERSION"
    n=0
    while test "$n" -lt 4353; do
        printf 'file\tp%04d.bin\tdata\t0\t%s\n' "$n" "$D0"
        n=$((n + 1))
    done
} >"$WORK/too-many-rows.metadata"
for hostile in cr nul non-ascii no-lf double-lf long-line too-many-rows; do
    catalog_for "$WORK/$hostile.metadata" "$WORK/$hostile.catalog"
done
for hostile in cr nul non-ascii; do
    expect_refusal "descriptor-matched metadata $hostile bytes" \
        'byte outside ASCII, HT, and LF' \
        inspect "$ID" "$VERSION" "$WORK/$hostile.metadata" \
        --catalog "$WORK/$hostile.catalog" --authority "$WORK/authority"
done
expect_refusal 'descriptor-matched missing final LF' 'must end in exactly one LF' \
    inspect "$ID" "$VERSION" "$WORK/no-lf.metadata" \
    --catalog "$WORK/no-lf.catalog" --authority "$WORK/authority"
expect_refusal 'descriptor-matched double final LF' 'unknown or blank metadata row kind' \
    inspect "$ID" "$VERSION" "$WORK/double-lf.metadata" \
    --catalog "$WORK/double-lf.catalog" --authority "$WORK/authority"
expect_refusal 'descriptor-matched metadata line bound' \
    'line exceeds the 4096-byte structural bound' \
    inspect "$ID" "$VERSION" "$WORK/long-line.metadata" \
    --catalog "$WORK/long-line.catalog" --authority "$WORK/authority"
expect_refusal 'descriptor-matched metadata row bound' \
    'exceeds the 4355-row structural bound' \
    inspect "$ID" "$VERSION" "$WORK/too-many-rows.metadata" \
    --catalog "$WORK/too-many-rows.catalog" --authority "$WORK/authority"

# The inclusive byte bound is real: this strict document is exactly 1 MiB,
# uses bounded protocol paths, and must still reach complete row counting.
fill240=$(head -c 240 /dev/zero | tr '\000' a)
fill241=${fill240}a
fill214=$(head -c 214 /dev/zero | tr '\000' b)
fill215=${fill214}b
{
    printf 'kofun-metadata/v1\nidentity\t%s\nversion\t%s\n' "$ID" "$VERSION"
    n=0
    while test "$n" -lt 1000; do
        printf 'file\ta%04d/%s/%s/%s/%s\tdata\t0\t%s\n' \
            "$n" "$fill240" "$fill240" "$fill240" "$fill241" "$D0"
        n=$((n + 1))
    done
    printf 'file\tz/%s/%s\tdata\t0\t%s\n' "$fill214" "$fill215" "$D0"
} >"$WORK/exact-bound.metadata"
test "$(wc -c <"$WORK/exact-bound.metadata" | tr -d ' ')" = 1048576 ||
    fail 'exact metadata byte-bound fixture is not 1048576 bytes'
catalog_for "$WORK/exact-bound.metadata" "$WORK/exact-bound.catalog"
"$TOOL" inspect "$ID" "$VERSION" "$WORK/exact-bound.metadata" \
    --catalog "$WORK/exact-bound.catalog" --authority "$WORK/authority" \
    >"$WORK/exact-bound.out"
grep -Fq 'strict metadata parsed 0 dependency and 1001 file descriptor row(s)' \
    "$WORK/exact-bound.out" || fail 'exact metadata byte bound did not fully parse'

# A regular file whose name starts with '-' is still a pathname, never a head
# option or an instruction to consume ambient stdin.
mkdir -p "$WORK/option-metadata" "$WORK/option-catalog" "$WORK/option-authority"
cp "$WORK/same-size-corrupt.metadata" "$WORK/option-metadata/-"
if (cd "$WORK/option-metadata" && "$TOOL" inspect "$ID" "$VERSION" - \
    --catalog "$WORK/catalog" --authority "$WORK/authority" \
    <"$WORK/metadata") >"$WORK/option-metadata.out" 2>&1
then
    fail "metadata pathname '-' was replaced by stdin"
fi
grep -Fq 'metadata digest does not match its catalog descriptor' \
    "$WORK/option-metadata.out" || fail "metadata pathname '-' was not read literally"
printf 'wrong\n' >"$WORK/option-catalog/-"
if (cd "$WORK/option-catalog" && "$TOOL" inspect "$ID" "$VERSION" missing \
    --catalog - --authority "$WORK/authority" <"$WORK/catalog") \
    >"$WORK/option-catalog.out" 2>&1
then
    fail "catalog pathname '-' was replaced by stdin"
fi
grep -Fq 'first line is not exactly kofun-catalog/v1' "$WORK/option-catalog.out" ||
    fail "catalog pathname '-' was not read literally"
printf 'wrong\n' >"$WORK/option-authority/-"
if (cd "$WORK/option-authority" && "$TOOL" inspect "$ID" "$VERSION" missing \
    --catalog "$WORK/catalog" --authority - <"$WORK/authority") \
    >"$WORK/option-authority.out" 2>&1
then
    fail "authority pathname '-' was replaced by stdin"
fi
grep -Fq 'first line is not exactly kofun-fetch-authority/v1' \
    "$WORK/option-authority.out" || fail "authority pathname '-' was not read literally"

ln -s "$WORK/metadata" "$WORK/metadata.symlink"
expect_refusal 'metadata symlink' 'not a regular non-symlink file' \
    inspect "$ID" "$VERSION" "$WORK/metadata.symlink" \
    --catalog "$WORK/catalog" --authority "$WORK/authority"
mkfifo "$WORK/metadata.fifo"
expect_refusal 'metadata FIFO' 'not a regular non-symlink file' \
    inspect "$ID" "$VERSION" "$WORK/metadata.fifo" \
    --catalog "$WORK/catalog" --authority "$WORK/authority"

# Each explicit pathname is opened once into a private snapshot. Swap the
# original after head returns; validation must continue from captured bytes.
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

cp "$WORK/authority" "$WORK/authority.saved"
PATH="$WORK/head-spy:$PATH" KPM_SWAP_TARGET="$WORK/authority" \
KPM_SWAP_BYTES="$WORK/unapproved.authority" KPM_SWAP_COUNT="$WORK/authority.count" \
    "$TOOL" inspect "$ID" "$VERSION" "$WORK/metadata" \
    --catalog "$WORK/catalog" --authority "$WORK/authority" >"$WORK/authority-swap.out"
test "$(sed -n '1p' "$WORK/authority.count")" = 1 ||
    fail 'authority pathname was not read exactly once'
cp "$WORK/authority.saved" "$WORK/authority"

cp "$WORK/catalog" "$WORK/catalog.saved"
PATH="$WORK/head-spy:$PATH" KPM_SWAP_TARGET="$WORK/catalog" \
KPM_SWAP_BYTES="$WORK/higher.catalog" KPM_SWAP_COUNT="$WORK/catalog.count" \
    "$TOOL" inspect "$ID" "$VERSION" "$WORK/metadata" \
    --catalog "$WORK/catalog" --authority "$WORK/authority" >"$WORK/catalog-swap.out"
test "$(sed -n '1p' "$WORK/catalog.count")" = 1 ||
    fail 'catalog pathname was not read exactly once'
cp "$WORK/catalog.saved" "$WORK/catalog"

cp "$WORK/metadata" "$WORK/metadata.saved"
PATH="$WORK/head-spy:$PATH" KPM_SWAP_TARGET="$WORK/metadata" \
KPM_SWAP_BYTES="$WORK/same-size-corrupt.metadata" KPM_SWAP_COUNT="$WORK/metadata.count" \
    "$TOOL" inspect "$ID" "$VERSION" "$WORK/metadata" \
    --catalog "$WORK/catalog" --authority "$WORK/authority" >"$WORK/metadata-swap.out"
test "$(sed -n '1p' "$WORK/metadata.count")" = 1 ||
    fail 'metadata pathname was not read exactly once'
cmp "$WORK/metadata" "$WORK/same-size-corrupt.metadata" ||
    fail 'metadata swap spy did not replace the original path'
cp "$WORK/metadata.saved" "$WORK/metadata"

# Success and refusal preserve bytes/path/type/device/inode/link/mode. Hostile
# empty environment state cannot add a network, ledger, or store effect.
chmod 640 "$WORK/metadata"
chmod 600 "$WORK/catalog"
chmod 440 "$WORK/authority"
ln "$WORK/metadata" "$WORK/metadata.link"
state "$WORK/metadata" "$WORK/metadata.link" "$WORK/catalog" "$WORK/authority" \
    >"$WORK/input.before"
"$TOOL" inspect "$ID" "$VERSION" "$WORK/metadata" \
    --catalog "$WORK/catalog" --authority "$WORK/authority" >"$WORK/state-success.out"
expect_refusal 'read-only digest refusal' 'metadata digest does not match' \
    inspect "$ID" "$VERSION" "$WORK/same-size-corrupt.metadata" \
    --catalog "$WORK/catalog" --authority "$WORK/authority"
state "$WORK/metadata" "$WORK/metadata.link" "$WORK/catalog" "$WORK/authority" \
    >"$WORK/input.after"
cmp "$WORK/input.before" "$WORK/input.after" ||
    fail 'success or refusal mutated explicit input state or bytes'

mkdir -p "$WORK/network-bin" "$WORK/hostile-home" "$WORK/hostile-xdg"
printf 'home\n' >"$WORK/hostile-home/marker"
printf 'xdg\n' >"$WORK/hostile-xdg/marker"
for network_command in curl wget fetch ftp sftp ssh nc ncat netcat telnet \
    openssl git host dig nslookup getent
do
    cp "$ROOT/tests/pm/network-sentinel.sh" "$WORK/network-bin/$network_command"
done
chmod +x "$WORK/network-bin"/*
state "$WORK/metadata" "$WORK/catalog" "$WORK/authority" \
    "$WORK/same-size-corrupt.metadata" >"$WORK/offline-input.before"
tree_state "$WORK/hostile-home" "$WORK/hostile-xdg" >"$WORK/ambient.before"
env -i PATH="$WORK/network-bin:$PATH" HOME="$WORK/hostile-home" \
XDG_CACHE_HOME="$WORK/hostile-xdg" KPM_STORE="$WORK/ambient-store" \
KPM_NETWORK_SENTINEL="$WORK/network.called" \
http_proxy=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 \
ALL_PROXY=socks5://127.0.0.1:9 \
    "$TOOL" inspect "$ID" "$VERSION" "$WORK/metadata" \
    --catalog "$WORK/catalog" --authority "$WORK/authority" >"$WORK/offline.out"
if env -i PATH="$WORK/network-bin:$PATH" HOME="$WORK/hostile-home" \
    XDG_CACHE_HOME="$WORK/hostile-xdg" KPM_STORE="$WORK/ambient-store" \
    KPM_NETWORK_SENTINEL="$WORK/network.called" \
    http_proxy=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 \
    ALL_PROXY=socks5://127.0.0.1:9 \
    "$TOOL" inspect "$ID" "$VERSION" "$WORK/same-size-corrupt.metadata" \
    --catalog "$WORK/catalog" --authority "$WORK/authority" \
    >"$WORK/offline-refusal.out" 2>&1
then
    fail 'hostile-environment digest mismatch was accepted'
fi
grep -Fq 'metadata digest does not match' "$WORK/offline-refusal.out" ||
    fail 'hostile refusal did not reach digest precedence'
test ! -e "$WORK/network.called" || fail 'metadata inspector attempted a network command'
test ! -e "$WORK/ambient-store" || fail 'metadata inspector used ambient KPM_STORE'
tree_state "$WORK/hostile-home" "$WORK/hostile-xdg" >"$WORK/ambient.after"
cmp "$WORK/ambient.before" "$WORK/ambient.after" ||
    fail 'metadata inspector mutated ambient HOME/XDG state'
state "$WORK/metadata" "$WORK/catalog" "$WORK/authority" \
    "$WORK/same-size-corrupt.metadata" >"$WORK/offline-input.after"
cmp "$WORK/offline-input.before" "$WORK/offline-input.after" ||
    fail 'hostile success/refusal mutated explicit input state or bytes'

printf 'pm: exact catalog membership binds one metadata snapshot by size then digest: PASS\n'
printf 'pm: descriptor-matched metadata reaches shared strict identity/version/row grammar: PASS\n'
printf 'pm: metadata binding precedence, read-once snapshots, offline and read-only: PASS\n'
