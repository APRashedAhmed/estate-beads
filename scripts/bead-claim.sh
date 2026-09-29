#!/usr/bin/env bash
# Claim a Bead and absorb the exit-code branch.
# Decision vocabulary on stdout, one word: CLAIMED | LOST. Skill prose branches on it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="bead-claim"
die() { printf '%s: %s\n' "$SELF" "$1" >&2; exit "${2:-1}"; }

# shellcheck source=lib/eb-common.sh
source "$SCRIPT_DIR/lib/eb-common.sh"

id=""; model_override=""; effort_override=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --id)     id="${2-}"; shift 2 ;;
    --model)  model_override="${2-}"; shift 2 ;;
    --effort) effort_override="${2-}"; shift 2 ;;
    *) die "unknown flag '$1'. Flags: --id <bead-id> [--model sonnet|opus|fable] [--effort low|medium|high|xhigh|max]" ;;
  esac
done
[[ -n "$id" ]] || die "missing required --id."
if [[ -n "$effort_override" ]]; then
  case "$effort_override" in
    low|medium|high|xhigh|max) ;;
    *) die "--effort must be low|medium|high|xhigh|max (got '$effort_override')." ;;
  esac
fi

# design §13 Verification / decision 1: the claim records metadata executor.model. --model
# overrides detection (an orchestrator on one model claims on behalf of a different executor).
executor_model=""; executor_effort="$effort_override"
if [[ -n "$model_override" ]]; then
  eb_model_valid "$model_override" \
    || die "--model must be sonnet|opus|fable (got '$model_override')."
  executor_model="$model_override"
  # --model without --effort records no effort: the oracle's effort is the claiming session's.
else
  executor_model="$(eb_detect_model || true)"
  if [[ -z "$executor_model" ]]; then
    if [[ "$(eb_detect_raw_family || true)" == "haiku" ]]; then
      die "haiku is no longer an allowed executor model; claim from a sonnet/opus/fable session or pass --model sonnet|opus|fable naming the executor's actual model."
    fi
    die "the session model could not be detected (ua-model.sh reported no 'ok' state). Re-run with --model sonnet|opus|fable naming the executor's actual model."
  fi
  [[ -n "$executor_effort" ]] || executor_effort="$(eb_detect_effort || true)"
fi

set +e
out="$(bd update "$id" --claim 2>&1)"
rc=$?
set -e

if [[ "$rc" -eq 0 ]]; then
  frag="$(jq -nc --arg m "$executor_model" --arg e "$executor_effort" '{"executor":({"model":$m} + (if $e == "" then {} else {"effort":$e} end))}')"
  eb_metadata_merge "$id" "$frag" \
    || die "claim landed but recording metadata executor.model failed. Run: bd update $id --metadata '$frag'"
  if [[ -z "$executor_effort" ]]; then
    # The deep merge keeps an earlier executor.effort; a claim that records none must drop it
    # (a stale effort would pick the wrong verifier row). bd's --metadata replaces the whole
    # top-level `executor` object, and a dotted --unset-metadata does not reach it.
    execobj="$(bd show --json "$id" 2>/dev/null | jq -c '.[0].metadata.executor // {} | del(.effort)')" \
      || die "claim landed but clearing a stale executor.effort failed (bd show). Re-run: $SCRIPT_DIR/bead-release.sh --id $id, then bead-claim.sh --id $id --model $executor_model"
    bd update "$id" --metadata "$(jq -nc --argjson x "$execobj" '{"executor":$x}')" >/dev/null \
      || die "claim landed but clearing a stale executor.effort failed. Run: bd update $id --metadata '$(jq -nc --argjson x "$execobj" '{"executor":$x}')'"
  fi
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
