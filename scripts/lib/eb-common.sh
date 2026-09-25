#!/usr/bin/env bash
# eb-common.sh — shared helpers sourced by every estate-beads script. Never executed directly.
# Sourced with: source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/eb-common.sh"
# (each caller computes its OWN SCRIPT_DIR first; this file never assumes one).

# --- SEAT_ROOT expansion (design §9; U2 pre-answered decision 12) --------------------------
# A leading literal "$SEAT_ROOT" in a metadata path (workunit references written before this
# fix existed) is expanded before any filesystem test. Never a shell-level expansion — the
# string is stored literally in bd's metadata JSON.
eb_expand_seat_root() {
  local p="$1"
  printf '%s' "${p/\$SEAT_ROOT/${SEAT_ROOT:-$HOME/heliopolis}}"
}

# --- Metadata merge (decision 3) ------------------------------------------------------------
# Read the Bead's existing metadata, deep-merge the given JSON fragment over it (jq `*`), write
# the FULL merged object back. Never loses an existing key even if bd's own --metadata merge
# behaves differently across versions.
eb_metadata_merge() {  # <id> <json-fragment>
  local id="$1" frag="$2" existing merged
  existing="$(bd show --json "$id" 2>/dev/null | jq -c '.[0].metadata // {}')" \
    || { printf 'eb-common: bd show --json failed for %s; refusing to merge metadata (would drop existing keys)\n' "$id" >&2; return 1; }
  [[ -n "$existing" && "$existing" != "null" ]] || existing='{}'
  merged="$(jq -nc --argjson a "$existing" --argjson b "$frag" '$a * $b')" \
    || { printf 'eb-common: metadata merge failed to build JSON for %s\n' "$id" >&2; return 1; }
  bd update "$id" --metadata "$merged" >/dev/null
}

# --- Model ladder (design §13, decision 1/4) ------------------------------------------------
# haiku < sonnet < opus < fable. Returns the numeric rank on stdout, or empty + rc=1 for an
# unrecognized name.
eb_model_rank() {
  case "${1:-}" in
    haiku)  printf '1\n' ;;
    sonnet) printf '2\n' ;;
    opus)   printf '3\n' ;;
    fable)  printf '4\n' ;;
    *) return 1 ;;
  esac
}

eb_model_valid() {
  case "${1:-}" in haiku|sonnet|opus|fable) return 0 ;; *) return 1 ;; esac
}

# --- Model detection (decision 1) -----------------------------------------------------------
# Detect the current session's model via the ua-model oracle. Overridable for hermetic tests
# via EB_MODEL_ORACLE (defaults to the fixed install path the oracle documents itself at).
# Prints the ladder name (haiku|sonnet|opus|fable) on stdout and returns 0 when the oracle
# reports state "ok" and a recognized family; returns 1 (prints nothing) otherwise — every
# non-ok oracle state nulls the trusted keys by the oracle's own contract, so "not ok" is
# always treated as undetectable, never as a confidently-wrong guess.
eb_detect_model() {
  local oracle="${EB_MODEL_ORACLE:-$HOME/.claude/state/ua-model.sh}"
  [[ -x "$oracle" || -f "$oracle" ]] || return 1
  local out state family
  out="$(bash "$oracle" get --json 2>/dev/null)" || return 1
  state="$(printf '%s' "$out" | jq -r '.state // ""' 2>/dev/null)"
  [[ "$state" == "ok" ]] || return 1
  family="$(printf '%s' "$out" | jq -r '.family // ""' 2>/dev/null)"
  eb_model_valid "$family" || return 1
  printf '%s\n' "$family"
}

# --- Open-blocker check (atomic-close fix) ---------------------------------------------------
# `bd close` refuses (without --force) when the Bead has an open `blocks` dependency (a Bead
# whose status is not closed, listed against this Bead with dependency_type "blocks" — i.e. it
# blocks this Bead / this Bead is blocked-by it). Callers MUST run this BEFORE any mutation and
# refuse atomically (no partial state change) when it reports blockers.
# Prints a comma-joined list of open blocker ids on stdout (empty if none). Returns 1 (prints
# nothing) if `bd show --json` itself failed — callers must fail closed on that, same as any
# other `bd show` failure.
eb_open_blockers() {  # <id> -> comma-joined open blocker ids on stdout
  local id="$1" json
  json="$(bd show --json "$id" 2>/dev/null)" || return 1
  printf '%s' "$json" \
    | jq -r '(.[0].dependencies // []) | map(select((.dependency_type == "blocks" or .dependency_type == "blocked-by") and .status != "closed") | .id) | join(",")'
}

# --- Frontmatter reader (decision 5) ---------------------------------------------------------
# Print a review report's YAML frontmatter as JSON on stdout. Uses the vendored python3 helper
# (PyYAML) rather than yq so the parser is stable across yq's Go/Python variants.
eb_read_frontmatter() {  # <lib-dir> <report-path>
  local libdir="$1" report="$2"
  python3 "$libdir/frontmatter.py" "$report"
}
