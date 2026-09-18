# SenseNova-U1.5 local image service

> [中文文档](README.zh-CN.md) · Chinese guide: [README.zh-CN.md](README.zh-CN.md),
> [Docs/DISTRIBUTING.zh-CN.md](Docs/DISTRIBUTING.zh-CN.md). English is the
> authoritative version.
>
> Versioning: this fork numbers its own releases (`SV_VERSION` in
> `cli/lib/common.sh`); the upstream commit it is based on is recorded in
> `BUILD-INFO.txt` inside each release archive, and the two numbering schemes are
> independent.

Text-to-image, instruction-based image editing and image understanding for your
own Mac — served to AI agents over MCP. No API key, no per-image cost, no uploads:
the model runs locally on Apple silicon through MLX, and every agent on the
machine shares **one** resident copy of the weights.

## Quick start

**From a release tarball** — no Xcode, no compiler, nothing to build. The stable
asset name keeps this one-liner valid across releases:

```bash
base=https://github.com/hrygo/SenseNovaU1-Service/releases/latest/download
curl -fsSLO "$base/sensenova-u1-macos-arm64.tar.gz"
curl -fsSLO "$base/sensenova-u1-macos-arm64.tar.gz.sha256"
shasum -a 256 -c sensenova-u1-macos-arm64.tar.gz.sha256
tar -xzf sensenova-u1-macos-arm64.tar.gz && cd sensenova-u1-*
bash install.sh          # `bash`, not `./install.sh` — see Docs/DISTRIBUTING.md
```

**From source** — for working on the service itself; needs Xcode 27 with the
Metal toolchain (see Requirements):

```bash
git clone https://github.com/hrygo/SenseNovaU1-Service.git
cd SenseNovaU1-Service
./install.sh
```

Either way the installer checks the machine, downloads a ready-to-run model
(~11 GiB by default, ModelScope first — no proxy needed in China), installs a
background service, wires the MCP clients it finds, and runs a smoke test. Then
restart your agent and ask it for a picture. Handing this to someone else, or
cutting a release: [Docs/DISTRIBUTING.md](Docs/DISTRIBUTING.md).

## Where it installs

Everything is per-user; nothing needs `sudo` and nothing is written into a
Homebrew prefix.

| | |
|---|---|
| Command | `~/.local/bin/sensenova-u1` |
| Binaries, MLX bundles, CLI internals | `~/.local/share/sensenova-u1/` |
| Weights (~11–33 GB) | `~/Library/Application Support/SenseNovaU1/models/` |
| Config, socket, service definition | `~/Library/Application Support/SenseNovaU1/` |
| Log | `~/Library/Logs/SenseNovaU1/served.log` |
| Generated images | `~/Pictures/SenseNovaU1/` |

`sensenova-u1 paths` prints them; `--home`, `--models`, `--out`, `--prefix` and
`--label` (or the matching `SENSENOVA_*` variables) move any of them. The
reasoning, and the exact rules each choice follows, is in
[Docs/LAYOUT.md](Docs/LAYOUT.md).

## What your agent gets

| Tool | What it does |
|---|---|
| `generate_image` | text → image; `tier=fast` for iteration, `tier=quality` for final art or text in the image. Takes a `seed` (reproducible), a `negative` prompt, and `steps`/`cfg` overrides |
| `edit_image` | instruction editing with one or more reference images, identity preserved |
| `describe_image` | read text out of a rendering, check a result against the brief, compare candidates |
| `model_options` | what this service accepts, before anything is asked of it: sizes, steps/cfg ranges and defaults, the seed rule, that `negative` applies to generate but not edit, where sidecars land, which tiers are installed |
| `model_status` | which weights are resident, how many loads since boot, queue depth, peak memory — plus the live step of the job in flight. Answers immediately even while a generation runs |
| `unload_model` | give the ~15–35 GB back immediately instead of waiting for the idle timeout |

## Requirements

| | |
|---|---|
| Hardware | Apple silicon (M1 or newer). MLX does not run on Intel Macs. |
| Memory | 18 GB minimum for the 4-bit tier (peaks ~15 GB); 48 GB+ to comfortably run the bf16 tier |
| macOS | 26 or newer (the Swift package targets macOS 26) |
| Disk | ~16 GiB for a fast-tier install, ~48 GiB with both tiers, plus a one-time ~2 GB build tree |
| python3 | Required. macOS ships it with the Command Line Tools (`xcode-select --install`, ~1.5 GB) or via `brew install python`. The installer stops early and says so if it is missing. |
| Toolchain | Only when building from source: Xcode 27 (full app, not just the Command Line Tools) — the build needs the Metal toolchain, which Xcode 27 ships as a separate download: `xcodebuild -downloadComponent MetalToolchain`. A release tarball needs none of this. |
| Time | 10–40 min the first time, dominated by the model download and the first build |

Already have the model? `./install.sh --model none --skip-build` skips both.
Downloads print progress and resume: interrupting a 33 GiB pull and re-running it
costs only the missing files.

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

Editing and VQA run on the quality artifact; `generate_image` is the only tool
where the two tiers differ.

### One artifact is enough

Installing both artifacts is optional. `tier` is a preference, not a
requirement: when the artifact it names is not installed, the daemon serves the
request from the one that is and says so in the reply —

```
Wrote ~/Pictures/SenseNovaU1/20260918T065356Z-t2i-seed610959.png
      [512x512, tier quality, asked for fast, not installed, 50 steps, 14.9s, seed 610959]
```

The recipe follows the artifact that runs, never the request: 8 steps at cfg 1.0
belong to the distilled weights and 50 steps at cfg 4.0 to the bf16 weights, so a
fallback can never drive one artifact with the other's settings. `model_status`
reports `available_tiers`, and `sensenova-u1 doctor` reports a missing artifact as
a note rather than a failure — a one-artifact machine is a supported setup.

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
sensenova-u1 options     # what sizes, steps, cfg and seeds are accepted
sensenova-u1 restart     # restart the daemon (the weights stay on disk)
```

### Comparing two runs, or two models

`--seed` pins the noise, and every image is written with a sidecar recording what
produced it — that is what turns "I think I used the same prompt" into something you
can check afterwards:

```bash
sensenova-u1 generate --prompt "a brass compass" --seed 42 --width 1216 --height 832
# Wrote ~/Pictures/SenseNovaU1/20260918T083207Z-t2i-seed42.png [1216x832, tier quality,
#       50 steps, 51.3s, seed 42] + 20260918T083207Z-t2i-seed42.png.json
sensenova-u1 generate --prompt "a brass compass" --seed 42 --n 4 --out ~/eval/run1 --json
```

Same seed + same artifact + same settings writes **byte-identical** bytes (measured:
two 512×512 runs at 6 steps produced the same SHA-256). The sidecar beside each PNG
carries the prompt verbatim and its SHA-256, the negative prompt, the seed and whether
it was pinned, size, steps, cfg, the artifact that ran, wall time and peak memory.
`--json` prints the same facts as a machine-readable object (an array when `--n > 1`),
and `--out` moves the image and its sidecar together.

One thing to know before a batch run: **a dispatched request cannot be cancelled.**
Killing the command does not stop the generation and its PNG still lands — see
[Docs/TROUBLESHOOTING.md](Docs/TROUBLESHOOTING.md).

The daemon starts on demand: the first request after an idle period loads the
weights (~5 s) and they are released again after 10 minutes of idleness
(`ttl_seconds` in `~/Library/Application Support/SenseNovaU1/config.json`). Nothing keeps 35 GB
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

* `~/Library/Application Support/SenseNovaU1/config.json` — `ttl_seconds`,
  `min_warm_seconds`, `fast_artifact`, `quality_artifact` (names are relative to
  the models root unless absolute).
* `~/Library/Application Support/SenseNovaU1/service.conf` — install layout
  (home, models, prefix, launchd label, socket). Written by `install.sh`;
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

Before changing anything, read [AGENTS.md](AGENTS.md): it lists the invariants
the service depends on, how to test an installer without touching your real
install, and which document to update for which change. Install locations and
their rationale: [Docs/LAYOUT.md](Docs/LAYOUT.md).

## Credits and license

* Upstream Swift/MLX port and the published MLX artifacts: **Xocialize**, MIT —
  [sensenova-u1-swift](https://github.com/xocialize/sensenova-u1-swift).
* **SenseNova-U1.5-8B-MoT** weights: SenseTime, Apache-2.0 —
  [sensenova/SenseNova-U1.5-8B-MoT](https://huggingface.co/sensenova/SenseNova-U1.5-8B-MoT).
* The 8-step distillation LoRA: [xocialize/SenseNova-U1.5-8B-MoT-LoRAs](https://huggingface.co/xocialize/SenseNova-U1.5-8B-MoT-LoRAs).
* The service, CLI and installers in this repository: MIT (see [LICENSE](LICENSE)
  and [NOTICE](NOTICE)).
