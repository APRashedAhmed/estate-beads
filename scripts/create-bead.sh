#!/usr/bin/env bash
# Author one estate Bead: labels, metadata, dependencies, the workunit.yaml
# backlink, and (for a migration) the migration-log line — in one action.
# Prints the Bead id on stdout and nothing else — except when an equivalent
# Bead already exists, in which case it prints "EXISTS: <id>", writes
# nothing, and exits 0 (see the idempotency guard below; --force skips it).
# --migration-log defaults to the real estate migration log; --workunit has
# no default. A dry run must pass both explicitly, pointed at scratch paths.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="create-bead"

die() { printf '%s: %s\n' "$SELF" "$1" >&2; exit "${2:-1}"; }

# shellcheck source=lib/eb-common.sh
source "$SCRIPT_DIR/lib/eb-common.sh"

title=""; btype="task"; description=""; acceptance=""
project=""; accept=""; recognized_by=""
tier=""; effort=""; workunit=""; governs=""; packet=""
parent=""; deps=""; by=""
# m5 (fix round 2, review pa-s2s.8-review-2): same fallback rationale as eb-common.sh's
# eb_expand_seat_root — SEAT_ROOT is an estate-wide session convention every seat exports, so
# $HOME/heliopolis only fires in the rare unexported case; settled, not deferred further.
migration_log="${SEAT_ROOT:-$HOME/heliopolis}/PerAnkh/projects/permaat/workunits/2026-09-17-beads-state-sovereignty/migration-log.md"
migrated_from=()
force=0
key=""; extra_labels=(); class=""; budget=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --title)          title="${2-}"; shift 2 ;;
    --type)           btype="${2-}"; shift 2 ;;
    --description)    description="${2-}"; shift 2 ;;
    --acceptance)     acceptance="${2-}"; shift 2 ;;
    --project)        project="${2-}"; shift 2 ;;
    --accept)         accept="${2-}"; shift 2 ;;
    --recognized-by)  recognized_by="${2-}"; shift 2 ;;
    --tier)           tier="${2-}"; shift 2 ;;
    --effort)         effort="${2-}"; shift 2 ;;
    --workunit)       workunit="${2-}"; shift 2 ;;
    --governs)        governs="${2-}"; shift 2 ;;
    --packet)         packet="${2-}"; shift 2 ;;
    --parent)         parent="${2-}"; shift 2 ;;
    --deps)           deps="${2-}"; shift 2 ;;
    --migrated-from)  migrated_from+=("${2-}"); shift 2 ;;
    --migration-log)  migration_log="${2-}"; shift 2 ;;
    --by)             by="${2-}"; shift 2 ;;
    --force)          force=1; shift ;;
    --key)            key="${2-}"; shift 2 ;;
    --label)          extra_labels+=("${2-}"); shift 2 ;;
    --class)          class="${2-}"; shift 2 ;;
    --budget)         budget="${2-}"; shift 2 ;;
    *) die "unknown flag '$1'. Flags: --title --type --description --acceptance --project --accept --recognized-by [--tier --effort --workunit --governs --packet --parent --deps --migrated-from --migration-log --by --force --key --label --class --budget]" ;;
  esac
done

for pair in title:"$title" description:"$description" acceptance:"$acceptance" \
            project:"$project" accept:"$accept" recognized-by:"$recognized_by"; do
  [[ -n "${pair#*:}" ]] || die "missing required --${pair%%:*}. Supply it and re-run."
done
command -v jq >/dev/null || die "jq not on PATH. Install jq, then re-run."
[[ -n "${BEADS_DIR:-}" ]] || die "no \$BEADS_DIR, so no database. Report it to your orchestrator; never 'bd init'. Do not re-run."

case "$accept" in evidence|independent|operator) ;; *) die "--accept must be evidence|independent|operator (got '$accept')." ;; esac
if [[ -n "$tier" ]]; then
  case "$tier" in fable|opus|sonnet) ;; *) die "--tier must be fable|opus|sonnet (got '$tier')." ;; esac
fi
if [[ -n "$class" ]]; then
  case "$class" in bounded-increment|hardened) ;; *) die "--class must be bounded-increment|hardened (got '$class')." ;; esac
else
  class="bounded-increment"
fi
# --budget cycles=<n>[,dim=<n>...], each value a non-negative integer (design §11.7).
budget_json='{"cycles":2}'
if [[ -n "$budget" ]]; then
  budget_json='{}'
  IFS=',' read -r -a __b_pairs <<<"$budget"
  for pair in "${__b_pairs[@]}"; do
    dim="${pair%%=*}"; val="${pair#*=}"
    [[ -n "$dim" && "$dim" != "$pair" ]] || die "--budget entry '$pair' is not 'dim=<n>'."
    [[ "$val" =~ ^[0-9]+$ ]] || die "--budget '$dim' must be a non-negative integer (got '$val')."
    budget_json="$(jq -nc --argjson b "$budget_json" --arg d "$dim" --argjson v "$val" '$b + {($d): $v}')"
  done
fi
if [[ "$deps" == *"external:"* ]]; then
  die "--deps carries an 'external:' edge; the estate does not use them. Drop it and re-run."
fi
if [[ "$deps" == *"blocks:"* ]]; then
  die "--deps carries 'blocks:', which points the edge the other way (the target depends on this Bead). Use 'blocked-by:<id>' or a bare id, then re-run."
fi
if [[ ${#migrated_from[@]} -gt 0 && -z "$workunit" ]]; then
  die "--migrated-from requires --workunit (a §5.2 migration always has a work-unit path); supply --workunit and re-run."
fi

# Migration-log existence check runs BEFORE bd create, so a missing log fails
# the run with no Bead created — not after, when it would already exist.
if [[ ${#migrated_from[@]} -gt 0 ]]; then
  [[ -f "$migration_log" ]] || die "migration log '$migration_log' does not exist. Create it with a '## Migrated Beads' heading, then re-run. No Bead was created."
  grep -qE '^## Migrated Beads' "$migration_log" || die "'$migration_log' has no '## Migrated Beads' heading. Add it, then re-run. No Bead was created."
fi

# Idempotency guard: refuse to double-create. Keyed on --migrated-from when
# given (exact match against an existing Bead's structured `migrated-from`
# metadata only — never free text, so a Bead that merely mentions the path
# does not trip it), else on an exact --title match. --force skips this entirely.
if [[ "$force" -ne 1 ]]; then
  existing_id=""
  list_json="$(bd list --json --status open,in_progress,blocked --limit 0 2>/dev/null)" \
    || die "'bd list --json' failed while running the idempotency guard. Fix the reported cause, then re-run; no Bead was created."
  # --key is the first idempotency match (decision 11/design §12.2); falls back to
  # --migrated-from, then the exact --title match, in that order.
  if [[ -n "$key" ]]; then
    existing_id="$(printf '%s' "$list_json" | jq -r --arg k "$key" 'map(select(.metadata.key == $k)) | .[0].id // empty')"
  fi
  if [[ -z "$existing_id" && ${#migrated_from[@]} -gt 0 ]]; then
    for mf in "${migrated_from[@]}"; do
      existing_id="$(printf '%s' "$list_json" | jq -r --arg mf "$mf" '
        map(select((.metadata["migrated-from"] // []) | index($mf) != null)) | .[0].id // empty')"
      [[ -n "$existing_id" ]] && break
    done
  fi
  if [[ -z "$existing_id" && -z "$key" && ${#migrated_from[@]} -eq 0 ]]; then
    existing_id="$(printf '%s' "$list_json" | jq -r --arg t "$title" 'map(select(.title == $t)) | .[0].id // empty')"
  fi
  if [[ -n "$existing_id" ]]; then
    printf 'EXISTS: %s\n' "$existing_id"
    exit 0
  fi
fi

# Labels: exactly one project:, exactly one accept:, at most one tier:/effort:, exactly one
# class: (default bounded-increment). --label is repeatable and additive.
labels="project:${project},accept:${accept},class:${class}"
[[ -n "$tier"   ]] && labels="${labels},tier:${tier}"
[[ -n "$effort" ]] && labels="${labels},effort:${effort}"
for l in "${extra_labels[@]}"; do labels="${labels},${l}"; done

# Metadata: hyphenated keys go only through --metadata JSON (--set-metadata rejects them).
mf_json='[]'
if [[ ${#migrated_from[@]} -gt 0 ]]; then
  mf_json="$(printf '%s\n' "${migrated_from[@]}" | jq -R . | jq -s .)"
fi
metadata="$(jq -nc \
  --arg rb "$recognized_by" --arg wu "$workunit" --arg gv "$governs" --arg pk "$packet" --arg key "$key" \
  --argjson mf "$mf_json" --argjson budget "$budget_json" '
  {"recognized-by": $rb, "budget": $budget}
  + (if $wu != "" then {"workunit": $wu} else {} end)
  + (if $gv != "" then {"governs": $gv} else {} end)
  + (if $pk != "" then {"packet": $pk} else {} end)
  + (if $key != "" then {"key": $key} else {} end)
  + (if ($mf | length) > 0 then {"migrated-from": $mf} else {} end)')"

cmd=(bd create "$title" --type "$btype" --description "$description"
     --acceptance "$acceptance" --labels "$labels" --metadata "$metadata" --json)
[[ -n "$governs" ]] && cmd+=(--spec-id "$governs")
[[ -n "$deps"    ]] && cmd+=(--deps "$deps")
# --parent inherits EVERY namespaced label from the parent (accept:, tier:, project:),
# yielding two acceptance authorities on one Bead. Always disable inheritance.
[[ -n "$parent"  ]] && cmd+=(--parent "$parent" --no-inherit-labels)

if ! created="$("${cmd[@]}" 2>/tmp/create-bead.$$.err)"; then
  printf '%s: bd create failed:\n' "$SELF" >&2
  cat /tmp/create-bead.$$.err >&2
  rm -f /tmp/create-bead.$$.err
  die "fix the reported cause, then re-run; no Bead was created."
fi
rm -f /tmp/create-bead.$$.err

id="$(printf '%s' "$created" | jq -r '.id // empty')"
[[ -n "$id" ]] || die "bd create returned no id. Run 'bd list --json' to check whether a Bead landed before re-running."

# Backlink, same action (contract §6.3). The Bead side is authoritative; this repairs the manifest.
if [[ -n "$workunit" ]]; then
  expanded_workunit="$(eb_expand_seat_root "$workunit")"
  manifest="${expanded_workunit%/}/workunit.yaml"
  [[ -f "$manifest" ]] || die "Bead $id was created, but '$manifest' does not exist so the backlink could not be written. Create the manifest, then run: $SCRIPT_DIR/check-bead.sh --id $id. Do not re-run this script."
  if grep -qE '^beads:' "$manifest"; then
    awk -v id="$id" '{print} /^beads:[[:space:]]*$/ {print "  - " id}' "$manifest" >"${manifest}.tmp" && mv "${manifest}.tmp" "$manifest"
  else
    printf 'beads:\n  - %s\n' "$id" >>"$manifest"
  fi
  if grep -qE '^lifecycle:' "$manifest"; then
    sed -i -E 's|^lifecycle:.*$|lifecycle: beads|' "$manifest"
  else
    printf 'lifecycle: beads\n' >>"$manifest"
  fi
fi

# Migration-log line — only for a §5.2 migration (contract part 4 §6.1). Brand-new work gets none.
# Existence and heading were already checked before bd create, above.
if [[ ${#migrated_from[@]} -gt 0 ]]; then
  printf -- '- %s | %s | migrated-from: %s | workunit: %s | by: %s\n' \
    "$(date +%F)" "$id" "$(IFS=,; printf '%s' "${migrated_from[*]}")" \
    "${workunit:+$(eb_expand_seat_root "$workunit" | sed 's#/*$##')/workunit.yaml}" \
    "${by:-${CLAUDE_CODE_SESSION_ID:-bead-author}}" \
    | tee -a "$migration_log" >/dev/null
fi

checker=("$SCRIPT_DIR/check-bead.sh" --id "$id")
[[ -n "$parent" ]] && checker+=(--expect-parent "$parent")
"${checker[@]}" || die "Bead $id was created but failed its own check (above). Repair it with the named command; do not re-run this script."

printf '%s\n' "$id"
