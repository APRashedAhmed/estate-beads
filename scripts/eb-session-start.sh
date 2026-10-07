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
#    as the mechanism an operator/orchestrator runs. A Bead labeled `acceptance-pending` is
#    EXCLUDED from that crashed-claim list (N1, fix round 2 review pa-s2s.8-review-2): it is
#    awaiting acceptance, not abandoned, and SessionEnd already leaves it alone on purpose (B1).
#    It gets its own, separate advisory naming scripts/bead-accept.sh (or bead-report-success.sh's
#    review path) as the closer, never bead-release.sh.
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

# --- 1b. scratch sweep: delete bead-scratch.sh folders whose marker is >24h old -----------------
# Filesystem-only (glob + stat, no `bd` call), runs regardless of whether BEADS_DIR resolves below
# — scratch cleanup is not conditioned on this session having a live Beads database. Never fails
# the hook: guarded (`-x` + `|| true`) so a missing script or non-zero exit never blocks prime.
SCRATCH_SCRIPT="$HERE/bead-scratch.sh"
if [ -x "$SCRATCH_SCRIPT" ]; then
  "$SCRATCH_SCRIPT" sweep-stale "${EB_SCRATCH_SWEEP_STALE_HOURS:-24}" >/dev/null 2>&1 || true
fi

# --- 1c. session log: record this session as started (a resumed session overrides its earlier
# `ended` line, last line wins) — before the BEADS_DIR check so it runs regardless of the database.
SELF="eb-session-start"
# shellcheck source=lib/eb-common.sh
source "$HERE/lib/eb-common.sh"
[ -z "$SESSION_ID" ] || eb_session_log "$SESSION_ID" started

# --- 2. prime + advisory sweep, only if BEADS_DIR resolves -------------------------------------
if [ -z "${BEADS_DIR:-}" ] || [ ! -d "$BEADS_DIR" ]; then
  exit 0
fi

PRIME_JSON="$(bd prime --hook-json 2>/dev/null)"
[ -n "$PRIME_JSON" ] || exit 0

# bd list --json (single call, not one per Bead — portability-contract.md §5.5-adjacent
# discipline applies to any per-claim loop, and there is exactly one candidate set here).
# A list failure prints a diagnostic on stderr (the sweep is skipped); the hook still exits 0.
eb_bd LIST_JSON list --status in_progress --json || LIST_JSON=""

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

SESSION_LOG="${EB_SESSION_LOG:-${XDG_STATE_HOME:-$HOME/.local/state}/estate-beads/sessions.tsv}"

python3 - "$PRIME_JSON" "$RELEASE_SCRIPT" "$SESSION_ID" "$CONFIG_DIR" "$LIST_JSON" "$STALE_HOURS" "$SESSION_LOG" <<'PYEOF'
import json
import re
import sys
import time
from pathlib import Path

prime_raw, release_script, own_session_id, config_dir, list_raw, stale_hours_raw, session_log = sys.argv[1:8]

# Session log (pa-jaaf): per sid, the LAST started/ended line wins (a resumed session's `started`
# overrides its earlier `ended`). sid -> (state, timestamp). `failed` lines are diagnostic only.
last_state = {}
try:
    for line in Path(session_log).read_text(errors="replace").splitlines():
        parts = line.split("\t")
        if len(parts) >= 3 and parts[1] in ("started", "ended"):
            last_state[parts[0]] = (parts[1], parts[2])
except (OSError, ValueError):
    pass
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
ended_advisories = []
pending_advisories = []
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
    # M3/§12.5: liveness first, for EVERY candidate — the sweep only ever concerns claims held
    # by a DEAD session; a Bead whose session is still live is not this sweep's business at all,
    # whether or not it happens to carry acceptance-pending.
    ended = last_state.get(sid, ("", ""))
    ended_sweep = ended[0] == "ended"
    transcripts = [] if ended_sweep else list(Path(config_dir).glob(f"projects/*/{sid}.jsonl"))
    if ended_sweep:
        # The session log says this session ended: no transcript check (a fresh transcript is
        # exactly what a just-ended session leaves behind).
        reason = f"session ended at {ended[1]} without releasing this claim"
    elif transcripts:
        # M3: presence alone is not a liveness signal — a transcript persists long after its
        # session ends (measured: ~4300 transcripts on disk at review time, spanning ~30 days).
        # Only a RECENTLY-touched transcript reads as live; an old one is a crash too.
        newest_mtime = max(t.stat().st_mtime for t in transcripts)
        if (now - newest_mtime) < stale_seconds:
            continue  # a recently-live transcript exists: not a crash, nothing to flag
        reason = f"transcript at {transcripts[0]} is stale (>{stale_hours_raw}h old)"
    else:
        reason = f"no transcript found at {config_dir}/projects/*/{sid}.jsonl"

    labels = (issue or {}).get("labels") or []
    if "acceptance-pending" in labels:
        # N1 (fix round 2, review pa-s2s.8-review-2): a pending Bead held by a DEAD session is
        # awaiting acceptance, not abandoned (B1 already leaves it alone at SessionEnd) — never
        # list it as "looks crashed" and never point it at bead-release.sh, which the previous
        # sweep did whenever its session's transcript also happened to look dead/stale.
        pending_advisories.append(
            f"- {issue.get('id')} is claimed by session {sid} and is acceptance-pending — "
            "awaiting acceptance, not crashed. Do NOT release it; close it via "
            "scripts/bead-accept.sh (or the --review form, per its accept: label)."
        )
        continue

    line = (
        f"- {issue.get('id')} is claimed by session {sid} ({reason}) — idle or crashed: check "
        f"before releasing. Advisory only: run `{release_script} --id {issue.get('id')} "
        f"--note '<why>'` to release it; this hook never releases automatically."
    )
    (ended_advisories if ended_sweep else advisories).append(line)

out = prime
hook_out = out.setdefault("hookSpecificOutput", {})
extra = ""
if ended_advisories:
    extra += "\n\n## estate-beads: claims held by ended sessions (release needed; never auto-released)\n" + "\n".join(ended_advisories) + "\n"
if advisories:
    extra += "\n\n## estate-beads: possibly-crashed claims (advisory only, never auto-released)\n" + "\n".join(advisories) + "\n"
if pending_advisories:
    extra += "\n\n## estate-beads: acceptance-pending claims (not crashed; close via bead-accept.sh)\n" + "\n".join(pending_advisories) + "\n"
if extra:
    hook_out["additionalContext"] = hook_out.get("additionalContext", "") + extra

print(json.dumps(out))
PYEOF
