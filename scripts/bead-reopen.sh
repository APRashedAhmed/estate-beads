#!/usr/bin/env bash
# Reopen a closed Bead on a later FAIL review verdict whose `prior` is the closing PASS report
# recorded in `close_reason` (contract §5.5). Same frontmatter form and tier rule as bead-accept.sh
# --review; consumes no cycle. The reviewer never mutates state; this script is the sole act.
# Decision vocabulary on stdout, one word: REOPENED.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="bead-reopen"
die() { printf '%s: %s\n' "$SELF" "$1" >&2; exit "${2:-1}"; }

# shellcheck source=lib/eb-common.sh
source "$SCRIPT_DIR/lib/eb-common.sh"

review=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --review) review="${2-}"; shift 2 ;;
    *) die "unknown flag '$1'. Flags: --review <report-path>" ;;
  esac
done
[[ -n "$review" ]] || die "missing required --review <report-path>."
[[ -f "$review" ]] || die "no report at '$review'. Confirm the path, then re-run."
review="$(realpath "$review")"
command -v jq >/dev/null || die "jq not on PATH. Install jq, then re-run."

fm="$(eb_read_frontmatter "$SCRIPT_DIR/lib" "$review")" \
  || die "'$review' has no readable YAML frontmatter (bead/verdict/reviewer/spawn/prior). Fix it, then re-run."

r_bead="$(printf '%s' "$fm" | jq -r '.bead // ""')"
r_verdict="$(printf '%s' "$fm" | jq -r '.verdict // ""')"
r_model="$(printf '%s' "$fm" | jq -r '.reviewer.model // ""')"
r_effort="$(printf '%s' "$fm" | jq -r '.reviewer.effort // ""')"
r_vendor="$(printf '%s' "$fm" | jq -r '.reviewer.vendor // ""')"
r_spawn="$(printf '%s' "$fm" | jq -r '.spawn // ""')"
r_prior="$(printf '%s' "$fm" | jq -r '.prior // empty')"

[[ -n "$r_bead" ]] || die "'$review' frontmatter has no 'bead'. Refusing."
[[ "$r_verdict" == "FAIL" ]] || die "'$review' verdict must be FAIL to reopen a closed Bead (got '${r_verdict:-<unset>}'). A PASS never reopens."
[[ "$r_spawn" == "fresh" ]] || die "'$review' is not attested 'spawn: fresh' (got '${r_spawn:-<unset>}'). A forked reviewer is refused; re-run with a fresh spawn."
[[ -n "$r_prior" && "$r_prior" != "null" ]] || die "'$review' has no 'prior' — reopen requires the report citing the closing PASS report."
# m10 (review pa-s2s.8-review-1): bead-accept.sh now records `close_reason` as an ABSOLUTE path
# (realpath'd there). Normalize `prior` the same way before the string compare below, so a
# relative `prior` written by an author who did not yet follow review-brief.md's "prior is
# absolute" rule still matches. Guarded by -f: only normalize an existing file.
[[ -f "$r_prior" ]] && r_prior="$(realpath "$r_prior")"

eb_bd raw show --json "$r_bead" || die "$(eb_show_remedy "$r_bead" "Confirm the id in '$review' frontmatter")"
bead="$(printf '%s' "$raw" | jq '.[0]')"
[[ "$bead" != "null" && -n "$bead" ]] || die "no Bead '$r_bead' in the database."

b_status="$(printf '%s' "$bead" | jq -r '.status')"
[[ "$b_status" == "closed" ]] || die "Bead $r_bead is not closed (status=$b_status). Reopen only applies to a closed Bead."

close_reason="$(printf '%s' "$bead" | jq -r '.close_reason // ""')"
[[ "$close_reason" == accepted\ * ]] || die "Bead $r_bead's close_reason does not start with 'accepted ' (got '${close_reason:-<empty>}'). Refusing."
closing_report="${close_reason#accepted }"
[[ "$r_prior" == "$closing_report" ]] \
  || die "'$review' 'prior' ('$r_prior') does not match the closing PASS report recorded in close_reason ('$closing_report'). Refusing."

b_executor="$(printf '%s' "$bead" | jq -r '.metadata.executor.model // ""')"
b_exec_effort="$(printf '%s' "$bead" | jq -r '.metadata.executor.effort // ""')"
[[ -n "$b_executor" ]] || die "Bead $r_bead has no metadata 'executor.model'. Refusing — the tier rule cannot be evaluated."
# Visibility for the EB_LADDER_FILE override (review pa-ym1-u2-check-1 MINOR-1, option b).
reopen_reason="reopened per FAIL review $review, prior $r_prior"
in_progress_line="reopened on a FAIL review"
if [[ -n "${EB_LADDER_FILE:-}" ]]; then
  printf 'ladder override: %s\n' "$EB_LADDER_FILE" >&2
  reopen_reason="${reopen_reason}, ladder override: ${EB_LADDER_FILE}"
  in_progress_line="${in_progress_line} (ladder override: ${EB_LADDER_FILE})"
fi

reason_err="$(eb_reviewer_adequate "$b_executor" "$b_exec_effort" "$r_vendor" "$r_model" "$r_effort" 2>&1 >/dev/null)" \
  || die "'$review' reviewer refused for Bead $r_bead: $reason_err. Refusing."

bd reopen "$r_bead" --reason "$reopen_reason" >/dev/null \
  || die "'bd reopen $r_bead' failed. Fix the reported cause, then re-run; nothing else was changed."

# m1 (review pa-s2s.8-review-1): --preserve keeps the existing COMPLETED line and any other
# surviving line (notably EVIDENCE:) verbatim; a bare --completed "(none)" call (no --preserve)
# clobbered them on every reopen, dropping the acceptance trail the closer had just written.
"$SCRIPT_DIR/bead-progress.sh" --id "$r_bead" --preserve \
  --in-progress "$in_progress_line" \
  --next "$review" \
  || die "the Bead was reopened but the rule-5 NEXT rewrite failed. Run: $SCRIPT_DIR/bead-progress.sh --id $r_bead --preserve --next '$review'"

printf 'REOPENED\n'
