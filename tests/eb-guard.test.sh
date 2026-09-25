#!/usr/bin/env bash
# eb-guard.test.sh — fixture-driven test for scripts/eb-guard.py (design §12.1, plan U3 decision
# table). One fixture per tests/fixtures/guard/*.json row; each fixture is fed to the guard as a
# real PreToolUse stdin payload (never a mocked internal call) and the observed verdict is
# compared against the fixture's `expect`/`reason_contains`. Prints one
# "fixture -> observed verdict" line per file so the U3 report's decision table is a paste.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GUARD="$ROOT/scripts/eb-guard.py"
FIXDIR="$ROOT/tests/fixtures/guard"

# shellcheck source=_assert.sh
source "$ROOT/tests/_assert.sh"
# shellcheck source=_scratch_db.sh
source "$ROOT/tests/_scratch_db.sh"

GENERIC_CWD="$(mktemp -d)"
NONGIT_CWD="$(mktemp -d)"
GIT_CWD="$ROOT"

# A scratch db with one open and one closed Bead, for the `--status open` checks that need a
# live `bd show`.
scratch=""
eb_scratch_db scratch
OPEN_JSON="$(bd create "guard test open" --type task -p 2 --json)"
OPEN_ID="$(printf '%s' "$OPEN_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
CLOSED_JSON="$(bd create "guard test closed" --type task -p 2 --json)"
CLOSED_ID="$(printf '%s' "$CLOSED_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
bd close "$CLOSED_ID" --json >/dev/null
SCRATCH_CWD="$scratch/db"

run_fixture() {  # <fixture-json-path>
  local fx="$1"
  python3 - "$fx" "$GENERIC_CWD" "$NONGIT_CWD" "$GIT_CWD" "$SCRATCH_CWD" "$OPEN_ID" "$CLOSED_ID" "$GUARD" <<'PYEOF'
import json, subprocess, sys

fx_path, generic_cwd, nongit_cwd, git_cwd, scratch_cwd, open_id, closed_id, guard = sys.argv[1:9]
fx = json.load(open(fx_path))

def sub(s):
    return (s.replace("__NONGIT_CWD__", nongit_cwd)
              .replace("__GIT_CWD__", git_cwd)
              .replace("__SCRATCH_CWD__", scratch_cwd)
              .replace("__CWD__", generic_cwd)
              .replace("__OPEN_ID__", open_id)
              .replace("__CLOSED_ID__", closed_id))

command = sub(fx["command"])
cwd = sub(fx["cwd"])
payload = json.dumps({
    "session_id": "guard-test",
    "cwd": cwd,
    "hook_event_name": "PreToolUse",
    "tool_name": "Bash",
    "tool_input": {"command": command},
    "transcript_path": None,
})

r = subprocess.run(["python3", guard], input=payload, capture_output=True, text=True)
stdout = r.stdout.strip()

observed = "allow" if stdout == "" else "deny"
reason = ""
if observed == "deny":
    try:
        reason = json.loads(stdout)["hookSpecificOutput"]["permissionDecisionReason"]
    except Exception:
        reason = "<unparseable deny envelope>"

print(f"FIXTURE_RESULT\t{fx['id']}\t{fx['expect']}\t{observed}\t{r.returncode}\t{reason}")
PYEOF
}

echo "## eb-guard.py decision-table fixtures"
declare -i any_fail=0
for fx in "$FIXDIR"/*.json; do
  [[ -f "$fx" ]] || continue
  line="$(run_fixture "$fx")"
  # line: FIXTURE_RESULT<TAB>id<TAB>expect<TAB>observed<TAB>rc<TAB>reason
  IFS=$'\t' read -r _tag id expect observed rc reason <<<"$line"
  printf '%s -> expect=%s observed=%s rc=%s\n' "$id" "$expect" "$observed" "$rc"
  assert_eq "$id: verdict" "$expect" "$observed"
  assert_eq "$id: exit code always 0 (verdict, not a hook crash)" "0" "$rc"
  if [[ "$expect" == "deny" ]]; then
    reason_contains="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("reason_contains",""))' "$fx")"
    if [[ -n "$reason_contains" ]]; then
      assert_contains "$id: deny reason names the replacement" "$reason" "$reason_contains"
    fi
  fi
done

rm -rf "$scratch" "$GENERIC_CWD" "$NONGIT_CWD"
eb_report
