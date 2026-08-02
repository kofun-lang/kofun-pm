#!/bin/sh
set -eu

# Concatenate the core with the shell and build. The executable slice has no
# module imports, so a two-layer program is assembled by text in a fixed
# order — core first, which is the dependency direction and the only one that
# compiles.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
KOFUN="$ROOT/vendor/kofun/bin/kofun"
SEED=${SEED:-resolver}
OUT=${1:-"$ROOT/build/$SEED"}
if test "$#" -gt 0; then shift; fi

mkdir -p "$(dirname -- "$OUT")"
UNIT="$(dirname -- "$OUT")/$SEED.unit.kofun"

test -f "$ROOT/seed/$SEED/core.kofun" ||
    { printf 'build-seed: no seed named %s\n' "$SEED" >&2; exit 2; }
cat "$ROOT/seed/$SEED/core.kofun" >"$UNIT"
printf '\n' >>"$UNIT"
cat "$ROOT/seed/$SEED/shell.kofun" >>"$UNIT"

"$KOFUN" build "$UNIT" -o "$OUT" "$@" >/dev/null
printf '%s\n' "$OUT"
