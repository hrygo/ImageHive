#!/usr/bin/env python3
"""Send one raw line to the daemon socket and print the first line of the reply.

    socket_probe.py <socket> <json>            # payload + newline, print the answer
    socket_probe.py --close <socket> <json>    # payload + newline, close immediately
    socket_probe.py --partial <socket> <json>  # payload with no newline, then close

The tests use this to pin the wire contract that the MCP front end hides: one JSON
object per line, an answer for every line (a bare newline included), an error rather
than a silent default when an argument has the wrong JSON type, and no hang when a
client forgets the terminating newline.
"""

import socket
import sys


def send(socket_path: str, payload: str, newline: bool, read_reply: bool) -> int:
    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    connection.settimeout(10)
    connection.connect(socket_path)
    connection.sendall(payload.encode() + (b"\n" if newline else b""))
    if not read_reply:
        connection.close()
        print("(sent, no reply expected)")
        return 0
    buffer = b""
    while b"\n" not in buffer:
        chunk = connection.recv(65536)
        if not chunk:
            connection.close()
            print("(closed, no reply)")
            return 0
        buffer += chunk
    connection.close()
    print(buffer.split(b"\n")[0].decode("utf-8", "replace"))
    return 0


def main(argv: list[str]) -> int:
    mode = "line"
    if argv and argv[0] in ("--close", "--partial"):
        mode = argv[0][2:]
        argv = argv[1:]
    if len(argv) != 2:
        print(__doc__)
        return 2
    # `--close` and `--partial` both end the connection without expecting an answer:
    # the daemon has nothing to reply to. Waiting would only trip the timeout.
    return send(argv[0], argv[1], newline=(mode == "line"), read_reply=(mode == "line"))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
