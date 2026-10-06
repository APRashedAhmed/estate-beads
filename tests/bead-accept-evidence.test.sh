#!/usr/bin/env bash
# bead-accept.sh --id --evidence <path> [--operator] (design §11.4): requires acceptance-pending,
# sets close_reason, closes. N2 (fix round 2, review pa-s2s.8-review-2): the form GATES on the
# Bead's accept: mode — evidence closes as before; operator requires the explicit --operator flag
# (refuses without it); independent is refused outright, naming --review <report>.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source tests/_scratch_db.sh
source tests/_assert.sh

eb_scratch_db scratch accept-evidence || exit 1
trap 'rm -rf "$scratch"' EXIT
export BEADS_ACTOR=actor1

make_pending() {  # <title> <mode> -> prints the Bead id, already acceptance-pending
  local title="$1" mode="$2" id
  id="$(scripts/create-bead.sh --title "$title" --description d --acceptance a --project p --accept "$mode" --recognized-by x)"
  scripts/bead-claim.sh --id "$id" --model sonnet >/dev/null
  bd update "$id" --append-notes "EVIDENCE: initial report" >/dev/null
  bd update "$id" --add-label "acceptance-pending" >/dev/null
  printf '%s' "$id"
}

# --- accept:evidence closes with no flag, as before -----------------------------------------------
id="$(make_pending "Evi-evidence" evidence)"
out="$(scripts/bead-accept.sh --id "$id" --evidence "$scratch/evidence-evidence.txt")"; rc=$?
assert_eq "bead-accept --evidence closes an acceptance-pending Bead (evidence)" "CLOSED" "$out"
assert_rc "exits 0 (evidence)" 0 "$rc"
bead="$(bd show --json "$id" 2>/dev/null | jq -c '.[0]')"
assert_eq "status is closed (evidence)" "closed" "$(printf '%s' "$bead" | jq -r '.status')"
assert_contains "close_reason starts with 'accepted ' (evidence)" "$(printf '%s' "$bead" | jq -r '.close_reason')" "accepted $scratch/evidence-evidence.txt"
labels="$(printf '%s' "$bead" | jq -c '.labels')"
assert_ne "acceptance-pending was removed on close (evidence)" '["accept:evidence","acceptance-pending","class:bounded-increment","project:p"]' "$labels"
notes="$(printf '%s' "$bead" | jq -r '.notes')"
assert_eq "CLOSED leaves IN-PROGRESS: none (evidence), no stale value" \
  "IN-PROGRESS: none" "$(printf '%s\n' "$notes" | grep '^IN-PROGRESS: ')"
assert_eq "CLOSED leaves NEXT: none — closed (evidence), no stale value" \
  "NEXT: none — closed" "$(printf '%s\n' "$notes" | grep '^NEXT: ')"

# --- accept:operator refuses WITHOUT --operator, closes WITH it (N2) -----------------------------
id="$(make_pending "Evi-operator" operator)"
before="$(bd show --json "$id" 2>/dev/null | jq -c '.[0]')"
out="$(scripts/bead-accept.sh --id "$id" --evidence "$scratch/evidence-operator.txt" 2>&1)"; rc=$?
assert_rc "accept:operator refuses without --operator" 1 "$rc"
assert_contains "the refusal names --operator" "$out" "--operator"
after="$(bd show --json "$id" 2>/dev/null | jq -c '.[0]')"
assert_eq "a refused close (no --operator) changes nothing" \
  "$(printf '%s' "$before" | jq -c '{status, labels, notes}')" \
  "$(printf '%s' "$after" | jq -c '{status, labels, notes}')"

out="$(scripts/bead-accept.sh --id "$id" --evidence "$scratch/evidence-operator.txt" --operator)"; rc=$?
assert_eq "accept:operator closes WITH --operator" "CLOSED" "$out"
assert_rc "exits 0 (operator, --operator given)" 0 "$rc"
bead="$(bd show --json "$id" 2>/dev/null | jq -c '.[0]')"
assert_eq "status is closed (operator)" "closed" "$(printf '%s' "$bead" | jq -r '.status')"
assert_eq "CLOSED leaves NEXT: none — closed (operator), no stale value" \
  "NEXT: none — closed" "$(printf '%s' "$bead" | jq -r '.notes' | grep '^NEXT: ')"

# --- accept:independent is refused outright, naming --review (N2) --------------------------------
id="$(make_pending "Evi-independent" independent)"
before="$(bd show --json "$id" 2>/dev/null | jq -c '.[0]')"
out="$(scripts/bead-accept.sh --id "$id" --evidence "$scratch/evidence-independent.txt" 2>&1)"; rc=$?
assert_rc "accept:independent is refused by the --id --evidence form" 1 "$rc"
assert_contains "the refusal names --review <report>" "$out" "--review"
after="$(bd show --json "$id" 2>/dev/null | jq -c '.[0]')"
assert_eq "a refused independent close changes nothing" \
  "$(printf '%s' "$before" | jq -c '{status, labels, notes}')" \
  "$(printf '%s' "$after" | jq -c '{status, labels, notes}')"
# --operator does not override the independent refusal either.
out="$(scripts/bead-accept.sh --id "$id" --evidence "$scratch/evidence-independent.txt" --operator 2>&1)"; rc=$?
assert_rc "accept:independent is refused even with --operator" 1 "$rc"

# --- refuses when not acceptance-pending ---------------------------------------------------------
notpending="$(scripts/create-bead.sh --title "NotPending" --description d --acceptance a --project p --accept evidence --recognized-by x)"
out="$(scripts/bead-accept.sh --id "$notpending" --evidence "$scratch/no.txt" 2>&1)"; rc=$?
assert_rc "refuses a Bead that is not acceptance-pending" 1 "$rc"

# --- atomic close: an open blocker refuses before any mutation -------------------------------
blocker="$(scripts/create-bead.sh --title "Blocker" --description d --acceptance a --project p --accept evidence --recognized-by x)"
blocked="$(scripts/create-bead.sh --title "Blocked" --description d --acceptance a --project p --accept evidence --recognized-by x)"
bd dep "$blocker" --blocks "$blocked" >/dev/null
scripts/bead-claim.sh --id "$blocked" --model sonnet >/dev/null
bd update "$blocked" --append-notes "EVIDENCE: initial report" >/dev/null
bd update "$blocked" --add-label "acceptance-pending" >/dev/null
before_bead="$(bd show --json "$blocked" 2>/dev/null | jq -c '.[0]')"
out="$(scripts/bead-accept.sh --id "$blocked" --evidence "$scratch/blocked.txt")"; rc=$?
assert_eq "open blocker prints BLOCKED-BY" "BLOCKED-BY $blocker" "$out"
assert_rc "open blocker exits 1" 1 "$rc"
after_bead="$(bd show --json "$blocked" 2>/dev/null | jq -c '.[0]')"
assert_eq "label/status/notes unchanged when blocked" \
  "$(printf '%s' "$before_bead" | jq -c '{status, labels, notes}')" \
  "$(printf '%s' "$after_bead" | jq -c '{status, labels, notes}')"

bd close "$blocker" --reason "unblock" >/dev/null
out="$(scripts/bead-accept.sh --id "$blocked" --evidence "$scratch/blocked.txt")"; rc=$?
assert_eq "closes once the blocker is closed" "CLOSED" "$out"
assert_rc "exits 0 once unblocked" 0 "$rc"

# --- M1 (review pa-s2s.8-review-1): close from a DIFFERENT actor than the claimant ----------------
export BEADS_ACTOR=claimant-actor
id="$(scripts/create-bead.sh --title "CrossActor" --description d --acceptance a --project p --accept evidence --recognized-by x)"
scripts/bead-claim.sh --id "$id" --model sonnet >/dev/null
bd update "$id" --append-notes "EVIDENCE: initial report" >/dev/null
bd update "$id" --add-label "acceptance-pending" >/dev/null
export BEADS_ACTOR=closer-actor
out="$(scripts/bead-accept.sh --id "$id" --evidence "$scratch/cross-actor.txt")"; rc=$?
export BEADS_ACTOR=actor1
assert_eq "closes as a different actor than the claimant" "CLOSED" "$out"
assert_rc "exits 0 as a different actor" 0 "$rc"
bead="$(bd show --json "$id" 2>/dev/null | jq -c '.[0]')"
assert_eq "status is closed (cross-actor)" "closed" "$(printf '%s' "$bead" | jq -r '.status')"
assert_eq "assignee stays the original claimant (audit trail: who did the work)" \
  "claimant-actor" "$(printf '%s' "$bead" | jq -r '.assignee')"
assert_contains "notes record who closed it" "$(printf '%s' "$bead" | jq -r '.notes')" "closed by closer-actor"

# --- the intended whole-block NEXT rewrite on close never leaks bd's --notes-replaced warning ----
warn="$(make_pending "WarningSuppressed" evidence)"
errf="$scratch/accept-evidence-warning.err"
scripts/bead-accept.sh --id "$warn" --evidence "$scratch/warning.txt" >/dev/null 2>"$errf"
assert_eq "bead-accept --evidence close prints no bd --notes-replaced warning" \
  "0" "$(grep -c -- '--notes replaced' "$errf" || true)"

# --- "Confirm the id" only for a missing id; a broken database reports its own error -------------
empty_db="$(mktemp -d)"
cd "$scratch" || exit 1   # a non-git dir: bd also prints its beads.role warning here
miss="$("$ROOT/scripts/bead-accept.sh" --id zz-999 --evidence "$scratch/x.txt" 2>&1)"; rc=$?
broken="$(BEADS_DIR="$empty_db" "$ROOT/scripts/bead-accept.sh" --id accept-evidence-abc --evidence "$scratch/x.txt" 2>&1)"; rc2=$?
cd "$ROOT" || exit 1
rmdir "$empty_db"
assert_rc "a missing id exits 1" 1 "$rc"
assert_contains "a missing id keeps the Confirm-the-id remedy" "$miss" "Confirm the id"
assert_eq "a missing id: the error is the first line" "bead-accept: bd show failed: no issues found matching the provided IDs" "${miss%%$'\n'*}"
case "$miss" in
  *"bd show failed"*"beads.role not configured"*) eb_ok "a missing id: the warning follows the error" ;;
  *) eb_bad "a missing id: the warning follows the error" "$miss" ;;
esac
assert_rc "a broken database exits 1" 1 "$rc2"
assert_contains "a broken database reports bd's own error" "$broken" "no beads database found"
case "$broken" in
  *"Confirm the id"*) eb_bad "a broken database does not say Confirm the id" "$broken" ;;
  *) eb_ok "a broken database does not say Confirm the id" ;;
esac

# --- step 5 (pa-q1w0): close fails AND the notes restore fails -> RESTORE-FAILED naming the id --------
# A PATH wrapper over the real (scratch) bd: `close` always fails; once it has, `--notes` restores fail too.
idr="$(make_pending "Evi-restore-fail" evidence)"
rwrap="$scratch/rwrap"; mkdir -p "$rwrap"
printf '#!/usr/bin/env bash\nif [[ "$1" == close ]]; then : >"%s/closed"; printf "Error: close boom\\n" >&2; exit 1; fi\nif [[ -e "%s/closed" && "$*" == *" --notes "* ]]; then printf "Error: restore boom\\n" >&2; exit 1; fi\nexec "%s" "$@"\n' \
  "$rwrap" "$rwrap" "$(command -v bd)" >|"$rwrap/bd"
chmod +x "$rwrap/bd"
out="$(PATH="$rwrap:$PATH" scripts/bead-accept.sh --id "$idr" --evidence "$scratch/e.txt" 2>&1)"; rc=$?
assert_contains "a failed notes restore prints RESTORE-FAILED" "$out" "RESTORE-FAILED"
assert_contains "RESTORE-FAILED names the Bead id" "$out" "RESTORE-FAILED $idr:"
assert_rc "the exit code stays 1 on a failed close" 1 "$rc"

eb_report
