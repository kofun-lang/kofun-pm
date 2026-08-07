#!/bin/sh
set -eu

# The content-addressed store.
#
#   scripts/store.sh path DIGEST        where that digest lives
#   scripts/store.sh add FILE           place it, print its digest
#   scripts/store.sh link DIGEST DEST   put it in a project, without copying
#   scripts/store.sh verify             every entry still hashes to its name
#
# pnpm's insight: a package version is immutable, so its bytes are its name.
# An entry's path is derived from its digest and from nothing else — no package
# name, no version, no registry — which is what makes two packages with
# identical bytes one entry rather than two, and what makes "is this the
# artifact the lock promised" answerable without a network.
#
# The store is global state, and that is the cost this lane owes. A directory
# shared by every project on a machine is one place where a mistake is not
# confined to the project that made it. Two things follow, and both are here
# rather than in a document:
#
#   Entries are read-only. A hard link is the same inode, so a writable entry
#   is a file any project can edit *in place* — corrupting the dependency for
#   every other project on the machine, silently, with no copy to compare
#   against. Read-only is not tidiness; it is the difference between a shared
#   store and a shared liability.
#
#   `verify` is a gate rather than a subcommand. A store whose integrity is
#   only checked when someone remembers is a store whose integrity is unknown.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

# The store location is an input, not a discovery. A tool that picks a
# directory by looking around is a tool that uses a different one under cron.
STORE=${KPM_STORE:-"${XDG_CACHE_HOME:-$HOME/.cache}/kofun/store"}

fail() {
    printf 'store: %s\n' "$*" >&2
    exit 1
}

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum <"$1" | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 <"$1" | cut -d' ' -f1
    else
        fail 'no sha256sum or shasum available'
    fi
}

is_digest() {
    case $1 in
        *[!0-9a-f]* | '') return 1 ;;
    esac
    test "${#1}" -eq 64
}

# Two levels, split at two characters, the way git shards its objects. The
# split is part of the layout rather than a preference: a single directory
# holding every artifact a machine has ever fetched is slow to read on most
# filesystems and unpleasant to look at on all of them.
#
# Nothing but the digest goes into this path. A name or a version in it would
# make the same bytes two entries, and would make the store's own integrity
# depend on metadata the bytes do not carry.
path_of() {
    printf '%s/%s/%s\n' "$STORE" "$(printf '%s' "$1" | cut -c1-2)" \
        "$(printf '%s' "$1" | cut -c3-)"
}

case "${1:-}" in
    path)
        digest=${2:-}
        is_digest "$digest" || fail "not a sha256 digest: ${digest:-<empty>}"
        path_of "$digest"
        ;;

    add)
        file=${2:-}
        test -n "$file" || fail 'usage: scripts/store.sh add FILE'
        test -f "$file" || fail "no such file: $file"

        digest=$(sha256_of "$file")
        target=$(path_of "$digest")

        if test -e "$target"; then
            # Already present, and its name is its content, so there is
            # nothing to compare and nothing to overwrite. Re-adding the same
            # bytes is not an update — it is a no-op, and that is the whole
            # reason ten projects share one copy.
            printf '%s\n' "$digest"
            exit 0
        fi

        mkdir -p "$(dirname -- "$target")"
        # Write beside the target and move into place, so a store entry never
        # exists half-written under its final name. A reader that found one
        # would have no way to tell it from corruption.
        tmp="$target.incoming.$$"
        cat "$file" >"$tmp"
        chmod 444 "$tmp"
        mv "$tmp" "$target"
        printf '%s\n' "$digest"
        ;;

    link)
        digest=${2:-}
        dest=${3:-}
        is_digest "$digest" || fail "not a sha256 digest: ${digest:-<empty>}"
        test -n "$dest" || fail 'usage: scripts/store.sh link DIGEST DEST'
        source=$(path_of "$digest")
        test -f "$source" || fail "not in the store: $digest"

        mkdir -p "$(dirname -- "$dest")"
        rm -f "$dest"

        # A hard link costs nothing and shares the bytes. It is refused across
        # filesystems, and on filesystems that do not have hard links at all —
        # so the copy is a real path, not a defensive one, and a store that
        # only worked on one filesystem would be a store nobody could put on a
        # separate volume.
        #
        # KPM_NO_HARDLINK forces the fallback, because a fallback that is never
        # exercised is a fallback nobody knows is broken.
        if test "${KPM_NO_HARDLINK:-0}" != 1 && ln "$source" "$dest" 2>/dev/null
        then
            printf 'store: linked %s\n' "$dest"
        else
            cp "$source" "$dest"
            # The copy is read-only for the same reason the entry is, even
            # though it is no longer shared: a project that can edit its
            # dependency in place is a project whose lock stops describing it.
            chmod 444 "$dest"
            printf 'store: copied %s (the filesystem refused a link)\n' "$dest"
        fi
        ;;

    verify)
        test -d "$STORE" || fail "no store at $STORE"
        work=$(mktemp -d "${TMPDIR:-/tmp}/kpm-verify.XXXXXX")
        trap 'rm -rf "$work"' 0 1 2 15

        entries=0
        bad=0

        # Every entry, in a stable order, so two runs of `verify` produce the
        # same report and a difference between them means the store changed.
        find "$STORE" -type f ! -name '*.incoming.*' | LC_ALL=C sort >"$work/entries"

        while IFS= read -r entry; do
            entries=$((entries + 1))
            # The name the path claims, reassembled from the two levels.
            claimed=$(printf '%s' "${entry#"$STORE"/}" | tr -d '/')
            actual=$(sha256_of "$entry")
            if test "$claimed" != "$actual"; then
                # Named, not counted. "The store is corrupt" tells an operator
                # to delete all of it; this tells them which artifact to fetch
                # again.
                printf 'store: CORRUPT %s\n' "$entry" >&2
                printf '  expected %s\n' "$claimed" >&2
                printf '  actual   %s\n' "$actual" >&2
                bad=$((bad + 1))
                continue
            fi
            if test -w "$entry"; then
                # Not corruption yet, and the condition under which corruption
                # becomes possible without anyone doing anything wrong.
                printf 'store: WRITABLE %s\n' "$entry" >&2
                printf '  a hard link into a project shares this inode, so a\n' >&2
                printf '  writable entry can be edited in place for every\n' >&2
                printf '  project on this machine\n' >&2
                bad=$((bad + 1))
            fi
        done <"$work/entries"

        # A leftover half-written file is not corruption of an entry — nothing
        # claims it — but it is evidence a write was interrupted, and a store
        # that quietly accumulates them is one nobody is watching.
        incoming=$(find "$STORE" -type f -name '*.incoming.*' | wc -l | tr -d ' ')
        if test "$incoming" -ne 0; then
            printf 'store: %s interrupted write(s) left behind\n' "$incoming" >&2
            bad=$((bad + 1))
        fi

        test "$bad" -eq 0 ||
            fail "$bad of $entries entries did not verify"
        printf 'store: %s entries, each hashing to its own name\n' "$entries"
        ;;

    *)
        sed -n '5,9p' "$0" | sed 's/^# \{0,1\}//'
        exit 2
        ;;
esac
