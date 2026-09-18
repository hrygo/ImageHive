# Changelog

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
