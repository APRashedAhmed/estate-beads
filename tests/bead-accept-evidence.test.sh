#!/usr/bin/env bash
# bead-accept.sh --id --evidence <path> (design §11.4): requires acceptance-pending, sets
# close_reason, closes — exercised on each accept: mode (the form itself does not gate on mode).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source tests/_scratch_db.sh
source tests/_assert.sh

eb_scratch_db scratch accept-evidence || exit 1
trap 'rm -rf "$scratch"' EXIT
export BEADS_ACTOR=actor1

for mode in evidence independent operator; do
  id="$(scripts/create-bead.sh --title "Evi-$mode" --description d --acceptance a --project p --accept "$mode" --recognized-by x)"
  scripts/bead-claim.sh --id "$id" --model sonnet >/dev/null
  if [[ "$mode" == "evidence" ]]; then
    # accept:evidence closes itself inside bead-report-success.sh — put it into
    # acceptance-pending directly to exercise bead-accept.sh --evidence as its own path.
    bd update "$id" --append-notes "EVIDENCE: initial report" >/dev/null
    bd update "$id" --add-label "acceptance-pending" >/dev/null
  else
    scripts/bead-report-success.sh --id "$id" --evidence "initial report" >/dev/null
  fi
  out="$(scripts/bead-accept.sh --id "$id" --evidence "$scratch/evidence-$mode.txt")"; rc=$?
  assert_eq "bead-accept --evidence closes an acceptance-pending Bead ($mode)" "CLOSED" "$out"
  assert_rc "exits 0 ($mode)" 0 "$rc"
  bead="$(bd show --json "$id" 2>/dev/null | jq -c '.[0]')"
  assert_eq "status is closed ($mode)" "closed" "$(printf '%s' "$bead" | jq -r '.status')"
  assert_contains "close_reason starts with 'accepted ' ($mode)" "$(printf '%s' "$bead" | jq -r '.close_reason')" "accepted $scratch/evidence-$mode.txt"
  labels="$(printf '%s' "$bead" | jq -c '.labels')"
  assert_ne "acceptance-pending was removed on close ($mode)" '["accept:'"$mode"'","acceptance-pending","class:bounded-increment","project:p"]' "$labels"
done

# --- refuses when not acceptance-pending ---------------------------------------------------------
notpending="$(scripts/create-bead.sh --title "NotPending" --description d --acceptance a --project p --accept evidence --recognized-by x)"
out="$(scripts/bead-accept.sh --id "$notpending" --evidence "$scratch/no.txt" 2>&1)"; rc=$?
assert_rc "refuses a Bead that is not acceptance-pending" 1 "$rc"

# --- atomic close: an open blocker refuses before any mutation -------------------------------
blocker="$(scripts/create-bead.sh --title "Blocker" --description d --acceptance a --project p --accept evidence --recognized-by x)"
blocked="$(scripts/create-bead.sh --title "Blocked" --description d --acceptance a --project p --accept evidence --recognized-by x)"
bd dep "$blocker" --blocks "$blocked" >/dev/null
scripts/bead-claim.sh --id "$blocked" --model sonnet >/dev/null
bd update "$blocked" --append-notes "EVIDENCE: initial report" >/dev/null
bd update "$blocked" --add-label "acceptance-pending" >/dev/null
before_bead="$(bd show --json "$blocked" 2>/dev/null | jq -c '.[0]')"
out="$(scripts/bead-accept.sh --id "$blocked" --evidence "$scratch/blocked.txt")"; rc=$?
assert_eq "open blocker prints BLOCKED-BY" "BLOCKED-BY $blocker" "$out"
assert_rc "open blocker exits 1" 1 "$rc"
after_bead="$(bd show --json "$blocked" 2>/dev/null | jq -c '.[0]')"
assert_eq "label/status/notes unchanged when blocked" \
  "$(printf '%s' "$before_bead" | jq -c '{status, labels, notes}')" \
  "$(printf '%s' "$after_bead" | jq -c '{status, labels, notes}')"

bd close "$blocker" --reason "unblock" >/dev/null
out="$(scripts/bead-accept.sh --id "$blocked" --evidence "$scratch/blocked.txt")"; rc=$?
assert_eq "closes once the blocker is closed" "CLOSED" "$out"
assert_rc "exits 0 once unblocked" 0 "$rc"

eb_report
