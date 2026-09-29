#!/usr/bin/env bash
# The closer (design §13; contract §5.3-§5.5). Two forms:
#   --id <id> --evidence <path> [--operator]   (§11.4: an accept:evidence Bead already
#                                                acceptance-pending, or an accept:operator Bead
#                                                closed on the operator's say-so in chat, which
#                                                REQUIRES --operator; §11.6)
#   --review <report>                          (§13: a review verdict; the reviewer never
#                                                mutates state, this script is the sole act of
#                                                acceptance on its output)
# The reviewer never mutates Bead state; no hook closes a Bead; this is the only closer.
# N2 (fix round 2, review pa-s2s.8-review-2): the --id --evidence form gates on the Bead's
# accept: mode — evidence closes as before; operator requires the explicit --operator flag
# (never silently); independent refuses outright, naming --review <report> as the only path (a
# fresh auditor's verdict is the judgment for that mode, never this form).
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

id=""; evidence=""; review=""; operator=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --id)       id="${2-}"; shift 2 ;;
    --evidence) evidence="${2-}"; shift 2 ;;
    --review)   review="${2-}"; shift 2 ;;
    --operator) operator=1; shift ;;
    *) die "unknown flag '$1'. Flags: --id <bead-id> --evidence <path> [--operator]  |  --review <report-path>" ;;
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

release_and_halt() {  # <id> <halt-label> <next-line>
  local id="$1" label="$2" next="$3"
  bd update "$id" --status open --assignee "" >/dev/null \
    || die "halt release ('bd update $id --status open --assignee \"\"') failed; nothing else was changed."
  bd update "$id" --add-label "$label" >/dev/null \
    || die "the claim was released but adding label '$label' failed. Run: bd update $id --add-label $label"
  "$SCRIPT_DIR/bead-progress.sh" --id "$id" --preserve \
    --in-progress "released: $label" --next "$next" \
    || die "the halt landed but the rule-5 note failed to write (COMPLETED/workunit/other lines were meant to be preserved). Run: $SCRIPT_DIR/bead-progress.sh --id $id --preserve --in-progress 'released: $label' --next '$next'"
}

# M1 (review pa-s2s.8-review-1): `bd close` refuses when the actor is not the recorded assignee
# (since U3 the actor is the session id, so the closer only worked inside the claiming session).
# Design §11.6: an accept:operator Bead is closed on the operator's say-so in chat, in a LATER
# session by definition; accept:evidence/independent's closer runs from the executor's own
# session too, but a review can land after that session ends. Probed empirically on bd 1.3.0
# (scratch db): `bd close --force` bypasses ONLY the assignee-mismatch refusal for our purposes
# here (this script already checks open blockers itself, via eb_open_blockers, before ever
# reaching this call) and leaves the `assignee` field untouched -- the original executor stays on
# record as who did the work. `--force` is passed ONLY when the actor differs from the recorded
# assignee, never unconditionally, so a same-session close behaves exactly as before.
#
# Atomic-as-BLOCKED-BY restore: the caller passes the bead's PRE-mutation notes; on a close
# failure this restores that exact blob (undoing the EVIDENCE/"closed by" append) and re-adds
# acceptance-pending, so a retry never sees a duplicated EVIDENCE line.
# N6 (fix round 2, review pa-s2s.8-review-2): `bd` records no closer-actor field anywhere a
# cross-actor close is visible (verified empirically: `bd show --json`/`--long` and `bd history
# --json` all show "beads" as the committer, never the actor who ran `bd close`). Rule 5 sanctions
# only the EVIDENCE line as an append, never a second free-text line, so the closer goes INSIDE
# that one line, parenthetically, rather than as its own "closed by ..." line.
eb_close_or_restore() {  # <id> <orig-notes> <evidence-line> <close-reason> <retry-hint>
  local id="$1" orig_notes="$2" evidence_line="$3" close_reason="$4" retry_hint="$5"
  local assignee actor close_args=(--reason "$close_reason")

  assignee="$(bd show --json "$id" 2>/dev/null | jq -r '.[0].assignee // ""')"
  actor="${BEADS_ACTOR:-}"
  if [[ -n "$assignee" && "$assignee" != "$actor" ]]; then
    close_args+=(--force)
    evidence_line="${evidence_line} (closed by ${actor:-<unknown actor>})"
  fi

  bd update "$id" --append-notes "$evidence_line" >/dev/null \
    || die "'bd update $id --append-notes' failed. Fix the reported cause and re-run; nothing was changed."
  bd update "$id" --remove-label "acceptance-pending" >/dev/null \
    || die "the evidence line landed but removing 'acceptance-pending' failed. Run: bd update $id --remove-label acceptance-pending"
  if ! bd close "$id" "${close_args[@]}" >/dev/null; then
    bd update "$id" --add-label "acceptance-pending" >/dev/null 2>&1
    bd update "$id" --notes "$orig_notes" >/dev/null 2>&1
    die "the label was removed but 'bd close' failed; restored 'acceptance-pending' and the prior notes. Fix the reported cause, then re-run: $retry_hint"
  fi
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

  # N2 (fix round 2, review pa-s2s.8-review-2): the accept-mode gate. Before this fix the form
  # closed ANY acceptance-pending Bead as ANY actor, including accept:independent ones with no
  # review at all — a universal bypass of independent review once the guard made this script the
  # only close path.
  mode="$(printf '%s' "$bead" | jq -r '[.labels[]? | select(startswith("accept:"))] | if length == 1 then .[0][7:] else "" end')"
  [[ -n "$mode" ]] || die "Bead $id does not carry exactly one 'accept:' label. Run check-bead.sh --id $id, fix the labels, then re-run."
  case "$mode" in
    evidence) ;;
    operator)
      [[ "$operator" -eq 1 ]] || die "Bead $id is accept:operator; this form closes it only on the operator's explicit say-so. Re-run with --operator (design §11.6) once the operator has said so in chat."
      ;;
    independent)
      die "Bead $id is accept:independent; this form never closes it (no review would have been checked). Use --review <report> with a fresh auditor's PASS verdict."
      ;;
    *) die "Bead $id carries an unrecognized accept: mode '$mode'." ;;
  esac

  blockers="$(eb_open_blockers "$id")" || die "'bd show --json $id' failed while checking blockers. Nothing was changed."
  if [[ -n "$blockers" ]]; then
    printf 'BLOCKED-BY %s\n' "$blockers"
    exit 1
  fi

  orig_notes="$(printf '%s' "$bead" | jq -r '.notes // ""')"
  eb_close_or_restore "$id" "$orig_notes" "EVIDENCE: ${evidence}" "accepted ${evidence}" \
    "bead-accept.sh --id $id --evidence ${evidence}"
  printf 'CLOSED\n'
  exit 0
fi

# =============================================================================================
# Form 2: --review <report> (design §13)
# =============================================================================================
[[ -n "$review" ]] || die "give --id --evidence <path>, or --review <report-path>."
[[ -f "$review" ]] || die "no report at '$review'. Confirm the path, then re-run."
# m10 (review pa-s2s.8-review-1): resolve to absolute BEFORE writing it anywhere (EVIDENCE line,
# close_reason, NEXT) — bead-reopen.sh later string-compares its own `prior` against this exact
# value, and a relative path recorded here can never match a later realpath'd comparison.
review="$(realpath "$review")"

fm="$(eb_read_frontmatter "$SCRIPT_DIR/lib" "$review")" \
  || die "'$review' has no readable YAML frontmatter (bead/verdict/reviewer/spawn/prior). Fix it, then re-run."

r_bead="$(printf '%s' "$fm" | jq -r '.bead // ""')"
r_verdict="$(printf '%s' "$fm" | jq -r '.verdict // ""')"
r_model="$(printf '%s' "$fm" | jq -r '.reviewer.model // ""')"
r_effort="$(printf '%s' "$fm" | jq -r '.reviewer.effort // ""')"
r_vendor="$(printf '%s' "$fm" | jq -r '.reviewer.vendor // ""')"
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
b_exec_effort="$(printf '%s' "$bead" | jq -r '.metadata.executor.effort // ""')"

[[ "$b_status" == "in_progress" && "$b_pending" == "1" ]] \
  || die "Bead $r_bead is not acceptance-pending (status=$b_status). A review verdict only closes a Bead already reported ACCEPTANCE-PENDING."
[[ -n "$b_accept" ]] || die "Bead $r_bead does not carry exactly one 'accept:' label. Run check-bead.sh --id $r_bead, fix the labels, then re-run."
[[ -n "$b_executor" ]] || die "Bead $r_bead has no metadata 'executor.model' (claimed before bead-claim.sh recorded it, or claimed off-script). Refusing — the tier rule cannot be evaluated. Set it with: bd update $r_bead --metadata '{\"executor\":{\"model\":\"<sonnet|opus|fable>\"}}', or re-claim through bead-claim.sh."

# Visibility for the EB_LADDER_FILE override (review pa-ym1-u2-check-1 MINOR-1, option b): say so on
# stderr and carry the path into the EVIDENCE line below.
ladder_note=""
if [[ -n "${EB_LADDER_FILE:-}" ]]; then
  printf 'ladder override: %s\n' "$EB_LADDER_FILE" >&2
  ladder_note=" (ladder override: ${EB_LADDER_FILE})"
fi

reason_err="$(eb_reviewer_adequate "$b_executor" "$b_exec_effort" "$r_vendor" "$r_model" "$r_effort" 2>&1 >/dev/null)" \
  || die "'$review' reviewer refused for Bead $r_bead: $reason_err. Refusing."

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
    evidence_line="EVIDENCE: $(printf '%s\n' "${chain[@]}" | paste -sd';' -)${ladder_note}"
    case "$b_accept" in
      evidence|independent)
        # These two modes are the ones that call `bd close` below — check open blockers BEFORE
        # any mutation so a refusal here changes nothing (accept:operator never closes here; its
        # eventual close goes through the --id --evidence --operator form, which checks again
        # there, and requires the operator's explicit say-so via --operator — N2).
        blockers="$(eb_open_blockers "$r_bead")" || die "'bd show --json $r_bead' failed while checking blockers. Nothing was changed."
        if [[ -n "$blockers" ]]; then
          printf 'BLOCKED-BY %s\n' "$blockers"
          exit 1
        fi
        r_orig_notes="$(printf '%s' "$bead" | jq -r '.notes // ""')"
        eb_close_or_restore "$r_bead" "$r_orig_notes" "$evidence_line" "accepted ${review}" \
          "bead-accept.sh --review ${review}"
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
      "$SCRIPT_DIR/bead-progress.sh" --id "$r_bead" --preserve \
        --in-progress "review FAILED; see findings" \
        --next "$review" \
        || die "budget was decremented but the rule-5 NEXT rewrite failed. Run: $SCRIPT_DIR/bead-progress.sh --id $r_bead --preserve --in-progress 'review FAILED; see findings' --next '$review' (preserving COMPLETED/workunit/other lines)."
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
