#!/usr/bin/env bash
# uninstall.sh — reverse install.sh's MECHANISM. Idempotent (safe when not installed / run twice).
# Preserves accumulated user data by default; --purge-data removes it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE_DIR="${EB_STATE_DIR:-$HOME/.claude/state}"
CODEX_AGENTS="${CODEX_HOME:-$HOME/.codex}/agents"
PURGE=0; [ "${1:-}" = "--purge-data" ] && PURGE=1
# --- Codex agent deposit: remove only MARKER-BEARING files of ours, restore priors --
PRIOR_DIR="$STATE_DIR/eb/codex-agents.prior"
MARKER="# generated-by: gen-agents.py plugin=estate-beads"
ours() { [ -e "$1" ] && IFS= read -r l < "$1" && [ "$l" = "$MARKER" ]; }
if [ -d "$CODEX_AGENTS" ]; then
  for dest in "$CODEX_AGENTS"/eb-*.toml; do
    ours "$dest" || continue          # prefix match alone is not ownership
    prior="$PRIOR_DIR/$(basename "$dest")"
    if [ -e "$prior" ]; then command mv "$prior" "$dest"; else rm -f "$dest"; fi
  done
  rmdir "$PRIOR_DIR" 2>/dev/null || true
fi

# TODO: restore saved prior values (settings.json, git config) instead of blind-deleting; remove
#       launchers / descriptors / mechanism files this plugin owns. Where mechanism + data share a
#       directory, delete by file-class (keep the data files).
if [ "$PURGE" -eq 1 ]; then
  : # TODO: remove accumulated user data here
else
  echo "  (user data preserved; re-run with --purge-data to remove)"
fi
echo "✓ estate-beads uninstalled (mechanism removed)"
