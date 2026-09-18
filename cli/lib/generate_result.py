#!/usr/bin/env python3
"""Read one generate_image answer and print it — a path, a line, or the raw object.

The daemon's reply is the source of truth; the only thing rewritten here is the image
path, because the caller may have moved the file with --out after it was written.

    generate_result.py path <answer>            PNG path (exit 1 if the call failed)
    generate_result.py text <answer> [path]     the one-line summary, path replaced
    generate_result.py json <answer> [path]     the structured result, one JSON object

Exit codes: 1 = the service reported an error (its message is on stderr), 2 = no
usable answer at all, which usually means the service is not installed.
"""
import json
import sys


def result_of(path):
    try:
        raw = open(path).read()
    except OSError:
        print("could not read the service's answer", file=sys.stderr)
        sys.exit(2)
    for line in raw.splitlines():
        if not line.strip():
            continue
        try:
            envelope = json.loads(line)
        except ValueError:
            continue
        if isinstance(envelope, dict) and "result" in envelope:
            return envelope["result"]
    print("no answer from the local image service — is it installed? (sensenova-u1 doctor)",
          file=sys.stderr)
    sys.exit(2)


def main():
    mode, answer = sys.argv[1], sys.argv[2]
    result = result_of(answer)
    if result.get("isError"):
        blocks = result.get("content") or [{}]
        print(blocks[0].get("text", "the request failed"), file=sys.stderr)
        sys.exit(1)

    structured = result.get("structuredContent") or {}
    if mode == "path":
        path = structured.get("path")
        if not path:
            print("the service answered without a path", file=sys.stderr)
            sys.exit(2)
        print(path)
        return

    moved = sys.argv[3] if len(sys.argv) > 3 else None
    if mode == "json":
        if moved and moved != structured.get("path"):
            structured["path_moved_from"] = structured.get("path")
            if structured.get("metadata"):
                structured["metadata"] = moved + ".json"
            structured["path"] = moved
        # Sorted keys: the point of --json is that a script (or a diff between two
        # runs) sees the same thing twice.
        print(json.dumps(structured, ensure_ascii=False, sort_keys=True))
        return

    line = ((result.get("content") or [{}])[0]).get("text", "")
    if moved and structured.get("path"):
        line = line.replace(structured["path"], moved)
    print(line)


if __name__ == "__main__":
    main()
