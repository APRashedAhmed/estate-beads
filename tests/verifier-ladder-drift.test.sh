#!/usr/bin/env bash
# verifier-ladder-drift.test.sh — guards scripts/lib/verifier-ladder.json against drift from its
# human copy, the 'Verifier ladders' table in orchestrator-mode's tiers.md. Machine-local input:
# when tiers.md is absent (another machine, an installed clone) the comparison SKIPS loudly.
# Override the path with EB_TIERS_MD.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/tests/_assert.sh"

tiers="${EB_TIERS_MD:-$HOME/.agents/skills/orchestrator-mode/references/tiers.md}"
ladder="$ROOT/scripts/lib/verifier-ladder.json"
if [[ ! -f "$tiers" ]]; then
  printf 'verifier-ladder-drift: SKIPPED — tiers.md not found at %s (set EB_TIERS_MD to compare)\n' "$tiers"
  eb_report; exit $?
fi

compare() {  # <ladder-json> -> "OK ..." or "ERR ..." on stdout
  python3 - "$tiers" "$1" <<'PY'
import json, re, sys
tiers, ladder = sys.argv[1], sys.argv[2]
L = json.load(open(ladder))
efforts = ["low", "medium", "high", "xhigh", "max"]
rows, verifiers, errs = {}, [], []
text = open(tiers).read()
m = re.search(r"^## Verifier ladders\n(.*?)(?=^## )", text, re.S | re.M)
if not m:
    print("ERR tiers.md has no '## Verifier ladders' section"); sys.exit(0)
for line in m.group(1).splitlines():
    cells = [c.strip() for c in line.strip().strip("|").split("|")]
    if len(cells) < 2 or not line.lstrip().startswith("|") or cells[0].startswith("Worker") or set(cells[0]) <= set("-: "):
        continue
    label, cv = cells[0], cells[1]
    lm = re.match(r"^(Sonnet|Opus|Fable)\b(.*)$", label)
    if not lm:
        errs.append(f"unparsed worker label {label!r}"); continue
    model, rest = lm.group(1).lower(), lm.group(2)
    if model == "fable":
        effs = efforts
    elif "and above" in rest:
        lo = re.search(r"\((\w+) and above\)", rest).group(1); effs = efforts[efforts.index(lo):]
    else:
        pm = re.search(r"\(([^)]*)\)", rest)
        if not pm: errs.append(f"no effort list in {label!r}"); continue
        effs = [e.strip() for e in pm.group(1).split(",")]
    if any(e not in efforts for e in effs):
        errs.append(f"unknown effort in {label!r}"); continue
    verifiers.append(cv)
    for e in effs:
        rows.setdefault(model, {})[e] = cv
pts = L.get("codex_points", {})
for cv in verifiers:
    if cv not in pts: errs.append(f"tiers.md codex verifier {cv} is not in codex_points")
extra = sorted(set(pts) - set(verifiers))
if extra: errs.append(f"codex_points names models tiers.md does not: {extra}")
xr = L.get("executor_rows", {})
if set(rows) != set(xr): errs.append(f"executor models differ: tiers.md {sorted(rows)} vs json {sorted(xr)}")
for model, by in rows.items():
    if set(by) != set(efforts): errs.append(f"tiers.md {model} rows do not cover every effort: {sorted(by)}")
    for e, cv in by.items():
        want, got = pts.get(cv), xr.get(model, {}).get(e)
        if want != got: errs.append(f"{model}/{e}: tiers.md says {cv} (point {want}), json row is {got}")
    strict = max((pts.get(cv, 0) for cv in by.values()), default=None)
    if xr.get(model, {}).get("missing") != strict:
        errs.append(f"{model}/missing: json {xr.get(model, {}).get('missing')}, strictest tiers.md row is {strict}")
print("ERR " + "; ".join(errs) if errs else f"OK {len(verifiers)} verifier rows")
PY
}
out="$(compare "$ladder")"
assert_contains "verifier-ladder.json matches the tiers.md 'Verifier ladders' table" "$out" "OK "
printf '  (%s)\n' "$out"

# the guard itself detects drift: a moved row, a renamed point, and a stale missing row all fail
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
jq '.executor_rows.opus.xhigh = 4' "$ladder" > "$tmp/row.json"
assert_contains "guard catches a moved executor row" "$(compare "$tmp/row.json")" "opus/xhigh"
jq '.codex_points |= with_entries(if .key == "gpt-6.1-sol@low" then .key = "gpt-6-sol@high" else . end)' "$ladder" > "$tmp/name.json"
assert_contains "guard catches a renamed codex point" "$(compare "$tmp/name.json")" "gpt-6-sol@high"
jq '.executor_rows.sonnet.missing = 1' "$ladder" > "$tmp/miss.json"
assert_contains "guard catches a missing row that is not the strictest" "$(compare "$tmp/miss.json")" "sonnet/missing"
eb_report
