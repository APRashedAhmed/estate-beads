#!/usr/bin/env bash
# eb-session-start.sh — SessionStart hook (design §11.2/§12.5, plan U3 decision 4).
#
# 1. Actor export (P3/P6 PASS, U1): writes `export BEADS_ACTOR=<session_id>` into
#    $CLAUDE_ENV_FILE so every subsequent Bash call in THIS session records/claims under the
#    session id. Independent of whether a Beads database is present.
# 2. `bd prime --hook-json` + an ADVISORY crash-claim sweep, only when $BEADS_DIR resolves to an
#    existing directory — silent (no stdout) otherwise. The sweep never releases anything; it
#    only lists Beads claimed by a session whose transcript file is gone, naming
#    scripts/bead-release.sh as the mechanism an operator/orchestrator runs.
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

python3 - "$PRIME_JSON" "$RELEASE_SCRIPT" "$SESSION_ID" "$HOME" "$LIST_JSON" <<'PYEOF'
import json
import re
import sys
from pathlib import Path

prime_raw, release_script, own_session_id, home, list_raw = sys.argv[1:6]

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
    transcripts = list(Path(home).glob(f".claude/projects/*/{sid}.jsonl"))
    if transcripts:
        continue  # a live transcript exists: not a crash, nothing to flag
    advisories.append(
        f"- {issue.get('id')} is claimed by session {sid} (no transcript found at "
        f"~/.claude/projects/*/{sid}.jsonl) — looks crashed. Advisory only: run "
        f"`{release_script} --id {issue.get('id')} --note '<why>'` to release it; this hook "
        f"never releases automatically."
    )

out = prime
hook_out = out.setdefault("hookSpecificOutput", {})
if advisories:
    extra = "\n\n## estate-beads: possibly-crashed claims (advisory only, never auto-released)\n" + "\n".join(advisories) + "\n"
    hook_out["additionalContext"] = hook_out.get("additionalContext", "") + extra

print(json.dumps(out))
PYEOF
