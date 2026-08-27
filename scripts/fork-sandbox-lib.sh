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
    local repo="$1" branch="$2" dest="$3" start_sha="${4:-}"
    git clone --shared --quiet "$repo" "$dest" || return 1
    (cd "$dest" && git checkout --quiet -b "$branch" ${start_sha:+"$start_sha"}) || return 1
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
    local origin_repo="$1" clone_dir="$2" ver dir
    FS_NODE_FLAGS=()
    if [[ -f "$origin_repo/.nvmrc" ]]; then
        ver="$(tr -d 'v[:space:]' < "$origin_repo/.nvmrc")"
        dir="$HOME/.nvm/versions/node/v$ver"
        if [[ ! "$ver" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
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
    origin_real="$(realpath -m "$origin_repo")"
    clone_real="$(realpath -m "$clone_dir")"
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
        src_real="$(realpath -m "$src")"
        dest_real="$(realpath -m "$dest")"
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
    home="$(sed -nE 's/^home[[:space:]]*=[[:space:]]*//p' "$cfg" | head -n1)"
    [[ -n "$home" ]] || return 0
    home="$(realpath -m "$home")"
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
        alt="$(realpath -m "$line")"
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
# Fills FS_PI_NODE (the interpreter), FS_PI_REAL (the entry script), FS_PI_ROOT
# (the one tree to bind) and FS_PI_BIN_DIR (the directory for PATH).
# shellcheck disable=SC2034  # written here, read by the sourcing scripts
FS_PI_NODE=""
# shellcheck disable=SC2034  # written here, read by the sourcing scripts
FS_PI_REAL=""
# shellcheck disable=SC2034  # written here, read by the sourcing scripts
FS_PI_ROOT=""
# shellcheck disable=SC2034  # written here, read by the sourcing scripts
FS_PI_BIN_DIR=""

fs_resolve_pi() {
    local pi_bin cand
    FS_PI_NODE=""; FS_PI_REAL=""; FS_PI_ROOT=""; FS_PI_BIN_DIR=""

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
    if [[ -d "$pw_root" ]]; then
        FS_CACHE_FLAGS+=(--bind-ro "$pw_root")
    fi
    return 0
}
