#!/usr/bin/env bash
# tests/acceptance/claude-code/run.sh — end-to-end acceptance stub (portability-contract.md §9
# "Two-tier testing"). SKIPS (exit 0), never fails, when `claude` isn't on PATH — harness
# absence is not a test failure. Otherwise pipes one fixture PreToolUse event through the shim
# and asserts it renders an envelope. Extend this to drive a real `claude` session as the
# plugin's hook surface grows past the scaffolded single shim.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"

if ! command -v claude >/dev/null 2>&1; then
  echo "SKIP: claude not on PATH"
  exit 0
fi

FIXTURE='{"session_id":"acceptance-fixture","cwd":"'"$ROOT"'","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo hi"},"transcript_path":null}'
OUT="$(printf '%s' "$FIXTURE" | "$ROOT/hooks/eb-shim.sh")"
RC=$?
echo "$OUT"
if [ "$RC" -ne 0 ]; then
  echo "FAIL: shim exited $RC"
  exit 1
fi
echo "OK: shim ran under a fixture PreToolUse event"
