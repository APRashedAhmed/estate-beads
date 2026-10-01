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

# --- workunit.yaml backlink: flow-form beads: [] -> beads: [<new>] (B7) -------------------------
mkdir -p "$scratch/wu-flow-empty"
printf 'slug: flow-empty\nbeads: []\n' > "$scratch/wu-flow-empty/workunit.yaml"
flowid="$(scripts/create-bead.sh --title "FlowEmpty" --description d --acceptance a --project p --accept evidence --recognized-by x --workunit "$scratch/wu-flow-empty")"; rc=$?
assert_rc "create-bead.sh exits 0 for a flow-form 'beads: []' manifest" 0 "$rc"
[[ -n "$flowid" ]] && eb_ok "create-bead.sh prints the new id for flow-form 'beads: []'" \
  || eb_bad "create-bead.sh prints the new id for flow-form 'beads: []'"
grep -qF "beads: [$flowid]" "$scratch/wu-flow-empty/workunit.yaml" \
  && eb_ok "flow-form 'beads: []' becomes 'beads: [<new>]'" \
  || eb_bad "flow-form 'beads: []' becomes 'beads: [<new>]'"

# --- workunit.yaml backlink: flow-form beads: [a, b] -> beads: [a, b, <new>] (B7) ---------------
mkdir -p "$scratch/wu-flow-pop"
printf 'slug: flow-pop\nbeads: [existing-a, existing-b]\n' > "$scratch/wu-flow-pop/workunit.yaml"
flowid2="$(scripts/create-bead.sh --title "FlowPop" --description d --acceptance a --project p --accept evidence --recognized-by x --workunit "$scratch/wu-flow-pop")"; rc=$?
assert_rc "create-bead.sh exits 0 for a flow-form 'beads: [a, b]' manifest" 0 "$rc"
[[ -n "$flowid2" ]] && eb_ok "create-bead.sh prints the new id for flow-form 'beads: [a, b]'" \
  || eb_bad "create-bead.sh prints the new id for flow-form 'beads: [a, b]'"
grep -qF "beads: [existing-a, existing-b, $flowid2]" "$scratch/wu-flow-pop/workunit.yaml" \
  && eb_ok "flow-form 'beads: [a, b]' becomes 'beads: [a, b, <new>]'" \
  || eb_bad "flow-form 'beads: [a, b]' becomes 'beads: [a, b, <new>]'"

# --- block form still works unchanged (regression guard for B7 fix) -----------------------------
mkdir -p "$scratch/wu-block"
printf 'slug: block\nbeads:\n  - existing-c\n' > "$scratch/wu-block/workunit.yaml"
blockid="$(scripts/create-bead.sh --title "BlockForm" --description d --acceptance a --project p --accept evidence --recognized-by x --workunit "$scratch/wu-block")"
grep -qF -- "- $blockid" "$scratch/wu-block/workunit.yaml" \
  && eb_ok "block-form 'beads:' list still gets the new id appended" \
  || eb_bad "block-form 'beads:' list still gets the new id appended"
grep -qF -- "- existing-c" "$scratch/wu-block/workunit.yaml" \
  && eb_ok "block-form existing entries are preserved" \
  || eb_bad "block-form existing entries are preserved"

# --- workunit.yaml backlink: multi-line flow list is rejected, file left unchanged (review-1 MAJOR 1) -
mkdir -p "$scratch/wu-flow-multiline"
printf 'slug: flow-multiline\nbeads: [\n  existing-a,\n  existing-b\n]\n' > "$scratch/wu-flow-multiline/workunit.yaml"
before_ml="$(cat "$scratch/wu-flow-multiline/workunit.yaml")"
out_ml="$(scripts/create-bead.sh --title "FlowMultiline" --description d --acceptance a --project p --accept evidence --recognized-by x --workunit "$scratch/wu-flow-multiline" 2>&1)"; rc_ml=$?
assert_rc "create-bead.sh exits non-zero for a multi-line flow 'beads:' list" 1 "$rc_ml"
printf '%s' "$out_ml" | grep -qE 'cannot safely rewrite|unsupported' \
  && eb_ok "multi-line flow list error names the file and the manual edit" \
  || eb_bad "multi-line flow list error names the file and the manual edit" "$out_ml"
after_ml="$(cat "$scratch/wu-flow-multiline/workunit.yaml")"
[[ "$before_ml" == "$after_ml" ]] \
  && eb_ok "multi-line flow list: workunit.yaml left byte-identical" \
  || eb_bad "multi-line flow list: workunit.yaml left byte-identical"

# --- workunit.yaml backlink: unsupported trailing content after ']' is rejected, file unchanged ----
mkdir -p "$scratch/wu-flow-trailing"
printf 'slug: flow-trailing\nbeads: [existing-a] extra\n' > "$scratch/wu-flow-trailing/workunit.yaml"
before_tr="$(cat "$scratch/wu-flow-trailing/workunit.yaml")"
out_tr="$(scripts/create-bead.sh --title "FlowTrailing" --description d --acceptance a --project p --accept evidence --recognized-by x --workunit "$scratch/wu-flow-trailing" 2>&1)"; rc_tr=$?
assert_rc "create-bead.sh exits non-zero for unrecognized trailing content after ']'" 1 "$rc_tr"
after_tr="$(cat "$scratch/wu-flow-trailing/workunit.yaml")"
[[ "$before_tr" == "$after_tr" ]] \
  && eb_ok "unsupported trailing content: workunit.yaml left byte-identical" \
  || eb_bad "unsupported trailing content: workunit.yaml left byte-identical"

# --- workunit.yaml backlink: a trailing '# comment' is preserved, id still appended (review-1 MAJOR 1 optional) -
mkdir -p "$scratch/wu-flow-comment"
printf 'slug: flow-comment\nbeads: [existing-a] # keep me\n' > "$scratch/wu-flow-comment/workunit.yaml"
commentid="$(scripts/create-bead.sh --title "FlowComment" --description d --acceptance a --project p --accept evidence --recognized-by x --workunit "$scratch/wu-flow-comment")"; rc_c=$?
assert_rc "create-bead.sh exits 0 for a flow list with a trailing comment" 0 "$rc_c"
grep -qF "beads: [existing-a, $commentid] # keep me" "$scratch/wu-flow-comment/workunit.yaml" \
  && eb_ok "trailing '# comment' is preserved and the id is appended before it" \
  || eb_bad "trailing '# comment' is preserved and the id is appended before it"
scripts/check-bead.sh --id "$commentid" >/dev/null 2>&1 \
  && eb_ok "check-bead.sh finds the id in a comment-trailing flow list" \
  || eb_bad "check-bead.sh finds the id in a comment-trailing flow list"

# --- workunit.yaml backlink: quoted ids are recognized and deduped (review-1 MINOR 1) ---------------
mkdir -p "$scratch/wu-flow-quoted"
printf 'slug: flow-quoted\nbeads: ["existing-a", '"'"'existing-b'"'"']\n' > "$scratch/wu-flow-quoted/workunit.yaml"
quotedid="$(scripts/create-bead.sh --title "FlowQuoted" --description d --acceptance a --project p --accept evidence --recognized-by x --workunit "$scratch/wu-flow-quoted")"; rc_q=$?
assert_rc "create-bead.sh exits 0 for a flow list with quoted ids" 0 "$rc_q"
grep -qF "beads: [\"existing-a\", 'existing-b', $quotedid]" "$scratch/wu-flow-quoted/workunit.yaml" \
  && eb_ok "quoted existing ids are preserved and the new bare id is appended" \
  || eb_bad "quoted existing ids are preserved and the new bare id is appended"
scripts/check-bead.sh --id "$quotedid" >/dev/null 2>&1 \
  && eb_ok "check-bead.sh finds the id in a quoted-id flow list" \
  || eb_bad "check-bead.sh finds the id in a quoted-id flow list"

eb_report
