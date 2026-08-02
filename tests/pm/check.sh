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

# --- the transitive closure
#
# The app requires 10 at v2; a dependency it pulls in requires 10 at v5 and
# brings 30 with it. These four lines are the property that makes MVS a single
# fold rather than a loop.
check 'without the dependency, the app gets what it asked for' 35 38 '10 1 2 7 '
check 'the dependency raises the bound the app set lower' 39 42 '10 1 5 7 '
check 'and leaves an unrelated module where it was' 43 46 '20 1 1 3 '
check 'a module only the dependency needs is still selected' 47 50 '30 1 1 1 '
check 'swapping the two sets changes nothing' 51 54 '10 1 5 7 '

# Monotone, read from the golden rather than trusted: adding requirements may
# raise a selection and may never lower one. A resolver that could lower one
# would need a fixed point to iterate towards, which the executable slice has
# no loop to express.
without=$(field 35 38 | awk '{print $3}')
with=$(field 39 42 | awk '{print $3}')
test "$with" -ge "$without" ||
    fail "adding a dependency lowered a selection, from $without to $with;
  MVS would then need iteration, and a lock would depend on traversal order"

# Associativity, likewise: which set a bound was found in cannot matter.
swapped=$(field 51 54 | awk '{print $3}')
test "$with" = "$swapped" ||
    fail "swapping the requirement sets changed the selection, $with vs $swapped"

lines=$(wc -l <"$expected" | tr -d ' ')
test "$lines" -eq 54 ||
    fail "recorded decisions cover the whole golden: expected 54 lines, got $lines"

# Order-independence, read from the golden rather than trusted: the two
# reordered queries must equal the two original ones, byte for byte.
original=$(field 3 10)
reordered=$(field 19 26)
test "$original" = "$reordered" ||
    fail "reordering the requirement set changed the resolution:
  original:  $original
  reordered: $reordered"

# ================================================== derivation identity
#
# ADR 4's three properties, read out of the recorded identities rather than
# asserted about them.

dcore="$ROOT/seed/derivation/core.kofun"
dshell="$ROOT/seed/derivation/shell.kofun"
dexpected="$ROOT/seed/derivation/derivation.stdout"
for f in "$dcore" "$dshell" "$dexpected"; do
    test -f "$f" || fail "missing $f"
done

sed 's/[[:space:]]*#.*$//' "$dcore" >"$WORK/dcore.code"
grep -qE '^fn main' "$WORK/dcore.code" &&
    fail 'the derivation core owns an entry point'
grep -qE '^[[:space:]]*print\(' "$WORK/dcore.code" &&
    fail 'the derivation core prints; an identity is a value, not an effect'
grep -qE 'clock_gettime|getenv|fopen|socket\(|import ' "$WORK/dcore.code" &&
    fail 'the derivation core names ambient state — the closure would be incomplete'

dseed="$WORK/derivation.unit.kofun"
cat "$dcore" >"$dseed"
printf '\n' >>"$dseed"
cat "$dshell" >>"$dseed"

"$KOFUN" build "$dseed" -o "$WORK/derivation" >"$WORK/dbuild.out" 2>"$WORK/dbuild.err" ||
    fail "the derivation seed did not build: $(cat "$WORK/dbuild.err")"
"$WORK/derivation" >"$WORK/dbackend.out"
cmp "$dexpected" "$WORK/dbackend.out" ||
    fail 'C11 backend output differs from the recorded identities'
"$KOFUN" run "$dseed" >"$WORK/dreference.out" 2>"$WORK/drun.err" ||
    fail "the derivation seed did not run: $(cat "$WORK/drun.err")"
cmp "$dexpected" "$WORK/dreference.out" ||
    fail 'reference executor and C11 backend disagree on an identity'
env -i "$WORK/derivation" >"$WORK/dbare.out"
cmp "$WORK/dbackend.out" "$WORK/dbare.out" ||
    fail 'an identity changed with an empty environment'

# One label, kind, identity per line after the bound. Read the relationships,
# because the numbers themselves are a projection of sha256 and their values
# are not the claim — their relationships are.
id_of() {
    grep -v '^$' "$dexpected" | tail -n +2 | paste - - - |
        awk -F'\t' -v want="$1" '$1 == want { print $3 }'
}
kind_of() {
    grep -v '^$' "$dexpected" | tail -n +2 | paste - - - |
        awk -F'\t' -v want="$1" '$1 == want { print $2 }'
}

test "$(sed -n '1p' "$dexpected")" = 4 ||
    fail 'the recorded input bound is not the one the core declares'

# Order-independence: the same two sources in the other order.
test "$(id_of 2)" = "$(id_of 3)" ||
    fail "the same inputs in another order produced different identities:
  $(id_of 2) and $(id_of 3)"

# Completeness: one source byte moves and the identity moves with it.
test "$(id_of 2)" != "$(id_of 5)" ||
    fail 'a changed source left the identity unmoved; the cache would serve the old build'

# Transitivity: the dependent moves because its dependency did.
test "$(id_of 4)" != "$(id_of 6)" ||
    fail 'a changed dependency left its dependent unmoved; the closure is not transitive'

# The toolchain is inside the closure.
test "$(id_of 4)" != "$(id_of 7)" ||
    fail 'a changed toolchain left the identity unmoved; the build is impure'

# The refusals, by kind: 2 NoInputs, 3 ReservedDigest.
test "$(kind_of 8)" = 2 || fail 'an empty closure was not refused'
test "$(kind_of 9)" = 3 || fail 'a reserved digest in a live slot was not refused'

printf 'pm: an identity is the same in any input order, and moves when any input does: PASS\n'
printf 'pm: a change in a dependency reaches its dependent: PASS\n'

printf 'pm: the core resolves without printing or reaching for the world: PASS\n'
printf 'pm: minimal version selection, every closed outcome read by name: PASS\n'
printf 'pm: the same requirement set in any order gives the same lock: PASS\n'
printf 'pm: a transitive bound only ever rises, so one pass is the whole answer: PASS\n'
printf 'pm: reference and C11 agree; bytes hold under hostile TZ, locale, env -i: PASS\n'
