#!/usr/bin/env bash
# bead-release.sh --id --note (rules 7/10): return to open, unassign, record via bead-progress.sh.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source tests/_scratch_db.sh
source tests/_assert.sh

eb_scratch_db scratch bead-release || exit 1
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

# --- N1 (review pa-s2s.8-review-2): refuses an acceptance-pending Bead, unless --force-pending ---
pending_id="$(scripts/create-bead.sh --title "Pending" --description d --acceptance a --project p --accept operator --recognized-by x)"
scripts/bead-claim.sh --id "$pending_id" --model sonnet >/dev/null
bd update "$pending_id" --append-notes "EVIDENCE: pending report" >/dev/null
bd update "$pending_id" --add-label "acceptance-pending" >/dev/null
before_pending="$(bd show --json "$pending_id" 2>/dev/null | jq -c '.[0]')"

out="$(scripts/bead-release.sh --id "$pending_id" --note "trying to release" 2>&1)"; rc=$?
assert_rc "release refuses an acceptance-pending Bead" 1 "$rc"
assert_contains "refusal names bead-accept.sh" "$out" "bead-accept.sh"
assert_contains "refusal names --force-pending" "$out" "--force-pending"
after_pending="$(bd show --json "$pending_id" 2>/dev/null | jq -c '.[0]')"
assert_eq "a refused release changes nothing (status/labels/notes)" \
  "$(printf '%s' "$before_pending" | jq -c '{status, labels, notes}')" \
  "$(printf '%s' "$after_pending" | jq -c '{status, labels, notes}')"

out="$(scripts/bead-release.sh --id "$pending_id" --note "operator says abandon it" --force-pending)"; rc=$?
assert_eq "--force-pending releases an acceptance-pending Bead anyway" "RELEASED" "$out"
assert_rc "--force-pending exits 0" 0 "$rc"
forced="$(bd show --json "$pending_id" 2>/dev/null | jq -c '.[0]')"
assert_eq "--force-pending returns status to open" "open" "$(printf '%s' "$forced" | jq -r '.status')"
assert_eq "--force-pending clears the assignee" "null" "$(printf '%s' "$forced" | jq -c '.assignee')"

eb_report
