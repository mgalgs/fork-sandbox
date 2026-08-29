#!/usr/bin/env bash
# fork-sandbox-k8s-outbox-extract.sh -- safely extract a pod's artifact
# outbox tarball onto the host, invoked by fork-sandbox-k8s.sh's `run` verb
# after it pulls /work/outbox out of the pod over kubectl exec.
#
# Usage: fork-sandbox-k8s-outbox-extract.sh TAR_FILE DEST_DIR
#
# Untarring a stream from an untrusted pod onto the host is a path-traversal
# sink -- kubectl cp is itself tar-over-exec and has had CVEs of exactly
# this shape. A hostile or simply confused pod can emit entries with
# absolute paths, `..` components, or symlinks pointing anywhere on the
# host, and the whole containment story of this project would leak out
# through this one convenience if it were done naively. So, in order:
#
#   1. Refuse the file outright if it is over a fixed size cap, rather than
#      extracting an unbounded amount of data onto disk.
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
# Written as a standalone, independently-invocable script -- not inlined
# into fork-sandbox-k8s.sh's cmd_run -- so its guards can be driven directly
# by a test, against a fixture tarball, with no cluster and no kubectl
# involved. Bash, not POSIX sh: unlike fork-sandbox-k8s-inbox-write.sh,
# which runs inside the pod's possibly-minimal image, this script runs only
# on the host, where GNU bash and coreutils are already required (see
# fs_require_gnu_tools).

set -euo pipefail

tar_file="${1:?usage: fork-sandbox-k8s-outbox-extract.sh TAR_FILE DEST_DIR}"
dest_dir="${2:?usage: fork-sandbox-k8s-outbox-extract.sh TAR_FILE DEST_DIR}"

# 64 MiB. An outbox is for screenshots, reports and the like, not build
# artifacts or datasets -- generous enough for that, small enough that a
# confused or hostile pod cannot use it to fill the host's disk.
max_bytes=$((64 * 1024 * 1024))

size="$(stat -c '%s' -- "$tar_file")"
if (( size > max_bytes )); then
    echo "fork-sandbox-k8s-outbox-extract: $tar_file is $size bytes, over the $max_bytes byte cap; refusing it." >&2
    exit 1
fi

# List before extracting anything. Entries from a well-formed
# `tar cf - -C /work/outbox .` look like `./`, `./foo.png`, `./sub/bar.txt`
# -- relative, with a leading `./`, no `..` component -- so those are the
# only shapes this loop lets through.
# Two passes over the archive, deliberately, because the two questions want
# different output formats and mixing them is how this check gets silently
# defeated.
#
# Link detection needs `tar -tvf`, whose first column carries the type bit
# and whose hard-link entries append " link to TARGET". But `-tvf` is
# COLUMNAR, and a path is not a column: a member named `../../pwned x.txt`
# puts `x.txt` in the last field, so picking the last whitespace-separated
# field passes a traversal path straight through this guard. Any filename
# containing a space defeats it, and screenshots with spaces in their names
# are entirely ordinary.
#
# So paths are read from `tar -tf` instead, which prints one member name per
# line and nothing else. (A name containing a literal newline would still be
# ambiguous, but GNU tar escapes control characters in listings, so it
# cannot smuggle a line break through here.)
while IFS= read -r line; do
    if [[ "${line:0:1}" == "l" ]] || [[ "$line" == *" link to "* ]]; then
        echo "fork-sandbox-k8s-outbox-extract: $tar_file contains a link entry; refusing the whole archive." >&2
        exit 1
    fi
done < <(tar -tvf "$tar_file")

while IFS= read -r path; do
    case "$path" in
        /*)
            echo "fork-sandbox-k8s-outbox-extract: $tar_file contains an absolute path ('$path'); refusing the whole archive." >&2
            exit 1
            ;;
        ..|../*|*/..|*/../*)
            echo "fork-sandbox-k8s-outbox-extract: $tar_file contains a '..' path component ('$path'); refusing the whole archive." >&2
            exit 1
            ;;
    esac
done < <(tar -tf "$tar_file")

# Freshly created: mkdir, not mkdir -p, so this fails loudly if dest_dir
# already exists rather than extracting into and possibly clobbering
# something that was already there.
mkdir -- "$dest_dir"

# Never as anyone but the invoking user -- no sudo, nothing
# privilege-related; --no-same-owner/--no-same-permissions strip whatever
# the archive itself claims.
tar -xf "$tar_file" -C "$dest_dir" --no-same-owner --no-same-permissions
