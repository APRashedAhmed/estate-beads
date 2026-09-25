#!/usr/bin/env bash
# Emit a scoped window of a Claude Code transcript: the current turn plus the
# previous N. User text, assistant text, and tool_use name + a short argument
# summary only. tool_result content is dropped entirely and never printed.
#
# A turn starts at each `user` record whose .message.content is a plain string;
# tool results arrive as `user` records with array content and do not start turns.
set -euo pipefail

SELF="transcript-window"
die() { printf '%s: %s\n' "$SELF" "$1" >&2; exit "${2:-1}"; }

session=""; turns=3; path=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --session) session="${2-}"; shift 2 ;;
    --turns)   turns="${2-}"; shift 2 ;;
    --path)    path="${2-}"; shift 2 ;;
    *) die "unknown flag '$1'. Flags: --session <parent-session-id> [--turns N] [--path <transcript.jsonl>]" ;;
  esac
done

[[ "$turns" =~ ^[0-9]+$ ]] || die "--turns must be a non-negative integer (got '$turns')."
(( turns > 10 )) && turns=10   # hard cap
command -v jq >/dev/null || die "jq not on PATH. Install jq, then re-run."

if [[ -z "$path" ]]; then
  [[ -n "$session" ]] || die "give --session <parent-session-id> or --path <transcript.jsonl>."
  slug="${PWD//\//-}"
  path="$HOME/.claude/projects/${slug}/${session}.jsonl"
fi
[[ -f "$path" ]] || die "no transcript at '$path'. Check the session id and the working directory the parent ran in, then re-run."

# Pass 1 — turn-start line numbers. Streams; the file is never held in memory.
mapfile -t starts < <(jq -r 'select((.type? // "") == "user" and ((.message?.content? | type) == "string")) | input_line_number' "$path")
(( ${#starts[@]} > 0 )) || die "no turns found in '$path'. Confirm it is a Claude Code transcript."

want=$(( turns + 1 ))
idx=$(( ${#starts[@]} - want ))
(( idx < 0 )) && idx=0
first="${starts[$idx]}"

# Pass 2 — format from that line onward. Also streams.
tail -n "+${first}" "$path" | jq -r '
  def summary: (. // {} | tostring) | if (length > 120) then (.[0:120] + "…") else . end;
  if ((.type? // "") == "user" and ((.message?.content? | type) == "string")) then
    "--- turn ---\nUSER: " + .message.content
  elif ((.type? // "") == "assistant" and ((.message?.content? | type) == "array")) then
    ( [ .message.content[]
        | if (.type? == "text") then "ASSISTANT: " + (.text // "")
          elif (.type? == "tool_use") then "TOOL: " + (.name // "?") + " " + (.input | summary)
          else empty end ]
      | join("\n") )
  else empty end
  | select(. != "")'
