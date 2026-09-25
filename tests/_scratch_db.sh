#!/usr/bin/env bash
# _scratch_db.sh — the ONLY path through which any test (or probe) may run `bd init`.
# Source this, then call `eb_scratch_db` to get a fresh, hermetic scratch Beads database in a
# freshly made non-git temp dir. NEVER type `bd init` directly in an agent Bash call — the live
# settings deny it; a script invoking it is not matched, but that exception is for this helper
# only. NEVER let any test touch /home/apra/.local/share/beads/estate.
#
# Leading underscore + no `test_`/`.test.sh` suffix: scripts/test.sh's discovery globs
# (`*.test.sh`) do not match this file, so it is never itself run as a suite.
set -uo pipefail

# eb_scratch_db [prefix] — creates dir, inits db, exports BEADS_DIR/HOME/XDG_CONFIG_HOME/BEADS_ACTOR,
# echoes the scratch root dir to stdout. Caller captures it for cleanup:
#   scratch="$(eb_scratch_db)"; trap 'rm -rf "$scratch"' EXIT
eb_scratch_db() {
  local prefix="${1:-t}"
  local dir
  dir="$(mktemp -d)" || { echo "eb_scratch_db: mktemp failed" >&2; return 1; }

  # Hermetic HOME/XDG so bd/git config reads/writes never touch the ambient environment.
  export HOME="$dir/home"
  export XDG_CONFIG_HOME="$dir/xdg"
  mkdir -p "$HOME" "$XDG_CONFIG_HOME"
  git config --global user.email "test@estate-beads.invalid" >/dev/null 2>&1
  git config --global user.name "estate-beads test harness" >/dev/null 2>&1

  local db="$dir/db"
  mkdir -p "$db"
  ( cd "$db" && env -u BEADS_DIR bd init --skip-hooks --skip-agents --non-interactive --prefix "$prefix" >/dev/null ) \
    || { echo "eb_scratch_db: bd init failed" >&2; return 1; }

  export BEADS_DIR="$db/.beads"
  # A fresh HOME has no git user.name fallback path issue since we set it above, but BEADS_ACTOR
  # is the documented first-precedence actor (bead-context.sh) and tests need a stable, distinct
  # actor per session to exercise claim/LOST races — export a default, caller may override per-actor.
  export BEADS_ACTOR="${BEADS_ACTOR:-test-actor-$$}"

  printf '%s\n' "$dir"
}
