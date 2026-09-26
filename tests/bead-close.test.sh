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

# --- superseded: non-permitted actor (non-operator, non-owner) refuses ----------------------
supnonop="$(mk "Superseded-non-operator")"
supref="$(mk "Superseded-non-operator-ref")"
before_bead="$(bd show --json "$supnonop" 2>/dev/null | jq -c '.[0] | {status, labels, notes}')"
out="$(scripts/bead-close.sh --id "$supnonop" --reason superseded --ref "$supref" --note "x" 2>&1)"; rc=$?
assert_rc "superseded without --operator refuses" 1 "$rc"
assert_contains "refusal names --operator" "$out" "--operator"
after_bead="$(bd show --json "$supnonop" 2>/dev/null | jq -c '.[0] | {status, labels, notes}')"
assert_eq "non-operator superseded refusal changes nothing" "$before_bead" "$after_bead"

# --- infeasible: non-permitted actor (non-operator, non-owner) refuses -----------------------
infeasnonop="$(mk "Infeasible-non-operator")"
printf 'ev\n' > "$scratch/infeasible-nonop-evidence.txt"
before_bead="$(bd show --json "$infeasnonop" 2>/dev/null | jq -c '.[0] | {status, labels, notes}')"
out="$(scripts/bead-close.sh --id "$infeasnonop" --reason infeasible --note "x" --evidence "$scratch/infeasible-nonop-evidence.txt" 2>&1)"; rc=$?
assert_rc "infeasible without --operator refuses" 1 "$rc"
assert_contains "refusal names --operator" "$out" "--operator"
after_bead="$(bd show --json "$infeasnonop" 2>/dev/null | jq -c '.[0] | {status, labels, notes}')"
assert_eq "non-operator infeasible refusal changes nothing" "$before_bead" "$after_bead"

# --- infeasible: missing --evidence refuses --------------------------------------------------
infeasnoev="$(mk "Infeasible-no-evidence")"
before_bead="$(bd show --json "$infeasnoev" 2>/dev/null | jq -c '.[0] | {status, labels, notes}')"
out="$(scripts/bead-close.sh --id "$infeasnoev" --reason infeasible --note "x" --operator 2>&1)"; rc=$?
assert_rc "infeasible without --evidence refuses" 1 "$rc"
assert_contains "refusal names --evidence" "$out" "--evidence"
after_bead="$(bd show --json "$infeasnoev" 2>/dev/null | jq -c '.[0] | {status, labels, notes}')"
assert_eq "missing-evidence refusal changes nothing" "$before_bead" "$after_bead"

# --- infeasible: nonexistent --evidence path refuses ------------------------------------------
infeasbadev="$(mk "Infeasible-bad-evidence-path")"
before_bead="$(bd show --json "$infeasbadev" 2>/dev/null | jq -c '.[0] | {status, labels, notes}')"
out="$(scripts/bead-close.sh --id "$infeasbadev" --reason infeasible --note "x" --evidence "$scratch/does-not-exist.txt" --operator 2>&1)"; rc=$?
assert_rc "infeasible with nonexistent --evidence refuses" 1 "$rc"
assert_contains "refusal names --evidence" "$out" "--evidence"
after_bead="$(bd show --json "$infeasbadev" 2>/dev/null | jq -c '.[0] | {status, labels, notes}')"
assert_eq "nonexistent-evidence refusal changes nothing" "$before_bead" "$after_bead"

# --- superseded/duplicate: nonexistent --ref refuses -----------------------------------------
noexistref="$(mk "Ref-target-missing")"
before_bead="$(bd show --json "$noexistref" 2>/dev/null | jq -c '.[0] | {status, labels, notes}')"
out="$(scripts/bead-close.sh --id "$noexistref" --reason superseded --ref "zz-does-not-exist" --note "x" --operator 2>&1)"; rc=$?
assert_rc "nonexistent --ref refuses" 1 "$rc"
assert_contains "refusal names the missing --ref" "$out" "does not exist"
after_bead="$(bd show --json "$noexistref" 2>/dev/null | jq -c '.[0] | {status, labels, notes}')"
assert_eq "nonexistent-ref refusal changes nothing" "$before_bead" "$after_bead"

# --- m1: --ref naming an already-closed Bead refuses -----------------------------------------
closedref="$(mk "Already-closed-ref-target")"
bd close "$closedref" --reason "cleanup" >/dev/null
supclosed="$(mk "Superseded-onto-closed-ref")"
before_bead="$(bd show --json "$supclosed" 2>/dev/null | jq -c '.[0] | {status, labels, notes}')"
out="$(scripts/bead-close.sh --id "$supclosed" --reason superseded --ref "$closedref" --note "x" --operator 2>&1)"; rc=$?
assert_rc "--ref naming a closed Bead refuses" 1 "$rc"
assert_contains "refusal names the closed --ref" "$out" "$closedref"
after_bead="$(bd show --json "$supclosed" 2>/dev/null | jq -c '.[0] | {status, labels, notes}')"
assert_eq "closed-ref refusal changes nothing" "$before_bead" "$after_bead"

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

# =============================================================================================
# m3: a flag given without a value prints a usage line naming the flag and exits 1
# =============================================================================================
out="$(scripts/bead-close.sh --id "$(mk "Trailing-flag-no-value")" --reason 2>&1)"; rc=$?
assert_rc "a trailing flag with no value exits 1" 1 "$rc"
assert_contains "usage line names the flag" "$out" "--reason"

# =============================================================================================
# m2: a failed restore (after a failed bd close) prints RESTORE-FAILED and exits 2
# =============================================================================================
# Stub `bd` to fail `close` on one named id AND fail the restoring `update --notes` call for
# that same id, so the EVIDENCE-append-then-restore path's restore step itself fails.
restorefailcase="$(mk "Restore-fails-too")"
printf 'evidence for the doubly-failing close\n' > "$scratch/restore-fail-evidence.txt"
stubdir2="$scratch/stubbin2"
mkdir -p "$stubdir2"
cat > "$stubdir2/bd" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "close" ]]; then
  for a in "\$@"; do
    if [[ "\$a" == "$restorefailcase" ]]; then
      echo "stub: injected close failure" >&2
      exit 1
    fi
  done
fi
if [[ "\$1" == "update" && "\$2" == "$restorefailcase" ]]; then
  for a in "\$@"; do
    if [[ "\$a" == "--notes" ]]; then
      echo "stub: injected restore failure" >&2
      exit 1
    fi
  done
fi
exec "$REAL_BD" "\$@"
STUB
chmod +x "$stubdir2/bd"

before_bead="$(bd show --json "$restorefailcase" 2>/dev/null | jq -c '.[0] | {status, labels, notes}')"
out="$(PATH="$stubdir2:$PATH" scripts/bead-close.sh --id "$restorefailcase" --reason infeasible \
  --note "cannot be done" --evidence "$scratch/restore-fail-evidence.txt" --operator 2>&1)"; rc=$?
assert_rc "a doubly-failed close/restore exits 2" 2 "$rc"
assert_contains "stderr prints RESTORE-FAILED with the id" "$out" "RESTORE-FAILED $restorefailcase"

eb_report
