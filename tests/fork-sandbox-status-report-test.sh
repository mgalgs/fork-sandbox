#!/usr/bin/env bash
set -uo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
status="$repo_dir/scripts/fork-sandbox-status.sh"
rd="$(mktemp -d /var/tmp/claude-scratch/forks/claude-fork-sandbox.status.XXXXXX)"
trap 'rm -rf -- "$rd"' EXIT
cat > "$rd/run.env" <<EOF
version=1
branch=test
origin_repo=/tmp/origin
clone_dir=/tmp/clone
started_at=$(date +%s)
EOF
cat > "$rd/review-loop.json" <<'EOF'
{"ended":"approved"}
EOF
cat > "$rd/events.jsonl" <<'EOF'
{"type":"result","subtype":"success","result":"session account"}
EOF
printf 'APPROVED\nChecked: tests.\n\n## Report\nleg 1\n' > "$rd/review-verdict-1.md"
printf 'FINDINGS\n\nfile:1 finding\n\n## Report\nleg 2\n' > "$rd/review-verdict-2.md"

out="$($status --result "$rd")"
[[ "$out" == *"== report: review leg 2 (FINDINGS) =="* ]] || { echo "no leg 2 report"; exit 1; }
[[ "$out" == *$'leg 2\n\n== the session'* ]] || { echo "report did not precede session account"; exit 1; }
[[ "$out" != *"file:1 finding"* && "$out" != *"Checked:"* ]] || { echo "verdict body leaked into report"; exit 1; }
printf 'done\n' > "$rd/summary.txt"
printf '0\n' > "$rd/exit-code"
out="$($status "$rd")"
[[ "$out" == *"== report: review leg 2 (FINDINGS) =="* ]] || { echo "default status omitted review report"; exit 1; }
[[ "$out" == *$'leg 2\n\n== the session'* ]] || { echo "default status report did not precede session account"; exit 1; }
[[ "$out" != *"file:1 finding"* && "$out" != *"Checked:"* ]] || { echo "default status leaked verdict body"; exit 1; }
printf 'APPROVED\nChecked: no report heading.\n' > "$rd/review-verdict-3.md"
out="$($status --result "$rd")"
[[ "$out" == *"== report: review leg 3 (APPROVED) — verdict, no usable report section =="* ]] || { echo "no report banner missing"; exit 1; }
[[ "$out" == *$'APPROVED\nChecked: no report heading.\n\n== the session'* ]] || { echo "whole verdict was not printed"; exit 1; }
printf 'APPROVED\nChecked: useful evidence.\n\n## Report\n' > "$rd/review-verdict-5.md"
out="$($status --result "$rd")"
[[ "$out" == *"== report: review leg 5 (APPROVED) — verdict, no usable report section =="* ]] || { echo "malformed report fallback banner missing"; exit 1; }
[[ "$out" == *$'APPROVED\nChecked: useful evidence.\n\n## Report\n\n== the session'* ]] || { echo "malformed report did not fall back to whole verdict"; exit 1; }
printf 'APPROVED\nChecked: useful evidence.\n\n## Report\nfirst\n\n## Report\nsecond\n' > "$rd/review-verdict-6.md"
out="$($status --result "$rd")"
[[ "$out" == *"== report: review leg 6 (APPROVED) — verdict, no usable report section =="* ]] || { echo "duplicate report fallback banner missing"; exit 1; }
[[ "$out" == *$'first\n\n## Report\nsecond\n\n== the session'* ]] || { echo "duplicate report did not fall back to whole verdict"; exit 1; }
json="$($status --json "$rd" 2>/dev/null || true)"
[[ -z "$json" ]] || { echo "unexpected json without summary"; exit 1; }
ln -s /etc/passwd "$rd/review-verdict-4.md"
if "$status" --result "$rd" >/dev/null 2>&1; then
    echo "symlinked verdict was accepted"; exit 1
fi
echo "1 passed, 0 failed"
