#!/usr/bin/env bash
# bead-scratch.test.sh — tests for scripts/bead-scratch.sh (pa-e38.8: the only sanctioned path to
# `bd init` now that scripts/eb-guard.py denies every direct one), and the SessionEnd/SessionStart
# cleanup it feeds. Every case runs against EB_SCRATCH_ROOT, a throwaway root this suite owns, so
# it never touches a real session's scratch folders or the real estate database.
set -uo pipefail
shopt -s nullglob
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="$ROOT/scripts/bead-scratch.sh"
START="$ROOT/scripts/eb-session-start.sh"
END="$ROOT/scripts/eb-session-end.sh"

# shellcheck source=_assert.sh
source "$ROOT/tests/_assert.sh"

SCRATCH_ROOT_DIR="$(mktemp -d)"
export EB_SCRATCH_ROOT="$SCRATCH_ROOT_DIR"
unset CLAUDE_CODE_SESSION_ID
ERR_FILE="$(mktemp)"
FAKE_BIN=""
trap 'rm -rf "$SCRATCH_ROOT_DIR" "$ERR_FILE" "$FAKE_BIN"' EXIT

MARKER_NAME=".estate-beads-scratch"

write_marker() {  # <dir> <session-id> <created-epoch>
  mkdir -p "$1"
  printf 'session_id=%s\ncreated=%s\n' "$2" "$3" > "$1/$MARKER_NAME"
}

# --- 1. `new`: creates under the root, prints BEADS_DIR=, marker present, db usable -------------
OUT1="$(bash "$SCRATCH" new)"
assert_contains "new: prints a BEADS_DIR= line" "$OUT1" "BEADS_DIR="
BEADS_DIR_1="${OUT1#BEADS_DIR=}"
DB_DIR_1="$(dirname "$BEADS_DIR_1")"      # .../<sid>-<rand>/db
FOLDER_1="$(dirname "$DB_DIR_1")"          # .../<sid>-<rand>
case "$FOLDER_1" in
  "$SCRATCH_ROOT_DIR"/*) eb_ok "new: folder is created under the scratch root" ;;
  *) eb_bad "new: folder is created under the scratch root" "got: $FOLDER_1 (root: $SCRATCH_ROOT_DIR)" ;;
esac
if [[ -f "$FOLDER_1/$MARKER_NAME" ]]; then
  eb_ok "new: marker file is present at the folder's top level"
else
  eb_bad "new: marker file is present at the folder's top level" "missing: $FOLDER_1/$MARKER_NAME"
fi
assert_contains "new: marker records this session's id (nosession default)" \
  "$(cat "$FOLDER_1/$MARKER_NAME")" "session_id=nosession"
if [[ -d "$BEADS_DIR_1" ]]; then
  eb_ok "new: BEADS_DIR itself exists"
else
  eb_bad "new: BEADS_DIR itself exists" "missing: $BEADS_DIR_1"
fi
LIST_OUT="$(BEADS_DIR="$BEADS_DIR_1" bd list --json 2>/dev/null)"
assert_eq "new: the database is usable (bd list --json returns an empty array)" "[]" "$LIST_OUT"

# --- 2. `rm`: deletes a legitimate scratch folder (given any path under it) ----------------------
ERR_RM1="$(bash "$SCRATCH" rm "$BEADS_DIR_1" 2>&1 >/dev/null)"
RC_RM1=$?
assert_rc "rm: a legitimate marked folder is accepted (exit 0)" 0 "$RC_RM1"
if [[ -e "$FOLDER_1" ]]; then
  eb_bad "rm: the folder is actually gone afterward" "still exists: $FOLDER_1" "rc=$RC_RM1 stderr: $ERR_RM1"
else
  eb_ok "rm: the folder is actually gone afterward"
fi

# --- 3. `rm`: refuses an unmarked folder, even if it sits under the root -------------------------
UNMARKED="$SCRATCH_ROOT_DIR/unmarked-folder"
mkdir -p "$UNMARKED"
bash "$SCRATCH" rm "$UNMARKED" >/dev/null 2>&1
RC_RM2=$?
assert_ne "rm: an unmarked folder under the root is refused (nonzero exit)" "0" "$RC_RM2"
if [[ -d "$UNMARKED" ]]; then
  eb_ok "rm: the unmarked folder is left untouched"
else
  eb_bad "rm: the unmarked folder is left untouched" "it was deleted"
fi
rm -rf "$UNMARKED"

# --- 4. `rm`: refuses a path outside the root entirely, even if marked --------------------------
OUTSIDE="$(mktemp -d)"
write_marker "$OUTSIDE" "nosession" "$(date +%s)"
bash "$SCRATCH" rm "$OUTSIDE" >/dev/null 2>&1
RC_RM3=$?
assert_ne "rm: a marked folder OUTSIDE the root is refused (nonzero exit)" "0" "$RC_RM3"
if [[ -d "$OUTSIDE" ]]; then
  eb_ok "rm: the out-of-root folder is left untouched"
else
  eb_bad "rm: the out-of-root folder is left untouched" "it was deleted"
fi
rm -rf "$OUTSIDE"

# --- 5. `run -- <cmd>`: creates, runs with BEADS_DIR exported, deletes on SUCCESS ----------------
RUN_OUT="$(bash "$SCRATCH" run -- bash -c '
  echo "BEADS_DIR=$BEADS_DIR"
  bd create "scratch run test" --type task -p 2 --json >/dev/null
  bd list --json
' 2>"$ERR_FILE")"
RC_RUN_OK=$?
ERR_RUN_OK="$(cat "$ERR_FILE")"
assert_rc "run (success): the wrapped command exits 0" 0 "$RC_RUN_OK"
assert_contains "run (success): BEADS_DIR was exported to the command" "$RUN_OUT" "BEADS_DIR="
assert_contains "run (success): the command could actually use bd against it" "$RUN_OUT" "scratch run test"
LEFTOVER_AFTER_SUCCESS=("$SCRATCH_ROOT_DIR"/*/)
if [[ "${#LEFTOVER_AFTER_SUCCESS[@]}" -eq 0 ]]; then
  eb_ok "run (success): the scratch folder is deleted on exit"
else
  eb_bad "run (success): the scratch folder is deleted on exit" "left over: ${LEFTOVER_AFTER_SUCCESS[*]}" \
    "rc=$RC_RUN_OK stderr: $ERR_RUN_OK"
fi

# --- 6. `run -- <cmd>`: deletes on FAILURE too, and propagates the command's own exit code -------
ERR_RUN_FAIL="$(bash "$SCRATCH" run -- bash -c 'exit 37' 2>&1 >/dev/null)"
RC_RUN_FAIL=$?
assert_rc "run (failure): the wrapped command's exit code is propagated" 37 "$RC_RUN_FAIL"
LEFTOVER_AFTER_FAIL=("$SCRATCH_ROOT_DIR"/*/)
if [[ "${#LEFTOVER_AFTER_FAIL[@]}" -eq 0 ]]; then
  eb_ok "run (failure): the scratch folder is STILL deleted on a failing command"
else
  eb_bad "run (failure): the scratch folder is STILL deleted on a failing command" \
    "left over: ${LEFTOVER_AFTER_FAIL[*]}" "rc=$RC_RUN_FAIL stderr: $ERR_RUN_FAIL"
fi

# --- 7. a `bd serve`-shaped process mentioning the scratch folder is stopped on cleanup ----------
# A fake long-running process whose argv0 encodes both "serve" and the scratch folder path --
# `_stop_server_for` matches on the joined cmdline text, so this is representative of a real
# `bd serve --db <dir> ...`/proxied-server invocation without needing a real bd server.
RUN_OUT2="$(bash "$SCRATCH" run -- bash -c '
  echo "DIR=$(dirname "$(dirname "$BEADS_DIR")")"
  ( exec -a "fake-bd-serve-$(dirname "$(dirname "$BEADS_DIR")")" sleep 30 ) &
  echo "FAKE_PID=$!"
  sleep 0.3
')"
FAKE_PID="$(printf '%s' "$RUN_OUT2" | sed -n 's/^FAKE_PID=//p')"
sleep 0.3
if [[ -n "$FAKE_PID" ]] && kill -0 "$FAKE_PID" 2>/dev/null; then
  eb_bad "run cleanup: a bd-serve-shaped process mentioning the folder is stopped" \
    "pid $FAKE_PID is still alive after cleanup"
else
  eb_ok "run cleanup: a bd-serve-shaped process mentioning the folder is stopped"
fi

# --- 8. SessionEnd (scripts/eb-session-end.sh) deletes ONLY the ending session's own folders ----
SID_A="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
SID_B="bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
FOLDER_A="$SCRATCH_ROOT_DIR/${SID_A}-f1"
FOLDER_B="$SCRATCH_ROOT_DIR/${SID_B}-f1"
write_marker "$FOLDER_A" "$SID_A" "$(date +%s)"
write_marker "$FOLDER_B" "$SID_B" "$(date +%s)"
UNMARKED_SE="$SCRATCH_ROOT_DIR/unmarked-sessionend"
mkdir -p "$UNMARKED_SE"

sessionend_payload() { printf '{"session_id":"%s","hook_event_name":"SessionEnd"}' "$1"; }
ERR_END="$(env -u BEADS_DIR bash "$END" <<<"$(sessionend_payload "$SID_A")" 2>&1 >/dev/null)"
RC_END=$?

if [[ -d "$FOLDER_A" ]]; then
  eb_bad "SessionEnd: deletes the ending session's own marked folder" "still exists: $FOLDER_A" \
    "rc=$RC_END stderr: $ERR_END"
else
  eb_ok "SessionEnd: deletes the ending session's own marked folder"
fi
if [[ -d "$FOLDER_B" ]]; then
  eb_ok "SessionEnd: leaves ANOTHER session's marked folder alone"
else
  eb_bad "SessionEnd: leaves ANOTHER session's marked folder alone" "was deleted: $FOLDER_B"
fi
if [[ -d "$UNMARKED_SE" ]]; then
  eb_ok "SessionEnd: leaves an unmarked folder alone"
else
  eb_bad "SessionEnd: leaves an unmarked folder alone" "was deleted: $UNMARKED_SE"
fi
rm -rf "$FOLDER_B" "$UNMARKED_SE"

# --- 9. SessionStart (scripts/eb-session-start.sh) sweeps ONLY stale (>24h) marked folders -------
NOW_EPOCH="$(date +%s)"
OLD_FOLDER="$SCRATCH_ROOT_DIR/sessC-old"
FRESH_FOLDER="$SCRATCH_ROOT_DIR/sessC-fresh"
UNMARKED_SS="$SCRATCH_ROOT_DIR/unmarked-sessionstart"
write_marker "$OLD_FOLDER" "sessC" "$(( NOW_EPOCH - 25*3600 ))"   # 25h old: past the 24h default
write_marker "$FRESH_FOLDER" "sessC" "$NOW_EPOCH"                  # fresh: must survive
mkdir -p "$UNMARKED_SS"

sessionstart_payload() { printf '{"session_id":"%s","source":"startup","hook_event_name":"SessionStart"}' "$1"; }
SID_SWEEPER="55555555-5555-5555-5555-555555555555"
ERR_START="$(env -u BEADS_DIR bash "$START" <<<"$(sessionstart_payload "$SID_SWEEPER")" 2>&1 >/dev/null)"
RC_START=$?

if [[ -d "$OLD_FOLDER" ]]; then
  eb_bad "SessionStart: the 24h sweep deletes a stale (>24h) marked folder" "still exists: $OLD_FOLDER" \
    "rc=$RC_START stderr: $ERR_START"
else
  eb_ok "SessionStart: the 24h sweep deletes a stale (>24h) marked folder"
fi
if [[ -d "$FRESH_FOLDER" ]]; then
  eb_ok "SessionStart: the 24h sweep leaves a fresh marked folder alone"
else
  eb_bad "SessionStart: the 24h sweep leaves a fresh marked folder alone" "was deleted: $FRESH_FOLDER"
fi
if [[ -d "$UNMARKED_SS" ]]; then
  eb_ok "SessionStart: the 24h sweep leaves an unmarked folder alone"
else
  eb_bad "SessionStart: the 24h sweep leaves an unmarked folder alone" "was deleted: $UNMARKED_SS"
fi
rm -rf "$FRESH_FOLDER" "$UNMARKED_SS"

# --- 10. `rm`/`new` work from a cwd-PINNED caller (the pa-e38.8 problem statement itself) --------
# The guard's cwd-outside-git-repo scratch allow is gone; bead-scratch.sh does not look at cwd at
# all (root is fixed by EB_SCRATCH_ROOT/XDG_RUNTIME_DIR), so a cwd that IS a git repo must work
# exactly the same as any other cwd.
GIT_CWD="$(mktemp -d)"
git init -q "$GIT_CWD"
OUT_PINNED="$(cd "$GIT_CWD" && bash "$SCRATCH" new)"
BEADS_DIR_PINNED="${OUT_PINNED#BEADS_DIR=}"
if [[ -d "$BEADS_DIR_PINNED" ]]; then
  eb_ok "new: works from a cwd that IS inside a git repository (the cwd-pinned-agent case)"
else
  eb_bad "new: works from a cwd that IS inside a git repository (the cwd-pinned-agent case)" \
    "no database at: $BEADS_DIR_PINNED"
fi
ERR_RM_PINNED="$(bash "$SCRATCH" rm "$BEADS_DIR_PINNED" 2>&1 >/dev/null)"
RC_RM_PINNED=$?
assert_eq "rm: works from a cwd-pinned caller too" "0|" "$RC_RM_PINNED|$ERR_RM_PINNED"

# `run` too, from the same cwd-pinned caller — and the folder must land under the scratch root,
# NOT under the git cwd, proving the fixed root (not cwd) is what makes this reachable at all.
RUN_PINNED_OUT="$(cd "$GIT_CWD" && bash "$SCRATCH" run -- bash -c 'echo "DB_UNDER_GIT_CWD=$BEADS_DIR"; test -d "$BEADS_DIR"')"
RC_RUN_PINNED=$?
assert_rc "run: works from a cwd-pinned caller too" 0 "$RC_RUN_PINNED"
case "$RUN_PINNED_OUT" in
  *"DB_UNDER_GIT_CWD=$SCRATCH_ROOT_DIR"*) eb_ok "run (cwd-pinned): the database lands under the scratch root, not the git cwd" ;;
  *) eb_bad "run (cwd-pinned): the database lands under the scratch root, not the git cwd" "got: $RUN_PINNED_OUT" ;;
esac
rm -rf "$GIT_CWD"

# --- 11. a FAILED removal is visible: fake `rm` first on PATH, for the script call only ----------
# BOOM: writes to stderr, exits 1. NOOP: exits 0 and deletes nothing (the "still exists" case).
FAKE_BIN="$(mktemp -d)"
mkdir -p "$FAKE_BIN/boom" "$FAKE_BIN/noop"
printf '#!/bin/sh\necho "fake-rm: boom" >&2\nexit 1\n' > "$FAKE_BIN/boom/rm"
printf '#!/bin/sh\nexit 0\n' > "$FAKE_BIN/noop/rm"
chmod +x "$FAKE_BIN/boom/rm" "$FAKE_BIN/noop/rm"

for MODE in boom noop; do
  if [[ "$MODE" == boom ]]; then WANT="could not remove"; else WANT="still exists"; fi

  # rm: nonzero exit, message names the folder, the rc and (boom) rm's own error / (noop) "still exists"
  FOLDER_F="$SCRATCH_ROOT_DIR/sessF-$MODE"
  write_marker "$FOLDER_F" "sessF" "$(date +%s)"
  ERR_F="$(PATH="$FAKE_BIN/$MODE:$PATH" bash "$SCRATCH" rm "$FOLDER_F" 2>&1 >/dev/null)"
  RC_F=$?
  assert_eq "rm ($MODE): a failed removal returns 1" "1" "$RC_F"
  assert_contains "rm ($MODE): stderr names the folder" "$ERR_F" "could not remove $FOLDER_F "
  assert_contains "rm ($MODE): stderr carries the rm status" "$ERR_F" "(rc=$([[ $MODE == boom ]] && echo 1 || echo 0))"
  if [[ "$MODE" == boom ]]; then
    assert_contains "rm (boom): stderr carries rm's own error" "$ERR_F" "fake-rm: boom"
  fi
  assert_contains "rm ($MODE): stderr says $WANT" "$ERR_F" "$WANT"
  rm -rf "$FOLDER_F"

  # run: the wrapped command's exit code (37, and 0) survives a failed removal; the failure is reported
  for WRAPPED in 37 0; do
    ERR_F="$(PATH="$FAKE_BIN/$MODE:$PATH" bash "$SCRATCH" run -- bash -c "exit $WRAPPED" 2>&1 >/dev/null)"
    RC_F=$?
    LEFT_F=("$SCRATCH_ROOT_DIR"/*/)
    assert_eq "run ($MODE, cmd exit $WRAPPED): the wrapped command's exit code is kept" "$WRAPPED" "$RC_F"
    assert_eq "run ($MODE, cmd exit $WRAPPED): the folder is left behind" "1" "${#LEFT_F[@]}"
    assert_contains "run ($MODE, cmd exit $WRAPPED): stderr names the folder" "$ERR_F" \
      "could not remove ${LEFT_F[0]%/} "
    assert_contains "run ($MODE, cmd exit $WRAPPED): stderr carries the rm status" "$ERR_F" \
      "(rc=$([[ $MODE == boom ]] && echo 1 || echo 0))"
    assert_contains "run ($MODE, cmd exit $WRAPPED): stderr carries the reason" "$ERR_F" \
      "$([[ $MODE == boom ]] && echo 'fake-rm: boom' || echo 'still exists')"
    rm -rf "${LEFT_F[@]}"
  done
done
rm -rf "$FAKE_BIN"

eb_report
