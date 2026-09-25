#!/usr/bin/env bash
# precommit-audit.sh — pre-commit hook: run the workspace plugin-convention audit (self-contained
# --local checks) on THIS plugin. Resolves the workspace audit script via $PLUGINS_WORKSPACE, else
# the parent dir (plugins nest in the workspace). SKIPS LOUDLY (warn, non-blocking) if the script
# isn't reachable, so a standalone clone with no workspace doesn't hard-fail the commit.
# Installed/updated by the workspace's scripts/add-precommit-audit.sh — edit there, not here.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AUDIT="${PLUGINS_WORKSPACE:-$(cd "$ROOT/.." && pwd)}/scripts/audit-plugin.sh"
if [ -x "$AUDIT" ]; then
  exec "$AUDIT" --local "$ROOT"
else
  echo "⚠ plugin-convention-audit skipped: audit-plugin.sh not reachable at $AUDIT" >&2
  echo "  (set PLUGINS_WORKSPACE to the plugins workspace root to enable it)" >&2
  exit 0
fi
