#!/bin/sh
set -eu

: "${KPM_NETWORK_SENTINEL:?}"
printf '%s\n' "${0##*/}" >"$KPM_NETWORK_SENTINEL"
printf 'network sentinel: %s was called\n' "${0##*/}" >&2
exit 97
