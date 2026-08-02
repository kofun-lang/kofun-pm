#!/bin/sh
set -eu

# The kofun-pm gate.
#
# The resolver is the repository's whole claim right now, so the gate reads
# every decision it makes rather than accepting a golden. Each assertion names
# the rule, so a failure says which rule moved.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
KOFUN="$ROOT/vendor/kofun/bin/kofun"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/kofun-pm.XXXXXX")
trap 'rm -rf "$WORK"' 0 1 2 15

fail() {
    printf 'pm: FAIL: %s\n' "$*" >&2
    exit 1
}

core="$ROOT/seed/resolver/core.kofun"
shell="$ROOT/seed/resolver/shell.kofun"
expected="$ROOT/seed/resolver/resolver.stdout"
for f in "$core" "$shell" "$expected"; do
    test -f "$f" || fail "missing $f"
done

# The core decides; the shell prints. Read with comments stripped, because the
# core spends paragraphs explaining what it refuses to do and a grep over the
# whole text cannot tell an explanation from a violation.
sed 's/[[:space:]]*#.*$//' "$core" >"$WORK/core.code"
grep -qE '^fn main' "$WORK/core.code" &&
    fail 'the resolver core owns an entry point; emission belongs to the shell'
grep -qE '^[[:space:]]*print\(' "$WORK/core.code" &&
    fail 'the resolver core prints; a resolution is a value, not an effect'
grep -qE 'clock_gettime|getenv|fopen|socket\(|import ' "$WORK/core.code" &&
    fail 'the resolver core names ambient state'

seed="$WORK/resolver.unit.kofun"
cat "$core" >"$seed"
printf '\n' >>"$seed"
cat "$shell" >>"$seed"

"$KOFUN" check "$seed" >"$WORK/check.out" 2>"$WORK/check.err" ||
    fail "the resolver did not check: $(cat "$WORK/check.err")"
"$KOFUN" build "$seed" -o "$WORK/resolver" --emit-c "$WORK/resolver.c" \
    >"$WORK/build.out" 2>"$WORK/build.err" ||
    fail "the resolver did not build: $(cat "$WORK/build.err")"

"$WORK/resolver" >"$WORK/backend.out"
cmp "$expected" "$WORK/backend.out" ||
    fail 'C11 backend output differs from the recorded resolutions'
"$KOFUN" run "$seed" >"$WORK/reference.out" 2>"$WORK/run.err" ||
    fail "the resolver did not run on the reference executor: $(cat "$WORK/run.err")"
cmp "$expected" "$WORK/reference.out" ||
    fail 'reference executor and C11 backend disagree'

# A resolution must not depend on anything outside the requirement set.
"$WORK/resolver" >"$WORK/second.out"
cmp "$WORK/backend.out" "$WORK/second.out" ||
    fail 'two runs of the same resolver differ'
TZ=Pacific/Kiritimati LC_ALL=tr_TR.UTF-8 "$WORK/resolver" >"$WORK/hostile.out"
cmp "$WORK/backend.out" "$WORK/hostile.out" ||
    fail 'the resolution changed under a hostile time zone and locale'
env -i "$WORK/resolver" >"$WORK/bare.out"
cmp "$WORK/backend.out" "$WORK/bare.out" ||
    fail 'the resolution changed with an empty environment'

# ---------------------------------------------------- recorded decisions
#
# Two header lines (the bounds), then four integers per query: module,
# outcome kind, payload, and the registry's ceiling. Kind 1 Selected,
# 2 Unpublished, 3 AboveHighest, 4 Unrequired.

field() {
    sed -n "$1,$2p" "$expected" | tr '\n' ' '
}

check() {
    label=$1; from=$2; to=$3; want=$4
    got=$(field "$from" "$to")
    test "$got" = "$want" || fail "$label: expected '$want', got '$got'"
}

check 'the bounds this projection resolves within' 1 2 '4 3 '

# The rule: two lower bounds, and the larger satisfies both. Not a conflict.
check 'two requirements select the larger, not the newest published' \
    3 6 '10 1 5 7 '
check 'a single requirement selects exactly it' 7 10 '20 1 3 3 '
check 'a module nobody publishes is named' 11 14 '99 2 99 0 '
check 'a published module nobody requires is answered before the registry' \
    15 18 '30 4 30 1 '

# The property that makes a lock reproducible on another machine.
check 'the same requirement set in another order gives the same answer' \
    19 22 '10 1 5 7 '
check 'and so does its neighbour' 23 26 '20 1 3 3 '

# The refusal carries the demand, because the caller knows their own ceiling
# and does not know which requirement was too high.
check 'a demand above everything published carries the demand' \
    27 30 '20 3 9 3 '
# Half-open would be a bug here: the newest release must be selectable.
check 'the highest published version is selectable' 31 34 '10 1 7 7 '

lines=$(wc -l <"$expected" | tr -d ' ')
test "$lines" -eq 34 ||
    fail "recorded decisions cover the whole golden: expected 34 lines, got $lines"

# Order-independence, read from the golden rather than trusted: the two
# reordered queries must equal the two original ones, byte for byte.
original=$(field 3 10)
reordered=$(field 19 26)
test "$original" = "$reordered" ||
    fail "reordering the requirement set changed the resolution:
  original:  $original
  reordered: $reordered"

printf 'pm: the core resolves without printing or reaching for the world: PASS\n'
printf 'pm: minimal version selection, every closed outcome read by name: PASS\n'
printf 'pm: the same requirement set in any order gives the same lock: PASS\n'
printf 'pm: reference and C11 agree; bytes hold under hostile TZ, locale, env -i: PASS\n'
