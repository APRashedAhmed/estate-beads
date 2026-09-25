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

# --- 5. SessionEnd timing: one direct stdin feed with one claimed Bead completes < 1s ----------
BEAD5_JSON="$(BEADS_ACTOR=creator bd create "timing test" --type task -p 2 --json)"
BEAD5_ID="$(printf '%s' "$BEAD5_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
SID_TIMING="99999999-9999-9999-9999-999999999999"
BEADS_ACTOR="$SID_TIMING" bd update "$BEAD5_ID" --claim --json >/dev/null
T0=$(date +%s%N)
bash "$END" <<<"$(sessionend_payload "$SID_TIMING")" >/dev/null
T1=$(date +%s%N)
ELAPSED_NS=$((T1 - T0))
ELAPSED_MS=$((ELAPSED_NS / 1000000))
if [ "$ELAPSED_NS" -lt 1000000000 ]; then
  eb_ok "SessionEnd: completes within 1s on a scratch db (${ELAPSED_MS}ms)"
else
  eb_bad "SessionEnd: completes within 1s on a scratch db" "took ${ELAPSED_MS}ms"
fi

# --- 5b. SessionEnd budget (fix round 1, F4): THREE claimed Beads release concurrently, all
#         become open+unassigned, and total wall time stays under Claude's shared ~1.5s SessionEnd
#         budget (portability-contract.md §5.5/§269) ----------------------------------------------
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

T0=$(date +%s%N)
bash "$END" <<<"$(sessionend_payload "$SID_MULTI")" >/dev/null
T1=$(date +%s%N)
ELAPSED3_NS=$((T1 - T0))
ELAPSED3_MS=$((ELAPSED3_NS / 1000000))

for bid in "$BEAD6_ID" "$BEAD7_ID" "$BEAD8_ID"; do
  st="$(bd show --json "$bid" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["status"])')"
  asn="$(bd show --json "$bid" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0].get("assignee") or "")')"
  assert_eq "SessionEnd (3 claims): $bid is released (status open)" "open" "$st"
  assert_eq "SessionEnd (3 claims): $bid is unassigned" "" "$asn"
done

if [ "$ELAPSED3_NS" -lt 1500000000 ]; then
  eb_ok "SessionEnd: 3 concurrent claims release within 1.5s on a scratch db (${ELAPSED3_MS}ms)"
else
  eb_bad "SessionEnd: 3 concurrent claims release within 1.5s on a scratch db" "took ${ELAPSED3_MS}ms"
fi

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
