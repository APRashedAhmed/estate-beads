#!/usr/bin/env bash
# bead-report-success.sh: accept:evidence closes as today; accept:operator unchanged; accept:
# independent's message changes to "ACCEPTANCE-PENDING review" (design §13, plan U2 item 6).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source tests/_scratch_db.sh
source tests/_assert.sh

eb_scratch_db scratch report-success || exit 1
trap 'rm -rf "$scratch"' EXIT
export BEADS_ACTOR=actor1

ev="$(scripts/create-bead.sh --title "Evidence" --description d --acceptance a --project p --accept evidence --recognized-by x)"
scripts/bead-claim.sh --id "$ev" --model sonnet >/dev/null
out="$(scripts/bead-report-success.sh --id "$ev" --evidence "tests pass")"
assert_eq "accept:evidence still closes on its own report" "CLOSED" "$out"
notes="$(bd show --json "$ev" 2>/dev/null | jq -r '.[0].notes')"
assert_eq "accept:evidence CLOSED leaves IN-PROGRESS: none, no stale value" \
  "IN-PROGRESS: none" "$(printf '%s\n' "$notes" | grep '^IN-PROGRESS: ')"
assert_eq "accept:evidence CLOSED leaves NEXT: none — closed, no stale value" \
  "NEXT: none — closed" "$(printf '%s\n' "$notes" | grep '^NEXT: ')"

op="$(scripts/create-bead.sh --title "Operator" --description d --acceptance a --project p --accept operator --recognized-by x)"
scripts/bead-claim.sh --id "$op" --model sonnet >/dev/null
out="$(scripts/bead-report-success.sh --id "$op" --evidence "tests pass")"
assert_eq "accept:operator's message matches the contract token" "ACCEPTANCE-PENDING operator" "$out"
notes="$(bd show --json "$op" 2>/dev/null | jq -r '.[0].notes')"
assert_contains "accept:operator sets IN-PROGRESS: none — awaiting acceptance" "$notes" "IN-PROGRESS: none — awaiting acceptance"
assert_contains "accept:operator NEXT names the operator-accept command" "$notes" "NEXT: acceptance — operator accepts with bead-accept.sh --id $op --evidence <path> --operator"

ind="$(scripts/create-bead.sh --title "Independent" --description d --acceptance a --project p --accept independent --recognized-by x)"
scripts/bead-claim.sh --id "$ind" --model sonnet >/dev/null
out="$(scripts/bead-report-success.sh --id "$ind" --evidence "tests pass")"
assert_eq "accept:independent now prints ACCEPTANCE-PENDING review" "ACCEPTANCE-PENDING review" "$out"
notes="$(bd show --json "$ind" 2>/dev/null | jq -r '.[0].notes')"
assert_contains "accept:independent sets IN-PROGRESS: none — awaiting acceptance" "$notes" "IN-PROGRESS: none — awaiting acceptance"
assert_contains "accept:independent NEXT names the review-then-accept path" "$notes" "NEXT: acceptance — dispatch a fresh review (references/review-brief.md), then bead-accept.sh --review <report>"

# --- the intended whole-block rewrite never leaks bd's generic --notes-replaced warning ----------
errf="$scratch/report-success-warning.err"
warn="$(scripts/create-bead.sh --title "WarningSuppressed" --description d --acceptance a --project p --accept independent --recognized-by x)"
scripts/bead-claim.sh --id "$warn" --model sonnet >/dev/null
scripts/bead-progress.sh --id "$warn" --completed "step1" --in-progress "working" --next "keep going" >/dev/null
scripts/bead-report-success.sh --id "$warn" --evidence "tests pass" >"$scratch/report-success-warning.out" 2>"$errf"
assert_eq "report-success's whole-block rewrite prints no bd --notes-replaced warning" \
  "0" "$(grep -c -- '--notes replaced' "$errf" || true)"

eb_report
