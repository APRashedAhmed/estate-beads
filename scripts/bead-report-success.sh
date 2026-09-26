#!/usr/bin/env bash
# Rule 9: report success. Adds the evidence line and the acceptance-pending label,
# then closes ONLY under accept:evidence. Under any other accept: mode it stops and
# names the acceptance authority.
# Decision vocabulary on stdout, one line: CLOSED | ACCEPTANCE-PENDING <authority>.
set -euo pipefail

SELF="bead-report-success"
die() { printf '%s: %s\n' "$SELF" "$1" >&2; exit "${2:-1}"; }

id=""; evidence=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --id)       id="${2-}"; shift 2 ;;
    --evidence) evidence="${2-}"; shift 2 ;;
    *) die "unknown flag '$1'. Flags: --id <bead-id> --evidence '<what you checked, where the artifacts are>'" ;;
  esac
done
[[ -n "$id"       ]] || die "missing required --id."
[[ -n "$evidence" ]] || die "missing required --evidence."
command -v jq >/dev/null || die "jq not on PATH. Install jq, then re-run."

raw="$(bd show --json "$id")" || die "'bd show --json $id' failed. Confirm the id, then re-run."
bead="$(printf '%s' "$raw" | jq '.[0]')"
[[ "$bead" != "null" && -n "$bead" ]] || die "no Bead '$id' in the database. Confirm the id, then re-run."

mode="$(printf '%s' "$bead" | jq -r '[.labels[]? | select(startswith("accept:"))] | if length == 1 then .[0][7:] else "" end')"
[[ -n "$mode" ]] || die "Bead $id does not carry exactly one 'accept:' label, so the acceptance authority is undetermined. Run check-bead.sh --id $id, fix the labels, then re-run."

# One EVIDENCE line appended at the terminal moment — the only append this skill allows.
bd update "$id" --append-notes "EVIDENCE: ${evidence}" >/dev/null \
  || die "'bd update $id --append-notes' failed. Fix the reported cause and re-run; nothing was changed."
bd update "$id" --add-label "acceptance-pending" >/dev/null \
  || die "the evidence line landed but 'acceptance-pending' did not. Run: bd update $id --add-label acceptance-pending"

if [[ "$mode" == "evidence" ]]; then
  bd close "$id" --reason accepted >/dev/null \
    || die "the label landed but the close failed. Fix the reported cause, then run: bd close $id --reason accepted"
  printf 'CLOSED\n'
  exit 0
fi

if [[ "$mode" == "independent" ]]; then
  # design §13: accept:independent is review-accepted; the executor dispatches a fresh review
  # and runs `bead-accept.sh --review <report>` on its verdict (contract §9 rule 9).
  printf 'ACCEPTANCE-PENDING review\n'
  exit 0
fi

case "$mode" in
  # contract §5.4 token is exactly "ACCEPTANCE-PENDING operator" (fix round 1, minor: was
  # printing "ACCEPTANCE-PENDING the operator", which no emitter/consumer/test agreed on).
  operator)    authority="operator" ;;
  *)           authority="the authority named by accept:${mode}" ;;
esac
printf 'ACCEPTANCE-PENDING %s\n' "$authority"
