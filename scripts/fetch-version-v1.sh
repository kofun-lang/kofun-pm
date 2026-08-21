#!/bin/sh
set -eu

# Acquire one exact version from one supplied authority/catalog plan. The
# catalog alone derives metadata; its complete strict descriptor set is frozen
# before the first blob request, and every file must pass an independent store
# snapshot plus source/data validation before one version-level success.
#
#   scripts/fetch-version-v1.sh acquire IDENTITY VERSION \
#     --catalog CATALOG --authority AUTHORITY --ipv4 A.B.C.D \
#     --ca-file CA_PEM --store ABSOLUTE_STORE

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CATALOG_PLAN_TOOL=$ROOT/scripts/catalog-v1-plan.sh
METADATA_PLAN_TOOL=$ROOT/scripts/metadata-v1-plan.sh
OBJECT_TOOL=$ROOT/scripts/fetch-object-v1.sh
FETCH_TOOL=$ROOT/scripts/fetch-artifact-v1.sh
STORE_TOOL=$ROOT/scripts/store.sh
PROTOCOL_VALIDATOR=$ROOT/scripts/protocol-v1-validate.awk
REQUEST_VALIDATOR=$ROOT/scripts/metadata-request-v1-validate.awk
AUTHORITY_VALIDATOR=$ROOT/scripts/authority-v1-validate.awk
CATALOG_VALIDATOR=$ROOT/scripts/catalog-v1-validate.awk
METADATA_DESCRIPTOR_VALIDATOR=$ROOT/scripts/metadata-descriptor-v1-validate.awk
METADATA_VALIDATOR=$ROOT/scripts/metadata-v1-validate.awk
FETCH_VALIDATOR=$ROOT/scripts/fetch-artifact-v1-validate.awk
SAFE_PATH=/usr/bin:/bin
MAX_CA_BYTES=1048576

fail() {
    printf 'fetch-version-v1: %s\n' "$*" >&2
    exit 1
}

usage() {
    fail 'usage: scripts/fetch-version-v1.sh acquire IDENTITY VERSION --catalog CATALOG --authority AUTHORITY --ipv4 A.B.C.D --ca-file CA_PEM --store ABSOLUTE_STORE'
}

test "${1:-}" = acquire && test "$#" -ge 3 || usage
IDENTITY=$2
VERSION=$3
shift 3
CATALOG=
AUTHORITY=
IPV4=
CA_FILE=
STORE=
seen_catalog=0
seen_authority=0
seen_ipv4=0
seen_ca=0
seen_store=0
while test "$#" -gt 0; do
    option=$1
    shift
    case $option in
        --catalog)
            test "$seen_catalog" -eq 0 && test "$#" -gt 0 || usage
            seen_catalog=1; CATALOG=$1; shift
            ;;
        --authority)
            test "$seen_authority" -eq 0 && test "$#" -gt 0 || usage
            seen_authority=1; AUTHORITY=$1; shift
            ;;
        --ipv4)
            test "$seen_ipv4" -eq 0 && test "$#" -gt 0 || usage
            seen_ipv4=1; IPV4=$1; shift
            ;;
        --ca-file)
            test "$seen_ca" -eq 0 && test "$#" -gt 0 || usage
            seen_ca=1; CA_FILE=$1; shift
            ;;
        --store)
            test "$seen_store" -eq 0 && test "$#" -gt 0 || usage
            seen_store=1; STORE=$1; shift
            ;;
        *) usage ;;
    esac
done
test "$seen_catalog$seen_authority$seen_ipv4$seen_ca$seen_store" = 11111 || usage

for tool in "$CATALOG_PLAN_TOOL" "$METADATA_PLAN_TOOL" "$OBJECT_TOOL" \
    "$FETCH_TOOL" "$STORE_TOOL"
do
    test -x "$tool" || fail "required adapter is missing: $tool"
done
for required in "$PROTOCOL_VALIDATOR" "$REQUEST_VALIDATOR" \
    "$AUTHORITY_VALIDATOR" "$CATALOG_VALIDATOR" \
    "$METADATA_DESCRIPTOR_VALIDATOR" "$METADATA_VALIDATOR" "$FETCH_VALIDATOR"
do
    test -f "$required" || fail "validator is missing: $required"
done
KPM_METADATA_IDENTITY=$IDENTITY KPM_METADATA_VERSION=$VERSION LC_ALL=C awk \
    -f "$PROTOCOL_VALIDATOR" -f "$REQUEST_VALIDATOR" /dev/null ||
    fail 'requested identity/version grammar is invalid'

work=$(mktemp -d "${TMPDIR:-/tmp}/kofun-pm-fetch-version-v1.XXXXXX")
trap 'rm -rf "$work"' 0 1 2 15

/bin/sh "$CATALOG_PLAN_TOOL" inspect "$IDENTITY" "$CATALOG" --authority \
    "$AUTHORITY" >"$work/catalog.plan"
tab=$(printf '\t')
if ! KPM_VERSION=$VERSION LC_ALL=C awk -F "$tab" -v OFS="$tab" '
    BEGIN { requested = ENVIRON["KPM_VERSION"] }
    $1 == "identity" {
        identities++
        identity = $2
        origin = $3
    }
    $1 == "catalog" && $2 == requested {
        descriptors++
        size = $3
        digest = $4
    }
    END {
        if (identities != 1 || descriptors != 1 || identity == "" ||
            origin == "" || size == "" || digest == "")
            exit 1
        print identity, origin, size, digest
    }
' "$work/catalog.plan" >"$work/metadata.descriptor"
then
    fail "required version $IDENTITY@$VERSION is not published"
fi
IFS="$tab" read -r PLANNED_IDENTITY ORIGIN METADATA_SIZE METADATA_DIGEST \
    <"$work/metadata.descriptor"
test "$PLANNED_IDENTITY" = "$IDENTITY" ||
    fail 'catalog plan did not retain the exact requested identity'
identity_path=${PLANNED_IDENTITY#"$ORIGIN"}
case $identity_path in
    / | /*/) ;;
    *) fail 'catalog plan did not retain a canonical identity path below its origin' ;;
esac

# Only this operation reads the caller's CA pathname. Artifact children receive
# and may privately snapshot this retained file; they cannot observe a later
# mutation of the original input.
test ! -L "$CA_FILE" && test -f "$CA_FILE" ||
    fail "CA input is not a regular non-symlink file: $CA_FILE"
CA_SNAPSHOT=$work/ca.pem
head -c "$((MAX_CA_BYTES + 1))" <"$CA_FILE" >"$CA_SNAPSHOT" ||
    fail "could not read the CA snapshot: $CA_FILE"
ca_bytes=$(wc -c <"$CA_SNAPSHOT" | tr -d ' ')
test "$ca_bytes" -le "$MAX_CA_BYTES" ||
    fail "CA snapshot exceeds the $MAX_CA_BYTES-byte input bound: $ca_bytes"
chmod 400 "$CA_SNAPSHOT"

METADATA_TARGET=${identity_path}@kofun/v1/versions/$VERSION.meta
object_status=0
/bin/sh "$OBJECT_TOOL" acquire --class metadata --origin "$ORIGIN" \
    --target "$METADATA_TARGET" --ipv4 "$IPV4" --ca-file "$CA_SNAPSHOT" \
    --size "$METADATA_SIZE" --digest "$METADATA_DIGEST" --store "$STORE" \
    --snapshot "$work/metadata.store.snapshot" \
    >"$work/metadata.object.out" 2>"$work/metadata.object.err" || object_status=$?
case $object_status in
    0) ;;
    10) fail "catalog-bound metadata fetch failed for $IDENTITY@$VERSION" ;;
    11) fail "admitted metadata could not be reverified from the store: $METADATA_DIGEST" ;;
    *) fail "planned metadata acquisition adapter failed for $IDENTITY@$VERSION" ;;
esac

if ! env -i PATH="$SAFE_PATH" LC_ALL=C TMPDIR="$work" \
    /bin/sh "$METADATA_PLAN_TOOL" inspect "$IDENTITY" "$VERSION" \
    "$work/metadata.store.snapshot" --size "$METADATA_SIZE" \
    --digest "$METADATA_DIGEST" >"$work/metadata.plan" \
    2>"$work/metadata.err"
then
    fail "descriptor-valid metadata bytes failed strict parsing for $IDENTITY@$VERSION"
fi
LC_ALL=C awk -F "$tab" -v OFS="$tab" '
    $1 == "descriptor" { print $4, $5, $6, $7 }
' "$work/metadata.plan" >"$work/files.plan"
files=$(wc -l <"$work/files.plan" | tr -d ' ')
test "$files" -gt 0 || fail 'strict metadata plan exposed no file descriptors'
sources=$(LC_ALL=C awk -F "$tab" '$2 == "source" { count++ }
    END { print count + 0 }' "$work/files.plan")
data_files=$(LC_ALL=C awk -F "$tab" '$2 == "data" { count++ }
    END { print count + 0 }' "$work/files.plan")
test "$((sources + data_files))" -eq "$files" ||
    fail 'strict metadata plan exposed an unknown file kind'
ICONV=
if test "$sources" -gt 0; then
    ICONV=$(command -v iconv) ||
        fail 'iconv is required to validate source UTF-8'
    case $ICONV in
        /*) ;;
        *) fail "iconv did not resolve to an absolute executable pathname: $ICONV" ;;
    esac
    test -x "$ICONV" || fail "iconv is not executable: $ICONV"
fi

file_index=0
while IFS="$tab" read -r LOGICAL_PATH FILE_KIND BYTES DIGEST; do
    file_index=$((file_index + 1))
    TARGET=${identity_path}@kofun/v1/blobs/sha256/$DIGEST
    SNAPSHOT=$work/blob.$file_index.store.snapshot
    object_status=0
    /bin/sh "$OBJECT_TOOL" acquire --class blob --origin "$ORIGIN" \
        --target "$TARGET" --ipv4 "$IPV4" --ca-file "$CA_SNAPSHOT" \
        --size "$BYTES" --digest "$DIGEST" --store "$STORE" \
        --snapshot "$SNAPSHOT" >"$work/blob.$file_index.object.out" \
        2>"$work/blob.$file_index.object.err" || object_status=$?
    case $object_status in
        0) ;;
        10) fail "planned blob fetch failed for $IDENTITY@$VERSION:$LOGICAL_PATH" ;;
        11) fail "admitted blob could not be reverified from the store for $IDENTITY@$VERSION:$LOGICAL_PATH: $DIGEST" ;;
        *) fail "planned blob acquisition adapter failed for $IDENTITY@$VERSION:$LOGICAL_PATH" ;;
    esac
    if test "$FILE_KIND" = source; then
        if ! env -i PATH="$SAFE_PATH" LC_ALL=C "$ICONV" -f UTF-8 -t UTF-8 \
            "$SNAPSHOT" >"$work/blob.$file_index.iconv.out" \
            2>"$work/blob.$file_index.iconv.err"
        then
            fail "metadata-bound source is not valid UTF-8: $IDENTITY@$VERSION:$LOGICAL_PATH"
        fi
    fi
done <"$work/files.plan"
test "$file_index" -eq "$files" ||
    fail 'not every frozen metadata descriptor reached the acquisition loop'

printf 'fetch-version-v1: catalog-bound metadata and all %s file blob(s) admitted and independently reverified for %s@%s: %s source and %s data\n' \
    "$files" "$IDENTITY" "$VERSION" "$sources" "$data_files"
printf 'fetch-version-v1: one supplied authority/catalog and one exact version only; catalog acquisition/authenticity/history, MVS selection, dependency/workspace/rough-graph traversal, complete DNS/redirect/header/deadline transport, lock writing/migration, public materialization, install/build execution, global lifecycle proof, and same-handle consumption remain outside this slice\n'
