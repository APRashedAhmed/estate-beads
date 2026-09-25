#!/usr/bin/env python3
"""frontmatter.py — extract a Markdown file's leading YAML frontmatter as JSON.

Usage: frontmatter.py <path>

The frontmatter is the block between the first two lines that are exactly "---". Prints the
parsed block as JSON on stdout (top-level `null` fields serialize as JSON null, e.g. `prior: ~`).
Exits 1 with a message on stderr if the file has no frontmatter block or it fails to parse.
"""
import json
import sys

import yaml


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: frontmatter.py <path>", file=sys.stderr)
        return 1
    path = sys.argv[1]
    try:
        with open(path, "r", encoding="utf-8") as f:
            text = f.read()
    except OSError as e:
        print(f"frontmatter.py: cannot read '{path}': {e}", file=sys.stderr)
        return 1

    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        print(f"frontmatter.py: '{path}' has no leading '---' frontmatter fence", file=sys.stderr)
        return 1
    end = None
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            end = i
            break
    if end is None:
        print(f"frontmatter.py: '{path}' frontmatter fence never closes", file=sys.stderr)
        return 1

    block = "\n".join(lines[1:end])
    try:
        data = yaml.safe_load(block) or {}
    except yaml.YAMLError as e:
        print(f"frontmatter.py: '{path}' frontmatter is not valid YAML: {e}", file=sys.stderr)
        return 1

    if not isinstance(data, dict):
        print(f"frontmatter.py: '{path}' frontmatter is not a mapping", file=sys.stderr)
        return 1

    print(json.dumps(data))
    return 0


if __name__ == "__main__":
    sys.exit(main())
