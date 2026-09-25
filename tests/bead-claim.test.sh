#!/usr/bin/env bash
# bead-claim.sh: CLAIMED/LOST (README evaluation 3), executor.model detected/--model/refused
# (design §13 Verification, decision 1).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source tests/_scratch_db.sh
source tests/_assert.sh

eb_scratch_db scratch bead-claim || exit 1
trap 'rm -rf "$scratch"' EXIT
export BEADS_ACTOR=actor1

# --- README evaluation 3: CLAIMED on open, LOST on already-claimed ------------------------------
id="$(scripts/create-bead.sh --title "Claimable" --description d --acceptance a --project p --accept evidence --recognized-by x)"
out="$(scripts/bead-claim.sh --id "$id" --model sonnet)"; rc=$?
assert_eq "bead-claim prints CLAIMED on an open Bead" "CLAIMED" "$out"
assert_rc "bead-claim exits 0 on CLAIMED" 0 "$rc"

export BEADS_ACTOR=actor2
out="$(scripts/bead-claim.sh --id "$id" --model sonnet)"; rc=$?
assert_eq "bead-claim prints LOST on an already-claimed Bead" "LOST" "$out"
assert_rc "bead-claim exits 0 on LOST too" 0 "$rc"
export BEADS_ACTOR=actor1

# --- --model override records executor.model verbatim -------------------------------------------
id2="$(scripts/create-bead.sh --title "ModelOverride" --description d --acceptance a --project p --accept evidence --recognized-by x)"
scripts/bead-claim.sh --id "$id2" --model opus >/dev/null
got="$(bd show --json "$id2" 2>/dev/null | jq -r '.[0].metadata.executor.model')"
assert_eq "--model override is recorded as metadata executor.model" "opus" "$got"

# --- detection via the oracle (overridable for hermetic tests) -----------------------------------
id3="$(scripts/create-bead.sh --title "ModelDetected" --description d --acceptance a --project p --accept evidence --recognized-by x)"
EB_MODEL_ORACLE="$ROOT/tests/fixtures/fake-ua-model-oracle.sh" EB_MODEL_ORACLE_FAMILY=fable \
  scripts/bead-claim.sh --id "$id3" >/dev/null
got3="$(bd show --json "$id3" 2>/dev/null | jq -r '.[0].metadata.executor.model')"
assert_eq "a detected 'ok' oracle state records its family as executor.model" "fable" "$got3"

# --- undetectable + no --model refuses the claim (no metadata write, no claim) --------------------
id4="$(scripts/create-bead.sh --title "ModelUndetected" --description d --acceptance a --project p --accept evidence --recognized-by x)"
out="$(EB_MODEL_ORACLE=/nonexistent/no-such-oracle.sh scripts/bead-claim.sh --id "$id4" 2>&1)"; rc=$?
assert_rc "an undetectable model with no --model refuses the claim" 1 "$rc"
assert_contains "the refusal names the --model remedy" "$out" "--model"
status4="$(bd show --json "$id4" 2>/dev/null | jq -r '.[0].status')"
assert_eq "the refused Bead was never claimed" "open" "$status4"

# --- --model overrides a DETECTED (not just absent) model (MINOR-2, review pa-s2s.3-review-1) ---
id5="$(scripts/create-bead.sh --title "ModelDetectedButOverridden" --description d --acceptance a --project p --accept evidence --recognized-by x)"
EB_MODEL_ORACLE="$ROOT/tests/fixtures/fake-ua-model-oracle.sh" EB_MODEL_ORACLE_FAMILY=sonnet \
  scripts/bead-claim.sh --id "$id5" --model haiku >/dev/null
got5="$(bd show --json "$id5" 2>/dev/null | jq -r '.[0].metadata.executor.model')"
assert_eq "--model (haiku) overrides a detected 'ok' oracle family (sonnet)" "haiku" "$got5"

# --- an oracle in a non-ok state (stale/absent) is treated as undetectable, never guessed --------
cat > "$scratch/stale-oracle.sh" <<'EOF'
#!/usr/bin/env bash
echo '{"state":"stale","model_id":null,"family":null}'
EOF
chmod +x "$scratch/stale-oracle.sh"
out="$(EB_MODEL_ORACLE="$scratch/stale-oracle.sh" scripts/bead-claim.sh --id "$id4" 2>&1)"; rc=$?
assert_rc "a non-'ok' oracle state is treated as undetectable, not a guess" 1 "$rc"

eb_report
