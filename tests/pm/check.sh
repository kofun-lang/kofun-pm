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
# Two recordings of one answer. The seven integers per explanation — module,
# kind, the resolution being explained, the version, who stated the deciding
# bound, how many stated exactly it, and how many did not decide — and then,
# from line 170, the sentence the resolver writes for a person.
#
# The sentence is read where a sentence is the claim, and the integers are
# read where they carry something the words deliberately leave out. Until the
# language could return `Text` the wording was assembled here, in `awk`, from
# those integers: this gate wrote the sentence and then had nothing to check
# it against, so the one output a user actually reads was pinned nowhere.
# `seed/resolver/core.kofun` writes it now, and this reads it.

says() {
    label=$1; at=$2; want=$3
    got=$(sed -n "${at}p" "$WORK/backend.out")
    test "$got" = "$want" || fail "$label:
  expected: $want
  got:      $got"
}

says 'v5 because 20 required it, and the app'"'"'s v2 decided nothing' \
    170 'why 10: v5, because 20 requires >= 5'
says 'and the bound that decided nothing is still accounted for' \
    171 '  1 bound agreed; 1 other bound did not decide the answer'
# The explanation must be a function of the requirement set, exactly as the
# selection is. Naming "the first slot at the maximum" would answer
# differently here, and a lock whose explanation moved with its input order
# would be explaining the order rather than the rule.
says 'the same explanation from the same set in another order' \
    172 'why 10: v5, because 20 requires >= 5'
# The root package is named rather than numbered. It is the requirer an
# explanation names most often, and `1` is an internal code.
says 'a bound nobody competes with is explained by its only author' \
    174 'why 10: v7, because the root package requires >= 7'

# A tie, and the arrangement that makes the two candidate rules disagree: the
# larger requirer code sits in the earlier slot. "The first slot at the
# maximum" would answer 30 here and 20 below; the smallest requirer answers 20
# for both. Without this pair the order-independence claim is untested, because
# every other tie in this golden has the smaller code first and passes under
# either rule.
says 'a tie names the smallest requirer, not the first slot' \
    176 'why 10: v5, because 20 requires >= 5'
# And a tie is said to be one. An explanation naming a single requirer would
# imply that removing it lowers the selection, which is false here.
says 'a tie is reported as a tie, in the plural' \
    177 '  2 bounds agreed; 0 other bounds did not decide the answer'
tied=$(sed -n '176,177p' "$WORK/backend.out")
tied_reordered=$(sed -n '178,179p' "$WORK/backend.out")
test "$tied" = "$tied_reordered" ||
    fail "reordering a tie changed its explanation:
  one order:   $tied
  the other:   $tied_reordered
  the selection is a function of the set; the explanation must be too"

says 'across the closure, the dependency is the reason' \
    180 'why 10: v5, because 20 requires >= 5'
# The counterfactual, recorded rather than argued: remove the dependency and
# the app's own bound becomes the reason. This is what makes the explanation
# actionable — it names the requirement to change.
says 'with the dependency gone, the app is the reason' \
    182 'why 10: v2, because the root package requires >= 2'
says 'a module only the dependency requires does not name the app' \
    184 'why 30: v1, because 20 requires >= 1'
# Nothing to explain, said as such. A bound of zero would read as a real
# answer, and "no one requires this" is a different fact from "version 0".
says 'an unrequired module is unexplained, not explained as zero' \
    186 'why 99: nothing requires it, so there is nothing to explain'
says 'and it says there is no bound rather than reporting none' \
    187 '  no requirement names it, so there is no bound to list'

# The two refusals. As integers both are kind 3 and the output could not tell
# them apart; a reader could not either, and they send someone to two
# different fixes — publish it, or lower the demand. This pair is the clearest
# thing the move to `Text` bought, so it is checked as a pair.
says 'a demand above the ceiling says which ceiling' \
    188 'why 20: required above everything published, so there is nothing to explain'
says 'a module published nowhere says that instead' \
    203 'why 99: nobody publishes it, so there is nothing to explain'
above=$(sed -n '188p' "$WORK/backend.out")
nowhere=$(sed -n '203p' "$WORK/backend.out")
test "$above" != "$nowhere" ||
    fail "two different refusals produced one sentence:
  $above
  both are kind 3 in the fields; the words are what tells them apart"

# A member, and both halves of the rule that pulls in two directions.
says 'a member is explained as local, and as nothing to fetch' \
    192 'why 20: a workspace member, so there is nothing to fetch'
says 'and its requirements are still said to join the set' \
    193 '  a member has no version to select, and its own requirements still join the set'
says 'the member is named as the reason its bound decided the answer' \
    190 'why 10: v6, because 40 requires >= 6'

# What the sentence deliberately does not say, read from the fields instead.
# `resolution` is the outcome being explained — 4 Unrequired, 3 AboveHighest —
# and `version` is 0 rather than a bound. The wording carries neither on
# purpose: a reader does not need the outcome's number, and a machine should
# not be parsing prose for it.
check 'an unrequired explanation carries its outcome and invents no bound' \
    114 120 '99 2 4 0 0 0 0 '
check 'a refusal names its resolution and invents no bound' \
    121 127 '20 3 3 0 0 0 0 '

# The two recordings must not be able to disagree. They are made from one
# `Why` in one run, so a difference here is a rendering that drifted from the
# answer it renders — which would be worse than no explanation, because it
# would be a confident wrong one.
for pair in '58:170' '65:172' '72:174' '79:176' '86:178' '93:180' \
    '100:182' '107:184' '149:190'
do
    version=$(field "${pair%%:*}" "$((${pair%%:*} + 6))" | awk '{print $4}')
    sentence=$(sed -n "${pair##*:}p" "$WORK/backend.out")
    case "$sentence" in
        *"v$version, because "*) ;;
        *) fail "the sentence and the fields disagree:
  the fields say v$version
  the sentence says: $sentence" ;;
    esac
done

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
test "$lines" -eq 218 ||
    fail "recorded decisions cover the whole run: expected 218 lines, got $lines"

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

# BuildSettings is the declared inventory of output-affecting settings. Every
# field must be flattened into Closure and must be folded beside its own domain
# tag. This is the forward-looking half of completeness: adding a setting to
# the inventory without making it reach the identity fails here, before a
# cache can ignore it.
sed -n '/^type BuildSettings = {$/,/^}$/p' "$WORK/dcore.code" |
    sed -n 's/^[[:space:]]*\([a-z][a-z0-9_]*\):[[:space:]]*Int,$/\1/p' \
    >"$WORK/build-setting.fields"
test -s "$WORK/build-setting.fields" ||
    fail 'the derivation core declares no build settings'
sed -n '/^fn fold_settings(/,/^}/p' "$WORK/dcore.code" \
    >"$WORK/build-setting.fold"
while IFS= read -r setting; do
    grep -Fq "setting_${setting}: Int," "$WORK/dcore.code" ||
        fail "build setting '$setting' is not carried by Closure"
    grep -Eq "mix_domain\([^,]+, setting_${setting}_domain\(\), closure\.setting_${setting}\)" \
        "$WORK/build-setting.fold" ||
        fail "build setting '$setting' does not reach the derivation identity through its own domain"
done <"$WORK/build-setting.fields"

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

# Each named build setting is inside the closure. One opaque settings integer
# could not say which of these was forgotten.
setting_label=7
while IFS= read -r setting; do
    setting_label=$((setting_label + 1))
    test "$(id_of 4)" != "$(id_of "$setting_label")" ||
        fail "a changed $setting setting left the identity unmoved; the cache would serve the wrong build"
done <"$WORK/build-setting.fields"

# The refusals, by kind: 2 NoInputs, 3 ReservedDigest.
test "$(kind_of 14)" = 2 || fail 'an empty closure was not refused'
test "$(kind_of 15)" = 3 || fail 'a reserved digest in a live slot was not refused'

# ============================================ the CLI surface and its shape
#
# Two claims, and each is checked against something rather than asserted.

kcli="$ROOT/contracts/kpm-cli.kofun"
test -f "$kcli" || fail 'the CLI contract is missing'
version_file="$ROOT/VERSION"
test -f "$version_file" || fail 'the source release version is missing'
test "$(wc -l <"$version_file" | tr -d ' ')" -eq 1 &&
    grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' "$version_file" ||
    fail 'VERSION must contain exactly one semantic version'
project_version=$(sed -n '1p' "$version_file")
grep -Fq "    version \"$project_version\"" "$kcli" ||
    fail "the CLI contract version does not match VERSION $project_version"

for declaration in \
    'cli Kpm {' \
    '    name "kpm"' \
    '    command lock {' \
    '    command fetch {' \
    '    command verify {' \
    '    command why {'
do
    grep -Fq -- "$declaration" "$kcli" ||
        fail "the CLI contract lost a declaration: $declaration"
done

# Required data/authority inputs have no ambient default. Check the exact line
# inside the exact command block: a repository-wide substring check would let
# one command borrow another command's --store declaration, and a prefix check
# would miss somebody appending a default.
command_has_exact() {
    command_name=$1
    exact_declaration=$2
    awk -v target="    command $command_name {" \
        -v declaration="$exact_declaration" '
        $0 == target { commands++; inside = 1; next }
        inside && $0 == "    }" { inside = 0; next }
        inside && $0 == declaration { found++ }
        END { exit !(commands == 1 && found == 1) }
    ' "$kcli" || fail "the $command_name command lost its exact required input: $exact_declaration"
}

command_has_exact fetch \
    '        option authority "--authority" text "Path to the explicit approved-origin authority file"'
command_has_exact fetch \
    '        option store "--store" text "Path to the content-addressed store"'
command_has_exact lock \
    '        option store "--store" text "Path to the content-addressed store"'
command_has_exact why \
    '        option manifest "--manifest" text "Path to kofun.toml"'
command_has_exact why \
    '        option lock "--lock" text "Path to kofun.packages.lock"'
command_has_exact why \
    '        option store "--store" text "Path to the content-addressed store"'

# Network authority is a command, not a mode. Fetch is the only declared
# network operation, so lock cannot become online because somebody forgot a
# flag. The contract itself has no --offline switch because offline is the
# default and only behavior of every other command.
sed 's/[[:space:]]*#.*$//' "$kcli" >"$WORK/kcli.decl"
if grep -Fq -- '"--offline"' "$WORK/kcli.decl"; then
    fail 'the CLI contract made offline behavior optional again'
fi

fetch_adr="$ROOT/docs/adr/0007-static-url-fetch-protocol.md"
test -f "$fetch_adr" || fail 'the static URL fetch protocol ADR is missing'
for decision in \
    'P@kofun/v1/catalog' \
    'P@kofun/v1/versions/<version>.meta' \
    'P@kofun/v1/blobs/sha256/<64-lowercase-hex>' \
    'kofun-fetch-authority/v1' \
    'kofun-pm.lock/v2' \
    'Only `kpm fetch` has network authority' \
    'required version P@V is not published' \
    'separate workspace-identity visited set' \
    'There is no client-wide' \
    'metadata\t<identity>\t<version>\t<size>\t<sha256>' \
    'missing selected file' \
    'kofun-pm.requirements/v2' \
    'migration always requires explicit' \
    '`Accept-Encoding: identity`' \
    'approved public origins' \
    'atomic create-if-absent semantics' \
    'affine read handle' \
    'Every later add, lookup, link/copy, or build handoff rehashes' \
    'package identities in one closure, including workspace' \
    'distinct identity/version pairs in one rough graph' \
    'one lock v2 file' \
    'HTTP request/connection attempts in one fetch, including redirects and failures'
do
    grep -Fq -- "$decision" "$fetch_adr" ||
        fail "the fetch contract lost a decision: $decision"
done

fetch_authority="$ROOT/contracts/fetch-authority.tsv"
test -f "$fetch_authority" || fail 'the explicit fetch authority contract is missing'
test "$(sed -n '1p' "$fetch_authority")" = 'kofun-fetch-authority/v1' ||
    fail 'the fetch authority contract lost its format header'
awk -F '\t' '
    NR == 2 && $1 == "origin" && $2 == "https://example.org" { found = 1 }
    END { exit !found }
' "$fetch_authority" || fail 'the fetch authority contract lost its canonical origin row'

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

# ============================================================== the lock
#
# `go.sum` pins artifacts. This pins the resolution as well, and that is only
# worth doing because MVS is a function: re-resolving the same requirements
# must give the same answer, so verifying is a check rather than a hope.
#
# Four failures, and the whole value is that they are separate rather than one.
# "The lock is wrong" sends a reader nowhere; "you edited it", "it is stale",
# "the resolver changed", and "the same resolver changed its answer" each say
# what to do next.

lock_tool="$ROOT/scripts/lock.sh"
test -x "$lock_tool" || fail 'the lock tool is missing'
committed_lock="$ROOT/kofun.lock"
test -f "$committed_lock" || fail 'the committed lock is missing'

# Idempotence. Same requirements, byte-identical lock, run twice — the claim
# the language's own `kofun.packages.lock` makes and this extends.
sh "$lock_tool" write "$WORK/first.lock" >"$WORK/lock.write1" 2>&1 ||
    fail "the lock could not be written: $(cat "$WORK/lock.write1")"
sh "$lock_tool" write "$WORK/second.lock" >"$WORK/lock.write2" 2>&1 ||
    fail "the lock could not be written a second time: $(cat "$WORK/lock.write2")"
cmp "$WORK/first.lock" "$WORK/second.lock" ||
    fail "re-locking the same requirements produced a different lock:
$(diff "$WORK/first.lock" "$WORK/second.lock" | sed 's/^/    /')"

sh "$lock_tool" verify "$WORK/first.lock" >"$WORK/lock.verify" 2>&1 ||
    fail "a freshly written lock did not verify: $(cat "$WORK/lock.verify")"

# The committed lock still describes the scenario in the tree. This is the
# check that makes the lock a discipline rather than a file: change the
# requirements without re-locking and the gate says so.
sh "$lock_tool" verify "$committed_lock" >"$WORK/lock.committed" 2>&1 ||
    fail "the committed lock no longer matches the tree:
$(sed 's/^/    /' "$WORK/lock.committed")
  re-lock with: sh scripts/lock.sh write"

# A member is recorded as a member and carries no version. A lock that pinned
# one would be pinning a local path, which is wrong on every other machine —
# the reason Member is an outcome rather than a Selected with a version.
grep -qE '^20	workspace	-$' "$committed_lock" ||
    fail 'the lock does not record module 20 as a workspace member without a version'
if grep -E '^[0-9]+	workspace	' "$committed_lock" | grep -qvE '	-$'; then
    fail 'a workspace member was locked with a version; a lock must not pin a local path'
fi

# --- the four refusals, each by name

re_sign() {
    # Rebuild a lock's digest over its edited contents, so the result is
    # internally consistent. Without this a stale lock is indistinguishable
    # from an edited one, and the two want opposite responses.
    grep -v '^# digest: ' "$1" >"$WORK/resign.covered"
    cat "$WORK/resign.covered" >"$2"
    if command -v sha256sum >/dev/null 2>&1; then
        printf '# digest: %s\n' \
            "$(sha256sum <"$WORK/resign.covered" | cut -d' ' -f1)" >>"$2"
    else
        printf '# digest: %s\n' \
            "$(shasum -a 256 <"$WORK/resign.covered" | cut -d' ' -f1)" >>"$2"
    fi
}

expect_refusal() {
    label=$1; file=$2; needle=$3
    if sh "$lock_tool" verify "$file" >"$WORK/refusal.log" 2>&1; then
        fail "$label: the lock verified when it should not have"
    fi
    grep -Fq -- "$needle" "$WORK/refusal.log" ||
        fail "$label: refused, but not by name:
$(sed 's/^/    /' "$WORK/refusal.log")"
}

# An edited row.
sed 's/^10	selected	6$/10	selected	7/' "$committed_lock" >"$WORK/edited.lock"
expect_refusal 'a hand-edited row was not refused' \
    "$WORK/edited.lock" "the file has been edited by hand"

# An edited *header*. The digest covers everything above it for this reason:
# a digest over the rows alone would let someone move the requirement digest
# and keep the selection, which is the edit worth making and the one nobody
# would notice.
sed 's/^# requirements: .*/# requirements: 0000000000000000/' "$committed_lock" \
    >"$WORK/header.lock"
expect_refusal 'a hand-edited header was not refused' \
    "$WORK/header.lock" "the file has been edited by hand"

# A stale lock: internally consistent, but written against other requirements.
# It must be told apart from an edited one — re-locking is the answer to this
# and is the wrong answer to the two above.
sed 's/^# requirements: .*/# requirements: 1111111111111111111111111111111111111111111111111111111111111111/' \
    "$committed_lock" >"$WORK/stale.pre"
re_sign "$WORK/stale.pre" "$WORK/stale.lock"
expect_refusal 'a stale lock was not refused' \
    "$WORK/stale.lock" "written against a different requirement set"
# …and specifically not as tampering, or the reader is sent to the wrong fix.
sh "$lock_tool" verify "$WORK/stale.lock" >"$WORK/stale.log" 2>&1 || true
if grep -Fq 'edited by hand' "$WORK/stale.log"; then
    fail 'a stale lock was reported as a hand edit; the two want opposite responses'
fi

# A different resolver/tool input identity. It is internally consistent and
# its requirements still match, so this must not collapse into tampering or
# stale input. Repository HEAD is intentionally not used: unrelated commits
# must not force every project to re-lock.
sed 's/^# tool: .*/# tool: ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff/' \
    "$committed_lock" >"$WORK/tool-changed.pre"
re_sign "$WORK/tool-changed.pre" "$WORK/tool-changed.lock"
expect_refusal 'a different resolver tool identity was not refused' \
    "$WORK/tool-changed.lock" "the resolver tool identity changed"
sh "$lock_tool" verify "$WORK/tool-changed.lock" >"$WORK/tool-changed.log" 2>&1 || true
if grep -Eq 'edited by hand|different requirement set' "$WORK/tool-changed.log"; then
    fail 'a resolver change was confused with tampering or stale requirements'
fi

grep -Eq '^# tool: [0-9a-f]{64}$' "$committed_lock" ||
    fail 'the lock tool identity is not a SHA-256 digest'

# --- the manifest surface
#
# The declared shape of a `[dependencies]` section: an identity and a lower
# bound, and nothing else. The absences are the decisions, so they are asserted
# rather than described — a list of things a file does not contain is exactly
# the kind of claim that rots.

manifest="$ROOT/contracts/manifest.toml"
test -f "$manifest" || fail 'the manifest surface is missing'
grep -q '^\[dependencies\]$' "$manifest" ||
    fail 'the manifest surface no longer declares a [dependencies] section'

# Read with comments stripped: the file spends most of its length explaining
# what it refuses to carry, and a grep over the whole text cannot tell an
# explanation from a declaration.
sed 's/[[:space:]]*#.*$//' "$manifest" >"$WORK/manifest.decl"

# Every dependency is a lower bound. An upper bound reintroduces the conflict
# case MVS does not have, and with it the solver ADR 1 declined.
if grep -qE '"\^|"~|<[[:space:]]*[0-9]|,[[:space:]]*<' "$WORK/manifest.decl"; then
    fail 'the manifest declares an upper bound; every requirement under MVS is a lower bound'
fi
grep -qE '^"[^"]+"[[:space:]]*=[[:space:]]*">= ' "$WORK/manifest.decl" ||
    fail 'no dependency is declared as a lower bound'

# The major is in the identity, so there is no field for it.
if grep -qE '^[[:space:]]*major[[:space:]]*=' "$WORK/manifest.decl"; then
    fail 'the manifest names a major separately; the identity already carries it'
fi

# Each of these would make the resolution a function of something other than
# the requirement set, which is the property the lock rests on.
for absent in features optional 'git' branch rev registry index; do
    if grep -qE "^[[:space:]]*$absent[[:space:]]*=" "$WORK/manifest.decl"; then
        fail "the manifest grew a '$absent' field; the resolution would stop being a function of the requirement set alone"
    fi
done

# A member is declared and never given a version, for the same reason the lock
# refuses to pin one.
grep -q '^\[workspace\]$' "$WORK/manifest.decl" ||
    fail 'the manifest surface no longer declares a [workspace] section'
if grep -E '^members[[:space:]]*=' "$WORK/manifest.decl" | grep -qE '>=|[0-9]+\.[0-9]+'; then
    fail 'a workspace member carries a version; a member is declared, not required'
fi

printf 'pm: a dependency is an identity and a lower bound, and the absences are asserted: PASS\n'
printf 'pm: the lock pins the resolution, and re-locking is idempotent: PASS\n'
printf 'pm: edited, stale, resolver-changed, and drifted locks are four refusals: PASS\n'
printf 'pm: a workspace member is locked as a member, never as a version: PASS\n'

# ============================================================= the store
#
# A store keyed by digest makes "is this the artifact the lock promised" a
# question answerable without a network. It is also global state — one
# directory shared by every project on a machine — which is why `verify` runs
# here rather than waiting to be typed. A store whose integrity is only
# checked on request is a store whose integrity is unknown.

store_tool="$ROOT/scripts/store.sh"
test -x "$store_tool" || fail 'the store tool is missing'

STORE="$WORK/store"
store() {
    sh "$store_tool" --store "$STORE" "$@"
}

file_digest() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum <"$1" | cut -d' ' -f1
    else
        shasum -a 256 <"$1" | cut -d' ' -f1
    fi
}

store_entry_for() {
    printf '%s/%s/%s\n' "$STORE" "$(printf '%s' "$1" | cut -c1-2)" \
        "$(printf '%s' "$1" | cut -c3-)"
}

# HOME, XDG_CACHE_HOME, and a legacy KPM_STORE are not store authority. The
# adapter must stop before touching any of them when --store is absent.
if env -i PATH="$PATH" HOME="$WORK/ambient-home" \
    XDG_CACHE_HOME="$WORK/ambient-cache" KPM_STORE="$WORK/ambient-store" \
    sh "$store_tool" verify >"$WORK/store.ambient" 2>&1
then
    fail 'the store accepted ambient location authority without --store'
fi
grep -Fq -- '--store' "$WORK/store.ambient" ||
    fail 'the missing explicit store input was not refused by name'
test ! -e "$WORK/ambient-home" && test ! -e "$WORK/ambient-cache" &&
    test ! -e "$WORK/ambient-store" ||
    fail 'the store touched an ambient location before refusing it'
if sh "$store_tool" --store relative verify >"$WORK/store.relative" 2>&1; then
    fail 'the store accepted a relative mutation boundary'
fi
grep -Fq 'must be an absolute path' "$WORK/store.relative" ||
    fail 'a relative store was not refused by name'
if sh "$store_tool" --store / verify >"$WORK/store.root" 2>&1; then
    fail 'the store accepted the filesystem root as its mutation boundary'
fi
grep -Fq 'refuses the filesystem root' "$WORK/store.root" ||
    fail 'the filesystem-root store was not refused by name'
if sh "$store_tool" --store /tmp/.. verify >"$WORK/store.root-dotdot" 2>&1; then
    fail 'the store accepted a dot-segment alias of the filesystem root'
fi
grep -Fq 'refuses the filesystem root' "$WORK/store.root-dotdot" ||
    fail 'a dot-segment root alias was not normalized and refused by name'
ln -s / "$WORK/root-store-link"
if sh "$store_tool" --store "$WORK/root-store-link" verify \
    >"$WORK/store.root-symlink" 2>&1
then
    fail 'the store accepted a symlink alias of the filesystem root'
fi
grep -Fq 'refuses the filesystem root' "$WORK/store.root-symlink" ||
    fail 'a symlink root alias was not resolved and refused by name'

mkdir -p "$WORK/src"
printf 'package alpha\n' >"$WORK/src/a"
printf 'package beta\n' >"$WORK/src/b"
# The same bytes under a different name. Nothing about the name may reach the
# store, so this must not become a second entry.
printf 'package alpha\n' >"$WORK/src/a-renamed"

digest_a=$(env -i PATH="$PATH" sh "$store_tool" --store "$STORE" \
    add "$WORK/src/a" 2>"$WORK/store.add-a") ||
    fail 'the store could not accept a file'
digest_b=$(store add "$WORK/src/b" 2>"$WORK/store.add-b")
digest_again=$(store add "$WORK/src/a-renamed" 2>"$WORK/store.add-again")

mkdir -p "$WORK/option-input"
cp "$WORK/src/a" "$WORK/option-input/-"
digest_option=$(cd "$WORK/option-input" && \
    sh "$store_tool" --store "$STORE" add - <"$WORK/src/b" \
    2>"$WORK/store.add-option") || fail "the store could not read pathname '-'"
test "$digest_option" = "$digest_a" ||
    fail "the store replaced pathname '-' with ambient stdin"

test "$digest_a" = "$digest_again" ||
    fail "the same bytes under another name produced a different digest:
  $digest_a and $digest_again"
stored=$(find "$STORE" -type f | wc -l | tr -d ' ')
test "$stored" -eq 2 ||
    fail "three adds of two distinct contents produced $stored entries; the store is keyed by something other than content"

# Admission is the fetch boundary: the declared size and digest are checked on
# the completed temporary before any final name exists. Each refusal also has
# to clean its temporary; an untrusted partial must never look like a winner.
printf 'package gamma\n' >"$WORK/src/c"
digest_c=$(file_digest "$WORK/src/c")
bytes_c=$(wc -c <"$WORK/src/c" | tr -d ' ')
wrong_size=$((bytes_c + 1))
if store admit "$digest_c" "$wrong_size" "$WORK/src/c" \
    >"$WORK/store.wrong-size" 2>&1
then
    fail 'store admission accepted a candidate with the wrong declared size'
fi
grep -Fq 'input size does not match its descriptor' "$WORK/store.wrong-size" ||
    fail 'wrong-size admission was not refused by name'
test ! -e "$(store_entry_for "$digest_c")" ||
    fail 'wrong-size admission made a trusted final entry visible'

zero_digest=0000000000000000000000000000000000000000000000000000000000000000
if store admit "$zero_digest" "$bytes_c" "$WORK/src/c" \
    >"$WORK/store.wrong-digest" 2>&1
then
    fail 'store admission accepted a candidate with the wrong declared digest'
fi
grep -Fq 'candidate digest does not match its descriptor' "$WORK/store.wrong-digest" ||
    fail 'wrong-digest admission was not refused by name'
test ! -e "$(store_entry_for "$zero_digest")" ||
    fail 'wrong-digest admission made a trusted final entry visible'
test "$(find "$STORE" -type f -name '*.incoming.*' | wc -l | tr -d ' ')" -eq 0 ||
    fail 'a refused admission left an untrusted temporary behind'

# TERM during a real bounded copy must never expose a final name. The trap
# removes the partial candidate; the later manual-leftover case separately
# proves verify catches the residue that an untrappable SIGKILL could leave.
printf 'package interrupted\n' >"$WORK/src/interrupted"
interrupt_digest=$(file_digest "$WORK/src/interrupted")
interrupt_bytes=$(wc -c <"$WORK/src/interrupted" | tr -d ' ')
head_bin="$WORK/head-delay-bin"
head_marker="$WORK/head-delay.ready"
mkdir -p "$head_bin"
cp "$ROOT/tests/pm/head-delay.sh" "$head_bin/head"
chmod +x "$head_bin/head"
real_head=$(command -v head)
env PATH="$head_bin:$PATH" KPM_REAL_HEAD="$real_head" \
    KPM_HEAD_MARKER="$head_marker" \
    sh "$store_tool" --store "$STORE" admit \
    "$interrupt_digest" "$interrupt_bytes" "$WORK/src/interrupted" \
    >"$WORK/store.interrupted.out" 2>"$WORK/store.interrupted.err" &
interrupt_pid=$!
attempt=0
while ! test -f "$head_marker"; do
    attempt=$((attempt + 1))
    test "$attempt" -lt 10 || {
        kill -TERM "$interrupt_pid" 2>/dev/null || :
        wait "$interrupt_pid" 2>/dev/null || :
        fail 'the bounded copy never reached its observable interruption point'
    }
    sleep 1
done
kill -TERM "$interrupt_pid"
if wait "$interrupt_pid"; then
    fail 'a publisher interrupted during bounded copy reported success'
fi
test ! -e "$(store_entry_for "$interrupt_digest")" ||
    fail 'an interrupted publisher exposed an unverified final entry'
test "$(find "$STORE" -type f -name '*.incoming.*' | wc -l | tr -d ' ')" -eq 0 ||
    fail 'a trappable interrupted publisher left its partial candidate behind'

admitted_c=$(store admit "$digest_c" "$bytes_c" "$WORK/src/c" \
    2>"$WORK/store.admit-c") || fail 'a matching descriptor was not admitted'
test "$admitted_c" = "$digest_c" ||
    fail 'successful admission did not return the verified digest'
grep -Fq 'with create-if-absent' "$WORK/store.admit-c" ||
    fail 'successful admission did not name its no-replace publication'

# Install a directory symlink after the absence check but at the real ln call.
# Exact-name publication must fail without creating a nested hard link outside
# the explicitly supplied store boundary.
printf 'package exact target\n' >"$WORK/src/exact"
exact_digest=$(file_digest "$WORK/src/exact")
exact_bytes=$(wc -c <"$WORK/src/exact" | tr -d ' ')
exact_entry=$(store_entry_for "$exact_digest")
exact_outside="$WORK/publication-outside"
exact_bin="$WORK/ln-exact-bin"
mkdir -p "$(dirname -- "$exact_entry")" "$exact_outside" "$exact_bin"
cp "$ROOT/tests/pm/ln-barrier.sh" "$exact_bin/ln"
chmod +x "$exact_bin/ln"
real_ln=$(command -v ln)
if env PATH="$exact_bin:$PATH" KPM_REAL_LN="$real_ln" \
    KPM_LN_ATTACK_TARGET="$exact_entry" \
    KPM_LN_ATTACK_OUTSIDE="$exact_outside" \
    sh "$store_tool" --store "$STORE" admit \
    "$exact_digest" "$exact_bytes" "$WORK/src/exact" \
    >"$WORK/store.exact-target" 2>&1
then
    fail 'publication accepted a directory symlink installed at its final name'
fi
grep -Fq 'entry is not a regular file' "$WORK/store.exact-target" ||
    fail 'the directory-symlink publication race was not refused by name'
test "$(find "$exact_outside" -type f | wc -l | tr -d ' ')" -eq 0 ||
    fail 'publication created a nested hard link outside the store boundary'
test "$(find "$STORE" -type f -name '*.incoming.*' | wc -l | tr -d ' ')" -eq 0 ||
    fail 'the directory-symlink publication refusal left a temporary behind'
rm -f "$exact_entry"

# Force every publisher past its absence check before any real ln call. Exactly
# one hard link may create the final name; every loser must rehash and adopt it.
printf 'package delta\n' >"$WORK/src/d"
digest_d=$(file_digest "$WORK/src/d")
bytes_d=$(wc -c <"$WORK/src/d" | tr -d ' ')
barrier="$WORK/ln-barrier"
barrier_bin="$WORK/ln-barrier-bin"
race="$WORK/store-race"
mkdir -p "$barrier" "$barrier_bin" "$race"
cp "$ROOT/tests/pm/ln-barrier.sh" "$barrier_bin/ln"
chmod +x "$barrier_bin/ln"
real_ln=$(command -v ln)
race_pids=
n=1
while test "$n" -le 8; do
    env PATH="$barrier_bin:$PATH" KPM_REAL_LN="$real_ln" \
        KPM_LN_BARRIER="$barrier" KPM_LN_EXPECTED=8 \
        sh "$store_tool" --store "$STORE" \
        admit "$digest_d" "$bytes_d" "$WORK/src/d" \
        >"$race/$n.out" 2>"$race/$n.err" &
    race_pids="$race_pids $!"
    n=$((n + 1))
done
race_failures=0
for race_pid in $race_pids; do
    wait "$race_pid" || race_failures=$((race_failures + 1))
done
test "$race_failures" -eq 0 ||
    fail "$race_failures concurrent store publishers failed"
test "$(find "$barrier" -type f -name 'caller.*' | wc -l | tr -d ' ')" -eq 8 ||
    fail 'not every concurrent publisher reached atomic link publication'
published=$(grep -l 'published .* create-if-absent' "$race"/*.err | wc -l | tr -d ' ')
adopted=$(grep -l 'adopted .*winner' "$race"/*.err | wc -l | tr -d ' ')
test "$published" -eq 1 && test "$adopted" -eq 7 ||
    fail "concurrent publication produced $published publishers and $adopted adopters; expected 1 and 7"
for race_output in "$race"/*.out; do
    test "$(cat "$race_output")" = "$digest_d" ||
        fail "a concurrent publisher returned something other than $digest_d"
done
entry_d=$(store path "$digest_d")
test "$(file_digest "$entry_d")" = "$digest_d" ||
    fail 'the concurrent winner does not hash to its final name'
test "$(find "$STORE" -type f -name '*.incoming.*' | wc -l | tr -d ' ')" -eq 0 ||
    fail 'concurrent publication left a temporary behind'

# The path is the digest and nothing else. A name or a version in it would make
# the same bytes two entries and would make the store's integrity depend on
# metadata the bytes do not carry.
entry_a=$(store path "$digest_a")
test "$(printf '%s' "${entry_a#"$STORE"/}" | tr -d '/')" = "$digest_a" ||
    fail "the store path carries something other than the digest: $entry_a"

store verify >"$WORK/store.verify" 2>&1 ||
    fail "a freshly filled store did not verify: $(cat "$WORK/store.verify")"

# Links rather than copies: the same inode, so ten projects sharing a
# dependency store ten copies of nothing.
store link "$digest_a" "$WORK/proj/a" >"$WORK/store.link" 2>&1 ||
    fail "the store could not link an entry: $(cat "$WORK/store.link")"
grep -q '^store: linked and rehashed ' "$WORK/store.link" ||
    fail "linking fell back to a copy on a filesystem that supports links:
$(cat "$WORK/store.link")"
links=$(( $(stat -c %h "$entry_a" 2>/dev/null || stat -f %l "$entry_a") ))
test "$links" -ge 2 ||
    fail "the entry has $links link(s) after linking; the bytes were copied, not shared"

# And the fallback, forced. A fallback that is never exercised is a fallback
# nobody knows is broken — this is the path taken across filesystems and on
# filesystems without hard links at all.
KPM_NO_HARDLINK=1 sh "$store_tool" --store "$STORE" \
    link "$digest_b" "$WORK/proj/b" \
    >"$WORK/store.copy" 2>&1 ||
    fail "the copy fallback failed: $(cat "$WORK/store.copy")"
grep -q 'the filesystem refused a link' "$WORK/store.copy" ||
    fail 'the forced fallback did not take the copy path'
cmp "$WORK/src/b" "$WORK/proj/b" ||
    fail 'the copied dependency does not match the entry it came from'
test ! -w "$WORK/proj/b" ||
    fail 'a copied dependency is writable; a project that edits it in place makes its lock a description of something else'

# The destination is a second trust boundary. Corrupt a forced private copy
# immediately after its exact-name handoff; the post-handoff rehash must refuse
# even though the pre-handoff hash was correct.
mv_bin="$WORK/mv-corrupt-bin"
handoff_dest="$WORK/proj/handoff-corrupt"
mkdir -p "$mv_bin"
cp "$ROOT/tests/pm/mv-corrupt.sh" "$mv_bin/mv"
chmod +x "$mv_bin/mv"
real_mv=$(command -v mv)
if env PATH="$mv_bin:$PATH" KPM_REAL_MV="$real_mv" \
    KPM_MV_CORRUPT_DEST="$handoff_dest" KPM_NO_HARDLINK=1 \
    sh "$store_tool" --store "$STORE" link "$digest_b" "$handoff_dest" \
    >"$WORK/store.handoff-corrupt" 2>&1
then
    fail 'materialization accepted a destination corrupted at handoff'
fi
grep -Fq 'materialized destination changed before handoff' \
    "$WORK/store.handoff-corrupt" ||
    fail 'post-handoff destination corruption was not caught by rehash'
test "$(file_digest "$(store_entry_for "$digest_b")")" = "$digest_b" ||
    fail 'a corrupted private copy changed its source store entry'
rm -f "$handoff_dest"

# A lock-declared size is an I/O bound, not merely a comparison after work.
# Put a much larger digest-valid object in the store, then request a zero-byte
# snapshot under a SHA spy. Size mismatch must stop before hash, copy, temp,
# or destination visibility.
dd if=/dev/zero of="$WORK/src/oversized" bs=1048576 count=2 2>/dev/null
oversized_digest=$(store add "$WORK/src/oversized" 2>"$WORK/store.add-oversized")
sha_bin="$WORK/sha-forbid-bin"
sha_marker="$WORK/sha-forbid.called"
mkdir -p "$sha_bin"
cp "$ROOT/tests/pm/sha-forbid.sh" "$sha_bin/sha256sum"
chmod +x "$sha_bin/sha256sum"
if env PATH="$sha_bin:$PATH" KPM_SHA_MARKER="$sha_marker" \
    sh "$store_tool" --store "$STORE" snapshot "$oversized_digest" 0 \
    "$WORK/proj/oversized-snapshot" >"$WORK/store.oversized-snapshot" 2>&1
then
    fail 'a small lock descriptor snapshotted a much larger store object'
fi
grep -Fq 'size mismatch is refused before hashing' \
    "$WORK/store.oversized-snapshot" ||
    fail 'oversized store snapshot was not refused before digest work'
test ! -e "$sha_marker" ||
    fail 'oversized store snapshot hashed bytes after its size already mismatched'
test ! -e "$WORK/proj/oversized-snapshot" ||
    fail 'oversized store snapshot exposed a destination'
test "$(find "$WORK/proj" -name '.kpm-incoming.*' | wc -l | tr -d ' ')" -eq 0 ||
    fail 'oversized store snapshot created a private copy before size refusal'

# --- the three ways a store goes wrong, each named

expect_store_refusal() {
    label=$1; needle=$2
    if store verify >"$WORK/store.bad" 2>&1; then
        fail "$label: the store verified when it should not have"
    fi
    grep -Fq -- "$needle" "$WORK/store.bad" ||
        fail "$label: refused, but not by name:
$(sed 's/^/    /' "$WORK/store.bad")"
}

# Corruption names the entry, what it should be, and what it is. "The store is
# corrupt" tells an operator to delete all of it; this tells them which
# artifact to fetch again.
chmod 644 "$entry_a"
printf 'tampered\n' >"$entry_a"
chmod 444 "$entry_a"
if store path "$digest_a" >"$WORK/store.corrupt-path" 2>&1; then
    fail 'lookup returned a digest-shaped path without rehashing its bytes'
fi
grep -Fq 'store: CORRUPT' "$WORK/store.corrupt-path" ||
    fail 'lookup did not name corruption found at its use boundary'
if store link "$digest_a" "$WORK/proj/corrupt-source" \
    >"$WORK/store.corrupt-link" 2>&1
then
    fail 'materialization used a corrupt store entry'
fi
grep -Fq 'store: CORRUPT' "$WORK/store.corrupt-link" ||
    fail 'materialization did not rehash its source before use'
test ! -e "$WORK/proj/corrupt-source" ||
    fail 'materialization exposed a destination from a corrupt source entry'
winner_inode_before=$(stat -c %i "$entry_a" 2>/dev/null || stat -f %i "$entry_a")
bytes_a=$(wc -c <"$WORK/src/a" | tr -d ' ')
if store admit "$digest_a" "$bytes_a" "$WORK/src/a" \
    >"$WORK/store.corrupt-winner" 2>&1
then
    fail 'admission silently replaced a corrupt existing winner'
fi
grep -Fq 'store: CORRUPT' "$WORK/store.corrupt-winner" ||
    fail 'a corrupt existing winner was not rehashed and named'
grep -Fq 'recovery remove the entry' "$WORK/store.corrupt-winner" ||
    fail 'a corrupt existing winner did not name its recovery action'
winner_inode_after=$(stat -c %i "$entry_a" 2>/dev/null || stat -f %i "$entry_a")
test "$winner_inode_before" = "$winner_inode_after" ||
    fail 'a refused admission replaced the corrupt winner inode'
test "$(cat "$entry_a")" = tampered ||
    fail 'a refused admission changed the corrupt winner bytes'
expect_store_refusal 'a corrupted entry was not named' 'store: CORRUPT'
grep -Fq "  expected $digest_a" "$WORK/store.bad" ||
    fail 'the corruption report does not say what the entry should have been'
grep -qE '^  actual   [0-9a-f]{64}$' "$WORK/store.bad" ||
    fail 'the corruption report does not say what the entry actually is'

# Restore, and then the condition *under which* corruption becomes possible
# without anyone doing anything wrong. A hard link shares the inode, so a
# writable entry is one any project can edit for every other project.
chmod 644 "$entry_a"
cp "$WORK/src/a" "$entry_a"
expect_store_refusal 'a writable entry was not flagged' 'store: WRITABLE'
chmod 444 "$entry_a"

# An interrupted write is not corruption of an entry — nothing claims it — but
# a store that quietly accumulates half-written files is one nobody is
# watching.
touch "$STORE/$(printf '%s' "$digest_b" | cut -c1-2)/leftover.incoming.1"
expect_store_refusal 'an interrupted write was not reported' 'interrupted write'
rm -f "$STORE"/*/leftover.incoming.1

# A digest-looking symlink is not an entry. Verification must enumerate it and
# refuse rather than follow it or ignore it.
symlink_entry=$(store_entry_for "$zero_digest")
ln -s "$WORK/src/a" "$symlink_entry"
expect_store_refusal 'a symlink entry was not reported' 'store: NOT_REGULAR'
rm -f "$symlink_entry"

# Special files and directories at digest positions wedge admission just as a
# symlink does, so a green verify must enumerate and reject them too.
fifo_digest=1111111111111111111111111111111111111111111111111111111111111111
fifo_entry=$(store_entry_for "$fifo_digest")
mkdir -p "$(dirname -- "$fifo_entry")"
mkfifo "$fifo_entry"
expect_store_refusal 'a FIFO entry was ignored' 'store: NOT_REGULAR'
rm -f "$fifo_entry"
directory_digest=2222222222222222222222222222222222222222222222222222222222222222
directory_entry=$(store_entry_for "$directory_digest")
mkdir -p "$(dirname -- "$directory_entry")" "$directory_entry"
expect_store_refusal 'a directory at a digest position was ignored' 'store: NOT_REGULAR'
rmdir "$directory_entry"

# A partial inventory is not a verified store. In particular, find failure
# must not disappear behind sort/wc and report a false-green zero-entry shard.
unreadable_shard=$(dirname -- "$(store_entry_for "$digest_b")")
chmod 000 "$unreadable_shard"
if store verify >"$WORK/store.unreadable" 2>&1; then
    chmod 755 "$unreadable_shard"
    fail 'verify reported success after failing to enumerate a shard'
fi
chmod 755 "$unreadable_shard"
grep -Fq 'could not enumerate every object' "$WORK/store.unreadable" ||
    fail 'an unreadable shard was refused without naming incomplete enumeration'

store verify >"$WORK/store.final" 2>&1 ||
    fail "the store did not verify after the damage was undone: $(cat "$WORK/store.final")"

sh "$ROOT/tests/pm/lock-v2.sh"
sh "$ROOT/tests/pm/catalog-v1.sh"
sh "$ROOT/tests/pm/metadata-v1.sh"
sh "$ROOT/tests/pm/rough-graph-v2.sh"

printf 'pm: an entry is named by its content, so the same bytes are one entry: PASS\n'
printf 'pm: dependencies are links into the store, with a copy when the filesystem refuses: PASS\n'
printf 'pm: corruption names the entry, the expected digest, and the actual one: PASS\n'
printf 'pm: admission verifies descriptors; one concurrent publisher wins without overwrite: PASS\n'
printf 'pm: reference and C11 agree; bytes hold under hostile TZ, locale, env -i: PASS\n'
printf 'pm: the static fetch contract pins metadata; only fetch has network authority: PASS\n'
