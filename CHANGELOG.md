# Changelog

## Unreleased

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
