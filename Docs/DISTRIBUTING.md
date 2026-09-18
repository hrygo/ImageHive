# Distributing this service

> [中文版](DISTRIBUTING.zh-CN.md) — the authoritative README is the Chinese
> [README.md](../README.md), with its English mirror at
> [README.en.md](../README.en.md). Every one of these files ships inside the
> release archive.

For whoever hands this to someone else — a colleague, a friend, a machine with no
developer tools on it. Being usable by a non-developer is a requirement of this
project, so the rules below are not cosmetic.

## What to hand over

```bash
make release          # dist/imagehive-<version>-macos-arm64.tar.gz (+ .sha256)
make release-verify   # installs that tarball into a private HOME and checks it
```

The archive is self-contained on purpose: `install.sh` sources `cli/lib/*.sh`, so
a tarball holding only `prebuilt/` could not install anything.

```
imagehive-<version>-macos-arm64/
├── install.sh  uninstall.sh        the installers (`cli/` is sourced by them)
├── prebuilt/                       imagehived, imagehive-mcp + MLX *.bundle
├── cli/  Docs/                     management CLI and the documentation it points at
├── README.md  README.en.md          the two user-facing READMEs
├── AGENTS.md  LOCAL-SERVICE.md  UPSTREAM-README.md
├── CHANGELOG.md  LICENSE  NOTICE
├── BUILD-INFO.txt                  version, git revision, build host
└── SHA256SUMS                      every file above
dist/<name>.tar.gz.sha256           checksum of the archive itself
```

The version comes from `IH_VERSION` in `cli/lib/common.sh`; the upstream git tag
is recorded in `BUILD-INFO.txt` so a tarball is never mistaken for an upstream
release. Weights are **never** bundled — `NOTICE` requires them to be downloaded
from their publishers, and 11–33 GiB of Apache-2.0 weights do not belong in a
release.

## What the recipient does

```bash
base=https://github.com/hrygo/ImageHive/releases/latest/download
curl -fsSLO "$base/imagehive-macos-arm64.tar.gz"
curl -fsSLO "$base/imagehive-macos-arm64.tar.gz.sha256"
shasum -a 256 -c imagehive-macos-arm64.tar.gz.sha256
tar -xzf imagehive-macos-arm64.tar.gz && cd imagehive-*
bash install.sh
```

Then restart their agent and ask for an image. Nothing else: no Xcode, no Swift,
no `sudo`, no build step.

A release publishes the archive twice: under its versioned name
(`imagehive-<version>-macos-arm64.tar.gz`, for pinning) and under the stable
name above, so the one-liner does not have to be edited on every release. Both
have a matching `.sha256`.

The 0.6 rename **requires a new release**: the asset name went from
`sensenova-u1-macos-arm64.tar.gz` to `imagehive-macos-arm64.tar.gz`, and
`releases/latest/download/<asset>` only resolves against the newest release. An
old release does not carry the new name, so the documented one-liner 404s the day
the rename lands.

### Why `bash install.sh` and not `./install.sh`

Anything that arrives over the network carries `com.apple.quarantine`, and
Gatekeeper refuses to *execute* a quarantined file. Measured on macOS 26:

* a quarantined **Mach-O binary** hangs — the process waits in `syspolicyd` for a
  consent dialog that a terminal install never shows;
* a quarantined **shell script** runs fine when `bash` reads it (`bash install.sh`
  works on a freshly downloaded copy);
* BSD `install` and `cp` **propagate** the flag to their destination, so the
  binaries would land in `~/.local/share/imagehive/bin/` still quarantined and
  every MCP client launch would block.

So the installer clears `com.apple.quarantine` from the files it installs
(`dequarantine` in `install.sh`), and the README tells people to invoke it
through `bash`. No signing identity and no notarisation are involved; if you do
want a signed build, sign `prebuilt/imagehived` and
`prebuilt/imagehive-mcp` with your Developer ID before `make release` and this
step becomes redundant for the binaries (the flag would still be cleared).

## Offline and locked-down machines

1. Run the installer anywhere once to get the artifact (`imagehive models`),
   or download a published `mlx-community/*` artifact by hand.
2. Copy the tarball **and** the artifact directory
   (`<owner>-SenseNova-U1.5-8B-MoT-*`) to the target machine.
3. There, put the artifact under
   `~/Library/Application Support/ImageHive/models/` and run
   `bash install.sh --model none` — it keeps what is already on disk.

## Cutting a release

The version is `IH_VERSION` in `cli/lib/common.sh` — bump it, then:

```bash
V=0.6.1                    # tag first: BUILD-INFO.txt records git describe
git tag -a "v$V" -m "…" && git push origin "v$V"
make release-verify        # builds dist/, installs the tarball into a throwaway HOME
gh release create "v$V" --repo hrygo/ImageHive --title "…" --notes-file - \
  "dist/imagehive-$V-macos-arm64.tar.gz" \
  "dist/imagehive-$V-macos-arm64.tar.gz.sha256" \
  dist/imagehive-macos-arm64.tar.gz \
  dist/imagehive-macos-arm64.tar.gz.sha256
```

Four things that are easy to get wrong, all learned the hard way:

* **Tag first, then build.** `BUILD-INFO.txt` records `git describe`, so building
  before the tag ships an archive that says `revision v0.5.0-18-gc8679f9` instead of
  `v0.5.2` — the number a user picks to compare against `project_version`.
* **Upload the stable name as well.** `releases/latest/download/imagehive-macos-arm64.tar.gz`
  is what the README tells people to `curl`, and it only resolves because some release
  carries an asset with exactly that name.
* **Pass `--repo hrygo/ImageHive`.** This checkout also has `upstream`
  (where the port came from), and `gh` resolves the repository to it by default: the create
  fails with "tag … has not been pushed to xocialize/sensenova-u1-swift", or lands in
  the wrong place if a matching tag exists there.
* **Then check it the way a user would** — download the stable name anonymously and
  compare against the `.sha256` asset, rather than trusting the upload:

```bash
base=https://github.com/hrygo/ImageHive/releases/latest/download
curl -fsSLO "$base/imagehive-macos-arm64.tar.gz{,.sha256}"
shasum -a 256 -c imagehive-macos-arm64.tar.gz.sha256
```

## Checklist before handing it over

- [ ] `make release-verify` passes (it installs the tarball into a throwaway HOME,
      with the files quarantined, using `--skip-build`).
- [ ] `shasum -a 256 -c <tarball>.sha256` passes on the archive you are shipping.
- [ ] The tarball name carries the version from `cli/lib/common.sh`.
- [ ] You did not add weights, `dist/` or `.build/` to the archive.
- [ ] `CHANGELOG.md` has an entry for that version.

## Not done yet

* No Apple Developer ID signature or notarisation.
* No Homebrew formula or cask.
* No mirror reachable without a proxy from China: `releases/latest/download` is
  GitHub, which may need help to reach from some networks. Handing over the
  archive as a file is the fallback, and it installs exactly the same way.
