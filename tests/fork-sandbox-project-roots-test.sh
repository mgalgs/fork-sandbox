#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2088  # literal '~/...' PROJECT_ROOTS values are
# intentional: fs_require_project_root does the ~/ expansion itself, so the
# fixtures write the tilde form unexpanded, on purpose.
# fork-sandbox-project-roots-test.sh — fs_require_project_root's configurable
# project-root boundary
#
# Usage: tests/fork-sandbox-project-roots-test.sh
#
# fork-sandbox.sh is meant to be blanket-approved, and the project it clones
# is handed to a session that usually has internet access, so which
# directories a project may come from is a security boundary
# (fs_require_project_root in scripts/fork-sandbox-lib.sh). This suite covers
# the configurable side of that boundary: $config_dir/projects.env's
# PROJECT_ROOTS key, its ~/ expansion, and the refusals that keep a
# misconfigured file from silently widening what an approved invocation can
# hand to a sandbox. It does not re-cover the plain ~/src default's symlink
# semantics beyond what is needed here -- see fork-sandbox-k8s-test.sh's own
# fs_require_project_root section for that.
#
# Every case runs against a throwaway HOME and a throwaway config dir of its
# own, never the real ones.
#
# This lives in tests/ rather than scripts/tests/ on purpose: install.sh
# iterates scripts/* and runs `sed -n 2p` on each entry to build the
# Utilities table, and a directory there makes that read fail under `set -e`.

set -uo pipefail

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck source-path=SCRIPTDIR/../scripts
# shellcheck source=../scripts/fork-sandbox-lib.sh
# shellcheck disable=SC1091  # plain shellcheck cannot follow it; use -x
source "$repo_dir/scripts/fork-sandbox-lib.sh"

pass=0
fail=0
tmpdirs=()

cleanup() {
    local d
    for d in "${tmpdirs[@]-}"; do
        [[ -n "$d" && -d "$d" ]] && rm -rf -- "$d"
    done
}
trap cleanup EXIT

ok() { printf '  ok    %s\n' "$1"; pass=$(( pass + 1 )); }
no() { printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; fail=$(( fail + 1 )); }

# A fresh scratch HOME plus an (empty, non-existent) config dir under it --
# every case gets its own pair so a projects.env one case writes cannot leak
# into another.
new_home() {
    local h
    h="$(mktemp -d)"
    printf '%s' "$h"
}

write_projects_env() {
    local config_dir="$1" value="$2"
    mkdir -p "$config_dir"
    printf 'PROJECT_ROOTS=%s\n' "$value" > "$config_dir/projects.env"
}

printf '== default: no projects.env means exactly $HOME/src ==\n'
default_home="$(new_home)"; tmpdirs+=("$default_home")
default_config="$default_home/.config/fork-sandbox"
if HOME="$default_home" fs_require_project_root "$default_home/src/x" "$default_config" 2>/dev/null; then
    ok "default accepts \$HOME/src/x"
else
    no "default accepts \$HOME/src/x"
fi
err="$(mktemp)"
if HOME="$default_home" fs_require_project_root "$default_home/code/x" "$default_config" 2>"$err"; then
    no "default refuses \$HOME/code/x"
else
    case "$(cat "$err")" in
        *"must live under ~/src"*) ok "default refuses \$HOME/code/x" ;;
        *) no "default refuses \$HOME/code/x" "$(cat "$err")" ;;
    esac
fi

printf '\n== an empty PROJECT_ROOTS value means the default too ==\n'
empty_home="$(new_home)"; tmpdirs+=("$empty_home")
empty_config="$empty_home/.config/fork-sandbox"
write_projects_env "$empty_config" ""
if HOME="$empty_home" fs_require_project_root "$empty_home/src/x" "$empty_config" 2>/dev/null; then
    ok "an empty PROJECT_ROOTS value accepts \$HOME/src/x"
else
    no "an empty PROJECT_ROOTS value accepts \$HOME/src/x"
fi

printf '\n== a configured PROJECT_ROOTS with two ~/ entries ==\n'
multi_home="$(new_home)"; tmpdirs+=("$multi_home")
multi_config="$multi_home/.config/fork-sandbox"
write_projects_env "$multi_config" '~/src:~/code'
if HOME="$multi_home" fs_require_project_root "$multi_home/src/x" "$multi_config" 2>/dev/null; then
    ok "configured roots accept a project under the first root"
else
    no "configured roots accept a project under the first root"
fi
if HOME="$multi_home" fs_require_project_root "$multi_home/code/x" "$multi_config" 2>/dev/null; then
    ok "configured roots accept a project under the second root"
else
    no "configured roots accept a project under the second root"
fi
if HOME="$multi_home" fs_require_project_root "$multi_home/other/x" "$multi_config" 2>"$err"; then
    no "configured roots refuse a project under neither"
else
    case "$(cat "$err")" in
        *"must live under one of the configured roots"*)
            ok "configured roots refuse a project under neither" ;;
        *) no "configured roots refuse a project under neither" "$(cat "$err")" ;;
    esac
fi

printf '\n== an absolute root works ==\n'
abs_home="$(new_home)"; tmpdirs+=("$abs_home")
abs_config="$abs_home/.config/fork-sandbox"
abs_root="$(mktemp -d)"; tmpdirs+=("$abs_root")
write_projects_env "$abs_config" "$abs_root"
if HOME="$abs_home" fs_require_project_root "$abs_root/proj" "$abs_config" 2>/dev/null; then
    ok "an absolute PROJECT_ROOTS entry accepts a project inside it"
else
    no "an absolute PROJECT_ROOTS entry accepts a project inside it"
fi

printf '\n== a symlinked root accepts a project inside it; an outward link inside it is refused ==\n'
link_stage="$(mktemp -d)"; tmpdirs+=("$link_stage")
mkdir -p "$link_stage/home" "$link_stage/vol/root/proj" "$link_stage/outside/evil"
ln -s "$link_stage/vol/root" "$link_stage/home/projects"
ln -s "$link_stage/outside/evil" "$link_stage/vol/root/escape"
link_config="$link_stage/home/.config/fork-sandbox"
write_projects_env "$link_config" "$link_stage/home/projects"
if HOME="$link_stage/home" fs_require_project_root "$link_stage/home/projects/proj" "$link_config" 2>/dev/null; then
    ok "a project under a symlinked root is accepted"
else
    no "a project under a symlinked root is accepted"
fi
if HOME="$link_stage/home" fs_require_project_root "$link_stage/home/projects/escape" "$link_config" 2>"$err"; then
    no "a link inside a root that points outside is refused"
else
    case "$(cat "$err")" in
        *"must live under one of the configured roots"*)
            ok "a link inside a root that points outside is refused" ;;
        *) no "a link inside a root that points outside is refused" "$(cat "$err")" ;;
    esac
fi

printf '\n== a relative entry is refused, naming the key ==\n'
rel_home="$(new_home)"; tmpdirs+=("$rel_home")
rel_config="$rel_home/.config/fork-sandbox"
write_projects_env "$rel_config" 'relative/path'
if HOME="$rel_home" fs_require_project_root "$rel_home/src/x" "$rel_config" 2>"$err"; then
    no "a relative PROJECT_ROOTS entry is refused"
else
    case "$(cat "$err")" in
        *"PROJECT_ROOTS"*"'relative/path'"*"not"*"an absolute path"*)
            ok "a relative PROJECT_ROOTS entry is refused" ;;
        *) no "a relative PROJECT_ROOTS entry is refused" "$(cat "$err")" ;;
    esac
fi

printf "\n== '/' is refused, naming the key ==\n"
root_home="$(new_home)"; tmpdirs+=("$root_home")
root_config="$root_home/.config/fork-sandbox"
write_projects_env "$root_config" '/'
if HOME="$root_home" fs_require_project_root "$root_home/src/x" "$root_config" 2>"$err"; then
    no "'/' as a PROJECT_ROOTS entry is refused"
else
    case "$(cat "$err")" in
        *"PROJECT_ROOTS"*"'/'"*"resolves"*"to '/'"*)
            ok "'/' as a PROJECT_ROOTS entry is refused" ;;
        *) no "'/' as a PROJECT_ROOTS entry is refused" "$(cat "$err")" ;;
    esac
fi

printf "\n== a bare '~' is refused, naming the key ==\n"
tilde_home="$(new_home)"; tmpdirs+=("$tilde_home")
tilde_config="$tilde_home/.config/fork-sandbox"
write_projects_env "$tilde_config" '~'
if HOME="$tilde_home" fs_require_project_root "$tilde_home/src/x" "$tilde_config" 2>"$err"; then
    no "a bare '~' PROJECT_ROOTS entry is refused"
else
    case "$(cat "$err")" in
        *"PROJECT_ROOTS"*"'~'"*"HOME's real path or an ancestor of it"*)
            ok "a bare '~' PROJECT_ROOTS entry is refused" ;;
        *) no "a bare '~' PROJECT_ROOTS entry is refused" "$(cat "$err")" ;;
    esac
fi

printf '\n== an ancestor of HOME is refused, naming the key ==\n'
anc_home="$(new_home)"; tmpdirs+=("$anc_home")
mkdir -p "$anc_home/nested/home"
anc_config="$anc_home/nested/home/.config/fork-sandbox"
write_projects_env "$anc_config" "$anc_home"
if HOME="$anc_home/nested/home" fs_require_project_root \
    "$anc_home/nested/home/src/x" "$anc_config" 2>"$err"; then
    no "an ancestor of \$HOME as a PROJECT_ROOTS entry is refused"
else
    case "$(cat "$err")" in
        *"PROJECT_ROOTS"*"HOME's real path or an ancestor of it"*)
            ok "an ancestor of \$HOME as a PROJECT_ROOTS entry is refused" ;;
        *) no "an ancestor of \$HOME as a PROJECT_ROOTS entry is refused" "$(cat "$err")" ;;
    esac
fi

printf "\n== \$HOME itself as a PROJECT_ROOTS entry is refused ==\n"
homeself_home="$(new_home)"; tmpdirs+=("$homeself_home")
homeself_config="$homeself_home/.config/fork-sandbox"
write_projects_env "$homeself_config" "$homeself_home"
if HOME="$homeself_home" fs_require_project_root "$homeself_home/src/x" "$homeself_config" 2>"$err"; then
    no "\$HOME itself as a PROJECT_ROOTS entry is refused"
else
    case "$(cat "$err")" in
        *"PROJECT_ROOTS"*"HOME's real path or an ancestor of it"*)
            ok "\$HOME itself as a PROJECT_ROOTS entry is refused" ;;
        *) no "\$HOME itself as a PROJECT_ROOTS entry is refused" "$(cat "$err")" ;;
    esac
fi

printf "\n== a root that covers \$config_dir without being \$HOME or an ancestor is refused ==\n"
cfgcover_home="$(new_home)"; tmpdirs+=("$cfgcover_home")
cfgcover_config="$cfgcover_home/.config/fork-sandbox"
write_projects_env "$cfgcover_config" '~/.config'
if HOME="$cfgcover_home" fs_require_project_root \
    "$cfgcover_home/.config/fork-sandbox" "$cfgcover_config" 2>"$err"; then
    no "a root covering \$config_dir is refused"
else
    case "$(cat "$err")" in
        *"PROJECT_ROOTS"*"covers"*"$cfgcover_config"*)
            ok "a root covering \$config_dir is refused" ;;
        *) no "a root covering \$config_dir is refused" "$(cat "$err")" ;;
    esac
fi

printf "\n== a root that covers \$HOME/.ssh without being \$HOME or an ancestor is refused ==\n"
sshcover_home="$(new_home)"; tmpdirs+=("$sshcover_home")
sshcover_config="$sshcover_home/.config/fork-sandbox"
write_projects_env "$sshcover_config" '~/.ssh'
if HOME="$sshcover_home" fs_require_project_root \
    "$sshcover_home/.ssh" "$sshcover_config" 2>"$err"; then
    no "a root covering \$HOME/.ssh is refused"
else
    case "$(cat "$err")" in
        *"PROJECT_ROOTS"*"covers"*"$sshcover_home/.ssh"*)
            ok "a root covering \$HOME/.ssh is refused" ;;
        *) no "a root covering \$HOME/.ssh is refused" "$(cat "$err")" ;;
    esac
fi

printf '\n== empty entries (a::b, a trailing :) are skipped ==\n'
skip_home="$(new_home)"; tmpdirs+=("$skip_home")
skip_config="$skip_home/.config/fork-sandbox"
write_projects_env "$skip_config" '~/src::~/code:'
if HOME="$skip_home" fs_require_project_root "$skip_home/src/x" "$skip_config" 2>"$err"; then
    ok "an empty entry between two real ones is skipped, first root still accepted"
else
    no "an empty entry between two real ones is skipped, first root still accepted" "$(cat "$err")"
fi
if HOME="$skip_home" fs_require_project_root "$skip_home/code/x" "$skip_config" 2>"$err"; then
    ok "a trailing ':' is skipped, second root still accepted"
else
    no "a trailing ':' is skipped, second root still accepted" "$(cat "$err")"
fi

printf "\n== the refusal message names projects.env ==\n"
name_home="$(new_home)"; tmpdirs+=("$name_home")
name_config="$name_home/.config/fork-sandbox"
write_projects_env "$name_config" '~/src'
if HOME="$name_home" fs_require_project_root "$name_home/other/x" "$name_config" 2>"$err"; then
    no "the refusal names projects.env"
else
    case "$(cat "$err")" in
        *"$name_config/projects.env"*)
            ok "the refusal names projects.env" ;;
        *) no "the refusal names projects.env" "$(cat "$err")" ;;
    esac
fi

rm -f "$err"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
(( fail == 0 )) || exit 1
