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
  scripts/bead-claim.sh --id "$id5" --model opus >/dev/null
got5="$(bd show --json "$id5" 2>/dev/null | jq -r '.[0].metadata.executor.model')"
assert_eq "--model (opus) overrides a detected 'ok' oracle family (sonnet)" "opus" "$got5"

# --- haiku is off the ladder for new claims ---
id6="$(scripts/create-bead.sh --title "HaikuRefused" --description d --acceptance a --project p --accept evidence --recognized-by x)"
out6="$(scripts/bead-claim.sh --id "$id6" --model haiku 2>&1)"; rc=$?
assert_rc "--model haiku is refused for a new claim" 1 "$rc"
status6="$(bd show --json "$id6" 2>/dev/null | jq -r '.[0].status')"
assert_eq "the haiku-refused Bead was never claimed" "open" "$status6"

# --- a detected haiku session gets a distinct refusal (not "could not be detected") -----------------
id7="$(scripts/create-bead.sh --title "HaikuSession" --description d --acceptance a --project p --accept evidence --recognized-by x)"
out7="$(EB_MODEL_ORACLE="$ROOT/tests/fixtures/fake-ua-model-oracle.sh" EB_MODEL_ORACLE_FAMILY=haiku scripts/bead-claim.sh --id "$id7" 2>&1)"; rc=$?
assert_rc "a detected haiku session refuses the claim" 1 "$rc"
assert_contains "the refusal says haiku is no longer allowed" "$out7" "haiku is no longer an allowed executor model"
case "$out7" in *"could not be detected"*) assert_eq "haiku refusal is not the undetectable message" "distinct" "same" ;; *) assert_eq "haiku refusal is not the undetectable message" "distinct" "distinct" ;; esac
assert_eq "the haiku-session Bead was never claimed" "open" "$(bd show --json "$id7" 2>/dev/null | jq -r '.[0].status')"

# --- an oracle in a non-ok state (stale/absent) is treated as undetectable, never guessed --------
cat > "$scratch/stale-oracle.sh" <<'EOF'
#!/usr/bin/env bash
echo '{"state":"stale","model_id":null,"family":null}'
EOF
chmod +x "$scratch/stale-oracle.sh"
out="$(EB_MODEL_ORACLE="$scratch/stale-oracle.sh" scripts/bead-claim.sh --id "$id4" 2>&1)"; rc=$?
assert_rc "a non-'ok' oracle state is treated as undetectable, not a guess" 1 "$rc"

# --- executor.effort recording ---------------------------------------------------------------------
mkbead() { scripts/create-bead.sh --title "$1" --description d --acceptance a --project p --accept evidence --recognized-by x; }
effort_of() { bd show --json "$1" 2>/dev/null | jq -r '.[0].metadata.executor.effort // "none"'; }

ide1="$(mkbead EffortFlag)"
scripts/bead-claim.sh --id "$ide1" --model opus --effort high >/dev/null
assert_eq "--effort is recorded as executor.effort" "high" "$(effort_of "$ide1")"
assert_eq "--effort leaves executor.model intact" "opus" "$(bd show --json "$ide1" 2>/dev/null | jq -r '.[0].metadata.executor.model')"

ide2="$(mkbead EffortOracle)"
EB_MODEL_ORACLE="$ROOT/tests/fixtures/fake-ua-model-oracle.sh" EB_MODEL_ORACLE_FAMILY=opus \
  scripts/bead-claim.sh --id "$ide2" >/dev/null
assert_eq "the oracle's effort is recorded when the model comes from the oracle" "medium" "$(effort_of "$ide2")"

ide3="$(mkbead EffortModelOnly)"
EB_MODEL_ORACLE="$ROOT/tests/fixtures/fake-ua-model-oracle.sh" EB_MODEL_ORACLE_FAMILY=opus \
  scripts/bead-claim.sh --id "$ide3" --model sonnet >/dev/null
assert_eq "--model without --effort records no effort" "none" "$(effort_of "$ide3")"

ide4="$(mkbead EffortInvalid)"
out="$(scripts/bead-claim.sh --id "$ide4" --model opus --effort turbo 2>&1)"; rc=$?
assert_rc "an invalid --effort is refused" 1 "$rc"
assert_contains "the refusal lists the allowed efforts" "$out" "low|medium|high|xhigh|max"
assert_eq "the invalid-effort Bead was never claimed" "open" "$(bd show --json "$ide4" 2>/dev/null | jq -r '.[0].status')"

# --- stale effort on re-claim: a claim recording no effort drops the earlier one --------------------
ide5="$(mkbead EffortStale)"
scripts/bead-claim.sh --id "$ide5" --model opus --effort high >/dev/null
bd update "$ide5" --metadata "$(bd show --json "$ide5" 2>/dev/null | jq -c '.[0].metadata.executor + {"foo":"bar"} | {"executor":.}')" >/dev/null
assert_eq "first claim records effort high" "high" "$(effort_of "$ide5")"
scripts/bead-release.sh --id "$ide5" --note "test release" >/dev/null
scripts/bead-claim.sh --id "$ide5" --model opus >/dev/null
assert_eq "re-claim with no effort removes the stale executor.effort" "none" "$(effort_of "$ide5")"
assert_eq "the re-claim keeps executor.model" "opus" "$(bd show --json "$ide5" 2>/dev/null | jq -r '.[0].metadata.executor.model')"
assert_eq "the re-claim keeps other executor keys" "bar" "$(bd show --json "$ide5" 2>/dev/null | jq -r '.[0].metadata.executor.foo // "none"')"
assert_eq "the re-claim keeps unrelated metadata" "x" "$(bd show --json "$ide5" 2>/dev/null | jq -r '.[0].metadata["recognized-by"]')"

eb_report
