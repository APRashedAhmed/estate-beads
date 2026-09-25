#!/usr/bin/env bash
# check-views.sh — drift gate for this plugin's generated provider views.
#
# Implements portability-contract.md §2 "Canonical layout + generated views": hand-editing a
# generated view is a drift failure, and every plugin runs this from scripts/test.sh.
#
# Dev-tool only: the generators (scripts/gen-manifests.py, scripts/gen-agents.py) live in the
# WORKSPACE repo, not inside an installed plugin clone (lifecycle-contract.md §"Provider
# obligations" #1 — "install.sh runs in the installed clone, where the workspace generator is
# absent"). This script locates them by walking up from the plugin root looking for a sibling
# scripts/gen-*.py (the normal in-workspace layout: <workspace>/<plugin>/scripts/check-views.sh
# -> <workspace>/scripts/gen-*.py). When the plugin doesn't live directly under the workspace
# (a relocated clone, a scratch/smoke scaffold), it SKIPS that check loudly rather than failing
# — override with GEN_MANIFESTS_PY / GEN_AGENTS_PY to point at the real generators explicitly.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="eb"

_find_gen() {  # <script-basename> -> absolute path on stdout, or nothing + exit 1
  local name="$1" d="$ROOT"
  for _ in 1 2 3 4 5; do
    d="$(dirname "$d")"
    if [ -f "$d/scripts/$name" ]; then
      printf '%s\n' "$d/scripts/$name"
      return 0
    fi
  done
  return 1
}

GEN_MANIFESTS="${GEN_MANIFESTS_PY:-}"
[ -n "$GEN_MANIFESTS" ] || GEN_MANIFESTS="$(_find_gen gen-manifests.py || true)"
GEN_AGENTS="${GEN_AGENTS_PY:-}"
[ -n "$GEN_AGENTS" ] || GEN_AGENTS="$(_find_gen gen-agents.py || true)"

# Neither an env override nor the sibling-search found the workspace generators: this is a
# dev-tool-only check and there is nothing to check from here. Loud, not silent (never a bare
# exit 0) — stderr, exact message, so a CI log or a human running scripts/test.sh sees why the
# drift gate did not run rather than reading a quiet pass.
if [ -z "$GEN_MANIFESTS" ]; then
  echo "check-views: skipped — generators not on this machine (workspace-only check)" >&2
  exit 0
fi

fail=0

echo "## check-views: gen-manifests.py --check"
python3 "$GEN_MANIFESTS" "$ROOT" --check || fail=1

if [ -d "$ROOT/agents" ]; then
  if [ -n "$GEN_AGENTS" ] && [ -f "$GEN_AGENTS" ]; then
    echo "## check-views: gen-agents.py --check --prefix $PREFIX"
    python3 "$GEN_AGENTS" "$ROOT" --check --prefix "$PREFIX" || fail=1
  else
    echo "check-views: gen-agents.py not found even though gen-manifests.py was (unexpected layout) — skipping that check" >&2
  fi
fi

if [ "$fail" -eq 0 ]; then
  echo "check-views: no drift"
  exit 0
else
  echo "check-views: DRIFT DETECTED"
  exit 1
fi
