#!/usr/bin/env bash
# tests/acceptance/codex/run.sh — end-to-end acceptance stub (portability-contract.md §9
# "Two-tier testing"). SKIPS (exit 0), never fails, when `codex` isn't on PATH. A real Codex
# drive of this stub uses `--dangerously-bypass-hook-trust` — the only non-interactive trust
# path (§5.6, probe P-B) — and must never hardcode a model (`-m ...` is rejected outright on a
# ChatGPT-account Codex, probe P-B/P-E); use the config default. This stub itself only pipes
# one fixture PreToolUse event through the shim and asserts an envelope — it does not invoke
# `codex exec`, so it never counts as "the Codex install probe" (that is the verifier's job,
# per the WP4 brief; do not add a live `codex` invocation here without that context).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"

if ! command -v codex >/dev/null 2>&1; then
  echo "SKIP: codex not on PATH"
  exit 0
fi

FIXTURE='{"session_id":"acceptance-fixture","cwd":"'"$ROOT"'","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo hi"},"transcript_path":null,"permission_mode":"default","turn_id":"acceptance-fixture","model":null}'
OUT="$(printf '%s' "$FIXTURE" | "$ROOT/hooks/eb-shim.sh")"
RC=$?
echo "$OUT"
if [ "$RC" -ne 0 ]; then
  echo "FAIL: shim exited $RC"
  exit 1
fi
echo "OK: shim ran under a fixture PreToolUse event"
