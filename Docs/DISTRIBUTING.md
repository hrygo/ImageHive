# Distributing this service

> [中文版](DISTRIBUTING.zh-CN.md) — the recipient-facing guide is also available
> in Chinese ([README.zh-CN.md](../README.zh-CN.md)), and both ship inside the
> release archive.

For whoever hands this to someone else — a colleague, a friend, a machine with no
developer tools on it. Being usable by a non-developer is a requirement of this
project, so the rules below are not cosmetic.

## What to hand over

```bash
make release          # dist/sensenova-u1-<version>-macos-arm64.tar.gz (+ .sha256)
make release-verify   # installs that tarball into a private HOME and checks it
```

The archive is self-contained on purpose: `install.sh` sources `cli/lib/*.sh`, so
a tarball holding only `prebuilt/` could not install anything.

```
sensenova-u1-<version>-macos-arm64/
├── install.sh  uninstall.sh        the installers (`cli/` is sourced by them)
├── prebuilt/                       sensenova-served, sensenova-mcp + MLX *.bundle
├── cli/  Docs/                     management CLI and the documentation it points at
├── README.md  CHANGELOG.md  LICENSE  NOTICE
├── BUILD-INFO.txt                  version, git revision, build host
└── SHA256SUMS                      every file above
dist/<name>.tar.gz.sha256           checksum of the archive itself
```

The version comes from `SV_VERSION` in `cli/lib/common.sh`; the upstream git tag
is recorded in `BUILD-INFO.txt` so a tarball is never mistaken for an upstream
release. Weights are **never** bundled — `NOTICE` requires them to be downloaded
from their publishers, and 11–33 GiB of Apache-2.0 weights do not belong in a
release.

## What the recipient does

```bash
shasum -a 256 -c sensenova-u1-0.3.0-macos-arm64.tar.gz.sha256
tar -xzf sensenova-u1-0.3.0-macos-arm64.tar.gz
cd sensenova-u1-0.3.0-macos-arm64
bash install.sh
```

Then restart their agent and ask for an image. Nothing else: no Xcode, no Swift,
no `sudo`, no build step.

### Why `bash install.sh` and not `./install.sh`

Anything that arrives over the network carries `com.apple.quarantine`, and
Gatekeeper refuses to *execute* a quarantined file. Measured on macOS 26:

* a quarantined **Mach-O binary** hangs — the process waits in `syspolicyd` for a
  consent dialog that a terminal install never shows;
* a quarantined **shell script** runs fine when `bash` reads it (`bash install.sh`
  works on a freshly downloaded copy);
* BSD `install` and `cp` **propagate** the flag to their destination, so the
  binaries would land in `~/.local/share/sensenova-u1/bin/` still quarantined and
  every MCP client launch would block.

So the installer clears `com.apple.quarantine` from the files it installs
(`dequarantine` in `install.sh`), and the README tells people to invoke it
through `bash`. No signing identity and no notarisation are involved; if you do
want a signed build, sign `prebuilt/sensenova-served` and
`prebuilt/sensenova-mcp` with your Developer ID before `make release` and this
step becomes redundant for the binaries (the flag would still be cleared).

## Offline and locked-down machines

1. Run the installer anywhere once to get the artifact (`sensenova-u1 models`),
   or download a published `mlx-community/*` artifact by hand.
2. Copy the tarball **and** the artifact directory
   (`<owner>-SenseNova-U1.5-8B-MoT-*`) to the target machine.
3. There, put the artifact under
   `~/Library/Application Support/SenseNovaU1/models/` and run
   `bash install.sh --model none` — it keeps what is already on disk.

## Checklist before handing it over

- [ ] `make release-verify` passes (it installs the tarball into a throwaway HOME,
      with the files quarantined, using `--skip-build`).
- [ ] `shasum -a 256 -c <tarball>.sha256` passes on the archive you are shipping.
- [ ] The tarball name carries the version from `cli/lib/common.sh`.
- [ ] You did not add weights, `dist/` or `.build/` to the archive.
- [ ] `CHANGELOG.md` has an entry for that version.

## Not done yet

* No published download URL: the service currently lives in a local-only fork, so
  the archive is handed over as a file. Publishing it (a GitHub release, or a
  mirror reachable without a proxy from China) is a decision for the maintainer.
* No Apple Developer ID signature or notarisation.
* No Homebrew formula or cask.
