#!/usr/bin/env python3
"""batch.py — parse and resolve a batch-authoring artifact (design §11.7, §12.2).

Usage: batch.py <artifact-path>

Parses the FIRST fenced ```yaml block in <artifact-path> whose top level has both
`project` and `units`. Applies batch-level defaults to every unit (labels union,
class/budget override), resolves sibling `parent`/`deps` references into a
topological creation order, and prints ONE JSON object on stdout:

  {
    "project": "<str>",
    "recognized_by": "<str, default = the artifact path>",
    "units": [
      {
        "key": "<str>"|null,          # null when the unit gave no key (title-fallback, §11.7)
        "title": "<str>", "description": "<str>",
        "acceptance": "<str>", "accept": "evidence|independent|operator",
        "type": "<str, default task>",
        "labels": ["<str>", ...],           # batch ∪ unit, deduped, sorted
        "tier": "<str>"|null, "effort": "<str>"|null,
        "class": "<str>"|null,               # effective (unit overrides batch)
        "budget": "cycles=N[,dim=N...]"|null,
        "parent": {"kind": "sibling"|"external", "value": "<key-or-id>"}|null,
        "deps": [{"edge": "blocked-by"|"discovered-from",
                   "kind": "sibling"|"external", "value": "<key-or-id>"}, ...]
      },
      ...                                    # in resolved (topological) order
    ]
  }

Exits 1 with a one-line message on stderr and prints nothing on:
  - no fenced yaml block with both `project` and `units`
  - missing required batch `project`, or a unit missing `title`/`acceptance`/`accept`
    (`key` is optional — a keyless unit falls back to title matching, §11.7)
  - a unit `accept` not in {evidence, independent, operator}
  - a duplicate `key` across units
  - a `parent`/`deps` sibling-key cycle (including a unit citing its own key)

Nothing here touches `bd` or the filesystem beyond reading <artifact-path> — this
is pure parsing/resolution; scripts/create-beads-batch.sh does every side effect.
"""
import json
import re
import sys

import yaml

ACCEPT_VALUES = {"evidence", "independent", "operator"}
EDGE_KINDS = {"blocked-by", "discovered-from"}


def die(msg: str) -> "None":
    print(f"batch.py: {msg}", file=sys.stderr)
    sys.exit(1)


def extract_yaml_block(text: str):
    """Return the parsed dict of the first ```yaml fenced block with both
    top-level `project` and `units`, or None if none qualifies."""
    fence_re = re.compile(r"```ya?ml\s*\n(.*?)```", re.DOTALL)
    for m in fence_re.finditer(text):
        block = m.group(1)
        try:
            data = yaml.safe_load(block)
        except yaml.YAMLError:
            continue
        if isinstance(data, dict) and "project" in data and "units" in data:
            return data
    return None


def budget_map_to_flag(m):
    """{"cycles": 5} -> "cycles=5"; None/{} -> None. Validates non-negative ints."""
    if not m:
        return None
    if not isinstance(m, dict):
        die(f"'budget' must be a mapping, got {m!r}")
    parts = []
    for dim, val in m.items():
        if not isinstance(val, int) or isinstance(val, bool) or val < 0:
            die(f"budget dimension '{dim}' must be a non-negative integer, got {val!r}")
        parts.append(f"{dim}={val}")
    return ",".join(parts)


def parse_dep(raw: str, keys: set):
    raw = str(raw)
    if ":" not in raw:
        die(f"dep '{raw}' is not '<edge>:<key-or-id>' (missing ':')")
    edge, value = raw.split(":", 1)
    if edge not in EDGE_KINDS:
        die(f"dep '{raw}' has unknown edge '{edge}' (must be blocked-by|discovered-from)")
    kind = "sibling" if value in keys else "external"
    return {"edge": edge, "kind": kind, "value": value}


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: batch.py <artifact-path>", file=sys.stderr)
        return 1
    path = sys.argv[1]
    try:
        with open(path, "r", encoding="utf-8") as f:
            text = f.read()
    except OSError as e:
        die(f"cannot read '{path}': {e}")
        return 1

    data = extract_yaml_block(text)
    if data is None:
        die(f"no fenced ```yaml block in '{path}' has both top-level 'project' and 'units'")
        return 1

    project = data.get("project")
    if not project:
        die("batch is missing required 'project'")
        return 1
    recognized_by = data.get("recognized-by") or path
    batch_labels = data.get("labels") or []
    if not isinstance(batch_labels, list):
        die("batch 'labels' must be a list")
        return 1
    batch_class = data.get("class")
    batch_budget_raw = data.get("budget")
    batch_parent_default = data.get("parent")

    raw_units = data.get("units")
    if not isinstance(raw_units, list) or not raw_units:
        die("batch 'units' must be a non-empty list")
        return 1

    # m11 (review pa-s2s.8-review-1): §11.7 keeps title matching as the fallback "for artifacts
    # without keys" — a unit may omit `key`. It gets an INTERNAL-ONLY synthetic key (never
    # exposed in the output `key` field, never eligible as a sibling parent/dep target: only a
    # unit with a real `key` can be referenced by others) so the topological sort still has a
    # stable slot for it. create-beads-batch.sh sees `"key": null` for it and passes no --key to
    # create-bead.sh, which falls back to its own exact-title idempotency match.
    keys = []
    by_key = {}
    real_keyset = set()
    has_real_key = {}
    for i, u in enumerate(raw_units):
        if not isinstance(u, dict):
            die(f"unit #{i} is not a mapping")
            return 1
        key = u.get("key")
        label = key or f"(unit #{i}, title '{u.get('title', '')}')"
        if key:
            if key in by_key:
                die(f"duplicate unit key '{key}'")
                return 1
            real_keyset.add(key)
        else:
            key = f"__unkeyed_{i}"
        for field in ("title", "acceptance", "accept"):
            if not u.get(field):
                die(f"unit {label} is missing required '{field}'")
                return 1
        if u["accept"] not in ACCEPT_VALUES:
            die(f"unit {label} has accept '{u['accept']}' not in evidence|independent|operator")
            return 1
        keys.append(key)
        by_key[key] = u
        has_real_key[key] = key in real_keyset

    keyset = real_keyset

    # Build each unit's effective, resolved shape (labels union, class/budget
    # override, parent/deps kind-tagged). No topological ordering yet.
    resolved = {}
    edges = {k: set() for k in keys}  # k depends on edges[k] (must be created first)
    for key in keys:
        u = by_key[key]
        unit_labels = u.get("labels") or []
        if not isinstance(unit_labels, list):
            die(f"unit '{key}' labels must be a list")
            return 1
        labels = sorted(set(batch_labels) | set(unit_labels))

        eff_class = u.get("class") or batch_class
        eff_budget_raw = u.get("budget") if u.get("budget") is not None else batch_budget_raw
        eff_budget = budget_map_to_flag(eff_budget_raw)

        parent_raw = u.get("parent") or batch_parent_default
        parent = None
        if parent_raw:
            pkind = "sibling" if parent_raw in keyset else "external"
            if pkind == "sibling":
                if parent_raw == key:
                    die(f"unit '{key}' names itself as its own parent")
                    return 1
                edges[key].add(parent_raw)
            parent = {"kind": pkind, "value": parent_raw}

        deps_raw = u.get("deps") or []
        if not isinstance(deps_raw, list):
            die(f"unit '{key}' deps must be a list")
            return 1
        deps = []
        dep_edge_for = {}
        for d in deps_raw:
            dep = parse_dep(d, keyset)
            prev = dep_edge_for.get(dep["value"])
            if prev is not None and prev != dep["edge"]:
                die(f"unit '{key}' gives '{dep['value']}' two edge types ('{prev}' and '{dep['edge']}'); "
                    "bd allows one edge type per target")
                return 1
            dep_edge_for[dep["value"]] = dep["edge"]
            if dep["kind"] == "sibling":
                if dep["value"] == key:
                    die(f"unit '{key}' names itself in its own deps ('{d}')")
                    return 1
                edges[key].add(dep["value"])
            deps.append(dep)

        resolved[key] = {
            "key": key if has_real_key[key] else None,
            "title": u["title"],
            "description": u.get("description") or "",
            "acceptance": u["acceptance"],
            "accept": u["accept"],
            "type": u.get("type") or "task",
            "labels": labels,
            "tier": u.get("tier"),
            "effort": u.get("effort"),
            "class": eff_class,
            "budget": eff_budget,
            "parent": parent,
            "deps": deps,
        }

    # Kahn's algorithm over sibling-key edges only (parent + blocked-by/discovered-from
    # siblings) — a cycle (including self-reference, already rejected above) leaves
    # nodes stranded with nonzero in-degree.
    indegree = {k: len(edges[k]) for k in keys}
    ready = [k for k in keys if indegree[k] == 0]
    ready.sort()  # deterministic order for ties: artifact (insertion) order via stable sort below
    # Preserve original artifact order among ties by walking `keys` and picking ready ones.
    order = []
    remaining = set(keys)
    # dependents[k] = set of units that depend on k (edge FROM dependent TO k)
    dependents = {k: set() for k in keys}
    for k in keys:
        for dep in edges[k]:
            dependents[dep].add(k)

    frontier = [k for k in keys if indegree[k] == 0]
    while frontier:
        # Deterministic: process in original artifact order among the current frontier.
        frontier.sort(key=lambda k: keys.index(k))
        k = frontier.pop(0)
        order.append(k)
        remaining.discard(k)
        for dep_k in dependents[k]:
            indegree[dep_k] -= 1
            if indegree[dep_k] == 0:
                frontier.append(dep_k)

    if remaining:
        die(f"cycle detected among sibling parent/deps references: {', '.join(sorted(remaining))}")
        return 1

    out = {
        "project": project,
        "recognized_by": recognized_by,
        "units": [resolved[k] for k in order],
    }
    print(json.dumps(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
