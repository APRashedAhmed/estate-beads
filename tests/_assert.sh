#!/usr/bin/env bash
# _assert.sh — tiny assertion helpers shared by the *.test.sh suites. Source it; call eb_report
# at the end of the file to print a summary and exit non-zero on any failure.
# Leading underscore + no test_/`.test.sh` suffix: never itself discovered by scripts/test.sh.
set -uo pipefail

EB_PASS=0
EB_FAIL=0

eb_ok() {  # <description>
  EB_PASS=$((EB_PASS+1))
  printf '  ok - %s\n' "$1"
}

eb_bad() {  # <description> <detail...>
  EB_FAIL=$((EB_FAIL+1))
  printf '  NOT OK - %s\n' "$1" >&2
  shift
  [[ $# -gt 0 ]] && printf '    %s\n' "$@" >&2
}

assert_eq() {  # <description> <expected> <actual>
  if [[ "$2" == "$3" ]]; then eb_ok "$1"; else eb_bad "$1" "expected: $2" "actual:   $3"; fi
}

assert_ne() {  # <description> <not-expected> <actual>
  if [[ "$2" != "$3" ]]; then eb_ok "$1"; else eb_bad "$1" "actual should not equal: $2"; fi
}

assert_contains() {  # <description> <haystack> <needle>
  if [[ "$2" == *"$3"* ]]; then eb_ok "$1"; else eb_bad "$1" "needle:   $3" "haystack: $2"; fi
}

assert_rc() {  # <description> <expected-rc> <actual-rc>
  assert_eq "$1" "$2" "$3"
}

eb_report() {  # call once at the end of a *.test.sh file
  printf '%s: %d ok, %d not ok\n' "${0##*/}" "$EB_PASS" "$EB_FAIL"
  [[ "$EB_FAIL" -eq 0 ]]
}
