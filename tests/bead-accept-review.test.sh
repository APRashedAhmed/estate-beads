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

report_pending() {  # <title> <accept-mode> <model> -> prints the Bead id
  local title="$1" mode="$2" model="$3" id
  id="$(scripts/create-bead.sh --title "$title" --description d --acceptance a --project p --accept "$mode" --recognized-by x)"
  scripts/bead-claim.sh --id "$id" --model "$model" >/dev/null
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

eb_report
