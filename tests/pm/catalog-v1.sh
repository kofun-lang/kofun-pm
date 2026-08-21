#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
TOOL=$ROOT/scripts/catalog-v1.sh
WORK=$(mktemp -d "${TMPDIR:-/tmp}/kofun-pm-catalog-test.XXXXXX")
trap 'rm -rf "$WORK"' 0 1 2 15

fail() {
    printf 'pm: FAIL: catalog-v1: %s\n' "$*" >&2
    exit 1
}

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | cut -d' ' -f1
    else
        shasum -a 256 | cut -d' ' -f1
    fi
}

write_lock() {
    body=$1
    output=$2
    {
        printf '# format: kofun-pm.lock/v2\n'
        printf '# columns: typed rows: package identity state version | metadata identity version size sha256 | file identity version path kind size sha256\n'
        printf '# tool: %s\n' "$D0"
        printf '# requirements: %s\n' "$D1"
        sed -n '1,$p' "$body"
    } >"$WORK/lock.covered"
    lock_digest=$(sha256 <"$WORK/lock.covered")
    {
        sed -n '1,$p' "$WORK/lock.covered"
        printf '# digest: %s\n' "$lock_digest"
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
        fail "$label did not say '$needle': $(sed -n '1,8p' "$WORK/refusal.out" | tr '\n' ' ')"
    if grep -Eq '^catalog-v1: (first observation|supplied-lock continuity) passed' \
        "$WORK/refusal.out"
    then
        fail "$label emitted partial success"
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
ORIGIN=https://example.org
OTHER_ID=https://other.example/pkg/
D0=0000000000000000000000000000000000000000000000000000000000000000
D1=1111111111111111111111111111111111111111111111111111111111111111
D2=2222222222222222222222222222222222222222222222222222222222222222

printf 'kofun-fetch-authority/v1\norigin\t%s\norigin\thttps://unused.example\n' \
    "$ORIGIN" >"$WORK/authority"
{
    printf 'kofun-catalog/v1\n'
    printf '1.0.0\t0\t%s\n' "$D0"
    printf '1.2.0\t12\t%s\n' "$D1"
    printf '1.10.0\t13\t%s\n' "$D2"
} >"$WORK/catalog"
{
    printf 'package\t%s\tselected\t1.2.0\n' "$ID"
    printf 'metadata\t%s\t1.0.0\t0\t%s\n' "$ID" "$D0"
    printf 'metadata\t%s\t1.2.0\t12\t%s\n' "$ID" "$D1"
    printf 'file\t%s\t1.2.0\tsrc.kofun\tsource\t0\t%s\n' "$ID" "$D0"
} >"$WORK/history.body"
write_lock "$WORK/history.body" "$WORK/history.lock"
{
    printf 'package\t%s\tselected\t1.0.0\n' "$OTHER_ID"
    printf 'metadata\t%s\t1.0.0\t0\t%s\n' "$OTHER_ID" "$D0"
    printf 'file\t%s\t1.0.0\tdata.bin\tdata\t0\t%s\n' "$OTHER_ID" "$D0"
} >"$WORK/unrelated.body"
write_lock "$WORK/unrelated.body" "$WORK/unrelated.lock"

"$TOOL" inspect "$ID" "$WORK/catalog" --authority "$WORK/authority" \
    >"$WORK/first.out"
grep -Fq 'first observation passed' "$WORK/first.out" ||
    fail 'no-history success was not named first observation'
grep -Fq 'catalog authenticity/non-equivocation' "$WORK/first.out" ||
    fail 'no-history success omitted its authenticity boundary'
grep -Fq 'no observation ledger was read or written' "$WORK/first.out" ||
    fail 'no-history success did not state the absent ledger boundary'
if grep -Fq 'one supplied lock' "$WORK/first.out"; then
    fail 'no-history success claimed a lock that was not supplied'
fi

"$TOOL" inspect "$ID" "$WORK/catalog" --authority "$WORK/authority" \
    --history-lock "$WORK/history.lock" >"$WORK/history.out"
grep -Fq '2 prior metadata descriptor(s) matched' "$WORK/history.out" ||
    fail 'selected and superseded lock descriptors were not both compared'
grep -Fq 'one supplied lock' "$WORK/history.out" ||
    fail 'history success overstated or omitted its supplied-input boundary'

"$TOOL" inspect "$ID" "$WORK/catalog" --authority "$WORK/authority" \
    --history-lock "$WORK/unrelated.lock" >"$WORK/unrelated.out"
grep -Fq 'first observation passed' "$WORK/unrelated.out" ||
    fail 'an unrelated valid lock was not treated as first observation'
grep -Fq 'that lock records no metadata descriptor for this identity' "$WORK/unrelated.out" ||
    fail 'zero compared lock rows were not stated explicitly'

printf 'kofun-catalog/v1\n' >"$WORK/empty.catalog"
"$TOOL" inspect "$ID" "$WORK/empty.catalog" --authority "$WORK/authority" \
    >"$WORK/empty.out"
grep -Fq '0 catalog version(s)' "$WORK/empty.out" ||
    fail 'a structurally valid empty first-observation catalog did not report zero rows'

# The exact identity origin must be present. Extra valid origins are allowed,
# but finding the requested row never hides a malformed later row.
printf 'kofun-fetch-authority/v1\norigin\thttps://other.example\n' \
    >"$WORK/unapproved.authority"
expect_refusal 'unapproved origin' 'identity origin is not explicitly approved' \
    inspect "$ID" "$WORK/catalog" --authority "$WORK/unapproved.authority"
printf 'kofun-fetch-authority/v1\n' >"$WORK/header-only.authority"
expect_refusal 'header-only authority' 'identity origin is not explicitly approved' \
    inspect "$ID" "$WORK/catalog" --authority "$WORK/header-only.authority"
expect_refusal 'unapproved before missing catalog' \
    'identity origin is not explicitly approved' \
    inspect "$ID" "$WORK/does-not-exist.catalog" --authority "$WORK/unapproved.authority"
expect_refusal 'unapproved before missing history lock' \
    'identity origin is not explicitly approved' \
    inspect "$ID" "$WORK/catalog" --authority "$WORK/unapproved.authority" \
    --history-lock "$WORK/does-not-exist.lock"
printf 'wrong\norigin\t%s\n' "$ORIGIN" >"$WORK/bad-header.authority"
expect_refusal 'authority header' 'first line is not exactly kofun-fetch-authority/v1' \
    inspect "$ID" "$WORK/catalog" --authority "$WORK/bad-header.authority"
printf 'kofun-fetch-authority/v1\r\norigin\t%s\r\n' "$ORIGIN" \
    >"$WORK/cr.authority"
expect_refusal 'authority CR' 'byte outside ASCII, HT, and LF' \
    inspect "$ID" "$WORK/catalog" --authority "$WORK/cr.authority"
printf 'kofun-fetch-authority/v1\norigin\thttps://exam\303\251ple.org\n' \
    >"$WORK/non-ascii.authority"
expect_refusal 'authority non-ASCII' 'byte outside ASCII, HT, and LF' \
    inspect "$ID" "$WORK/catalog" --authority "$WORK/non-ascii.authority"
printf 'kofun-fetch-authority/v1\norigin\thttps://example.org\000\n' \
    >"$WORK/nul.authority"
expect_refusal 'authority NUL' 'byte outside ASCII, HT, and LF' \
    inspect "$ID" "$WORK/catalog" --authority "$WORK/nul.authority"
printf 'kofun-fetch-authority/v1\n\norigin\t%s\n' "$ORIGIN" \
    >"$WORK/blank.authority"
expect_refusal 'authority blank' 'authority row is not exactly' \
    inspect "$ID" "$WORK/catalog" --authority "$WORK/blank.authority"
printf 'kofun-fetch-authority/v1\n# no comments\norigin\t%s\n' "$ORIGIN" \
    >"$WORK/comment.authority"
expect_refusal 'authority comment' 'authority row is not exactly' \
    inspect "$ID" "$WORK/catalog" --authority "$WORK/comment.authority"
printf 'kofun-fetch-authority/v1\norigin\t%s\textra\n' "$ORIGIN" \
    >"$WORK/fields.authority"
expect_refusal 'authority fields' 'authority row is not exactly' \
    inspect "$ID" "$WORK/catalog" --authority "$WORK/fields.authority"
printf 'kofun-fetch-authority/v1\norigin\t%s\norigin\t%s\n' "$ORIGIN" "$ORIGIN" \
    >"$WORK/duplicate.authority"
expect_refusal 'authority duplicate' 'not in strict byte order' \
    inspect "$ID" "$WORK/catalog" --authority "$WORK/duplicate.authority"
printf 'kofun-fetch-authority/v1\norigin\thttps://z.example\norigin\t%s\n' "$ORIGIN" \
    >"$WORK/order.authority"
expect_refusal 'authority order' 'not in strict byte order' \
    inspect "$ID" "$WORK/catalog" --authority "$WORK/order.authority"
printf 'kofun-fetch-authority/v1\norigin\t%s\nunknown\tx\n' "$ORIGIN" \
    >"$WORK/trailing-malformed.authority"
expect_refusal 'malformed authority after approval' 'authority row is not exactly' \
    inspect "$ID" "$WORK/catalog" --authority "$WORK/trailing-malformed.authority"

for hostile in \
    'http://example.org' \
    'https://EXAMPLE.org' \
    'https://user@example.org' \
    'https://example.org:443' \
    'https://example.org/' \
    'https://example.org?q' \
    'https://127.0.0.1' \
    'https://2130706433' \
    'https://0x7f.0.0.1'
do
    printf 'kofun-fetch-authority/v1\norigin\t%s\n' "$hostile" \
        >"$WORK/hostile.authority"
    expect_refusal "hostile authority origin $hostile" 'approved origin' \
        inspect "$ID" "$WORK/catalog" --authority "$WORK/hostile.authority"
done
printf 'kofun-fetch-authority/v1\norigin\thttps://\n' >"$WORK/empty-host.authority"
expect_refusal 'authority empty host' 'approved origin host' \
    inspect "$ID" "$WORK/catalog" --authority "$WORK/empty-host.authority"

# DNS/origin bounds are shared with identity parsing: 63-byte labels and a
# 253-byte host (261-byte origin) pass; the next byte is refused.
label63=$(head -c 63 /dev/zero | tr '\000' a)
label64=${label63}a
printf 'kofun-fetch-authority/v1\norigin\thttps://%s.org\n' "$label63" \
    >"$WORK/label63.authority"
"$TOOL" inspect "https://$label63.org/pkg/" "$WORK/catalog" \
    --authority "$WORK/label63.authority" >"$WORK/label63.out"
printf 'kofun-fetch-authority/v1\norigin\thttps://%s.org\n' "$label64" \
    >"$WORK/label64.authority"
expect_refusal '64-byte DNS label' 'label is not canonical' \
    inspect "$ID" "$WORK/catalog" --authority "$WORK/label64.authority"
host253="$label63.$label63.$label63.$(head -c 61 /dev/zero | tr '\000' b)"
test "${#host253}" -eq 253 || fail 'host boundary fixture is not 253 bytes'
printf 'kofun-fetch-authority/v1\norigin\thttps://%s\n' "$host253" \
    >"$WORK/host253.authority"
"$TOOL" inspect "https://$host253/pkg/" "$WORK/catalog" \
    --authority "$WORK/host253.authority" >"$WORK/host253.out"
host254=${host253}b
printf 'kofun-fetch-authority/v1\norigin\thttps://%s\n' "$host254" \
    >"$WORK/host254.authority"
expect_refusal '262-byte HTTPS origin' 'not one canonical https origin' \
    inspect "$ID" "$WORK/catalog" --authority "$WORK/host254.authority"

printf 'kofun-fetch-authority/v1\norigin\t%s' "$ORIGIN" \
    >"$WORK/no-lf.authority"
expect_refusal 'authority final LF' 'must end in exactly one LF' \
    inspect "$ID" "$WORK/catalog" --authority "$WORK/no-lf.authority"
printf 'kofun-fetch-authority/v1\norigin\t%s\n\n' "$ORIGIN" \
    >"$WORK/double-lf.authority"
expect_refusal 'authority double LF' 'authority row is not exactly' \
    inspect "$ID" "$WORK/catalog" --authority "$WORK/double-lf.authority"
{
    printf 'kofun-fetch-authority/v1\norigin\thttps://'
    head -c 4090 /dev/zero | tr '\000' a
    printf '\n'
} >"$WORK/long.authority"
expect_refusal 'authority line bound' 'line exceeds the 4096-byte structural bound' \
    inspect "$ID" "$WORK/catalog" --authority "$WORK/long.authority"
head -c 524289 /dev/zero >"$WORK/large.authority"
expect_refusal 'authority byte bound' 'exceeds the 524288-byte input bound' \
    inspect "$ID" "$WORK/catalog" --authority "$WORK/large.authority"

{
    printf 'kofun-fetch-authority/v1\n'
    n=0
    while test "$n" -lt 2048; do
        printf 'origin\thttps://h%04d.example\n' "$n"
        n=$((n + 1))
    done
} >"$WORK/authority-2048"
printf 'kofun-catalog/v1\n1.0.0\t0\t%s\n' "$D0" >"$WORK/bound.catalog"
"$TOOL" inspect https://h0000.example/pkg/ "$WORK/bound.catalog" \
    --authority "$WORK/authority-2048" >"$WORK/authority-bound.out"
{
    sed -n '1,$p' "$WORK/authority-2048"
    printf 'origin\thttps://h2048.example\n'
} >"$WORK/authority-2049"
expect_refusal 'authority row bound' 'exceeds the 2049-row structural bound' \
    inspect https://h0000.example/pkg/ "$WORK/bound.catalog" \
    --authority "$WORK/authority-2049"

# Catalog grammar is exact and semantic-version ordered, not lexical.
printf 'wrong\n1.0.0\t0\t%s\n' "$D0" >"$WORK/bad-header.catalog"
expect_refusal 'catalog header' 'first line is not exactly kofun-catalog/v1' \
    inspect "$ID" "$WORK/bad-header.catalog" --authority "$WORK/authority"
printf 'kofun-catalog/v1\r\n1.0.0\t0\t%s\r\n' "$D0" >"$WORK/cr.catalog"
expect_refusal 'catalog CR' 'byte outside ASCII, HT, and LF' \
    inspect "$ID" "$WORK/cr.catalog" --authority "$WORK/authority"
printf 'kofun-catalog/v1\n1.0.0\t0\t%s\000\n' "$D0" >"$WORK/nul.catalog"
expect_refusal 'catalog NUL' 'byte outside ASCII, HT, and LF' \
    inspect "$ID" "$WORK/nul.catalog" --authority "$WORK/authority"
printf 'kofun-catalog/v1\n1.0.0\t0\t%s\n\n' "$D0" >"$WORK/blank.catalog"
expect_refusal 'catalog blank' 'catalog row must have' \
    inspect "$ID" "$WORK/blank.catalog" --authority "$WORK/authority"
printf 'kofun-catalog/v1\n# no comments\n' >"$WORK/comment.catalog"
expect_refusal 'catalog comment' 'catalog row must have' \
    inspect "$ID" "$WORK/comment.catalog" --authority "$WORK/authority"
printf 'kofun-catalog/v1\n1.0.0\t0\t%s\textra\n' "$D0" >"$WORK/fields.catalog"
expect_refusal 'catalog fields' 'catalog row must have' \
    inspect "$ID" "$WORK/fields.catalog" --authority "$WORK/authority"
printf 'kofun-catalog/v1\n1.0.0\t0\t%s\n1.0.0\t0\t%s\n' "$D0" "$D0" \
    >"$WORK/duplicate.catalog"
expect_refusal 'catalog duplicate' 'not in strict semantic order' \
    inspect "$ID" "$WORK/duplicate.catalog" --authority "$WORK/authority"
printf 'kofun-catalog/v1\n1.10.0\t0\t%s\n1.2.0\t0\t%s\n' "$D0" "$D0" \
    >"$WORK/semantic-order.catalog"
expect_refusal 'catalog semantic order' 'not in strict semantic order' \
    inspect "$ID" "$WORK/semantic-order.catalog" --authority "$WORK/authority"
printf 'kofun-catalog/v1\n2.0.0\t0\t%s\n' "$D0" >"$WORK/major.catalog"
expect_refusal 'catalog major binding' 'does not carry major 2 in its identity' \
    inspect "$ID" "$WORK/major.catalog" --authority "$WORK/authority"
printf 'kofun-catalog/v1\n0.1.0\t0\t%s\n' "$D0" >"$WORK/major-zero.catalog"
expect_refusal 'catalog major zero' 'uses unsupported major zero' \
    inspect "$ID" "$WORK/major-zero.catalog" --authority "$WORK/authority"
printf 'kofun-catalog/v1\n1.0.0\t00\t%s\n' "$D0" >"$WORK/uint.catalog"
expect_refusal 'catalog canonical size' 'not canonical unsigned decimal' \
    inspect "$ID" "$WORK/uint.catalog" --authority "$WORK/authority"
printf 'kofun-catalog/v1\n1.0.0\t1048577\t%s\n' "$D0" >"$WORK/meta-size.catalog"
expect_refusal 'catalog metadata size bound' 'exceeds its bound' \
    inspect "$ID" "$WORK/meta-size.catalog" --authority "$WORK/authority"
printf 'kofun-catalog/v1\n1.2147483647.2147483647\t1048576\t%s\n' "$D0" \
    >"$WORK/scalar-max.catalog"
"$TOOL" inspect "$ID" "$WORK/scalar-max.catalog" --authority "$WORK/authority" \
    >"$WORK/scalar-max.out"
printf 'kofun-catalog/v1\n1.2147483648.0\t1048576\t%s\n' "$D0" \
    >"$WORK/component-over.catalog"
expect_refusal 'semantic-version component bound' 'component exceeds its bound' \
    inspect "$ID" "$WORK/component-over.catalog" --authority "$WORK/authority"
printf 'kofun-catalog/v1\n1.0.0\t0\t%s\n' "$(printf '%s' "$D0" | tr a-f A-F)" \
    >"$WORK/upper-digest.catalog"
# D0 has no letters, so use a digest that does.
printf 'kofun-catalog/v1\n1.0.0\t0\tE3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855\n' \
    >"$WORK/upper-digest.catalog"
expect_refusal 'catalog lowercase digest' 'not one lowercase sha256 digest' \
    inspect "$ID" "$WORK/upper-digest.catalog" --authority "$WORK/authority"
{
    printf 'kofun-catalog/v1\n'
    printf '1.0.0\t0\t%s\n' "$D0"
    printf '1.1.0\t1\t%s\n' "$D0"
} >"$WORK/conflict-size.catalog"
expect_refusal 'catalog digest size conflict' 'one metadata digest carries conflicting sizes' \
    inspect "$ID" "$WORK/conflict-size.catalog" --authority "$WORK/authority"
printf 'kofun-catalog/v1\n1.0.0\t0\t%s' "$D0" >"$WORK/no-lf.catalog"
expect_refusal 'catalog final LF' 'must end in exactly one LF' \
    inspect "$ID" "$WORK/no-lf.catalog" --authority "$WORK/authority"
head -c 1048577 /dev/zero >"$WORK/large.catalog"
expect_refusal 'catalog byte bound' 'exceeds the 1048576-byte input bound' \
    inspect "$ID" "$WORK/large.catalog" --authority "$WORK/authority"

{
    printf 'kofun-catalog/v1\n'
    n=0
    while test "$n" -lt 4096; do
        printf '1.%s.0\t0\t%s\n' "$n" "$D0"
        n=$((n + 1))
    done
} >"$WORK/catalog-4096"
"$TOOL" inspect "$ID" "$WORK/catalog-4096" --authority "$WORK/authority" \
    >"$WORK/catalog-bound.out"
{
    sed -n '1,$p' "$WORK/catalog-4096"
    printf '1.4096.0\t0\t%s\n' "$D0"
} >"$WORK/catalog-4097"
expect_refusal 'catalog row bound' 'exceeds the 4097-row structural bound' \
    inspect "$ID" "$WORK/catalog-4097" --authority "$WORK/authority"

expect_refusal 'invalid identity' 'identity grammar is invalid' \
    inspect 'https://127.0.0.1/pkg/' "$WORK/catalog" --authority "$WORK/authority"
expect_refusal 'identity backslash escape is not normalized' 'identity grammar is invalid' \
    inspect 'https://example.org/pkg/\x2f/' "$WORK/catalog" --authority "$WORK/authority"
expect_refusal 'catalog release against v2 identity' 'major one identity carries a version suffix' \
    inspect 'https://example.org/pkg/v2/' "$WORK/catalog" --authority "$WORK/authority"

# A lock-recorded descriptor may neither disappear nor change. Catalog rows
# not represented by this one supplied lock remain allowed.
{
    printf 'kofun-catalog/v1\n'
    printf '1.0.0\t0\t%s\n' "$D0"
    printf '1.10.0\t13\t%s\n' "$D2"
} >"$WORK/withdrawn.catalog"
expect_refusal 'withdrawal' 'withdrawal/history violation' \
    inspect "$ID" "$WORK/withdrawn.catalog" --authority "$WORK/authority" \
    --history-lock "$WORK/history.lock"
grep -Fq 'catalog  missing' "$WORK/refusal.out" ||
    fail 'withdrawal did not distinguish a missing catalog row'
grep -Fq 'version  1.2.0' "$WORK/refusal.out" ||
    fail 'withdrawal did not name identity/version context'
if grep -Fq 'immutability violation' "$WORK/refusal.out"; then
    fail 'withdrawal was also misdiagnosed as descriptor mutation'
fi
{
    printf 'kofun-catalog/v1\n'
    printf '1.0.0\t0\t%s\n' "$D0"
    printf '1.2.0\t13\t%s\n' "$D1"
} >"$WORK/changed-size.catalog"
expect_refusal 'changed size' 'immutability violation: descriptor changed' \
    inspect "$ID" "$WORK/changed-size.catalog" --authority "$WORK/authority" \
    --history-lock "$WORK/history.lock"
grep -Fq 'locked   size=12' "$WORK/refusal.out" &&
    grep -Fq 'catalog  size=13' "$WORK/refusal.out" ||
    fail 'changed size did not print old and current descriptors'
if grep -Fq 'withdrawal/history violation' "$WORK/refusal.out"; then
    fail 'changed size was also misdiagnosed as withdrawal'
fi
{
    printf 'kofun-catalog/v1\n'
    printf '1.0.0\t0\t%s\n' "$D0"
    printf '1.2.0\t12\t%s\n' "$D2"
} >"$WORK/changed-digest.catalog"
expect_refusal 'changed digest' 'immutability violation: descriptor changed' \
    inspect "$ID" "$WORK/changed-digest.catalog" --authority "$WORK/authority" \
    --history-lock "$WORK/history.lock"
grep -Fq "catalog  size=12 sha256=$D2" "$WORK/refusal.out" ||
    fail 'changed digest did not print the current descriptor'
if grep -Fq 'withdrawal/history violation' "$WORK/refusal.out"; then
    fail 'changed digest was also misdiagnosed as withdrawal'
fi

printf 'kofun-catalog/v1\n1.0.0\t00\t%s\n' "$D0" \
    >"$WORK/malformed-withdrawal.catalog"
expect_refusal 'catalog grammar before history relation' 'not canonical unsigned decimal' \
    inspect "$ID" "$WORK/malformed-withdrawal.catalog" --authority "$WORK/authority" \
    --history-lock "$WORK/history.lock"
if grep -Fq 'withdrawal/history violation' "$WORK/refusal.out"; then
    fail 'malformed catalog was misdiagnosed as withdrawal'
fi

printf '# format: kofun-pm.lock/v1\n' >"$WORK/v1.lock"
expect_refusal 'v1 history lock' 'lock v1 remains frozen' \
    inspect "$ID" "$WORK/catalog" --authority "$WORK/authority" \
    --history-lock "$WORK/v1.lock"
sed '$c\# digest: 0000000000000000000000000000000000000000000000000000000000000000' \
    "$WORK/history.lock" >"$WORK/bad-digest.lock"
expect_refusal 'history self digest' 'lock digest does not cover its preceding bytes' \
    inspect "$ID" "$WORK/catalog" --authority "$WORK/authority" \
    --history-lock "$WORK/bad-digest.lock"
sed 's/^metadata\t/unknown\t/' "$WORK/history.body" >"$WORK/bad-body.body"
write_lock "$WORK/bad-body.body" "$WORK/bad-body.lock"
expect_refusal 'history full body grammar' 'unknown or blank lock row kind' \
    inspect "$ID" "$WORK/catalog" --authority "$WORK/authority" \
    --history-lock "$WORK/bad-body.lock"
expect_refusal 'history grammar before changed descriptor' 'unknown or blank lock row kind' \
    inspect "$ID" "$WORK/changed-digest.catalog" --authority "$WORK/authority" \
    --history-lock "$WORK/bad-body.lock"
if grep -Fq 'immutability violation' "$WORK/refusal.out"; then
    fail 'invalid history lock reached descriptor continuity comparison'
fi

# One pathname read creates each supplied snapshot. The head wrapper swaps an
# original path after returning those bytes. All later work must still use the
# corresponding private snapshot and succeed against the original inputs.
real_head=$(command -v head)
mkdir -p "$WORK/head-spy"
cp "$WORK/catalog" "$WORK/catalog.before-swap"
cp "$WORK/changed-digest.catalog" "$WORK/catalog.swap"
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
PATH="$WORK/head-spy:$PATH" KPM_SWAP_TARGET="$WORK/catalog" \
KPM_SWAP_BYTES="$WORK/catalog.swap" KPM_SWAP_COUNT="$WORK/head.count" \
    "$TOOL" inspect "$ID" "$WORK/catalog" --authority "$WORK/authority" \
    --history-lock "$WORK/history.lock" >"$WORK/snapshot-swap.out"
test "$(sed -n '1p' "$WORK/head.count")" = 1 ||
    fail 'catalog pathname was not read exactly once for its private snapshot'
cmp "$WORK/catalog" "$WORK/catalog.swap" ||
    fail 'head spy did not replace the original catalog path after snapshot'
cp "$WORK/catalog.before-swap" "$WORK/catalog"
cp "$WORK/authority" "$WORK/authority.before-swap"
PATH="$WORK/head-spy:$PATH" KPM_SWAP_TARGET="$WORK/authority" \
KPM_SWAP_BYTES="$WORK/unapproved.authority" KPM_SWAP_COUNT="$WORK/authority-head.count" \
    "$TOOL" inspect "$ID" "$WORK/catalog" --authority "$WORK/authority" \
    --history-lock "$WORK/history.lock" >"$WORK/authority-snapshot-swap.out"
test "$(sed -n '1p' "$WORK/authority-head.count")" = 1 ||
    fail 'authority pathname was not read exactly once for its private snapshot'
cmp "$WORK/authority" "$WORK/unapproved.authority" ||
    fail 'head spy did not replace the original authority path after snapshot'
cp "$WORK/authority.before-swap" "$WORK/authority"
cp "$WORK/history.lock" "$WORK/history.before-swap"
PATH="$WORK/head-spy:$PATH" KPM_SWAP_TARGET="$WORK/history.lock" \
KPM_SWAP_BYTES="$WORK/bad-digest.lock" KPM_SWAP_COUNT="$WORK/history-head.count" \
    "$TOOL" inspect "$ID" "$WORK/catalog" --authority "$WORK/authority" \
    --history-lock "$WORK/history.lock" >"$WORK/history-snapshot-swap.out"
test "$(sed -n '1p' "$WORK/history-head.count")" = 1 ||
    fail 'history lock pathname was not read exactly once for its private snapshot'
cmp "$WORK/history.lock" "$WORK/bad-digest.lock" ||
    fail 'head spy did not replace the original history path after snapshot'
cp "$WORK/history.before-swap" "$WORK/history.lock"

# Every pathname input is read-only in success and refusal. Hard-link count,
# inode, type, mode, bytes, and path remain stable.
chmod 640 "$WORK/catalog"
chmod 600 "$WORK/authority"
chmod 440 "$WORK/history.lock"
ln "$WORK/catalog" "$WORK/catalog.link"
state "$WORK/catalog" "$WORK/catalog.link" "$WORK/authority" "$WORK/history.lock" \
    >"$WORK/state.before"
"$TOOL" inspect "$ID" "$WORK/catalog" --authority "$WORK/authority" \
    --history-lock "$WORK/history.lock" >"$WORK/state-success.out"
state "$WORK/catalog" "$WORK/catalog.link" "$WORK/authority" "$WORK/history.lock" \
    >"$WORK/state.after-success"
cmp "$WORK/state.before" "$WORK/state.after-success" ||
    fail 'success mutated an input path, type, inode, link, mode, size, or bytes'
state "$WORK/changed-digest.catalog" >"$WORK/refusal-input.before"
expect_refusal 'read-only refusal' 'immutability violation' \
    inspect "$ID" "$WORK/changed-digest.catalog" --authority "$WORK/authority" \
    --history-lock "$WORK/history.lock"
state "$WORK/changed-digest.catalog" >"$WORK/refusal-input.after"
cmp "$WORK/refusal-input.before" "$WORK/refusal-input.after" ||
    fail 'refusal mutated its catalog input'
state "$WORK/catalog" "$WORK/catalog.link" "$WORK/authority" "$WORK/history.lock" \
    >"$WORK/state.after-refusal"
cmp "$WORK/state.before" "$WORK/state.after-refusal" ||
    fail 'refusal mutated an input path, type, inode, link, mode, size, or bytes'

ln -s "$WORK/catalog" "$WORK/catalog.symlink"
expect_refusal 'catalog symlink' 'not a regular non-symlink file' \
    inspect "$ID" "$WORK/catalog.symlink" --authority "$WORK/authority"
mkfifo "$WORK/catalog.fifo"
expect_refusal 'catalog FIFO' 'not a regular non-symlink file' \
    inspect "$ID" "$WORK/catalog.fifo" --authority "$WORK/authority"

# Two contradictory catalogs without history are independent first supplied
# observations. Neither creates an ambient ledger; only the explicit lock
# makes the second descriptor an immutability refusal.
mkdir -p "$WORK/sentinel-bin" "$WORK/hostile-home" "$WORK/hostile-xdg"
printf 'home marker\n' >"$WORK/hostile-home/marker"
printf 'xdg marker\n' >"$WORK/hostile-xdg/marker"
tree_state "$WORK/hostile-home" "$WORK/hostile-xdg" >"$WORK/ledger.before"
HOME="$WORK/hostile-home" XDG_CACHE_HOME="$WORK/hostile-xdg" \
    "$TOOL" inspect "$ID" "$WORK/catalog" --authority "$WORK/authority" \
    >"$WORK/ledger-a.out"
HOME="$WORK/hostile-home" XDG_CACHE_HOME="$WORK/hostile-xdg" \
    "$TOOL" inspect "$ID" "$WORK/changed-digest.catalog" --authority "$WORK/authority" \
    >"$WORK/ledger-b.out"
grep -Fq 'first observation passed' "$WORK/ledger-a.out" &&
    grep -Fq 'first observation passed' "$WORK/ledger-b.out" ||
    fail 'contradictory no-history catalogs were not independent first observations'
tree_state "$WORK/hostile-home" "$WORK/hostile-xdg" >"$WORK/ledger.after"
cmp "$WORK/ledger.before" "$WORK/ledger.after" ||
    fail 'first observation created or changed an ambient ledger'

# Hostile ambient network and home state cannot grant success or refusal an
# escape hatch. Reuse the common sentinel and compare hashes plus complete
# path/type/device/inode/link/mode state for every explicit and ambient input.
for network_command in curl wget fetch ftp sftp ssh nc ncat netcat telnet \
    openssl git host dig nslookup getent
do
    cp "$ROOT/tests/pm/network-sentinel.sh" "$WORK/sentinel-bin/$network_command"
done
chmod +x "$WORK/sentinel-bin"/*
state "$WORK/catalog" "$WORK/changed-digest.catalog" "$WORK/authority" \
    "$WORK/history.lock" >"$WORK/offline-input.before"
tree_state "$WORK/hostile-home" "$WORK/hostile-xdg" >"$WORK/ambient.before"
env -i PATH="$WORK/sentinel-bin:$PATH" \
HOME="$WORK/hostile-home" XDG_CACHE_HOME="$WORK/hostile-xdg" \
KPM_STORE="$WORK/ambient-store" KPM_NETWORK_SENTINEL="$WORK/network-called" \
http_proxy=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 \
ALL_PROXY=socks5://127.0.0.1:9 \
    "$TOOL" inspect "$ID" "$WORK/catalog" --authority "$WORK/authority" \
    >"$WORK/offline-first-observation.out"
grep -Fq 'first observation passed' "$WORK/offline-first-observation.out" ||
    fail 'no-history success did not survive hostile empty environment state'
env -i PATH="$WORK/sentinel-bin:$PATH" \
HOME="$WORK/hostile-home" XDG_CACHE_HOME="$WORK/hostile-xdg" \
KPM_STORE="$WORK/ambient-store" KPM_NETWORK_SENTINEL="$WORK/network-called" \
http_proxy=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9 \
HTTP_PROXY=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 ALL_PROXY=socks5://127.0.0.1:9 \
    "$TOOL" inspect "$ID" "$WORK/catalog" --authority "$WORK/authority" \
    --history-lock "$WORK/history.lock" >"$WORK/offline.out"
test ! -e "$WORK/network-called" || fail 'a network command was attempted on success'
if env -i PATH="$WORK/sentinel-bin:$PATH" \
    HOME="$WORK/hostile-home" XDG_CACHE_HOME="$WORK/hostile-xdg" \
    KPM_STORE="$WORK/ambient-store" KPM_NETWORK_SENTINEL="$WORK/network-called" \
    http_proxy=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 \
    ALL_PROXY=http://127.0.0.1:9 \
    "$TOOL" inspect "$ID" "$WORK/changed-digest.catalog" \
    --authority "$WORK/authority" --history-lock "$WORK/history.lock" \
    >"$WORK/offline-refusal.out" 2>&1
then
    fail 'hostile-environment changed descriptor was accepted'
fi
grep -Fq 'immutability violation' "$WORK/offline-refusal.out" ||
    fail 'hostile-environment refusal did not reach descriptor continuity'
test ! -e "$WORK/network-called" || fail 'a network command was attempted on refusal'
test ! -e "$WORK/ambient-store" || fail 'ambient KPM_STORE was used'
tree_state "$WORK/hostile-home" "$WORK/hostile-xdg" >"$WORK/ambient.after"
cmp "$WORK/ambient.before" "$WORK/ambient.after" ||
    fail 'hostile HOME or XDG state was mutated'
state "$WORK/catalog" "$WORK/changed-digest.catalog" "$WORK/authority" \
    "$WORK/history.lock" >"$WORK/offline-input.after"
cmp "$WORK/offline-input.before" "$WORK/offline-input.after" ||
    fail 'hostile success or refusal mutated explicit input state or bytes'

printf 'pm: catalog v1 authority, identity, bounds, strict grammar, and first observation: PASS\n'
printf 'pm: supplied lock selected/superseded continuity, withdrawal, and immutability: PASS\n'
printf 'pm: catalog v1 hostile precedence, offline behavior, and read-only inputs: PASS\n'
