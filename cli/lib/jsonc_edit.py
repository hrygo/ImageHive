#!/usr/bin/env python3
"""Line-level edits to opencode's JSONC config, which carries comments.

A JSON round-trip would delete the user's comments, so the entry is inserted as
a marked block inside the "mcp" object. `add` is idempotent: it removes every
previous copy first — our marked block, and any other "imagehive" entry in the
same object, hand-written ones included. Leaving those behind is not harmless:
JSON keeps the last duplicate key, so a stale entry pointing at an old path
silently wins over the one we just wrote.

Blocks written before 0.6 (when this project was called `sensenova-u1`) carry
different markers and a different key. They are recognised too, and for two
reasons: a block we no longer recognise is a block `remove` can no longer clean
up, and a leftover entry under the old key points at the old paths while the
client shows every tool twice.

Usage:
  jsonc_edit.py add        <file> <mcp-binary> <home> <daemon-binary>
  jsonc_edit.py remove     <file>
  jsonc_edit.py has        <file>
  jsonc_edit.py has-legacy <file>
"""

import os
import re
import sys

# Sibling module, so an invocation by path (`python3 cli/lib/jsonc_edit.py …`) and one
# by `-m` both find it.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from atomic_write import write_text  # noqa: E402  (needs the path above first)

BEGIN = "// imagehive:begin (managed by `imagehive clients`)"
END = "// imagehive:end"
KEY = "imagehive"
# 0.5.2 and earlier.
LEGACY_BEGIN = "// sensenova-u1:begin (managed by `sensenova-u1 clients`)"
LEGACY_END = "// sensenova-u1:end"
LEGACY_KEY = "sensenova"

_MANAGED = ((BEGIN, END), (LEGACY_BEGIN, LEGACY_END))
_KEYS = (KEY, LEGACY_KEY)
_ENDS = {END, LEGACY_END}


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
    """Drop our marked blocks, current and pre-0.6; (lines, removed_count).

    The *closing* marker goes with the block, and a closing marker with no
    opening one above it is dropped too. Both matter: an earlier version stopped
    skipping at the end marker and then kept the line, so every wiring left one
    more `// imagehive:end` behind than it removed — visible in the file, and one
    more each time the client was wired (measured 2026-09-18 on an opencode
    config that had been wired twice: two stray end markers).
    """
    out, skipping, end_marker, removed = [], False, None, 0
    for line in lines:
        if skipping:
            if end_marker in line:
                skipping, end_marker = False, None
            continue
        for begin, end in _MANAGED:
            if begin in line:
                skipping, end_marker, removed = True, end, removed + 1
                break
        else:
            if line.strip() not in _ENDS:
                out.append(line)
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


def _block(indent, comma, mcp, home, daemon):
    return [
        f"{indent}{BEGIN}",
        f'{indent}"{KEY}": {{',
        f'{indent}  "type": "local",',
        f'{indent}  "command": ["{mcp}"],',
        f'{indent}  "environment": {{',
        f'{indent}    "IMAGEHIVE_HOME": "{home}",',
        f'{indent}    "IMAGEHIVE_DAEMON_BIN": "{daemon}"',
        f"{indent}  }},",
        f'{indent}  "enabled": true',
        f"{indent}}}{comma}",
        f"{indent}{END}",
    ]


def insert(path, mcp, home, daemon):
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

    stale = [span for span in _entries(lines, open_index, close_index) if span[2] in _KEYS]
    if stale:
        lines = _drop_entries(lines, stale)
        close_index = _find_object(lines, "mcp")[1]
        removed += len(stale)

    open_index, close_index = _find_object(lines, "mcp")
    indent = re.match(r"^(\s*)", lines[open_index]).group(1) + "  "
    rest = _entries(lines, open_index, close_index)
    lines[open_index + 1:open_index + 1] = _block(indent, "," if rest else "", mcp, home, daemon)
    open_index, close_index = _find_object(lines, "mcp")
    lines = _normalise_commas(lines, open_index, close_index)

    write_text(path, "\n".join(lines))
    if removed:
        print(f"replaced {removed} previous imagehive entr{'y' if removed == 1 else 'ies'}", file=sys.stderr)


def remove(path):
    if not os.path.exists(path):
        return
    original = open(path).read().split("\n")
    lines, _removed = _strip_managed(original)
    # Compared by content, not by the block count: an orphan end marker is a
    # change worth writing even though no whole block was removed.
    if lines == original:
        return
    write_text(path, "\n".join(lines))


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
    elif action == "has-legacy":
        sys.exit(0 if os.path.exists(path) and LEGACY_BEGIN in open(path).read() else 1)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv)
