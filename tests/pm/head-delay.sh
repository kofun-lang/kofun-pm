#!/bin/sh
set -eu

# Test-only bounded-copy interruption point. Emit one untrusted byte, make the
# partial candidate observable, then let the parent receive TERM while this
# child is still the command it is waiting for.
: "${KPM_REAL_HEAD:?KPM_REAL_HEAD is required}"
: "${KPM_HEAD_MARKER:?KPM_HEAD_MARKER is required}"

printf 'ready\n' >"$KPM_HEAD_MARKER"
printf x
sleep 2
exec "$KPM_REAL_HEAD" "$@"
