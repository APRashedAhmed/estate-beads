#!/usr/bin/env python3
"""eb-guard.py — PreToolUse(Bash) governed seam: deny the `bd` verbs the estate's scripts must
own (design §12.1, plan U3). Pure python3 stdlib.

Contract (design §12.1 / portability-contract.md §7, governed seam, fails closed):
  - A command that never invokes `bd` (no `bd`-basename token anywhere, even after a parse
    failure) is ALWAYS allowed — this guard never blocks unrelated shell calls.
  - A command recognized as invoking `bd` whose tokenizer cannot produce a verdict (malformed
    shell) is DENIED.
  - Every other recognized `bd` invocation is judged verb-by-verb per the decision table below.
  - A command-position `$VAR`/`${VAR}`/`$( )`/backtick indirection is recognized as invoking `bd`
    ONLY when a `VAR=<literal>` assignment elsewhere in the same command text resolves it to a
    token whose basename is `bd` (re-tokenized once, then judged through the SAME verb-dispatch
    path as any other `bd` invocation). An indirection that cannot be resolved this way (no
    matching literal assignment, or a `$( )`/backtick command substitution, which is never
    resolved) is allowed — this guard never blanket-denies on the mere textual presence of `bd`
    elsewhere in the command (fix round 2, N3 — reverts a fix round 1 deviation).
    Exception (pa-e38.1 round 2, B3; fail-closed rows win over N3): a command word whose
    basename comes from a command substitution, or from a variable this same command assigns
    from a substitution or another expansion, is DENIED when the command mentions `bd` anywhere
    (`$(command -v bd) close x`, `P=$(printf bd); $P close x`). An unbound variable (`$EDITOR`)
    keeps the N3 allow.

Tokenization: split on `&&`, `||`, `;`, `|`, `&`, `|&`, and (quote-aware) bare newlines, recursing into
`$( )`, backtick, and `( )` bodies and heredoc bodies. A segment "invokes bd" when its first
token — after stripping leading `env` words, `VAR=val` words, and `command` — has basename `bd`.
A heredoc body fed to a shell/evaluator (`bash`, `sh`, `zsh`, `dash`, `ksh`, `eval`, `source`, `.`)
is parsed as a command and denied on either a recognized `bd` invocation or a parse failure that
still mentions `bd`; a heredoc body fed to anything else (`cat`, `tee`, a file, ...) is treated as
data, and a body line `shlex` cannot parse degrades to a per-line first-token check instead of
failing the whole command closed (fix round 2, N4). A consumer is also shell-fed when the rest of
its `<<` line pipes or chains to a shell (`cat <<EOF | sh`); a body fed to an interpreter
(`python3`, `perl`, `node`, ...) denies when it mentions `bd` anywhere (pa-e38.1 round 2, B2).

Output: silent (no stdout), exit 0 on allow. On deny: the vcs-rails PreToolUse JSON deny shape
on stdout, exit 0 (a `permissionDecision` verdict, not a hook crash).

A genuine tokenizer `ParseFailure` on the extracted `command` text (B2/B8, pa-e38.1) falls back to
`_parse_failure_should_deny`: a `bd` mention that sits only in quoted text or in a terminated,
non-expanding heredoc body read by a known data consumer is allowed; everything else denies. The
fallback masks nothing unless `_ShellScan` models the whole command exactly, so ANSI-C quoting,
an unbalanced quote, an unterminated heredoc, or any word that can execute a string or a heredoc
(a shell, `eval`, `source`, an interpreter, ...) sends it back to deny-on-any-`bd` (round 2, B1/B2).

Any OTHER exception anywhere in this script (e.g. malformed JSON on stdin, before `command` is
even extracted) is caught by the outermost guard: fall back to a raw substring/word-boundary
regex for `bd` over the ORIGINAL stdin text — deny if present, allow if not. A bug in this script
can never fail open on a live `bd` command.
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
        "Raw bd init is denied, always — there is no cwd-based exception. Use scripts/"
        "bead-scratch.sh for a throwaway Beads database: "
        "`bash \"$(bash <plugin>/bin/eb-root.sh plugin)/scripts/bead-scratch.sh\" new` "
        "(or `run -- <cmd>`); see references/authoring.md and README.md."
    ),
    "delete": "bd delete is denied. There is no script wrapper; this operation is off-limits from a Bash call.",
    "remember": "bd remember is denied. There is no script wrapper; this operation is off-limits from a Bash call.",
    "edit": "bd edit is denied ($EDITOR blocks agents). There is no script wrapper; this operation is off-limits from a Bash call.",
    "sql": "bd sql is denied. There is no script wrapper; this operation is off-limits from a Bash call.",
    "create": "Raw bd create is denied. Use scripts/create-bead.sh (single Bead) or scripts/create-beads-batch.sh (many from one artifact).",
    "close": "Raw bd close is denied. Use scripts/bead-report-success.sh, scripts/bead-accept.sh (accepted), scripts/bead-close.sh (superseded/duplicate/abandoned/infeasible/declined), or scripts/bead-reopen.sh.",
    "reopen": "Raw bd reopen is denied. Use scripts/bead-reopen.sh.",
    "update-status-closed": "Raw `bd update --status closed` is denied. Use scripts/bead-report-success.sh, scripts/bead-accept.sh (accepted), scripts/bead-close.sh (superseded/duplicate/abandoned/infeasible/declined), or scripts/bead-reopen.sh.",
    "update-status-open-on-closed": "Raw `bd update --status open` on a closed Bead is denied. Use scripts/bead-report-success.sh, scripts/bead-accept.sh, or scripts/bead-reopen.sh.",
    "update-append-notes": "Raw `bd update --append-notes` is denied. Use scripts/bead-progress.sh (the rule-5 note carrier).",
    "parse-failure": "This command could not be parsed and appears to invoke `bd` — denied to fail closed (a governed seam denies on a recognized failure state).",
    # M2 (review pa-s2s.8-review-1): verbs that close/create/delete Beads by a route the F1 alias
    # table did not cover (`bd <verb> --help` checked live on bd 1.3.0).
    "supersede": "bd supersede is denied — it automatically closes the superseded issue (contract §5.4). Use scripts/bead-close.sh --reason superseded --ref <bead-id>.",
    "duplicate": "bd duplicate is denied — it automatically closes the duplicate issue (contract §5.4). Use scripts/bead-close.sh --reason duplicate --ref <bead-id>.",
    "batch": "bd batch is denied. Its stdin grammar reaches close/create/update(status=closed) in one call; there is no script wrapper. This operation is off-limits from a Bash call.",
    "import": "bd import is denied. It upserts issues, including status, bypassing every guarded seam; there is no script wrapper. This operation is off-limits from a Bash call.",
    "prune": "bd prune is denied. It permanently deletes closed Beads; there is no script wrapper. This operation is off-limits from a Bash call.",
    "purge": "bd purge is denied. It permanently deletes closed ephemeral Beads; there is no script wrapper. This operation is off-limits from a Bash call.",
    # Round 2 (review pa-e38.1-review-1 B2/B3).
    "unresolved-indirection": "This command runs a command word the guard cannot resolve (a command substitution, or a variable this command assigns from one) and the command mentions `bd` — denied to fail closed (design §12.1). Call bd by name, or split the assignment and the bd call into separate Bash calls.",
    "exec-heredoc": "This command feeds a heredoc that mentions `bd` to an interpreter whose code the guard cannot judge — denied to fail closed (design §12.1).",
    "forget": "bd forget is denied (the inverse of the denied `bd remember`). There is no script wrapper; this operation is off-limits from a Bash call.",
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
    # M2 (review pa-s2s.8-review-1, `bd <verb> --help` checked live on bd 1.3.0):
    "create-form": "create",  # `bd create-form` = interactive `bd create`
}

BD_TOKEN_RE = re.compile(r"\bbd\b")
# A synthetic segment `[_DENY_SENTINEL, reason_key]` lets the tokenizer carry a verdict it
# reached on its own (an interpreter-fed heredoc mentioning `bd`) to `judge_segment`.
_DENY_SENTINEL = "\x00eb-deny"


class ParseFailure(Exception):
    pass


# --- B8 (pa-e38.1): genuine-parse-failure fallback, narrowed but conservative ----------------
# `main()`'s ParseFailure handler used to deny on a bare `BD_TOKEN_RE.search(command)`: a `bd`
# mention ANYWHERE, including quoted prose or a heredoc body that is pure data. The fallback now
# allows a `bd` mention that sits only in quoted text or a DATA heredoc body, but it masks
# nothing unless `_ShellScan` modelled the whole command (round 2, review pa-e38.1-review-1
# B1/B2): any construct the scanner does not model exactly (`$'...'`, `$"..."`, a backtick or a
# non-simple `${...}` inside double quotes, arithmetic `((`, a `case` inside a quoted `$( )`, an
# unbalanced quote, ...) or any word that can execute a quoted string or a heredoc body (a
# shell, `eval`, `source`, `xargs`, an interpreter, ...) sends the fallback back to
# deny-on-any-`bd`. A heredoc body is data only when it is terminated and, for an unquoted
# marker, contains no `$( )`/backtick expansion; even then a `bd` in command position on one of
# its lines denies.


def _crude_dequote(text: str) -> str:
    """Drop line continuations, quote characters, and backslashes, so `b''d` / `b\\<nl>d` /
    `"b"d` read as `bd`. Used only to WIDEN the `bd`-mention test (fail closed)."""
    return re.sub(r"[\"'\\]", "", re.sub(r"\\\n", "", text))


def _mentions_bd(text: str) -> bool:
    return bool(BD_TOKEN_RE.search(text) or BD_TOKEN_RE.search(_crude_dequote(text)))


# Words that can run a quoted string, a piped-in stream, or a heredoc body as code. In the
# parse-failure fallback, the presence of any of these (outside quotes) makes every quoted span
# and heredoc body potentially executable, so nothing is masked.
_FALLBACK_EXECUTORS = {
    "bash", "sh", "zsh", "dash", "ksh", "fish", "csh", "tcsh", "eval", "source", "exec",
    "xargs", "env", "sudo", "su", "ssh", "watch", "parallel", "find", "flock", "script",
    "perl", "ruby", "node", "nodejs", "php", "lua", "tclsh", "osascript", "irb",
    "awk", "gawk", "mawk", "nawk", "sed",
}
_PYTHON_RE = re.compile(r"^python[0-9.]*$")
_DOT_SOURCE_RE = re.compile(r"(?:^|[;&|(){}\n])\s*\.\s")
_VIS_WORD_SPLIT_RE = re.compile(r"[\s;&|()<>{}`=!,'\"]+")
# Commands that only READ a heredoc as data. In the fallback, a heredoc body is data only when
# every command word on its `<<` line is one of these (plus shell keywords that close a
# construct); any other consumer (`./run`, `$SHELL`, a function) may execute it.
_DATA_CONSUMERS = {
    "cat", "tee", "git", "gh", "jq", "yq", "grep", "egrep", "fgrep", "rg", "wc", "sort",
    "uniq", "head", "tail", "cut", "tr", "column", "fold", "fmt", "nl", "base64", "md5sum",
    "sha1sum", "sha256sum", "diff", "cmp", "less", "more", "printf", "echo", "true", ":",
    "read", "mapfile", "readarray", "case", "esac", "done", "fi", "}",
}
_BODY_PIECE_SPLIT_RE = re.compile(r"\n|;|&&|\|\||\||&|\$\(|\(|\)|`|\{|\}")


class _ShellScan:
    """Quote-, comment-, and heredoc-aware scan of a command the tokenizer could not parse.

    Produces `visible` (the command text outside comments and heredoc bodies, with every quoted
    span rendered as its content when that content has no whitespace, so `b''d` reads `bd`, or
    as the placeholder `Q` when it does, so quoted prose is masked), `heredocs` (one dict per
    heredoc: body, terminated, quoted marker), `unmodeled` (met a construct this scanner does not
    model exactly), and `unterminated` (a quote or `$( )` still open at end of text). It never
    raises. Callers must treat `unmodeled`/`unterminated` as "masking is not trustworthy"."""

    def __init__(self, text: str):
        self.t = text
        self.n = len(text)
        self.i = 0
        self.unmodeled = False
        self.unterminated = False
        self.vis = []
        self.heredocs = []
        self.pending = []
        self._scan_cmd(nested=False)
        self.visible = "".join(self.vis)

    def _last_vis_char(self):
        for chunk in reversed(self.vis):
            if chunk:
                return chunk[-1]
        return ""

    def _at_word_start(self):
        last = self._last_vis_char()
        return last == "" or last in " \t\n;&|()<>"

    def _emit_quoted(self, content):
        if not content:
            return
        if any(ch.isspace() for ch in content):
            self.vis.append("Q")
        else:
            self.vis.append(content)

    def _scan_cmd(self, nested):
        t, n = self.t, self.n
        depth = 0
        while self.i < n:
            c = t[self.i]
            nxt = t[self.i + 1] if self.i + 1 < n else ""
            if c == "\\":
                if nxt == "\n":
                    self.i += 2  # line continuation: joins the two lines
                    continue
                self.vis.append(nxt if nxt else "\\")
                self.i += 2 if nxt else 1
                continue
            if c == "$" and nxt in ("'", '"'):
                self.unmodeled = True  # ANSI-C / locale quoting: not modelled (B1)
                self.vis.append("$")
                self.i += 1
                continue
            if c == "'":
                self._scan_single()
                continue
            if c == '"':
                self._scan_double()
                continue
            if c == "`":
                # Backtick substitution: bash's quote handling inside it is not modelled.
                self.unmodeled = True
            if c == "#" and self._at_word_start():
                while self.i < n and t[self.i] != "\n":
                    self.i += 1
                continue
            if c == "<" and t.startswith("<<", self.i):
                if t.startswith("<<<", self.i):
                    self.vis.append("<<<")
                    self.i += 3
                    continue
                self._scan_heredoc_op()
                continue
            if c == "\n":
                self.vis.append("\n")
                self.i += 1
                if self.pending:
                    self._read_heredoc_bodies()
                continue
            if c == "(":
                if nxt == "(":
                    self.unmodeled = True  # arithmetic `((`/`$((`: `<<` there is a shift
                depth += 1
            elif c == ")" and self.pending:
                # `$(cat <<EOF)` closes before the body line: bash reads no body there, so the
                # following lines run as commands. Not modelled.
                self.unmodeled = True
            if c == ")" and nested:
                if depth == 0:
                    self.i += 1
                    return
                depth -= 1
            elif (
                nested
                and c == "c"
                and t.startswith("case", self.i)
                and (self.i + 4 >= n or t[self.i + 4].isspace())
                and self._at_word_start()
            ):
                self.unmodeled = True  # `case` patterns put bare `)` inside a quoted `$( )`
            self.vis.append(c)
            self.i += 1
        if nested:
            self.unterminated = True

    def _scan_single(self):
        start = self.i + 1
        j = self.t.find("'", start)
        if j == -1:
            self.unterminated = True
            self.i = self.n
            return
        content = self.t[start:j]
        if self.pending and "\n" in content:
            self.unmodeled = True
        self.i = j + 1
        self._emit_quoted(content)

    def _scan_double(self):
        t, n = self.t, self.n
        self.i += 1
        buf = []
        while self.i < n:
            c = t[self.i]
            nxt = t[self.i + 1] if self.i + 1 < n else ""
            if c == "\\":
                if nxt == "\n":
                    self.i += 2
                    continue
                buf.append(nxt if nxt in '"\\$`' else "\\" + nxt)
                self.i += 2
                continue
            if c == '"':
                self.i += 1
                self._emit_quoted("".join(buf))
                return
            if c == "`":
                self.unmodeled = True
            elif c == "$" and nxt == "(":
                if t.startswith("$((", self.i):
                    self.unmodeled = True
                else:
                    # A command substitution inside double quotes is CODE, scanned in command
                    # context; its text is visible, never masked as quoted prose.
                    self._emit_quoted("".join(buf))
                    buf = []
                    self.vis.append(" ( ")
                    self.i += 2
                    self._scan_cmd(nested=True)
                    self.vis.append(" ) ")
                    continue
            elif c == "$" and nxt == "{":
                m = re.match(r"\$\{[A-Za-z_][A-Za-z0-9_]*\}", t[self.i :])
                if m:
                    buf.append(m.group(0))
                    self.i += len(m.group(0))
                    continue
                self.unmodeled = True
            elif c == "\n" and self.pending:
                self.unmodeled = True
            buf.append(c)
            self.i += 1
        self.unterminated = True

    def _scan_heredoc_op(self):
        t, n = self.t, self.n
        self.i += 2
        strip_tabs = False
        if self.i < n and t[self.i] == "-":
            strip_tabs = True
            self.i += 1
        while self.i < n and t[self.i] in " \t":
            self.i += 1
        marker = []
        quoted = False
        while self.i < n:
            c = t[self.i]
            if c in " \t\n;&|()<>":
                break
            if c in ("'", '"'):
                quoted = True
                j = t.find(c, self.i + 1)
                if j == -1:
                    self.unmodeled = True
                    self.i = n
                    break
                part = t[self.i + 1 : j]
                if "$" in part or "\\" in part or "\n" in part:
                    self.unmodeled = True
                marker.append(part)
                self.i = j + 1
                continue
            if c == "\\":
                quoted = True
                if self.i + 1 < n:
                    marker.append(t[self.i + 1])
                self.i += 2
                continue
            if c in "$`":
                self.unmodeled = True
            marker.append(c)
            self.i += 1
        word = "".join(marker)
        if not word:
            self.unmodeled = True
            return
        joined = "".join(self.vis)
        line_start = joined.rfind("\n") + 1
        self.pending.append((word, strip_tabs, quoted, line_start))
        self.vis.append(" << ")

    def _read_heredoc_bodies(self):
        t, n = self.t, self.n
        joined = "".join(self.vis)
        for word, strip_tabs, quoted, line_start in self.pending:
            body_lines = []
            terminated = False
            while self.i < n:
                j = t.find("\n", self.i)
                line = t[self.i :] if j == -1 else t[self.i : j]
                self.i = n if j == -1 else j + 1
                test = line.lstrip("\t") if strip_tabs else line
                if test == word:
                    terminated = True
                    break
                if not quoted and line.endswith("\\"):
                    # An unquoted-marker body joins `\<newline>` lines before matching the
                    # terminator; not modelled here.
                    self.unmodeled = True
                body_lines.append(line)
            self.heredocs.append(
                {
                    "body": "\n".join(body_lines),
                    "terminated": terminated,
                    "quoted": quoted,
                    "line": joined[line_start:],
                }
            )
        self.pending = []


def _body_has_bd_command_piece(body: str) -> bool:
    """A data heredoc body line is prose unless one of its command pieces (split on `;`, `&&`,
    `||`, `|`, `&`, `$(`, parens, braces, backticks) starts, after the usual env/assignment/
    wrapper prefixes, with a token whose basename is `bd` (quotes and backslashes dropped)."""
    for piece in _BODY_PIECE_SPLIT_RE.split(body):
        toks = [re.sub(r"[\"'\\]", "", tok) for tok in piece.split()]
        toks = [tok for tok in toks if tok]
        if toks and _find_bd_invocation(toks) is not None:
            return True
    return False


def _piece_command_words(text: str):
    """The command word of each piece of `text` (split as in `_body_has_bd_command_piece`),
    after the usual env/assignment/wrapper/keyword prefixes."""
    words = []
    for piece in _BODY_PIECE_SPLIT_RE.split(text):
        toks = piece.split()
        if not toks:
            continue
        k = _advance_past_prefixes(toks)
        if k < len(toks):
            words.append(toks[k])
    return words


def _parse_failure_should_deny(command: str) -> bool:
    """The genuine-ParseFailure verdict. Deny unless every `bd` mention is provably inside
    quoted text or a data heredoc body, per `_ShellScan`."""
    if not _mentions_bd(command):
        return False
    sc = _ShellScan(command)
    if sc.unmodeled or sc.unterminated or sc.pending:
        return True
    words = {os.path.basename(w) for w in _VIS_WORD_SPLIT_RE.split(sc.visible) if w}
    if words & _FALLBACK_EXECUTORS or any(_PYTHON_RE.match(w) for w in words):
        return True
    if _DOT_SOURCE_RE.search(sc.visible):
        return True
    for cmd in _piece_command_words(sc.visible):
        if "$" in cmd:
            return True  # `$SHELL <<EOF`, `$P close x`: an unknown command word
    for h in sc.heredocs:
        body = h["body"]
        expands = not h["quoted"] and ("$(" in body or "`" in body)
        consumers_ok = all(
            os.path.basename(cmd) in _DATA_CONSUMERS for cmd in _piece_command_words(h["line"])
        )
        if not h["terminated"] or expands or not consumers_ok:
            if _mentions_bd(body):
                return True
            continue
        if _body_has_bd_command_piece(body):
            return True
    return _mentions_bd(sc.visible)


# --- heredoc extraction -------------------------------------------------------------------
_HEREDOC_START_RE = re.compile(r"<<-?\s*(['\"]?)(\w+)\1")
# N4 (review pa-s2s.8-review-2): operators that can separate a heredoc's CONSUMER command from
# whatever precedes it on the same line — used to isolate the consumer chunk before whitespace-
# splitting it. `$(` is included so `git commit -m "$(cat <<EOF ...` resolves to `cat`, not the
# outer `git`.
_SPLIT_BEFORE_HEREDOC_RE = re.compile(r"\$\(|\(|\|\||&&|;|\||&")
# Names whose STRING/heredoc argument executes as a command, not data (extends `_SHELL_C_NAMES`,
# defined below, with `eval`/`source`/`.` — the latter two never appear in `_SHELL_C_NAMES` since
# that set is for the `NAME -c STRING` shape specifically, not `NAME <<HEREDOC`).
_HEREDOC_SHELL_FED_EXTRA = {"eval", "source", "."}


def _heredoc_consumer_name(prefix_text):
    """Return the basename of the command that will read a heredoc whose `<<` marker is preceded,
    on the same line, by `prefix_text` (everything up to but not including `<<`) — or None if no
    command name can be recovered. Best-effort: `prefix_text` is not standalone valid shell (e.g.
    `git commit -m "$(cat ` from a `$(cat <<EOF` line), so this splits on the operators that can
    precede a heredoc consumer, whitespace-splits the LAST chunk, and skips the same leading
    wrapper/assignment prefixes `_advance_past_prefixes` skips elsewhere (`sudo bash <<EOF`
    resolves to `bash`)."""
    chunk = _SPLIT_BEFORE_HEREDOC_RE.split(prefix_text)[-1]
    chunk = chunk.replace('"', " ").replace("'", " ")
    toks = chunk.split()
    if not toks:
        return None
    i = _advance_past_prefixes(toks)
    if i >= len(toks):
        return None
    return os.path.basename(toks[i])


# Round 2 (review pa-e38.1-review-1 B2): interpreters whose stdin/heredoc body is code in a
# language this guard does not parse. A `bd` mention anywhere in such a body denies.
_HEREDOC_INTERPRETERS = {"perl", "ruby", "node", "nodejs", "php", "lua", "tclsh", "osascript", "irb"}
_LINE_WORD_SPLIT_RE = re.compile(r"[\s;&|()<>{}`'\"]+")


def _is_interpreter_name(name):
    return name in _HEREDOC_INTERPRETERS or bool(_PYTHON_RE.match(name))


def _heredoc_kind(line, m):
    """Classify the heredoc started by match `m` on `line`: "shell" (the body runs as shell
    code), "interp" (the body runs as another language's code), or "data". The consumer is the
    command on the `<<` line (`_heredoc_consumer_name`); round 2 also scans the REST of the line
    after the marker, so `cat <<EOF | sh` / `cat <<EOF | tee f | bash` / `cat <<EOF > f && bash f`
    are shell-fed, not data."""
    consumer = _heredoc_consumer_name(line[: m.start()])
    rest_words = {
        os.path.basename(w) for w in _LINE_WORD_SPLIT_RE.split(line[m.end() :]) if w
    }
    shellish = _SHELL_C_NAMES | _HEREDOC_SHELL_FED_EXTRA
    if (consumer is not None and consumer in shellish) or rest_words & shellish:
        return "shell"
    if (consumer is not None and _is_interpreter_name(consumer)) or any(
        _is_interpreter_name(w) for w in rest_words
    ):
        return "interp"
    return "data"


def _extract_heredocs(command: str):
    """Return (command_with_heredocs_stripped, [(kind, heredoc_body_text), ...]), `kind` per
    `_heredoc_kind` ("shell" / "interp" / "data").

    Best-effort: handles one or more `<<WORD` / `<<-WORD` / `<<'WORD'` / `<<"WORD"` heredocs in
    document order. Not a full shell grammar (nested heredocs inside quotes are not special-
    cased), but sufficient for the decision table's heredoc row and any straightforward variant.

    `kind == "shell"` (N4, review pa-s2s.8-review-2): the heredoc's CONSUMER (the command
    on its `<<` line) is a shell/evaluator (`bash`/`sh`/`zsh`/`dash`/`ksh`, `eval`, `source`, `.`)
    that executes the body as a command, not data. `tokenize_segments` uses this to decide
    whether a body `shlex` cannot parse fails the command closed (shell-fed) or degrades to a
    per-line check (data-fed, e.g. `cat`/`tee`/a file). A consumer this heuristic cannot resolve
    defaults to data-fed — no worse than every heredoc's treatment before this fix.
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
        kind = _heredoc_kind(line, m)
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
            bodies.append((kind, "\n".join(body_lines)))
        if not terminator_found:
            # Unterminated heredoc: not a recognizable shape. Treat as a parse failure by
            # signalling via a sentinel the caller checks for.
            raise ParseFailure("unterminated heredoc")
    return "\n".join(out_lines), bodies


# --- backtick extraction ------------------------------------------------------------------
_BACKTICK_RE = re.compile(r"`([^`]*)`")


def _extract_backticks(command: str):
    """Return (command_with_backticks_replaced_by_a_sentinel, [backtick_body, ...]).
    m3 (review pa-s2s.8-review-1): blanking a backtick group to plain whitespace silently drops
    the command name when it sat in command position (`` `command -v bd` close x `` would
    otherwise tokenize to the bare, unrecognized segment `close x`). Substitute the same
    `$(...)` sentinel `_split_segments` leaves for a command-position `$( )` group, so
    `_find_bd_invocation`/the variable-indirection check downstream still see SOMETHING there."""
    bodies = [m.group(1) for m in _BACKTICK_RE.finditer(command)]
    stripped = _BACKTICK_RE.sub(" $(...) ", command)
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

# B2 (pa-e38.1): `shlex(..., punctuation_chars=True)` does not treat `$` as a punctuation char, so
# a `VAR=$(` sequence arrives glued to the assignment word as one token (`P=$`), and a `)`
# immediately followed by another punctuation char (`;`, `|`, `&`, ...) arrives glued the other
# way (`');'`) since shlex groups adjacent punctuation chars into a single run. Both glues defeat
# `_split_segments`'s `tok == "$" and tokens[i + 1] == "("` / bare-`")"` checks, so a perfectly
# ordinary `P=$(cmd); bd show x` raises ParseFailure("unbalanced parens") and falls to the
# textual `bd`-anywhere deny fallback — denying an allowed `bd show` that merely follows a
# `$( )`-assignment. `_repair_glued_tokens` re-splits both glues after shlex has otherwise done
# its job, so `_split_segments`'s existing `$( )`-recursion sees the tokens it expects.
# Narrowed to runs containing a paren: the glue bug this repairs is specifically a `(`/`)` fused
# to an adjacent punctuation char by shlex's punctuation-run grouping (e.g. `");"` from
# `...plugin); bd...`). A pure non-paren run (`;;`, `||`, `&&`, `2>&1`'s `>&`, ...) is already
# shlex's own correctly-grouped operator token and is left untouched — narrower than "any
# punctuation-only run" so this repair pass cannot reshape operator tokens the existing 88 rows
# already depend on.
_PUNCT_ONLY_RE = re.compile(r"^(?=.*[()])[()<>|&;]+$")
# A whole token shlex produced INSIDE a quoted assignment (`X="$(bd show x)"` dequotes, posix-
# style, to the single glued word `X=$(bd show x)`, never split by shlex at all since nothing
# inside it is unquoted whitespace). Recognized here and exploded into the same `VAR=`, `$`, `(`,
# ...inner tokens..., `)` shape `_split_segments` already knows how to recurse into — so the
# substitution's own contents (which may themselves invoke/deny a `bd` verb) get their own
# judged segment, and the following/preceding segments see a bare `VAR=` (an inert assignment,
# never a `bd` invocation) rather than one opaque, unrecognized token.
_ASSIGN_SUBSHELL_TOKEN_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*=)\$\((.*)\)$", re.DOTALL)


def _resplit_punct_run(s):
    out = []
    i = 0
    n = len(s)
    while i < n:
        two = s[i : i + 2]
        if two in _OPERATORS:
            out.append(two)
            i += 2
        else:
            out.append(s[i])
            i += 1
    return out


def _repair_glued_tokens(tokens):
    out = []
    for tok in tokens:
        m = _ASSIGN_SUBSHELL_TOKEN_RE.match(tok)
        if m:
            assign, inner = m.group(1), m.group(2)
            out.append(assign)
            out.append("$")
            out.append("(")
            out.extend(_shlex_tokens(inner))
            out.append(")")
            continue
        if len(tok) > 1 and tok.endswith("$"):
            out.append(tok[:-1])
            out.append("$")
            continue
        if (
            len(tok) > 1
            and tok not in _OPERATORS
            and _PUNCT_ONLY_RE.match(tok)
            and "<(" not in tok
            and ">(" not in tok
        ):
            # Round 2: a process substitution `<(`/`>(` stays glued, so it still raises
            # ParseFailure at its `)` exactly as on main and reaches the conservative fallback.
            # Repairing it would let `source <(echo "bd close x")` / `bash <(...)` split into
            # harmless-looking segments (probe P14/P15).
            out.extend(_resplit_punct_run(tok))
            continue
        out.append(tok)
    return out


def _shlex_tokens(text: str):
    lex = shlex.shlex(text, posix=True, punctuation_chars=True)
    lex.whitespace_split = True
    try:
        tokens = list(lex)
    except ValueError as e:
        raise ParseFailure(str(e)) from e
    return _repair_glued_tokens(tokens)


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
            if not current:
                # m3 (review pa-s2s.8-review-1): a command-position `$( )` group (`$(command -v
                # bd) close x`) would otherwise vanish entirely from `current`, leaving the bare
                # unrecognized segment `close x`. Leave a sentinel so the variable-indirection
                # check below still sees something occupying command position.
                current.append("$(...)")
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
    if "$'" in command:
        # Round 2 (review pa-e38.1-review-1 B1): shlex does not model ANSI-C `$'...'` quoting
        # (`$'it\'s'` ends at a different quote than bash's), so it can see a live `bd` as
        # quoted text. Textual and deliberately over-broad (`'cost $' 'x'` also trips it):
        # the fallback then judges the command, conservatively.
        raise ParseFailure("ANSI-C $'...' quoting is not modelled")
    stripped, heredoc_bodies = _extract_heredocs(command)
    stripped, backtick_bodies = _extract_backticks(stripped)
    normalized = _normalize_newlines(stripped)
    tokens = _shlex_tokens(normalized)
    segments = _split_segments(tokens)
    for kind, body in heredoc_bodies:
        if kind == "interp":
            # Round 2 (review pa-e38.1-review-1 B2): a body fed to an interpreter is code this
            # guard cannot parse; a `bd` mention anywhere in it fails closed.
            if _mentions_bd(body):
                segments.append([_DENY_SENTINEL, "exec-heredoc"])
            continue
        body_norm = _normalize_newlines(body)
        try:
            segments.extend(_split_segments(_shlex_tokens(body_norm)))
        except ParseFailure:
            if kind == "shell":
                # N4 (review pa-s2s.8-review-2): a heredoc fed to a shell/evaluator (`bash`,
                # `sh`, `zsh`, `dash`, `ksh`, `eval`, `source`, `.`) EXECUTES its body as a real
                # command — a body `shlex` cannot parse is that command's own failure state, the
                # same "recognized bd invocation, no verdict" case the top-level parse-failure
                # deny already covers, not prose. Propagate instead of degrading to a per-line
                # first-token check, which a prefixed/chained `bd` (`sudo bd close`, `cd x && bd
                # close`) on a later line would otherwise slip past (the apostrophe fallback is
                # for DATA, never for a shell-fed body).
                raise
            # m2 (review pa-s2s.8-review-1): a heredoc BODY line containing an apostrophe (e.g.
            # a commit message "fix: don't...") is common, legitimate prose that shlex cannot
            # parse as shell tokens — it is not shell at all, when the heredoc is DATA-fed (`cat`,
            # `tee`, a file, ...). Degrade to a per-LINE first-token check instead of failing the
            # whole command closed: a line whose first token has basename `bd` still gets judged
            # as its own segment (so `cat <<EOF\nbd close x\nEOF` still denies); an ordinary prose
            # line never does.
            for line in body.split("\n"):
                stripped_line = line.strip()
                if not stripped_line:
                    continue
                first_tok = stripped_line.split()[0]
                if os.path.basename(first_tok) == "bd":
                    segments.append(stripped_line.split())
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


def _advance_past_wrappers_before_env(segment):
    """Like `_advance_past_prefixes`, but stops AT a bare `env` token instead of consuming it and
    its own flags — `_find_env_split_string` needs `env`'s flags untouched so it can inspect them
    itself. Skips `VAR=val` assignments and known wrappers (`sudo`, `nice`, `timeout`, ...) ahead
    of `env` (N5, review pa-s2s.8-review-2: `sudo env -S 'bd close x'` must resolve to `env`, not
    stop at `sudo`)."""
    i = 0
    n = len(segment)
    while i < n:
        tok = segment[i]
        if tok == "env":
            return i
        if _ASSIGN_RE.match(tok):
            i += 1
            continue
        new_i = _skip_wrapper_prefix(segment, i)
        if new_i != i:
            i = new_i
            continue
        break
    return i


# m3 (review pa-s2s.8-review-1): `env -S`/`--split-string` parses its value as a shell command
# LINE and execs it — same execution class as `bash -c`/`eval` (F3), not a value `env` merely
# passes through unread.
def _find_env_split_string(segment):
    """Return env's -S/--split-string value, or None. Recognizes `env` after skipping any leading
    wrapper prefixes (N5, review pa-s2s.8-review-2: `sudo env -S 'bd close x'` — `_advance_past_
    prefixes` alone would consume `env`'s OWN `-S value` as if unrelated, landing past the end of
    the segment with nothing left to inspect; `_advance_past_wrappers_before_env` stops AT `env`
    instead so its flags are still visible here)."""
    n = len(segment)
    i0 = _advance_past_wrappers_before_env(segment)
    if i0 >= n or segment[i0] != "env":
        return None
    i = i0 + 1
    while i < n and segment[i].startswith("-"):
        tok = segment[i]
        if tok in ("-S", "--split-string") and i + 1 < n:
            return segment[i + 1]
        if tok.startswith("--split-string="):
            return tok[len("--split-string=") :]
        if tok in _ENV_VALUE_FLAGS and i + 1 < n:
            i += 2
            continue
        i += 1
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


def _recursive_bd_deny(text, cwd, depth, outer_assigns=None, outer_command=""):
    """F3: does executing `text` as a nested shell command invoke a `bd` verb the guard would
    deny? Recurses through the same tokenizer/judge path (same `cwd`, so a `bd show` inside the
    nested string still sees the real hook payload's cwd — `bd init` no longer depends on cwd at
    all, pa-e38.8). Returns a deny-reason-key, or None. Depth-capped against pathological nesting;
    a ParseFailure that still textually mentions `bd` fails closed, matching the top-level
    contract."""
    if depth > 8:
        return "parse-failure" if BD_TOKEN_RE.search(text) else None
    try:
        segments = tokenize_segments(text)
    except ParseFailure:
        return "parse-failure" if BD_TOKEN_RE.search(text) else None
    # Round 2: the nested string runs in the SAME command, so the outer command's assignments
    # apply (`P=$(printf bd); eval "$P close x"`, `P=bd; eval "$P close x"`); a name poisoned on
    # either side stays poisoned. The `bd`-mention test sees the whole outer command.
    assigns = dict(outer_assigns or {})
    for name, value in _collect_assigns_from_text(text).items():
        if assigns.get(name) is not _POISONED:
            assigns[name] = value
    mention_text = outer_command or text
    for seg in segments:
        verdict = judge_segment(
            seg, cwd, depth=depth + 1, original_command=mention_text, assigns=assigns
        )
        if verdict is not None:
            return verdict
    return None


# --- N3 (review pa-s2s.8-review-2): command-position variable indirection, narrowed -----------
# design §12.1: a command-position `$VAR`/`${VAR}` is recognized as invoking `bd` ONLY when a
# `VAR=<literal>` assignment elsewhere in the SAME command text resolves it to a token whose
# basename is `bd`. A `$( )`/backtick command substitution is never resolved this way (its value
# cannot be known without running it). Round 2 (pa-e38.1 B3): such an unresolvable command word
# denies when the command mentions `bd` (see the end of `judge_segment`); only an unbound
# variable's indirection stays allowed.
_ASSIGN_LITERAL_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=([A-Za-z0-9_./:-]*)$")
_VAR_REF_RE = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)")
_ASSIGN_ANY_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", re.DOTALL)
# Any `$NAME` / `${NAME...}` reference, including operator forms (`${Q:-bd}`, `${P%x}`).
_VAR_NAME_REF_RE = re.compile(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)")
# Marks a variable assigned in this command from a command substitution or another expansion.
_POISONED = object()


def _collect_assigns_from_text(text):
    """Best-effort `{name: literal_value}` table of every `VAR=<literal>` word appearing anywhere
    in `text` (only a LITERAL right-hand side enters the table as a value). A name assigned from
    `$( )`, a backtick, or another `$` expansion maps to `_POISONED` instead (round 2, B3), so a
    command-position use of it is known to be unresolvable. Never raises: any tokenizing failure
    here just yields an empty table.

    Includes SHELL-FED heredoc bodies (`bash <<EOF\\nB=bd\\n$B close x\\nEOF`) — that body
    executes as command text just as much as the rest of the command line, so an assignment
    inside it is as much "the same command text" as one outside it. A DATA-fed heredoc body
    (`cat`, `tee`, ...) is never scanned here; it never executes."""
    try:
        stripped, heredoc_bodies = _extract_heredocs(text)
    except ParseFailure:
        stripped, heredoc_bodies = text, []
    stripped, _ = _extract_backticks(stripped)
    normalized = _normalize_newlines(stripped)
    all_tokens = []
    try:
        all_tokens.extend(_shlex_tokens(normalized))
    except ParseFailure:
        pass
    for kind, body in heredoc_bodies:
        if kind != "shell":
            continue
        try:
            all_tokens.extend(_shlex_tokens(_normalize_newlines(body)))
        except ParseFailure:
            continue
    table = {}
    for k, tok in enumerate(all_tokens):
        m = _ASSIGN_ANY_RE.match(tok)
        if not m:
            continue
        name, value = m.group(1), m.group(2)
        nxt = all_tokens[k + 1] if k + 1 < len(all_tokens) else None
        # Round 2 (review pa-e38.1-review-1 B3): `P=$(...)` reaches here as `P=` followed by the
        # repaired `$`, `(` tokens (a backtick as the `$(...)` sentinel's `$`), and `X=$P` /
        # `X=${Q:-bd}` keep their `$`. Such a value is unknowable: mark the name POISONED
        # (sticky across later literal assignments) instead of recording an empty literal.
        if (value == "" and nxt in ("$", "$(...)")) or "$" in value or "`" in value:
            table[name] = _POISONED
            continue
        lm = _ASSIGN_LITERAL_RE.match(tok)
        if lm and table.get(name) is not _POISONED:
            table[name] = lm.group(2)
    return table


def _resolve_command_position_token(token, assigns):
    """Try to resolve a command-position token that starts with `$` using ONLY the literal
    `VAR=val` assignments in `assigns` (design §12.1's narrow re-tokenize-once exception).
    Returns the resolved string, or None if the token is a `$( )`/backtick sentinel, or any
    variable it references has no literal assignment (an unresolved indirection stays
    unresolved — never guessed, never denied on that basis alone)."""
    if token == "$(...)":
        return None  # command substitution / backtick sentinel: never resolved

    missing = []

    def _sub(m):
        name = m.group(1) or m.group(2)
        if name not in assigns or assigns[name] is _POISONED:
            missing.append(name)
            return ""
        return assigns[name]

    resolved = _VAR_REF_RE.sub(_sub, token)
    if missing:
        return None
    return resolved


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


# m4 (review pa-s2s.8-review-1): must be STRICTLY LESS than hooks.json's PreToolUse timeout (10s)
# — portability-contract.md §7's "a timed-out PreToolUse hook renders no decision" means a `bd
# show` that runs out the FULL hook budget fails OPEN on `update --status open`, not closed. A
# margin, not equality, is the invariant tests/eb-guard.test.sh asserts against hooks.json.
BD_SHOW_TIMEOUT = 5


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
            timeout=BD_SHOW_TIMEOUT,
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
def judge_segment(segment, cwd, depth=0, original_command="", assigns=None):
    """Return None (allow) or a deny-reason-key string (see DENY_MESSAGES)."""
    if assigns is None:
        assigns = {}
    if segment and segment[0] == _DENY_SENTINEL:
        return segment[1]
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

        # m2 (review pa-s2s.8-review-1): `bd <verb> --help`/`-h` is documentation, never a
        # mutation — allow it regardless of verb, but ONLY when it is the FIRST token after the
        # verb (never scan the whole arg list: `bd close pa-x --reason -h` must still deny —
        # `-h`/`--help` there is a flag VALUE, not a request for help text).
        if args and args[0] in ("--help", "-h"):
            return None

        # F1: canonicalize aliases (`done`->close, `new`/`q`/`create-form`->create,
        # `note`->update-append-notes) before judging, so an alias is denied with the SAME
        # message as its canonical verb.
        canonical = VERB_ALIASES.get(verb, verb)

        if canonical == "init":
            # pa-e38.8: the old cwd-outside-git-repo scratch allow is removed — a cwd-pinned
            # agent (one whose hook payload's cwd is always inside a git repo) could never
            # satisfy it, so it could never reach a scratch database at all. Every direct
            # `bd init` is denied now, unconditionally; scripts/bead-scratch.sh is the only
            # sanctioned path (fixed root under $XDG_RUNTIME_DIR/estate-beads-scratch, not cwd).
            return "init"

        if canonical in ("delete", "remember", "edit", "sql", "forget"):
            return canonical

        if canonical == "reopen":  # F6
            return "reopen"

        # M2: `bd supersede`/`bd duplicate` auto-close their target; `bd batch`/`bd import`
        # reach close/create/update(status) in one call; `bd prune`/`bd purge` permanently
        # delete. None has a script wrapper today.
        if canonical in ("supersede", "duplicate", "batch", "import", "prune", "purge"):
            return canonical

        # M2: `bd todo` is a two-word verb family — `bd todo done <id>` -> close, `bd todo add
        # <title>` -> create; bare `bd todo` / `bd todo list` are read-only and allowed.
        if canonical == "todo":
            sub = args[0] if args else None
            if sub == "done":
                return "close"
            if sub == "add":
                return "create"
            return None

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
        return _recursive_bd_deny(exec_str, cwd, depth, assigns, original_command)

    # m3 (review pa-s2s.8-review-1): `env -S '...'`/`--split-string='...'` execs its value as a
    # shell command line, same class as the `bash -c`/`eval` check above.
    env_split = _find_env_split_string(segment)
    if env_split is not None:
        return _recursive_bd_deny(env_split, cwd, depth, assigns, original_command)

    # N3 (review pa-s2s.8-review-2, reverting a fix round 1 deviation): a variable/command-
    # substitution/backtick sentinel sits in COMMAND POSITION (`B=bd; $B close x`, `$(command -v
    # bd) close x`). Resolve it ONLY via a literal `VAR=value` assignment recorded elsewhere in
    # the same command text (never a `$( )`/backtick substitution, which `_resolve_command_
    # position_token` never resolves) — if that yields a token whose basename is `bd`, judge the
    # REBUILT segment through the SAME verb-dispatch path above, so the deny message names the
    # actual verb (e.g. "Raw bd close is denied...") rather than a separate generic reason. An
    # indirection that cannot be resolved this way is allowed when nothing in the command binds
    # it (`$EDITOR bd-notes.md`, row81) — see the round-2 exception below.
    i = _advance_past_prefixes(segment)
    if i < len(segment) and segment[i].startswith("$"):
        resolved = _resolve_command_position_token(segment[i], assigns)
        if resolved is not None and os.path.basename(resolved) == "bd":
            rebuilt = segment[:i] + [resolved] + segment[i + 1 :]
            return judge_segment(
                rebuilt, cwd, depth=depth, original_command=original_command, assigns=assigns
            )

    # Round 2 (review pa-e38.1-review-1 B3; brief: fail-closed rows win over N3): a command word
    # whose basename comes from a command substitution (the `$(...)`/backtick sentinel) or from
    # a variable this same command assigns from a substitution or another expansion
    # (`P=$(printf bd); $P close x`, `P="$(command -v bd)"; "$P" close x`) cannot be resolved
    # and may well be `bd`. Deny when the command mentions `bd` anywhere. A command word whose
    # basename is literal (`"$ROOT/scripts/x.sh"`) can never be `bd` and stays allowed; an
    # unbound variable (`$EDITOR`) keeps N3's allow.
    if i < len(segment) and _command_word_tainted(segment[i], assigns):
        if _mentions_bd(original_command or " ".join(segment)):
            return "unresolved-indirection"

    return None


def _command_word_tainted(token, assigns):
    if token == "$(...)":
        return True
    base = os.path.basename(token)
    if "$" not in base:
        return False
    return any(
        assigns.get(name) is _POISONED for name in _VAR_NAME_REF_RE.findall(base)
    )


def judge_command(command, cwd):
    """Return None (allow) or a deny-reason-key string. Raises ParseFailure if the tokenizer
    cannot produce segments at all."""
    segments = tokenize_segments(command)
    assigns = _collect_assigns_from_text(command)
    for segment in segments:
        verdict = judge_segment(segment, cwd, original_command=command, assigns=assigns)
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
            if _parse_failure_should_deny(command):
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
