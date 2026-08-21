#!/bin/sh
set -eu

# Qualify exactly one already-described immutable HTTPS response against an
# explicitly approved origin/target/pinned-IPv4 tuple, then admit only verified
# bytes through the existing no-replace store. This is deliberately not kpm
# fetch: it performs no DNS, redirect, catalog, graph, or lock work, and curl's
# CLI cannot impose ADR 7's exact pre-parse HTTP header bounds.
#
#   scripts/fetch-artifact-v1.sh \
#     --class metadata|blob --origin https://HOST --target /absolute/path \
#     --ipv4 A.B.C.D --ca-file FILE --size N --digest SHA256 \
#     --store ABSOLUTE_STORE

case $0 in
    */*) script_dir=${0%/*} ;;
    *) script_dir=. ;;
esac
ROOT=$(CDPATH= cd -- "$script_dir/.." && pwd)
VALIDATOR=$ROOT/scripts/fetch-artifact-v1-validate.awk
PROTOCOL_VALIDATOR=$ROOT/scripts/protocol-v1-validate.awk
STORE_TOOL=$ROOT/scripts/store.sh
MAX_CA_BYTES=1048576
SAFE_PATH=/usr/bin:/bin

fail() {
    printf 'fetch-artifact-v1: %s\n' "$*" >&2
    exit 1
}

usage() {
    fail 'usage: scripts/fetch-artifact-v1.sh --class metadata|blob --origin https://HOST --target /absolute/path --ipv4 A.B.C.D --ca-file FILE --size N --digest SHA256 --store ABSOLUTE_STORE'
}

CLASS=
ORIGIN=
TARGET=
IPV4=
CA_FILE=
BYTES=
DIGEST=
STORE=
seen_class=0
seen_origin=0
seen_target=0
seen_ipv4=0
seen_ca=0
seen_size=0
seen_digest=0
seen_store=0

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
        *) usage ;;
    esac
done

test "$seen_class$seen_origin$seen_target$seen_ipv4$seen_ca$seen_size$seen_digest$seen_store" = 11111111 ||
    usage
for required in "$VALIDATOR" "$PROTOCOL_VALIDATOR"; do
    test -f "$required" || fail "validator is missing: $required"
done
test -x "$STORE_TOOL" || fail "store adapter is missing: $STORE_TOOL"
CURL=$(command -v curl) || fail 'curl 8.4.0 or newer is required'
case $CURL in
    /*) ;;
    *) fail "curl did not resolve to an absolute executable pathname: $CURL" ;;
esac
test -x "$CURL" || fail "curl is not executable: $CURL"
PATH=$SAFE_PATH
export PATH
if SHA_TOOL=$(command -v sha256sum); then
    SHA_MODE=sha256sum
elif SHA_TOOL=$(command -v shasum); then
    SHA_MODE=shasum
else
    fail 'no sha256sum or shasum is available'
fi
case $SHA_TOOL in
    /*) ;;
    *) fail "SHA-256 tool did not resolve to an absolute executable pathname: $SHA_TOOL" ;;
esac
test -x "$SHA_TOOL" || fail "SHA-256 tool is not executable: $SHA_TOOL"

scalar_plan=$(KPM_FETCH_CLASS=$CLASS KPM_FETCH_ORIGIN=$ORIGIN \
    KPM_FETCH_TARGET=$TARGET KPM_FETCH_IPV4=$IPV4 KPM_FETCH_SIZE=$BYTES \
    KPM_FETCH_DIGEST=$DIGEST LC_ALL=C awk -f "$PROTOCOL_VALIDATOR" \
    -f "$VALIDATOR" /dev/null) || fail 'artifact request grammar is invalid'
tab=$(printf '\t')
IFS="$tab" read -r scalar_kind HOST <<EOF
$scalar_plan
EOF
test "$scalar_kind" = host && test -n "$HOST" ||
    fail 'validated artifact request did not retain its hostname'

test -n "$STORE" || usage
KPM_STORE_PATH=$STORE LC_ALL=C awk '
    BEGIN { exit ENVIRON["KPM_STORE_PATH"] ~ /[[:cntrl:]]/ ? 1 : 0 }
' /dev/null || fail '--store path contains a control byte'
case $STORE in
    /*) ;;
    *) fail "--store must be an absolute path: $STORE" ;;
esac
test "$STORE" != / || fail '--store refuses the filesystem root'
case $STORE in
    */) fail "--store must not end in '/': $STORE" ;;
esac
STORE=$(realpath -m -- "$STORE") ||
    fail "could not resolve the store mutation boundary: $STORE"
test "$STORE" != / || fail '--store refuses the filesystem root'
entry=$STORE/$(printf '%s' "$DIGEST" | cut -c1-2)/$(printf '%s' "$DIGEST" | cut -c3-)
entry_ancestor=${entry%/*}
while test ! -e "$entry_ancestor" && test ! -L "$entry_ancestor"; do
    entry_ancestor=${entry_ancestor%/*}
    test -n "$entry_ancestor" || entry_ancestor=/
done
test ! -L "$entry_ancestor" && test -d "$entry_ancestor" ||
    fail "store entry is below a non-directory or symlink path: $entry_ancestor"
test -x "$entry_ancestor" ||
    fail "store entry has no searchable ancestor: $entry_ancestor"

work=$(mktemp -d "${TMPDIR:-/tmp}/kofun-pm-fetch-artifact-v1.XXXXXX")
trap 'rm -rf "$work"' 0 1 2 15
mkdir "$work/curl-home" "$work/curl-xdg" "$work/empty-capath"
if ! env -i PATH="$SAFE_PATH" LC_ALL=C \
    HOME="$work/curl-home" XDG_CONFIG_HOME="$work/curl-xdg" \
    "$CURL" -q --version >"$work/curl.version"
then
    fail 'could not inspect the frozen curl executable'
fi
curl_plan=$(LC_ALL=C awk '
    function at_least_8_4(version, part) {
        if (version !~ /^[0-9]+\.[0-9]+\.[0-9]+/) return 0
        split(version, part, "\\.")
        return (part[1] + 0) > 8 ||
            ((part[1] + 0) == 8 && (part[2] + 0) >= 4)
    }
    $1 == "curl" {
        tool = $2
        for (i = 3; i <= NF; i++)
            if (index($i, "libcurl/") == 1)
                library = substr($i, 9)
    }
    $1 == "Protocols:" {
        for (i = 2; i <= NF; i++) if ($i == "https") https = 1
    }
    $1 == "Features:" {
        for (i = 2; i <= NF; i++) if ($i == "SSL") ssl = 1
    }
    END {
        if (!at_least_8_4(tool) || !at_least_8_4(library) || !https || !ssl)
            exit 1
        print "versions\t" tool "\t" library
    }
' "$work/curl.version") ||
    fail 'curl and linked libcurl 8.4.0 or newer with HTTPS/SSL support are required'
IFS="$tab" read -r curl_plan_kind curl_version libcurl_version <<EOF
$curl_plan
EOF
test "$curl_plan_kind" = versions && test -n "$curl_version" &&
    test -n "$libcurl_version" || fail 'curl version output is not recognized'

test ! -L "$CA_FILE" && test -f "$CA_FILE" ||
    fail "CA input is not a regular non-symlink file: $CA_FILE"
CA_SNAPSHOT=$work/ca.pem
head -c "$((MAX_CA_BYTES + 1))" <"$CA_FILE" >"$CA_SNAPSHOT" ||
    fail "could not read the CA snapshot: $CA_FILE"
ca_bytes=$(wc -c <"$CA_SNAPSHOT" | tr -d ' ')
test "$ca_bytes" -le "$MAX_CA_BYTES" ||
    fail "CA snapshot exceeds the $MAX_CA_BYTES-byte input bound: $ca_bytes"
chmod 400 "$CA_SNAPSHOT"

if test -e "$entry" || test -L "$entry"; then
    if ! env -i PATH="$SAFE_PATH" LC_ALL=C /bin/sh "$STORE_TOOL" \
        --store "$STORE" snapshot "$DIGEST" "$BYTES" "$work/warm.snapshot"
    then
        fail "existing store object did not verify: $DIGEST"
    fi
    printf 'fetch-artifact-v1: reused verified store object without network: %s\n' "$DIGEST"
    exit 0
fi
test ! -L "$entry_ancestor" && test -d "$entry_ancestor" &&
    test -x "$entry_ancestor" && test -w "$entry_ancestor" ||
    fail "store entry has no real searchable writable ancestor: $entry_ancestor"

if test "$BYTES" = 0; then
    transfer_limit=1
else
    transfer_limit=$BYTES
fi
BODY=$work/body
REPORT=$work/report
HEADERS=$work/headers
URL=$ORIGIN$TARGET
if ! env -i PATH="$SAFE_PATH" LC_ALL=C \
    HOME="$work/curl-home" XDG_CONFIG_HOME="$work/curl-xdg" \
    "$CURL" -q --globoff --silent --show-error --request GET \
    --proto '=https' --http1.1 --tlsv1.2 \
    --cacert "$CA_SNAPSHOT" --capath "$work/empty-capath" \
    --resolve "$HOST:443:$IPV4" --ipv4 \
    --proxy '' --noproxy '*' --no-netrc --retry 0 --max-redirs 0 \
    --max-filesize "$transfer_limit" --connect-timeout 10 \
    --speed-limit 1 --speed-time 30 --max-time 600 \
    --header 'Accept-Encoding: identity' \
    --dump-header "$HEADERS" \
    --output "$BODY" \
    --write-out 'scheme=%{scheme}\npeer=%{remote_ip}\nstatus=%{http_code}\nredirects=%{num_redirects}\n' \
    --url "$URL" >"$REPORT" 2>"$work/curl.stderr"
then
    fail "pinned HTTPS GET failed for $ORIGIN$TARGET"
fi

test ! -L "$BODY" && test -f "$BODY" ||
    fail 'curl did not produce one private regular response body'
test ! -L "$REPORT" && test -f "$REPORT" ||
    fail 'curl did not produce one private regular response report'
test ! -L "$HEADERS" && test -f "$HEADERS" ||
    fail 'curl did not produce one private regular response header snapshot'
report_value() {
    report_key=$1
    LC_ALL=C awk -F = -v expected="$report_key" '
        index($0, expected "=") == 1 {
            found++
            print substr($0, length(expected) + 2)
        }
        END { exit found == 1 ? 0 : 1 }
    ' "$REPORT"
}
scheme=$(report_value scheme) || fail 'curl did not report exactly one final scheme'
peer=$(report_value peer) || fail 'curl did not report exactly one connected peer'
status=$(report_value status) || fail 'curl did not report exactly one final status'
redirects=$(report_value redirects) || fail 'curl did not report exactly one redirect count'
test "$scheme" = HTTPS || test "$scheme" = https ||
    fail "curl final scheme was not HTTPS: $scheme"
test "$peer" = "$IPV4" ||
    fail "connected peer does not match the explicitly pinned IPv4 address: $peer"
test "$status" = 200 || fail "HTTPS response status is not 200: $status"
test "$redirects" = 0 || fail "curl followed a redirect: $redirects"
LC_ALL=C awk '
    {
        line = $0
        sub(/\r$/, "", line)
        if (line ~ /^[ \t]/) {
            if (content_encoding) bad = 1
            next
        }
        content_encoding = 0
        colon = index(line, ":")
        if (!colon || tolower(substr(line, 1, colon - 1)) != "content-encoding")
            next
        content_encoding = 1
        count++
        value = substr(line, colon + 1)
        sub(/^[ \t]*/, "", value)
        sub(/[ \t]*$/, "", value)
        if (value != "identity") bad = 1
    }
    END { exit bad || count > 1 }
' "$HEADERS" ||
    fail 'Content-Encoding is not absent or identity exactly once'

actual_size=$(wc -c <"$BODY" | tr -d ' ')
test "$actual_size" = "$BYTES" ||
    fail "response size does not match its supplied descriptor
  expected $BYTES
  actual   $actual_size
  actual digest not computed"
if test "$SHA_MODE" = sha256sum; then
    actual_digest=$("$SHA_TOOL" <"$BODY" | cut -d' ' -f1)
else
    actual_digest=$("$SHA_TOOL" -a 256 <"$BODY" | cut -d' ' -f1)
fi
test "$actual_digest" = "$DIGEST" ||
    fail "response digest does not match its supplied descriptor
  expected $DIGEST
  actual   $actual_digest"

admitted=$(env -i PATH="$SAFE_PATH" LC_ALL=C /bin/sh "$STORE_TOOL" \
    --store "$STORE" admit "$DIGEST" "$BYTES" "$BODY") ||
    fail 'verified response could not be admitted without replacement'
test "$admitted" = "$DIGEST" ||
    fail 'store admission did not return the verified response digest'
printf 'fetch-artifact-v1: pinned HTTPS response verified and admitted: %s\n' "$DIGEST"
printf 'fetch-artifact-v1: one explicitly approved origin/target/IPv4 tuple and supplied descriptor only; DNS/public-address policy, redirects, exact HTTP header/Content-Length bounds, catalog/package acquisition, parsing, graph/MVS, lock writing, and same-handle consumption remain outside this qualification\n'
