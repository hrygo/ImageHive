# Connecting MCP clients

Every client points at the same binary and the same two environment variables,
so one install serves all of them:

```
command: ~/.local/share/sensenova-u1/bin/sensenova-mcp
env:     SENSENOVA_HOME=<app home>                 # ~/Library/Application Support/SenseNovaU1
         SENSENOVA_SERVED_BIN=<bin dir>/sensenova-served
         # only when they differ from what the app home implies:
         # SENSENOVA_MODELS=<models root>   SENSENOVA_OUT=<images directory>
```

`sensenova-u1 clients snippet` prints this block with this machine's real paths.

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

## What the tools take

Ask the service instead of guessing: **`model_options`** returns the whole contract
without loading the weights — accepted sizes, the steps/cfg ranges and their per-tier
defaults, the seed rule, which prompt arguments apply to which tool, where the
metadata lands, and which tiers this machine has. `sensenova-u1 options` prints the
same thing in a terminal.

| Tool | Arguments that matter |
|---|---|
| `generate_image` | `prompt`, `negative`, `tier`, `width`/`height`, `steps`, `cfg`, `seed`, `inline_thumbnail` |
| `edit_image` | `prompt`, `images[]`, `tier`, `width`/`height` or `target_pixels`, `steps`, `cfg`, `img_cfg`, `seed` |
| `describe_image` | `prompt`, `images[]`, `think`, `max_tokens`, `tier` |
| `model_options` / `model_status` | none |
| `unload_model` | none |

Things an agent should know before it starts:

* **Sizes are multiples of 32**, 32–4096 px. The latent grid is `size/32`, so anything
  else is refused with the nearest valid value — it used to abort the whole process.
  Recommended: 1024×1024, 1216×832, 1600×896, 896×1600.
* **`seed` makes a run reproducible**: same seed + same artifact + same settings =
  byte-identical PNG. Without it the seed is random and the reply says so
  (`seed_source=random`), which is the difference between a result you can repeat and
  one that merely looks similar.
* **`negative` is for `generate_image` only.** It is the unconditional branch of
  guidance, so it only bites when guidance is on (quality tier, cfg > 1); `edit_image`
  rejects it rather than ignoring it.
* **Every image gets a sidecar** (`<image>.png.json`) with the prompt and its SHA-256,
  the seed, size, steps, cfg, the artifact that ran and the timing. A `--json` run of
  the CLI, or the tool's `structuredContent`, carries the same fields.
* **`model_status` answers while a generation is running**, and reports the live step
  (`current`). Use it to tell "busy" from "stuck".
* **A request cannot be cancelled.** The daemon runs it to completion and writes the
  PNG even if the client disconnects, so a batch that is killed mid-flight leaves
  images behind that have to be accounted for.
