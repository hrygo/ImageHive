# Troubleshooting

Start here:

```bash
sensenova-u1 doctor     # host, install, models, service, clients — with exit status
sensenova-u1 status     # resident tier, loads, queue, peak memory
sensenova-u1 logs       # last 40 lines of the daemon log
```

## Common symptoms

**`Failed to load the default metallib` in the log, or the daemon dies on the
first generation.**
MLX keeps its Metal library in `mlx-swift_Cmlx.bundle`, which has to sit next to
the executable. Installing only the binary breaks it. Re-run `./install.sh`
(it copies every `*.bundle`), then check that
`ls ~/.local/share/sensenova-u1/bin/*.bundle` lists at least one bundle.

**The build stops early with a Metal or `metal` compiler error.**
Xcode 27 ships the Metal toolchain as a separate component:

```bash
xcodebuild -downloadComponent MetalToolchain
```

**`no model artifact installed: looked for …` as an error from a tool call.**
Neither tier's artifact is on disk, so there is nothing to serve the request
from. `sensenova-u1 models` shows what is there; `sensenova-u1 models pull
fast-4bit` (11 GiB) or `quality-bf16` (33 GiB) installs one. One artifact is
enough — see [MODELS.md](MODELS.md#one-artifact-is-enough).

**The reply says `asked for fast, not installed` (or `asked for quality`).**
That is the single-artifact fallback working: this machine installed only the
other tier, so the daemon served the request from it, at *its* recipe, and named
both tiers so the caller is not surprised by the step count. Install the missing
artifact (`sensenova-u1 models pull fast-4bit`) if you want that path, then
`sensenova-u1 restart`. `available_tiers` in `sensenova-u1 status` lists what the
daemon can serve.

**A client shows no image tools.**
MCP servers are started per session — restart the client, then
`codex mcp list` / `opencode mcp list` / `claude mcp list` should show
`sensenova`. If the entry is missing entirely, `sensenova-u1 clients add <name>`.

**The first image after a while takes 5–10 s longer.**
That is the model load, not a hang. It is released again after `ttl_seconds`
idle (default 600 s). Raise `ttl_seconds` in
`~/Library/Application Support/SenseNovaU1/config.json`
if you would rather stay warm, or call `sensenova-u1 unload` when you are done.

**Two clients, one at a time.**
Generations are serialised inside the daemon on purpose: one resident model,
one GPU. A second request waits its turn (`queue_depth` in `sensenova-u1 status`).

**`another instance is live at …` in the log.**
A daemon already owns the socket. That is the single-instance protection, not an
error: the new process exits with code 3 without touching the weights. If you
really want a fresh daemon: `sensenova-u1 restart`.

**A download stopped halfway.**
Just re-run `sensenova-u1 models pull <preset>` — it resumes and skips files
whose size already matches. `sensenova-u1 models verify` compares the files on
disk with the recorded manifest.

**Memory pressure while the model is resident.**
`sensenova-u1 unload` releases the weights immediately. To make that automatic
sooner, lower `ttl_seconds` (for example 120). Check what a run actually cost
with `last_peak_mb` from `sensenova-u1 status`.

**Slow downloads from Hugging Face in China.**
The default source is ModelScope, which needs no proxy. If you must use Hugging
Face and it crawls, try the public mirror:

```bash
HF_ENDPOINT=https://hf-mirror.com sensenova-u1 models pull fast-4bit hf
```

## Collecting a useful bug report

```bash
sensenova-u1 doctor > /tmp/doctor.txt 2>&1; echo "exit=$?" >> /tmp/doctor.txt
sensenova-u1 status >> /tmp/doctor.txt 2>&1
tail -100 ~/Library/Logs/SenseNovaU1/served.log >> /tmp/doctor.txt
sw_vers >> /tmp/doctor.txt; swift --version >> /tmp/doctor.txt
```

The log is append-only across restarts, so `grep "loaded\|unloading\|error"` is
usually enough to reconstruct what happened.
