#!/usr/bin/env bash
# bead-reopen.sh --review <report> (contract §5.5, design §13 Reopen): valid FAIL-citing-closing-PASS
# chain reopens; wrong prior, non-FAIL verdict, and a not-closed Bead are refused.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source tests/_scratch_db.sh
source tests/_assert.sh
source tests/_review_fixture.sh

eb_scratch_db scratch reopen
trap 'rm -rf "$scratch"' EXIT
export BEADS_ACTOR=actor1
REPORTS="$scratch/reports"; mkdir -p "$REPORTS"

id="$(scripts/create-bead.sh --title "ReopenMe" --description d --acceptance a --project p --accept independent --recognized-by x)"
scripts/bead-claim.sh --id "$id" --model sonnet >/dev/null
scripts/bead-report-success.sh --id "$id" --evidence "initial" >/dev/null
pass="$REPORTS/pass.md"; eb_write_review "$pass" "$id" PASS opus fresh ""
scripts/bead-accept.sh --review "$pass" >/dev/null

# --- valid chain: FAIL review citing the closing PASS report reopens -----------------------------
fail="$REPORTS/fail.md"; eb_write_review "$fail" "$id" FAIL opus fresh "$pass"
out="$(scripts/bead-reopen.sh --review "$fail")"; rc=$?
assert_eq "a valid FAIL-citing-PASS chain prints REOPENED" "REOPENED" "$out"
assert_rc "exits 0" 0 "$rc"
bead="$(bd show --json "$id" 2>/dev/null | jq -c '.[0]')"
assert_eq "status returns to open" "open" "$(printf '%s' "$bead" | jq -r '.status')"
assert_contains "NEXT is the FAIL report path" "$(printf '%s' "$bead" | jq -r '.notes')" "NEXT: $fail"

# --- a PASS verdict never reopens -----------------------------------------------------------------
id2="$(scripts/create-bead.sh --title "ReopenPassRefused" --description d --acceptance a --project p --accept independent --recognized-by x)"
scripts/bead-claim.sh --id "$id2" --model sonnet >/dev/null
scripts/bead-report-success.sh --id "$id2" --evidence "initial" >/dev/null
pass2="$REPORTS/pass2.md"; eb_write_review "$pass2" "$id2" PASS opus fresh ""
scripts/bead-accept.sh --review "$pass2" >/dev/null
badverdict="$REPORTS/pass-as-reopen.md"; eb_write_review "$badverdict" "$id2" PASS opus fresh "$pass2"
out="$(scripts/bead-reopen.sh --review "$badverdict" 2>&1)"; rc=$?
assert_rc "a PASS verdict is refused for reopen" 1 "$rc"

# --- wrong prior (does not cite the actual closing report) refused --------------------------------
wrongprior="$REPORTS/wrong-prior.md"; eb_write_review "$wrongprior" "$id2" FAIL opus fresh "/nonexistent/report.md"
out="$(scripts/bead-reopen.sh --review "$wrongprior" 2>&1)"; rc=$?
assert_rc "a prior that does not match close_reason's report is refused" 1 "$rc"

# --- not-closed Bead refused -----------------------------------------------------------------------
id3="$(scripts/create-bead.sh --title "NotClosed" --description d --acceptance a --project p --accept independent --recognized-by x)"
notclosed="$REPORTS/not-closed.md"; eb_write_review "$notclosed" "$id3" FAIL opus fresh "$pass"
out="$(scripts/bead-reopen.sh --review "$notclosed" 2>&1)"; rc=$?
assert_rc "reopen refuses a Bead that is not closed" 1 "$rc"

eb_report
