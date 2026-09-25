#!/usr/bin/env bash
# The faithful read path: bd show --json, indexed at [0], projected to a fixed shape.
set -euo pipefail

SELF="bead-read"
die() { printf '%s: %s\n' "$SELF" "$1" >&2; exit "${2:-1}"; }

id=""; resume=0; next=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --id)     id="${2-}"; shift 2 ;;
    --resume) resume=1; shift ;;
    --next)   next=1; shift ;;
    *) die "unknown flag '$1'. Flags: --id <bead-id> [--resume] [--next]" ;;
  esac
done
[[ -n "$id" ]] || die "missing required --id."
command -v jq >/dev/null || die "jq not on PATH. Install jq, then re-run."

raw="$(bd show --json "$id")" || die "'bd show --json $id' failed. Confirm the id, then re-run."
bead="$(printf '%s' "$raw" | jq '.[0]')"
[[ "$bead" != "null" && -n "$bead" ]] || die "no Bead '$id' in the database. Confirm the id, then re-run."

if [[ "$next" -eq 1 ]]; then
  # bead-progress.sh writes the rule-5 block as a fixed three-line `notes`
  # rewrite; the last line is always `NEXT: <value>`. Print the value alone —
  # no framing — so a resumer can read it without parsing.
  n="$(printf '%s' "$bead" | jq -r '(.notes // "") | split("\n") | map(select(startswith("NEXT: "))) | last // empty')"
  [[ -n "$n" ]] || die "no 'NEXT: ' line in notes for '$id'. Confirm bead-progress.sh has run, then re-run."
  printf '%s\n' "${n#NEXT: }"
  exit 0
fi

printf '%s' "$bead" | jq -r '
  "id:           \(.id)",
  "title:        \(.title)",
  "status:       \(.status)",
  "assignee:     \(.assignee // .owner // "-")",
  "labels:       \((.labels // []) | join(", "))",
  "metadata:     \((.metadata // {}) | to_entries | map("\(.key)=\(.value|if type=="array" then join(";") else tostring end)") | join(" | "))",
  "dependencies: \((.dependencies // []) | map("\(.dependency_type):\(.id)") | join(", "))",
  "design:       \(if (.design // "") == "" then "unset" else "set (read with: bd show --json \(.id) | jq -r '.[0].design')" end)",
  "notes:",
  ((.notes // "(none)") | split("\n") | map("  " + .) | join("\n"))'

if [[ "$resume" -eq 1 ]]; then
  wu="$(printf '%s' "$bead" | jq -r '.metadata.workunit // ""')"
  printf 'workunit:     %s\n' "${wu:-(none)}"
  printf 'resume order: this Bead, then the work-unit handoff, then the work-unit anchor.\n'
fi
