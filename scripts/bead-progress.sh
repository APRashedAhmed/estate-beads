#!/usr/bin/env bash
# Write the rule-5 progress block. Always --notes (replace), never --append-notes,
# so a notes history is structurally unreachable.
#
# --preserve: for writers (bead-accept.sh's FAIL/HALT/INCOMPLETE paths, bead-release.sh) that must
# rewrite only IN-PROGRESS/NEXT without clobbering the rest of the existing block. Keeps the
# existing COMPLETED line, the workunit line, and any other surviving line (e.g. EVIDENCE:)
# verbatim; only IN-PROGRESS and NEXT are replaced. --completed is then optional and only used as
# the COMPLETED fallback when the existing block has none.
set -euo pipefail

SELF="bead-progress"
die() { printf '%s: %s\n' "$SELF" "$1" >&2; exit "${2:-1}"; }

id=""; completed=""; in_progress=""; next=""; design_file=""; preserve=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --id)          id="${2-}"; shift 2 ;;
    --completed)   completed="${2-}"; shift 2 ;;
    --in-progress) in_progress="${2-}"; shift 2 ;;
    --next)        next="${2-}"; shift 2 ;;
    --design-file) design_file="${2-}"; shift 2 ;;
    --preserve)    preserve=1; shift 1 ;;
    *) die "unknown flag '$1'. Flags: --id --completed --in-progress --next [--design-file <path>] [--preserve]" ;;
  esac
done
[[ -n "$id"          ]] || die "missing required --id."
[[ "$preserve" -eq 1 ]] || [[ -n "$completed" ]] || die "missing required --completed."
[[ -n "$in_progress" ]] || die "missing required --in-progress."
[[ -n "$next"        ]] || die "missing required --next."
command -v jq >/dev/null || die "jq not on PATH. Install jq, then re-run."

for f in completed in_progress next; do
  if [[ "${!f}" == *$'\n'* ]]; then
    die "--${f//_/-} must be one line. Put the long form in a file and pass --design-file; have --next summarise it."
  fi
done
if [[ -n "$design_file" && ! -f "$design_file" ]]; then
  die "--design-file '$design_file' does not exist. Write it, then re-run."
fi

raw="$(bd show --json "$id")" || die "'bd show --json $id' failed. Confirm the id, then re-run."

if [[ "$preserve" -eq 1 ]]; then
  existing="$(printf '%s' "$raw" | jq -r '.[0].notes // ""')"
  completed_line="$(printf '%s\n' "$existing" | grep '^COMPLETED: ' | tail -n1 || true)"
  [[ -n "$completed_line" ]] || completed_line="COMPLETED: ${completed:-(none)}"
  extra_lines="$(printf '%s\n' "$existing" | grep -v '^COMPLETED: ' | grep -v '^IN-PROGRESS: ' | grep -v '^NEXT: ' || true)"
  block="${completed_line}
IN-PROGRESS: ${in_progress}
NEXT: ${next}"
  [[ -n "$extra_lines" ]] && block="${block}
${extra_lines}"
else
  wu="$(printf '%s' "$raw" | jq -r '.[0].metadata.workunit // ""')"
  block="COMPLETED: ${completed}
IN-PROGRESS: ${in_progress}
NEXT: ${next}"
  [[ -n "$wu" ]] && block="${block}
workunit: ${wu}"
fi

cmd=(bd update "$id" --notes "$block")
[[ -n "$design_file" ]] && cmd+=(--design-file "$design_file")
"${cmd[@]}" >/dev/null || die "'bd update $id --notes …' failed. Fix the reported cause and re-run; notes were not changed."
