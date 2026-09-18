# Where everything lives

The installer writes to four places, each chosen for what it is. Nothing needs
root, nothing is written into a Homebrew prefix, and every path can be
overridden.

| What | Where | Override |
|---|---|---|
| App data: `config.json`, `service.conf`, `served.sock` | `~/Library/Application Support/SenseNovaU1/` | `SENSENOVA_HOME`, `--home` |
| Model weights (11–66 GB) | `~/Library/Application Support/SenseNovaU1/models/` | `SENSENOVA_MODELS`, `--models` |
| Commands on `PATH` | `~/.local/bin/sensenova-u1` | `SENSENOVA_PREFIX`, `--prefix` |
| Private executables: `sensenova-served`, `sensenova-mcp`, the MLX `*.bundle`s, the CLI's own scripts | `~/.local/share/sensenova-u1/` (binaries in `bin/`) | `SENSENOVA_PREFIX`, `--prefix` |
| Log | `~/Library/Logs/SenseNovaU1/served.log` | — |
| Generated images | `~/Pictures/SenseNovaU1/` | `SENSENOVA_OUT`, `--out` |
| launchd job | `~/Library/LaunchAgents/<label>.plist` | `SENSENOVA_LABEL`, `--label` |

`sensenova-u1 paths` prints all of it for the install on this machine.

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
technically re-creatable, so `~/Library/Caches/SenseNovaU1/models` is a
defensible choice — but a 11.3 GB (4-bit) or 33 GB (bf16) re-download is an
expensive way to discover that macOS reclaimed the cache, so the default is the
non-purgeable location and the cache path stays available as an opt-in:

```bash
./install.sh --models ~/Library/Caches/SenseNovaU1/models
```

This also matches how other local model runners behave on macOS — Ollama keeps
its weights in `~/.ollama/models`, LM Studio in `~/.lmstudio/models`, the
Hugging Face client in `~/.cache/huggingface` — with the difference that those
are per-tool directories rather than one shared `~/Models`.

**Images in `~/Pictures`.** Generated PNGs are user files; Apple's rule that
`~/Library` is for things the user should not have to see argues against hiding
them inside the app's data directory.

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

`sensenova-u1 doctor` reports the old directory for as long as it is there.
Nothing in the new layout depends on it.
