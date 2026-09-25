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

op="$(scripts/create-bead.sh --title "Operator" --description d --acceptance a --project p --accept operator --recognized-by x)"
scripts/bead-claim.sh --id "$op" --model sonnet >/dev/null
out="$(scripts/bead-report-success.sh --id "$op" --evidence "tests pass")"
assert_eq "accept:operator's message matches the contract token" "ACCEPTANCE-PENDING operator" "$out"

ind="$(scripts/create-bead.sh --title "Independent" --description d --acceptance a --project p --accept independent --recognized-by x)"
scripts/bead-claim.sh --id "$ind" --model sonnet >/dev/null
out="$(scripts/bead-report-success.sh --id "$ind" --evidence "tests pass")"
assert_eq "accept:independent now prints ACCEPTANCE-PENDING review" "ACCEPTANCE-PENDING review" "$out"

eb_report
