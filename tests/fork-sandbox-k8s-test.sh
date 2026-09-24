#!/usr/bin/env bash
# shellcheck disable=SC2016  # literal shell snippets and source-text needles are intentional
# fork-sandbox-k8s-test.sh — the Kubernetes run mode holds its own contract
#
# Usage: tests/fork-sandbox-k8s-test.sh
#
# Runs entirely offline: no cluster, no network. Everything it checks is
# either static analysis (shellcheck, yamllint) or the rendered text of a
# --dry-run invocation, which touches no kubectl and no git remote. That is
# the whole point of --dry-run existing -- see docs/kubernetes-runs.md.
#
# It covers:
#   - shellcheck on the seven new scripts (the client, the platform plugin,
#     the pod entrypoint, the egress gate, the inbox writer, the review
#     loop, the context extractor).
#   - yamllint on manifests/k8s/ and on the install/submit/run --dry-run
#     renders.
#   - fork-sandbox-k8s-platform-generic's two verbs.
#   - the properties docs/kubernetes-runs.md promises: the agent pod never
#     automounts a ServiceAccount token, and its egress policy has no rule
#     permitting port 443 -- only the proxy and DNS are reachable.
#   - an unknown platform name fails with a clear error.
#   - `run --dry-run` renders byte-for-byte the same Job YAML as
#     `submit --dry-run`, proving run delegates rather than growing its own
#     divergent copy of the rendering, and rejects the same argument
#     mistakes the other verbs reject.
#   - `run`'s whole poll/wait/fetch/pull-back/rm sequence, driven end to
#     end against a stubbed kubectl+git pair (the stub cannot prove what a
#     real pod does with the .fetched marker, only what the client does in
#     what order): a failed outbox read reports kubectl's own stderr,
#     a failed read with empty stderr says so explicitly, the outbox
#     read happens BEFORE the fetch touches /work/.fetched, a
#     substantially-over-cap outbox is diagnosed as over the cap (not as
#     a read failure) even when kubectl dies of EPIPE, the
#     review-loop.json read carries the same request-timeout bound, and a
#     zero-harvest run (agent exit 0, zero commits, an outbox holding
#     nothing but operator metadata) makes run itself exit 3 with no
#     'run complete' line.
#   - the `wait` and `collect` verbs, driven directly against the same
#     stubbed kubectl pair: a completed wait prints the agent's exit code
#     to stdout and nothing else (a non-zero AGENT exit is a successful
#     wait that exits 0), while a Failed pod, a Succeeded pod (run
#     completed, then idled out its TTL), a Failed job condition and a
#     malformed sentinel each fail the wait with the terminal code 2
#     (the run can never complete through it again) and a timeout fails
#     it with code 1 (the run may still be going); collect
#     lands the outbox at --outbox-dir, refuses an over-cap one without
#     costing the fetch, warns on an unreadable one and still fetches,
#     reports an approved and a cap review-loop outcome under
#     --review-loop 1, never reads review-loop.json when --review-loop is
#     omitted, removes the job unless --keep, and reads the outbox before
#     the fetch touches /work/.fetched. It also pulls the agent's
#     transcript and the per-container pod logs back into an `evidence`
#     directory SIBLING of the outbox, before the fetch touches
#     /work/.fetched, with the same request-timeout bound; a run whose
#     evidence capture failed is NOT reaped (a loud block and the manual
#     rm command, and --keep still keeps working unchanged); a pod spec
#     that is not readable JSON is such a failed capture, not a silent
#     abandon; and a
#     zero-harvest run -- the agent exited 0, the fetch brought back zero
#     commits, and the outbox holds no file the agent wrote (.fork-
#     sandbox-model discounted as operator metadata) -- keeps its job and
#     exits 3, under --keep as well, while zero commits with a non-empty
#     outbox stays a success and a non-zero agent exit is never flagged.
#   - `submit --dry-run`'s rendered handoff.md carries the operator-inbox
#     section, names /work/inbox, and never claims that directory is
#     read-only -- it is not, in a pod (see docs/kubernetes-runs.md).
#   - `say`'s own argument validation (missing --branch, missing/empty
#     message, unknown option) -- all rejected before any kubectl call, so
#     they run with no cluster. The kubectl exec write itself needs a live
#     pod and is not covered here.
#   - fork-sandbox-k8s-inbox-write.sh's naming and no-collision behavior,
#     run directly against a plain directory -- the same script the pod
#     mounts and `say` execs over kubectl exec, so this is the real
#     implementation under test, not a duplicate of its logic.
#   - no file in the repo matches a private-hostname shape, guarding the
#     public-repo leak rule every script and manifest here has to hold to.
#   - the per-run services spec's env var name rules: services[].env
#     accepts Kubernetes' IsEnvVarName set -- dotted names
#     (discovery.type, bootstrap.memory_lock, node.store.allow_mmap) and a
#     dashed name -- while refusing the literal names '.' and '..' and
#     still refusing a space, a '$' and a leading digit; sandboxEnv is
#     deliberately stricter (shell-safe names only) and its refusal
#     message says why, since that map is written into a shell-sourced
#     .env.sandbox; and the parser's 6-positional-argument render form
#     still renders as before.
#   - the parser's validate-only mode (the verb fork-sandbox
#     validate-services routes to): exit 0 with the limits it applied
#     printed (built-in defaults when the config's k8s.env names none of
#     the cap keys, the k8s.env values when it does -- so a local pass is
#     never mistaken for a guarantee under a different site's
#     configuration), non-zero with the same field-naming message on an
#     invalid spec, and it writes nothing; an invalid spec's message
#     names the file the user actually gave.
#   - fork-sandbox-k8s.sh keeps spelling its GNU tools through the
#     resolved names fork-sandbox-lib.sh sets ($FS_STAT, $FS_REALPATH,
#     $FS_TIMEOUT) rather than the bare names, which on macOS are the BSD
#     tools that reject the GNU flags -- with exactly one documented
#     exception, the readlink -f bootstrap that runs before the library
#     is sourced.
#   - fork-sandbox.sh --k8s: the two new lib functions it shares with the
#     local path (fs_require_scratch_handoff, fs_require_src_project), that
#     it defaults a bare --k8s to --harness pi, that a model-less --k8s run
#     passes the launcher on ANY install -- on a legacy install the
#     refusal is fork-sandbox-k8s.sh's own run verb, and on an endpoints
#     install the render lands on K8S_DEFAULT_ENDPOINT's endpoint when
#     k8s.env names one --
#     that --harness claude is accepted too (also requiring --model, its
#     own Claude Code model name) while every other --harness value and
#     every flag the cluster path cannot honor is refused by name (never
#     silently dropping one), that --timeout/--keep are refused without
#     --k8s, that a --branch is generated when none is given, and that
#     --dry-run renders byte-for-byte the same Job YAML
#     `fork-sandbox-k8s.sh run --dry-run` does for the same arguments --
#     proving the dispatcher execs rather than growing a divergent copy of
#     anything.
#   - `submit --dry-run --review-loop N`: the four review-loop ConfigMap
#     keys (review-prompt.md, fix-prompt-header.md,
#     code-review-portable-skill.md, review-loop.sh) and the REVIEW_LOOP_CAP
#     / BASE_SHA env vars render only with the flag, never without it; the
#     rendered review-prompt.md and fix-prompt-header.md are byte-for-byte
#     what fs_emit_prompt_preamble + fs_emit_review_prompt_body /
#     fs_emit_fix_prompt_body produce for the same arguments, with no
#     overlay in between -- the property that keeps this from growing a
#     second copy of the prompt text; the rendered review prompt names the
#     POD's skill and verdict paths, never a host path; --review-loop 0 and
#     a non-numeric value are both rejected before any kubectl call.
#   - `--pi-args ARGS` on submit and run: the value renders verbatim into
#     the rendered Job's PI_ARGS env var when given, and the flag's
#     absence renders no PI_ARGS env at all (not an empty value); the
#     entrypoint's pi invocation (run_pi_coding_leg, extracted from the
#     entrypoint's own source and run against a stubbed pi that records
#     its argv) receives "--thinking low" as two separate arguments and
#     an unset or empty PI_ARGS as none; a value containing a single
#     quote, a double quote, or a backslash is refused at parse time
#     with nothing created (the stubbed kubectl's log stays empty),
#     --harness claude is refused,
#     and run's copy forwards to submit unchanged (byte-for-byte the same
#     dry-run render).
#   - fork-sandbox.sh --k8s --review-loop N is no longer refused, and
#     --review-model given without --review-loop still is, on either
#     harness -- the same coherence rule the local path applies. On
#     --harness claude, a --review-loop also requires --review-harness pi
#     given explicitly (with a review model, via --review-model or the
#     combined pi/<id> form), since the pod's review leg is always pi and
#     never claude; --review-harness itself is refused outright on
#     --harness pi, where there is nothing to switch.
#   - fork-sandbox-k8s-review-loop.sh, the pod-side review/fix loop, driven
#     directly against a scratch git repo with PI_BIN pointed at a stub --
#     no cluster, no pod, no real pi. Covers every ended value the control
#     flow can reach: approved, findings-then-fix-with-progress,
#     no-progress, harness-error (a bad first verdict line, a missing
#     verdict, and a SYMLINKED verdict whose target is never read), cap,
#     and skipped (branch head already at --base-sha).
#   - `--outbox-max` on both submit and run: a parsed value in each accepted
#     unit (bare digits, K, M, G) reaches both the rendered Job spec's
#     OUTBOX_MAX_BYTES env entry and fs_emit_prompt_preamble's stated MiB
#     figure; run's own copy is forwarded through to submit's render, not
#     just accepted directly; 0/negative/garbage values are rejected before
#     anything is created, for both verbs; combined with --review-loop N,
#     all three preamble renders (not just handoff.md) carry the raised
#     figure; the default still renders when the flag is absent, and its
#     literal matches the pod-side entrypoint's own default; the work
#     emptyDir volume carries no sizeLimit key. The extractor honoring an
#     explicit non-default cap is covered in its own section below.
#   - fork-sandbox-k8s-entrypoint.sh points the bare repo's HEAD at the
#     pushed branch before cloning (so the clone never hits the dangling
#     default HEAD a bare push leaves behind) and no longer uses
#     `checkout -b` (the clone already lands on that branch); a real git
#     bare-repo/push/symbolic-ref/clone sequence confirms the property the
#     fix relies on: no "nonexistent ref" warning, and the clone's HEAD is
#     the pushed branch.
#   - `--context-ro DIR` on both submit and run, under --dry-run: the
#     context-extract.sh ConfigMap key ships unconditionally (like
#     inbox-write.sh), but the `## Gathered context` handoff.md section
#     naming /work/context renders only with the flag; a directory outside
#     /var/tmp/claude-scratch/forks/ and a directory that does not exist
#     are both refused by name before any kubectl call; run --dry-run
#     forwards the flag and renders byte-for-byte the same YAML submit
#     --dry-run does. fork-sandbox-k8s-context-extract.sh's own extraction
#     guards (well-formed, absolute path, `..`, symlink, hard link,
#     over-cap, an existing DEST_DIR) are covered in its own section above,
#     the pod-side half of this same mechanism.
#   - `--checkout REF` on submit and run: the push's source side is no
#     longer hardcoded to HEAD. A resolvable ref renders (exits 0) under
#     --dry-run; an unresolvable one fails with the ref named and the
#     stubbed kubectl's own log still empty (nothing created), under
#     --dry-run and not; a value with a single quote is refused by
#     fs_reject_unsafe_chars before any kubectl call, like every other
#     rejected input; the push refspec carries the resolved sha of the
#     named ref (not HEAD), and the push line reports it; under
#     --review-loop, the BASE_SHA the loop measures against is that same
#     sha; without the flag the refspec and the base are HEAD, exactly as
#     before; and `fork-sandbox.sh --k8s --checkout REF` is no longer
#     refused -- it forwards the flag, and its render matches a direct
#     `run --dry-run --checkout REF` byte-for-byte.
#   - `install --postmaster`: renders and applies manifests/k8s/40-postmaster.yaml
#     alongside the base install, driven against a stubbed kubectl (a real
#     kubectl refuses --context=<fixture-context> even under
#     --dry-run=client, so every case here needs the stub, unlike plain
#     --dry-run elsewhere in this file). Every required key
#     (K8S_POSTMASTER_IMAGE/_REPO_URL/_GIT_KEY_FILE/_KNOWN_HOSTS_FILE)
#     refuses when missing, and a malformed repo URL or project name
#     refuses, all before any kubectl call; storageClassName renders iff
#     K8S_POSTMASTER_STORAGE_CLASS is set; the access mode defaults to
#     ReadWriteOncePod, accepts ReadWriteOnce, and refuses anything else;
#     each of personas/prompts/handlers/presets renders (env, volumeMount,
#     volume, and its own ConfigMap) iff the matching config dir exists,
#     independently, in every combination -- including the mixed ones
#     (some present, some not), which is the case a template-indentation
#     bug in an earlier round of this work broke (a stray comment
#     indentation on the LAST surviving optional block only, fixed in
#     manifests/k8s/40-postmaster.yaml); a subdirectory inside one of
#     those config dirs refuses, naming it; a non-executable file under
#     handlers/ is skipped with a warning, not refused, and does not reach
#     the rendered ConfigMap while its executable sibling does; the total
#     ConfigMap payload is capped at 900 KiB, refusing and naming the
#     biggest file over that; the checksum/pm-config annotation changes
#     when fleet.yaml's content changes; and the git deploy key and known
#     hosts file content never appear in the command's stdout or stderr --
#     only the placeholder "not shown" line does. The plain (non-
#     --postmaster) install stays byte-identical, pinned against a fixture
#     captured before this feature existed.
#   - The client Role in manifests/k8s/10-rbac.yaml and the postmaster Role
#     in manifests/k8s/40-postmaster.yaml grant the same rules (same
#     resource+verb sets, order-independent): both need watch/patch and
#     the services/networkpolicies/secrets resources for submit and rm's
#     label-based cleanup delete, so a kubeconfig bound to the client Role
#     does not fail at cleanup the way the older, narrower client Role did.
#   - K8S_PROXY_ENDPOINTS, the named-keyless-endpoint registry: a legacy
#     K8S_PROXY_UPSTREAM install renders byte-identical to
#     tests/fixtures/k8s-proxy-legacy-install.yaml, a render captured before
#     this feature existed; K8S_PROXY_UPSTREAM and K8S_PROXY_ENDPOINTS set
#     together are refused as mutually exclusive; neither set is still
#     refused with a useful message; N registered endpoints render exactly
#     2N EXACT-match locations (/e/<name>/v1/chat/completions,
#     /e/<name>/v1/models, never a regex or prefix match) alongside the
#     surviving default-deny `location /`; a K8S_PROXY_ENDPOINTS install
#     creates no Secret, references no upstream-key Secret volume or
#     volumeMount on the Deployment, includes no upstream-key.conf, and
#     injects no Authorization header; its rendered nginx.conf passes
#     `nginx -t`, the same check the legacy render gets above; submit
#     --endpoint NAME renders a Job whose PROXY_BASE_URL is the
#     endpoint's /e/NAME/v1 location, an unregistered name and an omitted
#     --endpoint against a multi-endpoint install are both errors listing
#     the registered names, an omitted --endpoint against a single-
#     endpoint install resolves to it (and says so on stderr), and
#     --endpoint against a legacy K8S_PROXY_UPSTREAM install is refused;
#     K8S_DEFAULT_ENDPOINT in k8s.env sits between the flag and the
#     one-candidate rule -- an explicit --endpoint wins over it, a default
#     naming an unregistered endpoint is a parse-time error naming k8s.env
#     and listing the registered names (never a fallthrough), and a default
#     on a legacy K8S_PROXY_UPSTREAM install is refused with the same shape
#     as the --endpoint refusal;
#     --model is optional on an endpoints install (submit accepts it and
#     renders an empty MODEL env) but stays required on a legacy install,
#     and --harness claude keeps the requirement even on an endpoints
#     install; K8S_PROXY_ALLOW
#     replaces the default RFC1918-except egress block with exactly the
#     given <cidr>:<port> entries, and a hostname there is refused with a
#     message naming why (NetworkPolicy has no hostname field); a partial
#     K8S_PROXY_ALLOW (covering some registered endpoints but not others)
#     warns by name about the ones it does not cover; http:// is accepted
#     to a private address and refused to a public one, checked on both
#     the legacy K8S_PROXY_UPSTREAM path and a K8S_PROXY_ENDPOINTS entry,
#     and each of those warns that it is unreachable when K8S_PROXY_ALLOW
#     is unset; an IPv4 octet with a leading zero is never read as octal
#     (nor spews a bash arithmetic error) when classifying an address as
#     private; a duplicate name, a non-RFC1123 name, and an empty base URL
#     in K8S_PROXY_ENDPOINTS are each refused, as is a K8S_PROXY_ALLOW
#     port outside 1-65535, a K8S_PROXY_ALLOW CIDR octet outside 0-255, or
#     a K8S_PROXY_ALLOW prefix outside 0-32 (both refusals quoting the
#     entry as written, even for a leading-zero spelling), and a
#     leading-zero CIDR octet normalizes to canonical decimal in the
#     rendered policy; a 0.0.0.0/0 K8S_PROXY_ALLOW entry stays accepted.
#   - fork-sandbox-k8s-entrypoint.sh's pod-side model discovery
#     (discover_model_facts), driven with curl stubbed on PATH: a
#     single-model /v1/models response resolves MODEL and sets CTX /
#     MAX_TOKENS from max_model_len (agent-sandboxed's rules: a 32768
#     MAX_TOKENS floor capped at a quarter of the window); a multi-model
#     response with no MODEL is an error listing the ids; a context
#     length that would have to be GUESSED -- a MODEL absent from the
#     listing, a failed or unparseable catalog fetch, or a listed entry
#     with no usable max_model_len -- refuses at the single point the
#     guess would be returned, unless ALLOW_UNLISTED_MODEL permits a
#     launch whose context had to be guessed; id comparison is
#     case-insensitive, with the run recording the listing's canonical
#     spelling; REVIEW_MODEL gets the window discovered for its OWN id,
#     not MODEL's -- the --harness claude case where MODEL is a Claude
#     Code model name the listing never contains;
#     and discovery runs in the script BEFORE the repository-receive
#     wait, with no hardcoded contextWindow/maxTokens left in
#     synthesize_pi_config's render. The call itself is gated on the
#     host-set MODEL_DISCOVERY env: a legacy K8S_PROXY_UPSTREAM install
#     (whose proxy forwards only /api/v1/chat/completions, so /models
#     would 403) and a --harness claude run without a --review-loop
#     (no pi leg talks to the proxy, so the run must not hard-depend on
#     the endpoint being up) render no MODEL_DISCOVERY env and the pod
#     keeps the pre-discovery 131072/32768 constants, while an endpoints
#     render for a run that uses the pi proxy carries it. A failed
#     repository push in submit surfaces the pod's container log, since
#     a pod that died in early discovery would otherwise only show
#     git's bare "connection refused".
#   - CLAUDE_CREDENTIALS in claude.env: a --harness claude submit --dry-run
#     reads the named file instead of $HOME/.claude/.credentials.json for
#     both the ConfigMap placeholder and the per-run Secret's access
#     token; a missing named file fails naming that path, not the default;
#     an expired override's error also names the override path, proving
#     fs_claude_credential_source and fs_read_claude_credential are
#     threaded the same override, not just one of the two.
#   - the durable run log (~/.claude/sandbox-runs.jsonl): submit creates a
#     run directory in exactly the shape fork-sandbox.sh's own local run
#     creates, prints its path on a "  run dir:  " line a fan-out caller
#     scrapes the same way, and populates it with run.env, task-meta.json
#     (only with --task-meta) and a copy of the handoff taken AT SUBMIT
#     TIME (editing the original afterward does not change the archive);
#     --dry-run creates no such directory; an invalid --task-meta is
#     refused before anything is created. collect's new --run-dir
#     finalizes that directory -- summary.json carries mode=run,
#     network=cluster, harness/model read back from submit's own run.env,
#     branch, origin_repo, base_sha and exit_code/commits as known at
#     collect, and never a cost_usd/total_cost_usd/usage key (omitted, not
#     zero) -- and calls sandbox-run-log.py record, verified by re-running
#     record against a scratch HOME. Fixture calls themselves use this
#     suite's isolated HOME, which cleanup removes, while their
#     FORK_SANDBOX_RUN_SOURCE=test tag exercises provenance filtering.
#     collect without --run-dir
#     still writes and records nothing, even when a run directory for the
#     branch exists on disk, and a missing sandbox-run-log.py does not
#     fail collect. `run` threads --run-dir from its own submit phase to
#     its own collect phase automatically. fork-sandbox.sh --k8s no longer
#     refuses --task-meta: it forwards the raw value, byte-for-byte
#     identical to a direct `run --dry-run` render, and an invalid value
#     is still refused (now by cmd_submit, forwarded through).
#
# This lives in tests/ rather than scripts/tests/ on purpose: install.sh
# iterates scripts/* and runs `sed -n 2p` on each entry to build the
# Utilities table, and a directory there makes that read fail under `set -e`.

set -uo pipefail

# Keep git fixtures independent of the operator's global and system config.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

repo_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"

# Every run this suite launches is a fixture, not real work. Mark its row so
# sandbox-run-log.py's list/stats exclude it by default. Fixture commands
# that record use the isolated k8s_test_home below, which cleanup removes;
# the tag remains a provenance/filtering assertion rather than protection for
# the operator's durable log.
export FORK_SANDBOX_RUN_SOURCE=test

pass=0; fail=0; tmpdirs=()
# Fixture commands that invoke record must never write prompt archives into
# the operator's durable home. They use this isolated HOME.
k8s_test_operator_home="$HOME"
k8s_test_handoff_archive="$k8s_test_operator_home/.claude/sandbox-handoffs"
k8s_test_home="$(mktemp -d)"; tmpdirs+=("$k8s_test_home")

# Every real (non --dry-run) submit this suite drives now also creates a
# genuine run directory under the forks root -- unlike every other
# artifact this suite creates, that directory is deliberately NOT removed
# by the tool itself (an orchestrator removes it after review, exactly
# like a local run's own run directory), so most call sites below have
# nothing to add to tmpdirs for it. Swept at exit instead: snapshot what is
# already there before any test runs, then remove whatever new
# claude-fork-sandbox.* directory shows up by the time this suite exits --
# a stubbed-kubectl fixture run's own directory is not evidence worth
# keeping on a real machine, and this suite alone drives dozens of real
# submits.
k8s_test_forks_root=/var/tmp/claude-scratch/forks
k8s_test_preexisting_rundirs="$(find "$k8s_test_forks_root" -maxdepth 1 \
    -name 'claude-fork-sandbox.*' 2>/dev/null | sort)"

# Same idea, for the durable run log itself: fixture commands that can call
# record use $k8s_test_home, so snapshot that fixture log and read only its
# rows near the end.
k8s_test_runlog="$k8s_test_home/.claude/sandbox-runs.jsonl"
k8s_test_runlog_before_lines=0
[[ -f "$k8s_test_runlog" ]] && k8s_test_runlog_before_lines="$(wc -l < "$k8s_test_runlog")"

# Every claude-fork-sandbox.* directory under the forks root that this
# suite's own fixtures created, one per line. Ownership, not just novelty:
# a directory that showed up after the pre-suite snapshot is not
# necessarily this suite's own -- a real `fork-sandbox.sh` run started
# concurrently, from the identical mktemp template under the identical
# forks root, looks identical at this point. Only counted when its own
# run-source marker carries this suite's FORK_SANDBOX_RUN_SOURCE=test tag
# (every fixture run this suite drives writes one); a live run's marker,
# if it has one at all, will not read "test". Used both by cleanup()'s
# sweep and by the handoff-archive guard near the end of this file, so
# each recomputes the identical set rather than drifting apart.
k8s_test_owned_rundirs() {
    local d
    find "$k8s_test_forks_root" -maxdepth 1 \
        -name 'claude-fork-sandbox.*' 2>/dev/null | sort | while IFS= read -r d; do
        [[ -z "$d" ]] && continue
        grep -qxF "$d" <<< "$k8s_test_preexisting_rundirs" && continue
        [[ "$(cat "$d/run-source" 2>/dev/null)" == test ]] || continue
        printf '%s\n' "$d"
    done
}

cleanup() {
    local d
    for d in "${tmpdirs[@]-}"; do [[ -n "$d" && -d "$d" ]] && rm -rf -- "$d"; done
    while IFS= read -r d; do
        [[ -z "$d" ]] && continue
        rm -rf -- "$d"
    done < <(k8s_test_owned_rundirs)
}
trap cleanup EXIT
ok() { printf '  ok    %s\n' "$1"; pass=$(( pass + 1 )); }
no() { printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; fail=$(( fail + 1 )); }
check() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then ok "$label"; else no "$label" "expected '$expected', got '$actual'"; fi
}
refuses() {
    local label="$1" needle="$2" out rc; shift 2
    out="$("$@" 2>&1)"; rc=$?
    if (( rc != 0 )) && [[ "$out" == *"$needle"* ]]; then ok "$label"; else no "$label" "status $rc: $out"; fi
}
newdir() { mktemp -d; }

printf '== exit sweep ownership (this suite'"'"'s own cleanup trap) ==\n'
# cleanup()'s exit-time sweep, above, removes a claude-fork-sandbox.*
# directory that showed up after the pre-existing-directories snapshot
# ONLY when that directory's own run-source marker reads exactly "test" --
# not merely because it is new, which a real fork-sandbox.sh run started
# concurrently under the same forks root would also be. Exercised here
# against throwaway directories of our own, never the real forks root, so
# this check cannot itself delete anything live.
sweep_owned_dir="$(newdir)"; tmpdirs+=("$sweep_owned_dir")
printf 'test\n' > "$sweep_owned_dir/run-source"
sweep_foreign_dir="$(newdir)"; tmpdirs+=("$sweep_foreign_dir")
printf 'some-other-source\n' > "$sweep_foreign_dir/run-source"
sweep_bare_dir="$(newdir)"; tmpdirs+=("$sweep_bare_dir")
check "sweep ownership: this suite's own run-source marker reads 'test'" \
    "test" "$(cat "$sweep_owned_dir/run-source" 2>/dev/null)"
if [[ "$(cat "$sweep_foreign_dir/run-source" 2>/dev/null)" != test ]]; then
    ok "sweep ownership: a foreign run-source marker is not this suite's own"
else
    no "sweep ownership: a foreign run-source marker is not this suite's own"
fi
if [[ "$(cat "$sweep_bare_dir/run-source" 2>/dev/null)" != test ]]; then
    ok "sweep ownership: a directory with no run-source marker at all is not this suite's own"
else
    no "sweep ownership: a directory with no run-source marker at all is not this suite's own"
fi

k8s_sh="$repo_dir/scripts/fork-sandbox-k8s.sh"
fs_sh="$repo_dir/scripts/fork-sandbox.sh"
lib_sh="$repo_dir/scripts/fork-sandbox-lib.sh"
platform_generic="$repo_dir/scripts/fork-sandbox-k8s-platform-generic"
entrypoint_sh="$repo_dir/scripts/fork-sandbox-k8s-entrypoint.sh"
gate_sh="$repo_dir/scripts/fork-sandbox-k8s-egress-gate.sh"
inbox_write_sh="$repo_dir/scripts/fork-sandbox-k8s-inbox-write.sh"
review_loop_sh="$repo_dir/scripts/fork-sandbox-k8s-review-loop.sh"
outbox_extract_sh="$repo_dir/scripts/fork-sandbox-k8s-outbox-extract.sh"
context_extract_sh="$repo_dir/scripts/fork-sandbox-k8s-context-extract.sh"

# Sourced directly into this shell, not a subshell: ok()/no() below have to
# reach the pass/fail counters this file reports at the end, and a subshell
# (command substitution, or the read side of a pipe) would trap them there.
# Sourced up here, rather than only where fs_require_scratch_handoff is
# first used further down, because the --review-loop ConfigMap-rendering
# section below also needs fs_emit_prompt_preamble / fs_emit_review_prompt_body
# / fs_emit_fix_prompt_body directly, to compute the byte-for-byte expected
# prompt text.
# shellcheck source-path=SCRIPTDIR/../scripts
# shellcheck source=../scripts/fork-sandbox-lib.sh
# shellcheck disable=SC1091  # plain shellcheck cannot follow it; use -x
source "$lib_sh"

printf '== shellcheck ==\n'
if ! command -v shellcheck >/dev/null 2>&1; then
    printf '  SKIP  shellcheck not installed\n'
else
    for f in "$k8s_sh" "$platform_generic" "$entrypoint_sh" "$gate_sh" "$inbox_write_sh" "$review_loop_sh" "$outbox_extract_sh" "$context_extract_sh"; do
        out="$(shellcheck "$f" 2>&1)"
        if [[ -z "$out" ]]; then ok "shellcheck: $(basename "$f")"; else no "shellcheck: $(basename "$f")" "$out"; fi
    done
fi

printf '\n== yamllint manifests/k8s/ ==\n'
if ! command -v yamllint >/dev/null 2>&1; then
    printf '  SKIP  yamllint not installed\n'
else
    out="$(yamllint "$repo_dir/manifests/k8s" 2>&1)"
    if [[ -z "$out" ]]; then ok "yamllint: manifests/k8s/"; else no "yamllint: manifests/k8s/" "$out"; fi
fi

printf '\n== fork-sandbox-k8s-platform-generic ==\n'
caps="$("$platform_generic" --capabilities)"
check "capabilities: policy" "policy=networkpolicy" "$(grep '^policy=' <<< "$caps")"
check "capabilities: icmp" "icmp=unfiltered" "$(grep '^icmp=' <<< "$caps")"
check "capabilities: dns" "dns=recursive" "$(grep '^dns=' <<< "$caps")"
check "capabilities: runtimeclass" "runtimeclass=none" "$(grep '^runtimeclass=' <<< "$caps")"
check "capabilities: grant" "grant=render-grant" "$(grep '^grant=' <<< "$caps")"

policy="$("$platform_generic" render-policy --namespace fork-sandbox \
    --agent-label app=fork-sandbox-agent --proxy-label app=fork-sandbox-proxy --proxy-port 8080)"
if command -v yamllint >/dev/null 2>&1; then
    out="$(yamllint - <<< "$policy" 2>&1)"
    if [[ -z "$out" ]]; then ok "yamllint: render-policy output"; else no "yamllint: render-policy output" "$out"; fi
fi
if [[ "$policy" == *"port: 443"* ]]; then
    no "agent policy has no rule permitting port 443" "found 'port: 443' in render-policy output"
else
    ok "agent policy has no rule permitting port 443"
fi

# --allow-namespace -- the one option that widens the agent's seal. The
# baseline policy carries exactly one namespaceSelector (kube-system, for
# DNS) and two `ports:` keys (DNS and the proxy), so both are counted rather
# than checked for bare presence.
check "render-policy: baseline has one namespaceSelector" \
    "1" "$(grep -c 'namespaceSelector' <<< "$policy")"
check "render-policy: baseline has two ports: keys" \
    "2" "$(grep -c 'ports:' <<< "$policy")"

policy_ns_port="$("$platform_generic" render-policy --namespace fork-sandbox \
    --agent-label app=fork-sandbox-agent --proxy-label app=fork-sandbox-proxy \
    --proxy-port 8080 --allow-namespace preview-one:8000)"
if command -v yamllint >/dev/null 2>&1; then
    out="$(yamllint - <<< "$policy_ns_port" 2>&1)"
    if [[ -z "$out" ]]; then
        ok "yamllint: render-policy --allow-namespace output"
    else
        no "yamllint: render-policy --allow-namespace output" "$out"
    fi
fi
if grep -qF 'kubernetes.io/metadata.name: preview-one' <<< "$policy_ns_port" \
    && [[ "$(grep -c 'namespaceSelector' <<< "$policy_ns_port")" == 2 ]] \
    && [[ "$(grep -c 'ports:' <<< "$policy_ns_port")" == 3 ]]; then
    ok "--allow-namespace <ns>:<port> adds one namespaceSelector rule with a port"
else
    no "--allow-namespace <ns>:<port> adds one namespaceSelector rule with a port" \
        "$policy_ns_port"
fi

# No port means every port, which NetworkPolicy spells as the ABSENCE of a
# ports: key -- `ports: []` would match nothing at all.
policy_ns_bare="$("$platform_generic" render-policy --namespace fork-sandbox \
    --agent-label app=fork-sandbox-agent --proxy-label app=fork-sandbox-proxy \
    --proxy-port 8080 --allow-namespace preview-two)"
if grep -qF 'kubernetes.io/metadata.name: preview-two' <<< "$policy_ns_bare" \
    && [[ "$(grep -c 'namespaceSelector' <<< "$policy_ns_bare")" == 2 ]] \
    && [[ "$(grep -c 'ports:' <<< "$policy_ns_bare")" == 2 ]]; then
    ok "--allow-namespace <ns> (no port) renders the rule and omits ports: entirely"
else
    no "--allow-namespace <ns> (no port) renders the rule and omits ports: entirely" \
        "$policy_ns_bare"
fi

policy_ns_two="$("$platform_generic" render-policy --namespace fork-sandbox \
    --agent-label app=fork-sandbox-agent --proxy-label app=fork-sandbox-proxy \
    --proxy-port 8080 --allow-namespace preview-one:8000 --allow-namespace preview-two)"
if [[ "$(grep -c 'namespaceSelector' <<< "$policy_ns_two")" == 3 ]]; then
    ok "--allow-namespace is repeatable: two entries render two extra rules"
else
    no "--allow-namespace is repeatable: two entries render two extra rules" \
        "$policy_ns_two"
fi

# Omitting the option must leave the output byte-identical to what every
# existing caller already gets -- this is what makes the widening opt-in
# rather than a change in the sealed default.
#
# Pinned against the literal expected document, NOT against a second
# invocation of the same binary with the same arguments: that would be
# f(x) == f(x), true for any edit to the script and therefore evidence of
# nothing. The baseline has to be written down to be a baseline.
read -r -d '' sealed_baseline <<'SEALED' || true
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: fork-sandbox-agent-egress
  namespace: fork-sandbox
spec:
  podSelector:
    matchLabels:
      app: fork-sandbox-agent
  policyTypes:
    - Ingress
    - Egress
  ingress: []
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
    - to:
        - podSelector:
            matchLabels:
              app: fork-sandbox-proxy
      ports:
        - protocol: TCP
          port: 8080
SEALED
check "render-policy without --allow-namespace matches the sealed baseline" \
    "$sealed_baseline" "$policy"

# A leading-zero port must normalize to canonical decimal, not render as-is
# and not abort in bash arithmetic reading "08" as octal -- the trap
# parse_proxy_allow_ns documents for the identical input.
policy_ns_octal="$("$platform_generic" render-policy --namespace fork-sandbox \
    --agent-label app=fork-sandbox-agent --proxy-label app=fork-sandbox-proxy \
    --proxy-port 8080 --allow-namespace preview-three:08)"
if grep -qE '^ +port: 8$' <<< "$policy_ns_octal" \
    && ! grep -qE '^ +port: 08$' <<< "$policy_ns_octal"; then
    ok "--allow-namespace normalizes a leading-zero port to decimal"
else
    no "--allow-namespace normalizes a leading-zero port to decimal" "$policy_ns_octal"
fi

refuses "--allow-namespace refuses an invalid namespace" \
    "does not name a valid" \
    "$platform_generic" render-policy --namespace fork-sandbox \
    --agent-label app=fork-sandbox-agent --proxy-label app=fork-sandbox-proxy \
    --proxy-port 8080 --allow-namespace Bad_NS
refuses "--allow-namespace refuses a trailing colon with no port" \
    "has a trailing ':'" \
    "$platform_generic" render-policy --namespace fork-sandbox \
    --agent-label app=fork-sandbox-agent --proxy-label app=fork-sandbox-proxy \
    --proxy-port 8080 --allow-namespace preview-one:
refuses "--allow-namespace refuses port 0" \
    "invalid port" \
    "$platform_generic" render-policy --namespace fork-sandbox \
    --agent-label app=fork-sandbox-agent --proxy-label app=fork-sandbox-proxy \
    --proxy-port 8080 --allow-namespace preview-one:0
refuses "--allow-namespace refuses a port above 65535" \
    "invalid port" \
    "$platform_generic" render-policy --namespace fork-sandbox \
    --agent-label app=fork-sandbox-agent --proxy-label app=fork-sandbox-proxy \
    --proxy-port 8080 --allow-namespace preview-one:99999

# render-grant: the per-run widening object. It must never carry
# render-policy's fixed name -- that name is the shared seal, and a
# per-run object reusing it would REPLACE the seal for every other agent
# pod in the namespace (see docs/k8s-platform.md). It also must carry no
# ingress: key and only Egress in policyTypes -- it is purely additive,
# not a second seal.
grant="$("$platform_generic" render-grant --namespace fork-sandbox \
    --name demo-branch-agent-grant --agent-label fork-sandbox/branch=demo-branch \
    --label fork-sandbox.io/run=demo-branch --allow-namespace demo-slot-01:9090)"
if command -v yamllint >/dev/null 2>&1; then
    out="$(yamllint - <<< "$grant" 2>&1)"
    if [[ -z "$out" ]]; then ok "yamllint: render-grant output"; else no "yamllint: render-grant output" "$out"; fi
fi
check "render-grant: metadata.name is the given NAME, never the seal's name" \
    "  name: demo-branch-agent-grant" "$(grep '^  name:' <<< "$grant")"
if grep -qF 'fork-sandbox-agent-egress' <<< "$grant"; then
    no "render-grant output never names the seal's fixed NetworkPolicy name" \
        "found 'fork-sandbox-agent-egress' in: $grant"
else
    ok "render-grant output never names the seal's fixed NetworkPolicy name"
fi
check "render-grant: policyTypes is Egress only" \
    "1" "$(grep -c -- '- Egress' <<< "$grant")"
if grep -q 'Ingress' <<< "$grant"; then
    no "render-grant has no Ingress in policyTypes" "$grant"
else
    ok "render-grant has no Ingress in policyTypes"
fi
if grep -q '^  ingress:' <<< "$grant"; then
    no "render-grant carries no ingress: key at all" "$grant"
else
    ok "render-grant carries no ingress: key at all"
fi
check "render-grant: podSelector matches --agent-label" \
    "      fork-sandbox/branch: demo-branch" "$(grep '^      fork-sandbox/branch:' <<< "$grant")"
check "render-grant: --label lands on metadata.labels" \
    "    fork-sandbox.io/run: demo-branch" "$(grep '^    fork-sandbox.io/run:' <<< "$grant")"
check "render-grant: egress has exactly one namespaceSelector rule" \
    "1" "$(grep -c 'namespaceSelector' <<< "$grant")"
check "render-grant: the namespaced rule names the granted namespace and port" \
    "              kubernetes.io/metadata.name: demo-slot-01" \
    "$(grep '^              kubernetes.io/metadata.name:' <<< "$grant")"

grant_two="$("$platform_generic" render-grant --namespace fork-sandbox \
    --name demo-branch-agent-grant --agent-label fork-sandbox/branch=demo-branch \
    --allow-namespace demo-slot-01:9090 --allow-namespace demo-slot-02)"
check "render-grant: --allow-namespace is repeatable: two entries render two rules" \
    "2" "$(grep -c 'namespaceSelector' <<< "$grant_two")"
if grep -q '^  labels:' <<< "$grant_two"; then
    no "render-grant with no --label omits metadata.labels entirely" "$grant_two"
else
    ok "render-grant with no --label omits metadata.labels entirely"
fi

refuses "render-grant refuses zero --allow-namespace" \
    "at least one --allow-namespace" \
    "$platform_generic" render-grant --namespace fork-sandbox \
    --name demo-branch-agent-grant --agent-label fork-sandbox/branch=demo-branch
refuses "render-grant refuses a missing --name" \
    "Missing: --name" \
    "$platform_generic" render-grant --namespace fork-sandbox \
    --agent-label fork-sandbox/branch=demo-branch --allow-namespace demo-slot-01
refuses "render-grant refuses an invalid namespace, same as render-policy" \
    "does not name a valid" \
    "$platform_generic" render-grant --namespace fork-sandbox \
    --name demo-branch-agent-grant --agent-label fork-sandbox/branch=demo-branch \
    --allow-namespace Bad_NS

# render-policy's output must be byte-for-byte unchanged by the refactor
# that factored the shared allow-namespace rendering out for render-grant
# to reuse -- re-checked here against the same sealed_baseline defined
# above, one more time, right next to the render-grant tests that motivated
# the refactor.
check "render-policy is unchanged by the render-grant refactor" \
    "$sealed_baseline" \
    "$("$platform_generic" render-policy --namespace fork-sandbox \
        --agent-label app=fork-sandbox-agent --proxy-label app=fork-sandbox-proxy --proxy-port 8080)"

printf '\n== fork-sandbox-k8s.sh --dry-run (fixture config, no cluster) ==\n'
config_dir="$(newdir)"; tmpdirs+=("$config_dir")
cat > "$config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_UPSTREAM=https://openrouter.ai
K8S_DENIED_PROBE=10.0.0.1:443
K8S_RUN_TTL=1800
CONF
install -m 600 /dev/null "$config_dir/pi.env"
printf 'OPENROUTER_API_KEY=sk-test-dummy\n' >> "$config_dir/pi.env"
chmod 600 "$config_dir/pi.env"

refuses "unknown platform name fails with a clear error" \
    "cannot find fork-sandbox-k8s-platform-bogus" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" FORK_SANDBOX_K8S_PLATFORM=bogus \
    "$k8s_sh" install --dry-run

proj_dir="$(newdir)"; tmpdirs+=("$proj_dir")
git -C "$proj_dir" init -q
git -C "$proj_dir" config user.email t@fork-sandbox.invalid
git -C "$proj_dir" config user.name Tester
git -C "$proj_dir" commit -q --allow-empty -m init

handoff_file="$(newdir)/handoff.md"; tmpdirs+=("$(dirname "$handoff_file")")
printf 'Do the thing.\n' > "$handoff_file"

install_out="$(newdir)/install.yaml"; tmpdirs+=("$(dirname "$install_out")")
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" install --dry-run > "$install_out" 2>/tmp/fs-k8s-test-install.err; then
    ok "install --dry-run exits 0"
else
    no "install --dry-run exits 0" "$(cat /tmp/fs-k8s-test-install.err)"
fi
if command -v yamllint >/dev/null 2>&1; then
    out="$(yamllint "$install_out" 2>&1)"
    if [[ -z "$out" ]]; then ok "yamllint: install --dry-run output"; else no "yamllint: install --dry-run output" "$out"; fi
    out="$(yamllint - < "$install_out" 2>&1)"
    if [[ -z "$out" ]]; then ok "yamllint: install --dry-run piped through stdin"; else no "yamllint: install --dry-run piped through stdin" "$out"; fi
fi

printf '\n== shared proxy Service and static NetworkPolicy carry the role key ==\n'
# fork-sandbox/role: model-proxy, alongside the pre-existing app:
# fork-sandbox-proxy, on the Deployment's pod template, the Service
# selector and the static NetworkPolicy's podSelector -- three SEPARATE
# objects, since a --harness claude run's per-run proxy Pod also carries
# app: fork-sandbox-proxy (for the platform agent-egress policy) and would
# otherwise be picked up by either the Service (round-robining pi traffic
# into a proxy that 403s it) or the static policy (whose ingress admits
# every agent pod in the namespace, not just one run's own). A bare
# occurrence count of 3 cannot tell "one per object" apart from "three
# copies inside the Deployment's pod template, Service selector and
# NetworkPolicy podSelector left untightened" -- so each object's own
# rendered document is checked individually instead.
extract_doc_by_kind() {
    local kind="$1" file="$2"
    awk -v k="kind: $kind" '
        $0 == k { flag=1 }
        flag && /^---$/ { exit }
        flag { print }
    ' "$file"
}
# extract_doc_by_kind stops at the FIRST document of a kind, which is the
# proxy's for NetworkPolicy -- the agent-egress policy the platform plugin
# renders is a second one in the same stream. This selects a document by
# content instead, so either can be addressed.
extract_doc_matching() {
    local pattern="$1" file="$2"
    awk -v pat="$pattern" '
        /^---$/ { if (doc ~ pat) { printf "%s", doc; exit } doc = ""; next }
        { doc = doc $0 "\n" }
        END { if (doc ~ pat) printf "%s", doc }
    ' "$file"
}
proxy_deployment_doc="$(extract_doc_by_kind Deployment "$install_out")"
proxy_service_doc="$(extract_doc_by_kind Service "$install_out")"
proxy_netpol_doc="$(extract_doc_by_kind NetworkPolicy "$install_out")"
if grep -qF 'fork-sandbox/role: model-proxy' <<< "$proxy_deployment_doc"; then
    ok "the Deployment's pod template carries fork-sandbox/role: model-proxy"
else
    no "the Deployment's pod template carries fork-sandbox/role: model-proxy" \
        "not found in Deployment doc from $install_out"
fi
if grep -qF 'fork-sandbox/role: model-proxy' <<< "$proxy_service_doc"; then
    ok "the Service's own selector carries fork-sandbox/role: model-proxy"
else
    no "the Service's own selector carries fork-sandbox/role: model-proxy" \
        "not found in Service doc from $install_out"
fi
if grep -qF 'fork-sandbox/role: model-proxy' <<< "$proxy_netpol_doc"; then
    ok "the static NetworkPolicy's own podSelector carries fork-sandbox/role: model-proxy"
else
    no "the static NetworkPolicy's own podSelector carries fork-sandbox/role: model-proxy" \
        "not found in NetworkPolicy doc from $install_out"
fi

printf '\n== namespace enforces Pod Security Admission (restricted) ==\n'
if grep -q 'pod-security.kubernetes.io/enforce: restricted' "$install_out"; then
    ok "rendered Namespace enforces PSA restricted"
else
    no "rendered Namespace enforces PSA restricted" "not found in $install_out"
fi
if grep -q 'pod-security.kubernetes.io/warn: restricted' "$install_out" \
    && grep -q 'pod-security.kubernetes.io/audit: restricted' "$install_out"; then
    ok "rendered Namespace holds PSA warn and audit to the same level"
else
    no "rendered Namespace holds PSA warn and audit to the same level" "not found in $install_out"
fi

printf '\n== proxy Deployment rolls when its config changes ==\n'
# A ConfigMap update alone does not restart the pods reading it, so
# fork-sandbox-k8s.sh hashes the rendered nginx.conf into the proxy
# Deployment's POD TEMPLATE annotation -- see the annotation's own comment
# in manifests/k8s/30-proxy.yaml. Confirm the annotation exists, and that it
# actually changes when the config does, by rendering install twice with two
# different K8S_PROXY_UPSTREAM values (the upstream is embedded in
# nginx.conf, so this is a real config change, not a synthetic one).
checksum1="$(sed -n 's/.*checksum\/nginx-conf: "\([0-9a-f]*\)".*/\1/p' "$install_out" | head -n1)"
if [[ -n "$checksum1" ]]; then
    ok "rendered proxy Deployment carries a checksum/nginx-conf annotation"
else
    no "rendered proxy Deployment carries a checksum/nginx-conf annotation" "not found in $install_out"
fi

config_dir2="$(newdir)"; tmpdirs+=("$config_dir2")
cat > "$config_dir2/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_UPSTREAM=https://example.com
K8S_DENIED_PROBE=10.0.0.1:443
K8S_RUN_TTL=1800
CONF
install -m 600 /dev/null "$config_dir2/pi.env"
printf 'OPENROUTER_API_KEY=sk-test-dummy\n' >> "$config_dir2/pi.env"
chmod 600 "$config_dir2/pi.env"
install_out2="$(newdir)/install2.yaml"; tmpdirs+=("$(dirname "$install_out2")")
FORK_SANDBOX_CONFIG_DIR="$config_dir2" "$k8s_sh" install --dry-run > "$install_out2" 2>/tmp/fs-k8s-test-install2.err
checksum2="$(sed -n 's/.*checksum\/nginx-conf: "\([0-9a-f]*\)".*/\1/p' "$install_out2" | head -n1)"
if [[ -n "$checksum1" && -n "$checksum2" && "$checksum1" != "$checksum2" ]]; then
    ok "checksum/nginx-conf annotation changes when the proxy config changes"
else
    no "checksum/nginx-conf annotation changes when the proxy config changes" \
        "checksum1='$checksum1' checksum2='$checksum2' ($(cat /tmp/fs-k8s-test-install2.err 2>/dev/null))"
fi
rm -f /tmp/fs-k8s-test-install2.err

printf '\n== nginx -t on the rendered proxy config ==\n'
# The gap this closes: yamllint proves the manifest is valid YAML, not that
# the string embedded in it is a config nginx will actually start on -- see
# 'manifests/k8s: Fix the two directives nginx refuses to start on'. Extract
# the nginx.conf key exactly as the ConfigMap embeds it (indent_block's
# 4-space block-scalar indent), then run nginx -t against it, either with a
# real nginx or with the image manifests/k8s/30-proxy.yaml itself names.
extract_nginx_conf() {
    awk '
        /^  nginx\.conf: \|$/ { flag=1; next }
        flag && (length($0)==0 || substr($0,1,4)=="    ") { print substr($0,5); next }
        flag { flag=0 }
    ' "$1"
}

nginx_conf="$(extract_nginx_conf "$install_out")"
if [[ -z "$nginx_conf" ]]; then
    no "extracted nginx.conf from install --dry-run output" "no nginx.conf block found in $install_out"
else
    nginx_check_dir="$(newdir)"; tmpdirs+=("$nginx_check_dir")
    # nginx resolves `resolver` AT STARTUP, and
    # kube-dns.kube-system.svc.cluster.local only exists inside a real
    # cluster. An IP literal needs no resolution, so this lets the check run
    # outside a cluster -- in THIS COPY ONLY. manifests/k8s/30-proxy.yaml
    # keeps the real in-cluster name; nothing here writes back to it.
    printf '%s\n' "${nginx_conf//kube-dns.kube-system.svc.cluster.local/127.0.0.1}" \
        > "$nginx_check_dir/nginx.conf"
    # $upstream_key is Secret-mounted in a deployed pod; a throwaway stub
    # stands in at the same path the include names.
    # shellcheck disable=SC2016  # $upstream_key is nginx config, not shell
    printf 'set $upstream_key "dummy";\n' > "$nginx_check_dir/upstream-key.conf"

    proxy_image="$(sed -n 's/^[[:space:]]*image:[[:space:]]*//p' "$repo_dir/manifests/k8s/30-proxy.yaml" | head -n1)"

    nginx_mode=""
    if command -v nginx >/dev/null 2>&1; then
        nginx_mode=native
    elif command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        nginx_mode=docker
    fi

    # Runs `nginx -t` against $1/nginx.conf ($nginx_check_dir when $1 is
    # omitted, the legacy-render caller below), with upstream-key.conf
    # staged at the literal absolute path the include names
    # (/etc/nginx/upstream-key.conf) -- harmless to stage even against a
    # keyless render's config, which never includes it. Prints combined
    # output; returns nginx's exit status.
    run_nginx_t() {
        local check_dir="${1:-$nginx_check_dir}"
        case "$nginx_mode" in
            native)
                # The include and proxy_ssl_trusted_certificate directives
                # are absolute host paths, so testing natively needs the
                # stub staged at the literal path -- which needs root. Fall
                # back to docker rather than fail outright when that is not
                # available.
                if install -Dm644 "$check_dir/upstream-key.conf" \
                        /etc/nginx/upstream-key.conf 2>/dev/null; then
                    local rc
                    nginx -t -c "$check_dir/nginx.conf" 2>&1
                    rc=$?
                    rm -f /etc/nginx/upstream-key.conf
                    return "$rc"
                fi
                if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
                    echo "(cannot stage /etc/nginx/upstream-key.conf without root; falling back to docker)"
                    nginx_mode=docker
                    run_nginx_t "$check_dir"
                    return $?
                fi
                echo "nginx is on PATH but /etc/nginx/upstream-key.conf could not be staged, and no docker fallback is available"
                return 127
                ;;
            docker)
                docker run --rm \
                    -v "$check_dir/nginx.conf:/etc/nginx/nginx.conf:ro" \
                    -v "$check_dir/upstream-key.conf:/etc/nginx/upstream-key.conf:ro" \
                    "$proxy_image" nginx -t 2>&1
                return $?
                ;;
        esac
    }

    if [[ -z "$nginx_mode" ]]; then
        printf '  SKIP  neither nginx nor a working docker on PATH\n'
    else
        out="$(run_nginx_t)"; rc=$?
        if (( rc == 0 )); then
            ok "nginx -t accepts the rendered proxy config"
        else
            no "nginx -t accepts the rendered proxy config" "$out"
        fi
    fi
fi

submit_out="$(newdir)/submit.yaml"; tmpdirs+=("$(dirname "$submit_out")")
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3 \
    "$proj_dir" "$handoff_file" > "$submit_out" 2>/tmp/fs-k8s-test-submit.err; then
    ok "submit --dry-run exits 0"
else
    no "submit --dry-run exits 0" "$(cat /tmp/fs-k8s-test-submit.err)"
fi
if command -v yamllint >/dev/null 2>&1; then
    out="$(yamllint "$submit_out" 2>&1)"
    if [[ -z "$out" ]]; then ok "yamllint: submit --dry-run output"; else no "yamllint: submit --dry-run output" "$out"; fi
    out="$(yamllint - < "$submit_out" 2>&1)"
    if [[ -z "$out" ]]; then ok "yamllint: submit --dry-run piped through stdin"; else no "yamllint: submit --dry-run piped through stdin" "$out"; fi
fi
if grep -q 'automountServiceAccountToken: false' "$submit_out"; then
    ok "rendered Job sets automountServiceAccountToken: false"
else
    no "rendered Job sets automountServiceAccountToken: false" "not found in $submit_out"
fi

printf '\n== submit: --allow-namespace / --reach-probe flag parsing and validation ==\n'
# --reach-probe requires --allow-namespace, and vice versa: a grant the gate
# never exercises is not verified, and a probe with nothing to verify is
# meaningless.
refuses "--reach-probe without --allow-namespace is refused" \
    "--reach-probe requires --allow-namespace" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-ns --model moonshotai/kimi-k3 \
    --reach-probe "svc.demo-slot-01:8000" \
    "$proj_dir" "$handoff_file"
refuses "--allow-namespace without --reach-probe is refused" \
    "--allow-namespace requires at least one --reach-probe" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-ns --model moonshotai/kimi-k3 \
    --allow-namespace "demo-slot-01:8000" \
    "$proj_dir" "$handoff_file"

# A probe targeting a namespace this run did not grant is refused -- a grant
# the gate never exercises is not verified, and a probe for an ungranted
# namespace verifies nothing about THIS run's own grants.
refuses "--reach-probe targeting an ungranted namespace is refused" \
    "not one of this run's --allow-namespace grants" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-ns --model moonshotai/kimi-k3 \
    --allow-namespace "demo-slot-01:8000" \
    --reach-probe "svc.demo-slot-02:8000" \
    "$proj_dir" "$handoff_file"

# A probe whose port disagrees with its namespace's own grant port can never
# pass the gate -- refused at submit instead of failing 60s later for a
# reason submit could have named.
refuses "--reach-probe with a port disagreeing with its namespace's grant is refused" \
    "they must match, or the probe can never pass the gate" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-ns --model moonshotai/kimi-k3 \
    --allow-namespace "demo-slot-01:8000" \
    --reach-probe "svc.demo-slot-01:9000" \
    "$proj_dir" "$handoff_file"

# A namespace granted twice with different ports (both legal: the flag is
# repeatable) must accept a --reach-probe on EITHER granted port, not just
# the first one declared -- checking only the first array entry for that
# namespace would wrongly refuse a probe on the second-declared port even
# though the gate would actually let it through.
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-ns --model moonshotai/kimi-k3 \
    --allow-namespace "demo-slot-01:443" --allow-namespace "demo-slot-01:80" \
    --reach-probe "svc.demo-slot-01:80" \
    "$proj_dir" "$handoff_file" >/dev/null 2>/tmp/fs-k8s-test-ns-dup2nd.err; then
    ok "--reach-probe on the second-declared port of a twice-granted namespace is accepted"
else
    no "--reach-probe on the second-declared port of a twice-granted namespace is accepted" \
        "$(cat /tmp/fs-k8s-test-ns-dup2nd.err)"
fi
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-ns --model moonshotai/kimi-k3 \
    --allow-namespace "demo-slot-01:443" --allow-namespace "demo-slot-01:80" \
    --reach-probe "svc.demo-slot-01:443" \
    "$proj_dir" "$handoff_file" >/dev/null 2>/tmp/fs-k8s-test-ns-dup1st.err; then
    ok "--reach-probe on the first-declared port of a twice-granted namespace is accepted"
else
    no "--reach-probe on the first-declared port of a twice-granted namespace is accepted" \
        "$(cat /tmp/fs-k8s-test-ns-dup1st.err)"
fi
refuses "--reach-probe on neither port of a twice-granted namespace is still refused" \
    "they must match, or the probe can never pass the gate" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-ns --model moonshotai/kimi-k3 \
    --allow-namespace "demo-slot-01:443" --allow-namespace "demo-slot-01:80" \
    --reach-probe "svc.demo-slot-01:22" \
    "$proj_dir" "$handoff_file"

# The three accepted HOST shapes: bare <svc>.<ns>, <svc>.<ns>.svc, and
# <svc>.<ns>.svc.$K8S_CLUSTER_DOMAIN (default cluster.local, unset in
# $config_dir/k8s.env).
for shape_host in "svc.demo-slot-01" "svc.demo-slot-01.svc" "svc.demo-slot-01.svc.cluster.local"; do
    if out="$(FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
        --branch fs-k8s-test-ns --model moonshotai/kimi-k3 \
        --allow-namespace "demo-slot-01:8000" \
        --reach-probe "$shape_host:8000" \
        "$proj_dir" "$handoff_file" 2>&1)"; then
        ok "--reach-probe host shape '$shape_host' is accepted"
    else
        no "--reach-probe host shape '$shape_host' is accepted" "$out"
    fi
done

# A host with no shape marker at all (no dot, or three labels with no .svc
# marker) must be refused -- this is the shape check's own CAUTION case,
# tested directly rather than trusted on inspection.
refuses "--reach-probe host with no dot at all is refused" \
    "<svc>.<ns>, <svc>.<ns>.svc" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-ns --model moonshotai/kimi-k3 \
    --allow-namespace "demo-slot-01:8000" \
    --reach-probe "bareword:8000" \
    "$proj_dir" "$handoff_file"
refuses "--reach-probe host with three labels and no .svc marker is refused" \
    "<svc>.<ns>, <svc>.<ns>.svc" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-ns --model moonshotai/kimi-k3 \
    --allow-namespace "demo-slot-01:8000" \
    --reach-probe "svc.demo-slot-01.extra:8000" \
    "$proj_dir" "$handoff_file"

# A host with an extra label wedged in before the ".svc" marker must not
# slip past the shape check as if it were <svc>.<ns>.svc -- a glob check
# written as "*.*.svc" lets "*" absorb the embedded dot and wrongly accepts
# this, which is exactly the "fails 60s later at the gate instead" failure
# mode --reach-probe exists to catch here. Same trap applies with the
# cluster-domain suffix appended.
refuses "--reach-probe host with an extra label before the .svc marker is refused" \
    "<svc>.<ns>, <svc>.<ns>.svc" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-ns --model moonshotai/kimi-k3 \
    --allow-namespace "demo-slot-01:8000" \
    --reach-probe "svc.demo-slot-01.extra.svc:8000" \
    "$proj_dir" "$handoff_file"
refuses "--reach-probe host with an extra label before .svc.\$K8S_CLUSTER_DOMAIN is refused" \
    "<svc>.<ns>, <svc>.<ns>.svc" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-ns --model moonshotai/kimi-k3 \
    --allow-namespace "demo-slot-01:8000" \
    --reach-probe "svc.demo-slot-01.extra.svc.cluster.local:8000" \
    "$proj_dir" "$handoff_file"

# --allow-namespace with no port (every port/protocol) never triggers the
# port-agreement refusal, whatever port the probe names.
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-ns --model moonshotai/kimi-k3 \
    --allow-namespace "demo-slot-01" \
    --reach-probe "svc.demo-slot-01:1234" \
    "$proj_dir" "$handoff_file" >/dev/null 2>/tmp/fs-k8s-test-ns-noport.err; then
    ok "--allow-namespace with no port accepts a --reach-probe on any port"
else
    no "--allow-namespace with no port accepts a --reach-probe on any port" \
        "$(cat /tmp/fs-k8s-test-ns-noport.err)"
fi

# Both K8S_AGENT_ALLOW_NS (machine-wide) and --allow-namespace (this run
# only) set at once must each announce, distinguishably -- the static key's
# message has no "this run's" wording, the flag's does.
both_submit_ns_config_dir="$(newdir)"; tmpdirs+=("$both_submit_ns_config_dir")
cat > "$both_submit_ns_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_UPSTREAM=https://openrouter.ai
K8S_AGENT_ALLOW_NS=static-slot:9000
K8S_DENIED_PROBE=10.0.0.1:443
CONF
install -m 600 /dev/null "$both_submit_ns_config_dir/pi.env"
printf 'OPENROUTER_API_KEY=sk-test-dummy\n' >> "$both_submit_ns_config_dir/pi.env"
if FORK_SANDBOX_CONFIG_DIR="$both_submit_ns_config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-ns --model moonshotai/kimi-k3 \
    --allow-namespace "demo-slot-01:8000" \
    --reach-probe "svc.demo-slot-01:8000" \
    "$proj_dir" "$handoff_file" >/dev/null 2>/tmp/fs-k8s-test-both-submit-ns.err; then
    ok "submit with both K8S_AGENT_ALLOW_NS and --allow-namespace exits 0"
else
    no "submit with both K8S_AGENT_ALLOW_NS and --allow-namespace exits 0" \
        "$(cat /tmp/fs-k8s-test-both-submit-ns.err)"
fi
if grep -qF "K8S_AGENT_ALLOW_NS opens agent egress to namespace 'static-slot'" \
        /tmp/fs-k8s-test-both-submit-ns.err \
    && grep -qF "this run's --allow-namespace opens agent egress to namespace 'demo-slot-01'" \
        /tmp/fs-k8s-test-both-submit-ns.err; then
    ok "submit announces both the static key's and this run's own --allow-namespace grant"
else
    no "submit announces both the static key's and this run's own --allow-namespace grant" \
        "$(cat /tmp/fs-k8s-test-both-submit-ns.err)"
fi
# The announcements above are just wording -- the handoff also requires the
# per-run grant object itself to carry exactly the flag's namespaces, not
# the static key's, since PROXY_ALLOW_NS_* is a module-global the static-key
# parse and the flag parse both populate and could clobber each other.
both_submit_ns_out="$(FORK_SANDBOX_CONFIG_DIR="$both_submit_ns_config_dir" "$k8s_sh" \
    submit --dry-run \
    --branch fs-k8s-test-ns --model moonshotai/kimi-k3 \
    --allow-namespace "demo-slot-01:8000" \
    --reach-probe "svc.demo-slot-01:8000" \
    "$proj_dir" "$handoff_file")"
if grep -qF 'kubernetes.io/metadata.name: demo-slot-01' <<< "$both_submit_ns_out" \
    && ! grep -qF 'kubernetes.io/metadata.name: static-slot' <<< "$both_submit_ns_out"; then
    ok "the rendered grant NetworkPolicy carries exactly the flag's namespaces, not the static key's"
else
    no "the rendered grant NetworkPolicy carries exactly the flag's namespaces, not the static key's" \
        "$both_submit_ns_out"
fi

printf '\n== submit: per-run grant apply (render-grant, stale-grant refusal, capability gate) ==\n'
# --dry-run renders the grant NetworkPolicy, named <safe_name>-agent-grant,
# ahead of the Job -- the apply order submit itself uses.
grant_dry_out="$(FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-grant --model moonshotai/kimi-k3 \
    --allow-namespace "demo-slot-01:8000" \
    --reach-probe "svc.demo-slot-01:8000" \
    "$proj_dir" "$handoff_file")"
if grep -q '^  name: fork-sandbox-agent-fs-k8s-test-grant-agent-grant$' <<< "$grant_dry_out"; then
    ok "--dry-run renders the grant NetworkPolicy, named <safe_name>-agent-grant"
else
    no "--dry-run renders the grant NetworkPolicy, named <safe_name>-agent-grant" "$grant_dry_out"
fi
grant_line="$(grep -n '^  name: fork-sandbox-agent-fs-k8s-test-grant-agent-grant$' <<< "$grant_dry_out" | cut -d: -f1)"
job_line="$(grep -n '^kind: Job$' <<< "$grant_dry_out" | head -1 | cut -d: -f1)"
if [[ -n "$grant_line" && -n "$job_line" ]] && (( grant_line < job_line )); then
    ok "the grant is rendered before the Job, matching submit's own apply order"
else
    no "the grant is rendered before the Job, matching submit's own apply order" \
        "grant_line=$grant_line job_line=$job_line"
fi
# The grant must select the agent pod by job-name, never by the branch label:
# the per-run claude-proxy Pod (the one holding the real access token) carries
# fork-sandbox/branch too, and never job-name.
grant_doc="$(sed -n '/^  name: fork-sandbox-agent-fs-k8s-test-grant-agent-grant$/,/^---$/p' <<< "$grant_dry_out")"
grant_selector="$(sed -n '/^  podSelector:$/,/^  policyTypes:$/p' <<< "$grant_doc")"
if grep -qx '      job-name: fork-sandbox-agent-fs-k8s-test-grant' <<< "$grant_selector" \
    && ! grep -q 'fork-sandbox/branch' <<< "$grant_selector"; then
    ok "the grant's podSelector is job-name=<safe_name> alone, not the branch label"
else
    no "the grant's podSelector is job-name=<safe_name> alone, not the branch label" "$grant_selector"
fi
proxy_pod_labels="$(sed -n '/^kind: Pod$/,/^spec:$/p' "$repo_dir/manifests/k8s/31-claude-proxy.yaml")"
if [[ -n "$proxy_pod_labels" ]] && ! grep -q 'job-name' <<< "$proxy_pod_labels"; then
    ok "the claude-proxy Pod carries no job-name label, so the grant cannot select it"
else
    no "the claude-proxy Pod carries no job-name label, so the grant cannot select it" "$proxy_pod_labels"
fi

# No --allow-namespace at all: no grant object rendered.
if [[ "$submit_out" != *"agent-grant"* ]]; then
    ok "a run with no --allow-namespace renders no grant object"
else
    no "a run with no --allow-namespace renders no grant object" "$submit_out"
fi

# A platform whose --capabilities omits grant=render-grant is refused
# before any cluster object exists (--dry-run touches nothing, so a refusal
# here proves the check ran ahead of any kubectl call, not merely that it
# ran ahead of the Job).
nogrant_platform_dir="$(newdir)"; tmpdirs+=("$nogrant_platform_dir")
cat > "$nogrant_platform_dir/fork-sandbox-k8s-platform-nogrant" <<'PLATFORM'
#!/usr/bin/env bash
if [[ "${1-}" == --capabilities ]]; then
    cat <<'EOF'
policy=networkpolicy
icmp=unfiltered
dns=recursive
runtimeclass=none
EOF
    exit 0
fi
echo "Error: fork-sandbox-k8s-platform-nogrant stub implements only --capabilities" >&2
exit 1
PLATFORM
chmod +x "$nogrant_platform_dir/fork-sandbox-k8s-platform-nogrant"
nogrant_out="$(PATH="$nogrant_platform_dir:$PATH" FORK_SANDBOX_K8S_PLATFORM=nogrant \
    FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-grant --model moonshotai/kimi-k3 \
    --allow-namespace "demo-slot-01:8000" \
    --reach-probe "svc.demo-slot-01:8000" \
    "$proj_dir" "$handoff_file" 2>&1)"
nogrant_rc=$?
if (( nogrant_rc != 0 )) && [[ "$nogrant_out" == *"'nogrant'"* ]] \
    && [[ "$nogrant_out" == *"grant=render-grant"* ]]; then
    ok "--allow-namespace on a platform without grant=render-grant is refused, naming the platform and the missing capability"
else
    no "--allow-namespace on a platform without grant=render-grant is refused, naming the platform and the missing capability" \
        "status $nogrant_rc: $nogrant_out"
fi
# The same platform, with no --allow-namespace at all, is never asked about
# the grant capability -- confirms the check is gated on --allow-namespace,
# not a blanket new requirement on every submit.
if PATH="$nogrant_platform_dir:$PATH" FORK_SANDBOX_K8S_PLATFORM=nogrant \
    FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-grant --model moonshotai/kimi-k3 \
    "$proj_dir" "$handoff_file" >/dev/null 2>/tmp/fs-k8s-test-nogrant-plain.err; then
    ok "the same platform, with no --allow-namespace, is never asked for the grant capability"
else
    no "the same platform, with no --allow-namespace, is never asked for the grant capability" \
        "$(cat /tmp/fs-k8s-test-nogrant-plain.err)"
fi

# A pre-existing NetworkPolicy named <safe_name>-agent-grant is refused as
# stale, before anything else is created, naming the exact rm command that
# clears it -- a stale grant would otherwise silently widen a new run that
# reuses the branch name. This is NOT a --dry-run invocation: the stale
# check is the one kubectl read submit does before that point, and a
# --dry-run must contact no kubectl at all (see the "no kubectl, no cluster
# reachability check" --dry-run contract this suite's header documents), so
# --dry-run would exit before ever reaching this stub.
stale_stub_dir="$(newdir)"; tmpdirs+=("$stale_stub_dir")
cat > "$stale_stub_dir/kubectl" <<'STUB'
#!/usr/bin/env bash
# fork-sandbox-k8s.sh's own kubectl() wrapper prepends --context=... -n ...
# ahead of the verb, so the verb and resource are found by scanning, not by
# fixed position -- the same technique this suite's other kubectl stubs use.
verb=""; prev=""; name=""
for arg in "$@"; do
    case "$arg" in get) verb=get ;; esac
    [[ "$prev" == networkpolicy ]] && name="$arg"
    prev="$arg"
done
if [[ "$verb" == get && -n "$name" ]]; then
    echo "networkpolicy.networking.k8s.io/$name"
fi
exit 0
STUB
chmod +x "$stale_stub_dir/kubectl"
stale_home="$(newdir)"; tmpdirs+=("$stale_home")
refuses "a pre-existing grant NetworkPolicy is refused as stale, naming the exact rm command" \
    "fork-sandbox-k8s.sh rm --branch fs-k8s-test-stale-grant" \
    env PATH="$stale_stub_dir:$PATH" HOME="$stale_home" FORK_SANDBOX_RUN_SOURCE=test \
    FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit \
    --branch fs-k8s-test-stale-grant --model moonshotai/kimi-k3 \
    --allow-namespace "demo-slot-01:8000" \
    --reach-probe "svc.demo-slot-01:8000" \
    "$proj_dir" "$handoff_file"

# A pi-harness run whose Job apply fails must still remove the grant it
# already applied -- until now, only --harness claude installed any trap
# that deleted cluster objects on failure; a pi run leaked everything,
# including the grant, on any failure past the base context-tar-only trap.
printf '\n== submit: pi-harness Job-apply failure also deletes a previously-applied grant ==\n'
pi_fail_home="$(newdir)"; tmpdirs+=("$pi_fail_home")
pi_fail_name_out="$(newdir)/pi-fail-name.yaml"; tmpdirs+=("$(dirname "$pi_fail_name_out")")
FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-pi-grant-fail --model moonshotai/kimi-k3 --harness pi \
    --allow-namespace "demo-slot-01:8000" --reach-probe "svc.demo-slot-01:8000" \
    "$proj_dir" "$handoff_file" > "$pi_fail_name_out"
pi_fail_safe_name="$(awk '/^kind: Job$/{job=1} job && /^  name:/{print $2; exit}' "$pi_fail_name_out")"
pi_fail_stub_dir="$(newdir)"; tmpdirs+=("$pi_fail_stub_dir")
pi_fail_log="$(newdir)/kubectl.log"; tmpdirs+=("$(dirname "$pi_fail_log")")
cat > "$pi_fail_stub_dir/kubectl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$K8S_STUB_LOG"
verb=""; for arg in "$@"; do case "$arg" in apply|get|delete) verb="$arg" ;; esac; done
case "$verb" in
    apply)
        content="$(cat)"
        if [[ "$content" == *"kind: Job"* ]]; then
            echo "kubectl: stub apply failure for Job" >&2
            exit 1
        fi
        ;;
    get) : ;;
    delete) : ;;
    *) : ;;
esac
STUB
chmod +x "$pi_fail_stub_dir/kubectl"
PATH="$pi_fail_stub_dir:$PATH" K8S_STUB_LOG="$pi_fail_log" HOME="$pi_fail_home" \
    FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit \
    --branch fs-k8s-test-pi-grant-fail --model moonshotai/kimi-k3 --harness pi \
    --allow-namespace "demo-slot-01:8000" --reach-probe "svc.demo-slot-01:8000" \
    "$proj_dir" "$handoff_file" >/tmp/fs-k8s-test-pi-grant-fail.out 2>&1
pi_fail_rc=$?
if (( pi_fail_rc != 0 )); then
    ok "a pi-harness run whose Job apply fails makes submit fail"
else
    no "a pi-harness run whose Job apply fails makes submit fail" "submit unexpectedly succeeded"
fi
if grep -qF "delete job,pod,service,secret,configmap,networkpolicy -l fork-sandbox/branch=$pi_fail_safe_name --ignore-not-found" "$pi_fail_log"; then
    ok "the failure trap deletes the grant (and every other cluster object) for a pi-harness run too"
else
    no "the failure trap deletes the grant (and every other cluster object) for a pi-harness run too" \
        "not found in $pi_fail_log: $(cat "$pi_fail_log")"
fi
rm -f /tmp/fs-k8s-test-pi-grant-fail.out

# The claude harness installs its own, richer failure trap. Once the Job
# has been applied, a failure in a later step (here, the Job's pod Ready
# wait) must remove the Job too -- and the trap's message must no longer
# tell the operator to finish the cleanup by hand.
printf '\n== submit: claude-harness failure after the Job apply also deletes the Job ==\n'
claude_jobfail_home="$(newdir)"; tmpdirs+=("$claude_jobfail_home")
mkdir -p "$claude_jobfail_home/.claude"
claude_jobfail_future_ms=$(( ($(date +%s) + 7200) * 1000 ))
cat > "$claude_jobfail_home/.claude/.credentials.json" <<JSON
{"claudeAiOauth": {"accessToken": "fixture-jobfail-token", "refreshToken": "fixture-refresh-token", "refreshTokenExpiresAt": 123, "expiresAt": $claude_jobfail_future_ms, "scopes": ["user:inference"]}}
JSON
claude_jobfail_name_out="$(newdir)/claude-jobfail-name.yaml"; tmpdirs+=("$(dirname "$claude_jobfail_name_out")")
HOME="$claude_jobfail_home" FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-claude-jobfail --model claude-sonnet-5 --harness claude \
    "$proj_dir" "$handoff_file" > "$claude_jobfail_name_out"
claude_jobfail_safe_name="$(awk '/^kind: Job$/{job=1} job && /^  name:/{print $2; exit}' "$claude_jobfail_name_out")"
claude_jobfail_stub_dir="$(newdir)"; tmpdirs+=("$claude_jobfail_stub_dir")
claude_jobfail_log="$(newdir)/kubectl.log"; tmpdirs+=("$(dirname "$claude_jobfail_log")")
cat > "$claude_jobfail_stub_dir/kubectl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$K8S_STUB_LOG"
verb=""; for arg in "$@"; do case "$arg" in apply|wait|get|delete) verb="$arg" ;; esac; done
case "$verb" in
    apply) cat >/dev/null ;;
    get) printf 'stub-pod\n' ;;
    wait)
        case "$*" in
            *job-name=*) echo "kubectl: stub Ready wait failure" >&2; exit 1 ;;
        esac
        ;;
esac
STUB
chmod +x "$claude_jobfail_stub_dir/kubectl"
PATH="$claude_jobfail_stub_dir:$PATH" K8S_STUB_LOG="$claude_jobfail_log" HOME="$claude_jobfail_home" \
    FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit \
    --branch fs-k8s-test-claude-jobfail --model claude-sonnet-5 --harness claude \
    "$proj_dir" "$handoff_file" >/tmp/fs-k8s-test-claude-jobfail.out 2>&1
claude_jobfail_rc=$?
if (( claude_jobfail_rc != 0 )) && grep -q 'job-name=' "$claude_jobfail_log"; then
    ok "a claude-harness run whose Job pod never becomes Ready makes submit fail"
else
    no "a claude-harness run whose Job pod never becomes Ready makes submit fail" \
        "rc=$claude_jobfail_rc log=$(cat "$claude_jobfail_log")"
fi
if grep -qF "delete job,pod,service,secret,configmap,networkpolicy -l fork-sandbox/branch=$claude_jobfail_safe_name --ignore-not-found" "$claude_jobfail_log"; then
    ok "the claude failure trap deletes the run's Job along with its other cluster objects"
else
    no "the claude failure trap deletes the run's Job along with its other cluster objects" \
        "not found in $claude_jobfail_log: $(cat "$claude_jobfail_log")"
fi
if grep -qF "if a Job for this branch was also created" /tmp/fs-k8s-test-claude-jobfail.out; then
    no "the claude failure trap no longer tells the operator to remove the Job by hand" \
        "$(cat /tmp/fs-k8s-test-claude-jobfail.out)"
else
    ok "the claude failure trap no longer tells the operator to remove the Job by hand"
fi
rm -f /tmp/fs-k8s-test-claude-jobfail.out

# fs_emit_prompt_preamble (fork-sandbox-lib.sh), shared with fork-sandbox.sh's
# local path: the rendered handoff.md must carry the clone-path and
# gated-egress blocks, must carry an "Operator inbox" section naming
# /work/inbox, must NOT claim that directory is read-only (it is not, in a
# pod -- see docs/kubernetes-runs.md), and must still carry the operator's
# own handoff text after the preamble.
if grep -q '/work/clone' "$submit_out"; then
    ok "rendered handoff.md preamble names the pod's clone path"
else
    no "rendered handoff.md preamble names the pod's clone path" "not found in $submit_out"
fi
if grep -q "egress is gated to the model proxy" "$submit_out"; then
    ok "rendered handoff.md preamble includes the gated-egress block"
else
    no "rendered handoff.md preamble includes the gated-egress block" \
        "not found in $submit_out"
fi
if grep -q '## Operator inbox' "$submit_out"; then
    ok "rendered handoff.md includes the operator inbox section"
else
    no "rendered handoff.md includes the operator inbox section" \
        "not found in $submit_out"
fi
if grep -q '/work/inbox' "$submit_out"; then
    ok "rendered handoff.md preamble names the pod's inbox path"
else
    no "rendered handoff.md preamble names the pod's inbox path" "not found in $submit_out"
fi
# The negated form ("not mounted read-only", the pod's honest wording) also
# contains the substring 'mounted read-only', so this checks for the old,
# unqualified claim exactly -- the sentence a local run's rendered preamble
# still carries unchanged.
if grep -qF 'The directory is mounted read-only.' "$submit_out"; then
    no "rendered handoff.md does not claim the pod inbox is read-only" \
        "found the unqualified read-only claim in $submit_out"
else
    ok "rendered handoff.md does not claim the pod inbox is read-only"
fi
if grep -qF 'not mounted read-only' "$submit_out"; then
    ok "rendered handoff.md tells the agent the pod inbox is writable"
else
    no "rendered handoff.md tells the agent the pod inbox is writable" \
        "not found in $submit_out"
fi
if grep -q 'Do the thing.' "$submit_out"; then
    ok "rendered handoff.md still carries the operator's own handoff text"
else
    no "rendered handoff.md still carries the operator's own handoff text" \
        "not found in $submit_out"
fi
rm -f /tmp/fs-k8s-test-install.err /tmp/fs-k8s-test-submit.err

printf '\n== K8S_PROXY_ENDPOINTS: named keyless endpoints ==\n'
# Byte-identical legacy render: the load-bearing backward-compatibility
# guarantee for this whole feature. tests/fixtures/k8s-proxy-legacy-install.yaml
# is a render captured before K8S_PROXY_ENDPOINTS/K8S_PROXY_ALLOW/the
# optional-key/the http-private-address work started, using the exact same
# k8s.env as $config_dir/$install_out above -- an existing
# K8S_PROXY_UPSTREAM install must still render exactly this.
if diff -q "$repo_dir/tests/fixtures/k8s-proxy-legacy-install.yaml" "$install_out" >/dev/null 2>&1; then
    ok "legacy K8S_PROXY_UPSTREAM install renders byte-identical to the pre-change fixture"
else
    no "legacy K8S_PROXY_UPSTREAM install renders byte-identical to the pre-change fixture" \
        "$(diff "$repo_dir/tests/fixtures/k8s-proxy-legacy-install.yaml" "$install_out" 2>&1 | head -20)"
fi

# K8S_PROXY_UPSTREAM and K8S_PROXY_ENDPOINTS are mutually exclusive -- an
# error, never a precedence rule.
both_config_dir="$(newdir)"; tmpdirs+=("$both_config_dir")
cat > "$both_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_UPSTREAM=https://openrouter.ai
K8S_PROXY_ENDPOINTS=primary=http://10.0.0.5:8001/v1
K8S_DENIED_PROBE=10.0.0.1:443
CONF
refuses "K8S_PROXY_UPSTREAM and K8S_PROXY_ENDPOINTS together are refused" \
    "mutually" \
    env FORK_SANDBOX_CONFIG_DIR="$both_config_dir" "$k8s_sh" install --dry-run

# Neither a key (K8S_PROXY_UPSTREAM) nor K8S_PROXY_ENDPOINTS: still a clear
# error, not a silent default.
neither_config_dir="$(newdir)"; tmpdirs+=("$neither_config_dir")
cat > "$neither_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_DENIED_PROBE=10.0.0.1:443
CONF
refuses "install with neither K8S_PROXY_UPSTREAM nor K8S_PROXY_ENDPOINTS errors usefully" \
    "K8S_PROXY_ENDPOINTS" \
    env FORK_SANDBOX_CONFIG_DIR="$neither_config_dir" "$k8s_sh" install --dry-run

# parse_proxy_endpoints' own refusal branches: a name registered twice, a
# name that doesn't match the RFC1123-label shape it becomes a path
# segment from, and an entry with no base URL at all.
dup_name_config_dir="$(newdir)"; tmpdirs+=("$dup_name_config_dir")
cat > "$dup_name_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_ENDPOINTS=primary=http://10.0.0.5:8001/v1,primary=http://10.0.0.6:8001/v1
K8S_DENIED_PROBE=10.0.0.1:443
CONF
refuses "a K8S_PROXY_ENDPOINTS name registered twice is refused" \
    "must be unique" \
    env FORK_SANDBOX_CONFIG_DIR="$dup_name_config_dir" "$k8s_sh" install --dry-run

bad_name_config_dir="$(newdir)"; tmpdirs+=("$bad_name_config_dir")
cat > "$bad_name_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_ENDPOINTS=Primary_1=http://10.0.0.5:8001/v1
K8S_DENIED_PROBE=10.0.0.1:443
CONF
refuses "a K8S_PROXY_ENDPOINTS name that is not RFC1123-label shaped is refused" \
    "is not valid" \
    env FORK_SANDBOX_CONFIG_DIR="$bad_name_config_dir" "$k8s_sh" install --dry-run

empty_url_config_dir="$(newdir)"; tmpdirs+=("$empty_url_config_dir")
cat > "$empty_url_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_ENDPOINTS=primary=
K8S_DENIED_PROBE=10.0.0.1:443
CONF
refuses "a K8S_PROXY_ENDPOINTS entry with an empty base URL is refused" \
    "has an empty" \
    env FORK_SANDBOX_CONFIG_DIR="$empty_url_config_dir" "$k8s_sh" install --dry-run

# parse_proxy_allow's own port-range branch.
bad_port_allow_config_dir="$(newdir)"; tmpdirs+=("$bad_port_allow_config_dir")
cat > "$bad_port_allow_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_ENDPOINTS=primary=http://10.0.0.5:8001/v1
K8S_PROXY_ALLOW=10.0.0.5/32:70000
K8S_DENIED_PROBE=10.0.0.1:443
CONF
refuses "a K8S_PROXY_ALLOW port outside 1-65535 is refused" \
    "must be 1-65535" \
    env FORK_SANDBOX_CONFIG_DIR="$bad_port_allow_config_dir" "$k8s_sh" install --dry-run

# N registered endpoints render exactly 2N EXACT-match locations
# (/e/<name>/v1/chat/completions, /e/<name>/v1/models), never a regex or
# prefix match, and the default-deny location / survives unchanged.
endpoints_config_dir="$(newdir)"; tmpdirs+=("$endpoints_config_dir")
cat > "$endpoints_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_ENDPOINTS=primary=http://10.0.0.5:8001/v1,secondary=http://10.0.0.6:8000/v1
K8S_DENIED_PROBE=10.0.0.1:443
CONF
endpoints_out="$(newdir)/endpoints-install.yaml"; tmpdirs+=("$(dirname "$endpoints_out")")
if FORK_SANDBOX_CONFIG_DIR="$endpoints_config_dir" "$k8s_sh" install --dry-run \
    > "$endpoints_out" 2>/tmp/fs-k8s-test-endpoints-install.err; then
    ok "K8S_PROXY_ENDPOINTS install --dry-run exits 0"
else
    no "K8S_PROXY_ENDPOINTS install --dry-run exits 0" "$(cat /tmp/fs-k8s-test-endpoints-install.err)"
fi

# submit --endpoint wires the run to the named endpoint's /e/<name>/v1
# location instead of the legacy /api/v1 path -- the wiring the old
# "submit refuses endpoints installs" refusal stood in for, now proven
# by rendering.
ep_submit_out="$(newdir)/ep-submit.yaml"; tmpdirs+=("$(dirname "$ep_submit_out")")
if FORK_SANDBOX_CONFIG_DIR="$endpoints_config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3 --endpoint secondary \
    "$proj_dir" "$handoff_file" > "$ep_submit_out" 2>/tmp/fs-k8s-test-ep-submit.err; then
    ok "submit --dry-run --endpoint against a K8S_PROXY_ENDPOINTS namespace exits 0"
else
    no "submit --dry-run --endpoint against a K8S_PROXY_ENDPOINTS namespace exits 0" \
        "$(cat /tmp/fs-k8s-test-ep-submit.err)"
fi
if grep -qF 'value: "http://fork-sandbox-proxy.fork-sandbox-test.svc.cluster.local:8080/e/secondary/v1"' "$ep_submit_out" \
    && ! grep -qF 'value: "http://fork-sandbox-proxy.fork-sandbox-test.svc.cluster.local:8080/api/v1"' "$ep_submit_out"; then
    ok "submit --endpoint renders PROXY_BASE_URL at the endpoint's /e/<name>/v1"
else
    no "submit --endpoint renders PROXY_BASE_URL at the endpoint's /e/<name>/v1" \
        "$(grep -A1 'name: PROXY_BASE_URL' "$ep_submit_out")"
fi

# An unregistered name is an error listing the registered ones.
refuses "submit --endpoint with an unregistered name errors listing the registered ones" \
    "--endpoint 'bogus' is not registered" \
    env FORK_SANDBOX_CONFIG_DIR="$endpoints_config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3 --endpoint bogus \
    "$proj_dir" "$handoff_file"
unreg_out="$(FORK_SANDBOX_CONFIG_DIR="$endpoints_config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3 --endpoint bogus \
    "$proj_dir" "$handoff_file" 2>&1 >/dev/null || true)"
if [[ "$unreg_out" == *primary* && "$unreg_out" == *secondary* ]]; then
    ok "the unregistered --endpoint error lists the registered names"
else
    no "the unregistered --endpoint error lists the registered names" "$unreg_out"
fi

# An omitted --endpoint against a multi-endpoint install is an error
# listing the names (the one-candidate rule, mirrored from
# agent-sandboxed's model resolution).
refuses "submit with no --endpoint against a multi-endpoint install errors" \
    "more than one endpoint" \
    env FORK_SANDBOX_CONFIG_DIR="$endpoints_config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3 "$proj_dir" "$handoff_file"
multi_out="$(FORK_SANDBOX_CONFIG_DIR="$endpoints_config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3 \
    "$proj_dir" "$handoff_file" 2>&1 >/dev/null || true)"
if [[ "$multi_out" == *primary* && "$multi_out" == *secondary* ]]; then
    ok "the multi-endpoint no-\`--endpoint\` error lists the registered names"
else
    no "the multi-endpoint no-\`--endpoint\` error lists the registered names" "$multi_out"
fi

# K8S_DEFAULT_ENDPOINT in k8s.env is the site's preferred named
# endpoint. Precedence: an explicit --endpoint, then the default, then
# the one-candidate rule, then the error listing the names.
default_ep_config_dir="$(newdir)"; tmpdirs+=("$default_ep_config_dir")
cat > "$default_ep_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_ENDPOINTS=primary=http://10.0.0.5:8001/v1,secondary=http://10.0.0.6:8000/v1
K8S_DEFAULT_ENDPOINT=secondary
K8S_DENIED_PROBE=10.0.0.1:443
CONF

# An explicit --endpoint wins over K8S_DEFAULT_ENDPOINT.
def_flag_out="$(newdir)/def-flag-submit.yaml"; tmpdirs+=("$(dirname "$def_flag_out")")
def_flag_err="$(newdir)/def-flag-submit.err"; tmpdirs+=("$(dirname "$def_flag_err")")
if FORK_SANDBOX_CONFIG_DIR="$default_ep_config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3 --endpoint primary \
    "$proj_dir" "$handoff_file" > "$def_flag_out" 2>"$def_flag_err"; then
    ok "submit --endpoint wins over K8S_DEFAULT_ENDPOINT and exits 0"
else
    no "submit --endpoint wins over K8S_DEFAULT_ENDPOINT and exits 0" \
        "$(cat "$def_flag_err")"
fi
if grep -qF 'value: "http://fork-sandbox-proxy.fork-sandbox-test.svc.cluster.local:8080/e/primary/v1"' "$def_flag_out" \
    && ! grep -qF '/e/secondary/v1' "$def_flag_out"; then
    ok "the --endpoint-over-default render is wired to the flagged endpoint"
else
    no "the --endpoint-over-default render is wired to the flagged endpoint" \
        "$(grep -A1 'name: PROXY_BASE_URL' "$def_flag_out")"
fi

# No flag, several registered: the default is used and announced.
def_default_out="$(newdir)/def-default-submit.yaml"; tmpdirs+=("$(dirname "$def_default_out")")
def_default_err="$(newdir)/def-default-submit.err"; tmpdirs+=("$(dirname "$def_default_err")")
if FORK_SANDBOX_CONFIG_DIR="$default_ep_config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3 \
    "$proj_dir" "$handoff_file" > "$def_default_out" 2>"$def_default_err"; then
    ok "submit with no --endpoint uses K8S_DEFAULT_ENDPOINT against a multi-endpoint install"
else
    no "submit with no --endpoint uses K8S_DEFAULT_ENDPOINT against a multi-endpoint install" \
        "$(cat "$def_default_err")"
fi
if grep -qF 'value: "http://fork-sandbox-proxy.fork-sandbox-test.svc.cluster.local:8080/e/secondary/v1"' "$def_default_out"; then
    ok "the K8S_DEFAULT_ENDPOINT resolution renders that endpoint's /e/<name>/v1"
else
    no "the K8S_DEFAULT_ENDPOINT resolution renders that endpoint's /e/<name>/v1" \
        "$(grep -A1 'name: PROXY_BASE_URL' "$def_default_out")"
fi
if grep -q 'K8S_DEFAULT_ENDPOINT' "$def_default_err" && grep -q "'secondary'" "$def_default_err"; then
    ok "the K8S_DEFAULT_ENDPOINT resolution announces itself on stderr"
else
    no "the K8S_DEFAULT_ENDPOINT resolution announces itself on stderr" \
        "$(cat "$def_default_err")"
fi

# A default naming an unregistered endpoint is a parse-time error that
# names k8s.env (the command line never mentions the bad name) and lists
# the registered names -- never a fallthrough to the one-candidate rule.
bad_default_config_dir="$(newdir)"; tmpdirs+=("$bad_default_config_dir")
sed 's/^K8S_DEFAULT_ENDPOINT=.*/K8S_DEFAULT_ENDPOINT=bogus/' \
    "$default_ep_config_dir/k8s.env" > "$bad_default_config_dir/k8s.env"
refuses "submit with an unregistered K8S_DEFAULT_ENDPOINT errors" \
    "K8S_DEFAULT_ENDPOINT 'bogus'" \
    env FORK_SANDBOX_CONFIG_DIR="$bad_default_config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3 \
    "$proj_dir" "$handoff_file"
bad_default_out="$(FORK_SANDBOX_CONFIG_DIR="$bad_default_config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3 \
    "$proj_dir" "$handoff_file" 2>&1 >/dev/null || true)"
if [[ "$bad_default_out" == *k8s.env* && "$bad_default_out" == *"is not registered"* \
    && "$bad_default_out" == *primary* && "$bad_default_out" == *secondary* ]]; then
    ok "the unregistered K8S_DEFAULT_ENDPOINT error names k8s.env and the registered names"
else
    no "the unregistered K8S_DEFAULT_ENDPOINT error names k8s.env and the registered names" "$bad_default_out"
fi

# A default on a legacy K8S_PROXY_UPSTREAM install is a config error, not
# something to ignore -- the same shape as the --endpoint refusal.
legacy_default_config_dir="$(newdir)"; tmpdirs+=("$legacy_default_config_dir")
sed 's/^K8S_PROXY_ENDPOINTS=.*/K8S_PROXY_UPSTREAM=https:\/\/openrouter.ai/' \
    "$default_ep_config_dir/k8s.env" > "$legacy_default_config_dir/k8s.env"
refuses "K8S_DEFAULT_ENDPOINT on a legacy K8S_PROXY_UPSTREAM install errors" \
    "K8S_DEFAULT_ENDPOINT is not available" \
    env FORK_SANDBOX_CONFIG_DIR="$legacy_default_config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3 \
    "$proj_dir" "$handoff_file"

# ...and against a single-endpoint install it resolves to the one
# endpoint, says so on stderr, and renders that endpoint's location.
single_ep_config_dir="$(newdir)"; tmpdirs+=("$single_ep_config_dir")
cat > "$single_ep_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_ENDPOINTS=primary=http://10.0.0.5:8001/v1
K8S_DENIED_PROBE=10.0.0.1:443
CONF
single_ep_submit_out="$(newdir)/single-ep-submit.yaml"; tmpdirs+=("$(dirname "$single_ep_submit_out")")
single_ep_submit_err="$(newdir)/single-ep-submit.err"; tmpdirs+=("$(dirname "$single_ep_submit_err")")
if FORK_SANDBOX_CONFIG_DIR="$single_ep_config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3 \
    "$proj_dir" "$handoff_file" > "$single_ep_submit_out" 2>"$single_ep_submit_err"; then
    ok "submit with no --endpoint against a single-endpoint install exits 0"
else
    no "submit with no --endpoint against a single-endpoint install exits 0" \
        "$(cat "$single_ep_submit_err")"
fi
if grep -q 'using the single' "$single_ep_submit_err" \
    && grep -q "'primary'" "$single_ep_submit_err"; then
    ok "the single-endpoint resolution announces itself on stderr"
else
    no "the single-endpoint resolution announces itself on stderr" \
        "$(cat "$single_ep_submit_err")"
fi
if grep -qF 'value: "http://fork-sandbox-proxy.fork-sandbox-test.svc.cluster.local:8080/e/primary/v1"' "$single_ep_submit_out"; then
    ok "the single-endpoint resolution renders that endpoint's /e/<name>/v1"
else
    no "the single-endpoint resolution renders that endpoint's /e/<name>/v1" \
        "$(grep -A1 'name: PROXY_BASE_URL' "$single_ep_submit_out")"
fi

# --model is optional on an endpoints install: accepted, and the rendered
# Job carries an empty MODEL env (the pod will discover it).
no_model_submit_out="$(newdir)/no-model-submit.yaml"; tmpdirs+=("$(dirname "$no_model_submit_out")")
no_model_err="$(FORK_SANDBOX_CONFIG_DIR="$single_ep_config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch "$proj_dir" "$handoff_file" 2>&1 >/dev/null || true)"
if FORK_SANDBOX_CONFIG_DIR="$single_ep_config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch "$proj_dir" "$handoff_file" \
    > "$no_model_submit_out" 2>/dev/null; then
    ok "submit without --model on an endpoints install is accepted"
else
    no "submit without --model on an endpoints install is accepted" "$no_model_err"
fi
model_env="$(grep -A1 'name: MODEL$' "$no_model_submit_out" | tail -n1)"
check "the no-\`--model\` endpoints render carries an empty MODEL env" \
    '              value: ""' "$model_env"
# ...but stays required on a legacy install, with the same error text.
refuses "submit without --model on a legacy install is still refused" \
    "submit requires --model. There is no default:" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch "$proj_dir" "$handoff_file"
# ...and --harness claude keeps the requirement even on an endpoints
# install: discovery lists the pi endpoint's model ids, never a Claude
# Code model name.
refuses "submit --harness claude without --model on an endpoints install is refused" \
    "not Claude Code model" \
    env FORK_SANDBOX_CONFIG_DIR="$single_ep_config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --harness claude "$proj_dir" "$handoff_file"

# == K8S_DEFAULT_MODEL -- a default model for a run with no --model ==
# Precedence: --model, then K8S_DEFAULT_MODEL, then the pod's own
# single-candidate discovery rule, mirroring K8S_DEFAULT_ENDPOINT one
# layer up.
default_model_config_dir="$(newdir)"; tmpdirs+=("$default_model_config_dir")
cat > "$default_model_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_ENDPOINTS=primary=http://10.0.0.5:8001/v1
K8S_DEFAULT_MODEL=qwen3-8b
K8S_DENIED_PROBE=10.0.0.1:443
CONF

# An explicit --model wins over K8S_DEFAULT_MODEL.
def_model_flag_out="$(newdir)/def-model-flag-submit.yaml"; tmpdirs+=("$(dirname "$def_model_flag_out")")
if FORK_SANDBOX_CONFIG_DIR="$default_model_config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3 \
    "$proj_dir" "$handoff_file" > "$def_model_flag_out" 2>/dev/null; then
    ok "submit --model wins over K8S_DEFAULT_MODEL and exits 0"
else
    no "submit --model wins over K8S_DEFAULT_MODEL and exits 0" "(see rendered output)"
fi
model_env="$(grep -A1 'name: MODEL$' "$def_model_flag_out" | tail -n1)"
check "the --model-over-default render carries the flagged model" \
    '              value: "moonshotai/kimi-k3"' "$model_env"

# No --model: K8S_DEFAULT_MODEL is used and announced on stderr.
def_model_default_out="$(newdir)/def-model-default-submit.yaml"; tmpdirs+=("$(dirname "$def_model_default_out")")
def_model_default_err="$(newdir)/def-model-default-submit.err"; tmpdirs+=("$(dirname "$def_model_default_err")")
if FORK_SANDBOX_CONFIG_DIR="$default_model_config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch \
    "$proj_dir" "$handoff_file" > "$def_model_default_out" 2>"$def_model_default_err"; then
    ok "submit with no --model uses K8S_DEFAULT_MODEL against an endpoints install"
else
    no "submit with no --model uses K8S_DEFAULT_MODEL against an endpoints install" \
        "$(cat "$def_model_default_err")"
fi
model_env="$(grep -A1 'name: MODEL$' "$def_model_default_out" | tail -n1)"
check "the K8S_DEFAULT_MODEL resolution renders that model into MODEL" \
    '              value: "qwen3-8b"' "$model_env"
if grep -q 'K8S_DEFAULT_MODEL' "$def_model_default_err" && grep -q "'qwen3-8b'" "$def_model_default_err"; then
    ok "the K8S_DEFAULT_MODEL resolution announces itself on stderr"
else
    no "the K8S_DEFAULT_MODEL resolution announces itself on stderr" \
        "$(cat "$def_model_default_err")"
fi

# --harness claude still requires --model even with K8S_DEFAULT_MODEL set:
# discovery lists the pi endpoint's model ids, never a Claude Code model
# name, so the claude-harness branch must be checked before the default
# falls in.
refuses "submit --harness claude with K8S_DEFAULT_MODEL set still requires --model" \
    "not Claude Code model" \
    env FORK_SANDBOX_CONFIG_DIR="$default_model_config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --harness claude "$proj_dir" "$handoff_file"

# Unset K8S_DEFAULT_MODEL + no --model: MODEL stays empty (no regression --
# already covered above by "the no-`--model` endpoints render carries an
# empty MODEL env" against single_ep_config_dir, which sets no
# K8S_DEFAULT_MODEL; named here so the pair reads together).

# K8S_DEFAULT_MODEL on a legacy K8S_PROXY_UPSTREAM install: there is no
# model discovery for it to stand in for, so it must be refused explicitly
# -- like K8S_DEFAULT_ENDPOINT is on the same kind of install -- rather
# than silently ignored and then flatly denied by the generic "there is no
# default" message, which would contradict the operator's own k8s.env.
legacy_default_model_config_dir="$(newdir)"; tmpdirs+=("$legacy_default_model_config_dir")
cat > "$legacy_default_model_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_UPSTREAM=https://openrouter.ai
K8S_DEFAULT_MODEL=qwen3-8b
K8S_DENIED_PROBE=10.0.0.1:443
CONF
refuses "submit: K8S_DEFAULT_MODEL on a legacy K8S_PROXY_UPSTREAM install is refused" \
    "K8S_DEFAULT_MODEL is not available" \
    env FORK_SANDBOX_CONFIG_DIR="$legacy_default_model_config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch "$proj_dir" "$handoff_file"
refuses "run: K8S_DEFAULT_MODEL on a legacy K8S_PROXY_UPSTREAM install is refused" \
    "K8S_DEFAULT_MODEL is not available" \
    env FORK_SANDBOX_CONFIG_DIR="$legacy_default_model_config_dir" "$k8s_sh" run --dry-run \
    --branch fs-k8s-test-branch "$proj_dir" "$handoff_file"
# --model still works on that same install -- the refusal above is about
# the unset --model + set K8S_DEFAULT_MODEL combination specifically, not
# about K8S_DEFAULT_MODEL merely being present in k8s.env.
if FORK_SANDBOX_CONFIG_DIR="$legacy_default_model_config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3 \
    "$proj_dir" "$handoff_file" > /dev/null 2>/dev/null; then
    ok "submit --model still works on a legacy install with K8S_DEFAULT_MODEL set"
else
    no "submit --model still works on a legacy install with K8S_DEFAULT_MODEL set" \
        "(see rendered output)"
fi

# == K8S_ALLOW_UNLISTED_MODEL -- the escape hatch from the pod's unlisted-
# == model refusal. Only 1 is accepted; set to 1 it renders the pod's
# ALLOW_UNLISTED_MODEL env, unset it renders nothing so the pod-side
# default stays refuse.
allow_model_config_dir="$(newdir)"; tmpdirs+=("$allow_model_config_dir")
cat > "$allow_model_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_ENDPOINTS=primary=http://10.0.0.5:8001/v1
K8S_DEFAULT_MODEL=qwen3-8b
K8S_ALLOW_UNLISTED_MODEL=1
K8S_DENIED_PROBE=10.0.0.1:443
CONF
allow_model_submit_out="$(newdir)/allow-model-submit.yaml"; tmpdirs+=("$(dirname "$allow_model_submit_out")")
if FORK_SANDBOX_CONFIG_DIR="$allow_model_config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch \
    "$proj_dir" "$handoff_file" > "$allow_model_submit_out" 2>/dev/null; then
    ok "submit with K8S_ALLOW_UNLISTED_MODEL=1 exits 0"
else
    no "submit with K8S_ALLOW_UNLISTED_MODEL=1 exits 0" "(see rendered output)"
fi
if [[ "$(grep -cF -- '- name: ALLOW_UNLISTED_MODEL' "$allow_model_submit_out")" == 1 ]] \
    && grep -A1 -F -- '- name: ALLOW_UNLISTED_MODEL' "$allow_model_submit_out" | grep -qF 'value: "1"'; then
    ok "a K8S_ALLOW_UNLISTED_MODEL=1 render carries the ALLOW_UNLISTED_MODEL=1 env"
else
    no "a K8S_ALLOW_UNLISTED_MODEL=1 render carries the ALLOW_UNLISTED_MODEL=1 env" \
        "$(grep -A1 'name: ALLOW_UNLISTED_MODEL' "$allow_model_submit_out")"
fi
# Unset: the render carries no ALLOW_UNLISTED_MODEL env at all (the pod's
# default is refuse; nothing in k8s.env opts out of it by omission).
if [[ "$(grep -cF -- '- name: ALLOW_UNLISTED_MODEL' "$no_model_submit_out")" == 0 ]]; then
    ok "a render without K8S_ALLOW_UNLISTED_MODEL carries no ALLOW_UNLISTED_MODEL env"
else
    no "a render without K8S_ALLOW_UNLISTED_MODEL carries no ALLOW_UNLISTED_MODEL env" \
        "found it in the single-endpoint render"
fi
# Anything other than 1 (or unset) is a parse-time error naming the key.
allow_bad_config_dir="$(newdir)"; tmpdirs+=("$allow_bad_config_dir")
cp "$allow_model_config_dir/k8s.env" "$allow_bad_config_dir/k8s.env"
sed -i 's/^K8S_ALLOW_UNLISTED_MODEL=1$/K8S_ALLOW_UNLISTED_MODEL=2/' "$allow_bad_config_dir/k8s.env"
refuses "submit with K8S_ALLOW_UNLISTED_MODEL=2 is refused" \
    "K8S_ALLOW_UNLISTED_MODEL" \
    env FORK_SANDBOX_CONFIG_DIR="$allow_bad_config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch "$proj_dir" "$handoff_file"

# --endpoint against a legacy K8S_PROXY_UPSTREAM install is an error.
refuses "submit --endpoint against a legacy K8S_PROXY_UPSTREAM install errors" \
    "K8S_PROXY_UPSTREAM; there are no named" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3 --endpoint primary \
    "$proj_dir" "$handoff_file"
# And the legacy render keeps the /api/v1 literal, untouched by all of
# the above (already asserted by the byte-identical fixture render and
# the submit_out checks above; named here so the pair reads together).
if grep -qF 'value: "http://fork-sandbox-proxy.fork-sandbox-test.svc.cluster.local:8080/api/v1"' "$submit_out"; then
    ok "a legacy install's rendered PROXY_BASE_URL is still the /api/v1 literal"
else
    no "a legacy install's rendered PROXY_BASE_URL is still the /api/v1 literal" \
        "$(grep -A1 'name: PROXY_BASE_URL' "$submit_out")"
fi
# ...and the legacy render carries no MODEL_DISCOVERY env at all: that
# proxy forwards only /api/v1/chat/completions, so the pod-side discovery
# probe would 403 and die the pod before the repository push. (The needle
# is the YAML env line itself, which the entrypoint's own prose never
# spells.)
model_discovery_count="$(grep -cF -- '- name: MODEL_DISCOVERY' "$submit_out")"
if [[ "$model_discovery_count" == 0 ]]; then
    ok "a legacy install's rendered Job carries no MODEL_DISCOVERY env"
else
    no "a legacy install's rendered Job carries no MODEL_DISCOVERY env" \
        "found $model_discovery_count in the legacy submit render"
fi
if [[ "$(grep -cF -- '- name: MODEL_DISCOVERY' "$no_model_submit_out")" == 1 ]] \
    && grep -A1 -F -- '- name: MODEL_DISCOVERY' "$no_model_submit_out" | grep -qF 'value: "1"'; then
    ok "an endpoints install's rendered Job carries MODEL_DISCOVERY=1"
else
    no "an endpoints install's rendered Job carries MODEL_DISCOVERY=1" \
        "$(grep -A1 -F -- '- name: MODEL_DISCOVERY' "$no_model_submit_out")"
fi
# A --harness claude run on an endpoints install WITHOUT a --review-loop
# never talks to the pi proxy (its leg uses CLAUDE_PROXY_BASE_URL), so
# the render carries no MODEL_DISCOVERY env: the run must not die at pod
# start just because a workstation-class endpoint is down. WITH a
# --review-loop the loop runs pi, so the env is back.
claude_gate_home="$(newdir)"; tmpdirs+=("$claude_gate_home")
mkdir -p "$claude_gate_home/.claude"
claude_gate_future_ms=$(( ($(date +%s) + 7200) * 1000 ))
cat > "$claude_gate_home/.claude/.credentials.json" <<JSON
{"claudeAiOauth": {"accessToken": "fixture-gate-token", "refreshToken": "fixture-refresh-token", "refreshTokenExpiresAt": 123, "expiresAt": $claude_gate_future_ms, "scopes": ["user:inference"]}}
JSON
claude_gate_out="$(newdir)/claude-gate.yaml"; tmpdirs+=("$(dirname "$claude_gate_out")")
if HOME="$claude_gate_home" FORK_SANDBOX_CONFIG_DIR="$single_ep_config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model claude-opus-5 --harness claude \
    "$proj_dir" "$handoff_file" > "$claude_gate_out" 2>/dev/null; then
    ok "submit --dry-run --harness claude on an endpoints install exits 0"
else
    no "submit --dry-run --harness claude on an endpoints install exits 0" \
        "$(HOME="$claude_gate_home" FORK_SANDBOX_CONFIG_DIR="$single_ep_config_dir" "$k8s_sh" submit --dry-run \
            --branch fs-k8s-test-branch --model claude-opus-5 --harness claude \
            "$proj_dir" "$handoff_file" 2>&1)"
fi
if [[ "$(grep -cF -- '- name: MODEL_DISCOVERY' "$claude_gate_out")" == 0 ]]; then
    ok "a claude run without a review loop carries no MODEL_DISCOVERY env"
else
    no "a claude run without a review loop carries no MODEL_DISCOVERY env" \
        "found MODEL_DISCOVERY in the claude render: $(grep -A1 -F -- '- name: MODEL_DISCOVERY' "$claude_gate_out")"
fi
claude_gate_loop_out="$(newdir)/claude-gate-loop.yaml"; tmpdirs+=("$(dirname "$claude_gate_loop_out")")
if HOME="$claude_gate_home" FORK_SANDBOX_CONFIG_DIR="$single_ep_config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model claude-opus-5 --harness claude \
    --review-loop 1 --review-model qwen3-8b \
    "$proj_dir" "$handoff_file" > "$claude_gate_loop_out" 2>/dev/null; then
    ok "submit --dry-run --harness claude --review-loop on an endpoints install exits 0"
else
    no "submit --dry-run --harness claude --review-loop on an endpoints install exits 0" \
        "$(HOME="$claude_gate_home" FORK_SANDBOX_CONFIG_DIR="$single_ep_config_dir" "$k8s_sh" submit --dry-run \
            --branch fs-k8s-test-branch --model claude-opus-5 --harness claude \
            --review-loop 1 --review-model qwen3-8b \
            "$proj_dir" "$handoff_file" 2>&1)"
fi
if [[ "$(grep -cF -- '- name: MODEL_DISCOVERY' "$claude_gate_loop_out")" == 1 ]] \
    && grep -A1 -F -- '- name: MODEL_DISCOVERY' "$claude_gate_loop_out" | grep -qF 'value: "1"'; then
    ok "a claude run with a --review-loop carries MODEL_DISCOVERY=1 (the loop runs pi)"
else
    no "a claude run with a --review-loop carries MODEL_DISCOVERY=1 (the loop runs pi)" \
        "$(grep -A1 -F -- '- name: MODEL_DISCOVERY' "$claude_gate_loop_out")"
fi

# run forwards --endpoint (and the omitted --model) to submit rather than
# growing its own copy of either: the same arguments must render
# byte-for-byte the same YAML as the direct submit call.
ep_run_out="$(newdir)/ep-run.yaml"; tmpdirs+=("$(dirname "$ep_run_out")")
ep_run_err="$(newdir)/ep-run.err"; tmpdirs+=("$(dirname "$ep_run_err")")
ep_run_submit_out="$(newdir)/ep-run-submit.yaml"; tmpdirs+=("$(dirname "$ep_run_submit_out")")
if FORK_SANDBOX_CONFIG_DIR="$single_ep_config_dir" "$k8s_sh" run --dry-run \
    --branch fs-k8s-test-branch --endpoint primary \
    "$proj_dir" "$handoff_file" > "$ep_run_out" 2>"$ep_run_err" \
    && FORK_SANDBOX_CONFIG_DIR="$single_ep_config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --endpoint primary \
    "$proj_dir" "$handoff_file" > "$ep_run_submit_out" 2>/dev/null; then
    ok "run --dry-run --endpoint (no --model) exits 0"
else
    no "run --dry-run --endpoint (no --model) exits 0" "$(cat "$ep_run_err")"
fi
if diff -q "$ep_run_out" "$ep_run_submit_out" >/dev/null 2>&1; then
    ok "run --dry-run --endpoint renders byte-for-byte the same YAML as submit"
else
    no "run --dry-run --endpoint renders byte-for-byte the same YAML as submit" \
        "$(diff "$ep_run_out" "$ep_run_submit_out" 2>&1 | head -n 20)"
fi
if command -v yamllint >/dev/null 2>&1; then
    out="$(yamllint "$endpoints_out" 2>&1)"
    if [[ -z "$out" ]]; then
        ok "yamllint: K8S_PROXY_ENDPOINTS install --dry-run output"
    else
        no "yamllint: K8S_PROXY_ENDPOINTS install --dry-run output" "$out"
    fi
fi
location_count="$(grep -c '^            location = /e/' "$endpoints_out")"
check "two registered endpoints render exactly 4 (2N) locations" 4 "$location_count"
non_exact_count="$(grep -c '^            location [^=]' "$endpoints_out")"
check "the only non-exact-match location is the default-deny location /" 1 "$non_exact_count"
regex_count="$(grep -c 'location ~' "$endpoints_out")"
check "no endpoint location uses a regex match" 0 "$regex_count"
for path in /e/primary/v1/chat/completions /e/primary/v1/models \
    /e/secondary/v1/chat/completions /e/secondary/v1/models; do
    if grep -qF "location = $path {" "$endpoints_out"; then
        ok "renders an exact-match location for $path"
    else
        no "renders an exact-match location for $path" "not found in $endpoints_out"
    fi
done
if grep -q 'location / {' "$endpoints_out"; then
    ok "the default-deny location / survives a K8S_PROXY_ENDPOINTS install"
else
    no "the default-deny location / survives a K8S_PROXY_ENDPOINTS install" \
        "not found in $endpoints_out"
fi

# Same coverage as 'nginx -t on the rendered proxy config' above, against
# the K8S_PROXY_ENDPOINTS (keyless) render this time -- a genuinely
# different nginx.conf shape (no upstream-key.conf include, no
# $upstream_key, 2N exact-match locations, $upstream values carrying a
# path component that proxy_pass then concatenates onto) that every other
# assertion in this section only greps YAML text for, so a keyless config
# nginx refuses to start on could ship fully green otherwise. Reuses
# nginx_mode/run_nginx_t/proxy_image from the legacy check above --
# staging upstream-key.conf here is harmless even though this render never
# includes it.
endpoints_nginx_conf="$(extract_nginx_conf "$endpoints_out")"
if [[ -z "$endpoints_nginx_conf" ]]; then
    no "extracted nginx.conf from K8S_PROXY_ENDPOINTS install --dry-run output" \
        "no nginx.conf block found in $endpoints_out"
elif [[ -z "${nginx_mode:-}" ]]; then
    printf '  SKIP  neither nginx nor a working docker on PATH\n'
else
    endpoints_nginx_check_dir="$(newdir)"; tmpdirs+=("$endpoints_nginx_check_dir")
    printf '%s\n' "${endpoints_nginx_conf//kube-dns.kube-system.svc.cluster.local/127.0.0.1}" \
        > "$endpoints_nginx_check_dir/nginx.conf"
    # shellcheck disable=SC2016  # $upstream_key is nginx config, not shell
    printf 'set $upstream_key "dummy";\n' > "$endpoints_nginx_check_dir/upstream-key.conf"
    out="$(run_nginx_t "$endpoints_nginx_check_dir")"; rc=$?
    if (( rc == 0 )); then
        ok "nginx -t accepts the rendered K8S_PROXY_ENDPOINTS (keyless) proxy config"
    else
        no "nginx -t accepts the rendered K8S_PROXY_ENDPOINTS (keyless) proxy config" "$out"
    fi
fi

# Keyless by construction: no Secret, no upstream-key.conf include, no
# Authorization header anywhere in the render.
if grep -q 'kind: Secret' "$endpoints_out"; then
    no "K8S_PROXY_ENDPOINTS install creates no Secret" "found 'kind: Secret' in $endpoints_out"
else
    ok "K8S_PROXY_ENDPOINTS install creates no Secret"
fi
if grep -q 'include /etc/nginx/upstream-key.conf' "$endpoints_out"; then
    no "K8S_PROXY_ENDPOINTS install includes no upstream-key.conf" \
        "found the include in $endpoints_out"
else
    ok "K8S_PROXY_ENDPOINTS install includes no upstream-key.conf"
fi
if grep -q 'Authorization' "$endpoints_out"; then
    no "K8S_PROXY_ENDPOINTS install injects no Authorization header" \
        "found 'Authorization' in $endpoints_out"
else
    ok "K8S_PROXY_ENDPOINTS install injects no Authorization header"
fi
# The other half of "no Secret": the Deployment must not reference one
# either, via the volumeMount or the volume itself -- a render with no
# `kind: Secret` doc but a surviving `secretName: fork-sandbox-upstream-key`
# volume still fails at kubelet ("secret ... not found"), which the
# assertions above alone would not catch.
if grep -q 'secretName: fork-sandbox-upstream-key' "$endpoints_out"; then
    no "K8S_PROXY_ENDPOINTS install references no upstream-key Secret volume" \
        "found 'secretName: fork-sandbox-upstream-key' in $endpoints_out"
else
    ok "K8S_PROXY_ENDPOINTS install references no upstream-key Secret volume"
fi
if grep -q 'name: upstream-key' "$endpoints_out"; then
    no "K8S_PROXY_ENDPOINTS install carries no upstream-key volume/volumeMount" \
        "found 'name: upstream-key' in $endpoints_out"
else
    ok "K8S_PROXY_ENDPOINTS install carries no upstream-key volume/volumeMount"
fi

# K8S_PROXY_ALLOW replaces the default RFC1918-except egress block with
# exactly the given <cidr>:<port> entries.
allow_config_dir="$(newdir)"; tmpdirs+=("$allow_config_dir")
cat > "$allow_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_ENDPOINTS=primary=http://10.0.0.5:8001/v1,secondary=http://10.0.0.6:8000/v1
K8S_PROXY_ALLOW=10.0.0.5/32:8001,10.0.0.6/32:8000
K8S_DENIED_PROBE=10.0.0.1:443
CONF
allow_out="$(newdir)/allow-install.yaml"; tmpdirs+=("$(dirname "$allow_out")")
FORK_SANDBOX_CONFIG_DIR="$allow_config_dir" "$k8s_sh" install --dry-run \
    > "$allow_out" 2>/tmp/fs-k8s-test-allow-install.err
proxy_netpol_allow_doc="$(extract_doc_by_kind NetworkPolicy "$allow_out")"
if grep -q 'cidr: 0.0.0.0/0' <<< "$proxy_netpol_allow_doc"; then
    no "K8S_PROXY_ALLOW replaces the default RFC1918-except block" \
        "still found 'cidr: 0.0.0.0/0' in the NetworkPolicy doc"
else
    ok "K8S_PROXY_ALLOW replaces the default RFC1918-except block"
fi
if grep -q 'cidr: 10.0.0.5/32' <<< "$proxy_netpol_allow_doc" \
    && grep -q 'port: 8001' <<< "$proxy_netpol_allow_doc" \
    && grep -q 'cidr: 10.0.0.6/32' <<< "$proxy_netpol_allow_doc" \
    && grep -q 'port: 8000' <<< "$proxy_netpol_allow_doc"; then
    ok "K8S_PROXY_ALLOW renders exactly the given cidr:port entries"
else
    no "K8S_PROXY_ALLOW renders exactly the given cidr:port entries" "$proxy_netpol_allow_doc"
fi

# A set K8S_PROXY_ALLOW REPLACES the default egress rule wholesale rather
# than extending it -- so an entry it does not literally cover is just as
# unreachable as an http:// endpoint under the unset-K8S_PROXY_ALLOW
# default, and install must warn about it by name, not just the one entry
# that happened to prompt setting K8S_PROXY_ALLOW in the first place.
partial_allow_config_dir="$(newdir)"; tmpdirs+=("$partial_allow_config_dir")
cat > "$partial_allow_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_ENDPOINTS=a=http://10.0.0.5:8001/v1,b=http://10.0.0.6:9000/v1
K8S_PROXY_ALLOW=10.0.0.5/32:8001
K8S_DENIED_PROBE=10.0.0.1:443
CONF
partial_allow_err="$(FORK_SANDBOX_CONFIG_DIR="$partial_allow_config_dir" "$k8s_sh" install --dry-run \
    2>&1 >/dev/null)"
if [[ "$partial_allow_err" == *"'b'"* && "$partial_allow_err" == *"10.0.0.6"* ]]; then
    ok "a partial K8S_PROXY_ALLOW warns about the endpoint it does not cover"
else
    no "a partial K8S_PROXY_ALLOW warns about the endpoint it does not cover" "$partial_allow_err"
fi
if [[ "$partial_allow_err" == *"'a'"* ]]; then
    no "a partial K8S_PROXY_ALLOW does not also warn about the endpoint it does cover" \
        "$partial_allow_err"
else
    ok "a partial K8S_PROXY_ALLOW does not also warn about the endpoint it does cover"
fi

# A hostname in K8S_PROXY_ALLOW is refused -- NetworkPolicy has no hostname
# field, so the error says so rather than just "invalid".
hostname_allow_config_dir="$(newdir)"; tmpdirs+=("$hostname_allow_config_dir")
cat > "$hostname_allow_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_ENDPOINTS=primary=http://10.0.0.5:8001/v1
K8S_PROXY_ALLOW=vllm.internal.example.com:8001
K8S_DENIED_PROBE=10.0.0.1:443
CONF
refuses "a hostname in K8S_PROXY_ALLOW is refused" \
    "NetworkPolicy has no hostname field" \
    env FORK_SANDBOX_CONFIG_DIR="$hostname_allow_config_dir" "$k8s_sh" install --dry-run

# http:// is accepted to a private address and refused to a public one, on
# both the legacy K8S_PROXY_UPSTREAM path and a K8S_PROXY_ENDPOINTS entry.
http_private_config_dir="$(newdir)"; tmpdirs+=("$http_private_config_dir")
cat > "$http_private_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_UPSTREAM=http://10.0.0.5:8001
K8S_DENIED_PROBE=10.0.0.1:443
CONF
install -m 600 /dev/null "$http_private_config_dir/pi.env"
printf 'OPENROUTER_API_KEY=sk-test-dummy\n' >> "$http_private_config_dir/pi.env"
if FORK_SANDBOX_CONFIG_DIR="$http_private_config_dir" "$k8s_sh" install --dry-run \
    >/tmp/fs-k8s-test-http-private.out 2>/tmp/fs-k8s-test-http-private.err; then
    ok "K8S_PROXY_UPSTREAM http:// to a private address is accepted"
else
    no "K8S_PROXY_UPSTREAM http:// to a private address is accepted" \
        "$(cat /tmp/fs-k8s-test-http-private.err)"
fi
# Accepted is not the same as reachable: this exact config's default
# egress policy excepts the only address it can ever dial (see
# validate_upstream_url's own header), so install must say so rather than
# render a NetworkPolicy that provably never lets this proxy connect.
if grep -q 'K8S_PROXY_ALLOW=<cidr>:<port> for this endpoint' /tmp/fs-k8s-test-http-private.err; then
    ok "K8S_PROXY_UPSTREAM http:// to a private address with no K8S_PROXY_ALLOW warns it is unreachable"
else
    no "K8S_PROXY_UPSTREAM http:// to a private address with no K8S_PROXY_ALLOW warns it is unreachable" \
        "$(cat /tmp/fs-k8s-test-http-private.err)"
fi

http_public_config_dir="$(newdir)"; tmpdirs+=("$http_public_config_dir")
cat > "$http_public_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_UPSTREAM=http://8.8.8.8
K8S_DENIED_PROBE=10.0.0.1:443
CONF
refuses "K8S_PROXY_UPSTREAM http:// to a public address is refused" \
    "open internet in cleartext" \
    env FORK_SANDBOX_CONFIG_DIR="$http_public_config_dir" "$k8s_sh" install --dry-run

endpoints_http_private_config_dir="$(newdir)"; tmpdirs+=("$endpoints_http_private_config_dir")
cat > "$endpoints_http_private_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_ENDPOINTS=primary=http://10.0.0.5:8001/v1
K8S_DENIED_PROBE=10.0.0.1:443
CONF
if FORK_SANDBOX_CONFIG_DIR="$endpoints_http_private_config_dir" "$k8s_sh" install --dry-run \
    >/tmp/fs-k8s-test-endpoints-http-private.out 2>/tmp/fs-k8s-test-endpoints-http-private.err; then
    ok "K8S_PROXY_ENDPOINTS http:// to a private address is accepted"
else
    no "K8S_PROXY_ENDPOINTS http:// to a private address is accepted" \
        "$(cat /tmp/fs-k8s-test-endpoints-http-private.err)"
fi
# Same reachability warning as the legacy K8S_PROXY_UPSTREAM case above.
if grep -q 'K8S_PROXY_ALLOW=<cidr>:<port> for this endpoint' /tmp/fs-k8s-test-endpoints-http-private.err; then
    ok "K8S_PROXY_ENDPOINTS http:// to a private address with no K8S_PROXY_ALLOW warns it is unreachable"
else
    no "K8S_PROXY_ENDPOINTS http:// to a private address with no K8S_PROXY_ALLOW warns it is unreachable" \
        "$(cat /tmp/fs-k8s-test-endpoints-http-private.err)"
fi

endpoints_http_public_config_dir="$(newdir)"; tmpdirs+=("$endpoints_http_public_config_dir")
cat > "$endpoints_http_public_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_ENDPOINTS=primary=http://1.2.3.4:8001/v1
K8S_DENIED_PROBE=10.0.0.1:443
CONF
refuses "K8S_PROXY_ENDPOINTS http:// to a public address is refused" \
    "open internet in cleartext" \
    env FORK_SANDBOX_CONFIG_DIR="$endpoints_http_public_config_dir" "$k8s_sh" install --dry-run

# An octet with a leading zero must never be read as octal by the (( ))
# arithmetic validate_upstream_url uses to classify an address as private
# -- "012" is decimal 12 (a public address), not octal 10 (private
# 10.5.6.7), so this must still be refused as public.
octal_octet_config_dir="$(newdir)"; tmpdirs+=("$octal_octet_config_dir")
cat > "$octal_octet_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_ENDPOINTS=primary=http://012.5.6.7:8001/v1
K8S_DENIED_PROBE=10.0.0.1:443
CONF
refuses "an octet with a leading zero is not read as octal (012 stays decimal 12, public)" \
    "open internet in cleartext" \
    env FORK_SANDBOX_CONFIG_DIR="$octal_octet_config_dir" "$k8s_sh" install --dry-run

# A leading-zero octet that isn't valid octal ("08", "09") must not spew
# a bash arithmetic error instead of this function's own message.
invalid_octal_octet_config_dir="$(newdir)"; tmpdirs+=("$invalid_octal_octet_config_dir")
cat > "$invalid_octal_octet_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_ENDPOINTS=primary=http://08.0.0.1:8001/v1
K8S_DENIED_PROBE=10.0.0.1:443
CONF
invalid_octal_err="$(FORK_SANDBOX_CONFIG_DIR="$invalid_octal_octet_config_dir" "$k8s_sh" install --dry-run \
    2>&1 >/dev/null)"
# "not a private address" itself is not checked here -- validate_upstream_url
# wraps it across a line break ("...is not a\nprivate address...") that a
# plain substring match can't span; "is not a valid IPv4" is this
# function's other (unwrapped) message and proves the same thing.
if [[ "$invalid_octal_err" == *"value too great for base"* ]]; then
    no "a leading-zero octet that isn't valid octal fails with this function's own message" \
        "$invalid_octal_err"
elif [[ "$invalid_octal_err" == *"K8S_PROXY_ENDPOINTS entry 'primary'"* ]]; then
    ok "a leading-zero octet that isn't valid octal fails with this function's own message"
else
    no "a leading-zero octet that isn't valid octal fails with this function's own message" \
        "$invalid_octal_err"
fi

# http:// to an in-cluster Service DNS name (host ends in
# .svc.$K8S_CLUSTER_DOMAIN) is accepted without the IPv4-privateness check
# below -- the proxy's own NetworkPolicy egress is what actually keeps this
# safe even against an ExternalName Service CNAMEd off-cluster (see
# validate_upstream_url's own header). Default K8S_CLUSTER_DOMAIN is
# cluster.local.
svc_dns_config_dir="$(newdir)"; tmpdirs+=("$svc_dns_config_dir")
cat > "$svc_dns_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_ENDPOINTS=primary=http://svc-a.example-ns.svc.cluster.local:8001/v1
K8S_DENIED_PROBE=10.0.0.1:443
CONF
if FORK_SANDBOX_CONFIG_DIR="$svc_dns_config_dir" "$k8s_sh" install --dry-run \
    >/tmp/fs-k8s-test-svc-dns.out 2>/tmp/fs-k8s-test-svc-dns.err; then
    ok "K8S_PROXY_ENDPOINTS http:// to a .svc.cluster.local name is accepted"
else
    no "K8S_PROXY_ENDPOINTS http:// to a .svc.cluster.local name is accepted" \
        "$(cat /tmp/fs-k8s-test-svc-dns.err)"
fi

# A custom K8S_CLUSTER_DOMAIN is honored -- cluster.local is only the
# common default, not hardcoded.
custom_domain_config_dir="$(newdir)"; tmpdirs+=("$custom_domain_config_dir")
cat > "$custom_domain_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_ENDPOINTS=primary=http://svc-a.example-ns.svc.some-other.domain:8001/v1
K8S_CLUSTER_DOMAIN=some-other.domain
K8S_DENIED_PROBE=10.0.0.1:443
CONF
if FORK_SANDBOX_CONFIG_DIR="$custom_domain_config_dir" "$k8s_sh" install --dry-run \
    >/tmp/fs-k8s-test-custom-domain.out 2>/tmp/fs-k8s-test-custom-domain.err; then
    ok "http:// to a .svc.<K8S_CLUSTER_DOMAIN> name is accepted with a custom domain"
else
    no "http:// to a .svc.<K8S_CLUSTER_DOMAIN> name is accepted with a custom domain" \
        "$(cat /tmp/fs-k8s-test-custom-domain.err)"
fi

# K8S_CLUSTER_DOMAIN is substituted unquoted into manifests, a sed
# expression, and nginx's `resolver` directive -- a bad shape must be a
# named, load-time error (like K8S_NAMESPACE's own shape check), not a
# `sed: unknown option` or a broken NetworkPolicy/nginx render.
bad_domain_config_dir="$(newdir)"; tmpdirs+=("$bad_domain_config_dir")
cp "$custom_domain_config_dir/k8s.env" "$bad_domain_config_dir/k8s.env"
sed -i 's/^K8S_CLUSTER_DOMAIN=.*/K8S_CLUSTER_DOMAIN=clus|ter.local/' "$bad_domain_config_dir/k8s.env"
refuses "a K8S_CLUSTER_DOMAIN with an invalid shape is refused" \
    "K8S_CLUSTER_DOMAIN='clus|ter.local' is not a valid DNS" \
    env FORK_SANDBOX_CONFIG_DIR="$bad_domain_config_dir" "$k8s_sh" install --dry-run

injected_domain_config_dir="$(newdir)"; tmpdirs+=("$injected_domain_config_dir")
cp "$custom_domain_config_dir/k8s.env" "$injected_domain_config_dir/k8s.env"
sed -i 's/^K8S_CLUSTER_DOMAIN=.*/K8S_CLUSTER_DOMAIN=cluster.local; deny all/' "$injected_domain_config_dir/k8s.env"
refuses "a K8S_CLUSTER_DOMAIN that would inject into the rendered nginx resolver line is refused" \
    "is not a valid DNS" \
    env FORK_SANDBOX_CONFIG_DIR="$injected_domain_config_dir" "$k8s_sh" install --dry-run

# A host merely ending in the cluster domain, without the .svc. segment
# that marks it as a Service name, is still refused -- the narrowest rule
# that covers the case, not "anything under the domain".
non_svc_domain_config_dir="$(newdir)"; tmpdirs+=("$non_svc_domain_config_dir")
cat > "$non_svc_domain_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_ENDPOINTS=primary=http://svc-a.cluster.local:8001/v1
K8S_DENIED_PROBE=10.0.0.1:443
CONF
refuses "http:// to a host merely ending in the cluster domain, without .svc., is refused" \
    "verified as private without DNS" \
    env FORK_SANDBOX_CONFIG_DIR="$non_svc_domain_config_dir" "$k8s_sh" install --dry-run

# http:// to a .svc. name on port 443 is refused unconditionally -- the
# default egress policy carries ANY address on 443, so a Service name
# CNAMEd off-cluster would leak this endpoint's Authorization header in
# cleartext. Named the port, per validate_upstream_url's own message.
svc_dns_443_config_dir="$(newdir)"; tmpdirs+=("$svc_dns_443_config_dir")
cat > "$svc_dns_443_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_ENDPOINTS=primary=http://svc-a.example-ns.svc.cluster.local:443/v1
K8S_DENIED_PROBE=10.0.0.1:443
CONF
refuses "http:// to a .svc. name on port 443 is refused, naming the port" \
    "would leave the cluster in cleartext" \
    env FORK_SANDBOX_CONFIG_DIR="$svc_dns_443_config_dir" "$k8s_sh" install --dry-run

# The port-443 refusal above only holds when K8S_PROXY_ALLOW is unset: a
# set K8S_PROXY_ALLOW replaces the default egress policy wholesale, so
# whether port 443 still carries ANY address depends on the operator's own
# entries, not the hardcoded default-policy assumption. This fixture's
# K8S_PROXY_ALLOW is a private CIDR, so a CNAME to a public host is
# dropped by the policy and no cleartext leak is possible -- install must
# succeed instead of citing the unset-K8S_PROXY_ALLOW default policy, which
# is not the config in hand.
svc_dns_443_allow_config_dir="$(newdir)"; tmpdirs+=("$svc_dns_443_allow_config_dir")
cat > "$svc_dns_443_allow_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_ENDPOINTS=primary=http://svc-a.example-ns.svc.cluster.local:443/v1
K8S_PROXY_ALLOW=10.0.0.0/8:443
K8S_DENIED_PROBE=10.0.0.1:443
CONF
svc_dns_443_allow_err="$(FORK_SANDBOX_CONFIG_DIR="$svc_dns_443_allow_config_dir" "$k8s_sh" \
    install --dry-run 2>&1 >/dev/null)"
svc_dns_443_allow_rc=$?
if (( svc_dns_443_allow_rc == 0 )) \
    && [[ "$svc_dns_443_allow_err" != *'would leave the cluster in cleartext'* ]]; then
    ok "http:// to a .svc. name on port 443 is accepted when K8S_PROXY_ALLOW replaces the default policy"
else
    no "http:// to a .svc. name on port 443 is accepted when K8S_PROXY_ALLOW replaces the default policy" \
        "status $svc_dns_443_allow_rc: $svc_dns_443_allow_err"
fi

# https:// to a .svc. name on port 443 stays accepted -- the gate above is
# about cleartext, not the port number itself.
svc_dns_https_443_config_dir="$(newdir)"; tmpdirs+=("$svc_dns_https_443_config_dir")
cat > "$svc_dns_https_443_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_ENDPOINTS=primary=https://svc-a.example-ns.svc.cluster.local:443/v1
K8S_DENIED_PROBE=10.0.0.1:443
CONF
if FORK_SANDBOX_CONFIG_DIR="$svc_dns_https_443_config_dir" "$k8s_sh" install --dry-run \
    >/tmp/fs-k8s-test-svc-dns-https-443.out 2>/tmp/fs-k8s-test-svc-dns-https-443.err; then
    ok "https:// to a .svc. name on port 443 is still accepted"
else
    no "https:// to a .svc. name on port 443 is still accepted" \
        "$(cat /tmp/fs-k8s-test-svc-dns-https-443.err)"
fi

# A custom K8S_PROXY_ALLOW that opens this endpoint's port to a NON-private
# CIDR is a deliberate operator choice (K8S_PROXY_ALLOW replaces the
# default policy wholesale), so a .svc. http:// endpoint on that port is a
# warning, not a refusal -- naming the endpoint and the matching entry.
# 192.0.2.0/24 is this repo's RFC 5737 documentation range, a safe stand-in
# for "a real public CIDR" in a test fixture.
svc_dns_public_allow_config_dir="$(newdir)"; tmpdirs+=("$svc_dns_public_allow_config_dir")
cat > "$svc_dns_public_allow_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_ENDPOINTS=primary=http://svc-a.example-ns.svc.cluster.local:8080/v1
K8S_PROXY_ALLOW=192.0.2.0/24:8080
K8S_DENIED_PROBE=10.0.0.1:443
CONF
if FORK_SANDBOX_CONFIG_DIR="$svc_dns_public_allow_config_dir" "$k8s_sh" install --dry-run \
    >/tmp/fs-k8s-test-svc-dns-public-allow.out 2>/tmp/fs-k8s-test-svc-dns-public-allow.err; then
    ok "a .svc. http:// endpoint whose port a public K8S_PROXY_ALLOW CIDR opens is accepted, not refused"
else
    no "a .svc. http:// endpoint whose port a public K8S_PROXY_ALLOW CIDR opens is accepted, not refused" \
        "$(cat /tmp/fs-k8s-test-svc-dns-public-allow.err)"
fi
if grep -qF "K8S_PROXY_ENDPOINTS entry 'primary'" /tmp/fs-k8s-test-svc-dns-public-allow.err \
    && grep -qF '192.0.2.0/24:8080' /tmp/fs-k8s-test-svc-dns-public-allow.err \
    && grep -qF 'leave the cluster in cleartext' /tmp/fs-k8s-test-svc-dns-public-allow.err; then
    ok "the public-CIDR warning names the endpoint and the matching K8S_PROXY_ALLOW entry"
else
    no "the public-CIDR warning names the endpoint and the matching K8S_PROXY_ALLOW entry" \
        "$(cat /tmp/fs-k8s-test-svc-dns-public-allow.err)"
fi

# The same shape, but the matching K8S_PROXY_ALLOW entry's CIDR is private
# -- no cleartext-leak warning, since a private CIDR can never route to a
# public CNAME target regardless of what the .svc. name resolves to.
svc_dns_private_allow_config_dir="$(newdir)"; tmpdirs+=("$svc_dns_private_allow_config_dir")
cat > "$svc_dns_private_allow_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_ENDPOINTS=primary=http://svc-a.example-ns.svc.cluster.local:8080/v1
K8S_PROXY_ALLOW=10.0.0.0/24:8080
K8S_DENIED_PROBE=10.0.0.1:443
CONF
svc_dns_private_allow_err="$(FORK_SANDBOX_CONFIG_DIR="$svc_dns_private_allow_config_dir" "$k8s_sh" \
    install --dry-run 2>&1 >/dev/null)"
if [[ "$svc_dns_private_allow_err" == *'leave the cluster in cleartext'* ]]; then
    no "a .svc. http:// endpoint whose matching K8S_PROXY_ALLOW CIDR is private does not warn about a leak" \
        "$svc_dns_private_allow_err"
else
    ok "a .svc. http:// endpoint whose matching K8S_PROXY_ALLOW CIDR is private does not warn about a leak"
fi

# cidr_is_private must reject a supernet whose network address merely
# starts with a private-looking octet -- 10.0.0.0/7 is a canonical,
# parser-accepted CIDR, but it actually spans into 11.0.0.0/8, which is
# public. A check on the network address's own octets alone (ignoring the
# prefix) would call this CIDR private and suppress the cleartext warning
# even though it is exactly the shape that warning exists to catch.
svc_dns_supernet_allow_config_dir="$(newdir)"; tmpdirs+=("$svc_dns_supernet_allow_config_dir")
cat > "$svc_dns_supernet_allow_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_ENDPOINTS=primary=http://svc-a.example-ns.svc.cluster.local:8080/v1
K8S_PROXY_ALLOW=10.0.0.0/7:8080
K8S_DENIED_PROBE=10.0.0.1:443
CONF
svc_dns_supernet_allow_err="$(FORK_SANDBOX_CONFIG_DIR="$svc_dns_supernet_allow_config_dir" "$k8s_sh" \
    install --dry-run 2>&1 >/dev/null)"
if [[ "$svc_dns_supernet_allow_err" == *'leave the cluster in cleartext'* ]]; then
    ok "a .svc. http:// endpoint whose matching K8S_PROXY_ALLOW CIDR is a private-looking public supernet still warns"
else
    no "a .svc. http:// endpoint whose matching K8S_PROXY_ALLOW CIDR is a private-looking public supernet still warns" \
        "$svc_dns_supernet_allow_err"
fi

# parse_proxy_allow must normalize a leading-zero port the same way
# parse_proxy_allow_ns already does -- left unnormalized, cmd_install's
# reachability review's (( port == PROXY_ALLOW_PORTS[j] )) comparison hands
# bash an octal-looking literal and crashes instead of rendering the
# public-CIDR cleartext warning this K8S_PROXY_ALLOW entry should trigger.
leading_zero_allow_port_config_dir="$(newdir)"; tmpdirs+=("$leading_zero_allow_port_config_dir")
cat > "$leading_zero_allow_port_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_ENDPOINTS=primary=http://svc-a.example-ns.svc.cluster.local:8080/v1
K8S_PROXY_ALLOW=192.0.2.0/24:08080
K8S_DENIED_PROBE=10.0.0.1:443
CONF
leading_zero_allow_port_err="$(FORK_SANDBOX_CONFIG_DIR="$leading_zero_allow_port_config_dir" "$k8s_sh" \
    install --dry-run 2>&1 >/dev/null)"
if [[ "$leading_zero_allow_port_err" == *'value too great for base'* ]]; then
    no "a leading-zero K8S_PROXY_ALLOW port normalizes instead of crashing the reachability review" \
        "$leading_zero_allow_port_err"
elif [[ "$leading_zero_allow_port_err" != *'leave the cluster in cleartext'* ]]; then
    no "a leading-zero K8S_PROXY_ALLOW port normalizes instead of crashing the reachability review" \
        "$leading_zero_allow_port_err"
else
    ok "a leading-zero K8S_PROXY_ALLOW port normalizes instead of crashing the reachability review"
fi

# The same leading-zero-port normalization is needed on the non-.svc
# IPv4-literal reachability path (K8S_PROXY_ALLOW set, endpoint host a
# literal IPv4 address) -- a separate loop from the .svc. one above, and
# the one the original fix's own leading-zero test never reached.
leading_zero_ipv4_port_config_dir="$(newdir)"; tmpdirs+=("$leading_zero_ipv4_port_config_dir")
cat > "$leading_zero_ipv4_port_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_ENDPOINTS=primary=http://10.0.0.5:08080/v1
K8S_PROXY_ALLOW=10.0.0.0/8:8080
K8S_DENIED_PROBE=10.0.0.1:443
CONF
leading_zero_ipv4_port_err="$(FORK_SANDBOX_CONFIG_DIR="$leading_zero_ipv4_port_config_dir" "$k8s_sh" \
    install --dry-run 2>&1 >/dev/null)"
if [[ "$leading_zero_ipv4_port_err" == *'value too great for base'* ]]; then
    no "a leading-zero URL port on the IPv4-literal K8S_PROXY_ALLOW path normalizes instead of crashing" \
        "$leading_zero_ipv4_port_err"
elif [[ "$leading_zero_ipv4_port_err" == *'will be dropped'* ]]; then
    no "a leading-zero URL port on the IPv4-literal K8S_PROXY_ALLOW path normalizes instead of crashing" \
        "$leading_zero_ipv4_port_err"
else
    ok "a leading-zero URL port on the IPv4-literal K8S_PROXY_ALLOW path normalizes instead of crashing"
fi

# parse_proxy_allow must normalize a leading-zero CIDR *prefix* the same
# way it now normalizes the port -- left unnormalized, cidr_contains's
# unforced-base `mask=$(( ... << (32 - prefix) ...))` arithmetic hands
# bash an octal-looking literal and crashes the whole install instead of
# rendering the coverage warning this K8S_PROXY_ALLOW entry should trigger.
leading_zero_allow_prefix_config_dir="$(newdir)"; tmpdirs+=("$leading_zero_allow_prefix_config_dir")
cat > "$leading_zero_allow_prefix_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_ENDPOINTS=primary=http://10.0.0.5:8080/v1
K8S_PROXY_ALLOW=10.0.0.0/08:8080
K8S_DENIED_PROBE=10.0.0.1:443
CONF
leading_zero_allow_prefix_err="$(FORK_SANDBOX_CONFIG_DIR="$leading_zero_allow_prefix_config_dir" "$k8s_sh" \
    install --dry-run 2>&1 >/dev/null)"
if [[ "$leading_zero_allow_prefix_err" == *'value too great for base'* ]]; then
    no "a leading-zero K8S_PROXY_ALLOW CIDR prefix normalizes instead of crashing the install" \
        "$leading_zero_allow_prefix_err"
else
    ok "a leading-zero K8S_PROXY_ALLOW CIDR prefix normalizes instead of crashing the install"
fi

# parse_proxy_allow must normalize leading-zero *octets* to canonical
# decimal and store (and render) them that way. The manifest renders the
# stored CIDR verbatim, and a current Kubernetes API server refuses a
# leading-zero octet in NetworkPolicy ipBlock.cidr -- verified by
# server-side dry-run against a live v1.36.1 API server: "must not have
# leading 0s in IP or prefix length". Unnormalized, the install would die
# at apply time with an API error instead of the parser's own message.
# (See the rationale at parse_proxy_allow's normalization line for why
# ParseCIDRSloppy's leniency is not a counter-argument.)
leading_zero_allow_octet_config_dir="$(newdir)"; tmpdirs+=("$leading_zero_allow_octet_config_dir")
cat > "$leading_zero_allow_octet_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_ENDPOINTS=primary=http://svc-a.example-ns.svc.cluster.local:8080/v1
K8S_PROXY_ALLOW=192.000.002.015/32:8080
K8S_DENIED_PROBE=10.0.0.1:443
CONF
leading_zero_allow_octet_out="$(newdir)/leading-zero-octet-install.yaml"; tmpdirs+=("$(dirname "$leading_zero_allow_octet_out")")
FORK_SANDBOX_CONFIG_DIR="$leading_zero_allow_octet_config_dir" "$k8s_sh" install --dry-run \
    > "$leading_zero_allow_octet_out" 2>/tmp/fs-k8s-test-leading-zero-octet-install.err
leading_zero_allow_octet_netpol_doc="$(extract_doc_by_kind NetworkPolicy "$leading_zero_allow_octet_out")"
if grep -q 'cidr: 192.0.2.15/32' <<< "$leading_zero_allow_octet_netpol_doc" \
    && ! grep -qF '192.000.002.015' "$leading_zero_allow_octet_out"; then
    ok "a leading-zero K8S_PROXY_ALLOW CIDR octet normalizes to canonical decimal in the rendered policy"
else
    no "a leading-zero K8S_PROXY_ALLOW CIDR octet normalizes to canonical decimal in the rendered policy" \
        "$leading_zero_allow_octet_netpol_doc"
fi

# parse_proxy_allow must refuse an out-of-range octet (the regex admits
# up to 3 digits per octet, so 256 and 999 both pass it) -- an
# out-of-range octet overflows ipv4_to_int's 32-bit packing and would be
# classified against a different real network than the one written.
for bad_octet in 256.0.0.1/32 999.999.999.999/32; do
    bad_octet_allow_config_dir="$(newdir)"; tmpdirs+=("$bad_octet_allow_config_dir")
    cat > "$bad_octet_allow_config_dir/k8s.env" <<CONF
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_ENDPOINTS=primary=http://10.0.0.5:8080/v1
K8S_PROXY_ALLOW=${bad_octet}:8080
K8S_DENIED_PROBE=10.0.0.1:443
CONF
    refuses "a K8S_PROXY_ALLOW CIDR with an out-of-range octet ($bad_octet) is refused" \
        "outside the valid range 0-255" \
        env FORK_SANDBOX_CONFIG_DIR="$bad_octet_allow_config_dir" "$k8s_sh" install --dry-run
done

# parse_proxy_allow must refuse an out-of-range prefix length (the regex
# admits 1-2 digits, so 33 through 99 all pass it) -- cidr_contains's and
# cidr_is_private's << (32 - prefix) shift arithmetic assumes 0-32.
for bad_prefix in 10.0.0.0/33 10.0.0.0/99; do
    bad_prefix_allow_config_dir="$(newdir)"; tmpdirs+=("$bad_prefix_allow_config_dir")
    cat > "$bad_prefix_allow_config_dir/k8s.env" <<CONF
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_ENDPOINTS=primary=http://10.0.0.5:8080/v1
K8S_PROXY_ALLOW=${bad_prefix}:8080
K8S_DENIED_PROBE=10.0.0.1:443
CONF
    refuses "a K8S_PROXY_ALLOW CIDR with an out-of-range prefix ($bad_prefix) is refused" \
        "outside the valid range 0-32" \
        env FORK_SANDBOX_CONFIG_DIR="$bad_prefix_allow_config_dir" "$k8s_sh" install --dry-run
done

# The prefix refusal must quote the CIDR exactly as the operator wrote
# it, not the parser's normalized internal state: the check sits before
# the octet normalization, so a leading-zero spelling comes back raw.
bad_prefix_raw_config_dir="$(newdir)"; tmpdirs+=("$bad_prefix_raw_config_dir")
cat > "$bad_prefix_raw_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_ENDPOINTS=primary=http://10.0.0.5:8080/v1
K8S_PROXY_ALLOW=192.000.002.015/33:8080
K8S_DENIED_PROBE=10.0.0.1:443
CONF
refuses "a K8S_PROXY_ALLOW prefix refusal quotes the operator's raw CIDR" \
    "outside the valid range 0-32 (in CIDR '192.000.002.015/33')" \
    env FORK_SANDBOX_CONFIG_DIR="$bad_prefix_raw_config_dir" "$k8s_sh" install --dry-run

# 0.0.0.0/0 stays accepted and stored unchanged: it is a legitimate
# "open everything" entry that cmd_install's reachability review warns
# about, and it must not become a parse-time refusal.
open_all_allow_config_dir="$(newdir)"; tmpdirs+=("$open_all_allow_config_dir")
cat > "$open_all_allow_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_ENDPOINTS=primary=http://10.0.0.5:8080/v1
K8S_PROXY_ALLOW=0.0.0.0/0:8080
K8S_DENIED_PROBE=10.0.0.1:443
CONF
open_all_allow_out="$(newdir)/open-all-install.yaml"; tmpdirs+=("$(dirname "$open_all_allow_out")")
FORK_SANDBOX_CONFIG_DIR="$open_all_allow_config_dir" "$k8s_sh" install --dry-run \
    > "$open_all_allow_out" 2>/tmp/fs-k8s-test-open-all-install.err
open_all_netpol_doc="$(extract_doc_by_kind NetworkPolicy "$open_all_allow_out")"
if grep -q 'cidr: 0.0.0.0/0' <<< "$open_all_netpol_doc"; then
    ok "a 0.0.0.0/0 K8S_PROXY_ALLOW entry is still accepted and rendered unchanged"
else
    no "a 0.0.0.0/0 K8S_PROXY_ALLOW entry is still accepted and rendered unchanged" \
        "$open_all_netpol_doc"
fi

# K8S_PROXY_ALLOW_NS -- selector-based egress for an in-cluster Service.
# The static DNS egress rule already carries its own namespaceSelector
# (kube-system/kube-dns), so "adds none" is checked as an unchanged
# occurrence count (exactly that one), not a bare absence check.
if [[ "$(grep -c 'namespaceSelector' <<< "$proxy_netpol_doc")" == 1 ]]; then
    ok "unset K8S_PROXY_ALLOW_NS renders no additional namespaceSelector rule (default egress)"
else
    no "unset K8S_PROXY_ALLOW_NS renders no additional namespaceSelector rule (default egress)" \
        "$proxy_netpol_doc"
fi
if [[ "$(grep -c 'namespaceSelector' <<< "$proxy_netpol_allow_doc")" == 1 ]]; then
    ok "unset K8S_PROXY_ALLOW_NS renders no additional namespaceSelector rule (K8S_PROXY_ALLOW set)"
else
    no "unset K8S_PROXY_ALLOW_NS renders no additional namespaceSelector rule (K8S_PROXY_ALLOW set)" \
        "$proxy_netpol_allow_doc"
fi

# A set K8S_PROXY_ALLOW_NS=<namespace>:<port>, with K8S_PROXY_ALLOW unset,
# composes with (does not replace) the default egress rule.
allow_ns_config_dir="$(newdir)"; tmpdirs+=("$allow_ns_config_dir")
cat > "$allow_ns_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_ENDPOINTS=primary=http://svc-a.example-ns.svc.cluster.local:8001/v1
K8S_PROXY_ALLOW_NS=example-ns:8001
K8S_DENIED_PROBE=10.0.0.1:443
CONF
allow_ns_out="$(newdir)/allow-ns-install.yaml"; tmpdirs+=("$(dirname "$allow_ns_out")")
FORK_SANDBOX_CONFIG_DIR="$allow_ns_config_dir" "$k8s_sh" install --dry-run \
    > "$allow_ns_out" 2>/tmp/fs-k8s-test-allow-ns-install.err
proxy_netpol_allow_ns_doc="$(extract_doc_by_kind NetworkPolicy "$allow_ns_out")"
if grep -qF 'cidr: 0.0.0.0/0' <<< "$proxy_netpol_allow_ns_doc" \
    && grep -q 'namespaceSelector' <<< "$proxy_netpol_allow_ns_doc" \
    && grep -qF 'kubernetes.io/metadata.name: example-ns' <<< "$proxy_netpol_allow_ns_doc" \
    && grep -q 'port: 8001' <<< "$proxy_netpol_allow_ns_doc"; then
    ok "K8S_PROXY_ALLOW_NS=<ns>:<port> adds a namespaceSelector rule alongside the default egress block"
else
    no "K8S_PROXY_ALLOW_NS=<ns>:<port> adds a namespaceSelector rule alongside the default egress block" \
        "$proxy_netpol_allow_ns_doc"
fi
# The reachability check must know a K8S_PROXY_ALLOW_NS entry can cover a
# Service DNS endpoint -- an install matching this one's own K8S_PROXY_ALLOW_NS
# entry must print no reachability warning at all, unlike the false positive
# this used to print (judged only against K8S_PROXY_ALLOW/the default ipBlock
# policy, which can never reach a ClusterIP -- see parse_proxy_allow_ns).
if grep -q 'Warning:' /tmp/fs-k8s-test-allow-ns-install.err; then
    no "a K8S_PROXY_ALLOW_NS-covered Service endpoint prints no reachability warning" \
        "$(cat /tmp/fs-k8s-test-allow-ns-install.err)"
else
    ok "a K8S_PROXY_ALLOW_NS-covered Service endpoint prints no reachability warning"
fi

# A K8S_PROXY_ALLOW_NS entry naming the right namespace but the wrong port
# does NOT cover the endpoint -- the reachability warning must still fire,
# and must point at K8S_PROXY_ALLOW_NS (never K8S_PROXY_ALLOW, which cannot
# reach a ClusterIP at all).
allow_ns_wrongport_config_dir="$(newdir)"; tmpdirs+=("$allow_ns_wrongport_config_dir")
cat > "$allow_ns_wrongport_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_ENDPOINTS=primary=http://svc-a.example-ns.svc.cluster.local:8001/v1
K8S_PROXY_ALLOW_NS=example-ns:9999
K8S_DENIED_PROBE=10.0.0.1:443
CONF
FORK_SANDBOX_CONFIG_DIR="$allow_ns_wrongport_config_dir" "$k8s_sh" install --dry-run \
    > /dev/null 2>/tmp/fs-k8s-test-allow-ns-wrongport-install.err
if grep -qF 'to K8S_PROXY_ALLOW_NS to fix that.' /tmp/fs-k8s-test-allow-ns-wrongport-install.err \
    && ! grep -qF 'K8S_PROXY_ALLOW=<cidr>' /tmp/fs-k8s-test-allow-ns-wrongport-install.err; then
    ok "a K8S_PROXY_ALLOW_NS entry on the wrong port still warns, naming K8S_PROXY_ALLOW_NS"
else
    no "a K8S_PROXY_ALLOW_NS entry on the wrong port still warns, naming K8S_PROXY_ALLOW_NS" \
        "$(cat /tmp/fs-k8s-test-allow-ns-wrongport-install.err)"
fi
rm -f /tmp/fs-k8s-test-allow-ns-wrongport-install.err

# A set K8S_PROXY_ALLOW_NS=<namespace> with no port renders the
# namespaceSelector rule with no ports: key at all (every port).
allow_ns_noport_config_dir="$(newdir)"; tmpdirs+=("$allow_ns_noport_config_dir")
cat > "$allow_ns_noport_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_ENDPOINTS=primary=http://svc-a.example-ns.svc.cluster.local:8001/v1
K8S_PROXY_ALLOW_NS=example-ns
K8S_DENIED_PROBE=10.0.0.1:443
CONF
allow_ns_noport_out="$(newdir)/allow-ns-noport-install.yaml"; tmpdirs+=("$(dirname "$allow_ns_noport_out")")
FORK_SANDBOX_CONFIG_DIR="$allow_ns_noport_config_dir" "$k8s_sh" install --dry-run \
    > "$allow_ns_noport_out" 2>/tmp/fs-k8s-test-allow-ns-noport-install.err
proxy_netpol_allow_ns_noport_doc="$(extract_doc_by_kind NetworkPolicy "$allow_ns_noport_out")"
if grep -qF 'kubernetes.io/metadata.name: example-ns' <<< "$proxy_netpol_allow_ns_noport_doc"; then
    ok "K8S_PROXY_ALLOW_NS=<ns> (no port) renders the namespaceSelector rule"
else
    no "K8S_PROXY_ALLOW_NS=<ns> (no port) renders the namespaceSelector rule" \
        "$proxy_netpol_allow_ns_noport_doc"
fi
ns_line_after="$(grep -A1 -F 'kubernetes.io/metadata.name: example-ns' <<< "$proxy_netpol_allow_ns_noport_doc" | tail -1)"
if [[ "$ns_line_after" == *'ports:'* ]]; then
    no "K8S_PROXY_ALLOW_NS=<ns> (no port) omits the ports: key entirely" \
        "line after matchLabels was: $ns_line_after"
else
    ok "K8S_PROXY_ALLOW_NS=<ns> (no port) omits the ports: key entirely"
fi
if grep -q 'Warning:' /tmp/fs-k8s-test-allow-ns-noport-install.err; then
    no "a K8S_PROXY_ALLOW_NS=<ns> (every port) covered Service endpoint prints no reachability warning" \
        "$(cat /tmp/fs-k8s-test-allow-ns-noport-install.err)"
else
    ok "a K8S_PROXY_ALLOW_NS=<ns> (every port) covered Service endpoint prints no reachability warning"
fi

# K8S_PROXY_ALLOW and K8S_PROXY_ALLOW_NS compose: both an ipBlock rule (from
# K8S_PROXY_ALLOW, replacing the default) and a namespaceSelector rule (from
# K8S_PROXY_ALLOW_NS) appear in the same NetworkPolicy.
combined_allow_config_dir="$(newdir)"; tmpdirs+=("$combined_allow_config_dir")
cat > "$combined_allow_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_ENDPOINTS=primary=http://10.0.0.5:8001/v1,secondary=http://svc-a.example-ns.svc.cluster.local:9000/v1
K8S_PROXY_ALLOW=10.0.0.5/32:8001
K8S_PROXY_ALLOW_NS=example-ns:9000
K8S_DENIED_PROBE=10.0.0.1:443
CONF
combined_allow_out="$(newdir)/combined-allow-install.yaml"; tmpdirs+=("$(dirname "$combined_allow_out")")
FORK_SANDBOX_CONFIG_DIR="$combined_allow_config_dir" "$k8s_sh" install --dry-run \
    > "$combined_allow_out" 2>/tmp/fs-k8s-test-combined-allow-install.err
proxy_netpol_combined_doc="$(extract_doc_by_kind NetworkPolicy "$combined_allow_out")"
if grep -qF 'cidr: 10.0.0.5/32' <<< "$proxy_netpol_combined_doc" \
    && grep -q 'namespaceSelector' <<< "$proxy_netpol_combined_doc" \
    && grep -qF 'kubernetes.io/metadata.name: example-ns' <<< "$proxy_netpol_combined_doc" \
    && grep -q 'port: 9000' <<< "$proxy_netpol_combined_doc"; then
    ok "K8S_PROXY_ALLOW and K8S_PROXY_ALLOW_NS compose in the same NetworkPolicy"
else
    no "K8S_PROXY_ALLOW and K8S_PROXY_ALLOW_NS compose in the same NetworkPolicy" \
        "$proxy_netpol_combined_doc"
fi
if grep -q 'Warning:' /tmp/fs-k8s-test-combined-allow-install.err; then
    no "K8S_PROXY_ALLOW and K8S_PROXY_ALLOW_NS composing covers both endpoints with no warning" \
        "$(cat /tmp/fs-k8s-test-combined-allow-install.err)"
else
    ok "K8S_PROXY_ALLOW and K8S_PROXY_ALLOW_NS composing covers both endpoints with no warning"
fi

# K8S_AGENT_ALLOW_NS -- the AGENT pod's own egress widening. Distinct from
# K8S_PROXY_ALLOW_NS above in every way that matters: a different pod, a
# different policy document, and a different question ("what may the agent
# reach", not "what may the proxy dial"). The two must not bleed into each
# other, so this checks BOTH documents from the same install.
agent_ns_config_dir="$(newdir)"; tmpdirs+=("$agent_ns_config_dir")
cat > "$agent_ns_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_UPSTREAM=https://openrouter.ai
K8S_AGENT_ALLOW_NS=preview-alpha:8000,preview-beta
K8S_DENIED_PROBE=10.0.0.1:443
CONF
install -m 600 /dev/null "$agent_ns_config_dir/pi.env"
printf 'OPENROUTER_API_KEY=sk-test-dummy\n' >> "$agent_ns_config_dir/pi.env"
agent_ns_out="$(newdir)/agent-allow-ns-install.yaml"; tmpdirs+=("$(dirname "$agent_ns_out")")
FORK_SANDBOX_CONFIG_DIR="$agent_ns_config_dir" "$k8s_sh" install --dry-run \
    > "$agent_ns_out" 2>/tmp/fs-k8s-test-agent-allow-ns-install.err
agent_netpol_doc="$(extract_doc_matching 'fork-sandbox-agent-egress' "$agent_ns_out")"
proxy_netpol_untouched_doc="$(extract_doc_by_kind NetworkPolicy "$agent_ns_out")"

if grep -qF 'kubernetes.io/metadata.name: preview-alpha' <<< "$agent_netpol_doc" \
    && grep -qF 'kubernetes.io/metadata.name: preview-beta' <<< "$agent_netpol_doc" \
    && grep -qE '^ +port: 8000$' <<< "$agent_netpol_doc"; then
    ok "K8S_AGENT_ALLOW_NS reaches the agent policy as --allow-namespace rules"
else
    no "K8S_AGENT_ALLOW_NS reaches the agent policy as --allow-namespace rules" \
        "$agent_netpol_doc"
fi

# The agent key must not leak into the proxy's policy. The proxy document is
# the first NetworkPolicy in the stream and carries exactly one
# namespaceSelector of its own (kube-system, for DNS) when K8S_PROXY_ALLOW_NS
# is unset -- as it is here.
if [[ "$(grep -c 'namespaceSelector' <<< "$proxy_netpol_untouched_doc")" == 1 ]] \
    && ! grep -qF 'preview-alpha' <<< "$proxy_netpol_untouched_doc"; then
    ok "K8S_AGENT_ALLOW_NS does not widen the proxy's own policy"
else
    no "K8S_AGENT_ALLOW_NS does not widen the proxy's own policy" \
        "$proxy_netpol_untouched_doc"
fi

# Widening the seal is announced, not silent -- that announcement is the
# whole reason this is a caller key rather than something a plugin reads on
# its own, so it is a tested property, not a nicety.
if grep -qF "opens agent egress to namespace 'preview-alpha' on TCP port 8000" \
        /tmp/fs-k8s-test-agent-allow-ns-install.err \
    && grep -qF "opens agent egress to namespace 'preview-beta' on every port and protocol" \
        /tmp/fs-k8s-test-agent-allow-ns-install.err \
    && grep -qF 'K8S_DENIED_PROBE must name a destination outside those namespaces' \
        /tmp/fs-k8s-test-agent-allow-ns-install.err; then
    ok "K8S_AGENT_ALLOW_NS announces every entry it opens, and the probe caveat"
else
    no "K8S_AGENT_ALLOW_NS announces every entry it opens, and the probe caveat" \
        "$(cat /tmp/fs-k8s-test-agent-allow-ns-install.err)"
fi

# Unset (every existing install) must leave the agent policy exactly sealed.
agent_netpol_default_doc="$(extract_doc_matching 'fork-sandbox-agent-egress' "$install_out")"
if [[ "$(grep -c 'namespaceSelector' <<< "$agent_netpol_default_doc")" == 1 ]]; then
    ok "unset K8S_AGENT_ALLOW_NS leaves the agent policy sealed to DNS and the proxy"
else
    no "unset K8S_AGENT_ALLOW_NS leaves the agent policy sealed to DNS and the proxy" \
        "$agent_netpol_default_doc"
fi

# A bad entry must name K8S_AGENT_ALLOW_NS, not the proxy key it shares a
# parser with -- an operator who set one key should never be sent to the
# other.
agent_ns_bad_dir="$(newdir)"; tmpdirs+=("$agent_ns_bad_dir")
cat > "$agent_ns_bad_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_UPSTREAM=https://openrouter.ai
K8S_AGENT_ALLOW_NS=Bad_NS
K8S_DENIED_PROBE=10.0.0.1:443
CONF
install -m 600 /dev/null "$agent_ns_bad_dir/pi.env"
printf 'OPENROUTER_API_KEY=sk-test-dummy\n' >> "$agent_ns_bad_dir/pi.env"
refuses "a bad K8S_AGENT_ALLOW_NS entry names that key, not K8S_PROXY_ALLOW_NS" \
    "Error: K8S_AGENT_ALLOW_NS entry" \
    env FORK_SANDBOX_CONFIG_DIR="$agent_ns_bad_dir" "$k8s_sh" install --dry-run

# BOTH keys set at once -- the fixture that was missing while the two shared
# a parser. Each key must land in its own policy document and nowhere else.
#
# Read what this does and does not defend. It pins the END STATE, which is
# what a user actually gets. It does NOT catch the reordering hazard the
# call site's own comment describes: under today's ordering the proxy policy
# is already rendered before the agent's parse clobbers PROXY_ALLOW_NS_*, so
# this passes with or without the restore (verified by removing it). The
# restore is the protection; no fixture here can substitute for it, because
# the hazard only exists in a rearrangement of the code this test cannot
# reach. Do not read a green run here as license to drop that line.
both_ns_config_dir="$(newdir)"; tmpdirs+=("$both_ns_config_dir")
cat > "$both_ns_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_ENDPOINTS=primary=http://svc-a.proxy-side-ns.svc.cluster.local:8001/v1
K8S_PROXY_ALLOW_NS=proxy-side-ns:8001
K8S_AGENT_ALLOW_NS=agent-side-ns:8000
K8S_DENIED_PROBE=10.0.0.1:443
CONF
install -m 600 /dev/null "$both_ns_config_dir/pi.env"
printf 'OPENROUTER_API_KEY=sk-test-dummy\n' >> "$both_ns_config_dir/pi.env"
both_ns_out="$(newdir)/both-allow-ns-install.yaml"; tmpdirs+=("$(dirname "$both_ns_out")")
FORK_SANDBOX_CONFIG_DIR="$both_ns_config_dir" "$k8s_sh" install --dry-run \
    > "$both_ns_out" 2>/tmp/fs-k8s-test-both-allow-ns-install.err
both_proxy_doc="$(extract_doc_by_kind NetworkPolicy "$both_ns_out")"
both_agent_doc="$(extract_doc_matching 'fork-sandbox-agent-egress' "$both_ns_out")"

if grep -qF 'kubernetes.io/metadata.name: proxy-side-ns' <<< "$both_proxy_doc" \
    && ! grep -qF 'agent-side-ns' <<< "$both_proxy_doc"; then
    ok "with both keys set, the proxy policy carries only K8S_PROXY_ALLOW_NS"
else
    no "with both keys set, the proxy policy carries only K8S_PROXY_ALLOW_NS" \
        "$both_proxy_doc"
fi
if grep -qF 'kubernetes.io/metadata.name: agent-side-ns' <<< "$both_agent_doc" \
    && ! grep -qF 'proxy-side-ns' <<< "$both_agent_doc"; then
    ok "with both keys set, the agent policy carries only K8S_AGENT_ALLOW_NS"
else
    no "with both keys set, the agent policy carries only K8S_AGENT_ALLOW_NS" \
        "$both_agent_doc"
fi

# A bad namespace shape in K8S_PROXY_ALLOW_NS is a parse-time error, nothing
# created.
bad_ns_config_dir="$(newdir)"; tmpdirs+=("$bad_ns_config_dir")
cat > "$bad_ns_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_ENDPOINTS=primary=http://10.0.0.5:8001/v1
K8S_PROXY_ALLOW_NS=-bad-:8001
K8S_DENIED_PROBE=10.0.0.1:443
CONF
refuses "a bad namespace shape in K8S_PROXY_ALLOW_NS is refused" \
    "does not name a valid" \
    env FORK_SANDBOX_CONFIG_DIR="$bad_ns_config_dir" "$k8s_sh" install --dry-run

# A bad port in K8S_PROXY_ALLOW_NS is a parse-time error, nothing created.
bad_ns_port_config_dir="$(newdir)"; tmpdirs+=("$bad_ns_port_config_dir")
cat > "$bad_ns_port_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_ENDPOINTS=primary=http://10.0.0.5:8001/v1
K8S_PROXY_ALLOW_NS=example-ns:99999
K8S_DENIED_PROBE=10.0.0.1:443
CONF
refuses "a bad port in K8S_PROXY_ALLOW_NS is refused" \
    "has an invalid port" \
    env FORK_SANDBOX_CONFIG_DIR="$bad_ns_port_config_dir" "$k8s_sh" install --dry-run

# A leading-zero port ("08") must not hit bash's unforced-base arithmetic
# ("08": value too great for base) instead of this function's own range
# check -- the same trap validate_upstream_url's own header documents and
# guards against with 10#$octet. Left unguarded, the (( )) test's raw
# arithmetic error leaves the && short-circuited to false, so no error is
# raised and the literal string "08" renders straight into the
# NetworkPolicy -- which the Kubernetes API reads as a *named* port (it
# contains no letter, so it isn't one) and rejects the whole policy.
# Correctly interpreted as decimal port 8 (in range), it must be accepted
# -- but normalized to "8" in the render, never carried through as the
# literal "08" string.
leading_zero_ns_port_config_dir="$(newdir)"; tmpdirs+=("$leading_zero_ns_port_config_dir")
cp "$bad_ns_port_config_dir/k8s.env" "$leading_zero_ns_port_config_dir/k8s.env"
sed -i 's/^K8S_PROXY_ALLOW_NS=.*/K8S_PROXY_ALLOW_NS=example-ns:08/' \
    "$leading_zero_ns_port_config_dir/k8s.env"
leading_zero_ns_port_out="$(newdir)/leading-zero-ns-port-install.yaml"
tmpdirs+=("$(dirname "$leading_zero_ns_port_out")")
if FORK_SANDBOX_CONFIG_DIR="$leading_zero_ns_port_config_dir" "$k8s_sh" install --dry-run \
    > "$leading_zero_ns_port_out" 2>/tmp/fs-k8s-test-leading-zero-ns-port.err; then
    ok "a leading-zero port in K8S_PROXY_ALLOW_NS (decimal-valid) is accepted, not crashed on"
else
    no "a leading-zero port in K8S_PROXY_ALLOW_NS (decimal-valid) is accepted, not crashed on" \
        "$(cat /tmp/fs-k8s-test-leading-zero-ns-port.err)"
fi
leading_zero_ns_port_netpol="$(extract_doc_by_kind NetworkPolicy "$leading_zero_ns_port_out")"
if grep -qF 'port: 8' <<< "$leading_zero_ns_port_netpol" \
    && ! grep -qF 'port: 08' <<< "$leading_zero_ns_port_netpol"; then
    ok "a leading-zero K8S_PROXY_ALLOW_NS port renders normalized to decimal, never the literal '08'"
else
    no "a leading-zero K8S_PROXY_ALLOW_NS port renders normalized to decimal, never the literal '08'" \
        "$leading_zero_ns_port_netpol"
fi

# A trailing ':' with no port after it must not silently mean "every
# port" -- that would grant broader egress than a typo'd entry ever asked
# for, the one input where this parser could otherwise grant more access
# than requested (see parse_proxy_endpoint_keys's sibling empty-half
# checks for the established convention).
trailing_colon_config_dir="$(newdir)"; tmpdirs+=("$trailing_colon_config_dir")
cat > "$trailing_colon_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_ENDPOINTS=primary=http://10.0.0.5:8001/v1
K8S_PROXY_ALLOW_NS=example-ns:
K8S_DENIED_PROBE=10.0.0.1:443
CONF
refuses "K8S_PROXY_ALLOW_NS with a trailing ':' and no port is refused" \
    "trailing ':'" \
    env FORK_SANDBOX_CONFIG_DIR="$trailing_colon_config_dir" "$k8s_sh" install --dry-run

# The port parsed straight out of a K8S_PROXY_ENDPOINTS URL, unlike
# K8S_PROXY_ALLOW_NS's own port (already normalized by parse_proxy_allow_ns),
# was never validated before cmd_install's reachability review does (( port
# == PROXY_ALLOW_NS_PORTS[j] )) arithmetic on it -- a non-numeric port must
# be this function's own clean error, not a raw bash arithmetic message.
url_bad_port_config_dir="$(newdir)"; tmpdirs+=("$url_bad_port_config_dir")
cat > "$url_bad_port_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_ENDPOINTS=primary=http://svc-a.example-ns.svc.cluster.local:abc/v1
K8S_PROXY_ALLOW_NS=example-ns
K8S_DENIED_PROBE=10.0.0.1:443
CONF
refuses "a non-numeric port in a K8S_PROXY_ENDPOINTS URL is refused, naming the endpoint" \
    "K8S_PROXY_ENDPOINTS entry 'primary' has an invalid port" \
    env FORK_SANDBOX_CONFIG_DIR="$url_bad_port_config_dir" "$k8s_sh" install --dry-run

# An out-of-range port (> 65535) in the URL is refused the same way.
url_out_of_range_port_config_dir="$(newdir)"; tmpdirs+=("$url_out_of_range_port_config_dir")
cp "$url_bad_port_config_dir/k8s.env" "$url_out_of_range_port_config_dir/k8s.env"
sed -i 's/:abc\/v1/:99999\/v1/' "$url_out_of_range_port_config_dir/k8s.env"
refuses "an out-of-range port in a K8S_PROXY_ENDPOINTS URL is refused" \
    "K8S_PROXY_ENDPOINTS entry 'primary' has an invalid port" \
    env FORK_SANDBOX_CONFIG_DIR="$url_out_of_range_port_config_dir" "$k8s_sh" install --dry-run

# A leading-zero port in the URL itself (e.g. ":08") must normalize to
# decimal 8 the same way parse_proxy_allow_ns already does for its own
# side -- before this fix, "08" != 8 under plain (( )) arithmetic (a raw
# bash error, in fact), so install told the operator to add "example-ns:08"
# to K8S_PROXY_ALLOW_NS, which the parser then normalizes right back to 8,
# reproducing the same false warning forever. Normalized, "8" covers "8"
# and no warning (and no crash) appears at all.
url_leading_zero_port_config_dir="$(newdir)"; tmpdirs+=("$url_leading_zero_port_config_dir")
cat > "$url_leading_zero_port_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_ENDPOINTS=primary=http://svc-a.example-ns.svc.cluster.local:08/v1
K8S_PROXY_ALLOW_NS=example-ns:8
K8S_DENIED_PROBE=10.0.0.1:443
CONF
url_leading_zero_port_err="$(FORK_SANDBOX_CONFIG_DIR="$url_leading_zero_port_config_dir" "$k8s_sh" \
    install --dry-run 2>&1 >/dev/null)"
if [[ "$url_leading_zero_port_err" == *'value too great for base'* ]]; then
    no "a leading-zero URL port normalizes to decimal instead of raising a bash arithmetic error" \
        "$url_leading_zero_port_err"
elif [[ "$url_leading_zero_port_err" == *'K8S_PROXY_ALLOW_NS'* ]]; then
    no "a leading-zero URL port normalizes to decimal instead of raising a bash arithmetic error" \
        "$url_leading_zero_port_err"
else
    ok "a leading-zero URL port normalizes to decimal instead of raising a bash arithmetic error"
fi

# The reachability warning for an uncovered .svc. endpoint must say what
# will actually happen under the egress policy in hand. An https:// .svc.
# endpoint on port 443, with K8S_PROXY_ALLOW unset and no covering
# K8S_PROXY_ALLOW_NS entry, is NOT dropped -- the default policy carries
# any address on 443 -- so the warning must say requests WILL go through,
# not that they will be dropped.
uncovered_carried_config_dir="$(newdir)"; tmpdirs+=("$uncovered_carried_config_dir")
cat > "$uncovered_carried_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_ENDPOINTS=primary=https://svc-a.example-ns.svc.cluster.local:443/v1
K8S_DENIED_PROBE=10.0.0.1:443
CONF
uncovered_carried_err="$(FORK_SANDBOX_CONFIG_DIR="$uncovered_carried_config_dir" "$k8s_sh" \
    install --dry-run 2>&1 >/dev/null)"
if [[ "$uncovered_carried_err" == *'WILL go through'* ]] \
    && [[ "$uncovered_carried_err" != *'every request to it will be dropped'* ]]; then
    ok "an uncovered .svc. endpoint the default policy carries (https on 443) warns it WILL go through"
else
    no "an uncovered .svc. endpoint the default policy carries (https on 443) warns it WILL go through" \
        "$uncovered_carried_err"
fi

# The same shape, but on a port neither the default policy nor any
# K8S_PROXY_ALLOW entry carries -- the original "will be dropped" wording
# must still apply unchanged, since that remains true for this port.
uncovered_dropped_config_dir="$(newdir)"; tmpdirs+=("$uncovered_dropped_config_dir")
cat > "$uncovered_dropped_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_ENDPOINTS=primary=https://svc-a.example-ns.svc.cluster.local:9000/v1
K8S_DENIED_PROBE=10.0.0.1:443
CONF
uncovered_dropped_err="$(FORK_SANDBOX_CONFIG_DIR="$uncovered_dropped_config_dir" "$k8s_sh" \
    install --dry-run 2>&1 >/dev/null)"
if [[ "$uncovered_dropped_err" == *'every request to it will be dropped'* ]] \
    && [[ "$uncovered_dropped_err" != *'WILL go through'* ]]; then
    ok "an uncovered .svc. endpoint on a port no policy carries still warns it will be dropped"
else
    no "an uncovered .svc. endpoint on a port no policy carries still warns it will be dropped" \
        "$uncovered_dropped_err"
fi

# The same "WILL go through" shape, but the port is carried by a set,
# genuinely public K8S_PROXY_ALLOW entry rather than the default policy --
# the reason clause spliced into the warning must read as a full clause
# with its own subject and verb ("K8S_PROXY_ALLOW entry ... carries port
# ... to ..."), not a noun phrase dangling off a "which". 192.0.2.0/24 is
# this repo's RFC 5737 documentation range, a safe stand-in for a public
# CIDR (see the other K8S_PROXY_ALLOW=192.0.2.0/24 fixtures above).
uncovered_carried_allow_config_dir="$(newdir)"; tmpdirs+=("$uncovered_carried_allow_config_dir")
cat > "$uncovered_carried_allow_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_ENDPOINTS=primary=https://svc-a.example-ns.svc.cluster.local:8080/v1
K8S_PROXY_ALLOW=192.0.2.0/24:8080
K8S_DENIED_PROBE=10.0.0.1:443
CONF
uncovered_carried_allow_err="$(FORK_SANDBOX_CONFIG_DIR="$uncovered_carried_allow_config_dir" "$k8s_sh" \
    install --dry-run 2>&1 >/dev/null)"
if [[ "$uncovered_carried_allow_err" == *'WILL go through'* ]] \
    && [[ "$uncovered_carried_allow_err" == \
        *'K8S_PROXY_ALLOW entry 192.0.2.0/24:8080 carries port 8080 to 192.0.2.0/24, so'* ]]; then
    ok "the K8S_PROXY_ALLOW-carried reason clause reads as a full sentence, not a bare noun phrase"
else
    no "the K8S_PROXY_ALLOW-carried reason clause reads as a full sentence, not a bare noun phrase" \
        "$uncovered_carried_allow_err"
fi

# A K8S_PROXY_ALLOW entry that carries the port but only to a PRIVATE CIDR
# must NOT claim "WILL go through" -- an ExternalName CNAME to a public
# host still matches no ipBlock in that entry and is dropped, same as if
# nothing had matched the port at all. This is the fixture the previous
# test used to use (172.16.0.0/12, itself private) while asserting the
# public-carry wording -- moved here to assert the wording it should
# actually get.
uncovered_carried_private_allow_config_dir="$(newdir)"; tmpdirs+=("$uncovered_carried_private_allow_config_dir")
cat > "$uncovered_carried_private_allow_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_ENDPOINTS=primary=https://svc-a.example-ns.svc.cluster.local:8080/v1
K8S_PROXY_ALLOW=172.16.0.0/12:8080
K8S_DENIED_PROBE=10.0.0.1:443
CONF
uncovered_carried_private_allow_err="$(FORK_SANDBOX_CONFIG_DIR="$uncovered_carried_private_allow_config_dir" "$k8s_sh" \
    install --dry-run 2>&1 >/dev/null)"
if [[ "$uncovered_carried_private_allow_err" == *'every request to it will be dropped'* ]] \
    && [[ "$uncovered_carried_private_allow_err" != *'WILL go through'* ]]; then
    ok "a K8S_PROXY_ALLOW entry carrying the port to a private-only CIDR still warns it will be dropped"
else
    no "a K8S_PROXY_ALLOW entry carrying the port to a private-only CIDR still warns it will be dropped" \
        "$uncovered_carried_private_allow_err"
fi

rm -f /tmp/fs-k8s-test-allow-ns-install.err /tmp/fs-k8s-test-allow-ns-noport-install.err \
    /tmp/fs-k8s-test-combined-allow-install.err

printf '\n== K8S_PROXY_ENDPOINT_KEYS -- optionally-keyed named endpoints ==\n'
# 'primary' stays keyless; 'secondary' is keyed by MY_API_KEY in pi.env --
# invented names, per this repo's leak guard.
keyed_config_dir="$(newdir)"; tmpdirs+=("$keyed_config_dir")
cat > "$keyed_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_ENDPOINTS=primary=http://10.0.0.5:8001/v1,secondary=http://10.0.0.6:8000/v1
K8S_PROXY_ENDPOINT_KEYS=secondary=MY_API_KEY
K8S_DENIED_PROBE=10.0.0.1:443
CONF
install -m 600 /dev/null "$keyed_config_dir/pi.env"
printf 'MY_API_KEY=sk-secondary-test-dummy\n' >> "$keyed_config_dir/pi.env"

keyed_out="$(newdir)/keyed-install.yaml"; tmpdirs+=("$(dirname "$keyed_out")")
if FORK_SANDBOX_CONFIG_DIR="$keyed_config_dir" "$k8s_sh" install --dry-run \
    > "$keyed_out" 2>/tmp/fs-k8s-test-keyed-install.err; then
    ok "a keyed endpoints install --dry-run exits 0"
else
    no "a keyed endpoints install --dry-run exits 0" "$(cat /tmp/fs-k8s-test-keyed-install.err)"
fi

if grep -qF "would create/update Secret fork-sandbox-upstream-key entry for K8S_PROXY_ENDPOINTS endpoint 'secondary'" "$keyed_out"; then
    ok "install --dry-run announces the keyed Secret entry, naming the endpoint"
else
    no "install --dry-run announces the keyed Secret entry, naming the endpoint" "$keyed_out"
fi
if grep -qF 'sk-secondary-test-dummy' "$keyed_out"; then
    no "the keyed value never appears in --dry-run output" "found the fixture value in $keyed_out"
else
    ok "the keyed value never appears in --dry-run output"
fi
if grep -q 'kind: Secret' "$keyed_out"; then
    no "install --dry-run renders no Secret object itself (created separately, after apply)" \
        "found 'kind: Secret' in $keyed_out"
else
    ok "install --dry-run renders no Secret object itself (created separately, after apply)"
fi

# Both of 'secondary's locations carry the Authorization header (the
# brief's own "both paths" trap); 'primary' (keyless) carries neither.
secondary_chat_block="$(awk '/location = \/e\/secondary\/v1\/chat\/completions \{/,/^            \}/' "$keyed_out")"
secondary_models_block="$(awk '/location = \/e\/secondary\/v1\/models \{/,/^            \}/' "$keyed_out")"
primary_chat_block="$(awk '/location = \/e\/primary\/v1\/chat\/completions \{/,/^            \}/' "$keyed_out")"
primary_models_block="$(awk '/location = \/e\/primary\/v1\/models \{/,/^            \}/' "$keyed_out")"
if grep -qF 'Authorization "Bearer $upstream_key_secondary"' <<< "$secondary_chat_block"; then
    ok "the keyed endpoint's chat/completions location carries the Authorization header"
else
    no "the keyed endpoint's chat/completions location carries the Authorization header" "$secondary_chat_block"
fi
if grep -qF 'Authorization "Bearer $upstream_key_secondary"' <<< "$secondary_models_block"; then
    ok "the keyed endpoint's models location ALSO carries the Authorization header"
else
    no "the keyed endpoint's models location ALSO carries the Authorization header" "$secondary_models_block"
fi
if grep -q 'Authorization' <<< "$primary_chat_block"$'\n'"$primary_models_block"; then
    no "the unkeyed sibling endpoint carries no Authorization header" \
        "$primary_chat_block"$'\n'"$primary_models_block"
else
    ok "the unkeyed sibling endpoint carries no Authorization header"
fi

# The upstream-key include and volume stay in place (needed by the keyed
# endpoint), unlike an all-keyless install.
if grep -q 'include /etc/nginx/upstream-key.conf' "$keyed_out"; then
    ok "a keyed endpoints install keeps the upstream-key.conf include"
else
    no "a keyed endpoints install keeps the upstream-key.conf include" "$keyed_out"
fi
if grep -q 'secretName: fork-sandbox-upstream-key' "$keyed_out"; then
    ok "a keyed endpoints install keeps the upstream-key Secret volume"
else
    no "a keyed endpoints install keeps the upstream-key Secret volume" "$keyed_out"
fi

# Same coverage as 'nginx -t on the rendered proxy config' above, against
# the keyed render this time -- a genuinely third nginx.conf shape (the
# upstream-key.conf include restored, 'Authorization "Bearer
# $upstream_key_secondary"' in both of 'secondary's locations, and
# $upstream_key_secondary itself a per-endpoint variable that must be
# defined at server level before any location references it), which every
# assertion above this only greps YAML text for. The stub the two checks
# above stage defines only $upstream_key (the legacy/keyless shape) --
# this render never references that name, so it needs its own stub
# defining $upstream_key_secondary, or nginx would fail to start on an
# unknown variable. Reuses nginx_mode/run_nginx_t/proxy_image from the
# legacy check above.
keyed_nginx_conf="$(extract_nginx_conf "$keyed_out")"
if [[ -z "$keyed_nginx_conf" ]]; then
    no "extracted nginx.conf from keyed endpoints install --dry-run output" \
        "no nginx.conf block found in $keyed_out"
elif [[ -z "${nginx_mode:-}" ]]; then
    printf '  SKIP  neither nginx nor a working docker on PATH\n'
else
    keyed_nginx_check_dir="$(newdir)"; tmpdirs+=("$keyed_nginx_check_dir")
    printf '%s\n' "${keyed_nginx_conf//kube-dns.kube-system.svc.cluster.local/127.0.0.1}" \
        > "$keyed_nginx_check_dir/nginx.conf"
    # shellcheck disable=SC2016  # $upstream_key_secondary is nginx config, not shell
    printf 'set $upstream_key_secondary "dummy";\n' > "$keyed_nginx_check_dir/upstream-key.conf"
    out="$(run_nginx_t "$keyed_nginx_check_dir")"; rc=$?
    if (( rc == 0 )); then
        ok "nginx -t accepts the rendered keyed endpoints proxy config"
    else
        no "nginx -t accepts the rendered keyed endpoints proxy config" "$out"
    fi
fi

# A real (non-dry-run) install, against a stubbed kubectl (no live cluster
# needed -- same technique as the 'rm' section elsewhere in this file): the
# Secret this creates carries one 'set $upstream_key_<name> "value";' line
# for the keyed endpoint, and the value never appears anywhere else.
keyed_install_stub_bin="$(newdir)"; tmpdirs+=("$keyed_install_stub_bin")
keyed_install_log="$(newdir)/kubectl-keyed-install.log"; tmpdirs+=("$(dirname "$keyed_install_log")")
cat > "$keyed_install_stub_bin/kubectl" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$keyed_install_log"
case "\$*" in
    *"create secret"*) printf 'apiVersion: v1\nkind: Secret\n' ;;
    *) cat >/dev/null ;;
esac
exit 0
STUB
chmod +x "$keyed_install_stub_bin/kubectl"
if PATH="$keyed_install_stub_bin:$PATH" FORK_SANDBOX_CONFIG_DIR="$keyed_config_dir" \
    "$k8s_sh" install >/dev/null 2>/tmp/fs-k8s-test-keyed-real-install.err; then
    ok "a real (non-dry-run) keyed endpoints install exits 0 against a stubbed kubectl"
else
    no "a real (non-dry-run) keyed endpoints install exits 0 against a stubbed kubectl" \
        "$(cat /tmp/fs-k8s-test-keyed-real-install.err)"
fi
# shellcheck disable=SC2016  # $upstream_key_secondary is nginx config, not shell
if grep -qF 'create secret generic fork-sandbox-upstream-key --from-literal=upstream-key.conf=set $upstream_key_secondary "sk-secondary-test-dummy";' "$keyed_install_log"; then
    ok "the real install creates the Secret with one 'set \$upstream_key_<name>' line for the keyed endpoint"
else
    no "the real install creates the Secret with one 'set \$upstream_key_<name>' line for the keyed endpoint" \
        "$(cat "$keyed_install_log")"
fi
if grep -qF 'sk-secondary-test-dummy' /tmp/fs-k8s-test-keyed-real-install.err; then
    no "the real install's own stderr never carries the keyed value" \
        "$(cat /tmp/fs-k8s-test-keyed-real-install.err)"
else
    ok "the real install's own stderr never carries the keyed value"
fi

# An endpoint declared keyed but missing (or empty) in pi.env is an
# install-time error naming both the endpoint and the variable. This check
# now runs BEFORE the main manifest is rendered or `kubectl apply`'d (a
# typo'd K8S_PROXY_ENDPOINT_KEYS variable must never leave a namespace's
# shared proxy partially applied with no Secret behind it -- see
# strip_proxy_key_volume's own header), so the stubbed kubectl below must
# never be invoked at all; a log file, rather than just exit-0, proves
# that.
missing_var_stub_bin="$(newdir)"; tmpdirs+=("$missing_var_stub_bin")
missing_var_kubectl_log="$(newdir)/kubectl-missing-var.log"; tmpdirs+=("$(dirname "$missing_var_kubectl_log")")
cat > "$missing_var_stub_bin/kubectl" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$missing_var_kubectl_log"
cat >/dev/null
exit 0
STUB
chmod +x "$missing_var_stub_bin/kubectl"

missing_var_config_dir="$(newdir)"; tmpdirs+=("$missing_var_config_dir")
cp "$keyed_config_dir/k8s.env" "$missing_var_config_dir/k8s.env"
install -m 600 /dev/null "$missing_var_config_dir/pi.env"
refuses "a keyed endpoint whose pi.env variable is missing is refused, naming both" \
    "'secondary' keyed by MY_API_KEY, but MY_API_KEY is not set" \
    env PATH="$missing_var_stub_bin:$PATH" FORK_SANDBOX_CONFIG_DIR="$missing_var_config_dir" \
    "$k8s_sh" install
if [[ -s "$missing_var_kubectl_log" ]]; then
    no "a keyed endpoint whose pi.env variable is missing never invokes kubectl (checked before render/apply)" \
        "$(cat "$missing_var_kubectl_log")"
else
    ok "a keyed endpoint whose pi.env variable is missing never invokes kubectl (checked before render/apply)"
fi
refuses "install --dry-run also refuses a keyed endpoint whose pi.env variable is missing" \
    "'secondary' keyed by MY_API_KEY, but MY_API_KEY is not set" \
    env PATH="$missing_var_stub_bin:$PATH" FORK_SANDBOX_CONFIG_DIR="$missing_var_config_dir" \
    "$k8s_sh" install --dry-run

empty_var_config_dir="$(newdir)"; tmpdirs+=("$empty_var_config_dir")
cp "$keyed_config_dir/k8s.env" "$empty_var_config_dir/k8s.env"
install -m 600 /dev/null "$empty_var_config_dir/pi.env"
printf 'MY_API_KEY=\n' >> "$empty_var_config_dir/pi.env"
refuses "a keyed endpoint whose pi.env variable is empty is refused, naming both" \
    "'secondary' keyed by MY_API_KEY, but MY_API_KEY is not set" \
    env PATH="$missing_var_stub_bin:$PATH" FORK_SANDBOX_CONFIG_DIR="$empty_var_config_dir" \
    "$k8s_sh" install

# A keyed credential containing '"', '$' or '\' would break the nginx `set
# $var "...";` line it renders into -- refused by name at install time
# instead of shipping a crashlooping proxy with nothing in the install
# output to point at the cause.
unsafe_key_config_dir="$(newdir)"; tmpdirs+=("$unsafe_key_config_dir")
cp "$keyed_config_dir/k8s.env" "$unsafe_key_config_dir/k8s.env"
install -m 600 /dev/null "$unsafe_key_config_dir/pi.env"
printf 'MY_API_KEY=sk-a$b"c\n' >> "$unsafe_key_config_dir/pi.env"
refuses "a keyed credential containing a double quote or \$ is refused" \
    "would break the" \
    env PATH="$missing_var_stub_bin:$PATH" FORK_SANDBOX_CONFIG_DIR="$unsafe_key_config_dir" \
    "$k8s_sh" install --dry-run

# A backslash is nginx's own escape character inside a quoted string, so a
# trailing one escapes the closing quote of the rendered `set` line and
# makes a config nginx refuses to load -- the same crashloop the '"'/'$'
# check above prevents, and the same refusal.
backslash_key_config_dir="$(newdir)"; tmpdirs+=("$backslash_key_config_dir")
cp "$keyed_config_dir/k8s.env" "$backslash_key_config_dir/k8s.env"
install -m 600 /dev/null "$backslash_key_config_dir/pi.env"
printf 'MY_API_KEY=sk-trailing\\\n' >> "$backslash_key_config_dir/pi.env"
refuses "a keyed credential containing a backslash is refused" \
    "would break the" \
    env PATH="$missing_var_stub_bin:$PATH" FORK_SANDBOX_CONFIG_DIR="$backslash_key_config_dir" \
    "$k8s_sh" install --dry-run

# K8S_PROXY_UPSTREAM and a K8S_PROXY_ENDPOINTS URL render into the exact
# same nginx `set $upstream "...";` sink as OPENROUTER_API_KEY and a keyed
# credential above -- validate_upstream_url only inspects scheme and host,
# never the path, so a '"' in the URL's path must be refused the same way
# instead of injecting arbitrary nginx directives into the shared proxy's
# server block (a real, previously-unguarded injection: an unvalidated URL
# path here used to render straight into that sink).
nginx_unsafe_upstream_config_dir="$(newdir)"; tmpdirs+=("$nginx_unsafe_upstream_config_dir")
cat > "$nginx_unsafe_upstream_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_UPSTREAM=https://api.example.com/v1";return 302 "http://evil.example/x
K8S_DENIED_PROBE=10.0.0.1:443
CONF
install -m 600 /dev/null "$nginx_unsafe_upstream_config_dir/pi.env"
printf 'OPENROUTER_API_KEY=sk-test-dummy\n' >> "$nginx_unsafe_upstream_config_dir/pi.env"
refuses "a K8S_PROXY_UPSTREAM URL with a nginx-unsafe character is refused" \
    "would break the" \
    env FORK_SANDBOX_CONFIG_DIR="$nginx_unsafe_upstream_config_dir" "$k8s_sh" install --dry-run

nginx_unsafe_endpoint_config_dir="$(newdir)"; tmpdirs+=("$nginx_unsafe_endpoint_config_dir")
cat > "$nginx_unsafe_endpoint_config_dir/k8s.env" <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_ENDPOINTS=primary=http://10.0.0.5:8001/v1";return 302 "http://evil.example/x
K8S_DENIED_PROBE=10.0.0.1:443
CONF
refuses "a K8S_PROXY_ENDPOINTS URL with a nginx-unsafe character is refused" \
    "would break the" \
    env FORK_SANDBOX_CONFIG_DIR="$nginx_unsafe_endpoint_config_dir" "$k8s_sh" install --dry-run

# An unregistered endpoint name in K8S_PROXY_ENDPOINT_KEYS is an
# install-time error, nothing created.
unreg_key_config_dir="$(newdir)"; tmpdirs+=("$unreg_key_config_dir")
sed 's/^K8S_PROXY_ENDPOINT_KEYS=.*/K8S_PROXY_ENDPOINT_KEYS=bogus=MY_API_KEY/' \
    "$keyed_config_dir/k8s.env" > "$unreg_key_config_dir/k8s.env"
install -m 600 /dev/null "$unreg_key_config_dir/pi.env"
printf 'MY_API_KEY=sk-secondary-test-dummy\n' >> "$unreg_key_config_dir/pi.env"
refuses "an unregistered K8S_PROXY_ENDPOINT_KEYS endpoint name is refused" \
    "but 'bogus' is not" \
    env FORK_SANDBOX_CONFIG_DIR="$unreg_key_config_dir" "$k8s_sh" install --dry-run

# A duplicate endpoint name in K8S_PROXY_ENDPOINT_KEYS is a parse-time error.
dup_key_config_dir="$(newdir)"; tmpdirs+=("$dup_key_config_dir")
sed 's/^K8S_PROXY_ENDPOINT_KEYS=.*/K8S_PROXY_ENDPOINT_KEYS=secondary=MY_API_KEY,secondary=OTHER_KEY/' \
    "$keyed_config_dir/k8s.env" > "$dup_key_config_dir/k8s.env"
refuses "a K8S_PROXY_ENDPOINT_KEYS name registered twice is refused" \
    "endpoint 'secondary' more" \
    env FORK_SANDBOX_CONFIG_DIR="$dup_key_config_dir" "$k8s_sh" install --dry-run

# A K8S_PROXY_ENDPOINT_KEYS entry with a malformed VAR_NAME is a
# parse-time error.
bad_var_config_dir="$(newdir)"; tmpdirs+=("$bad_var_config_dir")
sed 's/^K8S_PROXY_ENDPOINT_KEYS=.*/K8S_PROXY_ENDPOINT_KEYS=secondary=not-a-valid-name/' \
    "$keyed_config_dir/k8s.env" > "$bad_var_config_dir/k8s.env"
refuses "a K8S_PROXY_ENDPOINT_KEYS entry with a malformed VAR_NAME is refused" \
    "is not a valid environment variable name" \
    env FORK_SANDBOX_CONFIG_DIR="$bad_var_config_dir" "$k8s_sh" install --dry-run

rm -f /tmp/fs-k8s-test-keyed-install.err /tmp/fs-k8s-test-keyed-real-install.err

rm -f /tmp/fs-k8s-test-endpoints-install.err /tmp/fs-k8s-test-allow-install.err \
    /tmp/fs-k8s-test-http-private.out /tmp/fs-k8s-test-http-private.err \
    /tmp/fs-k8s-test-endpoints-http-private.out /tmp/fs-k8s-test-endpoints-http-private.err \
    /tmp/fs-k8s-test-svc-dns.out /tmp/fs-k8s-test-svc-dns.err \
    /tmp/fs-k8s-test-custom-domain.out /tmp/fs-k8s-test-custom-domain.err

printf '\n== fork-sandbox-k8s.sh submit --dry-run --harness claude ==\n'
# The default (--harness pi, i.e. submit_out above) renders no claude-proxy
# object at all -- the per-run proxy is entirely opt-in.
if grep -q 'claude-proxy' "$submit_out"; then
    no "a pi run (default harness) renders no claude-proxy object" \
        "found 'claude-proxy' in $submit_out"
else
    ok "a pi run (default harness) renders no claude-proxy object"
fi

refuses "--harness takes only pi or claude" \
    "--harness takes 'pi' or 'claude'" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model claude-sonnet-5 --harness bogus \
    "$proj_dir" "$handoff_file"

# A fixture HOME carrying a Claude credential, so --harness claude never
# reads the real operator's ~/.claude/.credentials.json. The access token
# is a distinctive fixture string, checked below to never leak into any
# rendered output.
claude_home="$(newdir)"; tmpdirs+=("$claude_home")
mkdir -p "$claude_home/.claude"
claude_fixture_token="fixture-real-secret-token-do-not-leak"
claude_future_ms=$(( ($(date +%s) + 7200) * 1000 ))
cat > "$claude_home/.claude/.credentials.json" <<JSON
{"claudeAiOauth": {"accessToken": "$claude_fixture_token", "refreshToken": "fixture-refresh-token", "refreshTokenExpiresAt": 123, "expiresAt": $claude_future_ms, "scopes": ["user:inference"]}}
JSON

claude_submit_out="$(newdir)/claude-submit.yaml"; tmpdirs+=("$(dirname "$claude_submit_out")")
if HOME="$claude_home" FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model claude-sonnet-5 --harness claude \
    "$proj_dir" "$handoff_file" > "$claude_submit_out" 2>/tmp/fs-k8s-test-claude-submit.err; then
    ok "submit --dry-run --harness claude exits 0"
else
    no "submit --dry-run --harness claude exits 0" "$(cat /tmp/fs-k8s-test-claude-submit.err)"
fi
if command -v yamllint >/dev/null 2>&1; then
    # Line-length excluded, same as the --review-loop render below: this
    # ConfigMap embeds fork-sandbox-inbox-hook.sh's full prose-commented
    # source as a block-scalar value, and long lines in that string are
    # not a YAML structure problem -- see .yamllint's own header comment.
    out="$(yamllint -d "{extends: default, rules: {line-length: disable}}" "$claude_submit_out" 2>&1)"
    if [[ -z "$out" ]]; then ok "yamllint: submit --dry-run --harness claude output (line-length excluded)"
    else no "yamllint: submit --dry-run --harness claude output (line-length excluded)" "$out"; fi
fi
if grep -q '__RUN_NAME__' "$claude_submit_out" || grep -q '__NAMESPACE__' "$claude_submit_out"; then
    no "submit --dry-run --harness claude leaves no unsubstituted placeholder" \
        "found __RUN_NAME__ or __NAMESPACE__ in $claude_submit_out"
else
    ok "submit --dry-run --harness claude leaves no unsubstituted placeholder"
fi
# fork-sandbox-agent-fs-k8s-test-branch is k8s_safe_name's own output for
# prefix fork-sandbox-agent and branch fs-k8s-test-branch, the same
# derivation the rendered Job/ConfigMap names above already rely on.
claude_run_name="fork-sandbox-agent-fs-k8s-test-branch"
if grep -q '^kind: Pod$' "$claude_submit_out" && grep -q "name: $claude_run_name-claude-proxy\$" "$claude_submit_out"; then
    ok "rendered manifest carries the per-run claude-proxy Pod"
else
    no "rendered manifest carries the per-run claude-proxy Pod" "not found in $claude_submit_out"
fi
if grep -q '^kind: Service$' "$claude_submit_out"; then
    ok "rendered manifest carries the per-run claude-proxy Service"
else
    no "rendered manifest carries the per-run claude-proxy Service" "not found in $claude_submit_out"
fi
if grep -q "name: $claude_run_name-claude-proxy-conf" "$claude_submit_out"; then
    ok "rendered manifest carries the per-run claude-proxy ConfigMap"
else
    no "rendered manifest carries the per-run claude-proxy ConfigMap" "not found in $claude_submit_out"
fi
if grep -q "secretName: $claude_run_name-claude-token" "$claude_submit_out"; then
    ok "rendered claude-proxy Pod mounts this run's own claude-token Secret"
else
    no "rendered claude-proxy Pod mounts this run's own claude-token Secret" \
        "not found in $claude_submit_out"
fi
if grep -qF 'location = /v1/messages {' "$claude_submit_out" \
    && grep -qF 'location = /v1/messages/count_tokens {' "$claude_submit_out"; then
    ok "rendered claude-proxy nginx.conf forwards exactly the two v1/messages paths"
else
    no "rendered claude-proxy nginx.conf forwards exactly the two v1/messages paths" \
        "not found in $claude_submit_out"
fi
# The manifest's own comments explain in prose that anthropic-beta is
# passed through untouched, so this checks for a directive that would
# actually intercept it (proxy_set_header/proxy_hide_header naming it),
# not for the plain substring, which the prose itself contains.
if grep -qiE '(proxy_set_header|proxy_hide_header)[[:space:]]+anthropic-beta' "$claude_submit_out"; then
    no "rendered claude-proxy nginx.conf does not touch the anthropic-beta header" \
        "found a directive naming anthropic-beta in $claude_submit_out"
else
    ok "rendered claude-proxy nginx.conf does not touch the anthropic-beta header"
fi
if grep -qF 'app: fork-sandbox-proxy' "$claude_submit_out"; then
    ok "the claude-proxy Pod carries the shared app: fork-sandbox-proxy label"
else
    no "the claude-proxy Pod carries the shared app: fork-sandbox-proxy label" \
        "not found in $claude_submit_out"
fi
# fork-sandbox/role: model-proxy is the key that keeps this Pod OUT of the
# shared proxy's own Service and NetworkPolicy selectors (both tightened to
# require it -- see the install-render checks above). This Pod must never
# carry it itself, or it would opt back into both.
if grep -qF 'fork-sandbox/role: model-proxy' "$claude_submit_out"; then
    no "the claude-proxy Pod does not carry fork-sandbox/role: model-proxy" \
        "found in $claude_submit_out"
else
    ok "the claude-proxy Pod does not carry fork-sandbox/role: model-proxy"
fi
if grep -q "^kind: NetworkPolicy\$" "$claude_submit_out" \
    && grep -qF "name: $claude_run_name-claude-proxy" "$claude_submit_out"; then
    ok "rendered manifest carries the per-run claude-proxy NetworkPolicy"
else
    no "rendered manifest carries the per-run claude-proxy NetworkPolicy" \
        "not found in $claude_submit_out"
fi
if grep -qF 'fork-sandbox/role: claude-proxy' "$claude_submit_out" \
    && grep -qF "fork-sandbox/branch: $claude_run_name" "$claude_submit_out" \
    && grep -qF 'app: fork-sandbox-agent' "$claude_submit_out"; then
    ok "the per-run claude-proxy NetworkPolicy scopes ingress to this run's own agent Pod"
else
    no "the per-run claude-proxy NetworkPolicy scopes ingress to this run's own agent Pod" \
        "not found in $claude_submit_out"
fi
# The rendered ConfigMap's claude-credentials.json: sanitized (no
# refreshToken) and carrying the "sandbox" placeholder access token, never
# the fixture's real one -- the whole point of the substitution.
if grep -q '"accessToken": "sandbox"' "$claude_submit_out"; then
    ok "rendered claude-credentials.json carries the sandbox placeholder access token"
else
    no "rendered claude-credentials.json carries the sandbox placeholder access token" \
        "not found in $claude_submit_out"
fi
if grep -q 'refreshToken' "$claude_submit_out"; then
    no "rendered claude-credentials.json carries no refreshToken" \
        "found 'refreshToken' in $claude_submit_out"
else
    ok "rendered claude-credentials.json carries no refreshToken"
fi
if grep -qF "$claude_fixture_token" "$claude_submit_out"; then
    no "the rendered YAML never contains the fixture's real access token" \
        "found the fixture token in $claude_submit_out"
else
    ok "the rendered YAML never contains the fixture's real access token"
fi
if grep -q 'inbox-hook.sh: |' "$claude_submit_out"; then
    ok "rendered ConfigMap carries the inbox-hook.sh key"
else
    no "rendered ConfigMap carries the inbox-hook.sh key" "not found in $claude_submit_out"
fi
if grep -qF 'Addenda are pushed to you automatically' "$claude_submit_out"; then
    ok "rendered handoff.md preamble is worded for the claude harness (pushed, not polled)"
else
    no "rendered handoff.md preamble is worded for the claude harness (pushed, not polled)" \
        "not found in $claude_submit_out"
fi
if grep -q 'name: HARNESS' "$claude_submit_out" \
    && grep -A1 'name: HARNESS' "$claude_submit_out" | grep -q 'value: "claude"'; then
    ok "rendered Job sets HARNESS=claude"
else
    no "rendered Job sets HARNESS=claude" "not found in $claude_submit_out"
fi
if grep -q 'name: CLAUDE_PROXY_BASE_URL' "$claude_submit_out" \
    && grep -A1 'name: CLAUDE_PROXY_BASE_URL' "$claude_submit_out" \
        | grep -qF "http://$claude_run_name-claude-proxy.fork-sandbox-test.svc.cluster.local:8080"; then
    ok "rendered Job's CLAUDE_PROXY_BASE_URL names this run's own proxy Service"
else
    no "rendered Job's CLAUDE_PROXY_BASE_URL names this run's own proxy Service" \
        "not found in $claude_submit_out"
fi
if grep -A1 'name: PROXY_HOST' "$claude_submit_out" \
    | grep -qF "value: \"$claude_run_name-claude-proxy.fork-sandbox-test.svc.cluster.local\""; then
    ok "the egress-gate initContainer's PROXY_HOST names this run's own proxy Service"
else
    no "the egress-gate initContainer's PROXY_HOST names this run's own proxy Service" \
        "not found in $claude_submit_out"
fi
# The pi path's own PROXY_HOST is untouched by any of the above: a plain
# pi run keeps probing the shared proxy.
if grep -A1 'name: PROXY_HOST' "$submit_out" \
    | grep -qF 'value: "fork-sandbox-proxy.fork-sandbox-test.svc.cluster.local"'; then
    ok "a pi run's egress-gate PROXY_HOST still names the shared proxy"
else
    no "a pi run's egress-gate PROXY_HOST still names the shared proxy" "not found in $submit_out"
fi
if grep -q 'would create Secret' "$claude_submit_out"; then
    ok "submit --dry-run --harness claude notes the Secret it would create, without a value"
else
    no "submit --dry-run --harness claude notes the Secret it would create, without a value" \
        "not found in $claude_submit_out"
fi
rm -f /tmp/fs-k8s-test-claude-submit.err

printf '\n== fork-sandbox-k8s.sh submit --dry-run: --refresh-at / --refresh-max ==\n'
# A claude run refreshes by default (0.5 of a 200k window = 100000 tokens,
# cap 6), exactly like a local one: Job env, three ConfigMap keys, run.env.
refresh_dry() {
    HOME="$claude_home" FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
        --branch fs-k8s-test-branch --model claude-sonnet-5 "$@" \
        "$proj_dir" "$handoff_file" 2>&1
}
refresh_env_val() {
    grep -A1 "name: $1\$" <<< "$2" | sed -n 's/.*value: "\(.*\)"/\1/p'
}
refresh_default_out="$(refresh_dry --harness claude)"
check "claude default: REFRESH_THRESHOLD_TOKENS is 100000" "100000" \
    "$(refresh_env_val REFRESH_THRESHOLD_TOKENS "$refresh_default_out")"
check "claude default: REFRESH_MAX is 6" "6" \
    "$(refresh_env_val REFRESH_MAX "$refresh_default_out")"
check "claude default: REFRESH_CEILING_TOKENS is 160000 (0.8 of 200k)" "160000" \
    "$(refresh_env_val REFRESH_CEILING_TOKENS "$refresh_default_out")"
for key in refresh.sh continuation-header.md handoff-original.md; do
    if grep -qx "  $key: |" <<< "$refresh_default_out"; then
        ok "claude default: ConfigMap carries $key"
    else
        no "claude default: ConfigMap carries $key" "not found"
    fi
done
if grep -qF 'fs_refresh_take_handoff()' <<< "$refresh_default_out"; then
    ok "claude default: refresh.sh key carries the shared refresh functions"
else
    no "claude default: refresh.sh key carries the shared refresh functions" "not found"
fi
# handoff-original.md is the operator's file verbatim; the header is the
# rendered text BEFORE the separator, so header + separator + original is
# exactly the handoff.md key.
refresh_key_body() {
    awk -v k="  $1: |" '
        $0 == k { on = 1; next }
        on && /^  [a-z][a-z.-]*: / { exit }
        on && /^---$/ { exit }
        on { sub(/^    /, ""); print }' <<< "$2"
}
# Compared modulo trailing newlines (command substitution): the key is clip-chomped.
check "claude default: handoff-original.md is the operator handoff" \
    "$(cat "$handoff_file")" "$(refresh_key_body handoff-original.md "$refresh_default_out")"
check "claude default: handoff.md is header + separator + operator handoff" \
    "$(refresh_key_body continuation-header.md "$refresh_default_out")"$'\n\n---\n\n'"$(cat "$handoff_file")" \
    "$(refresh_key_body handoff.md "$refresh_default_out")"
if command -v yamllint >/dev/null 2>&1; then
    refresh_yaml="$(newdir)/refresh.yaml"; tmpdirs+=("$(dirname "$refresh_yaml")")
    printf '%s\n' "$refresh_default_out" > "$refresh_yaml"
    out="$(yamllint -d "{extends: default, rules: {line-length: disable}}" "$refresh_yaml" 2>&1)"
    if [[ -z "$out" ]]; then ok "yamllint: refresh-enabled claude render"
    else no "yamllint: refresh-enabled claude render" "$out"; fi
    # The key the pod sources must fit the 100-column YAML limit once
    # indented: run yamllint with line-length ENABLED over a document that
    # holds only the refresh keys.
    refresh_keys_yaml="$(newdir)/refresh-keys.yaml"; tmpdirs+=("$(dirname "$refresh_keys_yaml")")
    {
        printf '%s\n' '---' 'data:'
        awk '$0 == "  refresh.sh: |" { on = 1 }
             on && /^  [a-z][a-z.-]*: / && $0 != "  refresh.sh: |" { exit }
             on { print }' <<< "$refresh_default_out"
    } > "$refresh_keys_yaml"
    out="$(yamllint -d "{extends: default, rules: {line-length: {max: 100}}}" "$refresh_keys_yaml" 2>&1)"
    if [[ -z "$out" ]]; then ok "yamllint: refresh.sh ConfigMap key with line-length enabled"
    else no "yamllint: refresh.sh ConfigMap key with line-length enabled" "$out"; fi
fi
refresh_off_out="$(refresh_dry --harness claude --refresh-at 0)"
for pat in '- name: REFRESH_THRESHOLD_TOKENS' '- name: REFRESH_MAX' '- name: REFRESH_CEILING_TOKENS' '  refresh.sh: |' '  continuation-header.md: |' '  handoff-original.md: |'; do
    if grep -qF -- "$pat" <<< "$refresh_off_out"; then
        no "--refresh-at 0: no '$pat' in the render" "found"
    else
        ok "--refresh-at 0: no '$pat' in the render"
    fi
done
refresh_tok_out="$(refresh_dry --harness claude --refresh-at 150000 --refresh-max 3)"
check "--refresh-at 150000: REFRESH_THRESHOLD_TOKENS" "150000" \
    "$(refresh_env_val REFRESH_THRESHOLD_TOKENS "$refresh_tok_out")"
check "--refresh-max 3: REFRESH_MAX" "3" "$(refresh_env_val REFRESH_MAX "$refresh_tok_out")"
check "--refresh-at 150000: REFRESH_CEILING_TOKENS still 160000 (window-based)" "160000" \
    "$(refresh_env_val REFRESH_CEILING_TOKENS "$refresh_tok_out")"

# A brief that is already a large share of a leg's own working budget warns
# at submit time too, same rule and same fs_refresh_warn_brief helper as the
# local runner's --dry-run still runs far enough to reach this check.
big_brief_handoff="$(newdir)/big-handoff.md"; tmpdirs+=("$(dirname "$big_brief_handoff")")
head -c 200 /dev/zero | tr '\0' 'x' > "$big_brief_handoff"
big_brief_out="$(HOME="$claude_home" FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" \
    submit --dry-run --branch fs-k8s-test-branch --model claude-sonnet-5 \
    --harness claude --refresh-at 100 "$proj_dir" "$big_brief_handoff" 2>&1)"
if grep -qF -- 'this brief is 200 bytes' <<< "$big_brief_out"; then
    ok "submit warns at launch for a large brief"
else
    no "submit warns at launch for a large brief" "not found in: $big_brief_out"
fi
if grep -qF -- '100-token --refresh-at threshold' <<< "$big_brief_out"; then
    ok "submit's large-brief warning names the threshold"
else
    no "submit's large-brief warning names the threshold" "not found in: $big_brief_out"
fi
small_brief_out="$(HOME="$claude_home" FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" \
    submit --dry-run --branch fs-k8s-test-branch --model claude-sonnet-5 \
    --harness claude --refresh-at 100 "$proj_dir" "$handoff_file" 2>&1)"
if grep -q 'this brief is' <<< "$small_brief_out"; then
    no "submit triggers no large-brief warning for a small brief"
else
    ok "submit triggers no large-brief warning for a small brief"
fi

refuses "pi + --refresh-at is refused with the local message" \
    "Error: --refresh-at only works with --harness claude" \
    env HOME="$claude_home" FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model claude-sonnet-5 --harness pi --refresh-at 0.5 \
    "$proj_dir" "$handoff_file"
refuses "a bad --refresh-max is refused" \
    "--refresh-max" \
    env HOME="$claude_home" FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model claude-sonnet-5 --harness claude --refresh-max nope \
    "$proj_dir" "$handoff_file"
if grep -qF -- '- name: REFRESH_THRESHOLD_TOKENS' "$submit_out"; then
    no "a pi run (default harness) renders no refresh env" "found in $submit_out"
else
    ok "a pi run (default harness) renders no refresh env"
fi
# run delegates: the same flags reach submit through cmd_run.
run_refresh_out="$(HOME="$claude_home" FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" run --dry-run \
    --branch fs-k8s-test-branch --model claude-sonnet-5 --harness claude \
    --refresh-at 150000 --refresh-max 3 "$proj_dir" "$handoff_file" 2>&1)"
check "run --dry-run forwards --refresh-at" "150000" \
    "$(refresh_env_val REFRESH_THRESHOLD_TOKENS "$run_refresh_out")"
check "run --dry-run forwards --refresh-max" "3" "$(refresh_env_val REFRESH_MAX "$run_refresh_out")"

printf '\n== fork-sandbox-k8s.sh submit --dry-run --harness claude, CLAUDE_CREDENTIALS override ==\n'
# An empty HOME -- no ~/.claude at all -- so the default credential lookup
# has nothing to fall back to. Any of the three checks below succeeding
# proves the override in claude.env was actually read, not the default path
# silently working some other way.
claude_override_home="$(newdir)"; tmpdirs+=("$claude_override_home")

claude_override_config_dir="$(newdir)"; tmpdirs+=("$claude_override_config_dir")
cp "$config_dir/k8s.env" "$claude_override_config_dir/k8s.env"
install -m 600 /dev/null "$claude_override_config_dir/pi.env"
printf 'OPENROUTER_API_KEY=sk-test-dummy\n' >> "$claude_override_config_dir/pi.env"

claude_override_cred="$(newdir)/override-credentials.json"; tmpdirs+=("$(dirname "$claude_override_cred")")
claude_override_token="fixture-override-secret-token-do-not-leak"
cat > "$claude_override_cred" <<JSON
{"claudeAiOauth": {"accessToken": "$claude_override_token", "refreshToken": "fixture-override-refresh-token", "refreshTokenExpiresAt": 123, "expiresAt": $claude_future_ms, "scopes": ["user:inference"]}}
JSON
printf 'CLAUDE_CREDENTIALS=%s\n' "$claude_override_cred" > "$claude_override_config_dir/claude.env"

claude_override_out="$(newdir)/claude-override-submit.yaml"; tmpdirs+=("$(dirname "$claude_override_out")")
if HOME="$claude_override_home" FORK_SANDBOX_CONFIG_DIR="$claude_override_config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model claude-sonnet-5 --harness claude \
    "$proj_dir" "$handoff_file" > "$claude_override_out" 2>/tmp/fs-k8s-test-claude-override.err; then
    ok "submit --dry-run --harness claude with CLAUDE_CREDENTIALS exits 0 despite an empty HOME"
else
    no "submit --dry-run --harness claude with CLAUDE_CREDENTIALS exits 0 despite an empty HOME" \
        "$(cat /tmp/fs-k8s-test-claude-override.err)"
fi
if grep -q '"accessToken": "sandbox"' "$claude_override_out"; then
    ok "CLAUDE_CREDENTIALS override still renders the sandbox placeholder access token"
else
    no "CLAUDE_CREDENTIALS override still renders the sandbox placeholder access token" \
        "not found in $claude_override_out"
fi
if grep -qF "$claude_override_token" "$claude_override_out"; then
    no "CLAUDE_CREDENTIALS override's real access token never leaks into the output" \
        "found the override fixture token in $claude_override_out"
else
    ok "CLAUDE_CREDENTIALS override's real access token never leaks into the output"
fi
rm -f /tmp/fs-k8s-test-claude-override.err

# A CLAUDE_CREDENTIALS naming a file that does not exist must fail naming
# that path, not silently fall back to $HOME/.claude/.credentials.json
# (which this HOME does not even have) or the macOS Keychain.
claude_missing_config_dir="$(newdir)"; tmpdirs+=("$claude_missing_config_dir")
cp "$config_dir/k8s.env" "$claude_missing_config_dir/k8s.env"
install -m 600 /dev/null "$claude_missing_config_dir/pi.env"
printf 'OPENROUTER_API_KEY=sk-test-dummy\n' >> "$claude_missing_config_dir/pi.env"
claude_missing_cred="$claude_override_home/does-not-exist-credentials.json"
printf 'CLAUDE_CREDENTIALS=%s\n' "$claude_missing_cred" > "$claude_missing_config_dir/claude.env"
refuses "a missing CLAUDE_CREDENTIALS path fails naming that path" \
    "$claude_missing_cred" \
    env HOME="$claude_override_home" FORK_SANDBOX_CONFIG_DIR="$claude_missing_config_dir" \
    "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model claude-sonnet-5 --harness claude \
    "$proj_dir" "$handoff_file"

# An expired override credential must report the OVERRIDE path in its error
# -- proving fs_claude_credential_source (not just fs_read_claude_credential)
# is threaded the same override on this path too.
claude_expired_config_dir="$(newdir)"; tmpdirs+=("$claude_expired_config_dir")
cp "$config_dir/k8s.env" "$claude_expired_config_dir/k8s.env"
install -m 600 /dev/null "$claude_expired_config_dir/pi.env"
printf 'OPENROUTER_API_KEY=sk-test-dummy\n' >> "$claude_expired_config_dir/pi.env"
claude_expired_cred="$(newdir)/expired-credentials.json"; tmpdirs+=("$(dirname "$claude_expired_cred")")
claude_past_ms=$(( ($(date +%s) - 3600) * 1000 ))
cat > "$claude_expired_cred" <<JSON
{"claudeAiOauth": {"accessToken": "fixture-expired-token", "refreshToken": "fixture-refresh-token", "refreshTokenExpiresAt": 123, "expiresAt": $claude_past_ms, "scopes": ["user:inference"]}}
JSON
printf 'CLAUDE_CREDENTIALS=%s\n' "$claude_expired_cred" > "$claude_expired_config_dir/claude.env"
claude_expired_out="$(HOME="$claude_override_home" FORK_SANDBOX_CONFIG_DIR="$claude_expired_config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model claude-sonnet-5 --harness claude \
    "$proj_dir" "$handoff_file" 2>&1)"
claude_expired_rc=$?
if (( claude_expired_rc != 0 )) && [[ "$claude_expired_out" == *"the access token in $claude_expired_cred has expired"* ]]; then
    ok "an expired CLAUDE_CREDENTIALS override's error names the override path"
else
    no "an expired CLAUDE_CREDENTIALS override's error names the override path" \
        "status $claude_expired_rc: $claude_expired_out"
fi
if [[ "$claude_expired_out" == *"login Keychain"* ]]; then
    no "an expired CLAUDE_CREDENTIALS override's error does not mention the Keychain" \
        "found 'login Keychain' in: $claude_expired_out"
else
    ok "an expired CLAUDE_CREDENTIALS override's error does not mention the Keychain"
fi

# A claude_access_token containing '"', '$' or '\' renders into the exact
# same nginx `set $var "...";` sink as OPENROUTER_API_KEY and a keyed
# endpoint's credential above, so it must be refused the same way instead
# of shipping a per-run proxy Pod that crashloops with nothing in the
# install output pointing at the cause. Each fake token is an obvious
# dummy value, and the check below confirms it never appears verbatim in
# the command's combined output -- the value must never leak, even in an
# error message naming the credential.
for claude_unsafe_case in \
    'dquote:sk-ant-test-dummy\"broken' \
    'dollar:sk-ant-test-dummy$broken' \
    'backslash:sk-ant-test-dummy\\broken'; do
    claude_unsafe_label="${claude_unsafe_case%%:*}"
    claude_unsafe_json_token="${claude_unsafe_case#*:}"
    claude_unsafe_home="$(newdir)"; tmpdirs+=("$claude_unsafe_home")
    mkdir -p "$claude_unsafe_home/.claude"
    cat > "$claude_unsafe_home/.claude/.credentials.json" <<JSON
{"claudeAiOauth": {"accessToken": "$claude_unsafe_json_token", "refreshToken": "fixture-refresh-token", "refreshTokenExpiresAt": 123, "expiresAt": $claude_future_ms, "scopes": ["user:inference"]}}
JSON
    claude_unsafe_out="$(HOME="$claude_unsafe_home" \
        FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
        --branch fs-k8s-test-branch --model claude-sonnet-5 --harness claude \
        "$proj_dir" "$handoff_file" 2>&1)"
    claude_unsafe_rc=$?
    claude_unsafe_raw_token="$(printf '%s' "$claude_unsafe_json_token" | sed 's/\\"/"/g; s/\\\\/\\/g')"
    if (( claude_unsafe_rc != 0 )) && [[ "$claude_unsafe_out" == *"access token"* ]] \
        && [[ "$claude_unsafe_out" == *"would break the"* ]]; then
        ok "a claude access token containing a $claude_unsafe_label is refused"
    else
        no "a claude access token containing a $claude_unsafe_label is refused" \
            "status $claude_unsafe_rc: $claude_unsafe_out"
    fi
    if [[ "$claude_unsafe_out" == *"$claude_unsafe_raw_token"* ]]; then
        no "a claude access token containing a $claude_unsafe_label never leaks into the output" \
            "found the fake token in the command's output"
    else
        ok "a claude access token containing a $claude_unsafe_label never leaks into the output"
    fi
done

printf '\n== fork-sandbox-k8s.sh submit: --claude-credentials flag and the credential balancer ==\n'
# This entry point reads claude.env directly (unlike fork-sandbox.sh's own
# --k8s delegation, which resolves and forwards --claude-credentials
# instead) -- so it exercises fs_balance_claude_credential itself, the same
# lib function fork-sandbox.sh's local path calls. Full config-error and
# hook-exit-code coverage lives in fork-sandbox-balance-test.sh (the lib's
# own unit suite) and fork-sandbox-claude-credentials-test.sh (the local
# launcher's integration suite); this section only proves the same wiring
# reaches this entry point too -- one or two representative cases each,
# per those suites' own precedent, not a full re-sweep.

balance_config_dir="$(newdir)"; tmpdirs+=("$balance_config_dir")
cp "$config_dir/k8s.env" "$balance_config_dir/k8s.env"
install -m 600 /dev/null "$balance_config_dir/pi.env"
printf 'OPENROUTER_API_KEY=sk-test-dummy\n' >> "$balance_config_dir/pi.env"

balance_pool_a="$(newdir)/pool-a-credentials.json"; tmpdirs+=("$(dirname "$balance_pool_a")")
cat > "$balance_pool_a" <<JSON
{"claudeAiOauth": {"accessToken": "pool-a-tok", "refreshToken": "fixture-refresh-token", "refreshTokenExpiresAt": 123, "expiresAt": $claude_future_ms, "scopes": ["user:inference"]}}
JSON
balance_pool_b="$(newdir)/pool-b-credentials.json"; tmpdirs+=("$(dirname "$balance_pool_b")")
cat > "$balance_pool_b" <<JSON
{"claudeAiOauth": {"accessToken": "pool-b-tok", "refreshToken": "fixture-refresh-token", "refreshTokenExpiresAt": 123, "expiresAt": $claude_future_ms, "scopes": ["user:inference"]}}
JSON

# A fake hook executable named fork-sandbox-headroom-<name>, staged in its
# own PATH dir -- same shape as fork-sandbox-balance-test.sh's own fake_hook,
# duplicated here (as fork-sandbox-claude-credentials-test.sh's copy already
# is) since this suite drives the real k8s entry point rather than calling
# fs_balance_claude_credential directly.
balance_fake_hook() {
    local name="$1" body="$2" bindir
    bindir="$(newdir)"
    cat > "$bindir/fork-sandbox-headroom-$name" <<HOOK
#!/usr/bin/env bash
$body
HOOK
    chmod +x "$bindir/fork-sandbox-headroom-$name"
    printf '%s' "$bindir"
}

# The flag beats a configured pool: the hook must never be invoked. Exercised
# via --dry-run since the flag/balancer precedence and its existence checks
# all run before the dry-run render+exit.
balance_flag_marker="$(newdir)/hook-invoked-flag-wins"; tmpdirs+=("$(dirname "$balance_flag_marker")")
rm -f "$balance_flag_marker"
balance_hook_dir_flagwins="$(balance_fake_hook flagwins "touch $balance_flag_marker; printf '%s\n' \"\$1\"")"
{
    printf 'CLAUDE_CREDENTIAL_POOL=%s:%s\n' "$balance_pool_a" "$balance_pool_b"
    printf 'CLAUDE_HEADROOM_HOOK=flagwins\n'
} > "$balance_config_dir/claude.env"
if PATH="$balance_hook_dir_flagwins:$PATH" FORK_SANDBOX_CONFIG_DIR="$balance_config_dir" \
    "$k8s_sh" submit --dry-run --branch fs-k8s-test-branch --model claude-sonnet-5 \
    --harness claude --claude-credentials "$claude_override_cred" \
    "$proj_dir" "$handoff_file" >/tmp/fs-k8s-test-balance-flagwins.out 2>&1; then
    ok "--claude-credentials on submit beats a configured pool: exits 0"
else
    no "--claude-credentials on submit beats a configured pool: exits 0" \
        "$(cat /tmp/fs-k8s-test-balance-flagwins.out)"
fi
if [[ -f "$balance_flag_marker" ]]; then
    no "--claude-credentials on submit beats a configured pool: the hook is not invoked" \
        "marker file exists"
else
    ok "--claude-credentials on submit beats a configured pool: the hook is not invoked"
fi
rm -f /tmp/fs-k8s-test-balance-flagwins.out

# Happy path (hook's choice used, recorded into run.env/summary.json) needs
# a full non-dry-run submit through to a running pod -- driven further down
# in this file, in the "durable run log" section, once runstub_dir (the
# git+kubectl pair that fakes a whole cluster round trip) exists.

# A pure --harness pi submit must never invoke the hook, even with a valid
# pool and hook configured -- this harness has no claude leg to balance a
# credential for.
balance_pi_marker="$(newdir)/hook-invoked-pure-pi"; tmpdirs+=("$(dirname "$balance_pi_marker")")
rm -f "$balance_pi_marker"
balance_hook_dir_pi="$(balance_fake_hook pimarker "touch $balance_pi_marker; printf '%s\n' \"\$1\"")"
if PATH="$balance_hook_dir_pi:$PATH" FORK_SANDBOX_CONFIG_DIR="$balance_config_dir" \
    "$k8s_sh" submit --dry-run --branch fs-k8s-test-branch --model moonshotai/kimi-k3 \
    "$proj_dir" "$handoff_file" >/tmp/fs-k8s-test-balance-pi.out 2>&1; then
    ok "a pure pi submit never invokes the headroom hook: exits 0"
else
    no "a pure pi submit never invokes the headroom hook: exits 0" \
        "$(cat /tmp/fs-k8s-test-balance-pi.out)"
fi
if [[ -f "$balance_pi_marker" ]]; then
    no "a pure pi submit never invokes the headroom hook" "marker file exists"
else
    ok "a pure pi submit never invokes the headroom hook"
fi
rm -f /tmp/fs-k8s-test-balance-pi.out

# One representative config error: a pool without a hook is refused loudly,
# proving this entry point surfaces fs_balance_claude_credential's own
# error rather than swallowing it. Every config-error shape is already
# covered directly against the lib function by fork-sandbox-balance-test.sh.
printf 'CLAUDE_CREDENTIAL_POOL=%s\n' "$balance_pool_a" > "$balance_config_dir/claude.env"
refuses "submit: a pool without a hook is refused loudly" \
    "without" \
    env FORK_SANDBOX_CONFIG_DIR="$balance_config_dir" \
    "$k8s_sh" submit --dry-run --branch fs-k8s-test-branch --model claude-sonnet-5 \
    --harness claude "$proj_dir" "$handoff_file"

# Exit 2 (the hook's own "no routable candidate" answer) is a hard error
# naming the --claude-credentials pin as the escape hatch.
balance_hook_dir_noroute="$(balance_fake_hook noroute2 'exit 2')"
{
    printf 'CLAUDE_CREDENTIAL_POOL=%s\n' "$balance_pool_a"
    printf 'CLAUDE_HEADROOM_HOOK=noroute2\n'
} > "$balance_config_dir/claude.env"
refuses "submit: exit 2 (no routable candidate) is a hard error naming the flag override" \
    "no routable credential" \
    env PATH="$balance_hook_dir_noroute:$PATH" FORK_SANDBOX_CONFIG_DIR="$balance_config_dir" \
    "$k8s_sh" submit --dry-run --branch fs-k8s-test-branch --model claude-sonnet-5 \
    --harness claude "$proj_dir" "$handoff_file"

# The balancer's choice naming a missing file is a hard error, the same
# rule the explicit flag and CLAUDE_CREDENTIALS get below -- the pool is
# operator-authored, so a bad entry is this run's problem to raise, not to
# swallow. The pool entry is syntactically valid (absolute, no whitespace
# or colon) but does not exist on disk; exercised via --dry-run since this
# check runs before the dry-run render+exit.
balance_pool_missing="$(newdir)/pool-missing-credentials.json"; tmpdirs+=("$(dirname "$balance_pool_missing")")
balance_hook_dir_missing="$(balance_fake_hook missing2 'printf "%s\n" "$2"')"
{
    printf 'CLAUDE_CREDENTIAL_POOL=%s:%s\n' "$balance_pool_a" "$balance_pool_missing"
    printf 'CLAUDE_HEADROOM_HOOK=missing2\n'
} > "$balance_config_dir/claude.env"
refuses "submit: the balancer choosing a missing file is refused" \
    "the credential balancer chose" \
    env PATH="$balance_hook_dir_missing:$PATH" FORK_SANDBOX_CONFIG_DIR="$balance_config_dir" \
    "$k8s_sh" submit --dry-run --branch fs-k8s-test-branch --model claude-sonnet-5 \
    --harness claude "$proj_dir" "$handoff_file"
refuses "submit: the balancer-chose-missing-file error names the pool entry" \
    "$balance_pool_missing" \
    env PATH="$balance_hook_dir_missing:$PATH" FORK_SANDBOX_CONFIG_DIR="$balance_config_dir" \
    "$k8s_sh" submit --dry-run --branch fs-k8s-test-branch --model claude-sonnet-5 \
    --harness claude "$proj_dir" "$handoff_file"

# The new --claude-credentials flag itself: a missing path is refused naming
# it, both on submit directly and via run's forwarding into submit_argv.
rm -f "$balance_config_dir/claude.env"
balance_missing_cred="$(newdir)/does-not-exist-credentials.json"; tmpdirs+=("$(dirname "$balance_missing_cred")")
refuses "submit --claude-credentials naming a missing file is refused" \
    "$balance_missing_cred" \
    env FORK_SANDBOX_CONFIG_DIR="$balance_config_dir" \
    "$k8s_sh" submit --dry-run --branch fs-k8s-test-branch --model claude-sonnet-5 \
    --harness claude --claude-credentials "$balance_missing_cred" "$proj_dir" "$handoff_file"
refuses "run --claude-credentials naming a missing file is refused (forwarded to submit)" \
    "$balance_missing_cred" \
    env FORK_SANDBOX_CONFIG_DIR="$balance_config_dir" \
    "$k8s_sh" run --dry-run --branch fs-k8s-test-branch --model claude-sonnet-5 \
    --harness claude --claude-credentials "$balance_missing_cred" "$proj_dir" "$handoff_file"

# The existing valid flag credential still works end to end via --dry-run.
if PATH="$PATH" FORK_SANDBOX_CONFIG_DIR="$balance_config_dir" \
    "$k8s_sh" submit --dry-run --branch fs-k8s-test-branch --model claude-sonnet-5 \
    --harness claude --claude-credentials "$claude_override_cred" \
    "$proj_dir" "$handoff_file" >/tmp/fs-k8s-test-balance-flagok.out 2>&1; then
    ok "submit --claude-credentials naming an existing file exits 0"
else
    no "submit --claude-credentials naming an existing file exits 0" \
        "$(cat /tmp/fs-k8s-test-balance-flagok.out)"
fi
rm -f /tmp/fs-k8s-test-balance-flagok.out

# --claude-credentials naming a missing file is refused even on a
# --harness pi submit, which will never read the file -- the same
# "fail loud rather than silently drop it" rule fork-sandbox.sh's own two
# entry points apply to this identical flag. An earlier revision of this
# suite asserted the opposite (silently ignored on a non-claude harness);
# that was a real divergence from the other two call sites this round was
# meant to keep from drifting, fixed alongside this test.
refuses "--claude-credentials naming a missing file is refused even on a --harness pi submit" \
    "$balance_missing_cred" \
    env PATH="$PATH" FORK_SANDBOX_CONFIG_DIR="$balance_config_dir" \
    "$k8s_sh" submit --dry-run --branch fs-k8s-test-branch --model moonshotai/kimi-k3 \
    --claude-credentials "$balance_missing_cred" "$proj_dir" "$handoff_file"

# But a VALID --claude-credentials on a --harness pi submit still parses
# fine and is simply unused (this harness never reads a claude credential).
if PATH="$PATH" FORK_SANDBOX_CONFIG_DIR="$balance_config_dir" \
    "$k8s_sh" submit --dry-run --branch fs-k8s-test-branch --model moonshotai/kimi-k3 \
    --claude-credentials "$claude_override_cred" \
    "$proj_dir" "$handoff_file" >/tmp/fs-k8s-test-balance-pi-flag.out 2>&1; then
    ok "--claude-credentials naming an existing file on a --harness pi submit exits 0"
else
    no "--claude-credentials naming an existing file on a --harness pi submit exits 0" \
        "$(cat /tmp/fs-k8s-test-balance-pi-flag.out)"
fi
rm -f /tmp/fs-k8s-test-balance-pi-flag.out

# The cleanup trap must exist before Secret creation: a label failure leaves
# an unlabeled Secret behind, so only the explicit by-name delete can catch
# it. This stub makes that exact command fail and records the cleanup calls.
printf '\n== submit cleanup trap and safe-name uniqueness ==\n'
submit_stub_dir="$(newdir)"; tmpdirs+=("$submit_stub_dir")
cat > "$submit_stub_dir/kubectl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$K8S_STUB_LOG"
verb=""; for arg in "$@"; do case "$arg" in create|apply|label|delete|wait|exec|get) verb="$arg" ;; esac; done
case "$verb" in
    create) printf 'apiVersion: v1\nkind: Secret\n' ;;
    apply) cat >/dev/null ;;
    label) exit 37 ;;
    delete) : ;;
    *) : ;;
esac
STUB
chmod +x "$submit_stub_dir/kubectl"
label_stub_log="$(newdir)/kubectl.log"; tmpdirs+=("$(dirname "$label_stub_log")")
PATH="$submit_stub_dir:$PATH" K8S_STUB_LOG="$label_stub_log" HOME="$claude_home" \
    FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit \
    --branch fs-k8s-test-label-failure --model claude-sonnet-5 --harness claude \
    "$proj_dir" "$handoff_file" >/tmp/fs-k8s-test-label.out 2>&1
label_rc=$?
if (( label_rc == 0 )); then
    no "label failure makes submit fail and invokes by-name Secret cleanup" "submit unexpectedly succeeded"
else
    if grep -q 'label secret fork-sandbox-agent-fs-k8s-test-label-failure-claude-token' "$label_stub_log" \
        && grep -q 'delete secret fork-sandbox-agent-fs-k8s-test-label-failure-claude-token' "$label_stub_log"; then
        ok "label failure makes submit fail and invokes by-name Secret cleanup"
    else
        no "label failure makes submit fail and invokes by-name Secret cleanup" "$(cat "$label_stub_log")"
    fi
fi
rm -f /tmp/fs-k8s-test-label.out

# Long branches with the same truncated prefix must still name distinct
# objects, while the already-pinned short naming rule remains unchanged.
name_branch_a="same-prefix-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-branch-one"
name_branch_b="same-prefix-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-branch-two"
name_a_out="$(newdir)/a.yaml"; tmpdirs+=("$(dirname "$name_a_out")")
name_b_out="$(newdir)/b.yaml"; tmpdirs+=("$(dirname "$name_b_out")")
FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch "$name_branch_a" --model moonshotai/kimi-k3 "$proj_dir" "$handoff_file" >"$name_a_out"
FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch "$name_branch_b" --model moonshotai/kimi-k3 "$proj_dir" "$handoff_file" >"$name_b_out"
safe_a="$(awk '/^kind: Job$/{job=1} job && /^  name:/{print $2; exit}' "$name_a_out")"
safe_b="$(awk '/^kind: Job$/{job=1} job && /^  name:/{print $2; exit}' "$name_b_out")"
if [[ "$safe_a" != "$safe_b" && ${#safe_a} -le 50 && ${#safe_b} -le 50 ]]; then
    ok "long branch names get distinct safe names within the 50-byte cap"
else
    no "long branch names get distinct safe names within the 50-byte cap" "a='$safe_a' b='$safe_b'"
fi
if grep -q 'name: fork-sandbox-agent-fs-k8s-test-branch$' "$submit_out"; then
    ok "short branch safe name remains unchanged"
else
    no "short branch safe name remains unchanged" "expected pinned short name"
fi

# Normalization is lossy even for short branches. Each colliding pair must
# receive a digest-bearing name, so submitting one cannot overwrite the
# other's objects (and cleanup cannot remove the wrong run).
normalized_a_out="$(newdir)/normalized-a.yaml"; tmpdirs+=("$(dirname "$normalized_a_out")")
normalized_b_out="$(newdir)/normalized-b.yaml"; tmpdirs+=("$(dirname "$normalized_b_out")")
FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch feature/foo --model moonshotai/kimi-k3 "$proj_dir" "$handoff_file" >"$normalized_a_out"
FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch feature-foo --model moonshotai/kimi-k3 "$proj_dir" "$handoff_file" >"$normalized_b_out"
normalized_a="$(awk '/^kind: Job$/{job=1} job && /^  name:/{print $2; exit}' "$normalized_a_out")"
normalized_b="$(awk '/^kind: Job$/{job=1} job && /^  name:/{print $2; exit}' "$normalized_b_out")"
if [[ "$normalized_a" != "$normalized_b" && "$normalized_a" =~ -[0-9a-f]{8}$ \
        && ${#normalized_a} -le 50 && ${#normalized_b} -le 50 ]]; then
    ok "slash and dash branch names get distinct digest-bearing safe names"
else
    no "slash and dash branch names get distinct digest-bearing safe names" \
        "a='$normalized_a' b='$normalized_b'"
fi

FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch FeatureFoo --model moonshotai/kimi-k3 "$proj_dir" "$handoff_file" >"$normalized_a_out"
FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch featurefoo --model moonshotai/kimi-k3 "$proj_dir" "$handoff_file" >"$normalized_b_out"
normalized_a="$(awk '/^kind: Job$/{job=1} job && /^  name:/{print $2; exit}' "$normalized_a_out")"
normalized_b="$(awk '/^kind: Job$/{job=1} job && /^  name:/{print $2; exit}' "$normalized_b_out")"
if [[ "$normalized_a" != "$normalized_b" && "$normalized_a" =~ -[0-9a-f]{8}$ \
        && ${#normalized_a} -le 50 && ${#normalized_b} -le 50 ]]; then
    ok "case-colliding branch names get distinct digest-bearing safe names"
else
    no "case-colliding branch names get distinct digest-bearing safe names" \
        "a='$normalized_a' b='$normalized_b'"
fi

printf '\n== fork-sandbox-k8s.sh submit --dry-run --harness claude (long branch name) ==\n'
# k8s_safe_name used to cap at 63 with no budget for the "-claude-proxy"
# suffix appended afterward, so any branch whose sanitized form was 32+
# characters rendered an over-63-char Service name and submit aborted after
# the Secret, ConfigMap and Pod for the run already existed. This branch's
# sanitized form is well past that threshold.
long_branch="claude-harness-review-fix-round-2-with-extra-words-appended-to-push-well-past-any-reasonable-cap"
long_submit_out="$(newdir)/claude-long-submit.yaml"; tmpdirs+=("$(dirname "$long_submit_out")")
if HOME="$claude_home" FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch "$long_branch" --model claude-sonnet-5 --harness claude \
    "$proj_dir" "$handoff_file" > "$long_submit_out" 2>/tmp/fs-k8s-test-claude-long-submit.err; then
    ok "submit --dry-run --harness claude (long branch) exits 0"
else
    no "submit --dry-run --harness claude (long branch) exits 0" \
        "$(cat /tmp/fs-k8s-test-claude-long-submit.err)"
fi
# The claude-proxy Service name must still fit a Service's 63-char RFC 1035
# label cap once the "-claude-proxy" suffix (13 chars) lands on it.
long_proxy_name="$(grep -m1 '^kind: Service$' -A2 "$long_submit_out" \
    | sed -n 's/^ *name: //p')"
if [[ -n "$long_proxy_name" && ${#long_proxy_name} -le 63 ]]; then
    ok "long-branch claude-proxy Service name fits the 63-char label cap (${#long_proxy_name} chars)"
else
    no "long-branch claude-proxy Service name fits the 63-char label cap" \
        "name='$long_proxy_name' (${#long_proxy_name} chars) in $long_submit_out"
fi
rm -f /tmp/fs-k8s-test-claude-long-submit.err

# submit_out above carries no --review-model, so it must render no
# REVIEW_MODEL env at all -- the flag is opt-in for both harnesses.
if grep -q 'name: REVIEW_MODEL' "$submit_out"; then
    no "a submit with no --review-model renders no REVIEW_MODEL env" \
        "found 'name: REVIEW_MODEL' in $submit_out"
else
    ok "a submit with no --review-model renders no REVIEW_MODEL env"
fi

printf '\n== fork-sandbox-k8s.sh submit --dry-run --review-model (both harnesses) ==\n'
# REVIEW_MODEL now renders for --harness pi too, not just claude -- the
# review loop always runs pi and needs to know which id to prefer
# regardless of the coding leg's own harness.
pi_rm_submit_out="$(newdir)/pi-rm-submit.yaml"; tmpdirs+=("$(dirname "$pi_rm_submit_out")")
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3 --review-model opus \
    "$proj_dir" "$handoff_file" > "$pi_rm_submit_out" 2>/tmp/fs-k8s-test-pi-rm-submit.err; then
    ok "submit --dry-run --harness pi --review-model exits 0"
else
    no "submit --dry-run --harness pi --review-model exits 0" \
        "$(cat /tmp/fs-k8s-test-pi-rm-submit.err)"
fi
if grep -q 'name: REVIEW_MODEL' "$pi_rm_submit_out" \
    && grep -A1 'name: REVIEW_MODEL' "$pi_rm_submit_out" | grep -q 'value: "opus"'; then
    ok "a pi run's rendered Job sets REVIEW_MODEL when --review-model is given"
else
    no "a pi run's rendered Job sets REVIEW_MODEL when --review-model is given" \
        "not found in $pi_rm_submit_out"
fi
if grep -q 'name: CLAUDE_PROXY_BASE_URL' "$pi_rm_submit_out"; then
    no "a pi run with --review-model still renders no CLAUDE_PROXY_BASE_URL" \
        "found 'name: CLAUDE_PROXY_BASE_URL' in $pi_rm_submit_out"
else
    ok "a pi run with --review-model still renders no CLAUDE_PROXY_BASE_URL"
fi
rm -f /tmp/fs-k8s-test-pi-rm-submit.err

claude_rm_submit_out="$(newdir)/claude-rm-submit.yaml"; tmpdirs+=("$(dirname "$claude_rm_submit_out")")
if HOME="$claude_home" FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model claude-sonnet-5 --harness claude --review-model opus \
    "$proj_dir" "$handoff_file" > "$claude_rm_submit_out" 2>/tmp/fs-k8s-test-claude-rm-submit.err; then
    ok "submit --dry-run --harness claude --review-model exits 0"
else
    no "submit --dry-run --harness claude --review-model exits 0" \
        "$(cat /tmp/fs-k8s-test-claude-rm-submit.err)"
fi
if grep -q 'name: REVIEW_MODEL' "$claude_rm_submit_out" \
    && grep -A1 'name: REVIEW_MODEL' "$claude_rm_submit_out" | grep -q 'value: "opus"'; then
    ok "a claude run's rendered Job sets REVIEW_MODEL when --review-model is given"
else
    no "a claude run's rendered Job sets REVIEW_MODEL when --review-model is given" \
        "not found in $claude_rm_submit_out"
fi
rm -f /tmp/fs-k8s-test-claude-rm-submit.err

printf '\n== fork-sandbox-k8s.sh submit/run --pi-args ==\n'
# --pi-args is extra arguments for the pod's pi coding leg. It travels
# the same path --model takes: into the rendered Job's env (PI_ARGS),
# then into the pi command line in the entrypoint -- and is refused, at
# parse time, on a claude run and for values fs_reject_unsafe_chars
# rejects, before anything is created.
pialg_submit_out="$(newdir)/pialg-submit.yaml"; tmpdirs+=("$(dirname "$pialg_submit_out")")
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3 \
    --pi-args "--thinking low" \
    "$proj_dir" "$handoff_file" > "$pialg_submit_out" 2>/tmp/fs-k8s-test-pialg-submit.err; then
    ok "submit --dry-run --pi-args exits 0 and prints the rendered YAML"
else
    no "submit --dry-run --pi-args exits 0 and prints the rendered YAML" \
        "$(cat /tmp/fs-k8s-test-pialg-submit.err)"
fi
if grep -q 'name: PI_ARGS' "$pialg_submit_out" \
    && grep -A1 'name: PI_ARGS' "$pialg_submit_out" | grep -q 'value: "--thinking low"'; then
    ok "the rendered Job carries PI_ARGS with the value verbatim"
else
    no "the rendered Job carries PI_ARGS with the value verbatim" \
        "$(grep -A1 'name: PI_ARGS' "$pialg_submit_out")"
fi
rm -f /tmp/fs-k8s-test-pialg-submit.err

# submit_out above carries no --pi-args, so it must render no PI_ARGS env
# at all -- absence asserted, not an empty value.
if grep -q 'name: PI_ARGS' "$submit_out"; then
    no "a submit with no --pi-args renders no PI_ARGS env" \
        "found 'name: PI_ARGS' in $submit_out"
else
    ok "a submit with no --pi-args renders no PI_ARGS env"
fi

# The pod-side half of the contract: run_pi_coding_leg, extracted from
# the entrypoint's own source and run against a stubbed pi that records
# its argv -- the same function-extraction this suite uses for
# discover_model_facts. The stub's record is its own argv count first, so
# an empty-string argument (which pi would see as a positional) is
# visible even at the end of the line.
pialg_fn="$(sed -n '/^run_pi_coding_leg() {/,/^}/p' "$entrypoint_sh")"
pialg_fn_file="$(newdir)/run-pi-leg.sh"; tmpdirs+=("$(dirname "$pialg_fn_file")")
if [[ -n "$pialg_fn" ]]; then
    printf '%s\n' 'set -euo pipefail' \
        ': "${PI_ARGS:=}"' \
        "$pialg_fn" \
        'run_pi_coding_leg' > "$pialg_fn_file"
    ok "run_pi_coding_leg is a standalone function in the entrypoint"
else
    no "run_pi_coding_leg is a standalone function in the entrypoint" \
        "function not found in $entrypoint_sh"
fi
# $1 = the PI_ARGS value to pass (unset when called with no argument).
# PIALG_RECORD ends up holding the stub pi's recorded argv (count line
# first, then one argument per line). Called directly, never inside a
# command substitution, so the tmpdirs it registers are not lost in a
# subshell.
PIALG_RECORD=""
pialg_run() {
    local stub_dir record mounts work
    stub_dir="$(newdir)"; tmpdirs+=("$stub_dir")
    record="$(newdir)/pi-argv.txt"; tmpdirs+=("$(dirname "$record")")
    printf '%s\n' '#!/usr/bin/env bash' \
        'printf "%s\n" "$#" > "$PI_ARGV_RECORD"' \
        'printf "%s\n" "$@" >> "$PI_ARGV_RECORD"' \
        'exit 0' > "$stub_dir/pi"
    chmod +x "$stub_dir/pi"
    mounts="$(newdir)"; tmpdirs+=("$mounts")
    work="$(newdir)"; tmpdirs+=("$work")
    printf 'Do the thing.\n' > "$mounts/handoff.md"
    PIALG_RECORD="$record"
    if [[ $# -gt 0 ]]; then
        PI_ARGS="$1" PI_ARGV_RECORD="$record" PATH="$stub_dir:$PATH" \
            MODEL="moonshotai/kimi-k3" mounts_dir="$mounts" work_dir="$work" \
            SESSION_HARNESS_STORE="${PIALG_SESSION_HARNESS_STORE:-}" \
            SESSION_ID="${PIALG_SESSION_ID:-}" session_store_dir="$work/session-store" \
            bash "$pialg_fn_file" >/dev/null
    else
        PI_ARGV_RECORD="$record" PATH="$stub_dir:$PATH" \
            MODEL="moonshotai/kimi-k3" mounts_dir="$mounts" work_dir="$work" \
            SESSION_HARNESS_STORE="${PIALG_SESSION_HARNESS_STORE:-}" \
            SESSION_ID="${PIALG_SESSION_ID:-}" session_store_dir="$work/session-store" \
            bash "$pialg_fn_file" >/dev/null
    fi
}
# The stub's $@ never includes the command name itself, so the base
# invocation records seven arguments.
pialg_base="--provider
proxy
--model
moonshotai/kimi-k3
--mode
json
-p"
pialg_run "--thinking low"
pialg_two="$(cat "$PIALG_RECORD")"
pialg_expected_two="$pialg_base"$'\n--thinking\nlow'
if [[ "$(printf '%s\n' "$pialg_two" | head -n1)" == 9 ]] \
    && [[ "$(printf '%s\n' "$pialg_two" | tail -n2)" == $'--thinking\nlow' ]] \
    && printf '%s\n' "$pialg_two" | grep -qx -- '--thinking' \
    && printf '%s\n' "$pialg_two" | grep -qx -- 'low' \
    && ! printf '%s\n' "$pialg_two" | grep -qxF -- '--thinking low' \
    && [[ "$(printf '%s\n' "$pialg_two" | tail -n +2)" == "$pialg_expected_two" ]]; then
    ok "the entrypoint's pi line receives PI_ARGS as two arguments, appended to the base flags"
else
    no "the entrypoint's pi line receives PI_ARGS as two arguments, appended to the base flags" \
        "record: $(printf '%s\n' "$pialg_two" | tr '\n' '|')"
fi
pialg_run
pialg_none="$(cat "$PIALG_RECORD")"
pialg_run ""
pialg_empty="$(cat "$PIALG_RECORD")"
for case_none in "none:$pialg_none" "empty:$pialg_empty"; do
    pialg_case_name="${case_none%%:*}"
    pialg_case_val="${case_none#*:}"
    if [[ "$(printf '%s\n' "$pialg_case_val" | head -n1)" == 7 ]] \
        && [[ "$(printf '%s\n' "$pialg_case_val" | tail -n +2)" == "$pialg_base" ]]; then
        ok "an unset/empty PI_ARGS adds no arguments at all ($pialg_case_name)"
    else
        no "an unset/empty PI_ARGS adds no arguments at all ($pialg_case_name)" \
            "record: $(printf '%s\n' "$pialg_case_val" | tr '\n' '|')"
    fi
done

# SESSION_HARNESS_STORE=1 (R3a section 4): run_pi_coding_leg appends
# --session-dir/--session-id to the pi argv right after the base flags
# and ahead of PI_ARGS -- coding leg only, since this function is never
# called for a review-loop pi leg.
PIALG_SESSION_HARNESS_STORE=1 PIALG_SESSION_ID=deadbeef-0000-0000-0000-000000000000 \
    pialg_run
pialg_sess="$(cat "$PIALG_RECORD")"
# The literal work dir is only known inside pialg_run, so compare the
# session-dir line by its own basename rather than the whole path.
if [[ "$(printf '%s\n' "$pialg_sess" | head -n1)" == 11 ]] \
    && [[ "$(printf '%s\n' "$pialg_sess" | sed -n '2,8p')" == "$pialg_base" ]] \
    && [[ "$(printf '%s\n' "$pialg_sess" | sed -n '9p')" == "--session-dir" ]] \
    && [[ "$(printf '%s\n' "$pialg_sess" | sed -n '10p')" == */session-store ]] \
    && [[ "$(printf '%s\n' "$pialg_sess" | sed -n '11,12p')" == $'--session-id\ndeadbeef-0000-0000-0000-000000000000' ]]; then
    ok "SESSION_HARNESS_STORE=1 appends --session-dir/--session-id to the pi coding leg's argv"
else
    no "SESSION_HARNESS_STORE=1 appends --session-dir/--session-id to the pi coding leg's argv" \
        "record: $(printf '%s\n' "$pialg_sess" | tr '\n' '|')"
fi
PIALG_SESSION_HARNESS_STORE="" PIALG_SESSION_ID="" pialg_run
pialg_nosess="$(cat "$PIALG_RECORD")"
if [[ "$(printf '%s\n' "$pialg_nosess" | head -n1)" == 7 ]] \
    && [[ "$(printf '%s\n' "$pialg_nosess" | tail -n +2)" == "$pialg_base" ]]; then
    ok "an unset SESSION_HARNESS_STORE adds no session flags to the pi coding leg's argv"
else
    no "an unset SESSION_HARNESS_STORE adds no session flags to the pi coding leg's argv" \
        "record: $(printf '%s\n' "$pialg_nosess" | tr '\n' '|')"
fi
PIALG_SESSION_HARNESS_STORE=1 pialg_run
pialg_sess_noid="$(cat "$PIALG_RECORD")"
if [[ "$(printf '%s\n' "$pialg_sess_noid" | head -n1)" == 9 ]] \
    && [[ "$(printf '%s\n' "$pialg_sess_noid" | sed -n '2,8p')" == "$pialg_base" ]] \
    && [[ "$(printf '%s\n' "$pialg_sess_noid" | sed -n '9p')" == "--session-dir" ]] \
    && ! printf '%s\n' "$pialg_sess_noid" | grep -qxF -- '--session-id'; then
    ok "SESSION_HARNESS_STORE=1 with no SESSION_ID adds --session-dir but no --session-id"
else
    no "SESSION_HARNESS_STORE=1 with no SESSION_ID adds --session-dir but no --session-id" \
        "record: $(printf '%s\n' "$pialg_sess_noid" | tr '\n' '|')"
fi
PIALG_SESSION_HARNESS_STORE="" PIALG_SESSION_ID=""
# run_pi_coding_leg (used by the coding leg only) is the sole caller of
# --session-dir/--session-id in the entrypoint -- review-loop.sh, the
# review/fix legs' own control flow, is a separate script this function
# never touches, so those legs get no session flags by construction.
if [[ "$(grep -c -- '--session-dir' "$entrypoint_sh")" == 1 ]]; then
    ok "the entrypoint names --session-dir exactly once, inside run_pi_coding_leg (coding leg only)"
else
    no "the entrypoint names --session-dir exactly once, inside run_pi_coding_leg (coding leg only)" \
        "$(grep -n -- '--session-dir' "$entrypoint_sh")"
fi

# An unsafe character in the value is refused at parse time -- and the
# refusal is before any Job, Secret or proxy Pod exists. Proven against a
# stubbed kubectl (no --dry-run here) whose log must stay empty.
refuses "submit --pi-args with a single quote is refused" \
    "single quote" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3 \
    --pi-args "--thinking it's" \
    "$proj_dir" "$handoff_file"
# A double quote and a backslash are refused too: the rendered Job embeds
# the value as a double-quoted YAML scalar, where a quote would break the
# manifest and a backslash would be re-escaped by the YAML parser into a
# value different from the one split and passed to pi.
refuses "submit --pi-args with a double quote is refused" \
    "double quote" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3 \
    --pi-args 'a"b' \
    "$proj_dir" "$handoff_file"
refuses "submit --pi-args with a backslash is refused" \
    "backslash" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3 \
    --pi-args 'a\nb' \
    "$proj_dir" "$handoff_file"
pialg_stub_bin="$(newdir)"; tmpdirs+=("$pialg_stub_bin")
pialg_klog="$(newdir)/kubectl.log"; tmpdirs+=("$(dirname "$pialg_klog")")
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$*" >> "$K8S_STUB_LOG"' > "$pialg_stub_bin/kubectl"
chmod +x "$pialg_stub_bin/kubectl"
pialg_rc=0
PATH="$pialg_stub_bin:$PATH" K8S_STUB_LOG="$pialg_klog" \
    FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3 \
    --pi-args "--thinking it's" \
    "$proj_dir" "$handoff_file" >/tmp/fs-k8s-test-pialg-unsafe.out 2>&1 || pialg_rc=$?
if (( pialg_rc != 0 )) && [[ ! -s "$pialg_klog" ]] \
    && grep -q 'single quote' /tmp/fs-k8s-test-pialg-unsafe.out; then
    ok "a refused --pi-args value creates nothing (the stubbed kubectl recorded no call)"
else
    no "a refused --pi-args value creates nothing (the stubbed kubectl recorded no call)" \
        "rc=$pialg_rc log=$(cat "$pialg_klog") out=$(cat /tmp/fs-k8s-test-pialg-unsafe.out)"
fi
rm -f /tmp/fs-k8s-test-pialg-unsafe.out
# Same "nothing created" proof for the YAML-scalar rejections: a double
# quote and a backslash must also die before the first kubectl call.
pialg_rc=0
PATH="$pialg_stub_bin:$PATH" K8S_STUB_LOG="$pialg_klog" \
    FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3 \
    --pi-args 'a"b' \
    "$proj_dir" "$handoff_file" >/tmp/fs-k8s-test-pialg-unsafe.out 2>&1 || pialg_rc=$?
if (( pialg_rc != 0 )) && [[ ! -s "$pialg_klog" ]] \
    && grep -q 'double quote' /tmp/fs-k8s-test-pialg-unsafe.out; then
    ok "a --pi-args value with a double quote creates nothing (the stubbed kubectl recorded no call)"
else
    no "a --pi-args value with a double quote creates nothing (the stubbed kubectl recorded no call)" \
        "rc=$pialg_rc log=$(cat "$pialg_klog") out=$(cat /tmp/fs-k8s-test-pialg-unsafe.out)"
fi
rm -f /tmp/fs-k8s-test-pialg-unsafe.out
pialg_rc=0
PATH="$pialg_stub_bin:$PATH" K8S_STUB_LOG="$pialg_klog" \
    FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3 \
    --pi-args 'a\nb' \
    "$proj_dir" "$handoff_file" >/tmp/fs-k8s-test-pialg-unsafe.out 2>&1 || pialg_rc=$?
if (( pialg_rc != 0 )) && [[ ! -s "$pialg_klog" ]] \
    && grep -q 'backslash' /tmp/fs-k8s-test-pialg-unsafe.out; then
    ok "a --pi-args value with a backslash creates nothing (the stubbed kubectl recorded no call)"
else
    no "a --pi-args value with a backslash creates nothing (the stubbed kubectl recorded no call)" \
        "rc=$pialg_rc log=$(cat "$pialg_klog") out=$(cat /tmp/fs-k8s-test-pialg-unsafe.out)"
fi
rm -f /tmp/fs-k8s-test-pialg-unsafe.out

refuses "submit --pi-args with --harness claude is refused" \
    "passes flags to pi, which a claude run" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model claude-sonnet-5 --harness claude \
    --pi-args "--thinking low" \
    "$proj_dir" "$handoff_file"

# run forwards --pi-args to submit unchanged: the same arguments must
# render byte-for-byte the same YAML as the direct submit call.
pialg_run_out="$(newdir)/pialg-run.yaml"; tmpdirs+=("$(dirname "$pialg_run_out")")
pialg_run_err="$(newdir)/pialg-run.err"; tmpdirs+=("$(dirname "$pialg_run_err")")
pialg_run_submit_out="$(newdir)/pialg-run-submit.yaml"; tmpdirs+=("$(dirname "$pialg_run_submit_out")")
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" run --dry-run \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3 \
    --pi-args "--thinking low" \
    "$proj_dir" "$handoff_file" > "$pialg_run_out" 2>"$pialg_run_err" \
    && FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3 \
    --pi-args "--thinking low" \
    "$proj_dir" "$handoff_file" > "$pialg_run_submit_out" 2>/dev/null; then
    ok "run --dry-run --pi-args exits 0"
else
    no "run --dry-run --pi-args exits 0" "$(cat "$pialg_run_err")"
fi
if diff -q "$pialg_run_out" "$pialg_run_submit_out" >/dev/null 2>&1; then
    ok "run --dry-run --pi-args renders byte-for-byte the same YAML as submit (forwarded unchanged)"
else
    no "run --dry-run --pi-args renders byte-for-byte the same YAML as submit (forwarded unchanged)" \
        "$(diff "$pialg_run_out" "$pialg_run_submit_out" 2>&1 | head -n 20)"
fi

printf '\n== fork-sandbox-k8s.sh submit --dry-run --harness claude: credential expiry ==\n'
claude_home_expired="$(newdir)"; tmpdirs+=("$claude_home_expired")
mkdir -p "$claude_home_expired/.claude"
claude_past_ms=$(( ($(date +%s) - 3600) * 1000 ))
cat > "$claude_home_expired/.claude/.credentials.json" <<JSON
{"claudeAiOauth": {"accessToken": "tok", "expiresAt": $claude_past_ms}}
JSON
refuses "an expired Claude credential is refused" \
    "has expired" \
    env HOME="$claude_home_expired" FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model claude-sonnet-5 --harness claude \
    "$proj_dir" "$handoff_file"

claude_home_soon="$(newdir)"; tmpdirs+=("$claude_home_soon")
mkdir -p "$claude_home_soon/.claude"
claude_soon_ms=$(( ($(date +%s) + 1800) * 1000 ))
cat > "$claude_home_soon/.claude/.credentials.json" <<JSON
{"claudeAiOauth": {"accessToken": "tok", "expiresAt": $claude_soon_ms}}
JSON
soon_out="$(HOME="$claude_home_soon" FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model claude-sonnet-5 --harness claude \
    "$proj_dir" "$handoff_file" 2>&1 1>/dev/null)"
if [[ "$soon_out" == *"expires in"*"the pod's session dies then"* ]]; then
    ok "a credential expiring within an hour warns but still renders"
else
    no "a credential expiring within an hour warns but still renders" "$soon_out"
fi

claude_home_floor="$(newdir)"; tmpdirs+=("$claude_home_floor")
mkdir -p "$claude_home_floor/.claude"
claude_floor_ms=$(( ($(date +%s) + 180) * 1000 ))
cat > "$claude_home_floor/.claude/.credentials.json" <<JSON
{"claudeAiOauth": {"accessToken": "tok", "expiresAt": $claude_floor_ms}}
JSON
refuses "a credential expiring within 5 minutes is refused (the pod cannot refresh it)" \
    "the pod's session would die almost at once" \
    env HOME="$claude_home_floor" FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model claude-sonnet-5 --harness claude \
    "$proj_dir" "$handoff_file"

printf '\n== fork-sandbox-k8s.sh rm removes the per-run claude-proxy objects ==\n'
# No live cluster here (see this file's own header), so `rm`'s kubectl
# calls are checked against a stub kubectl placed ahead of the real one on
# PATH, logging its own argv rather than touching any cluster.
kubectl_stub_bin="$(newdir)"; tmpdirs+=("$kubectl_stub_bin")
kubectl_log="$(newdir)/kubectl.log"; tmpdirs+=("$(dirname "$kubectl_log")")
cat > "$kubectl_stub_bin/kubectl" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$kubectl_log"
exit 0
STUB
chmod +x "$kubectl_stub_bin/kubectl"
if PATH="$kubectl_stub_bin:$PATH" FORK_SANDBOX_CONFIG_DIR="$config_dir" \
    "$k8s_sh" rm --branch fs-k8s-test-branch >/dev/null 2>/tmp/fs-k8s-test-rm.err; then
    ok "rm exits 0 against a stubbed kubectl"
else
    no "rm exits 0 against a stubbed kubectl" "$(cat /tmp/fs-k8s-test-rm.err)"
fi
if grep -q "delete pod,service,secret,configmap,networkpolicy -l fork-sandbox/branch=$claude_run_name --ignore-not-found" "$kubectl_log"; then
    ok "rm issues the label-based delete covering the claude-proxy Pod/Service/Secret/ConfigMap/NetworkPolicy"
else
    no "rm issues the label-based delete covering the claude-proxy Pod/Service/Secret/ConfigMap/NetworkPolicy" \
        "not found in $kubectl_log: $(cat "$kubectl_log")"
fi
if grep -q "delete job $claude_run_name --ignore-not-found" "$kubectl_log" \
    && grep -q "delete configmap $claude_run_name-scripts --ignore-not-found" "$kubectl_log"; then
    ok "rm still issues its original job/configmap deletes too"
else
    no "rm still issues its original job/configmap deletes too" "$(cat "$kubectl_log")"
fi
rm -f /tmp/fs-k8s-test-rm.err

printf '\n== fork-sandbox-k8s.sh install --dry-run excludes 31-claude-proxy.yaml ==\n'
if grep -q 'claude-proxy' "$install_out"; then
    no "install --dry-run renders no claude-proxy object (per-run only)" \
        "found 'claude-proxy' in $install_out"
else
    ok "install --dry-run renders no claude-proxy object (per-run only)"
fi

printf '\n== fork-sandbox-k8s.sh submit --dry-run --review-loop N ==\n'
# Extracts one ConfigMap data key's block-scalar content, reversing
# indent_block's 4-space indent -- the same technique extract_nginx_conf
# above uses for the nginx.conf key, generalized to any key name so it can
# pull review-prompt.md and fix-prompt-header.md back out for a byte-for-byte
# comparison against what fs_emit_prompt_preamble / fs_emit_review_prompt_body
# / fs_emit_fix_prompt_body produce directly.
extract_configmap_key() {
    local key="$1" file="$2"
    awk -v k="  ${key}: |" '
        $0 == k { flag=1; next }
        flag && (length($0)==0 || substr($0,1,4)=="    ") { print substr($0,5); next }
        flag { flag=0 }
    ' "$file"
}

proj_base_sha="$(git -C "$proj_dir" rev-parse --verify --quiet HEAD)"
rl_submit_out="$(newdir)/rl-submit.yaml"; tmpdirs+=("$(dirname "$rl_submit_out")")
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-rl-branch --model moonshotai/kimi-k3 --review-loop 2 \
    "$proj_dir" "$handoff_file" > "$rl_submit_out" 2>/tmp/fs-k8s-test-rl-submit.err; then
    ok "submit --dry-run --review-loop 2 exits 0"
else
    no "submit --dry-run --review-loop 2 exits 0" "$(cat /tmp/fs-k8s-test-rl-submit.err)"
fi
# Item: --harness claude --review-loop with no --review-model is refused
# here directly, not just by fork-sandbox.sh's own --k8s gate -- this
# script is a documented direct entry point in its own right, and without
# this check a bad direct invocation would only fail pod-side, after the
# proxy Pod, the token Secret, the Job and a full repository push already
# exist for the run.
refuses "submit --harness claude --review-loop without --review-model is refused" \
    "--review-model is required with --harness claude" \
    env HOME="$claude_home" FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-rl-branch --model claude-sonnet-5 --harness claude --review-loop 2 \
    "$proj_dir" "$handoff_file"

if command -v yamllint >/dev/null 2>&1; then
    # Only structural validity is asserted here, not zero warnings: the
    # rendered review/fix prompt bodies and the skill's own front matter
    # carry long prose lines by nature, which .yamllint's own header comment
    # documents as an accepted, non-error condition for exactly this file.
    out="$(yamllint -d "{extends: default, rules: {line-length: disable}}" "$rl_submit_out" 2>&1)"
    if [[ -z "$out" ]]; then ok "yamllint: submit --dry-run --review-loop output (line-length excluded)"
    else no "yamllint: submit --dry-run --review-loop output (line-length excluded)" "$out"; fi
fi

# Item: the four review-loop-only ConfigMap keys render with the flag, and
# render in NONE of the earlier no-flag submit_out.
for key in review-prompt.md fix-prompt-header.md code-review-portable-skill.md review-loop.sh; do
    if grep -qF "  $key: |" "$rl_submit_out"; then
        ok "submit --review-loop renders the $key ConfigMap key"
    else
        no "submit --review-loop renders the $key ConfigMap key" "not found in $rl_submit_out"
    fi
    if grep -qF "  $key: |" "$submit_out"; then
        no "submit without --review-loop renders no $key ConfigMap key" "found in $submit_out"
    else
        ok "submit without --review-loop renders no $key ConfigMap key"
    fi
done

# Item: REVIEW_LOOP_CAP / BASE_SHA env present with the flag, absent without
# it. Matched as full Job-spec env entries ("- name: X"), not a bare
# substring search -- entrypoint.sh's own header comment now mentions both
# names in prose, and that comment is embedded in EVERY render, flag or not.
if grep -qF -- '- name: REVIEW_LOOP_CAP' "$rl_submit_out" \
    && grep -qF -- '- name: BASE_SHA' "$rl_submit_out"; then
    ok "submit --review-loop renders REVIEW_LOOP_CAP and BASE_SHA env entries"
else
    no "submit --review-loop renders REVIEW_LOOP_CAP and BASE_SHA env entries" \
        "not found in $rl_submit_out"
fi
if grep -qF -- '- name: REVIEW_LOOP_CAP' "$submit_out" \
    || grep -qF -- '- name: BASE_SHA' "$submit_out"; then
    no "submit without --review-loop renders no REVIEW_LOOP_CAP/BASE_SHA env entries" \
        "found in $submit_out"
else
    ok "submit without --review-loop renders no REVIEW_LOOP_CAP/BASE_SHA env entries"
fi

# Item: the rendered review-prompt.md / fix-prompt-header.md are
# byte-for-byte what fs_emit_prompt_preamble + fs_emit_review_prompt_body /
# fs_emit_fix_prompt_body produce for the same arguments, with NO overlay in
# between -- the property that keeps fork-sandbox-k8s.sh from ever growing a
# second copy of this prompt text. Same assertion style
# tests/fork-sandbox-prompt-overlay-test.sh already uses for the local path.
pod_clone_dir_expected=/work/clone
pod_inbox_dir_expected=/work/inbox
pod_skill_dir_expected=/work/skills/code-review-portable
pod_verdict_file_expected=/work/clone/.git/review-verdict.md
pod_outbox_dir_expected=/work/outbox
expected_rl_review_prompt="$({ fs_emit_prompt_preamble "$pod_clone_dir_expected" \
        "$pod_inbox_dir_expected" pi gated "$pod_outbox_dir_expected" pod
    fs_emit_review_prompt_body fs-k8s-test-rl-branch "$proj_base_sha" \
        "$pod_skill_dir_expected" "$pod_verdict_file_expected" \
        "$pod_inbox_dir_expected" "$handoff_file"
})"
actual_rl_review_prompt="$(extract_configmap_key review-prompt.md "$rl_submit_out")"
check "review-prompt.md renders byte-for-byte (preamble + body, no overlay)" \
    "$expected_rl_review_prompt" "$actual_rl_review_prompt"
# The review prompt must carry the operator's handoff -- the spec the
# branch was built against -- the same as the local path. The byte-for-byte
# check above proves it for the fixture text, but this names it: a wiring
# that drops the handoff argument silently renders a spec-less review.
case "$actual_rl_review_prompt" in
    *"$(cat "$handoff_file")"*)
        ok "review-prompt.md embeds the operator's handoff" ;;
    *)
        no "review-prompt.md embeds the operator's handoff" "not found" ;;
esac

expected_rl_fix_header="$({ fs_emit_prompt_preamble "$pod_clone_dir_expected" \
        "$pod_inbox_dir_expected" pi gated "$pod_outbox_dir_expected" pod
    fs_emit_fix_prompt_body fs-k8s-test-rl-branch "$proj_base_sha" "$handoff_file"
})"
actual_rl_fix_header="$(extract_configmap_key fix-prompt-header.md "$rl_submit_out")"
check "fix-prompt-header.md renders byte-for-byte (preamble + body, no overlay)" \
    "$expected_rl_fix_header" "$actual_rl_fix_header"
# The fix header carries the handoff the same as the review prompt -- the
# fix leg weighs the findings against the spec too -- and the findings
# paragraph still lands last, after the embedded handoff.
case "$actual_rl_fix_header" in
    *"Do the thing."*)
        ok "fix-prompt-header.md embeds the operator's handoff" ;;
    *)
        no "fix-prompt-header.md embeds the operator's handoff" "not found" ;;
esac
check "fix-prompt-header.md ends with the findings paragraph, after the handoff" \
    "one out." "$(printf '%s\n' "$actual_rl_fix_header" | tail -n 1)"

# Item: render_review_loop_configmap_keys fails rather than swallows an
# emitter failure. A $(...) inside a heredoc body hands its exit status to
# cat, not to the caller, so the function must capture each key's content
# into a variable first and return 1 on failure -- without that, a handoff
# deleted or made unreadable in the window between cmd_submit's pre-render
# validation and the render itself would render the prompt prose ("the
# brief ... is appended below") with the brief silently absent, a spec-less
# review and fix leg, and the submit would go ahead. Extract both functions
# from the k8s script's own source and drive the render directly, the same
# function-extraction this suite uses for the entrypoint's run_pi_coding_leg.
rlrender_fn="$(sed -n -e '/^indent_block() {/,/^}/p' \
    -e '/^render_review_loop_configmap_keys() {/,/^}/p' "$k8s_sh")"
rlrender_fn_file="$(newdir)/rl-render.sh"; tmpdirs+=("$(dirname "$rlrender_fn_file")")
if [[ -n "$rlrender_fn" ]]; then
    printf '%s\n' 'set -euo pipefail' \
        "source \"$lib_sh\"" \
        "$rlrender_fn" \
        'render_review_loop_configmap_keys "$@"' > "$rlrender_fn_file"
    ok "indent_block and render_review_loop_configmap_keys are standalone functions in the k8s script"
else
    no "indent_block and render_review_loop_configmap_keys are standalone functions in the k8s script" \
        "function not found in $k8s_sh"
fi
rlrender_missing_handoff="$(newdir)/gone-handoff.md"
if out="$(bash "$rlrender_fn_file" \
        /work/clone /work/inbox /work/skills/code-review-portable \
        /work/clone/.git/review-verdict.md fs-k8s-test-rl-branch "$proj_base_sha" \
        "$repo_dir/skills/code-review-portable/SKILL.md" "$review_loop_sh" \
        /work/outbox "" "$rlrender_missing_handoff" \
        2>/tmp/fs-k8s-test-rlrender.err)"; then
    no "render_review_loop_configmap_keys fails on a missing handoff" \
        "exited 0; output starts: $(head -n 3 <<< "$out")"
else
    ok "render_review_loop_configmap_keys fails on a missing handoff"
fi
if grep -q "missing or unreadable at prompt-build time" /tmp/fs-k8s-test-rlrender.err; then
    ok "the missing-handoff failure names the prompt-build-time guarantee"
else
    no "the missing-handoff failure names the prompt-build-time guarantee" \
        "stderr: $(cat /tmp/fs-k8s-test-rlrender.err)"
fi
if out="$(bash "$rlrender_fn_file" \
        /work/clone /work/inbox /work/skills/code-review-portable \
        /work/clone/.git/review-verdict.md fs-k8s-test-rl-branch "$proj_base_sha" \
        "$repo_dir/skills/code-review-portable/SKILL.md" "$review_loop_sh" \
        /work/outbox "" "$handoff_file" 2>/dev/null)"; then
    ok "render_review_loop_configmap_keys exits 0 with a readable handoff"
else
    no "render_review_loop_configmap_keys exits 0 with a readable handoff" \
        "$(cat /tmp/fs-k8s-test-rlrender.err)"
fi
if [[ "$out" == *"  review-prompt.md: |"* && "$out" == *"  fix-prompt-header.md: |"* \
    && "$out" == *"Do the thing."* ]]; then
    ok "the successful render carries both prompt keys and the embedded handoff"
else
    no "the successful render carries both prompt keys and the embedded handoff" \
        "output starts: $(head -n 3 <<< "$out")"
fi
rm -f /tmp/fs-k8s-test-rlrender.err

# Item: the rendered review prompt names the POD's paths, never a host path
# -- proof this run's clone-under-/var/tmp and the operator's real project
# path never leak into a prompt a model on the internet is about to read.
if grep -qF '/work/skills/code-review-portable' "$rl_submit_out" \
    && grep -qF '/work/clone/.git/review-verdict.md' "$rl_submit_out"; then
    ok "rendered review prompt names the pod's skill and verdict paths"
else
    no "rendered review prompt names the pod's skill and verdict paths" \
        "not found in $rl_submit_out"
fi
if grep -qF "$proj_dir" "$rl_submit_out"; then
    no "rendered review prompt does not name the host project path" \
        "found $proj_dir in $rl_submit_out"
else
    ok "rendered review prompt does not name the host project path"
fi

# Item: an empty outbox_dir argument (5th positional) omits the whole
# "## Artifact outbox" section -- fs_emit_prompt_preamble is shared with the
# local path, where a run genuinely has no outbox to point at is not a case
# that currently arises (fork-sandbox.sh now always binds one), but the
# function itself still has to degrade cleanly for any future caller that
# passes "".
no_outbox_preamble="$(fs_emit_prompt_preamble "$pod_clone_dir_expected" \
    "$pod_inbox_dir_expected" pi gated "" pod)"
if [[ "$no_outbox_preamble" != *'## Artifact outbox'* ]]; then
    ok "fs_emit_prompt_preamble omits the outbox section when outbox_dir is empty"
else
    no "fs_emit_prompt_preamble omits the outbox section when outbox_dir is empty" \
        "found '## Artifact outbox' despite an empty outbox_dir argument"
fi

# Item: --review-loop 0 and a non-numeric value are both rejected, before
# any kubectl call -- --dry-run proves that, the same way it does for every
# other flag-validation case in this file.
refuses "submit --review-loop 0 is rejected" \
    "--review-loop takes a positive integer" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-rl-bad --model moonshotai/kimi-k3 --review-loop 0 \
    "$proj_dir" "$handoff_file"
refuses "submit --review-loop abc is rejected" \
    "--review-loop takes a positive integer" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-rl-bad --model moonshotai/kimi-k3 --review-loop abc \
    "$proj_dir" "$handoff_file"
rm -f /tmp/fs-k8s-test-rl-submit.err

printf '\n== fork-sandbox-k8s.sh run --dry-run (fixture config, no cluster) ==\n'
run_out="$(newdir)/run.yaml"; tmpdirs+=("$(dirname "$run_out")")
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" run --dry-run \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3 \
    "$proj_dir" "$handoff_file" > "$run_out" 2>/tmp/fs-k8s-test-run.err; then
    ok "run --dry-run exits 0"
else
    no "run --dry-run exits 0" "$(cat /tmp/fs-k8s-test-run.err)"
fi
if command -v yamllint >/dev/null 2>&1; then
    out="$(yamllint "$run_out" 2>&1)"
    if [[ -z "$out" ]]; then ok "yamllint: run --dry-run output"; else no "yamllint: run --dry-run output" "$out"; fi
    out="$(yamllint - < "$run_out" 2>&1)"
    if [[ -z "$out" ]]; then ok "yamllint: run --dry-run piped through stdin"; else no "yamllint: run --dry-run piped through stdin" "$out"; fi
fi
# The strongest proof that `run --dry-run` delegates to cmd_submit's own
# rendering, rather than having grown a second, divergent copy of it: for
# the same arguments the two must render byte-for-byte identical YAML.
if diff -q "$submit_out" "$run_out" >/dev/null 2>&1; then
    ok "run --dry-run renders the same Job YAML as submit --dry-run"
else
    no "run --dry-run renders the same Job YAML as submit --dry-run" \
        "$(diff "$submit_out" "$run_out" 2>&1 | head -n 20)"
fi
rm -f /tmp/fs-k8s-test-run.err

refuses "run rejects a missing --branch" \
    "run requires --branch" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" run --dry-run \
    --model moonshotai/kimi-k3 "$proj_dir" "$handoff_file"
refuses "run rejects a missing project path" \
    "Usage: fork-sandbox-k8s.sh run" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" run --dry-run \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3
refuses "run rejects an unknown option" \
    "unknown option" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" run --dry-run \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3 --bogus \
    "$proj_dir" "$handoff_file"

printf '\n== fork-sandbox-k8s.sh submit/run --dry-run --outbox-max ==\n'
# --outbox-max threads one byte value into both the rendered Job spec's
# OUTBOX_MAX_BYTES env entry and fs_emit_prompt_preamble's own stated
# figure -- covers bare digits plus each accepted unit suffix, per the
# operator addendum that added this flag ("a parsed value in each accepted
# unit reaches the Job spec and the preamble text").
check_outbox_max_render() {
    local label="$1" out="$2" expected_bytes="$3" expected_mib="$4"
    if grep -qF "value: \"$expected_bytes\"" "$out"; then
        ok "$label: OUTBOX_MAX_BYTES=$expected_bytes in the Job spec"
    else
        no "$label: OUTBOX_MAX_BYTES=$expected_bytes in the Job spec" "not found in $out"
    fi
    if grep -qF "$expected_mib MiB budget" "$out"; then
        ok "$label: preamble states $expected_mib MiB budget"
    else
        no "$label: preamble states $expected_mib MiB budget" "not found in $out"
    fi
}

om_bare_out="$(newdir)/om-bare.yaml"; tmpdirs+=("$(dirname "$om_bare_out")")
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-om-bare --model moonshotai/kimi-k3 \
    --outbox-max "$((100 * 1024 * 1024))" \
    "$proj_dir" "$handoff_file" > "$om_bare_out" 2>/tmp/fs-k8s-test-om.err; then
    ok "submit --outbox-max <bare digits> exits 0"
else
    no "submit --outbox-max <bare digits> exits 0" "$(cat /tmp/fs-k8s-test-om.err)"
fi
check_outbox_max_render "submit --outbox-max <bare digits>" "$om_bare_out" "$((100 * 1024 * 1024))" 100

om_k_out="$(newdir)/om-k.yaml"; tmpdirs+=("$(dirname "$om_k_out")")
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-om-k --model moonshotai/kimi-k3 --outbox-max 131072K \
    "$proj_dir" "$handoff_file" > "$om_k_out" 2>/tmp/fs-k8s-test-om.err; then
    ok "submit --outbox-max 131072K exits 0"
else
    no "submit --outbox-max 131072K exits 0" "$(cat /tmp/fs-k8s-test-om.err)"
fi
check_outbox_max_render "submit --outbox-max 131072K" "$om_k_out" "$((131072 * 1024))" 128

om_m_out="$(newdir)/om-m.yaml"; tmpdirs+=("$(dirname "$om_m_out")")
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-om-m --model moonshotai/kimi-k3 --outbox-max 256M \
    "$proj_dir" "$handoff_file" > "$om_m_out" 2>/tmp/fs-k8s-test-om.err; then
    ok "submit --outbox-max 256M exits 0"
else
    no "submit --outbox-max 256M exits 0" "$(cat /tmp/fs-k8s-test-om.err)"
fi
check_outbox_max_render "submit --outbox-max 256M" "$om_m_out" "$((256 * 1024 * 1024))" 256

om_g_out="$(newdir)/om-g.yaml"; tmpdirs+=("$(dirname "$om_g_out")")
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-om-g --model moonshotai/kimi-k3 --outbox-max 2G \
    "$proj_dir" "$handoff_file" > "$om_g_out" 2>/tmp/fs-k8s-test-om.err; then
    ok "submit --outbox-max 2G exits 0"
else
    no "submit --outbox-max 2G exits 0" "$(cat /tmp/fs-k8s-test-om.err)"
fi
check_outbox_max_render "submit --outbox-max 2G" "$om_g_out" "$((2 * 1024 * 1024 * 1024))" 2048
rm -f /tmp/fs-k8s-test-om.err

# `run --dry-run --outbox-max` is a different code path than the direct
# submit case above: cmd_run parses its own copy for its own pull-back
# guard, then forwards the raw string into submit_argv for cmd_submit to
# parse again for the Job spec -- the same boundary --review-loop already
# crosses. Assert the forwarded path renders the same figure, not just the
# direct one.
om_run_out="$(newdir)/om-run.yaml"; tmpdirs+=("$(dirname "$om_run_out")")
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" run --dry-run \
    --branch fs-k8s-test-om-run --model moonshotai/kimi-k3 --outbox-max 256M \
    "$proj_dir" "$handoff_file" > "$om_run_out" 2>/tmp/fs-k8s-test-om-run.err; then
    ok "run --outbox-max 256M exits 0"
else
    no "run --outbox-max 256M exits 0" "$(cat /tmp/fs-k8s-test-om-run.err)"
fi
check_outbox_max_render "run --outbox-max 256M (forwarded to submit)" "$om_run_out" "$((256 * 1024 * 1024))" 256
rm -f /tmp/fs-k8s-test-om-run.err

# Bad values are rejected before anything is created -- same convention as
# the --review-loop bad-value checks above -- for both verbs, since each
# parses its own copy via fs_parse_size_bytes.
for verb in submit run; do
    refuses "$verb --outbox-max 0 is rejected" \
        "Error: size '0' must be greater than zero" \
        env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" "$verb" --dry-run \
        --branch fs-k8s-test-om-bad --model moonshotai/kimi-k3 --outbox-max 0 \
        "$proj_dir" "$handoff_file"
    refuses "$verb --outbox-max -5 is rejected" \
        "Error: invalid size '-5'" \
        env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" "$verb" --dry-run \
        --branch fs-k8s-test-om-bad --model moonshotai/kimi-k3 --outbox-max -5 \
        "$proj_dir" "$handoff_file"
    refuses "$verb --outbox-max bogus is rejected" \
        "Error: invalid size 'bogus'" \
        env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" "$verb" --dry-run \
        --branch fs-k8s-test-om-bad --model moonshotai/kimi-k3 --outbox-max bogus \
        "$proj_dir" "$handoff_file"
done

# --review-loop N --outbox-max SIZE together: render_review_loop_configmap_keys
# is a separate code path from the handoff.md render above, with its own
# fs_emit_prompt_preamble calls for review-prompt.md and fix-prompt-header.md
# -- confirm the raised figure reaches all three preamble renders, not just
# handoff.md. 512K is deliberately sub-1-MiB: fs_emit_prompt_preamble's MiB
# display truncates via integer division (see fork-sandbox-lib.sh), so this
# also pins the pre-existing "0 MiB budget" display for a sub-1-MiB cap
# rather than silently drifting if that rounding ever changes.
om_rl_out="$(newdir)/om-rl.yaml"; tmpdirs+=("$(dirname "$om_rl_out")")
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-om-rl --model moonshotai/kimi-k3 \
    --review-loop 2 --outbox-max 512K \
    "$proj_dir" "$handoff_file" > "$om_rl_out" 2>/tmp/fs-k8s-test-om-rl.err; then
    ok "submit --review-loop 2 --outbox-max 512K exits 0"
else
    no "submit --review-loop 2 --outbox-max 512K exits 0" "$(cat /tmp/fs-k8s-test-om-rl.err)"
fi
om_rl_mib_count="$(grep -c '0 MiB budget' "$om_rl_out" || true)"
check "--review-loop + --outbox-max 512K: all three preambles (handoff.md, review-prompt.md, fix-prompt-header.md) state 0 MiB budget" \
    3 "$om_rl_mib_count"
om_rl_env_count="$(grep -cF 'value: "524288"' "$om_rl_out" || true)"
check "--review-loop + --outbox-max 512K: exactly one OUTBOX_MAX_BYTES Job-spec env entry carries 524288" \
    1 "$om_rl_env_count"
rm -f /tmp/fs-k8s-test-om-rl.err

# Default OUTBOX_MAX_BYTES (FS_OUTBOX_MAX_BYTES, unraised) still renders when
# --outbox-max is absent -- reusing submit_out from the plain submit
# --dry-run render earlier in this file, which was never given the flag.
if grep -qF "value: \"$FS_OUTBOX_MAX_BYTES\"" "$submit_out"; then
    ok "submit without --outbox-max renders the default OUTBOX_MAX_BYTES"
else
    no "submit without --outbox-max renders the default OUTBOX_MAX_BYTES" "not found in $submit_out"
fi
# The pod-side entrypoint has its own literal default (it does not source
# fork-sandbox-lib.sh) -- guard the two from drifting apart silently.
if grep -qF ":=$FS_OUTBOX_MAX_BYTES}" "$entrypoint_sh"; then
    ok "fork-sandbox-k8s-entrypoint.sh's OUTBOX_MAX_BYTES default matches FS_OUTBOX_MAX_BYTES"
else
    no "fork-sandbox-k8s-entrypoint.sh's OUTBOX_MAX_BYTES default matches FS_OUTBOX_MAX_BYTES" \
        "expected literal $FS_OUTBOX_MAX_BYTES in $entrypoint_sh"
fi

# The work emptyDir must never grow a sizeLimit key back (see the comment
# on that volume entry in fork-sandbox-k8s.sh, which explains why -- and
# which itself mentions the word "sizeLimit" in prose, so this checks for
# the YAML key specifically rather than the bare substring). Scoped to the
# work volume's own block, not the whole file, so this would still fail if
# some other volume grew a sizeLimit while `work` stayed clean.
work_volume_block="$(awk '
    /^        - name: work$/ { p=1 }
    p { print }
    p && /emptyDir: \{\}/ { exit }
' "$submit_out")"
if [[ -n "$work_volume_block" ]] && ! grep -qE '^\s*sizeLimit:' <<< "$work_volume_block"; then
    ok "the work emptyDir volume carries no sizeLimit"
else
    no "the work emptyDir volume carries no sizeLimit" "$work_volume_block"
fi

# Captured once, then matched, rather than piped straight into `grep -q`.
# Piping is what made this flaky: `grep -q` exits the moment it matches,
# which closes the pipe under usage()'s `sed`, which then dies of SIGPIPE --
# and with `set -o pipefail` above, that non-zero status fails the whole
# pipeline even though grep found what it was looking for. It only bit the
# `run` check, because `run` appears early enough in the help text that grep
# reliably won the race; `say` appears further down and so usually finished
# writing first. Same latent bug either way.
help_out="$("$k8s_sh" --help 2>&1)"
for verb in run say; do
    if grep -q "fork-sandbox-k8s.sh $verb" <<< "$help_out"; then
        ok "usage() mentions $verb"
    else
        no "usage() mentions $verb" "not found in --help output"
    fi
done

printf '\n== fork-sandbox-k8s.sh submit/run --dry-run --context-ro ==\n'
# --context-ro pushes a directory into the pod at /work/context over the
# same gated channel the repository push uses -- see
# docs/kubernetes-runs.md's "Getting files in" section. All of this is
# checked under --dry-run, which touches no kubectl and no cluster: the
# path-under-/var/tmp/claude-scratch/forks/ and directory-exists checks run
# before --dry-run's early exit, and the ConfigMap key / prompt section are
# both computed as part of the same rendered YAML --dry-run prints.
cr_dir="$(mktemp -d /var/tmp/claude-scratch/forks/fs-k8s-test-cr.XXXXXX)"; tmpdirs+=("$cr_dir")
printf 'gathered notes\n' > "$cr_dir/notes.md"

cr_submit_out="$(newdir)/cr-submit.yaml"; tmpdirs+=("$(dirname "$cr_submit_out")")
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-cr-branch --model moonshotai/kimi-k3 --context-ro "$cr_dir" \
    "$proj_dir" "$handoff_file" > "$cr_submit_out" 2>/tmp/fs-k8s-test-cr-submit.err; then
    ok "submit --dry-run --context-ro exits 0"
else
    no "submit --dry-run --context-ro exits 0" "$(cat /tmp/fs-k8s-test-cr-submit.err)"
fi
rm -f /tmp/fs-k8s-test-cr-submit.err

if grep -q '^  context-extract.sh: |$' "$cr_submit_out"; then
    ok "submit --context-ro renders the context-extract.sh ConfigMap key"
else
    no "submit --context-ro renders the context-extract.sh ConfigMap key" "not found in $cr_submit_out"
fi
if grep -q '## Gathered context' "$cr_submit_out"; then
    ok "submit --context-ro renders the Gathered context section"
else
    no "submit --context-ro renders the Gathered context section" "not found in $cr_submit_out"
fi
if grep -q '/work/context' "$cr_submit_out"; then
    ok "submit --context-ro names the pod's context path"
else
    no "submit --context-ro names the pod's context path" "not found in $cr_submit_out"
fi

# The context-extract.sh ConfigMap key ships unconditionally, the same way
# inbox-write.sh does even on a run where `say` is never used -- small,
# cheap, and simpler than a second conditionally-rendered key. Only the
# prompt section is conditional on the flag. Reuses submit_out from the
# earlier fixture-config dry-run section above, which was rendered with no
# --context-ro at all.
if grep -q '^  context-extract.sh: |$' "$submit_out"; then
    ok "submit without --context-ro still renders the context-extract.sh ConfigMap key"
else
    no "submit without --context-ro still renders the context-extract.sh ConfigMap key" \
        "not found in $submit_out"
fi
if grep -q '## Gathered context' "$submit_out"; then
    no "submit without --context-ro renders no Gathered context section" \
        "found in $submit_out"
else
    ok "submit without --context-ro renders no Gathered context section"
fi

# A path outside the allowed root is refused by name, before any kubectl call.
cr_outside="$(mktemp -d)"; tmpdirs+=("$cr_outside")
refuses "submit --context-ro outside /var/tmp/claude-scratch/forks/ is refused" \
    "--context-ro must name a directory under" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-cr-bad --model moonshotai/kimi-k3 --context-ro "$cr_outside" \
    "$proj_dir" "$handoff_file"

# A missing directory is refused, even though its name is under the
# allowed root.
refuses "submit --context-ro on a missing directory is refused" \
    "does not exist" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-cr-missing --model moonshotai/kimi-k3 \
    --context-ro /var/tmp/claude-scratch/forks/fs-k8s-test-cr-missing-xyz \
    "$proj_dir" "$handoff_file"

# A directory containing a symlink is refused on the host, before the
# Job is ever created -- `tar cf`'s ordinary walk would turn it into a
# link entry the pod-side extractor also refuses, but only after the
# repository has already been pushed. --dry-run touches no kubectl and no
# cluster, so this check runs (and is observable) with neither.
cr_sym_dir="$(mktemp -d /var/tmp/claude-scratch/forks/fs-k8s-test-cr-sym.XXXXXX)"; tmpdirs+=("$cr_sym_dir")
ln -s /etc/passwd "$cr_sym_dir/evil"
refuses "submit --context-ro containing a symlink is refused" \
    "contains a symlink" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-cr-sym --model moonshotai/kimi-k3 --context-ro "$cr_sym_dir" \
    "$proj_dir" "$handoff_file"

# A directory containing a hard link is refused on the host too -- `find
# -type l` alone never matches a hard link (it has no distinct file type),
# but `tar cf`'s walk still turns the second name for the same inode into a
# link entry, which the pod-side extractor refuses just like a symlink's,
# before the Job exists or the repository is pushed.
cr_hl_dir="$(mktemp -d /var/tmp/claude-scratch/forks/fs-k8s-test-cr-hl.XXXXXX)"; tmpdirs+=("$cr_hl_dir")
printf 'x\n' > "$cr_hl_dir/f.txt"
ln "$cr_hl_dir/f.txt" "$cr_hl_dir/g.txt"
refuses "submit --context-ro containing a hard link is refused" \
    "contains a hard-linked file" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-cr-hl --model moonshotai/kimi-k3 --context-ro "$cr_hl_dir" \
    "$proj_dir" "$handoff_file"

# A single hard-linked file is refused even when its other name is outside
# the context tree; link count, rather than duplicate in-tree inodes, is the
# security property being checked.
cr_ext_parent="$(mktemp -d /var/tmp/claude-scratch/forks/fs-k8s-test-cr-ext.XXXXXX)"; tmpdirs+=("$cr_ext_parent")
cr_ext_dir="$cr_ext_parent/context"; mkdir "$cr_ext_dir"
printf 'outside-linked\n' > "$cr_ext_parent/outside.txt"
ln "$cr_ext_parent/outside.txt" "$cr_ext_dir/inside.txt"
refuses "submit --context-ro refuses a file hard-linked outside the tree" \
    "inside.txt" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-cr-external-link --model moonshotai/kimi-k3 --context-ro "$cr_ext_dir" \
    "$proj_dir" "$handoff_file"

# A two-file fixture never queues enough `stat` output to catch this: the
# hard-link check's `awk` used to `exit` on the first duplicate inode,
# which, once there was more than a pipe buffer (64 KiB) of `stat` output
# still to come, closed the pipe out from under a still-writing `stat`,
# took it down with SIGPIPE, and made `find` (and, under this file's
# `set -euo pipefail`, the whole script) fail before "contains a
# hard-linked file" ever printed. A `cp -al`-provisioned cache -- exactly
# the shape this check exists for -- reproduces it: thousands of files in
# one call each via brace expansion and `cp -al`, no per-file forking.
cr_hl_many_dir="$(mktemp -d /var/tmp/claude-scratch/forks/fs-k8s-test-cr-hl-many.XXXXXX)"; tmpdirs+=("$cr_hl_many_dir")
mkdir "$cr_hl_many_dir/a"
touch "$cr_hl_many_dir/a/f"{1..4000}
cp -al "$cr_hl_many_dir/a" "$cr_hl_many_dir/b"
refuses "submit --context-ro with many hard links still reports its own error" \
    "contains a hard-linked file" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-cr-hl-many --model moonshotai/kimi-k3 --context-ro "$cr_hl_many_dir" \
    "$proj_dir" "$handoff_file"

# `run --dry-run --context-ro` forwards to submit rather than growing its
# own divergent copy -- same property --outbox-max's own run/submit pair
# already proves above, applied to this flag.
cr_run_out="$(newdir)/cr-run.yaml"; tmpdirs+=("$(dirname "$cr_run_out")")
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" run --dry-run \
    --branch fs-k8s-test-cr-branch --model moonshotai/kimi-k3 --context-ro "$cr_dir" \
    "$proj_dir" "$handoff_file" > "$cr_run_out" 2>/tmp/fs-k8s-test-cr-run.err; then
    ok "run --dry-run --context-ro exits 0"
else
    no "run --dry-run --context-ro exits 0" "$(cat /tmp/fs-k8s-test-cr-run.err)"
fi
rm -f /tmp/fs-k8s-test-cr-run.err
check "run --dry-run --context-ro renders byte-for-byte the same as submit --dry-run --context-ro" \
    "$(cat "$cr_submit_out")" "$(cat "$cr_run_out")"

# The host-side archive cap is checked before any kubectl apply. A tar stub
# makes a sparse over-cap archive without allocating 256 MiB of test data.
cr_big_dir="$(mktemp -d /var/tmp/claude-scratch/forks/fs-k8s-test-cr-big.XXXXXX)"; tmpdirs+=("$cr_big_dir")
printf 'too large\n' > "$cr_big_dir/file.txt"
cr_order_stub="$(newdir)"; tmpdirs+=("$cr_order_stub")
cat > "$cr_order_stub/tar" <<'STUB'
#!/usr/bin/env bash
truncate -s $((256 * 1024 * 1024 + 1)) "$2"
STUB
chmod +x "$cr_order_stub/tar"
cr_order_log="$(newdir)/kubectl.log"; tmpdirs+=("$(dirname "$cr_order_log")")
cr_order_kubectl="$(newdir)/kubectl"; tmpdirs+=("$(dirname "$cr_order_kubectl")")
cat > "$cr_order_kubectl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$K8S_STUB_LOG"
STUB
chmod +x "$cr_order_kubectl"
PATH="$cr_order_stub:$(dirname "$cr_order_kubectl"):$PATH" K8S_STUB_LOG="$cr_order_log" \
    FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit \
    --branch fs-k8s-test-cr-over-cap --model moonshotai/kimi-k3 --context-ro "$cr_big_dir" \
    "$proj_dir" "$handoff_file" >/tmp/fs-k8s-test-cr-big.out 2>&1
cr_order_rc=$?
if (( cr_order_rc == 0 )); then
    no "oversized context is refused before kubectl apply" "submit unexpectedly succeeded"
else
    if [[ ! -s "$cr_order_log" ]] && grep -q 'over the .* byte' /tmp/fs-k8s-test-cr-big.out; then
        ok "oversized context is refused before kubectl apply"
    else
        no "oversized context is refused before kubectl apply" "log=$(cat "$cr_order_log") out=$(cat /tmp/fs-k8s-test-cr-big.out)"
    fi
fi
# This failure is strictly host-side -- no kubectl apply ever ran, so no
# cluster object exists for an orchestrator or an operator's `rm --branch`
# to find -- so the run directory submit had already created and printed
# above must not survive it either, or it leaks forever with nothing able
# to join to it.
cr_order_rd="$(sed -n 's/^  run dir:  *//p' /tmp/fs-k8s-test-cr-big.out | head -1)"
if [[ -n "$cr_order_rd" ]] && [[ ! -e "$cr_order_rd" ]]; then
    ok "an over-cap context also removes the run dir it never got to use"
else
    no "an over-cap context also removes the run dir it never got to use" \
        "run_dir=$cr_order_rd $([[ -e "$cr_order_rd" ]] && echo STILL_PRESENT)"
fi
rm -f /tmp/fs-k8s-test-cr-big.out

# A context exec failure must remove the already-sized host archive. The git
# wrapper lets validation and the repository push complete without a remote;
# the kubectl stub fails only the context exec and records every call.
cr_exec_tmp="$(newdir)"; tmpdirs+=("$cr_exec_tmp")
cr_exec_git="$(newdir)/git"; tmpdirs+=("$(dirname "$cr_exec_git")")
cat > "$cr_exec_git" <<'STUB'
#!/usr/bin/env bash
case " $* " in
    *" push "*) exit 0 ;;
esac
exec /usr/bin/git "$@"
STUB
chmod +x "$cr_exec_git"
cr_exec_kubectl="$(newdir)/kubectl"; tmpdirs+=("$(dirname "$cr_exec_kubectl")")
cat > "$cr_exec_kubectl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$K8S_STUB_LOG"
verb=""; for arg in "$@"; do case "$arg" in apply|wait|exec|get) verb="$arg" ;; esac; done
case "$verb" in
    apply|wait) cat >/dev/null ;;
    get) printf 'stub-pod\n' ;;
    exec) cat >/dev/null; exit 19 ;;
esac
STUB
chmod +x "$cr_exec_kubectl"
cr_exec_log="$(newdir)/kubectl.log"; tmpdirs+=("$(dirname "$cr_exec_log")")
PATH="$(dirname "$cr_exec_git"):$(dirname "$cr_exec_kubectl"):$PATH" \
    TMPDIR="$cr_exec_tmp" K8S_STUB_LOG="$cr_exec_log" \
    FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit \
    --branch fs-k8s-test-cr-exec-failure --model moonshotai/kimi-k3 --context-ro "$cr_dir" \
    "$proj_dir" "$handoff_file" >/tmp/fs-k8s-test-cr-exec.out 2>&1
cr_exec_rc=$?
if (( cr_exec_rc == 0 )); then
    no "context exec failure removes the temporary archive" "submit unexpectedly succeeded"
else
    if [[ -z "$(find "$cr_exec_tmp" -type f -print -quit)" ]] \
        && grep -q 'exec -i stub-pod' "$cr_exec_log"; then
        ok "context exec failure removes the temporary archive"
    else
        no "context exec failure removes the temporary archive" "tmp=$(find "$cr_exec_tmp" -type f) log=$(cat "$cr_exec_log")"
    fi
fi
rm -f /tmp/fs-k8s-test-cr-exec.out

# --thread-dir/--attach-dir: same transport as --context-ro (spooled tar,
# kubectl exec through the same extractor, same CONTEXT_MAX_BYTES cap,
# checked before --dry-run's early exit), but validated with
# fs_validate_scratch_dir's whole-scratch-root rule, not --context-ro's
# narrower forks/-only rule -- the postmaster stages these under its mail
# root, which is under the scratch root but not under forks/, so
# --context-ro's own rule would refuse every real wake. One function, run
# for each flag, to avoid two near-identical copies of the same battery.
td_test_scratch_push() {
    local flag="$1" pod_path="$2" tag="$3"
    local d wf_out rc
    d="$(mktemp -d "/var/tmp/claude-scratch/fs-k8s-test-${tag}.XXXXXX")"; tmpdirs+=("$d")
    printf 'gathered notes\n' > "$d/notes.md"
    mkdir -p "$d/sub"
    printf 'nested\n' > "$d/sub/nested.txt"
    printf 'dotfile\n' > "$d/.dotfile"
    printf 'space\n' > "$d/name with space.txt"
    printf 'dash\n' > "$d/-dashname.txt"

    wf_out="$(newdir)/${tag}-submit.yaml"; tmpdirs+=("$(dirname "$wf_out")")
    if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
        --branch "fs-k8s-test-${tag}-branch" --model moonshotai/kimi-k3 "$flag" "$d" \
        "$proj_dir" "$handoff_file" > "$wf_out" 2>"/tmp/fs-k8s-test-${tag}.err"; then
        ok "submit --dry-run $flag exits 0"
    else
        no "submit --dry-run $flag exits 0" "$(cat "/tmp/fs-k8s-test-${tag}.err")"
    fi
    rm -f "/tmp/fs-k8s-test-${tag}.err"

    if grep -qF "mountPath: $pod_path" "$wf_out"; then
        ok "submit $flag renders the emptyDir mount at $pod_path"
    else
        no "submit $flag renders the emptyDir mount at $pod_path" "not found in $wf_out"
    fi
    if grep -qF "mountPath: $pod_path" "$submit_out"; then
        no "submit without $flag renders no mount at $pod_path" "found in $submit_out"
    else
        ok "submit without $flag renders no mount at $pod_path"
    fi

    # Outside the whole scratch root: refused by name, before any kubectl call.
    local outside; outside="$(mktemp -d)"; tmpdirs+=("$outside")
    refuses "submit $flag outside the scratch root is refused" \
        "must name a directory under" \
        env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
        --branch "fs-k8s-test-$tag-bad" --model moonshotai/kimi-k3 "$flag" "$outside" \
        "$proj_dir" "$handoff_file"

    # Missing directory: refused even though its name is under the scratch root.
    refuses "submit $flag on a missing directory is refused" \
        "does not exist" \
        env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
        --branch "fs-k8s-test-${tag}-missing" --model moonshotai/kimi-k3 \
        "$flag" "/var/tmp/claude-scratch/fs-k8s-test-${tag}-missing-xyz" \
        "$proj_dir" "$handoff_file"

    # A dir under the scratch root but OUTSIDE forks/ is ACCEPTED -- the
    # case that distinguishes this flag's rule from --context-ro's.
    local outside_forks; outside_forks="$(mktemp -d "/var/tmp/claude-scratch/fs-k8s-test-${tag}-outside-forks.XXXXXX")"; tmpdirs+=("$outside_forks")
    printf 'x\n' > "$outside_forks/f.txt"
    if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
        --branch "fs-k8s-test-${tag}-of" --model moonshotai/kimi-k3 "$flag" "$outside_forks" \
        "$proj_dir" "$handoff_file" >"/tmp/fs-k8s-test-${tag}-of.out" 2>&1; then
        ok "submit $flag under the scratch root but outside forks/ is accepted"
    else
        no "submit $flag under the scratch root but outside forks/ is accepted" \
            "$(cat "/tmp/fs-k8s-test-${tag}-of.out")"
    fi
    rm -f "/tmp/fs-k8s-test-${tag}-of.out"

    # Symlink: refused on the host, before the Job is ever created.
    local sym_dir; sym_dir="$(mktemp -d "/var/tmp/claude-scratch/fs-k8s-test-${tag}-sym.XXXXXX")"; tmpdirs+=("$sym_dir")
    ln -s /etc/passwd "$sym_dir/evil"
    refuses "submit $flag containing a symlink is refused" \
        "contains a symlink" \
        env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
        --branch "fs-k8s-test-${tag}-sym" --model moonshotai/kimi-k3 "$flag" "$sym_dir" \
        "$proj_dir" "$handoff_file"

    # Hard link: refused on the host too, same reason as --context-ro's own check.
    local hl_dir; hl_dir="$(mktemp -d "/var/tmp/claude-scratch/fs-k8s-test-${tag}-hl.XXXXXX")"; tmpdirs+=("$hl_dir")
    printf 'x\n' > "$hl_dir/f.txt"
    ln "$hl_dir/f.txt" "$hl_dir/g.txt"
    refuses "submit $flag containing a hard link is refused" \
        "contains a hard-linked file" \
        env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
        --branch "fs-k8s-test-${tag}-hl" --model moonshotai/kimi-k3 "$flag" "$hl_dir" \
        "$proj_dir" "$handoff_file"

    # run --dry-run forwards to submit rather than growing a divergent copy.
    local run_out; run_out="$(newdir)/${tag}-run.yaml"; tmpdirs+=("$(dirname "$run_out")")
    if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" run --dry-run \
        --branch "fs-k8s-test-${tag}-branch" --model moonshotai/kimi-k3 "$flag" "$d" \
        "$proj_dir" "$handoff_file" > "$run_out" 2>"/tmp/fs-k8s-test-${tag}-run.err"; then
        ok "run --dry-run $flag exits 0"
    else
        no "run --dry-run $flag exits 0" "$(cat "/tmp/fs-k8s-test-${tag}-run.err")"
    fi
    rm -f "/tmp/fs-k8s-test-${tag}-run.err"
    check "run --dry-run $flag renders byte-for-byte the same as submit --dry-run $flag" \
        "$(cat "$wf_out")" "$(cat "$run_out")"

    # Over-cap: refused before any kubectl apply, same tar-stub trick as
    # --context-ro's own over-cap test.
    local big_dir order_stub order_log order_kubectl
    big_dir="$(mktemp -d "/var/tmp/claude-scratch/fs-k8s-test-${tag}-big.XXXXXX")"; tmpdirs+=("$big_dir")
    printf 'too large\n' > "$big_dir/file.txt"
    order_stub="$(newdir)"; tmpdirs+=("$order_stub")
    cat > "$order_stub/tar" <<'STUB'
#!/usr/bin/env bash
truncate -s $((256 * 1024 * 1024 + 1)) "$2"
STUB
    chmod +x "$order_stub/tar"
    order_log="$(newdir)/kubectl.log"; tmpdirs+=("$(dirname "$order_log")")
    order_kubectl="$(newdir)/kubectl"; tmpdirs+=("$(dirname "$order_kubectl")")
    cat > "$order_kubectl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$K8S_STUB_LOG"
STUB
    chmod +x "$order_kubectl"
    PATH="$order_stub:$(dirname "$order_kubectl"):$PATH" K8S_STUB_LOG="$order_log" \
        FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit \
        --branch "fs-k8s-test-${tag}-over-cap" --model moonshotai/kimi-k3 "$flag" "$big_dir" \
        "$proj_dir" "$handoff_file" >"/tmp/fs-k8s-test-${tag}-big.out" 2>&1
    rc=$?
    if (( rc == 0 )); then
        no "oversized $flag is refused before kubectl apply" "submit unexpectedly succeeded"
    elif [[ ! -s "$order_log" ]] && grep -q 'over the .* byte' "/tmp/fs-k8s-test-${tag}-big.out"; then
        ok "oversized $flag is refused before kubectl apply"
    else
        no "oversized $flag is refused before kubectl apply" \
            "log=$(cat "$order_log") out=$(cat "/tmp/fs-k8s-test-${tag}-big.out")"
    fi
    rm -f "/tmp/fs-k8s-test-${tag}-big.out"

    # The non-dry-run push issues an exec to the extractor with the right
    # destination, before the sentinel exec -- mirrors --context-ro's own
    # exec-failure-removes-tar fixture, adapted to confirm the destination
    # and ordering rather than re-testing failure-cleanup a third time.
    local exec_tmp exec_git exec_kubectl exec_log exec_tar
    exec_tmp="$(newdir)"; tmpdirs+=("$exec_tmp")
    exec_git="$(newdir)/git"; tmpdirs+=("$(dirname "$exec_git")")
    cat > "$exec_git" <<'STUB'
#!/usr/bin/env bash
case " $* " in
    *" push "*) exit 0 ;;
esac
exec /usr/bin/git "$@"
STUB
    chmod +x "$exec_git"
    exec_kubectl="$(newdir)/kubectl"; tmpdirs+=("$(dirname "$exec_kubectl")")
    cat > "$exec_kubectl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$K8S_STUB_LOG"
verb=""; for arg in "$@"; do case "$arg" in apply|wait|exec|get) verb="$arg" ;; esac; done
case "$verb" in
    apply|wait) cat >/dev/null ;;
    get) printf 'stub-pod\n' ;;
    exec)
        if [[ -n "${K8S_STUB_CAPTURE_TAR:-}" ]] && [[ " $* " == *" ${K8S_STUB_CAPTURE_DEST:-} "* ]]; then
            cat > "$K8S_STUB_CAPTURE_TAR"
        else
            cat >/dev/null
        fi
        ;;
esac
STUB
    chmod +x "$exec_kubectl"
    exec_log="$(newdir)/kubectl.log"; tmpdirs+=("$(dirname "$exec_log")")
    exec_tar="$exec_tmp/captured.tar"
    PATH="$(dirname "$exec_git"):$(dirname "$exec_kubectl"):$PATH" \
        TMPDIR="$exec_tmp" K8S_STUB_LOG="$exec_log" \
        K8S_STUB_CAPTURE_DEST="$pod_path" K8S_STUB_CAPTURE_TAR="$exec_tar" \
        FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit \
        --branch "fs-k8s-test-${tag}-exec-order" --model moonshotai/kimi-k3 "$flag" "$d" \
        "$proj_dir" "$handoff_file" >"/tmp/fs-k8s-test-${tag}-exec.out" 2>&1
    rc=$?
    if (( rc == 0 )) \
        && grep -qF "exec -i stub-pod -- sh /mnt/fork-sandbox/context-extract.sh $pod_path" "$exec_log" \
        && [[ "$(grep -n "exec -i stub-pod -- sh /mnt/fork-sandbox/context-extract.sh $pod_path" "$exec_log" | head -1 | cut -d: -f1)" \
              -lt "$(grep -n "touch /work/.inputs-complete" "$exec_log" | head -1 | cut -d: -f1)" ]]; then
        ok "the non-dry-run push for $flag execs the extractor at $pod_path before the sentinel"
    else
        no "the non-dry-run push for $flag execs the extractor at $pod_path before the sentinel" \
            "rc=$rc log=$(cat "$exec_log") out=$(cat "/tmp/fs-k8s-test-${tag}-exec.out")"
    fi
    rm -f "/tmp/fs-k8s-test-${tag}-exec.out"

    # The archive actually pushed for this flag: real k8s_spool_dir_entries
    # output, captured off the stubbed kubectl exec's stdin above -- not a
    # re-typed pipeline standing in for it.
    if [[ -s "$exec_tar" ]]; then
        local tar_members
        tar_members="$(tar tf "$exec_tar")"
        if ! grep -qxF '.' <<< "$tar_members" && ! grep -qxF './' <<< "$tar_members"; then
            ok "the captured $flag archive has no top-level '.' or './' member"
        else
            no "the captured $flag archive has no top-level '.' or './' member" "$tar_members"
        fi
        local missing="" want
        for want in './notes.md' './sub/nested.txt' './.dotfile' \
                    './name with space.txt' './-dashname.txt'; do
            grep -qxF "$want" <<< "$tar_members" || missing+="$want "
        done
        if [[ -z "$missing" ]]; then
            ok "the captured $flag archive contains every fixture entry"
        else
            no "the captured $flag archive contains every fixture entry" "missing: $missing"
        fi
    else
        no "the captured $flag archive contains every fixture entry" "no archive captured at $exec_tar"
    fi
}

printf '\n== fork-sandbox-k8s.sh submit/run --dry-run --thread-dir ==\n'
td_test_scratch_push --thread-dir /thread thread

printf '\n== fork-sandbox-k8s.sh submit/run --dry-run --attach-dir ==\n'
td_test_scratch_push --attach-dir /attachments attach

printf '\n== fork-sandbox-k8s.sh submit: empty --attach-dir ==\n'
# An empty --attach-dir must still push cleanly: k8s_spool_dir_entries'
# no-members branch (tar cf ... -T /dev/null) and the extractor's
# existing-empty-DEST_DIR acceptance are the two halves that make that
# work end to end.
empty_attach_dir="$(mktemp -d "/var/tmp/claude-scratch/fs-k8s-test-empty-attach.XXXXXX")"; tmpdirs+=("$empty_attach_dir")
empty_attach_git="$(newdir)/git"; tmpdirs+=("$(dirname "$empty_attach_git")")
cat > "$empty_attach_git" <<'STUB'
#!/usr/bin/env bash
case " $* " in
    *" push "*) exit 0 ;;
esac
exec /usr/bin/git "$@"
STUB
chmod +x "$empty_attach_git"
empty_attach_kubectl="$(newdir)/kubectl"; tmpdirs+=("$(dirname "$empty_attach_kubectl")")
cat > "$empty_attach_kubectl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$K8S_STUB_LOG"
verb=""; for arg in "$@"; do case "$arg" in apply|wait|exec|get) verb="$arg" ;; esac; done
case "$verb" in
    apply|wait) cat >/dev/null ;;
    get) printf 'stub-pod\n' ;;
    exec)
        if [[ -n "${K8S_STUB_CAPTURE_TAR:-}" ]] && [[ " $* " == *" ${K8S_STUB_CAPTURE_DEST:-} "* ]]; then
            cat > "$K8S_STUB_CAPTURE_TAR"
        else
            cat >/dev/null
        fi
        ;;
esac
STUB
chmod +x "$empty_attach_kubectl"
empty_attach_log="$(newdir)/kubectl.log"; tmpdirs+=("$(dirname "$empty_attach_log")")
empty_attach_tar="$(newdir)/captured.tar"; tmpdirs+=("$(dirname "$empty_attach_tar")")
if PATH="$(dirname "$empty_attach_git"):$(dirname "$empty_attach_kubectl"):$PATH" \
        K8S_STUB_LOG="$empty_attach_log" K8S_STUB_CAPTURE_DEST="/attachments" \
        K8S_STUB_CAPTURE_TAR="$empty_attach_tar" \
        FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit \
        --branch fs-k8s-test-empty-attach --model moonshotai/kimi-k3 \
        --attach-dir "$empty_attach_dir" "$proj_dir" "$handoff_file" \
        >"$empty_attach_log.submit-out" 2>&1; then
    ok "submit with an empty --attach-dir exits 0"
else
    no "submit with an empty --attach-dir exits 0" "$(cat "$empty_attach_log.submit-out")"
fi
if [[ -f "$empty_attach_tar" ]] && [[ -z "$(tar tf "$empty_attach_tar")" ]]; then
    ok "the captured empty --attach-dir archive has zero members"
else
    no "the captured empty --attach-dir archive has zero members" \
        "$(tar tf "$empty_attach_tar" 2>&1)"
fi
empty_attach_dest="$(newdir)/dest"; mkdir -p "$empty_attach_dest"; tmpdirs+=("$(dirname "$empty_attach_dest")")
if "$context_extract_sh" "$empty_attach_dest" 100000000 < "$empty_attach_tar" \
        >"$empty_attach_log.extract-err" 2>&1; then
    ok "extracting the empty --attach-dir archive into an existing empty dir exits 0"
else
    no "extracting the empty --attach-dir archive into an existing empty dir exits 0" \
        "$(cat "$empty_attach_log.extract-err")"
fi

printf '\n== fork-sandbox-k8s.sh submit: --thread-dir spool is portable to a find(1)-less host ==\n'
# k8s_spool_dir_entries must not shell out to find(1) at all -- BSD find
# (macOS) has no -printf, so the old find|tar pipeline broke there. Prove
# it by putting a find(1) on PATH that unconditionally fails and checking
# the spool still succeeds.
find_stub_dir="$(newdir)"; tmpdirs+=("$find_stub_dir")
cat > "$find_stub_dir/find" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$find_stub_dir/find"
portable_src="$(mktemp -d "/var/tmp/claude-scratch/fs-k8s-test-portable.XXXXXX")"; tmpdirs+=("$portable_src")
printf 'gathered notes\n' > "$portable_src/notes.md"
mkdir -p "$portable_src/sub"
printf 'nested\n' > "$portable_src/sub/nested.txt"
printf 'dotfile\n' > "$portable_src/.dotfile"
portable_git="$(newdir)/git"; tmpdirs+=("$(dirname "$portable_git")")
cat > "$portable_git" <<'STUB'
#!/usr/bin/env bash
case " $* " in
    *" push "*) exit 0 ;;
esac
exec /usr/bin/git "$@"
STUB
chmod +x "$portable_git"
portable_kubectl="$(newdir)/kubectl"; tmpdirs+=("$(dirname "$portable_kubectl")")
cat > "$portable_kubectl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$K8S_STUB_LOG"
verb=""; for arg in "$@"; do case "$arg" in apply|wait|exec|get) verb="$arg" ;; esac; done
case "$verb" in
    apply|wait) cat >/dev/null ;;
    get) printf 'stub-pod\n' ;;
    exec)
        if [[ -n "${K8S_STUB_CAPTURE_TAR:-}" ]] && [[ " $* " == *" ${K8S_STUB_CAPTURE_DEST:-} "* ]]; then
            cat > "$K8S_STUB_CAPTURE_TAR"
        else
            cat >/dev/null
        fi
        ;;
esac
STUB
chmod +x "$portable_kubectl"
portable_log="$(newdir)/kubectl.log"; tmpdirs+=("$(dirname "$portable_log")")
portable_tar="$(newdir)/captured.tar"; tmpdirs+=("$(dirname "$portable_tar")")
if PATH="$find_stub_dir:$(dirname "$portable_git"):$(dirname "$portable_kubectl"):$PATH" \
        K8S_STUB_LOG="$portable_log" K8S_STUB_CAPTURE_DEST="/thread" \
        K8S_STUB_CAPTURE_TAR="$portable_tar" \
        FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit \
        --branch fs-k8s-test-portable --model moonshotai/kimi-k3 \
        --thread-dir "$portable_src" "$proj_dir" "$handoff_file" \
        >"$portable_log.submit-out" 2>&1; then
    ok "submit --thread-dir succeeds with no working find(1) on PATH"
else
    no "submit --thread-dir succeeds with no working find(1) on PATH" \
        "$(cat "$portable_log.submit-out")"
fi
if [[ -s "$portable_tar" ]]; then
    portable_members="$(tar tf "$portable_tar")"
    if grep -qxF './notes.md' <<< "$portable_members" \
        && grep -qxF './sub/nested.txt' <<< "$portable_members" \
        && grep -qxF './.dotfile' <<< "$portable_members" \
        && ! grep -qxF '.' <<< "$portable_members" \
        && ! grep -qxF './' <<< "$portable_members"; then
        ok "the archive captured with no working find(1) has the correct entries-only shape"
    else
        no "the archive captured with no working find(1) has the correct entries-only shape" \
            "$portable_members"
    fi
else
    no "the archive captured with no working find(1) has the correct entries-only shape" \
        "no archive captured at $portable_tar"
fi

printf '\n== fork-sandbox-k8s-context-extract.sh: existing-empty-destination acceptance is exercised above ==\n'
# (covered in the extraction-guards section below, not repeated here.)

printf '\n== fork-sandbox-k8s.sh run: poll/fetch/pull-back vs stubbed kubectl ==\n'
# The sequence cmd_run drives after submit was previously only executable
# against a live cluster (see this file's header); it is now driven end to
# end with a stubbed git (no-ops the ext:: push/fetch) and a stubbed
# kubectl (logs every invocation, serves canned answers). The outbox read
# -- the kubectl exec that tars /work/outbox -- is controlled through the
# environment: it always tars K8S_STUB_OUTBOX_DIR when that is set, then
# exits with K8S_STUB_OUTBOX_RC and writes K8S_STUB_OUTBOX_STDERR to stderr
# -- RC is independent of the streaming, which is what lets a test pair a
# large stream with EPIPE's status.
runstub_dir="$(newdir)"; tmpdirs+=("$runstub_dir")
cat > "$runstub_dir/git" <<'STUB'
#!/usr/bin/env bash
case " $* " in
    *" push "*) exit 0 ;;
    *" fetch "*)
        # Emulate the real fetch's refspec refs/heads/X:refs/heads/X,
        # which creates the local branch at the pod's tip even when the
        # agent committed nothing. The pod's tip is the pushed base
        # (K8S_STUB_BASE_SHA, default: this repo's HEAD), and one commit
        # past it when K8S_STUB_FETCH_REF is set -- the agent
        # "committed".
        base="${K8S_STUB_BASE_SHA:-$(git -C . rev-parse -q --verify HEAD 2>/dev/null || true)}"
        for arg in "$@"; do
            case "$arg" in
                refs/heads/*:refs/heads/*)
                    tip="$base"
                    if [[ -n "${K8S_STUB_FETCH_REF:-}" ]]; then
                        parent="$(git -C . rev-parse -q --verify "$base" 2>/dev/null || true)"
                        if [[ -n "$parent" ]]; then
                            tip="$(GIT_AUTHOR_NAME=stub-fetch GIT_AUTHOR_EMAIL=stub-fetch@fork-sandbox.invalid \
                                GIT_COMMITTER_NAME=stub-fetch GIT_COMMITTER_EMAIL=stub-fetch@fork-sandbox.invalid \
                                git -C . commit-tree "$(git -C . hash-object -t tree /dev/null)" -p "$parent" -m "stub: fetched commit")"
                        fi
                    fi
                    [[ -n "$tip" ]] && git -C . update-ref "refs/heads/${arg#*:}" "$tip"
                    ;;
            esac
        done
        exit 0 ;;
esac
exec /usr/bin/git "$@"
STUB
cat > "$runstub_dir/kubectl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$K8S_STUB_LOG"
case " $* " in
    *"context-extract.sh /work/session-store "*)
        # The session-store push (cmd_submit, alongside --context-ro's own
        # push): capture the piped tar stream whenever a test asks, so it
        # can prove the host --session-state directory's own content is
        # what got pushed, not just that the call happened.
        if [[ -n "${K8S_STUB_SESSION_PUSH_CAPTURE:-}" ]]; then
            cat > "$K8S_STUB_SESSION_PUSH_CAPTURE"
        else
            cat >/dev/null
        fi
        exit 0 ;;
    *" apply -f -"*)
        if [[ -n "${K8S_STUB_APPLY_MANIFEST:-}" ]]; then
            cat > "$K8S_STUB_APPLY_MANIFEST"
        else
            cat >/dev/null
        fi
        # Overridable so a test can simulate a submit that dies at the
        # manifest apply -- well after the run directory (and everything
        # submit had spooled before this call) already exists.
        exit "${K8S_STUB_APPLY_RC:-0}" ;;
    *" wait "*) exit 0 ;;
    *" get pod -l job-name="*) printf 'stub-pod\n' ;;
    *" -o jsonpath={.status.phase} "*)
        # cmd_wait's per-poll liveness check. Defaults to Running (never
        # Failed/Succeeded, so the poll loop falls through to the sentinel
        # read below) unless a test overrides it to exercise a dead pod.
        printf '%s\n' "${K8S_STUB_POD_PHASE:-Running}"; exit 0 ;;
    *" get pod "*)
        # The pod's spec, for the per-container log capture.
        spec="${K8S_STUB_POD_SPEC:-}"
        [[ -n "$spec" ]] || spec='{"spec":{"containers":[{"name":"agent"}]}}'
        printf '%s\n' "$spec" ;;
    *" get "*) printf 'stub-pod\n' ;;
    *" /work/repo.git rev-parse "*)
        # The pushed base sha, read by the zero-harvest check on every
        # collect (first and re-collect alike).
        printf '%s\n' "${K8S_STUB_BASE_SHA:-}"
        exit 0 ;;
    *" delete "*) exit 0 ;;
    *" logs "*) printf 'stub pod log: entrypoint narration\n'; exit 0 ;;
    *" tar cf - -C /work/outbox "*)
        # Serve the fixture stream whenever K8S_STUB_OUTBOX_DIR is set,
        # independently of the exit status -- a kubectl exec that dies of
        # EPIPE partway through an over-cap stream has already streamed
        # data, so callers can pair a large fixture with a non-zero RC.
        if [[ -n "${K8S_STUB_OUTBOX_DIR:-}" ]]; then
            ( cd "$K8S_STUB_OUTBOX_DIR" && tar cf - . ) || true
        fi
        [[ -n "${K8S_STUB_OUTBOX_STDERR:-}" ]] && printf '%s' "$K8S_STUB_OUTBOX_STDERR" >&2
        exit "${K8S_STUB_OUTBOX_RC:-1}"
        ;;
    *" cat /work/.run-complete "*)
        # Overridable so a test can simulate a pod that died before ever
        # writing the sentinel -- exec into it just fails, the same as a
        # real dead container.
        if [[ -n "${K8S_STUB_RUN_COMPLETE_RC:-}" ]]; then
            exit "$K8S_STUB_RUN_COMPLETE_RC"
        fi
        # A still-running pod: the sentinel read fails until the Nth poll.
        if [[ -n "${K8S_STUB_RUN_COMPLETE_AFTER:-}" ]]; then
            n=$(( $(cat "$K8S_STUB_COUNTER" 2>/dev/null || echo 0) + 1 ))
            printf '%s' "$n" > "$K8S_STUB_COUNTER"
            (( n > K8S_STUB_RUN_COMPLETE_AFTER )) || exit 1
        fi
        printf '%s\n' "${K8S_STUB_RUN_COMPLETE_VALUE:-0}" ;;
esac
exit 0
STUB
chmod +x "$runstub_dir/git" "$runstub_dir/kubectl"
runstub_pod_outbox="$(newdir)"; tmpdirs+=("$runstub_pod_outbox")
printf 'an artifact\n' > "$runstub_pod_outbox/hello.txt"
runstub_run() {
    # $1 = kubectl log, $2 = output file, rest = fork-sandbox-k8s.sh run args.
    # K8S_STUB_OUTBOX_DIR may be set by the caller to serve a different
    # pod-side outbox fixture than the default one. K8S_STUB_BASE_SHA
    # defaults to this repo's HEAD: the pod's bare repository always holds
    # a pushed base, so the stub's emulated fetch and the stub's base-sha
    # read must agree on one, and the caller's repo's own HEAD is the only
    # sha both can reach.
    local log="$1" out="$2" run_home="$HOME"; shift 2
    [[ "$run_home" == "$k8s_test_operator_home" ]] && run_home="$k8s_test_home"
    HOME="$run_home" PATH="$runstub_dir:$PATH" K8S_STUB_LOG="$log" \
        K8S_STUB_BASE_SHA="${K8S_STUB_BASE_SHA:-$(git -C "$proj_dir" rev-parse HEAD)}" \
        K8S_STUB_OUTBOX_DIR="${K8S_STUB_OUTBOX_DIR:-$runstub_pod_outbox}" \
        FORK_SANDBOX_CONFIG_DIR="$config_dir" \
        "$k8s_sh" run "$@" > "$out" 2>&1
}

# 1. A failed outbox read must surface kubectl's own stderr: the stub's
# exec writes a recognizable string to stderr and exits non-zero, and the
# operator sees both the existing warning and that string.
runstub_log1="$(newdir)/kubectl.log"; runstub_out1="$(newdir)/out1.txt"
tmpdirs+=("$(dirname "$runstub_log1")" "$(dirname "$runstub_out1")")
if K8S_STUB_OUTBOX_STDERR='stub-kubectl says: pod stub-pod is already Completed' \
    K8S_STUB_OUTBOX_RC=1 runstub_run "$runstub_log1" "$runstub_out1" \
    --branch fs-k8s-test-run-outbox-err --model moonshotai/kimi-k3 \
    --outbox-dir "$(dirname "$runstub_out1")/outbox-1" \
    "$proj_dir" "$handoff_file"; then
    if grep -q 'warning: could not read the outbox' "$runstub_out1" \
        && grep -q 'stub-kubectl says: pod stub-pod is already Completed' "$runstub_out1" \
        && grep -q 'run complete' "$runstub_out1"; then
        ok "failed outbox read surfaces kubectl's own stderr"
    else
        no "failed outbox read surfaces kubectl's own stderr" "$(cat "$runstub_out1")"
    fi
else
    no "failed outbox read surfaces kubectl's own stderr" "run exited nonzero: $(cat "$runstub_out1")"
fi

# 1b. `run` actually threads --run-dir from its own submit phase to its own
# collect phase: the only path a real `fork-sandbox.sh --k8s` run takes,
# and the one behavior in this file's own header that nothing directly
# asserted before this test -- dropping K8S_LAST_SUBMIT_RUN_DIR or the
# `[[ -n "$run_dir" ]] && collect_argv+=(--run-dir ...)` line in cmd_run
# would leave every test above green while this silently stopped working.
# Reuses test 1's own successful run, whose stubbed outbox read failed but
# whose run still completed and collected.
runstub_rd1="$(sed -n 's/^  run dir:  *//p' "$runstub_out1" | head -1)"
if [[ -n "$runstub_rd1" && -f "$runstub_rd1/summary.json" ]] \
    && jq -e . "$runstub_rd1/summary.json" >/dev/null 2>&1; then
    ok "run threads --run-dir: submit's run dir carries a summary.json after run"
    check "run threads --run-dir: summary.json branch" \
        "fs-k8s-test-run-outbox-err" "$(jq -r '.branch' "$runstub_rd1/summary.json")"
    check "run threads --run-dir: summary.json mode" \
        "run" "$(jq -r '.mode' "$runstub_rd1/summary.json")"
    runstub_rd1_log_home="$(newdir)"; tmpdirs+=("$runstub_rd1_log_home")
    HOME="$runstub_rd1_log_home" python3 "$repo_dir/scripts/sandbox-run-log.py" \
        record --run-dir "$runstub_rd1" >/dev/null 2>&1
    runstub_rd1_log_line="$(tail -1 "$runstub_rd1_log_home/.claude/sandbox-runs.jsonl" 2>/dev/null)"
    check "run threads --run-dir: record() folds in the same branch" \
        "fs-k8s-test-run-outbox-err" "$(jq -r '.branch' <<< "$runstub_rd1_log_line")"
else
    no "run threads --run-dir: submit's run dir carries a summary.json after run" \
        "run_dir=$runstub_rd1 $([[ -n "$runstub_rd1" ]] && cat "$runstub_rd1/summary.json" 2>/dev/null; echo NOFILE)"
fi

# 1c. cmd_run's OTHER call to sandbox-run-log.py record -- the wait-failure
# branch, reached when cmd_wait fails before the agent's sentinel ever
# appears -- is never exercised by the wait-verb tests above (every one of
# those drives cmd_wait directly, never through cmd_run, so none of them
# ever reach this second call site). This drives `run` for real, with the
# pod's sentinel read failing and its phase Failed (a genuinely dead pod --
# the terminal case this branch means to cover), $HOME pointed at a
# scratch directory, and the repo's own scripts/ on PATH so the real
# sandbox-run-log.py is what runs, then reads the row back from that real,
# unmodified $HOME/.claude/sandbox-runs.jsonl -- not a second, separate
# invocation of record() the way the checks above do.
reallog2_home="$(newdir)"; tmpdirs+=("$reallog2_home")
reallog2_log="$(newdir)/kubectl.log"; reallog2_out="$(newdir)/out.txt"
tmpdirs+=("$(dirname "$reallog2_log")" "$(dirname "$reallog2_out")")
rc=0
HOME="$reallog2_home" PATH="$repo_dir/scripts:$PATH" \
    K8S_STUB_RUN_COMPLETE_RC=1 K8S_STUB_POD_PHASE=Failed \
    runstub_run "$reallog2_log" "$reallog2_out" \
    --branch fs-k8s-test-run-waitfail-deadpod --model moonshotai/kimi-k3 \
    "$proj_dir" "$handoff_file" || rc=$?
reallog2_line="$(tail -1 "$reallog2_home/.claude/sandbox-runs.jsonl" 2>/dev/null)"
if (( rc == 2 )) && [[ -n "$reallog2_line" ]] \
    && [[ "$(jq -r '.branch' <<< "$reallog2_line")" == "fs-k8s-test-run-waitfail-deadpod" ]] \
    && [[ "$(jq -r '.summary_missing' <<< "$reallog2_line")" == "true" ]]; then
    ok "cmd_run's wait-failure path really records a row for a dead pod (terminal, exit 2)"
else
    no "cmd_run's wait-failure path really records a row for a dead pod (terminal, exit 2)" \
        "rc=$rc line=$reallog2_line out=$(cat "$reallog2_out")"
fi

# The flip side of that same fix: a TIMEOUT (exit 1) is not terminal --
# cmd_wait's own message says the pod is still running, holding its work
# -- so this call site must NOT record a row for it. A premature run_end
# while the run is still going would be a false record that nothing later
# ever supersedes (the by-hand fetch/rm advice passes no --run-dir).
reallog3_home="$(newdir)"; tmpdirs+=("$reallog3_home")
reallog3_log="$(newdir)/kubectl.log"; reallog3_out="$(newdir)/out.txt"
tmpdirs+=("$(dirname "$reallog3_log")" "$(dirname "$reallog3_out")")
rc=0
HOME="$reallog3_home" PATH="$repo_dir/scripts:$PATH" \
    K8S_STUB_RUN_COMPLETE_RC=1 \
    runstub_run "$reallog3_log" "$reallog3_out" \
    --branch fs-k8s-test-run-waitfail-timeout --model moonshotai/kimi-k3 --timeout 0 \
    "$proj_dir" "$handoff_file" || rc=$?
if (( rc == 1 )) && [[ ! -f "$reallog3_home/.claude/sandbox-runs.jsonl" ]]; then
    ok "cmd_run's wait-failure path records nothing for a timeout (not terminal, exit 1)"
else
    no "cmd_run's wait-failure path records nothing for a timeout (not terminal, exit 1)" \
        "rc=$rc log=$(cat "$reallog3_home/.claude/sandbox-runs.jsonl" 2>/dev/null) out=$(cat "$reallog3_out")"
fi

# 1d. `resume`: run's tail, for a run submit already created. Each case
# submits for real (against the stubs) and then resumes from the run
# directory alone.
resume_nosleep="$(newdir)"; tmpdirs+=("$resume_nosleep")
printf '#!/usr/bin/env bash\nexit 0\n' > "$resume_nosleep/sleep"
chmod +x "$resume_nosleep/sleep"
runstub_verb() {
    # $1 = kubectl log, $2 = output file, $3 = verb, rest = its args.
    local log="$1" out="$2" verb="$3" run_home="$HOME"; shift 3
    [[ "$run_home" == "$k8s_test_operator_home" ]] && run_home="$k8s_test_home"
    HOME="$run_home" PATH="${RESUME_EXTRA_PATH:+$RESUME_EXTRA_PATH:}$runstub_dir:$PATH" \
        K8S_STUB_LOG="$log" \
        K8S_STUB_BASE_SHA="${K8S_STUB_BASE_SHA:-$(git -C "$proj_dir" rev-parse HEAD)}" \
        K8S_STUB_OUTBOX_DIR="${K8S_STUB_OUTBOX_DIR:-$runstub_pod_outbox}" \
        FORK_SANDBOX_CONFIG_DIR="$config_dir" \
        "$k8s_sh" "$verb" "$@" > "$out" 2>&1
}
# Submits a run and prints its run dir; $1 = branch, rest = extra submit args.
resume_submit() {
    local branch="$1"; shift
    local d; d="$(newdir)"; tmpdirs+=("$d")
    runstub_verb "$d/submit.log" "$d/submit.out" submit --branch "$branch" \
        --model moonshotai/kimi-k3 "$@" "$proj_dir" "$handoff_file" || return 1
    sed -n 's/^  run dir:  *//p' "$d/submit.out" | head -1
}

resume_rd_a="$(resume_submit fs-k8s-test-resume-done \
    --outbox-dir "$(newdir)/resume-outbox-a" --timeout 900 --keep)"
resume_env_a="$resume_rd_a/run.env"
for kv in BRANCH=fs-k8s-test-resume-done "PROJECT=$proj_dir" TIMEOUT=900 KEEP=true \
    REVIEW_LOOP= "OUTBOX_MAX_BYTES=$((64 * 1024 * 1024))"; do
    if grep -qxF -- "$kv" "$resume_env_a"; then ok "submit records $kv in run.env"
    else no "submit records $kv in run.env" "$(cat "$resume_env_a" 2>/dev/null)"; fi
done
if grep -qE '^OUTBOX_DIR=.+/resume-outbox-a$' "$resume_env_a" \
    && grep -qE '^SUBMITTED_AT=[0-9]+$' "$resume_env_a"; then
    ok "submit records OUTBOX_DIR and SUBMITTED_AT in run.env"
else
    no "submit records OUTBOX_DIR and SUBMITTED_AT in run.env" "$(cat "$resume_env_a" 2>/dev/null)"
fi
resume_log_a="$(newdir)/kubectl.log"; resume_out_a="$(dirname "$resume_log_a")/out.txt"
tmpdirs+=("$(dirname "$resume_log_a")")
rc=0
K8S_STUB_RUN_COMPLETE_VALUE=7 K8S_STUB_OUTBOX_RC=0 \
    runstub_verb "$resume_log_a" "$resume_out_a" resume --run-dir "$resume_rd_a" || rc=$?
if (( rc == 7 )) && grep -q 'run complete. branch=fs-k8s-test-resume-done agent_exit=7' "$resume_out_a" \
    && [[ -f "$resume_rd_a/summary.json" ]] \
    && [[ -f "$(sed -n 's/^OUTBOX_DIR=//p' "$resume_env_a")/hello.txt" ]] \
    && ! grep -q ' delete ' "$resume_log_a"; then
    ok "resume on a completed run collects and exits with the agent's code (outbox dir and keep read back)"
else
    no "resume on a completed run collects and exits with the agent's code (outbox dir and keep read back)" \
        "rc=$rc out=$(cat "$resume_out_a") log=$(cat "$resume_log_a")"
fi
if ! grep -q 'apply -f -' "$resume_log_a"; then
    ok "resume submits nothing"
else
    no "resume submits nothing" "$(cat "$resume_log_a")"
fi

resume_rd_b="$(resume_submit fs-k8s-test-resume-running)"
resume_log_b="$(newdir)/kubectl.log"; resume_out_b="$(dirname "$resume_log_b")/out.txt"
tmpdirs+=("$(dirname "$resume_log_b")")
rc=0
RESUME_EXTRA_PATH="$resume_nosleep" K8S_STUB_RUN_COMPLETE_AFTER=2 \
    K8S_STUB_COUNTER="$(dirname "$resume_log_b")/count" \
    runstub_verb "$resume_log_b" "$resume_out_b" resume --run-dir "$resume_rd_b" || rc=$?
if (( rc == 0 )) && [[ "$(cat "$(dirname "$resume_log_b")/count")" -ge 3 ]] \
    && grep -q 'run complete. branch=fs-k8s-test-resume-running agent_exit=0' "$resume_out_b" \
    && [[ -f "$resume_rd_b/summary.json" ]]; then
    ok "resume on a still-running run waits, then collects"
else
    no "resume on a still-running run waits, then collects" "rc=$rc out=$(cat "$resume_out_b")"
fi

resume_rd_c="$(resume_submit fs-k8s-test-resume-dead)"
resume_home_c="$(newdir)"; tmpdirs+=("$resume_home_c")
resume_log_c="$(newdir)/kubectl.log"; resume_out_c="$(dirname "$resume_log_c")/out.txt"
tmpdirs+=("$(dirname "$resume_log_c")")
rc=0
HOME="$resume_home_c" RESUME_EXTRA_PATH="$repo_dir/scripts" \
    K8S_STUB_RUN_COMPLETE_RC=1 K8S_STUB_POD_PHASE=Failed \
    runstub_verb "$resume_log_c" "$resume_out_c" resume --run-dir "$resume_rd_c" || rc=$?
resume_line_c="$(tail -1 "$resume_home_c/.claude/sandbox-runs.jsonl" 2>/dev/null)"
if (( rc == 2 )) && [[ "$(jq -r '.branch' <<< "$resume_line_c")" == fs-k8s-test-resume-dead ]] \
    && [[ "$(jq -r '.summary_missing' <<< "$resume_line_c")" == true ]]; then
    ok "resume on a dead pod exits 2 and writes the run-log row"
else
    no "resume on a dead pod exits 2 and writes the run-log row" \
        "rc=$rc line=$resume_line_c out=$(cat "$resume_out_c")"
fi

resume_rd_d="$(resume_submit fs-k8s-test-resume-timeout)"
resume_home_d="$(newdir)"; tmpdirs+=("$resume_home_d")
resume_log_d="$(newdir)/kubectl.log"; resume_out_d="$(dirname "$resume_log_d")/out.txt"
tmpdirs+=("$(dirname "$resume_log_d")")
rc=0
HOME="$resume_home_d" RESUME_EXTRA_PATH="$repo_dir/scripts" K8S_STUB_RUN_COMPLETE_RC=1 \
    runstub_verb "$resume_log_d" "$resume_out_d" resume --run-dir "$resume_rd_d" --timeout 0 || rc=$?
if (( rc == 1 )) && grep -q 'timed out after 0s waiting for branch' "$resume_out_d" \
    && [[ ! -f "$resume_home_d/.claude/sandbox-runs.jsonl" ]]; then
    ok "resume: a wait timeout exits 1 and records nothing (the Job is still running)"
else
    no "resume: a wait timeout exits 1 and records nothing (the Job is still running)" \
        "rc=$rc out=$(cat "$resume_out_d")"
fi

resume_rd_e="$(resume_submit fs-k8s-test-resume-nobranch)"
sed -i '/^BRANCH=/d' "$resume_rd_e/run.env"
rc=0
runstub_verb "$(newdir)/kubectl.log" "$resume_rd_e/resume.out" resume --run-dir "$resume_rd_e" || rc=$?
if (( rc == 1 )) && grep -q 'lacks BRANCH or PROJECT' "$resume_rd_e/resume.out"; then
    ok "resume refuses a run.env missing BRANCH"
else
    no "resume refuses a run.env missing BRANCH" "rc=$rc out=$(cat "$resume_rd_e/resume.out")"
fi
resume_empty_dir="$(newdir)"; tmpdirs+=("$resume_empty_dir")
rc=0
runstub_verb "$(newdir)/kubectl.log" "$resume_empty_dir/out" resume --run-dir "$resume_empty_dir" || rc=$?
if (( rc == 1 )) && grep -q 'has no run.env' "$resume_empty_dir/out"; then
    ok "resume refuses a run dir without run.env"
else
    no "resume refuses a run dir without run.env" "rc=$rc out=$(cat "$resume_empty_dir/out")"
fi

# resume's default --timeout (no --timeout given) is the recorded TIMEOUT
# minus time elapsed since SUBMITTED_AT -- cmd_wait's own startup line
# (printed to stderr only when --probe is not given, which resume's
# internal cmd_wait call never passes) reveals the timeout it actually
# computed.
resume_rd_f="$(resume_submit fs-k8s-test-resume-timeout-default --timeout 900)"
sed -i "s/^SUBMITTED_AT=.*/SUBMITTED_AT=$(( $(date +%s) - 100 ))/" "$resume_rd_f/run.env"
resume_log_f="$(newdir)/kubectl.log"; resume_out_f="$(dirname "$resume_log_f")/out.txt"
tmpdirs+=("$(dirname "$resume_log_f")")
rc=0
runstub_verb "$resume_log_f" "$resume_out_f" resume --run-dir "$resume_rd_f" || rc=$?
resume_f_timeout="$(grep -oE 'timeout [0-9]+s\)' "$resume_out_f" | grep -oE '[0-9]+')"
if (( rc == 0 )) && [[ -n "$resume_f_timeout" ]] \
    && (( resume_f_timeout >= 790 && resume_f_timeout <= 800 )); then
    ok "resume's default --timeout is the recorded timeout minus time elapsed since submit"
else
    no "resume's default --timeout is the recorded timeout minus time elapsed since submit" \
        "rc=$rc timeout=$resume_f_timeout out=$(cat "$resume_out_f")"
fi

# The same default, floored at 60s once elapsed time exceeds the recorded
# timeout.
resume_rd_g="$(resume_submit fs-k8s-test-resume-timeout-floor --timeout 120)"
sed -i "s/^SUBMITTED_AT=.*/SUBMITTED_AT=$(( $(date +%s) - 10000 ))/" "$resume_rd_g/run.env"
resume_log_g="$(newdir)/kubectl.log"; resume_out_g="$(dirname "$resume_log_g")/out.txt"
tmpdirs+=("$(dirname "$resume_log_g")")
rc=0
runstub_verb "$resume_log_g" "$resume_out_g" resume --run-dir "$resume_rd_g" || rc=$?
resume_g_timeout="$(grep -oE 'timeout [0-9]+s\)' "$resume_out_g" | grep -oE '[0-9]+')"
if (( rc == 0 )) && [[ "$resume_g_timeout" == 60 ]]; then
    ok "resume's default --timeout floors at 60s once elapsed exceeds the recorded timeout"
else
    no "resume's default --timeout floors at 60s once elapsed exceeds the recorded timeout" \
        "rc=$rc timeout=$resume_g_timeout out=$(cat "$resume_out_g")"
fi

# A relative --outbox-dir given to a direct CLI `submit` is recorded
# absolute, resolved against submit's own cwd -- not left relative, which
# would resolve against `resume`'s cwd later instead of the original
# caller's.
resume_reldir_home="$(newdir)"; tmpdirs+=("$resume_reldir_home")
resume_reldir_cwd="$(newdir)"; tmpdirs+=("$resume_reldir_cwd")
resume_reldir_d="$(newdir)"; tmpdirs+=("$resume_reldir_d")
rc=0
[[ "$HOME" == "$k8s_test_operator_home" ]] && resume_reldir_run_home="$k8s_test_home" \
    || resume_reldir_run_home="$HOME"
(
    cd "$resume_reldir_cwd" \
        && HOME="$resume_reldir_run_home" PATH="$runstub_dir:$PATH" \
            K8S_STUB_LOG="$resume_reldir_d/submit.log" \
            K8S_STUB_BASE_SHA="$(git -C "$proj_dir" rev-parse HEAD)" \
            FORK_SANDBOX_CONFIG_DIR="$config_dir" \
            "$k8s_sh" submit --branch fs-k8s-test-resume-reloutbox \
            --model moonshotai/kimi-k3 --outbox-dir relative-subdir \
            "$proj_dir" "$handoff_file" > "$resume_reldir_d/submit.out" 2>&1
) || rc=$?
resume_reldir_rd="$(sed -n 's/^  run dir:  *//p' "$resume_reldir_d/submit.out" | head -1)"
if (( rc == 0 )) \
    && grep -qxF "OUTBOX_DIR=$(realpath -m "$resume_reldir_cwd/relative-subdir")" \
        "$resume_reldir_rd/run.env"; then
    ok "submit records a relative --outbox-dir absolute, resolved against its own cwd"
else
    no "submit records a relative --outbox-dir absolute, resolved against its own cwd" \
        "rc=$rc run.env=$(cat "$resume_reldir_rd/run.env" 2>/dev/null)"
fi

# 2. A failed read with NOTHING on stderr is reported as silent, not as an
# empty block: the explicit "wrote nothing" line, and not the heading the
# non-empty case prints.
runstub_log2="$(newdir)/kubectl.log"; runstub_out2="$(newdir)/out2.txt"
tmpdirs+=("$(dirname "$runstub_log2")" "$(dirname "$runstub_out2")")
if K8S_STUB_OUTBOX_STDERR='' K8S_STUB_OUTBOX_RC=1 \
    runstub_run "$runstub_log2" "$runstub_out2" \
    --branch fs-k8s-test-run-outbox-silent --model moonshotai/kimi-k3 \
    --outbox-dir "$(dirname "$runstub_out2")/outbox-2" \
    "$proj_dir" "$handoff_file"; then
    if grep -q 'wrote nothing to stderr' "$runstub_out2" \
        && ! grep -q 'reported, on stderr:' "$runstub_out2"; then
        ok "failed outbox read with empty stderr is reported as silent"
    else
        no "failed outbox read with empty stderr is reported as silent" "$(cat "$runstub_out2")"
    fi
else
    no "failed outbox read with empty stderr is reported as silent" "run exited nonzero: $(cat "$runstub_out2")"
fi

# 3. The regression test for the ordering: the stubbed kubectl logs every
# invocation, and the outbox tar read must appear in that log BEFORE the
# fetch's touch /work/.fetched -- which is what makes the pod exit, and a
# kubectl exec into a completed pod fails. The same log line must carry
# the request-timeout bound that keeps a hung read from delaying the
# fetch indefinitely.
runstub_log3="$(newdir)/kubectl.log"; runstub_out3="$(newdir)/out3.txt"; runstub_dest3="$(newdir)/outbox-3"
tmpdirs+=("$(dirname "$runstub_log3")" "$(dirname "$runstub_out3")" "$(dirname "$runstub_dest3")")
if K8S_STUB_OUTBOX_RC=0 runstub_run "$runstub_log3" "$runstub_out3" \
    --branch fs-k8s-test-run-ordering --model moonshotai/kimi-k3 \
    --outbox-dir "$runstub_dest3" \
    "$proj_dir" "$handoff_file"; then
    # || true: under pipefail a grep that finds nothing would otherwise
    # take the whole suite down at the assignment rather than failing the
    # assertion below.
    tar_ln="$(grep -n 'tar cf - -C /work/outbox' "$runstub_log3" | head -n 1 | cut -d: -f1 || true)"
    fetched_ln="$(grep -n 'touch /work/.fetched' "$runstub_log3" | head -n 1 | cut -d: -f1 || true)"
    # The run path's own pod-log capture is asserted here too: the
    # per-container log file must exist in the evidence sibling, so a
    # capture silently abandoned on this path (non-JSON pod spec, failed
    # jq) cannot pass without a missing file.
    if [[ -n "$tar_ln" && -n "$fetched_ln" ]] && (( tar_ln < fetched_ln )) \
        && grep -q -- '--request-timeout=60s' <(sed -n "${tar_ln}p" "$runstub_log3") \
        && [[ -f "$runstub_dest3/hello.txt" ]] \
        && [[ -f "$(dirname -- "$runstub_dest3")/evidence/pod-log-agent.log" ]] \
        && grep -q 'outbox: 1 agent file(s) at' "$runstub_out3"; then
        ok "outbox is pulled back before the fetch touches /work/.fetched"
        ok "the outbox kubectl exec carries a request-timeout bound"
    else
        no "outbox is pulled back before the fetch touches /work/.fetched" \
            "tar_ln=$tar_ln fetched_ln=$fetched_ln dest=$(find "$runstub_dest3" 2>/dev/null) out=$(cat "$runstub_out3")"
    fi
else
    no "outbox is pulled back before the fetch touches /work/.fetched" "run exited nonzero: $(cat "$runstub_out3")"
fi

# 4. A substantially-over-cap outbox is the over-cap case, not a read
# failure: with set -o pipefail in force, head -c exiting early makes
# kubectl die of EPIPE and the pipeline non-zero. K8S_STUB_OUTBOX_RC=141
# (bash's SIGPIPE status) emulates that EPIPE on a stream that is well
# past the cap -- the run must warn about the cap, not report a failed
# read, and must not extract anything.
runstub_big_outbox="$(newdir)"; tmpdirs+=("$runstub_big_outbox")
head -c 4096 /dev/zero > "$runstub_big_outbox/big.bin"
runstub_log4="$(newdir)/kubectl.log"; runstub_out4="$(newdir)/out4.txt"; runstub_dest4="$(newdir)/outbox-4"
tmpdirs+=("$(dirname "$runstub_log4")" "$(dirname "$runstub_out4")" "$(dirname "$runstub_dest4")")
if K8S_STUB_OUTBOX_DIR="$runstub_big_outbox" K8S_STUB_OUTBOX_RC=141 \
    runstub_run "$runstub_log4" "$runstub_out4" \
    --branch fs-k8s-test-run-outbox-overcap --model moonshotai/kimi-k3 \
    --outbox-max 128 \
    --outbox-dir "$runstub_dest4" \
    "$proj_dir" "$handoff_file"; then
    if grep -q 'over the 128 byte cap; refusing to pull it back' "$runstub_out4" \
        && ! grep -q 'could not read the outbox' "$runstub_out4" \
        && [[ ! -d "$runstub_dest4" ]] \
        && grep -q 'run complete' "$runstub_out4"; then
        ok "substantially-over-cap outbox is diagnosed as over the cap, not a read failure"
    else
        no "substantially-over-cap outbox is diagnosed as over the cap, not a read failure" \
            "dest=$(find "$runstub_dest4" 2>/dev/null) out=$(cat "$runstub_out4")"
    fi
else
    no "substantially-over-cap outbox is diagnosed as over the cap, not a read failure" "run exited nonzero: $(cat "$runstub_out4")"
fi

# 5. The review-loop.json read is the second kubectl exec in run's tail
# sequence that can execute while the pod is idle, so it must carry the
# same --request-timeout bound as the outbox read: a --review-loop run's
# kubectl log shows the bound on that exec too.
runstub_log5="$(newdir)/kubectl.log"; runstub_out5="$(newdir)/out5.txt"
tmpdirs+=("$(dirname "$runstub_log5")" "$(dirname "$runstub_out5")")
if runstub_run "$runstub_log5" "$runstub_out5" \
    --branch fs-k8s-test-run-loop-timeout --model moonshotai/kimi-k3 \
    --review-loop 1 \
    --outbox-dir "$(dirname "$runstub_out5")/outbox-5" \
    "$proj_dir" "$handoff_file"; then
    # || true: under pipefail a grep that finds nothing would otherwise
    # take the whole suite down at the assignment rather than failing the
    # assertion below.
    loop_ln="$(grep -n 'cat /work/review-loop.json' "$runstub_log5" | head -n 1 | cut -d: -f1 || true)"
    if [[ -n "$loop_ln" ]] \
        && grep -q -- '--request-timeout=60s' <(sed -n "${loop_ln}p" "$runstub_log5"); then
        ok "the review-loop.json kubectl exec carries a request-timeout bound"
    else
        no "the review-loop.json kubectl exec carries a request-timeout bound" \
            "loop_ln=$loop_ln out=$(cat "$runstub_out5")"
    fi
else
    no "the review-loop.json kubectl exec carries a request-timeout bound" "run exited nonzero: $(cat "$runstub_out5")"
fi

# 6. A dead run through run: the agent's sentinel holds 0, the stubbed
# fetch lands no commits, and the outbox holds nothing but the entrypoint's
# own .fork-sandbox-model dotfile -- the full three-way zero-harvest
# conjunction. run must exit non-zero (3, collect's suspicious code), must
# not print the success line, and must not reap the job.
runstub_dead_outbox="$(newdir)"; tmpdirs+=("$runstub_dead_outbox")
mkdir -p -- "$runstub_dead_outbox"
printf 'discovered-model\n' > "$runstub_dead_outbox/.fork-sandbox-model"
runstub_log6="$(newdir)/kubectl.log"; runstub_out6="$(newdir)/out6.txt"; runstub_dest6="$(newdir)/outbox-6"
tmpdirs+=("$(dirname "$runstub_log6")" "$(dirname "$runstub_out6")" "$(dirname "$runstub_dest6")")
rc=0
K8S_STUB_OUTBOX_DIR="$runstub_dead_outbox" K8S_STUB_OUTBOX_RC=0 \
    runstub_run "$runstub_log6" "$runstub_out6" \
    --branch fs-k8s-test-run-dead --model moonshotai/kimi-k3 \
    --outbox-dir "$runstub_dest6" \
    "$proj_dir" "$handoff_file" || rc=$?
if (( rc == 3 )) \
    && grep -q 'SUSPICIOUS: this run produced nothing' "$runstub_out6" \
    && ! grep -q 'run complete' "$runstub_out6" \
    && ! grep -q 'delete job' "$runstub_log6" \
    && grep -qF -- "fork-sandbox-k8s.sh rm --branch fs-k8s-test-run-dead" "$runstub_out6" \
    && grep -q 'outbox: empty of agent files (only 1 operator metadata file(s))' "$runstub_out6"; then
    ok "a dead run through run exits 3, keeps the job, and names the manual rm"
else
    no "a dead run through run exits 3, keeps the job, and names the manual rm" \
        "rc=$rc log=$(grep delete "$runstub_log6") out=$(cat "$runstub_out6")"
fi

# 7. A pod that dies before writing the sentinel: cmd_wait itself fails
# (Failed phase, code 2, before collect ever runs -- see the "wait: direct
# drive" section below for that exit code's own coverage), and run must
# still leave a row in the durable run log rather than the run directory
# submit created sitting with no summary.json and no record at all -- the
# exact "seat silently failing" case this log exists to surface. run's own
# exit code must stay wait's terminal code (2), not the agent's.
runstub_log7="$(newdir)/kubectl.log"; runstub_out7="$(newdir)/out7.txt"
tmpdirs+=("$(dirname "$runstub_log7")" "$(dirname "$runstub_out7")")
rc=0
K8S_STUB_RUN_COMPLETE_RC=1 K8S_STUB_POD_PHASE=Failed \
    runstub_run "$runstub_log7" "$runstub_out7" \
    --branch fs-k8s-test-run-wait-fail --model moonshotai/kimi-k3 \
    "$proj_dir" "$handoff_file" || rc=$?
runstub_rd7="$(sed -n 's/^  run dir:  *//p' "$runstub_out7" | head -1)"
if (( rc == 2 )) && [[ -n "$runstub_rd7" && -d "$runstub_rd7" ]] \
    && grep -q 'is Failed' "$runstub_out7" \
    && ! grep -q 'run complete' "$runstub_out7"; then
    ok "a run whose pod dies before the sentinel exits wait's own code (2)"
else
    no "a run whose pod dies before the sentinel exits wait's own code (2)" \
        "rc=$rc run_dir=$runstub_rd7 out=$(cat "$runstub_out7")"
fi
check "a dead-pod run's directory carries no summary.json (collect never ran)" \
    "false" "$([[ -n "$runstub_rd7" ]] && [[ -f "$runstub_rd7/summary.json" ]] && echo true || echo false)"
if [[ -n "$runstub_rd7" ]]; then
    runstub_rd7_log_home="$(newdir)"; tmpdirs+=("$runstub_rd7_log_home")
    HOME="$runstub_rd7_log_home" python3 "$repo_dir/scripts/sandbox-run-log.py" \
        record --run-dir "$runstub_rd7" >/dev/null 2>&1
    runstub_rd7_log_line="$(tail -1 "$runstub_rd7_log_home/.claude/sandbox-runs.jsonl" 2>/dev/null)"
    check "a dead-pod run's row went through record's summary-missing fallback" \
        "true" "$(jq -r '.summary_missing' <<< "$runstub_rd7_log_line")"
    check "a dead-pod run's row falls back to run.env: branch" \
        "fs-k8s-test-run-wait-fail" "$(jq -r '.branch' <<< "$runstub_rd7_log_line")"
    check "a dead-pod run's row falls back to run.env: model" \
        "moonshotai/kimi-k3" "$(jq -r '.model' <<< "$runstub_rd7_log_line")"
    check "a dead-pod run's row carries no exit_code (none is known)" \
        "false" "$(jq 'has("exit_code")' <<< "$runstub_rd7_log_line")"
fi

printf '\n== fork-sandbox-k8s.sh wait: direct drive vs stubbed kubectl ==\n'
# The extracted wait verb, driven directly against a stubbed kubectl that
# serves canned pod/job answers through the environment. The distinction
# under test is the whole reason the verb exists: a non-zero AGENT exit is
# a successful wait that prints the code to stdout, while a non-zero wait
# exit means the wait itself failed.
waitstub_dir="$(newdir)"; tmpdirs+=("$waitstub_dir")
cat > "$waitstub_dir/kubectl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$K8S_STUB_LOG"
case " $* " in
    *" get pod -l job-name="*)
        # K8S_STUB_POD_GET_RC simulates the API refusing/failing to answer
        # this lookup at all -- distinct from a successful-but-empty
        # answer (no K8S_STUB_POD_NAME), which is a determinate "no pod".
        [[ -n "${K8S_STUB_POD_GET_RC:-}" ]] && exit "$K8S_STUB_POD_GET_RC"
        if [[ -n "${K8S_STUB_POD_NAME:-}" ]]; then
            printf '%s\n' "$K8S_STUB_POD_NAME"
            exit 0
        fi
        # No matching pod. Real kubectl's exit code on a genuinely empty
        # PodList depends on the jsonpath template: {.items[0]...} is a
        # template error (array index out of bounds) that exits 1, while
        # {.items[*]...} succeeds with empty output. Mimic that split so
        # a probe-path regression to the [0] form (finding 1) fails this
        # suite instead of passing it.
        case " $* " in
            *'items[0]'*)
                echo 'error: error executing jsonpath "{.items[0].metadata.name}": Error executing template: array index out of bounds: index 0, length 0' >&2
                exit 1 ;;
        esac
        exit 0 ;;
    *" get job "*"--ignore-not-found -o name"*)
        # The probe-only Job existence check (k8s_probe_find_job):
        # K8S_STUB_JOB_GET_RC simulates the API failing this call;
        # K8S_STUB_JOB_EXISTS=1 answers "still exists", anything else
        # answers "" (kubectl's own --ignore-not-found behavior for a
        # missing Job).
        [[ -n "${K8S_STUB_JOB_GET_RC:-}" ]] && exit "$K8S_STUB_JOB_GET_RC"
        [[ "${K8S_STUB_JOB_EXISTS:-}" == 1 ]] && printf 'job.batch/stub-job\n'
        exit 0 ;;
    *" get pod "*)
        printf '%s' "${K8S_STUB_POD_PHASE:-Running}"
        exit 0 ;;
    *" get job "*)
        printf '%s' "${K8S_STUB_JOB_FAILED:-False}"
        exit 0 ;;
    *" cat /work/.run-complete "*)
        [[ -n "${K8S_STUB_RUN_COMPLETE:-}" ]] && printf '%s\n' "$K8S_STUB_RUN_COMPLETE"
        exit "${K8S_STUB_SENTINEL_RC:-1}" ;;
esac
exit 0
STUB
chmod +x "$waitstub_dir/kubectl"
waitstub_wait() {
    # $1 = kubectl log, $2 = stdout file, $3 = stderr file, rest = wait
    # args. K8S_STUB_* env vars, set by the caller, control the pod's
    # answers (sentinel value/rc, pod phase, job condition).
    local log="$1" out="$2" err="$3"; shift 3
    K8S_STUB_POD_NAME="${K8S_STUB_POD_NAME:-stub-pod}" \
    PATH="$waitstub_dir:$PATH" K8S_STUB_LOG="$log" \
    FORK_SANDBOX_CONFIG_DIR="$config_dir" \
    "$k8s_sh" wait "$@" > "$out" 2> "$err"
}
# Same as waitstub_wait, but with no default for K8S_STUB_POD_NAME -- an
# empty/unset value here really means "kubectl answered: no pod", the case
# waitstub_wait's own always-stub-pod default can never exercise.
waitstub_wait_nopod() {
    local log="$1" out="$2" err="$3"; shift 3
    PATH="$waitstub_dir:$PATH" K8S_STUB_LOG="$log" \
    FORK_SANDBOX_CONFIG_DIR="$config_dir" \
    "$k8s_sh" wait "$@" > "$out" 2> "$err"
}

# 1. Sentinel present: the agent's exit code lands on stdout, alone, and
# the wait exits 0 even though the agent itself exited non-zero.
wait_log1="$(newdir)/kubectl.log"; wait_out1="$(newdir)/out1.txt"; wait_err1="$(newdir)/err1.txt"
tmpdirs+=("$(dirname "$wait_log1")")
if K8S_STUB_RUN_COMPLETE=3 K8S_STUB_SENTINEL_RC=0 \
    waitstub_wait "$wait_log1" "$wait_out1" "$wait_err1" \
    --branch fs-k8s-test-wait-rc --timeout 5; then
    if [[ "$(cat "$wait_out1")" == "3" ]] \
        && grep -q 'agent finished (exit 3)' "$wait_err1"; then
        ok "a completed wait prints the agent exit code to stdout, alone"
    else
        no "a completed wait prints the agent exit code to stdout, alone" \
            "stdout='$(cat "$wait_out1")' stderr='$(cat "$wait_err1")'"
    fi
else
    no "a completed wait prints the agent exit code to stdout, alone" "wait exited nonzero: $(cat "$wait_err1")"
fi

# 2. A Failed pod: the wait itself fails with the TERMINAL code 2 (the
# run can never complete through this wait again -- a probe loop must
# give the seat up, not re-probe it), naming the pod.
wait_log2="$(newdir)/kubectl.log"; wait_out2="$(newdir)/out2.txt"; wait_err2="$(newdir)/err2.txt"
tmpdirs+=("$(dirname "$wait_log2")")
rc=0
K8S_STUB_POD_PHASE=Failed \
    waitstub_wait "$wait_log2" "$wait_out2" "$wait_err2" \
    --branch fs-k8s-test-wait-podfailed --timeout 5 || rc=$?
if (( rc == 2 )) && grep -q 'pod stub-pod is Failed -- it died before writing' "$wait_err2"; then
    ok "a Failed pod fails the wait with the terminal code 2"
else
    no "a Failed pod fails the wait with the terminal code 2" "rc=$rc: $(cat "$wait_err2")"
fi

# 3. A Failed job condition: the wait itself fails with the terminal
# code 2, naming the job.
wait_log3="$(newdir)/kubectl.log"; wait_out3="$(newdir)/out3.txt"; wait_err3="$(newdir)/err3.txt"
tmpdirs+=("$(dirname "$wait_log3")")
rc=0
K8S_STUB_JOB_FAILED=True \
    waitstub_wait "$wait_log3" "$wait_out3" "$wait_err3" \
    --branch fs-k8s-test-wait-jobfailed --timeout 5 --probe || rc=$?
if (( rc == 2 )) && grep -q 'reports a Failed condition' "$wait_err3"; then
    ok "a Failed job condition fails the wait with the terminal code 2"
else
    no "a Failed job condition fails the wait with the terminal code 2" "rc=$rc: $(cat "$wait_err3")"
fi

# 4. No sentinel by the deadline: the wait itself fails with code 1 --
# NOT the terminal 2, because the run may still be going and a probe
# loop must try again -- with the fetch-by-hand advice. --timeout 0
# trips on the first probe, so no 10s poll sleep.
wait_log4="$(newdir)/kubectl.log"; wait_out4="$(newdir)/out4.txt"; wait_err4="$(newdir)/err4.txt"
tmpdirs+=("$(dirname "$wait_log4")")
rc=0
waitstub_wait "$wait_log4" "$wait_out4" "$wait_err4" \
    --branch fs-k8s-test-wait-timeout --timeout 0 || rc=$?
if (( rc == 1 )) && grep -q 'timed out after 0s waiting for branch' "$wait_err4" \
    && grep -q 'Fetch by hand once it' "$wait_err4"; then
    ok "a timed-out wait fails with code 1 and the fetch-by-hand advice"
else
    no "a timed-out wait fails with code 1 and the fetch-by-hand advice" "rc=$rc: $(cat "$wait_err4")"
fi

# The poller form keeps a still-running seat quiet: only the caller knows
# that this was an expected transient result.
wait_log_probe="$(newdir)/kubectl.log"; wait_out_probe="$(newdir)/out-probe.txt"; wait_err_probe="$(newdir)/err-probe.txt"
tmpdirs+=("$(dirname "$wait_log_probe")")
rc=0
waitstub_wait "$wait_log_probe" "$wait_out_probe" "$wait_err_probe" \
    --branch fs-k8s-test-wait-probe --timeout 0 --probe || rc=$?
if (( rc == 1 )) && [[ ! -s "$wait_err_probe" ]]; then
    ok "a probe timeout exits 1 with empty stderr"
else
    no "a probe timeout exits 1 with empty stderr" "rc=$rc: $(cat "$wait_err_probe")"
fi

# 5. A malformed sentinel: the wait fails rather than guessing, with the
# terminal code 2 (the sentinel will not repair itself; no further wait
# can succeed).
wait_log5="$(newdir)/kubectl.log"; wait_out5="$(newdir)/out5.txt"; wait_err5="$(newdir)/err5.txt"
tmpdirs+=("$(dirname "$wait_log5")")
rc=0
K8S_STUB_RUN_COMPLETE='not-a-number' K8S_STUB_SENTINEL_RC=0 \
    waitstub_wait "$wait_log5" "$wait_out5" "$wait_err5" \
    --branch fs-k8s-test-wait-malformed --timeout 5 || rc=$?
if (( rc == 2 )) && grep -q 'does not hold an' "$wait_err5" \
    && grep -q "integer exit code (got: 'not-a-number')" "$wait_err5"; then
    ok "a malformed sentinel fails the wait with the terminal code 2"
else
    no "a malformed sentinel fails the wait with the terminal code 2" "rc=$rc: $(cat "$wait_err5")"
fi

# 6. A Succeeded pod: the run finished and its container has since exited
# (TTL idled out, or already fetched), so the sentinel can no longer be
# read via exec. The wait must fail fast on the first probe -- not poll to
# its own timeout on a run that can never become executable again -- and
# must NOT advise a by-hand fetch: fetch and collect both run through
# kubectl exec, which cannot reach an exited container, so the only
# by-hand steps left are the logs pointer and the rm.
wait_log6="$(newdir)/kubectl.log"; wait_out6="$(newdir)/out6.txt"; wait_err6="$(newdir)/err6.txt"
tmpdirs+=("$(dirname "$wait_log6")")
rc=0
K8S_STUB_POD_PHASE=Succeeded \
    waitstub_wait "$wait_log6" "$wait_out6" "$wait_err6" \
    --branch fs-k8s-test-wait-podsucceeded --timeout 0 || rc=$?
if (( rc == 2 )) && grep -q 'pod stub-pod is Succeeded -- the run completed and' "$wait_err6" \
    && grep -q 'unreachable through this tool' "$wait_err6" \
    && ! grep -q 'fetch --branch' "$wait_err6" \
    && ! grep -q 'timed out' "$wait_err6"; then
    ok "a Succeeded pod fails the wait with the terminal code 2, without fetch advice"
else
    no "a Succeeded pod fails the wait with the terminal code 2, without fetch advice" "rc=$rc: $(cat "$wait_err6")"
fi

# 7. --probe: the pod lookup itself cannot reach the cluster (kubectl
# fails, not just an empty answer) -- this is NOT the same as "no pod",
# and must not be read as one: exit 4, the run's state is unknown.
wait_log7="$(newdir)/kubectl.log"; wait_out7="$(newdir)/out7.txt"; wait_err7="$(newdir)/err7.txt"
tmpdirs+=("$(dirname "$wait_log7")")
rc=0
K8S_STUB_POD_GET_RC=1 \
    waitstub_wait_nopod "$wait_log7" "$wait_out7" "$wait_err7" \
    --branch fs-k8s-test-wait-probe-unreachable --timeout 5 --probe || rc=$?
if (( rc == 4 )) && grep -q 'cannot reach the cluster to probe branch' "$wait_err7"; then
    ok "--probe: an unreachable API on the pod lookup exits 4, not 2"
else
    no "--probe: an unreachable API on the pod lookup exits 4, not 2" "rc=$rc: $(cat "$wait_err7")"
fi

# 8. --probe: no pod, but the Job still exists (evicted pod, or not yet
# scheduled) -- not terminal, probe again (exit 1).
wait_log8="$(newdir)/kubectl.log"; wait_out8="$(newdir)/out8.txt"; wait_err8="$(newdir)/err8.txt"
tmpdirs+=("$(dirname "$wait_log8")")
rc=0
K8S_STUB_JOB_EXISTS=1 \
    waitstub_wait_nopod "$wait_log8" "$wait_out8" "$wait_err8" \
    --branch fs-k8s-test-wait-probe-nopod-job --timeout 5 --probe || rc=$?
if (( rc == 1 )) && [[ ! -s "$wait_err8" ]]; then
    ok "--probe: no pod but the Job still exists is not terminal (exit 1)"
else
    no "--probe: no pod but the Job still exists is not terminal (exit 1)" "rc=$rc: $(cat "$wait_err8")"
fi

# 9. --probe: no pod AND no Job -- only this combination is terminal
# (exit 2), unchanged from before finding 1.
wait_log9="$(newdir)/kubectl.log"; wait_out9="$(newdir)/out9.txt"; wait_err9="$(newdir)/err9.txt"
tmpdirs+=("$(dirname "$wait_log9")")
rc=0
waitstub_wait_nopod "$wait_log9" "$wait_out9" "$wait_err9" \
    --branch fs-k8s-test-wait-probe-nopod-nojob --timeout 5 --probe || rc=$?
if (( rc == 2 )) && grep -q 'no pod found for branch' "$wait_err9"; then
    ok "--probe: no pod and no Job is terminal (exit 2)"
else
    no "--probe: no pod and no Job is terminal (exit 2)" "rc=$rc: $(cat "$wait_err9")"
fi

# 10. --probe: the Job lookup itself cannot reach the cluster -- exit 4,
# same as the pod lookup failing.
wait_log10="$(newdir)/kubectl.log"; wait_out10="$(newdir)/out10.txt"; wait_err10="$(newdir)/err10.txt"
tmpdirs+=("$(dirname "$wait_log10")")
rc=0
K8S_STUB_JOB_GET_RC=1 \
    waitstub_wait_nopod "$wait_log10" "$wait_out10" "$wait_err10" \
    --branch fs-k8s-test-wait-probe-job-unreachable --timeout 5 --probe || rc=$?
if (( rc == 4 )) && grep -q 'cannot reach the cluster to probe branch' "$wait_err10"; then
    ok "--probe: an unreachable API on the Job lookup exits 4"
else
    no "--probe: an unreachable API on the Job lookup exits 4" "rc=$rc: $(cat "$wait_err10")"
fi

# 11. The same failing pod-get stub, WITHOUT --probe, keeps today's exit
# code: k8s_find_pod (unlike k8s_probe_find_pod) still swallows the
# kubectl failure as "no pod" -- pinned so finding 1 never touches the
# non-probe path.
wait_log11="$(newdir)/kubectl.log"; wait_out11="$(newdir)/out11.txt"; wait_err11="$(newdir)/err11.txt"
tmpdirs+=("$(dirname "$wait_log11")")
rc=0
K8S_STUB_POD_GET_RC=1 \
    waitstub_wait_nopod "$wait_log11" "$wait_out11" "$wait_err11" \
    --branch fs-k8s-test-wait-nonprobe-podfail --timeout 5 || rc=$?
if (( rc == 2 )) && grep -q 'no pod found for branch' "$wait_err11" \
    && ! grep -q -- '--request-timeout' "$wait_log11"; then
    ok "non-probe wait: a failing pod-get keeps the old exit 2, no --request-timeout added"
else
    no "non-probe wait: a failing pod-get keeps the old exit 2, no --request-timeout added" \
        "rc=$rc err=$(cat "$wait_err11") log=$(cat "$wait_log11")"
fi

# 12. --probe never sleeps past its own deadline: a still-running pod with
# --probe --timeout 5 must return (exit 1) well under the old ~10s a
# single unconditional poll-interval sleep would have cost.
wait_log12="$(newdir)/kubectl.log"; wait_out12="$(newdir)/out12.txt"; wait_err12="$(newdir)/err12.txt"
tmpdirs+=("$(dirname "$wait_log12")")
rc=0
SECONDS=0
waitstub_wait "$wait_log12" "$wait_out12" "$wait_err12" \
    --branch fs-k8s-test-wait-probe-nosleeppast --timeout 5 --probe || rc=$?
wait12_elapsed=$SECONDS
if (( rc == 1 )) && (( wait12_elapsed < 8 )); then
    ok "--probe caps its poll sleep to the remaining deadline (${wait12_elapsed}s < 8s)"
else
    no "--probe caps its poll sleep to the remaining deadline" \
        "rc=$rc elapsed=${wait12_elapsed}s: $(cat "$wait_err12")"
fi

# 13. Every kubectl call on the probe path carries --request-timeout,
# capped at 10s: the pod lookup, the sentinel exec, and the per-poll phase
# and Job-condition checks (test 12's still-running pod exercises all of
# them at least once).
wait12_rt_count="$(grep -c -- '--request-timeout=5s' "$wait_log12" || true)"
if (( wait12_rt_count >= 3 )); then
    ok "--probe: every kubectl call on the probe path carries --request-timeout"
else
    no "--probe: every kubectl call on the probe path carries --request-timeout" \
        "count=$wait12_rt_count: $(cat "$wait_log12")"
fi

printf '\n== fork-sandbox-k8s.sh collect: direct drive vs stubbed kubectl ==\n'
# The extracted collect verb, driven directly against a stubbed git+kubectl
# pair: the same outbox machinery run drives, with the pod's answers
# controlled through the environment.
collectstub_dir="$(newdir)"; tmpdirs+=("$collectstub_dir")
cat > "$collectstub_dir/git" <<'STUB'
#!/usr/bin/env bash
case " $* " in
    *" push "*) exit 0 ;;
    *" fetch "*)
        # Emulate the real fetch's refspec refs/heads/X:refs/heads/X,
        # which creates the local branch at the pod's tip even when the
        # agent committed nothing -- the first-collect case the
        # zero-harvest check must measure against the pushed base, not a
        # ref the fetch itself creates. The pod's tip is the pushed base
        # (K8S_STUB_BASE_SHA, default: this repo's HEAD), one commit past
        # it when K8S_STUB_FETCH_REF is set -- the agent "committed" --
        # or exactly K8S_STUB_CLONE_TIP when that is set -- a commit an
        # earlier collect already delivered, for the re-collect tests.
        base="${K8S_STUB_BASE_SHA:-$(git -C . rev-parse -q --verify HEAD 2>/dev/null || true)}"
        for arg in "$@"; do
            case "$arg" in
                refs/heads/*:refs/heads/*)
                    tip="$base"
                    if [[ -n "${K8S_STUB_CLONE_TIP:-}" ]]; then
                        tip="$K8S_STUB_CLONE_TIP"
                    elif [[ -n "${K8S_STUB_FETCH_REF:-}" ]]; then
                        parent="$(git -C . rev-parse -q --verify "$base" 2>/dev/null || true)"
                        if [[ -n "$parent" ]]; then
                            tip="$(GIT_AUTHOR_NAME=stub-fetch GIT_AUTHOR_EMAIL=stub-fetch@fork-sandbox.invalid \
                                GIT_COMMITTER_NAME=stub-fetch GIT_COMMITTER_EMAIL=stub-fetch@fork-sandbox.invalid \
                                git -C . commit-tree "$(git -C . hash-object -t tree /dev/null)" -p "$parent" -m "stub: fetched commit")"
                        fi
                    fi
                    [[ -n "$tip" ]] && git -C . update-ref "refs/heads/${arg#*:}" "$tip"
                    ;;
            esac
        done
        exit 0 ;;
esac
exec /usr/bin/git "$@"
STUB
cat > "$collectstub_dir/kubectl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$K8S_STUB_LOG"
case " $* " in
    *" get pod -l job-name="*)
        [[ -n "${K8S_STUB_POD_NAME:-}" ]] && printf '%s\n' "$K8S_STUB_POD_NAME"
        exit 0 ;;
    *" get pod "*)
        # The pod's spec, for the per-container log capture. Containers and
        # an initContainer, like a real claude-harness run's pod shape.
        spec="${K8S_STUB_POD_SPEC:-}"
        [[ -n "$spec" ]] || spec='{"spec":{"containers":[{"name":"agent"}],"initContainers":[{"name":"egress-gate"}]}}'
        printf '%s\n' "$spec" ;;
    *" /work/repo.git rev-parse "*)
        # The pushed base sha, read by the zero-harvest check on every
        # collect (first and re-collect alike). K8S_STUB_BASE_SHA_RC
        # simulates the bounded kubectl exec itself failing -- the base is
        # unreadable -- independently of whatever K8S_STUB_BASE_SHA holds,
        # which the fetch emulation above still uses to build its own
        # tip.
        if [[ -n "${K8S_STUB_BASE_SHA_RC:-}" ]]; then
            exit "$K8S_STUB_BASE_SHA_RC"
        fi
        printf '%s\n' "${K8S_STUB_BASE_SHA:-}"
        exit 0 ;;
    *" cat /work/review-loop.json "*)
        [[ -n "${K8S_STUB_REVIEW_LOOP_JSON:-}" ]] && printf '%s' "$K8S_STUB_REVIEW_LOOP_JSON"
        exit "${K8S_STUB_REVIEW_LOOP_RC:-0}" ;;
    *" cat /work/.run-complete "*)
        # The sentinel, when the stub pod "finished": value and rc
        # independent, like the outbox read above.
        if [[ -n "${K8S_STUB_RUN_COMPLETE:-}" ]]; then
            printf '%s\n' "$K8S_STUB_RUN_COMPLETE"
            exit "${K8S_STUB_RUN_COMPLETE_RC:-0}"
        fi
        exit 1 ;;
    *" logs "*)
        printf 'stub pod log: entrypoint narration for %s\n' "${K8S_STUB_LOGS_CONTAINER:-agent}"
        exit "${K8S_STUB_LOGS_RC:-0}" ;;
    *" tar cf - --files-from="*)
        # The transcript read: serve the pod's /work fixture whenever
        # K8S_STUB_WORK_DIR is set, same trick as the outbox read above.
        if [[ -n "${K8S_STUB_WORK_DIR:-}" ]]; then
            ( cd "$K8S_STUB_WORK_DIR" && find . -maxdepth 1 \
                \( -name "events*.jsonl" -o -name "pi-stderr.log" -o -name "claude-stderr.log" \
                   -o -name "claude-stderr-*.log" -o -name "handoff-*.md" -o -name "refresh.json" \
                   -o -name "continuation-prompt-*.md" -o -name "refresh.log" \) \
                | tar cf - --files-from=- ) || true
        fi
        [[ -n "${K8S_STUB_WORK_STDERR:-}" ]] && printf '%s' "$K8S_STUB_WORK_STDERR" >&2
        exit "${K8S_STUB_WORK_RC:-0}" ;;
    *" tar cf - -C /work/outbox "*)
        # Serve the fixture stream whenever K8S_STUB_OUTBOX_DIR is set,
        # independently of the exit status -- same trick the runstub uses
        # above.
        if [[ -n "${K8S_STUB_OUTBOX_DIR:-}" ]]; then
            ( cd "$K8S_STUB_OUTBOX_DIR" && tar cf - . ) || true
        fi
        [[ -n "${K8S_STUB_OUTBOX_STDERR:-}" ]] && printf '%s' "$K8S_STUB_OUTBOX_STDERR" >&2
        exit "${K8S_STUB_OUTBOX_RC:-1}" ;;
    *" tar cf - -C /work/session-store "*)
        # Same trick as the outbox arm above, for the session-store pull:
        # serve K8S_STUB_SESSION_DIR's contents whenever it is set,
        # independently of the exit status, so a test can pair a fixture
        # with a non-zero rc to simulate an EPIPE-under-cap read.
        # K8S_STUB_SESSION_OVERSIZE, when set, ignores K8S_STUB_SESSION_DIR
        # and streams a cheap cap+1-byte /dev/zero run instead: the
        # session-store cap (CONTEXT_MAX_BYTES) has no --outbox-max-shaped
        # override, so a stream genuinely past the 256 MiB cap is the only
        # way to drive the pull's own size check, the same SIGPIPE-shaped
        # emulation the outbox pull's own substantially-over-cap case uses.
        if [[ -n "${K8S_STUB_SESSION_OVERSIZE:-}" ]]; then
            head -c $((256 * 1024 * 1024 + 1)) /dev/zero
            exit 141
        fi
        if [[ -n "${K8S_STUB_SESSION_DIR:-}" ]]; then
            ( cd "$K8S_STUB_SESSION_DIR" && tar cf - . ) || true
        fi
        [[ -n "${K8S_STUB_SESSION_STDERR:-}" ]] && printf '%s' "$K8S_STUB_SESSION_STDERR" >&2
        exit "${K8S_STUB_SESSION_RC:-1}" ;;
    *" delete "*) exit 0 ;;
esac
exit 0
STUB
chmod +x "$collectstub_dir/git" "$collectstub_dir/kubectl"
collectstub_collect() {
    # $1 = kubectl log, $2 = output file, rest = collect args.
    # K8S_STUB_BASE_SHA defaults to this repo's HEAD: the pod's bare
    # repository always holds a pushed base, so the stub's emulated fetch
    # and the stub's base-sha read must agree on one, and the caller's
    # repo's own HEAD is the only sha both can reach.
    local log="$1" out="$2"; shift 2
    K8S_STUB_POD_NAME="${K8S_STUB_POD_NAME:-stub-pod}" \
    HOME="$k8s_test_home" PATH="$collectstub_dir:$PATH" K8S_STUB_LOG="$log" \
    K8S_STUB_BASE_SHA="${K8S_STUB_BASE_SHA:-$(git -C "$proj_dir" rev-parse HEAD)}" \
    K8S_STUB_OUTBOX_DIR="${K8S_STUB_OUTBOX_DIR:-$runstub_pod_outbox}" \
    FORK_SANDBOX_CONFIG_DIR="$config_dir" \
    "$k8s_sh" collect "$@" > "$out" 2>&1
}

# 1. A readable outbox lands at the --outbox-dir path, and the fetch still
# happens.
collect_log1="$(newdir)/kubectl.log"; collect_out1="$(newdir)/out1.txt"; collect_dest1="$(newdir)/outbox-1"
tmpdirs+=("$(dirname "$collect_log1")" "$(dirname "$collect_dest1")")
if K8S_STUB_OUTBOX_RC=0 \
    collectstub_collect "$collect_log1" "$collect_out1" \
    --branch fs-k8s-test-collect-outbox --outbox-dir "$collect_dest1" "$proj_dir"; then
    if [[ -f "$collect_dest1/hello.txt" ]] \
        && grep -q "outbox: 1 agent file(s) at $collect_dest1" "$collect_out1" \
        && grep -q 'fetched into' "$collect_out1"; then
        ok "collect lands the outbox at --outbox-dir and fetches"
    else
        no "collect lands the outbox at --outbox-dir and fetches" \
            "dest=$(find "$collect_dest1" 2>/dev/null) out=$(cat "$collect_out1")"
    fi
else
    no "collect lands the outbox at --outbox-dir and fetches" "collect exited nonzero: $(cat "$collect_out1")"
fi

# tar's `.` walk must carry the harness metadata dotfile home too.
collect_log_meta="$(newdir)/kubectl.log"; collect_out_meta="$(newdir)/out-meta.txt"; collect_dest_meta="$(newdir)/outbox-meta"
collect_meta_src="$(newdir)/pod-outbox-meta"
tmpdirs+=("$(dirname "$collect_log_meta")" "$collect_meta_src" "$(dirname "$collect_dest_meta")")
mkdir -p -- "$collect_meta_src"
printf 'discovered-model\n' > "$collect_meta_src/.fork-sandbox-model"
if K8S_STUB_OUTBOX_DIR="$collect_meta_src" K8S_STUB_OUTBOX_RC=0 \
    collectstub_collect "$collect_log_meta" "$collect_out_meta" \
    --branch fs-k8s-test-collect-dotfile --outbox-dir "$collect_dest_meta" "$proj_dir"; then
    if [[ "$(cat "$collect_dest_meta/.fork-sandbox-model" 2>/dev/null)" == discovered-model ]] \
        && grep -qF 'model: discovered-model' "$collect_out_meta" \
        && ! grep -q 'context_source' "$collect_out_meta"; then
        ok "collect brings the model metadata dotfile home and records a bare-id run without facts"
    else
        no "collect brings the model metadata dotfile home and records a bare-id run without facts" "dest=$(find "$collect_dest_meta" 2>/dev/null)"
    fi
else
    no "collect brings the model metadata dotfile home and records a bare-id run without facts" "collect exited nonzero: $(cat "$collect_out_meta")"
fi

# ...and the same dotfile carrying the context facts an entrypoint that
# ran model discovery appends: a completed run's record must say whether
# its context was reported or guessed, so the fallback's 32768/8192
# signature is readable after the pod is reaped. An unrecognized extra
# line is tolerated, not an error.
collect_log_meta2="$(newdir)/kubectl.log"; collect_out_meta2="$(newdir)/out-meta2.txt"; collect_dest_meta2="$(newdir)/outbox-meta2"
collect_meta_src2="$(newdir)/pod-outbox-meta2"
tmpdirs+=("$(dirname "$collect_log_meta2")" "$collect_meta_src2" "$(dirname "$collect_dest_meta2")")
mkdir -p -- "$collect_meta_src2"
printf 'discovered-model\ncontext=131072\nmax_tokens=32768\ncontext_source=reported\nunknown_key=x\n' \
    > "$collect_meta_src2/.fork-sandbox-model"
if K8S_STUB_OUTBOX_DIR="$collect_meta_src2" K8S_STUB_OUTBOX_RC=0 \
    collectstub_collect "$collect_log_meta2" "$collect_out_meta2" \
    --branch fs-k8s-test-collect-dotfile-facts --outbox-dir "$collect_dest_meta2" "$proj_dir"; then
    if grep -qF 'model: discovered-model (context=131072, max_tokens=32768, context_source=reported)' \
        "$collect_out_meta2" \
        && ! grep -q 'unknown_key' "$collect_out_meta2"; then
        ok "collect surfaces the context facts from a recorded model, tolerating unknown lines"
    else
        no "collect surfaces the context facts from a recorded model, tolerating unknown lines" \
            "out=$(cat "$collect_out_meta2")"
    fi
else
    no "collect surfaces the context facts from a recorded model, tolerating unknown lines" \
        "collect exited nonzero: $(cat "$collect_out_meta2")"
fi

# 2. An over-cap outbox is refused -- and only the pull-back is refused:
# the fetch must still complete and collect must still exit 0.
collect_log2="$(newdir)/kubectl.log"; collect_out2="$(newdir)/out2.txt"; collect_dest2="$(newdir)/outbox-2"
tmpdirs+=("$(dirname "$collect_log2")" "$(dirname "$collect_dest2")")
if K8S_STUB_OUTBOX_DIR="$runstub_big_outbox" K8S_STUB_OUTBOX_RC=141 \
    collectstub_collect "$collect_log2" "$collect_out2" \
    --branch fs-k8s-test-collect-overcap --outbox-max 128 --outbox-dir "$collect_dest2" "$proj_dir"; then
    if grep -q 'over the 128 byte cap; refusing to pull it back' "$collect_out2" \
        && ! grep -q 'could not read the outbox' "$collect_out2" \
        && [[ ! -d "$collect_dest2" ]] \
        && grep -q 'fetched into' "$collect_out2"; then
        ok "collect refuses an over-cap outbox without costing the fetch"
    else
        no "collect refuses an over-cap outbox without costing the fetch" \
            "dest=$(find "$collect_dest2" 2>/dev/null) out=$(cat "$collect_out2")"
    fi
else
    no "collect refuses an over-cap outbox without costing the fetch" "collect exited nonzero: $(cat "$collect_out2")"
fi

# 3. An unreadable outbox warns, falls through, and the fetch succeeds.
collect_log3="$(newdir)/kubectl.log"; collect_out3="$(newdir)/out3.txt"; collect_dest3="$(newdir)/outbox-3"
tmpdirs+=("$(dirname "$collect_log3")" "$(dirname "$collect_dest3")")
if K8S_STUB_OUTBOX_STDERR='stub-kubectl says: outbox read exploded' K8S_STUB_OUTBOX_RC=1 \
    collectstub_collect "$collect_log3" "$collect_out3" \
    --branch fs-k8s-test-collect-outbox-err --outbox-dir "$collect_dest3" "$proj_dir"; then
    if grep -q 'warning: could not read the outbox' "$collect_out3" \
        && grep -q 'stub-kubectl says: outbox read exploded' "$collect_out3" \
        && grep -q 'fetched into' "$collect_out3"; then
        ok "collect warns on an unreadable outbox and still fetches"
    else
        no "collect warns on an unreadable outbox and still fetches" "$(cat "$collect_out3")"
    fi
else
    no "collect warns on an unreadable outbox and still fetches" "collect exited nonzero: $(cat "$collect_out3")"
fi

# 4. --review-loop 1 reports an approved outcome.
collect_log4="$(newdir)/kubectl.log"; collect_out4="$(newdir)/out4.txt"; collect_dest4="$(newdir)/outbox-4"
tmpdirs+=("$(dirname "$collect_log4")" "$(dirname "$collect_dest4")")
if K8S_STUB_OUTBOX_RC=0 K8S_STUB_REVIEW_LOOP_JSON='{"ended":"approved","iterations":[{},{}]}' \
    collectstub_collect "$collect_log4" "$collect_out4" \
    --branch fs-k8s-test-collect-loop-approved --review-loop 1 \
    --outbox-dir "$collect_dest4" "$proj_dir"; then
    if grep -q 'review loop: APPROVED after 2 iteration(s)' "$collect_out4"; then
        ok "collect --review-loop 1 reports an approved outcome"
    else
        no "collect --review-loop 1 reports an approved outcome" "$(cat "$collect_out4")"
    fi
else
    no "collect --review-loop 1 reports an approved outcome" "collect exited nonzero: $(cat "$collect_out4")"
fi

# 5. --review-loop 1 reports a cap outcome, with the last iteration's
# finding count.
collect_log5="$(newdir)/kubectl.log"; collect_out5="$(newdir)/out5.txt"; collect_dest5="$(newdir)/outbox-5"
tmpdirs+=("$(dirname "$collect_log5")" "$(dirname "$collect_dest5")")
if K8S_STUB_OUTBOX_RC=0 \
    K8S_STUB_REVIEW_LOOP_JSON='{"ended":"cap","iterations":[{"findings":5},{"findings":4}]}' \
    collectstub_collect "$collect_log5" "$collect_out5" \
    --branch fs-k8s-test-collect-loop-cap --review-loop 1 \
    --outbox-dir "$collect_dest5" "$proj_dir"; then
    if grep -q "review loop ended 'cap' after" "$collect_out5" \
        && grep -q '2 iteration(s)' "$collect_out5" \
        && grep -q '4 finding(s)' "$collect_out5"; then
        ok "collect --review-loop 1 reports a cap outcome"
    else
        no "collect --review-loop 1 reports a cap outcome" "$(cat "$collect_out5")"
    fi
else
    no "collect --review-loop 1 reports a cap outcome" "collect exited nonzero: $(cat "$collect_out5")"
fi

# 6. --review-loop omitted: no review-loop.json read at all -- a loop
# outcome that was never going to be printed must not be read "just in
# case" and turned into silence.
collect_log6="$(newdir)/kubectl.log"; collect_out6="$(newdir)/out6.txt"; collect_dest6="$(newdir)/outbox-6"
tmpdirs+=("$(dirname "$collect_log6")" "$(dirname "$collect_dest6")")
if K8S_STUB_OUTBOX_RC=0 \
    collectstub_collect "$collect_log6" "$collect_out6" \
    --branch fs-k8s-test-collect-no-loop --outbox-dir "$collect_dest6" "$proj_dir"; then
    if ! grep -q 'review-loop.json' "$collect_log6"; then
        ok "collect without --review-loop reads no review-loop.json"
    else
        no "collect without --review-loop reads no review-loop.json" \
            "log=$(grep 'review-loop.json' "$collect_log6")"
    fi
else
    no "collect without --review-loop reads no review-loop.json" "collect exited nonzero: $(cat "$collect_out6")"
fi

# 7. --keep leaves the job and pod in place.
collect_log7="$(newdir)/kubectl.log"; collect_out7="$(newdir)/out7.txt"; collect_dest7="$(newdir)/outbox-7"
tmpdirs+=("$(dirname "$collect_log7")" "$(dirname "$collect_dest7")")
if K8S_STUB_OUTBOX_RC=0 \
    collectstub_collect "$collect_log7" "$collect_out7" \
    --branch fs-k8s-test-collect-keep --outbox-dir "$collect_dest7" --keep "$proj_dir"; then
    if grep -q -- '--keep set; leaving job and pod' "$collect_out7" \
        && ! grep -q 'delete job' "$collect_log7"; then
        ok "collect --keep leaves the job in place"
    else
        no "collect --keep leaves the job in place" \
            "log=$(grep 'delete' "$collect_log7") out=$(cat "$collect_out7")"
    fi
else
    no "collect --keep leaves the job in place" "collect exited nonzero: $(cat "$collect_out7")"
fi

# 8. Without --keep the job is removed.
collect_log8="$(newdir)/kubectl.log"; collect_out8="$(newdir)/out8.txt"; collect_dest8="$(newdir)/outbox-8"
tmpdirs+=("$(dirname "$collect_log8")" "$(dirname "$collect_dest8")")
if K8S_STUB_OUTBOX_RC=0 \
    collectstub_collect "$collect_log8" "$collect_out8" \
    --branch fs-k8s-test-collect-rm --outbox-dir "$collect_dest8" "$proj_dir"; then
    if grep -q 'delete job' "$collect_log8" \
        && ! grep -q -- '--keep set' "$collect_out8"; then
        ok "collect without --keep removes the job"
    else
        no "collect without --keep removes the job" \
            "log=$(grep 'delete' "$collect_log8") out=$(cat "$collect_out8")"
    fi
else
    no "collect without --keep removes the job" "collect exited nonzero: $(cat "$collect_out8")"
fi

# 9. The ordering invariant holds on the collect path too: the outbox tar
# read must appear in the kubectl log BEFORE the fetch's touch
# /work/.fetched.
collect_log9="$(newdir)/kubectl.log"; collect_out9="$(newdir)/out9.txt"; collect_dest9="$(newdir)/outbox-9"
tmpdirs+=("$(dirname "$collect_log9")" "$(dirname "$collect_dest9")")
if K8S_STUB_OUTBOX_RC=0 \
    collectstub_collect "$collect_log9" "$collect_out9" \
    --branch fs-k8s-test-collect-ordering --outbox-dir "$collect_dest9" "$proj_dir"; then
    # || true: under pipefail a grep that finds nothing would otherwise
    # take the whole suite down at the assignment rather than failing the
    # assertion below.
    tar_ln="$(grep -n 'tar cf - -C /work/outbox' "$collect_log9" | head -n 1 | cut -d: -f1 || true)"
    fetched_ln="$(grep -n 'touch /work/.fetched' "$collect_log9" | head -n 1 | cut -d: -f1 || true)"
    if [[ -n "$tar_ln" && -n "$fetched_ln" ]] && (( tar_ln < fetched_ln )); then
        ok "collect pulls the outbox back before the fetch touches /work/.fetched"
    else
        no "collect pulls the outbox back before the fetch touches /work/.fetched" \
            "tar_ln=$tar_ln fetched_ln=$fetched_ln out=$(cat "$collect_out9")"
    fi
else
    no "collect pulls the outbox back before the fetch touches /work/.fetched" "collect exited nonzero: $(cat "$collect_out9")"
fi

# 10. The agent's transcript and the per-container pod logs land in an
# `evidence` directory SIBLING of the outbox (never inside it), each
# review leg distinguishable from the coding leg, and the transcript pull
# sits BEFORE the fetch's touch /work/.fetched, carrying the same
# request-timeout bound as the outbox read.
collect_work10="$(newdir)/pod-work-10"; tmpdirs+=("$collect_work10")
mkdir -p -- "$collect_work10"
printf '{"type":"assistant","text":"the coding leg did the work"}\n' > "$collect_work10/events.jsonl"
printf '{"type":"assistant","text":"the review leg verdict"}\n' > "$collect_work10/events-review-1.jsonl"
printf 'connection to the proxy refused once\n' > "$collect_work10/pi-stderr.log"
printf 'not evidence: agent workspace file\n' > "$collect_work10/notes.md"
collect_log10="$(newdir)/kubectl.log"; collect_out10="$(newdir)/out10.txt"; collect_dest10="$(newdir)/outbox-10"
tmpdirs+=("$(dirname "$collect_log10")" "$(dirname "$collect_dest10")")
if K8S_STUB_WORK_DIR="$collect_work10" K8S_STUB_OUTBOX_RC=0 \
    collectstub_collect "$collect_log10" "$collect_out10" \
    --branch fs-k8s-test-collect-evidence --outbox-dir "$collect_dest10" "$proj_dir"; then
    evidence10="$(dirname -- "$collect_dest10")/evidence"
    trans_ln="$(grep -n 'tar cf - --files-from=' "$collect_log10" | head -n 1 | cut -d: -f1 || true)"
    fetched_ln="$(grep -n 'touch /work/.fetched' "$collect_log10" | head -n 1 | cut -d: -f1 || true)"
    # The pod-spec read is the one kubectl GET in the evidence block: it
    # must carry the same request-timeout bound as the execs, or a hung
    # get can hang the collect the way the rest of the block exists to
    # prevent.
    spec_ln="$(grep -n 'get pod stub-pod -o json' "$collect_log10" | head -n 1 | cut -d: -f1 || true)"
    if [[ -n "$trans_ln" && -n "$fetched_ln" ]] && (( trans_ln < fetched_ln )) \
        && grep -q -- '--request-timeout=60s' <(sed -n "${trans_ln}p" "$collect_log10") \
        && [[ -n "$spec_ln" ]] \
        && grep -q -- '--request-timeout=60s' <(sed -n "${spec_ln}p" "$collect_log10") \
        && [[ -f "$evidence10/events.jsonl" && -f "$evidence10/events-review-1.jsonl" && -f "$evidence10/pi-stderr.log" ]] \
        && [[ ! -e "$evidence10/notes.md" ]] \
        && [[ -f "$evidence10/pod-log-agent.log" && -f "$evidence10/pod-log-egress-gate.log" ]] \
        && [[ ! -e "$collect_dest10/events.jsonl" ]] \
        && [[ "$(find "$collect_dest10" -type f | wc -l)" == 1 ]]; then
        ok "the transcript and per-container pod logs land in the evidence sibling, before the fetch"
    else
        no "the transcript and per-container pod logs land in the evidence sibling, before the fetch" \
            "trans_ln=$trans_ln fetched_ln=$fetched_ln evidence=$(find "$evidence10" 2>/dev/null) outbox=$(find "$collect_dest10" 2>/dev/null) out=$(cat "$collect_out10")"
    fi
else
    no "the transcript and per-container pod logs land in the evidence sibling, before the fetch" "collect exited nonzero: $(cat "$collect_out10")"
fi

# 11. THE dead-run case: the agent's sentinel holds 0, the fetch lands no
# commits, and the outbox holds nothing but .fork-sandbox-model -- exactly
# the run today's every-file count read as a success ("outbox: 1 file(s)").
# collect must call it suspicious, exit 3, keep the job, and the agent's
# own transcript must be in the fetched artifacts.
collect_work11="$(newdir)/pod-work-11"; tmpdirs+=("$collect_work11")
mkdir -p -- "$collect_work11"
printf '{"type":"assistant","text":"...nothing"}\n' > "$collect_work11/events.jsonl"
collect_outbox11="$(newdir)/pod-outbox-11"; tmpdirs+=("$collect_outbox11")
mkdir -p -- "$collect_outbox11"
printf 'discovered-model\n' > "$collect_outbox11/.fork-sandbox-model"
collect_log11="$(newdir)/kubectl.log"; collect_out11="$(newdir)/out11.txt"; collect_dest11="$(newdir)/outbox-11"
tmpdirs+=("$(dirname "$collect_log11")" "$(dirname "$collect_dest11")")
rc=0
K8S_STUB_RUN_COMPLETE=0 K8S_STUB_WORK_DIR="$collect_work11" \
K8S_STUB_OUTBOX_DIR="$collect_outbox11" K8S_STUB_OUTBOX_RC=0 \
    collectstub_collect "$collect_log11" "$collect_out11" \
    --branch fs-k8s-test-collect-dead --outbox-dir "$collect_dest11" "$proj_dir" || rc=$?
if (( rc == 3 )) \
    && grep -q 'SUSPICIOUS: this run produced nothing' "$collect_out11" \
    && ! grep -q 'delete job' "$collect_log11" \
    && grep -qF -- "fork-sandbox-k8s.sh rm --branch fs-k8s-test-collect-dead" "$collect_out11" \
    && [[ -f "$(dirname -- "$collect_dest11")/evidence/events.jsonl" ]]; then
    ok "a dead run (exit 0, zero commits, dotfile-only outbox) is suspicious: exit 3, job kept, transcript fetched"
else
    no "a dead run (exit 0, zero commits, dotfile-only outbox) is suspicious: exit 3, job kept, transcript fetched" \
        "rc=$rc log=$(grep delete "$collect_log11") out=$(cat "$collect_out11")"
fi

# 12. Zero commits with a NON-EMPTY outbox is a success -- a review panel
# seat commits nothing and writes its verdict to the outbox. Never flagged.
collect_outbox12="$(newdir)/pod-outbox-12"; tmpdirs+=("$collect_outbox12")
mkdir -p -- "$collect_outbox12"
printf '# verdict\napproved\n' > "$collect_outbox12/verdict.md"
collect_log12="$(newdir)/kubectl.log"; collect_out12="$(newdir)/out12.txt"; collect_dest12="$(newdir)/outbox-12"
tmpdirs+=("$(dirname "$collect_log12")" "$(dirname "$collect_dest12")")
if K8S_STUB_RUN_COMPLETE=0 K8S_STUB_OUTBOX_DIR="$collect_outbox12" K8S_STUB_OUTBOX_RC=0 \
    collectstub_collect "$collect_log12" "$collect_out12" \
    --branch fs-k8s-test-collect-verdict --outbox-dir "$collect_dest12" "$proj_dir"; then
    if grep -q "outbox: 1 agent file(s) at $collect_dest12" "$collect_out12" \
        && ! grep -q 'SUSPICIOUS' "$collect_out12" \
        && grep -q 'delete job' "$collect_log12"; then
        ok "zero commits with a non-empty outbox is a success, not suspicious"
    else
        no "zero commits with a non-empty outbox is a success, not suspicious" \
            "out=$(cat "$collect_out12")"
    fi
else
    no "zero commits with a non-empty outbox is a success, not suspicious" "collect exited nonzero: $(cat "$collect_out12")"
fi

# 13. The agent wrote nothing to the outbox but its commits came back --
# the stub fetch advances the branch ref, so the before/after compare sees
# new work. Not flagged, despite the dotfile-only outbox.
collect_log13="$(newdir)/kubectl.log"; collect_out13="$(newdir)/out13.txt"; collect_dest13="$(newdir)/outbox-13"
tmpdirs+=("$(dirname "$collect_log13")" "$(dirname "$collect_dest13")")
if K8S_STUB_RUN_COMPLETE=0 K8S_STUB_FETCH_REF=fs-k8s-test-collect-commits \
    K8S_STUB_OUTBOX_DIR="$collect_outbox11" K8S_STUB_OUTBOX_RC=0 \
    collectstub_collect "$collect_log13" "$collect_out13" \
    --branch fs-k8s-test-collect-commits --outbox-dir "$collect_dest13" "$proj_dir"; then
    if ! grep -q 'SUSPICIOUS' "$collect_out13" \
        && grep -q 'delete job' "$collect_log13" \
        && git -C "$proj_dir" rev-parse -q --verify refs/heads/fs-k8s-test-collect-commits >/dev/null 2>&1; then
        ok "a dotfile-only outbox with commits brought back is not suspicious"
    else
        no "a dotfile-only outbox with commits brought back is not suspicious" \
            "out=$(cat "$collect_out13")"
    fi
else
    no "a dotfile-only outbox with commits brought back is not suspicious" "collect exited nonzero: $(cat "$collect_out13")"
fi

# 14. A non-zero agent exit with zero commits and an empty outbox is not
# the suspicious conjunction either -- the agent's own failure already
# reports loudly, and this check must not re-flag it.
collect_log14="$(newdir)/kubectl.log"; collect_out14="$(newdir)/out14.txt"; collect_dest14="$(newdir)/outbox-14"
tmpdirs+=("$(dirname "$collect_log14")" "$(dirname "$collect_dest14")")
if K8S_STUB_RUN_COMPLETE=3 K8S_STUB_OUTBOX_DIR="$collect_outbox11" K8S_STUB_OUTBOX_RC=0 \
    collectstub_collect "$collect_log14" "$collect_out14" \
    --branch fs-k8s-test-collect-agentfail --outbox-dir "$collect_dest14" "$proj_dir"; then
    if ! grep -q 'SUSPICIOUS' "$collect_out14" \
        && grep -q 'delete job' "$collect_log14"; then
        ok "a non-zero agent exit is never flagged suspicious"
    else
        no "a non-zero agent exit is never flagged suspicious" "out=$(cat "$collect_out14")"
    fi
else
    no "a non-zero agent exit is never flagged suspicious" "collect exited nonzero: $(cat "$collect_out14")"
fi

# 15. A failed transcript read does not cost the fetch, but the run is NOT
# reaped: a loud block, the manual rm command, and no delete in the log.
collect_log15="$(newdir)/kubectl.log"; collect_out15="$(newdir)/out15.txt"; collect_dest15="$(newdir)/outbox-15"
tmpdirs+=("$(dirname "$collect_log15")" "$(dirname "$collect_dest15")")
if K8S_STUB_WORK_RC=1 K8S_STUB_WORK_STDERR='stub-kubectl says: transcript read exploded' K8S_STUB_OUTBOX_RC=0 \
    collectstub_collect "$collect_log15" "$collect_out15" \
    --branch fs-k8s-test-collect-nocapture --outbox-dir "$collect_dest15" "$proj_dir"; then
    if grep -q 'could not read the transcript from pod' "$collect_out15" \
        && grep -q 'stub-kubectl says: transcript read exploded' "$collect_out15" \
        && grep -q 'LEFT IN PLACE rather than' "$collect_out15" \
        && grep -qF -- "fork-sandbox-k8s.sh rm --branch fs-k8s-test-collect-nocapture" "$collect_out15" \
        && grep -q 'fetched into' "$collect_out15" \
        && ! grep -q 'delete job' "$collect_log15"; then
        ok "a failed evidence capture leaves the run in place with the manual rm command"
    else
        no "a failed evidence capture leaves the run in place with the manual rm command" \
            "log=$(grep delete "$collect_log15") out=$(cat "$collect_out15")"
    fi
else
    no "a failed evidence capture leaves the run in place with the manual rm command" "collect exited nonzero: $(cat "$collect_out15")"
fi

# 16. --keep keeps working unchanged even when the capture failed: the old
# message, no scary block.
collect_log16="$(newdir)/kubectl.log"; collect_out16="$(newdir)/out16.txt"; collect_dest16="$(newdir)/outbox-16"
tmpdirs+=("$(dirname "$collect_log16")" "$(dirname "$collect_dest16")")
if K8S_STUB_WORK_RC=1 K8S_STUB_OUTBOX_RC=0 \
    collectstub_collect "$collect_log16" "$collect_out16" \
    --branch fs-k8s-test-collect-keep-nocapture --outbox-dir "$collect_dest16" --keep "$proj_dir"; then
    if grep -q -- '--keep set; leaving job and pod' "$collect_out16" \
        && ! grep -q 'LEFT IN PLACE' "$collect_out16" \
        && ! grep -q 'delete job' "$collect_log16"; then
        ok "--keep is unchanged when the evidence capture failed"
    else
        no "--keep is unchanged when the evidence capture failed" "out=$(cat "$collect_out16")"
    fi
else
    no "--keep is unchanged when the evidence capture failed" "collect exited nonzero: $(cat "$collect_out16")"
fi

# 17. --keep does not soften the zero-harvest verdict: the flag controls
# the reap, and a dead run is still reported and still exits 3 under it.
collect_log17="$(newdir)/kubectl.log"; collect_out17="$(newdir)/out17.txt"; collect_dest17="$(newdir)/outbox-17"
tmpdirs+=("$(dirname "$collect_log17")" "$(dirname "$collect_dest17")")
rc=0
K8S_STUB_RUN_COMPLETE=0 K8S_STUB_OUTBOX_DIR="$collect_outbox11" K8S_STUB_OUTBOX_RC=0 \
    collectstub_collect "$collect_log17" "$collect_out17" \
    --branch fs-k8s-test-collect-keep-dead --outbox-dir "$collect_dest17" --keep "$proj_dir" || rc=$?
if (( rc == 3 )) \
    && grep -q 'SUSPICIOUS: this run produced nothing' "$collect_out17" \
    && ! grep -q 'delete job' "$collect_log17"; then
    ok "a dead run under --keep is still flagged and still exits 3"
else
    no "a dead run under --keep is still flagged and still exits 3" \
        "rc=$rc log=$(grep delete "$collect_log17") out=$(cat "$collect_out17")"
fi

# 18. A pod spec that is not readable JSON: the per-container log capture
# fails exactly like every other failure in its block -- it warns, and the
# run is not reaped. A silent abandon here (the pre-fix behavior) would
# leave a run reaped with no record of what it did at all.
collect_log18="$(newdir)/kubectl.log"; collect_out18="$(newdir)/out18.txt"; collect_dest18="$(newdir)/outbox-18"
tmpdirs+=("$(dirname "$collect_log18")" "$(dirname "$collect_dest18")")
if K8S_STUB_POD_SPEC='stub-pod (not the JSON the capture assumes)' K8S_STUB_OUTBOX_RC=0 \
    collectstub_collect "$collect_log18" "$collect_out18" \
    --branch fs-k8s-test-collect-badspec --outbox-dir "$collect_dest18" "$proj_dir"; then
    if grep -q 'could not read the container names' "$collect_out18" \
        && grep -q 'LEFT IN PLACE rather than' "$collect_out18" \
        && grep -qF -- "fork-sandbox-k8s.sh rm --branch fs-k8s-test-collect-badspec" "$collect_out18" \
        && grep -q 'fetched into' "$collect_out18" \
        && ! grep -q 'delete job' "$collect_log18" \
        && [[ ! -e "$(dirname -- "$collect_dest18")/evidence/pod-log-agent.log" ]]; then
        ok "an unreadable pod spec warns and leaves the run in place"
    else
        no "an unreadable pod spec warns and leaves the run in place" \
            "log=$(grep delete "$collect_log18") out=$(cat "$collect_out18")"
    fi
else
    no "an unreadable pod spec warns and leaves the run in place" "collect exited nonzero: $(cat "$collect_out18")"
fi

# 19. An outbox the extraction guard REFUSES is undecidable, not a
# zero-harvest: a symlink entry (a natural habit for an agent that
# symlinks a report into the outbox) makes the guard refuse the whole
# archive, so the agent-file count never sees the file the agent did
# write. With the sentinel at 0 and the fetch landing no commits, the
# refusal must not read as "the outbox holds no file the agent wrote".
collect_outbox19="$(newdir)/pod-outbox-19"; tmpdirs+=("$collect_outbox19")
mkdir -p -- "$collect_outbox19"
printf '# report\nthe work is here\n' > "$collect_outbox19/report.md"
ln -s report.md "$collect_outbox19/link.md"
collect_log19="$(newdir)/kubectl.log"; collect_out19="$(newdir)/out19.txt"; collect_dest19="$(newdir)/outbox-19"
tmpdirs+=("$(dirname "$collect_log19")" "$(dirname "$collect_dest19")")
rc=0
K8S_STUB_RUN_COMPLETE=0 K8S_STUB_OUTBOX_DIR="$collect_outbox19" K8S_STUB_OUTBOX_RC=0 \
    collectstub_collect "$collect_log19" "$collect_out19" \
    --branch fs-k8s-test-collect-outbox-refused --outbox-dir "$collect_dest19" "$proj_dir" || rc=$?
if (( rc == 0 )) \
    && grep -q 'warning: could not extract the outbox tarball' "$collect_out19" \
    && grep -q 'refusing the whole archive' "$collect_out19" \
    && ! grep -q 'SUSPICIOUS' "$collect_out19" \
    && grep -q 'delete job' "$collect_log19"; then
    ok "a guard-refused outbox is undecidable, not a zero-harvest"
else
    no "a guard-refused outbox is undecidable, not a zero-harvest" \
        "rc=$rc log=$(grep delete "$collect_log19") out=$(cat "$collect_out19")"
fi

# 20. A re-collect of a branch whose commits an EARLIER collect already
# delivered: the local ref pre-exists at the advanced sha, the fetch
# lands no new commits (before == after), the sentinel is 0 and the
# outbox holds only the operator dotfile. The ref's before/after compare
# reads "no new work" -- but the run plainly produced its commits, and
# the caller's repo already holds them. Not flagged; the pushed-base
# measure (branch tip advanced off it) is what keeps this honest.
collect_refetch_tip="$(GIT_AUTHOR_NAME=stub-delivered GIT_AUTHOR_EMAIL=stub-delivered@fork-sandbox.invalid \
    GIT_COMMITTER_NAME=stub-delivered GIT_COMMITTER_EMAIL=stub-delivered@fork-sandbox.invalid \
    git -C "$proj_dir" commit-tree "$(git -C "$proj_dir" hash-object -t tree /dev/null)" \
        -p "$(git -C "$proj_dir" rev-parse HEAD)" -m 'stub: previously delivered')"
git -C "$proj_dir" update-ref refs/heads/fs-k8s-test-collect-refetch-delivered "$collect_refetch_tip"
collect_log20="$(newdir)/kubectl.log"; collect_out20="$(newdir)/out20.txt"; collect_dest20="$(newdir)/outbox-20"
tmpdirs+=("$(dirname "$collect_log20")" "$(dirname "$collect_dest20")")
if K8S_STUB_RUN_COMPLETE=0 K8S_STUB_CLONE_TIP="$collect_refetch_tip" \
    K8S_STUB_OUTBOX_DIR="$collect_outbox11" K8S_STUB_OUTBOX_RC=0 \
    collectstub_collect "$collect_log20" "$collect_out20" \
    --branch fs-k8s-test-collect-refetch-delivered --outbox-dir "$collect_dest20" "$proj_dir"; then
    if ! grep -q 'SUSPICIOUS' "$collect_out20" \
        && grep -q 'delete job' "$collect_log20" \
        && [[ "$(git -C "$proj_dir" rev-parse -q --verify refs/heads/fs-k8s-test-collect-refetch-delivered)" == "$collect_refetch_tip" ]] \
        && grep -q 'outbox: empty of agent files' "$collect_out20"; then
        ok "a re-collect of an already-delivered branch is not a zero-harvest"
    else
        no "a re-collect of an already-delivered branch is not a zero-harvest" \
            "ref=$(git -C "$proj_dir" rev-parse -q --verify refs/heads/fs-k8s-test-collect-refetch-delivered) out=$(cat "$collect_out20")"
    fi
else
    no "a re-collect of an already-delivered branch is not a zero-harvest" "collect exited nonzero: $(cat "$collect_out20")"
fi

# 21. The same re-collect shape, but for a run that produced NOTHING: the
# local ref pre-exists at the pushed base (the crash window between the
# fetch's ref update and its touch of /work/.fetched), the fetch lands
# nothing, the sentinel is 0 and the outbox holds only the dotfile. The
# pushed base still says the branch never moved -- flagged, exit 3.
collect_refetch_dead_branch=fs-k8s-test-collect-refetch-dead
git -C "$proj_dir" update-ref "refs/heads/$collect_refetch_dead_branch" "$(git -C "$proj_dir" rev-parse HEAD)"
collect_log21="$(newdir)/kubectl.log"; collect_out21="$(newdir)/out21.txt"; collect_dest21="$(newdir)/outbox-21"
tmpdirs+=("$(dirname "$collect_log21")" "$(dirname "$collect_dest21")")
rc=0
K8S_STUB_RUN_COMPLETE=0 K8S_STUB_OUTBOX_DIR="$collect_outbox11" K8S_STUB_OUTBOX_RC=0 \
    collectstub_collect "$collect_log21" "$collect_out21" \
    --branch "$collect_refetch_dead_branch" --outbox-dir "$collect_dest21" "$proj_dir" || rc=$?
if (( rc == 3 )) \
    && grep -q 'SUSPICIOUS: this run produced nothing' "$collect_out21" \
    && ! grep -q 'delete job' "$collect_log21" \
    && grep -qF -- "fork-sandbox-k8s.sh rm --branch $collect_refetch_dead_branch" "$collect_out21"; then
    ok "a re-collect of a dead run (local ref at the base) is still a zero-harvest"
else
    no "a re-collect of a dead run (local ref at the base) is still a zero-harvest" \
        "rc=$rc log=$(grep delete "$collect_log21") out=$(cat "$collect_out21")"
fi

# 22. A re-collect whose pushed base is unreadable (a bounded kubectl exec
# failure), but whose fetch still lands a new commit past the local ref's
# pre-existing tip: the zero-harvest check is decided by the before/after
# compare alone (not a zero-harvest -- the run produced work), but the
# exact commit COUNT written to summary.json cannot be: there is no base
# to rev-list against. commits must be null (not measured), never 0 --
# 0 would tell a reader this run produced no commits, when it produced
# some unknown positive number of them.
collect_undecidable_branch=fs-k8s-test-collect-commits-undecidable
git -C "$proj_dir" update-ref "refs/heads/$collect_undecidable_branch" "$(git -C "$proj_dir" rev-parse HEAD)"
collect_undecidable_rd="$(mktemp -d /var/tmp/claude-scratch/forks/claude-fork-sandbox.XXXXXX)"; tmpdirs+=("$collect_undecidable_rd")
{
    printf 'mode=run\n'
    printf 'harness=pi\n'
    printf 'model=moonshotai/kimi-k3\n'
} > "$collect_undecidable_rd/run.env"
# This run dir is built by hand, not via cmd_submit, so it never picked up
# the FORK_SANDBOX_RUN_SOURCE=test tag submit writes to run-source (see the
# sweep-ownership section above). The collect below records through the
# fixture's isolated HOME; add the marker so the row still proves the suite's
# source=test provenance invariant.
printf 'test\n' > "$collect_undecidable_rd/run-source"
collect_log22="$(newdir)/kubectl.log"; collect_out22="$(newdir)/out22.txt"; collect_dest22="$(newdir)/outbox-22"
tmpdirs+=("$(dirname "$collect_log22")" "$(dirname "$collect_dest22")")
if K8S_STUB_RUN_COMPLETE=0 K8S_STUB_BASE_SHA_RC=1 K8S_STUB_FETCH_REF="$collect_undecidable_branch" \
    K8S_STUB_OUTBOX_DIR="$collect_outbox11" K8S_STUB_OUTBOX_RC=0 \
    collectstub_collect "$collect_log22" "$collect_out22" \
    --branch "$collect_undecidable_branch" --outbox-dir "$collect_dest22" \
    --run-dir "$collect_undecidable_rd" "$proj_dir"; then
    if ! grep -q 'SUSPICIOUS' "$collect_out22" \
        && [[ -f "$collect_undecidable_rd/summary.json" ]] \
        && [[ "$(jq -r '.base_sha' "$collect_undecidable_rd/summary.json")" == null ]] \
        && [[ "$(jq -r '.commits' "$collect_undecidable_rd/summary.json")" == null ]]; then
        ok "an unreadable base with new commits fetched writes commits: null, not 0"
    else
        no "an unreadable base with new commits fetched writes commits: null, not 0" \
            "summary=$(cat "$collect_undecidable_rd/summary.json" 2>/dev/null; echo NOFILE) out=$(cat "$collect_out22")"
    fi
else
    no "an unreadable base with new commits fetched writes commits: null, not 0" \
        "collect exited nonzero: $(cat "$collect_out22")"
fi

# Refresh records in summary.json. Three shapes, each on a hand-built run
# dir: disabled (no refresh_threshold_tokens in run.env) -> "none" and [];
# enabled with the pod's refresh.json pulled -> its ended and continuations
# (no cost or usage inside an entry); enabled with no usable refresh.json
# (missing, or garbage) -> both keys ABSENT and a warning.
refresh_sum_branch=fs-k8s-test-collect-refresh-summary
git -C "$proj_dir" update-ref "refs/heads/$refresh_sum_branch" "$(git -C "$proj_dir" rev-parse HEAD)"
refresh_sum_case() {
    # refresh_sum_case <tag> <threshold-or-empty> <work-dir> [outbox-dir]; sets
    # refresh_sum_rd and refresh_sum_out, returns collect's status.
    local tag="$1" tokens="$2" work="$3"
    refresh_sum_rd="$(mktemp -d /var/tmp/claude-scratch/forks/claude-fork-sandbox.XXXXXX)"; tmpdirs+=("$refresh_sum_rd")
    {
        printf 'mode=run\n'
        printf 'harness=claude\n'
        printf 'model=some-model\n'
        [[ -z "$tokens" ]] || printf 'refresh_threshold_tokens=%s\n' "$tokens"
    } > "$refresh_sum_rd/run.env"
    printf 'test\n' > "$refresh_sum_rd/run-source"
    local klog
    klog="$(newdir)/kubectl.log"; refresh_sum_out="$(newdir)/out-$tag.txt"; refresh_sum_dest="${4:-$(newdir)/outbox-$tag}"
    tmpdirs+=("$(dirname "$klog")" "$(dirname "$refresh_sum_dest")")
    K8S_STUB_WORK_DIR="$work" K8S_STUB_RUN_COMPLETE=0 K8S_STUB_FETCH_REF="$refresh_sum_branch" \
        K8S_STUB_OUTBOX_DIR="$refresh_sum_outbox" K8S_STUB_OUTBOX_RC=0 \
        collectstub_collect "$klog" "$refresh_sum_out" \
        --branch "$refresh_sum_branch" --outbox-dir "$refresh_sum_dest" \
        --run-dir "$refresh_sum_rd" "$proj_dir"
}
refresh_sum_work="$(newdir)/pod-work-rs"; tmpdirs+=("$refresh_sum_work")
mkdir -p -- "$refresh_sum_work"
# An outbox with an agent-written file, so collect does not call the run
# a zero-harvest and exit 3.
refresh_sum_outbox="$(newdir)/outbox-rs"; tmpdirs+=("$refresh_sum_outbox")
mkdir -p -- "$refresh_sum_outbox"
printf 'reply\n' > "$refresh_sum_outbox/reply.md"
printf '{"type":"result"}\n' > "$refresh_sum_work/events.jsonl"
printf '{"type":"result"}\n' > "$refresh_sum_work/events-continuation-1.jsonl"
printf 'handoff one\n' > "$refresh_sum_work/handoff-1.md"
printf 'prompt one\n' > "$refresh_sum_work/continuation-prompt-1.md"
printf 'stderr one\n' > "$refresh_sum_work/claude-stderr-continuation-1.log"
printf 'notes\n' > "$refresh_sum_work/refresh.log"
printf 'not evidence\n' > "$refresh_sum_work/notes.md"

# disabled
if refresh_sum_case dis "" "$refresh_sum_work" \
    && [[ "$(jq -c '[.refresh, .continuations]' "$refresh_sum_rd/summary.json")" == '["none",[]]' ]]; then
    ok "collect: a run without refresh writes refresh none and continuations []"
else
    no "collect: a run without refresh writes refresh none and continuations []" \
        "summary=$(cat "$refresh_sum_rd/summary.json" 2>/dev/null; echo NOFILE) out=$(cat "$refresh_sum_out")"
fi

# enabled, refresh.json pulled
printf '%s\n' '{"ended":"cap","continuations":[{"leg":2,"exit":0,"handoff":"/work/handoff-1.md","handoff_stale":false,"cost_usd":9}]}' \
    > "$refresh_sum_work/refresh.json"
if refresh_sum_case en 100000 "$refresh_sum_work" \
    && [[ "$(jq -r '.refresh' "$refresh_sum_rd/summary.json")" == cap ]] \
    && [[ "$(jq -r '.continuations | length' "$refresh_sum_rd/summary.json")" == 1 ]] \
    && [[ "$(jq -r '.continuations[0].leg' "$refresh_sum_rd/summary.json")" == 2 ]] \
    && [[ "$(jq -r '.continuations[0].handoff' "$refresh_sum_rd/summary.json")" == /work/handoff-1.md ]] \
    && [[ "$(jq -r '.continuations[0] | has("cost_usd")' "$refresh_sum_rd/summary.json")" == false ]] \
    && ! grep -q 'no usable refresh.json' "$refresh_sum_out" \
    && refresh_sum_ev="$(dirname -- "$refresh_sum_dest")/evidence" \
    && [[ -f "$refresh_sum_ev/handoff-1.md" && -f "$refresh_sum_ev/continuation-prompt-1.md" ]] \
    && [[ -f "$refresh_sum_ev/claude-stderr-continuation-1.log" && -f "$refresh_sum_ev/refresh.json" ]] \
    && [[ -f "$refresh_sum_ev/events-continuation-1.jsonl" && ! -e "$refresh_sum_ev/notes.md" ]]; then
    ok "collect: an enabled run copies ended and continuations from the pulled refresh.json"
else
    no "collect: an enabled run copies ended and continuations from the pulled refresh.json" \
        "summary=$(cat "$refresh_sum_rd/summary.json" 2>/dev/null; echo NOFILE) out=$(cat "$refresh_sum_out")"
fi

# enabled, refresh.json garbage, then missing
printf 'not json{\n' > "$refresh_sum_work/refresh.json"
if refresh_sum_case bad 100000 "$refresh_sum_work" \
    && [[ "$(jq -r 'has("refresh") or has("continuations")' "$refresh_sum_rd/summary.json")" == false ]] \
    && grep -q 'no usable refresh.json' "$refresh_sum_out"; then
    ok "collect: an unparseable refresh.json leaves both keys absent and warns"
else
    no "collect: an unparseable refresh.json leaves both keys absent and warns" \
        "summary=$(cat "$refresh_sum_rd/summary.json" 2>/dev/null; echo NOFILE) out=$(cat "$refresh_sum_out")"
fi
rm -f -- "$refresh_sum_work/refresh.json"
if refresh_sum_case gone 100000 "$refresh_sum_work" \
    && [[ "$(jq -r 'has("refresh") or has("continuations")' "$refresh_sum_rd/summary.json")" == false ]] \
    && grep -q 'no usable refresh.json' "$refresh_sum_out"; then
    ok "collect: a missing refresh.json leaves both keys absent and warns"
else
    no "collect: a missing refresh.json leaves both keys absent and warns" \
        "summary=$(cat "$refresh_sum_rd/summary.json" 2>/dev/null; echo NOFILE) out=$(cat "$refresh_sum_out")"
fi
# A refresh.json left by an EARLIER collect into the same outbox-dir must not
# stand in for this pod's: this pod has none, so both keys stay absent.
printf '%s\n' '{"ended":"cap","continuations":[]}' > "$refresh_sum_work/refresh.json"
refresh_sum_reuse="$(newdir)/outbox-reuse"; tmpdirs+=("$(dirname "$refresh_sum_reuse")")
refresh_sum_case reuse1 100000 "$refresh_sum_work" "$refresh_sum_reuse" || true
rm -f -- "$refresh_sum_work/refresh.json"
if [[ "$(jq -r '.refresh' "$refresh_sum_rd/summary.json")" == cap ]] \
    && refresh_sum_case reuse2 100000 "$refresh_sum_work" "$refresh_sum_reuse" \
    && [[ "$(jq -r 'has("refresh") or has("continuations")' "$refresh_sum_rd/summary.json")" == false ]] \
    && grep -q 'no usable refresh.json' "$refresh_sum_out"; then
    ok "collect: a refresh.json from an earlier collect is not reused when this pod has none"
else
    no "collect: a refresh.json from an earlier collect is not reused when this pod has none" \
        "summary=$(cat "$refresh_sum_rd/summary.json" 2>/dev/null; echo NOFILE) out=$(cat "$refresh_sum_out")"
fi

printf '\n== fetch-back sets the branch upstream (k8s path) ==\n'
# The same rule fork-sandbox.sh's own local runner applies on the k8s path
# (see tests/fork-sandbox-upstream-test.sh for fs_resolve_upstream/
# fs_apply_upstream themselves): submit resolves the upstream once, before
# the run starts, because HEAD in the origin repo can move while the pod
# runs; records it in run.env; collect reads it back and hands it to
# cmd_fetch's own --upstream/--upstream-none; and a standalone fetch, with
# neither flag, resolves it itself at fetch time instead.
# git branch --set-upstream-to needs a REAL configured remote, not just a
# hand-crafted refs/remotes/... ref -- so this builds a genuine bare
# "remote", seeds it with a dev branch, and clones from it: the clone
# checks out dev tracking origin/dev automatically, since dev is the bare
# repo's own HEAD.
upstream_remote_dir="$(newdir)"; tmpdirs+=("$upstream_remote_dir")
git init -q --bare "$upstream_remote_dir"
upstream_seed_dir="$(newdir)"; tmpdirs+=("$upstream_seed_dir")
git -C "$upstream_seed_dir" init -q
git -C "$upstream_seed_dir" config user.email t@fork-sandbox.invalid
git -C "$upstream_seed_dir" config user.name Tester
git -C "$upstream_seed_dir" commit -q --allow-empty -m init
git -C "$upstream_seed_dir" branch -M dev
git -C "$upstream_seed_dir" push -q "$upstream_remote_dir" dev
git -C "$upstream_remote_dir" symbolic-ref HEAD refs/heads/dev
upstream_proj_dir="$(newdir)"; tmpdirs+=("$upstream_proj_dir")
git clone -q "$upstream_remote_dir" "$upstream_proj_dir"
git -C "$upstream_proj_dir" config user.email t@fork-sandbox.invalid
git -C "$upstream_proj_dir" config user.name Tester

# A dedicated copy of runstub_dir's own kubectl+git stub pair, NOT
# runstub_dir/runstub_verb itself: runstub_dir's git stub's fetch
# emulation builds its update-ref target as "refs/heads/${arg#*:}", but
# ${arg#*:} on the real refspec refs/heads/X:refs/heads/X is already
# refs/heads/X -- so runstub_dir actually lands the stub fetch at
# refs/heads/refs/heads/X. Every existing test that uses runstub_dir only
# ever checks that SOMETHING fetched (a file, an output line), never the
# exact ref, so this has never mattered before -- but these tests check
# the fetched branch's own @{upstream}, which needs the ref at its real
# name. kubectl's stub here is byte-for-byte runstub_dir's own (same
# cases, same env knobs); only the git stub's update-ref line differs.
upstream_stub_dir="$(newdir)"; tmpdirs+=("$upstream_stub_dir")
cat > "$upstream_stub_dir/git" <<'STUB'
#!/usr/bin/env bash
case " $* " in
    *" push "*) exit 0 ;;
    *" fetch "*)
        base="${K8S_STUB_BASE_SHA:-$(git -C . rev-parse -q --verify HEAD 2>/dev/null || true)}"
        for arg in "$@"; do
            case "$arg" in
                refs/heads/*:refs/heads/*)
                    tip="$base"
                    if [[ -n "${K8S_STUB_FETCH_REF:-}" ]]; then
                        parent="$(git -C . rev-parse -q --verify "$base" 2>/dev/null || true)"
                        if [[ -n "$parent" ]]; then
                            tip="$(GIT_AUTHOR_NAME=stub-fetch GIT_AUTHOR_EMAIL=stub-fetch@fork-sandbox.invalid \
                                GIT_COMMITTER_NAME=stub-fetch GIT_COMMITTER_EMAIL=stub-fetch@fork-sandbox.invalid \
                                git -C . commit-tree "$(git -C . hash-object -t tree /dev/null)" -p "$parent" -m "stub: fetched commit")"
                        fi
                    fi
                    [[ -n "$tip" ]] && git -C . update-ref "${arg#*:}" "$tip"
                    ;;
            esac
        done
        exit 0 ;;
esac
exec /usr/bin/git "$@"
STUB
cat > "$upstream_stub_dir/kubectl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$K8S_STUB_LOG"
case " $* " in
    *"context-extract.sh /work/session-store "*)
        if [[ -n "${K8S_STUB_SESSION_PUSH_CAPTURE:-}" ]]; then
            cat > "$K8S_STUB_SESSION_PUSH_CAPTURE"
        else
            cat >/dev/null
        fi
        exit 0 ;;
    *" apply -f -"*)
        if [[ -n "${K8S_STUB_APPLY_MANIFEST:-}" ]]; then
            cat > "$K8S_STUB_APPLY_MANIFEST"
        else
            cat >/dev/null
        fi
        exit "${K8S_STUB_APPLY_RC:-0}" ;;
    *" wait "*) exit 0 ;;
    *" get pod -l job-name="*) printf 'stub-pod\n' ;;
    *" -o jsonpath={.status.phase} "*)
        printf '%s\n' "${K8S_STUB_POD_PHASE:-Running}"; exit 0 ;;
    *" get pod "*)
        spec="${K8S_STUB_POD_SPEC:-}"
        [[ -n "$spec" ]] || spec='{"spec":{"containers":[{"name":"agent"}]}}'
        printf '%s\n' "$spec" ;;
    *" get "*) printf 'stub-pod\n' ;;
    *" /work/repo.git rev-parse "*)
        printf '%s\n' "${K8S_STUB_BASE_SHA:-}"
        exit 0 ;;
    *" delete "*) exit 0 ;;
    *" logs "*) printf 'stub pod log: entrypoint narration\n'; exit 0 ;;
    *" tar cf - -C /work/outbox "*)
        if [[ -n "${K8S_STUB_OUTBOX_DIR:-}" ]]; then
            ( cd "$K8S_STUB_OUTBOX_DIR" && tar cf - . ) || true
        fi
        [[ -n "${K8S_STUB_OUTBOX_STDERR:-}" ]] && printf '%s' "$K8S_STUB_OUTBOX_STDERR" >&2
        exit "${K8S_STUB_OUTBOX_RC:-1}"
        ;;
    *" cat /work/.run-complete "*)
        if [[ -n "${K8S_STUB_RUN_COMPLETE_RC:-}" ]]; then
            exit "$K8S_STUB_RUN_COMPLETE_RC"
        fi
        if [[ -n "${K8S_STUB_RUN_COMPLETE_AFTER:-}" ]]; then
            n=$(( $(cat "$K8S_STUB_COUNTER" 2>/dev/null || echo 0) + 1 ))
            printf '%s' "$n" > "$K8S_STUB_COUNTER"
            (( n > K8S_STUB_RUN_COMPLETE_AFTER )) || exit 1
        fi
        printf '%s\n' "${K8S_STUB_RUN_COMPLETE_VALUE:-0}" ;;
esac
exit 0
STUB
chmod +x "$upstream_stub_dir/git" "$upstream_stub_dir/kubectl"
upstream_verb() {
    # $1 = kubectl log, $2 = output file, $3 = verb, rest = its args.
    local log="$1" out="$2" verb="$3"; shift 3
    HOME="$k8s_test_home" PATH="$upstream_stub_dir:$PATH" \
        K8S_STUB_LOG="$log" \
        K8S_STUB_BASE_SHA="${K8S_STUB_BASE_SHA:-$(git -C "$upstream_proj_dir" rev-parse HEAD)}" \
        K8S_STUB_OUTBOX_DIR="${K8S_STUB_OUTBOX_DIR:-$runstub_pod_outbox}" \
        FORK_SANDBOX_CONFIG_DIR="$config_dir" \
        "$k8s_sh" "$verb" "$@" > "$out" 2>&1
}

# 1. submit --checkout origin/dev resolves rule 1 and records it; collect
# reads that back and cmd_fetch applies it once the branch has landed.
upstream_submit_d="$(newdir)"; tmpdirs+=("$upstream_submit_d")
rc=0
K8S_STUB_BASE_SHA="$(git -C "$upstream_proj_dir" rev-parse HEAD)" \
    upstream_verb "$upstream_submit_d/submit.log" "$upstream_submit_d/submit.out" submit \
    --branch fs-k8s-test-upstream-checkout --model moonshotai/kimi-k3 \
    --checkout origin/dev "$upstream_proj_dir" "$handoff_file" || rc=$?
upstream_rd1="$(sed -n 's/^  run dir:  *//p' "$upstream_submit_d/submit.out" | head -1)"
if (( rc == 0 )) && grep -qxF 'UPSTREAM=origin/dev' "$upstream_rd1/run.env" \
    && grep -qxF 'UPSTREAM_REASON=' "$upstream_rd1/run.env"; then
    ok "submit --checkout origin/dev records UPSTREAM=origin/dev in run.env"
else
    no "submit --checkout origin/dev records UPSTREAM=origin/dev in run.env" \
        "rc=$rc run.env=$(cat "$upstream_rd1/run.env" 2>/dev/null)"
fi

upstream_collect_out1="$(newdir)/collect1.out"; tmpdirs+=("$(dirname "$upstream_collect_out1")")
rc=0
K8S_STUB_BASE_SHA="$(git -C "$upstream_proj_dir" rev-parse HEAD)" \
    upstream_verb "$(newdir)/kubectl1.log" "$upstream_collect_out1" collect \
    --branch fs-k8s-test-upstream-checkout --run-dir "$upstream_rd1" "$upstream_proj_dir" || rc=$?
upstream_tracked1="$(git -C "$upstream_proj_dir" rev-parse --abbrev-ref 'fs-k8s-test-upstream-checkout@{upstream}' 2>/dev/null || true)"
if [[ "$upstream_tracked1" == origin/dev ]] \
    && grep -q 'fork-sandbox: upstream of fs-k8s-test-upstream-checkout set to origin/dev' \
        "$upstream_collect_out1"; then
    ok "collect after submit --checkout origin/dev sets the fetched branch's upstream to origin/dev"
else
    no "collect after submit --checkout origin/dev sets the fetched branch's upstream to origin/dev" \
        "rc=$rc tracked=$upstream_tracked1 out=$(cat "$upstream_collect_out1")"
fi

# 2. A standalone fetch (no submit/collect context, so neither --upstream
# nor --upstream-none is given) resolves it itself, via rule 3: the origin
# repo's own HEAD already tracks origin/dev (set up above).
upstream_fetch_out2="$(newdir)/fetch2.out"; tmpdirs+=("$(dirname "$upstream_fetch_out2")")
rc=0
K8S_STUB_BASE_SHA="$(git -C "$upstream_proj_dir" rev-parse HEAD)" \
    upstream_verb "$(newdir)/kubectl2.log" "$upstream_fetch_out2" fetch \
    --branch fs-k8s-test-upstream-standalone "$upstream_proj_dir" || rc=$?
upstream_tracked2="$(git -C "$upstream_proj_dir" rev-parse --abbrev-ref 'fs-k8s-test-upstream-standalone@{upstream}' 2>/dev/null || true)"
if (( rc == 0 )) && [[ "$upstream_tracked2" == origin/dev ]] \
    && grep -q 'fork-sandbox: upstream of fs-k8s-test-upstream-standalone set to origin/dev' \
        "$upstream_fetch_out2"; then
    ok "a standalone fetch with no submit/collect context resolves the upstream itself (rule 3)"
else
    no "a standalone fetch with no submit/collect context resolves the upstream itself (rule 3)" \
        "rc=$rc tracked=$upstream_tracked2 out=$(cat "$upstream_fetch_out2")"
fi

# 3. --upstream and --upstream-none together are refused, before any pod is
# ever contacted.
upstream_fetch_out3="$(newdir)/fetch3.out"; tmpdirs+=("$(dirname "$upstream_fetch_out3")")
rc=0
upstream_verb "$(newdir)/kubectl3.log" "$upstream_fetch_out3" fetch \
    --branch fs-k8s-test-upstream-mutex --upstream origin/dev \
    --upstream-none "no reason" "$upstream_proj_dir" || rc=$?
if (( rc != 0 )) && grep -q 'mutually exclusive' "$upstream_fetch_out3"; then
    ok "fetch --upstream and --upstream-none together are refused"
else
    no "fetch --upstream and --upstream-none together are refused" \
        "rc=$rc out=$(cat "$upstream_fetch_out3")"
fi

printf '\n== submit/run: pushing /work/session-store ==\n'
# --session-state's host directory is pushed into the pod the same way
# --context-ro is (cmd_submit, "Same push, same extractor" above) -- proven
# here via `run`, capturing the pushed tar's own bytes through the runstub
# kubectl's context-extract.sh capture arm, rather than just asserting the
# call happened.
session_push_dir="$(mktemp -d /var/tmp/claude-scratch/forks/claude-fork-sandbox.XXXXXX)"; tmpdirs+=("$session_push_dir")
printf '{"pushed":true}\n' > "$session_push_dir/66666666-6666-6666-6666-666666666666.jsonl"
session_push_capture="$(newdir)/session-push.tar"; tmpdirs+=("$(dirname "$session_push_capture")")
session_push_log="$(newdir)/kubectl.log"; session_push_out="$(newdir)/out-push.txt"
tmpdirs+=("$(dirname "$session_push_log")" "$(dirname "$session_push_out")")
if K8S_STUB_SESSION_PUSH_CAPTURE="$session_push_capture" runstub_run "$session_push_log" "$session_push_out" \
    --branch fs-k8s-test-session-push --model moonshotai/kimi-k3 \
    --session-state "$session_push_dir" \
    --outbox-dir "$(dirname "$session_push_out")/outbox-push" \
    "$proj_dir" "$handoff_file"; then
    session_push_listing="$(tar tf "$session_push_capture" 2>/dev/null)"
    if grep -q 'context-extract.sh /work/session-store' "$session_push_log" \
        && printf '%s\n' "$session_push_listing" | grep -q '66666666-6666-6666-6666-666666666666\.jsonl'; then
        ok "--session-state's host directory is pushed into the pod's /work/session-store"
    else
        no "--session-state's host directory is pushed into the pod's /work/session-store" \
            "log=$(cat "$session_push_log") listing=$session_push_listing"
    fi
else
    no "--session-state's host directory is pushed into the pod's /work/session-store" \
        "run exited nonzero: $(cat "$session_push_out")"
fi

# A store that tars to more than 256 MiB must not fail the run: the
# handoff's own out-of-scope list says such a store "loses k8s continuity
# (warned, not fixed)" -- refusing outright would wedge every later wake of
# a seat once its store, which only ever grows, crosses the cap. So this
# run must still succeed, but with no push (no continuity for this wake)
# and no session_state recorded in run.env (so a standalone collect cannot
# pull a store back over the host one). A tar stub fakes the over-cap
# archive without allocating 256 MiB of test data, the same trick the
# --context-ro over-cap case above uses -- but falls back to the real tar
# for every other call, since this run (unlike the --context-ro case) runs
# to completion and collect's own outbox pull needs a real tar.
session_cap_dir="$(mktemp -d /var/tmp/claude-scratch/forks/claude-fork-sandbox.XXXXXX)"; tmpdirs+=("$session_cap_dir")
printf 'too large\n' > "$session_cap_dir/big-transcript.jsonl"
session_cap_tar_stub="$(newdir)"; tmpdirs+=("$session_cap_tar_stub")
cat > "$session_cap_tar_stub/tar" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "cf" && "$3" == "-C" && -e "$4/big-transcript.jsonl" ]]; then
    truncate -s $((256 * 1024 * 1024 + 1)) "$2"
else
    exec /usr/bin/tar "$@"
fi
STUB
chmod +x "$session_cap_tar_stub/tar"
session_cap_log="$(newdir)/kubectl.log"; session_cap_out="$(newdir)/out-cap.txt"
tmpdirs+=("$(dirname "$session_cap_log")" "$(dirname "$session_cap_out")")
if PATH="$session_cap_tar_stub:$PATH" runstub_run "$session_cap_log" "$session_cap_out" \
    --branch fs-k8s-test-session-cap --model moonshotai/kimi-k3 \
    --session-state "$session_cap_dir" \
    --outbox-dir "$(dirname "$session_cap_out")/outbox-cap" \
    "$proj_dir" "$handoff_file"; then
    session_cap_rd="$(sed -n 's/^  run dir:  *//p' "$session_cap_out" | head -1)"
    if grep -q 'Warning: --session-state' "$session_cap_out" \
        && grep -q 'over the .* byte' "$session_cap_out" \
        && grep -q 'without session' "$session_cap_out" \
        && ! grep -q 'context-extract.sh /work/session-store' "$session_cap_log" \
        && [[ -n "$session_cap_rd" && -f "$session_cap_rd/run.env" ]] \
        && ! grep -q '^session_state=' "$session_cap_rd/run.env"; then
        ok "an over-cap --session-state warns and runs without pushing or recording the store"
    else
        no "an over-cap --session-state warns and runs without pushing or recording the store" \
            "out=$(cat "$session_cap_out") log=$(cat "$session_cap_log") run.env=$(cat "${session_cap_rd:-/nonexistent}/run.env" 2>/dev/null)"
    fi
else
    no "an over-cap --session-state warns and runs without pushing or recording the store" \
        "run exited nonzero: $(cat "$session_cap_out")"
fi

printf '\n== collect: pulling /work/session-store back ==\n'
# session_state/session_id are read back from run.env (only submit's
# --session-state/--session-id know them), exactly like harness/model
# above -- so every case here drives collect through --run-dir with a
# hand-built run.env, the same shape as the undecidable-commits case (21)
# above.

# A. A clean pull: the host store is swapped for the pod's, and
# summary.json's session_id is discovered fresh from what is now there --
# not whatever the host store held before.
session_pull_branch_a=fs-k8s-test-collect-session-pull-ok
git -C "$proj_dir" update-ref "refs/heads/$session_pull_branch_a" "$(git -C "$proj_dir" rev-parse HEAD)"
session_pull_host_a="$(newdir)/session-store-a"; tmpdirs+=("$session_pull_host_a")
mkdir -p -- "$session_pull_host_a"
printf '{"old":true}\n' > "$session_pull_host_a/old-transcript.jsonl"
session_pull_pod_a="$(newdir)"; tmpdirs+=("$session_pull_pod_a")
printf '{"new":true}\n' > "$session_pull_pod_a/22222222-2222-2222-2222-222222222222.jsonl"
session_pull_rd_a="$(mktemp -d /var/tmp/claude-scratch/forks/claude-fork-sandbox.XXXXXX)"; tmpdirs+=("$session_pull_rd_a")
{
    printf 'mode=run\n'
    printf 'harness=claude\n'
    printf 'model=some-model\n'
    printf 'session_state=%s\n' "$session_pull_host_a"
} > "$session_pull_rd_a/run.env"
printf 'test\n' > "$session_pull_rd_a/run-source"
session_pull_log_a="$(newdir)/kubectl.log"; session_pull_out_a="$(newdir)/out-a.txt"; session_pull_dest_a="$(newdir)/outbox-a"
tmpdirs+=("$(dirname "$session_pull_log_a")" "$(dirname "$session_pull_dest_a")")
if K8S_STUB_SESSION_DIR="$session_pull_pod_a" K8S_STUB_SESSION_RC=0 \
    K8S_STUB_OUTBOX_DIR="$collect_outbox11" K8S_STUB_OUTBOX_RC=0 \
    collectstub_collect "$session_pull_log_a" "$session_pull_out_a" \
    --branch "$session_pull_branch_a" --outbox-dir "$session_pull_dest_a" \
    --run-dir "$session_pull_rd_a" "$proj_dir"; then
    if [[ -f "$session_pull_host_a/22222222-2222-2222-2222-222222222222.jsonl" ]] \
        && [[ ! -e "$session_pull_host_a/old-transcript.jsonl" ]] \
        && [[ "$(jq -r '.session_id' "$session_pull_rd_a/summary.json" 2>/dev/null)" == "22222222-2222-2222-2222-222222222222" ]] \
        && [[ "$(jq -r '.session_state' "$session_pull_rd_a/summary.json" 2>/dev/null)" == "$session_pull_host_a" ]]; then
        ok "a clean session-store pull swaps the host store and summary.json reports the newest id"
    else
        no "a clean session-store pull swaps the host store and summary.json reports the newest id" \
            "host=$(find "$session_pull_host_a" 2>/dev/null) summary=$(cat "$session_pull_rd_a/summary.json" 2>/dev/null)"
    fi
else
    no "a clean session-store pull swaps the host store and summary.json reports the newest id" \
        "collect exited nonzero: $(cat "$session_pull_out_a")"
fi

# B. A failed exec (the pod's tar dies non-zero, well under the cap so it
# is a genuine read failure, not the over-cap case) must leave the host
# store byte-identical and summary.json must report the OLD id -- the
# pull failed, so the previous turn's id is what is still there.
session_pull_branch_b=fs-k8s-test-collect-session-pull-execfail
git -C "$proj_dir" update-ref "refs/heads/$session_pull_branch_b" "$(git -C "$proj_dir" rev-parse HEAD)"
session_pull_host_b="$(newdir)/session-store-b"; tmpdirs+=("$session_pull_host_b")
mkdir -p -- "$session_pull_host_b"
printf '{"kept":true}\n' > "$session_pull_host_b/11111111-1111-1111-1111-111111111111.jsonl"
session_pull_host_b_before="$(find "$session_pull_host_b" -type f -exec sha256sum {} +)"
session_pull_rd_b="$(mktemp -d /var/tmp/claude-scratch/forks/claude-fork-sandbox.XXXXXX)"; tmpdirs+=("$session_pull_rd_b")
{
    printf 'mode=run\n'
    printf 'harness=claude\n'
    printf 'model=some-model\n'
    printf 'session_state=%s\n' "$session_pull_host_b"
} > "$session_pull_rd_b/run.env"
printf 'test\n' > "$session_pull_rd_b/run-source"
session_pull_log_b="$(newdir)/kubectl.log"; session_pull_out_b="$(newdir)/out-b.txt"; session_pull_dest_b="$(newdir)/outbox-b"
tmpdirs+=("$(dirname "$session_pull_log_b")" "$(dirname "$session_pull_dest_b")")
if K8S_STUB_SESSION_RC=1 K8S_STUB_SESSION_STDERR='stub-kubectl says: session store read exploded' \
    K8S_STUB_OUTBOX_DIR="$collect_outbox11" K8S_STUB_OUTBOX_RC=0 \
    collectstub_collect "$session_pull_log_b" "$session_pull_out_b" \
    --branch "$session_pull_branch_b" --outbox-dir "$session_pull_dest_b" \
    --run-dir "$session_pull_rd_b" "$proj_dir"; then
    session_pull_host_b_after="$(find "$session_pull_host_b" -type f -exec sha256sum {} +)"
    if [[ "$session_pull_host_b_before" == "$session_pull_host_b_after" ]] \
        && grep -q 'could not read the session store' "$session_pull_out_b" \
        && grep -q 'session store read exploded' "$session_pull_out_b" \
        && [[ "$(jq -r '.session_id' "$session_pull_rd_b/summary.json" 2>/dev/null)" == "11111111-1111-1111-1111-111111111111" ]]; then
        ok "a failed session-store exec leaves the host store byte-identical and reports the old id"
    else
        no "a failed session-store exec leaves the host store byte-identical and reports the old id" \
            "before=$session_pull_host_b_before after=$session_pull_host_b_after summary=$(cat "$session_pull_rd_b/summary.json" 2>/dev/null) out=$(cat "$session_pull_out_b")"
    fi
else
    no "a failed session-store exec leaves the host store byte-identical and reports the old id" \
        "collect exited nonzero: $(cat "$session_pull_out_b")"
fi

# C. An archive the extractor must refuse -- a symlink entry, same guard
# the outbox pull relies on -- must also leave the host store untouched
# and report the old id, not a partial extraction.
session_pull_branch_c=fs-k8s-test-collect-session-pull-symlink
git -C "$proj_dir" update-ref "refs/heads/$session_pull_branch_c" "$(git -C "$proj_dir" rev-parse HEAD)"
session_pull_host_c="$(newdir)/session-store-c"; tmpdirs+=("$session_pull_host_c")
mkdir -p -- "$session_pull_host_c"
printf '{"kept":true}\n' > "$session_pull_host_c/33333333-3333-3333-3333-333333333333.jsonl"
session_pull_host_c_before="$(find "$session_pull_host_c" -type f -exec sha256sum {} +)"
session_pull_pod_c="$(newdir)"; tmpdirs+=("$session_pull_pod_c")
ln -s /etc/passwd "$session_pull_pod_c/evil-link.jsonl"
session_pull_rd_c="$(mktemp -d /var/tmp/claude-scratch/forks/claude-fork-sandbox.XXXXXX)"; tmpdirs+=("$session_pull_rd_c")
{
    printf 'mode=run\n'
    printf 'harness=claude\n'
    printf 'model=some-model\n'
    printf 'session_state=%s\n' "$session_pull_host_c"
} > "$session_pull_rd_c/run.env"
printf 'test\n' > "$session_pull_rd_c/run-source"
session_pull_log_c="$(newdir)/kubectl.log"; session_pull_out_c="$(newdir)/out-c.txt"; session_pull_dest_c="$(newdir)/outbox-c"
tmpdirs+=("$(dirname "$session_pull_log_c")" "$(dirname "$session_pull_dest_c")")
if K8S_STUB_SESSION_DIR="$session_pull_pod_c" K8S_STUB_SESSION_RC=0 \
    K8S_STUB_OUTBOX_DIR="$collect_outbox11" K8S_STUB_OUTBOX_RC=0 \
    collectstub_collect "$session_pull_log_c" "$session_pull_out_c" \
    --branch "$session_pull_branch_c" --outbox-dir "$session_pull_dest_c" \
    --run-dir "$session_pull_rd_c" "$proj_dir"; then
    session_pull_host_c_after="$(find "$session_pull_host_c" -type f -exec sha256sum {} +)"
    if [[ "$session_pull_host_c_before" == "$session_pull_host_c_after" ]] \
        && grep -q 'could not extract the session store tarball' "$session_pull_out_c" \
        && [[ "$(jq -r '.session_id' "$session_pull_rd_c/summary.json" 2>/dev/null)" == "33333333-3333-3333-3333-333333333333" ]]; then
        ok "a session-store archive with a symlink entry is refused, leaving the host store intact"
    else
        no "a session-store archive with a symlink entry is refused, leaving the host store intact" \
            "before=$session_pull_host_c_before after=$session_pull_host_c_after summary=$(cat "$session_pull_rd_c/summary.json" 2>/dev/null) out=$(cat "$session_pull_out_c")"
    fi
else
    no "a session-store archive with a symlink entry is refused, leaving the host store intact" \
        "collect exited nonzero: $(cat "$session_pull_out_c")"
fi

# D. The rc-3 zero-harvest path (see case 21 above) still writes
# session_state/session_id: the summary write happens before that check,
# and a suspicious run is still worth resuming from.
session_pull_branch_d=fs-k8s-test-collect-session-pull-rc3
git -C "$proj_dir" update-ref "refs/heads/$session_pull_branch_d" "$(git -C "$proj_dir" rev-parse HEAD)"
session_pull_host_d="$(newdir)/session-store-d"; tmpdirs+=("$session_pull_host_d")
session_pull_pod_d="$(newdir)"; tmpdirs+=("$session_pull_pod_d")
printf '{"new":true}\n' > "$session_pull_pod_d/44444444-4444-4444-4444-444444444444.jsonl"
session_pull_rd_d="$(mktemp -d /var/tmp/claude-scratch/forks/claude-fork-sandbox.XXXXXX)"; tmpdirs+=("$session_pull_rd_d")
{
    printf 'mode=run\n'
    printf 'harness=claude\n'
    printf 'model=some-model\n'
    printf 'session_state=%s\n' "$session_pull_host_d"
} > "$session_pull_rd_d/run.env"
printf 'test\n' > "$session_pull_rd_d/run-source"
session_pull_log_d="$(newdir)/kubectl.log"; session_pull_out_d="$(newdir)/out-d.txt"; session_pull_dest_d="$(newdir)/outbox-d"
tmpdirs+=("$(dirname "$session_pull_log_d")" "$(dirname "$session_pull_dest_d")")
rc=0
K8S_STUB_RUN_COMPLETE=0 K8S_STUB_SESSION_DIR="$session_pull_pod_d" K8S_STUB_SESSION_RC=0 \
    K8S_STUB_OUTBOX_DIR="$collect_outbox11" K8S_STUB_OUTBOX_RC=0 \
    collectstub_collect "$session_pull_log_d" "$session_pull_out_d" \
    --branch "$session_pull_branch_d" --outbox-dir "$session_pull_dest_d" \
    --run-dir "$session_pull_rd_d" "$proj_dir" || rc=$?
if (( rc == 3 )) \
    && grep -q 'SUSPICIOUS: this run produced nothing' "$session_pull_out_d" \
    && [[ "$(jq -r '.session_id' "$session_pull_rd_d/summary.json" 2>/dev/null)" == "44444444-4444-4444-4444-444444444444" ]] \
    && [[ "$(jq -r '.session_state' "$session_pull_rd_d/summary.json" 2>/dev/null)" == "$session_pull_host_d" ]]; then
    ok "the rc-3 zero-harvest path still carries session_state/session_id in summary.json"
else
    no "the rc-3 zero-harvest path still carries session_state/session_id in summary.json" \
        "rc=$rc summary=$(cat "$session_pull_rd_d/summary.json" 2>/dev/null) out=$(cat "$session_pull_out_d")"
fi

# E. An over-cap store: the pull warns about the cap (not a read failure),
# leaves the host store byte-identical, and summary.json reports the OLD
# id -- the same preserve-on-failure contract as case B (exec failure) and
# case C (extractor refusal) above, driven this time by the size check
# itself.
session_pull_branch_e=fs-k8s-test-collect-session-pull-overcap
git -C "$proj_dir" update-ref "refs/heads/$session_pull_branch_e" "$(git -C "$proj_dir" rev-parse HEAD)"
session_pull_host_e="$(newdir)/session-store-e"; tmpdirs+=("$session_pull_host_e")
mkdir -p -- "$session_pull_host_e"
printf '{"kept":true}\n' > "$session_pull_host_e/55555555-5555-5555-5555-555555555555.jsonl"
session_pull_host_e_before="$(find "$session_pull_host_e" -type f -exec sha256sum {} +)"
session_pull_rd_e="$(mktemp -d /var/tmp/claude-scratch/forks/claude-fork-sandbox.XXXXXX)"; tmpdirs+=("$session_pull_rd_e")
{
    printf 'mode=run\n'
    printf 'harness=claude\n'
    printf 'model=some-model\n'
    printf 'session_state=%s\n' "$session_pull_host_e"
} > "$session_pull_rd_e/run.env"
printf 'test\n' > "$session_pull_rd_e/run-source"
session_pull_log_e="$(newdir)/kubectl.log"; session_pull_out_e="$(newdir)/out-e.txt"; session_pull_dest_e="$(newdir)/outbox-e"
tmpdirs+=("$(dirname "$session_pull_log_e")" "$(dirname "$session_pull_dest_e")")
if K8S_STUB_SESSION_OVERSIZE=1 \
    K8S_STUB_OUTBOX_DIR="$collect_outbox11" K8S_STUB_OUTBOX_RC=0 \
    collectstub_collect "$session_pull_log_e" "$session_pull_out_e" \
    --branch "$session_pull_branch_e" --outbox-dir "$session_pull_dest_e" \
    --run-dir "$session_pull_rd_e" "$proj_dir"; then
    session_pull_host_e_after="$(find "$session_pull_host_e" -type f -exec sha256sum {} +)"
    if [[ "$session_pull_host_e_before" == "$session_pull_host_e_after" ]] \
        && grep -q 'over the .* byte cap; leaving the host session store as it was' "$session_pull_out_e" \
        && ! grep -q 'could not read the session store' "$session_pull_out_e" \
        && [[ "$(jq -r '.session_id' "$session_pull_rd_e/summary.json" 2>/dev/null)" == "55555555-5555-5555-5555-555555555555" ]]; then
        ok "an over-cap session-store pull leaves the host store byte-identical and reports the old id"
    else
        no "an over-cap session-store pull leaves the host store byte-identical and reports the old id" \
            "before=$session_pull_host_e_before after=$session_pull_host_e_after summary=$(cat "$session_pull_rd_e/summary.json" 2>/dev/null) out=$(cat "$session_pull_out_e")"
    fi
else
    no "an over-cap session-store pull leaves the host store byte-identical and reports the old id" \
        "collect exited nonzero: $(cat "$session_pull_out_e")"
fi

printf '\n== fork-sandbox-k8s.sh say: argument validation (no cluster) ==\n'
# Every one of these is rejected before cmd_say ever calls kubectl, so all
# of them run with no cluster reachable. The write itself (kubectl exec into
# a real pod) is not covered here -- see the inbox-write.sh section below
# for what of the write path CAN be proven offline.
refuses "say rejects a missing --branch" \
    "say requires --branch" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" say "hello"
refuses "say rejects a missing message" \
    "nothing to say" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" say --branch fs-k8s-test-branch
refuses "say rejects an empty message" \
    "the message is empty" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" say --branch fs-k8s-test-branch ""
refuses "say rejects an all-whitespace message" \
    "the message is empty" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" say --branch fs-k8s-test-branch "   "
refuses "say rejects an unknown option" \
    "unknown option" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" say --branch fs-k8s-test-branch --bogus "hello"

# A large addendum must clear the emptiness check promptly. That check once
# used a whole-string glob substitution, which walks the message per
# multibyte character under a UTF-8 locale: 7.5s at 64KB, 33s at 128KB,
# 139s at 256KB, against ~6ms for the regex form. An addendum is exactly
# the input that gets large -- a thread, a diff, a log pasted in for the
# session to read. There is no cluster here, so this say fails at pod
# lookup either way; what is under test is that it FAILS rather than
# hangs. Exit 124 is timeout's own code, so it distinguishes the two.
say_big_dir="$(newdir)"; tmpdirs+=("$say_big_dir")
say_big="$say_big_dir/addendum.txt"
printf 'große Zeile mit Umlauten — %d\n' $(seq 6000) > "$say_big"
LC_ALL=C.UTF-8 timeout 20 env FORK_SANDBOX_CONFIG_DIR="$config_dir" \
    "$k8s_sh" say --branch fs-k8s-test-branch - < "$say_big" >/dev/null 2>&1
say_big_rc=$?
if (( say_big_rc != 124 )); then
    ok "say clears the emptiness check on a large multibyte message"
else
    no "say clears the emptiness check on a large multibyte message" \
        "timed out -- the check may have regressed to a glob substitution"
fi

printf '\n== fork-sandbox-k8s-inbox-write.sh: naming and no-collision (no cluster) ==\n'
# This is the exact script the pod mounts and `say` execs over kubectl exec
# -i -- run directly here, against a plain directory, so its naming and
# no-collision behavior is proven without a cluster or kubectl at all.
inbox_dir="$(newdir)"; tmpdirs+=("$inbox_dir")
fixed_epoch=1700000000
out1="$(printf 'first message\n' | "$inbox_write_sh" "$fixed_epoch" "$inbox_dir")"
if [[ "$out1" == "$inbox_dir"/"$fixed_epoch"-[0-9][0-9].md ]]; then
    ok "generated filename matches <epoch>-<nn>.md"
else
    no "generated filename matches <epoch>-<nn>.md" "got '$out1'"
fi
if [[ -f "$out1" && "$(cat "$out1")" == "first message" ]]; then
    ok "the written file holds the message"
else
    no "the written file holds the message" "'$out1' missing or wrong content"
fi
out2="$(printf 'second message\n' | "$inbox_write_sh" "$fixed_epoch" "$inbox_dir")"
if [[ -n "$out2" && "$out1" != "$out2" ]]; then
    ok "two addenda in the same second do not collide"
else
    no "two addenda in the same second do not collide" "out1='$out1' out2='$out2'"
fi
inbox_count="$(find "$inbox_dir" -maxdepth 1 -type f | wc -l)"
if [[ "$inbox_count" -eq 2 ]]; then
    ok "both addenda land in the inbox directory, nothing else"
else
    no "both addenda land in the inbox directory, nothing else" "$(ls "$inbox_dir")"
fi

printf '\n== fork-sandbox-k8s-outbox-extract.sh: extraction guards (no cluster) ==\n'
# This script is the actual security boundary for the outbox pull-back --
# what stands between a hostile or confused pod's tar stream and the host
# filesystem (see its own header comment for the full threat model). Driven
# directly here against hand-built tar fixtures, the same way the
# inbox-write.sh section above drives that script directly: no cluster, no
# kubectl, no real pod involved.
#
# GNU tar sanitizes dangerous member names AT CREATION TIME by default (it
# silently strips a leading `/` and a leading `../`), which is exactly the
# opposite of what a fixture for this test needs -- so the absolute-path and
# `..`-component fixtures below are built with `tar -P`/`--absolute-names`,
# which preserves the member name as given. The warning tar prints to
# stderr while doing that ("Removing leading...") is fixture-creation noise,
# not a signal, so it is redirected away rather than asserted on.

# well-formed: the shape `tar cf - -C /work/outbox .` on a real pod
# produces -- relative entries, no `..`, no links. Must extract cleanly.
of_src="$(newdir)"; tmpdirs+=("$of_src")
mkdir -p "$of_src/sub"
printf 'hello\n' > "$of_src/foo.txt"
printf 'world\n' > "$of_src/sub/bar.txt"
of_parent="$(newdir)"; tmpdirs+=("$of_parent")
of_wf_tar="$of_parent/wf.tar"
tar cf "$of_wf_tar" -C "$of_src" .
of_wf_dest="$of_parent/wf_dest"
if "$outbox_extract_sh" "$of_wf_tar" "$of_wf_dest" >/tmp/fs-k8s-outbox-wf.err 2>&1; then
    ok "well-formed archive extracts"
else
    no "well-formed archive extracts" "$(cat /tmp/fs-k8s-outbox-wf.err)"
fi
if [[ "$(cat "$of_wf_dest/foo.txt" 2>/dev/null)" == "hello" \
    && "$(cat "$of_wf_dest/sub/bar.txt" 2>/dev/null)" == "world" ]]; then
    ok "well-formed archive's files land with their content intact"
else
    no "well-formed archive's files land with their content intact" \
        "$(find "$of_wf_dest" 2>&1)"
fi
rm -f /tmp/fs-k8s-outbox-wf.err

# absolute path: refused outright, whole archive, before anything is
# extracted -- the dest directory must not even be created.
of_abs_src="$(newdir)"; tmpdirs+=("$of_abs_src")
mkdir -p "$of_abs_src/a"
printf 'x\n' > "$of_abs_src/a/f.txt"
of_abs_parent="$(newdir)"; tmpdirs+=("$of_abs_parent")
of_abs_tar="$of_abs_parent/abs.tar"
( cd "$of_abs_src" && tar -P -cf "$of_abs_tar" "$of_abs_src/a/f.txt" 2>/dev/null )
of_abs_dest="$of_abs_parent/abs_dest"
refuses "absolute path is refused" \
    "contains an absolute path" \
    "$outbox_extract_sh" "$of_abs_tar" "$of_abs_dest"
if [[ ! -e "$of_abs_dest" ]]; then
    ok "absolute-path archive: nothing is extracted"
else
    no "absolute-path archive: nothing is extracted" "$of_abs_dest exists"
fi

# `..` path component: same refuse-the-whole-archive treatment.
of_dd_src="$(newdir)"; tmpdirs+=("$of_dd_src")
mkdir -p "$of_dd_src/a"
printf 'x\n' > "$of_dd_src/a/f.txt"
of_dd_parent="$(newdir)"; tmpdirs+=("$of_dd_parent")
of_dd_tar="$of_dd_parent/dd.tar"
( cd "$of_dd_src" && tar -P -cf "$of_dd_tar" a/../a/f.txt 2>/dev/null )
of_dd_dest="$of_dd_parent/dd_dest"
refuses "a '..' path component is refused" \
    "contains a '..' path component" \
    "$outbox_extract_sh" "$of_dd_tar" "$of_dd_dest"
if [[ ! -e "$of_dd_dest" ]]; then
    ok "'..'-component archive: nothing is extracted"
else
    no "'..'-component archive: nothing is extracted" "$of_dd_dest exists"
fi

# symlink: refused as a link entry, listed and rejected before extraction
# even starts -- this is the guard that closes the kubectl-cp-CVE-shaped
# escape the script's header describes (a symlink entry followed by a
# second entry that writes through it).
of_sym_src="$(newdir)"; tmpdirs+=("$of_sym_src")
ln -s /etc/passwd "$of_sym_src/evil"
of_sym_parent="$(newdir)"; tmpdirs+=("$of_sym_parent")
of_sym_tar="$of_sym_parent/sym.tar"
tar cf "$of_sym_tar" -C "$of_sym_src" .
of_sym_dest="$of_sym_parent/sym_dest"
refuses "a symlink entry is refused" \
    "contains a link entry" \
    "$outbox_extract_sh" "$of_sym_tar" "$of_sym_dest"
if [[ ! -e "$of_sym_dest" ]]; then
    ok "symlink archive: nothing is extracted"
else
    no "symlink archive: nothing is extracted" "$of_sym_dest exists"
fi

# hard link: a distinct code path from the symlink check above (tar -tvf
# marks a hard link with a leading 'h' and a trailing "link to TARGET",
# not the 'l' mode a symlink gets), so it needs its own fixture.
of_hl_src="$(newdir)"; tmpdirs+=("$of_hl_src")
printf 'x\n' > "$of_hl_src/f.txt"
ln "$of_hl_src/f.txt" "$of_hl_src/g.txt"
of_hl_parent="$(newdir)"; tmpdirs+=("$of_hl_parent")
of_hl_tar="$of_hl_parent/hl.tar"
tar cf "$of_hl_tar" -C "$of_hl_src" .
of_hl_dest="$of_hl_parent/hl_dest"
refuses "a hard-link entry is refused" \
    "contains a link entry" \
    "$outbox_extract_sh" "$of_hl_tar" "$of_hl_dest"
if [[ ! -e "$of_hl_dest" ]]; then
    ok "hard-link archive: nothing is extracted"
else
    no "hard-link archive: nothing is extracted" "$of_hl_dest exists"
fi

# oversized: refused on the streaming byte-size cap, before tar -tvf is
# even run over it.
of_big_src="$(newdir)"; tmpdirs+=("$of_big_src")
dd if=/dev/zero of="$of_big_src/big.bin" bs=1M count=65 2>/dev/null
of_big_parent="$(newdir)"; tmpdirs+=("$of_big_parent")
of_big_tar="$of_big_parent/big.tar"
tar cf "$of_big_tar" -C "$of_big_src" .
of_big_dest="$of_big_parent/big_dest"
# The needle names both the outbox-extract label and the tar file: this is
# a failure surfaced through the shared context-extract.sh implementation,
# and an operator reading it must see which script and which archive were
# rejected, not "context-extract" naming a DEST_DIR that may belong to a
# run that never used --context-ro at all.
refuses "an over-cap archive is refused" \
    "fork-sandbox-k8s-outbox-extract: $of_big_tar" \
    "$outbox_extract_sh" "$of_big_tar" "$of_big_dest"
if [[ ! -e "$of_big_dest" ]]; then
    ok "over-cap archive: nothing is extracted"
else
    no "over-cap archive: nothing is extracted" "$of_big_dest exists"
fi

# An explicit $3 cap, not just the default -- the argument fork-sandbox-k8s.sh
# actually passes (its own resolved outbox_max_bytes), so this exercises the
# real call shape rather than only the no-arg default the two cases above use.
of_cap_src="$(newdir)"; tmpdirs+=("$of_cap_src")
printf 'a small file, well under any default cap\n' > "$of_cap_src/small.txt"
of_cap_parent="$(newdir)"; tmpdirs+=("$of_cap_parent")
of_cap_tar="$of_cap_parent/cap.tar"
tar cf "$of_cap_tar" -C "$of_cap_src" .
of_cap_dest_lo="$of_cap_parent/cap_dest_lo"
refuses "an explicit low \$3 cap refuses an archive under the default cap" \
    "byte cap; refusing it" \
    "$outbox_extract_sh" "$of_cap_tar" "$of_cap_dest_lo" 10
if [[ ! -e "$of_cap_dest_lo" ]]; then
    ok "explicit low \$3 cap: nothing is extracted"
else
    no "explicit low \$3 cap: nothing is extracted" "$of_cap_dest_lo exists"
fi
of_cap_dest_hi="$of_cap_parent/cap_dest_hi"
if "$outbox_extract_sh" "$of_cap_tar" "$of_cap_dest_hi" 1000000 \
    >/tmp/fs-k8s-outbox-cap.err 2>&1; then
    ok "an explicit high \$3 cap extracts the same archive"
else
    no "an explicit high \$3 cap extracts the same archive" "$(cat /tmp/fs-k8s-outbox-cap.err)"
fi
if [[ "$(cat "$of_cap_dest_hi/small.txt" 2>/dev/null)" == "a small file, well under any default cap" ]]; then
    ok "explicit high \$3 cap: the file lands with its content intact"
else
    no "explicit high \$3 cap: the file lands with its content intact" \
        "$(find "$of_cap_dest_hi" 2>&1)"
fi
rm -f /tmp/fs-k8s-outbox-cap.err

# A $3 above 256 MiB -- the shared context-extract.sh script's own default
# ceiling, meant for --context-ro -- must still be honored, not silently
# reduced to it: --outbox-max is documented as having no upper ceiling, so
# an archive between 256 MiB and the caller's $3 must still extract. This
# pins the regression where fork-sandbox-k8s-outbox-extract.sh became a thin
# wrapper around fork-sandbox-k8s-context-extract.sh and inherited its
# literal without overriding it.
of_huge_src="$(newdir)"; tmpdirs+=("$of_huge_src")
truncate -s 257M "$of_huge_src/big.bin"
of_huge_parent="$(newdir)"; tmpdirs+=("$of_huge_parent")
of_huge_tar="$of_huge_parent/huge.tar"
tar cf "$of_huge_tar" -C "$of_huge_src" .
of_huge_dest="$of_huge_parent/huge_dest"
if "$outbox_extract_sh" "$of_huge_tar" "$of_huge_dest" $((300 * 1024 * 1024)) \
        >/tmp/fs-k8s-outbox-huge.err 2>&1; then
    ok "a \$3 above 256 MiB is honored, not silently capped there"
else
    no "a \$3 above 256 MiB is honored, not silently capped there" \
        "$(cat /tmp/fs-k8s-outbox-huge.err)"
fi
rm -f /tmp/fs-k8s-outbox-huge.err
# These three fixtures are ~257 MiB apiece (source, tar, extracted copy);
# /tmp is a tmpfs, so held-until-EXIT here (this suite's default cleanup)
# means ~770 MiB of RAM for the rest of the run. Removed the moment this
# one assertion is done rather than joining tmpdirs for EXIT-time cleanup.
rm -rf -- "$of_huge_src" "$of_huge_parent"

printf '\n== fork-sandbox-k8s-context-extract.sh: extraction guards (no cluster) ==\n'
# The pod-side half of the --context-ro push -- what stands between a
# pushed tar stream and the pod's filesystem (see its own header comment
# for the full threat model). Driven directly here against hand-built tar
# fixtures on stdin, the same way the outbox-extract section above drives
# that script directly against a tar file argument: no cluster, no
# kubectl, no real pod involved. MAX_BYTES is a required argument for this
# script (unlike outbox-extract.sh's optional $3), so every case below
# passes one explicitly.

# well-formed: the shape `tar cf - -C CONTEXT_DIR .` on the host produces
# -- relative entries, no `..`, no links. Must extract cleanly.
cf_src="$(newdir)"; tmpdirs+=("$cf_src")
# mktemp -d defaults to mode 0700; pinned explicitly (rather than left at
# that default) so the archived top-level `./` entry's mode is known to
# differ from 0700, which the metadata-preservation test below chmods its
# own DEST_DIR to -- otherwise a coincidental match would hide a real
# restore-on-extract.
chmod 0755 "$cf_src"
mkdir -p "$cf_src/sub"
printf 'hello\n' > "$cf_src/foo.txt"
printf 'world\n' > "$cf_src/sub/bar.txt"
cf_parent="$(newdir)"; tmpdirs+=("$cf_parent")
cf_wf_tar="$cf_parent/wf.tar"
tar cf "$cf_wf_tar" -C "$cf_src" .
cf_wf_dest="$cf_parent/wf_dest"
if "$context_extract_sh" "$cf_wf_dest" 100000000 < "$cf_wf_tar" \
        >/tmp/fs-k8s-ctx-wf.err 2>&1; then
    ok "well-formed archive extracts"
else
    no "well-formed archive extracts" "$(cat /tmp/fs-k8s-ctx-wf.err)"
fi
if [[ "$(cat "$cf_wf_dest/foo.txt" 2>/dev/null)" == "hello" \
    && "$(cat "$cf_wf_dest/sub/bar.txt" 2>/dev/null)" == "world" ]]; then
    ok "well-formed archive's files land with their content intact"
else
    no "well-formed archive's files land with their content intact" \
        "$(find "$cf_wf_dest" 2>&1)"
fi
rm -f /tmp/fs-k8s-ctx-wf.err

# A regular member whose filename contains the words " link to " is not a
# link entry; only tar's leading type character identifies links here.
cf_phrase_src="$(newdir)"; tmpdirs+=("$cf_phrase_src")
printf 'ordinary\n' > "$cf_phrase_src/notes link to cache"
cf_phrase_parent="$(newdir)"; tmpdirs+=("$cf_phrase_parent")
cf_phrase_tar="$cf_phrase_parent/phrase.tar"
tar cf "$cf_phrase_tar" -C "$cf_phrase_src" .
cf_phrase_dest="$cf_phrase_parent/phrase_dest"
if "$context_extract_sh" "$cf_phrase_dest" 100000000 < "$cf_phrase_tar" \
        >/tmp/fs-k8s-ctx-phrase.err 2>&1; then
    ok "a regular filename containing ' link to ' extracts"
else
    no "a regular filename containing ' link to ' extracts" "$(cat /tmp/fs-k8s-ctx-phrase.err)"
fi
rm -f /tmp/fs-k8s-ctx-phrase.err

# An existing, EMPTY DEST_DIR is accepted -- the shape a --thread-dir/
# --attach-dir push always sees, since the pod spec's emptyDir volume
# mount pre-creates DEST_DIR before this script ever runs.
cf_exist_dest="$cf_parent/exist_dest"
mkdir -p "$cf_exist_dest"
if "$context_extract_sh" "$cf_exist_dest" 100000000 < "$cf_wf_tar" \
        >/tmp/fs-k8s-ctx-exist.err 2>&1; then
    ok "an existing EMPTY DEST_DIR is accepted"
else
    no "an existing EMPTY DEST_DIR is accepted" "$(cat /tmp/fs-k8s-ctx-exist.err)"
fi
if [[ "$(cat "$cf_exist_dest/foo.txt" 2>/dev/null)" == "hello" ]]; then
    ok "an existing EMPTY DEST_DIR: the archive's files land inside it"
else
    no "an existing EMPTY DEST_DIR: the archive's files land inside it" \
        "$(find "$cf_exist_dest" 2>&1)"
fi
rm -f /tmp/fs-k8s-ctx-exist.err

# An existing DEST_DIR's own metadata survives extraction even when this
# process is denied every chmod/utime/chown on it -- the real
# --thread-dir/--attach-dir shape: a kubelet-created emptyDir mount, owned
# by root, that this non-root, no-capabilities process cannot touch at
# all. A prior version of this test only asserted that a mode chmod'd to
# 0700 by the TEST ITSELF (which owns the directory and so CAN chmod it)
# came out as 0700 -- that passed whether or not any restore attempt
# happened, since chmod'ing 0700 to 0700 is a no-op either way, and it
# stayed green through a real regression (see commit c6d5cc1c37's own
# reviewer finding: --no-overwrite-dir does not actually stop GNU tar from
# attempting that chmod, and a non-owner gets EPERM from it regardless of
# whether the mode would change). The actual fix lives one level up, in
# fork-sandbox-k8s.sh's k8s_spool_dir_entries, which packs the directory's
# ENTRIES, never `.` itself, so no member in the archive ever maps onto
# DEST_DIR and this extractor never attempts to touch it. Proved
# here by actually denying chmod/fchmodat/utime/utimensat/chown on
# DEST_DIR through an LD_PRELOAD shim standing in for "not the owner, no
# CAP_FOWNER" -- a real EPERM, not a same-value coincidence. Skipped if no
# C compiler is on PATH to build the shim.
if command -v cc >/dev/null 2>&1; then
    cf_shim_dir="$(newdir)"; tmpdirs+=("$cf_shim_dir")
    cat > "$cf_shim_dir/shim.c" <<'SHIM_C'
#define _GNU_SOURCE
#include <stdlib.h>
#include <sys/types.h>
#include <errno.h>
#include <string.h>
#include <utime.h>
#include <dlfcn.h>

static int is_target(const char *path) {
    const char *target = getenv("FS_K8S_TEST_SHIM_TARGET");
    return target && path && strcmp(path, target) == 0;
}

int chmod(const char *path, mode_t mode) {
    if (is_target(path)) { errno = EPERM; return -1; }
    static int (*real)(const char *, mode_t);
    if (!real) real = dlsym(RTLD_NEXT, "chmod");
    return real(path, mode);
}

int fchmodat(int dirfd, const char *path, mode_t mode, int flags) {
    if (is_target(path)) { errno = EPERM; return -1; }
    static int (*real)(int, const char *, mode_t, int);
    if (!real) real = dlsym(RTLD_NEXT, "fchmodat");
    return real(dirfd, path, mode, flags);
}

int utime(const char *path, const struct utimbuf *times) {
    if (is_target(path)) { errno = EPERM; return -1; }
    static int (*real)(const char *, const struct utimbuf *);
    if (!real) real = dlsym(RTLD_NEXT, "utime");
    return real(path, times);
}

int utimensat(int dirfd, const char *path, const struct timespec times[2], int flags) {
    if (path && is_target(path)) { errno = EPERM; return -1; }
    static int (*real)(int, const char *, const struct timespec *, int);
    if (!real) real = dlsym(RTLD_NEXT, "utimensat");
    return real(dirfd, path, times, flags);
}

int chown(const char *path, uid_t owner, gid_t group) {
    if (is_target(path)) { errno = EPERM; return -1; }
    static int (*real)(const char *, uid_t, gid_t);
    if (!real) real = dlsym(RTLD_NEXT, "chown");
    return real(path, owner, group);
}
SHIM_C
    if cc -shared -fPIC -o "$cf_shim_dir/shim.so" "$cf_shim_dir/shim.c" -ldl \
            >/tmp/fs-k8s-ctx-shim-cc.err 2>&1; then
        # The fixture archive: a real --thread-dir push through a stubbed
        # submit, captured off the stubbed kubectl exec's stdin -- the
        # actual entries-only shape k8s_spool_dir_entries produces, not a
        # re-typed pipeline standing in for it.
        cf_meta_src="$(mktemp -d "/var/tmp/claude-scratch/fs-k8s-test-meta.XXXXXX")"; tmpdirs+=("$cf_meta_src")
        printf 'hello\n' > "$cf_meta_src/foo.txt"
        mkdir -p "$cf_meta_src/sub"
        printf 'world\n' > "$cf_meta_src/sub/bar.txt"
        cf_meta_git="$(newdir)/git"; tmpdirs+=("$(dirname "$cf_meta_git")")
        cat > "$cf_meta_git" <<'STUB'
#!/usr/bin/env bash
case " $* " in
    *" push "*) exit 0 ;;
esac
exec /usr/bin/git "$@"
STUB
        chmod +x "$cf_meta_git"
        cf_meta_kubectl="$(newdir)/kubectl"; tmpdirs+=("$(dirname "$cf_meta_kubectl")")
        cat > "$cf_meta_kubectl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$K8S_STUB_LOG"
verb=""; for arg in "$@"; do case "$arg" in apply|wait|exec|get) verb="$arg" ;; esac; done
case "$verb" in
    apply|wait) cat >/dev/null ;;
    get) printf 'stub-pod\n' ;;
    exec)
        if [[ -n "${K8S_STUB_CAPTURE_TAR:-}" ]] && [[ " $* " == *" ${K8S_STUB_CAPTURE_DEST:-} "* ]]; then
            cat > "$K8S_STUB_CAPTURE_TAR"
        else
            cat >/dev/null
        fi
        ;;
esac
STUB
        chmod +x "$cf_meta_kubectl"
        cf_meta_log="$(newdir)/kubectl.log"; tmpdirs+=("$(dirname "$cf_meta_log")")
        cf_meta_tar="$cf_parent/meta_entries.tar"
        cf_meta_submit_err="$(newdir)/submit.err"; tmpdirs+=("$(dirname "$cf_meta_submit_err")")
        if ! PATH="$(dirname "$cf_meta_git"):$(dirname "$cf_meta_kubectl"):$PATH" \
                K8S_STUB_LOG="$cf_meta_log" K8S_STUB_CAPTURE_DEST="/thread" \
                K8S_STUB_CAPTURE_TAR="$cf_meta_tar" \
                FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit \
                --branch fs-k8s-test-meta-shim --model moonshotai/kimi-k3 \
                --thread-dir "$cf_meta_src" "$proj_dir" "$handoff_file" \
                >"$cf_meta_submit_err" 2>&1; then
            no "the metadata-survives-EPERM fixture's real spool submit succeeds" "$(cat "$cf_meta_submit_err")"
        fi

        # 0777, not 0700: group/other-writable is the shape a kubelet
        # fsGroup-managed emptyDir mount actually has, and it is the shape
        # that made GNU tar attempt the chmod restore in the first place
        # (a 0700 pre-existing dest never triggers that attempt at all,
        # which is exactly how the old, buggy test above passed).
        cf_meta_dest="$cf_parent/meta_dest"
        mkdir -p "$cf_meta_dest"
        chmod 0777 "$cf_meta_dest"
        cf_meta_extract_err="$(newdir)/extract.err"; tmpdirs+=("$(dirname "$cf_meta_extract_err")")
        if FS_K8S_TEST_SHIM_TARGET="." LD_PRELOAD="$cf_shim_dir/shim.so" \
                "$context_extract_sh" "$cf_meta_dest" 100000000 < "$cf_meta_tar" \
                >"$cf_meta_extract_err" 2>&1; then
            ok "an existing DEST_DIR's own metadata survives extraction under denied chmod/utime/chown"
        else
            no "an existing DEST_DIR's own metadata survives extraction under denied chmod/utime/chown" \
                "$(cat "$cf_meta_extract_err")"
        fi
        cf_meta_mode="$(stat -c '%a' "$cf_meta_dest")"
        if [[ "$cf_meta_mode" == "777" ]]; then
            ok "an existing DEST_DIR's own permission bits are untouched under denied chmod/utime/chown"
        else
            no "an existing DEST_DIR's own permission bits are untouched under denied chmod/utime/chown" \
                "mode is $cf_meta_mode, expected 777"
        fi
        if [[ "$(cat "$cf_meta_dest/foo.txt" 2>/dev/null)" == "hello" \
            && "$(cat "$cf_meta_dest/sub/bar.txt" 2>/dev/null)" == "world" ]]; then
            ok "an existing DEST_DIR: the entries-only archive's files still land inside it"
        else
            no "an existing DEST_DIR: the entries-only archive's files still land inside it" \
                "$(find "$cf_meta_dest" 2>&1)"
        fi
    else
        printf '  SKIP  metadata-survives-EPERM test: could not compile the LD_PRELOAD shim\n'
        printf '        %s\n' "$(cat /tmp/fs-k8s-ctx-shim-cc.err)"
    fi
    rm -f /tmp/fs-k8s-ctx-shim-cc.err
else
    printf '  SKIP  metadata-survives-EPERM test: no C compiler (cc) on PATH\n'
fi

# An existing NON-empty DEST_DIR is still refused: a second push must not
# merge into a first.
cf_nonempty_dest="$cf_parent/nonempty_dest"
mkdir -p "$cf_nonempty_dest"
touch "$cf_nonempty_dest/already-here.txt"
refuses "an existing NON-EMPTY DEST_DIR is refused" \
    "already exists and is not empty; refusing" \
    "$context_extract_sh" "$cf_nonempty_dest" 100000000 < "$cf_wf_tar"

# absolute path: refused outright, whole archive, before anything is
# extracted -- the dest directory must not even be created.
cf_abs_src="$(newdir)"; tmpdirs+=("$cf_abs_src")
mkdir -p "$cf_abs_src/a"
printf 'x\n' > "$cf_abs_src/a/f.txt"
cf_abs_parent="$(newdir)"; tmpdirs+=("$cf_abs_parent")
cf_abs_tar="$cf_abs_parent/abs.tar"
( cd "$cf_abs_src" && tar -P -cf "$cf_abs_tar" "$cf_abs_src/a/f.txt" 2>/dev/null )
cf_abs_dest="$cf_abs_parent/abs_dest"
refuses "absolute path is refused" \
    "contains an absolute path" \
    "$context_extract_sh" "$cf_abs_dest" 100000000 < "$cf_abs_tar"
if [[ ! -e "$cf_abs_dest" ]]; then
    ok "absolute-path archive: nothing is extracted"
else
    no "absolute-path archive: nothing is extracted" "$cf_abs_dest exists"
fi

# `..` path component: same refuse-the-whole-archive treatment.
cf_dd_src="$(newdir)"; tmpdirs+=("$cf_dd_src")
mkdir -p "$cf_dd_src/a"
printf 'x\n' > "$cf_dd_src/a/f.txt"
cf_dd_parent="$(newdir)"; tmpdirs+=("$cf_dd_parent")
cf_dd_tar="$cf_dd_parent/dd.tar"
( cd "$cf_dd_src" && tar -P -cf "$cf_dd_tar" a/../a/f.txt 2>/dev/null )
cf_dd_dest="$cf_dd_parent/dd_dest"
refuses "a '..' path component is refused" \
    "contains a '..' path component" \
    "$context_extract_sh" "$cf_dd_dest" 100000000 < "$cf_dd_tar"
if [[ ! -e "$cf_dd_dest" ]]; then
    ok "'..'-component archive: nothing is extracted"
else
    no "'..'-component archive: nothing is extracted" "$cf_dd_dest exists"
fi

# symlink: refused as a link entry, listed and rejected before extraction
# even starts.
cf_sym_src="$(newdir)"; tmpdirs+=("$cf_sym_src")
ln -s /etc/passwd "$cf_sym_src/evil"
cf_sym_parent="$(newdir)"; tmpdirs+=("$cf_sym_parent")
cf_sym_tar="$cf_sym_parent/sym.tar"
tar cf "$cf_sym_tar" -C "$cf_sym_src" .
cf_sym_dest="$cf_sym_parent/sym_dest"
refuses "a symlink entry is refused" \
    "contains a link entry" \
    "$context_extract_sh" "$cf_sym_dest" 100000000 < "$cf_sym_tar"
if [[ ! -e "$cf_sym_dest" ]]; then
    ok "symlink archive: nothing is extracted"
else
    no "symlink archive: nothing is extracted" "$cf_sym_dest exists"
fi

# hard link: a distinct code path from the symlink check above.
cf_hl_src="$(newdir)"; tmpdirs+=("$cf_hl_src")
printf 'x\n' > "$cf_hl_src/f.txt"
ln "$cf_hl_src/f.txt" "$cf_hl_src/g.txt"
cf_hl_parent="$(newdir)"; tmpdirs+=("$cf_hl_parent")
cf_hl_tar="$cf_hl_parent/hl.tar"
tar cf "$cf_hl_tar" -C "$cf_hl_src" .
cf_hl_dest="$cf_hl_parent/hl_dest"
refuses "a hard-link entry is refused" \
    "contains a link entry" \
    "$context_extract_sh" "$cf_hl_dest" 100000000 < "$cf_hl_tar"
if [[ ! -e "$cf_hl_dest" ]]; then
    ok "hard-link archive: nothing is extracted"
else
    no "hard-link archive: nothing is extracted" "$cf_hl_dest exists"
fi

# oversized: refused on the spooled byte-size cap, before tar -tvf is even
# run over it.
cf_big_src="$(newdir)"; tmpdirs+=("$cf_big_src")
dd if=/dev/zero of="$cf_big_src/big.bin" bs=1M count=2 2>/dev/null
cf_big_parent="$(newdir)"; tmpdirs+=("$cf_big_parent")
cf_big_tar="$cf_big_parent/big.tar"
tar cf "$cf_big_tar" -C "$cf_big_src" .
cf_big_dest="$cf_big_parent/big_dest"
refuses "an over-cap archive is refused" \
    "byte cap; refusing it" \
    "$context_extract_sh" "$cf_big_dest" 100 < "$cf_big_tar"
if [[ ! -e "$cf_big_dest" ]]; then
    ok "over-cap archive: nothing is extracted"
else
    no "over-cap archive: nothing is extracted" "$cf_big_dest exists"
fi

# the same small archive under a generous cap still extracts -- confirms
# the cap check compares against the given MAX_BYTES, not a hidden default.
cf_hi_dest="$cf_parent/wf_dest_hi"
if "$context_extract_sh" "$cf_hi_dest" 1000000 < "$cf_wf_tar" \
        >/tmp/fs-k8s-ctx-hi.err 2>&1; then
    ok "the same well-formed archive extracts under a generous cap"
else
    no "the same well-formed archive extracts under a generous cap" "$(cat /tmp/fs-k8s-ctx-hi.err)"
fi
rm -f /tmp/fs-k8s-ctx-hi.err

# The 256 MiB literal on this stdin/kubectl-exec path cannot be raised by
# MAX_BYTES, however large -- there is deliberately no env var for that (see
# fork-sandbox-k8s-context-extract.sh's own header): a caller able to set an
# env var alongside MAX_BYTES on this path could raise its own ceiling, and
# the whole point of the literal is that it cannot. First, a small archive
# still extracts when MAX_BYTES is far above the literal -- clamping lowers
# the effective cap, it does not error out just because the caller asked
# for more than the literal allows.
cf_big_max_dest="$cf_parent/wf_dest_big_max"
if "$context_extract_sh" "$cf_big_max_dest" 100000000000 < "$cf_wf_tar" \
        >/tmp/fs-k8s-ctx-bigmax.err 2>&1; then
    ok "a small archive extracts under a MAX_BYTES far above the literal"
else
    no "a small archive extracts under a MAX_BYTES far above the literal" \
        "$(cat /tmp/fs-k8s-ctx-bigmax.err)"
fi
rm -f /tmp/fs-k8s-ctx-bigmax.err

# Second, an archive over the literal but comfortably under MAX_BYTES is
# still refused -- proving the clamp itself needs a real >256 MiB fixture,
# since there is no longer a way to shrink the literal for a cheap one.
# Sparse and removed the moment this assertion completes, the same as the
# of_huge_* fixture above: /tmp is a tmpfs, and this is the only place left
# in the suite that needs a fixture this size.
cf_clamp_src="$(newdir)"; tmpdirs+=("$cf_clamp_src")
truncate -s 257M "$cf_clamp_src/big.bin"
cf_clamp_parent="$(newdir)"; tmpdirs+=("$cf_clamp_parent")
cf_clamp_tar="$cf_clamp_parent/clamp.tar"
tar cf "$cf_clamp_tar" -C "$cf_clamp_src" .
cf_clamp_dest="$cf_clamp_parent/clamp_dest"
refuses "a MAX_BYTES far above the literal is still clamped down to it" \
    "byte cap; refusing it" \
    "$context_extract_sh" "$cf_clamp_dest" 100000000000 < "$cf_clamp_tar"
if [[ ! -e "$cf_clamp_dest" ]]; then
    ok "clamped-to-literal archive: nothing is extracted"
else
    no "clamped-to-literal archive: nothing is extracted" "$cf_clamp_dest exists"
fi
rm -rf -- "$cf_clamp_src" "$cf_clamp_parent"

# git disables the ext:: transport by default, so a push or fetch built
# without -c protocol.ext.allow=always fails at the git layer with 'fatal:
# transport "ext" not allowed' -- a real cluster confirmed this. This is a
# static assertion on the source rather than a live push/fetch, which no
# cluster here can exercise, but it is exactly the kind of check that stops
# a future refactor from silently dropping the flag on one of the two paths.
if grep -qE 'git -c protocol\.ext\.allow=always .*push' "$k8s_sh"; then
    ok "submit's git push scopes protocol.ext.allow=always"
else
    no "submit's git push scopes protocol.ext.allow=always" "not found in $k8s_sh"
fi
if grep -qE 'git -c protocol\.ext\.allow=always .*fetch' "$k8s_sh"; then
    ok "fetch's git fetch scopes protocol.ext.allow=always"
else
    no "fetch's git fetch scopes protocol.ext.allow=always" "not found in $k8s_sh"
fi
# This push and this fetch both run ON THE HOST, in a repo named on the
# command line, and git would otherwise run that repo's own hooks --
# pre-push on the push side, reference-transaction on the fetch side, since
# fetch here writes straight into refs/heads/$branch rather than a
# remote-tracking ref (githooks(5): reference-transaction "is invoked by any
# Git command that performs reference updates"). Scoped the same way as
# protocol.ext.allow=always, and checked the same way here.
if grep -qE 'git -c protocol\.ext\.allow=always -c core\.hooksPath=/dev/null push' "$k8s_sh"; then
    ok "submit's git push scopes core.hooksPath=/dev/null"
else
    no "submit's git push scopes core.hooksPath=/dev/null" "not found in $k8s_sh"
fi
if grep -qE 'git -c protocol\.ext\.allow=always -c core\.hooksPath=/dev/null fetch' "$k8s_sh"; then
    ok "fetch's git fetch scopes core.hooksPath=/dev/null"
else
    no "fetch's git fetch scopes core.hooksPath=/dev/null" "not found in $k8s_sh"
fi
if grep -qE 'kubectl.*exec -t' "$k8s_sh"; then
    no "no kubectl exec uses -t (would corrupt the pack stream)" "found in $k8s_sh"
else
    ok "no kubectl exec uses -t (would corrupt the pack stream)"
fi

printf '\n== fork-sandbox-k8s-review-loop.sh: control flow (no cluster) ==\n'
# Driven directly against a scratch git repo, with PI_BIN pointed at a tiny
# stub that reads the prompt off stdin (discarded) and writes a canned
# verdict / commit per the test's own logic. No cluster, no pod, no real pi
# -- this is the same reason fork-sandbox-k8s-inbox-write.sh's own section
# above runs the real script directly rather than re-implementing its logic
# in the test.
rl_sh="$repo_dir/scripts/fork-sandbox-k8s-review-loop.sh"

# A fresh one-commit-past-base git repo, with review-prompt.md/fix-header.md
# fixtures (their content is irrelevant to the control flow under test --
# the stub ignores stdin) and a work dir for the loop's own artifacts.
# Returns "repo base_sha work_dir review_prompt fix_header out" on stdout,
# callers split with `read`. The fixture's own root is `dirname "$repo"`,
# which is what callers register with tmpdirs for cleanup.
new_rl_fixture() {
    local d repo base_sha work
    d="$(mktemp -d /var/tmp/claude-scratch/fs-k8s-rl-test.XXXXXX)"
    repo="$d/repo"
    mkdir -p "$repo"
    git -C "$repo" init -q
    git -C "$repo" config user.email t@fork-sandbox.invalid
    git -C "$repo" config user.name Tester
    git -C "$repo" -c user.email=t@fork-sandbox.invalid -c user.name=Tester \
        commit -q --allow-empty -m init
    base_sha="$(git -C "$repo" rev-parse --verify --quiet HEAD)"
    git -C "$repo" -c user.email=t@fork-sandbox.invalid -c user.name=Tester \
        commit -q --allow-empty -m "the coding leg's work"
    printf 'review prompt fixture\n' > "$d/review-prompt.md"
    printf 'fix header fixture\n' > "$d/fix-header.md"
    work="$d/work"
    printf '%s %s %s %s %s %s\n' "$repo" "$base_sha" "$work" \
        "$d/review-prompt.md" "$d/fix-header.md" "$d/review-loop.json"
}

# jq -r '.ended' / '.iterations | length' / '.iterations[N].FIELD' against
# the written review-loop.json, for terse assertions below.
rl_json() { jq -r "$2" "$1" 2>/dev/null; }

printf '\n-- approved on the first review --\n'
stub_dir="$(mktemp -d /var/tmp/claude-scratch/fs-k8s-rl-stub.XXXXXX)"; tmpdirs+=("$stub_dir")
cat > "$stub_dir/pi-approve" <<'STUB'
#!/bin/sh
cat >/dev/null
printf 'APPROVED\n\n## Report\nThe branch is sound.\n' > "$RL_TEST_VERDICT"
exit 0
STUB
chmod +x "$stub_dir/pi-approve"
read -r repo base_sha work review_prompt fix_header out < <(new_rl_fixture)
tmpdirs+=("$(dirname "$repo")")
RL_TEST_VERDICT="$repo/.git/review-verdict.md" PI_BIN="$stub_dir/pi-approve" MODEL=test-model \
    "$rl_sh" --clone "$repo" --cap 2 --base-sha "$base_sha" \
    --review-prompt "$review_prompt" --fix-header "$fix_header" \
    --verdict "$repo/.git/review-verdict.md" --work-dir "$work" --out "$out" \
    >/dev/null 2>&1
check "approved: ended=approved" "approved" "$(rl_json "$out" '.ended')"
check "approved: one iteration recorded" "1" "$(rl_json "$out" '.iterations | length')"
check "approved: findings=0" "0" "$(rl_json "$out" '.iterations[0].findings')"

printf '\n-- malformed present report section --\n'
stub_dir_malformed="$(mktemp -d /var/tmp/claude-scratch/fs-k8s-rl-stub.XXXXXX)"; tmpdirs+=("$stub_dir_malformed")
cat > "$stub_dir_malformed/pi-malformed" <<'STUB'
#!/bin/sh
cat >/dev/null
printf 'APPROVED\n\nChecked: useful evidence.\n\n## Report\n' > "$RL_TEST_VERDICT"
exit 0
STUB
chmod +x "$stub_dir_malformed/pi-malformed"
read -r repo base_sha work review_prompt fix_header out < <(new_rl_fixture)
tmpdirs+=("$(dirname "$repo")")
RL_TEST_VERDICT="$repo/.git/review-verdict.md" PI_BIN="$stub_dir_malformed/pi-malformed" MODEL=test-model \
    "$rl_sh" --clone "$repo" --cap 2 --base-sha "$base_sha" \
    --review-prompt "$review_prompt" --fix-header "$fix_header" \
    --verdict "$repo/.git/review-verdict.md" --work-dir "$work" --out "$out" \
    >/dev/null 2>&1
check "malformed report: still ended=approved" "approved" "$(rl_json "$out" '.ended')"

printf '\n-- approved without a report section --\n'
stub_dir_no_report="$(mktemp -d /var/tmp/claude-scratch/fs-k8s-rl-stub.XXXXXX)"; tmpdirs+=("$stub_dir_no_report")
cat > "$stub_dir_no_report/pi-approve-no-report" <<'STUB'
#!/bin/sh
cat >/dev/null
printf 'APPROVED\n\nThe branch is sound.\n' > "$RL_TEST_VERDICT"
exit 0
STUB
chmod +x "$stub_dir_no_report/pi-approve-no-report"
read -r repo base_sha work review_prompt fix_header out < <(new_rl_fixture)
tmpdirs+=("$(dirname "$repo")")
RL_TEST_VERDICT="$repo/.git/review-verdict.md" PI_BIN="$stub_dir_no_report/pi-approve-no-report" MODEL=test-model \
    "$rl_sh" --clone "$repo" --cap 2 --base-sha "$base_sha" \
    --review-prompt "$review_prompt" --fix-header "$fix_header" \
    --verdict "$repo/.git/review-verdict.md" --work-dir "$work" --out "$out" \
    >/dev/null 2>&1
check "approved without report: ended=approved" "approved" "$(rl_json "$out" '.ended')"

printf '\n-- findings, then a fix leg that makes progress --\n'
stub_dir2="$(mktemp -d /var/tmp/claude-scratch/fs-k8s-rl-stub.XXXXXX)"; tmpdirs+=("$stub_dir2")
read -r repo base_sha work review_prompt fix_header out < <(new_rl_fixture)
tmpdirs+=("$(dirname "$repo")")
counter_file="$stub_dir2/count"
cat > "$stub_dir2/pi-dispatch" <<STUB
#!/bin/sh
cat >/dev/null
n=0
[ -f "$counter_file" ] && n=\$(cat "$counter_file")
n=\$((n + 1))
echo \$n > "$counter_file"
if [ \$((n % 2)) -eq 1 ]; then
    printf 'FINDINGS\n\nsomething is wrong at foo.c:12\n\n## Report\nThe review found one issue.\n' > "\$RL_TEST_VERDICT"
else
    git -C "$repo" -c user.email=t@fork-sandbox.invalid -c user.name=Tester \\
        commit -q --allow-empty -m "fix \$n"
fi
exit 0
STUB
chmod +x "$stub_dir2/pi-dispatch"
RL_TEST_VERDICT="$repo/.git/review-verdict.md" PI_BIN="$stub_dir2/pi-dispatch" MODEL=test-model \
    "$rl_sh" --clone "$repo" --cap 2 --base-sha "$base_sha" \
    --review-prompt "$review_prompt" --fix-header "$fix_header" \
    --verdict "$repo/.git/review-verdict.md" --work-dir "$work" --out "$out" \
    >/dev/null 2>&1
check "progress: ended=cap (findings still open after 2 iterations)" \
    "cap" "$(rl_json "$out" '.ended')"
check "progress: iteration 1 findings=1" "1" "$(rl_json "$out" '.iterations[0].findings')"
check "progress: iteration 1 head_after != head_before" "true" \
    "$(rl_json "$out" 'if .iterations[0].head_after != .iterations[0].head_before then "true" else "false" end')"
check "progress: iteration 1 commits_added=1" "1" "$(rl_json "$out" '.iterations[0].commits_added')"
if [[ -f "$work/fix-prompt-1.md" ]] && grep -qF 'fix header fixture' "$work/fix-prompt-1.md" \
    && grep -qF 'something is wrong at foo.c:12' "$work/fix-prompt-1.md"; then
    ok "the fix prompt concatenates the fix header and the verdict"
else
    no "the fix prompt concatenates the fix header and the verdict" \
        "$(cat "$work/fix-prompt-1.md" 2>/dev/null)"
fi

printf '\n-- findings without a report section --\n'
stub_dir_no_report_findings="$(mktemp -d /var/tmp/claude-scratch/fs-k8s-rl-stub.XXXXXX)"; tmpdirs+=("$stub_dir_no_report_findings")
read -r repo base_sha work review_prompt fix_header out < <(new_rl_fixture)
tmpdirs+=("$(dirname "$repo")")
cat > "$stub_dir_no_report_findings/pi-findings-no-report" <<STUB
#!/bin/sh
prompt=\$(cat)
n=0
[ -f "$stub_dir_no_report_findings/count" ] && n=\$(cat "$stub_dir_no_report_findings/count")
n=\$((n + 1))
echo \$n > "$stub_dir_no_report_findings/count"
if [ \$n -eq 1 ]; then
    printf 'FINDINGS\n\nfoo.c:12 first issue\n\nbar.c:34 second issue\n' > "\$RL_TEST_VERDICT"
    exit 0
fi
case "\$prompt" in
    *'foo.c:12 first issue'*'bar.c:34 second issue'*)
        git -C "$repo" -c user.email=t@fork-sandbox.invalid -c user.name=Tester \
            commit -q --allow-empty -m fix
        printf '{"type":"result","subtype":"success","total_cost_usd":0.01,"usage":{"input_tokens":100,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}\n'
        exit 0 ;;
    *) exit 1 ;;
esac
STUB
chmod +x "$stub_dir_no_report_findings/pi-findings-no-report"
RL_TEST_VERDICT="$repo/.git/review-verdict.md" PI_BIN="$stub_dir_no_report_findings/pi-findings-no-report" MODEL=test-model \
    "$rl_sh" --clone "$repo" --cap 1 --base-sha "$base_sha" \
    --review-prompt "$review_prompt" --fix-header "$fix_header" \
    --verdict "$repo/.git/review-verdict.md" --work-dir "$work" --out "$out" \
    >/dev/null 2>&1
check "findings without report: ended=cap" "cap" "$(rl_json "$out" '.ended')"
check "findings without report: counts two cited paragraphs" "2" \
    "$(rl_json "$out" '.iterations[0].findings')"
if grep -qF 'foo.c:12 first issue' "$work/fix-prompt-1.md" \
    && grep -qF 'bar.c:34 second issue' "$work/fix-prompt-1.md"; then
    ok "findings without report: fix prompt carries the verdict"
else
    no "findings without report: fix prompt carries the verdict" \
        "$(cat "$work/fix-prompt-1.md" 2>/dev/null)"
fi

printf '\n-- no-progress: the fix leg commits nothing --\n'
stub_dir3="$(mktemp -d /var/tmp/claude-scratch/fs-k8s-rl-stub.XXXXXX)"; tmpdirs+=("$stub_dir3")
read -r repo base_sha work review_prompt fix_header out < <(new_rl_fixture)
tmpdirs+=("$(dirname "$repo")")
cat > "$stub_dir3/pi-findings-only" <<'STUB'
#!/bin/sh
cat >/dev/null
printf 'FINDINGS\n\nsomething is wrong at foo.c:12\n\n## Report\nThe review found one issue.\n' > "$RL_TEST_VERDICT"
exit 0
STUB
chmod +x "$stub_dir3/pi-findings-only"
RL_TEST_VERDICT="$repo/.git/review-verdict.md" PI_BIN="$stub_dir3/pi-findings-only" MODEL=test-model \
    "$rl_sh" --clone "$repo" --cap 3 --base-sha "$base_sha" \
    --review-prompt "$review_prompt" --fix-header "$fix_header" \
    --verdict "$repo/.git/review-verdict.md" --work-dir "$work" --out "$out" \
    >/dev/null 2>&1
check "no-progress: ended=no-progress" "no-progress" "$(rl_json "$out" '.ended')"
check "no-progress: exactly one iteration ran" "1" "$(rl_json "$out" '.iterations | length')"

printf '\n-- harness-error: neither APPROVED nor FINDINGS --\n'
stub_dir4="$(mktemp -d /var/tmp/claude-scratch/fs-k8s-rl-stub.XXXXXX)"; tmpdirs+=("$stub_dir4")
read -r repo base_sha work review_prompt fix_header out < <(new_rl_fixture)
tmpdirs+=("$(dirname "$repo")")
cat > "$stub_dir4/pi-garbage" <<'STUB'
#!/bin/sh
cat >/dev/null
printf 'this is not a verdict\n' > "$RL_TEST_VERDICT"
exit 0
STUB
chmod +x "$stub_dir4/pi-garbage"
RL_TEST_VERDICT="$repo/.git/review-verdict.md" PI_BIN="$stub_dir4/pi-garbage" MODEL=test-model \
    "$rl_sh" --clone "$repo" --cap 2 --base-sha "$base_sha" \
    --review-prompt "$review_prompt" --fix-header "$fix_header" \
    --verdict "$repo/.git/review-verdict.md" --work-dir "$work" --out "$out" \
    >/dev/null 2>&1
check "bad first line: ended=harness-error" "harness-error" "$(rl_json "$out" '.ended')"

printf '\n-- harness-error: the review leg writes no verdict at all --\n'
stub_dir5="$(mktemp -d /var/tmp/claude-scratch/fs-k8s-rl-stub.XXXXXX)"; tmpdirs+=("$stub_dir5")
read -r repo base_sha work review_prompt fix_header out < <(new_rl_fixture)
tmpdirs+=("$(dirname "$repo")")
cat > "$stub_dir5/pi-silent" <<'STUB'
#!/bin/sh
cat >/dev/null
exit 0
STUB
chmod +x "$stub_dir5/pi-silent"
RL_TEST_VERDICT="$repo/.git/review-verdict.md" PI_BIN="$stub_dir5/pi-silent" MODEL=test-model \
    "$rl_sh" --clone "$repo" --cap 2 --base-sha "$base_sha" \
    --review-prompt "$review_prompt" --fix-header "$fix_header" \
    --verdict "$repo/.git/review-verdict.md" --work-dir "$work" --out "$out" \
    >/dev/null 2>&1
check "no verdict written: ended=harness-error" "harness-error" "$(rl_json "$out" '.ended')"

printf '\n-- harness-error: a SYMLINK at the verdict path is refused --\n'
stub_dir6="$(mktemp -d /var/tmp/claude-scratch/fs-k8s-rl-stub.XXXXXX)"; tmpdirs+=("$stub_dir6")
read -r repo base_sha work review_prompt fix_header out < <(new_rl_fixture)
rl_fixture_dir6="$(dirname "$repo")"; tmpdirs+=("$rl_fixture_dir6")
secret_target="$rl_fixture_dir6/secret-target"
printf 'this must never be read\n' > "$secret_target"
cat > "$stub_dir6/pi-symlink" <<STUB
#!/bin/sh
cat >/dev/null
ln -sf "$secret_target" "\$RL_TEST_VERDICT"
exit 0
STUB
chmod +x "$stub_dir6/pi-symlink"
RL_TEST_VERDICT="$repo/.git/review-verdict.md" PI_BIN="$stub_dir6/pi-symlink" MODEL=test-model \
    "$rl_sh" --clone "$repo" --cap 2 --base-sha "$base_sha" \
    --review-prompt "$review_prompt" --fix-header "$fix_header" \
    --verdict "$repo/.git/review-verdict.md" --work-dir "$work" --out "$out" \
    >/dev/null 2>&1
check "symlinked verdict: ended=harness-error" "harness-error" "$(rl_json "$out" '.ended')"
# A copy is only ever made AFTER the symlink check passes, so no
# review-verdict-*.md copy existing at all is itself proof the target was
# never read -- but check any that do exist too, in case that invariant
# ever regresses silently.
secret_leaked=false
while IFS= read -r verdict_copy_file; do
    [[ -n "$verdict_copy_file" ]] || continue
    grep -qF 'this must never be read' "$verdict_copy_file" 2>/dev/null && secret_leaked=true
done < <(find "$work" -maxdepth 1 -name 'review-verdict-*.md' 2>/dev/null)
if [[ "$secret_leaked" == true ]]; then
    no "symlinked verdict: the symlink target is never read" \
        "the secret target's content leaked into $work"
else
    ok "symlinked verdict: the symlink target is never read"
fi

printf '\n-- skipped: branch head already at --base-sha --\n'
stub_dir7="$(mktemp -d /var/tmp/claude-scratch/fs-k8s-rl-stub.XXXXXX)"; tmpdirs+=("$stub_dir7")
read -r repo base_sha work review_prompt fix_header out < <(new_rl_fixture)
tmpdirs+=("$(dirname "$repo")")
current_head="$(git -C "$repo" rev-parse --verify --quiet HEAD)"
RL_TEST_VERDICT="$repo/.git/review-verdict.md" PI_BIN="$stub_dir7/should-never-run" MODEL=test-model \
    "$rl_sh" --clone "$repo" --cap 2 --base-sha "$current_head" \
    --review-prompt "$review_prompt" --fix-header "$fix_header" \
    --verdict "$repo/.git/review-verdict.md" --work-dir "$work" --out "$out" \
    >/dev/null 2>&1
check "skipped: ended=skipped" "skipped" "$(rl_json "$out" '.ended')"
check "skipped: no iterations ran" "0" "$(rl_json "$out" '.iterations | length')"


printf '\n== fs_require_scratch_handoff / fs_require_src_project (fork-sandbox-lib.sh) ==\n'
# Unit-level, sourcing the lib directly -- the same level fork-sandbox-clone-
# test.sh tests fs_make_clone at. These are the two checks that let
# fork-sandbox.sh be blanket-approved as its own security boundary, shared
# between the local path and --k8s below; a regression here would silently
# widen what either path accepts. lib_sh was already sourced near the top of
# this file.
lib_test_scratch_dir="$(mktemp -d /var/tmp/claude-scratch/fs-k8s-flag-lib-test.XXXXXX)"
tmpdirs+=("$lib_test_scratch_dir")
err="$(mktemp)"

if fs_require_scratch_handoff "$lib_test_scratch_dir/handoff.md" 2>"$err"; then
    ok "a scratch-dir handoff accepted"
else
    no "a scratch-dir handoff accepted" "$(cat "$err")"
fi
if fs_require_scratch_handoff "/tmp/outside-scratch/handoff.md" 2>"$err"; then
    no "a handoff outside scratch is refused"
else
    case "$(cat "$err")" in
        *"must live under /var/tmp/claude-scratch"*)
            ok "a handoff outside scratch is refused" ;;
        *) no "a handoff outside scratch is refused" "$(cat "$err")" ;;
    esac
fi
if fs_require_scratch_handoff "/var/tmp/claude-scratch/forks/x/handoff.md" 2>"$err"; then
    no "a handoff under forks/ is refused"
else
    case "$(cat "$err")" in
        *"must not live under the forks/"*)
            ok "a handoff under forks/ is refused" ;;
        *) no "a handoff under forks/ is refused" "$(cat "$err")" ;;
    esac
fi
if fs_require_src_project "$HOME/src/anything" 2>"$err"; then
    ok "a ~/src project is accepted"
else
    no "a ~/src project is accepted" "$(cat "$err")"
fi
if fs_require_src_project "/tmp/outside-src" 2>"$err"; then
    no "a project outside ~/src is refused"
else
    case "$(cat "$err")" in
        *"must live under ~/src"*)
            ok "a project outside ~/src is refused" ;;
        *) no "a project outside ~/src is refused" "$(cat "$err")" ;;
    esac
fi

# ~/src as a symlink (the cluster postmaster's pod links it onto its data
# volume): a project inside it is accepted, a link inside ~/src pointing
# outward is still refused.
srclink_home="$(mktemp -d /var/tmp/claude-scratch/fs-k8s-srclink-test.XXXXXX)"
tmpdirs+=("$srclink_home")
mkdir -p "$srclink_home/home" "$srclink_home/vol/src/proj" "$srclink_home/outside/evil"
ln -s "$srclink_home/vol/src" "$srclink_home/home/src"
ln -s "$srclink_home/outside/evil" "$srclink_home/vol/src/escape"
if HOME="$srclink_home/home" fs_require_src_project "$srclink_home/home/src/proj" 2>"$err"; then
    ok "a project under a symlinked ~/src is accepted"
else
    no "a project under a symlinked ~/src is accepted" "$(cat "$err")"
fi
if HOME="$srclink_home/home" fs_require_src_project "$srclink_home/home/src/escape" 2>"$err"; then
    no "a link inside a symlinked ~/src that points outside is refused"
else
    case "$(cat "$err")" in
        *"must live under ~/src"*)
            ok "a link inside a symlinked ~/src that points outside is refused" ;;
        *) no "a link inside a symlinked ~/src that points outside is refused" "$(cat "$err")" ;;
    esac
fi
rm -f "$err"

printf '\n== fs_parse_size_bytes (fork-sandbox-lib.sh) ==\n'
# Unit-level, sourcing the lib directly -- the one place --outbox-max's
# accepted units and rejections are defined, shared by fork-sandbox.sh and
# fork-sandbox-k8s.sh below rather than each parsing it their own way.
check "bare digits mean bytes" "12345" "$(fs_parse_size_bytes 12345)"
check "K means KiB" "$((512 * 1024))" "$(fs_parse_size_bytes 512K)"
check "a lowercase k also means KiB" "$((512 * 1024))" "$(fs_parse_size_bytes 512k)"
check "M means MiB" "$((256 * 1024 * 1024))" "$(fs_parse_size_bytes 256M)"
check "G means GiB" "$((2 * 1024 * 1024 * 1024))" "$(fs_parse_size_bytes 2G)"

err_file="$(mktemp)"
for bad in "" 0 0K -5 5.5M 5MB M garbage; do
    if out="$(fs_parse_size_bytes "$bad" 2>"$err_file")"; then
        no "'$bad' is rejected" "accepted, got '$out'"
    else
        ok "'$bad' is rejected"
    fi
done
if fs_parse_size_bytes garbage 2>"$err_file"; then
    no "a bad value's error names what was given"
else
    case "$(cat "$err_file")" in
        *"'garbage'"*) ok "a bad value's error names what was given" ;;
        *) no "a bad value's error names what was given" "$(cat "$err_file")" ;;
    esac
fi
if fs_parse_size_bytes 0 2>"$err_file"; then
    no "0 is rejected with a message naming it"
else
    case "$(cat "$err_file")" in
        *"'0'"*) ok "0 is rejected with a message naming it" ;;
        *) no "0 is rejected with a message naming it" "$(cat "$err_file")" ;;
    esac
fi
rm -f "$err_file"

printf '\n== fork-sandbox.sh --k8s (fixture config, no cluster) ==\n'
# Real fixtures: unlike --dry-run's own local exit, fs_require_scratch_handoff
# and fs_require_src_project run for every --k8s call, including a --dry-run
# one, so a placeholder path is refused rather than ignored. Only the flag-
# refusal cases below get away with a placeholder -- each fails on its own
# flag before reaching these checks. new_src_project mirrors fork-sandbox-
# prompt-overlay-test.sh's own fixture: a real git repo under the real
# ~/src, since that is the one root fork-sandbox.sh accepts a project from.
# On every real operator machine ~/src already exists (fork-sandbox's own
# security boundary requires it for any real use), so this mkdir -p is a
# no-op there; it only actually creates anything under a from-scratch HOME
# with no prior fork-sandbox history, which this suite must also pass under.
mkdir -p "$HOME/src"
new_src_project() {
    local d
    d="$(mktemp -d "$HOME/src/fs-k8s-flag-test.XXXXXX")"
    (
        cd "$d" \
            && git init -q . \
            && git config user.email t@fork-sandbox.invalid \
            && git config user.name Tester \
            && printf 'hello\n' > file.txt \
            && git add file.txt \
            && git commit -q -m init
    ) >/dev/null 2>&1
    printf '%s' "$d"
}
k8s_flag_proj="$(new_src_project)"; tmpdirs+=("$k8s_flag_proj")
# A project fixture rooted under claude_home's own $HOME/src, not the real
# one -- fs_require_src_project checks the project path against $HOME/src
# at call time, so a --harness claude case run with HOME="$claude_home" (to
# pick up its fixture credential) needs a project under that same fixture
# HOME, not the real one k8s_flag_proj lives under.
mkdir -p "$claude_home/src"
k8s_flag_claude_proj="$(HOME="$claude_home" new_src_project)"; tmpdirs+=("$k8s_flag_claude_proj")
k8s_flag_handoff_dir="$(mktemp -d /var/tmp/claude-scratch/fs-k8s-flag-test.XXXXXX)"
tmpdirs+=("$k8s_flag_handoff_dir")
k8s_flag_handoff="$k8s_flag_handoff_dir/handoff.md"
printf 'Do the k8s thing.\n' > "$k8s_flag_handoff"

# A model-less pi --k8s run passes the launcher on ANY install: the
# endpoint question belongs to fork-sandbox-k8s.sh's install-mode-aware
# validation, and on a legacy K8S_PROXY_UPSTREAM install the refusal is
# its run verb's own -- after the launcher's project/handoff checks, so
# this case needs the real fixtures, not the placeholders the flag-
# refusal cases use.
refuses "--k8s with no --harness and no --model on a legacy install is refused by fork-sandbox-k8s.sh" \
    "run requires --model" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    "$k8s_flag_proj" "$k8s_flag_handoff"
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --model moonshotai/kimi-k3 --branch fs-k8s-flag-test-default-harness \
    "$k8s_flag_proj" "$k8s_flag_handoff" \
    > /dev/null 2>/tmp/fs-k8s-flag-test-default-harness.err; then
    ok "--k8s with no --harness defaults to pi"
else
    no "--k8s with no --harness defaults to pi" \
        "$(cat /tmp/fs-k8s-flag-test-default-harness.err)"
fi
rm -f /tmp/fs-k8s-flag-test-default-harness.err
if HOME="$claude_home" FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness claude --model claude-sonnet-5 \
    --branch fs-k8s-flag-test-claude-harness \
    "$k8s_flag_claude_proj" "$k8s_flag_handoff" \
    > /dev/null 2>/tmp/fs-k8s-flag-test-claude-harness.err; then
    ok "--k8s --harness claude is accepted"
else
    no "--k8s --harness claude is accepted" \
        "$(cat /tmp/fs-k8s-flag-test-claude-harness.err)"
fi
rm -f /tmp/fs-k8s-flag-test-claude-harness.err
refuses "--k8s --harness claude with no --model needs a model" \
    "--k8s --harness claude needs --model" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness claude "$k8s_flag_claude_proj" "$k8s_flag_handoff"
refuses "--k8s --harness pi-local is refused" \
    "--harness pi-local is not supported with --k8s" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness pi-local unused-project unused-handoff
refuses "--k8s --harness pi --network sealed is refused" \
    "--network sealed is not supported with --k8s" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness pi --network sealed unused-project unused-handoff
refuses "--k8s --harness codex is refused" \
    "only supports --harness pi" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness codex unused-project unused-handoff

refuses "--k8s --sandbox-args is refused" \
    "--sandbox-args is not supported with --k8s" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness pi --model moonshotai/kimi-k3 --sandbox-args "--unpin-egress" \
    unused-project unused-handoff
refuses "--k8s --claude-args is refused" \
    "--claude-args is not supported with --k8s" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness pi --model moonshotai/kimi-k3 --claude-args "--effort high" \
    unused-project unused-handoff
refuses "--k8s --no-services is refused" \
    "--no-services is not supported with --k8s" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness pi --model moonshotai/kimi-k3 --no-services \
    unused-project unused-handoff
# --services-trust-ref is carried through to the dispatched run. A checked-out
# service spec is disabled without the trust ref, so the rendered sidecar
# proves the launcher passed this flag rather than merely accepting it.
k8s_flag_svc_dir="$k8s_flag_proj/.agents/sandbox-services"
mkdir -p "$k8s_flag_svc_dir"
printf 'version: 1\nservices:\n  - name: launcher-svc\n    image: registry.example/x:1\n    port: 5432\n' > "$k8s_flag_svc_dir/services.yaml"
git -C "$k8s_flag_proj" add .agents/sandbox-services/services.yaml
git -C "$k8s_flag_proj" -c user.email=t@fork-sandbox.invalid -c user.name=Tester commit -q -m services
# -c tag.gpgSign=false: an operator with tag.gpgSign set otherwise gets an
# ANNOTATED tag here, which dies "fatal: no tag message?" and leaves the
# ref unborn -- the same hazard the fs-k8s-checkout fixture documents.
git -C "$k8s_flag_proj" -c tag.gpgSign=false tag fs-k8s-launcher-services
k8s_flag_services_sha="$(git -C "$k8s_flag_proj" rev-parse --verify --quiet HEAD)"
k8s_flag_services_out="$(newdir)/k8s-flag-services.yaml"; tmpdirs+=("$(dirname "$k8s_flag_services_out")")
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness pi --model moonshotai/kimi-k3 \
    --checkout "$k8s_flag_services_sha" \
    --services-trust-ref fs-k8s-launcher-services \
    --branch fs-k8s-flag-test-services-branch \
    "$k8s_flag_proj" "$k8s_flag_handoff" > "$k8s_flag_services_out" 2>/tmp/fs-k8s-flag-test-services.err; then
    ok "--k8s --services-trust-ref --dry-run reaches the dispatched command"
else
    no "--k8s --services-trust-ref --dry-run reaches the dispatched command" \
        "$(cat /tmp/fs-k8s-flag-test-services.err)"
fi
check "--k8s --services-trust-ref forwards the flag and enables the checked-out spec" \
    2 "$(awk '/^      initContainers:/{f=1} f&&/^      containers:/{f=0} f' "$k8s_flag_services_out" | grep -c '^        - name:')"
rm -f /tmp/fs-k8s-flag-test-services.err
refuses "--k8s --keep-session is refused" \
    "--keep-session is not supported with --k8s" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness pi --model moonshotai/kimi-k3 --keep-session \
    unused-project unused-handoff

# --checkout is carried through, not refused -- its own section below
# drives both verbs, stubbed, and proves the flag reaches the dispatcher's
# render.
# --pi-args is carried through too, not refused -- its own section below
# ("fork-sandbox.sh --k8s: --pi-args is forwarded, not refused") drives
# both verbs and proves the value reaches the rendered Job byte-for-byte
# the same as a direct run, and that a claude harness is still refused by
# fork-sandbox-k8s.sh's own cross-check, not this dispatcher's.
# --context-ro is carried through, not refused -- fork-sandbox-k8s.sh's own
# submit applies the directory-under-/var/tmp/claude-scratch/forks/,
# no-symlinks, 256 MiB constraints itself, so the fixture below needs a real
# directory satisfying those, the same way k8s_flag_proj/k8s_flag_handoff
# above stand in for --dry-run's own post-flag-parse validation.
k8s_flag_cr_dir="$(mktemp -d /var/tmp/claude-scratch/forks/fs-k8s-flag-test-cr.XXXXXX)"
tmpdirs+=("$k8s_flag_cr_dir")
printf 'gathered notes\n' > "$k8s_flag_cr_dir/notes.md"
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness pi --model moonshotai/kimi-k3 \
    --context-ro "$k8s_flag_cr_dir" \
    --branch fs-k8s-flag-test-cr-branch \
    "$k8s_flag_proj" "$k8s_flag_handoff" \
    > /tmp/fs-k8s-flag-test-cr.yaml 2>/tmp/fs-k8s-flag-test-cr.err; then
    ok "--k8s --context-ro --dry-run is no longer refused"
else
    no "--k8s --context-ro --dry-run is no longer refused" \
        "$(cat /tmp/fs-k8s-flag-test-cr.err)"
fi
if grep -q '## Gathered context' /tmp/fs-k8s-flag-test-cr.yaml; then
    ok "--k8s --context-ro --dry-run forwards the flag to fork-sandbox-k8s.sh"
else
    no "--k8s --context-ro --dry-run forwards the flag to fork-sandbox-k8s.sh" \
        "not found in /tmp/fs-k8s-flag-test-cr.yaml"
fi
rm -f /tmp/fs-k8s-flag-test-cr.err /tmp/fs-k8s-flag-test-cr.yaml
# --attach-dir and --thread-dir are carried through too, not refused --
# fork-sandbox-k8s.sh's own submit applies fs_validate_scratch_dir's wider
# whole-scratch-root boundary itself, so a directory under the scratch root
# but outside forks/ is enough here (unlike --context-ro's fixture above,
# which needs the narrower forks/ prefix).
k8s_flag_attach_dir="$(mktemp -d /var/tmp/claude-scratch/fs-k8s-flag-test-attach.XXXXXX)"
tmpdirs+=("$k8s_flag_attach_dir")
printf 'an attachment\n' > "$k8s_flag_attach_dir/file.txt"
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness pi --model moonshotai/kimi-k3 \
    --attach-dir "$k8s_flag_attach_dir" \
    --branch fs-k8s-flag-test-attach-branch \
    "$k8s_flag_proj" "$k8s_flag_handoff" \
    > /tmp/fs-k8s-flag-test-attach.yaml 2>/tmp/fs-k8s-flag-test-attach.err; then
    ok "--k8s --attach-dir --dry-run is no longer refused"
else
    no "--k8s --attach-dir --dry-run is no longer refused" \
        "$(cat /tmp/fs-k8s-flag-test-attach.err)"
fi
if grep -qF 'mountPath: /attachments' /tmp/fs-k8s-flag-test-attach.yaml; then
    ok "--k8s --attach-dir --dry-run forwards the flag to fork-sandbox-k8s.sh"
else
    no "--k8s --attach-dir --dry-run forwards the flag to fork-sandbox-k8s.sh" \
        "not found in /tmp/fs-k8s-flag-test-attach.yaml"
fi
rm -f /tmp/fs-k8s-flag-test-attach.err /tmp/fs-k8s-flag-test-attach.yaml
k8s_flag_thread_dir="$(mktemp -d /var/tmp/claude-scratch/fs-k8s-flag-test-thread.XXXXXX)"
tmpdirs+=("$k8s_flag_thread_dir")
printf 'thread.txt\n' > "$k8s_flag_thread_dir/thread.txt"
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness pi --model moonshotai/kimi-k3 \
    --thread-dir "$k8s_flag_thread_dir" \
    --branch fs-k8s-flag-test-thread-branch \
    "$k8s_flag_proj" "$k8s_flag_handoff" \
    > /tmp/fs-k8s-flag-test-thread.yaml 2>/tmp/fs-k8s-flag-test-thread.err; then
    ok "--k8s --thread-dir --dry-run is no longer refused"
else
    no "--k8s --thread-dir --dry-run is no longer refused" \
        "$(cat /tmp/fs-k8s-flag-test-thread.err)"
fi
if grep -qF 'mountPath: /thread' /tmp/fs-k8s-flag-test-thread.yaml; then
    ok "--k8s --thread-dir --dry-run forwards the flag to fork-sandbox-k8s.sh"
else
    no "--k8s --thread-dir --dry-run forwards the flag to fork-sandbox-k8s.sh" \
        "not found in /tmp/fs-k8s-flag-test-thread.yaml"
fi
rm -f /tmp/fs-k8s-flag-test-thread.err /tmp/fs-k8s-flag-test-thread.yaml
# --endpoint is carried through, not refused -- on a K8S_PROXY_ENDPOINTS
# install the forwarded flag must reach the render: the Job's PROXY_BASE_URL
# lands at the named endpoint's /e/<name>/v1 instead of the legacy /api/v1
# path. Reuses endpoints_config_dir's primary/secondary registry above.
k8s_flag_ep_out="$(newdir)/k8s-flag-ep.yaml"; tmpdirs+=("$(dirname "$k8s_flag_ep_out")")
if FORK_SANDBOX_CONFIG_DIR="$endpoints_config_dir" "$fs_sh" --k8s --dry-run \
    --harness pi --model moonshotai/kimi-k3 --endpoint secondary \
    --branch fs-k8s-flag-test-ep-branch \
    "$k8s_flag_proj" "$k8s_flag_handoff" \
    > "$k8s_flag_ep_out" 2>/tmp/fs-k8s-flag-test-ep.err; then
    ok "--k8s --endpoint --dry-run exits 0"
else
    no "--k8s --endpoint --dry-run exits 0" "$(cat /tmp/fs-k8s-flag-test-ep.err)"
fi
if grep -qF 'value: "http://fork-sandbox-proxy.fork-sandbox-test.svc.cluster.local:8080/e/secondary/v1"' "$k8s_flag_ep_out" \
    && ! grep -qF 'value: "http://fork-sandbox-proxy.fork-sandbox-test.svc.cluster.local:8080/api/v1"' "$k8s_flag_ep_out"; then
    ok "--k8s --endpoint --dry-run forwards the flag to fork-sandbox-k8s.sh"
else
    no "--k8s --endpoint --dry-run forwards the flag to fork-sandbox-k8s.sh" \
        "$(grep -A1 'name: PROXY_BASE_URL' "$k8s_flag_ep_out")"
fi
rm -f /tmp/fs-k8s-flag-test-ep.err
# --endpoint is also the launcher-side way off the pi model requirement:
# on a K8S_PROXY_ENDPOINTS install the pod discovers its model, so a
# model-less --k8s --endpoint --dry-run must reach the render with the
# discovery gate on and an empty MODEL env, mirroring the submit-level
# no-model assertions above.
k8s_flag_ep_nm_out="$(newdir)/k8s-flag-ep-nomodel.yaml"; tmpdirs+=("$(dirname "$k8s_flag_ep_nm_out")")
if FORK_SANDBOX_CONFIG_DIR="$endpoints_config_dir" "$fs_sh" --k8s --dry-run \
    --endpoint secondary \
    --branch fs-k8s-flag-test-ep-nomodel-branch \
    "$k8s_flag_proj" "$k8s_flag_handoff" \
    > "$k8s_flag_ep_nm_out" 2>/tmp/fs-k8s-flag-test-ep-nomodel.err; then
    ok "--k8s --endpoint --dry-run without --model exits 0"
else
    no "--k8s --endpoint --dry-run without --model exits 0" \
        "$(cat /tmp/fs-k8s-flag-test-ep-nomodel.err)"
fi
if [[ "$(grep -cF -- '- name: MODEL_DISCOVERY' "$k8s_flag_ep_nm_out")" == 1 ]] \
    && grep -A1 -F -- '- name: MODEL_DISCOVERY' "$k8s_flag_ep_nm_out" | grep -qF 'value: "1"'; then
    ok "the no-model --k8s --endpoint render carries MODEL_DISCOVERY=1"
else
    no "the no-model --k8s --endpoint render carries MODEL_DISCOVERY=1" \
        "$(grep -A1 -F -- '- name: MODEL_DISCOVERY' "$k8s_flag_ep_nm_out")"
fi
model_env="$(grep -A1 'name: MODEL$' "$k8s_flag_ep_nm_out" | tail -n1)"
check "the no-model --k8s --endpoint render carries an empty MODEL env" \
    '              value: ""' "$model_env"
rm -f /tmp/fs-k8s-flag-test-ep-nomodel.err "$k8s_flag_ep_nm_out"
# And the launcher no longer pre-empts the endpoint rule at all: with no
# --model and no --endpoint, K8S_DEFAULT_ENDPOINT in k8s.env alone is
# enough for a pi --k8s run to pass the launcher's own validation and
# reach the render, wired to the default's endpoint. Reuses
# default_ep_config_dir's primary/secondary registry + default above.
k8s_flag_def_out="$(newdir)/k8s-flag-def.yaml"; tmpdirs+=("$(dirname "$k8s_flag_def_out")")
if FORK_SANDBOX_CONFIG_DIR="$default_ep_config_dir" "$fs_sh" --k8s --dry-run \
    --branch fs-k8s-flag-test-def-branch \
    "$k8s_flag_proj" "$k8s_flag_handoff" \
    > "$k8s_flag_def_out" 2>/tmp/fs-k8s-flag-test-def.err; then
    ok "--k8s --dry-run with neither --model nor --endpoint passes the launcher when k8s.env names a default"
else
    no "--k8s --dry-run with neither --model nor --endpoint passes the launcher when k8s.env names a default" \
        "$(cat /tmp/fs-k8s-flag-test-def.err)"
fi
if grep -qF 'value: "http://fork-sandbox-proxy.fork-sandbox-test.svc.cluster.local:8080/e/secondary/v1"' "$k8s_flag_def_out" \
    && ! grep -qF '/e/primary/v1' "$k8s_flag_def_out"; then
    ok "the no-model no-endpoint --k8s render is wired to K8S_DEFAULT_ENDPOINT's endpoint"
else
    no "the no-model no-endpoint --k8s render is wired to K8S_DEFAULT_ENDPOINT's endpoint" \
        "$(grep -A1 'name: PROXY_BASE_URL' "$k8s_flag_def_out")"
fi
rm -f /tmp/fs-k8s-flag-test-def.err
# --harness claude keeps the model requirement even with --endpoint --
# the pod's discovery lists the pi endpoint's model ids, never a Claude
# Code model name -- and the launcher refuses it before any render.
refuses "--k8s --harness claude --endpoint without --model is still refused" \
    "--k8s --harness claude needs --model" \
    env FORK_SANDBOX_CONFIG_DIR="$endpoints_config_dir" "$fs_sh" --k8s --dry-run \
    --harness claude --endpoint secondary \
    "$k8s_flag_proj" "$k8s_flag_handoff"
# --task-meta is no longer refused with --k8s -- it is forwarded to
# fork-sandbox-k8s.sh run, which threads it to cmd_submit; see "the durable
# run log" section's own tests below for the positive coverage.
refuses "--k8s --prompts-dir is refused as not yet supported" \
    "--prompts-dir is not yet supported with --k8s" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness pi --model moonshotai/kimi-k3 --prompts-dir /nonexistent \
    unused-project unused-handoff
# --review-loop is carried through, not refused -- the cluster analogue of
# fork-sandbox.sh's own local loop, running pod-side. Real fixtures
# required (k8s_flag_proj / k8s_flag_handoff): --dry-run's own validation
# runs after fs_require_scratch_handoff / fs_require_src_project, unlike
# the flag-refusal cases above, which fail on their own flag first and so
# get away with a placeholder.
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness pi --model moonshotai/kimi-k3 --review-loop 2 \
    --branch fs-k8s-flag-test-rl-branch \
    "$k8s_flag_proj" "$k8s_flag_handoff" \
    > /tmp/fs-k8s-flag-test-rl.yaml 2>/tmp/fs-k8s-flag-test-rl.err; then
    ok "--k8s --review-loop 2 --dry-run is no longer refused"
else
    no "--k8s --review-loop 2 --dry-run is no longer refused" \
        "$(cat /tmp/fs-k8s-flag-test-rl.err)"
fi
if grep -qF '  review-prompt.md: |' /tmp/fs-k8s-flag-test-rl.yaml; then
    ok "--k8s --review-loop 2 --dry-run renders the review-prompt.md ConfigMap key"
else
    no "--k8s --review-loop 2 --dry-run renders the review-prompt.md ConfigMap key" \
        "not found in /tmp/fs-k8s-flag-test-rl.yaml"
fi
rm -f /tmp/fs-k8s-flag-test-rl.err /tmp/fs-k8s-flag-test-rl.yaml

# --review-model is now carried on both harnesses (models.json lists every
# distinct id among --model and --review-model), but only alongside
# --review-loop -- the same "only applies to review legs" rule the general
# non-k8s path applies, checked first in the --k8s block, before any
# harness-specific --review-harness rule below.
refuses "--k8s --harness pi --review-model without --review-loop is refused" \
    "only applies to review legs and requires" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness pi --model moonshotai/kimi-k3 --review-model opus \
    unused-project unused-handoff
refuses "--k8s --harness claude --review-model without --review-loop is refused (coherence checked before harness rules)" \
    "only applies to review legs and requires" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness claude --model claude-sonnet-5 --review-model opus \
    unused-project unused-handoff
refuses "--k8s --harness pi --review-harness pi --review-model without --review-loop hits the coherence message first" \
    "only applies to review legs and requires" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness pi --model moonshotai/kimi-k3 --review-harness pi --review-model opus \
    unused-project unused-handoff

pi_review_model_out="$(newdir)/pi-review-model.yaml"; tmpdirs+=("$(dirname "$pi_review_model_out")")
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness pi --model moonshotai/kimi-k3 --review-loop 2 --review-model opus \
    --branch fs-k8s-flag-test-pi-review-model \
    "$k8s_flag_proj" "$k8s_flag_handoff" \
    > "$pi_review_model_out" 2>/tmp/fs-k8s-flag-test-pi-review-model.err; then
    ok "--k8s --harness pi --review-model with --review-loop is accepted"
else
    no "--k8s --harness pi --review-model with --review-loop is accepted" \
        "$(cat /tmp/fs-k8s-flag-test-pi-review-model.err)"
fi
if grep -q 'name: REVIEW_MODEL' "$pi_review_model_out" \
    && grep -A1 'name: REVIEW_MODEL' "$pi_review_model_out" | grep -q 'value: "opus"'; then
    ok "--k8s --harness pi forwards --review-model through to the rendered Job env"
else
    no "--k8s --harness pi forwards --review-model through to the rendered Job env" \
        "not found in $pi_review_model_out"
fi
rm -f /tmp/fs-k8s-flag-test-pi-review-model.err

refuses "--k8s --harness pi --review-harness is refused (the pod's review loop is always pi)" \
    "not supported with --k8s --harness" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness pi --model moonshotai/kimi-k3 --review-loop 2 --review-harness pi \
    --review-model opus unused-project unused-handoff

refuses "--k8s --harness claude --review-loop without --review-harness pi is refused" \
    "needs" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness claude --model claude-sonnet-5 --review-loop 2 \
    unused-project unused-handoff
refuses "--k8s --harness claude --review-harness claude is refused as pi-only, regardless of --review-loop" \
    "pi-only" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness claude --model claude-sonnet-5 --review-harness claude \
    unused-project unused-handoff
refuses "--k8s --harness claude --review-loop --review-harness claude is refused as pi-only" \
    "pi-only" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness claude --model claude-sonnet-5 --review-loop 2 --review-harness claude \
    unused-project unused-handoff

claude_review_out="$(newdir)/claude-review.yaml"; tmpdirs+=("$(dirname "$claude_review_out")")
if HOME="$claude_home" FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness claude --model claude-sonnet-5 --review-loop 2 \
    --review-harness pi --review-model moonshotai/kimi-k3 \
    --branch fs-k8s-flag-test-claude-review \
    "$k8s_flag_claude_proj" "$k8s_flag_handoff" \
    > "$claude_review_out" 2>/tmp/fs-k8s-flag-test-claude-review.err; then
    ok "--k8s --harness claude --review-loop --review-harness pi --review-model is accepted"
else
    no "--k8s --harness claude --review-loop --review-harness pi --review-model is accepted" \
        "$(cat /tmp/fs-k8s-flag-test-claude-review.err)"
fi
if grep -q 'name: REVIEW_MODEL' "$claude_review_out" \
    && grep -A1 'name: REVIEW_MODEL' "$claude_review_out" | grep -q 'value: "moonshotai/kimi-k3"'; then
    ok "--k8s --harness claude forwards --review-model through to the rendered Job env"
else
    no "--k8s --harness claude forwards --review-model through to the rendered Job env" \
        "not found in $claude_review_out"
fi
rm -f /tmp/fs-k8s-flag-test-claude-review.err

# --context-secret is forwarded to fork-sandbox-k8s.sh (which validates the
# name and, in a real submit, the labels); refused without --k8s, and refused
# together with --context-ro on either path, before anything is created.
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness pi --model moonshotai/kimi-k3 \
    --context-secret preview-ctx --branch fs-k8s-flag-test-cs-branch \
    "$k8s_flag_proj" "$k8s_flag_handoff" \
    > /tmp/fs-k8s-flag-test-cs.yaml 2>/tmp/fs-k8s-flag-test-cs.err \
    && grep -q 'secretName: preview-ctx' /tmp/fs-k8s-flag-test-cs.yaml \
    && grep -q '## Context secret' /tmp/fs-k8s-flag-test-cs.yaml; then
    ok "--k8s --context-secret --dry-run forwards the flag to fork-sandbox-k8s.sh"
else
    no "--k8s --context-secret --dry-run forwards the flag to fork-sandbox-k8s.sh" \
        "$(cat /tmp/fs-k8s-flag-test-cs.err)"
fi
rm -f /tmp/fs-k8s-flag-test-cs.err /tmp/fs-k8s-flag-test-cs.yaml
refuses "--k8s --context-secret with a reserved name is refused by fork-sandbox-k8s.sh" \
    "starts with 'fork-sandbox-'" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness pi --model moonshotai/kimi-k3 \
    --context-secret fork-sandbox-upstream-key --branch fs-k8s-flag-test-cs-res \
    "$k8s_flag_proj" "$k8s_flag_handoff"
refuses "--context-secret without --k8s is refused" \
    "only apply with --k8s" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --dry-run \
    --context-secret preview-ctx unused-project unused-handoff
refuses "--context-secret with --context-ro is refused with --k8s" \
    "cannot be combined" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --context-secret preview-ctx --context-ro "$k8s_flag_cr_dir" \
    unused-project unused-handoff
refuses "--context-secret with --context-ro is refused without --k8s" \
    "cannot be combined" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --dry-run \
    --context-secret preview-ctx --context-ro "$k8s_flag_cr_dir" \
    unused-project unused-handoff

refuses "--timeout without --k8s is refused" \
    "only apply with --k8s" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --dry-run \
    --timeout 100 unused-project unused-handoff
refuses "--keep without --k8s is refused" \
    "only apply with --k8s" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --dry-run \
    --keep unused-project unused-handoff
refuses "--outbox-dir without --k8s is refused" \
    "only apply with --k8s" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --dry-run \
    --outbox-dir /tmp/fs-k8s-flag-test-outbox unused-project unused-handoff
refuses "--endpoint without --k8s is refused" \
    "only apply with --k8s" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --dry-run \
    --endpoint llm unused-project unused-handoff
refuses "--endpoint with a bad name shape is refused" \
    "takes a name matching" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --dry-run \
    --endpoint LLM-1 unused-project unused-handoff
# Names parse_proxy_endpoints would itself refuse (underscore, trailing
# hyphen) must be refused at the same shape, not only at submit as
# 'not registered'.
refuses "--endpoint with an underscore is refused as a bad shape" \
    "takes a name matching" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --dry-run \
    --endpoint my_ep unused-project unused-handoff
refuses "--endpoint with a trailing hyphen is refused as a bad shape" \
    "takes a name matching" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --dry-run \
    --endpoint a- unused-project unused-handoff

refuses "--k8s refuses a handoff outside the scratch dir" \
    "must live under /var/tmp/claude-scratch" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness pi --model moonshotai/kimi-k3 --branch fs-k8s-flag-test-branch \
    "$k8s_flag_proj" /tmp/fs-k8s-flag-test-outside-scratch.md
refuses "--k8s refuses a project outside ~/src" \
    "must live under ~/src" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness pi --model moonshotai/kimi-k3 --branch fs-k8s-flag-test-branch \
    /tmp/fs-k8s-flag-test-outside-src "$k8s_flag_handoff"

# The positive case: --k8s --harness pi --dry-run has to actually reach
# fork-sandbox-k8s.sh, and with the arguments this dispatcher promises. Prove
# it the same way this file already proves `run --dry-run` delegates to
# `submit --dry-run` above: a direct invocation and the dispatcher's must
# render byte-for-byte the same Job YAML for the same branch and model.
dispatch_out="$(newdir)/dispatch.yaml"; tmpdirs+=("$(dirname "$dispatch_out")")
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness pi --model moonshotai/kimi-k3 --branch fs-k8s-flag-test-branch \
    "$k8s_flag_proj" "$k8s_flag_handoff" \
    > "$dispatch_out" 2>/tmp/fs-k8s-flag-test-dispatch.err; then
    ok "--k8s --harness pi --dry-run exits 0"
else
    no "--k8s --harness pi --dry-run exits 0" "$(cat /tmp/fs-k8s-flag-test-dispatch.err)"
fi
direct_out="$(newdir)/direct.yaml"; tmpdirs+=("$(dirname "$direct_out")")
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" run --dry-run \
    --branch fs-k8s-flag-test-branch --model moonshotai/kimi-k3 \
    "$k8s_flag_proj" "$k8s_flag_handoff" \
    > "$direct_out" 2>/tmp/fs-k8s-flag-test-direct.err; then
    ok "direct run --dry-run (matching args) exits 0"
else
    no "direct run --dry-run (matching args) exits 0" \
        "$(cat /tmp/fs-k8s-flag-test-direct.err)"
fi
rm -f /tmp/fs-k8s-flag-test-direct.err
if diff -q "$direct_out" "$dispatch_out" >/dev/null 2>&1; then
    ok "--k8s renders the same Job YAML as a direct run --dry-run call"
else
    no "--k8s renders the same Job YAML as a direct run --dry-run call" \
        "$(diff "$direct_out" "$dispatch_out" 2>&1 | head -n 20)"
fi
rm -f /tmp/fs-k8s-flag-test-dispatch.err

# --branch omitted: --k8s generates one, unlike a direct `run` call, which
# requires --branch up front. The generated name follows submit's own
# auto-naming convention (k8s-<timestamp>), embedded in the rendered Job as
# both the fork-sandbox/branch label and the BRANCH env value.
nobranch_out="$(newdir)/nobranch.yaml"; tmpdirs+=("$(dirname "$nobranch_out")")
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness pi --model moonshotai/kimi-k3 \
    "$k8s_flag_proj" "$k8s_flag_handoff" \
    > "$nobranch_out" 2>/tmp/fs-k8s-flag-test-nobranch.err; then
    ok "--k8s without --branch exits 0"
else
    no "--k8s without --branch exits 0" "$(cat /tmp/fs-k8s-flag-test-nobranch.err)"
fi
if grep -qE 'value: "k8s-[0-9]{8}-[0-9]{6}"' "$nobranch_out"; then
    ok "--k8s without --branch generates a k8s-<timestamp> branch"
else
    no "--k8s without --branch generates a k8s-<timestamp> branch" \
        "$(cat "$nobranch_out")"
fi
rm -f /tmp/fs-k8s-flag-test-nobranch.err

# --timeout/--keep are accepted with --k8s (--dry-run never reaches the poll
# loop they configure, but they must not be refused as unsupported flags).
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness pi --model moonshotai/kimi-k3 --timeout 42 --keep \
    --branch fs-k8s-flag-test-branch2 \
    "$k8s_flag_proj" "$k8s_flag_handoff" \
    > /dev/null 2>/tmp/fs-k8s-flag-test-timeout.err; then
    ok "--k8s accepts --timeout and --keep"
else
    no "--k8s accepts --timeout and --keep" "$(cat /tmp/fs-k8s-flag-test-timeout.err)"
fi
rm -f /tmp/fs-k8s-flag-test-timeout.err

# --outbox-dir is likewise accepted with --k8s and threaded through to
# fork-sandbox-k8s.sh run (--dry-run never reaches the pull-back step it
# configures, but the flag must not be refused as unknown on either leg of
# the dispatch).
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness pi --model moonshotai/kimi-k3 --outbox-dir /tmp/fs-k8s-flag-test-outbox \
    --branch fs-k8s-flag-test-branch3 \
    "$k8s_flag_proj" "$k8s_flag_handoff" \
    > /dev/null 2>/tmp/fs-k8s-flag-test-outboxdir.err; then
    ok "--k8s accepts --outbox-dir"
else
    no "--k8s accepts --outbox-dir" "$(cat /tmp/fs-k8s-flag-test-outboxdir.err)"
fi
rm -f /tmp/fs-k8s-flag-test-outboxdir.err

printf '\n== --checkout: a named ref as the branch start (no cluster) ==\n'
# The push's source side was hardcoded HEAD, so a cluster run could only
# start from the origin repo's current HEAD. --checkout REF must instead
# resolve REF in the origin repo BEFORE anything is created, and push the
# resolved sha -- the one the push line reports and the review loop
# measures against. Driven with a stubbed kubectl (logs every invocation)
# and a stubbed git (records the push's own arguments, otherwise the real
# git): that pair is what makes "nothing was created" assertable against
# the stub's own log rather than by eyeballing the output.
co_proj="$(mktemp -d "$HOME/src/fs-k8s-checkout-test.XXXXXX")"; tmpdirs+=("$co_proj")
# Built with the operator's global and system git config neutralised. An
# operator who sets commit.gpgsign or tag.gpgSign (both are common, and both
# are set on at least one machine this suite runs on) otherwise gets a
# fixture that fails to build: `git tag <name>` with signing on is an
# ANNOTATED tag, which dies "fatal: no tag message?" without -m, and the &&
# chain then silently skips the second commit. The identity below is set
# locally, so dropping the global config costs the fixture nothing.
(
    cd "$co_proj" \
        && git init -q . \
        && git config user.email t@fork-sandbox.invalid \
        && git config user.name Tester \
        && printf 'one\n' > file.txt \
        && git add file.txt \
        && git commit -q -m one \
        && git tag fs-k8s-checkout-v1 \
        && printf 'two\n' >> file.txt \
        && git add file.txt \
        && git commit -q -m two
) >/dev/null 2>&1
co_tag="fs-k8s-checkout-v1"
# --verify --quiet, so an unbuilt fixture yields an EMPTY sha and the check
# below fails loudly. A bare `git rev-parse <bad-ref>` echoes the ref back on
# stdout, which made this assertion pass against a tag that did not exist.
co_tag_sha="$(git -C "$co_proj" rev-parse --verify --quiet "${co_tag}^{commit}")"
co_head_sha="$(git -C "$co_proj" rev-parse --verify --quiet HEAD)"
if [[ -n "$co_tag_sha" && "$co_tag_sha" != "$co_head_sha" ]]; then
    ok "the checkout fixture's tag is a commit distinct from HEAD"
else
    no "the checkout fixture's tag is a commit distinct from HEAD" \
        "tag=$co_tag_sha head=$co_head_sha"
fi
co_stub="$(newdir)"; tmpdirs+=("$co_stub")
cat > "$co_stub/git" <<'STUB'
#!/usr/bin/env bash
case " $* " in
    *" push "*) printf '%s\n' "$*" >> "$GIT_STUB_LOG"; exit 0 ;;
esac
exec /usr/bin/git "$@"
STUB
cat > "$co_stub/kubectl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$K8S_STUB_LOG"
case " $* " in
    *" apply -f -"*) cat >/dev/null; exit 0 ;;
    *" wait "*) exit 0 ;;
    *" get "*) printf 'stub-pod\n' ;;
esac
exit 0
STUB
chmod +x "$co_stub/git" "$co_stub/kubectl"

# 1. A ref that resolves renders cleanly under --dry-run, which touches
# nothing beyond the validation this flag lives in.
co_out1="$(newdir)/co-1.yaml"; tmpdirs+=("$(dirname "$co_out1")")
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-co-dryrun --model moonshotai/kimi-k3 --checkout "$co_tag" \
    "$co_proj" "$handoff_file" > "$co_out1" 2>&1; then
    ok "submit --dry-run --checkout with a resolvable ref exits 0"
else
    no "submit --dry-run --checkout with a resolvable ref exits 0" "$(cat "$co_out1")"
fi

# 2. The important one: a ref that does NOT resolve must fail, name the
# ref, and create nothing -- asserted against the stub kubectl's own log
# (it records every invocation) and the stub git's push log, on the
# NON-dry-run path where a Job, Secret and proxy Pod would otherwise go
# down.
co_dir2="$(newdir)"; tmpdirs+=("$co_dir2")
PATH="$co_stub:$PATH" K8S_STUB_LOG="$co_dir2/kubectl.log" GIT_STUB_LOG="$co_dir2/git.log" \
    FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit \
    --branch fs-k8s-test-co-badref --model moonshotai/kimi-k3 \
    --checkout fs-k8s-checkout-nosuch \
    "$co_proj" "$handoff_file" > "$co_dir2/out.txt" 2>&1
co_rc2=$?
if (( co_rc2 != 0 )) \
    && [[ "$(cat "$co_dir2/out.txt")" == *"fs-k8s-checkout-nosuch"* && "$(cat "$co_dir2/out.txt")" == *"does not name a commit"* ]] \
    && [[ ! -s "$co_dir2/kubectl.log" && ! -s "$co_dir2/git.log" ]]; then
    ok "submit --checkout with an unresolvable ref fails with the ref named and creates nothing (stub logs empty)"
else
    no "submit --checkout with an unresolvable ref fails with the ref named and creates nothing (stub logs empty)" \
        "rc=$co_rc2 kubectl=$(cat "$co_dir2/kubectl.log") git=$(cat "$co_dir2/git.log") out=$(cat "$co_dir2/out.txt")"
fi
# The same refusal holds under --dry-run: the check is validation, and
# --dry-run exists to exercise exactly those.
refuses "submit --dry-run --checkout with an unresolvable ref is refused before the render" \
    "does not name a commit" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-co-dryrun-bad --model moonshotai/kimi-k3 \
    --checkout fs-k8s-checkout-nosuch \
    "$co_proj" "$handoff_file"

# 3. A value with a single quote is refused by fs_reject_unsafe_chars, the
# same way the suite already tests other rejected inputs -- on the
# non-dry-run path, with the stub's log still empty: the value is
# interpolated into a git command line, so it is treated as hostile.
co_dir3="$(newdir)"; tmpdirs+=("$co_dir3")
PATH="$co_stub:$PATH" K8S_STUB_LOG="$co_dir3/kubectl.log" GIT_STUB_LOG="$co_dir3/git.log" \
    FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit \
    --branch fs-k8s-test-co-quote --model moonshotai/kimi-k3 \
    --checkout "no'such-ref" \
    "$co_proj" "$handoff_file" > "$co_dir3/out.txt" 2>&1
co_rc3=$?
if (( co_rc3 != 0 )) && [[ "$(cat "$co_dir3/out.txt")" == *"single quote"* ]] \
    && [[ ! -s "$co_dir3/kubectl.log" && ! -s "$co_dir3/git.log" ]]; then
    ok "submit --checkout with a single quote is refused before any kubectl call"
else
    no "submit --checkout with a single quote is refused before any kubectl call" \
        "rc=$co_rc3 kubectl=$(cat "$co_dir3/kubectl.log") out=$(cat "$co_dir3/out.txt")"
fi

# 4. The push refspec carries the RESOLVED SHA of the named ref, not HEAD
# or the ref name -- read from the stub git's record of the push's own
# arguments -- and the push line reports the same sha.
co_dir4="$(newdir)"; tmpdirs+=("$co_dir4")
PATH="$co_stub:$PATH" K8S_STUB_LOG="$co_dir4/kubectl.log" GIT_STUB_LOG="$co_dir4/git.log" \
    FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit \
    --branch fs-k8s-test-co-sha --model moonshotai/kimi-k3 --checkout "$co_tag" \
    "$co_proj" "$handoff_file" > "$co_dir4/out.txt" 2>&1
co_rc4=$?
if (( co_rc4 == 0 )) \
    && grep -qF -- "$co_tag_sha:refs/heads/fs-k8s-test-co-sha" "$co_dir4/git.log" \
    && ! grep -qF 'HEAD:refs/heads/' "$co_dir4/git.log" \
    && [[ "$(cat "$co_dir4/out.txt")" == *"branch starts at $co_tag_sha"* ]]; then
    ok "the push refspec carries the resolved sha of the named ref, not HEAD, and the push line reports it"
else
    no "the push refspec carries the resolved sha of the named ref, not HEAD, and the push line reports it" \
        "rc=$co_rc4 git=$(cat "$co_dir4/git.log") out=$(cat "$co_dir4/out.txt")"
fi

# 5. No --checkout: the refspec and the review base are exactly what they
# are today -- HEAD, resolved the same way.
co_dir5="$(newdir)"; tmpdirs+=("$co_dir5")
PATH="$co_stub:$PATH" K8S_STUB_LOG="$co_dir5/kubectl.log" GIT_STUB_LOG="$co_dir5/git.log" \
    FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit \
    --branch fs-k8s-test-co-head --model moonshotai/kimi-k3 \
    "$co_proj" "$handoff_file" > "$co_dir5/out.txt" 2>&1
co_rc5=$?
if (( co_rc5 == 0 )) \
    && grep -qF -- "HEAD:refs/heads/fs-k8s-test-co-head" "$co_dir5/git.log" \
    && [[ "$(cat "$co_dir5/out.txt")" == *"branch starts at HEAD"* ]]; then
    ok "no --checkout: the push refspec and the push line are HEAD, exactly as before"
else
    no "no --checkout: the push refspec and the push line are HEAD, exactly as before" \
        "rc=$co_rc5 git=$(cat "$co_dir5/git.log") out=$(cat "$co_dir5/out.txt")"
fi
co_out6="$(newdir)/co-6.yaml"; tmpdirs+=("$(dirname "$co_out6")")
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-co-rl-checkout --model moonshotai/kimi-k3 \
    --review-loop 1 --checkout "$co_tag" \
    "$co_proj" "$handoff_file" > "$co_out6" 2>/dev/null; then
    ok "submit --dry-run --review-loop 1 --checkout exits 0"
else
    no "submit --dry-run --review-loop 1 --checkout exits 0" "$(cat "$co_out6")"
fi
if grep -A1 'name: BASE_SHA' "$co_out6" | grep -qF "value: \"$co_tag_sha\""; then
    ok "under --checkout, the review base is the same revision the push sends"
else
    no "under --checkout, the review base is the same revision the push sends" \
        "$(grep -A1 'name: BASE_SHA' "$co_out6")"
fi
co_out7="$(newdir)/co-7.yaml"; tmpdirs+=("$(dirname "$co_out7")")
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-co-rl-head --model moonshotai/kimi-k3 \
    --review-loop 1 \
    "$co_proj" "$handoff_file" > "$co_out7" 2>/dev/null; then
    ok "submit --dry-run --review-loop 1 (no --checkout) exits 0"
else
    no "submit --dry-run --review-loop 1 (no --checkout) exits 0" "$(cat "$co_out7")"
fi
if grep -A1 'name: BASE_SHA' "$co_out7" | grep -qF "value: \"$co_head_sha\""; then
    ok "no --checkout: the review base is HEAD's sha, exactly as before"
else
    no "no --checkout: the review base is HEAD's sha, exactly as before" \
        "$(grep -A1 'name: BASE_SHA' "$co_out7")"
fi

# 6. The dispatcher: fork-sandbox.sh --k8s --checkout no longer errors, and
# the flag actually reaches fork-sandbox-k8s.sh run -- proved the same way
# this file proves every other carried flag, by diffing the dispatcher's
# render against a direct run --dry-run with the same arguments. --review-loop
# rides along so the pushed revision is visible in the render (BASE_SHA):
# a dispatcher that dropped --checkout would render HEAD's sha, and the tag
# is a different commit, so the diff would fail.
co_out8="$(newdir)/co-8.yaml"; tmpdirs+=("$(dirname "$co_out8")")
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness pi --model moonshotai/kimi-k3 --review-loop 1 --checkout "$co_tag" \
    --branch fs-k8s-test-co-dispatch \
    "$co_proj" "$k8s_flag_handoff" \
    > "$co_out8" 2>/tmp/fs-k8s-co-dispatch.err; then
    ok "fork-sandbox.sh --k8s --checkout --dry-run is no longer refused"
else
    no "fork-sandbox.sh --k8s --checkout --dry-run is no longer refused" \
        "$(cat /tmp/fs-k8s-co-dispatch.err)"
fi
co_out9="$(newdir)/co-9.yaml"; tmpdirs+=("$(dirname "$co_out9")")
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" run --dry-run \
    --branch fs-k8s-test-co-dispatch --model moonshotai/kimi-k3 \
    --review-loop 1 --checkout "$co_tag" \
    "$co_proj" "$k8s_flag_handoff" \
    > "$co_out9" 2>/dev/null; then
    ok "direct run --dry-run --checkout (matching args) exits 0"
else
    no "direct run --dry-run --checkout (matching args) exits 0" "$(cat "$co_out9")"
fi
if diff -q "$co_out8" "$co_out9" >/dev/null 2>&1 \
    && grep -A1 'name: BASE_SHA' "$co_out8" | grep -qF "value: \"$co_tag_sha\""; then
    ok "--k8s --checkout forwards the flag (render matches the direct run --checkout call, base is the checkout sha)"
else
    no "--k8s --checkout forwards the flag (render matches the direct run --checkout call, base is the checkout sha)" \
        "$(diff "$co_out8" "$co_out9" 2>&1 | head -n 20)"
fi
rm -f /tmp/fs-k8s-co-dispatch.err

printf '\n== bare repo HEAD points at the pushed branch before cloning ==\n'
# cmd_submit only ever pushes refs/heads/$branch into the pod's bare repo,
# so its default HEAD (set by git init --bare) dangles. The entrypoint must
# point HEAD at the pushed branch before cloning, not after -- otherwise the
# clone still hits the dangling default and prints the warning this fix
# exists to silence.
# shellcheck disable=SC2016  # the needles match a literal $BRANCH etc. in the entrypoint text
symref_line="$(grep -n 'symbolic-ref HEAD "refs/heads/\$BRANCH"' "$entrypoint_sh" | head -1 | cut -d: -f1)"
# shellcheck disable=SC2016  # ditto
clone_line="$(grep -n 'git clone --quiet "\$repo_bare" "\$clone_dir"' "$entrypoint_sh" | head -1 | cut -d: -f1)"
if [[ -n "$symref_line" && -n "$clone_line" ]]; then
    ok "entrypoint sets symbolic-ref HEAD to refs/heads/\$BRANCH"
    if (( symref_line < clone_line )); then
        ok "the symbolic-ref line precedes the git clone line"
    else
        no "the symbolic-ref line precedes the git clone line" \
            "symbolic-ref at line $symref_line, clone at line $clone_line"
    fi
else
    no "entrypoint sets symbolic-ref HEAD to refs/heads/\$BRANCH" \
        "symref_line='$symref_line' clone_line='$clone_line' in $entrypoint_sh"
fi

# Now that the clone lands directly on $BRANCH (HEAD already points there),
# `checkout -b` would fail with "already exists" -- the entrypoint must use
# a plain checkout instead.
if grep -qF 'checkout --quiet -b' "$entrypoint_sh"; then
    no "entrypoint no longer uses checkout --quiet -b" \
        "found 'checkout --quiet -b' in $entrypoint_sh"
else
    ok "entrypoint no longer uses checkout --quiet -b"
fi

# A generated sandbox env file is ignored through the clone-local exclude
# file, and the exact entry is guarded so repeated setup does not duplicate it.
if grep -qF '>> "$clone_dir/.git/info/exclude"' "$entrypoint_sh" \
    && grep -qF "grep -qxF '.env.sandbox' \"\$clone_dir/.git/info/exclude\"" "$entrypoint_sh"; then
    ok "entrypoint excludes .env.sandbox from end-of-leg commits without duplicate entries"
else
    no "entrypoint excludes .env.sandbox from end-of-leg commits without duplicate entries" \
        "missing clone-local info/exclude guard in $entrypoint_sh"
fi
if grep -qF 'git ls-files --error-unmatch -- .env.sandbox' "$entrypoint_sh" \
    && grep -qF 'refusing to overwrite it with generated sandboxEnv content' "$entrypoint_sh"; then
    ok "entrypoint refuses to overwrite a tracked .env.sandbox"
else
    no "entrypoint refuses to overwrite a tracked .env.sandbox" \
        "missing tracked-file refusal in $entrypoint_sh"
fi

# The real-git property the fix relies on: pushing a branch into a bare repo
# leaves its default HEAD dangling, and a plain `git clone` of that repo
# warns and checks out nothing -- but pointing HEAD at the pushed branch
# first makes the clone land directly on it, with no warning.
symref_root="$(mktemp -d /var/tmp/claude-scratch/fs-k8s-symref-test.XXXXXX)"; tmpdirs+=("$symref_root")
symref_bare="$symref_root/repo.git"
symref_src="$symref_root/src"
symref_clone="$symref_root/clone"
git init --quiet --bare "$symref_bare"
mkdir -p "$symref_src"
git -C "$symref_src" init --quiet
git -C "$symref_src" -c user.email=t@fork-sandbox.invalid -c user.name=Tester \
    commit -q --allow-empty -m init
git -C "$symref_src" push --quiet "$symref_bare" HEAD:refs/heads/x
git --git-dir="$symref_bare" symbolic-ref HEAD refs/heads/x
symref_clone_err="$(git clone --quiet "$symref_bare" "$symref_clone" 2>&1 1>/dev/null)"
if [[ "$symref_clone_err" != *"nonexistent ref"* ]]; then
    ok "cloning a bare repo with HEAD pointed at the pushed branch prints no nonexistent-ref warning"
else
    no "cloning a bare repo with HEAD pointed at the pushed branch prints no nonexistent-ref warning" \
        "$symref_clone_err"
fi
symref_clone_branch="$(git -C "$symref_clone" rev-parse --abbrev-ref HEAD 2>/dev/null)"
check "the clone lands directly on branch x" "x" "$symref_clone_branch"

printf '\n== entrypoint: HARNESS switch and claude coding leg ==\n'
# All the needles below are grepped as literal text against the entrypoint
# script's own source, matching a literal "$VAR" there -- none of them are
# meant to expand in this test script.
# shellcheck disable=SC2016

# HARNESS defaults to pi and rejects anything but pi|claude.
if grep -qF ': "${HARNESS:=pi}"' "$entrypoint_sh" \
    && grep -qF 'pi|claude) ;;' "$entrypoint_sh"; then
    ok "entrypoint defaults HARNESS to pi and validates it against pi|claude"
else
    no "entrypoint defaults HARNESS to pi and validates it against pi|claude" \
        "missing HARNESS default or pi|claude case arm in $entrypoint_sh"
fi

# CLAUDE_PROXY_BASE_URL is required only for HARNESS=claude.
# shellcheck disable=SC2016
if grep -qF 'CLAUDE_PROXY_BASE_URL:?CLAUDE_PROXY_BASE_URL must be set when HARNESS=claude' \
    "$entrypoint_sh"; then
    ok "entrypoint requires CLAUDE_PROXY_BASE_URL when HARNESS=claude"
else
    no "entrypoint requires CLAUDE_PROXY_BASE_URL when HARNESS=claude" \
        "missing CLAUDE_PROXY_BASE_URL required-var check in $entrypoint_sh"
fi

# A claude run with REVIEW_LOOP_CAP set and no REVIEW_MODEL fails at
# startup, before the coding leg -- the review loop always runs pi, and
# MODEL is a Claude Code model name pi cannot use.
# shellcheck disable=SC2016
if grep -qF 'HARNESS" == claude && -z "$REVIEW_MODEL"' "$entrypoint_sh"; then
    ok "entrypoint refuses HARNESS=claude with REVIEW_LOOP_CAP set and no REVIEW_MODEL"
else
    no "entrypoint refuses HARNESS=claude with REVIEW_LOOP_CAP set and no REVIEW_MODEL" \
        "missing the REVIEW_MODEL startup check in $entrypoint_sh"
fi

# The claude branch installs the placeholder credential and the pre-accepted
# onboarding/trust config at the paths claude reads from $HOME.
# shellcheck disable=SC2016
if grep -qF 'install -m 600 "$mounts_dir/claude-credentials.json" "$HOME/.claude/.credentials.json"' \
    "$entrypoint_sh"; then
    ok "entrypoint installs the placeholder claude credential"
else
    no "entrypoint installs the placeholder claude credential" \
        "missing the claude-credentials.json install line in $entrypoint_sh"
fi
# shellcheck disable=SC2016
if grep -qF 'hasCompletedOnboarding: true' "$entrypoint_sh" \
    && grep -qF '> "$HOME/.claude.json"' "$entrypoint_sh"; then
    ok "entrypoint writes a pre-accepted ~/.claude.json for the claude branch"
else
    no "entrypoint writes a pre-accepted ~/.claude.json for the claude branch" \
        "missing the .claude.json synthesis in $entrypoint_sh"
fi

# The operator-inbox hook is installed executable and registered via
# --settings, exactly as a local claude run's own inbox-hook install does.
# shellcheck disable=SC2016
if grep -qF 'install -m 755 "$mounts_dir/inbox-hook.sh" "$inbox_dir/.inbox-hook.sh"' \
    "$entrypoint_sh"; then
    ok "entrypoint installs the inbox hook mode 755"
else
    no "entrypoint installs the inbox hook mode 755" \
        "missing the inbox-hook.sh install line in $entrypoint_sh"
fi
# shellcheck disable=SC2016
if grep -qF '"$work_dir/inbox-settings.json"' "$entrypoint_sh"; then
    ok "entrypoint renders an inbox-settings.json for --settings"
else
    no "entrypoint renders an inbox-settings.json for --settings" \
        "missing inbox-settings.json in $entrypoint_sh"
fi

# The claude launch line itself: base URL via env, non-interactive flags,
# the inbox-hook --settings file, and stdin/stdout/stderr wired the same
# way as pi's own invocation but to claude-stderr.log, not pi-stderr.log.
# shellcheck disable=SC2016
claude_launch_checks=(
    'ANTHROPIC_BASE_URL="$CLAUDE_PROXY_BASE_URL"'
    'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1'
    'DISABLE_AUTOUPDATER=1'
    'TERM=dumb'
    'env "${leg_env[@]}" "${claude_argv[@]}"'
    'claude --dangerously-skip-permissions --print --verbose'
    '--output-format stream-json --model "$MODEL"'
    '--settings "$work_dir/inbox-settings.json" --include-hook-events'
    '< "${1:-$mounts_dir/handoff.md}"'
    '> "${2:-$work_dir/events.jsonl}"'
    '2> "${3:-$work_dir/claude-stderr.log}"'
)
claude_launch_missing=""
for needle in "${claude_launch_checks[@]}"; do
    if ! grep -qF -- "$needle" "$entrypoint_sh"; then
        claude_launch_missing+="  missing: $needle"$'\n'
    fi
done
if [[ -z "$claude_launch_missing" ]]; then
    ok "entrypoint's claude launch line carries every required flag/env/redirect"
else
    no "entrypoint's claude launch line carries every required flag/env/redirect" \
        "$claude_launch_missing"
fi

printf '\n== entrypoint: claude coding leg keeps its conversation (R3a section 4) ==\n'
# RESUME_FAIL_RE must match claude-sandboxed's own copy literally -- the
# entrypoint splits it across three assignments to stay under the
# ConfigMap-embedded YAML's line-length limit, so reconstruct it before
# comparing.
claude_sandboxed_sh="$repo_dir/scripts/claude-sandboxed"
ep_resume_re="$(awk -F"'" '/^ *RESUME_FAIL_RE\+?=/{printf "%s", $2}' "$entrypoint_sh")"
cs_resume_re="$(awk -F"'" '/^RESUME_FAIL_RE=/{printf "%s", $2}' "$claude_sandboxed_sh")"
if [[ -n "$ep_resume_re" && "$ep_resume_re" == "$cs_resume_re" ]]; then
    ok "the entrypoint's RESUME_FAIL_RE (reassembled) matches claude-sandboxed's literally"
else
    no "the entrypoint's RESUME_FAIL_RE (reassembled) matches claude-sandboxed's literally" \
        "entrypoint: $ep_resume_re | claude-sandboxed: $cs_resume_re"
fi

# The claude coding-leg block: the pi_rc=0 .. fi span that decides
# HARNESS, and for HARNESS=claude seeds/resumes/snapshots the session
# store. Extracted and run standalone against a stubbed claude, the same
# function-extraction technique this suite uses for discover_model_facts
# and run_pi_coding_leg -- this one is an if/else rather than a function
# because that is how the entrypoint itself is shaped, so the sed range
# is anchored on the unindented "fi" that closes it (every "fi" for a
# block nested inside it is itself indented).
claude_block="$(sed -n '/^pi_rc=0$/,/^fi$/p' "$entrypoint_sh")"
claude_block_file="$(newdir)/claude-block.sh"; tmpdirs+=("$(dirname "$claude_block_file")")
if [[ -n "$claude_block" ]]; then
    printf '%s\n' 'set -euo pipefail' "$claude_block" \
        'printf "CLAUDE_BLOCK_PI_RC=%s\n" "$pi_rc"' > "$claude_block_file"
    ok "the claude coding-leg block (pi_rc=0..fi) is isolable in the entrypoint"
else
    no "the claude coding-leg block (pi_rc=0..fi) is isolable in the entrypoint" \
        "block not found in $entrypoint_sh"
fi

# $1 = CLAUDE_STUB_MODE (ok|resume-fail|other-fail), $2 = RESUME_SESSION
# (empty for none), $3 = a shell snippet run to pre-seed $CLAUDE_BLOCK_HOME
# or $CLAUDE_BLOCK_STORE before the block runs (empty for none). Sets
# CLAUDE_BLOCK_HOME/_STORE/_CLONE/_RECORD/_OUT/_PI_RC/_CALLS after running.
claude_block_run() {
    local stub_dir mounts work home store clone record
    stub_dir="$(newdir)"; tmpdirs+=("$stub_dir")
    mounts="$(newdir)"; tmpdirs+=("$mounts")
    work="$(newdir)"; tmpdirs+=("$work")
    home="$(newdir)"; tmpdirs+=("$home")
    record="$(newdir)/claude-argv.txt"; tmpdirs+=("$(dirname "$record")")
    : > "$record"
    store="$work/session-store"
    clone="$work/clone"
    mkdir -p "$work/inbox" "$store"
    printf 'Do the thing.\n' > "$mounts/handoff.md"
    printf '{}' > "$mounts/claude-credentials.json"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$mounts/inbox-hook.sh"
    printf '%s\n' '#!/usr/bin/env bash' \
        'printf "%s\n" "$*" >> "$CLAUDE_STUB_RECORD"' \
        'case "$CLAUDE_STUB_MODE" in' \
        '  resume-fail)' \
        '    if printf "%s" "$*" | grep -q -- "--resume"; then' \
        '      echo "No conversation found with session ID: abc" >&2' \
        '      exit 1' \
        '    fi' \
        '    exit 0 ;;' \
        '  other-fail)' \
        '    echo "some other unrelated error" >&2' \
        '    exit 1 ;;' \
        '  *) exit 0 ;;' \
        'esac' > "$stub_dir/claude"
    chmod +x "$stub_dir/claude"
    CLAUDE_BLOCK_HOME="$home"
    CLAUDE_BLOCK_STORE="$store"
    CLAUDE_BLOCK_CLONE="$clone"
    CLAUDE_BLOCK_RECORD="$record"
    if [[ -n "${3:-}" ]]; then eval "$3"; fi
    CLAUDE_BLOCK_OUT="$(PATH="$stub_dir:$PATH" HOME="$home" \
        HARNESS=claude MODEL="claude-test-model" \
        CLAUDE_PROXY_BASE_URL="http://fs-k8s-test-proxy.invalid" \
        mounts_dir="$mounts" work_dir="$work" clone_dir="$clone" inbox_dir="$work/inbox" \
        session_store_dir="$store" \
        SESSION_HARNESS_STORE=1 RESUME_SESSION="${2:-}" \
        CLAUDE_STUB_MODE="${1:-ok}" CLAUDE_STUB_RECORD="$record" \
        bash "$claude_block_file" 2>&1)"
    CLAUDE_BLOCK_PI_RC="$(grep -o 'CLAUDE_BLOCK_PI_RC=.*' <<<"$CLAUDE_BLOCK_OUT" | tail -1 | cut -d= -f2)"
    CLAUDE_BLOCK_CALLS="$(wc -l < "$record")"
}

# Resume flag passed when RESUME_SESSION is set.
claude_block_run ok resumeid-0001-aaaa-bbbb-cccccccccccc
if grep -qF -- '--resume resumeid-0001-aaaa-bbbb-cccccccccccc' "$CLAUDE_BLOCK_RECORD" \
    && [[ "$CLAUDE_BLOCK_PI_RC" == 0 ]] && [[ "$CLAUDE_BLOCK_CALLS" == 1 ]]; then
    ok "the claude coding leg passes --resume when RESUME_SESSION is set"
else
    no "the claude coding leg passes --resume when RESUME_SESSION is set" \
        "record: $(cat "$CLAUDE_BLOCK_RECORD") pi_rc=$CLAUDE_BLOCK_PI_RC out=$CLAUDE_BLOCK_OUT"
fi

# A resume-shaped failure retries once, fresh (no --resume on the retry),
# and the retry's own success is what pi_rc reports.
claude_block_run resume-fail resumeid-0001-aaaa-bbbb-cccccccccccc
if [[ "$CLAUDE_BLOCK_CALLS" == 2 ]] \
    && [[ "$(sed -n 1p "$CLAUDE_BLOCK_RECORD")" == *"--resume resumeid-0001-aaaa-bbbb-cccccccccccc"* ]] \
    && [[ "$(sed -n 2p "$CLAUDE_BLOCK_RECORD")" != *"--resume"* ]] \
    && [[ "$CLAUDE_BLOCK_PI_RC" == 0 ]]; then
    ok "a resume-shaped claude failure retries once, fresh, and the retry's exit code wins"
else
    no "a resume-shaped claude failure retries once, fresh, and the retry's exit code wins" \
        "calls=$CLAUDE_BLOCK_CALLS record: $(cat "$CLAUDE_BLOCK_RECORD") pi_rc=$CLAUDE_BLOCK_PI_RC"
fi

# A failure that does NOT match RESUME_FAIL_RE is the run's own -- no retry.
claude_block_run other-fail resumeid-0001-aaaa-bbbb-cccccccccccc
if [[ "$CLAUDE_BLOCK_CALLS" == 1 ]] && [[ "$CLAUDE_BLOCK_PI_RC" != 0 ]]; then
    ok "a non-resume-shaped claude failure is not retried"
else
    no "a non-resume-shaped claude failure is not retried" \
        "calls=$CLAUDE_BLOCK_CALLS record: $(cat "$CLAUDE_BLOCK_RECORD") pi_rc=$CLAUDE_BLOCK_PI_RC"
fi

# No RESUME_SESSION at all: no --resume on the one and only attempt.
claude_block_run ok ""
if [[ "$CLAUDE_BLOCK_CALLS" == 1 ]] \
    && ! grep -qF -- '--resume' "$CLAUDE_BLOCK_RECORD" \
    && [[ "$CLAUDE_BLOCK_PI_RC" == 0 ]]; then
    ok "no RESUME_SESSION means no --resume and a single attempt"
else
    no "no RESUME_SESSION means no --resume and a single attempt" \
        "calls=$CLAUDE_BLOCK_CALLS record: $(cat "$CLAUDE_BLOCK_RECORD") pi_rc=$CLAUDE_BLOCK_PI_RC"
fi

# Flatten: a transcript pulled in under a FOREIGN slug directory is also
# copied into THIS pod's own slug directory (cwd with "/" -> "-"), with
# its original mtime kept -- the newest-mtime discovery rule depends on
# that mtime surviving the copy. The original under the foreign slug is
# left in place too.
claude_block_run ok "" '
    mkdir -p "$CLAUDE_BLOCK_STORE/-some-other-slug"
    printf "{}\n" > "$CLAUDE_BLOCK_STORE/-some-other-slug/foreign-transcript.jsonl"
    touch -d "2020-01-01T00:00:00Z" "$CLAUDE_BLOCK_STORE/-some-other-slug/foreign-transcript.jsonl"
'
pod_slug="${CLAUDE_BLOCK_CLONE//\//-}"
flatten_src="$CLAUDE_BLOCK_HOME/.claude/projects/-some-other-slug/foreign-transcript.jsonl"
flatten_dst="$CLAUDE_BLOCK_HOME/.claude/projects/$pod_slug/foreign-transcript.jsonl"
if [[ -f "$flatten_src" ]] && [[ -f "$flatten_dst" ]] \
    && [[ "$(stat -c '%Y' -- "$flatten_src")" == 1577836800 ]] \
    && [[ "$(stat -c '%Y' -- "$flatten_dst")" == 1577836800 ]]; then
    ok "a foreign-slug transcript is flattened into this pod's own slug directory, mtime kept"
else
    no "a foreign-slug transcript is flattened into this pod's own slug directory, mtime kept" \
        "src=$([[ -f "$flatten_src" ]] && echo present || echo missing) dst=$([[ -f "$flatten_dst" ]] && echo present || echo missing) out=$CLAUDE_BLOCK_OUT"
fi

# Snapshot: the block copies ~/.claude/projects into the store BEFORE
# returning, so a "reviewer" write into ~/.claude/projects that happens
# only AFTER the block has finished (as review-loop.sh's own claude/pi
# legs would, sharing the same $HOME) must never appear in the store --
# it is a point-in-time copy, not a live link.
claude_block_run ok ""
mkdir -p "$CLAUDE_BLOCK_HOME/.claude/projects/-work-clone"
printf '{"reviewer":true}\n' > "$CLAUDE_BLOCK_HOME/.claude/projects/-work-clone/reviewer-transcript.jsonl"
if ! find "$CLAUDE_BLOCK_STORE" -name 'reviewer-transcript.jsonl' | grep -q .; then
    ok "a post-block ~/.claude/projects write (simulating the review loop) never appears in the store"
else
    no "a post-block ~/.claude/projects write (simulating the review loop) never appears in the store" \
        "found reviewer-transcript.jsonl under $CLAUDE_BLOCK_STORE"
fi

# A failed snapshot (here: the work dir is read-only, so the staging copy
# cannot be created) must not kill the block under set -e, and must keep
# the store the wake started from -- a partial copy would be pulled back
# over the host's complete store.
claude_block_run ok "" '
    printf "pushed\n" > "$CLAUDE_BLOCK_STORE/pushed-marker.jsonl"
    for f in inbox-settings.json events.jsonl claude-stderr.log; do
        : > "$(dirname "$CLAUDE_BLOCK_STORE")/$f"
    done
    chmod 555 "$(dirname "$CLAUDE_BLOCK_STORE")"
'
chmod 755 "$(dirname "$CLAUDE_BLOCK_STORE")"
if [[ "$CLAUDE_BLOCK_PI_RC" == 0 ]] \
    && [[ "$(cat "$CLAUDE_BLOCK_STORE/pushed-marker.jsonl" 2>/dev/null)" == pushed ]] \
    && [[ ! -e "$CLAUDE_BLOCK_STORE.new" ]] \
    && grep -q 'session store snapshot failed' <<<"$CLAUDE_BLOCK_OUT"; then
    ok "a failed session-store snapshot warns and keeps the store the wake started from"
else
    no "a failed session-store snapshot warns and keeps the store the wake started from" \
        "pi_rc=$CLAUDE_BLOCK_PI_RC out=$CLAUDE_BLOCK_OUT"
fi

printf '\n== entrypoint: claude continuation legs (--refresh-at, pod side) ==\n'
# The block plus the two column-0 helpers it calls, run against a stub
# claude that counts its calls and, on chosen legs, writes a hand-off into
# the outbox and prints the inbox hook's nudge line.
refresh_ep_fns="$(sed -n '/^claude_hook_leg() {/,/^}/p;/^run_claude_continuations() {/,/^}/p' \
    "$entrypoint_sh")"
refresh_block_file="$(newdir)/refresh-block.sh"; tmpdirs+=("$(dirname "$refresh_block_file")")
printf '%s\n' 'set -euo pipefail' "$refresh_ep_fns" "$claude_block" \
    'printf "CLAUDE_BLOCK_PI_RC=%s\n" "$pi_rc"' > "$refresh_block_file"
# $1 threshold ("" = refresh off), $2 legs that write a hand-off, $3 legs that
# exit 1, $4 REFRESH_MAX, $5 RESUME_SESSION. Sets RB_WORK/_REC/_CALLS/_OUT/_RC.
refresh_block_run() {
    local stub_dir mounts home rec
    stub_dir="$(newdir)"; tmpdirs+=("$stub_dir")
    mounts="$(newdir)"; tmpdirs+=("$mounts")
    RB_WORK="$(newdir)"; tmpdirs+=("$RB_WORK")
    home="$(newdir)"; tmpdirs+=("$home")
    rec="$(newdir)"; tmpdirs+=("$rec")
    mkdir -p "$RB_WORK/inbox" "$RB_WORK/session-store" "$RB_WORK/outbox" "$RB_WORK/clone"
    # A real (tiny) git repo, not just a directory: the stall-stop check
    # reads the branch head with `git -C "$clone_dir" rev-parse HEAD`, and
    # the stub below commits into it by default on a leg that hands off,
    # the same "a leg that hands off has almost always committed
    # something" rule the local runner's own stub fixture uses.
    (cd "$RB_WORK/clone" && git init -q . \
        && GIT_AUTHOR_NAME=rb-stub GIT_AUTHOR_EMAIL=rb-stub@fork-sandbox.invalid \
           GIT_COMMITTER_NAME=rb-stub GIT_COMMITTER_EMAIL=rb-stub@fork-sandbox.invalid \
           git commit -q --allow-empty -m init) >/dev/null 2>&1
    printf 'Do the thing.\n' > "$mounts/handoff.md"
    printf 'ORIGINAL BRIEF\n' > "$mounts/handoff-original.md"
    printf 'CONTINUATION HEADER\n' > "$mounts/continuation-header.md"
    cp "$repo_dir/scripts/fork-sandbox-refresh.sh" "$mounts/refresh.sh"
    printf '{}' > "$mounts/claude-credentials.json"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$mounts/inbox-hook.sh"
    # shellcheck disable=SC1003  # a literal backslash inside the generated stub
    printf '%s\n' '#!/usr/bin/env bash' \
        'n=$(( $(cat "$RB_REC/count" 2>/dev/null || echo 0) + 1 ))' \
        'echo "$n" > "$RB_REC/count"' \
        'printf "%s\n" "$*" >> "$RB_REC/argv"' \
        'cat > "$RB_REC/stdin-$n.txt"' \
        'printf "%s|%s|%s|%s\n" "${FORK_SANDBOX_NUDGE_MARKER:-}" \' \
        '  "${FORK_SANDBOX_NUDGE_REMINDED:-}" "${FORK_SANDBOX_STALE_REMINDED:-}" \' \
        '  "${FORK_SANDBOX_INBOX_SEEN:-}" >> "$RB_REC/envs"' \
        'mkdir -p "$HOME/.claude/projects/-stub-slug"' \
        'echo "{}" > "$HOME/.claude/projects/-stub-slug/leg-$n.jsonl"' \
        'touch -d "@$((1700000000 + n))" "$HOME/.claude/projects/-stub-slug/leg-$n.jsonl"' \
        'if [[ " $RB_HANDOFF_LEGS " == *" $n "* ]]; then' \
        '  if [[ -n "$RB_CLONE" ]] && [[ " ${RB_NOCOMMIT_LEGS:-} " != *" $n "* ]]; then' \
        '    ( cd "$RB_CLONE" && echo "leg $n" >> progress.txt && git add progress.txt \' \
        '      && GIT_AUTHOR_NAME=rb-stub GIT_AUTHOR_EMAIL=rb-stub@fork-sandbox.invalid \' \
        '      GIT_COMMITTER_NAME=rb-stub GIT_COMMITTER_EMAIL=rb-stub@fork-sandbox.invalid \' \
        '      git commit -q -m "leg $n" ) >/dev/null 2>&1' \
        '  fi' \
        '  echo "handoff written by leg $n" > "$RB_OUTBOX/handoff.md"' \
        '  echo "{\"stderr\":\"fork-sandbox-refresh: nudged\"}"' \
        'fi' \
        'if [[ " ${RB_ADDENDUM_LEGS:-} " == *" $n "* ]]; then' \
        '  echo "operator addendum for leg $n" > "$RB_OUTBOX/../inbox/addendum-$n.md"' \
        'fi' \
        '[[ " $RB_FAIL_LEGS " == *" $n "* ]] && exit 1' \
        'exit 0' > "$stub_dir/claude"
    chmod +x "$stub_dir/claude"
    RB_REC="$rec"
    RB_OUT="$(PATH="$stub_dir:$PATH" HOME="$home" TMPDIR="$rec" \
        HARNESS=claude MODEL="claude-test-model" \
        CLAUDE_PROXY_BASE_URL="http://fs-k8s-test-proxy.invalid" \
        mounts_dir="$mounts" work_dir="$RB_WORK" clone_dir="$RB_WORK/clone" \
        inbox_dir="$RB_WORK/inbox" outbox_dir="$RB_WORK/outbox" \
        session_store_dir="$RB_WORK/session-store" SESSION_HARNESS_STORE=1 \
        RESUME_SESSION="${5:-}" REFRESH_THRESHOLD_TOKENS="${1:-}" REFRESH_MAX="${4:-6}" \
        REFRESH_CEILING_TOKENS="${RB_CEILING:-}" \
        RB_REC="$rec" RB_OUTBOX="$RB_WORK/outbox" RB_CLONE="$RB_WORK/clone" \
        RB_HANDOFF_LEGS="${2:-}" RB_FAIL_LEGS="${3:-}" \
        RB_ADDENDUM_LEGS="${RB_ADDENDUM_LEGS:-}" \
        RB_NOCOMMIT_LEGS="${RB_NOCOMMIT_LEGS:-}" \
        bash "$refresh_block_file" 2>&1)"
    RB_RC="$(grep -o 'CLAUDE_BLOCK_PI_RC=.*' <<<"$RB_OUT" | tail -1 | cut -d= -f2)"
    RB_CALLS="$(cat "$rec/count" 2>/dev/null || echo 0)"
}

refresh_block_run 100000 "" "" 6
if [[ "$RB_CALLS" == 1 && "$RB_RC" == 0 ]] \
    && [[ "$(jq -r .ended "$RB_WORK/refresh.json")" == empty-outbox ]] \
    && [[ "$(jq -c .continuations "$RB_WORK/refresh.json")" == '[]' ]] \
    && [[ ! -e "$RB_WORK/inbox/.refresh-config" ]] \
    && [[ ! -e "$RB_WORK/refresh.json.tmp" ]]; then
    ok "refresh on, no hand-off: one leg, ended empty-outbox, refresh.json written"
else
    no "refresh on, no hand-off: one leg, ended empty-outbox, refresh.json written" \
        "calls=$RB_CALLS rc=$RB_RC out=$RB_OUT"
fi

# A zero cap runs no continuation, and the waiting hand-off stays put.
refresh_block_run 100000 "1" "" 0
if [[ "$RB_CALLS" == 1 ]] && [[ "$(jq -r .ended "$RB_WORK/refresh.json")" == cap ]] \
    && [[ -f "$RB_WORK/outbox/handoff.md" ]]; then
    ok "REFRESH_MAX=0 with a hand-off waiting: no continuation, ended cap"
else
    no "REFRESH_MAX=0 with a hand-off waiting: no continuation, ended cap" \
        "calls=$RB_CALLS out=$RB_OUT"
fi

# The .refresh-config the hook reads is present while the legs run.
refresh_cfg_probe() {
    local ep_copy
    ep_copy="$(newdir)/probe.sh"; tmpdirs+=("$(dirname "$ep_copy")")
    printf '%s\n' 'set -euo pipefail' "$refresh_ep_fns" "$claude_block" > "$ep_copy"
    printf '%s' "$ep_copy"
}
refresh_cfg_stub_dir="$(newdir)"; tmpdirs+=("$refresh_cfg_stub_dir")
printf '%s\n' '#!/usr/bin/env bash' 'cat > /dev/null' \
    'cp "$RB_WORK_DIR/inbox/.refresh-config" "$RB_WORK_DIR/config-seen"' \
    > "$refresh_cfg_stub_dir/claude"
chmod +x "$refresh_cfg_stub_dir/claude"
refresh_cfg_work="$(newdir)"; tmpdirs+=("$refresh_cfg_work")
refresh_cfg_mounts="$(newdir)"; tmpdirs+=("$refresh_cfg_mounts")
mkdir -p "$refresh_cfg_work/inbox" "$refresh_cfg_work/outbox" "$refresh_cfg_work/clone"
printf 'x\n' > "$refresh_cfg_mounts/handoff.md"
printf 'x\n' > "$refresh_cfg_mounts/continuation-header.md"
printf 'x\n' > "$refresh_cfg_mounts/handoff-original.md"
printf '{}' > "$refresh_cfg_mounts/claude-credentials.json"
printf '#!/usr/bin/env bash\nexit 0\n' > "$refresh_cfg_mounts/inbox-hook.sh"
cp "$repo_dir/scripts/fork-sandbox-refresh.sh" "$refresh_cfg_mounts/refresh.sh"
PATH="$refresh_cfg_stub_dir:$PATH" HOME="$(newdir)" TMPDIR="$(newdir)" HARNESS=claude \
    MODEL=m CLAUDE_PROXY_BASE_URL=http://fs-k8s-test-proxy.invalid \
    mounts_dir="$refresh_cfg_mounts" work_dir="$refresh_cfg_work" \
    clone_dir="$refresh_cfg_work/clone" inbox_dir="$refresh_cfg_work/inbox" \
    outbox_dir="$refresh_cfg_work/outbox" session_store_dir="$refresh_cfg_work/store" \
    SESSION_HARNESS_STORE="" RESUME_SESSION="" REFRESH_THRESHOLD_TOKENS=123456 \
    REFRESH_MAX=6 REFRESH_CEILING_TOKENS=98765 RB_WORK_DIR="$refresh_cfg_work" \
    bash "$(refresh_cfg_probe)" > /dev/null 2>&1 || true
if [[ "$(cat "$refresh_cfg_work/config-seen" 2>/dev/null)" == \
    "THRESHOLD_TOKENS=123456
OUTBOX_DIR=$refresh_cfg_work/outbox
CLONE_DIR=$refresh_cfg_work/clone
CEILING_TOKENS=98765" ]]; then
    ok "the first leg runs with .refresh-config (threshold, outbox, clone, ceiling) in the inbox"
else
    no "the first leg runs with .refresh-config (threshold, outbox, clone, ceiling) in the inbox" \
        "seen: $(cat "$refresh_cfg_work/config-seen" 2>/dev/null)"
fi

# Hand-off on leg 1: one continuation, fresh (no --resume even with
# RESUME_SESSION set), original brief + hand-off on its stdin, the hand-off
# recorded in /work and gone from the outbox.
refresh_block_run 100000 "1" "" 6 resumeid-0001-aaaa-bbbb-cccccccccccc
if [[ "$RB_CALLS" == 2 && "$RB_RC" == 0 ]] \
    && [[ "$(sed -n 1p "$RB_REC/argv")" == *"--resume resumeid-0001"* ]] \
    && [[ "$(sed -n 2p "$RB_REC/argv")" != *"--resume"* ]] \
    && grep -qF 'ORIGINAL BRIEF' "$RB_REC/stdin-2.txt" \
    && grep -qF 'CONTINUATION HEADER' "$RB_REC/stdin-2.txt" \
    && grep -qF 'handoff written by leg 1' "$RB_REC/stdin-2.txt" \
    && cmp -s "$RB_REC/stdin-2.txt" "$RB_WORK/continuation-prompt-1.md" \
    && [[ -f "$RB_WORK/handoff-1.md" && ! -e "$RB_WORK/outbox/handoff.md" ]] \
    && [[ -f "$RB_WORK/events-continuation-1.jsonl" ]] \
    && [[ -f "$RB_WORK/claude-stderr-continuation-1.log" ]] \
    && [[ "$(jq -r .ended "$RB_WORK/refresh.json")" == empty-outbox ]] \
    && [[ "$(jq -c '.continuations | map({leg, exit, handoff})' "$RB_WORK/refresh.json")" \
        == '[{"leg":2,"exit":0,"handoff":"handoff-1.md"}]' ]]; then
    ok "a hand-off on leg 1 starts one fresh continuation with brief + hand-off on stdin"
else
    no "a hand-off on leg 1 starts one fresh continuation with brief + hand-off on stdin" \
        "calls=$RB_CALLS rc=$RB_RC argv: $(cat "$RB_REC/argv") out=$RB_OUT"
fi

# The refresh loop archives addenda out of /work/inbox, so the review and
# fix prompts must carry them: append_archived_addenda folds the archive into
# a copy of a prompt, oldest leg first, and writes nothing when there is none.
RB_ADDENDUM_LEGS="1 2" refresh_block_run 100000 "1" "" 6
addenda_fn="$(sed -n '/^append_archived_addenda() {/,/^}/p' "$entrypoint_sh")"
addenda_probe="$(newdir)/addenda-probe.sh"; tmpdirs+=("$(dirname "$addenda_probe")")
printf '%s\n' 'set -euo pipefail' "$addenda_fn" \
    'source "$REFRESH_SH"' \
    'append_archived_addenda "$SRC" "$DEST"' > "$addenda_probe"
printf 'REVIEW PROMPT BODY\n' > "$RB_WORK/src-prompt.md"
addenda_rc=0
REFRESH_SH="$repo_dir/scripts/fork-sandbox-refresh.sh" work_dir="$RB_WORK" \
    SRC="$RB_WORK/src-prompt.md" DEST="$RB_WORK/dest-prompt.md" \
    bash "$addenda_probe" > /dev/null 2>&1 || addenda_rc=$?
if [[ -n "$addenda_fn" && "$addenda_rc" == 0 ]] \
    && [[ ! -e "$RB_WORK/inbox/addendum-1.md" && ! -e "$RB_WORK/inbox/addendum-2.md" ]] \
    && [[ "$(head -1 "$RB_WORK/dest-prompt.md")" == 'REVIEW PROMPT BODY' ]] \
    && grep -qF 'operator addendum for leg 1' "$RB_WORK/dest-prompt.md" \
    && grep -qF 'operator addendum for leg 2' "$RB_WORK/dest-prompt.md" \
    && [[ "$(grep -n 'addendum for leg' "$RB_WORK/dest-prompt.md" | cut -d: -f1 | head -1)" \
        -lt "$(grep -n 'addendum for leg 2' "$RB_WORK/dest-prompt.md" | cut -d: -f1)" ]]; then
    ok "archived addenda are folded into the review/fix prompt copy after the refresh loop"
else
    no "archived addenda are folded into the review/fix prompt copy after the refresh loop" \
        "rc=$addenda_rc dest: $(cat "$RB_WORK/dest-prompt.md" 2>/dev/null)"
fi
# Nothing archived (refresh off / no addenda): rc 1 and no copy written.
rm -rf "$RB_WORK/inbox-delivered" "$RB_WORK/dest-prompt.md"
addenda_rc=0
REFRESH_SH="$repo_dir/scripts/fork-sandbox-refresh.sh" work_dir="$RB_WORK" \
    SRC="$RB_WORK/src-prompt.md" DEST="$RB_WORK/dest-prompt.md" \
    bash "$addenda_probe" > /dev/null 2>&1 || addenda_rc=$?
if [[ "$addenda_rc" == 1 && ! -e "$RB_WORK/dest-prompt.md" ]]; then
    ok "no archived addenda: append_archived_addenda returns 1 and writes no copy"
else
    no "no archived addenda: append_archived_addenda returns 1 and writes no copy" \
        "rc=$addenda_rc"
fi
# Without refresh.sh sourced (refresh off) the helper is inert too.
addenda_rc=0
work_dir="$RB_WORK" SRC="$RB_WORK/src-prompt.md" DEST="$RB_WORK/dest-prompt.md" \
    bash -c "$addenda_fn"'
append_archived_addenda "$SRC" "$DEST"' > /dev/null 2>&1 || addenda_rc=$?
if [[ "$addenda_rc" == 1 && ! -e "$RB_WORK/dest-prompt.md" ]]; then
    ok "append_archived_addenda is inert when refresh.sh was never sourced"
else
    no "append_archived_addenda is inert when refresh.sh was never sourced" "rc=$addenda_rc"
fi
# The review block hands the loop the addenda-carrying copies.
# shellcheck disable=SC2016
if grep -qF -- '--fix-header "$fix_header_path"' "$entrypoint_sh" \
    && grep -qF 'review_prompt_path="$work_dir/review-prompt-addenda.md"' "$entrypoint_sh" \
    && grep -qF 'fix_header_path="$work_dir/fix-prompt-header-addenda.md"' "$entrypoint_sh"; then
    ok "the pod review loop is handed the addenda-carrying review and fix prompts"
else
    no "the pod review loop is handed the addenda-carrying review and fix prompts" \
        "missing fix_header_path / review-prompt-addenda wiring in $entrypoint_sh"
fi

# Cap: REFRESH_MAX=1 with a hand-off on legs 1 and 2 -> two legs, ended cap,
# and the second hand-off is left for the operator to see in the outbox.
refresh_block_run 100000 "1 2" "" 1
if [[ "$RB_CALLS" == 2 && "$(jq -r .ended "$RB_WORK/refresh.json")" == cap ]]; then
    ok "REFRESH_MAX=1 with hand-offs on legs 1 and 2: two legs, ended cap"
else
    no "REFRESH_MAX=1 with hand-offs on legs 1 and 2: two legs, ended cap" \
        "calls=$RB_CALLS out=$RB_OUT"
fi

# A stall: leg 2 (the first continuation) hands off without committing.
# The chain ends rather than forking a third leg from it, and the stalled
# hand-off is kept as its own record.
RB_NOCOMMIT_LEGS="2" refresh_block_run 100000 "1 2" "" 6
if [[ "$RB_CALLS" == 2 ]] \
    && [[ "$(jq -r .ended "$RB_WORK/refresh.json")" == stalled ]] \
    && [[ "$(cat "$RB_WORK/handoff-stalled-2.md" 2>/dev/null)" == "handoff written by leg 2" ]] \
    && [[ ! -e "$RB_WORK/handoff-2.md" ]]; then
    ok "a continuation that hands off without committing: two legs, ended stalled"
else
    no "a continuation that hands off without committing: two legs, ended stalled" \
        "calls=$RB_CALLS out=$RB_OUT ended=$(jq -r .ended "$RB_WORK/refresh.json" 2>/dev/null)"
fi
RB_NOCOMMIT_LEGS=""

# Leg 1 (the coding leg) is exempt from the stall check: a hand-off it
# writes without committing still starts a second leg.
RB_NOCOMMIT_LEGS="1" refresh_block_run 100000 "1" "" 6
if [[ "$RB_CALLS" == 2 ]] \
    && [[ "$(jq -r .ended "$RB_WORK/refresh.json")" == empty-outbox ]]; then
    ok "leg 1 hands off without committing: not a stall, leg 2 still runs"
else
    no "leg 1 hands off without committing: not a stall, leg 2 still runs" \
        "calls=$RB_CALLS out=$RB_OUT ended=$(jq -r .ended "$RB_WORK/refresh.json" 2>/dev/null)"
fi
RB_NOCOMMIT_LEGS=""

# A continuation that crashes ends the loop with leg-error, pi_rc is its
# exit, and a hand-off it left behind is kept in /work, not the outbox.
refresh_block_run 100000 "1 2" "2" 6
if [[ "$RB_CALLS" == 2 && "$RB_RC" == 1 ]] \
    && [[ "$(jq -r .ended "$RB_WORK/refresh.json")" == leg-error ]] \
    && [[ "$(jq -r '.continuations[0].exit' "$RB_WORK/refresh.json")" == 1 ]] \
    && [[ -f "$RB_WORK/handoff-leg-2-after-error.md" && ! -e "$RB_WORK/outbox/handoff.md" ]]; then
    ok "a crashed continuation: leg-error, pi_rc is its exit, leftover hand-off kept"
else
    no "a crashed continuation: leg-error, pi_rc is its exit, leftover hand-off kept" \
        "calls=$RB_CALLS rc=$RB_RC out=$RB_OUT"
fi

# Every leg gets its own hook-state directory, leg 1 included.
refresh_block_run 100000 "1 2" "" 6
refresh_env_dirs="$(cut -d'|' -f1 "$RB_REC/envs" | xargs -n1 dirname | sort -u | wc -l)"
if [[ "$RB_CALLS" == 3 && "$refresh_env_dirs" == 3 ]] \
    && [[ "$(sed -n 1p "$RB_REC/envs")" == "$RB_REC/fs-hook-leg-1/nudged|$RB_REC/fs-hook-leg-1/nudge-reminded|$RB_REC/fs-hook-leg-1/stale-reminded|$RB_REC/fs-hook-leg-1/inbox-seen" ]] \
    && [[ "$(sed -n 3p "$RB_REC/envs")" == "$RB_REC/fs-hook-leg-3/nudged|"* ]]; then
    ok "every leg runs with its own fresh hook-state directory"
else
    no "every leg runs with its own fresh hook-state directory" \
        "dirs=$refresh_env_dirs envs: $(cat "$RB_REC/envs")"
fi

# Snapshot position: it follows the LAST continuation, so the newest
# transcript in the pushed-back store is the second continuation's (leg 3).
# shellcheck disable=SC2012  # names are fixed by the stub
if [[ "$(ls -t "$RB_WORK"/session-store/-stub-slug/ | head -1)" == leg-3.jsonl ]]; then
    ok "after two continuations the newest stored transcript is the last continuation's"
else
    no "after two continuations the newest stored transcript is the last continuation's" \
        "store: $(ls -lt "$RB_WORK"/session-store/-stub-slug/ 2>&1)"
fi

# Refresh off: no config, no loop, no hook env, no refresh.json.
refresh_block_run "" "1" "" 6
if [[ "$RB_CALLS" == 1 && "$RB_RC" == 0 ]] \
    && [[ ! -e "$RB_WORK/inbox/.refresh-config" && ! -e "$RB_WORK/refresh.json" ]] \
    && [[ "$(cat "$RB_REC/envs")" == '|||' ]] \
    && [[ -f "$RB_WORK/outbox/handoff.md" ]]; then
    ok "REFRESH_THRESHOLD_TOKENS empty: no config, no loop, no hook env, no refresh.json"
else
    no "REFRESH_THRESHOLD_TOKENS empty: no config, no loop, no hook env, no refresh.json" \
        "calls=$RB_CALLS out=$RB_OUT"
fi

ep_long="$(awk 'length > 96 { printf "%d ", FNR }' "$entrypoint_sh")"
if [[ -z "$ep_long" ]]; then
    ok "no entrypoint line exceeds 96 columns (it ships inside a ConfigMap)"
else
    no "no entrypoint line exceeds 96 columns (it ships inside a ConfigMap)" "lines: $ep_long"
fi

# The review loop always runs pi and always prefers REVIEW_MODEL over
# MODEL when set, regardless of harness -- required at startup for
# HARNESS=claude (checked above), optional otherwise.
# shellcheck disable=SC2016
if grep -qF 'review_loop_model="${REVIEW_MODEL:-$MODEL}"' "$entrypoint_sh" \
    && grep -qF 'synthesize_pi_config "$review_loop_model"' "$entrypoint_sh" \
    && grep -qF 'MODEL="$review_loop_model" bash "$mounts_dir/review-loop.sh"' "$entrypoint_sh"; then
    ok "entrypoint threads REVIEW_MODEL into the review loop's pi config and invocation"
else
    no "entrypoint threads REVIEW_MODEL into the review loop's pi config and invocation" \
        "missing review_loop_model wiring in $entrypoint_sh"
fi

# A non-zero pi exit no longer preempts the whole review-loop block -- the
# commits-based check runs first, and review-loop.sh itself decides the
# no-commits skip. The old "nothing worth reviewing" conclusion is gone
# entirely, from this file and the whole repo (regression -- kept even
# though it duplicates a grep run manually while diagnosing this bug).
if grep -qF 'nothing worth reviewing' "$entrypoint_sh"; then
    no "entrypoint's review-loop skip no longer asserts \"nothing worth reviewing\"" \
        "the literal string is still present in $entrypoint_sh"
else
    ok "entrypoint's review-loop skip no longer asserts \"nothing worth reviewing\""
fi
if ! grep -rlF 'nothing worth reviewing' -- "$repo_dir/scripts" "$repo_dir/docs" \
    >/dev/null 2>&1; then
    ok "\"nothing worth reviewing\" does not appear anywhere in scripts/ or docs/"
else
    no "\"nothing worth reviewing\" does not appear anywhere in scripts/ or docs/" \
        "$(grep -rlF 'nothing worth reviewing' -- "$repo_dir/scripts" "$repo_dir/docs" 2>/dev/null)"
fi

# The branch-readability check runs first, ahead of any pi_rc check, and
# gates only the review-loop.sh invocation -- not a bare pi_rc check
# gating the whole block, which was the bug.
# shellcheck disable=SC2016
if grep -qF 'coding_head="$(git -C "$clone_dir" rev-parse HEAD 2>/dev/null || true)"' \
    "$entrypoint_sh" \
    && grep -qF 'if [[ -z "$coding_head" ]]; then' "$entrypoint_sh"; then
    ok "entrypoint's review-loop block checks the branch head, not pi_rc, to decide skip-vs-run"
else
    no "entrypoint's review-loop block checks the branch head, not pi_rc, to decide skip-vs-run" \
        "missing the coding_head branch-readability check in $entrypoint_sh"
fi
review_block="$(awk '
    /^# The --review-loop pass, when this run carries one\./ { p=1 }
    p { print }
    p && /^fi$/ { exit }
' "$entrypoint_sh")"
if [[ -n "$review_block" ]] \
    && [[ "$(grep -c 'if \[\[ -z "\$coding_head" \]\]; then' <<<"$review_block")" == 1 ]] \
    && [[ "$(grep -c 'bash "\$mounts_dir/review-loop.sh"' <<<"$review_block")" == 1 ]]; then
    coding_head_line="$(grep -n 'if \[\[ -z "\$coding_head" \]\]; then' <<<"$review_block" \
        | cut -d: -f1)"
    review_loop_call_line="$(grep -n 'bash "\$mounts_dir/review-loop.sh"' <<<"$review_block" \
        | cut -d: -f1)"
    if (( coding_head_line < review_loop_call_line )); then
        ok "the branch-readability check precedes the review-loop.sh invocation, not the other way round"
    else
        no "the branch-readability check precedes the review-loop.sh invocation, not the other way round" \
            "coding_head check at line $coding_head_line, review-loop.sh call at line $review_loop_call_line"
    fi
else
    no "the branch-readability check precedes the review-loop.sh invocation, not the other way round" \
        "could not isolate the REVIEW_LOOP_CAP block in $entrypoint_sh"
fi

# The unreadable-branch skip states what happened, not a conclusion about
# whether the work is worth reviewing.
# shellcheck disable=SC2016
if grep -qF 'detail: ("branch " + $branch + " could not be read from the clone")' \
    "$entrypoint_sh"; then
    ok "entrypoint's unreadable-branch skip detail states what happened, not \"nothing worth reviewing\""
else
    no "entrypoint's unreadable-branch skip detail states what happened, not \"nothing worth reviewing\"" \
        "missing the branch-could-not-be-read detail string in $entrypoint_sh"
fi

# The coding leg's exit code is recorded in review-loop.json either way --
# the direct skip-write for an unreadable branch, and the post-process
# merge once review-loop.sh (which does not itself know pi's exit code)
# has written its own file.
# shellcheck disable=SC2016
if grep -qF -- '--argjson rc "$pi_rc" --arg branch "$BRANCH"' "$entrypoint_sh" \
    && grep -qF 'coding_exit_code: $rc,' "$entrypoint_sh" \
    && grep -qF "jq --argjson rc \"\$pi_rc\" '. + {coding_exit_code: \$rc}'" "$entrypoint_sh"; then
    ok "entrypoint records coding_exit_code in review-loop.json for both the skip and the run-anyway case"
else
    no "entrypoint records coding_exit_code in review-loop.json for both the skip and the run-anyway case" \
        "missing coding_exit_code wiring in $entrypoint_sh"
fi

# A non-zero pi exit gets an annotated review prompt (written under
# $work_dir since $mounts_dir is read-only), not a skip.
if grep -qF '## The coding session exited non-zero' "$entrypoint_sh" \
    && grep -qF 'review_prompt_path="$work_dir/review-prompt-annotated.md"' "$entrypoint_sh"; then
    ok "entrypoint annotates the review prompt with a non-zero-exit note instead of skipping"
else
    no "entrypoint annotates the review prompt with a non-zero-exit note instead of skipping" \
        "missing the annotated review-prompt logic in $entrypoint_sh"
fi

# A pi coding leg folds REVIEW_MODEL into models.json alongside MODEL up
# front, via a second synthesize_pi_config argument, and the function's
# own jq dedupes the two ids with `unique` so an unset REVIEW_MODEL (or
# one equal to MODEL) never produces a bogus or duplicate model entry.
# shellcheck disable=SC2016
if grep -qF 'synthesize_pi_config "$MODEL" "$REVIEW_MODEL"' "$entrypoint_sh"; then
    ok "entrypoint's pi coding leg folds REVIEW_MODEL into models.json up front"
else
    no "entrypoint's pi coding leg folds REVIEW_MODEL into models.json up front" \
        "missing synthesize_pi_config \"\$MODEL\" \"\$REVIEW_MODEL\" call in $entrypoint_sh"
fi
if grep -qF '| unique | map(' "$entrypoint_sh"; then
    ok "synthesize_pi_config's models.json dedupes MODEL/REVIEW_MODEL with jq unique"
else
    no "synthesize_pi_config's models.json dedupes MODEL/REVIEW_MODEL with jq unique" \
        "missing a '| unique |' models array in $entrypoint_sh"
fi

printf '\n== entrypoint: pod-side model discovery (curl stubbed) ==\n'
# discover_model_facts, the real function extracted from the entrypoint's
# own source and run in a subshell with a stubbed curl on PATH -- the
# same PATH-stubbing the suite already uses for kubectl. The subshell is
# what makes the function's own `exit 1` safe (it kills only the
# subshell), and on success the subshell prints the values the function
# established for the rest of the script to consume.
discover_fn="$(sed -n '/^discover_model_facts() {/,/^}/p' "$entrypoint_sh")"
discover_fn_file="$(newdir)/discover.sh"; tmpdirs+=("$(dirname "$discover_fn_file")")
if [[ -n "$discover_fn" ]]; then
    printf '%s\n' "$discover_fn" > "$discover_fn_file"
    ok "discover_model_facts is a standalone function in the entrypoint"
else
    no "discover_model_facts is a standalone function in the entrypoint" \
        "function not found in $entrypoint_sh"
fi

# Runs the extracted function in a subshell: $1 is the stub curl's stdout
# (or "FAIL" for a connection-refused stub), $2 the MODEL value (or "")
# it is handed, $3 the REVIEW_MODEL value (or ""), $4 the HARNESS value
# (default pi), $5 the ALLOW_UNLISTED_MODEL value (default unset).
# Captures combined output and the subshell's exit status in $discover_out
# / $discover_rc.
discover_run() {
    local stub_dir
    stub_dir="$(newdir)"; tmpdirs+=("$stub_dir")
    if [[ "$1" == FAIL ]]; then
        printf '%s\n' '#!/usr/bin/env bash' \
            'echo "curl: (7) Failed to connect to 10.0.0.5 port 8001: Connection refused" >&2' \
            'exit 7' > "$stub_dir/curl"
    else
        printf '%s\n' '#!/usr/bin/env bash' 'cat <<JSON' "$1" 'JSON' > "$stub_dir/curl"
    fi
    chmod +x "$stub_dir/curl"
    discover_out="$(PATH="$stub_dir:$PATH" MODEL="$2" REVIEW_MODEL="${3-}" HARNESS="${4:-pi}" \
        ALLOW_UNLISTED_MODEL="${5-}" \
        PROXY_BASE_URL="http://fork-sandbox-proxy.fork-sandbox-test.svc.cluster.local:8080/e/primary/v1" \
        bash -c 'source "$1"; discover_model_facts; \
            printf "MODEL=%s CTX=%s MAX_TOKENS=%s MODEL_CTX_SOURCE=%s REVIEW_CTX=%s REVIEW_MAX_TOKENS=%s\n" \
                "$MODEL" "$CTX" "$MAX_TOKENS" "${MODEL_CTX_SOURCE:-}" "$REVIEW_CTX" "$REVIEW_MAX_TOKENS"' \
        _ "$discover_fn_file" 2>&1)"
    discover_rc=$?
}

# A single-model response resolves MODEL and takes the context window
# from max_model_len; MAX_TOKENS is agent-sandboxed's rule -- a 32768
# floor, capped at a quarter of the window (24576/4 = 6144).
discover_run '{"data":[{"id":"qwen3-8b","max_model_len":24576}]}' ""
if (( discover_rc == 0 )) && [[ "$discover_out" == *"MODEL=qwen3-8b CTX=24576 MAX_TOKENS=6144"* ]]; then
    ok "discovery: single-model response resolves MODEL and CTX from max_model_len"
else
    no "discovery: single-model response resolves MODEL and CTX from max_model_len" \
        "rc=$discover_rc: $discover_out"
fi
if [[ "$discover_out" == *"serves exactly one model"* ]]; then
    ok "discovery: the resolved single model is announced on stderr"
else
    no "discovery: the resolved single model is announced on stderr" "$discover_out"
fi

# A large window keeps the 32768 MAX_TOKENS floor (131072/4 = 32768,
# not below the floor, so it stays) -- and the window came from the
# listing, so the context source is reported.
discover_run '{"data":[{"id":"big","max_model_len":131072}]}' ""
if [[ "$discover_out" == *"CTX=131072 MAX_TOKENS=32768 MODEL_CTX_SOURCE=reported"* ]]; then
    ok "discovery: MAX_TOKENS keeps the 32768 floor when the window is large"
else
    no "discovery: MAX_TOKENS keeps the 32768 floor when the window is large" \
        "rc=$discover_rc: $discover_out"
fi

# A listed id with no usable max_model_len reaches the guess through
# the third path to it: the default is to refuse, and
# ALLOW_UNLISTED_MODEL=1 permits the launch with a warning that names
# the guessed value as a guess. The recorded facts must be able to tell
# this 32768 apart from a 32768 that is a healthy large window's reply
# room.
discover_run '{"data":[{"id":"solo"}]}' ""
if (( discover_rc != 0 )) \
    && [[ "$discover_out" == *"for 'solo' had to be"* ]] \
    && [[ "$discover_out" == *"guessed"* ]] \
    && [[ "$discover_out" == *"no usable max_model_len"* ]] \
    && [[ "$discover_out" == *"K8S_ALLOW_UNLISTED_MODEL=1"* ]]; then
    ok "discovery: a listed id with no max_model_len refuses by default"
else
    no "discovery: a listed id with no max_model_len refuses by default" \
        "rc=$discover_rc: $discover_out"
fi
discover_run '{"data":[{"id":"solo"}]}' "" "" pi 1
if (( discover_rc == 0 )) \
    && [[ "$discover_out" == *"is a GUESS of"* ]] \
    && [[ "$discover_out" == *"32768 tokens"* ]] \
    && [[ "$discover_out" == *"MODEL=solo CTX=32768 MAX_TOKENS=8192 MODEL_CTX_SOURCE=guessed"* ]]; then
    ok "discovery: ALLOW_UNLISTED_MODEL=1 permits the guess, names it a guess, and records context_source=guessed"
else
    no "discovery: ALLOW_UNLISTED_MODEL=1 permits the guess, names it a guess, and records context_source=guessed" \
        "rc=$discover_rc: $discover_out"
fi

# Several models, no MODEL: an error naming the situation and listing
# what was found.
discover_run '{"data":[{"id":"a-model"},{"id":"b-model"}]}' ""
if (( discover_rc != 0 )) && [[ "$discover_out" == *"more than one model"* \
        && "$discover_out" == *a-model* && "$discover_out" == *b-model* ]]; then
    ok "discovery: multi-model response without MODEL errors listing the ids"
else
    no "discovery: multi-model response without MODEL errors listing the ids" \
        "rc=$discover_rc: $discover_out"
fi

# ...but a MODEL that IS in the listing goes through, unchanged.
discover_run '{"data":[{"id":"a-model","max_model_len":8192},{"id":"b-model"}]}' "a-model"
if (( discover_rc == 0 )) && [[ "$discover_out" == *"MODEL=a-model CTX=8192 MAX_TOKENS=2048"* ]]; then
    ok "discovery: a MODEL present in the listing passes through unchanged"
else
    no "discovery: a MODEL present in the listing passes through unchanged" \
        "rc=$discover_rc: $discover_out"
fi

# A MODEL that was GIVEN and is absent from the listing is refused by
# default: a warning that proceeds is indistinguishable from success
# once the pod is reaped, and the guess-low window that follows a
# missing id would then stand silently for a real one. The refusal is
# about the context having to be GUESSED, not about the id per se --
# the same refusal fires for a failed catalog fetch and for a listed
# entry with no max_model_len, all through the one check where the
# guess is returned. The error names the requested id, lists the ids
# the endpoint DOES offer, points at K8S_DEFAULT_MODEL in k8s.env, and
# names the escape hatch.
discover_run '{"data":[{"id":"a-model","max_model_len":8192}]}' "other-model"
if (( discover_rc != 0 )) \
    && [[ "$discover_out" == *"Error: "* ]] \
    && [[ "$discover_out" != *"Warning: "* ]] \
    && [[ "$discover_out" == *"for 'other-model' had to be"* ]] \
    && [[ "$discover_out" == *"guessed: the endpoint's listing does not contain that id"* ]] \
    && [[ "$discover_out" == *"  a-model"* ]] \
    && [[ "$discover_out" == *"K8S_DEFAULT_MODEL in k8s.env"* ]] \
    && [[ "$discover_out" == *"K8S_ALLOW_UNLISTED_MODEL=1"* ]] \
    && [[ "$discover_out" != *"MODEL=other-model"* ]]; then
    ok "discovery: an unlisted MODEL refuses the run by default, naming the offered ids and K8S_DEFAULT_MODEL"
else
    no "discovery: an unlisted MODEL refuses the run by default, naming the offered ids and K8S_DEFAULT_MODEL" \
        "rc=$discover_rc: $discover_out"
fi
# ...with more than one offered id, the error lists them all, not just the
# first.
discover_run '{"data":[{"id":"a-model","max_model_len":8192},{"id":"b-model"}]}' "other-model"
if (( discover_rc != 0 )) \
    && [[ "$discover_out" == *"  a-model"* && "$discover_out" == *"  b-model"* ]]; then
    ok "discovery: the refusal lists every id the endpoint offers"
else
    no "discovery: the refusal lists every id the endpoint offers" \
        "rc=$discover_rc: $discover_out"
fi
# ALLOW_UNLISTED_MODEL=1 restores the old warn-and-proceed for the same
# situation -- the explicit door for a stale listing -- naming the
# guessed value as a guess.
discover_run '{"data":[{"id":"a-model","max_model_len":8192}]}' "other-model" "" pi 1
if (( discover_rc == 0 )) \
    && [[ "$discover_out" == *"is a GUESS of"* ]] \
    && [[ "$discover_out" == *"32768 tokens"* ]] \
    && [[ "$discover_out" == *"does not contain that id"* ]] \
    && [[ "$discover_out" == *"ALLOW_UNLISTED_MODEL=1"* ]] \
    && [[ "$discover_out" == *"MODEL=other-model CTX=32768 MAX_TOKENS=8192 MODEL_CTX_SOURCE=guessed"* ]]; then
    ok "discovery: ALLOW_UNLISTED_MODEL=1 restores warn-and-proceed for an unlisted MODEL, naming the guess"
else
    no "discovery: ALLOW_UNLISTED_MODEL=1 restores warn-and-proceed for an unlisted MODEL, naming the guess" \
        "rc=$discover_rc: $discover_out"
fi

# The --harness claude case: MODEL is a Claude Code model name the pi
# endpoint's listing never contains and no pi leg of this run uses, so
# it is neither checked against the listing nor looked up per-model --
# no warning about it, and the summary names the review model. The
# review loop's window must come from REVIEW_MODEL's own entry, not
# inherit MODEL's.
discover_run '{"data":[{"id":"qwen3-8b","max_model_len":24576}]}' "claude-opus-5" "qwen3-8b" claude
if (( discover_rc == 0 )) && [[ "$discover_out" == *"MODEL=claude-opus-5 CTX=32768 MAX_TOKENS=8192"* \
        && "$discover_out" == *"REVIEW_CTX=24576 REVIEW_MAX_TOKENS=6144"* \
        && "$discover_out" == *"review model qwen3-8b at"* \
        && "$discover_out" != *"does not list"* \
        && "$discover_out" != *"does not report a context length"* ]]; then
    ok "discovery: on a claude run the Claude Code name is not probed and the review model's window stands"
else
    no "discovery: on a claude run the Claude Code name is not probed and the review model's window stands" \
        "rc=$discover_rc: $discover_out"
fi
# ...and a REVIEW_MODEL absent from the listing is a refusal of its own:
# the review loop is a pi leg, and its guessed context is the same
# class of damage.
discover_run '{"data":[{"id":"a-model","max_model_len":8192}]}' "a-model" "other-model"
if (( discover_rc != 0 )) \
    && [[ "$discover_out" == *"for 'other-model' had to be"* ]] \
    && [[ "$discover_out" != *"MODEL=a-model"* ]]; then
    ok "discovery: a REVIEW_MODEL absent from the listing refuses the run"
else
    no "discovery: a REVIEW_MODEL absent from the listing refuses the run" \
        "rc=$discover_rc: $discover_out"
fi
# ...and with ALLOW_UNLISTED_MODEL=1 the review model's guessed
# context is permitted, with the real MODEL's window untouched.
discover_run '{"data":[{"id":"a-model","max_model_len":8192}]}' "a-model" "other-model" pi 1
if (( discover_rc == 0 )) \
    && [[ "$discover_out" == *"MODEL=a-model CTX=8192 MAX_TOKENS=2048"* ]] \
    && [[ "$discover_out" == *"is a GUESS of"* ]] \
    && [[ "$discover_out" == *"32768 tokens"* ]] \
    && [[ "$discover_out" == *"REVIEW_CTX=32768 REVIEW_MAX_TOKENS=8192"* ]]; then
    ok "discovery: ALLOW_UNLISTED_MODEL=1 permits the review model's guessed context"
else
    no "discovery: ALLOW_UNLISTED_MODEL=1 permits the review model's guessed context" \
        "rc=$discover_rc: $discover_out"
fi
# ...and a case-variant REVIEW_MODEL that IS listed matches case-
# insensitively and gets the real window, not the guess.
discover_run '{"data":[{"id":"a-model","max_model_len":8192}]}' "a-model" "A-model"
if (( discover_rc == 0 )) \
    && [[ "$discover_out" == *"REVIEW_CTX=8192 REVIEW_MAX_TOKENS=2048"* ]] \
    && [[ "$discover_out" != *"GUESS"* ]]; then
    ok "discovery: a case-variant REVIEW_MODEL that is listed matches and gets the real window"
else
    no "discovery: a case-variant REVIEW_MODEL that is listed matches and gets the real window" \
        "rc=$discover_rc: $discover_out"
fi
# ...and with no separate review model, the review loop falls back to
# MODEL and shares its window.
discover_run '{"data":[{"id":"a-model","max_model_len":8192}]}' "a-model"
if (( discover_rc == 0 )) && [[ "$discover_out" == *"REVIEW_CTX=8192 REVIEW_MAX_TOKENS=2048"* ]]; then
    ok "discovery: no REVIEW_MODEL shares MODEL's window with the review loop"
else
    no "discovery: no REVIEW_MODEL shares MODEL's window with the review loop" \
        "rc=$discover_rc: $discover_out"
fi

# A curl failure with no model to fall back on -- the ordinary
# connection-refused state of a workstation-class endpoint -- errors
# naming the URL, and reads like operations rather than a stack trace.
discover_run FAIL ""
if (( discover_rc != 0 )) \
    && [[ "$discover_out" == *"/e/primary/v1/models"* \
        && "$discover_out" == *"Connection refused"* \
        && "$discover_out" == *"expected, ordinary state"* ]]; then
    ok "discovery: a curl failure without a configured MODEL errors naming the URL, ops-flavoured"
else
    no "discovery: a curl failure without a configured MODEL errors naming the URL, ops-flavoured" \
        "rc=$discover_rc: $discover_out"
fi
# A catalog fetch that FAILS with a model already configured reaches
# the guess through the second path to it: the default is to refuse,
# ops-flavoured, and ALLOW_UNLISTED_MODEL=1 permits the launch.
discover_run FAIL "a-model"
if (( discover_rc != 0 )) \
    && [[ "$discover_out" == *"/e/primary/v1/models"* \
        && "$discover_out" == *"Connection refused"* \
        && "$discover_out" == *"for 'a-model' had to be"* \
        && "$discover_out" == *"expected, ordinary state"* \
        && "$discover_out" == *"Start the endpoint and resubmit"* ]]; then
    ok "discovery: a failed catalog fetch with a configured MODEL refuses, ops-flavoured"
else
    no "discovery: a failed catalog fetch with a configured MODEL refuses, ops-flavoured" \
        "rc=$discover_rc: $discover_out"
fi
discover_run FAIL "a-model" "" pi 1
if (( discover_rc == 0 )) \
    && [[ "$discover_out" == *"is a GUESS of"* ]] \
    && [[ "$discover_out" == *"32768 tokens"* ]] \
    && [[ "$discover_out" == *"MODEL=a-model CTX=32768 MAX_TOKENS=8192 MODEL_CTX_SOURCE=guessed"* ]]; then
    ok "discovery: ALLOW_UNLISTED_MODEL=1 permits a launch whose catalog could not be read"
else
    no "discovery: ALLOW_UNLISTED_MODEL=1 permits a launch whose catalog could not be read" \
        "rc=$discover_rc: $discover_out"
fi
# ...and an UNPARSEABLE catalog answer is the same refusal class.
discover_run '{"not":"a model list"}' "a-model"
if (( discover_rc != 0 )) \
    && [[ "$discover_out" == *"no model list"* ]] \
    && [[ "$discover_out" == *"for 'a-model' had to be"* ]]; then
    ok "discovery: an unparseable catalog answer refuses when a MODEL is configured"
else
    no "discovery: an unparseable catalog answer refuses when a MODEL is configured" \
        "rc=$discover_rc: $discover_out"
fi
# The gateway's lookup is case-insensitive but /v1/models reports the
# canonical spelling: a case-variant id that IS listed must not be a
# miss, and the run records the LISTING's spelling -- while a
# case-variant id that is not listed under any spelling is still a
# miss.
discover_run '{"data":[{"id":"Qwen3-8B","max_model_len":24576}]}' "qwen3-8b"
if (( discover_rc == 0 )) \
    && [[ "$discover_out" == *"MODEL=Qwen3-8B CTX=24576 MAX_TOKENS=6144 MODEL_CTX_SOURCE=reported"* ]] \
    && [[ "$discover_out" == *"uses the listing's"* ]]; then
    ok "discovery: a case-variant listed id matches and the run records the canonical spelling"
else
    no "discovery: a case-variant listed id matches and the run records the canonical spelling" \
        "rc=$discover_rc: $discover_out"
fi
discover_run '{"data":[{"id":"a-model","max_model_len":8192}]}' "B-MODEL"
if (( discover_rc != 0 )) \
    && [[ "$discover_out" == *"for 'B-MODEL' had to be"* ]]; then
    ok "discovery: a case-variant id not listed under any spelling still refuses"
else
    no "discovery: a case-variant id not listed under any spelling still refuses" \
        "rc=$discover_rc: $discover_out"
fi

# The ordering the design doc's health-check requirement records: discovery
# runs BEFORE the repository-receive wait, so a dead endpoint fails in
# seconds instead of after the whole submit dance. It must ALSO run
# AFTER the bare repository's git init: the agent container has no
# readinessProbe, so the host's push can land the moment the container
# starts, and a discovery ahead of the git init would race that push
# against a nonexistent /work/repo.git and fail a healthy run.
# shellcheck disable=SC2016  # needle is literal entrypoint text
discover_call_line="$(grep -nE '^[[:space:]]*discover_model_facts[[:space:]]*$' "$entrypoint_sh" | head -n1 | cut -d: -f1)"
sentinel_wait_line="$(grep -nF 'waiting for $sentinel' "$entrypoint_sh" | head -n1 | cut -d: -f1)"
git_init_line="$(grep -nF 'git init --quiet --bare "$repo_bare"' "$entrypoint_sh" | head -n1 | cut -d: -f1)"
if [[ -n "$git_init_line" && -n "$discover_call_line" && -n "$sentinel_wait_line" \
        && "$git_init_line" -lt "$discover_call_line" \
        && "$discover_call_line" -lt "$sentinel_wait_line" ]]; then
    ok "discovery runs after git init and before the repository-receive wait"
else
    no "discovery runs after git init and before the repository-receive wait" \
        "git init line '$git_init_line', discovery call line '$discover_call_line', sentinel wait line '$sentinel_wait_line'"
fi
if grep -qF 'if [[ -n "$MODEL_DISCOVERY" ]]; then' "$entrypoint_sh" \
    && grep -qF 'CTX=131072' "$entrypoint_sh" \
    && grep -qF 'REVIEW_MAX_TOKENS=32768' "$entrypoint_sh"; then
    ok "discovery is gated on MODEL_DISCOVERY, with the legacy constants kept in the else branch"
else
    no "discovery is gated on MODEL_DISCOVERY, with the legacy constants kept in the else branch" \
        "missing the MODEL_DISCOVERY gate or the legacy 131072/32768 constants in $entrypoint_sh"
fi
# .fork-sandbox-model: line 1 stays the bare model id (an existing
# reader), the discovered context facts append as key=value lines, and
# they append ONLY when MODEL's own discovery produced them -- a
# claude run's stand-in constants do not belong to the Claude Code name
# line 1 carries, and a legacy run has no facts at all.
if grep -qF "printf '%s\n' \"\$MODEL\"" "$entrypoint_sh" \
    && grep -qF "printf 'context=%s\nmax_tokens=%s\ncontext_source=%s\n'" "$entrypoint_sh" \
    && grep -qF 'if [[ -n "${MODEL_CTX_SOURCE:-}" ]]; then' "$entrypoint_sh"; then
    ok "the model metadata dotfile keeps a bare id on line 1 and appends context facts only when discovered"
else
    no "the model metadata dotfile keeps a bare id on line 1 and appends context facts only when discovered" \
        "missing the bare-first-line write or the MODEL_CTX_SOURCE guard in $entrypoint_sh"
fi
if grep -qF ': "${MODEL:?MODEL must be set to a model id}"' "$entrypoint_sh"; then
    no "the entrypoint no longer hard-requires MODEL at startup" \
        "the old MODEL:? required-var check is still there"
else
    ok "the entrypoint no longer hard-requires MODEL at startup"
fi
if grep -qF 'contextWindow: 131072' "$entrypoint_sh" \
    || grep -qF 'maxTokens: 32768' "$entrypoint_sh"; then
    no "synthesize_pi_config carries no hardcoded contextWindow/maxTokens" \
        "a hardcoded 131072/32768 is still in the models.json render in $entrypoint_sh"
else
    ok "synthesize_pi_config carries no hardcoded contextWindow/maxTokens"
fi
# A repository push that fails because the pod's container already died
# (the entrypoint's fail-fast model discovery, on an K8S_PROXY_ENDPOINTS
# install with a dead endpoint) must surface the container's log -- git's
# own "connection refused" tells the operator nothing, and nothing else
# in this script reads the pod log.
if grep -qF -- '"$push_src:refs/heads/$branch") || push_rc=$?' "$k8s_sh" \
    && grep -A4 -F 'if (( push_rc != 0 )); then' "$k8s_sh" \
        | grep -qF 'kubectl logs "$pod_name"'; then
    ok "a failed repository push surfaces the pod's container log"
else
    no "a failed repository push surfaces the pod's container log" \
        "the push failure branch in $k8s_sh does not dump the container log"
fi
# Per-model windows, EXECUTED rather than grepped: the real
# synthesize_pi_config, extracted from the entrypoint's own source the
# same way discover_model_facts above is, run in a subshell against a
# throwaway HOME with two ids and DISTINCT coding/review windows. A
# models.json that is never written, a jq program that does not parse,
# or one id's window stamped onto the other all fail this; grepping the
# function's own source text would pass all three.
synth_fn="$(sed -n '/^synthesize_pi_config() {/,/^}/p' "$entrypoint_sh")"
synth_fn_file="$(newdir)/synthesize.sh"; tmpdirs+=("$(dirname "$synth_fn_file")")
if [[ -n "$synth_fn" ]]; then
    printf '%s\n' "$synth_fn" > "$synth_fn_file"
    ok "synthesize_pi_config is a standalone function in the entrypoint"
else
    no "synthesize_pi_config is a standalone function in the entrypoint" \
        "function not found in $entrypoint_sh"
fi

# Runs the extracted function in a subshell (so its `exit 1` kills only
# the subshell); the six arguments are passed through as-is. The
# rendered models.json is left in a throwaway HOME, captured in
# $synth_home, and $synth_out / $synth_rc hold the combined output and
# the subshell's exit status.
synth_run() {
    local home mounts
    home="$(newdir)"; tmpdirs+=("$home")
    mounts="$(newdir)"; tmpdirs+=("$mounts")
    synth_home="$home"
    synth_out="$(HOME="$home" mounts_dir="$mounts" \
        PROXY_BASE_URL="http://fork-sandbox-proxy.fork-sandbox-test.svc.cluster.local:8080/e/primary/v1" \
        bash -c 'source "$1"; synthesize_pi_config \
            "${2-}" "${3-}" "${4-}" "${5-}" "${6-}" "${7-}"' \
        _ "$synth_fn_file" "$@" 2>&1)"
    synth_rc=$?
}

# Two ids with distinct windows: each entry in models.json must carry
# the window for ITS OWN id, never one id's value stamped onto the
# other.
synth_run coder reviewer 24576 6144 98304 24576
synth_models="$(jq -r '.providers.proxy.models[] | "\(.id)=\(.contextWindow)/\(.maxTokens)"' \
    "$synth_home/.pi/agent/models.json" 2>/dev/null | sort)"
if (( synth_rc == 0 )) \
    && [[ "$synth_models" == *"coder=24576/6144"* && "$synth_models" == *"reviewer=98304/24576"* ]]; then
    ok "synthesize_pi_config renders each models.json id from its own window (executed)"
else
    no "synthesize_pi_config renders each models.json id from its own window (executed)" \
        "rc=$synth_rc: $synth_out; models.json: $synth_models"
fi
# ...and with no second model, exactly one entry, from the first pair.
synth_run coder "" 8192 2048 "" ""
synth_models="$(jq -r '.providers.proxy.models[] | "\(.id)=\(.contextWindow)/\(.maxTokens)"' \
    "$synth_home/.pi/agent/models.json" 2>/dev/null | sort)"
if (( synth_rc == 0 )) && [[ "$synth_models" == "coder=8192/2048" ]]; then
    ok "synthesize_pi_config with no second model renders exactly one entry (executed)"
else
    no "synthesize_pi_config with no second model renders exactly one entry (executed)" \
        "rc=$synth_rc: $synth_out; models.json: $synth_models"
fi
if grep -A1 -qF -- 'synthesize_pi_config "$MODEL" "$REVIEW_MODEL"' "$entrypoint_sh" \
    && grep -A1 -F 'synthesize_pi_config "$MODEL" "$REVIEW_MODEL"' "$entrypoint_sh" \
        | grep -qF -- '"$CTX" "$MAX_TOKENS" "$REVIEW_CTX" "$REVIEW_MAX_TOKENS"'; then
    ok "the pi coding leg's synthesize_pi_config passes both models' discovered windows"
else
    no "the pi coding leg's synthesize_pi_config passes both models' discovered windows" \
        "missing a per-model CTX/MAX_TOKENS wiring in $entrypoint_sh"
fi
if grep -A1 -F 'synthesize_pi_config "$review_loop_model"' "$entrypoint_sh" \
    | grep -qF -- '"$REVIEW_CTX" "$REVIEW_MAX_TOKENS"'; then
    ok "a claude coding leg's synthesize_pi_config uses the review model's own window"
else
    no "a claude coding leg's synthesize_pi_config uses the review model's own window" \
        "missing the REVIEW_CTX/REVIEW_MAX_TOKENS wiring in the claude branch of $entrypoint_sh"
fi

printf '\n== fork-sandbox-k8s.sh: fork-sandbox/owner and free-form --label ==\n'
# A fresh config dir carrying the same base k8s.env as $config_dir above, plus
# whatever extra lines this test needs appended (K8S_RUN_OWNER, K8S_RUN_LABELS)
# -- kept separate from $config_dir so these fixtures never interact with the
# many other tests that already depend on that dir's exact k8s.env content.
mk_label_config() {
    local d; d="$(newdir)"; tmpdirs+=("$d")
    {
        cat <<'CONF'
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_UPSTREAM=https://openrouter.ai
K8S_DENIED_PROBE=10.0.0.1:443
K8S_RUN_TTL=1800
CONF
        printf '%s\n' "$@"
    } > "$d/k8s.env"
    install -m 600 /dev/null "$d/pi.env"
    printf 'OPENROUTER_API_KEY=sk-test-dummy\n' >> "$d/pi.env"
    chmod 600 "$d/pi.env"
    printf '%s' "$d"
}

# 1. K8S_RUN_OWNER renders on the ConfigMap, Job and Pod-template labels (3
# render sites -- see build_extra_label_lines/render_extra_labels_indent).
owner_env_dir="$(mk_label_config 'K8S_RUN_OWNER=example-team')"
owner_env_out="$(newdir)/owner-env.yaml"; tmpdirs+=("$(dirname "$owner_env_out")")
FORK_SANDBOX_CONFIG_DIR="$owner_env_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3 \
    "$proj_dir" "$handoff_file" > "$owner_env_out" 2>/tmp/fs-k8s-test-owner.err
check "K8S_RUN_OWNER renders fork-sandbox/owner on all 3 render sites" 3 \
    "$(grep -cF 'fork-sandbox/owner: example-team' "$owner_env_out")"

# 2. $USER fallback when K8S_RUN_OWNER is unset.
user_owner_out="$(newdir)/user-owner.yaml"; tmpdirs+=("$(dirname "$user_owner_out")")
USER=alice FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3 \
    "$proj_dir" "$handoff_file" > "$user_owner_out" 2>/tmp/fs-k8s-test-user-owner.err
check "\$USER is used as fork-sandbox/owner when K8S_RUN_OWNER is unset" 3 \
    "$(grep -cF 'fork-sandbox/owner: alice' "$user_owner_out")"

# 3. A $USER needing sanitizing (uppercase, a dot, a trailing '$') is
# lowercased, has disallowed characters mapped to '-', and is trimmed --
# k8s_safe_name_component's own transform, reused as the owner sanitizer.
sanitize_owner_out="$(newdir)/sanitize-owner.yaml"; tmpdirs+=("$(dirname "$sanitize_owner_out")")
USER='Alice.Smith$' FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3 \
    "$proj_dir" "$handoff_file" > "$sanitize_owner_out" 2>/tmp/fs-k8s-test-sanitize-owner.err
check "a \$USER needing sanitizing renders sanitized as fork-sandbox/owner" 3 \
    "$(grep -cF 'fork-sandbox/owner: alice-smith' "$sanitize_owner_out")"

# 3b. A $USER whose sanitized form would begin with a hyphen. This is the
# case k8s_safe_name_component alone does NOT handle: its trim removes one
# hyphen per end, which suffices for an object name (rendered as
# "prefix-component", so a leftover hyphen lands interior) and not for a
# standalone label value, which the API server requires to begin and end
# alphanumeric. '..bob' sanitizes to '--bob' and must render as 'bob'.
edge_owner_out="$(newdir)/edge-owner.yaml"; tmpdirs+=("$(dirname "$edge_owner_out")")
USER='..bob' FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3 \
    "$proj_dir" "$handoff_file" > "$edge_owner_out" 2>/tmp/fs-k8s-test-edge-owner.err
check "a \$USER sanitizing to a leading hyphen renders trimmed" 3 \
    "$(grep -cF 'fork-sandbox/owner: bob' "$edge_owner_out")"
if grep -q 'fork-sandbox/owner: -' "$edge_owner_out"; then
    no "no fork-sandbox/owner value begins with a hyphen" \
        "found a hyphen-leading owner value in $edge_owner_out"
else
    ok "no fork-sandbox/owner value begins with a hyphen"
fi

# 3c. A $USER over the 63-character label-value cap is truncated, and the
# truncation itself must not leave a trailing hyphen. 62 'a's then '-xy'
# truncates at 63 to 62 'a's plus '-', whose trailing hyphen is trimmed.
long_owner_out="$(newdir)/long-owner.yaml"; tmpdirs+=("$(dirname "$long_owner_out")")
long_user="$(printf 'a%.0s' $(seq 62))-xy"
USER="$long_user" FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3 \
    "$proj_dir" "$handoff_file" > "$long_owner_out" 2>/tmp/fs-k8s-test-long-owner.err
check "an over-long \$USER renders capped at 63 with no trailing hyphen" 3 \
    "$(grep -cF "fork-sandbox/owner: $(printf 'a%.0s' $(seq 62))" "$long_owner_out")"
if grep -qE 'fork-sandbox/owner: .{64,}' "$long_owner_out"; then
    no "no fork-sandbox/owner value exceeds 63 characters" \
        "found an over-long owner value in $long_owner_out"
else
    ok "no fork-sandbox/owner value exceeds 63 characters"
fi

# 4. Neither K8S_RUN_OWNER nor a usable $USER: the label is omitted entirely,
# never invented -- see resolve_run_owner's own header comment.
no_owner_out="$(newdir)/no-owner.yaml"; tmpdirs+=("$(dirname "$no_owner_out")")
USER='' FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3 \
    "$proj_dir" "$handoff_file" > "$no_owner_out" 2>/tmp/fs-k8s-test-no-owner.err
if grep -q 'fork-sandbox/owner:' "$no_owner_out"; then
    no "the fork-sandbox/owner label is omitted when neither K8S_RUN_OWNER nor \$USER yields a value" \
        "found a fork-sandbox/owner label in $no_owner_out"
else
    ok "the fork-sandbox/owner label is omitted when neither K8S_RUN_OWNER nor \$USER yields a value"
fi

# 5. An invalid explicit K8S_RUN_OWNER (a space) is refused before anything is
# created -- the asymmetry with $USER (sanitized, never refused) is deliberate.
bad_owner_dir="$(mk_label_config 'K8S_RUN_OWNER=bad owner')"
refuses "an invalid explicit K8S_RUN_OWNER is refused, naming the key and the rule" \
    "K8S_RUN_OWNER='bad owner'" \
    env FORK_SANDBOX_CONFIG_DIR="$bad_owner_dir" "$k8s_sh" install --dry-run

# 6. A --label pair renders under the fixed fork-sandbox.io/ prefix on the
# same 3 render sites as the owner label.
plain_label_out="$(newdir)/plain-label.yaml"; tmpdirs+=("$(dirname "$plain_label_out")")
FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3 --label extra=example-value \
    "$proj_dir" "$handoff_file" > "$plain_label_out" 2>/tmp/fs-k8s-test-plain-label.err
check "--label renders fork-sandbox.io/<key> on all 3 render sites" 3 \
    "$(grep -cF 'fork-sandbox.io/extra: example-value' "$plain_label_out")"

# 7. The same --label also renders on the per-run claude-proxy's 4 objects
# (ConfigMap, Pod, Service, NetworkPolicy), for a total of 7 -- and the
# __EXTRA_LABELS__ marker never survives into real output, with or without a
# label set.
claude_label_out="$(newdir)/claude-label.yaml"; tmpdirs+=("$(dirname "$claude_label_out")")
HOME="$claude_home" FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model claude-sonnet-5 --harness claude \
    --label extra=example-value \
    "$proj_dir" "$handoff_file" > "$claude_label_out" 2>/tmp/fs-k8s-test-claude-label.err
check "--label renders on the claude-proxy objects too (7 render sites total)" 7 \
    "$(grep -cF 'fork-sandbox.io/extra: example-value' "$claude_label_out")"
if grep -q '__EXTRA_LABELS__' "$claude_label_out"; then
    no "the __EXTRA_LABELS__ marker never survives into real output (labels set)" \
        "found __EXTRA_LABELS__ in $claude_label_out"
else
    ok "the __EXTRA_LABELS__ marker never survives into real output (labels set)"
fi
if grep -q '__EXTRA_LABELS__' "$claude_submit_out"; then
    no "the __EXTRA_LABELS__ marker never survives into real output (no labels set)" \
        "found __EXTRA_LABELS__ in $claude_submit_out"
else
    ok "the __EXTRA_LABELS__ marker never survives into real output (no labels set)"
fi

# 8. K8S_RUN_LABELS supplies file-level defaults with no --label flag at all.
run_labels_dir="$(mk_label_config 'K8S_RUN_LABELS=team=example-team,purpose=demo')"
run_labels_out="$(newdir)/run-labels.yaml"; tmpdirs+=("$(dirname "$run_labels_out")")
FORK_SANDBOX_CONFIG_DIR="$run_labels_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3 \
    "$proj_dir" "$handoff_file" > "$run_labels_out" 2>/tmp/fs-k8s-test-run-labels.err
if grep -qF 'fork-sandbox.io/team: example-team' "$run_labels_out" \
    && grep -qF 'fork-sandbox.io/purpose: demo' "$run_labels_out"; then
    ok "K8S_RUN_LABELS supplies file-level label defaults"
else
    no "K8S_RUN_LABELS supplies file-level label defaults" "not found in $run_labels_out"
fi

# 9. A --label overrides one key from K8S_RUN_LABELS while a file-only key
# survives, and the override is announced on stderr.
override_out="$(newdir)/override.yaml"; tmpdirs+=("$(dirname "$override_out")")
FORK_SANDBOX_CONFIG_DIR="$run_labels_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3 --label team=override-team \
    "$proj_dir" "$handoff_file" > "$override_out" 2>/tmp/fs-k8s-test-override.err
if grep -qF 'fork-sandbox.io/team: override-team' "$override_out" \
    && ! grep -qF 'fork-sandbox.io/team: example-team' "$override_out" \
    && grep -qF 'fork-sandbox.io/purpose: demo' "$override_out"; then
    ok "--label overrides one K8S_RUN_LABELS key while a file-only key survives"
else
    no "--label overrides one K8S_RUN_LABELS key while a file-only key survives" \
        "not found in $override_out"
fi
if grep -qF "overrides K8S_RUN_LABELS's 'team=example-team'." /tmp/fs-k8s-test-override.err; then
    ok "the --label override is announced on stderr"
else
    no "the --label override is announced on stderr" "$(cat /tmp/fs-k8s-test-override.err)"
fi
rm -f /tmp/fs-k8s-test-owner.err /tmp/fs-k8s-test-user-owner.err \
    /tmp/fs-k8s-test-sanitize-owner.err /tmp/fs-k8s-test-no-owner.err \
    /tmp/fs-k8s-test-plain-label.err /tmp/fs-k8s-test-claude-label.err \
    /tmp/fs-k8s-test-run-labels.err /tmp/fs-k8s-test-override.err

# 10. Refusals, each naming the offending entry, nothing created.
refuses "--label with the reserved key 'app' is refused" \
    "'app', which is reserved" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3 --label app=x \
    "$proj_dir" "$handoff_file"
refuses "--label with the reserved key 'fork-sandbox/branch' is refused" \
    "'fork-sandbox/branch', which is reserved" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3 --label fork-sandbox/branch=x \
    "$proj_dir" "$handoff_file"
refuses "a --label entry with no '=' is refused" \
    "has no '='" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3 --label noequals \
    "$proj_dir" "$handoff_file"
refuses "a --label with a space in the key is refused" \
    "not a valid label key" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3 --label "bad key=x" \
    "$proj_dir" "$handoff_file"
refuses "a --label with a leading hyphen in the key is refused" \
    "not a valid label key" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3 --label "-badkey=x" \
    "$proj_dir" "$handoff_file"
refuses "a --label with a space in the value is refused" \
    "not a valid label" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3 --label "key=bad value" \
    "$proj_dir" "$handoff_file"
long_value="$(printf 'a%.0s' {1..70})"
refuses "a --label value over 63 characters is refused" \
    "not a valid label" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3 --label "key=$long_value" \
    "$proj_dir" "$handoff_file"
refuses "a duplicate key among --label flags on one invocation is refused" \
    "repeats key 'dup'" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3 --label dup=1 --label dup=2 \
    "$proj_dir" "$handoff_file"
dup_labels_dir="$(mk_label_config 'K8S_RUN_LABELS=dup=1,dup=2')"
refuses "a duplicate key within K8S_RUN_LABELS itself is refused" \
    "already set earlier in K8S_RUN_LABELS" \
    env FORK_SANDBOX_CONFIG_DIR="$dup_labels_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model moonshotai/kimi-k3 \
    "$proj_dir" "$handoff_file"

# 11. Regression: the existing selector labels are unchanged, with and
# without owner/free-form labels set -- this is the check that matters most,
# since app/fork-sandbox/branch gate access to a run's claude-proxy and its
# operator access token (see k8s_validate_label_kv's own header comment).
check "app: fork-sandbox-agent is unchanged with no labels set" 3 \
    "$(grep -cF 'app: fork-sandbox-agent' "$submit_out")"
check "fork-sandbox/branch is unchanged with no labels set" 3 \
    "$(grep -cF 'fork-sandbox/branch: fork-sandbox-agent-fs-k8s-test-branch' "$submit_out")"
check "app: fork-sandbox-agent is unchanged with owner+labels set" 3 \
    "$(grep -cF 'app: fork-sandbox-agent' "$plain_label_out")"
check "fork-sandbox/branch is unchanged with owner+labels set" 3 \
    "$(grep -cF 'fork-sandbox/branch: fork-sandbox-agent-fs-k8s-test-branch' "$plain_label_out")"

# 12. The load-bearing isolation property: a claude-proxy render with BOTH
# K8S_RUN_OWNER and --label set on the same invocation must not leak either
# into any selector/matchLabels/podSelector block -- a run whose pod could
# carry another run's fork-sandbox/branch value would be admitted to that
# run's proxy and could spend that operator's real Anthropic token.
combined_dir="$(mk_label_config 'K8S_RUN_OWNER=example-team')"
combined_out="$(newdir)/combined.yaml"; tmpdirs+=("$(dirname "$combined_out")")
HOME="$claude_home" FORK_SANDBOX_CONFIG_DIR="$combined_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-branch --model claude-sonnet-5 --harness claude \
    --label extra=example-value \
    "$proj_dir" "$handoff_file" > "$combined_out" 2>/tmp/fs-k8s-test-combined.err
selector_block="$(grep -A4 -E 'selector:|matchLabels:' "$combined_out" || true)"
if grep -qF 'fork-sandbox/owner' <<< "$selector_block" || grep -qF 'fork-sandbox.io/' <<< "$selector_block"; then
    no "no selector/matchLabels block leaks fork-sandbox/owner or a fork-sandbox.io/ label" \
        "$selector_block"
else
    ok "no selector/matchLabels block leaks fork-sandbox/owner or a fork-sandbox.io/ label"
fi
rm -f /tmp/fs-k8s-test-combined.err

printf '\n== no private-hostname shape anywhere in the repo ==\n'
# Guards the public-repo leak rule (see the fork-sandbox-k8s.sh header): no
# real hostname, cluster name or LAN address may be committed, only
# placeholders such as registry.example or your-cluster. .git is excluded
# (irrelevant to a checkout's own content) and this test file is excluded
# (it must be allowed to name the pattern it looks for without tripping on
# itself). 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16 and
# 100.64.0.0/10 are excluded when they appear as CIDR examples (a trailing
# /N) -- this project's own docs and manifests document those ranges by
# name, deliberately, as the excluded set in an egress policy.
#
# K8S_PROXY_ALLOW_NS/K8S_PROXY_ENDPOINTS (see e950fdbb31/d1a6c7f71f/
# 6d2bf0b0e9) made a new class of leak possible: an in-cluster Service DNS
# name, <svc>.<ns>.svc.<K8S_CLUSTER_DOMAIN>, carries real service/namespace
# names and, when K8S_CLUSTER_DOMAIN is overridden, a real cluster domain
# -- neither shape existed in this tool's config surface before. The
# placeholder convention this repo already uses everywhere for that shape
# (cluster.local as the domain, invented names like svc-a/example-ns) has
# no recognizable real-world TLD, so a `.svc.<label>.<real TLD>` occurrence
# is what a future commit pasting a real cluster's domain into a doc,
# fixture or commit message would look like; caught here, distinctly from
# the LAN/CIDR shapes above. A real cluster domain is very often itself
# multi-label (e.g. k8s.acme.com, cluster.prod.example.com), so the
# `.svc.` branch allows one or more labels before the TLD rather than
# exactly one. A bare `K8S_CLUSTER_DOMAIN=` assignment gets its own
# alternative, with no `.svc.` prefix required: a site's k8s.env could
# paste a real domain into that line, or a doc/commit message could quote
# the value, without ever forming a `.svc.` string anywhere.
# shellcheck disable=SC2016  # the regex is meant literally, not expanded
leak_pattern='[[:alnum:]-]+\.home\.lan\b|[[:alnum:]-]+\.lan\b|192\.168\.[0-9]+\.[0-9]+'
leak_pattern+='|\.svc\.([a-z0-9-]+\.)+(com|net|org|io|dev|ai|corp|internal)\b'
leak_pattern+='|\bK8S_CLUSTER_DOMAIN=([a-z0-9-]+\.)+(com|net|org|io|dev|ai|corp|internal)\b'
hits="$(grep -rEn --exclude-dir=.git --exclude='fork-sandbox-k8s-test.sh' \
    "$leak_pattern" "$repo_dir" 2>/dev/null \
    | grep -Ev '192\.168\.0\.0/16' || true)"
if [[ -z "$hits" ]]; then
    ok "no private-hostname shape in the repo"
else
    no "no private-hostname shape in the repo" "$hits"
fi
# A synthetic check that the new Service-DNS branch of leak_pattern is
# live, not silently inert -- proves a real-TLD-shaped Service DNS name
# would be caught, without writing one into the repo itself.
if grep -qE "$leak_pattern" <<< 'upstream: my-svc.some-team.svc.internal-cluster.com:8080'; then
    ok "leak_pattern catches a real-TLD-shaped in-cluster Service DNS name"
else
    no "leak_pattern catches a real-TLD-shaped in-cluster Service DNS name" \
        "regex did not match the synthetic fixture string"
fi
if grep -qE "$leak_pattern" <<< 'upstream: my-svc.some-team.svc.cluster.local:8080'; then
    no "leak_pattern does not flag the safe svc.cluster.local placeholder" \
        "regex matched the placeholder-domain string"
else
    ok "leak_pattern does not flag the safe svc.cluster.local placeholder"
fi
# Multi-label cluster domains: a real cluster domain is very often itself
# more than one label before the TLD, and the single-label alternation
# above would miss both of these.
if grep -qE "$leak_pattern" <<< 'upstream: my-svc.some-team.svc.k8s.acme.com:8080'; then
    ok "leak_pattern catches a two-label cluster domain (svc.k8s.acme.com)"
else
    no "leak_pattern catches a two-label cluster domain (svc.k8s.acme.com)" \
        "regex did not match the synthetic fixture string"
fi
if grep -qE "$leak_pattern" <<< 'upstream: my-svc.some-team.svc.cluster.prod.example.com:8080'; then
    ok "leak_pattern catches a three-label cluster domain (svc.cluster.prod.example.com)"
else
    no "leak_pattern catches a three-label cluster domain (svc.cluster.prod.example.com)" \
        "regex did not match the synthetic fixture string"
fi
# A bare K8S_CLUSTER_DOMAIN= assignment, with no .svc. prefix anywhere in
# the string -- the shape a k8s.env line or a doc quoting its value would
# take.
if grep -qE "$leak_pattern" <<< 'K8S_CLUSTER_DOMAIN=k8s.acme.com'; then
    ok "leak_pattern catches a bare K8S_CLUSTER_DOMAIN= real-domain assignment"
else
    no "leak_pattern catches a bare K8S_CLUSTER_DOMAIN= real-domain assignment" \
        "regex did not match the synthetic fixture string"
fi
if grep -qE "$leak_pattern" <<< 'K8S_CLUSTER_DOMAIN=cluster.local'; then
    no "leak_pattern does not flag the safe K8S_CLUSTER_DOMAIN=cluster.local default" \
        "regex matched the placeholder-domain assignment"
else
    ok "leak_pattern does not flag the safe K8S_CLUSTER_DOMAIN=cluster.local default"
fi

printf '\n== fork-sandbox-k8s.sh: the GNU tools go through their resolved names ==\n'
# Guards the fork-sandbox-lib.sh name resolution: on macOS the bare names
# are BSD tools that reject the GNU flags (stat -c) or don't exist at all
# (timeout), so every call site must use the $FS_* names. What counts as a
# match, per pattern:
#   - "stat -c" and "realpath -m/-s/-e": any literal occurrence, comment
#     lines included -- the shimmed form ("$FS_STAT" -c) cannot spell the
#     raw form, and a comment describing the raw form would steer the next
#     edit back to it, so it is caught too. The grep -vF is a belt: it
#     would exclude a line literally containing the shimmed form.
#   - "timeout": command position only -- start of line (indented or not)
#     or immediately after ;, &, | or $(. --timeout, --request-timeout,
#     and the word in echo prose ("every 10s, timeout ...") all begin or
#     continue from other characters and do not match.
#   - "readlink -f": counted over the whole file, expected to be EXACTLY
#     one -- the script_dir bootstrap, which runs before the library is
#     sourced and structurally cannot use $FS_REALPATH. BSD readlink
#     gained -f in macOS 12.3, so every supported macOS has it. Asserting
#     1 rather than 0 documents the exception: if the bootstrap moves or
#     a second raw readlink appears, this test says so instead of passing
#     silently.
# shellcheck disable=SC2016  # the shimmed form is meant literally, not expanded
raw_stat_hits="$(grep -n 'stat -c' "$k8s_sh" | grep -vF -- '"$FS_STAT" ' || true)"
if [[ -z "$raw_stat_hits" ]]; then
    ok "fork-sandbox-k8s.sh: no raw 'stat -c' outside the $FS_STAT shim"
else
    no "fork-sandbox-k8s.sh: no raw 'stat -c' outside the $FS_STAT shim" "$raw_stat_hits"
fi
# shellcheck disable=SC2016  # the shimmed form is meant literally, not expanded
raw_realpath_hits="$(grep -nE 'realpath -[mse]' "$k8s_sh" | grep -vF -- '"$FS_REALPATH" ' || true)"
if [[ -z "$raw_realpath_hits" ]]; then
    ok "fork-sandbox-k8s.sh: no raw 'realpath -m/-s/-e' outside the $FS_REALPATH shim"
else
    no "fork-sandbox-k8s.sh: no raw 'realpath -m/-s/-e' outside the $FS_REALPATH shim" "$raw_realpath_hits"
fi
# shellcheck disable=SC2016  # the pattern is meant literally, not expanded
raw_timeout_hits="$(grep -nE '(^|[;&|(])[[:space:]]*timeout[[:space:]]' "$k8s_sh" || true)"
if [[ -z "$raw_timeout_hits" ]]; then
    ok "fork-sandbox-k8s.sh: no bare 'timeout' command outside the $FS_TIMEOUT shim"
else
    no "fork-sandbox-k8s.sh: no bare 'timeout' command outside the $FS_TIMEOUT shim" "$raw_timeout_hits"
fi
readlink_count="$(grep -c 'readlink -f' "$k8s_sh" || true)"
check "fork-sandbox-k8s.sh: exactly one 'readlink -f' (the pre-library bootstrap)" \
    1 "$readlink_count"

printf '\n== per-run services (cluster path) ==\n'
# .agents/sandbox-services/services.yaml is declarative data the harness
# synthesizes sidecars from -- never a hook the repo could execute -- see
# docs/sandbox-services.md's cluster section. Every fixture below commits a
# spec at HEAD and calls submit --dry-run directly (no --checkout), which
# is the "trusted, operator's own HEAD" case (services_trusted defaults to
# 1 in fork-sandbox-k8s.sh's cmd_submit): rejections are asserted this way
# without needing a stubbed kubectl, since the parser runs and can fail
# before any Job is even assembled, --dry-run or not.
svc_mk_repo() {
    local content="$1" d
    d="$(newdir)"; tmpdirs+=("$d")
    mkdir -p "$d/.agents/sandbox-services"
    printf '%s' "$content" > "$d/.agents/sandbox-services/services.yaml"
    git -C "$d" init -q
    git -C "$d" config user.email t@fork-sandbox.invalid
    git -C "$d" config user.name Tester
    git -C "$d" add -A
    git -C "$d" commit -q -m spec
    printf '%s\n' "$d"
}
svc_initcontainers_count() {
    awk '/^      initContainers:/{f=1} f&&/^      containers:/{f=0} f' "$1" | grep -c '^        - name:'
}
svc_volumes_count() {
    awk '/^      volumes:/{f=1} f' "$1" | grep -c '^        - name:'
}
svc_refuses() {
    local label="$1" needle="$2" spec="$3" d
    d="$(svc_mk_repo "$spec")"
    refuses "$label" "$needle" \
        env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
        --branch fs-k8s-test-svc-rej --model moonshotai/kimi-k3 "$d" "$handoff_file"
}

# No spec file: byte-for-byte the same regression proof as every existing
# repo is in today -- proj_dir (built above) has no
# .agents/sandbox-services/ at all. This is the case that matters most: it
# must render exactly as before and never warn.
svc_nosvc_out="$(newdir)/svc-nosvc.yaml"; tmpdirs+=("$(dirname "$svc_nosvc_out")")
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-svc-none --model moonshotai/kimi-k3 \
    "$proj_dir" "$handoff_file" > "$svc_nosvc_out" 2>/tmp/fs-k8s-test-svc-none.err; then
    ok "submit --dry-run with no services spec exits 0"
else
    no "submit --dry-run with no services spec exits 0" "$(cat /tmp/fs-k8s-test-svc-none.err)"
fi
if [[ -s /tmp/fs-k8s-test-svc-none.err ]]; then
    no "no services spec: nothing warns on stderr" "$(cat /tmp/fs-k8s-test-svc-none.err)"
else
    ok "no services spec: nothing warns on stderr"
fi
for needle in 'sandbox-env:' '## Per-run services' 'terminationGracePeriodSeconds'; do
    if grep -qF -- "$needle" "$svc_nosvc_out"; then
        no "no services spec: rendered Job has no '$needle'" "found it"
    else
        ok "no services spec: rendered Job has no '$needle'"
    fi
done
check "no services spec: initContainers has exactly one entry (egress-gate only)" \
    1 "$(svc_initcontainers_count "$svc_nosvc_out")"

# A valid one-service spec: one initContainers entry, restartPolicy:
# Always, the harness security context present, port/env/writableDirs/
# readyWhen/resources all rendered as given.
svc1_dir="$(svc_mk_repo 'version: 1
services:
  - name: postgres
    image: registry.example/rootless/postgres:16
    port: 5432
    env:
      POSTGRES_PASSWORD: dev
    writableDirs:
      - /var/lib/postgresql/data
    readyWhen:
      tcpPort: 5432
    resources:
      cpu: 500m
      memory: 512Mi
sandboxEnv:
  DATABASE_URL: "postgres://dev:dev@127.0.0.1:5432/dev"
')"
svc1_out="$(newdir)/svc1.yaml"; tmpdirs+=("$(dirname "$svc1_out")")
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-svc1 --model moonshotai/kimi-k3 \
    "$svc1_dir" "$handoff_file" > "$svc1_out" 2>/tmp/fs-k8s-test-svc1.err; then
    ok "submit --dry-run with a valid one-service spec exits 0"
else
    no "submit --dry-run with a valid one-service spec exits 0" "$(cat /tmp/fs-k8s-test-svc1.err)"
fi
if command -v yamllint >/dev/null 2>&1; then
    out="$(yamllint "$svc1_out" 2>&1)"
    if [[ -z "$out" ]]; then ok "yamllint: one-service submit --dry-run output"; else no "yamllint: one-service submit --dry-run output" "$out"; fi
fi
check "one-service spec: initContainers has exactly two entries (egress-gate, postgres)" \
    2 "$(svc_initcontainers_count "$svc1_out")"
if grep -qF -- '        - name: postgres' "$svc1_out" \
    && grep -A1 -F -- '        - name: postgres' "$svc1_out" | grep -qF 'image: "registry.example/rootless/postgres:16"'; then
    ok "one-service spec: the sidecar's name and image render as given"
else
    no "one-service spec: the sidecar's name and image render as given" "$(cat "$svc1_out")"
fi
if grep -A3 -F -- '        - name: postgres' "$svc1_out" | grep -qF 'restartPolicy: Always'; then
    ok "one-service spec: the sidecar carries restartPolicy: Always (native sidecar)"
else
    no "one-service spec: the sidecar carries restartPolicy: Always (native sidecar)" "$(cat "$svc1_out")"
fi
svc1_postgres_block="$(awk '/^        - name: postgres$/{f=1} f&&/^        - name:/&&!/^        - name: postgres$/{exit} f&&/^      [a-zA-Z]/{exit} f' "$svc1_out")"
if grep -qF 'allowPrivilegeEscalation: false' <<< "$svc1_postgres_block" \
    && grep -qF 'readOnlyRootFilesystem: true' <<< "$svc1_postgres_block" \
    && grep -qF 'drop: ["ALL"]' <<< "$svc1_postgres_block"; then
    ok "one-service spec: the harness's security context is present on the sidecar"
else
    no "one-service spec: the harness's security context is present on the sidecar" "$svc1_postgres_block"
fi
if grep -A2 -F 'env:' "$svc1_out" | grep -qF -- '- name: POSTGRES_PASSWORD'; then
    ok "one-service spec: env renders the given key"
else
    no "one-service spec: env renders the given key" "$(cat "$svc1_out")"
fi
if grep -qF 'value: "dev"' "$svc1_out"; then
    ok "one-service spec: env renders the given literal value"
else
    no "one-service spec: env renders the given literal value" "$(cat "$svc1_out")"
fi
if grep -A2 -F 'startupProbe:' "$svc1_out" | grep -qF 'port: 5432'; then
    ok "readyWhen.tcpPort renders a startupProbe"
else
    no "readyWhen.tcpPort renders a startupProbe" "$(cat "$svc1_out")"
fi
if grep -qF -- '- name: postgres-wd0' "$svc1_out" \
    && grep -A1 -F -- '- name: postgres-wd0' "$svc1_out" | grep -qF 'mountPath: "/var/lib/postgresql/data"'; then
    ok "writableDirs renders a volumeMount"
else
    no "writableDirs renders a volumeMount" "$(cat "$svc1_out")"
fi
if [[ "$(svc_volumes_count "$svc1_out")" -eq 5 ]] \
    && grep -A1 -F -- '        - name: postgres-wd0' "$svc1_out" | grep -qF 'emptyDir: {}'; then
    ok "writableDirs renders exactly one emptyDir volume for the one entry given"
else
    no "writableDirs renders exactly one emptyDir volume for the one entry given" "$(cat "$svc1_out")"
fi
if grep -qF '  sandbox-env: |' "$svc1_out" \
    && grep -A1 -F '  sandbox-env: |' "$svc1_out" | grep -qF 'DATABASE_URL=postgres://dev:dev@127.0.0.1:5432/dev'; then
    ok ".env.sandbox content (sandbox-env ConfigMap key) matches sandboxEnv"
else
    no ".env.sandbox content (sandbox-env ConfigMap key) matches sandboxEnv" "$(cat "$svc1_out")"
fi
if grep -qF '## Per-run services' "$svc1_out" \
    && grep -qF '    postgres 127.0.0.1:5432' "$svc1_out"; then
    ok "the prompt names the service and its 127.0.0.1:<port>"
else
    no "the prompt names the service and its 127.0.0.1:<port>" "$(cat "$svc1_out")"
fi
if grep -qF 'terminationGracePeriodSeconds: 10' "$svc1_out"; then
    ok "terminationGracePeriodSeconds is set to 10 when services are present"
else
    no "terminationGracePeriodSeconds is set to 10 when services are present" "$(cat "$svc1_out")"
fi

# Two services: both present, both ports distinct, and no readyWhen means
# no startupProbe.
svc2_dir="$(svc_mk_repo 'version: 1
services:
  - name: a
    image: registry.example/a:1
    port: 5432
  - name: b
    image: registry.example/b:1
    port: 6379
')"
svc2_out="$(newdir)/svc2.yaml"; tmpdirs+=("$(dirname "$svc2_out")")
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-svc2 --model moonshotai/kimi-k3 \
    "$svc2_dir" "$handoff_file" > "$svc2_out" 2>/tmp/fs-k8s-test-svc2.err; then
    ok "submit --dry-run with a valid two-service spec exits 0"
else
    no "submit --dry-run with a valid two-service spec exits 0" "$(cat /tmp/fs-k8s-test-svc2.err)"
fi
check "two-service spec: initContainers has exactly three entries (egress-gate, a, b)" \
    3 "$(svc_initcontainers_count "$svc2_out")"
if grep -qF '    a 127.0.0.1:5432' "$svc2_out" && grep -qF '    b 127.0.0.1:6379' "$svc2_out"; then
    ok "two-service spec: both services' ports render, both distinct"
else
    no "two-service spec: both services' ports render, both distinct" "$(cat "$svc2_out")"
fi
if grep -qF 'The clone holds an env file, `.env.sandbox`' "$svc2_out"; then
    no "service-only spec: prompt does not name a nonexistent env file" "found env-file paragraph"
else
    ok "service-only spec: prompt does not name a nonexistent env file"
fi
if grep -qF 'startupProbe:' "$svc2_out"; then
    no "no readyWhen renders no startupProbe" "found startupProbe: with no readyWhen given"
else
    ok "no readyWhen renders no startupProbe"
fi

# Resources are always rendered, including when the spec omits them or gives
# only one member: omitted members take the configured per-service cap.
svc_cap_dir="$(svc_mk_repo 'version: 1
services:
  - name: capped
    image: registry.example/capped:1
    port: 5432
  - name: partial
    image: registry.example/partial:1
    port: 5433
    resources:
      cpu: 250m
')"
svc_cap_out="$(newdir)/svc-cap.yaml"; tmpdirs+=("$(dirname "$svc_cap_out")")
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-svc-cap --model moonshotai/kimi-k3 \
    "$svc_cap_dir" "$handoff_file" > "$svc_cap_out" 2>/tmp/fs-k8s-test-svc-cap.err; then
    ok "omitted and partial resources render successfully"
else
    no "omitted and partial resources render successfully" "$(cat /tmp/fs-k8s-test-svc-cap.err)"
fi
svc_cap_block="$(awk '/^        - name: capped$/{f=1} f&&/^        - name:/&&!/^        - name: capped$/{exit} f' "$svc_cap_out")"
svc_partial_block="$(awk '/^        - name: partial$/{f=1} f&&/^        - name:/&&!/^        - name: partial$/{exit} f' "$svc_cap_out")"
if [[ "$(grep -c '^            requests:$' <<<"$svc_cap_block")" == 1 \
    && "$(grep -c '^            limits:$' <<<"$svc_cap_block")" == 1 ]]; then
    ok "no-resources service renders both resource blocks"
else
    no "no-resources service renders both resource blocks" "$svc_cap_block"
fi
if [[ "$(grep -c '^            requests:$' <<<"$svc_partial_block")" == 1 \
    && "$(grep -c '^            limits:$' <<<"$svc_partial_block")" == 1 ]]; then
    ok "partial resources service renders both resource blocks"
else
    no "partial resources service renders both resource blocks" "$svc_partial_block"
fi
if grep -A12 -F -- '        - name: capped' "$svc_cap_out" | grep -qF 'cpu: "1000m"' \
    && grep -A12 -F -- '        - name: capped' "$svc_cap_out" | grep -qF 'memory: "1Gi"'; then
    ok "no-resources service defaults cpu and memory to their caps"
else
    no "no-resources service defaults cpu and memory to their caps" "$svc_cap_block"
fi
if grep -A12 -F -- '        - name: partial' "$svc_cap_out" | grep -qF 'cpu: "250m"' \
    && grep -A12 -F -- '        - name: partial' "$svc_cap_out" | grep -qF 'memory: "1Gi"'; then
    ok "partial resources preserves cpu and defaults memory to its cap"
else
    no "partial resources preserves cpu and defaults memory to its cap" "$svc_partial_block"
fi

printf '\n== per-run services: --services-trust-ref gates the spec like the local hook ==\n'
svc_trust_dir="$(mktemp -d "$HOME/src/fs-k8s-svc-trust-test.XXXXXX")"; tmpdirs+=("$svc_trust_dir")
(
    cd "$svc_trust_dir" \
        && git init -q . \
        && git config user.email t@fork-sandbox.invalid \
        && git config user.name Tester \
        && mkdir -p .agents/sandbox-services \
        && printf 'version: 1\nservices:\n  - name: a\n    image: registry.example/a:1\n    port: 5432\n' \
            > .agents/sandbox-services/services.yaml \
        && git add -A && git commit -q -m base \
        && git tag fs-k8s-svc-trust-v1 \
        && printf 'x\n' > unrelated.txt && git add -A && git commit -q -m unrelated
) >/dev/null 2>&1
svc_trust_tag=fs-k8s-svc-trust-v1
svc_trust_unchanged_sha="$(git -C "$svc_trust_dir" rev-parse --verify --quiet HEAD)"

svc_trust_a_out="$(newdir)/svc-trust-a.yaml"; tmpdirs+=("$(dirname "$svc_trust_a_out")")
FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-svc-trust-a --model moonshotai/kimi-k3 \
    --checkout "$svc_trust_unchanged_sha" --services-trust-ref "$svc_trust_tag" \
    "$svc_trust_dir" "$handoff_file" > "$svc_trust_a_out" 2>/tmp/fs-k8s-test-svc-trust-a.err
check "--services-trust-ref, unchanged relative to it: services stay enabled" \
    2 "$(svc_initcontainers_count "$svc_trust_a_out")"

(
    cd "$svc_trust_dir" \
        && printf 'version: 1\nservices:\n  - name: a\n    image: registry.example/a:1\n    port: 5433\n' \
            > .agents/sandbox-services/services.yaml \
        && git -c user.email=t@fork-sandbox.invalid -c user.name=Tester add -A \
        && git -c user.email=t@fork-sandbox.invalid -c user.name=Tester commit -q -m changed
) >/dev/null 2>&1
svc_trust_changed_sha="$(git -C "$svc_trust_dir" rev-parse --verify --quiet HEAD)"

svc_trust_b_out="$(newdir)/svc-trust-b.yaml"; tmpdirs+=("$(dirname "$svc_trust_b_out")")
FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-svc-trust-b --model moonshotai/kimi-k3 \
    --checkout "$svc_trust_changed_sha" --services-trust-ref "$svc_trust_tag" \
    "$svc_trust_dir" "$handoff_file" > "$svc_trust_b_out" 2>/tmp/fs-k8s-test-svc-trust-b.err
check "--services-trust-ref, changed relative to it: services disabled" \
    1 "$(svc_initcontainers_count "$svc_trust_b_out")"
if grep -qF 'relative to the trusted' /tmp/fs-k8s-test-svc-trust-b.err; then
    ok "--services-trust-ref, changed relative to it: warns naming the trust gate"
else
    no "--services-trust-ref, changed relative to it: warns naming the trust gate" \
        "$(cat /tmp/fs-k8s-test-svc-trust-b.err)"
fi

svc_trust_c_out="$(newdir)/svc-trust-c.yaml"; tmpdirs+=("$(dirname "$svc_trust_c_out")")
FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-svc-trust-c --model moonshotai/kimi-k3 \
    --checkout "$svc_trust_changed_sha" \
    "$svc_trust_dir" "$handoff_file" > "$svc_trust_c_out" 2>/tmp/fs-k8s-test-svc-trust-c.err
check "--checkout with no --services-trust-ref: services disabled" \
    1 "$(svc_initcontainers_count "$svc_trust_c_out")"
if grep -qF 'unanchored ref' /tmp/fs-k8s-test-svc-trust-c.err; then
    ok "--checkout with no --services-trust-ref: warns that the ref is unanchored"
else
    no "--checkout with no --services-trust-ref: warns that the ref is unanchored" \
        "$(cat /tmp/fs-k8s-test-svc-trust-c.err)"
fi

printf '\n== per-run services: every rejection in the spec names the offending field ==\n'
svc_refuses "unknown top-level key" \
    "unknown top-level key 'unknownTop'" \
    'version: 1
services: []
unknownTop: 1
'
svc_refuses "wrong version" \
    "version: must be one of [1], got 2" \
    'version: 2
services: []
'
svc_refuses "bad name" \
    "services[0].name: 'Bad_Name' must match" \
    'version: 1
services:
  - name: Bad_Name
    image: registry.example/x:1
    port: 5432
'
svc_refuses "41-character name" \
    "must be at most 40 characters, got 41" \
    "version: 1
services:
  - name: $(printf 'a%.0s' {1..41})
    image: registry.example/x:1
    port: 5432
"
svc_name40_dir="$(svc_mk_repo "version: 1
services:
  - name: $(printf 'a%.0s' {1..40})
    image: registry.example/x:1
    port: 5432
")"
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-svc-name40 --model moonshotai/kimi-k3 \
    "$svc_name40_dir" "$handoff_file" >/dev/null 2>/tmp/fs-k8s-test-svc-name40.err; then
    ok "40-character service name is accepted"
else
    no "40-character service name is accepted" "$(cat /tmp/fs-k8s-test-svc-name40.err)"
fi
svc_refuses "reserved name" \
    "is reserved by the harness's own pod containers" \
    'version: 1
services:
  - name: egress-gate
    image: registry.example/x:1
    port: 5432
'
svc_refuses "duplicate name across services" \
    "is used by more than one service; names must be unique" \
    'version: 1
services:
  - name: a
    image: registry.example/x:1
    port: 5432
  - name: a
    image: registry.example/y:1
    port: 5433
'
svc_refuses "bad image" \
    "value may not contain a quote or a backslash" \
    'version: 1
services:
  - name: db
    image: "registry.example/db'"'"'x:1"
    port: 5432
'
svc_refuses "port out of range" \
    "must be between 1025 and 65535, got 80" \
    'version: 1
services:
  - name: db
    image: registry.example/x:1
    port: 80
'
svc_refuses "duplicate port" \
    "is also used by service 'a'; ports must be unique" \
    'version: 1
services:
  - name: a
    image: registry.example/x:1
    port: 5432
  - name: b
    image: registry.example/y:1
    port: 5432
'
svc_refuses "relative writableDirs" \
    "must be an absolute path" \
    'version: 1
services:
  - name: db
    image: registry.example/x:1
    port: 5432
    writableDirs:
      - relative/path
'
svc_refuses ".. in writableDirs" \
    "must not contain '..'" \
    'version: 1
services:
  - name: db
    image: registry.example/x:1
    port: 5432
    writableDirs:
      - /var/../etc
'
svc_refuses "duplicate writableDirs entry" \
    "is already listed for this service" \
    'version: 1
services:
  - name: db
    image: registry.example/x:1
    port: 5432
    writableDirs:
      - /data
      - /data
'
svc_refuses "readyWhen unknown key" \
    "unknown key 'execCommand'; only 'tcpPort' is supported" \
    'version: 1
services:
  - name: db
    image: registry.example/x:1
    port: 5432
    readyWhen:
      execCommand: foo
'
svc_refuses "readyWhen missing tcpPort" \
    "readyWhen: needs 'tcpPort'" \
    'version: 1
services:
  - name: db
    image: registry.example/x:1
    port: 5432
    readyWhen: {}
'
svc_refuses "too many services" \
    "more than the 8 allowed" \
    "version: 1
services:
$(for i in 1 2 3 4 5 6 7 8 9; do printf '  - name: svc%d\n    image: registry.example/x:1\n    port: %d\n' "$i" $((5432 + i)); done)
"
svc_refuses "over-cap resources" \
    "exceeds the per-service cap" \
    'version: 1
services:
  - name: db
    image: registry.example/x:1
    port: 5432
    resources:
      cpu: 2000m
'
for key in securityContext hostPath privileged; do
    svc_refuses "spec attempting '$key:' is rejected as an unknown key, not expressible" \
        "unknown key '$key'" \
        "version: 1
services:
  - name: db
    image: registry.example/x:1
    port: 5432
    $key: {}
"
done

printf '\n== per-run services: env var name rules ==\n'
# services[].env names are rendered into the Job manifest and validated by
# Kubernetes itself: the IsEnvVarName set, dots and dashes included (the
# OpenSearch/Elasticsearch style: discovery.type, path.repo). sandboxEnv
# names land in a shell-sourced .env.sandbox and stay shell-safe only.
svc_envnames_dir="$(svc_mk_repo 'version: 1
services:
  - name: search
    image: registry.example/rootless/search:1
    port: 5601
    env:
      discovery.type: single-node
      bootstrap.memory_lock: "true"
      node.store.allow_mmap: "true"
      my-env-name: v
')"
svc_envnames_out="$(newdir)/svc-envnames.yaml"; tmpdirs+=("$(dirname "$svc_envnames_out")")
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-svc-envnames --model moonshotai/kimi-k3 \
    "$svc_envnames_dir" "$handoff_file" > "$svc_envnames_out" \
    2>/tmp/fs-k8s-test-svc-envnames.err; then
    ok "services[].env with dotted and dashed names renders"
else
    no "services[].env with dotted and dashed names renders" \
        "$(cat /tmp/fs-k8s-test-svc-envnames.err)"
fi
for needle in '- name: discovery.type' '- name: bootstrap.memory_lock' \
    '- name: node.store.allow_mmap' '- name: my-env-name'; do
    if grep -qF -- "$needle" "$svc_envnames_out"; then
        ok "services[].env: '$needle' renders into the sidecar's env"
    else
        no "services[].env: '$needle' renders into the sidecar's env" \
            "not found in render"
    fi
done
svc_refuses "services[].env: the literal name '.' is refused" \
    "'.' is not a valid env var name" \
    'version: 1
services:
  - name: db
    image: registry.example/x:1
    port: 5432
    env:
      ".": v
'
svc_refuses "services[].env: the literal name '..' is refused" \
    "'..' is not a valid env var name" \
    'version: 1
services:
  - name: db
    image: registry.example/x:1
    port: 5432
    env:
      "..": v
'
for bad in 'has space' 'has$dollar' '1leading'; do
    svc_refuses "services[].env: '$bad' is still refused" \
        "env var names match" \
        "version: 1
services:
  - name: db
    image: registry.example/x:1
    port: 5432
    env:
      $bad: v
"
done
# The case the split exists for: the same dotted name that services[].env
# now accepts must be refused in sandboxEnv, and the message must say WHY
# (the shell-sourced env file) -- not merely that the name is bad.
svc_refuses "sandboxEnv: a dotted name is refused with the why" \
    "stricter than the services[].env rule above" \
    'version: 1
services: []
sandboxEnv:
  discovery.type: single-node
'
svc_refuses "sandboxEnv: the refusal names the shell-sourced env file" \
    "shell-sourced env file" \
    'version: 1
services: []
sandboxEnv:
  node.store.allow_mmap: "true"
'
svc_sbx_env_dir="$(svc_mk_repo 'version: 1
services: []
sandboxEnv:
  DISABLE_SECURITY_PLUGIN: "true"
')"
svc_sbx_env_out="$(newdir)/svc-sbx-env.yaml"; tmpdirs+=("$(dirname "$svc_sbx_env_out")")
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-svc-sbxenv --model moonshotai/kimi-k3 \
    "$svc_sbx_env_dir" "$handoff_file" > "$svc_sbx_env_out" \
    2>/tmp/fs-k8s-test-svc-sbxenv.err; then
    ok "sandboxEnv: a shell-safe name still renders"
else
    no "sandboxEnv: a shell-safe name still renders" \
        "$(cat /tmp/fs-k8s-test-svc-sbxenv.err)"
fi
if grep -qF 'DISABLE_SECURITY_PLUGIN=true' "$svc_sbx_env_out"; then
    ok "sandboxEnv: DISABLE_SECURITY_PLUGIN renders into the env file"
else
    no "sandboxEnv: DISABLE_SECURITY_PLUGIN renders into the env file" \
        "not found in render"
fi

printf '\n== per-run services: the parser validate-only mode ==\n'
# The cluster path calls the parser with 6 positional arguments and renders
# into an out-dir. The validate-only form (reached as `fork-sandbox
# validate-services <file>`) takes just the file, applies the same limits
# the cluster path would, prints which it applied, and writes nothing.
svc_parse_py="$repo_dir/scripts/fork-sandbox-k8s-services-parse.py"
svc_validate_dir="$(newdir)"; tmpdirs+=("$svc_validate_dir")
printf 'version: 1\nservices:\n  - name: search\n    image: registry.example/rootless/search:1\n    port: 5601\n    env:\n      discovery.type: single-node\n' \
    > "$svc_validate_dir/services.yaml"
svc_val_out="$(newdir)/svc-validate.out"; tmpdirs+=("$(dirname "$svc_val_out")")
if env FORK_SANDBOX_CONFIG_DIR="$config_dir" python3 "$svc_parse_py" \
    "$svc_validate_dir/services.yaml" > "$svc_val_out" \
    2>/tmp/fs-k8s-test-svc-val.err; then
    ok "validate-only: a valid spec exits 0"
else
    no "validate-only: a valid spec exits 0" "$(cat /tmp/fs-k8s-test-svc-val.err)"
fi
if grep -qF 'valid services spec' "$svc_val_out"; then
    ok "validate-only: success says the spec is valid"
else
    no "validate-only: success says the spec is valid" "$(cat "$svc_val_out")"
fi
# The fixture k8s.env names none of the cap keys, so the built-in defaults
# apply -- and the output must say so, not just be silent about it.
check "validate-only: prints the limits it applied (built-in defaults)" \
    'K8S_SERVICES_MAX=8 (built-in default), K8S_SERVICE_MAX_CPU=1000m (built-in default), K8S_SERVICE_MAX_MEMORY=1Gi (built-in default)' \
    "$(sed -n 's/^limits applied: //p' "$svc_val_out")"
if [[ "$(find "$svc_validate_dir" -mindepth 1 -maxdepth 1 | wc -l)" == 1 \
    && -f "$svc_validate_dir/services.yaml" ]]; then
    ok "validate-only: writes no output (only the spec remains)"
else
    no "validate-only: writes no output (only the spec remains)" \
        "$(find "$svc_validate_dir" -mindepth 1)"
fi

# The dispatcher passes a post-verb -h/--help straight to this script
# (like every other verb, it must answer with its usage, exit 0), not
# treat the flag as a spec path.
for svc_flag in -h --help; do
    svc_help_out="$(env FORK_SANDBOX_CONFIG_DIR="$config_dir" python3 \
        "$svc_parse_py" "$svc_flag" 2>&1)"; svc_help_rc=$?
    if (( svc_help_rc == 0 )) && [[ "$svc_help_out" == *'Usage:'* \
        && "$svc_help_out" == *'validate only'* ]]; then
        ok "validate-only: $svc_flag prints usage and exits 0"
    else
        no "validate-only: $svc_flag prints usage and exits 0" \
            "rc=$svc_help_rc: $svc_help_out"
    fi
done

printf 'version: 1\nservices:\n  - name: db\n    image: registry.example/x:1\n    port: 80\n' \
    > "$svc_validate_dir/invalid.yaml"
svc_val_bad_out=""; svc_val_bad_rc=0
svc_val_bad_out="$(env FORK_SANDBOX_CONFIG_DIR="$config_dir" python3 "$svc_parse_py" \
    "$svc_validate_dir/invalid.yaml" 2>&1)" || svc_val_bad_rc=$?
if (( svc_val_bad_rc != 0 )) \
    && [[ "$svc_val_bad_out" == *"must be between 1025 and 65535, got 80"* ]]; then
    ok "validate-only: an invalid spec fails with the field-naming message"
else
    no "validate-only: an invalid spec fails with the field-naming message" \
        "rc=$svc_val_bad_rc: $svc_val_bad_out"
fi
if [[ "$svc_val_bad_out" == *"$svc_validate_dir/invalid.yaml"* ]]; then
    ok "validate-only: the failure names the file the user gave"
else
    no "validate-only: the failure names the file the user gave" \
        "$svc_val_bad_out"
fi

# The whole point of the mode: the limits are the site's, not a hidden
# copy. A config whose k8s.env tightens K8S_SERVICES_MAX must tighten
# validate-only identically, and the output must name k8s.env as the
# source.
svc_val_cfg_dir="$(newdir)"; tmpdirs+=("$svc_val_cfg_dir")
printf 'K8S_SERVICES_MAX=2\nK8S_SERVICE_MAX_CPU=500m\n' > "$svc_val_cfg_dir/k8s.env"
svc_val_cfg_out="$(newdir)/svc-validate-cfg.out"; tmpdirs+=("$(dirname "$svc_val_cfg_out")")
printf 'version: 1\nservices:\n  - name: a\n    image: registry.example/x:1\n    port: 5432\n  - name: b\n    image: registry.example/x:1\n    port: 5433\n  - name: c\n    image: registry.example/x:1\n    port: 5434\n' \
    > "$svc_validate_dir/three.yaml"
svc_val_three_out=""; svc_val_three_rc=0
svc_val_three_out="$(env FORK_SANDBOX_CONFIG_DIR="$svc_val_cfg_dir" python3 "$svc_parse_py" \
    "$svc_validate_dir/three.yaml" 2>&1)" || svc_val_three_rc=$?
if (( svc_val_three_rc != 0 )) \
    && [[ "$svc_val_three_out" == *"more than the 2 allowed"* ]]; then
    ok "validate-only: a k8s.env K8S_SERVICES_MAX=2 refuses three services"
else
    no "validate-only: a k8s.env K8S_SERVICES_MAX=2 refuses three services" \
        "rc=$svc_val_three_rc: $svc_val_three_out"
fi
printf 'version: 1\nservices:\n  - name: a\n    image: registry.example/x:1\n    port: 5432\n  - name: b\n    image: registry.example/x:1\n    port: 5433\n' \
    > "$svc_validate_dir/two.yaml"
if env FORK_SANDBOX_CONFIG_DIR="$svc_val_cfg_dir" python3 "$svc_parse_py" \
    "$svc_validate_dir/two.yaml" > "$svc_val_cfg_out" \
    2>/tmp/fs-k8s-test-svc-val-cfg.err; then
    ok "validate-only: two services pass under K8S_SERVICES_MAX=2"
else
    no "validate-only: two services pass under K8S_SERVICES_MAX=2" \
        "$(cat /tmp/fs-k8s-test-svc-val-cfg.err)"
fi
if grep -qF "K8S_SERVICES_MAX=2 (from $svc_val_cfg_dir/k8s.env)" \
        "$svc_val_cfg_out" \
    && grep -qF "K8S_SERVICE_MAX_CPU=500m (from $svc_val_cfg_dir/k8s.env)" \
        "$svc_val_cfg_out" \
    && grep -qF "K8S_SERVICE_MAX_MEMORY=1Gi (built-in default)" \
        "$svc_val_cfg_out"; then
    ok "validate-only: names k8s.env as the source for the keys it read"
else
    no "validate-only: names k8s.env as the source for the keys it read" \
        "$(cat "$svc_val_cfg_out")"
fi

# A malformed K8S_SERVICES_MAX is a k8s.env error, not a spec error: the
# cluster path validates the key against ^[0-9]+$ at config load, so
# validate-only must reject the same shapes with a message that names the
# config file -- and an empty value must fall back to the default the way
# ${K8S_SERVICES_MAX:-8} does, so a local pass is a guarantee under the
# same configuration.
svc_val_cfg_bad="$(newdir)"; tmpdirs+=("$svc_val_cfg_bad")
printf 'K8S_SERVICES_MAX=+5\n' > "$svc_val_cfg_bad/k8s.env"
svc_val_badmax_out=""; svc_val_badmax_rc=0
svc_val_badmax_out="$(env FORK_SANDBOX_CONFIG_DIR="$svc_val_cfg_bad" python3 "$svc_parse_py" \
    "$svc_validate_dir/services.yaml" 2>&1)" || svc_val_badmax_rc=$?
if (( svc_val_badmax_rc != 0 )) \
    && [[ "$svc_val_badmax_out" == *"K8S_SERVICES_MAX must be a positive integer, got '+5'"* \
    && "$svc_val_badmax_out" == *"$svc_val_cfg_bad/k8s.env"* \
    && "$svc_val_badmax_out" != *"services.yaml"* ]]; then
    ok "validate-only: K8S_SERVICES_MAX=+5 is a config error naming k8s.env"
else
    no "validate-only: K8S_SERVICES_MAX=+5 is a config error naming k8s.env" \
        "rc=$svc_val_badmax_rc: $svc_val_badmax_out"
fi
printf 'K8S_SERVICES_MAX=-1\n' > "$svc_val_cfg_bad/k8s.env"
svc_val_neg_out=""; svc_val_neg_rc=0
svc_val_neg_out="$(env FORK_SANDBOX_CONFIG_DIR="$svc_val_cfg_bad" python3 "$svc_parse_py" \
    "$svc_validate_dir/services.yaml" 2>&1)" || svc_val_neg_rc=$?
if (( svc_val_neg_rc != 0 )) \
    && [[ "$svc_val_neg_out" == *"K8S_SERVICES_MAX must be a positive integer, got '-1'"* \
    && "$svc_val_neg_out" != *"more than the"* ]]; then
    ok "validate-only: K8S_SERVICES_MAX=-1 is a config error, not a spec error"
else
    no "validate-only: K8S_SERVICES_MAX=-1 is a config error, not a spec error" \
        "rc=$svc_val_neg_rc: $svc_val_neg_out"
fi
printf 'K8S_SERVICES_MAX=\n' > "$svc_val_cfg_bad/k8s.env"
svc_val_empty_out="$(newdir)/svc-validate-empty.out"; tmpdirs+=("$(dirname "$svc_val_empty_out")")
if env FORK_SANDBOX_CONFIG_DIR="$svc_val_cfg_bad" python3 "$svc_parse_py" \
    "$svc_validate_dir/services.yaml" > "$svc_val_empty_out" \
    2>/tmp/fs-k8s-test-svc-val-empty.err; then
    ok "validate-only: an empty K8S_SERVICES_MAX falls back to the default 8"
else
    no "validate-only: an empty K8S_SERVICES_MAX falls back to the default 8" \
        "$(cat /tmp/fs-k8s-test-svc-val-empty.err)"
fi
if grep -qF 'K8S_SERVICES_MAX=8 (built-in default)' "$svc_val_empty_out"; then
    ok "validate-only: the empty-value fallback is reported as the default"
else
    no "validate-only: the empty-value fallback is reported as the default" \
        "$(cat "$svc_val_empty_out")"
fi

# The parser must see the same bytes the bash side's read_env_value sees:
# read -r keeps a trailing \r on a CRLF line, so a cap key written with
# CRLF endings is a k8s.env error the cluster path refuses at config load,
# not a silently cleaned-up value validate-only would pass under.
printf 'K8S_SERVICES_MAX=2\r\n' > "$svc_val_cfg_bad/k8s.env"
svc_val_crlf_out=""; svc_val_crlf_rc=0
svc_val_crlf_out="$(env FORK_SANDBOX_CONFIG_DIR="$svc_val_cfg_bad" python3 "$svc_parse_py" \
    "$svc_validate_dir/services.yaml" 2>&1)" || svc_val_crlf_rc=$?
if (( svc_val_crlf_rc != 0 )) \
    && [[ "$svc_val_crlf_out" == *"K8S_SERVICES_MAX must be a positive integer"* \
    && "$svc_val_crlf_out" == *"$svc_val_cfg_bad/k8s.env"* \
    && "$svc_val_crlf_out" != *"valid services spec"* ]]; then
    ok "validate-only: a CRLF cap key in k8s.env is refused like the cluster path"
else
    no "validate-only: a CRLF cap key in k8s.env is refused like the cluster path" \
        "rc=$svc_val_crlf_rc: $svc_val_crlf_out"
fi
# The refusal is about the \r inside a value, not CRLF files wholesale: a
# CRLF file naming no cap key still validates under the built-in defaults.
printf 'K8S_CONTEXT=ctx\r\nK8S_NAMESPACE=ns\r\n' > "$svc_val_cfg_bad/k8s.env"
if env FORK_SANDBOX_CONFIG_DIR="$svc_val_cfg_bad" python3 "$svc_parse_py" \
    "$svc_validate_dir/services.yaml" > /dev/null 2>&1; then
    ok "validate-only: a CRLF k8s.env naming no cap key still passes"
else
    no "validate-only: a CRLF k8s.env naming no cap key still passes"
fi
# A malformed cap from k8s.env is a config error, not a spec error -- the
# same attribution the K8S_SERVICES_MAX check above gets, applied to the
# other two keys resolve_limits reads.
printf 'K8S_SERVICE_MAX_CPU=abc\n' > "$svc_val_cfg_bad/k8s.env"
svc_val_badcpu_out=""; svc_val_badcpu_rc=0
svc_val_badcpu_out="$(env FORK_SANDBOX_CONFIG_DIR="$svc_val_cfg_bad" python3 "$svc_parse_py" \
    "$svc_validate_dir/services.yaml" 2>&1)" || svc_val_badcpu_rc=$?
if (( svc_val_badcpu_rc != 0 )) \
    && [[ "$svc_val_badcpu_out" == *"K8S_SERVICE_MAX_CPU: not a valid CPU quantity"* \
    && "$svc_val_badcpu_out" == *"$svc_val_cfg_bad/k8s.env"* \
    && "$svc_val_badcpu_out" != *"services.yaml"* ]]; then
    ok "validate-only: a malformed K8S_SERVICE_MAX_CPU names k8s.env, not the spec"
else
    no "validate-only: a malformed K8S_SERVICE_MAX_CPU names k8s.env, not the spec" \
        "rc=$svc_val_badcpu_rc: $svc_val_badcpu_out"
fi
printf 'K8S_SERVICE_MAX_MEMORY=xyz\n' > "$svc_val_cfg_bad/k8s.env"
svc_val_badmem_out=""; svc_val_badmem_rc=0
svc_val_badmem_out="$(env FORK_SANDBOX_CONFIG_DIR="$svc_val_cfg_bad" python3 "$svc_parse_py" \
    "$svc_validate_dir/services.yaml" 2>&1)" || svc_val_badmem_rc=$?
if (( svc_val_badmem_rc != 0 )) \
    && [[ "$svc_val_badmem_out" == *"K8S_SERVICE_MAX_MEMORY: not a valid memory quantity"* \
    && "$svc_val_badmem_out" == *"$svc_val_cfg_bad/k8s.env"* \
    && "$svc_val_badmem_out" != *"services.yaml"* ]]; then
    ok "validate-only: a malformed K8S_SERVICE_MAX_MEMORY names k8s.env, not the spec"
else
    no "validate-only: a malformed K8S_SERVICE_MAX_MEMORY names k8s.env, not the spec" \
        "rc=$svc_val_badmem_rc: $svc_val_badmem_out"
fi

# The 6-positional-argument form the cluster path uses must render exactly
# as before, and a wrong argument count still fails with usage.
svc_val_render_dir="$(newdir)/out"; tmpdirs+=("$(dirname "$svc_val_render_dir")")
if python3 "$svc_parse_py" "$svc_validate_dir/services.yaml" \
    "$svc_val_render_dir" 8 1000m 1Gi; then
    ok "render form: 6 positional arguments still exits 0"
else
    no "render form: 6 positional arguments still exits 0"
fi
for f in containers.yaml prompt-services.txt grace; do
    if [[ -f "$svc_val_render_dir/$f" ]]; then
        ok "render form: $f is written"
    else
        no "render form: $f is written" "missing"
    fi
done
if grep -qF -- '- name: discovery.type' "$svc_val_render_dir/containers.yaml"; then
    ok "render form: the dotted env name renders"
else
    no "render form: the dotted env name renders" \
        "$(cat "$svc_val_render_dir/containers.yaml")"
fi
svc_val_usage_rc=0
python3 "$svc_parse_py" a b c d > /dev/null 2>&1 || svc_val_usage_rc=$?
check "render form: a wrong argument count is refused" 1 "$svc_val_usage_rc"

printf '\n== the durable run log: cmd_submit creates and populates the run directory ==\n'
# --dry-run contacts nothing, and that includes the host filesystem outside
# rendering: no run directory may appear under the forks root.
rundir_dryrun_marker="$(mktemp /var/tmp/claude-scratch/forks/fs-k8s-test-rundir-marker.XXXXXX)"
FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-rundir-dryrun --model moonshotai/kimi-k3 \
    "$proj_dir" "$handoff_file" > /dev/null 2>/tmp/fs-k8s-test-rundir-dryrun.err
rundir_dryrun_leak="$(find /var/tmp/claude-scratch/forks -maxdepth 1 \
    -name 'claude-fork-sandbox.*' -newer "$rundir_dryrun_marker" 2>/dev/null)"
if [[ -z "$rundir_dryrun_leak" ]]; then
    ok "submit --dry-run creates no run directory"
else
    no "submit --dry-run creates no run directory" "$rundir_dryrun_leak"
fi
rm -f "$rundir_dryrun_marker"

rundir_handoff="$(newdir)/handoff.md"; tmpdirs+=("$(dirname "$rundir_handoff")")
printf 'do the submit-time task\n\n\n' > "$rundir_handoff"
rundir_kubectl_log="$(newdir)/kubectl.log"; tmpdirs+=("$(dirname "$rundir_kubectl_log")")
rundir_submit_out="$(newdir)/submit-out.txt"; tmpdirs+=("$(dirname "$rundir_submit_out")")
rundir_manifest="$(newdir)/submit.yaml"; tmpdirs+=("$(dirname "$rundir_manifest")")
rundir_head_sha="$(git -C "$proj_dir" rev-parse HEAD)"
PATH="$runstub_dir:$PATH" K8S_STUB_LOG="$rundir_kubectl_log" \
    K8S_STUB_BASE_SHA="$rundir_head_sha" \
    K8S_STUB_APPLY_MANIFEST="$rundir_manifest" \
    FORK_SANDBOX_CONFIG_DIR="$config_dir" \
    "$k8s_sh" submit --branch fs-k8s-test-rundir-submit --model moonshotai/kimi-k3 \
    --task-meta '{"kind":"implement","difficulty":2}' \
    "$proj_dir" "$rundir_handoff" > "$rundir_submit_out" 2>&1
rundir_submit_rc=$?
rundir_rd="$(sed -n 's/^  run dir:  *//p' "$rundir_submit_out" | head -1)"
if (( rundir_submit_rc == 0 )) && [[ -n "$rundir_rd" && -d "$rundir_rd" ]]; then
    ok "submit prints a run dir path and it exists"
    tmpdirs+=("$rundir_rd")
else
    no "submit prints a run dir path and it exists" \
        "rc=$rundir_submit_rc out=$(cat "$rundir_submit_out")"
fi

if [[ -n "$rundir_rd" && -d "$rundir_rd" ]]; then
    check "the run dir's basename is prefixed claude-fork-sandbox." \
        "claude-fork-sandbox" "$(basename "$rundir_rd" | grep -o '^claude-fork-sandbox')"
    check "the run dir sits directly under the forks root" \
        "/var/tmp/claude-scratch/forks" "$(dirname "$rundir_rd")"
    check "run.env carries mode=run" "mode=run" "$(grep '^mode=' "$rundir_rd/run.env")"
    check "run.env carries the harness" "harness=pi" "$(grep '^harness=' "$rundir_rd/run.env")"
    check "run.env carries network=cluster" \
        "network=cluster" "$(grep '^network=' "$rundir_rd/run.env")"
    check "run.env carries the model" \
        "model=moonshotai/kimi-k3" "$(grep '^model=' "$rundir_rd/run.env")"
    check "run.env carries the branch" \
        "branch=fs-k8s-test-rundir-submit" "$(grep '^branch=' "$rundir_rd/run.env")"
    check "run.env carries the origin repo" \
        "origin_repo=$(fs_repo_toplevel "$proj_dir")" "$(grep '^origin_repo=' "$rundir_rd/run.env")"
    check "run.env carries base_sha (this repo's HEAD, no --checkout given)" \
        "base_sha=$rundir_head_sha" "$(grep '^base_sha=' "$rundir_rd/run.env")"
    check "task-meta.json carries what --task-meta passed" \
        '{"kind":"implement","difficulty":2}' \
        "$(jq -c . "$rundir_rd/task-meta.json" 2>/dev/null)"
    check "the run-source marker carries this suite's own FORK_SANDBOX_RUN_SOURCE=test tag" \
        "test" "$(cat "$rundir_rd/run-source" 2>/dev/null)"
    check "handoff-original.md is a verbatim, unrendered copy of what was submitted" \
        "do the submit-time task" "$(cat "$rundir_rd/handoff-original.md" 2>/dev/null)"
    rundir_handoffmd_content="$(cat "$rundir_rd/handoff.md" 2>/dev/null)"
    if [[ "$rundir_handoffmd_content" == *"do the submit-time task"* ]]; then
        ok "handoff.md is the rendered prompt, embedding the operator's own text"
    else
        no "handoff.md is the rendered prompt, embedding the operator's own text" \
            "$rundir_handoffmd_content"
    fi
    if [[ "$rundir_handoffmd_content" != "do the submit-time task" ]]; then
        ok "handoff.md is not itself the raw file (it carries the preamble too)"
    else
        no "handoff.md is not itself the raw file (it carries the preamble too)"
    fi

    # The archive is exact, including blank terminal lines. The ConfigMap
    # intentionally differs: its `|` block scalar uses YAML clip chomping,
    # so the pod receives exactly one terminal newline. This comparison also
    # pins the sentinel above: without it command substitution would strip
    # the archive's blank terminal lines before this write.
    expected_rundir_handoff="$({ fs_emit_prompt_preamble /work/clone /work/inbox \
        pi gated /work/outbox pod 67108864
        printf '\n---\n\n'
        cat -- "$rundir_handoff"
        printf X
    })"
    expected_rundir_handoff="${expected_rundir_handoff%X}"
    if cmp -s <(printf '%s' "$expected_rundir_handoff") "$rundir_rd/handoff.md"; then
        ok "handoff.md faithfully archives rendered prompts with trailing blank lines"
    else
        no "handoff.md faithfully archives rendered prompts with trailing blank lines"
    fi
    configmap_handoff="$(extract_configmap_key handoff.md "$rundir_manifest")"
    expected_rundir_handoff_without_trailing_newlines="$(printf '%s' "$expected_rundir_handoff" | sed -z 's/\n*$//')"
    check "ConfigMap and archive have identical non-trailing prompt text" \
        "$expected_rundir_handoff_without_trailing_newlines" "$configmap_handoff"
    if grep -qF '  handoff.md: |' "$rundir_manifest"; then
        ok "ConfigMap's literal block uses clip chomping for one terminal newline"
    else
        no "ConfigMap's literal block uses clip chomping for one terminal newline"
    fi

    # Both copies must be taken AT SUBMIT TIME, not re-read later: the
    # caller may edit or remove the original while the run is in flight.
    printf 'edited after submit\n' > "$rundir_handoff"
    check "handoff-original.md is a copy taken at submit time, not re-read later" \
        "do the submit-time task" "$(cat "$rundir_rd/handoff-original.md" 2>/dev/null)"
    rundir_handoffmd_content2="$(cat "$rundir_rd/handoff.md" 2>/dev/null)"
    if [[ "$rundir_handoffmd_content2" == *"do the submit-time task"* ]]; then
        ok "handoff.md is likewise taken at submit time, not re-read later"
    else
        no "handoff.md is likewise taken at submit time, not re-read later" \
            "$rundir_handoffmd_content2"
    fi
fi

# --task-meta is validated before anything is created: an invalid JSON
# value is refused with an empty kubectl log (nothing created).
rundir_badmeta_log="$(newdir)/kubectl.log"; tmpdirs+=("$(dirname "$rundir_badmeta_log")")
refuses "--task-meta must be one valid JSON object" \
    "must be one valid JSON object" \
    env PATH="$runstub_dir:$PATH" K8S_STUB_LOG="$rundir_badmeta_log" \
    FORK_SANDBOX_CONFIG_DIR="$config_dir" \
    "$k8s_sh" submit --branch fs-k8s-test-rundir-badmeta --model moonshotai/kimi-k3 \
    --task-meta 'not json' \
    "$proj_dir" "$handoff_file"
if [[ ! -s "$rundir_badmeta_log" ]]; then
    ok "an invalid --task-meta creates nothing (empty kubectl log)"
else
    no "an invalid --task-meta creates nothing (empty kubectl log)" "$(cat "$rundir_badmeta_log")"
fi

# FORK_SANDBOX_RUN_SOURCE is validated before anything is created too, the
# same as the local path's own copy of this check in fork-sandbox.sh: an
# off-pattern token (an underscore here) must be refused with an empty
# kubectl log. This script's own copy is the ONLY gate that ever sees a
# `fork-sandbox.sh --k8s` launch's token, since that path execs into this
# script's own submit above fork-sandbox.sh's own check.
rundir_badsource_log="$(newdir)/kubectl.log"; tmpdirs+=("$(dirname "$rundir_badsource_log")")
refuses "FORK_SANDBOX_RUN_SOURCE with an underscore is refused" \
    "FORK_SANDBOX_RUN_SOURCE is a provenance token" \
    env PATH="$runstub_dir:$PATH" K8S_STUB_LOG="$rundir_badsource_log" \
    FORK_SANDBOX_CONFIG_DIR="$config_dir" FORK_SANDBOX_RUN_SOURCE=k8s_fixture \
    "$k8s_sh" submit --branch fs-k8s-test-rundir-badsource --model moonshotai/kimi-k3 \
    "$proj_dir" "$handoff_file"
if [[ ! -s "$rundir_badsource_log" ]]; then
    ok "an invalid FORK_SANDBOX_RUN_SOURCE creates nothing (empty kubectl log)"
else
    no "an invalid FORK_SANDBOX_RUN_SOURCE creates nothing (empty kubectl log)" "$(cat "$rundir_badsource_log")"
fi

# A submit that dies after the run directory exists (here: the manifest
# apply, well after the context spool and the repository push) must still
# print the directory's path -- so it is at least attributable -- rather
# than leaving it silently on disk. See cmd_submit's own comment on why
# the "  run dir:  " line moved to right after the directory is created.
rundir_applyfail_log="$(newdir)/kubectl.log"; tmpdirs+=("$(dirname "$rundir_applyfail_log")")
rundir_applyfail_out="$(newdir)/applyfail-out.txt"; tmpdirs+=("$(dirname "$rundir_applyfail_out")")
K8S_STUB_APPLY_RC=1 PATH="$runstub_dir:$PATH" K8S_STUB_LOG="$rundir_applyfail_log" \
    K8S_STUB_BASE_SHA="$rundir_head_sha" \
    FORK_SANDBOX_CONFIG_DIR="$config_dir" \
    "$k8s_sh" submit --branch fs-k8s-test-rundir-applyfail --model moonshotai/kimi-k3 \
    "$proj_dir" "$rundir_handoff" > "$rundir_applyfail_out" 2>&1
rundir_applyfail_rc=$?
rundir_applyfail_rd="$(sed -n 's/^  run dir:  *//p' "$rundir_applyfail_out" | head -1)"
if (( rundir_applyfail_rc != 0 )) && [[ -n "$rundir_applyfail_rd" && -d "$rundir_applyfail_rd" ]]; then
    ok "a submit that dies after creating the run dir still prints its path"
else
    no "a submit that dies after creating the run dir still prints its path" \
        "rc=$rundir_applyfail_rc run_dir=$rundir_applyfail_rd out=$(cat "$rundir_applyfail_out")"
fi

printf '\n== fork-sandbox-k8s.sh submit --harness claude: credential balancer happy path ==\n'
# The hook's choice is used, and run.env/summary.json record it -- needs a
# full (non-dry-run) submit through to a running claude-proxy Pod, which is
# why this lives here (after runstub_dir, the git+kubectl pair that fakes a
# whole cluster round trip, already exists) rather than beside this file's
# other --claude-credentials/balance cases above, which stay on --dry-run.
balance_happy_config_dir="$(newdir)"; tmpdirs+=("$balance_happy_config_dir")
cp "$config_dir/k8s.env" "$balance_happy_config_dir/k8s.env"
install -m 600 /dev/null "$balance_happy_config_dir/pi.env"
printf 'OPENROUTER_API_KEY=sk-test-dummy\n' >> "$balance_happy_config_dir/pi.env"
{
    printf 'CLAUDE_CREDENTIAL_POOL=%s:%s\n' "$balance_pool_a" "$balance_pool_b"
    printf 'CLAUDE_HEADROOM_HOOK=happy2\n'
} > "$balance_happy_config_dir/claude.env"
balance_happy_hook_dir="$(balance_fake_hook happy2 'printf "%s\n" "$2"')"
balance_happy_kubectl_log="$(newdir)/kubectl.log"; tmpdirs+=("$(dirname "$balance_happy_kubectl_log")")
balance_happy_out="$(PATH="$balance_happy_hook_dir:$runstub_dir:$PATH" \
    K8S_STUB_LOG="$balance_happy_kubectl_log" \
    K8S_STUB_BASE_SHA="$rundir_head_sha" \
    FORK_SANDBOX_CONFIG_DIR="$balance_happy_config_dir" \
    "$k8s_sh" submit --branch fs-k8s-test-balance-happy --model claude-sonnet-5 \
    --harness claude "$proj_dir" "$handoff_file" 2>&1)"
balance_happy_rc=$?
balance_happy_rd="$(sed -n 's/^  run dir:  *//p' <<<"$balance_happy_out" | head -1)"
if (( balance_happy_rc == 0 )) && [[ -n "$balance_happy_rd" && -d "$balance_happy_rd" ]]; then
    tmpdirs+=("$balance_happy_rd")
    ok "balance happy path: submit exits 0 and produces a run dir"
    check "balance happy path: run.env records via=balance" \
        "claude_credentials_via=balance" "$(grep '^claude_credentials_via=' "$balance_happy_rd/run.env")"
    check "balance happy path: run.env records the hook's choice as the source" \
        "claude_credentials_source=$balance_pool_b" \
        "$(grep '^claude_credentials_source=' "$balance_happy_rd/run.env")"
else
    no "balance happy path: submit exits 0 and produces a run dir" \
        "rc=$balance_happy_rc out=$balance_happy_out"
fi

# The pair fs_record_run_log actually prefers: cmd_collect writes
# claude_credentials_source/via into summary.json too (not just run.env),
# and reads summary.json first when both exist. Nothing before this asserted
# that these two fields survive the run.env -> summary.json handoff, so a
# regression in cmd_collect's jq filter could silently drop attribution from
# the durable log while every run.env-only check above stayed green.
if [[ -n "$balance_happy_rd" && -d "$balance_happy_rd" ]]; then
    balance_happy_collect_log="$(newdir)/kubectl.log"; tmpdirs+=("$(dirname "$balance_happy_collect_log")")
    balance_happy_collect_out="$(newdir)/collect-out.txt"; tmpdirs+=("$(dirname "$balance_happy_collect_out")")
    balance_happy_collect_outbox="$(newdir)/outbox"; tmpdirs+=("$(dirname "$balance_happy_collect_outbox")")
    HOME="$k8s_test_home" PATH="$runstub_dir:$PATH" K8S_STUB_LOG="$balance_happy_collect_log" \
        K8S_STUB_BASE_SHA="$rundir_head_sha" \
        K8S_STUB_OUTBOX_DIR="$runstub_pod_outbox" \
        FORK_SANDBOX_CONFIG_DIR="$balance_happy_config_dir" \
        "$k8s_sh" collect --branch fs-k8s-test-balance-happy --run-dir "$balance_happy_rd" \
        --outbox-dir "$balance_happy_collect_outbox" \
        "$proj_dir" > "$balance_happy_collect_out" 2>&1
    balance_happy_collect_rc=$?
    if (( balance_happy_collect_rc == 0 )) && [[ -f "$balance_happy_rd/summary.json" ]] \
        && jq -e . "$balance_happy_rd/summary.json" >/dev/null 2>&1; then
        ok "balance happy path: collect exits 0 and writes a valid summary.json"
        check "balance happy path: summary.json records via=balance" \
            "balance" "$(jq -r '.claude_credentials_via' "$balance_happy_rd/summary.json")"
        check "balance happy path: summary.json records the hook's choice as the source" \
            "$balance_pool_b" "$(jq -r '.claude_credentials_source' "$balance_happy_rd/summary.json")"
    else
        no "balance happy path: collect exits 0 and writes a valid summary.json" \
            "rc=$balance_happy_collect_rc out=$(cat "$balance_happy_collect_out") summary=$(cat "$balance_happy_rd/summary.json" 2>/dev/null; echo NOFILE)"
    fi
fi

printf '\n== fork-sandbox.sh --k8s delegation: via/source attribution and single hook call ==\n'
# fork-sandbox.sh --k8s resolves the whole precedence chain itself and
# forwards the choice as this script's own --claude-credentials (see the
# comment at its exec site) -- but a bare --claude-credentials flag on its
# own is indistinguishable from an operator typing the flag directly, which
# would flatten a delegated balance/claude-env choice to via=flag and make
# the ledger unable to answer "which account, chosen how" for any --k8s run
# launched the normal way. FORK_SANDBOX_CLAUDE_CREDENTIALS_VIA is the
# launcher's own internal handoff of the true source; these two cases drive
# this entry point directly with that env var set, the same way
# fork-sandbox.sh's own --k8s dispatch would set it, without needing a real
# fork-sandbox.sh --k8s delegation.
balance_via_config_dir="$(newdir)"; tmpdirs+=("$balance_via_config_dir")
cp "$config_dir/k8s.env" "$balance_via_config_dir/k8s.env"
install -m 600 /dev/null "$balance_via_config_dir/pi.env"
printf 'OPENROUTER_API_KEY=sk-test-dummy\n' >> "$balance_via_config_dir/pi.env"
: > "$balance_via_config_dir/claude.env"

balance_via_kubectl_log="$(newdir)/kubectl.log"; tmpdirs+=("$(dirname "$balance_via_kubectl_log")")
balance_via_out="$(FORK_SANDBOX_CONFIG_DIR="$balance_via_config_dir" \
    FORK_SANDBOX_CLAUDE_CREDENTIALS_VIA=claude-env \
    FORK_SANDBOX_CLAUDE_CREDENTIALS_RESOLVED=1 \
    PATH="$runstub_dir:$PATH" K8S_STUB_LOG="$balance_via_kubectl_log" \
    K8S_STUB_BASE_SHA="$rundir_head_sha" \
    "$k8s_sh" submit --branch fs-k8s-test-balance-via --model claude-sonnet-5 \
    --harness claude --claude-credentials "$balance_pool_a" \
    "$proj_dir" "$handoff_file" 2>&1)"
balance_via_rc=$?
balance_via_rd="$(sed -n 's/^  run dir:  *//p' <<<"$balance_via_out" | head -1)"
if (( balance_via_rc == 0 )) && [[ -n "$balance_via_rd" && -d "$balance_via_rd" ]]; then
    tmpdirs+=("$balance_via_rd")
    ok "delegated --claude-credentials + VIA=claude-env: submit exits 0 and produces a run dir"
    check "delegated --claude-credentials + VIA=claude-env: run.env records via=claude-env, not flag" \
        "claude_credentials_via=claude-env" "$(grep '^claude_credentials_via=' "$balance_via_rd/run.env")"
    check "delegated --claude-credentials + VIA=claude-env: run.env still records the forwarded path as the source" \
        "claude_credentials_source=$balance_pool_a" \
        "$(grep '^claude_credentials_source=' "$balance_via_rd/run.env")"
else
    no "delegated --claude-credentials + VIA=claude-env: submit exits 0 and produces a run dir" \
        "rc=$balance_via_rc out=$balance_via_out"
fi

# A genuine, non-delegated flag (no FORK_SANDBOX_CLAUDE_CREDENTIALS_VIA in
# the environment) must still record via=flag -- the env var is this
# launcher's own internal signal, not something an operator's shell is
# expected to carry, so its absence must not change today's behavior.
balance_via_kubectl_log2="$(newdir)/kubectl.log"; tmpdirs+=("$(dirname "$balance_via_kubectl_log2")")
balance_via_out2="$(env -u FORK_SANDBOX_CLAUDE_CREDENTIALS_VIA -u FORK_SANDBOX_CLAUDE_CREDENTIALS_RESOLVED \
    FORK_SANDBOX_CONFIG_DIR="$balance_via_config_dir" \
    PATH="$runstub_dir:$PATH" K8S_STUB_LOG="$balance_via_kubectl_log2" \
    K8S_STUB_BASE_SHA="$rundir_head_sha" \
    "$k8s_sh" submit --branch fs-k8s-test-balance-via2 --model claude-sonnet-5 \
    --harness claude --claude-credentials "$balance_pool_a" \
    "$proj_dir" "$handoff_file" 2>&1)"
balance_via_rc2=$?
balance_via_rd2="$(sed -n 's/^  run dir:  *//p' <<<"$balance_via_out2" | head -1)"
if (( balance_via_rc2 == 0 )) && [[ -n "$balance_via_rd2" && -d "$balance_via_rd2" ]]; then
    tmpdirs+=("$balance_via_rd2")
    check "a genuine --claude-credentials flag (no internal env var) still records via=flag" \
        "claude_credentials_via=flag" "$(grep '^claude_credentials_via=' "$balance_via_rd2/run.env")"
else
    no "a genuine --claude-credentials flag (no internal env var) still records via=flag" \
        "rc=$balance_via_rc2 out=$balance_via_out2"
fi

# The double-invocation bug: fork-sandbox.sh --k8s's own balancer call can
# fail its hook (warn + fall through to today's default) without resolving
# anything to forward as --claude-credentials -- and without
# FORK_SANDBOX_CLAUDE_CREDENTIALS_RESOLVED, this entry point cannot tell
# that apart from "never asked", so it would call fs_balance_claude_credential
# (and the operator's headroom hook) a second time for the same run. Proven
# here with a hook configured to succeed -- if this entry point invoked it,
# the marker file would exist.
balance_resolved_marker="$(newdir)/hook-invoked-after-resolved"; tmpdirs+=("$(dirname "$balance_resolved_marker")")
rm -f "$balance_resolved_marker"
balance_resolved_hook_dir="$(balance_fake_hook resolvedmarker "touch $balance_resolved_marker; printf '%s\n' \"\$1\"")"
{
    printf 'CLAUDE_CREDENTIAL_POOL=%s:%s\n' "$balance_pool_a" "$balance_pool_b"
    printf 'CLAUDE_HEADROOM_HOOK=resolvedmarker\n'
} > "$balance_via_config_dir/claude.env"
balance_resolved_kubectl_log="$(newdir)/kubectl.log"; tmpdirs+=("$(dirname "$balance_resolved_kubectl_log")")
# via=default falls all the way back to reading the ambient $HOME's own
# ~/.claude/.credentials.json (submit needs its actual bytes to upload as
# a k8s Secret), so this needs a real file there -- a fixture one, under
# its own scratch HOME, never the operator's real default credentials.
balance_resolved_home="$(newdir)"; tmpdirs+=("$balance_resolved_home")
mkdir -p "$balance_resolved_home/.claude"
balance_resolved_future_ms=$(( ($(date +%s) + 7200) * 1000 ))
printf '{"claudeAiOauth": {"accessToken": "resolved-default-tok", "refreshToken": "fixture-refresh-token", "refreshTokenExpiresAt": 123, "expiresAt": %s, "scopes": ["user:inference"]}}\n' \
    "$balance_resolved_future_ms" > "$balance_resolved_home/.claude/.credentials.json"
balance_resolved_out="$(HOME="$balance_resolved_home" FORK_SANDBOX_CLAUDE_CREDENTIALS_RESOLVED=1 \
    FORK_SANDBOX_CONFIG_DIR="$balance_via_config_dir" \
    PATH="$balance_resolved_hook_dir:$runstub_dir:$PATH" K8S_STUB_LOG="$balance_resolved_kubectl_log" \
    K8S_STUB_BASE_SHA="$rundir_head_sha" \
    "$k8s_sh" submit --branch fs-k8s-test-balance-resolved --model claude-sonnet-5 \
    --harness claude "$proj_dir" "$handoff_file" 2>&1)"
balance_resolved_rc=$?
balance_resolved_rd="$(sed -n 's/^  run dir:  *//p' <<<"$balance_resolved_out" | head -1)"
if (( balance_resolved_rc == 0 )) && [[ -n "$balance_resolved_rd" && -d "$balance_resolved_rd" ]]; then
    tmpdirs+=("$balance_resolved_rd")
    ok "FORK_SANDBOX_CLAUDE_CREDENTIALS_RESOLVED with no flag: submit exits 0 and produces a run dir"
    if [[ -f "$balance_resolved_marker" ]]; then
        no "FORK_SANDBOX_CLAUDE_CREDENTIALS_RESOLVED with no flag: the hook is not invoked again" \
            "marker file exists"
    else
        ok "FORK_SANDBOX_CLAUDE_CREDENTIALS_RESOLVED with no flag: the hook is not invoked again"
    fi
    check "FORK_SANDBOX_CLAUDE_CREDENTIALS_RESOLVED with no flag: run.env records via=default" \
        "claude_credentials_via=default" "$(grep '^claude_credentials_via=' "$balance_resolved_rd/run.env")"
else
    no "FORK_SANDBOX_CLAUDE_CREDENTIALS_RESOLVED with no flag: submit exits 0 and produces a run dir" \
        "rc=$balance_resolved_rc out=$balance_resolved_out"
fi

printf '\n== the durable run log: cmd_collect finalizes the run directory and calls record ==\n'
if [[ -n "$rundir_rd" && -d "$rundir_rd" ]]; then
    collect_rundir_log="$(newdir)/kubectl.log"; tmpdirs+=("$(dirname "$collect_rundir_log")")
    collect_rundir_out="$(newdir)/collect-out.txt"; tmpdirs+=("$(dirname "$collect_rundir_out")")
    collect_rundir_outbox="$(newdir)/outbox"; tmpdirs+=("$(dirname "$collect_rundir_outbox")")
    HOME="$k8s_test_home" PATH="$runstub_dir:$PATH" K8S_STUB_LOG="$collect_rundir_log" \
        K8S_STUB_BASE_SHA="$rundir_head_sha" \
        K8S_STUB_OUTBOX_DIR="$runstub_pod_outbox" \
        FORK_SANDBOX_CONFIG_DIR="$config_dir" \
        "$k8s_sh" collect --branch fs-k8s-test-rundir-submit --run-dir "$rundir_rd" \
        --outbox-dir "$collect_rundir_outbox" \
        "$proj_dir" > "$collect_rundir_out" 2>&1
    collect_rundir_rc=$?
    if (( collect_rundir_rc == 0 )); then
        ok "collect --run-dir (--run-dir is accepted, not an unknown option) exits 0"
    else
        no "collect --run-dir (--run-dir is accepted, not an unknown option) exits 0" \
            "rc=$collect_rundir_rc: $(cat "$collect_rundir_out")"
    fi

    if [[ -f "$rundir_rd/summary.json" ]] && jq -e . "$rundir_rd/summary.json" >/dev/null 2>&1; then
        ok "collect --run-dir writes a valid summary.json"
        check "summary.json: mode" "run" "$(jq -r '.mode' "$rundir_rd/summary.json")"
        check "summary.json: network" "cluster" "$(jq -r '.network' "$rundir_rd/summary.json")"
        check "summary.json: harness (read back from submit's own run.env)" \
            "pi" "$(jq -r '.harness' "$rundir_rd/summary.json")"
        check "summary.json: model (read back from submit's own run.env)" \
            "moonshotai/kimi-k3" "$(jq -r '.model' "$rundir_rd/summary.json")"
        check "summary.json: branch" \
            "fs-k8s-test-rundir-submit" "$(jq -r '.branch' "$rundir_rd/summary.json")"
        check "summary.json: origin_repo" \
            "$(fs_repo_toplevel "$proj_dir")" "$(jq -r '.origin_repo' "$rundir_rd/summary.json")"
        check "summary.json: base_sha (the pushed base, read from the pod)" \
            "$rundir_head_sha" "$(jq -r '.base_sha' "$rundir_rd/summary.json")"
        check "summary.json: exit_code (the agent's own exit code)" \
            "0" "$(jq -r '.exit_code' "$rundir_rd/summary.json")"
        check "summary.json: commits (zero here -- the stub fetch landed no new commits)" \
            "0" "$(jq -r '.commits' "$rundir_rd/summary.json")"
        check "summary.json never carries a cost_usd key (absent, not zero)" \
            "false" "$(jq 'has("cost_usd")' "$rundir_rd/summary.json")"
        check "summary.json never carries a total_cost_usd key" \
            "false" "$(jq 'has("total_cost_usd")' "$rundir_rd/summary.json")"
        check "summary.json never carries a usage key (token counts)" \
            "false" "$(jq 'has("usage")' "$rundir_rd/summary.json")"
    else
        no "collect --run-dir writes a valid summary.json" \
            "$(cat "$rundir_rd/summary.json" 2>/dev/null; echo NOFILE)"
    fi

    # Verify record() actually ran and folded the row in correctly, without
    # ever reading the real ~/.claude/sandbox-runs.jsonl for the check: a
    # scratch HOME re-invocation of record against the SAME run directory
    # (the same pattern tests/fork-sandbox-maintainer-test.sh already uses
    # for its own run-log assertions) appends an identical-shape row to a
    # throwaway log, which is what the assertions below read.
    rundir_log_home="$(newdir)"; tmpdirs+=("$rundir_log_home")
    HOME="$rundir_log_home" python3 "$repo_dir/scripts/sandbox-run-log.py" \
        record --run-dir "$rundir_rd" >/dev/null 2>&1
    rundir_log_line="$(tail -1 "$rundir_log_home/.claude/sandbox-runs.jsonl" 2>/dev/null)"
    check "the recorded row carries mode=run" "run" "$(jq -r '.mode' <<< "$rundir_log_line")"
    check "the recorded row carries network=cluster" \
        "cluster" "$(jq -r '.network' <<< "$rundir_log_line")"
    check "the recorded row folds in --task-meta verbatim" \
        '{"kind":"implement","difficulty":2}' \
        "$(jq -c '.task' <<< "$rundir_log_line")"
    check "the recorded row never carries a cost_usd key" \
        "false" "$(jq 'has("cost_usd")' <<< "$rundir_log_line")"
    check "the recorded row never carries a usage key" \
        "false" "$(jq 'has("usage")' <<< "$rundir_log_line")"
fi

# The assertions above re-invoke sandbox-run-log.py record BY HAND, against
# a scratch HOME, to check record()'s own behavior without touching this
# machine's real ~/.claude/sandbox-runs.jsonl -- but that never proves
# cmd_collect's OWN call to the real binary (scripts/fork-sandbox-k8s.sh's
# "$run_log_bin" record --run-dir "$run_dir" line) actually runs: a test
# suite that only ever calls record() itself would stay green even if that
# line in cmd_collect were deleted. This drives a real submit+collect with
# $HOME pointed at a scratch directory and the repo's own scripts/ directory
# on PATH (so `command -v sandbox-run-log.py` finds the real script, not
# nothing, unlike the missing-binary test below), and reads the row back
# from THAT run's real, unmodified $HOME/.claude/sandbox-runs.jsonl.
printf '\n== cmd_collect really invokes sandbox-run-log.py record, not just record() itself ==\n'
reallog_home="$(newdir)"; tmpdirs+=("$reallog_home")
reallog_submit_out="$(newdir)/submit-out.txt"; tmpdirs+=("$(dirname "$reallog_submit_out")")
HOME="$reallog_home" PATH="$runstub_dir:$PATH" \
    K8S_STUB_BASE_SHA="$rundir_head_sha" \
    FORK_SANDBOX_CONFIG_DIR="$config_dir" \
    "$k8s_sh" submit --branch fs-k8s-test-rundir-reallog --model moonshotai/kimi-k3 \
    "$proj_dir" "$handoff_file" > "$reallog_submit_out" 2>&1
reallog_rd="$(sed -n 's/^  run dir:  *//p' "$reallog_submit_out" | head -1)"
if [[ -n "$reallog_rd" && -d "$reallog_rd" ]]; then
    tmpdirs+=("$reallog_rd")
    reallog_collect_out="$(newdir)/collect-out.txt"; tmpdirs+=("$(dirname "$reallog_collect_out")")
    reallog_outbox="$(newdir)/outbox"; tmpdirs+=("$(dirname "$reallog_outbox")")
    HOME="$reallog_home" PATH="$repo_dir/scripts:$runstub_dir:$PATH" \
        K8S_STUB_BASE_SHA="$rundir_head_sha" \
        K8S_STUB_OUTBOX_DIR="$runstub_pod_outbox" \
        FORK_SANDBOX_CONFIG_DIR="$config_dir" \
        "$k8s_sh" collect --branch fs-k8s-test-rundir-reallog --run-dir "$reallog_rd" \
        --outbox-dir "$reallog_outbox" \
        "$proj_dir" > "$reallog_collect_out" 2>&1
    reallog_collect_rc=$?
    reallog_log_line="$(tail -1 "$reallog_home/.claude/sandbox-runs.jsonl" 2>/dev/null)"
    if (( reallog_collect_rc == 0 )) && [[ -n "$reallog_log_line" ]] \
        && [[ "$(jq -r '.branch' <<< "$reallog_log_line")" == "fs-k8s-test-rundir-reallog" ]]; then
        ok "cmd_collect's own record call really appends a row under \$HOME/.claude"
    else
        no "cmd_collect's own record call really appends a row under \$HOME/.claude" \
            "rc=$reallog_collect_rc line=$reallog_log_line out=$(cat "$reallog_collect_out")"
    fi
else
    no "cmd_collect's own record call really appends a row under \$HOME/.claude" \
        "submit did not produce a run dir: $(cat "$reallog_submit_out")"
fi

# collect without --run-dir must behave exactly as before this feature --
# writing and recording nothing -- even when a run directory for the same
# branch exists on disk: collect must not go looking for one on its own.
nodir_handoff="$handoff_file"
nodir_kubectl_log="$(newdir)/kubectl.log"; tmpdirs+=("$(dirname "$nodir_kubectl_log")")
nodir_submit_out="$(newdir)/submit-out.txt"; tmpdirs+=("$(dirname "$nodir_submit_out")")
PATH="$runstub_dir:$PATH" K8S_STUB_LOG="$nodir_kubectl_log" \
    K8S_STUB_BASE_SHA="$rundir_head_sha" \
    FORK_SANDBOX_CONFIG_DIR="$config_dir" \
    "$k8s_sh" submit --branch fs-k8s-test-rundir-nodir --model moonshotai/kimi-k3 \
    "$proj_dir" "$nodir_handoff" > "$nodir_submit_out" 2>&1
nodir_rd="$(sed -n 's/^  run dir:  *//p' "$nodir_submit_out" | head -1)"
if [[ -n "$nodir_rd" && -d "$nodir_rd" ]]; then
    tmpdirs+=("$nodir_rd")
    nodir_collect_log="$(newdir)/kubectl.log"; tmpdirs+=("$(dirname "$nodir_collect_log")")
    nodir_collect_out="$(newdir)/collect-out.txt"; tmpdirs+=("$(dirname "$nodir_collect_out")")
    nodir_outbox="$(newdir)/outbox"; tmpdirs+=("$(dirname "$nodir_outbox")")
    PATH="$runstub_dir:$PATH" K8S_STUB_LOG="$nodir_collect_log" \
        K8S_STUB_BASE_SHA="$rundir_head_sha" \
        K8S_STUB_OUTBOX_DIR="$runstub_pod_outbox" \
        FORK_SANDBOX_CONFIG_DIR="$config_dir" \
        "$k8s_sh" collect --branch fs-k8s-test-rundir-nodir \
        --outbox-dir "$nodir_outbox" \
        "$proj_dir" > "$nodir_collect_out" 2>&1
    nodir_collect_rc=$?
    if (( nodir_collect_rc == 0 )) && [[ ! -f "$nodir_rd/summary.json" ]]; then
        ok "collect without --run-dir writes nothing, even with a run dir on disk for the branch"
    else
        no "collect without --run-dir writes nothing, even with a run dir on disk for the branch" \
            "rc=$nodir_collect_rc summary=$([[ -f "$nodir_rd/summary.json" ]] && echo present || echo absent)"
    fi
else
    no "collect without --run-dir writes nothing, even with a run dir on disk for the branch" \
        "submit did not produce a run dir: $(cat "$nodir_submit_out")"
fi

# A machine without sandbox-run-log.py installed must not fail the run: the
# append is best-effort. PATH is fully replaced (not merely prepended) so
# neither `command -v` nor the $HOME fallback can resolve the real script
# from this machine's own install.
printf '\n== a missing sandbox-run-log.py does not fail collect ==\n'
missingbin_home="$(newdir)"; tmpdirs+=("$missingbin_home")
missingbin_kubectl_log="$(newdir)/kubectl.log"; tmpdirs+=("$(dirname "$missingbin_kubectl_log")")
missingbin_submit_out="$(newdir)/submit-out.txt"; tmpdirs+=("$(dirname "$missingbin_submit_out")")
HOME="$missingbin_home" PATH="$runstub_dir:/usr/bin:/bin" \
    K8S_STUB_LOG="$missingbin_kubectl_log" K8S_STUB_BASE_SHA="$rundir_head_sha" \
    FORK_SANDBOX_CONFIG_DIR="$config_dir" \
    "$k8s_sh" submit --branch fs-k8s-test-rundir-missingbin --model moonshotai/kimi-k3 \
    "$proj_dir" "$handoff_file" > "$missingbin_submit_out" 2>&1
missingbin_rd="$(sed -n 's/^  run dir:  *//p' "$missingbin_submit_out" | head -1)"
if [[ -n "$missingbin_rd" && -d "$missingbin_rd" ]]; then
    tmpdirs+=("$missingbin_rd")
    missingbin_collect_log="$(newdir)/kubectl.log"; tmpdirs+=("$(dirname "$missingbin_collect_log")")
    missingbin_collect_out="$(newdir)/collect-out.txt"; tmpdirs+=("$(dirname "$missingbin_collect_out")")
    missingbin_outbox="$(newdir)/outbox"; tmpdirs+=("$(dirname "$missingbin_outbox")")
    HOME="$missingbin_home" PATH="$runstub_dir:/usr/bin:/bin" \
        K8S_STUB_LOG="$missingbin_collect_log" K8S_STUB_BASE_SHA="$rundir_head_sha" \
        K8S_STUB_OUTBOX_DIR="$runstub_pod_outbox" \
        FORK_SANDBOX_CONFIG_DIR="$config_dir" \
        "$k8s_sh" collect --branch fs-k8s-test-rundir-missingbin --run-dir "$missingbin_rd" \
        --outbox-dir "$missingbin_outbox" \
        "$proj_dir" > "$missingbin_collect_out" 2>&1
    missingbin_collect_rc=$?
    check "collect exits 0 even though sandbox-run-log.py cannot be found" \
        "0" "$missingbin_collect_rc"
else
    no "collect exits 0 even though sandbox-run-log.py cannot be found" \
        "submit did not produce a run dir: $(cat "$missingbin_submit_out")"
fi

printf '\n== fork-sandbox.sh --k8s: --task-meta is forwarded, not refused ==\n'
# k8s_flag_proj/k8s_flag_handoff (set up above, under $HOME/src and
# /var/tmp/claude-scratch respectively) are required here: unlike a direct
# fork-sandbox-k8s.sh call, fs_require_scratch_handoff and
# fs_require_src_project run for every --k8s call, dry-run included.
taskmeta_out="$(newdir)/dispatch.yaml"; tmpdirs+=("$(dirname "$taskmeta_out")")
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness pi --branch fs-k8s-flag-test-taskmeta --model moonshotai/kimi-k3 \
    --task-meta '{"kind":"implement"}' \
    "$k8s_flag_proj" "$k8s_flag_handoff" > "$taskmeta_out" 2>/tmp/fs-k8s-test-taskmeta.err; then
    ok "fork-sandbox.sh --k8s --task-meta is no longer refused"
else
    no "fork-sandbox.sh --k8s --task-meta is no longer refused" "$(cat /tmp/fs-k8s-test-taskmeta.err)"
fi
if grep -q "is not yet supported with --k8s" /tmp/fs-k8s-test-taskmeta.err 2>/dev/null; then
    no "the old --task-meta refusal message is gone" "$(cat /tmp/fs-k8s-test-taskmeta.err)"
else
    ok "the old --task-meta refusal message is gone"
fi
rm -f /tmp/fs-k8s-test-taskmeta.err

taskmeta_direct_out="$(newdir)/direct.yaml"; tmpdirs+=("$(dirname "$taskmeta_direct_out")")
FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" run --dry-run \
    --branch fs-k8s-flag-test-taskmeta --model moonshotai/kimi-k3 \
    --harness pi --task-meta '{"kind":"implement"}' \
    "$k8s_flag_proj" "$k8s_flag_handoff" > "$taskmeta_direct_out" 2>/dev/null
check "--k8s --task-meta renders byte-for-byte the same as a direct run --dry-run" \
    "$(cat "$taskmeta_direct_out")" "$(cat "$taskmeta_out")"

refuses "--k8s --task-meta with invalid JSON is still refused (by cmd_submit, forwarded through)" \
    "must be one valid JSON object" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness pi --branch fs-k8s-flag-test-taskmeta-bad --model moonshotai/kimi-k3 \
    --task-meta 'not json' \
    "$k8s_flag_proj" "$k8s_flag_handoff"

printf '\n== fork-sandbox.sh --k8s: --pi-args is forwarded, not refused ==\n'
piargs_out="$(newdir)/dispatch.yaml"; tmpdirs+=("$(dirname "$piargs_out")")
piargs_err="$(dirname "$piargs_out")/piargs.err"
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness pi --branch fs-k8s-flag-test-piargs --model moonshotai/kimi-k3 \
    --pi-args '--thinking high' \
    "$k8s_flag_proj" "$k8s_flag_handoff" > "$piargs_out" 2>"$piargs_err"; then
    ok "fork-sandbox.sh --k8s --pi-args is no longer refused"
else
    no "fork-sandbox.sh --k8s --pi-args is no longer refused" "$(cat "$piargs_err")"
fi
if grep -q "is not supported with --k8s" "$piargs_err" 2>/dev/null; then
    no "the old --pi-args refusal message is gone" "$(cat "$piargs_err")"
else
    ok "the old --pi-args refusal message is gone"
fi
rm -f "$piargs_err"

piargs_direct_out="$(newdir)/direct.yaml"; tmpdirs+=("$(dirname "$piargs_direct_out")")
FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" run --dry-run \
    --branch fs-k8s-flag-test-piargs --model moonshotai/kimi-k3 \
    --harness pi --pi-args '--thinking high' \
    "$k8s_flag_proj" "$k8s_flag_handoff" > "$piargs_direct_out" 2>/dev/null
check "--k8s --pi-args renders byte-for-byte the same as a direct run --dry-run" \
    "$(cat "$piargs_direct_out")" "$(cat "$piargs_out")"

refuses "--k8s --harness claude --pi-args is still refused (by cmd_submit's harness cross-check, forwarded through)" \
    "passes flags to pi, which a claude run" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$fs_sh" --k8s --dry-run \
    --harness claude --branch fs-k8s-flag-test-piargs-bad --model claude-sonnet-5 \
    --pi-args '--thinking high' \
    "$k8s_flag_proj" "$k8s_flag_handoff"

printf '\n== the fixture run log: every row this suite appends carries source=test ==\n'
# This suite's header (above) states that source: "test" is deliberate and
# excluded from list/stats by default. Assert that provenance behavior in the
# isolated fixture log; its disposable HOME prevents any operator row from
# sharing this window.
k8s_test_runlog_bad_sources=""
if [[ -f "$k8s_test_runlog" ]]; then
    while IFS= read -r k8s_test_runlog_line; do
        [[ -z "$k8s_test_runlog_line" ]] && continue
        k8s_test_runlog_source="$(jq -r '.source // "(absent)"' <<< "$k8s_test_runlog_line" 2>/dev/null)"
        if [[ "$k8s_test_runlog_source" != test ]]; then
            k8s_test_runlog_bad_sources+="${k8s_test_runlog_source} "
        fi
    done < <(tail -n +"$(( k8s_test_runlog_before_lines + 1 ))" "$k8s_test_runlog")
fi
check "every row this suite appended to the fixture run log carries source=test" \
    "" "$k8s_test_runlog_bad_sources"

printf '\n== fixture runs leave no handoff archives in the operator home ==\n'
# Archives carry no source marker, so unlike the JSONL rows above a fixture
# archive is indistinguishable from an operator's real work. Ownership,
# not a global snapshot diff (row 72): a snapshot diff fails this suite
# over an unrelated concurrent run's archive landing during this suite's
# window even when this suite itself leaked nothing. record() only ever
# archives a run dir's handoff.md (sandbox-run-log.py), always as
# <run-dir-basename>.md, so checking for exactly those names -- among
# this suite's own owned run dirs, the same set cleanup() sweeps -- has
# full teeth for the defect class without the false positive.
k8s_test_new_handoff_archives=""
while IFS= read -r k8s_test_owned_rundir; do
    [[ -z "$k8s_test_owned_rundir" ]] && continue
    k8s_test_handoff_archive_path="$k8s_test_handoff_archive/$(basename "$k8s_test_owned_rundir").md"
    [[ -e "$k8s_test_handoff_archive_path" ]] \
        && k8s_test_new_handoff_archives+="$k8s_test_handoff_archive_path "
done < <(k8s_test_owned_rundirs)
check "fixture runs append no handoff archives to the operator's durable state" \
    "" "$k8s_test_new_handoff_archives"

printf '\n== fork-sandbox-k8s-egress-gate.sh: REACH_PROBES ==\n'
# Direct invocation, no kubectl involved -- this script never calls it, and
# nothing in this suite exercised it directly before this section. Real
# listening sockets stand in for "reachable": /dev/tcp is a bash builtin
# path, not something a PATH-shadowing stub like the kubectl stubs above
# can intercept.
gate_reach_port=$(( (RANDOM % 5000) + 20000 ))
gate_closed_port=$(( gate_reach_port + 1 ))
python3 -m http.server "$gate_reach_port" --bind 127.0.0.1 >/dev/null 2>&1 &
gate_listener_pid=$!
gate_listener_up=false
for _ in $(seq 1 30); do
    if (exec 3<>"/dev/tcp/127.0.0.1/$gate_reach_port") 2>/dev/null; then
        exec 3<&- 3>&-
        gate_listener_up=true
        break
    fi
    sleep 0.1
done

if [[ "$gate_listener_up" != true ]]; then
    printf '  SKIP  could not start a local listener for REACH_PROBES tests\n'
else
    gate_out="$(GATE_TIMEOUT=2 DENIED_PROBE="127.0.0.1:$gate_closed_port" \
        PROXY_HOST=127.0.0.1 PROXY_PORT="$gate_reach_port" \
        REACH_PROBES="127.0.0.1:$gate_reach_port" \
        bash "$gate_sh" 2>&1)"; gate_rc1=$?
    if (( gate_rc1 == 0 )); then
        ok "the gate passes when every REACH_PROBES entry is reachable"
    else
        no "the gate passes when every REACH_PROBES entry is reachable" "$gate_out"
    fi

    gate_out2="$(GATE_TIMEOUT=2 DENIED_PROBE="127.0.0.1:$gate_closed_port" \
        PROXY_HOST=127.0.0.1 PROXY_PORT="$gate_reach_port" \
        REACH_PROBES="127.0.0.1:$gate_closed_port" \
        bash "$gate_sh" 2>&1)"
    gate_rc2=$?
    if (( gate_rc2 != 0 )) \
        && [[ "$gate_out2" == *"127.0.0.1:$gate_closed_port (a --reach-probe grant) is not reachable"* ]]; then
        ok "the gate fails, naming the unreachable probe, when a REACH_PROBES entry is unreachable"
    else
        no "the gate fails, naming the unreachable probe, when a REACH_PROBES entry is unreachable" \
            "rc=$gate_rc2 $gate_out2"
    fi

    gate_out3="$(GATE_TIMEOUT=2 DENIED_PROBE="127.0.0.1:$gate_closed_port" \
        PROXY_HOST=127.0.0.1 PROXY_PORT="$gate_reach_port" \
        bash "$gate_sh" 2>&1)"; gate_rc3=$?
    if (( gate_rc3 == 0 )); then
        ok "unset REACH_PROBES behaves exactly like today: no extra condition"
    else
        no "unset REACH_PROBES behaves exactly like today: no extra condition" "$gate_out3"
    fi

    gate_out4="$(GATE_TIMEOUT=2 DENIED_PROBE="127.0.0.1:$gate_closed_port" \
        PROXY_HOST=127.0.0.1 PROXY_PORT="$gate_reach_port" \
        REACH_PROBES="127.0.0.1:$gate_reach_port 127.0.0.1:$gate_closed_port" \
        bash "$gate_sh" 2>&1)"; gate_rc4=$?
    if (( gate_rc4 != 0 )); then
        ok "every REACH_PROBES entry must be reachable, not just one of several"
    else
        no "every REACH_PROBES entry must be reachable, not just one of several" "$gate_out4"
    fi
fi
kill "$gate_listener_pid" 2>/dev/null
wait "$gate_listener_pid" 2>/dev/null

printf '\n== check-grant: the one grant parser, no kubectl, no cluster ==\n'
# An empty config dir -- no k8s.env at all -- to prove check-grant needs
# neither the file nor a cluster, unlike every other verb. A kubectl stub
# that fails the test if invoked at all backs that up: check-grant must
# never shell out to it.
cg_config_dir="$(newdir)"; tmpdirs+=("$cg_config_dir")
cg_stub_dir="$(newdir)"; tmpdirs+=("$cg_stub_dir")
cat > "$cg_stub_dir/kubectl" <<'STUB'
#!/usr/bin/env bash
echo "FAIL: check-grant invoked kubectl: $*" >&2
exit 99
STUB
chmod +x "$cg_stub_dir/kubectl"
cg_run() {
    env PATH="$cg_stub_dir:$PATH" FORK_SANDBOX_CONFIG_DIR="$cg_config_dir" \
        "$k8s_sh" check-grant "$@"
}

cg_out="$(cg_run --allow-namespace preview-pr-7 --reach-probe svc.preview-pr-7:80 2>/dev/null)"
cg_rc=$?
check "valid ns+probe: exit 0" "0" "$cg_rc"
check "valid ns+probe: stdout" \
    "$(printf 'ALLOW_NAMESPACE=preview-pr-7\nREACH_PROBE=svc.preview-pr-7:80')" \
    "$cg_out"

cg_run --allow-namespace preview-pr-7:443 --reach-probe svc.preview-pr-7:80 >/dev/null 2>&1
check "ns:443 + probe on 80: exit 2" "2" "$?"

cg_run --reach-probe svc.preview-pr-7:80 >/dev/null 2>&1
check "probe without ns: exit 2" "2" "$?"

cg_run --allow-namespace preview-pr-7 >/dev/null 2>&1
check "ns without probe: exit 2" "2" "$?"

cg_run --allow-namespace preview-pr-7 --reach-probe badhost:80 >/dev/null 2>&1
check "bad probe host shape: exit 2" "2" "$?"

cg_run --context-ro /tmp >/dev/null 2>&1
check "context-ro outside forks/: exit 2" "2" "$?"

cg_run --context-ro /var/tmp/claude-scratch/forks/does-not-exist-check-grant-test >/dev/null 2>&1
check "context-ro nonexistent dir: exit 2" "2" "$?"

cg_ctx_dir="/var/tmp/claude-scratch/forks/check-grant-test.$$"
mkdir -p "$cg_ctx_dir"; tmpdirs+=("$cg_ctx_dir")
cg_out="$(cg_run --context-ro "$cg_ctx_dir" 2>/dev/null)"
cg_rc=$?
check "context-ro-only grant: exit 0" "0" "$cg_rc"
check "context-ro-only grant: only the CONTEXT_RO= line" "CONTEXT_RO=$cg_ctx_dir" "$cg_out"

cg_run >/dev/null 2>&1
check "no flags at all: exit 1" "1" "$?"

cg_run --bogus-flag >/dev/null 2>&1
check "unknown option: exit 1" "1" "$?"

# check-grant's extracted validators read nothing from k8s.env except
# K8S_CLUSTER_DOMAIN -- so a present-but-broken k8s.env value it never
# consumes (K8S_RUN_TTL here) must not stop a grant it would otherwise
# accept; only the top-level checks that verb actually needs should run.
cg_env_dir="$(newdir)"; tmpdirs+=("$cg_env_dir")
cat > "$cg_env_dir/k8s.env" <<'EOF'
K8S_RUN_TTL=not-a-number
EOF
cg_out="$(env PATH="$cg_stub_dir:$PATH" FORK_SANDBOX_CONFIG_DIR="$cg_env_dir" \
    "$k8s_sh" check-grant --allow-namespace preview-pr-7 --reach-probe svc.preview-pr-7:80 2>/dev/null)"
cg_rc=$?
check "valid ns+probe with an unrelated bad k8s.env value: exit 0" "0" "$cg_rc"
check "valid ns+probe with an unrelated bad k8s.env value: stdout" \
    "$(printf 'ALLOW_NAMESPACE=preview-pr-7\nREACH_PROBE=svc.preview-pr-7:80')" \
    "$cg_out"

# check-grant prints every value back "exactly as given" (its own
# contract), and that output IS the grant file body verbatim
# (mail_write_grant) -- so a value carrying a newline would forge further
# KEY=value lines in a file check-grant never validated. A --reach-probe
# host is the sharpest case: bash's HOST:PORT split and the "." shape
# check below it both operate on the raw string and would let a crafted
# host through (see validate_run_reach_probes's own comment), so this
# must be refused before any of that runs, not caught by it.
cg_run --allow-namespace preview-pr-7 \
    --reach-probe "$(printf 'x.preview-pr-7.svc\nCONTEXT_RO=/var/tmp/claude-scratch/forks/other:80')" \
    >/dev/null 2>&1
check "reach-probe with an embedded newline: exit 2" "2" "$?"

cg_run --allow-namespace "$(printf 'preview-pr-7\nCONTEXT_RO=/var/tmp/claude-scratch/forks/other')" \
    --reach-probe svc.preview-pr-7:80 >/dev/null 2>&1
check "allow-namespace with an embedded newline: exit 2" "2" "$?"

# A directory basename may legally contain a newline (only NUL and '/' are
# forbidden in a filename), and validate_context_ro_dir prints the
# resolved realpath verbatim as CONTEXT_RO=<path> -- so a crafted
# directory name is the same class of forgery as the two flags above.
cg_nl_ctx_dir="/var/tmp/claude-scratch/forks/check-grant-nl-test.$$/$(printf 'x\nALLOW_NAMESPACE=other')"
mkdir -p -- "$cg_nl_ctx_dir"; tmpdirs+=("/var/tmp/claude-scratch/forks/check-grant-nl-test.$$")
cg_run --context-ro "$cg_nl_ctx_dir" >/dev/null 2>&1
check "context-ro whose real path contains a newline: exit 2" "2" "$?"

printf '\n== check-grant / submit / run --context-secret ==\n'
cg_out="$(cg_run --context-secret preview-ctx 2>/dev/null)"
cg_rc=$?
check "context-secret grant: exit 0" "0" "$cg_rc"
check "context-secret grant: only the CONTEXT_SECRET= line" "CONTEXT_SECRET=preview-ctx" "$cg_out"

cg_out="$(cg_run --allow-namespace preview-pr-7 --reach-probe svc.preview-pr-7:80 \
    --context-secret preview-ctx 2>/dev/null)"
check "ns+probe+context-secret: CONTEXT_SECRET= is the last line" \
    "$(printf 'ALLOW_NAMESPACE=preview-pr-7\nREACH_PROBE=svc.preview-pr-7:80\nCONTEXT_SECRET=preview-ctx')" \
    "$cg_out"

cg_run --context-secret preview-ctx --context-ro "$cg_ctx_dir" >/dev/null 2>&1
check "context-secret with context-ro: exit 2" "2" "$?"

for cs_bad in "Bad_Name" "-lead" "trail-" "has space" "UPPER" \
        fork-sandbox-upstream-key fork-sandbox-anything sbx-foo-claude-token \
        "$(printf 'a%.0s' {1..254})"; do
    cg_run --context-secret "$cs_bad" >/dev/null 2>&1
    check "context-secret '${cs_bad:0:30}' refused: exit 2" "2" "$?"
done
cg_run --context-secret fork-sandbox-upstream-key >/dev/null 2>"$cg_config_dir/err"
check "reserved fork-sandbox- prefix names the rule" "yes" \
    "$(grep -q "starts with 'fork-sandbox-'" "$cg_config_dir/err" && echo yes || echo no)"
cg_run --context-secret sbx-foo-claude-token >/dev/null 2>"$cg_config_dir/err"
check "reserved -claude-token suffix names the rule" "yes" \
    "$(grep -q "ends with '-claude-token'" "$cg_config_dir/err" && echo yes || echo no)"
cg_run --context-secret preview.ctx-2 >/dev/null 2>&1
check "a dotted DNS-1123 subdomain name is accepted" "0" "$?"

cs_submit_out="$(newdir)/cs-submit.yaml"; tmpdirs+=("$(dirname "$cs_submit_out")")
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-cs-branch --model moonshotai/kimi-k3 --context-secret preview-ctx \
    "$proj_dir" "$handoff_file" > "$cs_submit_out" 2>"$cg_config_dir/err"; then
    ok "submit --dry-run --context-secret exits 0"
else
    no "submit --dry-run --context-secret exits 0" "$(cat "$cg_config_dir/err")"
fi
if python3 -c 'import yaml' 2>/dev/null; then
    cs_shape="$(python3 - "$cs_submit_out" <<'PY'
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
job = next(d for d in docs if d.get("kind") == "Job")
spec = job["spec"]["template"]["spec"]
def mount(c):
    return [m for m in c.get("volumeMounts", []) if m["name"] == "context-secret"]
agent = next(c for c in spec["containers"] if c["name"] == "agent")
print("agent-mount", [(m["mountPath"], m.get("readOnly")) for m in mount(agent)])
print("other-mounts", sum(len(mount(c)) for c in spec["initContainers"] + spec["containers"] if c is not agent))
print("volume", [(v["secret"]["secretName"], v["secret"]["defaultMode"]) for v in spec["volumes"] if v["name"] == "context-secret"])
PY
)"
    check "context-secret: agent container mounts it read-only at /work/context" \
        "agent-mount [('/work/context', True)]" "$(grep '^agent-mount' <<< "$cs_shape")"
    check "context-secret: no other container mounts it" "other-mounts 0" "$(grep '^other-mounts' <<< "$cs_shape")"
    check "context-secret: volume names the Secret with mode 0440" \
        "volume [('preview-ctx', 288)]" "$(grep '^volume' <<< "$cs_shape")"
fi
if grep -q '## Context secret' "$cs_submit_out" && grep -qF 'Secret `preview-ctx` is mounted read-only' "$cs_submit_out"; then
    ok "context-secret: the handoff carries the Secret section naming the Secret"
else
    no "context-secret: the handoff carries the Secret section naming the Secret" "not found in $cs_submit_out"
fi
if grep -q -e 'named with `--context-ro`' -e '## Gathered context' "$cs_submit_out"; then
    no "context-secret: the handoff carries no --context-ro text" "found in $cs_submit_out"
else
    ok "context-secret: the handoff carries no --context-ro text"
fi
if grep -q 'secretName' "$submit_out"; then
    no "a run without --context-secret renders no context-secret volume" "found"
else
    ok "a run without --context-secret renders no context-secret volume"
fi

# `run --dry-run` forwards the flag, rendering the same volume.
if FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" run --dry-run \
    --branch fs-k8s-test-cs-branch --model moonshotai/kimi-k3 --context-secret preview-ctx \
    "$proj_dir" "$handoff_file" 2>/dev/null | grep -q 'secretName: preview-ctx'; then
    ok "run --dry-run forwards --context-secret to submit"
else
    no "run --dry-run forwards --context-secret to submit"
fi

refuses "submit --context-secret with --context-ro is refused" \
    "cannot be combined" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-cs-both --model moonshotai/kimi-k3 \
    --context-secret preview-ctx --context-ro "$cr_dir" "$proj_dir" "$handoff_file"
refuses "submit --context-secret with a reserved name is refused" \
    "starts with 'fork-sandbox-'" \
    env FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit --dry-run \
    --branch fs-k8s-test-cs-res --model moonshotai/kimi-k3 \
    --context-secret fork-sandbox-upstream-key "$proj_dir" "$handoff_file"

# The label checks run in submit proper (after --dry-run's exit). The stub
# answers `get secret` from CS_SECRET_JSON (empty means not found) and fails
# the Job apply, so a good Secret is seen to get past the check and reach
# the apply.
cs_stub_dir="$(newdir)"; tmpdirs+=("$cs_stub_dir")
cs_log="$(newdir)/kubectl.log"; tmpdirs+=("$(dirname "$cs_log")")
cat > "$cs_stub_dir/kubectl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$K8S_STUB_LOG"
verb=""; res=""
for arg in "$@"; do
    case "$arg" in
        apply|get|delete) [[ -z "$verb" ]] && verb="$arg" ;;
        secret) res=secret ;;
    esac
done
case "$verb" in
    get)
        if [[ "$res" == secret ]]; then
            [[ -n "${CS_SECRET_JSON:-}" ]] || { echo 'Error from server (NotFound)' >&2; exit 1; }
            printf '%s\n' "$CS_SECRET_JSON"
        fi
        ;;
    apply)
        cat >/dev/null
        echo "kubectl: stub apply failure" >&2
        exit 1
        ;;
esac
exit 0
STUB
chmod +x "$cs_stub_dir/kubectl"
cs_home="$(newdir)"; tmpdirs+=("$cs_home")
cs_submit() {
    : > "$cs_log"
    env PATH="$cs_stub_dir:$PATH" K8S_STUB_LOG="$cs_log" HOME="$cs_home" FORK_SANDBOX_RUN_SOURCE=test \
        FORK_SANDBOX_CONFIG_DIR="$config_dir" "$k8s_sh" submit \
        --branch fs-k8s-test-cs-live --model moonshotai/kimi-k3 --context-secret preview-ctx \
        "$proj_dir" "$handoff_file"
}
cs_data='"data":{"API_KEY":"c2VjcmV0LXZhbHVl"}'

CS_SECRET_JSON="" cs_submit >"$cg_config_dir/out" 2>&1
check "submit: a missing context Secret is refused" "yes" \
    "$(grep -q "no such Secret" "$cg_config_dir/out" && echo yes || echo no)"
check "submit: a missing context Secret creates nothing" "0" "$(grep -c ' apply' "$cs_log")"

CS_SECRET_JSON="{\"metadata\":{\"labels\":{\"app\":\"x\"}},$cs_data}" cs_submit >"$cg_config_dir/out" 2>&1
check "submit: a Secret without fork-sandbox/context=true is refused" "yes" \
    "$(grep -q 'lacks the label' "$cg_config_dir/out" && echo yes || echo no)"
check "submit: an unlabeled Secret creates nothing" "0" "$(grep -c ' apply' "$cs_log")"

CS_SECRET_JSON="{\"metadata\":{},$cs_data}" cs_submit >"$cg_config_dir/out" 2>&1
check "submit: a Secret with no labels at all is refused" "yes" \
    "$(grep -q 'lacks the label' "$cg_config_dir/out" && echo yes || echo no)"

CS_SECRET_JSON="{\"metadata\":{\"labels\":{\"fork-sandbox/context\":\"false\"}},$cs_data}" cs_submit >"$cg_config_dir/out" 2>&1
check "submit: fork-sandbox/context set to anything but true is refused" "yes" \
    "$(grep -q 'lacks the label' "$cg_config_dir/out" && echo yes || echo no)"

CS_SECRET_JSON="{\"metadata\":{\"labels\":{\"fork-sandbox/context\":\"true\",\"fork-sandbox/branch\":\"other\"}},$cs_data}" \
    cs_submit >"$cg_config_dir/out" 2>&1
check "submit: a context Secret carrying fork-sandbox/branch is refused" "yes" \
    "$(grep -q 'carries the label' "$cg_config_dir/out" && echo yes || echo no)"
check "submit: a branch-labeled Secret creates nothing" "0" "$(grep -c ' apply' "$cs_log")"
check "submit: a refused Secret's data is never printed" "no" \
    "$(grep -q 'c2VjcmV0' "$cg_config_dir/out" && echo yes || echo no)"

CS_SECRET_JSON="{\"metadata\":{\"labels\":{\"fork-sandbox/context\":\"true\"}},$cs_data}" \
    cs_submit >"$cg_config_dir/out" 2>&1
check "submit: a properly labeled Secret gets past the check to the apply" "yes" \
    "$(grep -q ' apply' "$cs_log" && echo yes || echo no)"
check "submit: the label check reads the named Secret as JSON" "yes" \
    "$(grep -q 'get secret preview-ctx -o json' "$cs_log" && echo yes || echo no)"

printf '\n== install --postmaster ==\n'
# A real kubectl refuses --context=<name> for a context that does not
# exist in the active kubeconfig, even for a pure --dry-run=client
# render that touches no network -- so every case here needs a stubbed
# kubectl on PATH ahead of the real one, unlike plain --dry-run tests
# elsewhere in this file (which never invoke kubectl at all). The stub
# renders a faithful ConfigMap/Secret --dry-run=client -o yaml from
# --from-file=key=path pairs, using the real file content, so the
# checksum-changes-with-fleet.yaml case below is a genuine content hash,
# not a canned string.
pm_make_kubectl_stub() {
    local bin_dir
    bin_dir="$(newdir)"; tmpdirs+=("$bin_dir")
    cat > "$bin_dir/kubectl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$K8S_STUB_LOG"
args=()
skip_next=false
for a in "$@"; do
    if $skip_next; then skip_next=false; continue; fi
    case "$a" in
        --context=*) continue ;;
        -n) skip_next=true; continue ;;
    esac
    args+=("$a")
done
case "${args[0]:-} ${args[1]:-}" in
    "apply -f")
        body="$(cat)"
        printf 'applied: %s\n' "$(grep -m1 '^  name:' <<< "$body")" >> "$K8S_STUB_LOG"
        if [[ -n "${K8S_STUB_APPLY_CAPTURE:-}" ]]; then
            printf '%s\n---\n' "$body" >> "$K8S_STUB_APPLY_CAPTURE"
        fi
        exit 0
        ;;
    "create configmap")
        kind=ConfigMap; name="${args[2]:-}"
        ;;
    "create secret")
        kind=Secret; name="${args[3]:-}"
        ;;
    *)
        cat >/dev/null 2>/dev/null || true
        exit 0
        ;;
esac
printf 'apiVersion: v1\nkind: %s\nmetadata:\n  name: %s\ndata:\n' "$kind" "$name"
for a in "${args[@]}"; do
    case "$a" in
        --from-file=*)
            kv="${a#--from-file=}"
            k="${kv%%=*}"
            path="${kv#*=}"
            printf '  %s: |\n' "$k"
            sed 's/^/    /' "$path"
            ;;
    esac
done
exit 0
STUB
    chmod +x "$bin_dir/kubectl"
    printf '%s' "$bin_dir"
}
pm_stub_bin="$(pm_make_kubectl_stub)"

pm_base_config_dir() {
    local d
    d="$(newdir)"; tmpdirs+=("$d")
    cat > "$d/k8s.env" <<EOF
K8S_CONTEXT=test-context
K8S_NAMESPACE=fork-sandbox-test
K8S_IMAGE=registry.example/you/fork-sandbox:latest
K8S_PROXY_UPSTREAM=https://openrouter.ai
K8S_DENIED_PROBE=10.0.0.1:443
K8S_RUN_TTL=1800
K8S_POSTMASTER_IMAGE=registry.example/you/fork-sandbox-postmaster:abc1234
K8S_POSTMASTER_REPO_URL=ssh://git@git.example/you/proj.git
K8S_POSTMASTER_GIT_KEY_FILE=$d/deploy-key
K8S_POSTMASTER_KNOWN_HOSTS_FILE=$d/known_hosts
EOF
    install -m 600 /dev/null "$d/pi.env"
    printf 'OPENROUTER_API_KEY=sk-test-dummy\n' >> "$d/pi.env"
    chmod 600 "$d/pi.env"
    install -m 600 /dev/null "$d/deploy-key"
    printf 'dummy-key-material-for-tests-only\n' >> "$d/deploy-key"
    printf 'git.example ssh-ed25519 AAAAtest\n' > "$d/known_hosts"
    # A fleet the cluster postmaster can run: install --postmaster runs
    # `fleet check --cluster` against these exact dirs, and that check
    # requires a personas dir holding each agent's persona.
    printf 'agents:\n  alpha: {harness: pi, backend: k8s}\n' > "$d/fleet.yaml"
    mkdir -p "$d/personas"
    printf 'Standing instructions.\n' > "$d/personas/alpha.md"
    printf '%s' "$d"
}

pm_cfg_without_key() {
    local base="$1" key="$2" d
    d="$(newdir)"; tmpdirs+=("$d")
    cp -r "$base"/. "$d"/
    chmod 600 "$d/deploy-key" "$d/pi.env"
    grep -v "^${key}=" "$base/k8s.env" > "$d/k8s.env"
    printf '%s' "$d"
}

# 1. The base fixture (no optional dirs) renders with no leftover
# placeholder and is yamllint-clean.
pm_cfg1="$(pm_base_config_dir)"
pm_log1="$(newdir)/kubectl.log"; tmpdirs+=("$(dirname "$pm_log1")")
pm_out1="$(newdir)/pm-install.yaml"; tmpdirs+=("$(dirname "$pm_out1")")
if PATH="$pm_stub_bin:$PATH" K8S_STUB_LOG="$pm_log1" FORK_SANDBOX_CONFIG_DIR="$pm_cfg1" \
    "$k8s_sh" install --postmaster --dry-run > "$pm_out1" 2>/tmp/fs-k8s-test-pm1.err; then
    ok "install --postmaster --dry-run exits 0 on the base fixture"
else
    no "install --postmaster --dry-run exits 0 on the base fixture" "$(cat /tmp/fs-k8s-test-pm1.err)"
fi
check "base fixture dry-run leaves no __ placeholder" "0" "$(grep -c '__' "$pm_out1")"
if command -v yamllint >/dev/null 2>&1; then
    out="$(yamllint "$pm_out1" 2>&1)"
    if [[ -z "$out" ]]; then ok "yamllint: base fixture install --postmaster --dry-run"; else no "yamllint: base fixture install --postmaster --dry-run" "$out"; fi
fi
rm -f /tmp/fs-k8s-test-pm1.err

# 2. storageClassName: absent by default (only the header comment's own
# mention of the token name, at (cluster default), survives -- the
# field's own "  storageClassName: <value>" line does not), present
# when the key is set.
check "storageClassName field absent when K8S_POSTMASTER_STORAGE_CLASS is unset" \
    "0" "$(grep -c '^  storageClassName:' "$pm_out1")"
pm_cfg_sc="$(newdir)"; tmpdirs+=("$pm_cfg_sc")
cp -r "$pm_cfg1"/. "$pm_cfg_sc"/
chmod 600 "$pm_cfg_sc/deploy-key" "$pm_cfg_sc/pi.env"
printf 'K8S_POSTMASTER_STORAGE_CLASS=fast-ssd\n' >> "$pm_cfg_sc/k8s.env"
pm_log_sc="$(newdir)/kubectl.log"; tmpdirs+=("$(dirname "$pm_log_sc")")
pm_out_sc="$(PATH="$pm_stub_bin:$PATH" K8S_STUB_LOG="$pm_log_sc" FORK_SANDBOX_CONFIG_DIR="$pm_cfg_sc" \
    "$k8s_sh" install --postmaster --dry-run 2>/dev/null)"
check "storageClassName renders the configured class on both PVCs" \
    "2" "$(grep -c '^  storageClassName: fast-ssd' <<< "$pm_out_sc")"

# 3. access mode: default, explicit override, and refusal.
check "access mode defaults to ReadWriteOncePod on both PVCs" \
    "2" "$(grep -c '^    - ReadWriteOncePod$' "$pm_out1")"
pm_cfg_rwo="$(newdir)"; tmpdirs+=("$pm_cfg_rwo")
cp -r "$pm_cfg1"/. "$pm_cfg_rwo"/
chmod 600 "$pm_cfg_rwo/deploy-key" "$pm_cfg_rwo/pi.env"
printf 'K8S_POSTMASTER_ACCESS_MODE=ReadWriteOnce\n' >> "$pm_cfg_rwo/k8s.env"
pm_log_rwo="$(newdir)/kubectl.log"; tmpdirs+=("$(dirname "$pm_log_rwo")")
pm_out_rwo="$(PATH="$pm_stub_bin:$PATH" K8S_STUB_LOG="$pm_log_rwo" FORK_SANDBOX_CONFIG_DIR="$pm_cfg_rwo" \
    "$k8s_sh" install --postmaster --dry-run 2>/dev/null)"
check "access mode ReadWriteOnce renders on both PVCs" "2" "$(grep -c '^    - ReadWriteOnce$' <<< "$pm_out_rwo")"

pm_cfg_badam="$(newdir)"; tmpdirs+=("$pm_cfg_badam")
cp -r "$pm_cfg1"/. "$pm_cfg_badam"/
chmod 600 "$pm_cfg_badam/deploy-key" "$pm_cfg_badam/pi.env"
printf 'K8S_POSTMASTER_ACCESS_MODE=ReadWriteMany\n' >> "$pm_cfg_badam/k8s.env"
pm_log_badam="$(newdir)/kubectl.log"; tmpdirs+=("$(dirname "$pm_log_badam")")
refuses "an invalid K8S_POSTMASTER_ACCESS_MODE refuses" \
    "ReadWriteOncePod or ReadWriteOnce" \
    env PATH="$pm_stub_bin:$PATH" K8S_STUB_LOG="$pm_log_badam" FORK_SANDBOX_CONFIG_DIR="$pm_cfg_badam" \
    "$k8s_sh" install --postmaster --dry-run
if [[ -s "$pm_log_badam" ]]; then
    no "invalid access mode never invokes kubectl" "$(cat "$pm_log_badam")"
else
    ok "invalid access mode never invokes kubectl"
fi

# 4. Each optional block renders (env, volumeMount, volume, its own
# ConfigMap) iff its config dir exists, checked one integration at a
# time, plus a mixed combination (the shape a template-indentation bug
# in an earlier round of this work broke -- see manifests/k8s/
# 40-postmaster.yaml's marker comments) and all four together.
pm_check_integration() {
    local label="$1" dirname_="$2" envvar="$3" cfgdir="$4" out="$5"
    if [[ -d "$cfgdir/$dirname_" ]]; then
        if grep -q "$envvar" <<< "$out"; then ok "$label: present"; else no "$label: present" "$out"; fi
    else
        if grep -q "$envvar" <<< "$out"; then no "$label: absent" "$out"; else ok "$label: absent"; fi
    fi
}

pm_mk_optdir() {
    local base="$1" name="$2" d
    d="$(newdir)"; tmpdirs+=("$d")
    cp -r "$base"/. "$d"/
    chmod 600 "$d/deploy-key" "$d/pi.env"
    mkdir -p "$d/$name"
    echo content > "$d/$name/file1.txt"
    printf '%s' "$d"
}

# personas is not in this loop: the fleet check every install runs requires
# the dir, so the base fixture always carries it (asserted just below).
check "the base fixture's personas dir always renders its env var" \
    "1" "$(grep -c FORK_SANDBOX_PERSONAS_DIR "$pm_out1")"
for pm_name in prompts handlers presets; do
    case "$pm_name" in
        prompts) pm_env=FORK_SANDBOX_PROMPTS_DIR ;;
        handlers) pm_env=FORK_SANDBOX_HANDLERS_DIR ;;
        presets) pm_env=FORK_SANDBOX_PRESETS_DIR ;;
    esac
    pm_cfg_one="$(pm_mk_optdir "$pm_cfg1" "$pm_name")"
    [[ "$pm_name" == handlers ]] && chmod 755 "$pm_cfg_one/handlers/file1.txt"
    pm_log_one="$(newdir)/kubectl.log"; tmpdirs+=("$(dirname "$pm_log_one")")
    pm_out_one="$(PATH="$pm_stub_bin:$PATH" K8S_STUB_LOG="$pm_log_one" FORK_SANDBOX_CONFIG_DIR="$pm_cfg_one" \
        "$k8s_sh" install --postmaster --dry-run 2>/dev/null)"
    check "yamllint: only $pm_name present" "" "$(command -v yamllint >/dev/null 2>&1 && printf '%s\n' "$pm_out_one" | yamllint - 2>&1)"
    if grep -q "$pm_env" <<< "$pm_out_one"; then
        ok "$pm_name alone: its env var renders"
    else
        no "$pm_name alone: its env var renders" "$pm_out_one"
    fi
    for pm_other in prompts handlers presets; do
        [[ "$pm_other" == "$pm_name" ]] && continue
        case "$pm_other" in
            prompts) pm_oenv=FORK_SANDBOX_PROMPTS_DIR ;;
            handlers) pm_oenv=FORK_SANDBOX_HANDLERS_DIR ;;
            presets) pm_oenv=FORK_SANDBOX_PRESETS_DIR ;;
        esac
        if grep -q "$pm_oenv" <<< "$pm_out_one"; then
            no "$pm_name alone: $pm_other stays absent" "$pm_out_one"
        else
            ok "$pm_name alone: $pm_other stays absent"
        fi
    done
done

# The previously-broken mixed case: personas+prompts present,
# handlers+presets absent.
pm_cfg_mixed="$(pm_mk_optdir "$pm_cfg1" personas)"
mkdir -p "$pm_cfg_mixed/prompts"; echo content > "$pm_cfg_mixed/prompts/file1.txt"
pm_log_mixed="$(newdir)/kubectl.log"; tmpdirs+=("$(dirname "$pm_log_mixed")")
pm_out_mixed="$(PATH="$pm_stub_bin:$PATH" K8S_STUB_LOG="$pm_log_mixed" FORK_SANDBOX_CONFIG_DIR="$pm_cfg_mixed" \
    "$k8s_sh" install --postmaster --dry-run 2>/dev/null)"
if command -v yamllint >/dev/null 2>&1; then
    out="$(printf '%s\n' "$pm_out_mixed" | yamllint - 2>&1)"
    if [[ -z "$out" ]]; then
        ok "yamllint: mixed optional blocks (personas+prompts present, handlers+presets absent)"
    else
        no "yamllint: mixed optional blocks (personas+prompts present, handlers+presets absent)" "$out"
    fi
fi
check "mixed: personas present" "1" "$(grep -c FORK_SANDBOX_PERSONAS_DIR <<< "$pm_out_mixed")"
check "mixed: prompts present" "1" "$(grep -c FORK_SANDBOX_PROMPTS_DIR <<< "$pm_out_mixed")"
check "mixed: handlers absent" "0" "$(grep -c FORK_SANDBOX_HANDLERS_DIR <<< "$pm_out_mixed")"
check "mixed: presets absent" "0" "$(grep -c FORK_SANDBOX_PRESETS_DIR <<< "$pm_out_mixed")"

# All four present together.
pm_cfg_all="$(pm_mk_optdir "$pm_cfg1" personas)"
mkdir -p "$pm_cfg_all/prompts" "$pm_cfg_all/handlers" "$pm_cfg_all/presets"
echo content > "$pm_cfg_all/prompts/file1.txt"
install -m 755 /dev/null "$pm_cfg_all/handlers/file1.txt"
printf '#!/bin/sh\n' > "$pm_cfg_all/handlers/file1.txt"
chmod 755 "$pm_cfg_all/handlers/file1.txt"
echo content > "$pm_cfg_all/presets/file1.txt"
pm_log_all="$(newdir)/kubectl.log"; tmpdirs+=("$(dirname "$pm_log_all")")
pm_out_all="$(PATH="$pm_stub_bin:$PATH" K8S_STUB_LOG="$pm_log_all" FORK_SANDBOX_CONFIG_DIR="$pm_cfg_all" \
    "$k8s_sh" install --postmaster --dry-run 2>/dev/null)"
if command -v yamllint >/dev/null 2>&1; then
    out="$(printf '%s\n' "$pm_out_all" | yamllint - 2>&1)"
    if [[ -z "$out" ]]; then ok "yamllint: all four optional blocks present"; else no "yamllint: all four optional blocks present" "$out"; fi
fi
check "all four: no leftover __ placeholder" "0" "$(grep -c '__' <<< "$pm_out_all")"

# 6. A subdirectory inside an optional dir refuses, naming it, before
# any kubectl call.
pm_cfg_subdir="$(pm_mk_optdir "$pm_cfg1" personas)"
mkdir -p "$pm_cfg_subdir/personas/nested"
pm_log_subdir="$(newdir)/kubectl.log"; tmpdirs+=("$(dirname "$pm_log_subdir")")
refuses "a subdirectory inside personas/ refuses, naming it" \
    "personas/nested" \
    env PATH="$pm_stub_bin:$PATH" K8S_STUB_LOG="$pm_log_subdir" FORK_SANDBOX_CONFIG_DIR="$pm_cfg_subdir" \
    "$k8s_sh" install --postmaster --dry-run
if [[ -s "$pm_log_subdir" ]]; then
    no "the subdirectory refusal happens before any kubectl call" "$(cat "$pm_log_subdir")"
else
    ok "the subdirectory refusal happens before any kubectl call"
fi

# 7. A non-executable file under handlers/ is skipped with a warning,
# install still succeeds, and its name never reaches the rendered
# ConfigMap while its executable sibling's does.
pm_cfg_handlers="$(pm_mk_optdir "$pm_cfg1" handlers)"
mv "$pm_cfg_handlers/handlers/file1.txt" "$pm_cfg_handlers/handlers/executable-hook.sh"
chmod 755 "$pm_cfg_handlers/handlers/executable-hook.sh"
echo content > "$pm_cfg_handlers/handlers/not-executable.sh"
chmod 644 "$pm_cfg_handlers/handlers/not-executable.sh"
pm_log_handlers="$(newdir)/kubectl.log"; tmpdirs+=("$(dirname "$pm_log_handlers")")
pm_out_handlers="$(PATH="$pm_stub_bin:$PATH" K8S_STUB_LOG="$pm_log_handlers" FORK_SANDBOX_CONFIG_DIR="$pm_cfg_handlers" \
    "$k8s_sh" install --postmaster --dry-run 2>/tmp/fs-k8s-test-pm-handlers.err)"
pm_handlers_rc=$?
check "a non-executable handler does not fail the install" "0" "$pm_handlers_rc"
if grep -q "is not executable; skipping it from the handlers" /tmp/fs-k8s-test-pm-handlers.err; then
    ok "a non-executable handler is skipped with a warning"
else
    no "a non-executable handler is skipped with a warning" "$(cat /tmp/fs-k8s-test-pm-handlers.err)"
fi
check "the executable handler reaches the rendered ConfigMap" \
    "1" "$(grep -c 'executable-hook.sh' <<< "$pm_out_handlers")"
check "the non-executable handler never reaches the rendered ConfigMap" \
    "0" "$(grep -c 'not-executable.sh' <<< "$pm_out_handlers")"
rm -f /tmp/fs-k8s-test-pm-handlers.err

# 8. The 900 KiB total ConfigMap payload guard.
pm_cfg_big="$(pm_mk_optdir "$pm_cfg1" personas)"
rm -f "$pm_cfg_big/personas/file1.txt"
head -c $(( 901 * 1024 )) /dev/zero > "$pm_cfg_big/personas/big-file.txt"
pm_log_big="$(newdir)/kubectl.log"; tmpdirs+=("$(dirname "$pm_log_big")")
refuses "the 900 KiB ConfigMap payload guard refuses, naming the biggest file" \
    "big-file.txt" \
    env PATH="$pm_stub_bin:$PATH" K8S_STUB_LOG="$pm_log_big" FORK_SANDBOX_CONFIG_DIR="$pm_cfg_big" \
    "$k8s_sh" install --postmaster --dry-run
if [[ -s "$pm_log_big" ]]; then
    no "the oversize guard runs before any kubectl call" "$(cat "$pm_log_big")"
else
    ok "the oversize guard runs before any kubectl call"
fi

# 9. Each missing required key refuses before any kubectl call.
for pm_key in K8S_POSTMASTER_IMAGE K8S_POSTMASTER_REPO_URL \
    K8S_POSTMASTER_GIT_KEY_FILE K8S_POSTMASTER_KNOWN_HOSTS_FILE; do
    pm_cfg_missing="$(pm_cfg_without_key "$pm_cfg1" "$pm_key")"
    pm_log_missing="$(newdir)/kubectl.log"; tmpdirs+=("$(dirname "$pm_log_missing")")
    refuses "missing $pm_key refuses" \
        "$pm_key is not set" \
        env PATH="$pm_stub_bin:$PATH" K8S_STUB_LOG="$pm_log_missing" FORK_SANDBOX_CONFIG_DIR="$pm_cfg_missing" \
        "$k8s_sh" install --postmaster --dry-run
    if [[ -s "$pm_log_missing" ]]; then
        no "missing $pm_key never invokes kubectl" "$(cat "$pm_log_missing")"
    else
        ok "missing $pm_key never invokes kubectl"
    fi
done

# 10. A malformed repo URL and a malformed project name each refuse.
pm_cfg_badurl="$(newdir)"; tmpdirs+=("$pm_cfg_badurl")
cp -r "$pm_cfg1"/. "$pm_cfg_badurl"/
chmod 600 "$pm_cfg_badurl/deploy-key" "$pm_cfg_badurl/pi.env"
sed -i 's|^K8S_POSTMASTER_REPO_URL=.*|K8S_POSTMASTER_REPO_URL=https://git.example/you/proj.git|' "$pm_cfg_badurl/k8s.env"
pm_log_badurl="$(newdir)/kubectl.log"; tmpdirs+=("$(dirname "$pm_log_badurl")")
refuses "a malformed K8S_POSTMASTER_REPO_URL refuses" \
    "recognized ssh URL" \
    env PATH="$pm_stub_bin:$PATH" K8S_STUB_LOG="$pm_log_badurl" FORK_SANDBOX_CONFIG_DIR="$pm_cfg_badurl" \
    "$k8s_sh" install --postmaster --dry-run

pm_cfg_badproj="$(newdir)"; tmpdirs+=("$pm_cfg_badproj")
cp -r "$pm_cfg1"/. "$pm_cfg_badproj"/
chmod 600 "$pm_cfg_badproj/deploy-key" "$pm_cfg_badproj/pi.env"
printf 'K8S_POSTMASTER_PROJECT=../escape\n' >> "$pm_cfg_badproj/k8s.env"
pm_log_badproj="$(newdir)/kubectl.log"; tmpdirs+=("$(dirname "$pm_log_badproj")")
refuses "a malformed K8S_POSTMASTER_PROJECT refuses" \
    "is not a valid" \
    env PATH="$pm_stub_bin:$PATH" K8S_STUB_LOG="$pm_log_badproj" FORK_SANDBOX_CONFIG_DIR="$pm_cfg_badproj" \
    "$k8s_sh" install --postmaster --dry-run

# 10b. A root-level scp-like URL (user@host:proj.git, no "/" at all) with
# no explicit K8S_POSTMASTER_PROJECT must still derive "proj", not the
# unstripped "user@host:proj" -- this mirrors
# fork-sandbox-postmaster-pod-init.sh's own derivation, which the same
# fixture URL exercises there.
pm_cfg_rootscp="$(newdir)"; tmpdirs+=("$pm_cfg_rootscp")
cp -r "$pm_cfg1"/. "$pm_cfg_rootscp"/
chmod 600 "$pm_cfg_rootscp/deploy-key" "$pm_cfg_rootscp/pi.env"
sed -i 's|^K8S_POSTMASTER_REPO_URL=.*|K8S_POSTMASTER_REPO_URL=git@git.example:proj.git|' "$pm_cfg_rootscp/k8s.env"
pm_log_rootscp="$(newdir)/kubectl.log"; tmpdirs+=("$(dirname "$pm_log_rootscp")")
if PATH="$pm_stub_bin:$PATH" K8S_STUB_LOG="$pm_log_rootscp" FORK_SANDBOX_CONFIG_DIR="$pm_cfg_rootscp" \
    "$k8s_sh" install --postmaster --dry-run >/dev/null 2>/tmp/fs-k8s-test-rootscp.err; then
    ok "root-level scp URL with no explicit project derives a valid name"
else
    no "root-level scp URL with no explicit project derives a valid name" \
        "$(cat /tmp/fs-k8s-test-rootscp.err)"
fi
rm -f /tmp/fs-k8s-test-rootscp.err

# 10c. No fleet.yaml on the laptop refuses before any kubectl call: a
# cluster postmaster's `deliver --cluster` refuses to start at all
# without one, so installing anyway would render and apply a Deployment
# whose pod crash-loops forever with no signal at install time.
pm_cfg_nofleet="$(newdir)"; tmpdirs+=("$pm_cfg_nofleet")
cp -r "$pm_cfg1"/. "$pm_cfg_nofleet"/
chmod 600 "$pm_cfg_nofleet/deploy-key" "$pm_cfg_nofleet/pi.env"
rm -f "$pm_cfg_nofleet/fleet.yaml"
pm_log_nofleet="$(newdir)/kubectl.log"; tmpdirs+=("$(dirname "$pm_log_nofleet")")
refuses "no fleet.yaml refuses" \
    "no fleet file" \
    env PATH="$pm_stub_bin:$PATH" K8S_STUB_LOG="$pm_log_nofleet" FORK_SANDBOX_CONFIG_DIR="$pm_cfg_nofleet" \
    "$k8s_sh" install --postmaster --dry-run
if [[ -s "$pm_log_nofleet" ]]; then
    no "missing fleet.yaml never invokes kubectl" "$(cat "$pm_log_nofleet")"
else
    ok "missing fleet.yaml never invokes kubectl"
fi

# 11. The checksum/pm-config annotation changes when fleet.yaml changes.
pm_cfg_fleet="$(newdir)"; tmpdirs+=("$pm_cfg_fleet")
cp -r "$pm_cfg1"/. "$pm_cfg_fleet"/
chmod 600 "$pm_cfg_fleet/deploy-key" "$pm_cfg_fleet/pi.env"
printf 'agents:\n  alpha: {harness: pi, backend: k8s}\n' > "$pm_cfg_fleet/fleet.yaml"
pm_log_fleet1="$(newdir)/kubectl.log"; tmpdirs+=("$(dirname "$pm_log_fleet1")")
pm_sum1="$(PATH="$pm_stub_bin:$PATH" K8S_STUB_LOG="$pm_log_fleet1" FORK_SANDBOX_CONFIG_DIR="$pm_cfg_fleet" \
    "$k8s_sh" install --postmaster --dry-run 2>/dev/null | grep -o 'checksum/pm-config: "[a-f0-9]*"')"
printf 'Standing instructions.\n' > "$pm_cfg_fleet/personas/beta.md"
printf 'agents:\n  alpha: {harness: pi, backend: k8s}\n  beta: {harness: pi, backend: k8s}\n' > "$pm_cfg_fleet/fleet.yaml"
pm_log_fleet2="$(newdir)/kubectl.log"; tmpdirs+=("$(dirname "$pm_log_fleet2")")
pm_sum2="$(PATH="$pm_stub_bin:$PATH" K8S_STUB_LOG="$pm_log_fleet2" FORK_SANDBOX_CONFIG_DIR="$pm_cfg_fleet" \
    "$k8s_sh" install --postmaster --dry-run 2>/dev/null | grep -o 'checksum/pm-config: "[a-f0-9]*"')"
if [[ -n "$pm_sum1" && -n "$pm_sum2" && "$pm_sum1" != "$pm_sum2" ]]; then
    ok "checksum/pm-config changes when fleet.yaml changes"
else
    no "checksum/pm-config changes when fleet.yaml changes" "sum1=$pm_sum1 sum2=$pm_sum2"
fi

# 12. The Secret's key file content never appears in stdout or stderr.
pm_log_secret="$(newdir)/kubectl.log"; tmpdirs+=("$(dirname "$pm_log_secret")")
pm_secret_out="$(PATH="$pm_stub_bin:$PATH" K8S_STUB_LOG="$pm_log_secret" FORK_SANDBOX_CONFIG_DIR="$pm_cfg1" \
    "$k8s_sh" install --postmaster --dry-run 2>/tmp/fs-k8s-test-pm-secret.err)"
if grep -qF 'dummy-key-material-for-tests-only' <<< "$pm_secret_out" || \
   grep -qF 'dummy-key-material-for-tests-only' /tmp/fs-k8s-test-pm-secret.err; then
    no "the deploy key content never appears in dry-run stdout/stderr" "leaked"
else
    ok "the deploy key content never appears in dry-run stdout/stderr"
fi
if grep -qF 'git.example ssh-ed25519 AAAAtest' <<< "$pm_secret_out" || \
   grep -qF 'git.example ssh-ed25519 AAAAtest' /tmp/fs-k8s-test-pm-secret.err; then
    no "the known_hosts content never appears in dry-run stdout/stderr" "leaked"
else
    ok "the known_hosts content never appears in dry-run stdout/stderr"
fi
if grep -qF '# (dry-run) would create Secret fork-sandbox-postmaster-git ... -- not shown.' <<< "$pm_secret_out"; then
    ok "the dry-run prints the Secret placeholder line instead of its content"
else
    no "the dry-run prints the Secret placeholder line instead of its content" "$pm_secret_out"
fi
rm -f /tmp/fs-k8s-test-pm-secret.err

# 13. FORK_SANDBOX_K8S_PLATFORM set to a non-generic plugin warns but does
# not refuse: the postmaster pod always resolves the generic plugin, so a
# mismatched laptop platform is a warning, not an install-time failure.
# The plugin named by FORK_SANDBOX_K8S_PLATFORM still has to resolve for
# plain install to proceed at all, so this uses a copy of the real generic
# plugin under a different name -- it is name-agnostic -- rather than a
# name nothing provides.
pm_platform_dir="$(newdir)"; tmpdirs+=("$pm_platform_dir")
cp "$repo_dir/scripts/fork-sandbox-k8s-platform-generic" \
    "$pm_platform_dir/fork-sandbox-k8s-platform-some-other-plugin"
chmod +x "$pm_platform_dir/fork-sandbox-k8s-platform-some-other-plugin"
pm_log_platform="$(newdir)/kubectl.log"; tmpdirs+=("$(dirname "$pm_log_platform")")
if PATH="$pm_platform_dir:$pm_stub_bin:$PATH" K8S_STUB_LOG="$pm_log_platform" FORK_SANDBOX_CONFIG_DIR="$pm_cfg1" \
    FORK_SANDBOX_K8S_PLATFORM=some-other-plugin \
    "$k8s_sh" install --postmaster --dry-run >/dev/null 2>/tmp/fs-k8s-test-pm-platform.err; then
    ok "install --postmaster still succeeds with a non-generic FORK_SANDBOX_K8S_PLATFORM"
else
    no "install --postmaster still succeeds with a non-generic FORK_SANDBOX_K8S_PLATFORM" \
        "$(cat /tmp/fs-k8s-test-pm-platform.err)"
fi
if grep -qF "FORK_SANDBOX_K8S_PLATFORM='some-other-plugin' is set" /tmp/fs-k8s-test-pm-platform.err; then
    ok "a non-generic FORK_SANDBOX_K8S_PLATFORM warns on stderr"
else
    no "a non-generic FORK_SANDBOX_K8S_PLATFORM warns on stderr" "$(cat /tmp/fs-k8s-test-pm-platform.err)"
fi
rm -f /tmp/fs-k8s-test-pm-platform.err

pm_log_platform_unset="$(newdir)/kubectl.log"; tmpdirs+=("$(dirname "$pm_log_platform_unset")")
PATH="$pm_stub_bin:$PATH" K8S_STUB_LOG="$pm_log_platform_unset" FORK_SANDBOX_CONFIG_DIR="$pm_cfg1" \
    "$k8s_sh" install --postmaster --dry-run >/dev/null 2>/tmp/fs-k8s-test-pm-platform-unset.err
if grep -qF "FORK_SANDBOX_K8S_PLATFORM" /tmp/fs-k8s-test-pm-platform-unset.err; then
    no "no warning when FORK_SANDBOX_K8S_PLATFORM is unset" "$(cat /tmp/fs-k8s-test-pm-platform-unset.err)"
else
    ok "no warning when FORK_SANDBOX_K8S_PLATFORM is unset"
fi
rm -f /tmp/fs-k8s-test-pm-platform-unset.err

pm_log_platform_generic="$(newdir)/kubectl.log"; tmpdirs+=("$(dirname "$pm_log_platform_generic")")
PATH="$pm_stub_bin:$PATH" K8S_STUB_LOG="$pm_log_platform_generic" FORK_SANDBOX_CONFIG_DIR="$pm_cfg1" \
    FORK_SANDBOX_K8S_PLATFORM=generic \
    "$k8s_sh" install --postmaster --dry-run >/dev/null 2>/tmp/fs-k8s-test-pm-platform-generic.err
if grep -qF "FORK_SANDBOX_K8S_PLATFORM" /tmp/fs-k8s-test-pm-platform-generic.err; then
    no "no warning when FORK_SANDBOX_K8S_PLATFORM=generic" "$(cat /tmp/fs-k8s-test-pm-platform-generic.err)"
else
    ok "no warning when FORK_SANDBOX_K8S_PLATFORM=generic"
fi
rm -f /tmp/fs-k8s-test-pm-platform-generic.err

# 14. The mail API: deployed beside the postmaster only when
# K8S_MAIL_API_TOKENS_FILE is set; the operator list; the install-time
# fleet check; both Secrets in the checksum, neither ever printed.
printf '\n== install --postmaster: mail API, operator list, fleet check ==\n'
pm_api_mint="$repo_dir/scripts/fork-sandbox-mail-api.py"
pm_api_marker_tokens='MARKER-TOKENS-FILE-7f3a91'
pm_api_marker_key='MARKER-GIT-KEY-c04d5e'

# pm_api_cfg [extra k8s.env lines...]: the base fixture plus its own copy of
# the key files and a valid tokens file (one operator, one client); prints
# the config dir.
pm_api_cfg() {
    local d line
    d="$(newdir)"; tmpdirs+=("$d")
    cp -r "$pm_cfg1"/. "$d"/
    chmod 600 "$d/deploy-key" "$d/pi.env"
    sed -i "s|^K8S_POSTMASTER_GIT_KEY_FILE=.*|K8S_POSTMASTER_GIT_KEY_FILE=$d/deploy-key|; s|^K8S_POSTMASTER_KNOWN_HOSTS_FILE=.*|K8S_POSTMASTER_KNOWN_HOSTS_FILE=$d/known_hosts|" "$d/k8s.env"
    printf '# %s\n' "$pm_api_marker_key" >> "$d/deploy-key"
    install -m 600 /dev/null "$d/mail-api-tokens"
    {
        printf '# %s\n' "$pm_api_marker_tokens"
        "$pm_api_mint" mint --role operator --label laptop | sed -n 2p
        "$pm_api_mint" mint --role client --label ci-kickoff --as @ci-kickoff --caps read | sed -n 2p
    } >> "$d/mail-api-tokens"
    printf 'K8S_MAIL_API_TOKENS_FILE=%s/mail-api-tokens\n' "$d" >> "$d/k8s.env"
    for line in "$@"; do printf '%s\n' "$line" >> "$d/k8s.env"; done
    printf '%s' "$d"
}

# pm_api_install <cfgdir> [VAR=value ...]: a dry-run install; stdout lands
# in $pm_api_out, stderr in $pm_api_err, the status in $pm_api_rc, and the
# kubectl stub's call log path in $pm_api_log.
pm_api_out="" pm_api_err="" pm_api_rc=0 pm_api_log=""
pm_api_install() {
    local cfg="$1" wd; shift
    wd="$(newdir)"; tmpdirs+=("$wd")
    pm_api_log="$wd/kubectl.log"
    pm_api_out="$(env PATH="$pm_stub_bin:$PATH" K8S_STUB_LOG="$pm_api_log" \
        FORK_SANDBOX_CONFIG_DIR="$cfg" "$@" "$k8s_sh" install --postmaster --dry-run 2>"$wd/err")"
    pm_api_rc=$?
    pm_api_err="$(<"$wd/err")"
}
pm_api_dep() { yq -r "select(.kind == \"Deployment\" and .metadata.name == \"fork-sandbox-postmaster\") | $1" <<< "$pm_api_out"; }
pm_api_sum() { grep -o 'checksum/pm-config: "[a-f0-9]*"' <<< "$pm_api_out"; }

# pm_api_refused <label> <needle> <cfgdir> [VAR=value ...]: install refuses
# with the needle in its output, before a single kubectl call.
pm_api_refused() {
    local label="$1" needle="$2"; shift 2
    pm_api_install "$@"
    if (( pm_api_rc != 0 )) && [[ "$pm_api_err" == *"$needle"* ]]; then
        ok "$label"
    else
        no "$label" "status $pm_api_rc: $pm_api_err"
    fi
    if [[ -s "$pm_api_log" ]]; then
        no "$label: before any kubectl call" "$(cat "$pm_api_log")"
    else
        ok "$label: before any kubectl call"
    fi
}

# 14a. Tokens file unset (the base fixture): no API pieces, no marker
# lines left, the operator env still on the postmaster container, and one
# stderr note pointing at the docs.
pm_api_install "$pm_cfg1"
check "no tokens file: install exits 0" "0" "$pm_api_rc"
check "no tokens file: only the postmaster container" "postmaster" \
    "$(pm_api_dep '.spec.template.spec.containers[].name')"
check "no tokens file: no mail-api Service" "0" "$(grep -c 'fork-sandbox-mail-api' <<< "$pm_api_out")"
check "no tokens file: no mail-api-tokens volume" "0" "$(grep -c 'mail-api-tokens' <<< "$pm_api_out")"
check "no tokens file: no mail-api marker lines left" "0" "$(grep -cE '# (>>>|<<<) mail-api ' <<< "$pm_api_out")"
check "no tokens file: the note names the key" "1" \
    "$(grep -c 'K8S_MAIL_API_TOKENS_FILE is' <<< "$pm_api_err")"
check "no tokens file: exactly one note" "1" "$(grep -c 'mail API is not deployed' <<< "$pm_api_err")"
check "no tokens file: postmaster carries FORK_SANDBOX_OPERATORS=@operator" "@operator" \
    "$(pm_api_dep '.spec.template.spec.containers[] | select(.name == "postmaster") | .env[] | select(.name == "FORK_SANDBOX_OPERATORS") | .value')"
if ! grep -q 'mail API is not deployed' "$pm_out1"; then ok "the note goes to stderr, not stdout"; else no "the note goes to stderr, not stdout"; fi
if command -v yamllint >/dev/null 2>&1; then
    out="$(printf '%s\n' "$pm_api_out" | yamllint - 2>&1)"
    if [[ -z "$out" ]]; then ok "yamllint: no tokens file"; else no "yamllint: no tokens file" "$out"; fi
fi

# 14b. Tokens file set: every piece renders, the API container is
# unprivileged, the SA token is projected into the postmaster only.
pm_cfg_api="$(pm_api_cfg K8S_POSTMASTER_OPERATORS=@alice,@operator)"
pm_api_install "$pm_cfg_api"
check "tokens file: install exits 0" "0" "$pm_api_rc"
check "tokens file: no note on stderr" "0" "$(grep -c 'mail API is not deployed' <<< "$pm_api_err")"
check "tokens file: containers are postmaster, mail-api" "postmaster mail-api" \
    "$(pm_api_dep '.spec.template.spec.containers[].name' | paste -sd' ')"
check "tokens file: Service fork-sandbox-mail-api present" "fork-sandbox-mail-api" \
    "$(yq -r 'select(.kind == "Service" and .metadata.name == "fork-sandbox-mail-api") | .metadata.name' <<< "$pm_api_out")"
check "tokens file: the Service selects the postmaster pod on port 80 -> http" "app=fork-sandbox-postmaster 80 http" \
    "$(yq -r 'select(.kind == "Service" and .metadata.name == "fork-sandbox-mail-api") | "app=\(.spec.selector.app) \(.spec.ports[0].port) \(.spec.ports[0].targetPort)"' <<< "$pm_api_out")"
check "tokens file: the mail-api-tokens volume is present" "fork-sandbox-mail-api-tokens" \
    "$(pm_api_dep '.spec.template.spec.volumes[] | select(.name == "mail-api-tokens") | .secret.secretName')"
check "tokens file: automountServiceAccountToken is false" "false" \
    "$(pm_api_dep '.spec.template.spec.automountServiceAccountToken')"
check "tokens file: the postmaster container mounts sa-token at the SA path" "sa-token" \
    "$(pm_api_dep '.spec.template.spec.containers[] | select(.name == "postmaster") | .volumeMounts[] | select(.mountPath == "/var/run/secrets/kubernetes.io/serviceaccount") | .name')"
check "tokens file: the mail-api container has no mount at the SA path" "0" \
    "$(pm_api_dep '.spec.template.spec.containers[] | select(.name == "mail-api") | .volumeMounts[] | select(.mountPath | startswith("/var/run/secrets"))' | grep -c .)"
check "tokens file: the mail-api container mounts none of git/config/sa-token" "0" \
    "$(pm_api_dep '.spec.template.spec.containers[] | select(.name == "mail-api") | .volumeMounts[] | select(.name == "git" or .name == "config" or .name == "sa-token") | .name' | grep -c .)"
check "tokens file: the mail-api container mounts neither src nor home-claude" "0" \
    "$(pm_api_dep '.spec.template.spec.containers[] | select(.name == "mail-api") | .volumeMounts[] | select(.mountPath == "/home/fs/src" or .mountPath == "/home/fs/.claude") | .mountPath' | grep -c .)"
check "tokens file: the mail-api container shares only the mail volume with the postmaster" "mail" \
    "$(pm_api_dep '.spec.template.spec.containers | ([.[] | select(.name == "mail-api") | .volumeMounts[].name]) as $a | [.[] | select(.name == "postmaster") | .volumeMounts[].name | select(. as $n | $a | index($n))] | unique | join(" ")')"
check "tokens file: the mail-api container mounts the mail volume at the mail root" \
    "/var/tmp/claude-scratch/agent-mail" \
    "$(pm_api_dep '.spec.template.spec.containers[] | select(.name == "mail-api") | .volumeMounts[] | select(.name == "mail") | .mountPath')"
check "tokens file: the mail-api container mounts nothing over the scratch root or forks/" "0" \
    "$(pm_api_dep '.spec.template.spec.containers[] | select(.name == "mail-api") | .volumeMounts[] | select(.mountPath == "/var/tmp/claude-scratch" or (.mountPath | startswith("/var/tmp/claude-scratch/forks")))' | grep -c .)"
check "tokens file: both containers carry the configured operator list" "@alice,@operator @alice,@operator" \
    "$(pm_api_dep '.spec.template.spec.containers[] | .env[] | select(.name == "FORK_SANDBOX_OPERATORS") | .value' | paste -sd' ')"
if command -v yamllint >/dev/null 2>&1; then
    out="$(printf '%s\n' "$pm_api_out" | yamllint - 2>&1)"
    if [[ -z "$out" ]]; then ok "yamllint: tokens file set"; else no "yamllint: tokens file set" "$out"; fi
fi
check "tokens file: the dry-run prints the tokens Secret placeholder" "1" \
    "$(grep -cF '# (dry-run) would create Secret fork-sandbox-mail-api-tokens ... -- not shown.' <<< "$pm_api_out")"
check "no tokens file: no tokens Secret placeholder" "0" \
    "$(grep -cF 'fork-sandbox-mail-api-tokens' "$pm_out1")"
pm_api_apply_order_wd="$(newdir)"; tmpdirs+=("$pm_api_apply_order_wd")
env PATH="$pm_stub_bin:$PATH" K8S_STUB_LOG="$pm_api_apply_order_wd/log" FORK_SANDBOX_CONFIG_DIR="$pm_cfg_api" \
    "$k8s_sh" install --postmaster >/dev/null 2>&1
pm_api_t_line="$(grep -n '^applied:   name: fork-sandbox-mail-api-tokens$' "$pm_api_apply_order_wd/log" | head -1 | cut -d: -f1)"
pm_api_d_line="$(grep -n '^applied:   name: fork-sandbox-postmaster$' "$pm_api_apply_order_wd/log" | tail -1 | cut -d: -f1)"
pm_api_g_line="$(grep -n '^applied:   name: fork-sandbox-postmaster-git$' "$pm_api_apply_order_wd/log" | head -1 | cut -d: -f1)"
if [[ -n "$pm_api_t_line" && -n "$pm_api_d_line" && -n "$pm_api_g_line" ]] \
    && (( pm_api_t_line < pm_api_d_line && pm_api_g_line < pm_api_d_line )); then
    ok "a real install applies the git and tokens Secrets before the Deployment bundle"
else
    no "a real install applies the git and tokens Secrets before the Deployment bundle" \
        "tokens=$pm_api_t_line git=$pm_api_g_line bundle=$pm_api_d_line: $(cat "$pm_api_apply_order_wd/log")"
fi

# 14c. The checksum covers both Secrets, and neither is ever printed.
pm_api_install "$pm_cfg_api"
pm_sum_base="$(pm_api_sum)"
check "neither planted marker appears in stdout" "0" \
    "$(grep -cE "$pm_api_marker_tokens|$pm_api_marker_key" <<< "$pm_api_out")"
check "neither planted marker appears in stderr" "0" \
    "$(grep -cE "$pm_api_marker_tokens|$pm_api_marker_key" <<< "$pm_api_err")"
printf '# rotated\n' >> "$pm_cfg_api/mail-api-tokens"
pm_api_install "$pm_cfg_api"
if [[ -n "$pm_sum_base" && -n "$(pm_api_sum)" && "$(pm_api_sum)" != "$pm_sum_base" ]]; then
    ok "changing only the tokens file changes checksum/pm-config"
else
    no "changing only the tokens file changes checksum/pm-config" "before=$pm_sum_base after=$(pm_api_sum)"
fi
pm_sum_tok="$(pm_api_sum)"
printf '# rotated\n' >> "$pm_cfg_api/deploy-key"
pm_api_install "$pm_cfg_api"
if [[ -n "$(pm_api_sum)" && "$(pm_api_sum)" != "$pm_sum_tok" ]]; then
    ok "changing only the git key file changes checksum/pm-config"
else
    no "changing only the git key file changes checksum/pm-config" "before=$pm_sum_tok after=$(pm_api_sum)"
fi
check "the rotated contents are still never printed" "0" "$(grep -c 'rotated' <<< "$pm_api_out$pm_api_err")"

# 14d. Tokens file refusals: malformed, symlink, missing.
pm_cfg_badtok="$(pm_api_cfg)"
printf 'not a valid entry\n' >> "$pm_cfg_badtok/mail-api-tokens"
pm_api_refused "a malformed tokens file refuses with the loader's line" "fork-sandbox-mail-api.py check" "$pm_cfg_badtok"
check "the loader's own line is passed through" "1" \
    "$(grep -c 'line 4' <<< "$pm_api_err")"
check "a malformed tokens file leaks no hash" "0" "$(grep -cE '[0-9a-f]{64}' <<< "$pm_api_err")"

pm_cfg_lnk="$(pm_api_cfg)"
mv "$pm_cfg_lnk/mail-api-tokens" "$pm_cfg_lnk/real-tokens"
ln -s "$pm_cfg_lnk/real-tokens" "$pm_cfg_lnk/mail-api-tokens"
pm_api_refused "a symlinked tokens file refuses" "is a symlink" "$pm_cfg_lnk"

pm_cfg_missing_tok="$(pm_api_cfg)"
rm -f "$pm_cfg_missing_tok/mail-api-tokens"
pm_api_refused "a missing tokens file refuses" "not found" "$pm_cfg_missing_tok"

# 14e. The operator list: refusals and the client-token cross-check.
pm_cfg_op1="$(pm_api_cfg K8S_POSTMASTER_OPERATORS=@a,,@b)"
pm_api_refused "K8S_POSTMASTER_OPERATORS=@a,,@b refuses, naming the empty element" "K8S_POSTMASTER_OPERATORS element ''" "$pm_cfg_op1"
pm_cfg_op2="$(pm_api_cfg K8S_POSTMASTER_OPERATORS=Bad)"
pm_api_refused "K8S_POSTMASTER_OPERATORS=Bad refuses, naming it" "element 'Bad'" "$pm_cfg_op2"
pm_cfg_op3="$(pm_api_cfg K8S_POSTMASTER_OPERATORS=@a,)"
pm_api_refused "a trailing comma refuses" "K8S_POSTMASTER_OPERATORS element ''" "$pm_cfg_op3"
pm_cfg_op4="$(pm_api_cfg K8S_POSTMASTER_OPERATORS=@operator,@alpha)"
pm_api_refused "an operator name that is a fleet agent refuses" "names '@alpha', which is a fleet" "$pm_cfg_op4"
pm_cfg_op5="$(pm_api_cfg K8S_POSTMASTER_OPERATORS=@ci-kickoff,@operator)"
pm_api_refused "a client token listing an operator-list name refuses (through check)" "ci-kickoff" "$pm_cfg_op5"
check "... and the refusal names the operator name" "1" "$(grep -c '@ci-kickoff' <<< "$pm_api_err")"

# 14f. The fleet check at install: refuses what the pod could not run,
# before anything renders, and looks only at $config_dir's dirs.
pm_cfg_local="$(pm_api_cfg)"
printf 'agents:\n  alpha: {harness: pi, backend: local}\n' > "$pm_cfg_local/fleet.yaml"
pm_api_refused "a backend: local seat refuses install --postmaster" "would crash-loop on this fleet" "$pm_cfg_local"
check "... after the fleet script's own error, naming the seat" "1" "$(grep -c 'agents.alpha' <<< "$pm_api_err")"
pm_cfg_triage="$(pm_api_cfg)"
printf 'triage: {}\nagents:\n  alpha: {harness: pi, backend: k8s}\n' > "$pm_cfg_triage/fleet.yaml"
pm_api_refused "a top-level triage: block refuses install --postmaster" "would crash-loop on this fleet" "$pm_cfg_triage"

pm_cfg_pin="$(pm_api_cfg)"
mkdir -p "$pm_cfg_pin/handlers"
printf '#!/bin/sh\nexit 0\n' > "$pm_cfg_pin/handlers/echo-handler"
chmod 755 "$pm_cfg_pin/handlers/echo-handler"
printf 'agents:\n  alpha: {harness: pi, backend: k8s}\n  notifier: {handler: exec, command: echo-handler}\n' \
    > "$pm_cfg_pin/fleet.yaml"
pm_empty_dir="$(newdir)"; tmpdirs+=("$pm_empty_dir")
pm_api_install "$pm_cfg_pin"
check "a handler seat whose command is in \$config_dir/handlers installs" "0" "$pm_api_rc"
pm_api_install "$pm_cfg_pin" FORK_SANDBOX_HANDLERS_DIR="$pm_empty_dir" FORK_SANDBOX_PRESETS_DIR="$pm_empty_dir"
check "a caller env pointing handlers/presets elsewhere does not change the result" "0" "$pm_api_rc"

# 14f-bis. FORK_SANDBOX_FLEET_FILE / FORK_SANDBOX_PERSONAS_DIR: unlike
# handlers/presets above, these two DO take their fleet file and personas
# dir from the caller's env when set, so a site can keep them in a repo
# of its own instead of $config_dir.
pm_fp_dir="$(newdir)"; tmpdirs+=("$pm_fp_dir")
mkdir -p "$pm_fp_dir/personas"
printf 'agents:\n  gamma: {harness: pi, backend: k8s}\n' > "$pm_fp_dir/fleet.yaml"
printf 'Standing instructions for gamma.\n' > "$pm_fp_dir/personas/gamma.md"
pm_api_install "$pm_cfg1" FORK_SANDBOX_FLEET_FILE="$pm_fp_dir/fleet.yaml" \
    FORK_SANDBOX_PERSONAS_DIR="$pm_fp_dir/personas"
check "env fleet/personas: install exits 0" "0" "$pm_api_rc"
check "env fleet file: the config ConfigMap ships the env file's content" "1" \
    "$(yq -r 'select(.kind == "ConfigMap" and .metadata.name == "fork-sandbox-postmaster-config") | .data."fleet.yaml"' <<< "$pm_api_out" | grep -c gamma)"
check "env personas dir: the personas ConfigMap ships the env dir's file" "1" \
    "$(yq -r 'select(.kind == "ConfigMap" and .metadata.name == "fork-sandbox-postmaster-personas") | .data | keys | .[]' <<< "$pm_api_out" | grep -c '^gamma.md$')"
check "env fleet file: the gate ran against it, not \$config_dir/fleet.yaml (alpha is absent)" "0" \
    "$(yq -r 'select(.kind == "ConfigMap" and .metadata.name == "fork-sandbox-postmaster-config") | .data."fleet.yaml"' <<< "$pm_api_out" | grep -c alpha)"
check "env fleet file: the stderr note names the path" "1" \
    "$(grep -c "shipping fleet file $pm_fp_dir/fleet.yaml" <<< "$pm_api_err")"
check "env personas dir: the stderr note names the path" "1" \
    "$(grep -c "shipping personas dir $pm_fp_dir/personas" <<< "$pm_api_err")"

# unset: falls back to $config_dir, byte-identical to the base fixture's
# earlier dry-run ($pm_out1 is a file path, not the content itself).
pm_api_install "$pm_cfg1"
check "unset FORK_SANDBOX_FLEET_FILE/PERSONAS_DIR: output unchanged from the base fixture" \
    "$(cat "$pm_out1")" "$pm_api_out"

# env names a missing file/dir: refused, naming the variable, before any
# kubectl call.
pm_api_refused "FORK_SANDBOX_FLEET_FILE naming a missing file refuses" \
    "FORK_SANDBOX_FLEET_FILE='/nonexistent/fleet.yaml' is not a" \
    "$pm_cfg1" FORK_SANDBOX_FLEET_FILE=/nonexistent/fleet.yaml
pm_api_refused "FORK_SANDBOX_PERSONAS_DIR naming a missing dir refuses" \
    "FORK_SANDBOX_PERSONAS_DIR='/nonexistent/personas' is not a" \
    "$pm_cfg1" FORK_SANDBOX_PERSONAS_DIR=/nonexistent/personas

# a symlinked personas dir is followed.
pm_fp_real="$(newdir)"; tmpdirs+=("$pm_fp_real")
printf 'Standing instructions for gamma.\n' > "$pm_fp_real/gamma.md"
pm_fp_link_parent="$(newdir)"; tmpdirs+=("$pm_fp_link_parent")
ln -s "$pm_fp_real" "$pm_fp_link_parent/personas"
pm_api_install "$pm_cfg1" FORK_SANDBOX_FLEET_FILE="$pm_fp_dir/fleet.yaml" \
    FORK_SANDBOX_PERSONAS_DIR="$pm_fp_link_parent/personas"
check "a symlinked personas dir is followed: install exits 0" "0" "$pm_api_rc"
check "a symlinked personas dir is followed: its file ships" "1" \
    "$(yq -r 'select(.kind == "ConfigMap" and .metadata.name == "fork-sandbox-postmaster-personas") | .data | keys | .[]' <<< "$pm_api_out" | grep -c '^gamma.md$')"

# 14g. Hooks: the laptop hooks dir ships as ConfigMap
# fork-sandbox-postmaster-hooks, mounted in the postmaster container only,
# exactly as handlers are; an optional site-created Secret
# (K8S_POSTMASTER_HOOKS_SECRET) is only referenced, never created.
# pm_hooks_cfg [extra k8s.env lines...]: the mail-API fixture (so a
# second, mail-api container exists to prove "postmaster only") plus a
# hooks dir holding one executable on-target and one non-executable file.
pm_hooks_cfg() {
    local d
    d="$(pm_api_cfg "$@")"
    mkdir -p "$d/hooks"
    printf '#!/bin/sh\nexit 0\n' > "$d/hooks/on-target"
    chmod 755 "$d/hooks/on-target"
    printf 'notes\n' > "$d/hooks/README-not-exec"
    chmod 644 "$d/hooks/README-not-exec"
    printf '%s' "$d"
}
pm_hooks_env_of() {   # container name -> "NAME=value" lines
    pm_api_dep ".spec.template.spec.containers[] | select(.name == \"$1\") | .env[]? | \"\(.name)=\(.value)\""
}
pm_hooks_mounts_of() {   # container name -> "name path readOnly" lines
    pm_api_dep ".spec.template.spec.containers[] | select(.name == \"$1\") | .volumeMounts[]? | \"\(.name) \(.mountPath) \(.readOnly)\""
}

pm_cfg_hooks="$(pm_hooks_cfg)"
pm_api_install "$pm_cfg_hooks"
check "hooks dir: install exits 0" "0" "$pm_api_rc"
check "hooks dir: the non-executable file is skipped with the warning" "1" \
    "$(grep -c 'README-not-exec is not executable; skipping it from the hooks' <<< "$pm_api_err")"
check "hooks dir: the ConfigMap holds the executable on-target" "on-target" \
    "$(yq -r 'select(.kind == "ConfigMap" and .metadata.name == "fork-sandbox-postmaster-hooks") | .data | keys | .[]' <<< "$pm_api_out")"
check "hooks dir: the skipped file never reaches the render" "0" "$(grep -c 'README-not-exec' <<< "$pm_api_out")"
check "hooks dir: the postmaster container sets FORK_SANDBOX_HOOKS_DIR" \
    "FORK_SANDBOX_HOOKS_DIR=/etc/fork-sandbox/hooks" \
    "$(pm_hooks_env_of postmaster | grep '^FORK_SANDBOX_HOOKS_DIR=')"
check "hooks dir: the postmaster container mounts it read-only" \
    "hooks /etc/fork-sandbox/hooks true" "$(pm_hooks_mounts_of postmaster | grep '^hooks ')"
check "hooks dir: the mail-api container gets no hooks env" "0" \
    "$(pm_hooks_env_of mail-api | grep -c 'HOOKS')"
check "hooks dir: the mail-api container gets no hooks mount" "0" \
    "$(pm_hooks_mounts_of mail-api | grep -c '^hooks ')"
check "hooks dir: the volume is the ConfigMap" "fork-sandbox-postmaster-hooks" \
    "$(pm_api_dep '.spec.template.spec.volumes[] | select(.name == "hooks") | .configMap.name')"
check "hooks dir: the volume mode is 0555, as handlers" "1" \
    "$(grep -A4 -- '- name: hooks$' <<< "$pm_api_out" | grep -c 'defaultMode: 0555')"
check "hooks dir: no leftover placeholders" "0" "$(grep -c '__PM_' <<< "$pm_api_out")"
check "hooks dir alone: no hook-secret pieces" "0" "$(grep -c 'FS_HOOK_SECRET_DIR\|hook-secret' <<< "$pm_api_out")"
if command -v yamllint >/dev/null 2>&1; then
    check "yamllint: hooks dir present" "" "$(printf '%s\n' "$pm_api_out" | yamllint - 2>&1)"
fi
pm_hooks_sum_with="$(pm_api_sum)"
printf '#!/bin/sh\nexit 1\n' > "$pm_cfg_hooks/hooks/on-target"
pm_api_install "$pm_cfg_hooks"
check "hooks content is in the checksum (changing it rolls the pod)" "1" \
    "$([[ -n "$pm_hooks_sum_with" && "$(pm_api_sum)" != "$pm_hooks_sum_with" ]] && echo 1 || echo 0)"

# A hooks dir with a subdirectory refuses, naming it, before kubectl.
pm_cfg_hooks_sub="$(pm_hooks_cfg)"
mkdir -p "$pm_cfg_hooks_sub/hooks/nested"
pm_api_refused "a subdirectory inside hooks/ refuses, naming it" "hooks/nested" "$pm_cfg_hooks_sub"

# Hooks dir absent (the mail-API fixture has none): nothing hooks-shaped.
pm_api_install "$pm_cfg_api"
check "no hooks dir: install exits 0" "0" "$pm_api_rc"
check "no hooks dir: no FORK_SANDBOX_HOOKS_DIR" "0" "$(grep -c 'FORK_SANDBOX_HOOKS_DIR' <<< "$pm_api_out")"
check "no hooks dir: no hooks volume or mount" "0" "$(grep -c -- '- name: hooks$' <<< "$pm_api_out")"
check "no hooks dir: no hooks ConfigMap" "0" "$(grep -c 'fork-sandbox-postmaster-hooks' <<< "$pm_api_out")"
check "no hooks dir: no hooks marker lines left" "0" "$(grep -cE '# (>>>|<<<) hooks' <<< "$pm_api_out")"

# K8S_POSTMASTER_HOOKS_SECRET set: referenced, mounted read-only in the
# postmaster container only, env set; the installer never creates it.
pm_cfg_hs="$(pm_api_cfg K8S_POSTMASTER_HOOKS_SECRET=site-hooks)"
pm_api_install "$pm_cfg_hs"
check "hooks secret: install exits 0" "0" "$pm_api_rc"
check "hooks secret: the postmaster container sets FS_HOOK_SECRET_DIR" \
    "FS_HOOK_SECRET_DIR=/etc/fork-sandbox/hook-secret" \
    "$(pm_hooks_env_of postmaster | grep '^FS_HOOK_SECRET_DIR=')"
check "hooks secret: the postmaster container mounts it read-only" \
    "hook-secret /etc/fork-sandbox/hook-secret true" "$(pm_hooks_mounts_of postmaster | grep '^hook-secret ')"
check "hooks secret: the mail-api container gets neither env nor mount" "0" \
    "$(( $(pm_hooks_env_of mail-api | grep -c 'HOOK_SECRET') + $(pm_hooks_mounts_of mail-api | grep -c '^hook-secret ') ))"
check "hooks secret: the volume names the site's Secret" "site-hooks" \
    "$(pm_api_dep '.spec.template.spec.volumes[] | select(.name == "hook-secret") | .secret.secretName')"
check "hooks secret: without a hooks dir there is still no hooks mount" "0" \
    "$(grep -c 'FORK_SANDBOX_HOOKS_DIR' <<< "$pm_api_out")"
check "hooks secret: the installer does not create the Secret" "0" \
    "$(yq -r 'select(.kind == "Secret") | .metadata.name' <<< "$pm_api_out" | grep -c 'site-hooks')"
check "hooks secret: no leftover placeholders" "0" "$(grep -c '__PM_' <<< "$pm_api_out")"
if command -v yamllint >/dev/null 2>&1; then
    check "yamllint: hooks secret present" "" "$(printf '%s\n' "$pm_api_out" | yamllint - 2>&1)"
fi
# Both together.
pm_cfg_hs2="$(pm_hooks_cfg K8S_POSTMASTER_HOOKS_SECRET=site-hooks.v2)"
pm_api_install "$pm_cfg_hs2"
check "hooks dir + secret: install exits 0" "0" "$pm_api_rc"
check "hooks dir + secret: both mounts on the postmaster container" "hooks hook-secret" \
    "$(pm_hooks_mounts_of postmaster | awk '$1 == "hooks" || $1 == "hook-secret" {print $1}' | paste -sd' ')"
if command -v yamllint >/dev/null 2>&1; then
    check "yamllint: hooks dir + secret" "" "$(printf '%s\n' "$pm_api_out" | yamllint - 2>&1)"
fi

# Unset (the mail-API fixture): all three hook-secret blocks are gone.
pm_api_install "$pm_cfg_api"
check "no hooks secret: no FS_HOOK_SECRET_DIR, no volume, no marker lines" "0" \
    "$(grep -cE 'FS_HOOK_SECRET_DIR|hook-secret|# (>>>|<<<) hook-secret' <<< "$pm_api_out")"

# Refusals, before any kubectl call.
pm_api_refused "a hooks Secret name with uppercase refuses" "K8S_POSTMASTER_HOOKS_SECRET" \
    "$(pm_api_cfg K8S_POSTMASTER_HOOKS_SECRET=Site_Hooks)"
pm_api_refused "a hooks Secret name ending in a dash refuses" "at most 253 characters" \
    "$(pm_api_cfg K8S_POSTMASTER_HOOKS_SECRET=site-hooks-)"
pm_api_refused "a hooks Secret name over 253 characters refuses" "at most 253 characters" \
    "$(pm_api_cfg "K8S_POSTMASTER_HOOKS_SECRET=$(printf 'a%.0s' $(seq 1 254))")"
for pm_own in fork-sandbox-upstream-key fork-sandbox-postmaster-git fork-sandbox-mail-api-tokens; do
    pm_api_refused "the installer's own Secret $pm_own refuses as the hooks Secret" "one of" \
        "$(pm_api_cfg K8S_POSTMASTER_HOOKS_SECRET=$pm_own)"
done

# 14i. Claude credential Secret: optional, from
# K8S_POSTMASTER_CLAUDE_CREDENTIALS_FILE, rendered exactly as the git-key
# Secret is (client-side dry-run, folded into the checksum, its text never
# printed), mounted read-only at /etc/fork-sandbox/claude in the
# postmaster container only, with a claude.env pointing CLAUDE_CREDENTIALS
# at that mount and FORK_SANDBOX_CLUSTER_CLAUDE=1 -- the signal
# `fleet check --cluster` reads to accept claude seats (see the fleet
# suite for that half).
pm_claude_fixture_token='sk-ant-oat01-TESTTOKEN'

# pm_claude_cred_file <dir> <expires_at_ms> [access_token]: writes a 0600
# credentials JSON at $dir/claude-cluster.json and prints its path.
pm_claude_cred_file() {
    local d="$1" exp="$2" tok="${3:-$pm_claude_fixture_token}" f
    f="$d/claude-cluster.json"
    jq -n --arg t "$tok" --argjson e "$exp" \
        '{claudeAiOauth: {accessToken: $t, expiresAt: $e}}' > "$f"
    chmod 600 "$f"
    printf '%s' "$f"
}
pm_claude_future_ms=$(( ($(date +%s) + 30 * 86400) * 1000 ))
pm_claude_soon_ms=$(( ($(date +%s) + 3600) * 1000 ))

pm_cfg_claude="$(pm_api_cfg)"
pm_claude_file="$(pm_claude_cred_file "$pm_cfg_claude" "$pm_claude_future_ms")"
printf 'K8S_POSTMASTER_CLAUDE_CREDENTIALS_FILE=%s\n' "$pm_claude_file" >> "$pm_cfg_claude/k8s.env"
pm_api_install "$pm_cfg_claude"
check "claude credentials: install exits 0" "0" "$pm_api_rc"
# The Secret's own YAML is never printed by a dry-run, same as the git-key
# and mail-api-tokens Secrets -- only this placeholder comment proves the
# conditional branch ran; the --from-file=credentials.json=... key name is
# asserted directly against cmd_install's source below instead.
check "claude credentials: the dry-run placeholder names the Secret" "1" \
    "$(grep -c 'would create Secret fork-sandbox-postmaster-claude' <<< "$pm_api_out")"
check "claude credentials: cmd_install renders the Secret with key credentials.json" "1" \
    "$(grep -c 'from-file="credentials.json=\$K8S_POSTMASTER_CLAUDE_CREDENTIALS_FILE"' "$k8s_sh")"
check "claude credentials: the postmaster container mounts it read-only" \
    "claude-credentials /etc/fork-sandbox/claude true" \
    "$(pm_hooks_mounts_of postmaster | grep '^claude-credentials ')"
check "claude credentials: the mail-api container gets no mount" "0" \
    "$(pm_hooks_mounts_of mail-api | grep -c '^claude-credentials ')"
check "claude credentials: the postmaster container sets FORK_SANDBOX_CLUSTER_CLAUDE=1" \
    "FORK_SANDBOX_CLUSTER_CLAUDE=1" \
    "$(pm_hooks_env_of postmaster | grep '^FORK_SANDBOX_CLUSTER_CLAUDE=')"
check "claude credentials: the mail-api container gets no such env" "0" \
    "$(pm_hooks_env_of mail-api | grep -c 'CLUSTER_CLAUDE')"
check "claude credentials: the config ConfigMap carries claude.env" \
    "CLAUDE_CREDENTIALS=/etc/fork-sandbox/claude/credentials.json" \
    "$(yq -r 'select(.kind == "ConfigMap" and .metadata.name == "fork-sandbox-postmaster-config") | .data["claude.env"]' <<< "$pm_api_out")"
check "claude credentials: no leftover placeholders" "0" "$(grep -c '__PM_' <<< "$pm_api_out")"
check "claude credentials: the token text never reaches stdout" "0" \
    "$(grep -c "$pm_claude_fixture_token" <<< "$pm_api_out")"
check "claude credentials: the token text never reaches stderr" "0" \
    "$(grep -c "$pm_claude_fixture_token" <<< "$pm_api_err")"
if command -v yamllint >/dev/null 2>&1; then
    check "yamllint: claude credentials present" "" "$(printf '%s\n' "$pm_api_out" | yamllint - 2>&1)"
fi

pm_claude_sum_with="$(pm_api_sum)"
pm_claude_file2="$(pm_claude_cred_file "$pm_cfg_claude" "$pm_claude_future_ms" 'sk-ant-oat01-TESTTOKEN-ROTATED')"
sed -i "s|^K8S_POSTMASTER_CLAUDE_CREDENTIALS_FILE=.*|K8S_POSTMASTER_CLAUDE_CREDENTIALS_FILE=$pm_claude_file2|" "$pm_cfg_claude/k8s.env"
pm_api_install "$pm_cfg_claude"
check "claude credentials: rotating the token changes the checksum" "1" \
    "$([[ -n "$pm_claude_sum_with" && "$(pm_api_sum)" != "$pm_claude_sum_with" ]] && echo 1 || echo 0)"

# Unset (the mail-API fixture, same base as pm_cfg1): no Secret, no
# marker lines, no claude.env, output byte-identical to the very first
# base-fixture dry-run -- the legacy fixture must not change.
pm_api_install "$pm_cfg1"
check "no claude credentials: output identical to the base fixture" "1" \
    "$([[ "$pm_api_out" == "$(cat "$pm_out1")" ]] && echo 1 || echo 0)"
check "no claude credentials: no Secret" "0" \
    "$(yq -r 'select(.kind == "Secret") | .metadata.name' <<< "$pm_api_out" | grep -c 'fork-sandbox-postmaster-claude')"
check "no claude credentials: no marker lines left" "0" \
    "$(grep -cE '# (>>>|<<<) claude-credentials' <<< "$pm_api_out")"
check "no claude credentials: no claude.env key" "0" "$(grep -c 'claude.env' <<< "$pm_api_out")"

# Refusals, before any kubectl call, none printing the token.
pm_cfg_claude_missing="$(pm_api_cfg)"
printf 'K8S_POSTMASTER_CLAUDE_CREDENTIALS_FILE=%s/nonexistent.json\n' "$pm_cfg_claude_missing" >> "$pm_cfg_claude_missing/k8s.env"
pm_api_refused "a missing claude credentials file refuses" "not found" "$pm_cfg_claude_missing"
check "a missing claude credentials file refuses: no token leak" "0" \
    "$(grep -c "$pm_claude_fixture_token" <<< "$pm_api_err$pm_api_out")"

pm_cfg_claude_badjson="$(pm_api_cfg)"
pm_claude_badjson_file="$pm_cfg_claude_badjson/claude-cluster.json"
printf 'not json\n' > "$pm_claude_badjson_file"
chmod 600 "$pm_claude_badjson_file"
printf 'K8S_POSTMASTER_CLAUDE_CREDENTIALS_FILE=%s\n' "$pm_claude_badjson_file" >> "$pm_cfg_claude_badjson/k8s.env"
pm_api_refused "malformed JSON refuses" "accessToken" "$pm_cfg_claude_badjson"
check "malformed JSON refuses: no token leak" "0" \
    "$(grep -c "$pm_claude_fixture_token" <<< "$pm_api_err$pm_api_out")"

pm_cfg_claude_noaccess="$(pm_api_cfg)"
pm_claude_noaccess_file="$pm_cfg_claude_noaccess/claude-cluster.json"
jq -n --argjson e "$pm_claude_future_ms" '{claudeAiOauth: {expiresAt: $e}}' > "$pm_claude_noaccess_file"
chmod 600 "$pm_claude_noaccess_file"
printf 'K8S_POSTMASTER_CLAUDE_CREDENTIALS_FILE=%s\n' "$pm_claude_noaccess_file" >> "$pm_cfg_claude_noaccess/k8s.env"
pm_api_refused "no accessToken refuses" "no non-empty" "$pm_cfg_claude_noaccess"
check "no accessToken refuses: no token leak" "0" \
    "$(grep -c "$pm_claude_fixture_token" <<< "$pm_api_err$pm_api_out")"

pm_cfg_claude_noexp="$(pm_api_cfg)"
pm_claude_noexp_file="$pm_cfg_claude_noexp/claude-cluster.json"
jq -n --arg t "$pm_claude_fixture_token" '{claudeAiOauth: {accessToken: $t}}' > "$pm_claude_noexp_file"
chmod 600 "$pm_claude_noexp_file"
printf 'K8S_POSTMASTER_CLAUDE_CREDENTIALS_FILE=%s\n' "$pm_claude_noexp_file" >> "$pm_cfg_claude_noexp/k8s.env"
pm_api_refused "no expiresAt refuses" "no numeric" "$pm_cfg_claude_noexp"
check "no expiresAt refuses: no token leak" "0" \
    "$(grep -c "$pm_claude_fixture_token" <<< "$pm_api_err$pm_api_out")"

pm_cfg_claude_strexp="$(pm_api_cfg)"
pm_claude_strexp_file="$pm_cfg_claude_strexp/claude-cluster.json"
jq -n --arg t "$pm_claude_fixture_token" '{claudeAiOauth: {accessToken: $t, expiresAt: "soon"}}' > "$pm_claude_strexp_file"
chmod 600 "$pm_claude_strexp_file"
printf 'K8S_POSTMASTER_CLAUDE_CREDENTIALS_FILE=%s\n' "$pm_claude_strexp_file" >> "$pm_cfg_claude_strexp/k8s.env"
pm_api_refused "a string expiresAt refuses" "no numeric" "$pm_cfg_claude_strexp"
check "a string expiresAt refuses: no token leak" "0" \
    "$(grep -c "$pm_claude_fixture_token" <<< "$pm_api_err$pm_api_out")"

pm_cfg_claude_soon="$(pm_api_cfg)"
pm_claude_soon_file="$(pm_claude_cred_file "$pm_cfg_claude_soon" "$pm_claude_soon_ms")"
printf 'K8S_POSTMASTER_CLAUDE_CREDENTIALS_FILE=%s\n' "$pm_claude_soon_file" >> "$pm_cfg_claude_soon/k8s.env"
pm_api_refused "an access token expiring within 7 days refuses" "expires too soon" "$pm_cfg_claude_soon"
check "an access token expiring within 7 days refuses: no token leak" "0" \
    "$(grep -c "$pm_claude_fixture_token" <<< "$pm_api_err$pm_api_out")"

# The key also feeds the install-time gate (`fleet check --cluster`): a
# claude-harness seat passes when the key is set, and is refused (the
# same way `fleet check --cluster` refuses it standalone -- see the fleet
# suite) when it is not. Uses FORK_SANDBOX_FLEET_FILE/PERSONAS_DIR to swap
# in a small claude-seat fleet instead of a whole new pm_*_cfg variant.
pm_claude_gate_dir="$(newdir)"; tmpdirs+=("$pm_claude_gate_dir")
mkdir -p "$pm_claude_gate_dir/personas"
printf 'agents:\n  delta: {harness: claude, backend: k8s}\n' > "$pm_claude_gate_dir/fleet.yaml"
printf 'Standing instructions for delta.\n' > "$pm_claude_gate_dir/personas/delta.md"

pm_cfg_claude_gate="$(pm_api_cfg)"
pm_claude_gate_file="$(pm_claude_cred_file "$pm_cfg_claude_gate" "$pm_claude_future_ms")"
printf 'K8S_POSTMASTER_CLAUDE_CREDENTIALS_FILE=%s\n' "$pm_claude_gate_file" >> "$pm_cfg_claude_gate/k8s.env"
pm_api_install "$pm_cfg_claude_gate" \
    FORK_SANDBOX_FLEET_FILE="$pm_claude_gate_dir/fleet.yaml" \
    FORK_SANDBOX_PERSONAS_DIR="$pm_claude_gate_dir/personas"
check "claude-seat gate: with the credential key set, a claude-seat fleet passes" "0" "$pm_api_rc"

pm_api_refused "claude-seat gate: without the credential key, the same fleet is refused" \
    "agents.delta.harness" "$pm_cfg1" \
    FORK_SANDBOX_FLEET_FILE="$pm_claude_gate_dir/fleet.yaml" \
    FORK_SANDBOX_PERSONAS_DIR="$pm_claude_gate_dir/personas"

# A real (non-dry-run) install with the key set: the apply path returns
# from cmd_install, so the claude.env temp file's EXIT trap fires after
# cmd_install's locals are gone. It must still exit 0 and remove the file.
pm_claude_real_wd="$(newdir)"; tmpdirs+=("$pm_claude_real_wd")
mkdir -p "$pm_claude_real_wd/tmp"
env PATH="$pm_stub_bin:$PATH" K8S_STUB_LOG="$pm_claude_real_wd/kubectl.log" \
    K8S_STUB_APPLY_CAPTURE="$pm_claude_real_wd/applied.yaml" \
    TMPDIR="$pm_claude_real_wd/tmp" FORK_SANDBOX_CONFIG_DIR="$pm_cfg_claude" \
    "$k8s_sh" install --postmaster >/dev/null 2>"$pm_claude_real_wd/err"
check "claude credentials: a real install exits 0" "0" "$?"
check "real install: the applied stream carries both PersistentVolumeClaims" \
    "fork-sandbox-postmaster fork-sandbox-postmaster-mail" \
    "$(yq -r 'select(.kind == "PersistentVolumeClaim") | .metadata.name' "$pm_claude_real_wd/applied.yaml" | sort | paste -sd' ')"
check "real install: the applied stream carries the postmaster Deployment" "fork-sandbox-postmaster" \
    "$(yq -r 'select(.kind == "Deployment" and .metadata.name == "fork-sandbox-postmaster") | .metadata.name' "$pm_claude_real_wd/applied.yaml")"
check "real install: the applied Deployment has no subPath anywhere" "0" \
    "$(yq -r 'select(.kind == "Deployment" and .metadata.name == "fork-sandbox-postmaster") | [.spec.template.spec.containers[], (.spec.template.spec.initContainers // [])[]] | [.[].volumeMounts[]? | select(has("subPath"))] | length' "$pm_claude_real_wd/applied.yaml")"
check "claude credentials: a real install hits no unbound variable" "0" \
    "$(grep -c 'unbound variable' "$pm_claude_real_wd/err")"
check "claude credentials: a real install leaves no claude.env temp file" "" \
    "$(grep -rl 'CLAUDE_CREDENTIALS=' "$pm_claude_real_wd/tmp" 2>/dev/null)"

# 14e. Storage layout: two whole PVCs, no subPath anywhere.
pm_ctrs='[.spec.template.spec.containers[], (.spec.template.spec.initContainers // [])[]]'
pm_mounts_of() {   # container name -> "volume path" lines
    pm_api_dep ".spec.template.spec.containers[] | select(.name == \"$1\") | .volumeMounts[] | .name + \" \" + .mountPath"
}
pm_pvc() { yq -r "select(.kind == \"PersistentVolumeClaim\" and .metadata.name == \"$1\") | $2" <<< "$pm_api_out"; }

pm_api_install "$pm_cfg_api"
check "storage: mail API enabled: no subPath in any container" "0" \
    "$(pm_api_dep "$pm_ctrs | [.[].volumeMounts[]? | select(has(\"subPath\"))] | length")"
check "storage: no pvc-dirs init container" "0" \
    "$(pm_api_dep '[(.spec.template.spec.initContainers // [])[] | select(.name == "pvc-dirs")] | length')"
check "storage: postmaster mounts data at the scratch root" "1" \
    "$(pm_mounts_of postmaster | grep -cx 'data /var/tmp/claude-scratch')"
check "storage: postmaster mounts mail at the mail root" "1" \
    "$(pm_mounts_of postmaster | grep -cx 'mail /var/tmp/claude-scratch/agent-mail')"
check "storage: postmaster mounts nothing at \$HOME/src or \$HOME/.claude" "0" \
    "$(pm_mounts_of postmaster | grep -cE ' /home/fs/(src|\.claude)$')"
check "storage: mail-api mounts mail at the mail root" "1" \
    "$(pm_mounts_of mail-api | grep -cx 'mail /var/tmp/claude-scratch/agent-mail')"
check "storage: mail-api has no mount of the data volume" "0" \
    "$(pm_mounts_of mail-api | grep -c '^data ')"
check "storage: the mail volume claims fork-sandbox-postmaster-mail" "fork-sandbox-postmaster-mail" \
    "$(pm_api_dep '.spec.template.spec.volumes[] | select(.name == "mail") | .persistentVolumeClaim.claimName')"
check "storage: the data volume claims fork-sandbox-postmaster" "fork-sandbox-postmaster" \
    "$(pm_api_dep '.spec.template.spec.volumes[] | select(.name == "data") | .persistentVolumeClaim.claimName')"

pm_api_install "$pm_cfg1"
check "storage: mail API disabled: no subPath in any container" "0" \
    "$(pm_api_dep "$pm_ctrs | [.[].volumeMounts[]? | select(has(\"subPath\"))] | length")"
check "storage: mail API disabled: postmaster still mounts mail at the mail root" "1" \
    "$(pm_mounts_of postmaster | grep -cx 'mail /var/tmp/claude-scratch/agent-mail')"
check "storage: mail API disabled: the mail volume is still declared" "fork-sandbox-postmaster-mail" \
    "$(pm_api_dep '.spec.template.spec.volumes[] | select(.name == "mail") | .persistentVolumeClaim.claimName')"
check "storage: both PVCs render" "fork-sandbox-postmaster fork-sandbox-postmaster-mail" \
    "$(yq -r 'select(.kind == "PersistentVolumeClaim") | .metadata.name' <<< "$pm_api_out" | sort | paste -sd' ')"
check "storage: the mail PVC defaults to 2Gi" "2Gi" \
    "$(pm_pvc fork-sandbox-postmaster-mail '.spec.resources.requests.storage')"
check "storage: the data PVC keeps its 20Gi default" "20Gi" \
    "$(pm_pvc fork-sandbox-postmaster '.spec.resources.requests.storage')"
check "storage: no storageClassName on either PVC by default" "0" \
    "$(yq -r 'select(.kind == "PersistentVolumeClaim") | .spec | has("storageClassName")' <<< "$pm_api_out" | grep -c true)"

pm_cfg_mailsz="$(pm_api_cfg K8S_POSTMASTER_MAIL_STORAGE=5Gi K8S_POSTMASTER_STORAGE_CLASS=invented-class K8S_POSTMASTER_ACCESS_MODE=ReadWriteOnce)"
pm_api_install "$pm_cfg_mailsz"
check "storage: K8S_POSTMASTER_MAIL_STORAGE sizes the mail PVC" "5Gi" \
    "$(pm_pvc fork-sandbox-postmaster-mail '.spec.resources.requests.storage')"
check "storage: K8S_POSTMASTER_MAIL_STORAGE leaves the data PVC alone" "20Gi" \
    "$(pm_pvc fork-sandbox-postmaster '.spec.resources.requests.storage')"
check "storage: the storage class lands on both PVCs" "invented-class invented-class" \
    "$(yq -r 'select(.kind == "PersistentVolumeClaim") | .spec.storageClassName' <<< "$pm_api_out" | paste -sd' ')"
check "storage: the access mode lands on both PVCs" "ReadWriteOnce ReadWriteOnce" \
    "$(yq -r 'select(.kind == "PersistentVolumeClaim") | .spec.accessModes[0]' <<< "$pm_api_out" | paste -sd' ')"
check "storage: no leftover __PM_ placeholder" "0" "$(grep -c '__PM_' <<< "$pm_api_out")"

pm_cfg_badmail="$(pm_api_cfg K8S_POSTMASTER_MAIL_STORAGE=5GB)"
pm_api_refused "storage: K8S_POSTMASTER_MAIL_STORAGE=5GB is refused" \
    "K8S_POSTMASTER_MAIL_STORAGE='5GB' must match" "$pm_cfg_badmail"
pm_badmail_wd="$(newdir)"; tmpdirs+=("$pm_badmail_wd")
env PATH="$pm_stub_bin:$PATH" K8S_STUB_LOG="$pm_badmail_wd/log" FORK_SANDBOX_CONFIG_DIR="$pm_cfg_badmail" \
    "$k8s_sh" install --postmaster >/dev/null 2>&1
check "storage: a refused real install exits 1" "1" "$?"
check "storage: a refused real install applies nothing" "0" "$(cat "$pm_badmail_wd/log" 2>/dev/null | grep -c 'apply')"

printf '\n== client Role vs postmaster Role: same rules ==\n'
rbac_yaml="$repo_dir/manifests/k8s/10-rbac.yaml"
pm_yaml="$repo_dir/manifests/k8s/40-postmaster.yaml"
if command -v yq >/dev/null 2>&1; then
    rbac_rules="$(yq -r '
        select(.kind == "Role" and .metadata.name == "fork-sandbox-client") | .rules[]
        | .apiGroups[] as $g | .resources[] as $r | .verbs[] as $v
        | "\($g)/\($r)/\($v)"
    ' "$rbac_yaml" | sort)"
    pm_rules="$(yq -r '
        select(.kind == "Role" and .metadata.name == "fork-sandbox-postmaster") | .rules[]
        | .apiGroups[] as $g | .resources[] as $r | .verbs[] as $v
        | "\($g)/\($r)/\($v)"
    ' "$pm_yaml" | sort)"
else
    rbac_rules="$(python3 -c '
import sys
import yaml

with open(sys.argv[1]) as f:
    docs = list(yaml.safe_load_all(f))
rules = []
for d in docs:
    if d and d.get("kind") == "Role" and d.get("metadata", {}).get("name") == sys.argv[2]:
        for rule in d.get("rules", []):
            for g in rule.get("apiGroups", []):
                for r in rule.get("resources", []):
                    for v in rule.get("verbs", []):
                        rules.append("{}/{}/{}".format(g, r, v))
for line in sorted(rules):
    print(line)
' "$rbac_yaml" "fork-sandbox-client")"
    pm_rules="$(python3 -c '
import sys
import yaml

with open(sys.argv[1]) as f:
    docs = list(yaml.safe_load_all(f))
rules = []
for d in docs:
    if d and d.get("kind") == "Role" and d.get("metadata", {}).get("name") == sys.argv[2]:
        for rule in d.get("rules", []):
            for g in rule.get("apiGroups", []):
                for r in rule.get("resources", []):
                    for v in rule.get("verbs", []):
                        rules.append("{}/{}/{}".format(g, r, v))
for line in sorted(rules):
    print(line)
' "$pm_yaml" "fork-sandbox-postmaster")"
fi
if [[ -z "$rbac_rules" || -z "$pm_rules" ]]; then
    no "client and postmaster Roles both parsed" "rbac_rules='$rbac_rules' pm_rules='$pm_rules'"
elif [[ "$rbac_rules" == "$pm_rules" ]]; then
    ok "client Role and postmaster Role grant the same resource+verb rules"
else
    no "client Role and postmaster Role grant the same resource+verb rules" \
        "$(diff <(echo "$rbac_rules") <(echo "$pm_rules"))"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
