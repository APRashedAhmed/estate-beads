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

# --- workunit.yaml backlink: a '#' INSIDE the brackets is rejected, not treated as a comment ------
mkdir -p "$scratch/wu-flow-hash-inside"
printf 'slug: flow-hash-inside\nbeads: [existing-a # not-a-real-id]\n' > "$scratch/wu-flow-hash-inside/workunit.yaml"
before_hi="$(cat "$scratch/wu-flow-hash-inside/workunit.yaml")"
out_hi="$(scripts/create-bead.sh --title "FlowHashInside" --description d --acceptance a --project p --accept evidence --recognized-by x --workunit "$scratch/wu-flow-hash-inside" 2>&1)"; rc_hi=$?
assert_rc "create-bead.sh exits non-zero for a '#' inside the brackets" 1 "$rc_hi"
after_hi="$(cat "$scratch/wu-flow-hash-inside/workunit.yaml")"
[[ "$before_hi" == "$after_hi" ]] \
  && eb_ok "'#' inside the brackets: workunit.yaml left byte-identical" \
  || eb_bad "'#' inside the brackets: workunit.yaml left byte-identical"

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

# check-bead.sh must match an id that is itself written quoted, double or single
printf 'slug: flow-quoted-self\nbeads: ["%s"]\nlifecycle: beads\n' "$quotedid" > "$scratch/wu-flow-quoted/workunit.yaml"
scripts/check-bead.sh --id "$quotedid" >/dev/null 2>&1 \
  && eb_ok "check-bead.sh matches an id written double-quoted in the flow list" \
  || eb_bad "check-bead.sh matches an id written double-quoted in the flow list"
printf "slug: flow-quoted-self\nbeads: ['%s']\nlifecycle: beads\n" "$quotedid" > "$scratch/wu-flow-quoted/workunit.yaml"
scripts/check-bead.sh --id "$quotedid" >/dev/null 2>&1 \
  && eb_ok "check-bead.sh matches an id written single-quoted in the flow list" \
  || eb_bad "check-bead.sh matches an id written single-quoted in the flow list"

# --- --deps failures relay bd's own error (bd --json writes it to stdout) -------------------------
CB_COMMON=(--description d --acceptance a --project p --accept evidence --recognized-by x)
a="$(scripts/create-bead.sh --title "DepTargetA" "${CB_COMMON[@]}")"
b="$(scripts/create-bead.sh --title "DepTargetB" "${CB_COMMON[@]}")"

# 1. missing target relays bd's error and a remedy
out="$(scripts/create-bead.sh --title "DepMissing" "${CB_COMMON[@]}" --deps "blocked-by:zz-999" 2>&1)"; rc=$?
assert_rc "missing --deps target exits 1" 1 "$rc"
assert_contains "missing --deps target relays bd's error text" "$out" 'no issue found matching "zz-999"'
assert_contains "missing --deps target remedy names 'bd show'" "$out" "bd show"

# 2. same target, two edge types: refused before bd, no Bead created
n0="$(bd list --json --limit 0 2>/dev/null | jq length)"
# Spy bd first on PATH for this one invocation: logs its args, then execs the real bd.
real_bd="$(command -v bd)"
spy_dir="$scratch/spy-bin"; spy_log="$scratch/spy-bd.log"
mkdir -p "$spy_dir"; : >"$spy_log"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s"\nexec "%s" "$@"\n' "$spy_log" "$real_bd" >"$spy_dir/bd"
chmod +x "$spy_dir/bd"
orig_path="$PATH"
PATH="$spy_dir:$PATH"
out="$(scripts/create-bead.sh --title "DepSameTarget" "${CB_COMMON[@]}" --deps "blocked-by:$a,discovered-from:$a" 2>&1)"; rc=$?
PATH="$orig_path"
n1="$(bd list --json --limit 0 2>/dev/null | jq length)"
[[ "$n0" =~ ^[0-9]+$ && "$n1" =~ ^[0-9]+$ ]] \
  && eb_ok "same-target Bead counts are non-empty integers" \
  || eb_bad "same-target Bead counts are non-empty integers" "before='$n0' after='$n1'"
creates="$(awk '$1 == "create"' "$spy_log" | wc -l)"
assert_eq "same-target refusal never reaches 'bd create'" "0" "${creates//[[:space:]]/}"
assert_rc "same target with two edge types exits 1" 1 "$rc"
assert_contains "same-target refusal says 'two edge types'" "$out" "two edge types"
assert_contains "same-target refusal keeps the typed word blocked-by" "$out" "blocked-by:$a"
assert_contains "same-target refusal names discovered-from" "$out" "discovered-from"
assert_eq "same-target refusal creates no Bead" "$n0" "$n1"

# 2b. empty edge type (':<id>') is refused before bd, no Bead created
n0="$(bd list --json --limit 0 2>/dev/null | jq length)"
out="$(scripts/create-bead.sh --title "DepEmptyType" "${CB_COMMON[@]}" --deps ":$a" 2>&1)"; rc=$?
n1="$(bd list --json --limit 0 2>/dev/null | jq length)"
[[ "$n0" =~ ^[0-9]+$ && "$n1" =~ ^[0-9]+$ ]] \
  && eb_ok "empty-type Bead counts are non-empty integers" \
  || eb_bad "empty-type Bead counts are non-empty integers" "before='$n0' after='$n1'"
assert_rc "empty edge type exits 1" 1 "$rc"
assert_contains "empty edge type refusal says 'has no edge type'" "$out" "has no edge type"
assert_eq "empty edge type creates no Bead" "$n0" "$n1"

# 3. distinct targets with two edge types succeed
n0="$(bd list --json --limit 0 2>/dev/null | jq length)"
id3="$(scripts/create-bead.sh --title "DepDistinct" "${CB_COMMON[@]}" --deps "blocked-by:$a,discovered-from:$b")"; rc=$?
assert_rc "distinct targets with two edge types exit 0" 0 "$rc"
dep3="$(bd show --json "$id3" 2>/dev/null | jq -c '.[0].dependencies')"
assert_eq "distinct targets land exactly two edges" "2" "$(printf '%s' "$dep3" | jq 'length')"
assert_eq "edge to the blocker is blocks" '"blocks"' \
  "$(printf '%s' "$dep3" | jq -c --arg i "$a" '.[] | select(.id==$i) | .dependency_type')"
assert_eq "edge to the origin is discovered-from" '"discovered-from"' \
  "$(printf '%s' "$dep3" | jq -c --arg i "$b" '.[] | select(.id==$i) | .dependency_type')"

# 4. bare id and same-type repeat still work
id4="$(scripts/create-bead.sh --title "DepBare" "${CB_COMMON[@]}" --deps "$a")"; rc=$?
assert_rc "bare --deps id exits 0" 0 "$rc"
edges="$(bd show --json "$id4" 2>/dev/null | jq -c '.[0].dependencies | map({id,dependency_type})')"
assert_eq "bare --deps id is a single blocks edge" "[{\"id\":\"$a\",\"dependency_type\":\"blocks\"}]" "$edges"
id4b="$(scripts/create-bead.sh --title "DepRepeat" "${CB_COMMON[@]}" --deps "blocked-by:$a,$a")"; rc=$?
assert_rc "same-type repeat exits 0" 0 "$rc"
edges="$(bd show --json "$id4b" 2>/dev/null | jq -c '.[0].dependencies | map({id,dependency_type})')"
assert_eq "same-type repeat is a single blocks edge" "[{\"id\":\"$a\",\"dependency_type\":\"blocks\"}]" "$edges"

# 5. unknown edge type is named with a remedy
out="$(scripts/create-bead.sh --title "DepUnknown" "${CB_COMMON[@]}" --deps "foo:$a" 2>&1)"; rc=$?
assert_rc "unknown edge type exits 1" 1 "$rc"
assert_contains "unknown edge type relays bd's text" "$out" 'unknown dependency type "foo"'
assert_contains "unknown edge type remedy names blocked-by:<id>" "$out" "blocked-by:<id>"

# 6. a bd warning never stands alone: bd's error comes first, the warning stays visible after it.
# From a non-git dir bd warns about beads.role on stderr (eb_scratch_db redirects HOME, not repo config).
cd "$scratch" || exit 1
err="$("$ROOT/scripts/create-bead.sh" --title "DepWarn" "${CB_COMMON[@]}" --deps "blocked-by:zz-999" 2>&1 >/dev/null)"; rc=$?
cd "$ROOT" || exit 1
assert_rc "warning scenario exits 1" 1 "$rc"
first_line="${err%%$'\n'*}"
case "$first_line" in
  "create-bead: bd create failed: resolving --deps target"*) eb_ok "first stderr line is bd's error, not the warning" ;;
  *) eb_bad "first stderr line is bd's error, not the warning" "first line: $first_line" ;;
esac
assert_contains "the beads.role warning is still shown" "$err" "beads.role not configured"
case "$err" in
  *"bd create failed: resolving"*"beads.role not configured"*) eb_ok "bd's error is printed before the warning" ;;
  *) eb_bad "bd's error is printed before the warning" "$err" ;;
esac

# --- a value-taking flag as the LAST argument dies with a cause and remedy -----------------------
for lastflag in --deps --key; do
  n0="$(bd list --json --limit 0 2>/dev/null | jq length)"
  out="$(scripts/create-bead.sh --title "TrailingFlag" "${CB_COMMON[@]}" "$lastflag" 2>&1)"; rc=$?
  n1="$(bd list --json --limit 0 2>/dev/null | jq length)"
  [[ "$n0" =~ ^[0-9]+$ && "$n1" =~ ^[0-9]+$ ]] \
    && eb_ok "trailing $lastflag Bead counts are non-empty integers" \
    || eb_bad "trailing $lastflag Bead counts are non-empty integers" "before='$n0' after='$n1'"
  assert_rc "trailing $lastflag exits 1" 1 "$rc"
  assert_contains "trailing $lastflag names the flag and its missing value" "$out" "$lastflag requires a value"
  assert_eq "trailing $lastflag creates no Bead" "$n0" "$n1"
done

# --- a boolean flag as the LAST argument still works (guard must not reject it) -----------------
out="$(scripts/create-bead.sh --title "TrailingForce" "${CB_COMMON[@]}" --force 2>&1)"; rc=$?
assert_rc "trailing boolean --force still exits 0" 0 "$rc"

eb_report
