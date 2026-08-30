#!/bin/sh
# fork-sandbox-k8s-context-extract.sh -- safely extract a --context-ro
# directory pushed into a pod, invoked by fork-sandbox-k8s.sh's `submit`
# verb over `kubectl exec -i`, with the tar stream on stdin.
#
# Usage: fork-sandbox-k8s-context-extract.sh DEST_DIR MAX_BYTES   (tar on stdin)
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
#      absolute path, contains a `..` path component, or is a symlink or
#      hard link of any kind.
#   3. Only then extract, into a freshly created directory, stripping
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
# Unlike fork-sandbox-k8s-outbox-extract.sh, which takes a tar FILE PATH as
# $1 because it runs on the host after the host has already pulled the
# stream down, this script is fed the tar directly on stdin -- it is what
# `kubectl exec -i POD -- sh .../context-extract.sh DEST MAX_BYTES` runs
# with `submit`'s spooled tar piped in, so the byte-cap check below has to
# spool stdin to a temp file first rather than stat a file it was handed.
#
# Written as a standalone POSIX sh script, not bash: like
# fork-sandbox-k8s-inbox-write.sh, this runs inside the pod's image, mounted
# from the per-run scripts ConfigMap, not on the host where GNU bash is
# already required. It can also be driven directly by a test, against a
# fixture tarball on stdin, with no cluster and no kubectl involved.

set -eu

dest_dir="${1:?usage: fork-sandbox-k8s-context-extract.sh DEST_DIR MAX_BYTES}"
max_bytes="${2:?usage: fork-sandbox-k8s-context-extract.sh DEST_DIR MAX_BYTES}"

tar_file="$(mktemp)"
tvf_out="$(mktemp)"
tf_out="$(mktemp)"
trap 'rm -f "$tar_file" "$tvf_out" "$tf_out"' EXIT

head -c "$((max_bytes + 1))" > "$tar_file"

size="$(stat -c '%s' -- "$tar_file")"
if [ "$size" -gt "$max_bytes" ]; then
    echo "context-extract: $size bytes, over $max_bytes byte cap; refusing it." >&2
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
tar -tvf "$tar_file" > "$tvf_out"
while IFS= read -r line; do
    case "$line" in
        l*|*" link to "*)
            echo "context-extract: contains a link entry; refusing the whole archive." >&2
            exit 1
            ;;
    esac
done < "$tvf_out"

tar -tf "$tar_file" > "$tf_out"
while IFS= read -r path; do
    case "$path" in
        /*)
            echo "context-extract: contains an absolute path; refusing the whole archive." >&2
            exit 1
            ;;
        ..|../*|*/..|*/../*)
            echo "context-extract: contains a '..' path component; refusing archive." >&2
            exit 1
            ;;
    esac
done < "$tf_out"

# Freshly created: mkdir, not mkdir -p, so this fails loudly if dest_dir
# already exists rather than merging a second push into a first.
mkdir -- "$dest_dir"

# Never as anyone but the invoking user -- no sudo, nothing
# privilege-related; --no-same-owner/--no-same-permissions strip whatever
# the archive itself claims.
tar -xf "$tar_file" -C "$dest_dir" --no-same-owner --no-same-permissions
