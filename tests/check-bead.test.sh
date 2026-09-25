#!/usr/bin/env bash
# check-bead.sh: parent linkage, $SEAT_ROOT expansion, class/budget invariants (design §11.7, §9).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source tests/_scratch_db.sh
source tests/_assert.sh

eb_scratch_db scratch check-bead
trap 'rm -rf "$scratch"' EXIT
export BEADS_ACTOR=actor1

# --- README evaluation 1: check-bead.sh on a well-formed Bead with --expect-parent -------------
parent=$(scripts/create-bead.sh --title "Parent" --description d --acceptance a --project p --accept evidence --recognized-by x)
child=$(scripts/create-bead.sh --title "Child" --description d --acceptance a --project p --accept evidence --recognized-by x --parent "$parent")
out="$(scripts/check-bead.sh --id "$child" --expect-parent "$parent" 2>&1)"; rc=$?
assert_rc "check-bead passes a well-formed child with --expect-parent" 0 "$rc"
assert_eq "check-bead is silent on pass" "" "$out"

# --- $SEAT_ROOT expansion (found while authoring pa-s2s; design §9) ---------------------------
mkdir -p "$scratch/wu"
cat > "$scratch/wu/workunit.yaml" <<'EOF'
slug: probe
EOF
export SEAT_ROOT="$scratch"
seatid=$(scripts/create-bead.sh --title "SeatExpand" --description d --acceptance a --project p --accept evidence --recognized-by x --workunit '$SEAT_ROOT/wu')
out="$(scripts/check-bead.sh --id "$seatid" 2>&1)"; rc=$?
assert_rc "check-bead expands a literal \$SEAT_ROOT before the -d test" 0 "$rc"
grep -qF -- "- $seatid" "$scratch/wu/workunit.yaml" \
  && eb_ok "backlink written to the \$SEAT_ROOT-expanded manifest" \
  || eb_bad "backlink written to the \$SEAT_ROOT-expanded manifest"
unset SEAT_ROOT

# --- class/budget invariants: well-formed passes, legacy (no class/budget) fails with remedies -
wellformed=$(bd create "WellFormed" --type task --description d --acceptance a \
  --labels "project:p,accept:evidence,class:hardened" \
  --metadata '{"recognized-by":"x","budget":{"cycles":3}}' --json 2>/dev/null | jq -r .id)
out="$(scripts/check-bead.sh --id "$wellformed" 2>&1)"; rc=$?
assert_rc "check-bead passes a Bead with one class: label and integer budget" 0 "$rc"

legacy=$(bd create "LegacyNoClassBudget" --type task --description d --acceptance a \
  --labels "project:p,accept:evidence" --metadata '{"recognized-by":"x"}' --json 2>/dev/null | jq -r .id)
out="$(scripts/check-bead.sh --id "$legacy" 2>&1)"; rc=$?
assert_rc "check-bead fails a legacy Bead with no class:/budget" 1 "$rc"
assert_contains "check-bead names the missing class: remedy" "$out" "class:bounded-increment"
assert_contains "check-bead names the missing budget remedy" "$out" '{"budget":{"cycles":2}}'

negbudget=$(bd create "NegBudget" --type task --description d --acceptance a \
  --labels "project:p,accept:evidence,class:bounded-increment" \
  --metadata '{"recognized-by":"x","budget":{"cycles":-1}}' --json 2>/dev/null | jq -r .id)
out="$(scripts/check-bead.sh --id "$negbudget" 2>&1)"; rc=$?
assert_rc "check-bead fails a negative budget dimension" 1 "$rc"

eb_report
