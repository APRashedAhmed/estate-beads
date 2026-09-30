#!/usr/bin/env bash
# bead-accept.sh --review <report> (design §13, full table): PASS on each accept: mode, FAIL
# decrement, FAIL to zero -> halt:budget, INCOMPLETE (plain / coverage / reshape / bounds-not-set),
# tier refusal (below, same non-top, top-tier same-tier accepted), spawn-not-fresh refusal, bead
# mismatch refusal, not-acceptance-pending refusal, missing executor.model refusal, legacy-bead
# budget-default materialization on FAIL.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source tests/_scratch_db.sh
source tests/_assert.sh
source tests/_review_fixture.sh

eb_scratch_db scratch accept-review || exit 1
trap 'rm -rf "$scratch"' EXIT
export BEADS_ACTOR=actor1
REPORTS="$scratch/reports"; mkdir -p "$REPORTS"

report_pending() {  # <title> <accept-mode> <model> [effort] -> prints the Bead id
  local title="$1" mode="$2" model="$3" effort="${4:-}" id
  id="$(scripts/create-bead.sh --title "$title" --description d --acceptance a --project p --accept "$mode" --recognized-by x)"
  scripts/bead-claim.sh --id "$id" --model "$model" ${effort:+--effort "$effort"} >/dev/null
  if [[ "$mode" == "evidence" ]]; then
    # accept:evidence closes itself inside bead-report-success.sh — put it into
    # acceptance-pending directly so a review verdict has something to close.
    bd update "$id" --append-notes "EVIDENCE: initial report" >/dev/null
    bd update "$id" --add-label "acceptance-pending" >/dev/null
  else
    scripts/bead-report-success.sh --id "$id" --evidence "initial report" >/dev/null
  fi
  printf '%s' "$id"
}

# --- PASS on each accept: mode -------------------------------------------------------------------
for mode in evidence independent operator; do
  id="$(report_pending "Pass-$mode" "$mode" sonnet)"
  r="$REPORTS/pass-$mode.md"; eb_write_review "$r" "$id" PASS opus fresh ""
  out="$(scripts/bead-accept.sh --review "$r")"; rc=$?
  assert_rc "PASS review exits 0 ($mode)" 0 "$rc"
  bead="$(bd show --json "$id" 2>/dev/null | jq -c '.[0]')"
  if [[ "$mode" == "operator" ]]; then
    assert_eq "PASS on accept:operator prints ACCEPTANCE-PENDING operator" "ACCEPTANCE-PENDING operator" "$out"
    assert_eq "accept:operator stays acceptance-pending" "in_progress" "$(printf '%s' "$bead" | jq -r '.status')"
  else
    assert_eq "PASS closes ($mode)" "CLOSED" "$out"
    assert_eq "status closed ($mode)" "closed" "$(printf '%s' "$bead" | jq -r '.status')"
    assert_contains "close_reason is 'accepted <report path>' ($mode)" "$(printf '%s' "$bead" | jq -r '.close_reason')" "accepted $r"
  fi
done

# --- FAIL decrements budget.cycles; FAIL to zero halts --------------------------------------------
id="$(report_pending "FailTwice" independent sonnet)"
r1="$REPORTS/fail1.md"; eb_write_review "$r1" "$id" FAIL opus fresh ""
out="$(scripts/bead-accept.sh --review "$r1")"
assert_eq "first FAIL prints FAILED 1 (default budget cycles=2)" "FAILED 1" "$out"
bead="$(bd show --json "$id" 2>/dev/null | jq -c '.[0]')"
assert_eq "status returns to in_progress after FAIL" "in_progress" "$(printf '%s' "$bead" | jq -r '.status')"
assert_contains "NEXT is rewritten to the findings path" "$(printf '%s' "$bead" | jq -r '.notes')" "NEXT: $r1"

scripts/bead-claim.sh --id "$id" --model sonnet >/dev/null
scripts/bead-report-success.sh --id "$id" --evidence "second attempt" >/dev/null
r2="$REPORTS/fail2.md"; eb_write_review "$r2" "$id" FAIL opus fresh ""
out="$(scripts/bead-accept.sh --review "$r2")"
assert_eq "second FAIL at zero prints HALTED" "HALTED" "$out"
bead="$(bd show --json "$id" 2>/dev/null | jq -c '.[0]')"
assert_eq "HALTED releases the claim (status open)" "open" "$(printf '%s' "$bead" | jq -r '.status')"
assert_eq "HALTED clears the assignee" "null" "$(printf '%s' "$bead" | jq -c '.assignee')"
assert_contains "HALTED adds label halt:budget" "$(printf '%s' "$bead" | jq -c '.labels')" "halt:budget"

# --- FAIL/HALT preserve COMPLETED and other pre-existing block lines (not just NEXT) --------------
id="$(scripts/create-bead.sh --title "PreserveOnFail" --description d --acceptance a --project p --accept independent --recognized-by x)"
bd update "$id" --metadata '{"workunit":"'"$scratch"'"}' >/dev/null
scripts/bead-claim.sh --id "$id" --model sonnet >/dev/null
scripts/bead-progress.sh --id "$id" --completed "step1 done" --in-progress "working" --next "keep going" >/dev/null
scripts/bead-report-success.sh --id "$id" --evidence "initial report" >/dev/null
rp1="$REPORTS/preserve-fail1.md"; eb_write_review "$rp1" "$id" FAIL opus fresh ""
scripts/bead-accept.sh --review "$rp1" >/dev/null
notes="$(bd show --json "$id" 2>/dev/null | jq -r '.[0].notes')"
assert_contains "FAIL preserves the prior COMPLETED line" "$notes" "COMPLETED: step1 done"
assert_contains "FAIL preserves the workunit line" "$notes" "workunit: $scratch"
assert_contains "FAIL preserves the EVIDENCE line (not just COMPLETED/workunit)" "$notes" "EVIDENCE: initial report"

scripts/bead-claim.sh --id "$id" --model sonnet >/dev/null
scripts/bead-report-success.sh --id "$id" --evidence "second attempt" >/dev/null
rp2="$REPORTS/preserve-fail2.md"; eb_write_review "$rp2" "$id" FAIL opus fresh ""
out="$(scripts/bead-accept.sh --review "$rp2")"
assert_eq "second preserve-FAIL at zero prints HALTED" "HALTED" "$out"
notes="$(bd show --json "$id" 2>/dev/null | jq -r '.[0].notes')"
assert_contains "HALT preserves the original COMPLETED line" "$notes" "COMPLETED: step1 done"
assert_contains "HALT preserves the workunit line" "$notes" "workunit: $scratch"

# --- legacy Bead (no budget metadata) FAIL materializes the default, then decrements --------------
legacy="$(bd create "LegacyFail" --type task --description d --acceptance a \
  --labels "project:p,accept:independent,class:bounded-increment" --metadata '{"recognized-by":"x"}' --json 2>/dev/null | jq -r .id)"
scripts/bead-claim.sh --id "$legacy" --model sonnet >/dev/null
scripts/bead-report-success.sh --id "$legacy" --evidence "x" >/dev/null
rl="$REPORTS/legacy-fail.md"; eb_write_review "$rl" "$legacy" FAIL opus fresh ""
out="$(scripts/bead-accept.sh --review "$rl" 2>"$scratch/legacy-stderr.txt")"
assert_eq "legacy Bead FAIL materializes default then decrements to 1" "FAILED 1" "$out"
assert_contains "a stderr note names the materialized default" "$(cat "$scratch/legacy-stderr.txt")" "materializing the default"

# --- INCOMPLETE: plain, coverage (no closer effect beyond plain), reshape, bounds-not-set ---------
for tag in "" coverage; do
  id="$(report_pending "Incomplete-${tag:-plain}" independent sonnet)"
  r="$REPORTS/incomplete-${tag:-plain}.md"; eb_write_review "$r" "$id" INCOMPLETE opus fresh "" "$tag"
  out="$(scripts/bead-accept.sh --review "$r")"
  assert_eq "INCOMPLETE (${tag:-plain}) prints INCOMPLETE, no change" "INCOMPLETE" "$out"
  bead="$(bd show --json "$id" 2>/dev/null | jq -c '.[0]')"
  assert_eq "status is still in_progress (${tag:-plain})" "in_progress" "$(printf '%s' "$bead" | jq -r '.status')"
done

for reason in reshape bounds-not-set; do
  id="$(report_pending "Halt-$reason" independent sonnet)"
  r="$REPORTS/halt-$reason.md"; eb_write_review "$r" "$id" INCOMPLETE opus fresh "" "$reason"
  out="$(scripts/bead-accept.sh --review "$r")"
  assert_eq "INCOMPLETE reason:$reason prints HALTED $reason" "HALTED $reason" "$out"
  bead="$(bd show --json "$id" 2>/dev/null | jq -c '.[0]')"
  assert_eq "status open ($reason)" "open" "$(printf '%s' "$bead" | jq -r '.status')"
  assert_contains "label halt:$reason added" "$(printf '%s' "$bead" | jq -c '.labels')" "halt:$reason"
done

# --- tier refusals ---------------------------------------------------------------------------------
id="$(report_pending "TierBelow" independent opus)"
r="$REPORTS/tier-below.md"; eb_write_review "$r" "$id" PASS sonnet fresh ""
out="$(scripts/bead-accept.sh --review "$r" 2>&1)"; rc=$?
assert_rc "a reviewer below the executor is refused" 1 "$rc"

id="$(report_pending "TierSame" independent sonnet)"
r="$REPORTS/tier-same.md"; eb_write_review "$r" "$id" PASS sonnet fresh ""
out="$(scripts/bead-accept.sh --review "$r" 2>&1)"; rc=$?
assert_rc "same-tier reviewer is refused when the executor is NOT top tier" 1 "$rc"

id="$(report_pending "TierTop" independent fable)"
r="$REPORTS/tier-top.md"; eb_write_review "$r" "$id" PASS fable fresh ""
out="$(scripts/bead-accept.sh --review "$r")"; rc=$?
assert_rc "same-tier reviewer IS accepted when the executor is top-tier (fable)" 0 "$rc"
assert_eq "top-tier same-tier PASS closes" "CLOSED" "$out"

# --- spawn not fresh refused -----------------------------------------------------------------------
id="$(report_pending "NotFresh" independent sonnet)"
r="$REPORTS/not-fresh.md"; eb_write_review "$r" "$id" PASS opus forked ""
out="$(scripts/bead-accept.sh --review "$r" 2>&1)"; rc=$?
assert_rc "a non-fresh spawn is refused" 1 "$rc"

# --- bead mismatch (nonexistent id) refused ---------------------------------------------------------
r="$REPORTS/bad-bead.md"; eb_write_review "$r" "no-such-bead-id" PASS opus fresh ""
out="$(scripts/bead-accept.sh --review "$r" 2>&1)"; rc=$?
assert_rc "a review naming a nonexistent Bead is refused" 1 "$rc"

# --- not acceptance-pending refused ------------------------------------------------------------------
id="$(scripts/create-bead.sh --title "NeverReported" --description d --acceptance a --project p --accept independent --recognized-by x)"
r="$REPORTS/never-reported.md"; eb_write_review "$r" "$id" PASS opus fresh ""
out="$(scripts/bead-accept.sh --review "$r" 2>&1)"; rc=$?
assert_rc "a Bead never put acceptance-pending is refused" 1 "$rc"

# --- missing executor.model refused -------------------------------------------------------------
id="$(bd create "NoExecutor" --type task --description d --acceptance a \
  --labels "project:p,accept:independent,class:bounded-increment" --metadata '{"recognized-by":"x","budget":{"cycles":2}}' --json 2>/dev/null | jq -r .id)"
bd update "$id" --claim >/dev/null
bd update "$id" --append-notes "EVIDENCE: manual" >/dev/null
bd update "$id" --add-label "acceptance-pending" >/dev/null
r="$REPORTS/no-executor.md"; eb_write_review "$r" "$id" PASS opus fresh ""
out="$(scripts/bead-accept.sh --review "$r" 2>&1)"; rc=$?
assert_rc "a Bead claimed off-script with no executor.model is refused" 1 "$rc"
assert_contains "the refusal names the metadata remedy" "$out" "executor"

# --- evidence chain: PASS with a re-review through prior lists both reports -----------------------
id="$(report_pending "Chained" independent sonnet)"
r1="$REPORTS/chain1.md"; eb_write_review "$r1" "$id" INCOMPLETE opus fresh ""
scripts/bead-accept.sh --review "$r1" >/dev/null
r2="$REPORTS/chain2.md"; eb_write_review "$r2" "$id" PASS opus fresh "$r1"
scripts/bead-accept.sh --review "$r2" >/dev/null
notes="$(bd show --json "$id" 2>/dev/null | jq -r '.[0].notes')"
assert_contains "evidence lists the prior report" "$notes" "$r1"
assert_contains "evidence lists the closing report" "$notes" "$r2"

# --- atomic close: an open blocker refuses a PASS before any mutation ------------------------------
blocker="$(scripts/create-bead.sh --title "RevBlocker" --description d --acceptance a --project p --accept evidence --recognized-by x)"
blocked="$(report_pending "RevBlocked" independent sonnet)"
bd dep "$blocker" --blocks "$blocked" >/dev/null
before_bead="$(bd show --json "$blocked" 2>/dev/null | jq -c '.[0]')"
r="$REPORTS/blocked.md"; eb_write_review "$r" "$blocked" PASS opus fresh ""
out="$(scripts/bead-accept.sh --review "$r")"; rc=$?
assert_eq "open blocker prints BLOCKED-BY on a PASS review" "BLOCKED-BY $blocker" "$out"
assert_rc "open blocker exits 1 on a PASS review" 1 "$rc"
after_bead="$(bd show --json "$blocked" 2>/dev/null | jq -c '.[0]')"
assert_eq "label/status/notes unchanged when blocked (review)" \
  "$(printf '%s' "$before_bead" | jq -c '{status, labels, notes}')" \
  "$(printf '%s' "$after_bead" | jq -c '{status, labels, notes}')"

bd close "$blocker" --reason "unblock" >/dev/null
out="$(scripts/bead-accept.sh --review "$r")"; rc=$?
assert_eq "closes once the blocker is closed (review)" "CLOSED" "$out"
assert_rc "exits 0 once unblocked (review)" 0 "$rc"

# --- M1 (review pa-s2s.8-review-1): close from a DIFFERENT actor than the claimant, both
#     accept: modes that close through the --review form -------------------------------------
for mode in evidence independent; do
  export BEADS_ACTOR=claimant-actor
  id="$(report_pending "CrossActor-$mode" "$mode" sonnet)"
  r="$REPORTS/cross-actor-$mode.md"; eb_write_review "$r" "$id" PASS opus fresh ""
  export BEADS_ACTOR=closer-actor
  out="$(scripts/bead-accept.sh --review "$r")"; rc=$?
  assert_eq "closes as a different actor than the claimant ($mode)" "CLOSED" "$out"
  assert_rc "exits 0 as a different actor ($mode)" 0 "$rc"
  bead="$(bd show --json "$id" 2>/dev/null | jq -c '.[0]')"
  assert_eq "status is closed (cross-actor, $mode)" "closed" "$(printf '%s' "$bead" | jq -r '.status')"
  assert_eq "assignee stays the original claimant ($mode)" \
    "claimant-actor" "$(printf '%s' "$bead" | jq -r '.assignee')"
  assert_contains "notes record who closed it ($mode)" "$(printf '%s' "$bead" | jq -r '.notes')" "closed by closer-actor"
done
export BEADS_ACTOR=actor1

# --- codex reviewers on the verifier ladder ---------------------------------------------------------
id="$(report_pending "CodexOnLadder" independent sonnet low)"
r="$REPORTS/codex-pass.md"; eb_write_review_codex "$r" "$id" PASS gpt-6-sol high fresh ""
out="$(scripts/bead-accept.sh --review "$r")"; rc=$?
assert_rc "on-ladder codex PASS exits 0" 0 "$rc"
assert_eq "on-ladder codex PASS closes" "CLOSED" "$out"
assert_eq "on-ladder codex PASS: status closed" "closed" "$(bd show --json "$id" 2>/dev/null | jq -r '.[0].status')"

id="$(report_pending "CodexBelow" independent opus)"
r="$REPORTS/codex-below.md"; eb_write_review_codex "$r" "$id" PASS gpt-6-sol high fresh ""
out="$(scripts/bead-accept.sh --review "$r" 2>&1)"; rc=$?
assert_rc "below-ladder codex (opus exec, point 1) is refused" 1 "$rc"
bead="$(bd show --json "$id" 2>/dev/null | jq -c '.[0]')"
assert_eq "below-ladder refusal leaves the Bead in_progress" "in_progress" "$(printf '%s' "$bead" | jq -r '.status')"
assert_contains "below-ladder refusal leaves it acceptance-pending" "$(printf '%s' "$bead" | jq -c '.labels')" "acceptance-pending"

id="$(report_pending "CodexUnknown" independent sonnet)"
r="$REPORTS/codex-unknown.md"; eb_write_review_codex "$r" "$id" PASS gpt-9-nova high fresh ""
out="$(scripts/bead-accept.sh --review "$r" 2>&1)"; rc=$?
assert_rc "unknown codex model is refused" 1 "$rc"
assert_contains "unknown codex refusal names the ladder" "$out" "not on the codex verifier ladder"

id="$(report_pending "CodexOperator" operator sonnet low)"
r="$REPORTS/codex-operator.md"; eb_write_review_codex "$r" "$id" PASS gpt-6-sol high fresh ""
out="$(scripts/bead-accept.sh --review "$r")"; rc=$?
assert_rc "codex PASS on accept:operator exits 0" 0 "$rc"
assert_eq "codex PASS on accept:operator prints ACCEPTANCE-PENDING operator" "ACCEPTANCE-PENDING operator" "$out"
assert_eq "codex PASS on accept:operator stays in_progress" "in_progress" "$(bd show --json "$id" 2>/dev/null | jq -r '.[0].status')"

id="$(report_pending "CodexFail" independent sonnet low)"
r="$REPORTS/codex-fail.md"; eb_write_review_codex "$r" "$id" FAIL gpt-6-sol high fresh ""
out="$(scripts/bead-accept.sh --review "$r")"; rc=$?
assert_eq "codex FAIL decrements budget (default cycles 2 -> FAILED 1)" "FAILED 1" "$out"
assert_eq "codex FAIL leaves the Bead in_progress" "in_progress" "$(bd show --json "$id" 2>/dev/null | jq -r '.[0].status')"

# executor effort recorded at claim moves the row: sonnet/high needs point 2, so point 1 is refused
id="$(report_pending "CodexEffortRow" independent sonnet high)"
assert_eq "claim recorded executor.effort high" "high" "$(bd show --json "$id" 2>/dev/null | jq -r '.[0].metadata.executor.effort')"
r="$REPORTS/codex-effort-row.md"; eb_write_review_codex "$r" "$id" PASS gpt-6-sol high fresh ""
out="$(scripts/bead-accept.sh --review "$r" 2>&1)"; rc=$?
assert_rc "sonnet/high executor row 2 refuses codex point 1" 1 "$rc"

# --- EB_LADDER_FILE override is visible (review pa-ym1-u2-check-1 MINOR-1) ---------------------------
id="$(report_pending "LadderOverride" independent sonnet low)"
r="$REPORTS/ladder-override.md"; eb_write_review "$r" "$id" PASS opus fresh ""
errf="$scratch/ladder-override.err"
out="$(EB_LADDER_FILE="$ROOT/scripts/lib/verifier-ladder.json" scripts/bead-accept.sh --review "$r" 2>"$errf")"; rc=$?
assert_rc "an accept under EB_LADDER_FILE succeeds" 0 "$rc"
assert_contains "the override is announced on stderr" "$(cat "$errf")" "ladder override: $ROOT/scripts/lib/verifier-ladder.json"
assert_contains "the ladder path is recorded in the EVIDENCE line" "$(bd show --json "$id" 2>/dev/null | jq -r '.[0].notes')" "ladder override: $ROOT/scripts/lib/verifier-ladder.json"

# --- NIT-1 (pa-tdf): the ladder override is also recorded on FAIL and halt notes ----------------------
LADDER="$ROOT/scripts/lib/verifier-ladder.json"
notes_of() { bd show --json "$1" 2>/dev/null | jq -r '.[0].notes'; }
inprog_fail() {  # <title> <ladder-file-or-empty> <cycles-left: 2|1> -> prints the Bead id after a FAIL verdict
  local fid fr
  fid="$(report_pending "$1" independent sonnet low)"
  [[ "$3" == 1 ]] && bd update "$fid" --metadata '{"budget":{"cycles":1}}' >/dev/null
  fr="$REPORTS/nit1-$fid.md"; eb_write_review "$fr" "$fid" FAIL opus fresh ""
  if [[ -n "$2" ]]; then EB_LADDER_FILE="$2" scripts/bead-accept.sh --review "$fr" >/dev/null 2>&1
  else scripts/bead-accept.sh --review "$fr" >/dev/null 2>&1; fi
  printf '%s' "$fid"
}
fid="$(inprog_fail "LadderFailCont" "$LADDER" 2)"
assert_contains "FAIL with cycles left records the ladder override in notes" "$(notes_of "$fid")" "ladder override: $LADDER"
fid="$(inprog_fail "LadderFailHalt" "$LADDER" 1)"
assert_contains "the halting FAIL is a halt" "$(bd show --json "$fid" 2>/dev/null | jq -c '.[0].labels')" "halt:budget"
assert_contains "FAIL that halts records the ladder override in notes" "$(notes_of "$fid")" "ladder override: $LADDER"
fid="$(inprog_fail "NoLadderFailCont" "" 2)"
assert_eq "FAIL with cycles left, no override: notes carry none" "0" "$(notes_of "$fid" | grep -c "ladder override:")"
fid="$(inprog_fail "NoLadderFailHalt" "" 1)"
assert_eq "FAIL that halts, no override: notes carry none" "0" "$(notes_of "$fid" | grep -c "ladder override:")"

eb_report
