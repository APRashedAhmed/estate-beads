#!/usr/bin/env bash
# Check one Bead against the estate's authoring invariants.
# Silent on pass. On fail: the violated invariant plus the exact remedy.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="check-bead"
die() { printf '%s: %s\n' "$SELF" "$1" >&2; exit "${2:-1}"; }

# shellcheck source=lib/eb-common.sh
source "$SCRIPT_DIR/lib/eb-common.sh"

id=""; expect_parent=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --id)            id="${2-}"; shift 2 ;;
    --expect-parent) expect_parent="${2-}"; shift 2 ;;
    *) die "unknown flag '$1'. Flags: --id <bead-id> [--expect-parent <parent-id>]" ;;
  esac
done
[[ -n "$id" ]] || die "missing required --id."
command -v jq >/dev/null || die "jq not on PATH. Install jq, then re-run."

raw="$(bd show --json "$id")" || die "'bd show --json $id' failed. Confirm the id, then re-run."
# bd show --json returns an ARRAY; index element 0.
bead="$(printf '%s' "$raw" | jq '.[0]')"
[[ "$bead" != "null" && -n "$bead" ]] || die "no Bead '$id' in the database. Confirm the id, then re-run."

fails=0
report() { printf '%s: %s\n  remedy: %s\n' "$SELF" "$1" "$2" >&2; fails=$((fails+1)); }

jqv() { printf '%s' "$bead" | jq -r "$1"; }

n_project="$(jqv '[.labels[]? | select(startswith("project:"))] | length')"
[[ "$n_project" == "1" ]] || report \
  "expected exactly one 'project:' label, found $n_project" \
  "bd update $id --set-labels 'project:<key>,accept:<mode>' (add tier: only when it applies)"

n_accept="$(jqv '[.labels[]? | select(startswith("accept:"))] | length')"
[[ "$n_accept" == "1" ]] || report \
  "expected exactly one 'accept:' label, found $n_accept" \
  "bd update $id --remove-label '<the wrong accept: label>'"

n_tier="$(jqv '[.labels[]? | select(startswith("tier:"))] | length')"
[[ "$n_tier" -le 1 ]] || report \
  "expected at most one 'tier:' label, found $n_tier" \
  "bd update $id --remove-label '<the wrong tier: label>'"

rb="$(jqv '.metadata["recognized-by"] // ""')"
[[ -n "$rb" ]] || report \
  "metadata 'recognized-by' is absent or empty; it is required always (contract §6.1)" \
  "bd update $id --metadata '{\"recognized-by\":\"<verbatim citation>\"}'"

n_class="$(jqv '[.labels[]? | select(startswith("class:"))] | length')"
[[ "$n_class" == "1" ]] || report \
  "expected exactly one 'class:' label, found $n_class (design §11.7)" \
  "bd update $id --add-label 'class:bounded-increment' (or 'class:hardened')"

budget_json="$(jqv '.metadata.budget // ""')"
if [[ -z "$budget_json" || "$budget_json" == "null" ]]; then
  report "metadata 'budget' is absent (design §11.7)" \
    "bd update $id --metadata '{\"budget\":{\"cycles\":2}}'"
else
  n_bad="$(jqv '(.metadata.budget // {}) | to_entries | map(select((.value | type) != "number" or (.value | floor) != .value or .value < 0)) | length')"
  [[ "$n_bad" == "0" ]] || report \
    "metadata 'budget' has a non-integer or negative dimension" \
    "bd update $id --metadata '{\"budget\":{\"cycles\":<non-negative integer>}}'"
fi

wu_raw="$(jqv '.metadata.workunit // ""')"
wu="$(eb_expand_seat_root "$wu_raw")"
if [[ -n "$wu" ]]; then
  manifest="${wu%/}/workunit.yaml"
  if [[ ! -d "${wu%/}" ]]; then
    report "metadata 'workunit' points at '${wu%/}', which is not a directory" \
      "correct the path: bd update $id --metadata '{\"workunit\":\"<real path>\"}'"
  elif [[ ! -f "$manifest" ]]; then
    report "'$manifest' does not exist, so the backlink is unwritable" \
      "create the manifest, then add:"$'\n'"beads:"$'\n'"  - $id"$'\n'"lifecycle: beads"
  elif ! grep -qF -- "- $id" "$manifest"; then
    report "'$manifest' carries no 'beads:' backlink to $id (contract §6.3)" \
      "append to $manifest:"$'\n'"beads:"$'\n'"  - $id"$'\n'"lifecycle: beads"
  elif ! grep -qE '^lifecycle:[[:space:]]*beads[[:space:]]*$' "$manifest"; then
    report "'$manifest' has a beads backlink but 'lifecycle: beads' is not set" \
      "set 'lifecycle: beads' in $manifest"
  fi
fi

if [[ -n "$expect_parent" ]]; then
  # parent_id / .parent is not the check — parentage lives in dependencies as parent-child.
  got="$(printf '%s' "$bead" | jq -r '[.dependencies[]? | select(.dependency_type=="parent-child") | .id] | join(",")')"
  [[ ",$got," == *",$expect_parent,"* ]] || report \
    "no 'parent-child' entry for '$expect_parent' in dependencies (found: ${got:-none})" \
    "bd update $id --parent $expect_parent --no-inherit-labels"
fi

[[ "$fails" -eq 0 ]] || die "$fails invariant(s) violated on $id. Apply the remedies above, then re-run." 1
