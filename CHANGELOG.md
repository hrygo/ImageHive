# Changelog

## 0.2.0 — 2026-09-18

**Install layout follows platform conventions** (rationale and sources in
[Docs/LAYOUT.md](Docs/LAYOUT.md)):

* App data — `config.json`, `service.conf`, `served.sock` — and the weights move
  to `~/Library/Application Support/SenseNovaU1/` (weights in `models/`), and
  generated images to `~/Pictures/SenseNovaU1/`.
* Executables move out of the data directory into `~/.local/share/sensenova-u1/`,
  with the command at `~/.local/bin/sensenova-u1` (XDG).
* `install.sh` migrates a pre-0.2 install automatically: it moves the artifacts,
  the raw checkpoint and the images, rewrites `config.json`, and leaves small
  wrappers in the old directory so client entries written earlier keep working —
  all of them still on one socket, so still one copy of the weights.
* New settings `SENSENOVA_MODELS` (`--models`) and `SENSENOVA_OUT` (`--out`),
  plus `--legacy-home` for unusual old layouts; environment still beats
  `service.conf`.
* Both executables now honour `$HOME` before the passwd entry, so a sandboxed
  `HOME` no longer reaches back into the real user's app home.
* New documentation: [AGENTS.md](AGENTS.md) for agents changing this repo and
  [Docs/LAYOUT.md](Docs/LAYOUT.md) for the layout decision.

## 0.1.0 — 2026-09-18

First shareable release of the local image service.

* `sensenova-served` — resident daemon: owns the model, serialises generations,
  unloads after an idle TTL, single-instance by socket bind, single-flight loads.
* `sensenova-mcp` — stateless stdio MCP front end with five tools
  (`generate_image`, `edit_image`, `describe_image`, `model_status`, `unload_model`),
  speaking both protocol eras (legacy `initialize` and 2026-07-28 `server/discover`).
* `install.sh` / `uninstall.sh` — preflight, artifact download (ModelScope first,
  Hugging Face and hf-mirror fallback), build, install, LaunchAgent, client wiring,
  smoke test; re-runnable and reversible.
* `sensenova-u1` — management CLI: `status`, `doctor`, `models`, `clients`,
  `start/stop/restart`, `logs`, `unload`, `generate`, `config`, `paths`.
* Client adapters: Codex, Claude Code, opencode, QwenPaw, Claude Desktop, Cursor,
  plus a generic snippet.
* Configuration moved into `$SENSENOVA_HOME/config.json` (tier paths, TTLs) and
  `$SENSENOVA_HOME/service.conf` (install layout); environment variables still win.
