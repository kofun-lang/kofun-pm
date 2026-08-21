#!/bin/sh
set -eu

# The content-addressed store.
#
#   scripts/store.sh --store /abs/path path DIGEST
#   scripts/store.sh --store /abs/path add FILE
#   scripts/store.sh --store /abs/path admit DIGEST SIZE FILE
#   scripts/store.sh --store /abs/path link DIGEST DEST
#   scripts/store.sh --store /abs/path snapshot DIGEST SIZE DEST
#   scripts/store.sh --store /abs/path verify
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

fail() {
    printf 'store: %s\n' "$*" >&2
    exit 1
}

# The store location is an explicit input, not a discovery. In particular,
# HOME and XDG_CACHE_HOME are not authority to mutate a directory. The future
# CLI carries this as --store, and the shell adapter deliberately has no
# environment or home-directory fallback.
test "${1:-}" = --store ||
    fail 'usage: scripts/store.sh --store ABSOLUTE_STORE COMMAND ...'
STORE=${2:-}
test -n "$STORE" || fail '--store requires an absolute path'
case $STORE in
    /*) ;;
    *) fail "--store must be an absolute path: $STORE" ;;
esac
test "$STORE" != / || fail '--store refuses the filesystem root'
case $STORE in
    */) fail "--store must not end in '/': $STORE" ;;
esac
STORE=$(realpath -m -- "$STORE") ||
    fail "could not resolve the store mutation boundary: $STORE"
test "$STORE" != / || fail '--store refuses the filesystem root'
shift 2

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum <"$1" | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 <"$1" | cut -d' ' -f1
    else
        fail 'no sha256sum or shasum available'
    fi
}

size_of() {
    size_input=$1
    # GNU stat reserves the exact operand '-' for stdin even after '--'. A
    # caller-supplied regular file named '-' must remain the cwd pathname.
    test "$size_input" != - || size_input=./-
    if stat -c %s -- "$size_input" >/dev/null 2>&1; then
        stat -c %s -- "$size_input"
    elif stat -f %z -- "$size_input" >/dev/null 2>&1; then
        stat -f %z -- "$size_input"
    else
        wc -c <"$size_input" | tr -d ' '
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

is_size() {
    case $1 in
        *[!0-9]* | '') return 1 ;;
        0) return 0 ;;
        0*) return 1 ;;
        *) return 0 ;;
    esac
}

is_at_most() {
    value=$1
    maximum=$2
    test "${#value}" -lt "${#maximum}" ||
        { test "${#value}" -eq "${#maximum}" && test "$value" -le "$maximum"; }
}

tmp=
tmp_dir=
cleanup() {
    if test -n "$tmp"; then
        rm -f "$tmp"
        tmp=
    fi
    if test -n "$tmp_dir"; then
        rmdir "$tmp_dir" 2>/dev/null || :
        tmp_dir=
    fi
}
trap cleanup 0
trap 'cleanup; exit 1' 1 2 15

check_entry_shape_and_size() {
    expected=$1
    entry=$2
    expected_entry_size=${3:-}

    if test -L "$entry" || ! test -f "$entry"; then
        fail "entry is not a regular file: $entry
  expected $expected
  recovery remove the object, then explicitly admit verified bytes again"
    fi

    actual_entry_size=$(size_of "$entry")
    if test -n "$expected_entry_size" &&
        test "$actual_entry_size" != "$expected_entry_size"
    then
        printf 'store: CORRUPT %s\n' "$entry" >&2
        printf '  expected-size %s\n' "$expected_entry_size" >&2
        printf '  actual-size   %s\n' "$actual_entry_size" >&2
        printf '  expected %s\n' "$expected" >&2
        printf '  actual   not computed; size mismatch is refused before hashing\n' >&2
        printf '  recovery remove the entry, then explicitly admit verified bytes again\n' >&2
        exit 1
    fi

    if test -w "$entry"; then
        fail "WRITABLE $entry
  expected $expected
  a shared writable inode can change after verification"
    fi
}

# Rehash at every ordinary use. A digest-shaped path, existence, and mode are
# not proof that the bytes still match. Symlinks and other non-regular objects
# are never store entries because following one would move verification
# outside the content-addressed namespace.
check_entry() {
    expected=$1
    entry=$2
    expected_entry_size=${3:-}

    check_entry_shape_and_size "$expected" "$entry" "$expected_entry_size"

    actual=$(sha256_of "$entry")
    if test "$actual" != "$expected"; then
        printf 'store: CORRUPT %s\n' "$entry" >&2
        if test -n "$expected_entry_size"; then
            printf '  expected-size %s\n' "$expected_entry_size" >&2
            printf '  actual-size   %s\n' "$actual_entry_size" >&2
        fi
        printf '  expected %s\n' "$expected" >&2
        printf '  actual   %s\n' "$actual" >&2
        printf '  recovery remove the entry, then explicitly admit verified bytes again\n' >&2
        exit 1
    fi
}

copy_candidate() {
    input=$1
    expected=$2
    expected_size=$3
    test -f "$input" || fail "no such regular input file: $input"
    input_size=$(size_of "$input")
    test "$input_size" = "$expected_size" ||
        fail "input size does not match its descriptor
  expected $expected_size
  actual   $input_size"
    candidate_target=$(path_of "$expected")
    mkdir -p "$(dirname -- "$candidate_target")"
    tmp=$(mktemp "$candidate_target.incoming.XXXXXX") ||
        fail "could not create a unique temporary beside $candidate_target"
    # Do not write beyond an untrusted declared bound. The shell adapter is a
    # Linux gate; the native transport will enforce the same limit while
    # reading its byte stream rather than after filling a temporary.
    head -c "$expected_size" <"$input" >"$tmp" ||
        fail "could not copy bounded candidate bytes from $input"
    input_size=$(size_of "$input")
    test "$input_size" = "$expected_size" ||
        fail "input changed size while its candidate was copied
  expected $expected_size
  actual   $input_size"
}

# The candidate already lives on the store filesystem. Verify its declared
# descriptor, then publish with hard-link create-if-absent semantics: link(2)
# creates the final name atomically and refuses EEXIST without replacing the
# winner. Plain mv/rename is intentionally absent from this path.
publish_candidate() {
    expected=$1
    expected_size=$2

    actual_size=$(size_of "$tmp")
    test "$actual_size" = "$expected_size" ||
        fail "candidate size does not match its descriptor
  expected $expected_size
  actual   $actual_size"
    actual=$(sha256_of "$tmp")
    test "$actual" = "$expected" ||
        fail "candidate digest does not match its descriptor
  expected $expected
  actual   $actual"

    target=$(path_of "$expected")
    mkdir -p "$(dirname -- "$target")"
    chmod 444 "$tmp"

    if test -e "$target" || test -L "$target"; then
        check_entry "$expected" "$target" "$expected_size"
        printf 'store: adopted verified winner %s\n' "$expected" >&2
        cleanup
        return
    fi

    # -T is essential: without it, a directory or directory symlink installed
    # at the final name during this race makes ln create a nested name instead
    # of applying link(2) to the exact final name.
    if ln -T -- "$tmp" "$target" 2>/dev/null; then
        # Rehash the final name too. This is deliberately more than trusting
        # that link(2) named the inode we supplied.
        check_entry "$expected" "$target" "$expected_size"
        printf 'store: published %s with create-if-absent\n' "$expected" >&2
        cleanup
        return
    fi

    # EEXIST is the normal concurrent-loser path. Any other failure while the
    # target is still absent means this filesystem cannot provide the required
    # primitive; never fall back to an overwriting rename.
    if test -e "$target" || test -L "$target"; then
        check_entry "$expected" "$target" "$expected_size"
        printf 'store: adopted concurrent winner %s\n' "$expected" >&2
        cleanup
        return
    fi
    fail "atomic create-if-absent publication is unavailable for $target"
}

case "${1:-}" in
    path)
        test "$#" -eq 2 || fail 'usage: scripts/store.sh path DIGEST'
        digest=${2:-}
        is_digest "$digest" || fail "not a sha256 digest: ${digest:-<empty>}"
        entry=$(path_of "$digest")
        check_entry "$digest" "$entry"
        printf '%s\n' "$entry"
        ;;

    add)
        test "$#" -eq 2 || fail 'usage: scripts/store.sh add FILE'
        file=${2:-}
        test -n "$file" || fail 'usage: scripts/store.sh add FILE'
        test -f "$file" || fail "no such regular input file: $file"
        digest=$(sha256_of "$file")
        bytes=$(size_of "$file")
        copy_candidate "$file" "$digest" "$bytes"
        publish_candidate "$digest" "$bytes"
        printf '%s\n' "$digest"
        ;;

    admit)
        test "$#" -eq 4 || fail 'usage: scripts/store.sh admit DIGEST SIZE FILE'
        digest=${2:-}
        bytes=${3:-}
        file=${4:-}
        is_digest "$digest" || fail "not a sha256 digest: ${digest:-<empty>}"
        is_size "$bytes" || fail "not a canonical byte size: ${bytes:-<empty>}"
        test -n "$file" || fail 'usage: scripts/store.sh admit DIGEST SIZE FILE'
        copy_candidate "$file" "$digest" "$bytes"
        publish_candidate "$digest" "$bytes"
        printf '%s\n' "$digest"
        ;;

    link)
        test "$#" -eq 3 || fail 'usage: scripts/store.sh link DIGEST DEST'
        digest=${2:-}
        dest=${3:-}
        is_digest "$digest" || fail "not a sha256 digest: ${digest:-<empty>}"
        test -n "$dest" || fail 'usage: scripts/store.sh link DIGEST DEST'
        source=$(path_of "$digest")
        check_entry "$digest" "$source"
        test ! -d "$dest" || fail "materialization destination is a directory: $dest"

        mkdir -p "$(dirname -- "$dest")"
        tmp_dir=$(mktemp -d "$(dirname -- "$dest")/.kpm-incoming.XXXXXX") ||
            fail "could not create a private materialization directory beside $dest"
        tmp=$tmp_dir/artifact

        # A hard link costs nothing and shares the bytes. It is refused across
        # filesystems, and on filesystems that do not have hard links at all —
        # so the copy is a real path, not a defensive one, and a store that
        # only worked on one filesystem would be a store nobody could put on a
        # separate volume.
        #
        # KPM_NO_HARDLINK forces the fallback, because a fallback that is never
        # exercised is a fallback nobody knows is broken.
        if test "${KPM_NO_HARDLINK:-0}" != 1
        then
            if ln -T -- "$source" "$tmp" 2>/dev/null; then
                materialization=linked
            else
                cat "$source" >"$tmp"
                materialization=copied
            fi
        else
            cat "$source" >"$tmp"
            materialization=copied
        fi

        chmod 444 "$tmp"
        materialized_digest=$(sha256_of "$tmp")
        test "$materialized_digest" = "$digest" ||
            fail "materialized bytes changed before handoff
  expected $digest
  actual   $materialized_digest"
        # As with publication, a directory at the destination must not make
        # the tool write a nested name. The private 0700 directory also means
        # link failure never opens a reusable public pathname for the copy.
        mv -fT -- "$tmp" "$dest"
        tmp=
        rmdir "$tmp_dir"
        tmp_dir=
        final_digest=$(sha256_of "$dest")
        test "$final_digest" = "$digest" ||
            fail "materialized destination changed before handoff
  expected $digest
  actual   $final_digest"
        test ! -w "$dest" || fail "materialized destination is writable: $dest"

        if test "$materialization" = linked; then
            printf 'store: linked and rehashed %s\n' "$dest"
        else
            printf 'store: copied and rehashed %s (the filesystem refused a link)\n' "$dest"
        fi
        ;;

    snapshot)
        test "$#" -eq 4 ||
            fail 'usage: scripts/store.sh snapshot DIGEST SIZE DEST'
        digest=${2:-}
        bytes=${3:-}
        dest=${4:-}
        is_digest "$digest" || fail "not a sha256 digest: ${digest:-<empty>}"
        is_size "$bytes" || fail "not a canonical byte size: ${bytes:-<empty>}"
        is_at_most "$bytes" 67108864 ||
            fail "snapshot exceeds the 67108864-byte file-blob bound: $bytes"
        test -n "$dest" || fail 'usage: scripts/store.sh snapshot DIGEST SIZE DEST'
        source=$(path_of "$digest")

        # Size is the I/O authority. Refuse an oversized digest-shaped object
        # before hashing or copying it; then hash the bounded private copy
        # rather than consuming the source pathname without an I/O cap.
        check_entry_shape_and_size "$digest" "$source" "$bytes"
        test ! -d "$dest" || fail "snapshot destination is a directory: $dest"
        mkdir -p "$(dirname -- "$dest")"
        tmp_dir=$(mktemp -d "$(dirname -- "$dest")/.kpm-incoming.XXXXXX") ||
            fail "could not create a private snapshot directory beside $dest"
        tmp=$tmp_dir/artifact
        head -c "$((bytes + 1))" <"$source" >"$tmp" ||
            fail "could not copy the bounded store snapshot: $digest"
        snapshot_size=$(size_of "$tmp")
        test "$snapshot_size" = "$bytes" ||
            fail "store entry changed size while snapshotting
  expected $bytes
  actual   $snapshot_size"
        chmod 444 "$tmp"
        snapshot_digest=$(sha256_of "$tmp")
        test "$snapshot_digest" = "$digest" ||
            fail "store entry changed while snapshotting: $source
  expected $digest
  actual   $snapshot_digest
  recovery remove the entry, then explicitly admit verified bytes again"
        mv -fT -- "$tmp" "$dest"
        tmp=
        rmdir "$tmp_dir"
        tmp_dir=
        final_size=$(size_of "$dest")
        test "$final_size" = "$bytes" ||
            fail "snapshot destination changed size at handoff
  expected $bytes
  actual   $final_size"
        final_digest=$(sha256_of "$dest")
        test "$final_digest" = "$digest" ||
            fail "snapshot destination changed at handoff
  expected $digest
  actual   $final_digest"
        test ! -w "$dest" || fail "snapshot destination is writable: $dest"
        printf 'store: snapshotted and rehashed %s\n' "$dest"
        ;;

    verify)
        test "$#" -eq 1 || fail 'usage: scripts/store.sh verify'
        test -d "$STORE" || fail "no store at $STORE"
        work=$(mktemp -d "${TMPDIR:-/tmp}/kpm-verify.XXXXXX")
        trap 'rm -rf "$work"' 0 1 2 15

        entries=0
        bad=0

        # Every entry, in a stable order, so two runs of `verify` produce the
        # same report and a difference between them means the store changed.
        find "$STORE" ! -path "$STORE" \
            \( ! -type d -o \
            ! -path "$STORE/[0123456789abcdef][0123456789abcdef]" \) \
            ! -name '*.incoming.*' >"$work/entries.unsorted" ||
            fail "could not enumerate every object under $STORE"
        LC_ALL=C sort <"$work/entries.unsorted" >"$work/entries"

        while IFS= read -r entry; do
            entries=$((entries + 1))
            if test -L "$entry" || ! test -f "$entry"; then
                printf 'store: NOT_REGULAR %s\n' "$entry" >&2
                printf '  store entries cannot be symlinks or special files\n' >&2
                bad=$((bad + 1))
                continue
            fi
            # The name the path claims, reassembled from the two levels.
            claimed=$(printf '%s' "${entry#"$STORE"/}" | tr -d '/')
            if ! is_digest "$claimed" ||
                test "$(path_of "$claimed")" != "$entry"
            then
                printf 'store: MALFORMED %s\n' "$entry" >&2
                printf '  an entry path must be the exact two-level sha256 layout\n' >&2
                bad=$((bad + 1))
                continue
            fi
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
        find "$STORE" ! -path "$STORE" -name '*.incoming.*' \
            >"$work/incoming" ||
            fail "could not enumerate interrupted writes under $STORE"
        incoming=$(wc -l <"$work/incoming" | tr -d ' ')
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
