#!/usr/bin/env bash
# eb-closeout-report.sh: two `beads:` in a fixture handoff -> two
# bead-report-success.sh calls, evidence citing the archived path; no beads ->
# "no beads"; no path given -> loud failure naming the dispatcher gap
# (design §12.6; plan U5). A handoff naming one open and one closed Bead -> the
# open one reports as before, the closed one prints "<id>: ALREADY-CLOSED"
# (pa-g6y, work-unit 2026-10-02-closeout-closed-bead-guard).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source tests/_scratch_db.sh
source tests/_assert.sh

FIXTURE="$ROOT/tests/fixtures/closeout/handoff-sample.md"

eb_scratch_db scratch closeout-report || exit 1
trap 'rm -rf "$scratch"' EXIT

a="$(scripts/create-bead.sh --title "Sample A" --description d --acceptance a --project p --accept evidence --recognized-by x --key sample-a)"
b="$(scripts/create-bead.sh --title "Sample B" --description d --acceptance a --project p --accept operator --recognized-by x --key sample-b)"

# The fixture's `beads:` list is keys, not ids — rewrite a scratch copy with this run's real ids.
handoff="$scratch/handoff-sample.md"
sed "s/beads: \[sample-a, sample-b\]/beads: [$a, $b]/" "$FIXTURE" >"$handoff"

out="$(scripts/eb-closeout-report.sh "$handoff")"; rc=$?
assert_rc "eb-closeout-report exits 0 on two accept:evidence/operator beads" 0 "$rc"
n_lines="$(printf '%s\n' "$out" | wc -l)"
assert_eq "one report line per Bead named in beads:" "2" "$n_lines"
assert_contains "reports the accept:evidence Bead CLOSED" "$out" "$a: CLOSED"
assert_contains "reports the accept:operator Bead ACCEPTANCE-PENDING" "$out" "$b: ACCEPTANCE-PENDING operator"

a_evidence="$(bd show --json "$a" 2>/dev/null | jq -r '.[0].notes // ""')"
assert_contains "Bead A's evidence cites the archived handoff path" "$a_evidence" "archived handoff: $handoff"
b_evidence="$(bd show --json "$b" 2>/dev/null | jq -r '.[0].notes // ""')"
assert_contains "Bead B's evidence cites the archived handoff path" "$b_evidence" "archived handoff: $handoff"

# --- no beads: -> "no beads", exit 0, no bead-report-success call --------------------------------
empty_handoff="$scratch/handoff-empty.md"
printf -- '---\nstatus: complete\nupdated: 2026-09-24\n---\n\n# Handoff (no beads)\n' >"$empty_handoff"
out2="$(scripts/eb-closeout-report.sh "$empty_handoff")"; rc2=$?
assert_rc "a handoff with no beads: exits 0" 0 "$rc2"
assert_eq "a handoff with no beads: prints exactly 'no beads'" "no beads" "$out2"

# --- no handoff path (neither \$1 nor \$CKPT_HANDOFF_PATH) -> loud failure -----------------------
( unset CKPT_HANDOFF_PATH; out3="$(scripts/eb-closeout-report.sh 2>&1)"; rc3=$?; \
  echo "$out3" >"$scratch/no-arg.out"; echo "$rc3" >"$scratch/no-arg.rc" )
out3="$(cat "$scratch/no-arg.out")"; rc3="$(cat "$scratch/no-arg.rc")"
assert_rc "no handoff path given fails (nonzero)" 1 "$rc3"
assert_contains "the failure names the dispatcher gap" "$out3" "ckpt-participants.sh"

# --- \$CKPT_HANDOFF_PATH is honored when \$1 is absent -------------------------------------------
out4="$(CKPT_HANDOFF_PATH="$empty_handoff" scripts/eb-closeout-report.sh)"; rc4=$?
assert_rc "\$CKPT_HANDOFF_PATH alone resolves the handoff" 0 "$rc4"
assert_eq "\$CKPT_HANDOFF_PATH path behaves the same as \$1" "no beads" "$out4"

# --- one open, one closed Bead in beads: -> open reports as before, closed prints ALREADY-CLOSED --
open_bead="$(scripts/create-bead.sh --title "Open" --description d --acceptance a --project p --accept evidence --recognized-by x)"
closed_bead="$(scripts/create-bead.sh --title "Closed" --description d --acceptance a --project p --accept evidence --recognized-by x)"
bd close "$closed_bead" --reason accepted >/dev/null

mixed_handoff="$scratch/handoff-mixed.md"
printf -- '---\nstatus: complete\nupdated: 2026-09-24\nbeads: [%s, %s]\n---\n\n# Handoff (mixed)\n' \
  "$open_bead" "$closed_bead" >"$mixed_handoff"

out5="$(scripts/eb-closeout-report.sh "$mixed_handoff")"; rc5=$?
assert_rc "mixed open/closed handoff exits 0" 0 "$rc5"
assert_contains "the open Bead reports CLOSED as before" "$out5" "$open_bead: CLOSED"
assert_contains "the closed Bead reports ALREADY-CLOSED" "$out5" "$closed_bead: ALREADY-CLOSED"

# --- archived handoff: rolling path gone, file under archive/ -> same output, evidence names the archive path
mk() { scripts/create-bead.sh --title "$1" --description d --acceptance a --project p --accept operator --recognized-by x; }
arc_bead="$(mk Arc)"
mkdir -p "$scratch/roll/archive"
arc="$scratch/roll/archive/h.md"
printf -- '---\nstatus: complete\nbeads: [%s]\n---\n' "$arc_bead" >"$arc"
rolling="$scratch/roll/h.md"
out_roll="$(scripts/eb-closeout-report.sh "$rolling")"; rc_roll=$?
assert_rc "rolling path with only an archived file exits 0" 0 "$rc_roll"
assert_eq "rolling path output equals the archived-path output" "$arc_bead: ACCEPTANCE-PENDING operator" "$out_roll"
arc_notes="$(bd show --json "$arc_bead" 2>/dev/null | jq -r '.[0].notes // ""')"
assert_contains "evidence names the archived path" "$arc_notes" "archived handoff: $arc"
assert_eq "evidence does not name the rolling path" "0" "$(printf '%s' "$arc_notes" | grep -cF "$rolling")"

# --- the given file exists and a differing archived sibling exists -> the given file is read, the sibling is not
bead_given="$(mk Given)"; bead_sib="$(mk Sibling)"
mkdir -p "$scratch/both/archive"
printf -- '---\nbeads: [%s]\n---\n' "$bead_given" >"$scratch/both/h.md"
printf -- '---\nbeads: [%s]\n---\n' "$bead_sib" >"$scratch/both/archive/h.md"
out_both="$(scripts/eb-closeout-report.sh "$scratch/both/h.md")"; rc_both=$?
assert_rc "existing file with an archived sibling exits 0" 0 "$rc_both"
assert_eq "output is that of the given file, not the sibling" "$bead_given: ACCEPTANCE-PENDING operator" "$out_both"

# --- neither the given path nor the archive has a file -> exit 1, message names the given path
out_none="$(scripts/eb-closeout-report.sh "$scratch/nowhere/h.md" 2>&1)"; rc_none=$?
assert_rc "no file anywhere exits 1" 1 "$rc_none"
assert_contains "the message names the given path" "$out_none" "no file at '$scratch/nowhere/h.md'."

eb_report
