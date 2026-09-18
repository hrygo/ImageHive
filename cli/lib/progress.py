#!/usr/bin/env python3
"""Draw the running job's step progress on stderr, until killed.

Started by `imagehive generate` only when stderr is a terminal. The request itself
is one blocking call with no cancel, so the daemon's own counter (`status` →
`current`) is the only live signal — and unlike everything else it answers while the
model is busy, which is exactly when someone is wondering whether anything is
happening.

    progress.py <socket-path>
"""
import json
import socket
import sys
import time


def status(sock):
    client = socket.socket(socket.AF_UNIX)
    try:
        client.settimeout(2)
        client.connect(sock)
        client.sendall(b'{"cmd":"status"}\n')
        buffer = b""
        while b"\n" not in buffer:
            chunk = client.recv(65536)
            if not chunk:
                break
            buffer += chunk
    finally:
        client.close()
    return json.loads(buffer.split(b"\n")[0])["status"]


def main():
    sock = sys.argv[1]
    last = None
    while True:
        try:
            current = status(sock).get("current")
        except Exception:
            current = None
        if current and current.get("total"):
            stamp = (current["step"], current["total"])
            if stamp != last:
                last = stamp
                sys.stderr.write("\r  %s %d/%d — %d%%, %.0fs%s" % (
                    current.get("tool", "job"), current["step"], current["total"],
                    current.get("percent", 0), current.get("elapsed_seconds", 0),
                    " " * 8))
                sys.stderr.flush()
        time.sleep(1)


if __name__ == "__main__":
    main()
