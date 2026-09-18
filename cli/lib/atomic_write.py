"""Replace a file's contents without ever leaving it half-written.

The files the client wiring edits — `opencode.json`, `mcp.json`, an editor's own
config — are the *user's* settings, and the copy on disk is the only one there is.
`open(path, "w").write(text)` truncates first and writes second, so a crash, a full
disk or a Ctrl-C in between leaves a truncated file and the editor silently loses its
settings (or refuses to start). Measured 2026-09-19 while auditing this path: the
project's own editors were the only place left writing user data non-atomically.

Write a sibling temporary file, flush it to the platter, copy the original's mode
across, then rename over the original. `os.replace` is atomic within a filesystem, so
a reader sees the old file or the new one — never a fragment of either.
"""

import os
import tempfile


def write_text(path, text):
    directory = os.path.dirname(path) or "."
    try:
        mode = os.stat(path).st_mode & 0o7777
    except FileNotFoundError:
        mode = None
    handle, temporary = tempfile.mkstemp(dir=directory, prefix=".imagehive-", suffix=".tmp")
    try:
        with os.fdopen(handle, "w") as stream:
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        if mode is not None:
            os.chmod(temporary, mode)
        os.replace(temporary, path)
    except BaseException:
        # Never leave our scratch file behind for the editor to trip over.
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise
