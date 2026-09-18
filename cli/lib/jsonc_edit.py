#!/usr/bin/env python3
"""Line-level edits to opencode's JSONC config, which carries comments.

A JSON round-trip would delete the user's comments, so the entry is inserted as
a marked block inside the "mcp" object. `add` is idempotent: it removes every
previous copy first — our marked block, and any other "sensenova" entry in the
same object, hand-written ones included. Leaving those behind is not harmless:
JSON keeps the last duplicate key, so a stale entry pointing at an old path
silently wins over the one we just wrote.

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
KEY = "sensenova"


def _depth_delta(line):
    """Brace/bracket delta outside strings and // comments."""
    line = _strip_comment(line)
    depth, in_string, escaped = 0, False, False
    for char in line:
        if in_string:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
        elif char == '"':
            in_string = True
        elif char in "{[":
            depth += 1
        elif char in "}]":
            depth -= 1
    return depth


def _strip_comment(line):
    in_string, escaped = False, False
    for index, char in enumerate(line):
        if in_string:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
        elif char == '"':
            in_string = True
        elif char == "/" and line[index:index + 2] == "//":
            return line[:index]
    return line


def _key_of(line):
    match = re.match(r'^\s*"([^"]+)"\s*:', line)
    return match.group(1) if match else None


def _strip_managed(lines):
    """Drop our marked blocks; returns (lines, removed_count)."""
    out, skipping, removed = [], False, 0
    for line in lines:
        if BEGIN in line:
            skipping, removed = True, removed + 1
        if not skipping:
            out.append(line)
        if skipping and END in line:
            skipping = False
    return out, removed


def _find_object(lines, key):
    """(open_index, close_index) of `"key": {` … matching `}`; None if absent."""
    for start, line in enumerate(lines):
        match = re.match(r'^\s*"%s"\s*:\s*\{\s*$' % re.escape(key), line)
        if not match:
            continue
        depth = 0
        for index in range(start, len(lines)):
            depth += _depth_delta(lines[index])
            if index > start and depth <= 0:
                return start, index
        return None
    return None


def _entries(lines, open_index, close_index):
    """Top-level (start, end, key) blocks inside an object, so commas can be fixed."""
    found, index, current, depth = [], open_index + 1, None, 0
    while index < close_index:
        line = lines[index]
        stripped = _strip_comment(line).strip()
        if current is None and stripped:
            key = _key_of(line)
            if key is not None:
                current, depth = [index, None, key], 0
        if current is not None:
            depth += _depth_delta(line)
            if depth <= 0:
                current[1] = index
                found.append(tuple(current))
                current = None
        index += 1
    return found


def _drop_entries(lines, spans):
    drop = set()
    for start, end, _key in spans:
        drop.update(range(start, end + 1))
    return [line for index, line in enumerate(lines) if index not in drop]


def _normalise_commas(lines, open_index, close_index):
    """Every entry but the last needs a comma; the last must not have one."""
    spans = _entries(lines, open_index, close_index)
    for position, (start, end, _key) in enumerate(spans):
        body = _strip_comment(lines[end]).rstrip()
        has_comma = body.endswith(",")
        last = position == len(spans) - 1
        if last and has_comma:
            lines[end] = lines[end].rstrip()[:-1]
        elif not last and not has_comma:
            lines[end] = lines[end].rstrip() + ","
    return lines


def _block(indent, comma, mcp, home, served):
    return [
        f"{indent}{BEGIN}",
        f'{indent}"{KEY}": {{',
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


def insert(path, mcp, home, served):
    lines = open(path).read().split("\n")

    # "mcp": {}  — an empty object written inline
    for index, line in enumerate(lines):
        inline = re.match(r'^(\s*)"mcp"\s*:\s*\{\s*\}\s*(,?)\s*$', line)
        if inline:
            lines[index:index + 1] = [f'{inline.group(1)}"mcp": {{', f"{inline.group(1)}}}" + inline.group(2)]
            break

    lines, removed = _strip_managed(lines)
    bounds = _find_object(lines, "mcp")
    if bounds is None:
        sys.exit(f'no "mcp" object found in {path} (open opencode once, then re-run)')
    open_index, close_index = bounds

    stale = [span for span in _entries(lines, open_index, close_index) if span[2] == KEY]
    if stale:
        lines = _drop_entries(lines, stale)
        close_index = _find_object(lines, "mcp")[1]
        removed += len(stale)

    open_index, close_index = _find_object(lines, "mcp")
    indent = re.match(r"^(\s*)", lines[open_index]).group(1) + "  "
    rest = _entries(lines, open_index, close_index)
    lines[open_index + 1:open_index + 1] = _block(indent, "," if rest else "", mcp, home, served)
    open_index, close_index = _find_object(lines, "mcp")
    lines = _normalise_commas(lines, open_index, close_index)

    open(path, "w").write("\n".join(lines))
    if removed:
        print(f"replaced {removed} previous sensenova entr{'y' if removed == 1 else 'ies'}", file=sys.stderr)


def remove(path):
    if not os.path.exists(path):
        return
    lines, removed = _strip_managed(open(path).read().split("\n"))
    if not removed:
        return
    open(path, "w").write("\n".join(lines))


def main(argv):
    if len(argv) < 3:
        sys.exit(__doc__)
    action, path = argv[1], argv[2]
    if action == "add":
        insert(path, argv[3], argv[4], argv[5])
    elif action == "remove":
        remove(path)
    elif action == "has":
        sys.exit(0 if os.path.exists(path) and BEGIN in open(path).read() else 1)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv)
