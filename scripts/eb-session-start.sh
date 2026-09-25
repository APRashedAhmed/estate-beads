#!/usr/bin/env bash
# eb-session-start.sh — SessionStart hook (design §11.2/§12.5, plan U3 decision 4).
#
# 1. Actor export (P3/P6 PASS, U1): writes `export BEADS_ACTOR=<session_id>` into
#    $CLAUDE_ENV_FILE so every subsequent Bash call in THIS session records/claims under the
#    session id. Independent of whether a Beads database is present.
# 2. `bd prime --hook-json` + an ADVISORY crash-claim sweep, only when $BEADS_DIR resolves to an
#    existing directory — silent (no stdout) otherwise. The sweep never releases anything; it
#    lists Beads claimed by a session whose transcript is MISSING, or present but older than
#    ${EB_SESSION_START_SWEEP_STALE_HOURS:-6}h (M3, fix round 1 review pa-s2s.8-review-1 — a
#    transcript persists long after its session ends, so presence alone is not a liveness
#    signal), under ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/, naming scripts/bead-release.sh
#    as the mechanism an operator/orchestrator runs.
#
# Both `bd prime --hook-json` and this hook's own output are the SAME SessionStart JSON envelope
# (`{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext": "..."}}`) — the
# sweep's advisory lines are appended to prime's `additionalContext`, never printed as a second,
# separate stdout payload (two JSON objects on stdout would break the hook parser).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

INPUT="$(cat)"

SESSION_ID="$(printf '%s' "$INPUT" | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("session_id") or "")
except Exception:
    print("")
' 2>/dev/null)"

# --- 1. actor export --------------------------------------------------------------------------
if [ -n "${CLAUDE_ENV_FILE:-}" ] && [ -n "$SESSION_ID" ]; then
  printf 'export BEADS_ACTOR=%q\n' "$SESSION_ID" >> "$CLAUDE_ENV_FILE"
fi

# --- 2. prime + advisory sweep, only if BEADS_DIR resolves -------------------------------------
if [ -z "${BEADS_DIR:-}" ] || [ ! -d "$BEADS_DIR" ]; then
  exit 0
fi

PRIME_JSON="$(bd prime --hook-json 2>/dev/null)"
[ -n "$PRIME_JSON" ] || exit 0

# bd list --json (single call, not one per Bead — portability-contract.md §5.5-adjacent
# discipline applies to any per-claim loop, and there is exactly one candidate set here).
LIST_JSON="$(bd list --status in_progress --json 2>/dev/null)"

RELEASE_SCRIPT="$HERE/bead-release.sh"

# M3 (review pa-s2s.8-review-1): the sweep must honour ${CLAUDE_CONFIG_DIR:-$HOME/.claude} for
# the transcript root, not a hardcoded $HOME/.claude — under this estate's per-account config
# directories, the hardcoded path would flag every live session of another account as crashed.
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
# Liveness threshold: a transcript MISSING or older than this many hours reads as crashed
# (design §11.2 "catches crashes"). A present-but-days-old transcript is exactly the case the
# prior "missing only" check could not detect (transcripts persist ~30 days after a session
# ends, so presence alone is not a liveness signal).
STALE_HOURS="${EB_SESSION_START_SWEEP_STALE_HOURS:-6}"

python3 - "$PRIME_JSON" "$RELEASE_SCRIPT" "$SESSION_ID" "$CONFIG_DIR" "$LIST_JSON" "$STALE_HOURS" <<'PYEOF'
import json
import re
import sys
import time
from pathlib import Path

prime_raw, release_script, own_session_id, config_dir, list_raw, stale_hours_raw = sys.argv[1:7]
stale_seconds = float(stale_hours_raw) * 3600.0
now = time.time()

try:
    prime = json.loads(prime_raw)
except Exception:
    # bd prime's own output failed to parse — pass it through unchanged rather than risk
    # corrupting a SessionStart envelope we cannot understand.
    sys.stdout.write(prime_raw)
    raise SystemExit(0)

try:
    issues = json.loads(list_raw) if list_raw.strip() else []
except Exception:
    issues = []
if isinstance(issues, dict):
    issues = issues.get("issues") or []

SESSION_ID_RE = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
)

advisories = []
for issue in issues:
    assignee = (issue or {}).get("assignee") or ""
    m = SESSION_ID_RE.match(assignee)
    if not m:
        continue
    sid = m.group(0)
    if sid == own_session_id:
        # This session's own claims are not "dead" — and at `startup` this session's own
        # transcript file may not exist yet regardless.
        continue
    transcripts = list(Path(config_dir).glob(f"projects/*/{sid}.jsonl"))
    if transcripts:
        # M3: presence alone is not a liveness signal — a transcript persists long after its
        # session ends (measured: ~4300 transcripts on disk at review time, spanning ~30 days).
        # Only a RECENTLY-touched transcript reads as live; an old one is a crash too.
        newest_mtime = max(t.stat().st_mtime for t in transcripts)
        if (now - newest_mtime) < stale_seconds:
            continue  # a recently-live transcript exists: not a crash, nothing to flag
        reason = f"transcript at {transcripts[0]} is stale (>{stale_hours_raw}h old)"
    else:
        reason = f"no transcript found at {config_dir}/projects/*/{sid}.jsonl"
    advisories.append(
        f"- {issue.get('id')} is claimed by session {sid} ({reason}) — looks crashed. Advisory "
        f"only: run `{release_script} --id {issue.get('id')} --note '<why>'` to release it; "
        f"this hook never releases automatically."
    )

out = prime
hook_out = out.setdefault("hookSpecificOutput", {})
if advisories:
    extra = "\n\n## estate-beads: possibly-crashed claims (advisory only, never auto-released)\n" + "\n".join(advisories) + "\n"
    hook_out["additionalContext"] = hook_out.get("additionalContext", "") + extra

print(json.dumps(out))
PYEOF
