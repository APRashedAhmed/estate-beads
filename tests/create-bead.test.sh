#!/usr/bin/env bash
# create-bead.sh: happy path, --parent (no inherited accept:/tier:), --key idempotency, --label,
# --class, --budget (design §11.7, §12.2). README evaluation 2.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source tests/_scratch_db.sh
source tests/_assert.sh

eb_scratch_db scratch create-bead || exit 1
trap 'rm -rf "$scratch"' EXIT
export BEADS_ACTOR=actor1

# --- README evaluation 2: happy path + --parent ------------------------------------------------
id="$(scripts/create-bead.sh --title "Happy" --description d --acceptance a --project p --accept evidence --recognized-by x --tier sonnet)"
[[ "$id" == *$'\n'* ]] && eb_bad "create-bead prints exactly one line" "$id" || eb_ok "create-bead prints exactly one line"

child="$(scripts/create-bead.sh --title "HappyChild" --description d --acceptance a --project p --accept operator --recognized-by x --parent "$id")"
labels="$(bd show --json "$child" 2>/dev/null | jq -c '.[0].labels | sort')"
assert_eq "child under --parent carries its own accept:/project:, no inherited tier:" \
  '["accept:operator","class:bounded-increment","project:p"]' "$labels"

# --- default class/budget when absent -----------------------------------------------------------
meta="$(bd show --json "$id" 2>/dev/null | jq -c '.[0].metadata.budget')"
assert_eq "default budget is {\"cycles\":2}" '{"cycles":2}' "$meta"

# --- --key idempotency (first match), title fallback only when --key absent --------------------
k1="$(scripts/create-bead.sh --title "KeyedA" --description d --acceptance a --project p --accept evidence --recognized-by x --key wk1)"
rerun="$(scripts/create-bead.sh --title "KeyedA-retitled" --description d --acceptance a --project p --accept evidence --recognized-by x --key wk1)"
assert_eq "rerun with the same --key prints EXISTS: <original id>, even retitled" "EXISTS: $k1" "$rerun"

titleonly="$(scripts/create-bead.sh --title "TitleOnly" --description d --acceptance a --project p --accept evidence --recognized-by x)"
rerun2="$(scripts/create-bead.sh --title "TitleOnly" --description d --acceptance a --project p --accept evidence --recognized-by x)"
assert_eq "rerun with no --key falls back to exact --title match" "EXISTS: $titleonly" "$rerun2"

# --- --label repeatable, --class, --budget ------------------------------------------------------
lb="$(scripts/create-bead.sh --title "Labeled" --description d --acceptance a --project p --accept evidence --recognized-by x \
  --label "wf:auto" --label "wf:effort:low" --class hardened --budget "cycles=5")"
labels2="$(bd show --json "$lb" 2>/dev/null | jq -c '.[0].labels | sort')"
assert_eq "repeatable --label + --class land together" \
  '["accept:evidence","class:hardened","project:p","wf:auto","wf:effort:low"]' "$labels2"
budget2="$(bd show --json "$lb" 2>/dev/null | jq -c '.[0].metadata.budget')"
assert_eq "--budget cycles=5 is written" '{"cycles":5}' "$budget2"

# --- validation ----------------------------------------------------------------------------------
out="$(scripts/create-bead.sh --title "BadClass" --description d --acceptance a --project p --accept evidence --recognized-by x --class bogus 2>&1)"; rc=$?
assert_rc "--class rejects an unknown value" 1 "$rc"
out="$(scripts/create-bead.sh --title "BadBudget" --description d --acceptance a --project p --accept evidence --recognized-by x --budget "cycles=-1" 2>&1)"; rc=$?
assert_rc "--budget rejects a negative integer" 1 "$rc"

# --- idempotency guard uses the same status filter (a closed Bead with the key does not block) -
closedkey="$(scripts/create-bead.sh --title "ClosedKeyed" --description d --acceptance a --project p --accept evidence --recognized-by x --key wk-closed)"
bd close "$closedkey" --reason "accepted test" >/dev/null 2>&1
reopened_new="$(scripts/create-bead.sh --title "ClosedKeyed-again" --description d --acceptance a --project p --accept evidence --recognized-by x --key wk-closed)"
assert_ne "a closed Bead's key does not block re-creation (open,in_progress,blocked filter)" "EXISTS: $closedkey" "$reopened_new"

eb_report
