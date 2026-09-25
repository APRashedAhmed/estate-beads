#!/usr/bin/env bash
# eb-closeout-report.sh <handoff-path>  (or $CKPT_HANDOFF_PATH when no argument is given)
#
# The estate-beads closeout participant's engine (design §12.6). Reads the
# ARCHIVED handoff's `beads:` frontmatter list and runs
# `bead-report-success.sh --id <id> --evidence "archived handoff: <path>"`
# once per Bead named there. Never dispatches the accepting review (design
# §13, Dispatch: that is the executor's own session, after
# `bead-report-success.sh` prints `ACCEPTANCE-PENDING review`).
#
# A handoff with no `beads:` (or an empty list) is legitimate — a unit with no
# Bead (checkpointing skills/handoff/SKILL.md line 29) — and prints "no beads"
# on stdout, exit 0.
#
# Stdout: one "<id>: <bead-report-success.sh's own stdout line>" per Bead named
# in `beads:`, in list order.
#
# KNOWN GAP (recorded in reviews/u5-batch.md): the checkpoint dispatcher's
# `ckpt-participants.sh` v1 runs a `kind: shell` participant's `run:` line
# verbatim via Bash and passes it NO per-run values (see
# ~/.claude/checkpoint.d/at-checkpoint-saved.yml's header comment) — it cannot
# hand this script the archived handoff path it just produced. Until that
# dispatcher gains per-run value passing, this script accepts the path only
# via $1 or $CKPT_HANDOFF_PATH; given neither, it fails LOUD (never a silent
# no-op) naming the gap, so a real closeout surfaces it in the health notice
# rather than quietly skipping the Beads.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="eb-closeout-report"
die() { printf '%s: %s\n' "$SELF" "$1" >&2; exit "${2:-1}"; }

# shellcheck source=lib/eb-common.sh
source "$SCRIPT_DIR/lib/eb-common.sh"

handoff="${1:-${CKPT_HANDOFF_PATH:-}}"
[[ -n "$handoff" ]] || die "no handoff path given (\$1 or \$CKPT_HANDOFF_PATH). The checkpoint dispatcher's ckpt-participants.sh v1 passes shell participants no per-run values (see the header comment in this file); until it does, invoke this script directly with the archived handoff path."
[[ -f "$handoff" ]] || die "no file at '$handoff'."
command -v jq >/dev/null || die "jq not on PATH. Install jq, then re-run."

fm="$(eb_read_frontmatter "$SCRIPT_DIR/lib" "$handoff")" \
  || die "'$handoff' has no readable YAML frontmatter. Fix it, then re-run."

mapfile -t bead_ids < <(printf '%s' "$fm" | jq -r '(.beads // []) | .[]')

if [[ ${#bead_ids[@]} -eq 0 ]]; then
  printf 'no beads\n'
  exit 0
fi

fail=0
for id in "${bead_ids[@]}"; do
  [[ -n "$id" ]] || continue
  line="$("$SCRIPT_DIR/bead-report-success.sh" --id "$id" --evidence "archived handoff: ${handoff}" 2>&1)"
  rc=$?
  printf '%s: %s\n' "$id" "$line"
  [[ $rc -eq 0 ]] || fail=1
done

exit "$fail"
