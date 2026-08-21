#!/bin/sh
set -eu

# Internal success-withholding edge shared by composed acquisition adapters.
# Fetch one already-planned artifact and independently snapshot its exact CAS
# object without exposing child success. Exit 10 names fetch/admission failure;
# exit 11 names post-admission store-snapshot failure.
#
#   scripts/fetch-object-v1.sh acquire \
#     --class metadata|blob --origin ORIGIN --target TARGET \
#     --ipv4 A.B.C.D --ca-file CA_PEM --size BYTES --digest SHA256 \
#     --store ABSOLUTE_STORE --snapshot PRIVATE_DESTINATION

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
FETCH_TOOL=$ROOT/scripts/fetch-artifact-v1.sh
STORE_TOOL=$ROOT/scripts/store.sh
PROTOCOL_VALIDATOR=$ROOT/scripts/protocol-v1-validate.awk
FETCH_VALIDATOR=$ROOT/scripts/fetch-artifact-v1-validate.awk
SAFE_PATH=/usr/bin:/bin

fail() {
    printf 'fetch-object-v1: %s\n' "$*" >&2
    exit 1
}

usage() {
    fail 'usage: scripts/fetch-object-v1.sh acquire --class metadata|blob --origin ORIGIN --target TARGET --ipv4 A.B.C.D --ca-file CA_PEM --size BYTES --digest SHA256 --store ABSOLUTE_STORE --snapshot PRIVATE_DESTINATION'
}

test "${1:-}" = acquire || usage
shift
CLASS=
ORIGIN=
TARGET=
IPV4=
CA_FILE=
BYTES=
DIGEST=
STORE=
SNAPSHOT=
seen_class=0
seen_origin=0
seen_target=0
seen_ipv4=0
seen_ca=0
seen_size=0
seen_digest=0
seen_store=0
seen_snapshot=0
while test "$#" -gt 0; do
    option=$1
    shift
    case $option in
        --class)
            test "$seen_class" -eq 0 && test "$#" -gt 0 || usage
            seen_class=1; CLASS=$1; shift
            ;;
        --origin)
            test "$seen_origin" -eq 0 && test "$#" -gt 0 || usage
            seen_origin=1; ORIGIN=$1; shift
            ;;
        --target)
            test "$seen_target" -eq 0 && test "$#" -gt 0 || usage
            seen_target=1; TARGET=$1; shift
            ;;
        --ipv4)
            test "$seen_ipv4" -eq 0 && test "$#" -gt 0 || usage
            seen_ipv4=1; IPV4=$1; shift
            ;;
        --ca-file)
            test "$seen_ca" -eq 0 && test "$#" -gt 0 || usage
            seen_ca=1; CA_FILE=$1; shift
            ;;
        --size)
            test "$seen_size" -eq 0 && test "$#" -gt 0 || usage
            seen_size=1; BYTES=$1; shift
            ;;
        --digest)
            test "$seen_digest" -eq 0 && test "$#" -gt 0 || usage
            seen_digest=1; DIGEST=$1; shift
            ;;
        --store)
            test "$seen_store" -eq 0 && test "$#" -gt 0 || usage
            seen_store=1; STORE=$1; shift
            ;;
        --snapshot)
            test "$seen_snapshot" -eq 0 && test "$#" -gt 0 || usage
            seen_snapshot=1; SNAPSHOT=$1; shift
            ;;
        *) usage ;;
    esac
done
test "$seen_class$seen_origin$seen_target$seen_ipv4$seen_ca$seen_size$seen_digest$seen_store$seen_snapshot" = 111111111 || usage

test -x "$FETCH_TOOL" || fail "fetch adapter is missing: $FETCH_TOOL"
test -x "$STORE_TOOL" || fail "store adapter is missing: $STORE_TOOL"
test -f "$PROTOCOL_VALIDATOR" ||
    fail "validator is missing: $PROTOCOL_VALIDATOR"
test -f "$FETCH_VALIDATOR" || fail "validator is missing: $FETCH_VALIDATOR"
test -n "$SNAPSHOT" || usage

work=$(mktemp -d "${TMPDIR:-/tmp}/kofun-pm-fetch-object-v1.XXXXXX")
trap 'rm -rf "$work"' 0 1 2 15

if ! /bin/sh "$FETCH_TOOL" --class "$CLASS" --origin "$ORIGIN" \
    --target "$TARGET" --ipv4 "$IPV4" --ca-file "$CA_FILE" \
    --size "$BYTES" --digest "$DIGEST" --store "$STORE" \
    >"$work/fetch.out" 2>"$work/fetch.err"
then
    exit 10
fi
if ! env -i PATH="$SAFE_PATH" LC_ALL=C /bin/sh "$STORE_TOOL" \
    --store "$STORE" snapshot "$DIGEST" "$BYTES" "$SNAPSHOT" \
    >"$work/store.out" 2>"$work/store.err"
then
    exit 11
fi

exit 0
