#!/usr/bin/env bash
# eb-closeout-report.sh — plain-command entry for scripts/eb-closeout-report.sh, so the checkpoint
# descriptor can run it from PATH (the plugin's bin/ is on PATH) with no path substitution.
# Runs the installed plugin's script (eb-root.sh plugin) so a stale PATH entry still runs the
# current version; falls back to this tree. Arguments, environment, output, exit code pass through.
d="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
r="$("$d/eb-root.sh" plugin 2>/dev/null)" || r=""
[ -n "$r" ] || r="$d/.."
exec "$r/scripts/eb-closeout-report.sh" "$@"
