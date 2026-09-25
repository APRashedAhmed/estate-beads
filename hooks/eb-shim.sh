#!/usr/bin/env bash
# eb-shim.sh — PreToolUse (Bash) transport shim (portability-contract.md §5 "Hook
# contract", §8 "Semantic-verdict parity"): read stdin, resolve roots, hand off to the engine,
# render its verdict as-is. No policy lives here. Engine ABSENT -> fail-open, exit 0 + stderr.
# Engine ran and exited 0 or 2 (the only recognized verdict forms, §5.3) -> pass through as-is.
# Any OTHER exit is a CRASH, not a verdict -> normalized to exit 2 + stderr (§7 "Engine/
# evaluator failure": fail closed). <ENVPREFIX>_ENGINE (PREFIX uppercased, hyphens->underscores,
# computed below — never a second scaffold placeholder) overrides the engine path; hermetic
# tests point this at a fixture engine without touching the plugin tree.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(dirname "$HERE")"
PREFIX="eb"
ENVPREFIX="$(printf '%s' "$PREFIX" | tr 'a-z-' 'A-Z_')"
ENGINE_VAR="${ENVPREFIX}_ENGINE"
ENGINE="${!ENGINE_VAR:-$PLUGIN_ROOT/lib/${PREFIX}_engine.py}"
ROOT_TWIN="$PLUGIN_ROOT/bin/$PREFIX-root.sh"

INPUT="$(cat)"

if [ ! -f "$ENGINE" ]; then
  echo "$PREFIX-shim: no engine at $ENGINE — fail-open (allow)" >&2
  exit 0
fi

CWD="$(printf '%s' "$INPUT" | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin).get("cwd") or "")
except Exception:
    print("")' 2>/dev/null)"
PROJECT_ROOT="$("$ROOT_TWIN" --cwd "$CWD" project 2>/dev/null || true)"

printf '%s' "$INPUT" | python3 "$ENGINE" --project-root "$PROJECT_ROOT"
RC=$?
if [ "$RC" -eq 0 ] || [ "$RC" -eq 2 ]; then
  exit "$RC"
fi
echo "$PREFIX-shim: engine $ENGINE crashed (exit $RC, not a recognized verdict) — fail-closed (deny)" >&2
exit 2
