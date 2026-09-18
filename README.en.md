# imagehive

**The resident local image service for your Mac: one copy of the weights, shared
by every agent.** The model is
[SenseNova-U1.5-8B-MoT](https://huggingface.co/sensenova/SenseNova-U1.5-8B-MoT),
run through the upstream Swift/MLX port.

[![ci](https://github.com/hrygo/ImageHive/actions/workflows/ci.yml/badge.svg)](https://github.com/hrygo/ImageHive/actions/workflows/ci.yml)
[![latest release](https://img.shields.io/github/v/release/hrygo/ImageHive)](https://github.com/hrygo/ImageHive/releases/latest)
[![license: MIT](https://img.shields.io/github/license/hrygo/ImageHive)](LICENSE)
[![platform: macOS 26+ · Apple silicon](https://img.shields.io/badge/platform-macOS%2026%2B%20%C2%B7%20arm64-black)](#requirements)

Text-to-image, instruction-based image editing and image understanding for your
own Mac — served to AI agents over MCP. No API key, no per-image cost, no
uploads: the model runs locally on Apple silicon through MLX, and every agent on
the machine shares **one** resident copy of the weights.

> **中文版为准.** The authoritative documentation is the Chinese
> [README.md](README.md), with [Docs/DISTRIBUTING.zh-CN.md](Docs/DISTRIBUTING.zh-CN.md);
> this file is its English mirror.
>
> **Name.** It is `imagehive`, not `sensenova-u1`. The model name belongs to
> SenseTime — carrying it here reads like an official product and ties the
> repository to one model generation. The name describes the thing itself: a
> resident local image service. Releases up to 0.5.2 were called `sensenova-u1`;
> the installer migrates such an install, see
> [Upgrading from an older version](#upgrading-from-an-older-version).
>
> **Versioning.** This repository numbers its own releases (`IH_VERSION` in
> `cli/lib/common.sh`) and continues upstream's tag sequence, so the first public
> release is `0.5.0` and the current one is `0.6.0`. The upstream commit a build is based on is recorded in
> `BUILD-INFO.txt` inside each release archive; the two numbering schemes are
> independent.

## At a glance

* **One resident copy of the weights per machine.** The unix socket bind is the
  process mutex, the load is single-flight, and at most one tier is in memory —
  so ten clients cost ten small stdio processes, never a second 11–33 GB copy.
* **Six MCP tools** — generate, edit, describe, ask what the service accepts,
  read its status, release memory: see [what your agent gets](#what-your-agent-gets).
* **Runs are reproducible and self-describing.** `--seed` pins the noise, and
  every image lands with a sidecar recording the prompt, its SHA-256, the seed
  and whether it was pinned, the artifact that ran, size, steps, cfg, wall time
  and peak memory. Same seed + same artifact + same settings writes
  byte-identical bytes (measured).
* **One artifact is enough.** Requesting a tier that is not installed is a
  preference, not an error: the request is served from the installed artifact, at
  that artifact's own recipe, and the reply says so.
* **Nothing runs as root, nothing listens on a port.** A per-user install, a unix
  socket in the app home, weights downloaded from their publishers and never
  redistributed by this repository.

## Contents

* [Quick start](#quick-start)
* [Requirements](#requirements)
* [Model tiers](#model-tiers)
* [Where it installs](#where-it-installs)
* [Upgrading from an older version](#upgrading-from-an-older-version)
* [Connect your agent](#connect-your-agent)
* [What your agent gets](#what-your-agent-gets)
* [Day to day](#day-to-day)
* [Reproducible runs](#reproducible-runs)
* [Configuration](#configuration)
* [Troubleshooting and help](#troubleshooting-and-help)
* [Known limitations](#known-limitations)
* [Uninstall](#uninstall)
* [Contributing](#contributing)
* [Documentation](#documentation)
* [Credits and license](#credits-and-license)

## Quick start

**From a release tarball** — no Xcode, no compiler, nothing to build. The stable
asset name keeps this one-liner valid across releases:

```bash
base=https://github.com/hrygo/ImageHive/releases/latest/download
curl -fsSLO "$base/imagehive-macos-arm64.tar.gz"
curl -fsSLO "$base/imagehive-macos-arm64.tar.gz.sha256"
shasum -a 256 -c imagehive-macos-arm64.tar.gz.sha256
tar -xzf imagehive-macos-arm64.tar.gz && cd imagehive-*
bash install.sh          # `bash`, not `./install.sh` — see Docs/DISTRIBUTING.md
```

**From source** — for working on the service itself; needs Xcode 27 with the
Metal toolchain (see [Requirements](#requirements)):

```bash
git clone https://github.com/hrygo/ImageHive.git
cd ImageHive
./install.sh
```

Either way the installer checks the machine, downloads a ready-to-run model
(~11 GiB by default, ModelScope first — no proxy needed in China), installs a
background service, wires the MCP clients it finds, and runs a smoke test. Then
restart your agent and ask it for a picture. Handing this to someone else, or
cutting a release: [Docs/DISTRIBUTING.md](Docs/DISTRIBUTING.md).

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

## Model tiers

Artifacts are the ready-to-run MLX conversions published by the upstream
project. They already contain the tokenizer, so there is no conversion step.

| Preset | Size on disk | Peak memory | 1024² image | Use it for |
|---|---|---|---|---|
| `fast-4bit` (default) | 11 GiB | ~15 GB | ~3 s | drafts, iteration, thumbnails |
| `fast-8bit` | 20 GiB | ~22 GB | ~4 s | same, closer to bf16 output |
| `quality-bf16` | 33 GiB | ~35 GB | ~50 s (50 steps) | final art, text rendering, editing, VQA |

```bash
./install.sh --model fast      # default
./install.sh --model both      # fast + quality
imagehive models pull quality-bf16    # add a tier later
imagehive models                      # see what is installed
```

Editing and VQA run on the quality artifact; `generate_image` is the only tool
where the two tiers differ.

### One artifact is enough

Installing both artifacts is optional. `tier` is a preference, not a requirement:
when the artifact it names is not installed, the daemon serves the request from
the one that is and says so in the reply —

```
Wrote ~/Pictures/ImageHive/20260918T065356Z-t2i-seed610959.png
      [512x512, tier quality, asked for fast, not installed, 50 steps, 14.9s, seed 610959]
```

The recipe follows the artifact that runs, never the request: 8 steps at cfg 1.0
belong to the distilled weights and 50 steps at cfg 4.0 to the bf16 weights, so a
fallback can never drive one artifact with the other's settings. `model_status`
reports `available_tiers`, and `imagehive doctor` reports a missing artifact as
a note rather than a failure — a one-artifact machine is a supported setup.

## Where it installs

Everything is per-user; nothing needs `sudo` and nothing is written into a
Homebrew prefix. `imagehive paths` prints all of it.

| | |
|---|---|
| Command | `~/.local/bin/imagehive` |
| Binaries, MLX bundles, CLI internals | `~/.local/share/imagehive/` |
| Weights (~11–33 GB) | `~/Library/Application Support/ImageHive/models/` |
| Config, socket, service definition | `~/Library/Application Support/ImageHive/` |
| Log | `~/Library/Logs/ImageHive/imagehived.log` |
| Generated images | `~/Pictures/ImageHive/` |

`--home`, `--models`, `--out`, `--prefix` and `--label` (or the matching
`IMAGEHIVE_*` variables) move any of them. The reasoning, and the exact rules each
choice follows, is in [Docs/LAYOUT.md](Docs/LAYOUT.md).

## Upgrading from an older version

Up to 0.5.2 this project was called `sensenova-u1`, and the command, the paths and
the environment variables all carried that name. Re-run `./install.sh`; it does
four things, in this order:

1. **stops the old daemon, then moves the directories.** The order matters: that
   daemon holds a second copy of the weights, and moving the app home takes its
   socket file along — the new daemon then probes the new path, gets an answer,
   and exits 3 without binding. The upgrade looks successful while every reply
   still comes from the old build.
2. moves `~/Library/Application Support/SenseNovaU1`, `~/Pictures/SenseNovaU1`
   and the log directory onto the new names (a same-volume `mv`: the 11–66 GB of
   artifacts are not downloaded again), then boots out the old LaunchAgent and
   deletes its plist. The job is identified by its content — the plist names the
   binary it starts — because the label is yours to set with `--label`. A label
   that carries the brand token is *renamed* rather than replaced:
   `com.hrygo.sensenova-u1` becomes `com.hrygo.imagehive` and keeps your prefix. An
   explicit `--label` on the command line wins over that.
3. keeps the old *names* working without letting them start a second service: the
   old binary paths become wrappers onto the new binaries (old MCP client entries
   point straight at them) and the old command name becomes a wrapper onto
   `imagehive`, while the old script and its libraries are removed — their
   defaults resolve the pre-0.6 home.
4. removes the old `sensenova` MCP entries from the clients it knows about. Two
   entries expose the same tools, and a client that keeps both lists every tool
   twice.

Paths you chose yourself with `--home`/`--out` are left alone: there is nothing at
the old defaults to find, and moving a directory you picked is worse than telling
you where it is. `imagehive doctor` keeps reporting what is left — the old app
home, an old daemon still running, a client still holding the old entry. Delete
the old directories once it is clean:

```bash
rm -rf "$HOME/Library/Application Support/SenseNovaU1" ~/Pictures/SenseNovaU1
```

The environment variables were renamed with everything else:
`SENSENOVA_HOME`/`_SOCKET`/`_MODELS`/`_OUT`/`_PREFIX`/`_LABEL` are now
`IMAGEHIVE_*`. An old variable in a shell profile does not error — it is ignored,
which is exactly the case that falls back to the default layout and can start a
second daemon. Update them in the same pass.

## Connect your agent

`install.sh` wires every client it recognises. To do it by hand, or to add one
later:

```bash
imagehive clients list          # what is installed / wired
imagehive clients add codex     # or: claude, opencode, qwenpaw, claude-desktop, cursor
imagehive clients add auto      # everything detected
imagehive clients snippet       # paste-able snippet for anything else
```

Clients that ship an `mcp add` command (`codex`, `claude`) are configured through
it; the rest get a marker block written into their config file, after a
timestamped backup, and `clients remove` takes it out again. MCP servers are read
once per session, so restart the client before looking for the tools. See
[Docs/CLIENTS.md](Docs/CLIENTS.md) for per-client notes.

## What your agent gets

| Tool | What it does |
|---|---|
| `generate_image` | text → image; `tier=fast` for iteration, `tier=quality` for final art or text in the image. Takes a `seed` (reproducible), a `negative` prompt, and `steps`/`cfg` overrides |
| `edit_image` | instruction editing with one or more reference images, identity preserved |
| `describe_image` | read text out of a rendering, check a result against the brief, compare candidates |
| `model_options` | what this service accepts, before anything is asked of it: sizes, steps/cfg ranges and defaults, the seed rule, that `negative` applies to generate but not edit, where sidecars land, which tiers are installed |
| `model_status` | which weights are resident, how many loads since boot, queue depth, peak memory — plus the live step of the job in flight. Answers immediately even while a generation runs |
| `unload_model` | give the ~15–35 GB back immediately instead of waiting for the idle timeout |

One detail worth knowing before writing prompts: the negative prompt *is* the
unconditional branch of CFG on this architecture, so it only has an effect when
`cfg > 1`. The quality recipe runs cfg 4.0 and honours it; the fast recipe runs
cfg 1.0 and has no unconditional branch at all. `edit_image` rejects a non-empty
negative rather than dropping it.

## Day to day

```bash
imagehive status      # resident tier, loads, queue, peaks
imagehive doctor      # check host, install, models, service, clients
imagehive logs -f     # daemon log
imagehive unload      # release the weights now
imagehive generate --prompt "a brass compass on a dark desk" --tier fast
imagehive options     # what sizes, steps, cfg and seeds are accepted
imagehive restart     # restart the daemon (the weights stay on disk)
imagehive paths       # every path this install uses
```

The daemon starts on demand: the first request after an idle period loads the
weights (~5 s) and they are released again after 10 minutes of idleness
(`ttl_seconds` in `~/Library/Application Support/ImageHive/config.json`).
Nothing keeps 35 GB pinned down unless you are actively using it.

## Reproducible runs

`--seed` pins the noise, and every image is written with a sidecar recording what
produced it — that is what turns "I think I used the same prompt" into something
you can check afterwards:

```bash
imagehive generate --prompt "a brass compass" --seed 42 --width 1216 --height 832
# Wrote ~/Pictures/ImageHive/20260918T083207Z-t2i-seed42.png [1216x832, tier quality,
#       50 steps, 51.3s, seed 42] + 20260918T083207Z-t2i-seed42.png.json
imagehive generate --prompt "a brass compass" --seed 42 --n 4 --out ~/eval/run1 --json
```

Same seed + same artifact + same settings writes **byte-identical** bytes
(measured: two 512×512 runs at 6 steps produced the same SHA-256), and
`--seed 500 --n 4` walks seeds 500–503, one file each. The sidecar beside each PNG
carries the prompt verbatim and its SHA-256, the negative prompt, the seed and
whether it was pinned, size, steps, cfg, the artifact that ran, wall time and peak
memory; `write_sidecar: false` / `IMAGEHIVE_SIDECAR=0` turns it off. `--json`
prints the same facts as a machine-readable object (an array when `--n > 1`), and
`--out` moves the image and its sidecar together. `imagehive generate --help`
lists every flag.

One thing to know before a batch run: **a dispatched request cannot be
cancelled.** Killing the command does not stop the generation and its PNG still
lands — see [Docs/TROUBLESHOOTING.md](Docs/TROUBLESHOOTING.md). Wait for each
reply before sending the next one if you are counting samples.

### One model, many agents

```
Codex ─┐
Claude ─┼─► imagehive-mcp (stdio, stateless, no weights)
Cursor ─┘        │
                 └─► unix socket ─► imagehived (owns the weights)
                                          └─► one resident model
```

The MCP front end is a thin, stateless bridge; the daemon owns the model and
serialises generations. Adding another client adds a small process, never a
second copy of the weights — the socket bind is the mutex, and concurrent cold
starts share a single load. The project's own smoke test asserts exactly that
(three concurrent clients, one load) — see
[how to verify a change](AGENTS.md#如何验证一处改动) (AGENTS.md is in Chinese).

## Configuration

Two files, both optional and both plain JSON/shell:

* `~/Library/Application Support/ImageHive/config.json` — `ttl_seconds`,
  `min_warm_seconds`, `fast_artifact`, `quality_artifact` (names are relative to
  the models root unless absolute).
* `~/Library/Application Support/ImageHive/service.conf` — install layout
  (home, models, prefix, launchd label, socket). Written by `install.sh`;
  `imagehive config set IMAGEHIVE_LABEL=...` edits it.

Environment variables (`IMAGEHIVE_HOME`, `IMAGEHIVE_TTL_SECONDS`,
`IMAGEHIVE_SOCKET`, …) override both, which is how the generated client entries
point at your install. A `config.json` that cannot be used is not silently
ignored: the daemon logs which keys it could not read, `status` reports them
(`config_warning=` lines, and `config_warnings` in the daemon's JSON reply), and
`doctor` says `config.json is not valid JSON`.

## Troubleshooting and help

Start with `imagehive doctor` — it exits non-zero when something is actually
broken. The usual suspects:

* **`Failed to load the default metallib`** — the MLX resource bundles are missing
  next to the binaries. Re-run `./install.sh` (it copies `*.bundle` alongside).
* **First build fails mentioning Metal** — `xcodebuild -downloadComponent MetalToolchain`.
* **Client shows no tools** — restart the client; MCP servers are loaded per session.
* **Generation is slow after an idle period** — that is the model loading; keep
  `ttl_seconds` higher if you would rather stay warm.
* **`width must be a number, got the string "512"`** — arguments are typed; only an
  absent key means "use the default", a present key of the wrong type is refused with
  the value it received. Send numbers as numbers.
* **Your `config.json` edits change nothing** — environment variables win over the
  file; check the daemon's warnings first.

More in [Docs/TROUBLESHOOTING.md](Docs/TROUBLESHOOTING.md). Still stuck? Open an
issue at <https://github.com/hrygo/ImageHive/issues> and include the
output of `imagehive doctor` and the daemon log (`imagehive logs`).

## Known limitations

Named here rather than discovered later:

* **A dispatched request cannot be cancelled.** It runs to completion and its PNG
  lands even if the client goes away; `model_options.cancellation.supported` is
  `false` instead of pretending otherwise.
* **No HTTP endpoint, by design.** The transport is a unix socket in the app home
  and the socket file *is* the lock, so there is no port to open and no second
  entry point that could load a second copy of the weights.
* **One tier at a time** — `cold | fast | quality`. The daemon holds at most one
  artifact, because holding two is exactly the memory cost this project exists to
  avoid.
* **Requests are serialised** and there is no MCP tasks extension yet: a tool call
  blocks until its image is written.
* **Apple silicon and macOS 26+ only.** MLX does not run on Intel Macs.

## Uninstall

```bash
./uninstall.sh                 # service, binaries, client entries; keeps the artifacts
./uninstall.sh --purge-models  # and delete the downloaded models
```

## Contributing

Issues and pull requests are welcome at
<https://github.com/hrygo/ImageHive/issues>.

This README is for people *using* the service. Everything needed to *change* it —
the build, test and release targets, the invariants the service depends on, how to
test an installer without touching your real install, and which document to update
for which change — is in [AGENTS.md](AGENTS.md), which contributors and coding
agents read alike. Design rationale and deliberate trade-offs are in
[LOCAL-SERVICE.md](LOCAL-SERVICE.md); handing the service to someone else, or
cutting a release, is [Docs/DISTRIBUTING.md](Docs/DISTRIBUTING.md).

Maintained by [hrygo](https://github.com/hrygo); the MLX port and the published
artifacts are maintained upstream by Xocialize.

## Documentation

| Document | What is in it |
|---|---|
| [Docs/DISTRIBUTING.md](Docs/DISTRIBUTING.md) · [中文](Docs/DISTRIBUTING.zh-CN.md) | what to hand to someone else, what they do, offline installs, the release checklist |
| [Docs/LAYOUT.md](Docs/LAYOUT.md) | why each path lives where it does, what is deliberately not there, and how to migrate from the old layout |
| [Docs/MODELS.md](Docs/MODELS.md) | artifacts, tiers, image sizes, one-artifact machines, building your own artifact |
| [Docs/CLIENTS.md](Docs/CLIENTS.md) | per-client wiring details, and what the tools accept |
| [Docs/TROUBLESHOOTING.md](Docs/TROUBLESHOOTING.md) | the failure modes worth naming, with the measurements behind them |
| [AGENTS.md](AGENTS.md) | how to change this repository without breaking it (Chinese) |
| [LOCAL-SERVICE.md](LOCAL-SERVICE.md) | design rationale and deliberate trade-offs (Chinese) |
| [UPSTREAM-README.md](UPSTREAM-README.md) | the upstream MLX port's own README: its performance tables, CLI and quantization doctrine |
| [CHANGELOG.md](CHANGELOG.md) | what changed in each release |
| [NOTICE](NOTICE) | attribution for the upstream port, the weights and the LoRAs |

## Credits and license

* Upstream Swift/MLX port and the published MLX artifacts: **Xocialize**, MIT —
  [sensenova-u1-swift](https://github.com/xocialize/sensenova-u1-swift). The port's
  sources and its commit history are kept in this repository; GitHub records no
  fork relationship between the two.
* **SenseNova-U1.5-8B-MoT** weights: SenseTime, Apache-2.0 —
  [sensenova/SenseNova-U1.5-8B-MoT](https://huggingface.co/sensenova/SenseNova-U1.5-8B-MoT).
* The 8-step distillation LoRA: [xocialize/SenseNova-U1.5-8B-MoT-LoRAs](https://huggingface.co/xocialize/SenseNova-U1.5-8B-MoT-LoRAs).
* The service, CLI and installers in this repository: MIT (see [LICENSE](LICENSE)
  and [NOTICE](NOTICE)). The weights are **not** distributed by this repository;
  the installer downloads them from their publishers on request.
