#!/usr/bin/env python3
"""eb-guard.py — PreToolUse(Bash) governed seam: deny the `bd` verbs the estate's scripts must
own (design §12.1, plan U3). Pure python3 stdlib.

Contract (design §12.1 / portability-contract.md §7, governed seam, fails closed):
  - A command that never invokes `bd` (no `bd`-basename token anywhere, even after a parse
    failure) is ALWAYS allowed — this guard never blocks unrelated shell calls.
  - A command recognized as invoking `bd` whose tokenizer cannot produce a verdict (malformed
    shell) is DENIED.
  - Every other recognized `bd` invocation is judged verb-by-verb per the decision table below.

Tokenization: split on `&&`, `||`, `;`, `|`, and (quote-aware) bare newlines, recursing into
`$( )`, backtick, and `( )` bodies and heredoc bodies. A segment "invokes bd" when its first
token — after stripping leading `env` words, `VAR=val` words, and `command` — has basename `bd`.

Output: silent (no stdout), exit 0 on allow. On deny: the vcs-rails PreToolUse JSON deny shape
on stdout, exit 0 (a `permissionDecision` verdict, not a hook crash).

Any exception anywhere in this script is caught by the outermost guard: fall back to a raw
substring/word-boundary regex for `bd` over the ORIGINAL stdin text — deny if present, allow
if not. A bug in this script can never fail open on a live `bd` command.
"""
from __future__ import annotations

import json
import os
import re
import shlex
import subprocess
import sys

DENY_MESSAGES = {
    "init": (
        "bd init is denied except the scratch form `env -u BEADS_DIR bd init ...` run with a "
        "cwd outside any git repository. See references/working.md and README.md 'Known gaps' "
        "for the transition-window note."
    ),
    "delete": "bd delete is denied. There is no script wrapper; this operation is off-limits from a Bash call.",
    "remember": "bd remember is denied. There is no script wrapper; this operation is off-limits from a Bash call.",
    "edit": "bd edit is denied ($EDITOR blocks agents). There is no script wrapper; this operation is off-limits from a Bash call.",
    "sql": "bd sql is denied. There is no script wrapper; this operation is off-limits from a Bash call.",
    "create": "Raw bd create is denied. Use scripts/create-bead.sh (single Bead) or scripts/create-beads-batch.sh (many from one artifact).",
    "close": "Raw bd close is denied. Use scripts/bead-report-success.sh, scripts/bead-accept.sh, or scripts/bead-reopen.sh.",
    "update-status-closed": "Raw `bd update --status closed` is denied. Use scripts/bead-report-success.sh, scripts/bead-accept.sh, or scripts/bead-reopen.sh.",
    "update-status-open-on-closed": "Raw `bd update --status open` on a closed Bead is denied. Use scripts/bead-report-success.sh, scripts/bead-accept.sh, or scripts/bead-reopen.sh.",
    "update-append-notes": "Raw `bd update --append-notes` is denied. Use scripts/bead-progress.sh (the rule-5 note carrier).",
    "parse-failure": "This command could not be parsed and appears to invoke `bd` — denied to fail closed (a governed seam denies on a recognized failure state).",
}

BD_TOKEN_RE = re.compile(r"\bbd\b")


class ParseFailure(Exception):
    pass


# --- heredoc extraction -------------------------------------------------------------------
_HEREDOC_START_RE = re.compile(r"<<-?\s*(['\"]?)(\w+)\1")


def _extract_heredocs(command: str):
    """Return (command_with_heredocs_stripped, [heredoc_body_text, ...]).

    Best-effort: handles one or more `<<WORD` / `<<-WORD` / `<<'WORD'` / `<<"WORD"` heredocs in
    document order. Not a full shell grammar (nested heredocs inside quotes are not special-
    cased), but sufficient for the decision table's heredoc row and any straightforward variant.
    """
    bodies = []
    out_lines = []
    lines = command.split("\n")
    i = 0
    n = len(lines)
    while i < n:
        line = lines[i]
        m = _HEREDOC_START_RE.search(line)
        if not m:
            out_lines.append(line)
            i += 1
            continue
        marker = m.group(2)
        strip_tabs = "<<-" in line
        out_lines.append(line)
        i += 1
        body_lines = []
        terminator_found = False
        while i < n:
            candidate = lines[i]
            test = candidate.lstrip("\t") if strip_tabs else candidate
            if test == marker:
                terminator_found = True
                i += 1
                break
            body_lines.append(candidate)
            i += 1
        if body_lines:
            bodies.append("\n".join(body_lines))
        if not terminator_found:
            # Unterminated heredoc: not a recognizable shape. Treat as a parse failure by
            # signalling via a sentinel the caller checks for.
            raise ParseFailure("unterminated heredoc")
    return "\n".join(out_lines), bodies


# --- backtick extraction ------------------------------------------------------------------
_BACKTICK_RE = re.compile(r"`([^`]*)`")


def _extract_backticks(command: str):
    """Return (command_with_backticks_blanked, [backtick_body, ...])."""
    bodies = [m.group(1) for m in _BACKTICK_RE.finditer(command)]
    stripped = _BACKTICK_RE.sub(" ", command)
    return stripped, bodies


# --- quote-aware newline -> ';' normalization ----------------------------------------------
def _normalize_newlines(command: str) -> str:
    out = []
    in_single = False
    in_double = False
    escape = False
    for ch in command:
        if escape:
            out.append(ch)
            escape = False
            continue
        if ch == "\\" and not in_single:
            out.append(ch)
            escape = True
            continue
        if ch == "'" and not in_double:
            in_single = not in_single
            out.append(ch)
            continue
        if ch == '"' and not in_single:
            in_double = not in_double
            out.append(ch)
            continue
        if ch == "\n" and not in_single and not in_double:
            out.append(";")
            continue
        out.append(ch)
    return "".join(out)


# --- tokenize + segment split ---------------------------------------------------------------
_OPERATORS = ("&&", "||", ";", "|")


def _shlex_tokens(text: str):
    lex = shlex.shlex(text, posix=True, punctuation_chars=True)
    lex.whitespace_split = True
    try:
        return list(lex)
    except ValueError as e:
        raise ParseFailure(str(e)) from e


def _split_segments(tokens):
    """Recursively split a flat shlex token stream into segments (lists of word-tokens),
    descending into `$( )` / `( )` groupings. Each such grouping's contents become their own
    independent segment(s), spliced into the returned list (order doesn't matter for verdicts)."""
    segments = []
    current = []
    i = 0
    n = len(tokens)
    while i < n:
        tok = tokens[i]
        if tok in _OPERATORS:
            if current:
                segments.append(current)
                current = []
            i += 1
            continue
        if tok == "$" and i + 1 < n and tokens[i + 1] == "(":
            i += 2
            inner, i = _collect_paren_group(tokens, i)
            segments.extend(_split_segments(inner))
            continue
        if tok == "(":
            i += 1
            inner, i = _collect_paren_group(tokens, i)
            segments.extend(_split_segments(inner))
            continue
        if tok == ")":
            # Unmatched close paren at this nesting level.
            raise ParseFailure("unmatched ')'")
        current.append(tok)
        i += 1
    if current:
        segments.append(current)
    return segments


def _collect_paren_group(tokens, i):
    depth = 1
    inner = []
    n = len(tokens)
    while i < n:
        t = tokens[i]
        if t == "(":
            depth += 1
        elif t == ")":
            depth -= 1
            if depth == 0:
                return inner, i + 1
        inner.append(t)
        i += 1
    raise ParseFailure("unbalanced parens")


def tokenize_segments(command: str):
    """command string -> list of segments (each a list of word tokens). Raises ParseFailure on
    anything this tokenizer cannot handle."""
    stripped, heredoc_bodies = _extract_heredocs(command)
    stripped, backtick_bodies = _extract_backticks(stripped)
    normalized = _normalize_newlines(stripped)
    tokens = _shlex_tokens(normalized)
    segments = _split_segments(tokens)
    for body in heredoc_bodies:
        body_norm = _normalize_newlines(body)
        segments.extend(_split_segments(_shlex_tokens(body_norm)))
    for body in backtick_bodies:
        segments.extend(_split_segments(_shlex_tokens(_normalize_newlines(body))))
    return segments


# --- "does this segment invoke bd" ----------------------------------------------------------
_ASSIGN_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
# `env` flags that take a following value token (the value must be skipped too), vs. bare flags.
_ENV_VALUE_FLAGS = {"-u", "--unset", "-C", "--chdir", "-S", "--split-string"}


def _find_bd_invocation(segment):
    """Return (bd_index, verb_or_None) if this segment invokes `bd`, else None. Skips a leading
    `env` invocation's OWN flags (`-u NAME`, `-C DIR`, ...) and `VAR=val` words, and a leading
    `command` builtin, so `env -u BEADS_DIR bd ...` / `command bd ...` are recognized as
    bd-invocations with `bd` as the resolved token, not `-u`/`BEADS_DIR`."""
    i = 0
    n = len(segment)
    in_env = False
    while i < n:
        tok = segment[i]
        if tok == "env" and not in_env:
            in_env = True
            i += 1
            continue
        if in_env and tok.startswith("-"):
            if tok in _ENV_VALUE_FLAGS and i + 1 < n:
                i += 2
            else:
                i += 1
            continue
        if tok == "command":
            i += 1
            continue
        if _ASSIGN_RE.match(tok):
            i += 1
            continue
        break
    if i >= n:
        return None
    if os.path.basename(segment[i]) != "bd":
        return None
    verb = segment[i + 1] if i + 1 < n else None
    return (i, verb)


# --- flag parsing over a bd command's args ---------------------------------------------------
def _flag_value(args, name):
    """args is the token list AFTER the verb. Returns the value of --name / --name=value, or
    None if the flag is absent. Returns "" (present, no explicit value) is not applicable here —
    every flag we check always takes a value."""
    long_flag = f"--{name}"
    for i, tok in enumerate(args):
        if tok == long_flag and i + 1 < len(args):
            return args[i + 1]
        if tok.startswith(long_flag + "="):
            return tok[len(long_flag) + 1 :]
    return None


def _flag_present(args, name):
    long_flag = f"--{name}"
    for tok in args:
        if tok == long_flag or tok.startswith(long_flag + "="):
            return True
    return False


def _first_positional(args):
    for tok in args:
        if not tok.startswith("-"):
            return tok
    return None


# --- the scratch bd-init allow exception -----------------------------------------------------
def _is_scratch_env_prefix(pre_tokens):
    return pre_tokens == ["env", "-u", "BEADS_DIR"]


def _cwd_outside_git_repo(cwd):
    if not cwd or not os.path.isdir(cwd):
        return False  # unresolved/nonexistent cwd never earns the scratch exception
    try:
        r = subprocess.run(
            ["git", "-C", cwd, "rev-parse", "--git-dir"],
            capture_output=True,
            text=True,
            timeout=5,
        )
    except Exception:
        return False
    return r.returncode != 0


def _bd_show_status(bead_id, cwd):
    """Return the Bead's status string, or None if `bd show` failed (fail closed by the
    caller). Never raises."""
    if not bead_id:
        return None
    try:
        r = subprocess.run(
            ["bd", "show", "--json", bead_id],
            capture_output=True,
            text=True,
            timeout=10,
            cwd=cwd if cwd and os.path.isdir(cwd) else None,
        )
    except Exception:
        return None
    if r.returncode != 0:
        return None
    try:
        data = json.loads(r.stdout)
    except Exception:
        return None
    if isinstance(data, list):
        data = data[0] if data else None
    if not isinstance(data, dict):
        return None
    return data.get("status")


# --- per-segment verdict -----------------------------------------------------------------------
def judge_segment(segment, cwd):
    """Return None (allow) or a deny-reason-key string (see DENY_MESSAGES)."""
    found = _find_bd_invocation(segment)
    if found is None:
        return None
    bd_index, verb = found
    pre_tokens = segment[:bd_index]

    if verb is None:
        return None  # bare `bd`, no verb: nothing to deny against

    if verb == "init":
        if _is_scratch_env_prefix(pre_tokens) and _cwd_outside_git_repo(cwd):
            return None
        return "init"

    if verb in ("delete", "remember", "edit", "sql"):
        return verb

    if verb == "create":
        return "create"

    if verb == "close":
        return "close"

    if verb == "update":
        args = segment[bd_index + 2 :]
        if _flag_present(args, "append-notes"):
            return "update-append-notes"
        status = _flag_value(args, "status")
        if status is not None:
            status_l = status.strip().lower()
            if status_l == "closed":
                return "update-status-closed"
            if status_l == "open":
                bead_id = _first_positional(args)
                current = _bd_show_status(bead_id, cwd)
                if current is None:
                    return "update-status-open-on-closed"  # bd show failed -> fail closed
                if current == "closed":
                    return "update-status-open-on-closed"
                return None
        return None

    return None  # every other verb (list, show, ready, search, dep, prime, sync, unknown...): allow


def judge_command(command, cwd):
    """Return None (allow) or a deny-reason-key string. Raises ParseFailure if the tokenizer
    cannot produce segments at all."""
    segments = tokenize_segments(command)
    for segment in segments:
        verdict = judge_segment(segment, cwd)
        if verdict is not None:
            return verdict
    return None


def emit_deny(reason_key):
    reason = DENY_MESSAGES.get(reason_key, DENY_MESSAGES["parse-failure"])
    print(
        json.dumps(
            {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": reason,
                },
                "systemMessage": reason,
            }
        )
    )


def main():
    raw_stdin = sys.stdin.read()
    try:
        payload = json.loads(raw_stdin) if raw_stdin.strip() else {}
        tool_name = payload.get("tool_name")
        if tool_name is not None and tool_name != "Bash":
            return 0
        tool_input = payload.get("tool_input") or {}
        command = tool_input.get("command") or ""
        cwd = payload.get("cwd") or ""
        if not command:
            return 0
        try:
            verdict = judge_command(command, cwd)
        except ParseFailure:
            if BD_TOKEN_RE.search(command):
                emit_deny("parse-failure")
                return 0
            return 0
        if verdict is not None:
            emit_deny(verdict)
        return 0
    except Exception:
        # Anything else unanticipated: fail closed only if a `bd` token is textually present.
        if BD_TOKEN_RE.search(raw_stdin):
            emit_deny("parse-failure")
        return 0


if __name__ == "__main__":
    sys.exit(main())
