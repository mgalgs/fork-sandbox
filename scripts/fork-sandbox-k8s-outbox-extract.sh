#!/usr/bin/env bash
# fork-sandbox-k8s-outbox-extract.sh -- safely extract a pod's artifact
# outbox tarball onto the host, invoked by fork-sandbox-k8s.sh's `run` verb
# after it pulls /work/outbox out of the pod over kubectl exec.
#
# Usage: fork-sandbox-k8s-outbox-extract.sh TAR_FILE DEST_DIR [MAX_BYTES]
#
# Untarring a stream from an untrusted pod onto the host is a path-traversal
# sink -- kubectl cp is itself tar-over-exec and has had CVEs of exactly
# this shape. See fork-sandbox-k8s-context-extract.sh's header for the full
# threat model and the order the guard applies in (bounded spool, then
# list-before-extract rejecting absolute paths / `..` components / links,
# then extract into a freshly created directory). This script no longer
# carries its own copy of that guard: it is a thin wrapper that adapts its
# own interface -- a TAR_FILE argument already on disk rather than a stdin
# stream, and its own 64 MiB default cap with no upper ceiling -- onto that
# one implementation, so the project's one path-traversal boundary exists
# once rather than twice, kept in sync by hand. It passes the shared script
# "outbox" as CALLER (the shared script's own table maps that to no
# literal ceiling, so the 256 MiB meant for --context-ro never becomes a
# hidden ceiling on an outbox that is documented as having none), and hands
# it FS_EXTRACT_INPUT_FILE (so TAR_FILE, which cmd_run already spooled to
# disk under its own cap, is read in place rather than copied again) and
# FS_EXTRACT_LABEL (so a rejection is attributed to this script and names
# TAR_FILE, not to "context-extract").
#
# Written as a standalone, independently-invocable script -- not inlined
# into fork-sandbox-k8s.sh's cmd_run -- so it can be driven directly by a
# test, against a fixture tarball, with no cluster and no kubectl involved.
# Bash, not POSIX sh: unlike fork-sandbox-k8s-context-extract.sh, which also
# runs inside the pod's possibly-minimal image, this script runs only on
# the host, where GNU bash and coreutils are already required (see
# fs_require_gnu_tools).

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

tar_file="${1:?usage: fork-sandbox-k8s-outbox-extract.sh TAR_FILE DEST_DIR [MAX_BYTES]}"
dest_dir="${2:?usage: fork-sandbox-k8s-outbox-extract.sh TAR_FILE DEST_DIR [MAX_BYTES]}"

# 64 MiB by default. An outbox is for screenshots, reports and the like, not
# build artifacts or datasets -- generous enough for that, small enough that
# a confused or hostile pod cannot use it to fill the host's disk. This
# script is deliberately standalone (see the header above) and does not
# source fork-sandbox-lib.sh, so the caller passes its own FS_OUTBOX_MAX_BYTES
# down as $3 rather than the two drifting apart; a bare invocation (as a test
# drives it directly against a fixture tarball) still gets the same default.
max_bytes="${3:-$((64 * 1024 * 1024))}"

FS_EXTRACT_LABEL="fork-sandbox-k8s-outbox-extract: $tar_file" \
FS_EXTRACT_INPUT_FILE="$tar_file" \
    sh "$script_dir/fork-sandbox-k8s-context-extract.sh" "$dest_dir" "$max_bytes" outbox
