#!/usr/bin/env bash
# fork-sandbox-git-ssh-lib.sh -- the cluster postmaster's git ssh command
# (sourced library, not a command)
#
# Usage: source "$script_dir/fork-sandbox-git-ssh-lib.sh"
#
# The postmaster container's git reaches its remote over ssh with the
# deploy key and known_hosts that fork-sandbox-postmaster-pod-init.sh
# installs under $HOME/.ssh. pod-init exports GIT_SSH_COMMAND before it
# execs `deliver`, so deliver and everything it runs inherit it; a postmaster
# verb run from another shell in the same container (`kubectl exec ... --
# fork-sandbox-postmaster.sh hook fire ...`) inherits nothing, and its hook's
# git fetch fails host-key verification. Both sides build the command here,
# so they can never drift apart.
#
# Its own file, not part of fork-sandbox-lib.sh: pod-init runs before
# anything else in the container and checks its own short tool list; the
# big library resolves GNU tools it never needs. Needs nothing but bash.

# Prints the ssh command for the deploy key and known_hosts under ssh dir $1
# (default $HOME/.ssh): that key only, and that host key strictly.
fs_git_ssh_command() {
    local ssh_dir="${1:-$HOME/.ssh}"
    printf 'ssh -i %s -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=%s' \
        "$ssh_dir/deploy-key" "$ssh_dir/known_hosts"
}

# Exports GIT_SSH_COMMAND the way pod-init does for `deliver`, but only when
# it is unset or empty and the deploy key and known_hosts pod-init installs
# are both in $HOME/.ssh. Anywhere else (a laptop, a caller that set its own)
# it changes nothing.
fs_git_ssh_export() {
    [[ -z "${GIT_SSH_COMMAND:-}" ]] || return 0
    [[ -f "$HOME/.ssh/deploy-key" && -f "$HOME/.ssh/known_hosts" ]] || return 0
    GIT_SSH_COMMAND="$(fs_git_ssh_command "$HOME/.ssh")"
    export GIT_SSH_COMMAND
}
