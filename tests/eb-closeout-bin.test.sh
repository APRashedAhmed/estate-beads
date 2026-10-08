#!/usr/bin/env bash
# bin/eb-closeout-report.sh: plain-command wrapper for scripts/eb-closeout-report.sh, and the seed
# descriptor's `run:` value (work-unit 2026-10-08-closeout-report-path-command, Bead pa-t73g).
# Only no-`beads:` fixtures are used, so no bd call happens.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source tests/_assert.sh

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
unset EB_PLUGIN_ROOT PLUGIN_ROOT CLAUDE_PLUGIN_ROOT EB_WORKSPACE_SIBLING SEAT_ROOT CKPT_HANDOFF_PATH 2>/dev/null
export EB_PLUGINS_JSON="$tmp/none.json"   # registry tier misses unless a case sets its own

W="$ROOT/bin/eb-closeout-report.sh"
S="$ROOT/scripts/eb-closeout-report.sh"
fx="$tmp/handoff.md"
printf -- '---\nstatus: complete\n---\n\n# Handoff (no beads)\n' >"$fx"

# run <cmd> [args]: sets o/e/rc from stdout, stderr, exit code.
run() { "$@" >"$tmp/o" 2>"$tmp/e"; rc=$?; o="$(cat "$tmp/o")"; e="$(cat "$tmp/e")"; }
same() {  # <label> then the args for both commands via CASE_ENV/CASE_ARGS
  run env $CASE_ENV "$S" "${CASE_ARGS[@]}"; so="$o"; se="$e"; src="$rc"
  run env $CASE_ENV "$W" "${CASE_ARGS[@]}"
  assert_eq "$1: stdout" "$so" "$o"; assert_eq "$1: stderr" "$se" "$e"; assert_eq "$1: rc" "$src" "$rc"
}

# --- A1: wrapper == script ---------------------------------------------------------------------
[[ -x "$W" ]] && eb_ok "wrapper is executable" || eb_bad "wrapper is executable" "$W"
CASE_ENV="A=1"; CASE_ARGS=("$fx");            same "A1 \$1 fixture"
run "$W" "$fx"; assert_eq "A1 \$1 fixture prints no beads" "no beads:0" "$o:$rc"
CASE_ENV="CKPT_HANDOFF_PATH=$fx"; CASE_ARGS=(); same "A1 CKPT_HANDOFF_PATH"
run env CKPT_HANDOFF_PATH="$fx" "$W"; assert_eq "A1 env path prints no beads" "no beads:0" "$o:$rc"
CASE_ENV="A=1"; CASE_ARGS=("$tmp/missing.md"); same "A1 no file"
run "$W" "$tmp/missing.md"; assert_contains "A1 no file says 'no file at'" "$e" "no file at"; assert_eq "A1 no file rc" 1 "$rc"
CASE_ENV="A=1"; CASE_ARGS=();                  same "A1 no path"
run "$W"; assert_contains "A1 no path message" "$e" "no handoff path given"; assert_eq "A1 no path rc" 1 "$rc"

# --- A2: symlink, other cwd --------------------------------------------------------------------
mkdir -p "$tmp/elsewhere" "$tmp/cwd"
ln -s "$W" "$tmp/elsewhere/eb-closeout-report.sh"
run bash -c 'cd "$1" && exec "$2" "$3"' _ "$tmp/cwd" "$tmp/elsewhere/eb-closeout-report.sh" "$fx"
assert_eq "A2 symlink + other cwd runs" "no beads:0" "$o:$rc"

# --- A3: eb-root decides; own tree on failure --------------------------------------------------
other="$tmp/other-root"; mkdir -p "$other/scripts" "$other/.claude-plugin"
printf '{"name": "estate-beads"}' >"$other/.claude-plugin/plugin.json"
printf '#!/usr/bin/env bash\necho other-root-marker "$@"\n' >"$other/scripts/eb-closeout-report.sh"
chmod +x "$other/scripts/eb-closeout-report.sh"
printf '{"plugins":{"estate-beads@homelab-plugins":[{"scope":"user","installPath":"%s"}]}}' "$other" >"$tmp/reg.json"
run env EB_PLUGINS_JSON="$tmp/reg.json" "$W" arg1
assert_eq "A3a registry root's script runs, args pass" "other-root-marker arg1" "$o"

# A3c: the full argument vector survives the wrapper (boundaries, empties, count).
argv_root="$tmp/argv-root"; mkdir -p "$argv_root/scripts" "$argv_root/.claude-plugin"
printf '{"name": "estate-beads"}' >"$argv_root/.claude-plugin/plugin.json"
printf '#!/usr/bin/env bash\nprintf "argc=%%s\\n" "$#"\nfor a in "$@"; do printf "[%%s]\\n" "$a"; done\n' >"$argv_root/scripts/eb-closeout-report.sh"
chmod +x "$argv_root/scripts/eb-closeout-report.sh"
printf '{"plugins":{"estate-beads@homelab-plugins":[{"scope":"user","installPath":"%s"}]}}' "$argv_root" >"$tmp/argv-reg.json"
run env EB_PLUGINS_JSON="$tmp/argv-reg.json" "$W" "with spaces" "" "last"
assert_eq "A3c three args keep boundaries and empty" $'argc=3\n[with spaces]\n[]\n[last]' "$o"
run env EB_PLUGINS_JSON="$tmp/argv-reg.json" "$W"
assert_eq "A3c no args" "argc=0" "$o"
run env EB_PLUGINS_JSON="$tmp/argv-reg.json" "$W" ""
assert_eq "A3c one empty arg" $'argc=1\n[]' "$o"

cp_tree="$tmp/copy"; mkdir -p "$cp_tree/bin" "$cp_tree/scripts"
cp "$W" "$cp_tree/bin/"
printf '#!/usr/bin/env bash\nexit 1\n' >"$cp_tree/bin/eb-root.sh"
printf '#!/usr/bin/env bash\necho own-tree-marker "$@"\n' >"$cp_tree/scripts/eb-closeout-report.sh"
chmod +x "$cp_tree/bin/"* "$cp_tree/scripts/"*
run "$cp_tree/bin/eb-closeout-report.sh" arg2
assert_eq "A3b eb-root failing -> own tree" "own-tree-marker arg2" "$o"
printf '#!/usr/bin/env bash\nexit 0\n' >"$cp_tree/bin/eb-root.sh"
run "$cp_tree/bin/eb-closeout-report.sh" arg3
assert_eq "A3b eb-root empty -> own tree" "own-tree-marker arg3" "$o"

# --- A4: seed run: value -----------------------------------------------------------------------
SEED="${EB_SEED_FILE:-$ROOT/seed/estate-beads-report.yaml}"
runval="$(python3 -c '
import sys, yaml
print(yaml.safe_load(open(sys.argv[1]))["run"], end="")' "$SEED")"
assert_eq "A4 run: value" "eb-closeout-report.sh" "$runval"
for bad in '$(' '`' 'bash '; do
  [[ "$runval" != *"$bad"* ]] && eb_ok "A4 run: has no '$bad'" || eb_bad "A4 run: has '$bad'" "$runval"
done

# --- A5: simulated closeout line ---------------------------------------------------------------
mkdir -p "$tmp/unit/archive"; cp "$fx" "$tmp/unit/archive/h.md"
line="CKPT_EVENT=closeout CKPT_HANDOFF_PATH=$tmp/unit/h.md eb-closeout-report.sh"
run env PATH="$ROOT/bin:$PATH" bash -c "$line"
assert_eq "A5 closeout line, archived-only file" "no beads:0" "$o:$rc"

eb_report
