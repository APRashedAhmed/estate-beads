#!/usr/bin/env bash
# eb-session-end.sh — SessionEnd hook (design §11.2/§12.5, plan U3 decision 5).
# Releases every claim whose assignee equals this session's actor (`<session_id>` or
# `<session_id>/<agent_id>` per §12.5's encoding), with the note "claim released at session end" —
# EXCEPT a Bead carrying the `acceptance-pending` label (contract §5.1 "awaiting acceptance" stays
# in_progress by design; fix round 1 B1), which is left untouched.
# Declared Claude-only in the capability matrix (design §12.8) — the seven-seam vocabulary has no
# `session_ended` seam and is not amended (operator direction 2026-09-24).
#
# Portability-contract.md §5.5 / plan decision 5: must finish within Claude's shared ~1.5s
# SessionEnd budget on a scratch db, via ONE `bd list --json` call, never one call per Bead.
#
# Two-phase release (fix round 1, F4): the state change that MUST land even if the process is cut
# off partway through is "open + unassigned". That is done first, SYNCHRONOUSLY, via ONE batched
# `bd update <id...> --status open --assignee "" --json` call per distinct assignee (`bd update`
# accepts several ids in one call — probed empirically: ~185ms for 2 ids vs. ~750-900ms/id for the
# full bead-release.sh chain). Only the rule-5 progress note (which needs a per-Bead `bd show` to
# preserve COMPLETED/NEXT) runs per-Bead, and that phase is backgrounded (one job per Bead, then
# `wait`) under a hard overall deadline — if the deadline kills it, the release state above has
# already landed and only the note is lost.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
RELEASE_SCRIPT="$HERE/bead-release.sh"
SCRATCH_SCRIPT="$HERE/bead-scratch.sh"
SELF="eb-session-end"
# A bd failure prints a diagnostic on stderr via eb_bd; this hook still exits 0 in every case.
# shellcheck source=lib/eb-common.sh
source "$HERE/lib/eb-common.sh"
# Total budget target, measured from THIS script's own start (not just phase 2) — leaves a margin
# under Claude's shared ~1.5s SessionEnd budget for the synchronous `bd list` + batched release
# calls in phase 1, whose cost varies with match count and db size.
TOTAL_BUDGET_SECONDS="${EB_SESSION_END_BUDGET:-1.3}"
MIN_NOTE_DEADLINE_SECONDS="${EB_SESSION_END_MIN_NOTE_DEADLINE:-0.2}"
_T_START_NS=$(date +%s%N)

INPUT="$(cat)"

SESSION_ID="$(printf '%s' "$INPUT" | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("session_id") or "")
except Exception:
    print("")
' 2>/dev/null)"

[ -n "$SESSION_ID" ] || exit 0

# Unconditional first marker (pa-jaaf): lands before any scratch sweep, BEADS_DIR check, or `bd`
# call, so even a budget kill or a missing database leaves the next session a record.
eb_session_log "$SESSION_ID" ended

# --- scratch cleanup: delete THIS session's own marked bead-scratch.sh folders ------------------
# Filesystem-only (glob + stat, no `bd` call) — negligible against the shared SessionEnd budget.
# Never fails the hook: bead-scratch.sh's own sweep-session is itself silent/no-fail, and this is
# additionally guarded here so a missing script or a non-zero exit never blocks claim release.
[ -x "$SCRATCH_SCRIPT" ] && "$SCRATCH_SCRIPT" sweep-session "$SESSION_ID" >/dev/null 2>&1

if [ -z "${BEADS_DIR:-}" ] || [ ! -d "${BEADS_DIR:-}" ]; then
  printf '%s: BEADS_DIR is unset or not a directory; claims not released\n' "$SELF" >&2
  exit 0
fi

eb_bd LIST_JSON list --status in_progress --json || exit 0
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
    if assignee != session_id and not assignee.startswith(prefix):
        continue
    # B1 fix (review pa-s2s.8-review-1): a Bead reported ACCEPTANCE-PENDING (contract §5.1
    # "awaiting acceptance") stays in_progress on purpose -- releasing it here would put it
    # back in `bd ready`, where another actor could claim and redo the work, and the eventual
    # closer would then refuse it (both accept forms require status == in_progress AND the
    # label). SessionEnd must never release a Bead carrying this label; skip it, the label's
    # authority (bead-accept.sh / the operator) is the only thing that clears it.
    labels = (issue or {}).get("labels") or []
    if "acceptance-pending" in labels:
        continue
    # tab-separated: id, and the EXACT assignee string (bare session id, or
    # session_id/agent_id) -- release must run as that same actor, or `bd update` refuses
    # to reassign a live claim held by a different actor without --force.
    bead_id = issue.get("id", "")
    print(bead_id + "\t" + assignee)
PYEOF
)"

[ -n "$MATCHES" ] || exit 0

# --- Phase 1 (synchronous, guaranteed): batch the status+assignee release by assignee group -----
# Different Beads in MATCHES can carry different exact assignees (`<session_id>` vs.
# `<session_id>/<agent_id>` for distinct subagents), and `bd update` must run as the SAME actor
# that holds the claim (or it refuses to reassign without --force) — so one batched call per
# distinct assignee, not one call overall.
declare -A GROUP_IDS=()
while IFS=$'\t' read -r id assignee; do
  [ -n "$id" ] || continue
  GROUP_IDS["$assignee"]="${GROUP_IDS[$assignee]:-}$id "
done <<<"$MATCHES"

for assignee in "${!GROUP_IDS[@]}"; do
  # shellcheck disable=SC2086 # intentional word-splitting: space-joined id list
  BEADS_ACTOR="$assignee" eb_bd _released update ${GROUP_IDS[$assignee]} --status open --assignee "" --json \
    || eb_session_log "$SESSION_ID" failed "${EB_BD_ERROR:-bd update failed}"
done

# --- Phase 2 (concurrent, best-effort, deadline-bound): per-Bead rule-5 release note ------------
# bead-release.sh re-applies the (now idempotent) status/assignee update and then writes the
# rule-5 progress note, preserving any prior COMPLETED/NEXT via its own `bd show`. Backgrounded one
# job per Bead so N claims cost ~one chain's wall time, not N chains' wall time.
note_pids=()
note_ids=()
note_errs=""
# No other EXIT trap exists in this script; this removes the per-job directory on every exit path.
trap '[ -z "$note_errs" ] || rm -rf "$note_errs"' EXIT
if ! note_errs="$(mktemp -d)" || [ -z "$note_errs" ]; then
  note_errs=""
  printf '%s: could not create a temporary directory; release notes skipped\n' "$SELF" >&2
  exit 0
fi
while IFS=$'\t' read -r id assignee; do
  [ -n "$id" ] || continue
  # stderr goes to a per-job file and is printed only if the job fails (below), so a clean run
  # stays silent but a failed release note is no longer invisible.
  BEADS_ACTOR="$assignee" "$RELEASE_SCRIPT" --id "$id" --note "claim released at session end" \
    >/dev/null 2>"$note_errs/${#note_pids[@]}" &
  note_pids+=("$!")
  note_ids+=("$id")
done <<<"$MATCHES"

if [ "${#note_pids[@]}" -gt 0 ]; then
  # Deadline is what's LEFT of the total budget after phase 1 + setup, not a fixed constant — a
  # slow `bd list`/batch-update phase must shrink phase 2's window rather than blow the total.
  _now_ns=$(date +%s%N)
  _elapsed_s=$(awk -v a="$_T_START_NS" -v b="$_now_ns" 'BEGIN { printf "%.3f", (b - a) / 1000000000 }')
  _remaining_s=$(awk -v total="$TOTAL_BUDGET_SECONDS" -v elapsed="$_elapsed_s" -v floor="$MIN_NOTE_DEADLINE_SECONDS" \
    'BEGIN { r = total - elapsed; if (r < floor) r = floor; printf "%.3f", r }')
  ( sleep "$_remaining_s"; for p in "${note_pids[@]}"; do kill -9 "$p" 2>/dev/null; done ) &
  watchdog_pid=$!
  for i in "${!note_pids[@]}"; do
    wait "${note_pids[$i]}" 2>/dev/null; _rc=$?
    # 137 = killed by the deadline watchdog (the documented loss of only the note).
    if [ "$_rc" -ne 0 ] && [ "$_rc" -ne 137 ]; then
      printf '%s: release note for %s failed (rc=%s):\n' "$SELF" "${note_ids[$i]}" "$_rc" >&2
      cat "$note_errs/$i" >&2 2>/dev/null || true
      eb_session_log "$SESSION_ID" failed \
        "release note for ${note_ids[$i]} failed (rc=$_rc): $(head -n 1 "$note_errs/$i" 2>/dev/null)"
    fi
  done
  kill "$watchdog_pid" 2>/dev/null || true
  wait "$watchdog_pid" 2>/dev/null || true
fi
exit 0
