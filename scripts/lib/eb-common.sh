#!/usr/bin/env bash
# eb-common.sh — shared helpers sourced by every estate-beads script. Never executed directly.
# Sourced with: source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/eb-common.sh"
# (each caller computes its OWN SCRIPT_DIR first; this file never assumes one).

# --- SEAT_ROOT expansion (design §9; U2 pre-answered decision 12) --------------------------
# A leading literal "$SEAT_ROOT" in a metadata path (workunit references written before this
# fix existed) is expanded before any filesystem test. Never a shell-level expansion — the
# string is stored literally in bd's metadata JSON.
# m5 residual (fix round 2, review pa-s2s.8-review-2): the `$HOME/heliopolis` fallback is exactly
# that — a fallback, used only when $SEAT_ROOT is unset. SEAT_ROOT is an estate-wide session
# convention (every seat exports it; see ~/.agents/AGENTS.md "Important Locations"), so this
# resolves correctly on any seat where it is exported, same as every other estate script that
# reads it. Settled here, not deferred further: a hardcoded fallback for the rare unexported case
# is strictly better than dying outright, and no operator ruling has named a different default.
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
# sonnet < opus < fable. Returns the numeric rank on stdout, or empty + rc=1 for an
# unrecognized name. `haiku` stays rank 1 so Beads whose recorded executor.model is haiku still
# evaluate; it is no longer a valid choice for new claims or reviewers (see eb_model_valid).
eb_ladder_file() {
  [[ -n "${EB_LADDER_FILE:-}" ]] && { printf '%s\n' "$EB_LADDER_FILE"; return 0; }
  printf '%s\n' "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/verifier-ladder.json"
}

eb_model_rank() {
  local r
  r="$(jq -r --arg m "${1:-}" '.claude_ranks[$m] // empty' "$(eb_ladder_file)" 2>/dev/null)" || return 1
  [[ -n "$r" ]] || return 1
  printf '%s\n' "$r"
}

eb_model_valid() {
  case "${1:-}" in sonnet|opus|fable) return 0 ;; *) return 1 ;; esac
}

# eb_reviewer_adequate <exec-model> <exec-effort|""> <vendor|""> <model> <effort|"">
# rc 0 = reviewer adequate for the executor. Non-zero = one-line reason on stderr.
# claude (or vendor absent): reviewer rank > executor rank, or both top (fable); effort ignored.
# codex: model@effort must be a ladder point whose rank >= the executor's row (missing effort =
# strictest row for the model). Reads verifier-ladder.json; never reads Bead labels (ADR-030).
eb_reviewer_adequate() {
  local xm="${1:-}" xe="${2:-}" vendor="${3:-}" rm="${4:-}" re="${5:-}" lf xr rr top need
  lf="$(eb_ladder_file)"
  jq -e . "$lf" >/dev/null 2>&1 || { printf "verifier ladder '%s' is missing or unreadable (plugin install defect)\n" "$lf" >&2; return 1; }
  [[ -n "$vendor" ]] || vendor=claude
  case "$vendor" in
    claude)
      eb_model_valid "$rm" || { printf "reviewer.model '%s' is not on the claude ladder (sonnet|opus|fable)\n" "$rm" >&2; return 1; }
      xr="$(eb_model_rank "$xm")" || { printf "executor.model '%s' is not on the ladder\n" "$xm" >&2; return 1; }
      rr="$(eb_model_rank "$rm")" || { printf "reviewer.model '%s' has no rank in the ladder file\n" "$rm" >&2; return 1; }
      top="$(eb_model_rank fable)" || { printf "ladder file has no rank for 'fable'\n" >&2; return 1; }
      [[ "$xr" =~ ^[0-9]+$ && "$rr" =~ ^[0-9]+$ && "$top" =~ ^[0-9]+$ ]] || { printf "verifier ladder '%s' has a non-numeric claude rank\n" "$lf" >&2; return 1; }
      if [[ "$xr" == "$top" ]]; then
        (( rr >= xr )) || { printf "reviewer '%s' is below executor '%s'; a top-tier executor needs a claude reviewer of fable\n" "$rm" "$xm" >&2; return 1; }
      else
        (( rr > xr )) || { printf "reviewer '%s' does not outrank executor '%s' (sonnet<opus<fable); need a claude reviewer one tier above\n" "$rm" "$xm" >&2; return 1; }
      fi
      ;;
    codex)
      [[ -n "$rm" && -n "$re" ]] || { printf "codex reviewer needs both reviewer.model and reviewer.effort\n" >&2; return 1; }
      rr="$(jq -r --arg k "$rm@$re" '.codex_points[$k] // empty' "$lf" 2>/dev/null)"
      [[ -n "$rr" ]] || { printf "'%s@%s' is not on the codex verifier ladder\n" "$rm" "$re" >&2; return 1; }
      xr="$(jq -r --arg m "$xm" --arg e "${xe:-missing}" '.executor_rows[$m] | if . == null then empty else (.[$e] // .missing) end' "$lf" 2>/dev/null)"
      [[ -n "$xr" ]] || { printf "executor.model '%s' has no codex verifier row\n" "$xm" >&2; return 1; }
      [[ "$xr" =~ ^[0-9]+$ && "$rr" =~ ^[0-9]+$ ]] || { printf "verifier ladder '%s' has a non-numeric row or point value\n" "$lf" >&2; return 1; }
      if (( rr < xr )); then
        need="$(jq -r --argjson x "$xr" '.codex_points | to_entries | map(select(.value == $x)) | .[0].key' "$lf" 2>/dev/null)"
        local alt="a claude reviewer one tier above the executor"
        [[ "$xm" == fable ]] && alt="a fable reviewer"
        printf "codex '%s@%s' (point %s) is below executor '%s/%s' (row %s); lowest adequate codex point is %s (or %s)\n" "$rm" "$re" "$rr" "$xm" "${xe:-<no effort>}" "$xr" "$need" "$alt" >&2
        return 1
      fi
      ;;
    *) printf "reviewer.vendor '%s' is not claude|codex\n" "$vendor" >&2; return 1 ;;
  esac
}

# Oracle effort (the session's own); prints low|medium|high|xhigh|max, or returns 1 if undetectable.
eb_detect_effort() {
  local oracle="${EB_MODEL_ORACLE:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/state/ua-model.sh}" out e
  [[ -x "$oracle" || -f "$oracle" ]] || return 1
  out="$(bash "$oracle" get --json 2>/dev/null)" || return 1
  [[ "$(printf '%s' "$out" | jq -r '.state // ""' 2>/dev/null)" == "ok" ]] || return 1
  e="$(printf '%s' "$out" | jq -r '.effort // ""' 2>/dev/null)"
  case "$e" in low|medium|high|xhigh|max) printf '%s\n' "$e" ;; *) return 1 ;; esac
}

# --- Model detection (decision 1) -----------------------------------------------------------
# Detect the current session's model via the ua-model oracle. Overridable for hermetic tests
# via EB_MODEL_ORACLE (defaults to the fixed install path the oracle documents itself at, under
# ${CLAUDE_CONFIG_DIR:-$HOME/.claude} — m5, fix round 2 residual: this estate is per-account
# config-dir keyed, same as the sweep's transcript root in eb-session-start.sh; a hardcoded
# $HOME/.claude here would look for another account's oracle state file).
# eb_detect_raw_family prints the oracle's family (any value, e.g. haiku) when state is ok, so callers
# can tell a retired model apart from an undetectable one.
# Prints the ladder name (sonnet|opus|fable) on stdout and returns 0 when the oracle
# reports state "ok" and a recognized family; returns 1 (prints nothing) otherwise — every
# non-ok oracle state nulls the trusted keys by the oracle's own contract, so "not ok" is
# always treated as undetectable, never as a confidently-wrong guess.
eb_detect_raw_family() {
  local oracle="${EB_MODEL_ORACLE:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/state/ua-model.sh}"
  [[ -x "$oracle" || -f "$oracle" ]] || return 1
  local out state
  out="$(bash "$oracle" get --json 2>/dev/null)" || return 1
  state="$(printf '%s' "$out" | jq -r '.state // ""' 2>/dev/null)"
  [[ "$state" == "ok" ]] || return 1
  printf '%s' "$out" | jq -r '.family // ""' 2>/dev/null
}

eb_detect_model() {
  local family
  family="$(eb_detect_raw_family)" || return 1
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
