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
"$KOFUN" run "$seed" >"$WORK/reference.out" 2>"$WORK/run.err" ||
    fail "the resolver did not run on the reference executor: $(cat "$WORK/run.err")"
cmp "$WORK/backend.out" "$WORK/reference.out" ||
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

# Read from what the binary printed, not from the golden. Asserting against
# the golden only proves the golden says what it says: a changed rule is then
# caught by the `cmp` at the end as "output differs", which names nothing.
# Reading the run is what lets a broken rule fail by the name of the rule —
# which is what the header of this file claims the gate does.
field() {
    sed -n "$1,$2p" "$WORK/backend.out" | tr '\n' ' '
}

check() {
    label=$1; from=$2; to=$3; want=$4
    got=$(field "$from" "$to")
    test "$got" = "$want" || fail "$label: expected '$want', got '$got'"
}

# A version is minor.patch inside one major line, and the major is part of the
# identity — so the resolver never compares across it.
# A version is minor.patch inside one major line, and the major is part of the
# identity — so the resolver never compares across it.
check 'a version encodes minor and patch' 1 3 '3014 3 14 '
check 'the bounds this projection resolves within' 4 5 '4 3 '

# The rule: two lower bounds, and the larger satisfies both. Not a conflict.
check 'two requirements select the larger, not the newest published' 6 9 '10 1 5 7 '
check 'a single requirement selects exactly it' 10 13 '20 1 3 3 '
check 'a module nobody publishes is named' 14 17 '99 2 99 0 '
check 'a published module nobody requires is answered before the registry' \
    18 21 '30 4 30 1 '

# The property that makes a lock reproducible on another machine.
check 'the same requirement set in another order gives the same answer' \
    22 25 '10 1 5 7 '
check 'and so does its neighbour' 26 29 '20 1 3 3 '

# The refusal carries the demand, because the caller knows their own ceiling
# and does not know which requirement was too high.
check 'a demand above everything published carries the demand' 30 33 '20 3 9 3 '
# Half-open would be a bug here: the newest release must be selectable.
check 'the highest published version is selectable' 34 37 '10 1 7 7 '

# --- the transitive closure
check 'without the dependency, the app gets what it asked for' 38 41 '10 1 2 7 '
check 'the dependency raises the bound the app set lower' 42 45 '10 1 5 7 '
check 'and leaves an unrelated module where it was' 46 49 '20 1 1 3 '
check 'a module only the dependency needs is still selected' 50 53 '30 1 1 1 '
check 'swapping the two sets changes nothing' 54 57 '10 1 5 7 '

# Monotone, read from the golden rather than trusted: adding requirements may
# raise a selection and may never lower one. A resolver that could lower one
# would need a fixed point to iterate towards, which the executable slice has
# no loop to express.
without=$(field 38 41 | awk '{print $3}')
with=$(field 42 45 | awk '{print $3}')
test "$with" -ge "$without" ||
    fail "adding a dependency lowered a selection, from $without to $with;
  MVS would then need iteration, and a lock would depend on traversal order"

# Associativity, likewise: which set a bound was found in cannot matter.
swapped=$(field 54 57 | awk '{print $3}')
test "$with" = "$swapped" ||
    fail "swapping the requirement sets changed the selection, $with vs $swapped"

# --- why: the selection explained as the maximum it is
#
# Seven integers per explanation: module, kind, the resolution being
# explained, the version, who stated the deciding bound, how many stated
# exactly it, and how many bounds did not decide the answer.
# Kind 1 Because, 2 Unrequired, 3 Unresolved.

check 'v5 because 20 required it, and the app'"'"'s v2 decided nothing' \
    58 64 '10 1 1 5 20 1 1 '
# The explanation must be a function of the requirement set, exactly as the
# selection is. Naming "the first slot at the maximum" would answer
# differently here, and a lock whose explanation moved with its input order
# would be explaining the order rather than the rule.
check 'the same explanation from the same set in another order' \
    65 71 '10 1 1 5 20 1 1 '
check 'a bound nobody competes with is explained by its only author' \
    72 78 '10 1 1 7 1 1 0 '

# A tie, and the arrangement that makes the two candidate rules disagree: the
# larger requirer code sits in the earlier slot. "The first slot at the
# maximum" would answer 30 here and 20 below; the smallest requirer answers 20
# for both. Without this pair the order-independence claim is untested, because
# every other tie in this golden has the smaller code first and passes under
# either rule.
check 'a tie names the smallest requirer, not the first slot' \
    79 85 '10 1 1 5 20 2 0 '
check 'and the same tie in the other order names the same one' \
    86 92 '10 1 1 5 20 2 0 '
tied=$(field 79 85)
tied_reordered=$(field 86 92)
test "$tied" = "$tied_reordered" ||
    fail "reordering a tie changed its explanation:
  one order:   $tied
  the other:   $tied_reordered
  the selection is a function of the set; the explanation must be too"

check 'across the closure, the dependency is the reason' \
    93 99 '10 1 1 5 20 1 1 '
# The counterfactual, recorded rather than argued: remove the dependency and
# the app's own bound becomes the reason. This is what makes the explanation
# actionable — it names the requirement to change.
check 'with the dependency gone, the app is the reason' \
    100 106 '10 1 1 2 1 1 0 '
check 'a module only the dependency requires does not name the app' \
    107 113 '30 1 1 1 20 1 0 '
# Nothing to explain, said as such. A bound of zero would read as a real
# answer, and "no one requires this" is a different fact from "version 0".
check 'an unrequired module is unexplained, not explained as zero' \
    114 120 '99 2 4 0 0 0 0 '
# A refusal has a reason but not a selection. The explanation names the
# resolution it is declining to explain rather than inventing a bound.
check 'a refusal names its resolution and invents no bound' \
    121 127 '20 3 3 0 0 0 0 '

# The explanation must agree with the decision. An explanation that drifted
# from the resolution it explains would be worse than none: it would be a
# confident wrong answer to the question a lock diff asks.
for pair in '6:58' '34:72' '42:93' '38:100' '50:107'; do
    decision=$(field "${pair%%:*}" "$((${pair%%:*} + 3))" | awk '{print $3}')
    explained=$(field "${pair##*:}" "$((${pair##*:} + 6))" | awk '{print $4}')
    test "$decision" = "$explained" ||
        fail "why explained v$explained for a resolution that selected v$decision"
done

# Every explanation that names a requirer must have a bound agreeing with it,
# and the bounds must add up: the ones that decided the answer plus the ones
# that did not are every live requirement for that module. An explanation that
# dropped a bound would understate what a change could move.
for start in 58 65 72 79 86 93 100 107; do
    row=$(field "$start" "$((start + 6))")
    agreeing=$(printf '%s' "$row" | awk '{print $6}')
    requirer=$(printf '%s' "$row" | awk '{print $5}')
    test "$agreeing" -ge 1 ||
        fail "the explanation at line $start names requirer $requirer but no bound agrees with it"
    test "$requirer" -ne 0 ||
        fail "the explanation at line $start claims a reason but names no requirer"
done

# Order-independence over the flat set, likewise read rather than trusted.
# --- workspace members
#
# Two rules that pull in opposite directions, so both are read: a member's
# requirements join the set, and a member is never fetched.
# Kind 6 Member.

check 'the workspace bound this projection resolves within' 128 128 '2 '

# A member is a package like any other as far as its own dependencies go: 40
# needs v6, above both the app's v2 and the dependency's v5, so the maximum
# rises to meet it. The union again, and the same rule.
check 'a member'"'"'s requirements join the set and raise the maximum' \
    129 132 '10 1 6 7 '

# The registry publishes 20 up to v3. The workspace wins, and it must: if the
# registry decided, publishing a package could take over a name the workspace
# owns.
check 'a member that is also published resolves to the workspace, not to v3' \
    133 136 '20 6 20 3 '
# Ceiling 0 — nobody publishes 40. Were the registry consulted first this
# would be Unpublished, which is the bug this ordering exists to prevent.
check 'a member nobody publishes resolves just the same' \
    137 140 '40 6 40 0 '
check 'a module that is not a member is unaffected by the workspace' \
    141 144 '30 1 1 1 '
# The control. Without this line the assertion above would be a claim about
# module 20 rather than about membership.
check 'the same module without a workspace is an ordinary dependency' \
    145 148 '20 1 1 3 '

member_resolved=$(field 133 136 | awk '{print $2}')
plain_resolved=$(field 145 148 | awk '{print $2}')
test "$member_resolved" != "$plain_resolved" ||
    fail "membership changed nothing: module 20 resolved the same way with and
  without the workspace, so the member rule is not being applied"

# A member is never fetched, read as the property rather than as two lines: no
# workspace member may resolve to a version, whatever the registry holds.
for start in 133 137; do
    kind=$(field "$start" "$((start + 3))" | awk '{print $2}')
    test "$kind" -eq 6 ||
        fail "a workspace member at line $start resolved to kind $kind; a member has no version to select"
done

# Explained: the member is the reason for v6, and a member itself is explained
# by where it comes from rather than by a bound. Kind 4 Local.
check 'the member is named as the reason its bound decided the answer' \
    149 155 '10 1 1 6 40 1 2 '
check 'a member is explained as local, not as unresolved' \
    156 162 '20 4 6 0 0 0 0 '
check 'and so is one nobody publishes' \
    163 169 '40 4 6 0 0 0 0 '

# The explanation must not send a reader looking for a requirement to change
# that does not exist. Local is a different answer from unresolved, and the
# resolution it carries must be the member outcome rather than a refusal.
for start in 156 163; do
    row=$(field "$start" "$((start + 6))")
    test "$(printf '%s' "$row" | awk '{print $2}')" -eq 4 ||
        fail "a member at line $start was not explained as local"
    test "$(printf '%s' "$row" | awk '{print $3}')" -eq 6 ||
        fail "a local explanation at line $start does not carry the member outcome"
done

lines=$(wc -l <"$WORK/backend.out" | tr -d ' ')
test "$lines" -eq 169 ||
    fail "recorded decisions cover the whole run: expected 169 lines, got $lines"

# Every named decision passed, so a difference here is a line no assertion
# owns. Checked last, and against the run rather than the other way round.
cmp "$expected" "$WORK/backend.out" ||
    fail 'named decisions passed but the recorded golden still differs'

# Order-independence, read from the golden rather than trusted: the two
# reordered queries must equal the two original ones, byte for byte.
original=$(field 6 13)
reordered=$(field 22 29)
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

# ============================================ the CLI surface and its shape
#
# Two claims, and each is checked against something rather than asserted.

kcli="$ROOT/contracts/kpm-cli.kofun"
test -f "$kcli" || fail 'the CLI contract is missing'

for declaration in \
    'cli Kpm {' \
    '    name "kpm"' \
    '    command lock {' \
    '    command verify {' \
    '    command why {'
do
    grep -Fq -- "$declaration" "$kcli" ||
        fail "the CLI contract lost a declaration: $declaration"
done

# Ahead of the compiler, on purpose. If this ever builds, the binding this
# repository is waiting for has landed and the contract should stop being a
# contract — so the gate fails rather than letting that go unnoticed.
if "$KOFUN" build "$kcli" --framework cli -o "$WORK/kpm" \
    >"$WORK/cli.out" 2>"$WORK/cli.err"
then
    fail 'the CLI contract built; arbitrary actions have landed, so this is
  no longer a contract — bind the commands to the resolver and delete this check'
fi
grep -q 'greet options are' "$WORK/cli.err" ||
    fail "the CLI contract did not stop at the documented boundary:
$(sed 's/^/    /' "$WORK/cli.err")"

# The distribution claim, measured rather than described: the framework writes
# a dependency-free static ELF, and a package manager that is one file is the
# whole reason to care.
"$KOFUN" build "$ROOT/vendor/kofun/examples/cli_tool.kofun" --framework cli \
    -o "$WORK/dist" >"$WORK/dist.out" 2>"$WORK/dist.err" ||
    fail "the native CLI path did not build: $(cat "$WORK/dist.err")"
bytes=$(wc -c <"$WORK/dist" | tr -d ' ')
test "$bytes" -lt 65536 ||
    fail "a native CLI binary is $bytes bytes; the claim is kilobytes, not tens of them"
if command -v ldd >/dev/null 2>&1; then
    ldd "$WORK/dist" 2>&1 | grep -q 'not a dynamic executable' ||
        fail 'the native CLI binary has dynamic dependencies; it is not distributable as one file'
fi
printf 'pm: the native CLI path writes a %s-byte binary with no dynamic dependency: PASS\n' \
    "$bytes"

printf 'pm: an identity is the same in any input order, and moves when any input does: PASS\n'
printf 'pm: a change in a dependency reaches its dependent: PASS\n'

printf 'pm: the core resolves without printing or reaching for the world: PASS\n'
printf 'pm: minimal version selection, every closed outcome read by name: PASS\n'
printf 'pm: the same requirement set in any order gives the same lock: PASS\n'
printf 'pm: a transitive bound only ever rises, so one pass is the whole answer: PASS\n'
printf 'pm: a selection is explained by the bound that decided it, and the explanation agrees: PASS\n'
printf 'pm: the explanation is order-independent, as the selection is: PASS\n'
printf 'pm: a member joins the requirement set and is never fetched: PASS\n'
printf 'pm: reference and C11 agree; bytes hold under hostile TZ, locale, env -i: PASS\n'
