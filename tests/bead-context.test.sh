#!/usr/bin/env bash
# bead-context.sh: a failed claimed-Beads list reads `claimed: unknown (...)`, never `claimed: none`;
# the script still exits 0 and writes nothing to stderr. A fake tracker on PATH stands in for bd.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source tests/_assert.sh

fakebin="$(mktemp -d)"
trap 'rm -rf "$fakebin"' EXIT
cat > "$fakebin/bd" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  info) exit 0 ;;
  list) printf 'Error: boom\n' >&2; exit 1 ;;
esac
exit 99
EOF
chmod +x "$fakebin/bd"

errf="$(mktemp)"
out="$(BEADS_DIR=/fake BEADS_ACTOR=actor1 PATH="$fakebin:$PATH" bash scripts/bead-context.sh 2>"$errf")"; rc=$?
assert_rc "a failed list still exits 0" 0 "$rc"
assert_contains "a failed list reads claimed: unknown" "$out" "claimed: unknown"
assert_contains "the unknown line carries the tracker's error" "$out" "boom"
case "$out" in *"claimed: none"*) assert_eq "a failed list never reads claimed: none" "absent" "present" ;; *) assert_eq "a failed list never reads claimed: none" "absent" "absent" ;; esac
assert_eq "a failed list leaves stderr silent" "" "$(cat "$errf")"
rm -f "$errf"

eb_report
