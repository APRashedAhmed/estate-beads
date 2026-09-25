#!/usr/bin/env python3
"""eb-guard.py — PreToolUse(Bash) governed seam: deny the `bd` verbs the estate's scripts must
own (design §12.1, plan U3). Pure python3 stdlib.

Contract (design §12.1 / portability-contract.md §7, governed seam, fails closed):
  - A command that never invokes `bd` (no `bd`-basename token anywhere, even after a parse
    failure) is ALWAYS allowed — this guard never blocks unrelated shell calls.
  - A command recognized as invoking `bd` whose tokenizer cannot produce a verdict (malformed
    shell) is DENIED.
  - Every other recognized `bd` invocation is judged verb-by-verb per the decision table below.

Tokenization: split on `&&`, `||`, `;`, `|`, `&`, `|&`, and (quote-aware) bare newlines, recursing into
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
    "reopen": "Raw bd reopen is denied. Use scripts/bead-reopen.sh.",
    "update-status-closed": "Raw `bd update --status closed` is denied. Use scripts/bead-report-success.sh, scripts/bead-accept.sh, or scripts/bead-reopen.sh.",
    "update-status-open-on-closed": "Raw `bd update --status open` on a closed Bead is denied. Use scripts/bead-report-success.sh, scripts/bead-accept.sh, or scripts/bead-reopen.sh.",
    "update-append-notes": "Raw `bd update --append-notes` is denied. Use scripts/bead-progress.sh (the rule-5 note carrier).",
    "parse-failure": "This command could not be parsed and appears to invoke `bd` — denied to fail closed (a governed seam denies on a recognized failure state).",
}

# --- F1: verb-alias -> canonical-verb table -------------------------------------------------
# `bd` 1.3.0 ships alias/adjacent subcommands that reach the same guarded operation as a denied
# canonical verb. Every row here is a VERB TOKEN the guard must judge exactly like its canonical
# counterpart (per-Bead `bd close --help` / `bd create --help` / `bd update --help` output,
# checked live on this bd 1.3.0). Kept as an explicit table (not folded into the verb match
# below) so a future alias addition is a one-line diff here, not a scattered edit.
VERB_ALIASES = {
    "done": "close",  # `bd close --help`: "Aliases: close, done"
    "new": "create",  # `bd create --help`: "Aliases: create, new"
    "q": "create",  # `bd q` = quick create, a top-level verb functionally aliasing `create`
    "note": "update-append-notes",  # `bd note` = shorthand for `bd update <id> --append-notes`
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
# `&` (background) and `|&` (pipe stdout+stderr) are command SEPARATORS just like `;`/`|` — a
# segment after either still gets its own independent verdict.
_OPERATORS = ("&&", "||", ";", "|", "&", "|&")


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

# --- F2: shell reserved words the guard must see through ------------------------------------
# These precede a command in normal shell grammar (`if bd close x; then ...`, `! bd close x`) but
# never take their own option/value tokens — a single-token skip.
_RESERVED_WORDS = {"if", "then", "else", "elif", "do", "while", "until", "!", "{"}

# --- F2: wrapper commands with their OWN options/values, skipped before landing on `bd` ------
# name -> (set of flags that consume a following value token, number of trailing positionals to
# skip AFTER the flags before the wrapped command starts — e.g. `timeout 5 bd ...`'s duration).
# `time` is here, not in _RESERVED_WORDS, because bash's `time` accepts its own `-p` option
# (`time -p bd close x`) that a single-token reserved-word skip would misread as the verb.
_WRAPPERS = {
    "time": (set(), 0),
    "nohup": (set(), 0),
    "exec": (set(), 0),
    "command": (set(), 0),
    "nice": ({"-n"}, 0),
    "sudo": ({"-u", "--user", "-g", "--group", "-p", "--prompt", "-C", "--close-from", "-r", "--role", "-t", "--type", "-h", "--host"}, 0),
    "timeout": ({"-s", "--signal", "-k", "--kill-after"}, 1),  # 1 positional: the duration
    "xargs": ({"-I", "-n", "-P", "-L", "-d", "--delimiter", "-s", "-a", "-E"}, 0),
    # F2 (guard gap): known coreutil/scheduling wrappers, kept in this same table so they're
    # skipped exactly like the wrappers above (nice, sudo, timeout, xargs, ...).
    "stdbuf": ({"-i", "--input", "-o", "--output", "-e", "--error"}, 0),
    "ionice": ({"-c", "--class", "-n", "--classdata", "-p", "--pid"}, 0),
    "chrt": ({"-p", "--pid"}, 1),  # 1 positional: the priority value
    "taskset": (set(), 1),  # 1 positional: the cpu list/mask (`-c LIST` or a bare mask)
    "unbuffer": (set(), 0),
}

# --- F3: shells/evaluators whose string ARGUMENT is executed, not merely quoted text ---------
# A `bd` token inside this string is an invocation (design §12.1 bypass table), never allowed as
# "quoted text mentioning bd" — that allow row is for a non-executing command (e.g. `echo "..."`).
_SHELL_C_NAMES = {"bash", "sh", "zsh", "dash", "ksh"}


def _skip_wrapper_prefix(segment, i):
    """From index i, skip one leading reserved word OR one wrapper invocation (name + its own
    flags/values + its skip-count positionals). Returns the new index, or i unchanged if nothing
    at position i is a reserved word or known wrapper."""
    n = len(segment)
    tok = segment[i]
    if tok in _RESERVED_WORDS:
        return i + 1
    if tok in _WRAPPERS:
        value_flags, positionals = _WRAPPERS[tok]
        j = i + 1
        while j < n and segment[j].startswith("-") and segment[j] not in ("--",):
            if segment[j] in value_flags and j + 1 < n:
                j += 2
            else:
                j += 1
        skipped = 0
        while j < n and skipped < positionals and not segment[j].startswith("-"):
            j += 1
            skipped += 1
        return j
    return i


def _advance_past_prefixes(segment):
    """Skip a leading `env` invocation's OWN flags (`-u NAME`, `-C DIR`, ...), `VAR=val` words,
    shell reserved words (`if`/`then`/.../`time`), and known wrappers with their own
    options/values (`timeout N`, `nohup`, `sudo [opts]`, `exec`, `command`, `nice [-n N]`,
    `xargs [opts]`, ...) — repeatedly, since these can stack (`sudo timeout 5 bd ...`). Returns
    the index of the first token that is none of the above (the real command name), or len(segment)
    if the whole segment is consumed."""
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
        if _ASSIGN_RE.match(tok):
            i += 1
            continue
        new_i = _skip_wrapper_prefix(segment, i)
        if new_i != i:
            i = new_i
            continue
        break
    return i


def _find_bd_invocation(segment):
    """Return (bd_index, verb_or_None) if this segment invokes `bd`, else None — so `env -u
    BEADS_DIR bd ...` / `command bd ...` / `if bd ...` / `timeout 5 bd ...` / `sudo bd ...` are
    all recognized as bd-invocations with `bd` as the resolved token, never one of the
    prefix tokens (see `_advance_past_prefixes`)."""
    i = _advance_past_prefixes(segment)
    n = len(segment)
    if i >= n:
        return None
    if os.path.basename(segment[i]) != "bd":
        return None
    verb = segment[i + 1] if i + 1 < n else None
    return (i, verb)


# --- F3: does this segment execute a shell-string argument (bash -c '...', eval '...') --------
_SHELL_C_FLAG_RE = re.compile(r"^-[a-zA-Z]*c[a-zA-Z]*$")  # -c, -lc, -ec, -xc, ... (any -c combo)


def _find_shell_exec_string(segment):
    """Return the string argument that a shell-executing wrapper would run as a command, or None.
    Covers `bash -c "..."` / `sh -c '...'` / `zsh -c ...` / `dash -c ...` / `ksh -c ...` (any
    option combination containing `c`, e.g. `-lc`) and `eval "..."` (its args, space-joined, per
    real eval semantics) — after skipping the same prefixes `_find_bd_invocation` skips, so
    `sudo bash -c "bd close x"` / `env FOO=1 eval "bd close x"` are still recognized."""
    i = _advance_past_prefixes(segment)
    n = len(segment)
    if i >= n:
        return None
    name = os.path.basename(segment[i])
    if name in _SHELL_C_NAMES:
        j = i + 1
        while j < n and segment[j].startswith("-"):
            if _SHELL_C_FLAG_RE.match(segment[j]):
                # The first non-flag token after the -c-bearing flag is the script string.
                if j + 1 < n:
                    return segment[j + 1]
                return None
            j += 1
        return None
    if name == "eval":
        rest = segment[i + 1 :]
        if not rest:
            return None
        return " ".join(rest)
    return None


def _skip_global_flags(args):
    """F5: `bd --json close pa-x` / `bd -q close pa-x` — global flags may precede the verb.
    Returns the index of the first non-flag token (the verb), or len(args) if none. Skips the
    value token of any global flag known to take one."""
    value_flags = {
        "--actor", "--database", "--db", "-C", "--directory", "--dolt-auto-commit", "--mem-profile",
    }
    i = 0
    n = len(args)
    while i < n and args[i].startswith("-"):
        tok = args[i]
        name = tok.split("=", 1)[0]
        if name in value_flags:
            if "=" in tok:
                i += 1
            elif i + 1 < n:
                i += 2
            else:
                i += 1
        else:
            i += 1
    return i


def _recursive_bd_deny(text, cwd, depth):
    """F3: does executing `text` as a nested shell command invoke a `bd` verb the guard would
    deny? Recurses through the same tokenizer/judge path (same `cwd`, so `bd show`/scratch-init
    checks inside the nested string still see the real hook payload's cwd). Returns a
    deny-reason-key, or None. Depth-capped against pathological nesting; a ParseFailure that
    still textually mentions `bd` fails closed, matching the top-level contract."""
    if depth > 8:
        return "parse-failure" if BD_TOKEN_RE.search(text) else None
    try:
        segments = tokenize_segments(text)
    except ParseFailure:
        return "parse-failure" if BD_TOKEN_RE.search(text) else None
    for seg in segments:
        verdict = judge_segment(seg, cwd, depth=depth + 1)
        if verdict is not None:
            return verdict
    return None


# --- flag parsing over a bd command's args ---------------------------------------------------
def _flag_value(args, name, short=None):
    """args is the token list AFTER the verb. Returns the value of --name / --name=value (and, if
    `short` is given, -short / -short=value / attached -shortvalue — F1's `-s`/`-s=`/`-svalue`
    alias of `--status`), or None if the flag is absent."""
    long_flag = f"--{name}"
    short_flag = f"-{short}" if short else None
    for i, tok in enumerate(args):
        if tok == long_flag and i + 1 < len(args):
            return args[i + 1]
        if tok.startswith(long_flag + "="):
            return tok[len(long_flag) + 1 :]
        if short_flag:
            if tok == short_flag and i + 1 < len(args):
                return args[i + 1]
            if tok.startswith(short_flag + "="):
                return tok[len(short_flag) + 1 :]
            # Attached short-flag value: `-sclosed` == `-s closed` (not `-s`, not `-s=...`, but
            # still prefixed by the short flag with a non-empty remainder).
            if tok.startswith(short_flag) and tok != short_flag and len(tok) > len(short_flag):
                return tok[len(short_flag) :]
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
def judge_segment(segment, cwd, depth=0):
    """Return None (allow) or a deny-reason-key string (see DENY_MESSAGES)."""
    found = _find_bd_invocation(segment)
    if found is not None:
        bd_index, _raw_verb = found
        pre_tokens = segment[:bd_index]
        rest = segment[bd_index + 1 :]

        # F5: global flags (`--json`, `-q`, `--db PATH`, ...) may precede the verb.
        gi = _skip_global_flags(rest)
        verb = rest[gi] if gi < len(rest) else None
        args = rest[gi + 1 :]

        if verb is None:
            return None  # bare `bd` (optionally with only global flags): nothing to deny against

        # F1: canonicalize aliases (`done`->close, `new`/`q`->create, `note`->update-append-notes)
        # before judging, so an alias is denied with the SAME message as its canonical verb.
        canonical = VERB_ALIASES.get(verb, verb)

        if canonical == "init":
            if _is_scratch_env_prefix(pre_tokens) and _cwd_outside_git_repo(cwd):
                return None
            return "init"

        if canonical in ("delete", "remember", "edit", "sql"):
            return canonical

        if canonical == "reopen":  # F6
            return "reopen"

        if canonical == "create":
            return "create"

        if canonical == "close":
            return "close"

        if canonical == "update-append-notes":  # `bd note <id> "text"` (F1 alias)
            return "update-append-notes"

        if canonical == "update":
            if _flag_present(args, "append-notes"):
                return "update-append-notes"
            status = _flag_value(args, "status", short="s")  # F1: `-s`/`-s=` alias of `--status`
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

    # No direct `bd` token in command position: is this segment a shell/eval executing a STRING
    # argument that itself invokes `bd` (F3)? `bash -c "bd close x"` / `eval "bd close x"` — a
    # `bd` token inside such a string is an invocation, never merely "quoted text mentioning bd"
    # (that allow row is for a non-executing command like `echo "run bd close later"`, which this
    # check never reaches since `echo` isn't in `_SHELL_C_NAMES` or `eval`).
    exec_str = _find_shell_exec_string(segment)
    if exec_str is not None:
        return _recursive_bd_deny(exec_str, cwd, depth)
    return None


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
