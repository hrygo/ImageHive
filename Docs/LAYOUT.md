# Where everything lives

The installer writes to four places, each chosen for what it is. Nothing needs
root, nothing is written into a Homebrew prefix, and every path can be
overridden.

| What | Where | Override |
|---|---|---|
| App data: `config.json`, `service.conf`, `imagehived.sock` | `~/Library/Application Support/ImageHive/` | `IMAGEHIVE_HOME`, `--home` |
| Model weights (11–66 GB) | `~/Library/Application Support/ImageHive/models/` | `IMAGEHIVE_MODELS`, `--models` |
| Commands on `PATH` | `~/.local/bin/imagehive` | `IMAGEHIVE_PREFIX`, `--prefix` |
| Private executables: `imagehived`, `imagehive-mcp`, the MLX `*.bundle`s, the CLI's own scripts | `~/.local/share/imagehive/` (binaries in `bin/`) | `IMAGEHIVE_PREFIX`, `--prefix` |
| Log | `~/Library/Logs/ImageHive/imagehived.log` | — |
| Generated images, each with its `<name>.png.json` sidecar | `~/Pictures/ImageHive/` | `IMAGEHIVE_OUT`, `--out` |
| launchd job | `~/Library/LaunchAgents/<label>.plist` | `IMAGEHIVE_LABEL`, `--label` |

`imagehive paths` prints all of it for the install on this machine.

## Why these

**Executables under `~/.local`.** The XDG Base Directory specification reserves
`$HOME/.local/bin` for user-specific executables and `$XDG_DATA_HOME`
(`~/.local/share`) for a tool's private files. `~/.local/bin` is already on
`PATH` for most macOS setups and is what `pipx`, `uv tool`, `cargo install` and
friends use. Homebrew's prefix (`/opt/homebrew` on Apple silicon) exists too,
but it belongs to Homebrew: a third-party installer writing there is what
`brew doctor` complains about.

**Weights under `~/Library/Application Support`.** Apple designates
`~/Library` for "files that are not user data files", with Application Support
for app-managed data and Caches for data that can be recreated. Weights are
technically re-creatable, so `~/Library/Caches/ImageHive/models` is a
defensible choice — but a 11.3 GB (4-bit) or 33 GB (bf16) re-download is an
expensive way to discover that macOS reclaimed the cache, so the default is the
non-purgeable location and the cache path stays available as an opt-in:

```bash
./install.sh --models ~/Library/Caches/ImageHive/models
```

This also matches how other local model runners behave on macOS — Ollama keeps
its weights in `~/.ollama/models`, LM Studio in `~/.lmstudio/models`, the
Hugging Face client in `~/.cache/huggingface` — with the difference that those
are per-tool directories rather than one shared `~/Models`.

**Images in `~/Pictures`.** Generated PNGs are user files; Apple's rule that
`~/Library` is for things the user should not have to see argues against hiding
them inside the app's data directory.

**A sidecar next to each image.** Every generation also writes
`<name>.png.json` — the prompt and its SHA-256, the negative prompt, the seed and
whether it was pinned or random, size, steps, cfg, the tier and artifact that
ran, the seconds and peak memory, the project version. It is the same payload a
`--json` CLI run or `structuredContent` returns, kept beside the PNG so a result
is still self-describing after the terminal that produced it is gone. It is a
plain file in the same directory, moved or copied with the image
(`--out` moves both), and it can be turned off with `write_sidecar: false` in
`config.json` or `IMAGEHIVE_SIDECAR=0`; an agent that wants a clean directory can
also delete them, at the cost of no longer being able to prove how an image was
made.

**No root, no daemon-owned system paths.** Everything is per-user, so
uninstalling never needs `sudo` and cannot break another user's install.

Sources, checked 2026-09-18:

* XDG Base Directory Specification — `$XDG_DATA_HOME`, `$XDG_CACHE_HOME`,
  `$HOME/.local/bin`: <https://specifications.freedesktop.org/basedir-spec/latest/>
* Apple, *File System Programming Guide* — "Library ... for any files that are
  not user data files", Application Support vs Caches, "the contents of the
  Library directory (with the exception of the Caches subdirectory) are backed
  up":
  <https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/FileSystemOverview/FileSystemOverview.html>
* Hugging Face Hub environment variables — `HF_HOME` defaults to
  `~/.cache/huggingface`: <https://huggingface.co/docs/huggingface_hub/package_reference/environment_variables>
* Ollama FAQ — macOS models in `~/.ollama/models`, `OLLAMA_MODELS` to move
  them: <https://docs.ollama.com/faq>
* Homebrew FAQ — why the prefix is `/opt/homebrew` on Apple silicon:
  <https://docs.brew.sh/FAQ>

## What is deliberately *not* here

* **No weights in the repository.** `install.sh` downloads them; the repo only
  holds code. `.gitignore` also keeps `dist/`, `prebuilt/` and build trees out.
* **No runtime state in the repo.** The socket, logs, images and config all live
  under the user's home, never in the checkout.
* **No `sudo`, no `/Library`, no `/usr/local`.** A user-level install must not
  need elevated rights, and must not shadow another tool's files.
* **No single shared `~/Models` root.** That is what the pre-0.2 layout did; it
  mixes app data, executables and images in one directory and makes it unclear
  which tool owns what.

## Upgrading from the old layout

Versions before 0.2 put everything in `~/Models/SenseNova-U1.5` (weights in
`artifacts/`, binaries in `bin/`, config at the top level). `install.sh` detects
that directory and:

1. moves the artifacts, the raw checkpoint under `src/` and any generated images
   to their new homes (a same-volume `mv`, so it is instant);
2. rewrites `config.json` so the tier names are relative to the new models root;
3. replaces `~/Models/SenseNova-U1.5/bin/*` with two tiny wrappers that export
   the new paths and exec the real binaries, because MCP client configs and
   already-running sessions still point there. The wrappers keep every session
   on the same socket, so the "one copy of the weights" guarantee holds across
   the upgrade;
4. leaves the rest of the old directory alone.

Once the MCP clients have been restarted, the old directory is dead weight:

```bash
rm -rf ~/Models/SenseNova-U1.5      # only after the clients restart
```

`imagehive doctor` reports the old directory for as long as it is there.

## Upgrading from the old name (0.6)

Up to 0.5.2 this project was called `sensenova-u1` and every path carried that
name. 0.6 renamed all of it, so an install from the old name has state in places
the current defaults never look:

| Old (≤ 0.5.2) | New (0.6) |
|---|---|
| `~/Library/Application Support/SenseNovaU1/` | `~/Library/Application Support/ImageHive/` |
| `~/Pictures/SenseNovaU1/` | `~/Pictures/ImageHive/` |
| `~/Library/Logs/SenseNovaU1/served.log` | `~/Library/Logs/ImageHive/imagehived.log` |
| `~/.local/share/sensenova-u1/` | `~/.local/share/imagehive/` |
| `~/.local/bin/sensenova-u1` | `~/.local/bin/imagehive` |
| launchd label `local.sensenova-u1` | `local.imagehive` (a `--label` of your own is renamed, not replaced: `com.hrygo.sensenova-u1` → `com.hrygo.imagehive`) |
| `served.sock` | `imagehived.sock` |
| `SENSENOVA_*` environment variables | `IMAGEHIVE_*` |

`install.sh` migrates the default locations, in this order:

1. **stops the old daemon, then clears its socket file.** This is first on
   purpose. That daemon holds a second copy of the weights, and moving the app
   home would move its socket file with it — the new daemon would then probe the
   new path, get an answer, and exit 3 without binding, so a machine would look
   upgraded while every reply still came from the old build;
2. boots out the old LaunchAgent and deletes its plist, which would otherwise
   start the old daemon again at the next login. The job is found by its content —
   the plist says which binary it starts — because the label is user-settable. If
   the label carries a brand token, it is *renamed* rather than replaced, so a
   `--label com.hrygo.sensenova-u1` install ends up with `com.hrygo.imagehive` and
   keeps its own prefix; an explicit `--label` on the command line wins over that;
3. moves the app home, the image directory and the log directory onto the new
   names (same-volume `mv`: instant, no copying of 11–66 GB);
4. leaves the old *command* working but harmless: `~/.local/share/sensenova-u1/bin/*`
   become wrappers onto the new binaries — old MCP client entries point straight
   at those paths — while the old script and its libraries are removed, because
   their defaults resolve the pre-0.6 home and would start a service of their own;
5. removes the old `sensenova` MCP entries from the clients it knows about. Two
   entries expose the same six tools, and a client that keeps both shows every
   tool twice.

Paths chosen with `--home`, `--models`, `--out` or `--prefix` are not touched:
there is nothing at the old defaults to find, and moving a directory the user
chose is worse than printing where things are. `imagehive doctor` reports the old
app home, an old daemon still running, and any client left with the old entry.

The old app home and the old image directory are never deleted for you — one is
11–66 GB of artifacts, the other is the user's own pictures. Delete them once
`imagehive doctor` is clean:

```bash
rm -rf "$HOME/Library/Application Support/SenseNovaU1" ~/Pictures/SenseNovaU1
```
Nothing in the new layout depends on it.
