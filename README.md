# SenseNova-U1.5 local image service

Text-to-image, instruction-based image editing and image understanding for your
own Mac — served to AI agents over MCP. No API key, no per-image cost, no uploads:
the model runs locally on Apple silicon through MLX, and every agent on the
machine shares **one** resident copy of the weights.

```bash
git clone https://github.com/<you>/SenseNovaU1-Service.git
cd SenseNovaU1-Service
./install.sh
```

The installer checks the machine, downloads a ready-to-run model (~11 GiB by
default, ModelScope first — no proxy needed in China), builds, installs a
background service, wires the MCP clients it finds, and runs a smoke test.
Then just ask your agent for a picture.

## What your agent gets

| Tool | What it does |
|---|---|
| `generate_image` | text → image; `tier=fast` for iteration, `tier=quality` for final art or text in the image |
| `edit_image` | instruction editing with one or more reference images, identity preserved |
| `describe_image` | read text out of a rendering, check a result against the brief, compare candidates |
| `model_status` | which weights are resident, how many loads since boot, queue depth, peak memory |
| `unload_model` | give the ~15–35 GB back immediately instead of waiting for the idle timeout |

## Requirements

| | |
|---|---|
| Hardware | Apple silicon (M1 or newer). MLX does not run on Intel Macs. |
| Memory | 18 GB minimum for the 4-bit tier (peaks ~15 GB); 48 GB+ to comfortably run the bf16 tier |
| macOS | 26 or newer (the Swift package targets macOS 26) |
| Disk | ~16 GiB for a fast-tier install, ~48 GiB with both tiers, plus a one-time ~2 GB build tree |
| Toolchain | Xcode 27 (full app, not just the Command Line Tools) — the build needs the Metal toolchain, which Xcode 27 ships as a separate download: `xcodebuild -downloadComponent MetalToolchain` |
| Time | 10–40 min the first time, dominated by the model download and the first build |

Already have the model? `./install.sh --model none --skip-build` skips both.

## Which model tier

Artifacts are the ready-to-run MLX conversions published by the upstream project.
They already contain the tokenizer, so there is no conversion step.

| Preset | Size on disk | Peak memory | 1024² image | Use it for |
|---|---|---|---|---|
| `fast-4bit` (default) | 11 GiB | ~15 GB | ~3 s | drafts, iteration, thumbnails |
| `fast-8bit` | 20 GiB | ~22 GB | ~4 s | same, closer to bf16 output |
| `quality-bf16` | 33 GiB | ~35 GB | ~7 s (50 steps) | final art, text rendering, editing, VQA |

```bash
./install.sh --model fast      # default
./install.sh --model both      # fast + quality
sensenova-u1 models pull quality-bf16    # add a tier later
sensenova-u1 models                      # see what is installed
```

Editing and VQA always use the quality tier; if only `fast-*` is installed they
fall back to it (slower, lower fidelity — `sensenova-u1 doctor` says so).

## Connect your agent

`install.sh` wires every client it recognises. To do it by hand, or to add one later:

```bash
sensenova-u1 clients list          # what is installed / wired
sensenova-u1 clients add codex     # or: claude, opencode, qwenpaw, claude-desktop, cursor
sensenova-u1 clients add auto      # everything detected
sensenova-u1 clients snippet       # paste-able snippet for anything else
```

Clients that ship a `mcp add` command (`codex`, `claude`) are configured through
it; the rest get a marker block written into their config file, after a
timestamped backup, and `clients remove` takes it out again. See
[Docs/CLIENTS.md](Docs/CLIENTS.md) for per-client notes.

## Day-to-day

```bash
sensenova-u1 status      # resident tier, loads, queue, peaks
sensenova-u1 doctor      # check host, install, models, service, clients
sensenova-u1 logs -f     # daemon log
sensenova-u1 unload      # release the weights now
sensenova-u1 generate --prompt "a brass compass on a dark desk" --tier fast
sensenova-u1 restart     # restart the daemon (the weights stay on disk)
```

The daemon starts on demand: the first request after an idle period loads the
weights (~5 s) and they are released again after 10 minutes of idleness
(`ttl_seconds` in `~/Models/SenseNova-U1.5/config.json`). Nothing keeps 35 GB
pinned down unless you are actively using it.

## One model, many agents

```
Codex ─┐
Claude ─┼─► sensenova-mcp (stdio, stateless, no weights)
Cursor ─┘        │
                 └─► unix socket ─► sensenova-served (owns the weights)
                                          └─► one resident model
```

The MCP front end is a thin, stateless bridge; the daemon owns the model and
serialises generations. Adding another client adds a small process, never a
second copy of the weights — the socket bind is the mutex, and concurrent cold
starts share a single load. You can check that claim on your own machine:

```bash
tests/smoke.sh           # three concurrent clients, asserts one load
```

## Configuration

Two files, both optional and both plain JSON/shell:

* `~/Models/SenseNova-U1.5/config.json` — `ttl_seconds`, `min_warm_seconds`,
  `fast_artifact`, `quality_artifact`.
* `~/Models/SenseNova-U1.5/service.conf` — install layout (where the binaries,
  the launchd label and the socket live). Written by `install.sh`;
  `sensenova-u1 config set SENSENOVA_LABEL=...` edits it.

Environment variables (`SENSENOVA_HOME`, `SENSENOVA_TTL_SECONDS`, `SENSENOVA_SOCKET`,
…) override both, which is how the generated client entries point at your install.

## Troubleshooting

Start with `sensenova-u1 doctor`. The usual suspects:

* **`Failed to load the default metallib`** — the MLX resource bundles are missing
  next to the binaries. Re-run `./install.sh` (it copies `*.bundle` alongside).
* **First build fails mentioning Metal** — `xcodebuild -downloadComponent MetalToolchain`.
* **Client shows no tools** — restart the client; MCP servers are loaded per session.
* **Generation is slow after an idle period** — that is the model loading; keep
  `ttl_seconds` higher if you would rather stay warm.

More in [Docs/TROUBLESHOOTING.md](Docs/TROUBLESHOOTING.md).

## Uninstall

```bash
./uninstall.sh                 # service, binaries, client entries; keeps the artifacts
./uninstall.sh --purge-models  # and delete the downloaded models
```

## Development

```bash
make build      # both products
make test       # smoke test against a throwaway daemon
make install    # build + install + restart the service
make release    # tarball with prebuilt binaries for binary-only installs
```

The service is two small Swift executables (`Sources/sensenova-served`,
`Sources/sensenova-mcp`) on top of the upstream
[`sensenova-u1-swift`](https://github.com/xocialize/sensenova-u1-swift) MLX port.
Build, protocol and design notes live in [LOCAL-SERVICE.md](LOCAL-SERVICE.md);
the upstream port's own README (performance tables, CLI, quantization doctrine) is
preserved as [UPSTREAM-README.md](UPSTREAM-README.md).

## Credits and license

* Upstream Swift/MLX port and the published MLX artifacts: **Xocialize**, MIT —
  [sensenova-u1-swift](https://github.com/xocialize/sensenova-u1-swift).
* **SenseNova-U1.5-8B-MoT** weights: SenseTime, Apache-2.0 —
  [sensenova/SenseNova-U1.5-8B-MoT](https://huggingface.co/sensenova/SenseNova-U1.5-8B-MoT).
* The 8-step distillation LoRA: [xocialize/SenseNova-U1.5-8B-MoT-LoRAs](https://huggingface.co/xocialize/SenseNova-U1.5-8B-MoT-LoRAs).
* The service, CLI and installers in this repository: MIT (see [LICENSE](LICENSE)
  and [NOTICE](NOTICE)).
