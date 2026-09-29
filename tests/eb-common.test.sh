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
adq "sonnet/low + gpt-6-sol@high passes"            0 sonnet low codex gpt-6-sol high
adq "opus/medium + gpt-5.6-sol@high passes"         0 opus medium codex gpt-5.6-sol high
adq "opus/high + gpt-5.6-sol@high refused"          1 opus high codex gpt-5.6-sol high
adq "opus/no-effort + gpt-5.6-sol@high refused"     1 opus "" codex gpt-5.6-sol high
adq "opus/no-effort + gpt-6-astra@low passes"       0 opus "" codex gpt-6-astra low
adq "fable + gpt-6-astra@low refused"               1 fable "" codex gpt-6-astra low
adq "fable + gpt-6-astra@medium passes"             0 fable "" codex gpt-6-astra medium
adq "sonnet/low + gpt-6-astra@low passes (>= rule)" 0 sonnet low codex gpt-6-astra low
adq "unknown codex model refused"                   1 sonnet low codex gpt-9-nova high
adq "unlisted codex effort refused"                 1 sonnet low codex gpt-6-sol xhigh
adq "missing reviewer effort refused"               1 sonnet low codex gpt-6-sol ""
adq "unknown vendor refused"                        1 sonnet low gemini gpt-6-sol high
adq "missing vendor: sonnet exec + opus reviewer passes" 0 sonnet "" "" opus ""
adq "missing vendor: opus + opus refused"           1 opus "" "" opus ""
adq "missing vendor: fable + fable passes"          0 fable "" "" fable ""
adq "claude vendor: haiku reviewer refused"         1 sonnet low claude haiku ""
adq "missing vendor: haiku reviewer refused"        1 sonnet low "" haiku ""

msg="$(eb_reviewer_adequate fable "" codex gpt-6-astra low 2>&1 >/dev/null)"
assert_contains "fable refusal names a fable reviewer" "$msg" "a fable reviewer"
case "$msg" in *"claude reviewer one tier above"*) assert_eq "fable refusal omits 'one tier above'" ok bad ;; *) assert_eq "fable refusal omits 'one tier above'" ok ok ;; esac
msg="$(eb_reviewer_adequate opus high codex gpt-5.6-sol high 2>&1 >/dev/null)"
assert_contains "non-fable refusal keeps the one-tier-above hint" "$msg" "one tier above the executor"

# --- ladder-file robustness (EB_LADDER_FILE override) ---------------------------------------------
ltmp="$(mktemp -d)"; trap 'rm -rf "$tmpbin" "$ltmp"' EXIT
real_ladder="$ROOT/scripts/lib/verifier-ladder.json"
for v in claude codex; do
  if [[ $v == claude ]]; then a=(sonnet low claude opus ""); else a=(sonnet low codex gpt-6-sol high); fi
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

eb_report
