#!/usr/bin/env bash
# Release a claim (rules 7/10): return the Bead to open, unassign it, and record the release
# note through the rule-5 progress block (never a raw `bd update --append-notes`).
# Decision vocabulary on stdout, one word: RELEASED.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="bead-release"
die() { printf '%s: %s\n' "$SELF" "$1" >&2; exit "${2:-1}"; }

# shellcheck source=lib/eb-common.sh
source "$SCRIPT_DIR/lib/eb-common.sh"

id=""; note=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --id)   id="${2-}"; shift 2 ;;
    --note) note="${2-}"; shift 2 ;;
    *) die "unknown flag '$1'. Flags: --id <bead-id> --note '<why released>'" ;;
  esac
done
[[ -n "$id"   ]] || die "missing required --id."
[[ -n "$note" ]] || die "missing required --note."
command -v jq >/dev/null || die "jq not on PATH. Install jq, then re-run."

raw="$(bd show --json "$id")" || die "'bd show --json $id' failed. Confirm the id, then re-run."
bead="$(printf '%s' "$raw" | jq '.[0]')"
[[ "$bead" != "null" && -n "$bead" ]] || die "no Bead '$id' in the database. Confirm the id, then re-run."

# Read the rule-5 progress block so NEXT survives the release; bead-progress.sh --preserve keeps
# COMPLETED/workunit/other lines verbatim and only IN-PROGRESS carries the release note.
notes="$(printf '%s' "$bead" | jq -r '.notes // ""')"
next="$(printf '%s' "$notes" | awk -F': ' '/^NEXT: /{sub(/^NEXT: /,""); print; exit}')"
[[ -n "$next" ]] || next="(none — released before a next step was recorded)"

bd update "$id" --status open --assignee "" >/dev/null \
  || die "'bd update $id --status open --assignee \"\"' failed. Fix the reported cause, then re-run; nothing was changed."

"$SCRIPT_DIR/bead-progress.sh" --id "$id" --preserve \
  --in-progress "released: ${note}" \
  --next "$next" \
  || die "the claim was released but the rule-5 note failed to write. Run: $SCRIPT_DIR/bead-progress.sh --id $id --preserve --in-progress 'released: $note' --next '$next'"

printf 'RELEASED\n'
