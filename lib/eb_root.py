#!/usr/bin/env python3
"""eb_root.py — plugin/project/data root resolution (bash twin: eb-root.sh).

Implements portability-contract.md §6 "Root resolution". Stdout is BYTE-IDENTICAL to the bash
twin for the same inputs; stderr is only semantically parallel. Adapted from
holonic/lib/hol_root.py + holonic/bin/hol-root.sh (cited "adapted from" per WP4 brief), with
the precedence order kept NON-inverted per the contract's default (holonic's anchor-before-git
ordering is the contract's documented §6 "governed-seam exception", not the default — invert it
only for a governed seam and note the inversion + its Codex consequence in this plugin's README
"## Provider support" matrix).

Plugin root:  <ENVPREFIX>_PLUGIN_ROOT -> PLUGIN_ROOT -> CLAUDE_PLUGIN_ROOT -> $0-relative
Project root: <ENVPREFIX>_PROJECT_ROOT -> --cwd -> `git rev-parse --show-toplevel` ->
              CLAUDE_PROJECT_DIR -> unresolved
Data dir:     <ENVPREFIX>_DATA -> PLUGIN_DATA -> CLAUDE_PLUGIN_DATA -> <plugin root>/.data
<ENVPREFIX> is PREFIX uppercased with hyphens -> underscores, computed below at runtime — it is
NOT a fourth scaffold-time substitution token (see scripts/scaffold-plugin.sh's render_template
for the full, fixed token set this file is rendered through).

Ambient-var OWNERSHIP CHECK (E2E finding, orchestrator ruling): a session can run several
plugins' hooks, and the harness exports PLUGIN_ROOT/CLAUDE_PLUGIN_ROOT/PLUGIN_DATA/
CLAUDE_PLUGIN_DATA freshly for WHICHEVER plugin's hook fired last — a non-hook invocation of
this twin (e.g. scripts/<prefix>-doctor run directly) can inherit a FOREIGN plugin's values from
that ambient environment. Only this plugin's OWN namespaced override (<ENVPREFIX>_PLUGIN_ROOT /
<ENVPREFIX>_DATA) is trusted unconditionally — it can only have been set deliberately for THIS
plugin. The four generic/ambient vars are validated before use:
  - PLUGIN_ROOT / CLAUDE_PLUGIN_ROOT: accepted only if <value>/.claude-plugin/plugin.json exists
    and its `name` equals this plugin's name (estate-beads); otherwise rejected silently and the
    chain falls through to $0-relative, which is always correct for a script inside this plugin.
  - PLUGIN_DATA / CLAUDE_PLUGIN_DATA: accepted only if the path has a component equal to
    estate-beads or starting with "estate-beads-" (Claude: ~/.claude/plugins/data/<name>/; Codex:
    ~/.codex/plugins/data/<name>-<marketplace>/); otherwise rejected and the source reports
    "fallback (ambient env var rejected: <var>)" rather than silently claiming "default".

--cwd stands in for hook-stdin's `cwd` field: this module has no stdin channel of its own, so a
shim reads stdin JSON and forwards `cwd` explicitly — that keeps both twins byte-identical from
the same CLI inputs, testable without a live hook invocation.

Exit codes: 0 ok | 2 misconfigured override | 3 project root unresolved | 64 usage error.
No caching across calls: every call re-reads the environment and re-probes git.
"""
import json
import os
import subprocess
import sys

PREFIX = "eb"
PLUGIN_NAME = "estate-beads"       # plugin.json `name` — the ownership key for ambient env vars
_ENVPREFIX = PREFIX.upper().replace("-", "_")  # matches scaffold-plugin.sh's own ENVPREFIX derivation

ENV_PLUGIN_OWN = f"{_ENVPREFIX}_PLUGIN_ROOT"
ENV_PLUGIN_AMBIENT = ("PLUGIN_ROOT", "CLAUDE_PLUGIN_ROOT")
ENV_PROJECT_OVERRIDE = f"{_ENVPREFIX}_PROJECT_ROOT"
ENV_ANCHOR = "CLAUDE_PROJECT_DIR"
ENV_DATA_OWN = f"{_ENVPREFIX}_DATA"
ENV_DATA_AMBIENT = ("PLUGIN_DATA", "CLAUDE_PLUGIN_DATA")


class RootError(RuntimeError):
    """An explicit root override is set but is not an existing absolute directory."""


def _norm(path):
    return os.path.realpath(path)


def _from_env(name):
    raw = os.environ.get(name)
    if not raw:
        return None
    if not os.path.isabs(raw):
        raise RootError(f"{name} must be an absolute path, got: {raw!r}")
    if not os.path.isdir(raw):
        raise RootError(f"{name} is not an existing directory: {raw!r}")
    return _norm(raw)


def _owns_plugin_root(path):
    """True iff <path>/.claude-plugin/plugin.json exists and its `name` is THIS plugin's."""
    manifest = os.path.join(path, ".claude-plugin", "plugin.json")
    try:
        with open(manifest, "r", encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return False
    return isinstance(data, dict) and data.get("name") == PLUGIN_NAME


def _owns_data_path(path):
    """True iff PATH has a component == PLUGIN_NAME or starting with "PLUGIN_NAME-"."""
    parts = os.path.normpath(path).split(os.sep)
    for part in parts:
        if part == PLUGIN_NAME or part.startswith(PLUGIN_NAME + "-"):
            return True
    return False


def _script_relative_root():
    root = os.path.dirname(os.path.dirname(_norm(__file__)))
    if not os.path.isdir(root):
        raise RootError(f"script-relative plugin root does not exist: {root!r}")
    return root


def _git_toplevel():
    env = dict(os.environ)
    for key in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE"):
        env.pop(key, None)
    try:
        proc = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            env=env, capture_output=True, text=True, check=False,
        )
    except OSError:
        return None
    if proc.returncode != 0:
        return None
    out = proc.stdout.strip()
    return _norm(out) if out and os.path.isdir(out) else None


def _registry_root():
    """installPath from installed_plugins.json for estate-beads@homelab-plugins (design §12.4),
    preferring scope "user" then the first record. This is the cross-plugin tier: the only one
    that resolves correctly for a vendored copy of this twin running inside another plugin's
    tree, where script-relative would resolve into that foreign plugin's own directory."""
    json_path = os.environ.get(
        "EB_PLUGINS_JSON",
        os.path.expanduser("~/.claude/plugins/installed_plugins.json"),
    )
    try:
        with open(json_path, "r", encoding="utf-8") as f:
            data = json.load(f)
        records = data.get("plugins", {}).get("estate-beads@homelab-plugins", [])
    except (OSError, ValueError, AttributeError):
        return None
    if not records:
        return None
    ordered = [r for r in records if r.get("scope") == "user"] + records
    install_path = ordered[0].get("installPath")
    if not install_path or not os.path.isdir(install_path):
        return None
    if not _owns_plugin_root(install_path):
        return None
    return _norm(install_path)


def resolve_plugin_root():
    value = _from_env(ENV_PLUGIN_OWN)
    if value is not None:
        return value, ENV_PLUGIN_OWN
    for var in ENV_PLUGIN_AMBIENT:
        value = _from_env(var)
        if value is not None and _owns_plugin_root(value):
            return value, var
        # set but NOT ours (a foreign plugin's ambient root, or no manifest there): never
        # trust it — fall through exactly as if it were unset (E2E finding).
    registry = _registry_root()
    if registry is not None:
        return registry, "installed-registry"
    sibling = os.environ.get("EB_WORKSPACE_SIBLING") or (
        os.path.join(os.environ["SEAT_ROOT"], "engineering/agentic/plugins/estate-beads")
        if os.environ.get("SEAT_ROOT")
        else None
    )
    if sibling and os.path.isdir(sibling) and _owns_plugin_root(sibling):
        return _norm(sibling), "workspace-sibling"
    return _script_relative_root(), "script-relative"


def resolve_project_root(stdin_cwd=None):
    value = _from_env(ENV_PROJECT_OVERRIDE)
    if value is not None:
        return value, ENV_PROJECT_OVERRIDE
    if stdin_cwd:
        if os.path.isabs(stdin_cwd) and os.path.isdir(stdin_cwd):
            return _norm(stdin_cwd), "stdin-cwd"
    git_root = _git_toplevel()
    if git_root is not None:
        return git_root, "git"
    value = _from_env(ENV_ANCHOR)
    if value is not None:
        return value, ENV_ANCHOR
    return None, "unresolved"


def resolve_data_dir(plugin_root):
    value = _from_env(ENV_DATA_OWN)
    if value is not None:
        return value, ENV_DATA_OWN
    rejected = None
    for var in ENV_DATA_AMBIENT:
        value = _from_env(var)
        if value is not None:
            if _owns_data_path(value):
                return value, var
            rejected = var  # set, but points at a FOREIGN plugin's data dir
    default = os.path.join(plugin_root, ".data")
    if rejected is not None:
        return default, f"fallback (ambient env var rejected: {rejected})"
    return default, "default"


_USAGE = (
    "usage: eb_root.py [--source] [--cwd PATH] {plugin|project|data}\n"
    "\n"
    "  plugin              print the resolved plugin root\n"
    "  project             print the resolved project root\n"
    "  data                print the resolved data dir\n"
    "  --cwd PATH          the hook-stdin `cwd` value a shim forwards\n"
    "  --source            also print the resolution source, tab-separated\n"
    "\n"
    "exit codes: 0 ok, 2 misconfigured override, 3 project root unresolved, 64 usage error\n"
)


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    want_source = False
    cwd = None
    cmd = None
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg in ("-h", "--help"):
            sys.stdout.write(_USAGE)
            return 0
        elif arg == "--source":
            want_source = True
        elif arg == "--cwd":
            i += 1
            if i >= len(argv):
                sys.stderr.write("eb_root: --cwd requires a value\n" + _USAGE)
                return 64
            cwd = argv[i]
        elif arg in ("plugin", "project", "data") and cmd is None:
            cmd = arg
        else:
            sys.stderr.write(f"eb_root: unexpected argument: {arg}\n" + _USAGE)
            return 64
        i += 1
    if cmd is None:
        sys.stderr.write("eb_root: missing subcommand (plugin|project|data)\n" + _USAGE)
        return 64

    try:
        if cmd == "plugin":
            path, source = resolve_plugin_root()
        elif cmd == "data":
            proot, _ = resolve_plugin_root()
            path, source = resolve_data_dir(proot)
        else:
            path, source = resolve_project_root(cwd)
            if path is None:
                sys.stderr.write("eb_root: project root unresolved\n")
                return 3
    except RootError as exc:
        sys.stderr.write(f"eb_root: {exc}\n")
        return 2

    if want_source:
        sys.stdout.write(f"{path}\t{source}\n")
    else:
        sys.stdout.write(f"{path}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
