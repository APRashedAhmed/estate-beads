#!/usr/bin/env bash
# eb-session-notice.sh — SessionStart hook (pa-jaaf): the OPERATOR-facing notice for claims still
# held by sessions the session log (EB_SESSION_LOG) records as ended. eb-session-start.sh's
# advisory lands in Claude's context; per the hooks reference a SessionStart hook's `systemMessage`
# is discarded and the only operator-visible channel is exit 2 with stderr (the session continues).
# One channel per hook, so this is a separate hook entry: silent exit 0 unless it has a notice.
# Live rendering of the exit-2 notice is doc-verified, not probe-verified.
# Skips `bd` only while the log records no ended session; once any session has ended normally and
# is not resumed, it runs one `bd list` per session start (bounded by its 10 s timeout).
# Never prints to stdout.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SELF="eb-session-notice"
# shellcheck source=lib/eb-common.sh
source "$HERE/lib/eb-common.sh"

INPUT="$(cat)"
SESSION_ID="$(printf '%s' "$INPUT" | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("session_id") or "")
except Exception:
    print("")
' 2>/dev/null)"

SESSION_LOG="${EB_SESSION_LOG:-${XDG_STATE_HOME:-$HOME/.local/state}/estate-beads/sessions.tsv}"
[ -r "$SESSION_LOG" ] || exit 0

# Ended sids: last started/ended line wins (a resumed session's `started` clears its `ended`).
ENDED="$(python3 - "$SESSION_LOG" <<'PYEOF'
import sys
last = {}
try:
    for line in open(sys.argv[1], errors="replace").read().splitlines():
        p = line.split("\t")
        if len(p) >= 3 and p[1] in ("started", "ended"):
            last[p[0]] = p[1]
except OSError:
    pass
print("\n".join(s for s, st in last.items() if st == "ended"))
PYEOF
)"
[ -n "$ENDED" ] || exit 0

[ -n "${BEADS_DIR:-}" ] && [ -d "$BEADS_DIR" ] || exit 0
eb_bd LIST_JSON list --status in_progress --json 2>/dev/null || exit 0

MSG="$(python3 - "$SESSION_ID" "$ENDED" "$LIST_JSON" <<'PYEOF'
import json, re, sys
own, ended_raw, raw = sys.argv[1:4]
ended = set(ended_raw.split())
sid_re = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
try:
    issues = json.loads(raw) if raw.strip() else []
except Exception:
    issues = []
if isinstance(issues, dict):
    issues = issues.get("issues") or []
held = []
for issue in issues:
    m = sid_re.match((issue or {}).get("assignee") or "")
    if m and m.group(0) != own and m.group(0) in ended:
        held.append(f"{issue.get('id')}@{m.group(0)[:8]}")
if held:
    print(f"estate-beads: {len(held)} claim(s) still held by ended session(s): {' '.join(held)}; "
          "run scripts/bead-release.sh (acceptance-pending ones: bead-accept.sh)")
PYEOF
)"
[ -n "$MSG" ] || exit 0
printf '%s\n' "$MSG" >&2
exit 2
