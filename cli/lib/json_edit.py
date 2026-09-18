#!/usr/bin/env python3
"""Minimal, order-preserving JSON edits used by `sensenova-u1 clients`.

Usage:
  json_edit.py set   <file> <dotted.path> <command> [ENV=value ...]
  json_edit.py set-client <file> <dotted.path> <flavor> <command> [ENV=value ...]
  json_edit.py unset <file> <dotted.path>
  json_edit.py has   <file> <dotted.path>

The file is created when missing, and the parent objects are created as needed.
Keys keep their original order; two-space indent, no ASCII escaping, trailing
newline — the shape every MCP client writes.
"""

import json
import os
import sys


def client_entry(flavor, command, env):
    """The entry shape each client expects. Keep them here, not in shell."""
    if flavor == "qwenpaw":
        return {
            "name": "sensenova_u1",
            "description": "Local SenseNova-U1.5 images: generate, edit, describe (one shared resident model)",
            "enabled": True,
            "transport": "stdio",
            "url": "",
            "headers": {},
            "command": command,
            "args": [],
            "env": env,
            "cwd": "",
            "http_timeout": None,
            "tools": None,
            "oauth": None,
        }
    return {"command": command, "env": env}


def load(path):
    if not os.path.exists(path) or os.path.getsize(path) == 0:
        return {}
    with open(path) as handle:
        return json.load(handle)


def store(path, data):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "w") as handle:
        json.dump(data, handle, indent=2, ensure_ascii=False)
        handle.write("\n")


def walk(data, path, create):
    node, parts = data, path.split(".")
    for key in parts[:-1]:
        if create:
            nxt = node.get(key)
            if not isinstance(nxt, dict):
                nxt = {}
                node[key] = nxt
            node = nxt
        else:
            node = node.get(key)
            if not isinstance(node, dict):
                return None, parts[-1]
    return node, parts[-1]


def main(argv):
    if len(argv) < 4:
        sys.exit(__doc__)
    action, path, target = argv[1], argv[2], argv[3]

    if action == "set":
        command, pairs = argv[4], argv[5:]
        data = load(path)
        node, key = walk(data, target, create=True)
        node[key] = client_entry("generic", command, dict(p.split("=", 1) for p in pairs))
        store(path, data)
    elif action == "set-client":
        flavor, command, pairs = argv[4], argv[5], argv[6:]
        data = load(path)
        node, key = walk(data, target, create=True)
        node[key] = client_entry(flavor, command, dict(p.split("=", 1) for p in pairs))
        store(path, data)
    elif action == "unset":
        if not os.path.exists(path):
            return
        data = load(path)
        node, key = walk(data, target, create=False)
        if node is not None:
            node.pop(key, None)
            store(path, data)
    elif action == "has":
        data = load(path)
        node, key = walk(data, target, create=False)
        sys.exit(0 if node is not None and key in node else 1)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv)
