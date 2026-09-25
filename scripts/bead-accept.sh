#!/usr/bin/env bash
# The closer (design §13; contract §5.3-§5.5). Two forms:
#   --id <id> --evidence <path>   (§11.4: an accept:evidence Bead already acceptance-pending)
#   --review <report>             (§13: a review verdict; the reviewer never mutates state,
#                                   this script is the sole act of acceptance on its output)
# The reviewer never mutates Bead state; no hook closes a Bead; this is the only closer.
# Decision vocabulary on stdout, one line:
#   CLOSED | ACCEPTANCE-PENDING <authority> | FAILED <cycles-left> | HALTED [<reason>] | INCOMPLETE
#   | BLOCKED-BY <ids> (exit 1: the Bead has open blockers; nothing was changed, re-run once they
#   close)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="bead-accept"
die() { printf '%s: %s\n' "$SELF" "$1" >&2; exit "${2:-1}"; }

# shellcheck source=lib/eb-common.sh
source "$SCRIPT_DIR/lib/eb-common.sh"

id=""; evidence=""; review=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --id)       id="${2-}"; shift 2 ;;
    --evidence) evidence="${2-}"; shift 2 ;;
    --review)   review="${2-}"; shift 2 ;;
    *) die "unknown flag '$1'. Flags: --id <bead-id> --evidence <path>  |  --review <report-path>" ;;
  esac
done
command -v jq >/dev/null || die "jq not on PATH. Install jq, then re-run."

bead_json() {  # <id> -> the bead object on stdout
  local raw b
  raw="$(bd show --json "$1" 2>/dev/null)" || return 1
  b="$(printf '%s' "$raw" | jq '.[0]')"
  [[ "$b" != "null" && -n "$b" ]] || return 1
  printf '%s' "$b"
}

release_and_halt() {  # <id> <halt-label> <next-line> <halt-token-suffix>
  local id="$1" label="$2" next="$3"
  local bead completed
  bead="$(bead_json "$id")" || die "'bd show --json $id' failed mid-halt."
  completed="$(printf '%s' "$bead" | jq -r '(.notes // "") | split("\n") | map(select(startswith("COMPLETED: "))) | last // "COMPLETED: (none)"' | sed 's/^COMPLETED: //')"
  [[ -n "$completed" ]] || completed="(none)"
  bd update "$id" --status open --assignee "" >/dev/null \
    || die "halt release ('bd update $id --status open --assignee \"\"') failed; nothing else was changed."
  bd update "$id" --add-label "$label" >/dev/null \
    || die "the claim was released but adding label '$label' failed. Run: bd update $id --add-label $label"
  "$SCRIPT_DIR/bead-progress.sh" --id "$id" --completed "$completed" \
    --in-progress "released: $label" --next "$next" \
    || die "the halt landed but the rule-5 note failed to write. Run: $SCRIPT_DIR/bead-progress.sh --id $id --completed '$completed' --in-progress 'released: $label' --next '$next'"
}

# =============================================================================================
# Form 1: --id --evidence (design §11.4)
# =============================================================================================
if [[ -n "$evidence" ]]; then
  [[ -n "$id" ]] || die "--evidence requires --id."
  [[ -z "$review" ]] || die "--evidence and --review are mutually exclusive."

  bead="$(bead_json "$id")" || die "'bd show --json $id' failed. Confirm the id, then re-run."
  status="$(printf '%s' "$bead" | jq -r '.status')"
  has_pending="$(printf '%s' "$bead" | jq -r '[.labels[]? | select(. == "acceptance-pending")] | length')"
  [[ "$status" == "in_progress" && "$has_pending" == "1" ]] \
    || die "Bead $id is not acceptance-pending (status=$status). Run bead-report-success.sh first."

  blockers="$(eb_open_blockers "$id")" || die "'bd show --json $id' failed while checking blockers. Nothing was changed."
  if [[ -n "$blockers" ]]; then
    printf 'BLOCKED-BY %s\n' "$blockers"
    exit 1
  fi

  bd update "$id" --append-notes "EVIDENCE: ${evidence}" >/dev/null \
    || die "'bd update $id --append-notes' failed. Fix the reported cause and re-run; nothing was changed."
  bd update "$id" --remove-label "acceptance-pending" >/dev/null \
    || die "the evidence line landed but removing 'acceptance-pending' failed. Run: bd update $id --remove-label acceptance-pending"
  bd close "$id" --reason "accepted ${evidence}" >/dev/null \
    || {
      bd update "$id" --add-label "acceptance-pending" >/dev/null 2>&1
      die "the label was removed but 'bd close' failed; restored 'acceptance-pending'. Fix the reported cause, then re-run: bead-accept.sh --id $id --evidence ${evidence}"
    }
  printf 'CLOSED\n'
  exit 0
fi

# =============================================================================================
# Form 2: --review <report> (design §13)
# =============================================================================================
[[ -n "$review" ]] || die "give --id --evidence <path>, or --review <report-path>."
[[ -f "$review" ]] || die "no report at '$review'. Confirm the path, then re-run."

fm="$(eb_read_frontmatter "$SCRIPT_DIR/lib" "$review")" \
  || die "'$review' has no readable YAML frontmatter (bead/verdict/reviewer/spawn/prior). Fix it, then re-run."

r_bead="$(printf '%s' "$fm" | jq -r '.bead // ""')"
r_verdict="$(printf '%s' "$fm" | jq -r '.verdict // ""')"
r_model="$(printf '%s' "$fm" | jq -r '.reviewer.model // ""')"
r_effort="$(printf '%s' "$fm" | jq -r '.reviewer.effort // ""')"
r_spawn="$(printf '%s' "$fm" | jq -r '.spawn // ""')"
r_prior="$(printf '%s' "$fm" | jq -r '.prior // empty')"
r_reason="$(printf '%s' "$fm" | jq -r '.reason // ""')"

[[ -n "$r_bead"    ]] || die "'$review' frontmatter has no 'bead'. Refusing."
[[ -n "$r_verdict" ]] || die "'$review' frontmatter has no 'verdict'. Refusing."
case "$r_verdict" in PASS|FAIL|INCOMPLETE) ;; *) die "'$review' verdict must be PASS|FAIL|INCOMPLETE (got '$r_verdict')." ;; esac
[[ "$r_spawn" == "fresh" ]] || die "'$review' is not attested 'spawn: fresh' (got '${r_spawn:-<unset>}'). A forked reviewer is refused; re-run with a fresh spawn."

bead="$(bead_json "$r_bead")" || die "'bd show --json $r_bead' failed. Confirm the id in '$review' frontmatter, then re-run."
b_status="$(printf '%s' "$bead" | jq -r '.status')"
b_pending="$(printf '%s' "$bead" | jq -r '[.labels[]? | select(. == "acceptance-pending")] | length')"
b_accept="$(printf '%s' "$bead" | jq -r '[.labels[]? | select(startswith("accept:"))] | if length == 1 then .[0][7:] else "" end')"
b_executor="$(printf '%s' "$bead" | jq -r '.metadata.executor.model // ""')"

[[ "$b_status" == "in_progress" && "$b_pending" == "1" ]] \
  || die "Bead $r_bead is not acceptance-pending (status=$b_status). A review verdict only closes a Bead already reported ACCEPTANCE-PENDING."
[[ -n "$b_accept" ]] || die "Bead $r_bead does not carry exactly one 'accept:' label. Run check-bead.sh --id $r_bead, fix the labels, then re-run."
[[ -n "$b_executor" ]] || die "Bead $r_bead has no metadata 'executor.model' (claimed before bead-claim.sh recorded it, or claimed off-script). Refusing — the tier rule cannot be evaluated. Set it with: bd update $r_bead --metadata '{\"executor\":{\"model\":\"<haiku|sonnet|opus|fable>\"}}', or re-claim through bead-claim.sh."

eb_model_valid "$r_model" || die "'$review' reviewer.model '$r_model' is not on the ladder (haiku|sonnet|opus|fable)."
executor_rank="$(eb_model_rank "$b_executor")" || die "Bead $r_bead metadata executor.model '$b_executor' is not on the ladder. Refusing."
reviewer_rank="$(eb_model_rank "$r_model")" || die "internal: bad reviewer model '$r_model'."
top_rank="$(eb_model_rank fable)"
if [[ "$executor_rank" == "$top_rank" ]]; then
  (( reviewer_rank >= executor_rank )) || die "reviewer '$r_model' does not outrank executor '$b_executor' (top-tier executor requires a same-or-higher-tier reviewer). Refusing."
else
  (( reviewer_rank > executor_rank )) || die "reviewer '$r_model' does not outrank executor '$b_executor' on the ladder (haiku<sonnet<opus<fable). Refusing."
fi

# Evidence chain: follow `prior` recursively through report files, oldest first, this report last.
chain=("$review")
cursor="$r_prior"
seen=("$review")
while [[ -n "$cursor" && "$cursor" != "null" ]]; do
  for s in "${seen[@]}"; do [[ "$s" == "$cursor" ]] && die "'prior' chain cycles back to '$cursor'. Refusing."; done
  [[ -f "$cursor" ]] || die "prior report '$cursor' does not exist. Refusing."
  chain=("$cursor" "${chain[@]}")
  seen+=("$cursor")
  cfm="$(eb_read_frontmatter "$SCRIPT_DIR/lib" "$cursor")" || die "prior report '$cursor' has no readable frontmatter."
  cursor="$(printf '%s' "$cfm" | jq -r '.prior // empty')"
done

case "$r_verdict" in
  PASS)
    evidence_line="EVIDENCE: $(printf '%s\n' "${chain[@]}" | paste -sd';' -)"
    case "$b_accept" in
      evidence|independent)
        # These two modes are the ones that call `bd close` below — check open blockers BEFORE
        # any mutation so a refusal here changes nothing (accept:operator never closes here; its
        # eventual close goes through the --evidence form, which checks again there).
        blockers="$(eb_open_blockers "$r_bead")" || die "'bd show --json $r_bead' failed while checking blockers. Nothing was changed."
        if [[ -n "$blockers" ]]; then
          printf 'BLOCKED-BY %s\n' "$blockers"
          exit 1
        fi
        bd update "$r_bead" --append-notes "$evidence_line" >/dev/null \
          || die "'bd update $r_bead --append-notes' failed. Fix the reported cause and re-run; nothing was changed."
        bd update "$r_bead" --remove-label "acceptance-pending" >/dev/null \
          || die "the evidence line landed but removing 'acceptance-pending' failed. Run: bd update $r_bead --remove-label acceptance-pending"
        bd close "$r_bead" --reason "accepted ${review}" >/dev/null \
          || {
            bd update "$r_bead" --add-label "acceptance-pending" >/dev/null 2>&1
            die "the label was removed but 'bd close' failed; restored 'acceptance-pending'. Fix the reported cause, then re-run: bead-accept.sh --review ${review}"
          }
        printf 'CLOSED\n'
        ;;
      operator)
        bd update "$r_bead" --append-notes "$evidence_line" >/dev/null \
          || die "'bd update $r_bead --append-notes' failed. Fix the reported cause and re-run; nothing was changed."
        printf 'ACCEPTANCE-PENDING operator\n'
        ;;
      *) die "Bead $r_bead carries an unrecognized accept: mode '$b_accept'." ;;
    esac
    ;;

  FAIL)
    # Materialize the default budget on a legacy Bead (decision 2), THEN decrement.
    budget_json="$(printf '%s' "$bead" | jq -c '.metadata.budget // empty')"
    if [[ -z "$budget_json" ]]; then
      printf '%s: Bead %s has no metadata budget; materializing the default {"cycles":2} before decrementing.\n' "$SELF" "$r_bead" >&2
      eb_metadata_merge "$r_bead" '{"budget":{"cycles":2}}' \
        || die "materializing the default budget failed. Run: bd update $r_bead --metadata '{\"budget\":{\"cycles\":2}}'"
      cycles_before=2
    else
      cycles_before="$(printf '%s' "$budget_json" | jq -r '.cycles // 2')"
    fi
    cycles_after=$(( cycles_before - 1 ))
    (( cycles_after < 0 )) && cycles_after=0
    eb_metadata_merge "$r_bead" "$(jq -nc --argjson c "$cycles_after" '{"budget":{"cycles":$c}}')" \
      || die "decrementing budget.cycles failed. Run: bd update $r_bead --metadata '{\"budget\":{\"cycles\":$cycles_after}}'"
    bd update "$r_bead" --remove-label "acceptance-pending" >/dev/null \
      || die "budget was decremented but removing 'acceptance-pending' failed. Run: bd update $r_bead --remove-label acceptance-pending"

    if [[ "$cycles_after" -eq 0 ]]; then
      release_and_halt "$r_bead" "halt:budget" "$review"
      printf 'HALTED\n'
    else
      "$SCRIPT_DIR/bead-progress.sh" --id "$r_bead" \
        --completed "$(printf '%s' "$bead" | jq -r '(.notes // "") | split("\n") | map(select(startswith("COMPLETED: "))) | last // "COMPLETED: (none)"' | sed 's/^COMPLETED: //')" \
        --in-progress "review FAILED; see findings" \
        --next "$review" \
        || die "budget was decremented but the rule-5 NEXT rewrite failed. Run: $SCRIPT_DIR/bead-progress.sh --id $r_bead --next '$review' (preserving COMPLETED/IN-PROGRESS)."
      printf 'FAILED %s\n' "$cycles_after"
    fi
    ;;

  INCOMPLETE)
    case "$r_reason" in
      ""|coverage)
        printf 'INCOMPLETE\n'
        ;;
      reshape|bounds-not-set)
        release_and_halt "$r_bead" "halt:${r_reason}" "$review"
        printf 'HALTED %s\n' "$r_reason"
        ;;
      *)
        die "'$review' frontmatter 'reason' must be unset, coverage, reshape, or bounds-not-set (got '$r_reason')."
        ;;
    esac
    ;;
esac
