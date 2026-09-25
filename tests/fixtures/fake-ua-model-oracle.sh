#!/usr/bin/env bash
# fake-ua-model-oracle.sh — stands in for ~/.claude/state/ua-model.sh in hermetic tests.
# Prints a fixed "ok" sidecar reading. Point EB_MODEL_ORACLE_FAMILY at a ladder name to control
# which model bead-claim.sh detects; defaults to "sonnet".
set -u
family="${EB_MODEL_ORACLE_FAMILY:-sonnet}"
cat <<JSON
{"state":"ok","model_id":"claude-${family}-x","model_display_name":"${family}","family":"${family}","effort":"medium","session_effort":"medium","thinking":true}
JSON
