#!/usr/bin/env bash
# eb-common.test.sh: eb_metadata_merge refuses (rc=1) instead of silently overwriting metadata
# with `{}` when `bd show --json` fails (MINOR-1, review pa-s2s.3-review-1). Uses a PATH shim
# `bd` so the real `bd`/live estate database is never touched.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source scripts/lib/eb-common.sh
source tests/_assert.sh

tmpbin="$(mktemp -d)"
trap 'rm -rf "$tmpbin"' EXIT
cat > "$tmpbin/bd" <<'EOF'
#!/usr/bin/env bash
# Shim: `bd show` always fails; anything else is unexpected in this test.
if [[ "${1:-}" == "show" ]]; then exit 1; fi
echo "eb-common.test.sh bd shim: unexpected call: $*" >&2
exit 1
EOF
chmod +x "$tmpbin/bd"

PATH="$tmpbin:$PATH" eb_metadata_merge "fake-id" '{"executor":{"model":"opus"}}'
rc=$?
assert_rc "eb_metadata_merge refuses (does not fall back to {}) when bd show fails" 1 "$rc"

# --- eb_reviewer_adequate: <exec-model> <exec-effort> <vendor> <model> <effort> -------------------
adq() {  # <desc> <expect-rc 0|1> args...
  local d="$1" want="$2"; shift 2
  eb_reviewer_adequate "$@" >/dev/null 2>&1; local rc=$?
  [[ "$want" == 1 && "$rc" != 0 ]] && rc=1
  assert_rc "$d" "$want" "$rc"
}
adq "sonnet/low + gpt-6.1-sol@low passes"           0 sonnet low codex gpt-6.1-sol low
adq "opus/medium + gpt-6.1-sol@high passes"         0 opus medium codex gpt-6.1-sol high
adq "opus/high + gpt-6.1-sol@high refused"          1 opus high codex gpt-6.1-sol high
adq "opus/no-effort + gpt-6.1-sol@high refused"     1 opus "" codex gpt-6.1-sol high
adq "opus/no-effort + gpt-6-astra@low passes"       0 opus "" codex gpt-6-astra low
adq "fable + gpt-6-astra@low refused"               1 fable "" codex gpt-6-astra low
adq "fable + gpt-6-astra@medium passes"             0 fable "" codex gpt-6-astra medium
adq "sonnet/low + gpt-6-astra@low passes (>= rule)" 0 sonnet low codex gpt-6-astra low
adq "unknown codex model refused"                   1 sonnet low codex gpt-9-nova high
adq "unlisted codex effort refused"                 1 sonnet low codex gpt-6.1-sol max
adq "missing reviewer effort refused"               1 sonnet low codex gpt-6.1-sol ""
adq "unknown vendor refused"                        1 sonnet low gemini gpt-6.1-sol low
# each executor row accepts exactly its codex point and refuses one point below it
adq "sonnet/low + gpt-6.1-sol@low passes (at row 1)"      0 sonnet low codex gpt-6.1-sol low
adq "sonnet/medium + gpt-6.1-sol@low passes (at row 1)"   0 sonnet medium codex gpt-6.1-sol low
adq "sonnet/high + gpt-6.1-sol@medium passes (at row 2)"  0 sonnet high codex gpt-6.1-sol medium
adq "sonnet/high + gpt-6.1-sol@low refused (row 2)"       1 sonnet high codex gpt-6.1-sol low
adq "opus/medium + gpt-6.1-sol@high passes (at row 3)"    0 opus medium codex gpt-6.1-sol high
adq "opus/medium + gpt-6.1-sol@medium refused (row 3)"    1 opus medium codex gpt-6.1-sol medium
adq "opus/high + gpt-6.1-sol@xhigh passes (at row 4)"     0 opus high codex gpt-6.1-sol xhigh
adq "opus/high + gpt-6.1-sol@high refused (row 4)"        1 opus high codex gpt-6.1-sol high
adq "opus/xhigh + gpt-6-astra@low passes (at row 5)"      0 opus xhigh codex gpt-6-astra low
adq "opus/xhigh + gpt-6.1-sol@xhigh refused (row 5)"      1 opus xhigh codex gpt-6.1-sol xhigh
adq "opus/max + gpt-6.1-sol@xhigh refused (row 5)"        1 opus max codex gpt-6.1-sol xhigh
adq "fable + gpt-6-astra@medium passes (at row 6)"        0 fable high codex gpt-6-astra medium
adq "fable + gpt-6-astra@low refused (row 6)"             1 fable high codex gpt-6-astra low
# missing executor effort takes the strictest row of the model
adq "sonnet/no-effort + gpt-6.1-sol@medium passes (row 2)" 0 sonnet "" codex gpt-6.1-sol medium
adq "sonnet/no-effort + gpt-6.1-sol@low refused (row 2)"   1 sonnet "" codex gpt-6.1-sol low
adq "opus/no-effort + gpt-6.1-sol@xhigh refused (row 5)"   1 opus "" codex gpt-6.1-sol xhigh
# models from the retired ladder are refused, not kept
adq "retired gpt-6-sol@high refused"                       1 sonnet low codex gpt-6-sol high
adq "retired gpt-5.6-sol@low refused"                      1 sonnet low codex gpt-5.6-sol low
adq "retired gpt-5.6-sol@high refused"                     1 sonnet low codex gpt-5.6-sol high
msg="$(eb_reviewer_adequate sonnet low codex gpt-6-sol high 2>&1 >/dev/null)"
assert_contains "retired gpt-6-sol@high refusal names the codex ladder" "$msg" "'gpt-6-sol@high' is not on the codex verifier ladder"
adq "missing vendor: sonnet exec + opus reviewer passes" 0 sonnet "" "" opus ""
adq "missing vendor: opus + opus refused"           1 opus "" "" opus ""
adq "missing vendor: fable + fable passes"          0 fable "" "" fable ""
adq "claude vendor: haiku reviewer refused"         1 sonnet low claude haiku ""
adq "missing vendor: haiku reviewer refused"        1 sonnet low "" haiku ""

msg="$(eb_reviewer_adequate fable "" codex gpt-6-astra low 2>&1 >/dev/null)"
assert_contains "fable refusal names a fable reviewer" "$msg" "a fable reviewer"
case "$msg" in *"claude reviewer one tier above"*) assert_eq "fable refusal omits 'one tier above'" ok bad ;; *) assert_eq "fable refusal omits 'one tier above'" ok ok ;; esac
msg="$(eb_reviewer_adequate opus high codex gpt-6.1-sol high 2>&1 >/dev/null)"
assert_contains "non-fable refusal keeps the one-tier-above hint" "$msg" "one tier above the executor"

# --- ladder-file robustness (EB_LADDER_FILE override) ---------------------------------------------
ltmp="$(mktemp -d)"; trap 'rm -rf "$tmpbin" "$ltmp"' EXIT
real_ladder="$ROOT/scripts/lib/verifier-ladder.json"
for v in claude codex; do
  if [[ $v == claude ]]; then a=(sonnet low claude opus ""); else a=(sonnet low codex gpt-6.1-sol low); fi
  msg="$(EB_LADDER_FILE="$ltmp/nope.json" eb_reviewer_adequate "${a[@]}" 2>&1 >/dev/null)"; rc=$?
  assert_rc "missing ladder ($v) refused" 1 "$([[ $rc != 0 ]] && echo 1 || echo 0)"
  assert_contains "missing ladder ($v) names the ladder file" "$msg" "$ltmp/nope.json"
  case "$msg" in *"jq:"*) assert_eq "missing ladder ($v) has no raw jq text" ok bad ;; *) assert_eq "missing ladder ($v) has no raw jq text" ok ok ;; esac
  printf '{ "claude_ranks": ' > "$ltmp/bad.json"
  msg="$(EB_LADDER_FILE="$ltmp/bad.json" eb_reviewer_adequate "${a[@]}" 2>&1 >/dev/null)"; rc=$?
  assert_rc "malformed ladder ($v) refused" 1 "$([[ $rc != 0 ]] && echo 1 || echo 0)"
  assert_contains "malformed ladder ($v) names the ladder file" "$msg" "$ltmp/bad.json"
  case "$msg" in *"jq:"*) assert_eq "malformed ladder ($v) has no raw jq text" ok bad ;; *) assert_eq "malformed ladder ($v) has no raw jq text" ok ok ;; esac
done
jq '.executor_rows.opus.missing = "x" | .codex_points["a@b"] = "y"' "$real_ladder" > "$ltmp/badtype.json"
( EB_LADDER_FILE="$ltmp/badtype.json" eb_reviewer_adequate opus "" codex a b ) >/dev/null 2>&1; rc=$?
assert_rc "non-numeric ladder value refused (codex)" 1 "$rc"
jq '.claude_ranks.sonnet = "x"' "$real_ladder" > "$ltmp/badtype2.json"
( EB_LADDER_FILE="$ltmp/badtype2.json" eb_reviewer_adequate sonnet low claude opus "" ) >/dev/null 2>&1; rc=$?
assert_rc "non-numeric ladder value refused (claude)" 1 "$rc"
jq 'del(.claude_ranks.opus)' "$real_ladder" > "$ltmp/norank.json"
msg="$(EB_LADDER_FILE="$ltmp/norank.json" eb_reviewer_adequate sonnet low claude opus "" 2>&1 >/dev/null)"
assert_contains "missing reviewer rank gives a reason" "$msg" "has no rank"

# --- eb_bd: reads BOTH streams, error first, warning kept, rc preserved, never exits ----------------
# A PATH shim `bd` whose behaviour is chosen by EB_FAKE (the real bd/live database is never touched).
fakebin="$(mktemp -d)"
trap 'rm -rf "$tmpbin" "$fakebin"' EXIT
cat > "$fakebin/bd" <<'EOF'
#!/usr/bin/env bash
warn() { printf 'warning: beads.role not configured (GH#2950).\n  Fix: git config beads.role maintainer\n' >&2; }
case "${EB_FAKE:-}" in
  stdout-json) warn; printf '{"error":"E1"}\n'; exit 1 ;;
  stderr-text) warn; printf 'Error: E2\nHint: try again\n' >&2; exit 1 ;;
  envelope)    warn; printf 'Error resolving x: E3\n' >&2
               printf '{"error":"1 of 2 issues failed to update","failed":[{"id":"x","error":"E3"}]}\n' >&2
               printf '[{"id":"ok-1"}]\n'; exit 3 ;;
  success)     warn; printf '[{"id":"ok-1"}]\n'; exit 0 ;;
  silent-fail) exit 1 ;;
esac
exit 99
EOF
chmod +x "$fakebin/bd"
SELF=t
errf="$(mktemp)"
run_bd() {  # <EB_FAKE mode> <verb> -> sets rc, out, err (eb_bd runs in THIS shell)
  EB_FAKE="$1" PATH="$fakebin:$PATH" eb_bd out "$2" --json x 2>"$errf"; rc=$?
  err="$(cat "$errf")"
}
first_line() { printf '%s' "${1%%$'\n'*}"; }

run_bd stdout-json show
assert_rc "eb_bd returns the CLI's exit code (stdout-JSON error)" 1 "$rc"
assert_eq "eb_bd names a stdout JSON .error first" "t: bd show failed: E1" "$(first_line "$err")"
assert_eq "eb_bd exports the message as EB_BD_ERROR" "E1" "${EB_BD_ERROR:-}"
assert_contains "eb_bd keeps the beads.role warning after the error" "$err" "beads.role not configured"
case "$err" in
  *"failed: E1"*"beads.role not configured"*) eb_ok "eb_bd prints the error line before the warning" ;;
  *) eb_bad "eb_bd prints the error line before the warning" "$err" ;;
esac

run_bd stderr-text list
assert_rc "eb_bd returns the CLI's exit code (stderr error)" 1 "$rc"
assert_eq "eb_bd names a stderr 'Error: ...' line, not the leading warning" "t: bd list failed: E2" "$(first_line "$err")"
assert_contains "eb_bd keeps the warning (stderr error)" "$err" "beads.role not configured"
case "$err" in
  *"failed: E2"*"beads.role not configured"*) eb_ok "eb_bd prints the error line before the warning (stderr error)" ;;
  *) eb_bad "eb_bd prints the error line before the warning (stderr error)" "$err" ;;
esac

run_bd envelope update
assert_rc "eb_bd preserves a non-1 exit code" 3 "$rc"
assert_contains "eb_bd reads the stderr JSON envelope" "$(first_line "$err")" "1 of 2 issues failed to update"
assert_contains "eb_bd names the failed id from .failed[]" "$(first_line "$err")" "x: E3"
assert_contains "eb_bd exports the failed-id message" "${EB_BD_ERROR:-}" "x: E3"

run_bd success show
assert_rc "eb_bd returns 0 on success" 0 "$rc"
assert_eq "eb_bd passes stdout to the out-var untouched" '[{"id":"ok-1"}]' "$out"
assert_contains "eb_bd forwards the warning on success" "$err" "beads.role not configured"
assert_eq "eb_bd clears EB_BD_ERROR on success" "" "${EB_BD_ERROR:-}"

run_bd silent-fail show
assert_rc "eb_bd returns the exit code when bd prints nothing" 1 "$rc"
assert_eq "eb_bd says so when bd printed no error text" "t: bd show failed: <bd printed no error text>" "$(first_line "$err")"
rm -f "$errf"

eb_report
