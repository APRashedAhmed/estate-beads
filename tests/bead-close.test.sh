#!/usr/bin/env bash
# bead-close.sh (design §14; contract §5.4 "Who may close"): the closer for the reasons other
# than `accepted`. One passing case per reason (with the right flags/actor), one refusal per
# gate, and the atomic restore on a failed `bd close`.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source tests/_scratch_db.sh
source tests/_assert.sh

eb_scratch_db scratch close || exit 1
trap 'rm -rf "$scratch"' EXIT
export BEADS_ACTOR=actor1

mk() {  # <title> -> prints a fresh open Bead id
  scripts/create-bead.sh --title "$1" --description d --acceptance a --project p \
    --accept evidence --recognized-by x
}

# =============================================================================================
# Passing case per reason
# =============================================================================================

# --- superseded: --ref verified, --operator (owner-or-operator gate) ------------------------
old="$(mk "Superseded-old")"
newbead="$(mk "Superseded-new")"
out="$(scripts/bead-close.sh --id "$old" --reason superseded --ref "$newbead" --note "replaced by the new plan" --operator)"; rc=$?
assert_eq "superseded closes with --ref and --operator" "CLOSED superseded" "$out"
assert_rc "superseded exits 0" 0 "$rc"
bead="$(bd show --json "$old" 2>/dev/null | jq -c '.[0]')"
assert_eq "status is closed (superseded)" "closed" "$(printf '%s' "$bead" | jq -r '.status')"
assert_eq "close_reason names the ref and note" "superseded: $newbead — replaced by the new plan" "$(printf '%s' "$bead" | jq -r '.close_reason')"

# --- duplicate: --ref verified, ANY actor (no --operator needed) ----------------------------
dup="$(mk "Duplicate-of-another")"
orig="$(mk "Original")"
out="$(scripts/bead-close.sh --id "$dup" --reason duplicate --ref "$orig" --note "same work as $orig")"; rc=$?
assert_eq "duplicate closes with --ref, no --operator required" "CLOSED duplicate" "$out"
assert_rc "duplicate exits 0" 0 "$rc"
bead="$(bd show --json "$dup" 2>/dev/null | jq -c '.[0]')"
assert_eq "status is closed (duplicate)" "closed" "$(printf '%s' "$bead" | jq -r '.status')"
assert_eq "close_reason names the ref and note" "duplicate: $orig — same work as $orig" "$(printf '%s' "$bead" | jq -r '.close_reason')"

# --- abandoned: --operator (recognition-source-owner check is not mechanically verifiable) ---
aband="$(mk "Abandoned-one")"
out="$(scripts/bead-close.sh --id "$aband" --reason abandoned --note "no longer wanted" --operator)"; rc=$?
assert_eq "abandoned closes with --operator" "CLOSED abandoned" "$out"
assert_rc "abandoned exits 0" 0 "$rc"
bead="$(bd show --json "$aband" 2>/dev/null | jq -c '.[0]')"
assert_eq "status is closed (abandoned)" "closed" "$(printf '%s' "$bead" | jq -r '.status')"

# --- infeasible: --operator, --evidence <existing file> recorded on EVIDENCE line -----------
infeas="$(mk "Infeasible-one")"
printf 'the API this depends on was removed upstream\n' > "$scratch/infeasible-evidence.txt"
out="$(scripts/bead-close.sh --id "$infeas" --reason infeasible --note "cannot be done as recognized" --evidence "$scratch/infeasible-evidence.txt" --operator)"; rc=$?
assert_eq "infeasible closes with --operator and --evidence" "CLOSED infeasible" "$out"
assert_rc "infeasible exits 0" 0 "$rc"
bead="$(bd show --json "$infeas" 2>/dev/null | jq -c '.[0]')"
assert_eq "status is closed (infeasible)" "closed" "$(printf '%s' "$bead" | jq -r '.status')"
assert_contains "EVIDENCE line records the evidence path" "$(printf '%s' "$bead" | jq -r '.notes')" "EVIDENCE: $scratch/infeasible-evidence.txt"

# --- declined: --operator (the only mechanical proxy for the Strategy-review actor) ---------
decl="$(mk "Declined-one")"
out="$(scripts/bead-close.sh --id "$decl" --reason declined --note "not selected at review" --operator)"; rc=$?
assert_eq "declined closes with --operator" "CLOSED declined" "$out"
assert_rc "declined exits 0" 0 "$rc"
bead="$(bd show --json "$decl" 2>/dev/null | jq -c '.[0]')"
assert_eq "status is closed (declined)" "closed" "$(printf '%s' "$bead" | jq -r '.status')"

# =============================================================================================
# One refusal per gate
# =============================================================================================

# --- refuses `--reason accepted`, naming bead-accept.sh -------------------------------------
acc="$(mk "Accepted-refused")"
out="$(scripts/bead-close.sh --id "$acc" --reason accepted --note "n/a" 2>&1)"; rc=$?
assert_rc "accepted is refused" 1 "$rc"
assert_contains "refusal names bead-accept.sh" "$out" "bead-accept.sh"
bead="$(bd show --json "$acc" 2>/dev/null | jq -r '.[0].status')"
assert_eq "accepted refusal changes nothing" "open" "$bead"

# --- superseded/duplicate: missing --ref refuses --------------------------------------------
noref="$(mk "Superseded-no-ref")"
out="$(scripts/bead-close.sh --id "$noref" --reason superseded --note "no ref given" --operator 2>&1)"; rc=$?
assert_rc "superseded without --ref refuses" 1 "$rc"
assert_contains "refusal names --ref" "$out" "--ref"
bead="$(bd show --json "$noref" 2>/dev/null | jq -r '.[0].status')"
assert_eq "missing-ref refusal changes nothing" "open" "$bead"

# --- abandoned: the executor (actor == assignee) is refused, pointed at bead-release.sh -----
exec_bead="$(mk "Executor-abandoned")"
scripts/bead-claim.sh --id "$exec_bead" --model sonnet >/dev/null
out="$(scripts/bead-close.sh --id "$exec_bead" --reason abandoned --note "giving up" 2>&1)"; rc=$?
assert_rc "executor closing abandoned is refused" 1 "$rc"
assert_contains "refusal points at bead-release.sh --note" "$out" "bead-release.sh"
bead="$(bd show --json "$exec_bead" 2>/dev/null | jq -r '.[0].status')"
assert_eq "executor refusal changes nothing" "in_progress" "$bead"

# --- declined: non-operator refuses ----------------------------------------------------------
declnonop="$(mk "Declined-non-operator")"
out="$(scripts/bead-close.sh --id "$declnonop" --reason declined --note "not selected" 2>&1)"; rc=$?
assert_rc "declined without --operator refuses" 1 "$rc"
assert_contains "refusal names --operator" "$out" "--operator"
bead="$(bd show --json "$declnonop" 2>/dev/null | jq -r '.[0].status')"
assert_eq "non-operator declined refusal changes nothing" "open" "$bead"

# --- lapsed is retired: refused outright, naming declined -----------------------------------
lapsedbead="$(mk "Lapsed-retired")"
out="$(scripts/bead-close.sh --id "$lapsedbead" --reason lapsed --note "old-style close" --operator 2>&1)"; rc=$?
assert_rc "lapsed refuses (retired)" 1 "$rc"
assert_contains "refusal points at declined" "$out" "declined"

# --- open blocker refuses -> BLOCKED-BY, atomically (nothing changed) ------------------------
blocker="$(mk "Blocker")"
blocked="$(mk "Blocked")"
bd dep "$blocker" --blocks "$blocked" >/dev/null
before_bead="$(bd show --json "$blocked" 2>/dev/null | jq -c '.[0]')"
out="$(scripts/bead-close.sh --id "$blocked" --reason abandoned --note "x" --operator)"; rc=$?
assert_eq "open blocker prints BLOCKED-BY" "BLOCKED-BY $blocker" "$out"
assert_rc "open blocker exits 1" 1 "$rc"
after_bead="$(bd show --json "$blocked" 2>/dev/null | jq -c '.[0]')"
assert_eq "status/labels/notes unchanged when blocked" \
  "$(printf '%s' "$before_bead" | jq -c '{status, labels, notes}')" \
  "$(printf '%s' "$after_bead" | jq -c '{status, labels, notes}')"
bd close "$blocker" --reason "unblock" >/dev/null
out="$(scripts/bead-close.sh --id "$blocked" --reason abandoned --note "x" --operator)"; rc=$?
assert_eq "closes once the blocker is closed" "CLOSED abandoned" "$out"

# --- open A4 children refuse (contract §1.2 rule 3): no cascade, refuse instead --------------
parent="$(mk "Parent-with-open-child")"
child="$(bd create "child of parent" --type task -p 2 --parent "$parent" --no-inherit-labels --json | jq -r .id)"
before_bead="$(bd show --json "$parent" 2>/dev/null | jq -c '.[0]')"
out="$(scripts/bead-close.sh --id "$parent" --reason abandoned --note "x" --operator 2>&1)"; rc=$?
assert_rc "open child refuses" 1 "$rc"
assert_contains "refusal names the open child" "$out" "$child"
after_bead="$(bd show --json "$parent" 2>/dev/null | jq -c '.[0]')"
assert_eq "open-child refusal changes nothing" \
  "$(printf '%s' "$before_bead" | jq -c '{status, labels, notes}')" \
  "$(printf '%s' "$after_bead" | jq -c '{status, labels, notes}')"
bd close "$child" --reason "cleanup" >/dev/null
out="$(scripts/bead-close.sh --id "$parent" --reason abandoned --note "x" --operator)"; rc=$?
assert_eq "closes once the child is closed" "CLOSED abandoned" "$out"

# =============================================================================================
# Atomic restore on a failed `bd close`
# =============================================================================================
# Stub `bd` ahead of PATH: proxies every subcommand to the real binary except `close` on one
# named id, which it fails — exercises the EVIDENCE-append-then-restore path (infeasible is the
# only reason that appends EVIDENCE before the `bd close` call).
REAL_BD="$(command -v bd)"
failcase="$(mk "Fail-close-restore")"
printf 'evidence for the failing close\n' > "$scratch/fail-evidence.txt"
stubdir="$scratch/stubbin"
mkdir -p "$stubdir"
cat > "$stubdir/bd" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "close" ]]; then
  for a in "\$@"; do
    if [[ "\$a" == "$failcase" ]]; then
      echo "stub: injected close failure" >&2
      exit 1
    fi
  done
fi
exec "$REAL_BD" "\$@"
STUB
chmod +x "$stubdir/bd"

before_bead="$(bd show --json "$failcase" 2>/dev/null | jq -c '.[0] | {status, labels, notes}')"
out="$(PATH="$stubdir:$PATH" scripts/bead-close.sh --id "$failcase" --reason infeasible \
  --note "cannot be done" --evidence "$scratch/fail-evidence.txt" --operator 2>&1)"; rc=$?
assert_rc "a failed bd close exits 1" 1 "$rc"
after_bead="$(bd show --json "$failcase" 2>/dev/null | jq -c '.[0] | {status, labels, notes}')"
assert_eq "a failed bd close restores notes atomically (no dangling EVIDENCE line)" \
  "$before_bead" "$after_bead"

eb_report
