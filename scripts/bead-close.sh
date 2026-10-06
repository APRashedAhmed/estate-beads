#!/usr/bin/env bash
# The closer for the §5.4 close reasons other than `accepted` (design §14; contract §5.4/§5.5).
# `bead-accept.sh` is the sole closer for `accepted`; this script never touches that path and
# refuses outright if asked to (`--reason accepted`).
#
#   bead-close.sh --id <id> --reason <superseded|duplicate|abandoned|infeasible|declined> \
#                 --note "<text>" [--ref <bead-id>] [--evidence <path>] [--operator]
#
# Gates (contract §5.4 "Who may close"):
#   superseded  requires --ref <other-bead-id> (verified to exist); actor gate SAME AS abandoned
#               (recognized-by owner or the operator). Close reason: "superseded: <ref> — <note>".
#   duplicate   requires --ref <other-bead-id> (verified to exist); ANY actor may close it
#               (contract: "any actor who verifies the duplication"). Close reason:
#               "duplicate: <ref> — <note>".
#   abandoned   the recognition source's owner or the operator. This script can verify only
#               --operator; `recognized-by` (contract §6.1) is a citation (journal id, artifact
#               path, Bead id), never an actor identity, so an owner-identity check is not
#               mechanically possible — documented here, not invented. An executor (actor ==
#               the Bead's own assignee) is refused outright per contract §5.4: "An executor
#               never closes a Bead abandoned; it releases the claim and proposes abandonment
#               in a note", pointed at bead-release.sh --note.
#   infeasible  same actor gate as abandoned, PLUS --evidence <path> (an existing file) recorded
#               on the EVIDENCE line ("Evidence shows the work cannot be done as recognized").
#   declined    contract §1.2/§5.4: "the operator at a recorded selection act, on the
#               owning project's proposal; an agent only when executing that recorded ruling;
#               never the audit walk". `lapsed` (the reason named in this Bead's original
#               brief) was retired by Operator direction (2026-09-26; contract §5.4) in favor of `declined`
#               before this unit landed — see README.md "Known gaps" for the full note. This
#               script cannot verify the recorded selection act beyond the --operator flag, which
#               it requires as the closest mechanical proxy available; `--reason lapsed` is
#               refused outright, naming `declined` as the replacement.
#
# Refused unconditionally: `--reason accepted` (use bead-accept.sh) and open blockers
# (BLOCKED-BY, same check as bead-accept.sh's eb_open_blockers) and open A4 children (contract
# §1.2 rule 3: a non-accepted close must close every open child with the same reason in the same
# action; this script does not cascade, so it refuses rather than leave rule 3 silently violated).
#
# Decision vocabulary on stdout, one line:
#   CLOSED <reason> | BLOCKED-BY <ids> | REFUSED <why>   (exit 1 on the last two)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="bead-close"
die() { printf '%s: %s\n' "$SELF" "$1" >&2; exit "${2:-1}"; }
refused() { printf 'REFUSED %s\n' "$1"; exit 1; }

# shellcheck source=lib/eb-common.sh
source "$SCRIPT_DIR/lib/eb-common.sh"

id=""; reason=""; note=""; ref=""; evidence=""; operator=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --id)       [[ $# -ge 2 ]] || die "--id requires a value. Usage: --id <bead-id>."; id="$2"; shift 2 ;;
    --reason)   [[ $# -ge 2 ]] || die "--reason requires a value. Usage: --reason <superseded|duplicate|abandoned|infeasible|declined>."; reason="$2"; shift 2 ;;
    --note)     [[ $# -ge 2 ]] || die "--note requires a value. Usage: --note '<text>'."; note="$2"; shift 2 ;;
    --ref)      [[ $# -ge 2 ]] || die "--ref requires a value. Usage: --ref <bead-id>."; ref="$2"; shift 2 ;;
    --evidence) [[ $# -ge 2 ]] || die "--evidence requires a value. Usage: --evidence <path>."; evidence="$2"; shift 2 ;;
    --operator) operator=1; shift ;;
    *) die "unknown flag '$1'. Flags: --id <bead-id> --reason <superseded|duplicate|abandoned|infeasible|declined> --note '<text>' [--ref <bead-id>] [--evidence <path>] [--operator]" ;;
  esac
done
[[ -n "$id"     ]] || die "missing required --id."
[[ -n "$reason" ]] || die "missing required --reason <superseded|duplicate|abandoned|infeasible|declined>."
[[ -n "$note"   ]] || die "missing required --note '<text>'."
command -v jq >/dev/null || die "jq not on PATH. Install jq, then re-run."

bead_json() {  # <id> <out-var> -> the bead object in out-var; rc 1 on failure, cause printed + in EB_BD_ERROR
  local raw b
  eb_bd raw show --json "$1" || return 1
  b="$(printf '%s' "$raw" | jq '.[0]')"
  [[ "$b" != "null" && -n "$b" ]] || { EB_BD_ERROR="no issue found matching \"$1\""; return 1; }
  printf -v "$2" '%s' "$b"
}

case "$reason" in
  superseded|duplicate|abandoned|infeasible|declined) ;;
  accepted) refused "accepted closes through bead-accept.sh, not this script (contract §5.3/§5.4)." ;;
  lapsed)
    refused "lapsed is retired as a close reason (contract §5.4, Operator direction 2026-09-26); use --reason declined on a recorded selection act instead."
    ;;
  *) die "unknown --reason '$reason'. Valid: superseded|duplicate|abandoned|infeasible|declined." ;;
esac

bead_json "$id" bead || die "$(eb_show_remedy "$id")"
status="$(printf '%s' "$bead" | jq -r '.status')"
[[ "$status" != "closed" ]] || refused "Bead $id is already closed."

# --- reason-specific requirements -----------------------------------------------------------
if [[ "$reason" == superseded || "$reason" == duplicate ]]; then
  [[ -n "$ref" ]] || refused "$reason requires --ref <bead-id> naming the other Bead (contract §5.4)."
  [[ "$ref" != "$id" ]] || refused "--ref must name a different Bead, not $id itself."
  bead_json "$ref" ref_bead || {
    eb_bd_not_found && refused "--ref '$ref' does not exist. Confirm the id, then re-run."
    die "$(eb_show_remedy "$ref")"
  }
  ref_status="$(printf '%s' "$ref_bead" | jq -r '.status')"
  [[ "$ref_status" == "open" || "$ref_status" == "in_progress" ]] \
    || refused "--ref '$ref' is $ref_status, not open or in_progress; $reason must name a Bead that replaces or duplicates live work."
fi

if [[ "$reason" == infeasible ]]; then
  [[ -n "$evidence" ]] || refused "infeasible requires --evidence <path> (contract §5.4: 'Evidence shows the work cannot be done as recognized')."
  [[ -f "$evidence" ]] || refused "--evidence '$evidence' does not exist. Confirm the path, then re-run."
fi

if [[ "$reason" == declined ]]; then
  [[ "$operator" -eq 1 ]] || refused "declined is closed only on a recorded selection act (contract §1.2/§5.4: 'the operator at a recorded selection act, on the owning project's proposal; an agent only when executing that recorded ruling; never the audit walk'); pass --operator, the only mechanical proxy this script can check."
fi

# --- actor gate: abandoned, infeasible, superseded (contract §5.4: "same as abandoned") -----
if [[ "$reason" == abandoned || "$reason" == infeasible || "$reason" == superseded ]]; then
  if [[ "$operator" -ne 1 ]]; then
    assignee="$(printf '%s' "$bead" | jq -r '.assignee // ""')"
    actor="${BEADS_ACTOR:-}"
    if [[ -n "$assignee" && -n "$actor" && "$assignee" == "$actor" ]]; then
      refused "the executor cannot close '$reason' (contract §5.4: 'An executor never closes a Bead abandoned; it releases the claim and proposes abandonment in a note'). Release the claim and propose it in a note: bead-release.sh --id $id --note '<why $reason>'."
    fi
    refused "$reason requires --operator, or verified standing as the recognition source's owner (contract §5.4). 'recognized-by' (contract §6.1) is a citation — a journal id, artifact path, or Bead id — never an actor identity, so this script cannot verify owner standing; it refuses without --operator."
  fi
fi
# duplicate: contract §5.4 "any actor who verifies the duplication" — no actor gate.

# --- open blockers (same check bead-accept.sh runs; refuse atomically, nothing changed) -----
blockers="$(eb_open_blockers "$id")" || die "'bd show --json $id' failed while checking blockers. Nothing was changed."
if [[ -n "$blockers" ]]; then
  printf 'BLOCKED-BY %s\n' "$blockers"
  exit 1
fi

# --- open A4 children (contract §1.2 rule 3) ------------------------------------------------
eb_bd children_json show --json --children "$id" \
  || die "'bd show --json --children $id' failed while checking children (cause above). Nothing was changed."
open_children="$(printf '%s' "$children_json" \
  | jq -r --arg id "$id" '(.[$id] // []) | map(select(.status != "closed")) | map(.id) | join(",")')"
if [[ -n "$open_children" ]]; then
  refused "open children $open_children (contract §1.2 rule 3: a non-accepted close must close every open A4 child with the same reason in the same action; this script does not cascade — close or re-recognize them first)."
fi

# --- build the close reason and perform the close, atomic-as-BLOCKED-BY restore ------------
case "$reason" in
  superseded|duplicate) close_reason="${reason}: ${ref} — ${note}" ;;
  *)                    close_reason="${reason}: ${note}" ;;
esac

evidence_line=""
[[ "$reason" == infeasible ]] && evidence_line="EVIDENCE: ${evidence}"

orig_notes="$(printf '%s' "$bead" | jq -r '.notes // ""')"
assignee="$(printf '%s' "$bead" | jq -r '.assignee // ""')"
actor="${BEADS_ACTOR:-}"
close_args=(--reason "$close_reason")
# Same cross-actor rule as bead-accept.sh's eb_close_or_restore: --force only when the actor
# differs from the recorded assignee (an operator or a non-executor owner closing someone
# else's claimed Bead), never unconditionally.
[[ -n "$assignee" && "$assignee" != "$actor" ]] && close_args+=(--force)

if [[ -n "$evidence_line" ]]; then
  bd update "$id" --append-notes "$evidence_line" >/dev/null \
    || die "'bd update $id --append-notes' failed. Fix the reported cause and re-run; nothing was changed."
fi

if ! bd close "$id" "${close_args[@]}" >/dev/null; then
  if [[ -n "$evidence_line" ]]; then
    if ! bd update "$id" --notes "$orig_notes" >/dev/null 2>&1; then
      printf 'RESTORE-FAILED %s: bd close failed AND restoring the pre-EVIDENCE notes also failed. Check %s'"'"'s notes for a dangling "%s" line; if present, remove it by hand: bd update %s --notes "<notes without that line>".\n' \
        "$id" "$id" "$evidence_line" "$id" >&2
      exit 2
    fi
    die "'bd close $id' failed; restored notes to their pre-EVIDENCE state. Fix the reported cause, then re-run: bead-close.sh --id $id --reason $reason --note '$note' --evidence $evidence"
  fi
  die "'bd close $id' failed; nothing was changed. Fix the reported cause, then re-run."
fi

# Rule-5 block, --preserve (keeps COMPLETED/workunit/any EVIDENCE line verbatim; only
# IN-PROGRESS/NEXT are rewritten). A failure here is reported but does not undo the close: the
# Bead is closed correctly in bd; only its rule-5 note is stale, same class of gap
# bead-accept.sh's HALT/FAIL paths already accept.
"$SCRIPT_DIR/bead-progress.sh" --id "$id" --preserve \
  --in-progress "closed: ${reason}" --next "n/a — closed ${reason}" \
  || printf '%s: the Bead closed but the rule-5 note failed to write. Run: %s/bead-progress.sh --id %s --preserve --in-progress "closed: %s" --next "n/a — closed %s"\n' \
    "$SELF" "$SCRIPT_DIR" "$id" "$reason" "$reason" >&2

printf 'CLOSED %s\n' "$reason"
