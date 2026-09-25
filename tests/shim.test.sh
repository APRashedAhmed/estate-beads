#!/usr/bin/env bash
# shim.test.sh — hermetic test for hooks/eb-shim.sh and the lib/eb_root.py /
# bin/eb-root.sh twin. Implements portability-contract.md §9 "Two-tier testing",
# hermetic tier: "shim contract by piping fixture stdin JSON and asserting the rendered
# envelope" and "root-twin byte-identical stdout". Named *.test.sh so scripts/test.sh's own
# suite discovery picks it up automatically — no explicit wiring needed there.
#
# NEVER MUTATES THE PLUGIN TREE. A bare scaffold ships no lib/eb_engine.py — the engine
# is the plugin author's policy, out of scope for the scaffolder (portability-contract.md §8
# "the engine owns the verdict") — so every fixture engine here lives in a mktemp dir and is
# wired in purely via the shim's <ENVPREFIX>_ENGINE env override, never by writing into lib/.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SHIM="$ROOT/hooks/eb-shim.sh"
PREFIX="eb"
ENVPREFIX="$(printf '%s' "$PREFIX" | tr 'a-z-' 'A-Z_')"
ENGINE_VAR="${ENVPREFIX}_ENGINE"
DENY_MARKER="eb_DENY"
pass=0; fail=0
ok(){ if eval "$2"; then printf '  ok  %s\n' "$1"; pass=$((pass+1)); else printf '  XX  %s\n' "$1"; fail=$((fail+1)); fi; }

FIXTMP="$(mktemp -d)"; trap 'rm -rf "$FIXTMP"' EXIT

fixture() {  # <command-string> -> a PreToolUse stdin JSON fixture on stdout
  printf '{"session_id":"shim-test","cwd":"%s","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"%s"},"transcript_path":null}' "$ROOT" "$1"
}

# --- 1. allow path: no engine configured -> fail-open (the shim's documented default) --------
unset "$ENGINE_VAR" 2>/dev/null || true
OUT_ALLOW="$(fixture 'echo hi' | env -u "$ENGINE_VAR" bash "$SHIM")"; RC_ALLOW=$?
ok "allow: shim fails open, exit 0, with no engine"        '[ "$RC_ALLOW" -eq 0 ]'
ok "allow: fail-open note goes to stderr, not the envelope" '! printf "%s" "$OUT_ALLOW" | grep -q "fail-open"'

# --- 2. deny path: a throwaway fixture engine (mktemp, never in lib/) denies on the marker ----
DENY_ENGINE="$FIXTMP/deny-engine.py"
cat > "$DENY_ENGINE" <<PYEOF
import json, sys
req = json.load(sys.stdin)
cmd = (req.get("tool_input") or {}).get("command", "")
if "$DENY_MARKER" in cmd:
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                              "permissionDecision": "deny",
                                              "permissionDecisionReason": "shim.test.sh fixture: deny marker present"}}))
sys.exit(0)
PYEOF

OUT_DENY="$(fixture "echo $DENY_MARKER" | env "$ENGINE_VAR=$DENY_ENGINE" bash "$SHIM")"; RC_DENY=$?
ok "deny: shim exits 0 (verdict rendered, not enforced by the shim itself)" '[ "$RC_DENY" -eq 0 ]'
ok "deny: envelope carries permissionDecision=deny"       'printf "%s" "$OUT_DENY" | grep -q "\"permissionDecision\": \"deny\""'

OUT_ALLOW2="$(fixture 'echo hi' | env "$ENGINE_VAR=$DENY_ENGINE" bash "$SHIM")"; RC_ALLOW2=$?
ok "allow (engine present, no marker): exit 0, no deny"   '[ "$RC_ALLOW2" -eq 0 ] && ! printf "%s" "$OUT_ALLOW2" | grep -q "\"permissionDecision\": \"deny\""'

# --- 3. crash path: an engine that dies with an unrecognized exit code is NOT a verdict -------
# (§7 "Engine/evaluator failure": governed seam fails closed) -> shim normalizes to exit 2.
CRASH_ENGINE="$FIXTMP/crash-engine.py"
cat > "$CRASH_ENGINE" <<'PYEOF'
import sys
sys.stderr.write("boom: simulated engine crash\n")
sys.exit(1)
PYEOF

OUT_CRASH="$(fixture 'echo hi' | env "$ENGINE_VAR=$CRASH_ENGINE" bash "$SHIM" 2>"$FIXTMP/crash.stderr")"; RC_CRASH=$?
ok "crash: shim normalizes an unrecognized exit code to exit 2 (fail closed)" '[ "$RC_CRASH" -eq 2 ]'
ok "crash: shim names the engine and its exit code on stderr" \
   'grep -q "crashed (exit 1" "$FIXTMP/crash.stderr"'

DENY_ENGINE_EXIT2="$FIXTMP/deny-exit2-engine.py"
cat > "$DENY_ENGINE_EXIT2" <<'PYEOF'
import sys
sys.stderr.write("denied via exit 2\n")
sys.exit(2)
PYEOF
env "$ENGINE_VAR=$DENY_ENGINE_EXIT2" bash "$SHIM" < <(fixture 'echo hi') >/dev/null 2>"$FIXTMP/exit2.stderr"; RC_EXIT2=$?
ok "deny via bare exit 2 is a recognized verdict, passed through unchanged (not re-wrapped as a crash)" \
   '[ "$RC_EXIT2" -eq 2 ] && grep -q "denied via exit 2" "$FIXTMP/exit2.stderr" && ! grep -q "crashed" "$FIXTMP/exit2.stderr"'

# --- 4. root-twin parity: sh and py agree byte-for-byte for the same inputs (§6) --------------
PY_PLUGIN="$(python3 "$ROOT/lib/eb_root.py" plugin)"
SH_PLUGIN="$(bash "$ROOT/bin/eb-root.sh" plugin)"
ok "root twin: plugin root identical (py vs sh)"           '[ "$PY_PLUGIN" = "$SH_PLUGIN" ]'

PY_PROJECT="$(python3 "$ROOT/lib/eb_root.py" --cwd "$ROOT" project)"
SH_PROJECT="$(bash "$ROOT/bin/eb-root.sh" --cwd "$ROOT" project)"
ok "root twin: project root identical (py vs sh) for the same --cwd" '[ "$PY_PROJECT" = "$SH_PROJECT" ]'

# --- 5. ambient-var OWNERSHIP CHECK (E2E finding): a session can run several plugins' hooks, so
# PLUGIN_ROOT/CLAUDE_PLUGIN_ROOT/PLUGIN_DATA/CLAUDE_PLUGIN_DATA may be a FOREIGN plugin's values
# left over from whichever hook fired last. A path/manifest not naming THIS plugin must be
# rejected (falling back to script-relative / the documented default dir), never trusted as-is.
NAME="estate-beads"

FOREIGN_DATA="$FIXTMP/foreign-plugin-data"
mkdir -p "$FOREIGN_DATA"
PY_DATA_FOREIGN="$(CLAUDE_PLUGIN_DATA="$FOREIGN_DATA" python3 "$ROOT/lib/eb_root.py" --source data)"
SH_DATA_FOREIGN="$(CLAUDE_PLUGIN_DATA="$FOREIGN_DATA" bash "$ROOT/bin/eb-root.sh" --source data)"
ok "data: a foreign CLAUDE_PLUGIN_DATA (no $NAME path component) is rejected" \
   'printf "%s" "$PY_DATA_FOREIGN" | grep -q "fallback (ambient env var rejected: CLAUDE_PLUGIN_DATA)"'
ok "data: foreign-rejection is byte-identical across twins (py vs sh)" '[ "$PY_DATA_FOREIGN" = "$SH_DATA_FOREIGN" ]'

OWN_DATA="$FIXTMP/claude-data/$NAME"
mkdir -p "$OWN_DATA"
PY_DATA_OWN="$(CLAUDE_PLUGIN_DATA="$OWN_DATA" python3 "$ROOT/lib/eb_root.py" --source data)"
SH_DATA_OWN="$(CLAUDE_PLUGIN_DATA="$OWN_DATA" bash "$ROOT/bin/eb-root.sh" --source data)"
ok "data: this plugin's OWN-name CLAUDE_PLUGIN_DATA path is accepted" \
   'printf "%s" "$PY_DATA_OWN" | grep -qE "CLAUDE_PLUGIN_DATA$"'
ok "data: own-name acceptance is byte-identical across twins (py vs sh)" '[ "$PY_DATA_OWN" = "$SH_DATA_OWN" ]'

FOREIGN_ROOT="$FIXTMP/foreign-plugin-root"
mkdir -p "$FOREIGN_ROOT/.claude-plugin"
printf '{"name":"some-other-plugin","description":"x","author":{"name":"t"}}\n' > "$FOREIGN_ROOT/.claude-plugin/plugin.json"
# SEAT_ROOT/EB_WORKSPACE_SIBLING unset here on purpose: they open a later, legitimate tier
# (design §12.4, the dev-checkout fallback) that this assertion is not testing — it isolates
# ambient-root rejection down to the last-resort tier.
PY_ROOT_FOREIGN="$(env -u SEAT_ROOT -u EB_WORKSPACE_SIBLING -u EB_PLUGINS_JSON CLAUDE_PLUGIN_ROOT="$FOREIGN_ROOT" python3 "$ROOT/lib/eb_root.py" --source plugin)"
SH_ROOT_FOREIGN="$(env -u SEAT_ROOT -u EB_WORKSPACE_SIBLING -u EB_PLUGINS_JSON CLAUDE_PLUGIN_ROOT="$FOREIGN_ROOT" bash "$ROOT/bin/eb-root.sh" --source plugin)"
ok "plugin: a foreign CLAUDE_PLUGIN_ROOT (plugin.json name != $NAME) is rejected -> script-relative" \
   'printf "%s" "$PY_ROOT_FOREIGN" | grep -q "script-relative"'
ok "plugin: foreign-root rejection is byte-identical across twins (py vs sh)" '[ "$PY_ROOT_FOREIGN" = "$SH_ROOT_FOREIGN" ]'

OWN_ROOT="$FIXTMP/own-plugin-root"
mkdir -p "$OWN_ROOT/.claude-plugin"
printf '{"name":"%s","description":"x","author":{"name":"t"}}\n' "$NAME" > "$OWN_ROOT/.claude-plugin/plugin.json"
PY_ROOT_OWN="$(CLAUDE_PLUGIN_ROOT="$OWN_ROOT" python3 "$ROOT/lib/eb_root.py" --source plugin)"
SH_ROOT_OWN="$(CLAUDE_PLUGIN_ROOT="$OWN_ROOT" bash "$ROOT/bin/eb-root.sh" --source plugin)"
ok "plugin: this plugin's own CLAUDE_PLUGIN_ROOT (matching plugin.json name) is accepted" \
   'printf "%s" "$PY_ROOT_OWN" | grep -q "CLAUDE_PLUGIN_ROOT"'
ok "plugin: own-root acceptance is byte-identical across twins (py vs sh)" '[ "$PY_ROOT_OWN" = "$SH_ROOT_OWN" ]'

echo
if [ "$fail" -eq 0 ]; then echo "ALL SHIM/ROOT-TWIN TESTS PASSED ($pass)"; exit 0
else echo "SHIM/ROOT-TWIN TESTS FAILED ($fail of $((pass+fail)))"; exit 1; fi
