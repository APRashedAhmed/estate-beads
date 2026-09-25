#!/usr/bin/env bash
# bead-release.sh --id --note (rules 7/10): return to open, unassign, record via bead-progress.sh.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source tests/_scratch_db.sh
source tests/_assert.sh

eb_scratch_db scratch bead-release
trap 'rm -rf "$scratch"' EXIT
export BEADS_ACTOR=actor1

id="$(scripts/create-bead.sh --title "Releasable" --description d --acceptance a --project p --accept evidence --recognized-by x)"
scripts/bead-claim.sh --id "$id" --model sonnet >/dev/null
out="$(scripts/bead-release.sh --id "$id" --note "handing off, out of budget")"; rc=$?
assert_eq "bead-release prints RELEASED" "RELEASED" "$out"
assert_rc "bead-release exits 0" 0 "$rc"

bead="$(bd show --json "$id" 2>/dev/null | jq -c '.[0]')"
assert_eq "release returns status to open" "open" "$(printf '%s' "$bead" | jq -r '.status')"
assert_eq "release clears the assignee" "null" "$(printf '%s' "$bead" | jq -c '.assignee')"
notes="$(printf '%s' "$bead" | jq -r '.notes')"
assert_contains "the rule-5 IN-PROGRESS line carries the release note" "$notes" "released: handing off, out of budget"
assert_contains "the rule-5 block still has a NEXT line" "$notes" "NEXT:"

eb_report
