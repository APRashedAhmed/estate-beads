#!/usr/bin/env bash
# eb-root.sh — bash twin of lib/eb_root.py (plugin/project/data root
# resolution). Implements portability-contract.md §6 "Root resolution". Stdout is
# BYTE-IDENTICAL to the Python twin for the same inputs; adapted from holonic/bin/hol-root.sh
# + holonic/lib/hol_root.py, precedence kept NON-inverted per the contract's default (see the
# Python twin's docstring for the governed-seam exception this deliberately does not apply).
#
# Plugin root:  <ENVPREFIX>_PLUGIN_ROOT -> PLUGIN_ROOT -> CLAUDE_PLUGIN_ROOT -> script-relative
# Project root: <ENVPREFIX>_PROJECT_ROOT -> --cwd -> `git rev-parse --show-toplevel` ->
#               CLAUDE_PROJECT_DIR -> unresolved
# Data dir:     <ENVPREFIX>_DATA -> PLUGIN_DATA -> CLAUDE_PLUGIN_DATA -> <plugin root>/.data
# <ENVPREFIX> is PREFIX uppercased with hyphens -> underscores, computed below at runtime — it
# is NOT a fourth scaffold-time substitution token (see scripts/scaffold-plugin.sh's
# render_template for the full, fixed token set this file is rendered through).
#
# --cwd stands in for hook-stdin's `cwd` field (this script has no stdin channel of its own).
#
# Ambient-var OWNERSHIP CHECK (E2E finding, orchestrator ruling): a session can run several
# plugins' hooks, and the harness exports PLUGIN_ROOT/CLAUDE_PLUGIN_ROOT/PLUGIN_DATA/
# CLAUDE_PLUGIN_DATA freshly for WHICHEVER plugin's hook fired last — a non-hook invocation of
# this twin can inherit a FOREIGN plugin's values from that ambient environment. Only this
# plugin's OWN namespaced override (<ENVPREFIX>_PLUGIN_ROOT / <ENVPREFIX>_DATA) is trusted
# unconditionally. PLUGIN_ROOT/CLAUDE_PLUGIN_ROOT are accepted only if
# <value>/.claude-plugin/plugin.json exists with `name` == this plugin's name; otherwise
# rejected, falling through to script-relative. PLUGIN_DATA/CLAUDE_PLUGIN_DATA are accepted
# only if the path has a component == PREFIX's plugin name or starting with "<name>-";
# otherwise rejected, source reports "fallback (ambient env var rejected: <var>)".
#
# Exit codes: 0 ok | 2 misconfigured override | 3 project root unresolved | 64 usage error.
#
# Usage: eb-root.sh [--source] [--cwd PATH] {plugin|project|data}
set -euo pipefail

PREFIX="eb"
PLUGIN_NAME="estate-beads"
ENVPREFIX="$(printf '%s' "$PREFIX" | tr 'a-z-' 'A-Z_')"

_USAGE="usage: eb-root.sh [--source] [--cwd PATH] {plugin|project|data}

  plugin              print the resolved plugin root
  project             print the resolved project root
  data                print the resolved data dir
  --cwd PATH          the hook-stdin \`cwd\` value a shim forwards
  --source            also print the resolution source, tab-separated

exit codes: 0 ok, 2 misconfigured override, 3 project root unresolved, 64 usage error
"

_has_readlink_f() {
  command -v readlink >/dev/null 2>&1 && readlink -f / >/dev/null 2>&1
}

_norm() {  # PATH -> normalized absolute path on stdout. Only called on proven directories.
  local p="$1"
  if _has_readlink_f; then readlink -f "$p"; else (cd -P "$p" && pwd); fi
}

_resolve_self() {  # absolute, symlink-resolved path to this script.
  local src="${BASH_SOURCE[0]}"
  if _has_readlink_f; then readlink -f "$src"; return 0; fi
  local n=0 dir target
  while [ -L "$src" ]; do
    n=$((n + 1))
    if [ "$n" -gt 40 ]; then
      printf 'eb-root: symlink loop resolving %s\n' "${BASH_SOURCE[0]}" >&2
      exit 2
    fi
    dir="$(cd -P "$(dirname "$src")" && pwd)"
    target="$(readlink "$src")"
    case "$target" in
      /*) src="$target" ;;
      *) src="$dir/$target" ;;
    esac
  done
  dir="$(cd -P "$(dirname "$src")" && pwd)"
  printf '%s/%s\n' "$dir" "$(basename "$src")"
}

# _from_env VAR -> prints normalized path, returns 0. Returns 10 if unset/empty (chain
# continues). Exits the WHOLE script with 2 if set to something that is not an existing
# absolute directory (a broken override never falls through to the next mechanism).
_from_env() {
  local var="$1" raw="${!1-}"
  [ -n "$raw" ] || return 10
  case "$raw" in
    /*) ;;
    *)
      printf 'eb-root: %s must be an absolute path, got: %s\n' "$var" "$raw" >&2
      exit 2
      ;;
  esac
  if [ ! -d "$raw" ]; then
    printf 'eb-root: %s is not an existing directory: %s\n' "$var" "$raw" >&2
    exit 2
  fi
  _norm "$raw"
}

_script_relative_root() {
  local self dir
  self="$(_resolve_self)"
  dir="$(dirname "$(dirname "$self")")"
  if [ ! -d "$dir" ]; then
    printf 'eb-root: script-relative plugin root does not exist: %s\n' "$dir" >&2
    exit 2
  fi
  printf '%s\n' "$dir"
}

_git_toplevel() {  # prints normalized git worktree root, or returns 1 (no candidate).
  command -v git >/dev/null 2>&1 || return 1
  local out rc=0
  out="$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE \
         git rev-parse --show-toplevel 2>/dev/null)" || rc=$?
  [ "$rc" -eq 0 ] || return 1
  [ -n "$out" ] && [ -d "$out" ] || return 1
  _norm "$out"
}

# _owns_plugin_root PATH -> 0 iff PATH/.claude-plugin/plugin.json exists and its `name` is ours.
_owns_plugin_root() {
  local path="$1" manifest="$1/.claude-plugin/plugin.json" name
  [ -f "$manifest" ] || return 1
  name="$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
    print(d.get("name", "") if isinstance(d, dict) else "")
except Exception:
    print("")
' "$manifest" 2>/dev/null)"
  [ "$name" = "$PLUGIN_NAME" ]
}

# _owns_data_path PATH -> 0 iff PATH has a component == PLUGIN_NAME or starting with "<name>-".
_owns_data_path() {
  local path="$1" part
  local IFS=/
  for part in $path; do
    [ "$part" = "$PLUGIN_NAME" ] && return 0
    case "$part" in "$PLUGIN_NAME"-*) return 0 ;; esac
  done
  return 1
}

# _registry_root -> prints installPath from ~/.claude/plugins/installed_plugins.json for
# estate-beads@homelab-plugins (prefer scope "user", else the first record), or returns 1.
# design §12.4: consumers never hardcode a cache path; this is the cross-plugin tier — the
# ONLY tier that resolves correctly for a vendored copy of this script running inside another
# plugin's tree, where CLAUDE_PLUGIN_ROOT (if set at all) names the FOREIGN caller plugin and
# script-relative would resolve into that foreign plugin's own directory.
_registry_root() {
  local json="${EB_PLUGINS_JSON:-$HOME/.claude/plugins/installed_plugins.json}" ip
  command -v jq >/dev/null 2>&1 || return 1
  [ -f "$json" ] || return 1
  ip="$(jq -r '
    (.plugins["estate-beads@homelab-plugins"] // [])
    | (map(select(.scope == "user")) + .)[0].installPath // empty
  ' "$json" 2>/dev/null)"
  [ -n "$ip" ] && [ -d "$ip" ] || return 1
  _owns_plugin_root "$ip" || return 1
  _norm "$ip"
}

_resolve_plugin() {  # sets OUT_PATH / OUT_SOURCE
  local v rc
  rc=0; v="$(_from_env "${ENVPREFIX}_PLUGIN_ROOT")" || rc=$?
  if [ "$rc" -eq 0 ]; then OUT_PATH="$v"; OUT_SOURCE="${ENVPREFIX}_PLUGIN_ROOT"; return 0; fi
  [ "$rc" -eq 10 ] || exit "$rc"

  for var in PLUGIN_ROOT CLAUDE_PLUGIN_ROOT; do
    rc=0; v="$(_from_env "$var")" || rc=$?
    if [ "$rc" -eq 0 ]; then
      if _owns_plugin_root "$v"; then OUT_PATH="$v"; OUT_SOURCE="$var"; return 0; fi
      # set but NOT ours (foreign plugin's ambient root, or no manifest there): never trust
      # it — fall through exactly as if it were unset (E2E finding).
      continue
    fi
    [ "$rc" -eq 10 ] || exit "$rc"
  done

  v="$(_registry_root)" && [ -n "$v" ] && { OUT_PATH="$v"; OUT_SOURCE="installed-registry"; return 0; }

  v="${EB_WORKSPACE_SIBLING:-}"
  if [ -z "$v" ] && [ -n "${SEAT_ROOT:-}" ]; then
    v="$SEAT_ROOT/engineering/agentic/plugins/estate-beads"
  fi
  if [ -n "$v" ] && [ -d "$v" ] && _owns_plugin_root "$v"; then
    OUT_PATH="$(_norm "$v")"; OUT_SOURCE="workspace-sibling"; return 0
  fi

  OUT_PATH="$(_script_relative_root)"
  OUT_SOURCE="script-relative"
}

_resolve_project() {  # sets OUT_PATH ("" if unresolved) / OUT_SOURCE
  local v rc override_var="${ENVPREFIX}_PROJECT_ROOT"
  rc=0; v="$(_from_env "$override_var")" || rc=$?
  if [ "$rc" -eq 0 ]; then OUT_PATH="$v"; OUT_SOURCE="$override_var"; return 0; fi
  [ "$rc" -eq 10 ] || exit "$rc"

  if [ -n "${OPT_CWD:-}" ] && [ -d "$OPT_CWD" ]; then
    case "$OPT_CWD" in
      /*) OUT_PATH="$(_norm "$OPT_CWD")"; OUT_SOURCE="stdin-cwd"; return 0 ;;
    esac
  fi

  rc=0; v="$(_git_toplevel)" || rc=$?
  if [ "$rc" -eq 0 ]; then OUT_PATH="$v"; OUT_SOURCE="git"; return 0; fi

  rc=0; v="$(_from_env CLAUDE_PROJECT_DIR)" || rc=$?
  if [ "$rc" -eq 0 ]; then OUT_PATH="$v"; OUT_SOURCE="CLAUDE_PROJECT_DIR"; return 0; fi
  [ "$rc" -eq 10 ] || exit "$rc"

  OUT_PATH=""; OUT_SOURCE="unresolved"
}

_resolve_data() {  # sets OUT_PATH / OUT_SOURCE; needs the plugin root already resolved
  local v rc rejected=""
  rc=0; v="$(_from_env "${ENVPREFIX}_DATA")" || rc=$?
  if [ "$rc" -eq 0 ]; then OUT_PATH="$v"; OUT_SOURCE="${ENVPREFIX}_DATA"; return 0; fi
  [ "$rc" -eq 10 ] || exit "$rc"

  for var in PLUGIN_DATA CLAUDE_PLUGIN_DATA; do
    rc=0; v="$(_from_env "$var")" || rc=$?
    if [ "$rc" -eq 0 ]; then
      if _owns_data_path "$v"; then OUT_PATH="$v"; OUT_SOURCE="$var"; return 0; fi
      rejected="$var"  # set, but points at a FOREIGN plugin's data dir
      continue
    fi
    [ "$rc" -eq 10 ] || exit "$rc"
  done
  _resolve_plugin
  local proot="$OUT_PATH"
  OUT_PATH="$proot/.data"
  if [ -n "$rejected" ]; then
    OUT_SOURCE="fallback (ambient env var rejected: $rejected)"
  else
    OUT_SOURCE="default"
  fi
}

main() {
  local want_source=0 cmd="" OPT_CWD=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help) printf '%s' "$_USAGE"; exit 0 ;;
      --source) want_source=1; shift ;;
      --cwd)
        [ $# -ge 2 ] || { printf 'eb-root: --cwd requires a value\n%s' "$_USAGE" >&2; exit 64; }
        OPT_CWD="$2"; shift 2 ;;
      plugin|project|data)
        if [ -z "$cmd" ]; then cmd="$1"; else
          printf 'eb-root: unexpected argument: %s\n%s' "$1" "$_USAGE" >&2; exit 64
        fi
        shift ;;
      *) printf 'eb-root: unexpected argument: %s\n%s' "$1" "$_USAGE" >&2; exit 64 ;;
    esac
  done
  if [ -z "$cmd" ]; then
    printf 'eb-root: missing subcommand (plugin|project|data)\n%s' "$_USAGE" >&2
    exit 64
  fi

  OUT_PATH=""; OUT_SOURCE=""
  case "$cmd" in
    plugin) _resolve_plugin ;;
    data) _resolve_data ;;
    project)
      _resolve_project
      if [ -z "$OUT_PATH" ]; then
        printf 'eb-root: project root unresolved\n' >&2
        exit 3
      fi
      ;;
  esac

  if [ "$want_source" -eq 1 ]; then
    printf '%s\t%s\n' "$OUT_PATH" "$OUT_SOURCE"
  else
    printf '%s\n' "$OUT_PATH"
  fi
}

main "$@"
