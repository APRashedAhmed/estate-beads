#!/usr/bin/env bash
# _scratch_db.sh — the ONLY path through which any test (or probe) may run `bd init`.
# Source this, then call `eb_scratch_db` to get a fresh, hermetic scratch Beads database in a
# freshly made non-git temp dir. NEVER type `bd init` directly in an agent Bash call — the live
# settings deny it; a script invoking it is not matched, but that exception is for this helper
# only. NEVER let any test touch /home/apra/.local/share/beads/estate.
#
# Leading underscore + no `test_`/`.test.sh` suffix: scripts/test.sh's discovery globs
# (`*.test.sh`) do not match this file, so it is never itself run as a suite.
#
# CALL IT AS A PLAIN STATEMENT, NEVER INSIDE `$(...)`: `eb_scratch_db` exports HOME, XDG_CONFIG_HOME,
# BEADS_DIR, and BEADS_ACTOR into the CALLING shell. Command substitution forks a subshell, so
# `scratch="$(eb_scratch_db)"` silently loses every export — the exact bug this comment exists to
# prevent. Use the variable-name form below instead.
set -uo pipefail

# eb_scratch_db <out-var> [prefix] — creates a fresh temp dir, inits a scratch bd database in it,
# exports BEADS_DIR/HOME/XDG_CONFIG_HOME/BEADS_ACTOR for every subsequent command in THIS shell,
# and assigns the scratch root dir path into the caller-named variable (nameref — no subshell).
#   local scratch; eb_scratch_db scratch; trap 'rm -rf "$scratch"' EXIT
eb_scratch_db() {
  # Never let a failed init fall through to whatever BEADS_DIR the caller's shell already had
  # (ambient/inherited/live-estate). Unsetting first means every failure path below hits an
  # unset BEADS_DIR, never a stale one.
  unset BEADS_DIR
  local -n _eb_out="$1"
  local prefix="${2:-t}"
  local dir
  dir="$(mktemp -d)" || { echo "eb_scratch_db: mktemp failed" >&2; exit 1; }

  # Resolve jq/yq's REAL (non-mise-shim) binary dirs BEFORE redirecting HOME: mise's shims read
  # ~/.config/mise/config.toml at $HOME, which becomes untrusted (and unfound) the instant HOME
  # points at a fresh sandbox, aborting every shimmed call with "Config files ... are not
  # trusted". Route around the shims entirely rather than depending on mise's trust store.
  local _jq_real _yq_real
  _jq_real="$(command -v jq 2>/dev/null)"; _yq_real="$(command -v yq 2>/dev/null)"
  local _extra_path=""
  if [[ -n "$_jq_real" ]] && command -v mise >/dev/null 2>&1; then
    _jq_real="$(mise which jq 2>/dev/null || true)"
  fi
  if [[ -n "$_yq_real" ]] && command -v mise >/dev/null 2>&1; then
    _yq_real="$(mise which yq 2>/dev/null || true)"
  fi
  [[ -n "$_jq_real" ]] && _extra_path="$(dirname "$_jq_real")"
  [[ -n "$_yq_real" ]] && _extra_path="$_extra_path:$(dirname "$_yq_real")"

  # Hermetic HOME/XDG so bd/git config reads/writes never touch the ambient environment.
  export HOME="$dir/home"
  export XDG_CONFIG_HOME="$dir/xdg"
  mkdir -p "$HOME" "$XDG_CONFIG_HOME"
  [[ -n "$_extra_path" ]] && export PATH="${_extra_path}:${PATH}"
  git config --global user.email "test@estate-beads.invalid" >/dev/null 2>&1
  git config --global user.name "estate-beads test harness" >/dev/null 2>&1

  local db="$dir/db"
  mkdir -p "$db"
  ( cd "$db" && env -u BEADS_DIR bd init --skip-hooks --skip-agents --non-interactive --prefix "$prefix" >/dev/null 2>&1 ) \
    || { echo "eb_scratch_db: bd init failed — refusing to continue with an unset/inherited BEADS_DIR" >&2; unset BEADS_DIR; exit 1; }

  export BEADS_DIR="$db/.beads"
  # Escape assertion: BEADS_DIR must be both set and rooted under the freshly made temp dir.
  # Checked unconditionally (not just "did init succeed") so a future refactor that sets
  # BEADS_DIR from somewhere else still trips this guard.
  [[ -n "${BEADS_DIR:-}" && "$BEADS_DIR" == "$dir"/* ]] \
    || { echo "eb_scratch_db: BEADS_DIR '${BEADS_DIR:-<unset>}' is not set under the scratch dir '$dir' — refusing" >&2; unset BEADS_DIR; exit 1; }
  # A fresh HOME has no git user.name fallback path issue since we set it above, but BEADS_ACTOR
  # is the documented first-precedence actor (bead-context.sh) and tests need a stable, distinct
  # actor per session to exercise claim/LOST races — export a default, caller may override per-actor.
  export BEADS_ACTOR="${BEADS_ACTOR:-test-actor-$$}"

  _eb_out="$dir"
}
