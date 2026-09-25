#!/usr/bin/env bash
# eb-common.test.sh: eb_metadata_merge refuses (rc=1) instead of silently overwriting metadata
# with `{}` when `bd show --json` fails (MINOR-1, review pa-s2s.3-review-1). Uses a PATH shim
# `bd` so the real `bd`/live estate database is never touched.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source scripts/lib/eb-common.sh
source tests/_assert.sh

tmpbin="$(mktemp -d)"
trap 'rm -rf "$tmpbin"' EXIT
cat > "$tmpbin/bd" <<'EOF'
#!/usr/bin/env bash
# Shim: `bd show` always fails; anything else is unexpected in this test.
if [[ "${1:-}" == "show" ]]; then exit 1; fi
echo "eb-common.test.sh bd shim: unexpected call: $*" >&2
exit 1
EOF
chmod +x "$tmpbin/bd"

PATH="$tmpbin:$PATH" eb_metadata_merge "fake-id" '{"executor":{"model":"opus"}}'
rc=$?
assert_rc "eb_metadata_merge refuses (does not fall back to {}) when bd show fails" 1 "$rc"

eb_report
