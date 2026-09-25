#!/usr/bin/env bash
# create-beads-batch.sh: fresh batch, rerun no-op, rerun with one new key, drift
# hint, parent-by-sibling, dep order, batch labels/class/budget on every child,
# --dry-run writes nothing. Uses tests/fixtures/batch/plan-sample.md (design
# §11.7, §12.2; plan U5).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source tests/_scratch_db.sh
source tests/_assert.sh

FIXTURE="$ROOT/tests/fixtures/batch/plan-sample.md"

# --- --dry-run writes nothing --------------------------------------------------------------
eb_scratch_db scratch batch-dryrun || exit 1
trap 'rm -rf "$scratch"' EXIT
before="$(bd list --json --limit 0 | jq 'length')"
dry_out="$(scripts/create-beads-batch.sh --artifact "$FIXTURE" --dry-run)"; dry_rc=$?
after="$(bd list --json --limit 0 | jq 'length')"
assert_rc "--dry-run exits 0" 0 "$dry_rc"
assert_eq "--dry-run creates nothing" "$before" "$after"
assert_contains "--dry-run prints the create-bead.sh argv per unit" "$dry_out" "--key epic-a"
assert_contains "--dry-run renders an unresolved sibling parent as its bare key" "$dry_out" "--parent epic-a"
assert_contains "--dry-run renders a sibling dep as its bare key" "$dry_out" "--deps blocked-by:unit-b"

# --- fresh batch ----------------------------------------------------------------------------
out1="$(scripts/create-beads-batch.sh --artifact "$FIXTURE")"; rc1=$?
assert_rc "fresh batch exits 0" 0 "$rc1"
n_lines="$(printf '%s\n' "$out1" | wc -l)"
assert_eq "fresh batch prints one line per unit (4)" "4" "$n_lines"
epic_id="$(printf '%s\n' "$out1" | awk '$1=="epic-a"{print $2}')"
b_id="$(printf '%s\n' "$out1" | awk '$1=="unit-b"{print $2}')"
c_id="$(printf '%s\n' "$out1" | awk '$1=="unit-c"{print $2}')"
d_id="$(printf '%s\n' "$out1" | awk '$1=="unit-d"{print $2}')"
[[ -n "$epic_id" && -n "$b_id" && -n "$c_id" && -n "$d_id" ]] && eb_ok "every key resolved to an id" \
  || eb_bad "every key resolved to an id" "$out1"

# --- parent-by-sibling -----------------------------------------------------------------------
b_parent="$(bd show --json "$b_id" 2>/dev/null | jq -r '.[0].parent // ""')"
c_parent="$(bd show --json "$c_id" 2>/dev/null | jq -r '.[0].parent // ""')"
assert_eq "unit-b's parent resolved to the epic's real id" "$epic_id" "$b_parent"
assert_eq "unit-c's parent resolved to the epic's real id" "$epic_id" "$c_parent"

# --- dep order (unit-c blocked-by unit-b) -----------------------------------------------------
c_deps="$(bd show --json "$c_id" 2>/dev/null | jq -c '[.[0].dependencies[]?.id] | sort')"
assert_contains "unit-c's dependencies include unit-b's real id" "$c_deps" "$b_id"

# --- batch labels/class/budget present on every child -----------------------------------------
for id in "$epic_id" "$b_id" "$c_id" "$d_id"; do
  labels="$(bd show --json "$id" 2>/dev/null | jq -c '.[0].labels | sort')"
  assert_contains "$id carries the batch label wf:auto" "$labels" "wf:auto"
  assert_contains "$id carries class:bounded-increment (batch default)" "$labels" "class:bounded-increment"
  budget="$(bd show --json "$id" 2>/dev/null | jq -c '.[0].metadata.budget')"
  assert_eq "$id carries the batch budget {\"cycles\":3}" '{"cycles":3}' "$budget"
done
d_labels="$(bd show --json "$d_id" 2>/dev/null | jq -c '.[0].labels | sort')"
assert_contains "unit-d's own label (wf:effort:low) is unioned with the batch label" "$d_labels" "wf:effort:low"

# --- rerun no-op -------------------------------------------------------------------------------
out2="$(scripts/create-beads-batch.sh --artifact "$FIXTURE")"; rc2=$?
assert_rc "rerun (no artifact change) exits 0" 0 "$rc2"
assert_eq "rerun prints the same key/id lines, no new Beads" "$out1" "$out2"
count_after_rerun="$(bd list --json --limit 0 | jq 'length')"
assert_eq "rerun creates no new Bead (still 4)" "4" "$count_after_rerun"

# --- rerun with one new key ---------------------------------------------------------------------
newkey_artifact="$scratch/plan-newkey.md"
python3 - "$FIXTURE" "$newkey_artifact" <<'PYEOF'
import sys
src, dst = sys.argv[1], sys.argv[2]
t = open(src).read()
t = t.replace(
  '    labels: [wf:effort:low]\n',
  '    labels: [wf:effort:low]\n'
  '  - key: unit-e\n'
  '    title: "Unit E"\n'
  '    description: "New in rerun."\n'
  '    acceptance: "E lands."\n'
  '    accept: evidence\n'
)
open(dst, "w").write(t)
PYEOF
out3="$(scripts/create-beads-batch.sh --artifact "$newkey_artifact")"; rc3=$?
assert_rc "rerun with a new key exits 0" 0 "$rc3"
e_line="$(printf '%s\n' "$out3" | awk '$1=="unit-e"{print}')"
[[ -n "$e_line" ]] && eb_ok "rerun with a new key creates only the new key" \
  || eb_bad "rerun with a new key creates only the new key" "$out3"
count_after_newkey="$(bd list --json --limit 0 | jq 'length')"
assert_eq "exactly one new Bead landed (5 total)" "5" "$count_after_newkey"
# old keys' ids are unchanged
old_ids_before="$(printf '%s\n' "$out1" | sort)"
old_ids_after="$(printf '%s\n' "$out3" | grep -v '^unit-e ' | sort)"
assert_eq "the four pre-existing keys keep their original ids" "$old_ids_before" "$old_ids_after"

# --- drift hint ----------------------------------------------------------------------------------
drift_artifact="$scratch/plan-drift.md"
sed 's/title: "Unit D"/title: "Unit D Retitled"/' "$newkey_artifact" >"$drift_artifact"
drift_err="$(scripts/create-beads-batch.sh --artifact "$drift_artifact" 2>&1 1>/dev/null)"
drift_out="$(scripts/create-beads-batch.sh --artifact "$drift_artifact" 2>/dev/null)"
assert_contains "drifted key prints EXISTS: <id> on stderr" "$drift_err" "EXISTS: $d_id"
assert_contains "drift hint names the field that changed" "$drift_err" "Unit D"
assert_contains "drifted key still gets a stdout key/id line (no update)" "$drift_out" "unit-d $d_id"
d_title_after="$(bd show --json "$d_id" 2>/dev/null | jq -r '.[0].title')"
assert_eq "a drifted title is never written in place" "Unit D" "$d_title_after"

eb_report
