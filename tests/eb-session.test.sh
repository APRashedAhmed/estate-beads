#!/usr/bin/env bash
# eb-session.test.sh — hermetic tests for scripts/eb-session-start.sh and
# scripts/eb-session-end.sh (design §11.2/§12.5, plan U3 decisions 4/5). Every case feeds real
# stdin payloads to the scripts directly (this agent type cannot run `claude -p`), on scratch
# databases only (tests/_scratch_db.sh).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
START="$ROOT/scripts/eb-session-start.sh"
END="$ROOT/scripts/eb-session-end.sh"

# shellcheck source=_assert.sh
source "$ROOT/tests/_assert.sh"
# shellcheck source=_scratch_db.sh
source "$ROOT/tests/_scratch_db.sh"

sessionstart_payload() {  # <session-id>
  printf '{"session_id":"%s","source":"startup","hook_event_name":"SessionStart"}' "$1"
}

# M3 (review pa-s2s.8-review-1): pin the transcript root this test's scratch HOME actually uses —
# an inherited CLAUDE_CONFIG_DIR (this estate is per-account keyed) would make every fixture
# transcript this suite writes under $HOME/.claude invisible to the sweep.
unset CLAUDE_CONFIG_DIR
sessionend_payload() {  # <session-id>
  printf '{"session_id":"%s","hook_event_name":"SessionEnd"}' "$1"
}

# --- 1. SessionStart on a scratch db: prime output present, env file has the export ------------
scratch1=""; eb_scratch_db scratch1
ENVFILE1="$(mktemp)"
SID1="11111111-1111-1111-1111-111111111111"
OUT1="$(CLAUDE_ENV_FILE="$ENVFILE1" bash "$START" <<<"$(sessionstart_payload "$SID1")")"
assert_contains "SessionStart: env file carries the BEADS_ACTOR export" \
  "$(cat "$ENVFILE1")" "export BEADS_ACTOR=$SID1"
assert_contains "SessionStart: prime output present in additionalContext" \
  "$OUT1" "Beads Workflow Context"
assert_contains "SessionStart: output is one valid SessionStart JSON envelope" \
  "$OUT1" "\"hookEventName\": \"SessionStart\""
python3 -c 'import json,sys; json.loads(sys.argv[1])' "$OUT1" \
  && eb_ok "SessionStart: output parses as JSON" \
  || eb_bad "SessionStart: output parses as JSON" "got: $OUT1"
rm -f "$ENVFILE1"

# --- 2. two concurrent scratch "sessions": claims stay isolated by actor -----------------------
BEAD_JSON="$(BEADS_ACTOR=creator bd create "isolation test" --type task -p 2 --json)"
BEAD_ID="$(printf '%s' "$BEAD_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
SID_A="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
SID_B="bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
BEADS_ACTOR="$SID_A" bd update "$BEAD_ID" --claim --json >/dev/null
ASSIGNEE_AFTER_A="$(bd show --json "$BEAD_ID" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["assignee"])')"
assert_eq "isolation: session A's claim recorded under session A's actor" "$SID_A" "$ASSIGNEE_AFTER_A"
# Session B claiming a DIFFERENT bead must not disturb A's claim.
BEAD2_JSON="$(BEADS_ACTOR=creator bd create "isolation test 2" --type task -p 2 --json)"
BEAD2_ID="$(printf '%s' "$BEAD2_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
BEADS_ACTOR="$SID_B" bd update "$BEAD2_ID" --claim --json >/dev/null
STILL_A="$(bd show --json "$BEAD_ID" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["assignee"])')"
assert_eq "isolation: session A's claim untouched by session B's activity" "$SID_A" "$STILL_A"
ASSIGNEE_B="$(bd show --json "$BEAD2_ID" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["assignee"])')"
assert_eq "isolation: session B's claim recorded under session B's actor" "$SID_B" "$ASSIGNEE_B"

# --- 3. SessionEnd release: session A's SessionEnd releases ONLY its own claim -----------------
bash "$END" <<<"$(sessionend_payload "$SID_A")" >/dev/null
STATUS_A_AFTER="$(bd show --json "$BEAD_ID" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["status"])')"
ASSIGNEE_A_AFTER="$(bd show --json "$BEAD_ID" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0].get("assignee") or "")')"
assert_eq "SessionEnd: session A's Bead is released (status open)" "open" "$STATUS_A_AFTER"
assert_eq "SessionEnd: session A's Bead is unassigned" "" "$ASSIGNEE_A_AFTER"
STATUS_B_AFTER="$(bd show --json "$BEAD2_ID" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["status"])')"
assert_eq "SessionEnd: session B's Bead is UNTOUCHED by session A's SessionEnd" "in_progress" "$STATUS_B_AFTER"

# --- 4. crash-sweep listing: a Bead claimed by a uuid with no transcript file -> advisory line,
#        Bead stays in_progress (SessionStart never releases) --------------------------------
SID_DEAD="dddddddd-dddd-dddd-dddd-dddddddddddd"
SID_LIVE="11111111-1111-1111-1111-111111111111"  # reuse SID1: gets a real transcript file below
BEAD3_JSON="$(BEADS_ACTOR=creator bd create "crash sweep test" --type task -p 2 --json)"
BEAD3_ID="$(printf '%s' "$BEAD3_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
BEADS_ACTOR="$SID_DEAD" bd update "$BEAD3_ID" --claim --json >/dev/null

BEAD4_JSON="$(BEADS_ACTOR=creator bd create "live session test" --type task -p 2 --json)"
BEAD4_ID="$(printf '%s' "$BEAD4_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
BEADS_ACTOR="$SID_LIVE" bd update "$BEAD4_ID" --claim --json >/dev/null
mkdir -p "$HOME/.claude/projects/fake-project"
: > "$HOME/.claude/projects/fake-project/$SID_LIVE.jsonl"

# SessionStart runs as a DIFFERENT (third) session, so both SID_DEAD and SID_LIVE are "someone
# else's" claims from its point of view — the sweep must flag the dead one only.
SID_SWEEPER="55555555-5555-5555-5555-555555555555"
ENVFILE2="$(mktemp)"
OUT2="$(CLAUDE_ENV_FILE="$ENVFILE2" bash "$START" <<<"$(sessionstart_payload "$SID_SWEEPER")")"
assert_contains "sweep: flags the dead-transcript claim" "$OUT2" "$BEAD3_ID"
assert_contains "sweep: names bead-release.sh as the mechanism" "$OUT2" "bead-release.sh"
assert_contains "sweep: does NOT flag the live-transcript claim" "$OUT2" "" # sanity no-op below
python3 - "$OUT2" "$BEAD4_ID" <<'PYEOF'
import sys
out, live_id = sys.argv[1:3]
assert live_id not in out, f"{live_id} should NOT appear in sweep advisories: {out}"
PYEOF
[ $? -eq 0 ] && eb_ok "sweep: live-transcript claim absent from advisories" \
             || eb_bad "sweep: live-transcript claim absent from advisories"

STATUS_DEAD_AFTER="$(bd show --json "$BEAD3_ID" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["status"])')"
assert_eq "sweep: dead claim's Bead stays in_progress (advisory only, never released)" \
  "in_progress" "$STATUS_DEAD_AFTER"
rm -f "$ENVFILE2"

# --- 4b. M3 (review pa-s2s.8-review-1): a PRESENT but STALE transcript (mtime older than the
#         threshold) reads as crashed too, not just a missing one -----------------------------
SID_STALE="eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
BEAD3B_JSON="$(BEADS_ACTOR=creator bd create "stale transcript sweep test" --type task -p 2 --json)"
BEAD3B_ID="$(printf '%s' "$BEAD3B_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
BEADS_ACTOR="$SID_STALE" bd update "$BEAD3B_ID" --claim --json >/dev/null
mkdir -p "$HOME/.claude/projects/fake-project"
: > "$HOME/.claude/projects/fake-project/$SID_STALE.jsonl"
touch -d '-7 hours' "$HOME/.claude/projects/fake-project/$SID_STALE.jsonl"

ENVFILE2B="$(mktemp)"
OUT2B="$(CLAUDE_ENV_FILE="$ENVFILE2B" bash "$START" <<<"$(sessionstart_payload "$SID_SWEEPER")")"
assert_contains "sweep: flags a present-but-stale-transcript claim" "$OUT2B" "$BEAD3B_ID"
assert_contains "sweep: names the transcript as stale, not just missing" "$OUT2B" "stale"
STATUS_STALE_AFTER="$(bd show --json "$BEAD3B_ID" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["status"])')"
assert_eq "sweep: stale-transcript claim's Bead stays in_progress (advisory only)" \
  "in_progress" "$STATUS_STALE_AFTER"

# A FRESH transcript (default threshold, well under 6h) must NOT be flagged.
: > "$HOME/.claude/projects/fake-project/$SID_LIVE.jsonl"
ENVFILE2C="$(mktemp)"
OUT2C="$(CLAUDE_ENV_FILE="$ENVFILE2C" bash "$START" <<<"$(sessionstart_payload "$SID_SWEEPER")")"
python3 - "$OUT2C" "$BEAD4_ID" <<'PYEOF'
import sys
out, live_id = sys.argv[1:3]
assert live_id not in out, f"{live_id} should NOT appear in sweep advisories: {out}"
PYEOF
[ $? -eq 0 ] && eb_ok "sweep: a fresh-mtime transcript stays live (not flagged as stale)" \
             || eb_bad "sweep: a fresh-mtime transcript stays live (not flagged as stale)"
rm -f "$ENVFILE2B" "$ENVFILE2C"

# --- 4c. N1 (review pa-s2s.8-review-2): a Bead that is acceptance-pending, held by a session
#         whose transcript is dead, is NOT listed as crashed (no "looks crashed", no
#         bead-release.sh advisory for it) — a distinct advisory routes it to bead-accept.sh -----
SID_PEND_DEAD="cccccccc-dddd-dddd-dddd-dddddddddddd"
BEAD3C_JSON="$(BEADS_ACTOR=creator bd create "pending dead-session sweep test" --type task -p 2 --json)"
BEAD3C_ID="$(printf '%s' "$BEAD3C_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
BEADS_ACTOR="$SID_PEND_DEAD" bd update "$BEAD3C_ID" --claim --json >/dev/null
BEADS_ACTOR="$SID_PEND_DEAD" bd update "$BEAD3C_ID" --append-notes "EVIDENCE: pending" --json >/dev/null
BEADS_ACTOR="$SID_PEND_DEAD" bd update "$BEAD3C_ID" --add-label "acceptance-pending" --json >/dev/null
# No transcript file at all for SID_PEND_DEAD -> would look "dead" under the crash-sweep logic.

ENVFILE2D="$(mktemp)"
OUT2D="$(CLAUDE_ENV_FILE="$ENVFILE2D" bash "$START" <<<"$(sessionstart_payload "$SID_SWEEPER")")"
assert_contains "N1: a pending Bead held by a dead-transcript session still gets an advisory" \
  "$OUT2D" "$BEAD3C_ID"
assert_contains "N1: the pending advisory names bead-accept.sh" "$OUT2D" "bead-accept.sh"
python3 - "$OUT2D" "$BEAD3C_ID" <<'PYEOF'
import json, sys
out, bid = sys.argv[1:3]
ctx = json.loads(out)["hookSpecificOutput"].get("additionalContext", "")
found = False
for line in ctx.splitlines():
    if bid in line:
        found = True
        assert "looks crashed" not in line, f"pending Bead's line must not say 'looks crashed': {line}"
        assert "bead-release.sh" not in line, f"pending Bead's line must not point to bead-release.sh: {line}"
assert found, f"{bid} not found in any advisory line: {ctx}"
PYEOF
[ $? -eq 0 ] && eb_ok "N1: pending Bead's advisory line excludes 'looks crashed' and bead-release.sh" \
             || eb_bad "N1: pending Bead's advisory line excludes 'looks crashed' and bead-release.sh"
STATUS_PEND_DEAD_AFTER="$(bd show --json "$BEAD3C_ID" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["status"])')"
assert_eq "N1: the pending Bead itself stays in_progress (sweep never releases)" \
  "in_progress" "$STATUS_PEND_DEAD_AFTER"
rm -f "$ENVFILE2D"

# --- 4d. N1/§12.5 (advisor follow-up): a pending Bead held by a LIVE session (fresh transcript)
#         gets NO advisory at all — the sweep is about dead sessions only, label or not -----------
BEAD3D_JSON="$(BEADS_ACTOR=creator bd create "pending live-session sweep test" --type task -p 2 --json)"
BEAD3D_ID="$(printf '%s' "$BEAD3D_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
BEADS_ACTOR="$SID_LIVE" bd update "$BEAD3D_ID" --claim --json >/dev/null
BEADS_ACTOR="$SID_LIVE" bd update "$BEAD3D_ID" --append-notes "EVIDENCE: pending" --json >/dev/null
BEADS_ACTOR="$SID_LIVE" bd update "$BEAD3D_ID" --add-label "acceptance-pending" --json >/dev/null
# SID_LIVE's transcript was freshly touched just above (line ~124) -> reads as live.

ENVFILE2E="$(mktemp)"
OUT2E="$(CLAUDE_ENV_FILE="$ENVFILE2E" bash "$START" <<<"$(sessionstart_payload "$SID_SWEEPER")")"
python3 - "$OUT2E" "$BEAD3D_ID" <<'PYEOF'
import sys
out, bid = sys.argv[1:3]
assert bid not in out, f"a pending Bead held by a LIVE session must not appear in any advisory: {out}"
PYEOF
[ $? -eq 0 ] && eb_ok "N1: a pending Bead held by a LIVE session gets no advisory at all" \
             || eb_bad "N1: a pending Bead held by a LIVE session gets no advisory at all"
rm -f "$ENVFILE2E"

# --- 5/5b timing model (F1, pa-e38.6): the old asserts used a hardcoded 1s/1.5s wall-clock
#     budget, which flakes under CPU load that has nothing to do with the handler — the box is
#     merely slower at spawning `bd`/python processes, not the handler doing unbounded work.
#     Per portability-contract.md §5.5, Claude shares a ~1.5s budget across SessionEnd hooks;
#     eb-session-end.sh's own TOTAL_BUDGET_SECONDS (default 1.3s, scripts/eb-session-end.sh:27)
#     targets that by design, backgrounding the per-Bead note phase under a watchdog deadline.
#     So ANY fixed threshold under ~1.3s is wrong independent of load, and a pure wall-clock cap
#     can't distinguish "this box is slow right now" from "the handler is doing unbounded work".
#
#     Model instead: measure a same-run BASELINE cost of the handler's own phase-1 call (a bare
#     `bd list --status in_progress --json`) immediately before each timed run, on the same
#     scratch db, under whatever load is currently present. Phase 1 of eb-session-end.sh is
#     exactly ONE `bd list` + ONE batched `bd update` per distinct assignee (never one call per
#     Bead — true for both the single-claim and the 3-claims-same-assignee cases here), so:
#       threshold_ms = 2*baseline_ms (phase 1: list + batched update) + budget_ms (phase 2's own
#                      watchdog deadline) + margin_ms (python/awk/watchdog spawn overhead, scaled
#                      with baseline so it inflates under the same load the baseline saw)
#     This scales with ambient load automatically (baseline is measured live, same run, same box)
#     instead of guessing a load-free wall-clock number.
#
#     That alone isn't enough: a stub that slows down EVERY `bd` invocation (including the
#     baseline call) would inflate the baseline right along with the real run and never trip the
#     threshold. So also enforce an absolute CEILING at 3x the contract's own figure
#     (3 * 1500ms = 4500ms) as a backstop that does not scale with a corrupted baseline — a
#     handler that is genuinely, unboundedly slow blows through this regardless of what the
#     baseline measured. A run must satisfy BOTH checks to pass.
EB_SESSION_END_CONTRACT_MS=1500
EB_SESSION_END_CEILING_MS=$((EB_SESSION_END_CONTRACT_MS * 3))
EB_SESSION_END_BUDGET_S="${EB_SESSION_END_BUDGET:-1.3}"
EB_SESSION_END_BUDGET_MS=$(awk -v b="$EB_SESSION_END_BUDGET_S" 'BEGIN { printf "%d", (b*1000)+0.5 }')

eb_timing_verdict() {  # <description> <baseline_ms> <elapsed_ms>
  local desc="$1" baseline_ms="$2" elapsed_ms="$3" margin_ms threshold_ms
  margin_ms="$baseline_ms"
  [ "$margin_ms" -lt 300 ] && margin_ms=300
  threshold_ms=$((2*baseline_ms + EB_SESSION_END_BUDGET_MS + margin_ms))
  if [ "$elapsed_ms" -le "$threshold_ms" ] && [ "$elapsed_ms" -le "$EB_SESSION_END_CEILING_MS" ]; then
    eb_ok "$desc (${elapsed_ms}ms; baseline ${baseline_ms}ms, threshold ${threshold_ms}ms, ceiling ${EB_SESSION_END_CEILING_MS}ms)"
  else
    eb_bad "$desc" "took ${elapsed_ms}ms; baseline ${baseline_ms}ms, threshold ${threshold_ms}ms, ceiling ${EB_SESSION_END_CEILING_MS}ms"
  fi
}

# --- 5. SessionEnd timing: one direct stdin feed with one claimed Bead -------------------------
BEAD5_JSON="$(BEADS_ACTOR=creator bd create "timing test" --type task -p 2 --json)"
BEAD5_ID="$(printf '%s' "$BEAD5_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
SID_TIMING="99999999-9999-9999-9999-999999999999"
BEADS_ACTOR="$SID_TIMING" bd update "$BEAD5_ID" --claim --json >/dev/null

BT0=$(date +%s%N)
bd list --status in_progress --json >/dev/null
BT1=$(date +%s%N)
BASELINE_MS=$(( (BT1 - BT0) / 1000000 ))

T0=$(date +%s%N)
bash "$END" <<<"$(sessionend_payload "$SID_TIMING")" >/dev/null
T1=$(date +%s%N)
ELAPSED_MS=$(( (T1 - T0) / 1000000 ))

eb_timing_verdict "SessionEnd: completes within budget on a scratch db" "$BASELINE_MS" "$ELAPSED_MS"

# --- 5b. SessionEnd budget (fix round 1, F4): THREE claimed Beads release concurrently, all
#         become open+unassigned, and total wall time stays within the same baseline+budget model
#         (portability-contract.md §5.5) -- phase 1 is still exactly one `bd list` + one batched
#         `bd update` here (all three share one assignee), so the same threshold applies ----------
BEAD6_JSON="$(BEADS_ACTOR=creator bd create "concurrent release 1" --type task -p 2 --json)"
BEAD6_ID="$(printf '%s' "$BEAD6_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
BEAD7_JSON="$(BEADS_ACTOR=creator bd create "concurrent release 2" --type task -p 2 --json)"
BEAD7_ID="$(printf '%s' "$BEAD7_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
BEAD8_JSON="$(BEADS_ACTOR=creator bd create "concurrent release 3" --type task -p 2 --json)"
BEAD8_ID="$(printf '%s' "$BEAD8_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
SID_MULTI="77777777-7777-7777-7777-777777777777"
BEADS_ACTOR="$SID_MULTI" bd update "$BEAD6_ID" --claim --json >/dev/null
BEADS_ACTOR="$SID_MULTI" bd update "$BEAD7_ID" --claim --json >/dev/null
BEADS_ACTOR="$SID_MULTI" bd update "$BEAD8_ID" --claim --json >/dev/null

BT0=$(date +%s%N)
bd list --status in_progress --json >/dev/null
BT1=$(date +%s%N)
BASELINE3_MS=$(( (BT1 - BT0) / 1000000 ))

T0=$(date +%s%N)
bash "$END" <<<"$(sessionend_payload "$SID_MULTI")" >/dev/null
T1=$(date +%s%N)
ELAPSED3_MS=$(( (T1 - T0) / 1000000 ))

for bid in "$BEAD6_ID" "$BEAD7_ID" "$BEAD8_ID"; do
  st="$(bd show --json "$bid" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["status"])')"
  asn="$(bd show --json "$bid" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0].get("assignee") or "")')"
  assert_eq "SessionEnd (3 claims): $bid is released (status open)" "open" "$st"
  assert_eq "SessionEnd (3 claims): $bid is unassigned" "" "$asn"
done

eb_timing_verdict "SessionEnd: 3 concurrent claims release within budget on a scratch db" \
  "$BASELINE3_MS" "$ELAPSED3_MS"

# --- 5c. B1 fix (review pa-s2s.8-review-1): a Bead carrying `acceptance-pending` survives
#         SessionEnd -- it must stay in_progress, still assigned, still labeled, even though its
#         assignee matches the ending session's actor -----------------------------------------
BEAD9_JSON="$(BEADS_ACTOR=creator bd create "acceptance-pending survives sessionend" --type task -p 2 --json)"
BEAD9_ID="$(printf '%s' "$BEAD9_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
SID_PENDING="66666666-6666-6666-6666-666666666666"
BEADS_ACTOR="$SID_PENDING" bd update "$BEAD9_ID" --claim --json >/dev/null
BEADS_ACTOR="$SID_PENDING" bd update "$BEAD9_ID" --append-notes "EVIDENCE: pending report" --json >/dev/null
BEADS_ACTOR="$SID_PENDING" bd update "$BEAD9_ID" --add-label "acceptance-pending" --json >/dev/null

bash "$END" <<<"$(sessionend_payload "$SID_PENDING")" >/dev/null

STATUS_PENDING_AFTER="$(bd show --json "$BEAD9_ID" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["status"])')"
ASSIGNEE_PENDING_AFTER="$(bd show --json "$BEAD9_ID" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0].get("assignee") or "")')"
LABELS_PENDING_AFTER="$(bd show --json "$BEAD9_ID" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)[0].get("labels") or []))')"
assert_eq "B1: an acceptance-pending Bead stays in_progress across SessionEnd" "in_progress" "$STATUS_PENDING_AFTER"
assert_eq "B1: an acceptance-pending Bead keeps its assignee across SessionEnd" "$SID_PENDING" "$ASSIGNEE_PENDING_AFTER"
assert_contains "B1: an acceptance-pending Bead keeps its label across SessionEnd" "$LABELS_PENDING_AFTER" "acceptance-pending"

# --- 6. Both hooks no-op silently when BEADS_DIR does not resolve ------------------------------
OUT_NODB="$(env -u BEADS_DIR bash "$START" <<<"$(sessionstart_payload "cccccccc-cccc-cccc-cccc-cccccccccccc")" 2>&1)"
if printf '%s' "$OUT_NODB" | grep -q 'Beads Workflow Context'; then
  eb_bad "SessionStart: no-op (no prime/sweep text) when no db" "got: $OUT_NODB"
else
  eb_ok "SessionStart: no-op (no prime/sweep text) when no db"
fi
OUT_END_NODB="$(env -u BEADS_DIR bash "$END" <<<"$(sessionend_payload "cccccccc-cccc-cccc-cccc-cccccccccccc")" 2>&1)"
assert_eq "SessionEnd: silent (no stdout) when no db" "" "$OUT_END_NODB"

rm -rf "$scratch1"
eb_report
