#!/bin/sh
set -eu

# Select one exact source/data descriptor from one supplied catalog-bound
# metadata document, derive its static blob target, fetch/admit it, then
# independently re-snapshot it before source UTF-8 validation and success.
#
#   scripts/fetch-file-v1.sh acquire IDENTITY VERSION LOGICAL_PATH METADATA \
#     --catalog CATALOG --authority AUTHORITY --ipv4 A.B.C.D \
#     --ca-file CA_PEM --store ABSOLUTE_STORE

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CATALOG_PLAN_TOOL=$ROOT/scripts/catalog-v1-plan.sh
METADATA_PLAN_TOOL=$ROOT/scripts/metadata-v1-plan.sh
FETCH_TOOL=$ROOT/scripts/fetch-artifact-v1.sh
STORE_TOOL=$ROOT/scripts/store.sh
PROTOCOL_VALIDATOR=$ROOT/scripts/protocol-v1-validate.awk
REQUEST_VALIDATOR=$ROOT/scripts/file-request-v1-validate.awk
AUTHORITY_VALIDATOR=$ROOT/scripts/authority-v1-validate.awk
CATALOG_VALIDATOR=$ROOT/scripts/catalog-v1-validate.awk
METADATA_DESCRIPTOR_VALIDATOR=$ROOT/scripts/metadata-descriptor-v1-validate.awk
METADATA_VALIDATOR=$ROOT/scripts/metadata-v1-validate.awk
FETCH_VALIDATOR=$ROOT/scripts/fetch-artifact-v1-validate.awk
SAFE_PATH=/usr/bin:/bin

fail() {
    printf 'fetch-file-v1: %s\n' "$*" >&2
    exit 1
}

usage() {
    fail 'usage: scripts/fetch-file-v1.sh acquire IDENTITY VERSION LOGICAL_PATH METADATA --catalog CATALOG --authority AUTHORITY --ipv4 A.B.C.D --ca-file CA_PEM --store ABSOLUTE_STORE'
}

test "${1:-}" = acquire && test "$#" -ge 5 || usage
IDENTITY=$2
VERSION=$3
LOGICAL_PATH=$4
METADATA=$5
shift 5
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

for tool in "$CATALOG_PLAN_TOOL" "$METADATA_PLAN_TOOL" "$FETCH_TOOL" "$STORE_TOOL"; do
    test -x "$tool" || fail "required adapter is missing: $tool"
done
for required in "$PROTOCOL_VALIDATOR" "$REQUEST_VALIDATOR" \
    "$AUTHORITY_VALIDATOR" "$CATALOG_VALIDATOR" \
    "$METADATA_DESCRIPTOR_VALIDATOR" "$METADATA_VALIDATOR" "$FETCH_VALIDATOR"
do
    test -f "$required" || fail "validator is missing: $required"
done
request_plan=$(KPM_FILE_IDENTITY=$IDENTITY KPM_FILE_VERSION=$VERSION \
    KPM_FILE_PATH=$LOGICAL_PATH LC_ALL=C awk -f "$PROTOCOL_VALIDATOR" \
    -f "$REQUEST_VALIDATOR" /dev/null) ||
    fail 'requested identity/version/logical-path grammar is invalid'
tab=$(printf '\t')
IFS="$tab" read -r request_kind requested_identity requested_version \
    requested_path <<EOF
$request_plan
EOF
test "$request_kind" = request && test "$requested_identity" = "$IDENTITY" &&
    test "$requested_version" = "$VERSION" &&
    test "$requested_path" = "$LOGICAL_PATH" ||
    fail 'file request validation did not retain the exact scalar values'

work=$(mktemp -d "${TMPDIR:-/tmp}/kofun-pm-fetch-file-v1.XXXXXX")
trap 'rm -rf "$work"' 0 1 2 15

sh "$CATALOG_PLAN_TOOL" inspect "$IDENTITY" "$CATALOG" --authority \
    "$AUTHORITY" >"$work/catalog.plan"
if ! KPM_FILE_VERSION=$VERSION LC_ALL=C awk -F "$tab" -v OFS="$tab" '
    BEGIN { requested = ENVIRON["KPM_FILE_VERSION"] }
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

if ! env -i PATH="$SAFE_PATH" LC_ALL=C TMPDIR="$work" \
    /bin/sh "$METADATA_PLAN_TOOL" inspect "$IDENTITY" "$VERSION" "$METADATA" \
    --size "$METADATA_SIZE" --digest "$METADATA_DIGEST" \
    >"$work/metadata.plan" 2>"$work/metadata.err"
then
    fail "supplied metadata failed its exact catalog descriptor or strict grammar for $IDENTITY@$VERSION"
fi
if ! KPM_FILE_PATH=$LOGICAL_PATH LC_ALL=C awk -F "$tab" -v OFS="$tab" '
    BEGIN { requested = ENVIRON["KPM_FILE_PATH"] }
    $1 == "descriptor" && $4 == requested {
        found++
        kind = $5
        size = $6
        digest = $7
    }
    END {
        if (found != 1 || kind == "" || size == "" || digest == "")
            exit 1
        print kind, size, digest
    }
' "$work/metadata.plan" >"$work/file.descriptor"
then
    fail "logical path is not published by the exact metadata document: $LOGICAL_PATH"
fi
IFS="$tab" read -r FILE_KIND BYTES DIGEST <"$work/file.descriptor"

identity_path=${PLANNED_IDENTITY#"$ORIGIN"}
case $identity_path in
    / | /*/) ;;
    *) fail 'catalog plan did not retain a canonical identity path below its origin' ;;
esac
TARGET=${identity_path}@kofun/v1/blobs/sha256/$DIGEST

ICONV=
if test "$FILE_KIND" = source; then
    ICONV=$(command -v iconv) || fail 'iconv is required to validate source UTF-8'
    case $ICONV in
        /*) ;;
        *) fail "iconv did not resolve to an absolute executable pathname: $ICONV" ;;
    esac
    test -x "$ICONV" || fail "iconv is not executable: $ICONV"
fi

if ! sh "$FETCH_TOOL" --class blob --origin "$ORIGIN" --target "$TARGET" \
    --ipv4 "$IPV4" --ca-file "$CA_FILE" --size "$BYTES" \
    --digest "$DIGEST" --store "$STORE" >"$work/fetch.out" \
    2>"$work/fetch.err"
then
    fail "metadata-bound blob fetch failed for $IDENTITY@$VERSION:$LOGICAL_PATH"
fi
if ! env -i PATH="$SAFE_PATH" LC_ALL=C /bin/sh "$STORE_TOOL" \
    --store "$STORE" snapshot "$DIGEST" "$BYTES" "$work/blob.store.snapshot" \
    >"$work/store.out" 2>"$work/store.err"
then
    fail "admitted blob could not be reverified from the store: $DIGEST"
fi
if test "$FILE_KIND" = source; then
    if ! env -i PATH="$SAFE_PATH" LC_ALL=C "$ICONV" -f UTF-8 -t UTF-8 \
        "$work/blob.store.snapshot" >"$work/iconv.out" 2>"$work/iconv.err"
    then
        fail "metadata-bound source is not valid UTF-8: $IDENTITY@$VERSION:$LOGICAL_PATH"
    fi
fi

printf 'fetch-file-v1: metadata-bound %s blob admitted and independently reverified for %s@%s:%s: %s\n' \
    "$FILE_KIND" "$IDENTITY" "$VERSION" "$LOGICAL_PATH" "$DIGEST"
printf 'fetch-file-v1: one supplied authority/catalog/metadata and one derived source/data blob request only; catalog/metadata acquisition or authenticity/history, dependency/selected-package traversal, DNS/public-address policy, redirects, exact HTTP header/Content-Length bounds, public materialization, graph/MVS, lock writing, install/build execution, and same-handle consumption remain outside this slice\n'
