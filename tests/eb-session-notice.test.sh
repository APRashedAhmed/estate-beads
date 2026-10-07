#!/usr/bin/env bash
# eb-session-notice.test.sh — hermetic tests for scripts/eb-session-notice.sh (pa-jaaf). `bd` is a
# PATH shim; no database is touched. EB_SESSION_LOG is pinned to a throwaway file.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NOTICE="$ROOT/scripts/eb-session-notice.sh"
# shellcheck source=_assert.sh
source "$ROOT/tests/_assert.sh"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/db"
SENTINEL="$T/bd-called"
SID_ENDED="eeee1111-eeee-eeee-eeee-eeeeeeeeeeee"
SID_OWN="99999999-9999-9999-9999-999999999999"
# Shim: any call leaves a sentinel; `list` reports one claim held by $SHIM_ASSIGNEE.
cat > "$T/bin/bd" <<'EOF'
#!/usr/bin/env bash
: > "$SENTINEL"
case "${1:-}" in
  list) printf '[{"id":"x-1","assignee":"%s","labels":[]}]\n' "$SHIM_ASSIGNEE" ;;
esac
EOF
chmod +x "$T/bin/bd"
export SENTINEL PATH="$T/bin:$PATH" BEADS_DIR="$T/db"
payload() { printf '{"session_id":"%s","hook_event_name":"SessionStart"}' "$SID_OWN"; }
run() {  # <log> ; sets OUT ERR RC
  OUT="$(EB_SESSION_LOG="$1" bash "$NOTICE" <<<"$(payload)" 2>"$T/err")"; RC=$?
  ERR="$(cat "$T/err")"
}

# N1: no ended sid in the log -> silent rc 0, and bd is never called.
LOG1="$T/n1.tsv"; printf '%s\tstarted\t2026-10-07T00:00:00Z\n' "$SID_ENDED" > "$LOG1"
rm -f "$SENTINEL"; SHIM_ASSIGNEE="$SID_ENDED" run "$LOG1"
assert_rc "N1: rc 0 when no session ended" 0 "$RC"
assert_eq "N1: empty stderr" "" "$ERR"
assert_eq "N1: empty stdout" "" "$OUT"
[ ! -e "$SENTINEL" ] && eb_ok "N1: bd was not called" || eb_bad "N1: bd was not called (a list on every start)"

# N2: ended sid holds a claim -> rc 2, one stderr line naming the id and bead-release.sh, no stdout.
LOG2="$T/n2.tsv"; printf '%s\tended\t2026-10-07T00:00:00Z\n' "$SID_ENDED" > "$LOG2"
SHIM_ASSIGNEE="$SID_ENDED" run "$LOG2"
assert_rc "N2: rc 2 when an ended session holds a claim" 2 "$RC"
assert_eq "N2: empty stdout" "" "$OUT"
assert_contains "N2: stderr names the Bead and the ended sid prefix" "$ERR" "x-1@eeee1111"
assert_contains "N2: stderr names bead-release.sh" "$ERR" "bead-release.sh"
assert_eq "N2: stderr is exactly one line" "1" "$(printf '%s\n' "$ERR" | wc -l | tr -d ' ')"

# N3: ended sid holds nothing (the claim belongs to someone else) -> silent rc 0.
SHIM_ASSIGNEE="ffffffff-ffff-ffff-ffff-ffffffffffff" run "$LOG2"
assert_rc "N3: rc 0 when the ended session holds nothing" 0 "$RC"
assert_eq "N3: empty stderr" "" "$ERR"
assert_eq "N3: empty stdout" "" "$OUT"

eb_report
