#!/bin/sh
set -eu

# Write and verify the lock.
#
#   scripts/lock.sh write [FILE]     resolve, and record what was resolved
#   scripts/lock.sh verify FILE      re-resolve, and check the record still holds
#
# `go.sum` pins artifacts. This pins **the resolution** as well — the selected
# version per module, and a digest of the requirement set that produced it.
#
# That is only worth doing because MVS is a function. Re-resolving from the
# same requirements must give the same answer, so `verify` is a check rather
# than a hope: a difference means the requirements changed or the tool did, and
# it can never mean the solver felt different today. A lock over a search could
# not make that claim, which is why locks over searches pin outputs only.
#
# Three failures, and each is a different thing to do about it:
#
#   the file was edited          its own digest no longer covers its body
#   the requirements changed     the lock is stale; re-lock
#   the resolution changed       same requirements, different answer — the
#                                tool changed, and that is a bug report
#
# The third cannot happen while the rule is a maximum. It is checked anyway,
# because "cannot happen" is the state every silent corruption was in first.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

FORMAT=kofun-pm.lock/v1
COLUMNS='module selection value'

fail() {
    printf 'lock: %s\n' "$*" >&2
    exit 1
}

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 | cut -d' ' -f1
    else
        fail 'no sha256sum or shasum available'
    fi
}

tool_version() {
    git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || printf 'unknown'
}

# The requirement set, as the resolver compiled it.
#
# There is no manifest to read yet — the scenario is written in the shell — so
# the requirements are digested from that source with comments stripped, the
# way the language pins its own fixtures. Rewording a comment above a
# requirement must not read as a change to the requirement.
#
# When `kofun.toml` grows a [dependencies] section this becomes a digest of
# that section instead, and nothing else here changes: the point is that the
# lock records *what it resolved from*, not where it was written down.
requirements_digest() {
    sed 's/[[:space:]]*#.*$//' "$ROOT/seed/resolver/shell.kofun" |
        sed -n '/^    let direct: Requirements = requirements_of($/,/^    )$/p;
                /^    let inherited: Requirements = requirements_of($/,/^    )$/p;
                /^    let member_reqs: Requirements = requirements_of($/,/^    )$/p;
                /^    let workspace: Workspace = workspace_of($/,/^    )$/p' |
        sha256
}

# The rows the resolver printed between its markers. Read by name, never by
# offset: a producer keyed to a line number breaks whenever a decision is added
# above it, and a producer that breaks on unrelated changes gets replaced by
# one that guesses.
lock_rows() {
    binary=$(sh "$ROOT/scripts/build-seed.sh" "$ROOT/build/resolver")
    # An empty environment, because a lock written under one environment and
    # verified under another must not be able to differ for that reason.
    env -i "$binary" |
        sed -n '/^-- lock --$/,/^-- end lock --$/p' |
        sed '1d;$d' |
        paste - - -
}

# One row, rendered. A member is recorded as a member and carries no version:
# a lock that pinned a local path would be wrong on every other machine, which
# is the whole reason `Member` is an outcome rather than a `Selected`.
render_rows() {
    awk -F'\t' '
        $2 == 1 { printf "%s\tselected\t%s\n", $1, $3; next }
        $2 == 6 { printf "%s\tworkspace\t-\n", $1; next }
        { printf "lock: module %s did not resolve (outcome %s)\n", $1, $2 > "/dev/stderr"; bad = 1 }
        END { exit bad + 0 }
    '
}

case "${1:-}" in
    write)
        out=${2:-"$ROOT/kofun.lock"}
        work=$(mktemp -d "${TMPDIR:-/tmp}/kofun-pm-lock.XXXXXX")
        trap 'rm -rf "$work"' 0 1 2 15

        lock_rows >"$work/rows" ||
            fail 'the resolver produced no lock block'
        render_rows <"$work/rows" >"$work/body" ||
            fail 'a module in the closure did not resolve; there is nothing to lock'

        # Everything except the digest line, which is what the digest covers.
        {
            printf '# format: %s\n' "$FORMAT"
            printf '# columns: %s\n' "$COLUMNS"
            printf '# tool: %s\n' "$(tool_version)"
            printf '# requirements: %s\n' "$(requirements_digest)"
            cat "$work/body"
        } >"$work/covered"

        {
            cat "$work/covered"
            # Last, and over everything above it, so an edit anywhere in the
            # file is an edit the digest notices — not only an edit to the
            # rows. A lock whose header could be changed silently would let
            # someone move the requirements digest and keep the selection.
            printf '# digest: %s\n' "$(sha256 <"$work/covered")"
        } >"$out"

        printf 'lock: wrote %s rows to %s\n' \
            "$(wc -l <"$work/body" | tr -d ' ')" "$out"
        ;;

    verify)
        lock=${2:-"$ROOT/kofun.lock"}
        test -f "$lock" || fail "no lock at $lock"
        work=$(mktemp -d "${TMPDIR:-/tmp}/kofun-pm-lock.XXXXXX")
        trap 'rm -rf "$work"' 0 1 2 15

        recorded_format=$(sed -n 's/^# format: //p' "$lock" | head -1)
        test "$recorded_format" = "$FORMAT" ||
            fail "lock format is '$recorded_format', this tool speaks '$FORMAT'"

        # 1. The file itself. Checked first, because every other field in it is
        #    only worth reading once the file is known not to have been edited.
        recorded_digest=$(sed -n 's/^# digest: //p' "$lock" | head -1)
        test -n "$recorded_digest" || fail 'the lock carries no digest'
        grep -v '^# digest: ' "$lock" >"$work/covered"
        actual_digest=$(sha256 <"$work/covered")
        test "$recorded_digest" = "$actual_digest" ||
            fail "the lock's own digest does not match its contents;
  header says $recorded_digest
  contents are $actual_digest
  the file has been edited by hand"

        # 2. What it was resolved from. A different requirement set is a stale
        #    lock, which is an ordinary thing that wants re-locking — and a
        #    different thing from the file having been tampered with.
        recorded_requirements=$(sed -n 's/^# requirements: //p' "$lock" | head -1)
        current_requirements=$(requirements_digest)
        test "$recorded_requirements" = "$current_requirements" ||
            fail "the lock was written against a different requirement set;
  lock says    $recorded_requirements
  requirements $current_requirements
  re-lock: scripts/lock.sh write"

        # 3. The resolution itself. Same requirements, so the same answer —
        #    unless the tool changed. Under a solver this check would be noise;
        #    under a maximum it is a bug report.
        lock_rows >"$work/rows" || fail 'the resolver produced no lock block'
        render_rows <"$work/rows" >"$work/body" ||
            fail 'a module in the closure did not resolve'
        grep -v '^#' "$lock" >"$work/recorded"
        if ! cmp -s "$work/recorded" "$work/body"; then
            printf 'lock: FAIL: the same requirements resolved differently\n' >&2
            printf '  columns:  %s\n' "$COLUMNS" >&2
            diff "$work/recorded" "$work/body" |
                sed 's/^/  /' >&2 || true
            printf '  the requirement digest matched, so this is the tool\n' >&2
            printf '  changing its answer — which minimal version selection\n' >&2
            printf '  cannot do while the rule is a maximum. This is a bug.\n' >&2
            exit 1
        fi

        printf 'lock: %s rows verified against the requirements they came from\n' \
            "$(wc -l <"$work/recorded" | tr -d ' ')"
        ;;

    *)
        sed -n '5,8p' "$0" | sed 's/^# \{0,1\}//'
        exit 2
        ;;
esac
