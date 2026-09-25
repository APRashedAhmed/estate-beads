#!/usr/bin/env bash
# Claim a Bead and absorb the exit-code branch.
# Decision vocabulary on stdout, one word: CLAIMED | LOST. Skill prose branches on it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="bead-claim"
die() { printf '%s: %s\n' "$SELF" "$1" >&2; exit "${2:-1}"; }

# shellcheck source=lib/eb-common.sh
source "$SCRIPT_DIR/lib/eb-common.sh"

id=""; model_override=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --id)    id="${2-}"; shift 2 ;;
    --model) model_override="${2-}"; shift 2 ;;
    *) die "unknown flag '$1'. Flags: --id <bead-id> [--model haiku|sonnet|opus|fable]" ;;
  esac
done
[[ -n "$id" ]] || die "missing required --id."

# design §13 Verification / decision 1: the claim records metadata executor.model. --model
# overrides detection (an orchestrator on one model claims on behalf of a different executor).
executor_model=""
if [[ -n "$model_override" ]]; then
  eb_model_valid "$model_override" \
    || die "--model must be haiku|sonnet|opus|fable (got '$model_override')."
  executor_model="$model_override"
else
  executor_model="$(eb_detect_model || true)"
  if [[ -z "$executor_model" ]]; then
    die "the session model could not be detected (ua-model.sh reported no 'ok' state). Re-run with --model haiku|sonnet|opus|fable naming the executor's actual model."
  fi
fi

set +e
out="$(bd update "$id" --claim 2>&1)"
rc=$?
set -e

if [[ "$rc" -eq 0 ]]; then
  eb_metadata_merge "$id" "$(jq -nc --arg m "$executor_model" '{"executor":{"model":$m}}')" \
    || die "claim landed but recording metadata executor.model failed. Run: bd update $id --metadata '{\"executor\":{\"model\":\"$executor_model\"}}'"
  printf 'CLAIMED\n'
  exit 0
fi

# A lost race is non-zero. Distinguish it from a real error so the caller does not
# treat a broken database as a lost race.
if printf '%s' "$out" | grep -qiE 'claim|assigned|in.progress|already'; then
  printf 'LOST\n'
  exit 0
fi

printf '%s: bd update --claim failed for a reason other than a lost race:\n%s\n' "$SELF" "$out" >&2
die "fix the reported cause, then re-run." "$rc"
