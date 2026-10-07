#!/bin/sh
# fork-sandbox-k8s-context-extract.sh -- safely extract a --context-ro
# directory pushed into a pod, invoked by fork-sandbox-k8s.sh's `submit`
# verb over `kubectl exec -i`, with the tar stream on stdin.
#
# Usage: fork-sandbox-k8s-context-extract.sh DEST_DIR MAX_BYTES [CALLER]   (tar on stdin)
#
# Untarring a stream from an untrusted client onto the pod's filesystem is a
# path-traversal sink, exactly like fork-sandbox-k8s-outbox-extract.sh's own
# pull-back in the other direction -- kubectl cp is itself tar-over-exec and
# has had CVEs of exactly this shape. A confused caller (a --context-ro
# directory containing a symlink out of itself, say) can emit entries with
# absolute paths, `..` components, or symlinks pointing anywhere the pod can
# reach, and the whole containment story of this project would leak out
# through this one convenience if it were done naively. So, in order:
#
#   1. Spool stdin to a temp file capped at one byte over the size limit
#      (`head -c $((max_bytes + 1))`), and refuse if the spooled file is
#      over the cap -- rather than buffering the whole stream, however
#      large, before anything checks it. /tmp is an emptyDir with no
#      sizeLimit of its own, so nothing else bounds this spool.
#   2. List every entry (`tar -tvf`) BEFORE extracting anything, and reject
#      the whole archive -- no partial extraction -- if any entry is an
#      absolute path, contains a `..` path component, or is anything other
#      than a regular file or a directory (a symlink or hard link of any
#      kind, a FIFO, a device node, or a socket).
#   3. Only then extract, into a freshly created directory (or an
#      existing, EMPTY one -- an emptyDir volume the pod spec already
#      mounted there, for a --thread-dir/--attach-dir push), stripping
#      ownership and permission bits from the archive.
#
# Someone will later think step 2 is redundant with tar's own
# extraction-time protections, since most tar implementations already
# refuse an absolute path or a leading `..` as they extract. It is not
# redundant: a symlink entry extracted first, followed by a second entry
# that writes through it via an innocent-looking relative path, is a
# classic and still-current escape -- the underlying shape of the kubectl
# cp CVEs -- and it defeats those per-entry checks because neither
# individual entry looks unsafe on its own. Listing and rejecting symlinks
# up front closes that regardless of what the extracting tar binary does.
#
# This is the one implementation of that guard: fork-sandbox-k8s-outbox-extract.sh
# is a thin bash wrapper around this script, adapting its own TAR_FILE
# argument and 64 MiB default cap onto this script's DEST_DIR/MAX_BYTES
# interface, rather than keeping a second copy of the guard in sync by
# hand. This script itself is normally fed the tar directly on stdin -- it
# is what `kubectl exec -i POD -- sh .../context-extract.sh DEST MAX_BYTES`
# runs with `submit`'s spooled tar piped in, so the byte-cap check below
# spools stdin to a temp file first by default, since a pipe cannot be
# `stat`ed in place; a caller that already has the tar as a file on disk,
# like outbox-extract.sh, sets FS_EXTRACT_INPUT_FILE to skip that copy
# instead.
#
# Written as a standalone POSIX sh script, not bash: like
# fork-sandbox-k8s-inbox-write.sh, this runs inside the pod's image, mounted
# from the per-run scripts ConfigMap, not on the host where GNU bash is
# already required. It can also be driven directly by a test, against a
# fixture tarball on stdin, with no cluster and no kubectl involved.
#
# MAX_BYTES is a threaded value, not this script's only cap on the
# --context-ro path: this script also holds a 256 MiB literal of its own,
# and MAX_BYTES can only lower the effective cap below that, never raise it
# past it. That literal is a guardrail against a mistaken MAX_BYTES
# argument, not a boundary against a hostile caller -- a party able to
# choose what this script is invoked with, over kubectl exec or otherwise,
# already has the run of the pod and does not need to talk this script into
# a bigger number. So the choice of literal is keyed on CALLER (the third
# argument, defaulting to "context"), a fixed table lives in this script,
# and CALLER is always passed on argv, never read from the environment --
# an inherited environment variable can carry a stray value into an
# invocation nobody meant it for, and argv cannot.
#
#   context (default) -- fork-sandbox-k8s.sh's --context-ro, --thread-dir
#     and --attach-dir pushes, over the kubectl-exec/stdin channel: 256 MiB,
#     matching its own CONTEXT_MAX_BYTES. --thread-dir/--attach-dir reuse
#     this literal CALLER rather than adding their own arms -- the ceiling
#     is identical either way, so a new arm would be pure duplication.
#   outbox -- fork-sandbox-k8s-outbox-extract.sh's own wrapper, which runs
#     entirely on the host against a tar already on disk (FS_EXTRACT_INPUT_FILE):
#     no ceiling, since --outbox-max is documented as having none.

set -eu

dest_dir="${1:?usage: fork-sandbox-k8s-context-extract.sh DEST_DIR MAX_BYTES [CALLER]}"
max_bytes="${2:?usage: fork-sandbox-k8s-context-extract.sh DEST_DIR MAX_BYTES [CALLER]}"
caller="${3:-context}"

label="${FS_EXTRACT_LABEL:-context-extract}"

case "$caller" in
    context)
        literal_max_bytes=$((256 * 1024 * 1024))
        if [ "$max_bytes" -gt "$literal_max_bytes" ]; then
            max_bytes="$literal_max_bytes"
        fi
        ;;
    outbox)
        # No literal -- MAX_BYTES (outbox-extract.sh's own --outbox-max) is
        # the whole cap.
        ;;
    *)
        echo "$label: internal error: unknown caller '$caller'." >&2
        exit 1
        ;;
esac

tvf_out="$(mktemp)"
tf_out="$(mktemp)"
if [ -n "${FS_EXTRACT_INPUT_FILE:-}" ]; then
    # Already a file on disk (fork-sandbox-k8s-outbox-extract.sh's TAR_FILE,
    # itself already spooled under a byte cap by cmd_run) -- stat it in
    # place rather than paying for a second temp-file copy of bytes we
    # already have.
    tar_file="$FS_EXTRACT_INPUT_FILE"
    trap 'rm -f "$tvf_out" "$tf_out"' EXIT
else
    tar_file="$(mktemp)"
    trap 'rm -f "$tar_file" "$tvf_out" "$tf_out"' EXIT
    head -c "$((max_bytes + 1))" > "$tar_file"
fi

size="$(stat -c '%s' -- "$tar_file")"
if [ "$size" -gt "$max_bytes" ]; then
    if [ -n "${FS_EXTRACT_INPUT_FILE:-}" ]; then
        echo "$label: $size bytes, over $max_bytes byte cap; refusing it." >&2
    else
        # The spool above stopped at max_bytes + 1, so $size on this path is
        # always exactly that -- never the stream's real size. Quoting it
        # would tell an operator they are one byte over the cap when they
        # could be gigabytes over.
        echo "$label: stream exceeded the $max_bytes byte cap; refusing it." >&2
    fi
    exit 1
fi

# List before extracting anything. Entries from a well-formed
# `tar cf - -C CONTEXT_DIR .` look like `./`, `./foo.txt`, `./sub/bar.txt`
# -- relative, with a leading `./`, no `..` component -- so those are the
# only shapes let through below.
#
# Two passes over the archive, deliberately, because the two questions want
# different output formats and mixing them is how this check gets silently
# defeated. Both listings are spooled to a temp file rather than piped into
# a `while read` loop directly: POSIX sh has no `< <(...)` process
# substitution, and the last stage of an ordinary pipe is not guaranteed to
# run in the current shell, which would make an `exit` inside the loop
# unreliable.
#
# Link detection needs `tar -tvf`, whose first column carries the type bit
# and whose hard-link entries append " link to TARGET". But `-tvf` is
# COLUMNAR, and a path is not a column: a member named `../../pwned x.txt`
# puts `x.txt` in the last field, so picking the last whitespace-separated
# field passes a traversal path straight through this guard. Any filename
# containing a space defeats it, and gathered-context files with spaces in
# their names are entirely ordinary.
#
# So paths are read from `tar -tf` instead, which prints one member name
# per line and nothing else. (A name containing a literal newline would
# still be ambiguous, but GNU tar escapes control characters in listings,
# so it cannot smuggle a line break through here.)
#
# Allowlisted by type, not blocklisted: only a regular file (`-`) or a
# directory (`d`) passes. Everything else is refused, including shapes a
# blocklist would miss -- a FIFO (`p`) extracted into the run dir and then
# read by a host-side tool with no timeout (`cp -rn` recreates it, and the
# first read blocks forever) is exactly as dangerous as the symlink/hard
# link case this already caught, and a device node or socket entry has no
# legitimate reason to be in a pushed directory either.
tar -tvf "$tar_file" > "$tvf_out"

# The listing is capped by entry COUNT before anything else walks it: a
# many-small-files archive (zero-byte members cost nothing to store, so a
# confused or adversarial pod can pack in as many as it likes) costs real
# wall-clock time to process even when every per-entry check below passes
# -- in the type/path loops here, and in whatever copies the result
# afterward. A plain `wc -l`, once, is the one fork this guard costs
# regardless of archive shape.
tvf_lines="$(wc -l < "$tvf_out")"
max_entries="${FS_EXTRACT_MAX_ENTRIES:-20000}"
if [ "$tvf_lines" -gt "$max_entries" ]; then
    echo "$label: $tvf_lines entries, over the $max_entries entry cap;" >&2
    echo "refusing the whole archive." >&2
    exit 1
fi

# A sparse member defeats the byte-cap check above entirely: GNU tar
# stores a sparse file's holes compactly, so a ~10 KB archive holding one
# multi-TiB sparse member still spools under any reasonable MAX_BYTES, and
# `tar -tvf` lists it with an ordinary `-` (regular file) type bit -- it
# passes the type allowlist below like any other file. Extraction then
# recreates the hole-and-data layout at its full logical size (sparse
# detection on extract is automatic; this script's own `tar -xf` needs no
# flag for it), landing a file whose APPARENT size is whatever the pod
# claimed, on a destination filesystem that may well honour it as a real
# sparse file -- and a host reader that later does an unbounded read of
# that file (a bare `cat`, a `head -n 1` that has to scan to the first
# newline, `read_env_value`'s own line scan) then blocks for as long as it
# takes to walk that many bytes, which for a claimed multi-TiB size is
# effectively forever. `tar -tvf`'s size column (the third
# whitespace-separated field: mode, owner/group, size, date, time, name --
# stable regardless of spaces in the name, which only ever appear after
# the fifth field) carries the member's real, undecimated logical size
# regardless of how compactly the archive stores it (verified against GNU
# tar directly: a 10 KB `--sparse` archive of a 1 TiB hole still lists
# that member at 1099511627776), so summing it across every entry and
# refusing the whole archive over MAX_BYTES closes this before a single
# byte is extracted -- the same "list before extract" discipline the
# link/path checks below already apply, extended to size.
# awk compares and formats the sum itself: some awks print a large sum as
# 1.09951e+12, which a shell `-gt` rejects, and the cap would then be
# silently skipped.
total_size="$(awk '{ sum += $3 } END { printf "%.0f", sum }' "$tvf_out")"
if awk -v max="$max_bytes" '{ sum += $3 } END { exit !(sum > max) }' "$tvf_out"; then
    echo "$label: entries declare $total_size bytes total (not the archive's" >&2
    echo "own size), over the $max_bytes byte cap; refusing the whole archive." >&2
    exit 1
fi

while IFS= read -r line; do
    case "$line" in
        -*|d*)
            ;;
        l*|h*)
            echo "$label: contains a link entry; refusing the whole archive." >&2
            exit 1
            ;;
        *)
            echo "$label: contains a non-regular-file entry; refusing the whole archive." >&2
            exit 1
            ;;
    esac
done < "$tvf_out"

tar -tf "$tar_file" > "$tf_out"
while IFS= read -r path; do
    case "$path" in
        /*)
            echo "$label: contains an absolute path; refusing the whole archive." >&2
            exit 1
            ;;
        ..|../*|*/..|*/../*)
            echo "$label: contains a '..' path component; refusing archive." >&2
            exit 1
            ;;
    esac
done < "$tf_out"

# Freshly created (mkdir, not mkdir -p), UNLESS DEST_DIR already exists as
# an empty directory -- fork-sandbox-k8s.sh's --thread-dir/--attach-dir
# push targets an emptyDir volume the pod spec already mounted there, so
# DEST_DIR pre-exists on every one of those pushes and mkdir would fail on
# the mount point itself. An existing NON-empty directory is still
# refused: that is still a second push merging into a first, the case
# this check exists for. --context-ro's own destination (POD_CONTEXT_DIR)
# never pre-exists, so this leaves its behaviour unchanged.
if [ -e "$dest_dir" ]; then
    if [ ! -d "$dest_dir" ]; then
        echo "$label: DEST_DIR '$dest_dir' exists and is not a directory; refusing." >&2
        exit 1
    fi
    if [ -n "$(find "$dest_dir" -mindepth 1 -print -quit)" ]; then
        echo "$label: DEST_DIR '$dest_dir' already exists and is not empty; refusing." >&2
        exit 1
    fi
    # The mount point itself is kubelet-created (an emptyDir), owned by
    # root even though fsGroup makes it group-writable -- this process
    # runs as a non-root uid with every capability dropped. GNU tar's
    # default (--overwrite-dir) chmods/utimes the directory that an
    # archive's top-level `./` entry maps onto, and a non-owner with no
    # CAP_FOWNER gets EPERM from that chmod even when the target mode is
    # already what the archive asks for -- setattr_prepare requires
    # ownership or CAP_FOWNER regardless of whether the mode actually
    # changes. --no-overwrite-dir does NOT avoid this: it still restores
    # the directory to a permissive working mode partway through
    # extraction (that restore is unconditional, not gated by the flag),
    # so the EPERM hits regardless and tar's exit status goes nonzero even
    # though every file underneath extracted fine; this script's `set -eu`
    # then reports the whole push as failed. The only fix that actually
    # avoids the chmod/utime call is to never give tar a member that maps
    # onto DEST_DIR in the first place: fork-sandbox-k8s.sh's
    # k8s_spool_dir_entries packs the directory's top-level ENTRIES, not
    # `.` itself, so no member here ever resolves to DEST_DIR and this
    # extractor never attempts to touch its metadata. Only reached on this
    # pre-existing-DEST_DIR branch, so --context-ro's destination (always
    # freshly mkdir'd below, and always packed as `-C DIR .`) is unaffected
    # either way.
else
    mkdir -- "$dest_dir"
fi

# Never as anyone but the invoking user -- no sudo, nothing
# privilege-related; --no-same-owner/--no-same-permissions strip whatever
# the archive itself claims.
tar -xf "$tar_file" -C "$dest_dir" --no-same-owner --no-same-permissions
