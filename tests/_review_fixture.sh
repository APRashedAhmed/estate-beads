#!/usr/bin/env bash
# _review_fixture.sh — write a review-verdict report with YAML frontmatter for accept/reopen tests.
# Leading underscore, no test_/.test.sh suffix: never discovered by scripts/test.sh.
set -uo pipefail

eb_write_review() {  # <path> <bead> <verdict> <reviewer-model> <spawn> <prior|""> [reason]
  local path="$1" bead="$2" verdict="$3" rmodel="$4" spawn="$5" prior="$6" reason="${7:-}"
  {
    printf -- '---\n'
    printf 'bead: %s\n' "$bead"
    printf 'verdict: %s\n' "$verdict"
    printf 'reviewer:\n  model: %s\n  effort: medium\n' "$rmodel"
    printf 'spawn: %s\n' "$spawn"
    if [[ -n "$prior" ]]; then printf 'prior: %s\n' "$prior"; else printf 'prior: ~\n'; fi
    [[ -n "$reason" ]] && printf 'reason: %s\n' "$reason"
    printf -- '---\n# Review report\n'
  } > "$path"
}
