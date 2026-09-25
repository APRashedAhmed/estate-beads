#!/usr/bin/env bash
# Single test entrypoint — runs ALL suites (bash/pytest/node), exits non-zero on any failure.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
fail=0
ran=0

# Discover suites but SKIP any under a git-ignored path (e.g. a nested git worktree left in
# .claude/worktrees/): those are stale duplicate checkouts, not this tree's suites, so running them
# double-counts passes or fails on outdated assertions. check-ignore generalizes to ANY ignored path
# while still running new, untracked-but-not-ignored suites (git ls-files would skip those).
in_git_repo=0
git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 && in_git_repo=1

# --- claude plugin validate (warnings OK; only a non-zero exit is a failure) ------------
echo "## validate: claude plugin validate ."
if command -v claude >/dev/null 2>&1; then
  ran=1
  claude plugin validate . || fail=1
else
  echo "(claude CLI not found — skipping plugin validate)"
fi

while IFS= read -r t; do
  [ -n "$t" ] || continue
  if [ "$in_git_repo" -eq 1 ] && git -C "$ROOT" check-ignore -q "$t" 2>/dev/null; then continue; fi
  ran=1; echo "## bash: $t"; bash "$t" || fail=1
done < <(find . -name '*.test.sh' -not -path './.git/*' -not -name 'test.sh' | sort)

if find . -name 'test_*.py' -not -path './.git/*' | grep -q .; then
  ran=1; echo "## pytest"; python3 -m pytest -q || fail=1
fi

# node suites: apply the SAME git-ignore filtering and pass EXPLICIT files — a bare `node --test`
# relies on Node's default recursive discovery, which does not consult .gitignore (so it would run a
# stale worktree's *.test.mjs) and fails under Node v24; the filtered file list is required.
nodetests=()
while IFS= read -r t; do
  [ -n "$t" ] || continue
  if [ "$in_git_repo" -eq 1 ] && git -C "$ROOT" check-ignore -q "$t" 2>/dev/null; then continue; fi
  nodetests+=("$t")
done < <(find . -name '*.test.mjs' -not -path './.git/*' | sort)
if [ "${#nodetests[@]}" -gt 0 ]; then
  ran=1; echo "## node"; node --test "${nodetests[@]}" || fail=1
fi

# Generated-view drift gate (portability-contract.md §2) — every tier ships this script.
if [ -x "$ROOT/scripts/check-views.sh" ]; then
  ran=1; echo "## check-views"; "$ROOT/scripts/check-views.sh" || fail=1
fi

[ "$ran" -eq 0 ] && echo "(no test suites found yet)"
[ "$fail" -eq 0 ] && { echo "ALL TESTS PASSED"; exit 0; } || { echo "TESTS FAILED"; exit 1; }
