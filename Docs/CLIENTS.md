# Connecting MCP clients

Every client points at the same binary and the same two environment variables,
so one install serves all of them:

```
command: <home>/bin/sensenova-mcp
env:     SENSENOVA_HOME=<home>
         SENSENOVA_SERVED_BIN=<home>/bin/sensenova-served
```

`install.sh` wires the clients it detects. Later:

```bash
sensenova-u1 clients list
sensenova-u1 clients add codex|claude|opencode|qwenpaw|claude-desktop|cursor|auto
sensenova-u1 clients remove codex
sensenova-u1 clients snippet        # for anything not listed here
```

## How each client is wired

| Client | Detected by | Wired through | Notes |
|---|---|---|---|
| Codex | `codex` on PATH | `codex mcp add` | writes `~/.codex/config.toml`; `codex mcp list` shows it |
| Claude Code | `claude` on PATH | `claude mcp add -s user` | user scope, so it applies to every project |
| opencode | `opencode` on PATH or existing config | marker block in `~/.config/opencode/opencode.jsonc` | see below |
| QwenPaw | `~/.qwenpaw/config.json` | JSON merge at `mcp.clients.sensenova_image` | `qwenpaw daemon reload-config` applies it |
| Claude Desktop | `~/Library/Application Support/Claude` | JSON merge at `mcpServers.sensenova` | restart the app |
| Cursor | `~/.cursor` | JSON merge at `mcpServers.sensenova` | reload the window |
| anything else | — | `clients snippet` | paste into its MCP config |

## opencode and comments

opencode's config is JSONC and people keep comments in it, so the wiring is a
line-level insert instead of a JSON round-trip — a round-trip would silently
delete every comment in the file. The block is fenced:

```jsonc
  "mcp": {
    // sensenova-u1:begin (managed by `sensenova-u1 clients`)
    "sensenova": { ... },
    // sensenova-u1:end
    "existing-server": { ... }
  },
```

`clients remove opencode` deletes exactly those lines. Every config edit is made
after a timestamped backup (`*.bak-YYYYMMDD-HHMMSS`), and the backup path is
printed.

## After wiring

MCP servers are launched per session: restart the client (or open a new session)
before expecting the tools to show up.

Verify from the client side:

```bash
codex mcp list | grep sensenova
opencode mcp list | grep sensenova
claude mcp list | grep sensenova
```

and from the service side:

```bash
sensenova-u1 status
```

## Project-scoped clients

VS Code (`.vscode/mcp.json`), Zed and similar tools want a per-project config.
Use `sensenova-u1 clients snippet` and drop the block into the project file —
the installer deliberately does not touch files inside your repositories.
