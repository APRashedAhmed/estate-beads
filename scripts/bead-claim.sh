#!/usr/bin/env bash
# Claim a Bead and absorb the exit-code branch.
# Decision vocabulary on stdout, one word: CLAIMED | LOST. Skill prose branches on it.
set -euo pipefail

SELF="bead-claim"
die() { printf '%s: %s\n' "$SELF" "$1" >&2; exit "${2:-1}"; }

id=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --id) id="${2-}"; shift 2 ;;
    *) die "unknown flag '$1'. Flags: --id <bead-id>" ;;
  esac
done
[[ -n "$id" ]] || die "missing required --id."

set +e
out="$(bd update "$id" --claim 2>&1)"
rc=$?
set -e

if [[ "$rc" -eq 0 ]]; then
  printf 'CLAIMED\n'
  exit 0
fi

# A lost race is non-zero. Distinguish it from a real error so the caller does not
# treat a broken database as a lost race.
if printf '%s' "$out" | grep -qiE 'claim|assigned|in.progress|already'; then
  printf 'LOST\n'
  exit 0
fi

printf '%s: bd update --claim failed for a reason other than a lost race:\n%s\n' "$SELF" "$out" >&2
die "fix the reported cause, then re-run." "$rc"
