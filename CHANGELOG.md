# Changelog

## Unreleased

**Reinstalling now actually changes what runs.** Found by doing it: the daemon
that answers is normally started by whichever MCP front end needed it first
(`spawnServed`), not by the launchd job, and that process outlives every front
end that started it. Replacing the binaries therefore left it holding the socket:
the launched job exited 3 without binding, the install reported success, and
every answer still came from the previous build — measured by a reinstall whose
`options` call was answered with `unknown cmd 'options'`.

* `stop`, `restart` and `install.sh` now hand the socket over: after the launchd
  job is stopped, whatever still holds the socket is terminated — but only if its
  command line names `sensenova-served`, so a client that happens to have the
  socket open is left alone. `restart` is now stop-then-start rather than
  `kickstart -k`, which only ever replaced the process launchd owned.
* `status` reports `pid`, `project_version` and `protocol`, so "which build is
  answering?" has an answer from the outside. `doctor` compares them with the
  installed CLI and says `the daemon answering reports version X, this install is
  Y` (a daemon older than 0.5.1 reports no version at all, which is the same
  signal), and the installer warns when the daemon left behind after the install
  is not the build it just wrote.
* Tests: `Tests/cli.sh` asserts that a daemon started by hand — which is how the
  normal install runs it — is ended by `stop`, that the socket is released, and
  that `status` names the process and the build.
* [Docs/TROUBLESHOOTING.md](Docs/TROUBLESHOOTING.md): "I reinstalled, and the
  behaviour did not change."

## 0.5.1 — 2026-09-18

**A run is now reproducible, self-describing and scriptable — and a bad request
can no longer kill the service.** This round came out of using the thing the way
someone comparing two models actually uses it, and the first discovery was not a
missing convenience but a crash.

* **A size that is not a multiple of 32 used to abort the daemon**, not the
  request. `Configuration.pixelsPerToken` is `patchSize / downsampleRatio` =
  16 / 0.5 = 32, so `1000x1000` became a latent grid the reshape could not
  satisfy: `Fatal error: [reshape] Cannot reshape array of size 3000000 into
  shape (1,3,31,32,31,32)`, uncatchable, every client session on the shared
  socket lost. `width`, `height` (multiples of 32, 32–4096), `steps` (1–500) and
  `seed` (non-negative) are now validated **before** the weights are loaded —
  a bad request costs nothing and the reply names the nearest legal value.
  Negative seeds and `steps: 0` were the same class of bug (`UInt64(-1)` trap).
* **`negative` now works on `generate_image`, and is refused on `edit_image`
  instead of being silently dropped.** The daemon ignored the argument end to
  end, while the model underneath supported it all along
  (`SenseNovaTokenizer.t2iIDs(prompt:negativePrompt:)`); measured, two requests
  with different negatives produced byte-identical files. The edit surface has no
  unconditional branch, so a non-empty negative there is now an error rather than
  a no-op.
* **Every image is accompanied by metadata.** `<image>.png.json` records the
  prompt and its SHA-256, the negative prompt and its hash, the seed **and whether
  it was pinned or random**, size, steps, cfg, the tier requested and the tier
  that ran, the artifact directory, seconds, peak memory, `created_at` and the
  project/protocol version. Before this, the only surviving record of a run was a
  file name, and a comparison could only be described, not proven.
  `write_sidecar: false` / `SENSENOVA_SIDECAR=0` turns it off.
* **`--seed` on the CLI and `seed` on the tools**, with `--n` for a batch:
  `--seed 500 --n 4` produces seeds 500–503, one file each. Byte-identical
  repeatability with the same seed and artifact was verified before relying on it
  (identical SHA-256 across runs).
* **`--json`, `--out`, `--steps`, `--cfg`, `--negative`** on `sensenova-u1
  generate`, and `-h/--help` on every subcommand (`generate --help` used to be
  `error: unknown option: --help`). `--json` emits one object, or an array for a
  batch, with machine-readable paths and timings instead of a sentence to
  re-parse; `--out` moves the PNG **and its sidecar** together.
* **New `model_options` MCP tool and `sensenova-u1 options`**: the contract —
  sizes and recommended values, step and cfg ranges with per-tier defaults, the
  seed rule, which arguments apply to which tool, whether a sidecar is written,
  whether cancellation exists, and which tiers this machine can serve — returned
  without loading the weights. Clients no longer discover the rules by sending
  requests and reading the 400s.
* **`model_status` answers while a generation is running.** A generation holds
  the actor for its whole duration, so `status` used to block behind it — measured
  at 75.3 s, which made the tool useless for telling "busy" from "stuck", and made
  `unload`'s busy path dead code. `status`, `options` and the busy branch of
  `unload` are now answered on the connection thread from a `StatusBoard`
  snapshot; the in-flight job publishes `current` (`tool`, `step`, `total`,
  `percent`, `elapsed_seconds`) from the step callback, which is also what the
  CLI's progress line reads.
* **The CLI shows progress on stderr while it waits** (only on a TTY, so piped
  and captured runs stay silent), polling `status.current` — a 71 s generation no
  longer looks like a hang.
* `sensenova-served` and `sensenova-mcp` report the project version from
  `SENSENOVA_VERSION` (written into `service.conf` by the installer) instead of a
  hard-coded `0.1.0` that had been wrong since 0.2, and expose
  `protocol: 1` for clients that want to detect the shape of the replies.
* Error replies use the underlying `localizedDescription` rather than dumping an
  `NSError`.
* **Not done, deliberately**: a request in flight still cannot be cancelled (the
  reply states it instead of pretending otherwise), the socket protocol stays
  one-line-in/one-line-out so no progress messages travel over it, and
  `--manifest` is not implemented — `--seed` + `--n` + `--json` covers the same
  ground for now.
* Tests: new `Tests/cli.sh` (help, validation, `options`, `--json` + seed +
  sidecar + byte-identical repeat, `--out`, `--n`, service survives a bad
  request), `Tests/smoke.sh` gained `model_options`, the bad-size-survival case,
  the same-seed byte-identity case and the "status answers during a generation"
  case. `Tests/smoke.sh` also stopped writing into the user's real
  `~/Pictures/SenseNovaU1/` (it never set `SENSENOVA_OUT`) — that is where the
  stray benchmark images came from. `make test-quick` runs both scripts in their
  fast mode; CI compiles the CLI's Python helpers.
* Docs: [Docs/MODELS.md](Docs/MODELS.md) gained "Image sizes" (the rule, the
  recommended set, the measured cost), [Docs/LAYOUT.md](Docs/LAYOUT.md) explains
  the sidecar beside the image, [Docs/CLIENTS.md](Docs/CLIENTS.md) gained "What
  the tools take" (argument table plus the six things an agent needs to know
  first), [Docs/TROUBLESHOOTING.md](Docs/TROUBLESHOOTING.md) covers the size
  refusal and the "I killed it and the image appeared anyway" case; both READMEs
  document the comparison workflow in their own language.

* `scripts/verify_release.sh` no longer aborts on read-only files. It quarantined the
  extracted copy with one recursive `xattr -wr`, and xattr refuses a file the caller
  cannot write — a macOS resource inside a bundle can be mode 444 in an archive built
  by another toolchain, which made the check die with `[Errno 13] Permission denied`
  after steps 1 and 2 had already passed. The flag is now applied per item, the count
  of refusals is reported, and the assertion that matters (the binaries are
  quarantined, then unquarantined by `install.sh`) is unchanged. Reproduced locally
  with a 444-resource archive: the old script failed exactly as CI did, the new one
  passes. `install.sh` already tolerated the same case.
* `install.sh` no longer refuses to install, or to print a dry run, when the machine
  is below the artifact memory floor and no artifact is involved. `--model none`
  stages the binaries without weights, and a dry run exists precisely so someone on a
  small machine can see what an install would do; both used to hit the same `die` as
  a real 15 GB install. The gate itself is unchanged where it belongs: a real install
  that would run weights still stops on a machine under 18 GB.
* `LICENSE` is a plain MIT text again, with the fork's copyright line next to the
  upstream one; the scope of the fork's additions is still spelled out in
  `NOTICE`. The addendum that used to sit after the MIT body made GitHub report
  the repository as `NOASSERTION` instead of MIT, which reads as "unclear
  license" to anyone deciding whether they may use this. The archive published as
  v0.5.0 carries the footnoted version of the same MIT terms; the legal meaning is
  identical, so nothing needs re-releasing.

## 0.5.0 — 2026-09-18 （首个公开发行版）

**版本号说明**：本 fork 在私有时用过 0.1.0–0.3.0（从未对外发布）。首个公开版
接续上游的 tag 序列编号——fork 时上游停在 `v0.4.0`，而 `v0.3.0`、`v0.3.1`、
`v0.3.2` 这些 tag 上游已经占用了，继续用 0.3.x 会和上游的既有 tag 撞名，
所以公开版从 **0.5.0** 开始；0.1.0–0.3.0 这些标签不再使用。

**Handing this to someone else, and letting a non-developer use it.** The
release archive was not installable, and a downloaded copy could hang on the
first launch; both are fixed and verified by `make release-verify`.

* `make release` now builds a complete, self-contained archive:
  `install.sh`, `uninstall.sh`, `cli/`, `Docs/`, `README`/`LICENSE`/`NOTICE`/
  `CHANGELOG`, `BUILD-INFO.txt`, `SHA256SUMS` and `prebuilt/` (both binaries plus
  the MLX bundles). `install.sh` sources `cli/lib/*.sh`, so the previous tarball —
  `prebuilt/` only — could not install anything.
* The archive is named after the project version in `cli/lib/common.sh`
  (0.5.0 here) instead of the upstream git tag, which used to make a fork build
  look like an upstream release; the tag is recorded in `BUILD-INFO.txt`.
* **Quarantine is handled.** Gatekeeper refuses to run a quarantined Mach-O: the
  process blocks in `syspolicyd` on a dialog a terminal install never shows, and
  BSD `install`/`cp` propagate the flag to the installed copies, so every MCP
  client launch would hang. `install.sh` now clears `com.apple.quarantine` from
  the files it installs and says so; `bash install.sh` works on a quarantined
  copy because scripts read by a shell are not gated. None of this needs a
  Developer ID or notarisation — the measurements are in
  [Docs/DISTRIBUTING.md](Docs/DISTRIBUTING.md).
* `python3` is now a checked requirement with an actionable message instead of a
  warning followed by a failure twenty minutes into a download.
* Model downloads print a heartbeat — file count, bytes, percent, elapsed — so a
  33 GiB pull no longer looks like a hang. The announcement also says the
  download is resumable. (`SENSENOVA_PROGRESS=0` silences it.)
* The installer's closing note points out when `~/.local/bin` is not on `PATH`,
  with the exact line to add, and tells the user to restart their agent.
* `scripts/verify_release.sh` (+ `make release-verify`): verifies the archive
  against its `.sha256`, quarantines the extracted copy, installs it into a
  private HOME with `--skip-build` (no Xcode, no Swift), and asserts the binaries,
  bundles and command are in place *and unquarantined*, that the sandbox service
  answers, and that `doctor` reports the model-less state of the sandbox.
  `SENSENOVA_VERIFY_SKIP_SERVICE=1` stops before the launchd steps for headless CI.
* `sensenova-mcp` writes its daemon log under `$HOME` like everything else, so a
  sandboxed install no longer appends to the real user's log.
* CI: a `release` job builds the archive and installs it from the tarball, plus a
  shell-syntax pass over every script (`bash -n`).
* Docs: new [Docs/DISTRIBUTING.md](Docs/DISTRIBUTING.md) (what to hand over, what
  the recipient does, offline installs, pre-flight checklist);
  [Docs/TROUBLESHOOTING.md](Docs/TROUBLESHOOTING.md) covers the quarantine hang,
  the python3 requirement, a stalled-looking download and the `PATH` gap; the
  README gained an Xcode-free quick start.
* **中文文档**：[README.zh-CN.md](README.zh-CN.md) 是完整中文首页（快速开始、安装
  位置、前置条件、档位与单档回退、客户端接线、日常命令、常见问题），
  [Docs/DISTRIBUTING.zh-CN.md](Docs/DISTRIBUTING.zh-CN.md) 是中文交付指南（交付
  什么、对方怎么做、为什么用 `bash install.sh`、离线安装、交付前清单）。两者都随
  归档发布，英文文档仍为权威版本；英文首页与交付指南都加了中文入口链接。

## 0.2.1 — 2026-09-18

**One artifact is enough.** `tier` is a preference, not a requirement — the docs
said so and the daemon did not, so a machine with a single artifact failed the
requests aimed at the other one.

* `sensenova-served` resolves the requested tier against what is installed and
  serves the request from the installed artifact when the requested one is
  missing (`resolveTier`, either direction). The recipe follows the artifact in
  memory — `fast` keeps 8 steps at cfg 1.0, `quality` keeps 50 steps at cfg 4.0 —
  so a fallback can never drive distilled weights with the reference recipe or
  the other way round.
* Replies name both tiers (`"tier": "quality", "tier_requested": "fast"`), the
  human line reads `tier quality, asked for fast, not installed`, and
  `model_status` reports `available_tiers`.
* `sensenova-u1 doctor` reports a missing tier as a note instead of a failure;
  `models` and `config show` mark each tier installed/not installed; `generate`
  without `--tier` picks whichever artifact this machine has.
* `install.sh` says so when only one artifact was installed, and its optional
  `--smoke-generate` no longer assumes the fast tier exists.
* `tests/smoke.sh` runs its generation assertions on whichever artifact the host
  has and, on a one-artifact machine, proves the fallback by requesting the tier
  that is not installed.
* [Docs/MODELS.md](Docs/MODELS.md) — "One artifact is enough";
  [Docs/TROUBLESHOOTING.md](Docs/TROUBLESHOOTING.md) — the new messages.

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
* `clients add opencode` rewrites its entry instead of appending a second one.
  Duplicate `"sensenova"` keys are not cosmetic: JSON keeps the **last** one, so
  a stale or hand-written entry pointing at an old path silently won over the
  one just written — the installer said "wired" while the client was still
  starting the previous binary. `add` now removes every copy first.
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
