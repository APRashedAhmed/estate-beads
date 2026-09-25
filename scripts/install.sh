#!/usr/bin/env bash
# install.sh — perform estate-beads's persistent side-effects. Idempotent; saves any prior value before
# clobbering so uninstall.sh can restore it. Non-interactive via --yes / EB_INSTALL_YES.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE_DIR="${EB_STATE_DIR:-$HOME/.claude/state}"
CODEX_AGENTS="${CODEX_HOME:-$HOME/.codex}/agents"   # CODEX_HOME roots all Codex state
# NOTE: if you add a mutation to a shared file (settings.json, git config), save its prior value
#       to a restore breadcrumb first (e.g. "$STATE_DIR/eb-prior-*.txt") iff absent, so
#       uninstall.sh can restore rather than blind-delete.

# --- Codex agent deposit (T1+; skip cleanly when Codex is absent) ---------------
# VIEW is the COMMITTED gen-agents.py output; nothing is generated here (the generator
# lives in the workspace repo and is not shipped beside an installed plugin).
VIEW="$ROOT/adapters/codex/agents"             # tracked generated view (portability-contract.md §"Agent delivery")
PRIOR_DIR="$STATE_DIR/eb/codex-agents.prior"   # scaffolder substitutes the namespace prefix
MARKER="# generated-by: gen-agents.py plugin=estate-beads"
ours() { [ -e "$1" ] && IFS= read -r l < "$1" && [ "$l" = "$MARKER" ]; }
if [ -d "$VIEW" ] && command -v codex >/dev/null 2>&1 && [ -d "${CODEX_HOME:-$HOME/.codex}" ]; then
  mkdir -p "$CODEX_AGENTS" "$PRIOR_DIR"
  for f in "$VIEW"/eb-*.toml; do
    [ -e "$f" ] || continue
    b="$(basename "$f")"; dest="$CODEX_AGENTS/$b"
    # No marker => a third party's file: save it once, OUTSIDE the scanned agents dir.
    # Marker present => our own stale deposit: overwrite, never save as a "prior".
    if [ -e "$dest" ] && ! ours "$dest" && [ ! -e "$PRIOR_DIR/$b" ]; then
      command cp "$dest" "$PRIOR_DIR/$b"
    fi
    command cp "$f" "$dest"
  done
  # reconcile a DROPPED agent (ours, no longer in the view): remove, restore prior if any
  for dest in "$CODEX_AGENTS"/eb-*.toml; do
    [ -e "$dest" ] || continue
    b="$(basename "$dest")"
    [ -e "$VIEW/$b" ] && continue
    ours "$dest" || continue
    if [ -e "$PRIOR_DIR/$b" ]; then command mv "$PRIOR_DIR/$b" "$dest"; else rm -f "$dest"; fi
  done
else
  echo "  (Codex not detected — agent deposit skipped)"
fi

# --- Codex hook-trust notice (any plugin shipping hooks/) ----------------------
if [ -f "$ROOT/hooks/hooks.json" ] && command -v codex >/dev/null 2>&1; then
  cat <<'NOTICE'
NOTE (Codex): plugin hooks are SKIPPED until you review and trust them. Codex records trust
against each hook's hash, so EVERY change to a hook re-arms the review — after any update to
this plugin, re-trust its hooks or they stop running, silently and with no warning.
Review interactively in Codex; --dangerously-bypass-hook-trust is the only documented
non-interactive path and is for fixtures, not for daily use.
Check trust state at any time with: scripts/eb-doctor
NOTICE
fi

echo "✓ estate-beads installed"
echo "  refresh the marketplace cache per guidelines/operations.md §\"Propagate a change\""
