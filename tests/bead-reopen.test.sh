#!/usr/bin/env bash
# bead-reopen.sh --review <report> (contract §5.5, design §13 Reopen): valid FAIL-citing-closing-PASS
# chain reopens; wrong prior, non-FAIL verdict, and a not-closed Bead are refused.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source tests/_scratch_db.sh
source tests/_assert.sh
source tests/_review_fixture.sh

eb_scratch_db scratch reopen || exit 1
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

# --- reviewer below the executor's tier is refused (MINOR-3, review pa-s2s.3-review-1) ------------
id4="$(scripts/create-bead.sh --title "ReopenTierBelow" --description d --acceptance a --project p --accept independent --recognized-by x)"
scripts/bead-claim.sh --id "$id4" --model opus >/dev/null
scripts/bead-report-success.sh --id "$id4" --evidence "initial" >/dev/null
# Close it with a reviewer that outranks the opus executor (opus is not top-tier, so a same-tier
# reviewer would itself be refused — use fable to get a clean close before exercising reopen).
pass4="$REPORTS/pass4.md"; eb_write_review "$pass4" "$id4" PASS fable fresh ""
scripts/bead-accept.sh --review "$pass4" >/dev/null
tierbelow="$REPORTS/tier-below.md"; eb_write_review "$tierbelow" "$id4" FAIL sonnet fresh "$pass4"
out="$(scripts/bead-reopen.sh --review "$tierbelow" 2>&1)"; rc=$?
assert_rc "a reviewer below the executor is refused on reopen" 1 "$rc"
bead4="$(bd show --json "$id4" 2>/dev/null | jq -c '.[0]')"
assert_eq "the refused reopen leaves the Bead closed" "closed" "$(printf '%s' "$bead4" | jq -r '.status')"

# --- a non-fresh ('spawn: fork') review is refused on reopen ---------------------------------------
notfresh="$REPORTS/not-fresh.md"; eb_write_review "$notfresh" "$id4" FAIL fable fork "$pass4"
out="$(scripts/bead-reopen.sh --review "$notfresh" 2>&1)"; rc=$?
assert_rc "a non-fresh ('spawn: fork') review is refused on reopen" 1 "$rc"
bead4b="$(bd show --json "$id4" 2>/dev/null | jq -c '.[0]')"
assert_eq "the refused non-fresh reopen leaves the Bead closed" "closed" "$(printf '%s' "$bead4b" | jq -r '.status')"

# --- codex reviewers on reopen ---------------------------------------------------------------------
# Close an opus Bead with a fable reviewer, then reopen with codex reviewers.
id5="$(scripts/create-bead.sh --title "ReopenCodex" --description d --acceptance a --project p --accept independent --recognized-by x)"
scripts/bead-claim.sh --id "$id5" --model opus >/dev/null
scripts/bead-report-success.sh --id "$id5" --evidence "initial" >/dev/null
pass5="$REPORTS/pass5.md"; eb_write_review "$pass5" "$id5" PASS fable fresh ""
scripts/bead-accept.sh --review "$pass5" >/dev/null

cxbelow="$REPORTS/codex-below.md"; eb_write_review_codex "$cxbelow" "$id5" FAIL gpt-6.1-sol low fresh "$pass5"
out="$(scripts/bead-reopen.sh --review "$cxbelow" 2>&1)"; rc=$?
assert_rc "a below-ladder codex reviewer (opus exec, point 1) is refused on reopen" 1 "$rc"
assert_eq "the refused codex reopen leaves the Bead closed" "closed" "$(bd show --json "$id5" 2>/dev/null | jq -r '.[0].status')"

cxon="$REPORTS/codex-on.md"; eb_write_review_codex "$cxon" "$id5" FAIL gpt-6-astra low fresh "$pass5"
errf="$scratch/reopen-override.err"
out="$(EB_LADDER_FILE="$ROOT/scripts/lib/verifier-ladder.json" scripts/bead-reopen.sh --review "$cxon" 2>"$errf")"; rc=$?
assert_contains "the ladder override is announced on stderr" "$(cat "$errf")" "ladder override: $ROOT/scripts/lib/verifier-ladder.json"
assert_contains "the ladder path is recorded in the reopen note" "$(bd show --json "$id5" 2>/dev/null | jq -r '.[0].notes')" "ladder override: $ROOT/scripts/lib/verifier-ladder.json"
assert_rc "an on-ladder codex reviewer (opus exec, astra@low) reopens" 0 "$rc"
assert_eq "the on-ladder codex reopen prints REOPENED" "REOPENED" "$out"
assert_eq "the on-ladder codex reopen returns the Bead to open" "open" "$(bd show --json "$id5" 2>/dev/null | jq -r '.[0].status')"

eb_report
