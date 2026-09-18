#!/usr/bin/env python3
"""Line-level edits to opencode's JSONC config, which carries comments.

A JSON round-trip would delete the user's comments, so we insert (and later
remove) a marked block inside the "mcp" object instead.

Usage:
  jsonc_edit.py add    <file> <mcp-binary> <home> <served-binary>
  jsonc_edit.py remove <file>
  jsonc_edit.py has    <file>
"""

import os
import re
import sys

BEGIN = "// sensenova-u1:begin (managed by `sensenova-u1 clients`)"
END = "// sensenova-u1:end"


def insert(path, mcp, home, served):
    lines = open(path).read().split("\n")
    out, inserted = [], False
    for index, line in enumerate(lines):
        # "mcp": {}  — an empty object written inline
        inline_empty = re.match(r'^(\s*)"mcp"\s*:\s*\{\s*\}\s*(,?)\s*$', line)
        if inline_empty and not inserted:
            indent, comma = inline_empty.group(1) + "  ", inline_empty.group(2)
            out.append(f'{inline_empty.group(1)}"mcp": {{')
            out += _block(indent, "", mcp, home, served)
            out.append(f"{inline_empty.group(1)}}}" + comma)
            inserted = True
            continue
        out.append(line)
        if inserted or not re.match(r'^\s*"mcp"\s*:\s*\{\s*$', line):
            continue
        indent = re.match(r"^(\s*)", line).group(1) + "  "
        rest = [l for l in lines[index + 1:] if l.strip()]
        # A trailing comma would be invalid if ours were the only entry.
        empty = bool(rest) and rest[0].strip().startswith("}")
        out += _block(indent, "" if empty else ",", mcp, home, served)
        inserted = True
    if not inserted:
        sys.exit(f'no "mcp" object found in {path} (open opencode once, then re-run)')
    open(path, "w").write("\n".join(out))


def _block(indent, comma, mcp, home, served):
    return [
        f"{indent}{BEGIN}",
        f'{indent}"sensenova": {{',
        f'{indent}  "type": "local",',
        f'{indent}  "command": ["{mcp}"],',
        f'{indent}  "environment": {{',
        f'{indent}    "SENSENOVA_HOME": "{home}",',
        f'{indent}    "SENSENOVA_SERVED_BIN": "{served}"',
        f"{indent}  }},",
        f'{indent}  "enabled": true',
        f"{indent}}}{comma}",
        f"{indent}{END}",
    ]


def remove(path):
    lines, out, skipping = open(path).read().split("\n"), [], False
    for line in lines:
        if BEGIN in line:
            skipping = True
        if not skipping:
            out.append(line)
        if skipping and END in line:
            skipping = False
    open(path, "w").write("\n".join(out))


def main(argv):
    if len(argv) < 3:
        sys.exit(__doc__)
    action, path = argv[1], argv[2]
    if action == "add":
        insert(path, argv[3], argv[4], argv[5])
    elif action == "remove":
        if os.path.exists(path):
            remove(path)
    elif action == "has":
        sys.exit(0 if os.path.exists(path) and BEGIN in open(path).read() else 1)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv)
