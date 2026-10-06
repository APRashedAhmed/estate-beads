#!/usr/bin/env bash
# Dynamic-context preflight for the beads skill's `## Now` placeholder.
# ALWAYS exits 0 — this augments context, it never blocks invocation.
# Emits at most ~6 lines, no descriptions/notes/JSON, no bd stderr (silences
# the beads.role warning so it never lands in context).
set -u

SELF="bead-context"
# shellcheck source=lib/eb-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/eb-common.sh"

if [[ -z "${BEADS_DIR:-}" ]]; then
  printf 'database: none ($BEADS_DIR unset)\n'
  exit 0
fi

if ! bd info >/dev/null 2>&1; then
  printf 'database: none (%s does not resolve to a bd database)\n' "$BEADS_DIR"
  exit 0
fi
printf 'database: %s\n' "$BEADS_DIR"

# Actor resolution mirrors bd's own precedence (see `bd --help`):
# --actor default is $BEADS_ACTOR, then git user.name, then $USER.
actor="${BEADS_ACTOR:-}"
if [[ -z "$actor" ]]; then
  actor="$(git config user.name 2>/dev/null || true)"
fi
[[ -n "$actor" ]] || actor="${USER:-}"

if [[ -z "$actor" ]]; then
  printf 'claimed: none\n'
  exit 0
fi

if ! eb_bd json list --assignee "$actor" --json 2>/dev/null; then
  # A failed list is not "none claimed": say it is unknown, with the tracker's own error.
  printf 'claimed: unknown (bd list failed: %s)\n' "${EB_BD_ERROR:-<unknown>}"
  exit 0
fi
if [[ -z "$json" ]]; then
  printf 'claimed: none\n'
  exit 0
fi

lines="$(printf '%s' "$json" | jq -r '.[]? | "\(.id) — \(.title) — \(.status)"' 2>/dev/null || true)"

if [[ -z "$lines" ]]; then
  printf 'claimed: none\n'
  exit 0
fi

count="$(printf '%s\n' "$lines" | wc -l | tr -d ' ')"
if [[ "$count" -gt 5 ]]; then
  printf '%s\n' "$lines" | head -5
  printf '… +%d more\n' "$((count - 5))"
else
  printf '%s\n' "$lines"
fi

exit 0
