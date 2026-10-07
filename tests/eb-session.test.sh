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

# Hermeticity (review MINOR-2): the SessionStart/SessionEnd sweeps run against
# $EB_SCRATCH_ROOT/${XDG_RUNTIME_DIR:-/tmp}/estate-beads-scratch when unset. Pin it to a
# throwaway root this suite owns so the sweeps never touch the operator's real scratch folders.
EB_SESSION_TEST_SCRATCH_ROOT="$(mktemp -d)"
export EB_SCRATCH_ROOT="$EB_SESSION_TEST_SCRATCH_ROOT"
# pa-jaaf: the session log defaults to the operator's real ~/.local/state; pin it here so no case
# (existing or new) can write it.
export EB_SESSION_LOG="$EB_SESSION_TEST_SCRATCH_ROOT/sessions.tsv"
trap 'rm -rf "$EB_SESSION_TEST_SCRATCH_ROOT"' EXIT

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

# --- 5/5b timing model (F1, pa-e38.6; fix round 2, review pa-e38.6-review-1 MAJOR-1): the old
#     asserts used a hardcoded 1s/1.5s wall-clock budget, which flakes under CPU load that has
#     nothing to do with the handler — the box is merely slower at spawning `bd`/python processes,
#     not the handler doing unbounded work. Per portability-contract.md §5.5, Claude shares a
#     ~1.5s budget across SessionEnd hooks; eb-session-end.sh's own TOTAL_BUDGET_SECONDS (default
#     1.3s, scripts/eb-session-end.sh:27) targets that by design, backgrounding the per-Bead note
#     phase under a watchdog deadline.
#
#     Round 1 scaled the whole threshold off a same-run baseline (2*B + budget + margin), which on
#     a quiet machine (B ~ 180ms) came out near 1960ms — above the contract's own 1.5s bound, so a
#     handler that drifts to 1.6-1.9s on an idle box passed. Fixed here: anchor the threshold AT
#     the contract's 1500ms, and widen it only by load-attributable EXTRA baseline cost above a
#     quiet-machine reference (B_QUIET_MS). k=3 approximates the handler's own `bd` call count
#     (phase 1: one `bd list` + one batched `bd update`; phase 2 watchdog/python overhead scales
#     similarly), so the widening tracks how much slower `bd` itself has gotten under load, not an
#     arbitrary multiple of the (already-inflated) baseline.
#       threshold_ms = 1500 + k * max(0, baseline_ms - B_QUIET_MS)
#     B_QUIET_MS=250 is set above the idle `bd list` cost measured on this box (8 runs, scratch db,
#     no synthetic load: 174-222ms, typical ~180ms — see pa-e38.6-round2.md for the measurement),
#     so a quiet run's margin term is 0 and the threshold sits exactly at the contract figure.
#
#     That alone isn't enough: a stub that slows down EVERY `bd` invocation (including the
#     baseline call) would inflate the baseline right along with the real run and could still
#     widen the threshold past a genuinely slow handler. So also enforce an absolute CEILING at 3x
#     the contract's own figure (3 * 1500ms = 4500ms) as a backstop that does not scale with a
#     corrupted baseline — a handler that is genuinely, unboundedly slow blows through this
#     regardless of what the baseline measured. A run must satisfy BOTH checks to pass.
EB_SESSION_END_CONTRACT_MS=1500
EB_SESSION_END_CEILING_MS=$((EB_SESSION_END_CONTRACT_MS * 3))
# 250ms is calibrated on this seat; a slower seat with a higher idle `bd list` cost should set
# EB_SESSION_END_B_QUIET_MS in its own environment rather than edit this default.
EB_SESSION_END_B_QUIET_MS="${EB_SESSION_END_B_QUIET_MS:-250}"
EB_SESSION_END_LOAD_K="${EB_SESSION_END_LOAD_K:-3}"

eb_timing_verdict() {  # <description> <baseline_ms> <elapsed_ms>
  local desc="$1" baseline_ms="$2" elapsed_ms="$3" excess_ms threshold_ms
  excess_ms=$((baseline_ms - EB_SESSION_END_B_QUIET_MS))
  [ "$excess_ms" -lt 0 ] && excess_ms=0
  threshold_ms=$((EB_SESSION_END_CONTRACT_MS + EB_SESSION_END_LOAD_K * excess_ms))
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
# T2 (pa-jaaf): SessionEnd with no BEADS_DIR still records the `ended` marker, names BEADS_DIR on
# stderr (the old silent `exit 0` must not return), keeps stdout empty, and exits 0.
LOG_T2="$EB_SESSION_TEST_SCRATCH_ROOT/t2.tsv"; SID_T2="cccccccc-cccc-cccc-cccc-cccccccccccc"
OUT_END_NODB="$(env -u BEADS_DIR EB_SESSION_LOG="$LOG_T2" bash "$END" <<<"$(sessionend_payload "$SID_T2")" 2>"$EB_SESSION_TEST_SCRATCH_ROOT/t2.err")"; RC_T2=$?
assert_eq "T2: SessionEnd with no db writes nothing on stdout" "" "$OUT_END_NODB"
assert_rc "T2: SessionEnd with no db exits 0" 0 "$RC_T2"
assert_contains "T2: SessionEnd with no db names BEADS_DIR on stderr (not a silent exit)" \
  "$(cat "$EB_SESSION_TEST_SCRATCH_ROOT/t2.err")" "BEADS_DIR is unset or not a directory; claims not released"
assert_contains "T2: SessionEnd with no db still writes the ended marker" "$(cat "$LOG_T2")" "$SID_T2"$'\tended\t'

# --- 7. SessionEnd on a write failure: a diagnostic on stderr, and the hook STILL exits 0 -------------
# Fault injector: the scratch database is made read-only after the claim lands (restored below).
scratch7=""; eb_scratch_db scratch7
SID7="sess-1"
BEAD7="$(BEADS_ACTOR=creator bd create "write-fail test" --type task -p 2 --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
BEADS_ACTOR="$SID7" bd update "$BEAD7" --claim --json >/dev/null
chmod -R a-w "$BEADS_DIR"
ERR7="$(bash "$END" <<<"$(sessionend_payload "$SID7")" 2>&1 >/dev/null)"; RC7=$?
chmod -R u+w "$BEADS_DIR"
assert_rc "SessionEnd: exits 0 even when the release write fails" 0 "$RC7"
case "$ERR7" in
  *"permission denied"*|*"failed to open database"*) eb_ok "SessionEnd: a write failure prints the cause on stderr" ;;
  *) eb_bad "SessionEnd: a write failure prints the cause on stderr" "stderr: $ERR7" ;;
esac
assert_contains "SessionEnd: the diagnostic names the hook and the call that failed" "$ERR7" "eb-session-end: bd list failed:"
assert_eq "SessionEnd: the claim stays in_progress after the failed release" "in_progress" \
  "$(bd show --json "$BEAD7" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["status"])')"
# A list failure (database unreachable) is also reported, and also exits 0.
EMPTY7="$(mktemp -d)"
ERR7L="$(BEADS_DIR="$EMPTY7" bash "$END" <<<"$(sessionend_payload "$SID7")" 2>&1 >/dev/null)"; RC7L=$?
assert_rc "SessionEnd: exits 0 when the list fails" 0 "$RC7L"
assert_contains "SessionEnd: a list failure prints the cause on stderr" "$ERR7L" "eb-session-end: bd list failed: no beads database found"
ERR7S="$(BEADS_DIR="$EMPTY7" bash "$START" <<<"$(sessionstart_payload "$SID7")" 2>&1 >/dev/null)"; RC7S=$?
rmdir "$EMPTY7"
assert_rc "SessionStart: exits 0 when the database is unreachable" 0 "$RC7S"
assert_contains "SessionStart: an unreachable database prints the cause on stderr" "$ERR7S" "no beads database found"
rm -rf "$scratch7"

# A read-only database fails the list before any update, so the batched release (and the phase-2
# release note) are exercised through a PATH shim `bd`: the list finds the claim, every write fails
# with the per-issue envelope on stderr (the shape measured on bd 1.3.0).
SHIM7="$(mktemp -d)"
cat > "$SHIM7/bd" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  list) printf '[{"id":"x-1","assignee":"sess-1","labels":[]},{"id":"x-2","assignee":"sess-1","labels":[]}]\n' ;;
  *) printf 'Error resolving x-2: boom\n{"error":"1 of 2 issues failed to update","failed":[{"id":"x-2","error":"boom"}]}\n' >&2; exit 1 ;;
esac
EOF
chmod +x "$SHIM7/bd"
SCRATCH7B="$(mktemp -d)"
LOG7="$EB_SESSION_TEST_SCRATCH_ROOT/t7.tsv"
ERR7U="$(EB_SESSION_LOG="$LOG7" PATH="$SHIM7:$PATH" BEADS_DIR="$SCRATCH7B" bash "$END" <<<"$(sessionend_payload "sess-1")" 2>&1 >/dev/null)"; RC7U=$?
rm -rf "$SHIM7" "$SCRATCH7B"
assert_rc "SessionEnd: exits 0 when the batched release fails" 0 "$RC7U"
assert_contains "SessionEnd: the update failure names the hook and the call" "$ERR7U" "eb-session-end: bd update failed: 1 of 2 issues failed to update"
assert_contains "SessionEnd: the update failure names the failed id" "$ERR7U" "x-2: boom"
assert_contains "SessionEnd: a failed phase-2 release note is reported too" "$ERR7U" "eb-session-end: release note for"
# T7: the failure text lands in the log AND the `ended` marker is still there (failure text is
# not written in place of the marker).
assert_contains "T7: the failed release is logged with its error text" "$(cat "$LOG7")" \
  $'sess-1\tfailed\t'
assert_contains "T7: the logged failure carries the batched-update error" "$(cat "$LOG7")" \
  "1 of 2 issues failed to update"
assert_contains "T7: the ended marker is still logged next to the failure" "$(cat "$LOG7")" $'sess-1\tended\t'

# --- T1: the marker lands BEFORE any bd call or BEADS_DIR check ------------------------------------
SHIM1="$(mktemp -d)"; EMPTY1="$(mktemp -d)"; LOG_T1="$EB_SESSION_TEST_SCRATCH_ROOT/t1.tsv"
printf '#!/usr/bin/env bash\nexit 1\n' > "$SHIM1/bd"; chmod +x "$SHIM1/bd"
EB_SESSION_LOG="$LOG_T1" PATH="$SHIM1:$PATH" BEADS_DIR="$EMPTY1" bash "$END" \
  <<<"$(sessionend_payload "sid-t1")" >/dev/null 2>&1
assert_contains "T1: ended marker present although bd list fails" "$(cat "$LOG_T1")" $'sid-t1\tended\t'
rm -rf "$SHIM1" "$EMPTY1"

# --- T3..T6, T8: the start sweep reads the log (fresh scratch db; the claims are hand-made) --------
scratchT=""; eb_scratch_db scratchT
mkdir -p "$HOME/.claude/projects/fake-project"
SID_SW="77777777-7777-7777-7777-777777777777"
newbead() {  # <title> <assignee-sid> -> bead id on stdout
  local id
  id="$(BEADS_ACTOR=creator bd create "$1" --type task -p 2 --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
  BEADS_ACTOR="$2" bd update "$id" --claim --json >/dev/null
  printf '%s' "$id"
}
status_of() { bd show --json "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["status"])'; }

# T3: ended + claim held + FRESH transcript -> flagged under the ended heading, transcript ignored.
SID_T3="aaaa3333-aaaa-aaaa-aaaa-aaaaaaaaaaaa"; B_T3="$(newbead "t3" "$SID_T3")"
: > "$HOME/.claude/projects/fake-project/$SID_T3.jsonl"
LOG_T3="$EB_SESSION_TEST_SCRATCH_ROOT/t3.tsv"; printf '%s\tended\t2026-10-07T01:02:03Z\n' "$SID_T3" > "$LOG_T3"
OUT_T3="$(EB_SESSION_LOG="$LOG_T3" bash "$START" <<<"$(sessionstart_payload "$SID_SW")")"
assert_contains "T3: an ended session's claim is listed under the ended-sessions heading" "$OUT_T3" \
  "## estate-beads: claims held by ended sessions (release needed; never auto-released)"
assert_contains "T3: the Bead is listed" "$OUT_T3" "$B_T3"
assert_contains "T3: the reason says when the session ended (a fresh transcript did not hide it)" "$OUT_T3" \
  "session ended at 2026-10-07T01:02:03Z without releasing this claim"
# T8: the envelope is still one JSON object after the new section.
python3 -c 'import json,sys; json.loads(sys.argv[1])' "$OUT_T3" \
  && eb_ok "T8: output parses as JSON with the ended-sessions section" \
  || eb_bad "T8: output parses as JSON with the ended-sessions section" "got: $OUT_T3"

# T9: a non-UTF-8 byte in the log must not drop the envelope.
LOG_T9="$EB_SESSION_TEST_SCRATCH_ROOT/t9.tsv"; printf '\xff\n%s\tended\t2026-10-07T01:02:03Z\n' "$SID_T3" > "$LOG_T9"
OUT_T9="$(EB_SESSION_LOG="$LOG_T9" bash "$START" <<<"$(sessionstart_payload "$SID_SW")" 2>/dev/null)"
python3 -c 'import json,sys; json.loads(sys.argv[1])' "$OUT_T9" \
  && eb_ok "T9: a non-UTF-8 byte in the session log still yields a JSON envelope" \
  || eb_bad "T9: a non-UTF-8 byte in the session log still yields a JSON envelope" "got: $OUT_T9"

# T4: ended THEN started for the same sid (a resume) -> not flagged; last line wins.
SID_T4="bbbb4444-bbbb-bbbb-bbbb-bbbbbbbbbbbb"; B_T4="$(newbead "t4" "$SID_T4")"
: > "$HOME/.claude/projects/fake-project/$SID_T4.jsonl"
LOG_T4="$EB_SESSION_TEST_SCRATCH_ROOT/t4.tsv"
printf '%s\tended\t2026-10-07T01:00:00Z\n%s\tstarted\t2026-10-07T01:05:00Z\n' "$SID_T4" "$SID_T4" > "$LOG_T4"
OUT_T4="$(EB_SESSION_LOG="$LOG_T4" bash "$START" <<<"$(sessionstart_payload "$SID_SW")")"
python3 - "$OUT_T4" "$B_T4" <<'PYEOF'
import sys
assert sys.argv[2] not in sys.argv[1], f"a resumed session's claim must not be flagged: {sys.argv[1]}"
PYEOF
[ $? -eq 0 ] && eb_ok "T4: ended-then-started session is not flagged (last line wins)" \
             || eb_bad "T4: ended-then-started session is not flagged (last line wins)"

# T5: no marker + stale transcript -> reworded advisory, still in_progress.
SID_T5="cccc5555-cccc-cccc-cccc-cccccccccccc"; B_T5="$(newbead "t5" "$SID_T5")"
: > "$HOME/.claude/projects/fake-project/$SID_T5.jsonl"; touch -d '-7 hours' "$HOME/.claude/projects/fake-project/$SID_T5.jsonl"
OUT_T5="$(EB_SESSION_LOG="$EB_SESSION_TEST_SCRATCH_ROOT/t5-empty.tsv" bash "$START" <<<"$(sessionstart_payload "$SID_SW")")"
assert_contains "T5: no-marker advisory uses the idle-or-crashed wording" "$OUT_T5" "idle or crashed: check before releasing"
assert_contains "T5: no-marker advisory still names bead-release.sh" "$OUT_T5" "bead-release.sh"
assert_eq "T5: the Bead stays in_progress (advisory never releases)" "in_progress" "$(status_of "$B_T5")"

# T6: acceptance-pending Bead held by an ended sid -> pending advisory, never bead-release.sh.
SID_T6="dddd6666-dddd-dddd-dddd-dddddddddddd"; B_T6="$(newbead "t6" "$SID_T6")"
BEADS_ACTOR="$SID_T6" bd update "$B_T6" --append-notes "EVIDENCE: pending" --json >/dev/null
BEADS_ACTOR="$SID_T6" bd update "$B_T6" --add-label "acceptance-pending" --json >/dev/null
LOG_T6="$EB_SESSION_TEST_SCRATCH_ROOT/t6.tsv"; printf '%s\tended\t2026-10-07T01:02:03Z\n' "$SID_T6" > "$LOG_T6"
OUT_T6="$(EB_SESSION_LOG="$LOG_T6" bash "$START" <<<"$(sessionstart_payload "$SID_SW")")"
python3 - "$OUT_T6" "$B_T6" <<'PYEOF'
import json, sys
ctx = json.loads(sys.argv[1])["hookSpecificOutput"].get("additionalContext", "")
lines = [l for l in ctx.splitlines() if sys.argv[2] in l]
assert lines, f"{sys.argv[2]} missing from advisories"
for l in lines:
    assert "bead-accept.sh" in l and "bead-release.sh" not in l, l
PYEOF
[ $? -eq 0 ] && eb_ok "T6: a pending Bead held by an ended sid gets the pending advisory (bead-accept.sh, no bead-release.sh)" \
             || eb_bad "T6: a pending Bead held by an ended sid gets the pending advisory (bead-accept.sh, no bead-release.sh)"
assert_eq "T6: the pending Bead stays in_progress" "in_progress" "$(status_of "$B_T6")"

# The start hook records its own sid as started.
LOG_ST="$EB_SESSION_TEST_SCRATCH_ROOT/st.tsv"
EB_SESSION_LOG="$LOG_ST" bash "$START" <<<"$(sessionstart_payload "$SID_SW")" >/dev/null
assert_contains "SessionStart: appends a started line for its own sid" "$(cat "$LOG_ST")" "$SID_SW"$'\tstarted\t'
rm -rf "$scratchT"

rm -rf "$scratch1"
eb_report
