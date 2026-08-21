#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
LOCK_TOOL=$ROOT/scripts/lock-v2.sh
STORE_TOOL=$ROOT/scripts/store.sh
WORK=$(mktemp -d "${TMPDIR:-/tmp}/kofun-pm-lock-v2-test.XXXXXX")
trap 'rm -rf "$WORK"' 0 1 2 15

fail() {
    printf 'pm: FAIL: lock-v2: %s\n' "$*" >&2
    exit 1
}

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | cut -d' ' -f1
    else
        shasum -a 256 | cut -d' ' -f1
    fi
}

STORE=$WORK/store
mkdir -p "$STORE" "$WORK/objects"

store() {
    sh "$STORE_TOOL" --store "$STORE" "$@"
}

entry_for() (
    digest=$1
    printf '%s/%s/%s\n' "$STORE" "$(printf '%s' "$digest" | cut -c1-2)" \
        "$(printf '%s' "$digest" | cut -c3-)"
)

add_object() {
    store add "$1" 2>/dev/null
}

write_lock() (
    body=$1
    out=$2
    covered=$WORK/covered
    {
        printf '# format: kofun-pm.lock/v2\n'
        printf '# columns: typed rows: package identity state version | metadata identity version size sha256 | file identity version path kind size sha256\n'
        printf '# tool: %s\n' "$tool_digest"
        printf '# requirements: %s\n' "$requirements_digest"
        cat "$body"
    } >"$covered"
    cat "$covered" >"$out"
    printf '# digest: %s\n' "$(sha256 <"$covered")" >>"$out"
)

verify() {
    env -i PATH="$PATH" sh "$LOCK_TOOL" inspect "$1" --store "$STORE"
}

expect_refusal() (
    label=$1
    needle=$2
    lock=$3
    if verify "$lock" >"$WORK/refusal.out" 2>&1; then
        fail "$label: hostile lock verified"
    fi
    grep -Fq -- "$needle" "$WORK/refusal.out" ||
        fail "$label: refusal did not name '$needle':
$(sed 's/^/    /' "$WORK/refusal.out")"
)

write_lock_with_metadata() (
    metadata_file=$1
    metadata_row=$2
    out=$3
    metadata_hash=$(add_object "$metadata_file")
    metadata_size=$(wc -c <"$metadata_file" | tr -d ' ')
    altered_body=$out.body
    awk -F '\t' -v OFS='\t' -v row="$metadata_row" \
        -v size="$metadata_size" -v hash="$metadata_hash" '
        NR == row { $4 = size; $5 = hash }
        { print }
    ' "$body" >"$altered_body"
    write_lock "$altered_body" "$out"
)

expect_metadata_refusal() (
    label=$1
    needle=$2
    metadata_file=$3
    metadata_row=${4:-5}
    hostile_lock=$WORK/metadata-$(printf '%s' "$label" | tr ' /' '--').lock
    write_lock_with_metadata "$metadata_file" "$metadata_row" "$hostile_lock"
    expect_refusal "$label" "$needle" "$hostile_lock"
)

test -x "$LOCK_TOOL" || fail 'the lock-v2 envelope verifier is not executable'
test -x "$STORE_TOOL" || fail 'the store adapter is not executable'

id_a=https://example.org/a/
id_b=https://example.org/b/v2/
id_local=https://example.org/local/

printf 'shared opaque bytes\n' >"$WORK/objects/shared-data"
printf 'fn main(): Int { 0 }\n' >"$WORK/objects/main-source"

shared=$(add_object "$WORK/objects/shared-data")
source=$(add_object "$WORK/objects/main-source")

size_shared=$(wc -c <"$WORK/objects/shared-data" | tr -d ' ')
size_source=$(wc -c <"$WORK/objects/main-source" | tr -d ' ')
unselected_size=$(printf 'unselected bytes\n' | wc -c | tr -d ' ')
unselected_digest=$(printf 'unselected bytes\n' | sha256)

{
    printf 'kofun-metadata/v1\n'
    printf 'identity\t%s\n' "$id_a"
    printf 'version\t1.0.0\n'
    # Superseded descriptors remain authenticated metadata, but their blobs
    # are not selected and therefore need no lock file row or store object.
    printf 'file\told.txt\tdata\t%s\t%s\n' \
        "$unselected_size" "$unselected_digest"
} >"$WORK/objects/meta-a-old"
{
    printf 'kofun-metadata/v1\n'
    printf 'identity\t%s\n' "$id_a"
    printf 'version\t1.2.0\n'
    printf 'dependency\t%s\t2.0.0\n' "$id_b"
    printf 'file\tREADME.md\tdata\t%s\t%s\n' "$size_shared" "$shared"
    printf 'file\tsrc/main.kofun\tsource\t%s\t%s\n' "$size_source" "$source"
} >"$WORK/objects/meta-a-selected"
{
    printf 'kofun-metadata/v1\n'
    printf 'identity\t%s\n' "$id_b"
    printf 'version\t2.0.0\n'
    printf 'file\tdata/shared.bin\tdata\t%s\t%s\n' "$size_shared" "$shared"
} >"$WORK/objects/meta-b"

meta_a_old=$(add_object "$WORK/objects/meta-a-old")
meta_a=$(add_object "$WORK/objects/meta-a-selected")
meta_b=$(add_object "$WORK/objects/meta-b")
size_meta_a_old=$(wc -c <"$WORK/objects/meta-a-old" | tr -d ' ')
size_meta_a=$(wc -c <"$WORK/objects/meta-a-selected" | tr -d ' ')
size_meta_b=$(wc -c <"$WORK/objects/meta-b" | tr -d ' ')
tool_digest=$(printf 'lock-v2 envelope tool\n' | sha256)
requirements_digest=$(printf 'lock-v2 requirements\n' | sha256)

body=$WORK/body
{
    printf 'package\t%s\tselected\t1.2.0\n' "$id_a"
    printf 'package\t%s\tselected\t2.0.0\n' "$id_b"
    printf 'package\t%s\tworkspace\t-\n' "$id_local"
    printf 'metadata\t%s\t1.0.0\t%s\t%s\n' "$id_a" "$size_meta_a_old" "$meta_a_old"
    printf 'metadata\t%s\t1.2.0\t%s\t%s\n' "$id_a" "$size_meta_a" "$meta_a"
    printf 'metadata\t%s\t2.0.0\t%s\t%s\n' "$id_b" "$size_meta_b" "$meta_b"
    printf 'file\t%s\t1.2.0\tREADME.md\tdata\t%s\t%s\n' "$id_a" "$size_shared" "$shared"
    printf 'file\t%s\t1.2.0\tsrc/main.kofun\tsource\t%s\t%s\n' "$id_a" "$size_source" "$source"
    # The same bytes under another identity are one store object and two
    # semantic descriptors. Deduplication must not collapse either lock row.
    printf 'file\t%s\t2.0.0\tdata/shared.bin\tdata\t%s\t%s\n' "$id_b" "$size_shared" "$shared"
} >"$body"

lock=$WORK/kofun.packages.lock
write_lock "$body" "$lock"
lock_before=$(sha256 <"$lock")
store_before=$(find "$STORE" -type f -print | LC_ALL=C sort | xargs sha256sum | sha256)
verify "$lock" >"$WORK/valid.out" 2>&1 ||
    fail "the canonical envelope did not verify: $(cat "$WORK/valid.out")"
grep -Fq 'inspected canonical envelope and strict metadata; selected metadata descriptors exactly matched lock file rows; 3 metadata and 3 file reference(s) matched private store snapshots' \
    "$WORK/valid.out" ||
    fail 'the positive fixture did not account for every metadata/file row'
grep -Fq 'catalog/history, dependency reachability/re-resolution, tool/requirements identity, writer/migration/fetch, and affine same-handle consumption remain outside this slice' \
    "$WORK/valid.out" ||
    fail 'the partial verifier did not state its remaining boundary'
test "$(sha256 <"$lock")" = "$lock_before" ||
    fail 'inspection changed the explicit lock input'
test "$(find "$STORE" -type f -print | LC_ALL=C sort | xargs sha256sum | sha256)" = "$store_before" ||
    fail 'inspection changed the explicit store input'
test ! -e "$(entry_for "$unselected_digest")" ||
    fail 'the superseded-only descriptor unexpectedly had a store object'

# Metadata mutations are content-addressed, installed in the store, reflected
# in the matching lock row, and then covered by a new lock self-digest. Each
# refusal therefore reaches the metadata parser or descriptor relation rather
# than succeeding only because an outer digest noticed the test edit.
sed '1s/.*/wrong-metadata-header/' "$WORK/objects/meta-a-selected" \
    >"$WORK/metadata-wrong-header"
expect_metadata_refusal 'metadata header' 'first line is not exactly kofun-metadata/v1' \
    "$WORK/metadata-wrong-header"

sed '2s#https://example\.org/a/#https://example.org/other/#' \
    "$WORK/objects/meta-a-selected" >"$WORK/metadata-wrong-identity"
expect_metadata_refusal 'metadata identity binding' 'identity does not match its lock row' \
    "$WORK/metadata-wrong-identity"

sed '3s/1\.2\.0/1.3.0/' "$WORK/objects/meta-a-selected" \
    >"$WORK/metadata-wrong-version"
expect_metadata_refusal 'metadata version binding' 'version does not match its lock row' \
    "$WORK/metadata-wrong-version"

awk 'NR == 1 { printf "%s\r\n", $0; next } { print }' \
    "$WORK/objects/meta-a-selected" >"$WORK/metadata-cr"
expect_metadata_refusal 'metadata CR' 'outside ASCII, HT, and LF' "$WORK/metadata-cr"

cp "$WORK/objects/meta-a-selected" "$WORK/metadata-nul"
printf '\000\n' >>"$WORK/metadata-nul"
expect_metadata_refusal 'metadata NUL' 'outside ASCII, HT, and LF' "$WORK/metadata-nul"

head -c -1 "$WORK/objects/meta-a-selected" >"$WORK/metadata-no-lf"
expect_metadata_refusal 'metadata final LF' 'metadata must end in exactly one LF' \
    "$WORK/metadata-no-lf"

awk 'NR == 4 { print "" } { print }' "$WORK/objects/meta-a-selected" \
    >"$WORK/metadata-blank"
expect_metadata_refusal 'metadata blank row' 'unknown or blank metadata row kind' \
    "$WORK/metadata-blank"

awk 'NR == 4 { print "# comment" } { print }' "$WORK/objects/meta-a-selected" \
    >"$WORK/metadata-comment"
expect_metadata_refusal 'metadata comment' 'unknown or blank metadata row kind' \
    "$WORK/metadata-comment"

awk 'NR == 4 { print $0 "\t"; next } { print }' \
    "$WORK/objects/meta-a-selected" >"$WORK/metadata-trailing-field"
expect_metadata_refusal 'metadata trailing field' 'dependency row must have three fields' \
    "$WORK/metadata-trailing-field"

awk 'NR == 3 { print; print "kofun-metadata/v1"; next } { print }' \
    "$WORK/objects/meta-a-selected" >"$WORK/metadata-duplicate-header"
expect_metadata_refusal 'metadata duplicate header' \
    'unknown or blank metadata row kind' "$WORK/metadata-duplicate-header"

awk 'NR == 4 { dependency = $0; next }
     { print }
     END { print dependency }' "$WORK/objects/meta-a-selected" \
    >"$WORK/metadata-dependency-after-file"
expect_metadata_refusal 'metadata dependency phase' 'dependency row appears after file rows' \
    "$WORK/metadata-dependency-after-file"

awk 'NR == 4 {
         print
         sub(/2\.0\.0$/, "2.1.0")
         print
         next
     }
     { print }' "$WORK/objects/meta-a-selected" \
    >"$WORK/metadata-duplicate-dependency"
expect_metadata_refusal 'metadata duplicate dependency' 'duplicate dependency identity' \
    "$WORK/metadata-duplicate-dependency"

awk -v higher='https://example.org/c/' 'NR == 4 {
         printf "dependency\t%s\t1.0.0\n", higher
     }
     { print }' "$WORK/objects/meta-a-selected" \
    >"$WORK/metadata-dependency-order"
expect_metadata_refusal 'metadata dependency order' \
    'dependency rows are not in strict identity-byte order' \
    "$WORK/metadata-dependency-order"

sed '4s#https://example\.org/b/v2/#https://127.1/#' \
    "$WORK/objects/meta-a-selected" >"$WORK/metadata-ip-dependency"
expect_metadata_refusal 'metadata numeric IP dependency' \
    'uses a forbidden numeric IP literal form' "$WORK/metadata-ip-dependency"

{
    printf 'kofun-metadata/v1\nidentity\t%s\nversion\t1.2.0\n' "$id_a"
    n=0
    while test "$n" -le 256; do
        printf 'dependency\thttps://deps.example.org/d%03d/\t1.0.0\n' "$n"
        n=$((n + 1))
    done
    printf 'file\tREADME.md\tdata\t%s\t%s\n' "$size_shared" "$shared"
} >"$WORK/metadata-too-many-dependencies"
expect_metadata_refusal 'metadata dependency count' 'direct dependency count exceeds 256' \
    "$WORK/metadata-too-many-dependencies"

sed '5,6d' "$WORK/objects/meta-a-selected" >"$WORK/metadata-no-files"
expect_metadata_refusal 'metadata missing file' 'metadata has no file row' \
    "$WORK/metadata-no-files"

sed '5s/README\.md/CON.txt/' "$WORK/objects/meta-a-selected" \
    >"$WORK/metadata-device-path"
expect_metadata_refusal 'metadata device path' 'Windows device segment' \
    "$WORK/metadata-device-path"

awk 'NR == 5 {
         print
         split($0, f, "\t")
         printf "file\treadme.MD\tdata\t%s\t%s\n", f[4], f[5]
         next
     }
     { print }' "$WORK/objects/meta-a-selected" >"$WORK/metadata-casefold"
expect_metadata_refusal 'metadata case-fold path' \
    'duplicates after ASCII case folding' "$WORK/metadata-casefold"

awk 'NR == 6 {
         split($0, f, "\t")
         printf "file\tsrc\tdata\t%s\t%s\n", f[4], f[5]
     }
     { print }' "$WORK/objects/meta-a-selected" >"$WORK/metadata-prefix"
expect_metadata_refusal 'metadata prefix path' 'descends through another file' \
    "$WORK/metadata-prefix"

awk 'NR == 5 { first = $0; next }
     NR == 6 { print; print first; next }
     { print }' "$WORK/objects/meta-a-selected" >"$WORK/metadata-file-order"
expect_metadata_refusal 'metadata file order' \
    'file rows are not in strict path-byte order' "$WORK/metadata-file-order"

sed '5s/\tdata\t/\texecutable\t/' "$WORK/objects/meta-a-selected" \
    >"$WORK/metadata-kind"
expect_metadata_refusal 'metadata file kind' 'neither source nor data' \
    "$WORK/metadata-kind"

awk -F '\t' -v OFS='\t' 'NR == 5 { $4 = "0" $4 } { print }' \
    "$WORK/objects/meta-a-selected" >"$WORK/metadata-leading-size"
expect_metadata_refusal 'metadata canonical size' 'not canonical unsigned decimal' \
    "$WORK/metadata-leading-size"

awk -F '\t' -v OFS='\t' 'NR == 5 { $4 = 67108865 } { print }' \
    "$WORK/objects/meta-a-selected" >"$WORK/metadata-oversize-file"
expect_metadata_refusal 'metadata file size bound' 'file size exceeds its bound' \
    "$WORK/metadata-oversize-file"

{
    printf 'kofun-metadata/v1\nidentity\t%s\nversion\t1.2.0\n' "$id_a"
    n=0
    while test "$n" -le 8; do
        printf 'file\tdata/f%02d\tdata\t67108864\t%s\n' "$n" \
            'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
        n=$((n + 1))
    done
} >"$WORK/metadata-package-bytes"
expect_metadata_refusal 'metadata package byte bound' \
    'metadata file bytes exceed 512 MiB' "$WORK/metadata-package-bytes"

awk -F '\t' -v OFS='\t' 'NR == 5 { $5 = toupper($5) } { print }' \
    "$WORK/objects/meta-a-selected" >"$WORK/metadata-uppercase-digest"
expect_metadata_refusal 'metadata canonical digest' 'not one lowercase sha256 digest' \
    "$WORK/metadata-uppercase-digest"

{
    printf 'kofun-metadata/v1\nidentity\t%s\nversion\t1.2.0\n' "$id_a"
    n=0
    while test "$n" -le 4096; do
        printf 'file\tdata/f%04d\tdata\t0\t%s\n' "$n" \
            'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
        n=$((n + 1))
    done
} >"$WORK/metadata-too-many-files"
expect_metadata_refusal 'metadata file count' 'file descriptor count exceeds 4096' \
    "$WORK/metadata-too-many-files"

{
    printf 'kofun-metadata/v1\nidentity\t%s\nversion\t1.2.0\nunknown\t' "$id_a"
    head -c 4097 /dev/zero | tr '\000' x
    printf '\n'
} >"$WORK/metadata-long-line"
expect_metadata_refusal 'metadata line bound' \
    'metadata line exceeds the 4096-byte structural bound' "$WORK/metadata-long-line"

{
    printf 'kofun-metadata/v1\nidentity\t%s\nversion\t1.2.0\n' "$id_a"
    n=0
    while test "$n" -le 4352; do
        printf '\n'
        n=$((n + 1))
    done
} >"$WORK/metadata-too-many-rows"
expect_metadata_refusal 'metadata row bound' \
    'metadata exceeds the 4355-row structural bound' "$WORK/metadata-too-many-rows"

# Aggregate bounds count every parsed metadata document before deduplication,
# including superseded versions whose file blobs are not selected.
: >"$WORK/aggregate-dependency-metadata-rows"
n=0
while test "$n" -le 64; do
    metadata_file=$WORK/objects/meta-dependency-aggregate-$n
    {
        printf 'kofun-metadata/v1\nidentity\t%s\nversion\t1.%s.0\n' "$id_a" "$n"
        dependency=0
        while test "$dependency" -le 255; do
            printf 'dependency\thttps://deps.example.org/d%03d/\t1.0.0\n' \
                "$dependency"
            dependency=$((dependency + 1))
        done
        printf 'file\tdata.bin\tdata\t%s\t%s\n' "$size_shared" "$shared"
    } >"$metadata_file"
    metadata_hash=$(add_object "$metadata_file")
    metadata_size=$(wc -c <"$metadata_file" | tr -d ' ')
    printf 'metadata\t%s\t1.%s.0\t%s\t%s\n' \
        "$id_a" "$n" "$metadata_size" "$metadata_hash" \
        >>"$WORK/aggregate-dependency-metadata-rows"
    n=$((n + 1))
done
{
    printf 'package\t%s\tselected\t1.64.0\n' "$id_a"
    cat "$WORK/aggregate-dependency-metadata-rows"
    printf 'file\t%s\t1.64.0\tdata.bin\tdata\t%s\t%s\n' \
        "$id_a" "$size_shared" "$shared"
} >"$WORK/metadata-dependency-aggregate.body"
write_lock "$WORK/metadata-dependency-aggregate.body" \
    "$WORK/metadata-dependency-aggregate.lock"
expect_refusal 'metadata dependency aggregate' \
    'remote metadata dependency edges exceed the 16384 bound' \
    "$WORK/metadata-dependency-aggregate.lock"
grep -Fq 'actual   16640' "$WORK/refusal.out" ||
    fail 'metadata dependency aggregate did not count every repeated edge'

: >"$WORK/aggregate-file-metadata-rows"
n=0
while test "$n" -le 16; do
    metadata_file=$WORK/objects/meta-file-aggregate-$n
    {
        printf 'kofun-metadata/v1\nidentity\t%s\nversion\t1.%s.0\n' "$id_a" "$n"
        descriptor=0
        while test "$descriptor" -le 4095; do
            printf 'file\tdata/f%04d\tdata\t0\t%s\n' "$descriptor" \
                'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
            descriptor=$((descriptor + 1))
        done
    } >"$metadata_file"
    metadata_hash=$(add_object "$metadata_file")
    metadata_size=$(wc -c <"$metadata_file" | tr -d ' ')
    printf 'metadata\t%s\t1.%s.0\t%s\t%s\n' \
        "$id_a" "$n" "$metadata_size" "$metadata_hash" \
        >>"$WORK/aggregate-file-metadata-rows"
    n=$((n + 1))
done
{
    printf 'package\t%s\tselected\t1.16.0\n' "$id_a"
    cat "$WORK/aggregate-file-metadata-rows"
    descriptor=0
    while test "$descriptor" -le 4095; do
        printf 'file\t%s\t1.16.0\tdata/f%04d\tdata\t0\t%s\n' \
            "$id_a" "$descriptor" \
            'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
        descriptor=$((descriptor + 1))
    done
} >"$WORK/metadata-file-aggregate.body"
write_lock "$WORK/metadata-file-aggregate.body" "$WORK/metadata-file-aggregate.lock"
expect_refusal 'metadata file aggregate' \
    'metadata file descriptors exceed the 65536 bound' \
    "$WORK/metadata-file-aggregate.lock"
grep -Fq 'actual   69632' "$WORK/refusal.out" ||
    fail 'metadata file aggregate did not count superseded descriptors'

# Valid metadata with a different selected descriptor set reaches the exact
# two-way relation check before file-row-driven snapshot validation begins.
sed '5d' "$WORK/objects/meta-a-selected" >"$WORK/metadata-bijection-missing"
expect_metadata_refusal 'metadata bijection missing' \
    'selected metadata file descriptors do not exactly match lock file rows' \
    "$WORK/metadata-bijection-missing"

awk 'NR == 6 {
         split($0, f, "\t")
         printf "file\textra.bin\tdata\t%s\t%s\n", f[4], f[5]
     }
     { print }' "$WORK/objects/meta-a-selected" >"$WORK/metadata-bijection-extra"
expect_metadata_refusal 'metadata bijection extra' \
    'selected metadata file descriptors do not exactly match lock file rows' \
    "$WORK/metadata-bijection-extra"

sed '5s/README\.md/README.txt/' "$WORK/objects/meta-a-selected" \
    >"$WORK/metadata-bijection-path"
expect_metadata_refusal 'metadata bijection path' \
    'selected metadata file descriptors do not exactly match lock file rows' \
    "$WORK/metadata-bijection-path"

sed '5s/\tdata\t/\tsource\t/' "$WORK/objects/meta-a-selected" \
    >"$WORK/metadata-bijection-kind"
expect_metadata_refusal 'metadata bijection kind' \
    'selected metadata file descriptors do not exactly match lock file rows' \
    "$WORK/metadata-bijection-kind"

awk -F '\t' -v OFS='\t' 'NR == 5 { $4 = $4 + 1 } { print }' \
    "$WORK/objects/meta-a-selected" >"$WORK/metadata-bijection-size"
expect_metadata_refusal 'metadata bijection size' \
    'selected metadata file descriptors do not exactly match lock file rows' \
    "$WORK/metadata-bijection-size"

awk -F '\t' -v OFS='\t' -v zero="$(printf '%064d' 0)" \
    'NR == 5 { $5 = zero } { print }' "$WORK/objects/meta-a-selected" \
    >"$WORK/metadata-bijection-digest"
expect_metadata_refusal 'metadata bijection digest' \
    'selected metadata file descriptors do not exactly match lock file rows' \
    "$WORK/metadata-bijection-digest"

sed '1s/.*/wrong-superseded-header/' "$WORK/objects/meta-a-old" \
    >"$WORK/metadata-bad-superseded"
expect_metadata_refusal 'superseded metadata parse' \
    'first line is not exactly kofun-metadata/v1' "$WORK/metadata-bad-superseded" 4

# Descriptor comparison precedes every file-row-driven snapshot. With one
# selected blob missing, a mismatched metadata plan must still fail as a
# bijection; the canonical lock then reaches the file branch and names the
# missing identity/version/path.
write_lock_with_metadata "$WORK/metadata-bijection-path" 5 \
    "$WORK/bijection-before-missing-file.lock"
rm -f "$(entry_for "$source")"
expect_refusal 'bijection before missing selected file' \
    'selected metadata file descriptors do not exactly match lock file rows' \
    "$WORK/bijection-before-missing-file.lock"
if verify "$lock" >"$WORK/missing-selected-file.out" 2>&1; then
    fail 'a canonical lock accepted a missing selected file object'
fi
grep -Fq 'file object is missing or corrupt' "$WORK/missing-selected-file.out" ||
    fail 'missing selected file did not reach the file snapshot refusal'
grep -Fq "identity $id_a" "$WORK/missing-selected-file.out" ||
    fail 'missing selected file refusal omitted its identity'
grep -Fq 'version  1.2.0' "$WORK/missing-selected-file.out" ||
    fail 'missing selected file refusal omitted its version'
grep -Fq 'path     src/main.kofun' "$WORK/missing-selected-file.out" ||
    fail 'missing selected file refusal omitted its path'
source_again=$(add_object "$WORK/objects/main-source")
test "$source_again" = "$source" || fail 'restoring selected source changed its digest'

# A hand edit is caught before any semantic interpretation.
sed 's/selected\t1\.2\.0/selected\t1.3.0/' "$lock" >"$WORK/edited.lock"
expect_refusal 'self digest' 'lock digest does not cover' "$WORK/edited.lock"

# Semantic mutations are re-signed so each reaches the intended structural
# refusal rather than passing only because the self digest noticed an edit.
awk 'NR == 1 { first = $0; next }
     NR == 2 { print; print first; next }
     { print }' "$body" >"$WORK/reordered.body"
write_lock "$WORK/reordered.body" "$WORK/reordered.lock"
expect_refusal 'package order' 'strict identity-byte order' "$WORK/reordered.lock"

{
    printf 'kofun-metadata/v1\nidentity\t%s\nversion\t1.0.0\n' "$id_a"
    printf 'file\t10\tdata\t%s\t%s\n' "$size_shared" "$shared"
    printf 'file\t2\tdata\t%s\t%s\n' "$size_shared" "$shared"
} >"$WORK/objects/meta-numeric-path"
meta_numeric=$(add_object "$WORK/objects/meta-numeric-path")
size_meta_numeric=$(wc -c <"$WORK/objects/meta-numeric-path" | tr -d ' ')
{
    printf 'package\t%s\tselected\t1.0.0\n' "$id_a"
    printf 'metadata\t%s\t1.0.0\t%s\t%s\n' \
        "$id_a" "$size_meta_numeric" "$meta_numeric"
    printf 'file\t%s\t1.0.0\t10\tdata\t%s\t%s\n' \
        "$id_a" "$size_shared" "$shared"
    printf 'file\t%s\t1.0.0\t2\tdata\t%s\t%s\n' \
        "$id_a" "$size_shared" "$shared"
} >"$WORK/numeric-path-valid.body"
write_lock "$WORK/numeric-path-valid.body" "$WORK/numeric-path-valid.lock"
verify "$WORK/numeric-path-valid.lock" >"$WORK/numeric-path-valid.out" 2>&1 ||
    fail 'canonical byte order 10 then 2 was treated as numeric order'

awk 'NR == 3 { first = $0; next }
     NR == 4 { print; print first; next }
     { print }' "$WORK/numeric-path-valid.body" >"$WORK/numeric-path-hostile.body"
write_lock "$WORK/numeric-path-hostile.body" "$WORK/numeric-path-hostile.lock"
expect_refusal 'numeric path byte order' 'file rows are not in identity/version/path order' \
    "$WORK/numeric-path-hostile.lock"

{
    printf 'kofun-metadata/v1\nidentity\t%s\nversion\t1.2.0\n' "$id_a"
    printf 'file\told.bin\tdata\t%s\t%s\n' "$size_shared" "$shared"
} >"$WORK/objects/meta-semantic-old"
{
    printf 'kofun-metadata/v1\nidentity\t%s\nversion\t1.10.0\n' "$id_a"
    printf 'file\tdata.bin\tdata\t%s\t%s\n' "$size_shared" "$shared"
} >"$WORK/objects/meta-semantic-selected"
meta_semantic_old=$(add_object "$WORK/objects/meta-semantic-old")
meta_semantic_selected=$(add_object "$WORK/objects/meta-semantic-selected")
size_meta_semantic_old=$(wc -c <"$WORK/objects/meta-semantic-old" | tr -d ' ')
size_meta_semantic_selected=$(wc -c <"$WORK/objects/meta-semantic-selected" | tr -d ' ')
{
    printf 'package\t%s\tselected\t1.10.0\n' "$id_a"
    printf 'metadata\t%s\t1.2.0\t%s\t%s\n' \
        "$id_a" "$size_meta_semantic_old" "$meta_semantic_old"
    printf 'metadata\t%s\t1.10.0\t%s\t%s\n' \
        "$id_a" "$size_meta_semantic_selected" "$meta_semantic_selected"
    printf 'file\t%s\t1.10.0\tdata.bin\tdata\t%s\t%s\n' \
        "$id_a" "$size_shared" "$shared"
} >"$WORK/semantic-order-valid.body"
write_lock "$WORK/semantic-order-valid.body" "$WORK/semantic-order-valid.lock"
verify "$WORK/semantic-order-valid.lock" >"$WORK/semantic-order-valid.out" 2>&1 ||
    fail 'semantic metadata order 1.2.0 then 1.10.0 was treated as byte order'

awk 'NR == 2 { first = $0; next }
     NR == 3 { print; print first; next }
     { print }' "$WORK/semantic-order-valid.body" >"$WORK/semantic-order-hostile.body"
write_lock "$WORK/semantic-order-hostile.body" "$WORK/semantic-order-hostile.lock"
expect_refusal 'semantic metadata order' 'metadata rows are not in identity/semantic-version order' \
    "$WORK/semantic-order-hostile.lock"

awk 'NR == 4 { print $0 "\t"; next } { print }' "$body" >"$WORK/trailing.body"
write_lock "$WORK/trailing.body" "$WORK/trailing.lock"
expect_refusal 'trailing field' 'metadata row must have five fields' "$WORK/trailing.lock"

awk 'NR == 1 { printf "%s\r\n", $0; next } { print }' "$body" \
    >"$WORK/cr.body"
write_lock "$WORK/cr.body" "$WORK/cr.lock"
expect_refusal 'CR byte' 'outside ASCII, HT, and LF' "$WORK/cr.lock"

cp "$body" "$WORK/nul.body"
printf '\000\n' >>"$WORK/nul.body"
write_lock "$WORK/nul.body" "$WORK/nul.lock"
expect_refusal 'NUL byte' 'outside ASCII, HT, and LF' "$WORK/nul.lock"

{
    n=0
    while test "$n" -le 82944; do
        printf '\n'
        n=$((n + 1))
    done
} >"$WORK/too-many-rows.body"
write_lock "$WORK/too-many-rows.body" "$WORK/too-many-rows.lock"
expect_refusal 'global body row bound' 'lock body exceeds the 82944-row structural bound' \
    "$WORK/too-many-rows.lock"

{
    printf 'unknown\t'
    head -c 4097 /dev/zero | tr '\000' x
    printf '\n'
} >"$WORK/long-line.body"
write_lock "$WORK/long-line.body" "$WORK/long-line.lock"
expect_refusal 'global line bound' 'lock line exceeds the 4096-byte structural bound' \
    "$WORK/long-line.lock"

awk 'NR == 4 { print "" } { print }' "$body" >"$WORK/blank.body"
write_lock "$WORK/blank.body" "$WORK/blank.lock"
expect_refusal 'blank row' 'unknown or blank lock row kind' "$WORK/blank.lock"

awk 'NR == 4 { print "unknown\trow"; next } { print }' "$body" \
    >"$WORK/unknown.body"
write_lock "$WORK/unknown.body" "$WORK/unknown.lock"
expect_refusal 'unknown row' 'unknown or blank lock row kind' "$WORK/unknown.lock"

awk -F'\t' -v OFS='\t' 'NR == 4 { $5 = "ABC" } { print }' "$body" \
    >"$WORK/bad-digest.body"
write_lock "$WORK/bad-digest.body" "$WORK/bad-digest.lock"
expect_refusal 'non-canonical digest' 'not one lowercase sha256 digest' \
    "$WORK/bad-digest.lock"

awk -F'\t' -v OFS='\t' 'NR == 4 { $4 = "0" $4 } { print }' "$body" \
    >"$WORK/leading-zero.body"
write_lock "$WORK/leading-zero.body" "$WORK/leading-zero.lock"
expect_refusal 'leading-zero size' 'is not canonical unsigned decimal' \
    "$WORK/leading-zero.lock"

awk -F'\t' -v OFS='\t' 'NR == 4 { $4 = 1048577 } { print }' "$body" \
    >"$WORK/oversize-metadata.body"
write_lock "$WORK/oversize-metadata.body" "$WORK/oversize-metadata.lock"
expect_refusal 'metadata size bound' 'metadata size exceeds its bound' \
    "$WORK/oversize-metadata.lock"

{
    printf 'package\t%s\tselected\t1.64.0\n' "$id_a"
    n=0
    while test "$n" -le 64; do
        printf 'metadata\t%s\t1.%s.0\t1048576\t%s\n' "$id_a" "$n" "$meta_a"
        n=$((n + 1))
    done
    printf 'file\t%s\t1.64.0\tdata.bin\tdata\t%s\t%s\n' \
        "$id_a" "$size_shared" "$shared"
} >"$WORK/metadata-total.body"
write_lock "$WORK/metadata-total.body" "$WORK/metadata-total.lock"
expect_refusal 'metadata aggregate bound' 'closure metadata bytes exceed 64 MiB' \
    "$WORK/metadata-total.lock"

{
    printf 'package\t%s\tselected\t1.4096.0\n' "$id_a"
    n=0
    while test "$n" -le 4096; do
        printf 'metadata\t%s\t1.%s.0\t0\t%s\n' "$id_a" "$n" "$meta_a"
        n=$((n + 1))
    done
    printf 'file\t%s\t1.4096.0\tdata.bin\tdata\t%s\t%s\n' \
        "$id_a" "$size_shared" "$shared"
} >"$WORK/metadata-count.body"
write_lock "$WORK/metadata-count.body" "$WORK/metadata-count.lock"
expect_refusal 'catalog version count' 'metadata versions for one identity exceed 4096' \
    "$WORK/metadata-count.lock"

empty_digest=$(printf '' | sha256)
{
    printf 'package\t%s\tselected\t1.0.0\n' "$id_a"
    printf 'metadata\t%s\t1.0.0\t0\t%s\n' "$id_a" "$empty_digest"
    n=0
    while test "$n" -le 4096; do
        printf 'file\t%s\t1.0.0\tdata/file-%04d.bin\tdata\t0\t%s\n' \
            "$id_a" "$n" "$empty_digest"
        n=$((n + 1))
    done
} >"$WORK/file-count.body"
write_lock "$WORK/file-count.body" "$WORK/file-count.lock"
expect_refusal 'files per version count' 'files for one selected version exceed 4096' \
    "$WORK/file-count.lock"

sed 's#https://example\.org/a/#https://Example.org/a/#g' "$body" \
    >"$WORK/invalid-identity.body"
write_lock "$WORK/invalid-identity.body" "$WORK/invalid-identity.lock"
expect_refusal 'canonical identity' 'host is not lowercase DNS A-label form' \
    "$WORK/invalid-identity.lock"

sed 's#https://example\.org/a/#https://127.0.0.1/a/#g' "$body" \
    >"$WORK/ip-identity.body"
write_lock "$WORK/ip-identity.body" "$WORK/ip-identity.lock"
expect_refusal 'IP identity' 'uses a forbidden numeric IP literal form' "$WORK/ip-identity.lock"

for hostile_host in 127.1 2130706433 0x7f000001 0x7f.0x1; do
    hostile_label=$(printf '%s' "$hostile_host" | tr '.' '-')
    sed "s#https://example\\.org/a/#https://$hostile_host/a/#g" "$body" \
        >"$WORK/ip-$hostile_label.body"
    write_lock "$WORK/ip-$hostile_label.body" "$WORK/ip-$hostile_label.lock"
    expect_refusal "legacy IP identity $hostile_host" \
        'uses a forbidden numeric IP literal form' "$WORK/ip-$hostile_label.lock"
done

sed 's/1\.2\.0/1.02.0/g' "$body" >"$WORK/invalid-version.body"
write_lock "$WORK/invalid-version.body" "$WORK/invalid-version.lock"
expect_refusal 'canonical semver' 'component is not canonical unsigned decimal' \
    "$WORK/invalid-version.lock"

sed 's/2\.0\.0/3.0.0/g' "$body" >"$WORK/major-mismatch.body"
write_lock "$WORK/major-mismatch.body" "$WORK/major-mismatch.lock"
expect_refusal 'identity major mismatch' 'does not carry major 3' \
    "$WORK/major-mismatch.lock"

awk 'NR == 1 { print; print; next } { print }' "$body" \
    >"$WORK/duplicate-package.body"
write_lock "$WORK/duplicate-package.body" "$WORK/duplicate-package.lock"
expect_refusal 'duplicate package' 'duplicate package identity' \
    "$WORK/duplicate-package.lock"

awk 'NR == 4 { print; print; next } { print }' "$body" \
    >"$WORK/duplicate-metadata.body"
write_lock "$WORK/duplicate-metadata.body" "$WORK/duplicate-metadata.lock"
expect_refusal 'duplicate metadata' 'duplicate metadata row' \
    "$WORK/duplicate-metadata.lock"

awk 'NR == 7 { print; print; next } { print }' "$body" \
    >"$WORK/duplicate-file.body"
write_lock "$WORK/duplicate-file.body" "$WORK/duplicate-file.lock"
expect_refusal 'duplicate file' 'duplicate file row' "$WORK/duplicate-file.lock"

sed '5d;7d;8d' "$body" >"$WORK/missing-selected.body"
write_lock "$WORK/missing-selected.body" "$WORK/missing-selected.lock"
expect_refusal 'missing selected metadata' 'has no matching metadata row' \
    "$WORK/missing-selected.lock"

awk -v id='https://example.org/c/' -v size="$size_meta_b" -v hash="$meta_b" \
    'NR == 7 { printf "metadata\t%s\t1.0.0\t%s\t%s\n", id, size, hash }
     { print }' "$body" >"$WORK/orphan-metadata.body"
write_lock "$WORK/orphan-metadata.body" "$WORK/orphan-metadata.lock"
expect_refusal 'orphan metadata' 'orphan metadata identity' \
    "$WORK/orphan-metadata.lock"

awk -v id="$id_local" -v size="$size_meta_b" -v hash="$meta_b" \
    'NR == 7 { printf "metadata\t%s\t1.0.0\t%s\t%s\n", id, size, hash }
     { print }' "$body" >"$WORK/workspace-metadata.body"
write_lock "$WORK/workspace-metadata.body" "$WORK/workspace-metadata.lock"
expect_refusal 'workspace metadata' 'workspace has metadata' \
    "$WORK/workspace-metadata.lock"

awk -v id='https://example.org/c/' -v size="$size_shared" -v hash="$shared" \
    '{ print }
     END { printf "file\t%s\t1.0.0\tdata.bin\tdata\t%s\t%s\n", id, size, hash }' \
    "$body" >"$WORK/orphan-file.body"
write_lock "$WORK/orphan-file.body" "$WORK/orphan-file.lock"
expect_refusal 'orphan file' 'orphan file identity' "$WORK/orphan-file.lock"

awk -F'\t' -v OFS='\t' '
    NR == 1 { $4 = "1.0.0" }
    (NR == 7 || NR == 8) { $3 = "1.0.0" }
    { print }
' "$body" >"$WORK/not-maximum.body"
write_lock "$WORK/not-maximum.body" "$WORK/not-maximum.lock"
expect_refusal 'selected maximum' 'selected version is not the maximum recorded metadata version' \
    "$WORK/not-maximum.lock"

sed 's/\t1\.2\.0\tREADME\.md/\t1.0.0\tREADME.md/' "$body" \
    >"$WORK/superseded-file.body"
write_lock "$WORK/superseded-file.body" "$WORK/superseded-file.lock"
expect_refusal 'superseded file' 'not for the selected version' \
    "$WORK/superseded-file.lock"

sed 's/\tREADME\.md\t/\tCON.txt\t/' "$body" >"$WORK/device.body"
write_lock "$WORK/device.body" "$WORK/device.lock"
expect_refusal 'device path' 'Windows device segment' "$WORK/device.lock"

sed 's/\tREADME\.md\t/\t..\/escape\t/' "$body" >"$WORK/parent-path.body"
write_lock "$WORK/parent-path.body" "$WORK/parent-path.lock"
expect_refusal 'parent path' 'forbidden segment' "$WORK/parent-path.lock"

awk 'NR == 7 {
         print
         split($0, f, "\t")
         printf "file\t%s\t%s\treadme.MD\tdata\t%s\t%s\n", f[2], f[3], f[6], f[7]
         next
     }
     { print }' "$body" >"$WORK/casefold.body"
write_lock "$WORK/casefold.body" "$WORK/casefold.lock"
expect_refusal 'case-fold duplicate' 'duplicates after ASCII case folding' \
    "$WORK/casefold.lock"

awk 'NR == 8 {
         split($0, f, "\t")
         printf "file\t%s\t%s\tSrc\tdata\t%s\t%s\n", f[2], f[3], f[6], f[7]
     }
     { print }' "$body" >"$WORK/prefix.body"
write_lock "$WORK/prefix.body" "$WORK/prefix.lock"
expect_refusal 'case-fold prefix collision' 'descends through another file' \
    "$WORK/prefix.lock"

awk -F'\t' -v OFS='\t' 'NR == 8 { $5 = "executable" } { print }' "$body" \
    >"$WORK/invalid-kind.body"
write_lock "$WORK/invalid-kind.body" "$WORK/invalid-kind.lock"
expect_refusal 'file kind' 'neither source nor data' "$WORK/invalid-kind.lock"

wrong_size=$((size_meta_a_old + 1))
awk -F'\t' -v OFS='\t' -v wrong="$wrong_size" \
    'NR == 4 { $4 = wrong } { print }' "$body" >"$WORK/wrong-size.body"
write_lock "$WORK/wrong-size.body" "$WORK/wrong-size.lock"
expect_refusal 'store size' 'size mismatch is refused before hashing' \
    "$WORK/wrong-size.lock"

awk -F'\t' -v OFS='\t' -v hash="$shared" -v wrong="$((size_shared + 1))" \
    'NR == 9 { $6 = wrong; $7 = hash } { print }' "$body" \
    >"$WORK/conflicting-size.body"
write_lock "$WORK/conflicting-size.body" "$WORK/conflicting-size.lock"
expect_refusal 'digest size conflict' 'one digest carries conflicting sizes' \
    "$WORK/conflicting-size.lock"

rm -f "$(entry_for "$meta_b")"
expect_refusal 'missing store object' 'object is missing or corrupt' "$lock"
meta_b_again=$(add_object "$WORK/objects/meta-b")
test "$meta_b_again" = "$meta_b" || fail 'restoring metadata changed its digest'

meta_a_entry=$(entry_for "$meta_a")
chmod 644 "$meta_a_entry"
printf 'corrupt metadata\n' >"$meta_a_entry"
chmod 444 "$meta_a_entry"
expect_refusal 'corrupt store object' 'object is missing or corrupt' "$lock"
rm -f "$meta_a_entry"
meta_a_again=$(add_object "$WORK/objects/meta-a-selected")
test "$meta_a_again" = "$meta_a" || fail 'restoring corrupt metadata changed its digest'

# Source is UTF-8; data is opaque. The same invalid byte is refused in the
# source row but succeeds when that descriptor kind is data.
printf '\377' >"$WORK/objects/non-utf8"
non_utf8=$(add_object "$WORK/objects/non-utf8")
{
    printf 'kofun-metadata/v1\nidentity\t%s\nversion\t1.2.0\n' "$id_a"
    printf 'dependency\t%s\t2.0.0\n' "$id_b"
    printf 'file\tREADME.md\tdata\t%s\t%s\n' "$size_shared" "$shared"
    printf 'file\tsrc/main.kofun\tsource\t1\t%s\n' "$non_utf8"
} >"$WORK/objects/meta-non-utf8-source"
meta_non_utf8_source=$(add_object "$WORK/objects/meta-non-utf8-source")
size_meta_non_utf8_source=$(wc -c <"$WORK/objects/meta-non-utf8-source" | tr -d ' ')
awk -F'\t' -v OFS='\t' -v metadata_hash="$meta_non_utf8_source" \
    -v metadata_size="$size_meta_non_utf8_source" -v file_hash="$non_utf8" '
    NR == 5 { $4 = metadata_size; $5 = metadata_hash }
    NR == 8 { $6 = 1; $7 = file_hash }
    { print }
' "$body" >"$WORK/non-utf8-source.body"
write_lock "$WORK/non-utf8-source.body" "$WORK/non-utf8-source.lock"
expect_refusal 'source UTF-8' 'locked source is not valid UTF-8' \
    "$WORK/non-utf8-source.lock"
{
    printf 'kofun-metadata/v1\nidentity\t%s\nversion\t2.0.0\n' "$id_b"
    printf 'file\tdata/shared.bin\tdata\t1\t%s\n' "$non_utf8"
} >"$WORK/objects/meta-opaque-data"
meta_opaque_data=$(add_object "$WORK/objects/meta-opaque-data")
size_meta_opaque_data=$(wc -c <"$WORK/objects/meta-opaque-data" | tr -d ' ')
awk -F'\t' -v OFS='\t' -v metadata_hash="$meta_opaque_data" \
    -v metadata_size="$size_meta_opaque_data" -v file_hash="$non_utf8" '
    NR == 6 { $4 = metadata_size; $5 = metadata_hash }
    NR == 9 { $6 = 1; $7 = file_hash }
    { print }
' "$body" >"$WORK/opaque-data.body"
write_lock "$WORK/opaque-data.body" "$WORK/opaque-data.lock"
verify "$WORK/opaque-data.lock" >"$WORK/opaque-data.out" 2>&1 ||
    fail 'an opaque data byte was incorrectly subjected to source UTF-8 rules'

# Byte grammar and terminal framing are checked before rows.
cp "$lock" "$WORK/after-digest.lock"
printf 'extra\n' >>"$WORK/after-digest.lock"
expect_refusal 'bytes after digest' 'final line is not one canonical lock digest' \
    "$WORK/after-digest.lock"

head -c -1 "$lock" >"$WORK/no-final-lf.lock"
expect_refusal 'missing final LF' 'must end in exactly one LF' \
    "$WORK/no-final-lf.lock"

if sh "$LOCK_TOOL" inspect "$lock" --store relative \
    >"$WORK/relative.out" 2>&1
then
    fail 'the lock verifier accepted an ambient relative store boundary'
fi
grep -Fq 'must be an absolute path' "$WORK/relative.out" ||
    fail 'relative store refusal was not named'

sed 's/kofun-pm\.lock\/v2/kofun-pm.lock\/v1/' "$lock" >"$WORK/v1.lock"
if sh "$LOCK_TOOL" inspect "$WORK/v1.lock" --store "$STORE" \
    >"$WORK/v1.out" 2>&1
then
    fail 'the v2 inspector accepted or migrated a v1 lock'
fi
grep -Fq 'lock v1 remains frozen' "$WORK/v1.out" ||
    fail 'v1 refusal did not name the frozen reader and explicit migration boundary'

printf 'pm: lock v2 envelope order, relations, self-digest, and named-store snapshots: PASS\n'
printf 'pm: metadata v1 grammar, aggregate bounds, and selected descriptor bijection: PASS\n'
printf 'pm: lock v2 hostile fields, paths, framing, missing bytes, and source UTF-8: PASS\n'
