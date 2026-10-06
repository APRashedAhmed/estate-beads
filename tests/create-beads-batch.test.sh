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
assert_contains "drift hint names the next-step remedy" "$drift_err" "Remedy: bd update $d_id"
assert_contains "drifted key still gets a stdout key/id line (no update)" "$drift_out" "unit-d $d_id"
d_title_after="$(bd show --json "$d_id" 2>/dev/null | jq -r '.[0].title')"
assert_eq "a drifted title is never written in place" "Unit D" "$d_title_after"

# --- m11 (review pa-s2s.8-review-1): a keyless unit falls back to title matching (§11.7) --------
keyless_artifact="$scratch/plan-keyless.md"
cat > "$keyless_artifact" <<'EOF'
```yaml
project: sample-proj
units:
  - title: "Keyless Unit"
    description: "No key given."
    acceptance: "Keyless work lands."
    accept: evidence
```
EOF
keyless_out1="$(scripts/create-beads-batch.sh --artifact "$keyless_artifact")"; keyless_rc1=$?
assert_rc "keyless unit exits 0" 0 "$keyless_rc1"
# the stdout line is "<empty-key> <id>" (a leading space, since the key is ""); awk's default
# field splitting collapses that leading whitespace, so grab the trailing field instead.
keyless_id1="${keyless_out1##* }"
[[ -n "$keyless_id1" ]] && eb_ok "keyless unit resolves to an id" \
  || eb_bad "keyless unit resolves to an id" "$keyless_out1"
keyless_meta="$(bd show --json "$keyless_id1" 2>/dev/null | jq -c '.[0].metadata.key // "absent"')"
assert_eq "a keyless unit's Bead carries no metadata.key" '"absent"' "$keyless_meta"

keyless_out2="$(scripts/create-beads-batch.sh --artifact "$keyless_artifact")"; keyless_rc2=$?
assert_rc "keyless unit rerun exits 0" 0 "$keyless_rc2"
keyless_id2="${keyless_out2##* }"
assert_eq "keyless unit rerun resolves to the SAME id (title-fallback idempotency)" \
  "$keyless_id1" "$keyless_id2"
count_after_keyless="$(bd list --json --limit 0 | jq 'length')"
assert_eq "keyless unit rerun creates no duplicate Bead" "6" "$count_after_keyless"

# --- same key under two edge types is refused before any Bead is created ---------------------------
samedep_artifact="$scratch/plan-samedep.md"
cat > "$samedep_artifact" <<'EOF'
```yaml
project: sample-proj
units:
  - key: k1
    title: "Same Dep K1"
    description: "Target."
    acceptance: "K1 lands."
    accept: evidence
  - key: k2
    title: "Same Dep K2"
    description: "Names k1 under two edge types."
    acceptance: "K2 lands."
    accept: evidence
    deps: ["blocked-by:k1", "discovered-from:k1"]
```
EOF
n_before_samedep="$(bd list --json --limit 0 | jq 'length')"
samedep_err="$(scripts/create-beads-batch.sh --artifact "$samedep_artifact" 2>&1 >/dev/null)"; samedep_rc=$?
n_after_samedep="$(bd list --json --limit 0 | jq 'length')"
[[ "$n_before_samedep" =~ ^[0-9]+$ && "$n_after_samedep" =~ ^[0-9]+$ ]] \
  && eb_ok "same-key Bead counts are non-empty integers" \
  || eb_bad "same-key Bead counts are non-empty integers" "before='$n_before_samedep' after='$n_after_samedep'"
assert_rc "same-key two-edge-type unit exits 1" 1 "$samedep_rc"
assert_contains "same-key refusal names the unit key" "$samedep_err" "unit 'k2'"
assert_contains "same-key refusal names the target k1" "$samedep_err" "'k1'"
assert_contains "same-key refusal says two edge types" "$samedep_err" "two edge types"
assert_eq "same-key refusal creates zero Beads" "$n_before_samedep" "$n_after_samedep"

eb_report
