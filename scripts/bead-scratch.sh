#!/usr/bin/env bash
# bead-scratch.sh — throwaway Beads databases with built-in cleanup (promoted from
# tests/_scratch_db.sh; design: PerAnkh refinement
# 2026-09-27-scratch-bd-init-unreachable-from-cwd-pinned-agents.md, operator direction
# 2026-10-01). This is the ONLY sanctioned path to `bd init` outside a test suite —
# scripts/eb-guard.py denies every direct `bd init` and names this script as the replacement.
#
# Problem this answers: a cwd-pinned agent (one whose Bash hook payload always reports a cwd
# INSIDE a git repository — e.g. a worktree-bound subagent) could never satisfy the old guard's
# cwd-outside-git-repo allow, so it could never create a scratch database at all. The fix is
# structural, not a smarter cwd check: scratch databases now live under a FIXED root
# (independent of any cwd) and are opened only through this script, never via a raw `bd init`.
#
# Commands:
#   bead-scratch.sh new [--prefix P]
#       Creates a fresh scratch database under the root and prints exactly one line:
#       `BEADS_DIR=<path>/.beads`. For one-shot use, prefer `run --` below. For multi-step use,
#       read the printed line, then pass the LITERAL path as a prefix on each later, SEPARATE
#       call: `bash bead-scratch.sh new` (note the printed `BEADS_DIR=<path>/.beads`), then
#       `BEADS_DIR=<path>/.beads bd list --json` — do NOT `eval`/capture-and-chain in one
#       command; the guard denies that form (it cannot resolve the command word).
#       The folder is NOT cleaned up automatically; the caller is responsible for `rm <path>`.
#   bead-scratch.sh rm <path>
#       Deletes `<path>` iff it resolves to a folder under the scratch root AND carries this
#       script's marker file — refuses (clear message, no delete) on anything else, including a
#       path that merely looks right but was never created by this script.
#   bead-scratch.sh run -- <cmd...>
#       Creates a fresh scratch database, exports BEADS_DIR for `<cmd...>`, runs it, and deletes
#       the database on EXIT — success, failure, or an uncaught signal — via a trap, then exits
#       with `<cmd...>`'s own exit code.
#   bead-scratch.sh sweep-session <session-id>
#       Internal: deletes every marked folder owned by <session-id>. Called by
#       scripts/eb-session-end.sh at SessionEnd (the ending session's own folders only).
#   bead-scratch.sh sweep-stale [hours]
#       Internal: deletes every marked folder whose marker's `created` epoch is older than
#       <hours> (default 24). Called by scripts/eb-session-start.sh.
#
# Layout: `${EB_SCRATCH_ROOT:-${XDG_RUNTIME_DIR:-/tmp}/estate-beads-scratch}/<session-id>-<rand>/`,
# each carrying a marker file `.estate-beads-scratch` (`session_id=`, `created=<epoch>`) at its
# top level. `rm`/the sweeps never touch a folder without that marker, and never touch anything
# outside the resolved root — a folder that merely sits under the root but lacks the marker (or
# a path outside the root entirely) is refused, not deleted.
#
# `bd init` itself runs exactly like the prior test-only helper (tests/_scratch_db.sh): hermetic
# HOME/XDG_CONFIG_HOME so bd/git config reads/writes never touch the real ambient environment,
# jq/yq resolved to their real (non-mise-shim) binary dirs before HOME moves, a throwaway git
# identity, then `env -u BEADS_DIR bd init --skip-hooks --skip-agents --non-interactive --prefix
# <p>`. That hermetic env is scoped to the init call alone (a subshell) — `new`'s caller and
# `run`'s wrapped command see the REAL ambient HOME, with only BEADS_DIR overridden, matching how
# a real agent actually uses a scratch database afterward.
#
# Server/daemon check (design point 1, probed live on bd 1.3.0): `bd init` + `bd list` + `bd
# create` leave no persistent per-database server process — the only background process observed
# was a transient `bd send-metrics` telemetry call that exits on its own within ~1s, unrelated to
# any specific database. `bd` does support an explicit `bd serve` (HTTP API over loopback) and a
# `--global`/`--database` proxied-server mode, so cleanup still defensively stops any `bd serve`
# process whose command line mentions the scratch folder being removed, before deleting it — a
# no-op in the common case, a safety net if a wrapped `run` command happens to start one.
set -uo pipefail
shopt -s nullglob

HERE="$(cd "$(dirname "$0")" && pwd)"
MARKER_NAME=".estate-beads-scratch"
ROOT="${EB_SCRATCH_ROOT:-${XDG_RUNTIME_DIR:-/tmp}/estate-beads-scratch}"

_usage() {
  cat <<'EOF'
usage: bead-scratch.sh new [--prefix P]
       bead-scratch.sh rm <path>
       bead-scratch.sh run -- <cmd...>
       bead-scratch.sh sweep-session <session-id>
       bead-scratch.sh sweep-stale [hours]
EOF
}

_session_id() {
  printf '%s' "${CLAUDE_CODE_SESSION_ID:-nosession}"
}

# _resolve_abs PATH -> absolute, symlink-resolved path on stdout (best-effort; never raises).
# Used only to compare a candidate path against the scratch root, so a `..`-laden or symlinked
# path cannot masquerade as "under the root".
_resolve_abs() {
  local p="$1"
  if command -v realpath >/dev/null 2>&1; then
    realpath -m "$p" 2>/dev/null
  elif [ -d "$p" ]; then
    ( cd "$p" 2>/dev/null && pwd )
  else
    ( cd "$(dirname "$p")" 2>/dev/null && printf '%s/%s\n' "$(pwd)" "$(basename "$p")" )
  fi
}

# _find_marked_ancestor PATH -> prints the nearest ancestor of PATH (PATH itself included) that
# is (a) strictly under the resolved scratch root and (b) carries the marker file; empty + return
# 1 if no such ancestor exists before walking off the root (or PATH does not resolve at all). A
# caller only ever receives `BEADS_DIR=<folder>/db/.beads` from `new`/`run`, so `rm` accepts ANY
# path under a marked folder (the folder itself, its `db` subdir, or `db/.beads`) and ascends to
# find the one folder that is actually safe to delete — the marked top-level folder, never a
# bare subdirectory of it.
_find_marked_ancestor() {
  local path="$1" abs_root abs_path cur
  [ -d "$ROOT" ] || mkdir -p "$ROOT"
  abs_root="$(_resolve_abs "$ROOT")"
  abs_path="$(_resolve_abs "$path")"
  [ -n "$abs_root" ] && [ -n "$abs_path" ] || return 1
  case "$abs_path" in
    "$abs_root"/*) ;;
    *) return 1 ;;  # not under the root at all — never ascend into it
  esac
  cur="$abs_path"
  while :; do
    case "$cur" in
      "$abs_root"/*) ;;
      *) return 1 ;;  # walked off the root without finding a marker
    esac
    if [ -f "$cur/$MARKER_NAME" ]; then
      printf '%s' "$cur"
      return 0
    fi
    cur="$(dirname "$cur")"
  done
}

_write_marker() {  # <dir> <session-id>
  printf 'session_id=%s\ncreated=%s\n' "$2" "$(date +%s)" > "$1/$MARKER_NAME"
}

_marker_field() {  # <dir> <field>
  [ -f "$1/$MARKER_NAME" ] || return 1
  sed -n "s/^$2=//p" "$1/$MARKER_NAME" | head -n1
}

# _stop_server_for DIR — best-effort: kill any process whose command line mentions both "serve"
# and DIR (a `bd serve`/proxied-server process a wrapped command may have started against this
# scratch database). Silent, never fails the caller — this is defense in depth, not the primary
# mechanism (ordinary `bd init`/`bd list`/`bd create` leave nothing to stop; see header).
_stop_server_for() {
  local dir="$1" pid cmdline pids=()
  [ -d /proc ] || return 0
  for pid in /proc/[0-9]*; do
    pid="${pid#/proc/}"
    [ -r "/proc/$pid/cmdline" ] || continue
    cmdline="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
    case "$cmdline" in
      *serve*"$dir"*|*"$dir"*serve*) pids+=("$pid") ;;
    esac
  done
  [ "${#pids[@]}" -gt 0 ] || return 0
  kill "${pids[@]}" 2>/dev/null || true
  sleep 0.2
  for pid in "${pids[@]}"; do
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
  done
  return 0
}

# _init_in DIR [PREFIX] — inits a scratch bd database at DIR/db, hermetically (see header).
# Returns 0 on success (BEADS_DIR is DIR/db/.beads), 1 on failure (DIR/db left for inspection,
# caller decides whether to rm it).
_init_in() {
  local dir="$1" prefix="${2:-t}" db="$dir/db"
  mkdir -p "$db"

  # Resolve jq/yq's REAL (non-mise-shim) binary dirs BEFORE redirecting HOME — mise's shims read
  # ~/.config/mise/config.toml at $HOME, untrusted the instant HOME points at a fresh sandbox.
  local jq_real yq_real extra_path=""
  jq_real="$(command -v jq 2>/dev/null)"; yq_real="$(command -v yq 2>/dev/null)"
  if [[ -n "$jq_real" ]] && command -v mise >/dev/null 2>&1; then
    jq_real="$(mise which jq 2>/dev/null || true)"
  fi
  if [[ -n "$yq_real" ]] && command -v mise >/dev/null 2>&1; then
    yq_real="$(mise which yq 2>/dev/null || true)"
  fi
  [[ -n "$jq_real" ]] && extra_path="$(dirname "$jq_real")"
  [[ -n "$yq_real" ]] && extra_path="$extra_path:$(dirname "$yq_real")"

  (
    export HOME="$dir/home"
    export XDG_CONFIG_HOME="$dir/xdg"
    mkdir -p "$HOME" "$XDG_CONFIG_HOME"
    [[ -n "$extra_path" ]] && export PATH="${extra_path}:${PATH}"
    git config --global user.email "scratch@estate-beads.invalid" >/dev/null 2>&1
    git config --global user.name "estate-beads scratch" >/dev/null 2>&1
    cd "$db" && env -u BEADS_DIR bd init --skip-hooks --skip-agents --non-interactive --prefix "$prefix"
  ) >/dev/null 2>&1
}

# _remove_dir DIR — rm -rf DIR and make a failed removal visible: if rm fails, or exits 0 but the
# folder is still there, print one line to stderr and return 1.
_remove_dir() {
  local dir="$1" err rc
  err="$(rm -rf "$dir" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "bead-scratch.sh: could not remove $dir (rc=$rc): $err" >&2
    return 1
  fi
  if [ -e "$dir" ]; then
    echo "bead-scratch.sh: could not remove $dir (rc=0): still exists${err:+: $err}" >&2
    return 1
  fi
  return 0
}

_new_folder() {  # prints the new folder's absolute path on stdout; returns 1 on mktemp failure
  mkdir -p "$ROOT"
  local sid dir
  sid="$(_session_id)"
  dir="$(mktemp -d "$ROOT/${sid}-XXXXXXXX" 2>/dev/null)" || return 1
  _write_marker "$dir" "$sid"
  printf '%s' "$dir"
}

cmd_new() {
  local prefix="t"
  while [ $# -gt 0 ]; do
    case "$1" in
      --prefix) prefix="${2:?--prefix requires a value}"; shift 2 ;;
      *) echo "bead-scratch.sh new: unexpected argument: $1" >&2; _usage >&2; return 64 ;;
    esac
  done
  local dir
  dir="$(_new_folder)" || { echo "bead-scratch.sh: mktemp failed" >&2; return 1; }
  if ! _init_in "$dir" "$prefix"; then
    _remove_dir "$dir" || true
    echo "bead-scratch.sh: bd init failed — refusing to leave a half-initialized scratch dir" >&2
    return 1
  fi
  echo "BEADS_DIR=$dir/db/.beads"
}

cmd_rm() {
  local path="${1:-}"
  [ -n "$path" ] || { echo "usage: bead-scratch.sh rm <path>" >&2; return 64; }
  local marked
  if ! marked="$(_find_marked_ancestor "$path")"; then
    echo "bead-scratch.sh: refusing to remove '$path' — not a marked scratch folder under $ROOT" >&2
    return 1
  fi
  _stop_server_for "$marked"
  _remove_dir "$marked"
}

cmd_run() {
  if [ "${1:-}" != "--" ]; then
    echo "usage: bead-scratch.sh run -- <cmd...>" >&2
    return 64
  fi
  shift
  [ $# -gt 0 ] || { echo "usage: bead-scratch.sh run -- <cmd...>" >&2; return 64; }

  local dir
  dir="$(_new_folder)" || { echo "bead-scratch.sh: mktemp failed" >&2; return 1; }
  if ! _init_in "$dir"; then
    _remove_dir "$dir" || true
    echo "bead-scratch.sh: bd init failed — refusing to run against a half-initialized scratch dir" >&2
    return 1
  fi

  # Deletes on EXIT no matter how the command below finishes (success, failure, or an uncaught
  # signal killing this script) — `ec=$?` captures the real exit status before cleanup runs
  # anything that could otherwise clobber it, and the explicit `exit "$ec"` re-asserts it.
  trap '
    ec=$?
    _stop_server_for "'"$dir"'"
    _remove_dir "'"$dir"'" || true
    exit "$ec"
  ' EXIT

  BEADS_DIR="$dir/db/.beads" "$@"
}

cmd_sweep_session() {
  local sid="${1:-}"
  [ -n "$sid" ] || return 0
  [ -d "$ROOT" ] || return 0
  local d
  for d in "$ROOT/${sid}-"*; do
    [ -d "$d" ] || continue
    [ -f "$d/$MARKER_NAME" ] || continue
    _stop_server_for "$d"
    _remove_dir "$d" || true
  done
  return 0
}

cmd_sweep_stale() {
  local hours="${1:-24}"
  [ -d "$ROOT" ] || return 0
  local now cutoff_s d created age
  now="$(date +%s)"
  cutoff_s=$(( hours * 3600 ))
  for d in "$ROOT"/*; do
    [ -d "$d" ] || continue
    [ -f "$d/$MARKER_NAME" ] || continue
    created="$(_marker_field "$d" created)"
    [[ "$created" =~ ^[0-9]+$ ]] || continue
    age=$(( now - created ))
    if [ "$age" -ge "$cutoff_s" ]; then
      _stop_server_for "$d"
      _remove_dir "$d" || true
    fi
  done
  return 0
}

main() {
  local sub="${1:-}"
  [ -n "$sub" ] && shift || true
  case "$sub" in
    new) cmd_new "$@" ;;
    rm) cmd_rm "$@" ;;
    run) cmd_run "$@" ;;
    sweep-session) cmd_sweep_session "$@" ;;
    sweep-stale) cmd_sweep_stale "$@" ;;
    -h|--help) _usage; exit 0 ;;
    "") echo "bead-scratch.sh: missing subcommand" >&2; _usage >&2; exit 64 ;;
    *) echo "bead-scratch.sh: unknown subcommand: $sub" >&2; _usage >&2; exit 64 ;;
  esac
}

main "$@"
