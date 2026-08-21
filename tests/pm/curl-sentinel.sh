#!/bin/sh
set -eu

# A test-only curl double for fetch-artifact-v1.sh.  Its control plane is a
# sibling directory rather than environment variables: the production command
# is required to scrub curl's environment, and the fixture must not create an
# exception to that rule.
#
# This sentinel proves curl selection, argv/environment confinement, response
# gate ordering, and bounded-output behavior.  It deliberately does not prove
# that a real curl/TLS stack verifies certificates or negotiates TLS 1.2.

fixture=${0%/*}/curl-fixture
test -d "$fixture" || {
    printf 'curl sentinel: missing fixture directory %s\n' "$fixture" >&2
    exit 98
}

read_fixture() {
    fixture_name=$1
    fixture_default=$2
    if test -f "$fixture/$fixture_name"; then
        fixture_value=
        IFS= read -r fixture_value <"$fixture/$fixture_name" || :
        printf '%s' "$fixture_value"
    else
        printf '%s' "$fixture_default"
    fi
}

case "${1:-} ${2:-}" in
    '--version '* | '-V '* | '-q --version')
        version=$(read_fixture version 8.4.0)
        libcurl_version=$(read_fixture libcurl-version "$version")
        protocols=$(read_fixture protocols 'http https')
        features=$(read_fixture features SSL)
        printf 'version\n' >>"$fixture/version.calls"
        printf 'curl %s (kofun-pm test sentinel) libcurl/%s\n' \
            "$version" "$libcurl_version"
        printf 'Protocols: %s\n' "$protocols"
        printf 'Features: %s\n' "$features"
        exit 0
        ;;
esac

argv_log=$fixture/argv.$$
env_log=$fixture/env.$$
printf 'transfer\n' >>"$fixture/transfer.calls"
for arg do
    if test -n "$arg"; then
        printf '%s\n' "$arg"
    else
        printf '<EMPTY>\n'
    fi
done >"$argv_log"
/usr/bin/env | LC_ALL=C /usr/bin/sort >"$env_log"

output=
write_out=
header_dump=
maximum=
cacert=
url=
while test "$#" -gt 0; do
    option=$1
    shift
    case $option in
        --output | -o)
            test "$#" -gt 0 || exit 98
            output=$1
            shift
            ;;
        --output=*) output=${option#*=} ;;
        --write-out | -w)
            test "$#" -gt 0 || exit 98
            write_out=$1
            shift
            ;;
        --write-out=*) write_out=${option#*=} ;;
        --dump-header | -D)
            test "$#" -gt 0 || exit 98
            header_dump=$1
            shift
            ;;
        --dump-header=*) header_dump=${option#*=} ;;
        --max-filesize)
            test "$#" -gt 0 || exit 98
            maximum=$1
            shift
            ;;
        --max-filesize=*) maximum=${option#*=} ;;
        --cacert)
            test "$#" -gt 0 || exit 98
            cacert=$1
            shift
            ;;
        --cacert=*) cacert=${option#*=} ;;
        --url)
            test "$#" -gt 0 || exit 98
            url=$1
            shift
            ;;
        https://*) url=$option ;;
    esac
done

test -n "$output" || {
    printf 'curl sentinel: no --output was supplied\n' >&2
    exit 98
}
test -n "$maximum" || {
    printf 'curl sentinel: no --max-filesize was supplied\n' >&2
    exit 98
}
test -n "$header_dump" || {
    printf 'curl sentinel: no --dump-header was supplied\n' >&2
    exit 98
}
case $maximum in
    *[!0-9]* | '')
        printf 'curl sentinel: non-decimal --max-filesize %s\n' "$maximum" >&2
        exit 98
        ;;
    0)
        printf 'zero\n' >"$fixture/max-filesize-zero.called"
        printf 'curl sentinel: --max-filesize 0 disables the curl limit\n' >&2
        exit 96
        ;;
esac
test -n "$cacert" && test -f "$cacert" || {
    printf 'curl sentinel: --cacert did not name a readable snapshot\n' >&2
    exit 98
}
test ! -L "$cacert" || {
    printf 'curl sentinel: --cacert snapshot is a symlink\n' >&2
    exit 98
}
/bin/cp -- "$cacert" "$fixture/observed-ca.$$"

if test -f "$fixture/barrier-expected"; then
    barrier_expected=$(read_fixture barrier-expected 1)
    case $barrier_expected in
        *[!0-9]* | '' | 0) exit 98 ;;
    esac
    /bin/mkdir -p "$fixture/barrier"
    : >"$fixture/barrier/caller.$$"
    barrier_attempt=0
    while :; do
        barrier_arrived=$(/usr/bin/find "$fixture/barrier" -type f \
            -name 'caller.*' | /usr/bin/wc -l | /usr/bin/tr -d ' ')
        test "$barrier_arrived" -ge "$barrier_expected" && break
        barrier_attempt=$((barrier_attempt + 1))
        test "$barrier_attempt" -lt 100 || {
            printf 'curl sentinel: only %s of %s callers reached the barrier\n' \
                "$barrier_arrived" "$barrier_expected" >&2
            exit 98
        }
        /bin/sleep 0.1
    done
fi

if test -f "$fixture/block"; then
    printf 'ready\n' >"$fixture/block.ready"
    block_seconds=$(read_fixture block 5)
    /bin/sleep "$block_seconds"
fi
if test -f "$fixture/block-until-release"; then
    printf 'ready\n' >"$fixture/block.ready"
    release_attempt=0
    while ! test -f "$fixture/block.release"; do
        release_attempt=$((release_attempt + 1))
        test "$release_attempt" -lt 3000 || {
            printf 'curl sentinel: release handshake timed out\n' >&2
            exit 98
        }
        /bin/sleep 0.1
    done
fi
if test -f "$fixture/signal"; then
    sentinel_signal=$(read_fixture signal TERM)
    test "$sentinel_signal" = TERM || exit 98
    kill -TERM "$$"
    exit 143
fi

body=$fixture/body
test -f "$body" || : >"$body"
body_size=$(/usr/bin/wc -c <"$body" | /usr/bin/tr -d ' ')
curl_exit=$(read_fixture exit 0)
case $curl_exit in
    *[!0-9]* | '') exit 98 ;;
esac

if test "$body_size" -gt "$maximum"; then
    /usr/bin/head -c "$maximum" <"$body" >"$output"
    test "$curl_exit" -ne 0 || curl_exit=63
else
    /bin/cp -- "$body" "$output"
fi

status=$(read_fixture status 200)
encoding=$(read_fixture encoding '')
peer=$(read_fixture peer 93.184.216.34)
scheme=$(read_fixture scheme HTTPS)
proxy_used=$(read_fixture proxy_used 0)
redirects=$(read_fixture redirects 0)
effective_url=$(read_fixture effective_url "$url")

if test -f "$fixture/headers"; then
    /bin/cp -- "$fixture/headers" "$header_dump"
else
    {
        printf 'HTTP/1.1 %s test fixture\r\n' "$status"
        if test -n "$encoding"; then
            printf 'Content-Encoding: %s\r\n' "$encoding"
        fi
        printf '\r\n'
    } >"$header_dump"
fi

if test -n "$write_out"; then
    if test "$write_out" = '%{json}'; then
        # The controlled fixture values contain no JSON metacharacters.
        printf '{"response_code":%s,"http_code":%s,"remote_ip":"%s","scheme":"%s","proxy_used":%s,"size_download":%s,"url_effective":"%s"}\n' \
            "$status" "$status" "$peer" "$scheme" "$proxy_used" \
            "$body_size" "$effective_url"
    else
        rendered=$(/usr/bin/awk \
            -v fmt="$write_out" \
            -v status="$status" \
            -v peer="$peer" \
            -v scheme="$scheme" \
            -v proxy="$proxy_used" \
            -v redirects="$redirects" \
            -v bytes="$body_size" \
            -v encoding="$encoding" \
            -v effective="$effective_url" '
            BEGIN {
                gsub(/%\{response_code\}/, status, fmt)
                gsub(/%\{http_code\}/, status, fmt)
                gsub(/%\{remote_ip\}/, peer, fmt)
                gsub(/%\{scheme\}/, scheme, fmt)
                gsub(/%\{proxy_used\}/, proxy, fmt)
                gsub(/%\{num_redirects\}/, redirects, fmt)
                gsub(/%\{size_download\}/, bytes, fmt)
                gsub(/%\{url_effective\}/, effective, fmt)
                gsub(/%header\{content-encoding\}/, encoding, fmt)
                printf "%s", fmt
            }
        ')
        # curl expands backslash escapes in --write-out strings.
        printf '%b' "$rendered"
    fi
fi

exit "$curl_exit"
