# Working in this repository

Guidance for coding agents (Codex, Claude Code, opencode, …) and for humans who
behave like them. User-facing documentation lives in [README.md](README.md) and
[Docs/](Docs/); this file is about changing the code without breaking it.

## What this is

A fork of [`xocialize/sensenova-u1-swift`](https://github.com/xocialize/sensenova-u1-swift)
that adds a resident local image service:

```
MCP clients ──► sensenova-mcp (stdio, stateless, no weights)
                    │  unix socket
                    └─► sensenova-served (owns the model, serialises work)
                            └─► one resident copy of the weights
```

The upstream port, its tests and `Docs/publish/`, `Docs/receipts/` are not ours
to change: keep the diff to `Package.swift` (two added executables), the two
`Sources/sensenova-*` targets, `cli/`, `install.sh`, `uninstall.sh` and the
documentation.

## Invariants — break these and the project is pointless

1. **One resident copy of the weights per machine.** Three mechanisms, all
   required: the unix socket bind is the process mutex; the daemon's load is
   single-flight (`pendingLoad`) so concurrent callers await the same task; the
   daemon holds at most one tier (`cold | fast | quality`). Adding another
   process that can load weights, or another socket, or a second cache, breaks
   the whole point of the project.
   A tier whose artifact is not installed is *served* from the one that is
   (`resolveTier`), at that artifact's own recipe — one artifact is a supported
   install, so never turn "that tier is not installed" into a hard failure, and
   never let the request's tier pick the step count of the artifact that runs.
2. **The front end stays stateless.** `sensenova-mcp` must not load weights,
   must not write config, and must not hold state between requests. It may start
   the daemon on demand.
3. **No HTTP endpoint.** The transport is a unix socket in the app home; the
   socket file *is* the lock. Do not add a TCP listener "for convenience".
4. **Tools return file paths, not base64 blobs**, unless the caller asks for
   `inline_thumbnail: true`. Large results must not be poured into an agent's
   context.
5. **Weights are never committed, never vendored and never redistributed by this
   repo.** The installer downloads them from their publishers (see
   [NOTICE](NOTICE)).
6. **Nothing runs as root and nothing writes outside the user's home**, excepting
   the user's own launchd directory. See [Docs/LAYOUT.md](Docs/LAYOUT.md).

## Layout and configuration

* Paths: [Docs/LAYOUT.md](Docs/LAYOUT.md) — app data and weights under
  `~/Library/Application Support/SenseNovaU1`, executables under `~/.local`,
  images in `~/Pictures/SenseNovaU1`. Every path is overridable (`--home`,
  `--models`, `--out`, `--prefix`, `--label`, or the matching `SENSENOVA_*`
  variables). Environment beats `service.conf` beats built-in defaults; keep
  that order when you add a setting.
* `service.conf` is parsed line by line, never sourced (a malformed file must not
  be able to execute anything). Values are single-quoted so paths with spaces
  survive a round trip — do not switch back to `printf %q`, whose escaping piles
  up on every rewrite.
* The installers generate the LaunchAgent from a template in `install.sh`. That
  heredoc is unquoted so `$(sv_*)` expands: **never** put backticks or `$( )`
  in its body, comments included — they are executed.
* `launchd` throttles respawns; `ThrottleInterval` is 1 second. The 10 s default
  stalls every explicit restart by that much (measured 19 s vs 0 s).

## Commands

```bash
make build          # both products, release
make test           # protocol + shared-weights assertions (needs artifacts)
make test-quick     # protocol only, no model needed — the CI default
make doctor         # check the installed service end to end
make install        # build + install + restart (keeps existing models)
install.sh --dry-run --model none --clients none     # show every action
```

`sensenova-u1` is the management CLI (`status`, `doctor`, `models`, `clients`,
`logs`, `unload`, `generate`, `config`, `paths`). `doctor` exits non-zero when
something is actually broken, so it is safe to use as a check.

## How to verify a change

Any change to the daemon, the front end or the installer is expected to keep
these green, and to say so in the commit message:

1. `swift build -c release` for both products — no new warnings.
2. `make test-quick` — protocol, single-instance refusal, cold status.
3. `make test` — three concurrent clients, one load (`loads_total == 1`), one
   `sensenova-served` process. This is the assertion the project exists for.
4. `install.sh --dry-run` and `uninstall.sh --dry-run` — no state change, no
   errors.

**Never test installers against your real home.** Point `HOME` at a scratch
directory and give the job its own label; this exercises the whole path
(binaries, config, LaunchAgent, wrappers) without touching the installed
service:

```bash
TD="$(mktemp -d)"; HOME="$TD" ./install.sh --model none --clients none \
  --label local.sensenova-u1-test --yes
HOME="$TD" "$TD/.local/bin/sensenova-u1" doctor
launchctl bootout gui/$(id -u)/local.sensenova-u1-test
```

Both Swift programs must honour `$HOME` before
`FileManager.homeDirectoryForCurrentUser`; otherwise a sandboxed run silently
reaches back into the real user's app home (this has happened once).

## Documentation map — update the right file

| Change | Update |
|---|---|
| Paths, environment variables, install locations | `Docs/LAYOUT.md`, README table |
| A new MCP client, or wiring details | `Docs/CLIENTS.md` |
| Model presets, tiers, artifact shapes | `Docs/MODELS.md` |
| New failure mode worth naming | `Docs/TROUBLESHOOTING.md` |
| Behaviour or interface changes | `CHANGELOG.md` (and bump `SV_VERSION`) |
| Design rationale, measurements, upstream deviations | `LOCAL-SERVICE.md` |

Runtime documents that are *not* in this repo: the machine-specific design and
acceptance record lives in the `本机优化配置` configuration repository on the
author's machine. Do not make this repo depend on it.

## Style

* Shell: `set -euo pipefail`, `bash -n` clean, idempotent steps, `--dry-run`
  honest, no `eval`, no `source` of user-editable files.
* Swift: Swift 6 language mode, no new warnings, small types, no global mutable
  state outside the existing configuration constants.
* Docs: state what was measured and when (`2026-09-18`, M5 Max, 128 GB) rather
  than generalities; keep the Chinese notes in `LOCAL-SERVICE.md` and the
  English user docs separate.
* Commits: `type(area): summary` with a Chinese body explaining *why* (the
  existing history is the model).
