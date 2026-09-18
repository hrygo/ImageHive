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

**`./install.sh` does nothing, or the terminal waits forever on the first
image.**
The files came from a download, so macOS marked them quarantined and Gatekeeper is
holding the process until you answer a dialog. Run the installer through the
shell instead — `bash install.sh` — which the quarantine does not gate; the
installer then clears the flag from the binaries it installs. Details and the
measurements: [DISTRIBUTING.md](DISTRIBUTING.md#why-bash-installsh-and-not-installsh).

**`python3 is required and was not found.`**
Unlike most of this project, python3 is not optional: the artifact downloader
parses the ModelScope/Hugging Face listings with it, the client wiring edits
JSON/JSONC configs, and the CLI reads `config.json` with it. Install it with
`xcode-select --install` (macOS ships it with the Command Line Tools, ~1.5 GB) or
`brew install python`, then re-run the installer — it picks up where it stopped.

**The download looks stuck.**
It prints a heartbeat every few seconds once it starts fetching (`3/12 files,
8.2 GiB of 33.0 GiB (24%), 4m10s elapsed`). If a file stalls, stop it with
Ctrl-C and re-run `sensenova-u1 models pull <preset>`: finished files are
verified by size and skipped, and partial files resume (`curl -C -`).

**`no model artifact installed: looked for …` as an error from a tool call.**
Neither tier's artifact is on disk, so there is nothing to serve the request
from. `sensenova-u1 models` shows what is there; `sensenova-u1 models pull
fast-4bit` (11 GiB) or `quality-bf16` (33 GiB) installs one. One artifact is
enough — see [MODELS.md](MODELS.md#one-artifact-is-enough).

**`sensenova-u1: command not found` after installing.**
`~/.local/bin` is not on the default macOS `PATH`. Either call it by full path
(`~/.local/bin/sensenova-u1 doctor`) or add `export PATH="$HOME/.local/bin:$PATH"`
to `~/.zprofile`. The installer prints this when it applies.

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

**I reinstalled, and the behaviour did not change.**
The daemon answering is normally started by whichever MCP client needed it first,
not by the launchd job, and such a process keeps the socket after you replace the
binaries: the launched job then fails to bind (`last exit code = 3` in
`launchctl print gui/$(id -u)/com.hrygo.sensenova-u1`) while every answer still
comes from the previous build. Installing, `sensenova-u1 stop` and
`sensenova-u1 restart` all end whatever holds the socket, so start there —
`sensenova-u1 restart`, then `sensenova-u1 status`, which names the process and
the build (`pid=`, `project_version=`). `doctor` reports a mismatch as
`the daemon answering reports version X, this install is Y`. A daemon from before
0.5.1 does not report a version at all, which is the same signal.

**`seed must be a number, got the string "126"` (or the same for `width`).**
Arguments are typed: a key that is present with the wrong JSON type is an error
rather than a silent fallback, so send numbers as numbers (`"width": 512`, not
`"width": "512"`) and booleans as `true`/`false`. Only an *absent* key means "use
the default" — omit `seed` for a random one. Before 0.5.2 every one of these was
accepted and quietly dropped (a string seed produced a *random* seed, a string
`steps` ran 50), which is why the refusal now names what it received.

**The settings in `config.json` are being ignored.**
A `config.json` the daemon cannot parse is no longer accepted in silence: it logs
`<path> is not valid JSON — every setting in it is ignored` at startup, `status`
prints a `config_warning=` line, and `doctor` reports `config.json is not valid
JSON`. A single key with the wrong type is reported by name
(`config.json: ttl_seconds must be a number … — that key is ignored`) and the rest
of the file still applies. Remember that environment variables win over the file,
so if a value changes nothing, check whether `SENSENOVA_TTL_SECONDS` and friends
are set in the launchd job or in the client entry that starts the daemon.

**`sensenova-u1 status` says the daemon is unreachable, but the socket file is there.**
That file can outlive its process (a crash, `kill -9`, a wedged machine). Nothing
acts on the file alone any more: every readiness check connects, a daemon starting
up unlinks a socket nobody is listening on before it binds, and `sensenova-u1 stop`
ends whatever still owns it — by process name, never by path alone. `doctor` and
`status` are safe to run: they will start a daemon if none is there.

**`width 833 is not a multiple of 32` (or the same for `height`).**
The model renders on a latent grid of `size/32`, so both dimensions have to be
multiples of 32 (32–4096 px). The message names the nearest valid value: use it.
Version 0.5.0 and earlier fed the raw number to the model and MLX aborted the
**whole daemon** with an uncatchable `[reshape]` fatal error, which took down
every client session sharing the service — the check now runs before any weights
are loaded. `sensenova-u1 options` lists the recommended sizes (1024×1024,
1216×832, 1600×896, 896×1600).

**I killed a run, and the image appeared anyway.**
That is expected, and it is why the daemon tracks work by request rather than by
connection: a request that has already been dispatched runs to completion and
writes its PNG even if the client process is gone, because cancelling mid-flight
would leave the model in an unknown state. There is no cancel command
(`model_options` reports `cancellation.supported: false`). A batch that is
interrupted therefore leaves images behind — count them, or clear the output
directory, before trusting a sample count.

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
