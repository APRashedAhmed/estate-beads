#!/usr/bin/env bash
# eb-session-end.sh — SessionEnd hook (design §11.2/§12.5, plan U3 decision 5).
# Releases every claim whose assignee equals this session's actor (`<session_id>` or
# `<session_id>/<agent_id>` per §12.5's encoding), with the note "claim released at session end".
# Declared Claude-only in the capability matrix (design §12.8) — the seven-seam vocabulary has no
# `session_ended` seam and is not amended (operator direction 2026-09-24).
#
# Portability-contract.md §5.5 / plan decision 5: must finish within 1s on a scratch db, via ONE
# `bd list --json` call, never one call per Bead.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
RELEASE_SCRIPT="$HERE/bead-release.sh"

INPUT="$(cat)"

SESSION_ID="$(printf '%s' "$INPUT" | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("session_id") or "")
except Exception:
    print("")
' 2>/dev/null)"

[ -n "$SESSION_ID" ] || exit 0
[ -n "${BEADS_DIR:-}" ] && [ -d "${BEADS_DIR:-}" ] || exit 0

LIST_JSON="$(bd list --status in_progress --json 2>/dev/null)"
[ -n "$LIST_JSON" ] || exit 0

MATCHES="$(python3 - "$SESSION_ID" "$LIST_JSON" <<'PYEOF'
import json, sys

session_id, raw = sys.argv[1:3]
try:
    issues = json.loads(raw) if raw.strip() else []
except Exception:
    issues = []
if isinstance(issues, dict):
    issues = issues.get("issues") or []

prefix = session_id + "/"
for issue in issues:
    assignee = (issue or {}).get("assignee") or ""
    if assignee == session_id or assignee.startswith(prefix):
        # tab-separated: id, and the EXACT assignee string (bare session id, or
        # session_id/agent_id) -- release must run as that same actor, or `bd update` refuses
        # to reassign a live claim held by a different actor without --force.
        bead_id = issue.get("id", "")
        print(bead_id + "\t" + assignee)
PYEOF
)"

[ -n "$MATCHES" ] || exit 0

while IFS=$'\t' read -r id assignee; do
  [ -n "$id" ] || continue
  BEADS_ACTOR="$assignee" "$RELEASE_SCRIPT" --id "$id" --note "claim released at session end" >/dev/null 2>&1 || true
done <<<"$MATCHES"

exit 0
