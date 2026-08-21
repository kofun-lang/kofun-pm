#!/bin/sh
set -eu

# Bind one supplied authority/catalog snapshot to one exact published metadata
# descriptor, derive its URL path, fetch/admit it, then re-snapshot and parse
# the stored bytes before exposing one top-level success.
#
#   scripts/fetch-metadata-v1.sh acquire IDENTITY VERSION \
#     --catalog CATALOG --authority AUTHORITY --ipv4 A.B.C.D \
#     --ca-file CA_PEM --store ABSOLUTE_STORE

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CATALOG_PLAN_TOOL=$ROOT/scripts/catalog-v1-plan.sh
FETCH_TOOL=$ROOT/scripts/fetch-artifact-v1.sh
STORE_TOOL=$ROOT/scripts/store.sh
METADATA_PLAN_TOOL=$ROOT/scripts/metadata-v1-plan.sh
PROTOCOL_VALIDATOR=$ROOT/scripts/protocol-v1-validate.awk
REQUEST_VALIDATOR=$ROOT/scripts/metadata-request-v1-validate.awk
DESCRIPTOR_VALIDATOR=$ROOT/scripts/metadata-descriptor-v1-validate.awk
AUTHORITY_VALIDATOR=$ROOT/scripts/authority-v1-validate.awk
CATALOG_VALIDATOR=$ROOT/scripts/catalog-v1-validate.awk
FETCH_VALIDATOR=$ROOT/scripts/fetch-artifact-v1-validate.awk
METADATA_VALIDATOR=$ROOT/scripts/metadata-v1-validate.awk
SAFE_PATH=/usr/bin:/bin

fail() {
    printf 'fetch-metadata-v1: %s\n' "$*" >&2
    exit 1
}

usage() {
    fail 'usage: scripts/fetch-metadata-v1.sh acquire IDENTITY VERSION --catalog CATALOG --authority AUTHORITY --ipv4 A.B.C.D --ca-file CA_PEM --store ABSOLUTE_STORE'
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

for tool in "$CATALOG_PLAN_TOOL" "$FETCH_TOOL" "$STORE_TOOL" "$METADATA_PLAN_TOOL"; do
    test -x "$tool" || fail "required adapter is missing: $tool"
done
for required in "$PROTOCOL_VALIDATOR" "$REQUEST_VALIDATOR" "$DESCRIPTOR_VALIDATOR" \
    "$AUTHORITY_VALIDATOR" "$CATALOG_VALIDATOR" "$FETCH_VALIDATOR" \
    "$METADATA_VALIDATOR"
do
    test -f "$required" || fail "validator is missing: $required"
done
KPM_METADATA_IDENTITY=$IDENTITY KPM_METADATA_VERSION=$VERSION LC_ALL=C awk \
    -f "$PROTOCOL_VALIDATOR" -f "$REQUEST_VALIDATOR" /dev/null ||
    fail 'requested identity/version grammar is invalid'

work=$(mktemp -d "${TMPDIR:-/tmp}/kofun-pm-fetch-metadata-v1.XXXXXX")
trap 'rm -rf "$work"' 0 1 2 15

sh "$CATALOG_PLAN_TOOL" inspect "$IDENTITY" "$CATALOG" --authority \
    "$AUTHORITY" >"$work/catalog.plan"
tab=$(printf '\t')
if ! KPM_METADATA_VERSION=$VERSION LC_ALL=C awk -F "$tab" -v OFS="$tab" '
    BEGIN { requested = ENVIRON["KPM_METADATA_VERSION"] }
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
        if (identities != 1 || descriptors != 1 || identity == "" || origin == "" ||
            size == "" || digest == "")
            exit 1
        print identity, origin, size, digest
    }
' "$work/catalog.plan" >"$work/descriptor"
then
    fail "required version $IDENTITY@$VERSION is not published"
fi
IFS="$tab" read -r PLANNED_IDENTITY ORIGIN BYTES DIGEST <"$work/descriptor"
test "$PLANNED_IDENTITY" = "$IDENTITY" ||
    fail 'catalog plan did not retain the exact requested identity'
identity_path=${PLANNED_IDENTITY#"$ORIGIN"}
case $identity_path in
    / | /*/) ;;
    *) fail 'catalog plan did not retain a canonical identity path below its origin' ;;
esac
TARGET=${identity_path}@kofun/v1/versions/$VERSION.meta

if ! sh "$FETCH_TOOL" --class metadata --origin "$ORIGIN" --target "$TARGET" \
    --ipv4 "$IPV4" --ca-file "$CA_FILE" --size "$BYTES" \
    --digest "$DIGEST" --store "$STORE" >"$work/fetch.out" \
    2>"$work/fetch.err"
then
    fail "catalog-bound metadata fetch failed for $IDENTITY@$VERSION"
fi

if ! env -i PATH="$SAFE_PATH" LC_ALL=C /bin/sh "$STORE_TOOL" \
    --store "$STORE" snapshot "$DIGEST" "$BYTES" "$work/metadata.store.snapshot" \
    >"$work/store.out" 2>"$work/store.err"
then
    fail "admitted metadata could not be reverified from the store: $DIGEST"
fi
if ! env -i PATH="$SAFE_PATH" LC_ALL=C TMPDIR="$work" \
    /bin/sh "$METADATA_PLAN_TOOL" \
    inspect "$IDENTITY" "$VERSION" "$work/metadata.store.snapshot" \
    --size "$BYTES" --digest "$DIGEST" >"$work/metadata.plan" \
    2>"$work/metadata.err"
then
    fail "descriptor-valid metadata bytes failed strict parsing for $IDENTITY@$VERSION"
fi
dependencies=$(LC_ALL=C awk -F "$tab" \
    '$1 == "dependency" { count++ } END { print count + 0 }' \
    "$work/metadata.plan")
files=$(LC_ALL=C awk -F "$tab" \
    '$1 == "descriptor" { count++ } END { print count + 0 }' \
    "$work/metadata.plan")

printf 'fetch-metadata-v1: catalog-bound metadata admitted, reverified, and strictly parsed for %s@%s: %s dependency and %s file descriptor row(s)\n' \
    "$IDENTITY" "$VERSION" "$dependencies" "$files"
printf 'fetch-metadata-v1: one supplied authority/catalog, explicit pinned IPv4/CA/store, and one derived metadata request only; catalog acquisition/authenticity/history, DNS/public-address policy, redirects, exact HTTP header/Content-Length bounds, graph/MVS, blobs, lock writing, and same-handle consumption remain outside this slice\n'
