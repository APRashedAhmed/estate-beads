#!/usr/bin/env bash
# scratch-db-safety.test.sh: a failing `bd init` inside eb_scratch_db must abort the CALLING
# PROCESS (exit 1), never fall through to a test running against an inherited/live BEADS_DIR
# (MAJOR-1, review pa-s2s.3-review-1). Uses a PATH shim `bd` whose `init` subcommand always
# fails — the real `bd`/live estate database is never touched by this test.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source tests/_assert.sh

tmpbin="$(mktemp -d)"
MARKER="$(mktemp -u)"
trap 'rm -rf "$tmpbin"; rm -f "$MARKER"' EXIT
export MARKER
cat > "$tmpbin/bd" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "init" ]]; then exit 1; fi
echo "scratch-db-safety.test.sh bd shim: unexpected call: $*" >&2
exit 1
EOF
chmod +x "$tmpbin/bd"

# A sentinel value standing in for a real, ambient BEADS_DIR (e.g. the live estate db) —
# never a real path, so the test never depends on (or risks) the real estate directory.
sentinel="/nonexistent/sentinel-inherited/.beads"

out="$(PATH="$tmpbin:$PATH" BEADS_DIR="$sentinel" bash -c '
  cd "'"$ROOT"'"
  source tests/_scratch_db.sh
  eb_scratch_db scratch failinit
  # Must never reach here: eb_scratch_db exits the process on a failed bd init.
  touch "$MARKER"
  echo "BEADS_DIR after call: ${BEADS_DIR:-<unset>}"
' 2>&1)"
rc=$?

assert_rc "a failing bd init makes the caller process exit non-zero" 1 "$rc"
assert_contains "the failure prints a clear diagnostic" "$out" "bd init failed"
if [[ -e "$MARKER" ]]; then
  eb_bad "code after a failed eb_scratch_db call must never run" "marker was created"
else
  eb_ok "code after a failed eb_scratch_db call never ran (BEADS_DIR never left pointing at the inherited path)"
fi

eb_report
