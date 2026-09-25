#!/usr/bin/env bash
# create-beads-batch.sh --artifact <path> [--dry-run]
#
# Batch-author several Beads from one governing artifact (design §11.7, §12.2).
# Parses the artifact's fenced ```yaml block (scripts/lib/batch.py), resolves
# sibling parent/blocked-by/discovered-from references into a topological
# creation order, and composes ONE `create-bead.sh` call per unit — never
# `bd create` directly.
#
# Idempotent by unit `key` (metadata `key`, scoped to the batch's `project`):
# a rerun on the same artifact creates only new keys; an existing key whose
# title/accept/class match the artifact is a no-op; an existing key whose
# fields DRIFTED prints "EXISTS: <id>" plus a one-line diff hint on stderr and
# is never updated in place.
#
# Stdout: one "<key> <id>" line per Bead, in resolution order. Exit 0 when
# every key resolves to an id (created or already existing); non-zero on any
# create failure or on an unresolved/unknown external parent/dep id (checked
# BEFORE any Bead is created, so a bad reference creates nothing).
#
# --dry-run: prints the resolved create-bead.sh argument list per unit
# (sibling parent/dep values rendered as their bare KEY, never an id, since
# nothing is created) and creates nothing; still runs the external-id
# preflight (read-only).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="create-beads-batch"

die() { printf '%s: %s\n' "$SELF" "$1" >&2; exit "${2:-1}"; }

artifact=""; dry_run=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --artifact) artifact="${2-}"; shift 2 ;;
    --dry-run)  dry_run=1; shift ;;
    *) die "unknown flag '$1'. Flags: --artifact <path> [--dry-run]" ;;
  esac
done
[[ -n "$artifact" ]] || die "missing required --artifact <path>."
[[ -f "$artifact" ]] || die "no file at '$artifact'."
command -v jq >/dev/null || die "jq not on PATH. Install jq, then re-run."
command -v python3 >/dev/null || die "python3 not on PATH. Install python3 (with PyYAML), then re-run."
python3 -c 'import yaml' 2>/dev/null || die "python3 has no PyYAML ('import yaml' failed). Install it, then re-run."
[[ -n "${BEADS_DIR:-}" ]] || die "no \$BEADS_DIR, so no database. Report it to your orchestrator; never 'bd init'. Do not re-run."

artifact_abs="$(cd "$(dirname "$artifact")" && pwd)/$(basename "$artifact")"

plan_err="$(mktemp)"
plan="$(python3 "$SCRIPT_DIR/lib/batch.py" "$artifact_abs" 2>"$plan_err")"
rc=$?
if [[ $rc -ne 0 ]]; then
  cat "$plan_err" >&2
  rm -f "$plan_err"
  die "batch.py failed to resolve '$artifact_abs' (above). Fix the artifact, then re-run; nothing was created."
fi
rm -f "$plan_err"

project="$(printf '%s' "$plan" | jq -r '.project')"
recognized_by="$(printf '%s' "$plan" | jq -r '.recognized_by')"
n_units="$(printf '%s' "$plan" | jq '.units | length')"

# --- Preflight: every EXTERNAL parent/dep reference must already exist in bd, ---
# --- checked before any Bead is created (design decision: "unknown key -> error, nothing created"). ---
ext_ids="$(printf '%s' "$plan" | jq -r '
  [.units[] | (if .parent and .parent.kind == "external" then [.parent.value] else [] end),
              (.deps // [] | map(select(.kind == "external") | .value))]
  | flatten | unique | .[]')"
if [[ -n "$ext_ids" ]]; then
  while IFS= read -r extid; do
    [[ -n "$extid" ]] || continue
    bd show --json "$extid" >/dev/null 2>&1 \
      || die "parent/dep '$extid' is not a sibling key in this batch and not found in the database. Fix the artifact, then re-run; nothing was created."
  done <<<"$ext_ids"
fi

declare -A id_map
exit_code=0

resolve_ref() {  # <kind> <value> -> id (real run) or key (dry-run/unresolved) on stdout
  local kind="$1" value="$2"
  if [[ "$kind" == "sibling" ]]; then
    if [[ "$dry_run" -eq 1 ]]; then
      printf '%s' "$value"
    else
      printf '%s' "${id_map[$value]:-}"
    fi
  else
    printf '%s' "$value"
  fi
}

for i in $(seq 0 $((n_units - 1))); do
  u="$(printf '%s' "$plan" | jq -c ".units[$i]")"
  key="$(printf '%s' "$u" | jq -r '.key')"
  title="$(printf '%s' "$u" | jq -r '.title')"
  description="$(printf '%s' "$u" | jq -r '.description // ""')"
  [[ -n "$description" ]] || description="$title"
  acceptance="$(printf '%s' "$u" | jq -r '.acceptance')"
  accept="$(printf '%s' "$u" | jq -r '.accept')"
  btype="$(printf '%s' "$u" | jq -r '.type')"
  tier="$(printf '%s' "$u" | jq -r '.tier // ""')"
  effort="$(printf '%s' "$u" | jq -r '.effort // ""')"
  class="$(printf '%s' "$u" | jq -r '.class // ""')"
  budget="$(printf '%s' "$u" | jq -r '.budget // ""')"
  mapfile -t labels < <(printf '%s' "$u" | jq -r '.labels[]? // empty')

  parent_kind="$(printf '%s' "$u" | jq -r '.parent.kind // ""')"
  parent_value="$(printf '%s' "$u" | jq -r '.parent.value // ""')"

  mapfile -t dep_lines < <(printf '%s' "$u" | jq -r '.deps[]? | "\(.edge)\t\(.kind)\t\(.value)"')
  deps_resolved=()
  for line in "${dep_lines[@]}"; do
    [[ -n "$line" ]] || continue
    IFS=$'\t' read -r edge dkind dvalue <<<"$line"
    resolved_val="$(resolve_ref "$dkind" "$dvalue")"
    if [[ "$dkind" == "sibling" && "$dry_run" -eq 0 && -z "$resolved_val" ]]; then
      die "internal: sibling dep '$dvalue' for unit '$key' has no resolved id yet (topological order violated)."
    fi
    deps_resolved+=("${edge}:${resolved_val}")
  done
  deps_str=""
  if [[ ${#deps_resolved[@]} -gt 0 ]]; then
    deps_str="$(IFS=,; printf '%s' "${deps_resolved[*]}")"
  fi

  parent_resolved=""
  if [[ -n "$parent_kind" ]]; then
    parent_resolved="$(resolve_ref "$parent_kind" "$parent_value")"
    if [[ "$parent_kind" == "sibling" && "$dry_run" -eq 0 && -z "$parent_resolved" ]]; then
      die "internal: sibling parent '$parent_value' for unit '$key' has no resolved id yet (topological order violated)."
    fi
  fi

  argv=(create-bead.sh --title "$title" --description "$description" --acceptance "$acceptance"
        --project "$project" --accept "$accept" --recognized-by "$recognized_by"
        --type "$btype" --key "$key")
  [[ -n "$tier"   ]] && argv+=(--tier "$tier")
  [[ -n "$effort" ]] && argv+=(--effort "$effort")
  [[ -n "$class"  ]] && argv+=(--class "$class")
  [[ -n "$budget" ]] && argv+=(--budget "$budget")
  for l in "${labels[@]}"; do argv+=(--label "$l"); done
  [[ -n "$parent_resolved" ]] && argv+=(--parent "$parent_resolved")
  [[ -n "$deps_str" ]] && argv+=(--deps "$deps_str")

  if [[ "$dry_run" -eq 1 ]]; then
    printf '%s\n' "${argv[*]}"
    continue
  fi

  existing_json="$(bd list --json --status open,in_progress,blocked,deferred,closed --limit 0 2>/dev/null \
    | jq -c --arg k "$key" --arg p "$project" \
      'map(select(.metadata.key == $k and ((.labels // []) | index("project:" + $p) != null))) | .[0] // empty')"

  if [[ -n "$existing_json" ]]; then
    existing_id="$(printf '%s' "$existing_json" | jq -r '.id')"
    e_title="$(printf '%s' "$existing_json" | jq -r '.title')"
    e_accept="$(printf '%s' "$existing_json" | jq -r '[.labels[]? | select(startswith("accept:"))] | .[0] // ""')"
    e_class="$(printf '%s' "$existing_json" | jq -r '[.labels[]? | select(startswith("class:"))] | .[0] // ""')"
    w_accept="accept:${accept}"
    w_class="class:${class:-bounded-increment}"
    if [[ "$e_title" == "$title" && "$e_accept" == "$w_accept" && "$e_class" == "$w_class" ]]; then
      id_map["$key"]="$existing_id"
      printf '%s %s\n' "$key" "$existing_id"
    else
      hint=""
      [[ "$e_title"  != "$title"   ]] && hint="${hint}title: '$e_title' -> '$title'; "
      [[ "$e_accept" != "$w_accept" ]] && hint="${hint}${e_accept:-accept:<none>} -> ${w_accept}; "
      [[ "$e_class"  != "$w_class"  ]] && hint="${hint}${e_class:-class:<none>} -> ${w_class}; "
      printf 'EXISTS: %s\n' "$existing_id" >&2
      printf '%s: key "%s" drifted from the artifact: %s. Remedy: bd update %s to match the drifted field(s), or give the artifact unit a different --key if it names a different Bead.\n' \
        "$SELF" "$key" "${hint%%; }" "$existing_id" >&2
      id_map["$key"]="$existing_id"
      printf '%s %s\n' "$key" "$existing_id"
    fi
    continue
  fi

  run_argv=("$SCRIPT_DIR/create-bead.sh" "${argv[@]:1}")
  out="$("${run_argv[@]}" 2>/tmp/create-beads-batch.$$.err)"
  create_rc=$?
  if [[ $create_rc -ne 0 ]]; then
    cat /tmp/create-beads-batch.$$.err >&2
    rm -f /tmp/create-beads-batch.$$.err
    die "create-bead.sh failed for key '$key' (above). Fix the reported cause; already-created units in this run are unaffected (idempotent by key), then re-run."
  fi
  rm -f /tmp/create-beads-batch.$$.err

  new_id="$out"
  if [[ "$out" == EXISTS:\ * ]]; then
    new_id="${out#EXISTS: }"
  fi
  id_map["$key"]="$new_id"
  printf '%s %s\n' "$key" "$new_id"
done

exit "$exit_code"
