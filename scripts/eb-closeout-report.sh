#!/usr/bin/env bash
# eb-closeout-report.sh [<handoff-path>]  ($1 when non-empty, otherwise $CKPT_HANDOFF_PATH)
#
# <handoff-path> may be the rolling path or the archived path. When no file sits at it but
# `<its folder>/archive/<its file name>` is a file, that archived file is read and cited.
#
# The estate-beads closeout participant's engine (design §12.6). Reads the
# archived handoff's `beads:` frontmatter list and runs
# `bead-report-success.sh --id <id> --evidence "archived handoff: <path>"`
# once per Bead named there. Never dispatches the accepting review (design
# §13, Dispatch: that is the executor's own session, after
# `bead-report-success.sh` prints `ACCEPTANCE-PENDING review`). A Bead already
# closed prints `<id>: ALREADY-CLOSED` (bead-report-success.sh's own guard; no
# write happens).
#
# A handoff with no `beads:` (or an empty list) is legitimate — a unit with no
# Bead (checkpointing skills/handoff/SKILL.md line 29) — and prints "no beads"
# on stdout, exit 0.
#
# Stdout: one "<id>: <bead-report-success.sh's own stdout line>" per Bead named
# in `beads:`, in list order.
#
# GAP CLOSED (was recorded in reviews/u5-batch.md): the checkpoint dispatcher's
# `ckpt-participants.sh` now accepts `--handoff <path>` and, under `--event`,
# prefixes a `kind: shell` participant's emitted `run:` line with
# `CKPT_HANDOFF_PATH=<path>` (right after `CKPT_EVENT=<event>`) on a closeout
# event — the save-checkpoint skill resolves and passes the work unit's ROLLING
# handoff path there, before the handoff participant archives the file; this script falls back
# to the archived sibling when the rolling file is gone. It uses $1 when non-empty, otherwise
# that variable; given
# neither, it still fails LOUD (never a silent no-op) naming the gap, so an
# un-upgraded dispatcher (or a manual invocation) surfaces in the health notice
# rather than quietly skipping the Beads.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="eb-closeout-report"
die() { printf '%s: %s\n' "$SELF" "$1" >&2; exit "${2:-1}"; }

# shellcheck source=lib/eb-common.sh
source "$SCRIPT_DIR/lib/eb-common.sh"

handoff="${1:-${CKPT_HANDOFF_PATH:-}}"
[[ -n "$handoff" ]] || die "no handoff path given (\$1 or \$CKPT_HANDOFF_PATH). The dispatcher (ckpt-participants.sh) sets \$CKPT_HANDOFF_PATH on a closeout event; either it did not run this as a closeout participant, or you invoked this script directly without the archived handoff path — give one."
given="$handoff"
if [[ ! -f "$handoff" ]]; then
  archived="$(dirname "$handoff")/archive/$(basename "$handoff")"
  [[ -f "$archived" ]] && handoff="$archived"
fi
[[ -f "$handoff" ]] || die "no file at '$given'."
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
