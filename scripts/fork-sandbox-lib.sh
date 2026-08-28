#!/usr/bin/env bash
# fork-sandbox-lib.sh — Shared clone and sandbox helpers (sourced library, not a command)
#
# Usage: source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/fork-sandbox-lib.sh"
#
# fork-task.sh --sandboxed and fork-sandbox.sh both run a Claude session in a
# throwaway `git clone --shared` of the user's repo, inside claude-sandboxed.
# The clone, the alternates walk and the argument guard are the same for both,
# and each one is load-bearing for the security design, so they live here
# instead of in two copies that would drift apart.
#
# Every function writes its own error message to stderr and returns non-zero.
# The caller decides whether to exit.

# GNU coreutils, under whatever name this machine has for it.
#
# Everything above the sandbox is bash, and it uses GNU flags that BSD userland
# does not have: `realpath -m` (canonicalize a path whose tail need not exist),
# `realpath -s` (normalize without resolving symlinks), `stat -c` (a format
# string BSD spells with -f, and differently), and `timeout`, which macOS does
# not ship at all. On Linux the GNU tool simply IS `realpath`. Under Homebrew on
# macOS, coreutils installs it as `grealpath` and is keg-only, so the plain name
# still resolves to BSD's.
#
# Resolving the name once, here, lets every call site keep its GNU flags
# instead of growing a second BSD spelling that nobody on Linux would ever
# exercise -- and an unexercised portability branch is a bug waiting for the
# one person who runs it.
#
# The bare name is the last resort, so Linux is unaffected and a macOS box
# without coreutils fails at fs_require_gnu_tools with a sentence rather than
# at a call site with "illegal option -- m".
FS_REALPATH="realpath"
FS_STAT="stat"
FS_TIMEOUT="timeout"

_fs_resolve_gnu_tool() {
    local name="$1" cand out
    for cand in "g$name" "$name"; do
        command -v "$cand" >/dev/null 2>&1 || continue
        # Capture rather than pipe: `--version | grep -q` gives the producer
        # SIGPIPE, and pipefail would then report a match as a failure.
        out="$("$cand" --version 2>/dev/null)" || out=""
        case "$out" in
            *"GNU coreutils"*) printf '%s\n' "$cand"; return 0 ;;
        esac
    done
    return 1
}

# shellcheck disable=SC2034  # written here, read by the sourcing scripts
FS_REALPATH="$(_fs_resolve_gnu_tool realpath || echo realpath)"
# shellcheck disable=SC2034  # written here, read by the sourcing scripts
FS_STAT="$(_fs_resolve_gnu_tool stat || echo stat)"
# shellcheck disable=SC2034  # written here, read by the sourcing scripts
FS_TIMEOUT="$(_fs_resolve_gnu_tool timeout || echo timeout)"

# Say so once, early, in words. Call this from an entry script before anything
# is created; the failure otherwise lands mid-run as an unknown-option error
# from a tool the reader has no reason to suspect.
fs_require_gnu_tools() {
    local tool missing=()
    for tool in realpath stat timeout; do
        _fs_resolve_gnu_tool "$tool" >/dev/null || missing+=("$tool")
    done
    if (( ${#missing[@]} )); then
        echo "Error: no GNU ${missing[*]} on PATH. These scripts use GNU flags" >&2
        echo "(realpath -m, stat -c) that the BSD tools of the same name do not" >&2
        echo "have, and timeout, which macOS does not ship at all. All three" >&2
        echo "come from one package. On macOS: brew install coreutils" >&2
        return 1
    fi
    return 0
}

# claude-sandboxed must exist before anything is created. Resolve it here
# rather than let it fail inside a tmux pane: the pane closes when its
# command exits, so the error would flash past and the fork would look like
# it silently did nothing.
fs_require_sandbox_wrapper() {
    if command -v claude-sandboxed >/dev/null; then
        return 0
    fi
    if [[ -x "$HOME/.claude/scripts/claude-sandboxed" ]]; then
        return 0
    fi
    echo "Error: this needs claude-sandboxed on PATH." >&2
    echo "Run install.sh in the fork-sandbox repo." >&2
    return 1
}

# Refuse a value that would break out of a generated command or a key=value
# record. A single quote ends the shell string these scripts build, and a
# newline ends a line in the run record that fork-sandbox-status.sh reads
# back. Check the inputs rather than the built string, which quotes on
# purpose. Check before anything is created, so a bad name cannot leave a
# clone behind on the way out.
fs_reject_unsafe_chars() {
    local v
    for v in "$@"; do
        if [[ "$v" == *"'"* ]]; then
            echo "Error: a path or argument contains a single quote, which would" >&2
            echo "break out of the shell command this script builds. Rename it." >&2
            return 1
        fi
        if [[ "$v" == *$'\n'* ]]; then
            echo "Error: a path or argument contains a newline, which would break" >&2
            echo "the run record this script writes. Rename it." >&2
            return 1
        fi
    done
    return 0
}

# Print the top level of the repository holding a path.
fs_repo_toplevel() {
    local path="$1"
    if ! (cd "$path" && git rev-parse --show-toplevel) 2>/dev/null; then
        echo "Error: '$path' is not in a git repository." >&2
        echo "A sandboxed fork works in a clone, so the target must be a repo." >&2
        return 1
    fi
    return 0
}

# The branch has to be new. An existing one fails twice over: the clone
# already carries it, so creating it there dies immediately, and git refuses
# to fetch into a branch that is checked out. Catching it here beats catching
# it when the session ends, hours later, with nowhere to put the work.
fs_check_branch_free() {
    local repo="$1" branch="$2"
    if (cd "$repo" && git show-ref --verify --quiet "refs/heads/$branch"); then
        echo "Error: branch '$branch' already exists in $repo." >&2
        echo "Sandboxed forks commit on a new branch and fetch it back, so pick" >&2
        echo "a name that is free." >&2
        return 1
    fi
    return 0
}

# The two path constraints that let fork-sandbox.sh be blanket-approved as
# its own security boundary: the handoff becomes the prompt of a session with
# internet access, and the project is what gets cloned or pushed into a run,
# so neither is trusted as given -- both are checked against a fixed root.
# Shared so that every entry point fork-sandbox.sh grows for starting a run
# (a local sandboxed session, a --k8s dispatch) enforces the same rule rather
# than drifting: a second copy of a security check is exactly the kind of
# duplication that silently stops matching the first one.
fs_require_scratch_handoff() {
    local handoff_file="$1" real
    real="$("$FS_REALPATH" -m "$handoff_file")"
    if [[ "$real" != /var/tmp/claude-scratch/* && "$real" != /tmp/claude-scratch/* ]]; then
        echo "Error: handoff files must live under /var/tmp/claude-scratch/ (or the" >&2
        echo "/tmp/claude-scratch compat symlink) — got '$real'. The handoff" >&2
        echo "becomes the prompt of a session with internet access, so this path is a" >&2
        echo "security boundary, not a tidiness rule. Stage the document there and" >&2
        echo "rerun." >&2
        return 1
    fi
    # forks/ is excluded: it holds what approved scripts mktemp -- run dirs,
    # stage dirs, and the codex credential staging dir. A handoff there would
    # read a file the machinery wrote (the credential above all) into the
    # prompt of a session with internet access. Handoffs go in the scratch root.
    if [[ "$real" == /var/tmp/claude-scratch/forks/* || "$real" == /tmp/claude-scratch/forks/* ]]; then
        echo "Error: handoff files must not live under the forks/ machinery" >&2
        echo "directory — got '$real'. forks/ holds run dirs, staging" >&2
        echo "dirs and credential files that approved scripts create; reading one" >&2
        echo "into an internet-connected prompt is the exfiltration this check" >&2
        echo "exists to stop. Stage the handoff in the scratch root itself." >&2
        return 1
    fi
    return 0
}

fs_require_src_project() {
    local project_path="$1" real
    real="$("$FS_REALPATH" -m "$project_path")"
    if [[ "$real" != "$HOME"/src/* && "$real" != "$HOME/src" ]]; then
        echo "Error: the project must live under ~/src — got '$real'." >&2
        echo "An unattended agent gets the whole clone, and for most harnesses it" >&2
        echo "gets internet too, so which repos may be handed over is a security" >&2
        echo "boundary. Work from a checkout under ~/src, or launch" >&2
        echo "claude-sandboxed by hand for something else." >&2
        return 1
    fi
    return 0
}

fs_warn_if_dirty() {
    local path="$1" repo="$2"
    if [[ -n "$(cd "$path" && git status --porcelain)" ]]; then
        echo "Warning: '$repo' has uncommitted changes. A clone carries" >&2
        echo "committed state only, so the session will not see them." >&2
    fi
}

# --shared keeps this cheap on a large repo: the clone stores no objects of
# its own and reads history through objects/info/alternates. Never let git
# use its default local clone, which hardlinks the object files — the sandbox
# could then corrupt the real repo's objects by writing through a link.
# Clone the top level, not a subdirectory: git clone rejects a path that is
# merely inside a repository.
#
# A fourth argument starts the branch at that commit instead of at the clone's
# HEAD. Pass a full sha, not a ref name: a clone copies refs/heads and
# refs/tags only, so a commit the source repo keeps under its own ref
# namespace — a fetched pull request head, say — has no name here. The object
# is still readable through the alternates, so a sha resolves.
fs_make_clone() {
    local repo="$1" branch="$2" dest="$3" start_sha="${4:-}" key value
    git clone --shared --quiet "$repo" "$dest" || return 1
    (cd "$dest" && git checkout --quiet -b "$branch" ${start_sha:+"$start_sha"}) || return 1
    # Carry the origin's identity across. git clone copies no repo-local
    # config, so a repo whose user.email is a local override — a work address
    # on a machine whose ~/.gitconfig holds a personal one — leaves the clone
    # with no identity of its own, and every commit the sandbox makes is
    # authored by the global address fs_gitconfig_bind mounts inside. Nothing
    # downstream catches that: integration re-creates the commits on the host,
    # and cherry-pick and rebase deliberately KEEP the author while making a
    # new committer, so the wrong name survives all the way in. Signing does
    # self-heal that way; authorship does not.
    #
    # --get reads the value git would actually use, so this is right whether
    # the override is repo-local, per-worktree, or an includeIf conditional
    # include — reading --global, or a config file by hand, would miss exactly
    # the case this fixes. It lands in the clone's own repo-local config,
    # which outranks the global copy bound at $HOME/.gitconfig inside. Name
    # and address only: signing keys stay out, because the sandbox holds no
    # ssh key to sign with and fs_gitconfig_bind switches signing off for
    # that reason. A repo with no override seeds the value the global copy
    # already carries, and a machine with no identity configured seeds
    # nothing — both silent, both no-ops.
    #
    # Running git in the clone is safe HERE, though the fork-sandbox and
    # sandbox-coder-mode skills tell callers never to do it: that rule guards
    # against a clone the sandbox has written, which can carry a
    # core.fsmonitor that then executes on the host. This is creation time.
    # The sandbox has not started, and the config is still only ours.
    for key in user.name user.email; do
        value="$( (cd "$repo" && git config --get "$key") 2>/dev/null || true )"
        [[ -n "$value" ]] || continue
        (cd "$dest" && git config "$key" "$value") || true
    done
    return 0
}

# Provision a node project into the clone, so the suites a handoff asks
# for can actually run. Committed state has no node_modules, and the
# sandbox's $HOME is a fresh tmpfs, so nvm's node is invisible there —
# without this a node repo gets /usr/bin/node at whatever version the host
# package manager last installed, and no npm at all.
#   - .nvmrc names the version; FS_NODE_FLAGS asks claude-sandboxed to
#     bind that exact install read-only and put its bin first on PATH.
#     Only a plain dotted version is accepted: an alias such as lts/iron
#     has no directory under ~/.nvm/versions, and the value ends up inside
#     a generated shell command, so anything else is refused, not quoted.
#   - node_modules is COPIED, never hardlinked: the clone is writable and
#     hardlinks share inodes, so cp -al would hand the sandbox write
#     access to the host's own files.
# Both halves are no-ops in a repo without them. Fills FS_NODE_FLAGS; the
# caller formats it for its own use, like FS_ALTERNATES.
# shellcheck disable=SC2034  # written here, read by the sourcing scripts
FS_NODE_FLAGS=()

fs_node_provision() {
    local origin_repo="$1" clone_dir="$2" ver dir native count nm
    local -a shown
    FS_NODE_FLAGS=()
    if [[ -f "$origin_repo/.nvmrc" ]]; then
        ver="$(tr -d 'v[:space:]' < "$origin_repo/.nvmrc")"
        dir="$HOME/.nvm/versions/node/v$ver"
        if [[ "$FS_BACKEND_TOOLCHAIN" != host ]]; then
            # The bind names a host node install, and the sandbox's userland
            # is the image's. Say which version was asked for and not honoured
            # rather than let a version mismatch surface as a mystery later.
            echo "Note: .nvmrc asks for node v$ver, but this backend brings its" >&2
            echo "own userland, so the image's node is what the run gets." >&2
        elif [[ ! "$ver" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
            echo "Warning: .nvmrc says '$ver', which is not a plain version" >&2
            echo "number. The sandbox falls back to system node." >&2
        elif [[ -d "$dir" ]]; then
            # shellcheck disable=SC2034  # read by the sourcing scripts
            FS_NODE_FLAGS=(--bind-ro "$dir" --prepend-path "$dir/bin")
        else
            echo "Warning: .nvmrc wants node v$ver, which is not installed" >&2
            echo "under ~/.nvm. The sandbox falls back to system node." >&2
        fi
    fi
    if [[ -d "$origin_repo/node_modules" ]]; then
        echo "Copying node_modules into the clone..." >&2
        cp -a "$origin_repo/node_modules" "$clone_dir/node_modules"
        # Nearly all of that tree is JavaScript and runs anywhere. A few
        # packages also carry a compiled .node, built for one OS and one CPU.
        # Under a host toolchain those are the right binaries. Under an image
        # they are not -- a different Linux, or on a Mac a different operating
        # system -- and the failure is a throw from deep inside node with
        # nothing to say the platform is the reason. So name them here.
        # Collect the whole list before counting: `find | head` would take
        # SIGPIPE, and pipefail would turn that into a failed provision.
        if [[ "$FS_BACKEND_TOOLCHAIN" != host ]]; then
            native="$(find "$clone_dir/node_modules" -type f -name '*.node' 2>/dev/null || true)"
            if [[ -n "$native" ]]; then
                count=0
                shown=()
                while IFS= read -r nm; do
                    count=$(( count + 1 ))
                    (( count <= 3 )) && shown+=("${nm#"$clone_dir/"}")
                done <<< "$native"
                echo "Warning: node_modules holds $count compiled native module(s)," >&2
                echo "built for THIS host. The sandbox's userland comes from its" >&2
                echo "image, so requiring one of these fails inside node:" >&2
                printf '  %s\n' "${shown[@]}" >&2
                (( count > 3 )) && echo "  ... and $(( count - 3 )) more" >&2
                echo "Run 'npm rebuild' (or 'npm ci') inside the sandbox to fix it." >&2
            fi
        fi
    fi
    return 0
}

# Provision the untracked paths a repo names in its sandbox-services provision-ro
# (.agents/sandbox-services/, or the legacy .claude/sandbox-services/), so a
# copied clone can still run the
# suites that need them. A clone carries committed state only: no .venv, no
# untracked build output. Each line of provision-ro is a repo-relative path;
# it is bound READ-ONLY from the origin repo into the clone at the same
# relative path, so tools find it where they expect it. Read-only because the
# sandbox must never write back into the user's real checkout. A relocated
# virtualenv still runs — .venv/bin/python is a symlink and sys.prefix follows
# the binary's own path — the one casualty being console-script shebangs, which
# hardcode the origin path.
#
# This is a security boundary, not a convenience. The provision-ro file is
# committed content, and for a pull-request review it can be attacker-authored.
# A malicious entry must not turn into an arbitrary host-file read: the bind
# rides into a sandbox with internet access. So every entry is checked — no
# absolute path, no '..', and both the resolved source and the resolved
# destination must stay inside the repo they belong to. A symlink that escapes
# is refused, not followed. Fills FS_PROVISION_RO_FLAGS as claude-sandboxed
# --bind-ro-at pairs; a repo without the file leaves it empty.
# shellcheck disable=SC2034  # written here, read by the sourcing scripts
FS_PROVISION_RO_FLAGS=()

# The sandbox-services contract lives in one directory per repo. Prefer the
# agent-neutral .agents/sandbox-services (the current location, shared by every
# agent that runs a sealed session); fall back to .claude/sandbox-services (the
# original path, still used by repos not yet migrated). The choice is by which
# directory actually HOLDS a contract file — the sandbox-services.sh hook or a
# provision-ro list — not by mere directory existence: an empty or partial
# .agents/sandbox-services left by a half-finished migration must not shadow a
# real .claude/sandbox-services. .agents still wins when both hold one. (Both
# files are checked, not just the hook, because a Level-1 repo ships only
# provision-ro and no hook.) When neither directory holds a contract, echo the
# .agents path — the current location — so the caller's own -d/-f guard reports
# "no contract" and any error names where to put one. Callers must source this
# library first, which fork-sandbox.sh and agent-sandboxed both do.
fs_services_dir() {
    local root="$1" d
    for d in "$root/.agents/sandbox-services" "$root/.claude/sandbox-services"; do
        if [[ -f "$d/sandbox-services.sh" || -f "$d/provision-ro" ]]; then
            printf '%s\n' "$d"
            return 0
        fi
    done
    printf '%s\n' "$root/.agents/sandbox-services"
}

fs_provision_ro() {
    local origin_repo="$1" clone_dir="$2" list rel src dest src_real dest_real
    local origin_real clone_real
    FS_PROVISION_RO_FLAGS=()
    list="$(fs_services_dir "$clone_dir")/provision-ro"
    [[ -f "$list" ]] || return 0
    origin_real="$("$FS_REALPATH" -m "$origin_repo")"
    clone_real="$("$FS_REALPATH" -m "$clone_dir")"
    while IFS= read -r rel || [[ -n "$rel" ]]; do
        # Trim surrounding whitespace. A line whose first non-blank character
        # is '#' is a comment; a '#' anywhere else is part of the path — an
        # inline-comment rule would silently truncate a path that contains one.
        rel="${rel#"${rel%%[![:space:]]*}"}"
        rel="${rel%"${rel##*[![:space:]]}"}"
        [[ -n "$rel" ]] || continue
        [[ "$rel" == \#* ]] && continue
        # Syntactic refusals first: an absolute path or a '..' component would
        # name something outside the repo before any symlink is even resolved.
        # Wrapping in slashes makes the match component-accurate, so a name
        # that merely starts with '..' ('..store', say) is not refused.
        if [[ "$rel" == /* || "/$rel/" == *"/../"* ]]; then
            echo "Warning: provision-ro entry '$rel' is not a repo-relative path" >&2
            echo "inside the repo; skipping it." >&2
            continue
        fi
        src="$origin_repo/$rel"
        dest="$clone_dir/$rel"
        if [[ ! -e "$src" ]]; then
            echo "Warning: provision-ro wants '$rel', which is not in the origin" >&2
            echo "repo. The session runs without it." >&2
            continue
        fi
        # Resolve symlinks and confirm both ends stay inside their repo. A
        # committed symlink pointing at /etc or ~/.ssh is refused here, so it
        # can never reach --bind-ro-at.
        src_real="$("$FS_REALPATH" -m "$src")"
        dest_real="$("$FS_REALPATH" -m "$dest")"
        if [[ "$src_real" != "$origin_real"/* ]]; then
            echo "Warning: provision-ro entry '$rel' resolves outside the repo" >&2
            echo "($src_real); refusing it." >&2
            continue
        fi
        if [[ "$dest_real" != "$clone_real"/* ]]; then
            echo "Warning: provision-ro entry '$rel' would mount outside the clone" >&2
            echo "($dest_real); refusing it." >&2
            continue
        fi
        # Pass the resolved source, so claude-sandboxed binds exactly what was
        # checked and not a symlink that could differ.
        FS_PROVISION_RO_FLAGS+=(--bind-ro-at "$src_real" "$dest_real")
        fs_venv_interpreter_bind "$src_real"
    done < "$list"
    return 0
}

# A provisioned virtualenv only runs if its interpreter is reachable inside
# the sandbox. A venv on the system python needs nothing (/usr is mounted),
# but uv and pyenv install interpreters under $HOME, which is a tmpfs inside:
# .venv/bin/python dangles, and every compiled extension in the venv is dead
# weight behind it. pyvenv.cfg names the interpreter's bin directory in
# `home =`; bind the interpreter prefix read-only at its own path when it
# lives in a recognized store.
#
# The store allowlist is deliberate. This is the one bind derived from
# UNTRACKED content (the venv is the user's working tree, not the repo's), so
# it must not become an arbitrary host-path read: only strict subdirectories
# of known interpreter stores qualify, checked after realpath so a symlink
# cannot point the bind elsewhere.
fs_venv_interpreter_bind() {
    local venv="$1" cfg home prefix store
    cfg="$venv/pyvenv.cfg"
    [[ -f "$cfg" ]] || return 0
    # An interpreter is an executable, so it can only be carried in when the
    # sandbox runs the host's userland. Under an image backend the bind would
    # deliver something the sandbox cannot execute; say so once, here, rather
    # than let .venv/bin/python fail as a format error.
    if [[ "$FS_BACKEND_TOOLCHAIN" != host ]]; then
        echo "Warning: the venv at '$venv' needs a host interpreter, which this" >&2
        echo "backend's sandbox cannot execute -- its userland comes from an" >&2
        echo "image. The venv will not run; the image must supply python." >&2
        return 0
    fi
    home="$(sed -nE 's/^home[[:space:]]*=[[:space:]]*//p' "$cfg" | head -n1)"
    [[ -n "$home" ]] || return 0
    home="$("$FS_REALPATH" -m "$home")"
    if [[ ! -d "$home" ]]; then
        echo "Warning: the venv at '$venv' names an interpreter home that does" >&2
        echo "not exist ($home). The venv will not run in the sandbox." >&2
        return 0
    fi
    case "$home" in
        /usr/*) return 0 ;;  # the system toolchain is already mounted
    esac
    prefix="$(dirname "$home")"
    for store in "$HOME/.local/share/uv/python" "$HOME/.pyenv/versions"; do
        if [[ "$prefix" == "$store"/* ]]; then
            echo "Binding the venv's interpreter read-only: $prefix" >&2
            FS_PROVISION_RO_FLAGS+=(--bind-ro-at "$prefix" "$prefix")
            return 0
        fi
    done
    echo "Warning: the venv at '$venv' runs an interpreter the sandbox cannot" >&2
    echo "see ($home), and it is not under a recognized interpreter store, so" >&2
    echo "it is NOT bound. The venv will not run in the sandbox." >&2
    return 0
}

# The venv-interpreter binds for a REAL checkout, as agent-sandboxed needs them.
# fs_provision_ro exists for a CLONE, which carries committed state only, so it
# binds every untracked path provision-ro names from the origin into the clone.
# agent-sandboxed has no clone: its work dir is the user's own tree, so those
# untracked paths are already there and binding them again is at best redundant
# and at worst flips a writable one read-only. The one thing that is still
# missing is what lives OUTSIDE the tree — a uv or pyenv virtualenv's
# interpreter, since .venv/bin/python is a symlink into an interpreter store
# under $HOME and $HOME is a tmpfs in the sandbox. So read the same provision-ro
# list, but do only the interpreter bind for each entry that is a venv; a
# non-venv entry adds nothing. fs_venv_interpreter_bind keeps the store
# allowlist that makes this safe from an untracked source. Fills
# FS_PROVISION_RO_FLAGS; a repo without the file leaves it empty.
fs_workdir_venv_binds() {
    local work_dir="$1" list rel
    FS_PROVISION_RO_FLAGS=()
    list="$(fs_services_dir "$work_dir")/provision-ro"
    [[ -f "$list" ]] || return 0
    while IFS= read -r rel || [[ -n "$rel" ]]; do
        # Same trim-and-comment handling as fs_provision_ro: a '#' only starts a
        # comment as the first non-blank character, so a path with a '#' in it
        # is not truncated.
        rel="${rel#"${rel%%[![:space:]]*}"}"
        rel="${rel%"${rel##*[![:space:]]}"}"
        [[ -n "$rel" ]] || continue
        [[ "$rel" == \#* ]] && continue
        # Keep the entry inside the tree. The interpreter bind itself is guarded
        # by fs_venv_interpreter_bind's store allowlist, but an entry that named
        # an absolute path or climbed out with '..' has no business here.
        if [[ "$rel" == /* || "/$rel/" == *"/../"* ]]; then
            echo "Warning: provision-ro entry '$rel' is not a repo-relative path;" >&2
            echo "skipping it." >&2
            continue
        fi
        [[ -e "$work_dir/$rel" ]] || continue
        fs_venv_interpreter_bind "$work_dir/$rel"
    done < "$list"
    return 0
}

# Collect the object stores the clone reads through, so they can be bound
# read-only. An alternates file names its stores directly, not transitively,
# so follow the chain: when the source repo is itself a --shared clone its
# store points on to another, and binding only the first leaves git in the
# sandbox with "bad object HEAD".
#
# Fills the FS_ALTERNATES array. The caller formats it for its own use.
FS_ALTERNATES=()

_fs_walk_alternates() {
    local objdir="$1" file line alt
    file="$objdir/info/alternates"
    [[ -r "$file" ]] || return 0
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        # An entry may be relative to the objects dir holding the file.
        [[ "$line" == /* ]] || line="$objdir/$line"
        alt="$("$FS_REALPATH" -m "$line")"
        [[ -d "$alt" ]] || continue
        # Stop on a repeat, so a cycle cannot spin forever.
        case " ${FS_ALTERNATES[*]-} " in *" $alt "*) continue ;; esac
        FS_ALTERNATES+=("$alt")
        _fs_walk_alternates "$alt"
    done < "$file"
}

fs_collect_alternates() {
    local clone="$1"
    FS_ALTERNATES=()
    _fs_walk_alternates "$clone/.git/objects"
}

# Find pi and the node that must run it, and work out what to bind so it
# still has its dependencies inside a sandbox. Two callers need this — the
# pi harnesses of fork-sandbox.sh and agent-sandboxed — and every step of it
# is a lesson already learned, so it lives here rather than in two copies.
#
# nvm is a shell function, so a non-interactive PATH usually has no node and
# no pi. Fall back to where a global npm install under nvm puts them; the
# last match of the glob wins, which is the newest version for the v1x/v2x
# names nvm creates.
#
# Resolve every part through symlinks before it becomes a mount. ~/.nvm/current
# is a symlink to the version directory, and pi's entry script resolves out of
# bin/ and into lib/node_modules — so a bin dir taken as written and a script
# taken as resolved name two different trees, and binding only what the first
# covers leaves node unable to find pi's dependencies.
#
# Under a backend that brings its own userland none of that applies: the host's
# pi and node cannot execute inside, the image supplies both, and pi is found
# on the sandbox's own PATH. That case fills the same variables with the
# nothing-to-bind answer, so a caller needs one branch and not five.
#
# Fills FS_PI_NODE (the interpreter), FS_PI_REAL (the entry script), FS_PI_ROOT
# (the one tree to bind), FS_PI_BIN_DIR (the directory for PATH), and
# FS_PI_ARGV0 (the words that start pi, whichever case applies). FS_PI_ROOT and
# FS_PI_BIN_DIR are EMPTY when there is nothing to bind or prepend; callers
# test that rather than testing the backend again.
# shellcheck disable=SC2034  # written here, read by the sourcing scripts
FS_PI_NODE=""
# shellcheck disable=SC2034  # written here, read by the sourcing scripts
FS_PI_REAL=""
# shellcheck disable=SC2034  # written here, read by the sourcing scripts
FS_PI_ROOT=""
# shellcheck disable=SC2034  # written here, read by the sourcing scripts
FS_PI_BIN_DIR=""
# shellcheck disable=SC2034  # written here, read by the sourcing scripts
FS_PI_ARGV0=()

fs_resolve_pi() {
    local pi_bin cand
    FS_PI_NODE=""; FS_PI_REAL=""; FS_PI_ROOT=""; FS_PI_BIN_DIR=""; FS_PI_ARGV0=()

    if [[ "$FS_BACKEND_TOOLCHAIN" != host ]]; then
        # Nothing to find, nothing to bind, nothing to put on PATH. pi is a
        # name the image resolves. Naming its node would be wrong here too:
        # the image's pi runs on the image's node, by its own shebang.
        # shellcheck disable=SC2034  # read by the sourcing scripts
        FS_PI_REAL="pi"
        # shellcheck disable=SC2034  # read by the sourcing scripts
        FS_PI_ARGV0=(pi)
        return 0
    fi

    pi_bin="$(command -v pi 2>/dev/null || true)"
    if [[ -z "$pi_bin" ]]; then
        for cand in "$HOME"/.nvm/versions/node/*/bin/pi; do
            [[ -x "$cand" ]] && pi_bin="$cand"
        done
    fi
    if [[ -z "$pi_bin" ]]; then
        echo "Error: cannot find pi. Install it with:" >&2
        echo "  npm install -g @earendil-works/pi-coding-agent" >&2
        return 1
    fi

    FS_PI_REAL="$(readlink -f "$pi_bin")"
    FS_PI_BIN_DIR="$(readlink -f "$(dirname "$pi_bin")")"
    FS_PI_ROOT="$(dirname "$FS_PI_BIN_DIR")"

    # pi is a node script whose shebang is `env node`, so running it by name
    # would take whatever node the sandbox PATH happens to offer — the
    # project's pinned one, from a different major version. Name its own node
    # instead, and let PATH stay the project's business.
    FS_PI_NODE="$FS_PI_BIN_DIR/node"
    if [[ ! -x "$FS_PI_NODE" ]]; then
        FS_PI_NODE="$(command -v node 2>/dev/null || true)"
    fi
    if [[ -z "$FS_PI_NODE" || ! -x "$FS_PI_NODE" ]]; then
        echo "Error: found pi at $pi_bin but no node to run it with." >&2
        return 1
    fi

    # One bind covers the lot: under nvm, bin/node and lib/node_modules/... are
    # both inside the version directory, so binding it carries pi's
    # dependencies too. Refuse the case it does not cover rather than guess at
    # a second mount — a guess that binds too little fails deep inside node, as
    # a missing package.
    if [[ "$FS_PI_REAL" != "$FS_PI_ROOT"/* ]]; then
        echo "Error: pi resolves to $FS_PI_REAL, which is outside its node" >&2
        echo "install at $FS_PI_ROOT. This binds that one tree into the" >&2
        echo "sandbox, so an install split across two would lose its" >&2
        echo "dependencies. Install pi with npm -g under nvm." >&2
        return 1
    fi
    # Every later use is the same words, so settle them once.
    # shellcheck disable=SC2034  # read by the sourcing scripts
    FS_PI_ARGV0=("$FS_PI_NODE" "$FS_PI_REAL")
    return 0
}

# The sandbox backend: the executable that actually isolates a run.
# FORK_SANDBOX_BACKEND names it and defaults to bwrap, so the resolved name is
# sandbox-backend-$FORK_SANDBOX_BACKEND. PATH comes first, which is how a
# backend that does not live in this repository gets used; a sibling of the
# calling script is the fallback, so a checkout works before install.sh has run.
# The contract every backend implements is docs/sandbox-backend.md.
#
# Takes the calling script's own directory, because the sibling lookup has to
# be relative to the CLIENT, not to this library. Fills FS_BACKEND_BIN.
# shellcheck disable=SC2034  # written here, read by the sourcing scripts
FS_BACKEND_BIN=""

fs_resolve_backend() {
    local script_dir="$1" name bin
    name="${FORK_SANDBOX_BACKEND:-bwrap}"
    FS_BACKEND_BIN=""
    # The name becomes part of a command name, so keep it to something that
    # can only ever be one: no slash, no shell metacharacter, no leading dash.
    if [[ ! "$name" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
        echo "Error: FORK_SANDBOX_BACKEND='$name' is not a backend name." >&2
        echo "It becomes 'sandbox-backend-$name', so it must be lowercase" >&2
        echo "alphanumerics, hyphens and underscores." >&2
        return 1
    fi
    bin="$(command -v "sandbox-backend-$name" 2>/dev/null || true)"
    if [[ -z "$bin" && -x "$script_dir/sandbox-backend-$name" ]]; then
        bin="$script_dir/sandbox-backend-$name"
    fi
    if [[ -z "$bin" ]]; then
        echo "Error: cannot find sandbox-backend-$name, which is the sandbox" >&2
        echo "this runs in. It is named by FORK_SANDBOX_BACKEND (default" >&2
        echo "bwrap) and looked up on PATH and beside this script. Run" >&2
        echo "install.sh in the fork-sandbox repo." >&2
        return 1
    fi
    # shellcheck disable=SC2034  # read by the sourcing scripts
    FS_BACKEND_BIN="$bin"
    return 0
}

# What the resolved backend says about itself. One property matters so far:
# whether the sandbox inherits the host's userland or brings its own.
#
# bwrap mounts the host's /usr, so the agent CLI, node and a venv interpreter
# can be bound in from the host and will run. A container gets its userland
# from its image, and a host binary bound into that has neither its
# interpreter nor its shared libraries. On a Mac that is Mach-O against Linux;
# on Linux it is the host's glibc against the image's. One property, two
# symptoms -- which is why this is asked of the BACKEND and never derived from
# `uname`. Deriving it from the host would leave Linux-plus-container broken
# and, worse, untestable: asking the backend means the image path can be
# exercised on Linux, where it is the same code path a Mac takes.
#
# A backend written before this option exists refuses it and exits nonzero.
# That reads as `host`, the status quo, so such a backend keeps behaving
# exactly as it does today rather than silently changing.
#
# Takes FS_BACKEND_BIN, or any backend path. Fills FS_BACKEND_TOOLCHAIN.
# shellcheck disable=SC2034  # written here, read by the sourcing scripts
FS_BACKEND_TOOLCHAIN=host

fs_backend_capabilities() {
    local bin="$1" out line key value
    FS_BACKEND_TOOLCHAIN=host
    # Parse only a clean exit. A backend that refuses the option may still
    # print its usage, and a usage line can hold an '=' -- reading that as a
    # capability would be inventing an answer out of an error message.
    out="$("$bin" --capabilities 2>/dev/null)" || return 0
    while IFS= read -r line; do
        [[ "$line" == *=* ]] || continue
        key="${line%%=*}"
        value="${line#*=}"
        case "$key" in
        toolchain)
            case "$value" in
            host|image)
                # shellcheck disable=SC2034  # read by the sourcing scripts
                FS_BACKEND_TOOLCHAIN="$value"
                ;;
            *)
                echo "Warning: the backend reports toolchain='$value', which is" >&2
                echo "not 'host' or 'image'. Assuming host, which is what every" >&2
                echo "backend did before the property existed." >&2
                ;;
            esac
            ;;
        esac
        # An unknown key is ignored on purpose: a newer backend may declare
        # properties this caller has never heard of.
    done <<< "$out"
    return 0
}

# Carry the git identity into a sandbox, but switch commit signing off. The
# host config here signs with an SSH key under ~/.ssh, and ~/.ssh is masked on
# purpose, so every commit inside the sandbox would fail. Appending the
# overrides at the end beats anything set earlier, includes included.
#
# Writes the copy into the caller's per-run state dir, which the caller's own
# cleanup removes, and fills FS_GITCONFIG_FLAGS with the backend flags that
# mount it at $HOME/.gitconfig inside. Both clients need this: a sealed pi run
# commits in the sandbox exactly as a claude run does.
# shellcheck disable=SC2034  # written here, read by the sourcing scripts
FS_GITCONFIG_FLAGS=()

fs_gitconfig_bind() {
    local state_dir="$1"
    FS_GITCONFIG_FLAGS=()
    if [[ -r "$HOME/.gitconfig" ]]; then
        cat "$HOME/.gitconfig" > "$state_dir/gitconfig"
    else
        : > "$state_dir/gitconfig"
    fi
    printf '\n[commit]\n\tgpgsign = false\n[tag]\n\tgpgsign = false\n' \
        >> "$state_dir/gitconfig"
    # shellcheck disable=SC2034  # read by the sourcing scripts
    FS_GITCONFIG_FLAGS=(--bind-ro-at "$state_dir/gitconfig" "$HOME/.gitconfig")
    return 0
}

# The Claude OAuth credential, as JSON on stdout.
#
# On Linux the CLI keeps it in ~/.claude/.credentials.json. On macOS it keeps
# it in the login Keychain instead and that file does not exist, so a Mac fails
# the file check and never reaches the sandbox at all. Reading it here rather
# than at two later jq call sites also means the Keychain is touched exactly
# once: it can prompt for access the first time, and a prompt is a foreground
# interaction in a tool built to run unattended, so it belongs at launch on the
# host and nowhere else.
#
# The value never reaches an argv. Callers hold it in a variable and pipe it
# with printf, a builtin, so `ps` never shows it.
#
# Prints the JSON on success; writes its own error and returns non-zero
# otherwise. It reports WHERE it came from through fs_claude_credential_source
# rather than through a variable of its own: a caller can only take the JSON
# through a command substitution, and a subshell cannot set a variable in the
# shell that started it -- so such a variable would read empty at exactly the
# moment an error message wanted it.
#
# The Keychain service name Claude Code stores the credential under. It is a
# list because the name is the CLI's business and could change; each is tried
# in turn, and the error below says how to look it up by hand.
FS_CLAUDE_KEYCHAIN_SERVICES=("Claude Code-credentials")

# A human name for where the credential comes from, for error messages. Reads
# nothing and holds no secret, so it is safe to call from anywhere, as often as
# a message needs it.
fs_claude_credential_source() {
    local file="$HOME/.claude/.credentials.json"
    if [[ ! -f "$file" && "$(uname -s)" == Darwin ]]; then
        printf '%s\n' "the login Keychain"
    else
        printf '%s\n' "$file"
    fi
}

fs_read_claude_credential() {
    local file="$HOME/.claude/.credentials.json" svc out
    if [[ -f "$file" ]]; then
        # `-f` proves it is a regular file, not that it can be read. Check the
        # read itself: an unreadable credential used to abort loudly, when jq
        # opened the file directly, and returning 0 with no output here would
        # instead be diagnosed downstream as an EXPIRED token -- sending the
        # user to re-log-in, which rewrites a file they still cannot read.
        if ! cat -- "$file"; then
            echo "Error: $file exists but could not be read. Check its owner" >&2
            echo "and mode -- a credential written under sudo is the usual" >&2
            echo "cause. This is not an expired token; logging in again would" >&2
            echo "rewrite a file you still cannot read." >&2
            return 1
        fi
        return 0
    fi

    if [[ "$(uname -s)" == Darwin ]] && command -v security >/dev/null 2>&1; then
        for svc in "${FS_CLAUDE_KEYCHAIN_SERVICES[@]}"; do
            out="$(security find-generic-password -s "$svc" -w 2>/dev/null)" || continue
            # A wrong item would otherwise become a silently broken credential
            # inside the sandbox, which fails as a 401 an hour later. Check the
            # shape here, where the error can still say what is wrong.
            printf '%s' "$out" | jq -e '.claudeAiOauth.accessToken' >/dev/null 2>&1 || continue
            printf '%s' "$out"
            return 0
        done
        echo "Error: no Claude credential found. $file does not exist, which is" >&2
        echo "expected on macOS -- the CLI keeps it in the login Keychain -- but" >&2
        echo "no usable item was there either. Tried: ${FS_CLAUDE_KEYCHAIN_SERVICES[*]}" >&2
        echo "Log in with claude first. If you are already logged in, the service" >&2
        echo "name may have changed; find it with:" >&2
        echo "  security dump-keychain | grep -i claude" >&2
        return 1
    fi

    echo "Error: $file not found. Log in with claude first." >&2
    return 1
}

# The host's model and browser caches, read-only, when the host has them.
# Both clients want them, and neither wants the surgery to be repeated.
# Fills FS_CACHE_FLAGS with backend flags; empty when the host has no cache.
#
# The Hugging Face model cache:
#
# An ML project's settings import commonly reaches transformers, and
# from_pretrained() is a local-disk read when the snapshot is already cached and
# a network call when it is not. In a sandbox that call is doomed: a sealed one
# has no network at all, a pinned one has no HF token, and a gated repo needs
# one. Binding the cache turns the common case back into the read it should be.
#
# Only the content subdirectories, and NEVER the parent ~/.cache/huggingface:
# that is where huggingface_hub writes `token` and `stored_tokens`. Read-only is
# enough to authenticate with, and this sandbox is built to hold no credential,
# so binding the parent would quietly hand an HF token to every session from the
# day the user first logs in. The subdirectories hold model content and nothing
# else.
#
# Read-only in the other direction too: sandboxed code cannot poison a cache the
# host later loads models from.
#
# HF_HUB_OFFLINE goes in only alongside the cache bind, never on its own. With a
# cache mounted it turns a doomed fetch into the local read it should be. With
# no cache there is nothing to read locally, and forcing offline would break a
# public download that a pinned-egress run could still have made.
#
# The Playwright browser cache:
#
# Playwright hardcodes ~/.cache/ms-playwright as its default browsers path, so
# a run that launches Chromium finds the build there or dies with "Executable
# doesn't exist" — and `playwright install` cannot fix it in a sandbox.
#
# Unlike the Hugging Face cache the WHOLE directory is bound: it holds browser
# builds (chromium-*, ffmpeg-*) and nothing else — no token, no config — so it
# needs none of the subdirectory surgery the HF bind does. Read-only in both
# directions, so a run cannot poison a browser the host later launches.
# Chromium's own inner sandbox keeps working: bwrap leaves nested user
# namespaces available, so callers need no --no-sandbox.
# shellcheck disable=SC2034  # written here, read by the sourcing scripts
FS_CACHE_FLAGS=()

fs_cache_binds() {
    local hf_root="$HOME/.cache/huggingface" pw_root="$HOME/.cache/ms-playwright"
    local hf_sub hf_bound=0
    FS_CACHE_FLAGS=()
    for hf_sub in hub xet; do
        [[ -d "$hf_root/$hf_sub" ]] || continue
        FS_CACHE_FLAGS+=(--bind-ro "$hf_root/$hf_sub")
        hf_bound=1
    done
    if (( hf_bound )); then
        FS_CACHE_FLAGS+=(--setenv HF_HUB_OFFLINE=1)
    fi
    # The Hugging Face bind above is model DATA and travels to any sandbox.
    # This one is browser BINARIES, so it is host-toolchain only: an image's
    # userland cannot execute the host's Chromium build, and an image that
    # needs a browser has to carry its own.
    if [[ -d "$pw_root" && "$FS_BACKEND_TOOLCHAIN" == host ]]; then
        FS_CACHE_FLAGS+=(--bind-ro "$pw_root")
    fi
    return 0
}
