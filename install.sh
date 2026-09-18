#!/usr/bin/env bash
# One-command install of imagehive — the resident local image service
# (SenseNova-U1.5-8B-MoT on MLX) that MCP agents call.
#
#   ./install.sh                    # default: 4-bit fast tier, wire detected clients
#   ./install.sh --model both       # also pull the bf16 quality tier (~33 GiB)
#   ./install.sh --model none       # use artifacts you already have
#   ./install.sh --dry-run          # print every action, change nothing
#   bash install.sh ...             # works even when the copy is quarantined
#
# Where things go (Docs/LAYOUT.md; every path is overridable):
#   ~/Library/Application Support/ImageHive/  config.json, service.conf, imagehived.sock, models/
#   ~/.local/bin/imagehive                    the command (~/.local/share/imagehive holds it)
#   ~/Library/Logs/ImageHive/imagehived.log   daemon log
#   ~/Pictures/ImageHive/                     generated images
#
# Steps: preflight -> the 0.6 rename (old daemon, old paths) -> model artifacts ->
# build -> install binaries -> retire the old names -> config -> LaunchAgent ->
# MCP clients -> smoke test. Safe to re-run: every step is idempotent and only
# reports what it changed.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cli/lib/common.sh
. "$REPO_DIR/cli/lib/common.sh"
# shellcheck source=cli/lib/models.sh
. "$REPO_DIR/cli/lib/models.sh"
# shellcheck source=cli/lib/clients.sh
. "$REPO_DIR/cli/lib/clients.sh"

DRY_RUN=0
ASSUME_YES=0
MODEL_CHOICE="fast"
SOURCE="auto"
CLIENTS_CHOICE="auto"
DO_BUILD="yes"
DO_SMOKE_GENERATE=0
# Whether the label came from --label (or service.conf) rather than from the
# default: the 0.6 migration renames a *custom* label in place, and an explicit
# choice on the command line must win over that inference.
LABEL_GIVEN=0

# Everything after line 1 up to the first non-comment line is the usage text.
usage() { awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "${BASH_SOURCE[0]}"; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)     DRY_RUN=1; shift ;;
    --yes|-y)      ASSUME_YES=1; shift ;;
    --model)       MODEL_CHOICE="${2:-}"; shift 2 ;;
    --source)      SOURCE="${2:-}"; shift 2 ;;
    --clients)     CLIENTS_CHOICE="${2:-}"; shift 2 ;;
    --home)        IMAGEHIVE_HOME="${2:-}"; shift 2 ;;
    --models)      IMAGEHIVE_MODELS="${2:-}"; shift 2 ;;
    --out)         IMAGEHIVE_OUT="${2:-}"; shift 2 ;;
    --prefix)      IMAGEHIVE_PREFIX="${2:-}"; shift 2 ;;
    --label)       IMAGEHIVE_LABEL="${2:-}"; LABEL_GIVEN=1; shift 2 ;;
    --legacy-home) IMAGEHIVE_LEGACY_HOME="${2:-}"; shift 2 ;;
    --fast-artifact)    IMAGEHIVE_FAST_ARTIFACT="${2:-}"; shift 2 ;;
    --quality-artifact) IMAGEHIVE_QUALITY_ARTIFACT="${2:-}"; shift 2 ;;
    --skip-build)  DO_BUILD="no"; shift ;;
    --smoke-generate) DO_SMOKE_GENERATE=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *)             usage; die "unknown option: $1" ;;
  esac
done

ih_load_conf
# A label recorded in an existing service.conf is that install's own choice as much
# as a `--label` on this command line is. Asked of the file, not of the variable:
# `ih_load_conf` exports the *resolved* label, so by now IMAGEHIVE_LABEL is always
# set — the default included.
if [ -f "$(ih_conf)" ] && grep -q '^IMAGEHIVE_LABEL=' "$(ih_conf)" 2>/dev/null; then
  LABEL_GIVEN=1
fi
# Hand this build's version to every child process as well as to service.conf. The
# daemon reports it in `status`, and one started before the file is written (or from a
# checkout whose conf is from an older install) would otherwise answer "unknown".
export IMAGEHIVE_VERSION="$IH_VERSION"

# Previous layout: everything (weights, binaries, images, config) in one
# directory. Detected and migrated below; overridable for unusual setups.
OLD_LAYOUT_HOME="${IMAGEHIVE_LEGACY_HOME:-$HOME/Models/SenseNova-U1.5}"

run() { # every mutating action goes through here, so --dry-run is honest
  if [ "$DRY_RUN" = "1" ]; then
    printf '  %swould run:%s %s\n' "$IH_DIM" "$IH_RESET" "$*" >&2
    return 0
  fi
  "$@"
}

# `hint`, for a line that states what *has* happened. Under --dry-run the "would
# run:" line above it is the whole truth, and a past-tense hint beside it reads
# as if the move had already been made.
did() { [ "$DRY_RUN" = "1" ] && return 0; hint "$*"; }

write_file() { # <path> ; content on stdin
  local path="$1"
  if [ "$DRY_RUN" = "1" ]; then
    printf '  %swould write:%s %s\n' "$IH_DIM" "$IH_RESET" "$path" >&2
    cat >/dev/null
    return 0
  fi
  mkdir -p "$(dirname "$path")"
  cat > "$path"
}

# Files that arrive from a download — a release tarball, a browser, AirDrop —
# carry com.apple.quarantine. Gatekeeper then refuses to run the Mach-O binaries
# this installer puts in place: the process blocks on a consent dialog that a
# terminal install never shows (measured: a quarantined imagehive-mcp hangs in
# `syspolicyd` until the user answers), and BSD `install`/`cp` propagate the flag
# to the copies. Shell scripts read by bash are not gated, which is why
# `bash install.sh` still works on a freshly downloaded copy.
#
# Clearing the flag from the files this installer owns is the whole fix; it needs
# no signing identity and no notarisation. Only our own install targets are
# touched, never the user's other files.
dequarantine() { # <path ...> ; prints the paths that were actually quarantined
  [ "$DRY_RUN" = "1" ] && return 0
  ih_have xattr || return 0
  local target found=0
  for target in "$@"; do
    [ -e "$target" ] || continue
    if xattr -p com.apple.quarantine "$target" >/dev/null 2>&1; then
      xattr -dr com.apple.quarantine "$target" 2>/dev/null || true
      say "  cleared the download quarantine flag on $target"
      found=1
    fi
  done
  [ "$found" = "1" ] || return 0
  hint "     (a quarantined binary would hang on a Gatekeeper prompt; Docs/DISTRIBUTING.md)"
}

# ---------------------------------------------------------------- preflight --

preflight() {
  step "preflight"
  [ "$(ih_host_arch)" = "arm64" ] || die "this service needs Apple silicon (MLX); found $(ih_host_arch)"

  local macos; macos="$(ih_macos)"
  case "$macos" in
    2[6-9].*|[3-9][0-9].*) hint "macOS $macos" ;;
    *) die "macOS $macos is too old: the package targets macOS 26+" ;;
  esac

  local ram; ram="$(ih_host_ram_gb)"
  if [ "$ram" -ge 32 ]; then
    hint "unified memory ${ram}GB"
  elif [ "$ram" -ge 18 ]; then
    warn "unified memory ${ram}GB — the 4-bit tier fits, but close other heavy apps"
  elif [ "$MODEL_CHOICE" = "none" ]; then
    # No weights are being installed, so nothing here will ever be run. The gate
    # belongs to the moment an artifact is chosen (`imagehive models`), and
    # blocking `--model none` would make it impossible to stage the binaries on a
    # small machine — or, in CI, to install a release tarball on a runner.
    hint "unified memory ${ram}GB — no model artifact is being installed"
  elif [ "$DRY_RUN" = "1" ]; then
    # A dry run is how someone on a small machine finds out what installing would
    # take; refusing to even print the plan would hide that. The gate still applies
    # to a real install, one line below.
    warn "unified memory ${ram}GB is below the smallest artifact's peak (~15GB) — a real install would refuse here"
  else
    die "unified memory ${ram}GB is too small (the smallest artifact peaks around 15GB)"
  fi

  if [ "$DO_BUILD" = "no" ]; then
    [ -x "$REPO_DIR/prebuilt/imagehived" ] \
      || die "--skip-build needs prebuilt/imagehived and prebuilt/imagehive-mcp"
  else
    ih_have swift || die "Swift toolchain not found — install Xcode 27 (xcode-select --install is not enough for Metal)"
    if ! xcrun -find metal >/dev/null 2>&1; then
      die "Metal toolchain missing. Run: xcodebuild -downloadComponent MetalToolchain   (Xcode 27 splits it into a separate download)"
    fi
    hint "swift $(swift --version 2>/dev/null | head -1 | awk '{print $4}'), metal toolchain present"
  fi

  # python3 is not a nicety: the artifact downloader parses the ModelScope /
  # Hugging Face listings with it, the client wiring edits JSON/JSONC configs with
  # it, and the CLI reads config.json with it. Saying so here beats dying twenty
  # minutes into a 33 GiB download.
  if ! ih_have python3; then
    die "python3 is required and was not found.
       macOS ships python3 with the Command Line Tools:  xcode-select --install
       (about 1.5 GB, one time), or with Homebrew:        brew install python"
  fi
  ih_have curl || die "curl not found"

  local need_gb=6 avail_gb
  case "$MODEL_CHOICE" in
    both) need_gb=48 ;;
    none) need_gb=4 ;;
    *)    need_gb=16 ;;
  esac
  # Weights are the big tenant, so measure the volume that will hold them.
  local disk_root; disk_root="$(ih_models)"
  while [ ! -d "$disk_root" ] && [ "$disk_root" != "/" ]; do disk_root="$(dirname "$disk_root")"; done
  avail_gb="$(df -g "$disk_root" 2>/dev/null | awk 'NR==2{print $4}')"
  if [ -n "$avail_gb" ] && [ "$avail_gb" -lt "$need_gb" ]; then
    die "not enough disk space: ${avail_gb}GB free, this install needs about ${need_gb}GB (plus the build tree)"
  fi
  hint "disk: ${avail_gb:-?}GB free"
}

# --------------------------------------------------------------- 0.6 rename --

# This project was called `sensenova-u1` up to 0.5.2, and a machine that installed
# it still holds state under those names. Two things have to happen before anything
# is built or started:
#
#   * the daemon from that install has to go. It holds a second copy of the
#     weights — the one thing this project exists to avoid — and because the home
#     below moves, its socket file moves with it: the new daemon then probes the
#     new path, finds a live answer, and exits 3 without binding, so the new build
#     looks installed while every reply still comes from the old one;
#   * the artifacts have to be found where they already are. 15–35 GB is a
#     download, not a hiccup, and nothing in the new layout points at the old home.
#
# Only the default locations are migrated: an install that used --home/--out has
# nothing here to find, and moving a path the user chose is worse than leaving it.
migrate_brand_home() {
  local from_home="$IH_LEGACY_HOME" from_out="$IH_LEGACY_OUT"
  local from_log="$IH_LEGACY_LOG_DIR" to_log="$HOME/Library/Logs/ImageHive"
  local migrated=0

  # The old daemon and the socket file it left behind. First, not last: everything
  # below moves the directories it is holding open.
  #
  # Guarded, because this is the one step here that cannot be undone by printing a
  # line instead of running it: it signals processes. A first version called it
  # unconditionally and a `--dry-run` on the author's machine really did stop the
  # service that was running at the time.
  if [ "$DRY_RUN" = "1" ]; then
    printf '  %swould run:%s stop any pre-0.6 daemon and clear its socket file\n' \
      "$IH_DIM" "$IH_RESET" >&2
  else
    ih_service_reap_legacy
  fi

  # The old job would start the old daemon again at the next login. Found by
  # content, not by name: the label is user-settable, and the machine this was
  # written on runs the old install under `com.hrygo.sensenova-u1`, so matching
  # the default label alone would have left its job in place.
  local plist label
  for plist in "$HOME/Library/LaunchAgents"/*.plist; do
    [ -f "$plist" ] || continue
    if ! grep -qE "$IH_LEGACY_DAEMON|$IH_LEGACY_SHARE" "$plist" 2>/dev/null; then continue; fi
    label="$(basename "$plist" .plist)"
    # Renamed, not just dropped. Whoever runs `--label com.hrygo.sensenova-u1`
    # chose the `com.hrygo.` prefix, so the new job keeps it and only the brand
    # token changes: `com.hrygo.imagehive`. (On the machine this was written on,
    # that is exactly the label in use.) A label with no brand in it has nothing
    # to carry over, and an explicit --label wins over this inference.
    local renamed
    if [ "$LABEL_GIVEN" = "0" ] && renamed="$(ih_rename_legacy_label "$label")"; then
      export IMAGEHIVE_LABEL="$renamed"
      LABEL_GIVEN=1
      hint "the job is renamed with the rest: $label -> $renamed"
    fi
    if launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1; then
      step "the rename: unloading $label"
      run launchctl bootout "gui/$(id -u)/$label" || true
    fi
    run rm -f "$plist"
    did "removed the old launchd job $label"
    migrated=1
  done

  if [ -d "$from_home" ] && [ "$(ih_home)" = "$IH_DEFAULT_HOME" ]; then
    step "the rename: $from_home -> $IH_DEFAULT_HOME"
    if [ -e "$IH_DEFAULT_HOME" ]; then
      # Both exist: merging two app homes is not something an installer can guess
      # at (which config.json wins? whose artifacts?). Say what is where.
      warn "$IH_DEFAULT_HOME already exists — leaving $from_home untouched"
      warn "  its weights are not used by this install: move them into $(ih_models), or delete them"
    else
      run mv "$from_home" "$IH_DEFAULT_HOME"
      migrated=1
    fi
  fi

  if [ -d "$from_out" ] && [ "$(ih_out_dir)" = "$IH_DEFAULT_OUT" ] && [ ! -e "$IH_DEFAULT_OUT" ]; then
    run mv "$from_out" "$IH_DEFAULT_OUT"
    did "images: $from_out -> $IH_DEFAULT_OUT"
    migrated=1
  fi

  if [ -d "$from_log" ] && [ ! -d "$to_log" ]; then
    run mkdir -p "$(dirname "$to_log")"
    run mv "$from_log" "$to_log"
    # Plain `if`, not `[ … ] && …`: a false test as the last command of a block
    # ends the install under `set -e`.
    if [ -f "$to_log/served.log" ]; then
      run mv "$to_log/served.log" "$to_log/imagehived.log"
    fi
    did "log: $from_log -> $to_log"
    migrated=1
  fi

  if [ "$migrated" = "1" ]; then
    # The environment was renamed at the same time. A shell profile or a script
    # that still exports the old names is not an error anywhere — it is silently
    # ignored, and the process then resolves the *default* layout, which is how a
    # second daemon gets started (invariant 10). So name the mapping here.
    hint "environment variables were renamed with the rest: SENSENOVA_HOME -> IMAGEHIVE_HOME,"
    hint "  SENSENOVA_SOCKET -> IMAGEHIVE_SOCKET, SENSENOVA_MODELS -> IMAGEHIVE_MODELS,"
    hint "  SENSENOVA_OUT -> IMAGEHIVE_OUT, SENSENOVA_PREFIX -> IMAGEHIVE_PREFIX,"
    hint "  SENSENOVA_LABEL -> IMAGEHIVE_LABEL (0.6.0 in CHANGELOG.md lists the rest)"
  fi
  return 0
}

# ------------------------------------------------------------------- models --

migrate_legacy() {
  [ -d "$OLD_LAYOUT_HOME" ] || return 0
  step "migrating the previous layout"
  hint "$OLD_LAYOUT_HOME -> $(ih_home) (+ $(ih_models), $(ih_out_dir))"
  run mkdir -p "$(ih_home)" "$(ih_models)" "$(ih_out_dir)"

  local entry moved=0
  if [ -d "$OLD_LAYOUT_HOME/artifacts" ]; then
    for entry in "$OLD_LAYOUT_HOME/artifacts"/*; do
      [ -e "$entry" ] || continue
      [ -e "$(ih_models)/$(basename "$entry")" ] && { hint "already there: $(basename "$entry")"; continue; }
      run mv "$entry" "$(ih_models)/" && moved=1
    done
  fi
  if [ -d "$OLD_LAYOUT_HOME/src" ] && [ ! -e "$(ih_models)/src" ]; then
    run mv "$OLD_LAYOUT_HOME/src" "$(ih_models)/src" && moved=1
  fi
  if [ -d "$OLD_LAYOUT_HOME/out" ]; then
    for entry in "$OLD_LAYOUT_HOME/out"/*; do
      [ -e "$entry" ] || continue
      [ -e "$(ih_out_dir)/$(basename "$entry")" ] && continue
      run mv "$entry" "$(ih_out_dir)/" && moved=1
    done
  fi

  # A daemon started before the move still holds the socket and would keep
  # looking for artifacts under the old paths, so let it go; front ends start a
  # fresh one (with the new paths) on their next request. Only when something
  # actually moved: a re-run on an already-migrated machine must not kill a
  # serving daemon for nothing.
  if [ "$moved" = "1" ] && pgrep -f "imagehived" >/dev/null 2>&1; then
    hint "stopping the daemon that is still running with the old paths"
    ih_service_stop >/dev/null 2>&1 || true
    run pkill -f "imagehived" || true
  fi
  [ "$moved" = "1" ] || hint "nothing left to move — only the compatibility wrappers remain"

  # The old config pinned artifacts as "artifacts/<name>" (relative to the old
  # home) or as absolute paths underneath it. Under the new layout a bare name
  # is relative to the models root, which is where those files just moved.
  if [ "$DRY_RUN" = "0" ] && [ -f "$OLD_LAYOUT_HOME/config.json" ] && [ ! -f "$(ih_config)" ]; then
    # NB: the alternation below means the delimiter cannot be "|".
    if sed -E -e 's#("(fast_|quality_)?artifact"[[:space:]]*:[[:space:]]*)"artifacts/#\1"#' \
              -e "s#(\"(fast_|quality_)?artifact\"[[:space:]]*:[[:space:]]*)\"$OLD_LAYOUT_HOME/artifacts/#\\1\"#" \
              "$OLD_LAYOUT_HOME/config.json" > "$(ih_config)"; then
      hint "wrote $(ih_config) from the old config (artifact paths adjusted)"
    else
      rm -f "$(ih_config)"
      warn "could not rewrite $OLD_LAYOUT_HOME/config.json — a fresh one will be written"
    fi
  fi

}

# ------------------------------------------------------------------- models --

choose_presets() {
  case "$MODEL_CHOICE" in
    none) return 0 ;;   # prints nothing: keep whatever is on disk
    fast) printf '%s\n' fast-4bit ;;
    quality) printf '%s\n' quality-bf16 ;;
    both) printf '%s\n' fast-4bit quality-bf16 ;;
    all) ih_preset_names ;;
    *) ih_preset_entry "$MODEL_CHOICE" >/dev/null || die "unknown model preset: $MODEL_CHOICE (fast|quality|both|all|none)"
       printf '%s\n' "$MODEL_CHOICE" ;;
  esac
}

fetch_models() {
  local presets; presets="$(choose_presets)"
  if [ -z "$presets" ]; then
    step "models"
    hint "--model none: keeping the artifacts already on disk"
    return 0
  fi
  step "model artifacts"
  local preset
  for preset in $presets; do
    ih_download_preset "$preset" "$SOURCE"
  done
}

write_daemon_config() {
  local presets; presets="$(choose_presets)"
  if [ -z "$presets" ] && [ -f "$(ih_config)" ]; then
    step "daemon config"
    hint "keeping $(ih_config) (--model none)"
    return 0
  fi
  local fast quality
  if printf '%s\n' "$presets" | grep -q '^fast-'; then
    # Artifact names are relative to the models root, not to the app home.
    fast="$(ih_preset_repo fast-4bit | tr '/' '-')"
    [ -d "$(ih_models)/$fast" ] || fast="$(ih_preset_repo fast-8bit | tr '/' '-')"
  else
    fast="$(ih_fast_artifact)"
  fi
  if printf '%s\n' "$presets" | grep -q '^quality-'; then
    quality="$(ih_preset_repo quality-bf16 | tr '/' '-')"
  else
    quality="$(ih_quality_artifact)"
  fi
  if [ "$(ih_artifact_dir fast)" = "$(ih_artifact_dir quality)" ]; then
    die "fast and quality would point at the same artifact — pass --model none or pick a second tier"
  fi
  if [ -z "$presets" ]; then
    # --model none without an existing config: write what we know and say so.
    warn "no model was selected, so the tier paths below may not exist yet;"
    warn "download one with: imagehive models pull fast-4bit"
  fi

  step "daemon config"
  write_file "$(ih_config)" <<JSON
{
  "ttl_seconds": 600,
  "min_warm_seconds": 60,
  "fast_artifact": "$fast",
  "quality_artifact": "$quality"
}
JSON
  hint "$(ih_config): fast=$fast quality=$quality (relative to $(ih_models))"
  for dir in "$(ih_models)/$fast" "$(ih_models)/$quality"; do
    [ -f "$dir/config.json" ] || warn "artifact not present yet: $dir"
  done
  # One artifact is a supported setup: the daemon serves the tiers whose artifact
  # is missing from the one that is installed, at that artifact's own recipe, and
  # says so in the reply. Worth a line, since the config names two paths.
  local have=""
  [ -f "$(ih_models)/$fast/config.json" ] && have="fast"
  [ -f "$(ih_models)/$quality/config.json" ] && have="${have:+$have }quality"
  case "$have" in
    fast|quality) hint "only the $have artifact is installed — requests for the other tier are served by it (Docs/MODELS.md)" ;;
  esac
}

# -------------------------------------------------------------------- build --

build_binaries() {
  step "build"
  if [ "$DO_BUILD" = "no" ]; then
    hint "--skip-build: using prebuilt/ binaries"
    return 0
  fi
  [ -f "$REPO_DIR/Package.swift" ] || die "Package.swift not found in $REPO_DIR"
  if [ "$DRY_RUN" = "1" ]; then
    printf '  %swould run:%s swift build -c release (both products)\n' "$IH_DIM" "$IH_RESET" >&2
    return 0
  fi
  ( cd "$REPO_DIR" && swift build -c release --product imagehived )
  ( cd "$REPO_DIR" && swift build -c release --product imagehive-mcp )
}

install_binaries() {
  step "install"
  local bin; bin="$(ih_bin_dir)"
  run mkdir -p "$bin"
  local out="$REPO_DIR/.build/release"
  [ "$DO_BUILD" = "no" ] && out="$REPO_DIR/prebuilt"
  [ -x "$out/imagehived" ] || die "missing build product: $out/imagehived"

  run install -m 0755 "$out/imagehived" "$bin/imagehived"
  run install -m 0755 "$out/imagehive-mcp" "$bin/imagehive-mcp"
  if [ "$DRY_RUN" = "0" ]; then
    local bundle
  for bundle in "$out"/*.bundle; do
    [ -e "$bundle" ] || continue
    rm -rf "$bin/$(basename "$bundle")"
    cp -R "$bundle" "$bin/"
  done
  fi
  dequarantine "$bin/imagehived" "$bin/imagehive-mcp" "$bin"/*.bundle
  hint "binaries + MLX resource bundles -> $bin"

  # The management CLI keeps its helper scripts next to it in share/.
  local share; share="$(ih_prefix)/share/imagehive"
  run mkdir -p "$share" "$(ih_prefix)/bin"
  run cp -R "$REPO_DIR/cli/." "$share/"
  run chmod +x "$share/imagehive" "$share"/lib/*.py
  run ln -sf "$share/imagehive" "$(ih_cli_path)"
  dequarantine "$share" "$(ih_cli_path)"
  hint "command installed: $(ih_cli_path)"
}

# MCP entries written before the layout change point at <legacy>/bin/* with
# IMAGEHIVE_HOME=<legacy>. Those paths live in client configs and in sessions
# that are already running, so leave small wrappers that re-export the new
# paths and exec the real binary: old entries keep working, and every session
# stays on ONE socket — which is what keeps it to one copy of the weights.
# Delete the legacy directory once the clients have been restarted.
link_legacy_home() {
  [ -d "$OLD_LAYOUT_HOME" ] || return 0
  [ -d "$OLD_LAYOUT_HOME/bin" ] || return 0
  if [ "$DRY_RUN" = "1" ]; then
    printf '  %swould write:%s %s/bin/{imagehive-mcp,imagehived} (compatibility wrappers)\n' \
      "$IH_DIM" "$IH_RESET" "$OLD_LAYOUT_HOME" >&2
    return 0
  fi
  local product
  for product in imagehive-mcp imagehived; do
    [ -e "$(ih_bin_dir)/$product" ] || continue
    cat > "$OLD_LAYOUT_HOME/bin/$product" <<SHIM
#!/bin/sh
# Compatibility wrapper for the pre-$IH_VERSION layout: the service moved to
# ~/Library/Application Support/ImageHive (see Docs/LAYOUT.md). Re-run
# ./install.sh, restart the MCP clients, then delete $OLD_LAYOUT_HOME.
export IMAGEHIVE_HOME="$(ih_home)"
export IMAGEHIVE_MODELS="$(ih_models)"
export IMAGEHIVE_OUT="$(ih_out_dir)"
export IMAGEHIVE_SOCKET="$(ih_socket)"
# The prefix and the label too: the front end this wrapper starts reads them to find
# the daemon and the launchd job.
export IMAGEHIVE_PREFIX="$(ih_prefix)"
export IMAGEHIVE_LABEL="$(ih_label)"
exec "$(ih_bin_dir)/$product" "\$@"
SHIM
    chmod 0755 "$OLD_LAYOUT_HOME/bin/$product"
  done
  hint "compatibility wrappers left in $OLD_LAYOUT_HOME/bin (old client entries keep working)"
}

# Old *names*, handled after the new binaries are in place. MCP client entries and
# already-running sessions still point at them, so they have to keep working — and
# none of them may reach the pre-0.6 scripts, whose defaults are the old home and
# the old socket: that is one more daemon, one more copy of the weights.
retire_legacy_names() {
  [ -d "$IH_LEGACY_SHARE" ] || [ -e "$IH_LEGACY_CLI" ] || [ -L "$IH_LEGACY_CLI" ] || return 0
  step "the rename: retiring the old names"

  local bin="$IH_LEGACY_SHARE/bin" pair old new
  if [ -d "$bin" ]; then
    # The two binaries keep their old paths — client entries point straight at
    # them — but become wrappers onto the new ones, with the layout this install
    # resolved. Same trick as the pre-0.2 wrappers above, and for the same reason:
    # every path into the service has to end at the same socket.
    for pair in "$IH_LEGACY_DAEMON:imagehived" "$IH_LEGACY_MCP:imagehive-mcp"; do
      old="${pair%%:*}"; new="${pair##*:}"
      write_file "$bin/$old" <<SHIM
#!/bin/sh
# Compatibility wrapper for the pre-0.6 name: the service is now imagehive.
# Re-run ./install.sh, restart the MCP clients, then delete $IH_LEGACY_SHARE.
export IMAGEHIVE_HOME="$(ih_home)"
export IMAGEHIVE_MODELS="$(ih_models)"
export IMAGEHIVE_OUT="$(ih_out_dir)"
export IMAGEHIVE_SOCKET="$(ih_socket)"
export IMAGEHIVE_PREFIX="$(ih_prefix)"
export IMAGEHIVE_LABEL="$(ih_label)"
export IMAGEHIVE_DAEMON_BIN="$(ih_bin_dir)/$new"
exec "$(ih_bin_dir)/$new" "\$@"
SHIM
      run chmod 0755 "$bin/$old"
    done
    hint "$bin/* now forward to the new binaries (same socket, same weights)"
  fi

  # The old command and its libraries are the dangerous part: they resolve the
  # pre-0.6 home, find nothing there, and start a daemon of their own. Drop them.
  local old_cli_script="$IH_LEGACY_SHARE/${IH_LEGACY_CLI##*/}"
  if [ -e "$old_cli_script" ] || [ -d "$IH_LEGACY_SHARE/lib" ]; then
    if [ -e "$old_cli_script" ]; then run rm -f "$old_cli_script"; fi
    if [ -d "$IH_LEGACY_SHARE/lib" ]; then run rm -rf "$IH_LEGACY_SHARE/lib"; fi
    hint "removed the pre-0.6 command and its libraries from $IH_LEGACY_SHARE"
  fi

  # The old command name itself. `rm` before writing: the path is normally a
  # symlink into the directory just cleaned, and writing through it would put the
  # shim where the old script used to be instead of at the name the user types.
  if [ -e "$IH_LEGACY_CLI" ] || [ -L "$IH_LEGACY_CLI" ]; then
    run rm -f "$IH_LEGACY_CLI"
    write_file "$IH_LEGACY_CLI" <<SHIM
#!/bin/sh
# The command was renamed to imagehive in 0.6.0; this keeps the old name working.
printf '%s\n' 'sensenova-u1 is now imagehive — re-run ./install.sh, this wrapper goes away with it' >&2
exec "$(ih_cli_path)" "\$@"
SHIM
    run chmod 0755 "$IH_LEGACY_CLI"
    hint "old command name kept alive: $IH_LEGACY_CLI -> $(ih_cli_path)"
  fi

  # Client entries written under the old name. A dry run must not touch the user's
  # client configs, so it says what it would do instead.
  if [ "$DRY_RUN" = "1" ]; then
    printf '  %swould run:%s remove the pre-0.6 MCP entries from every detected client\n' \
      "$IH_DIM" "$IH_RESET" >&2
  else
    ih_client_remove_legacy
  fi
}

write_conf_and_service() {
  step "configuration"
  if [ "$DRY_RUN" = "0" ]; then
    ih_write_conf
    hint "wrote $(ih_conf)"
  else
    printf '  %swould write:%s %s\n' "$IH_DIM" "$IH_RESET" "$(ih_conf)" >&2
  fi

  # This heredoc is deliberately unquoted so $(ih_*) expands. That also means
  # backticks or $( ) anywhere in the body — comments included — are executed,
  # so keep the template free of both.
  write_file "$(ih_plist)" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$(ih_label)</string>
	<key>ProgramArguments</key>
	<array>
		<string>$(ih_daemon)</string>
	</array>
	<key>EnvironmentVariables</key>
	<dict>
		<key>HOME</key>
		<string>$HOME</string>
		<key>IMAGEHIVE_HOME</key>
		<string>$(ih_home)</string>
		<key>IMAGEHIVE_MODELS</key>
		<string>$(ih_models)</string>
		<key>IMAGEHIVE_OUT</key>
		<string>$(ih_out_dir)</string>
	</dict>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<false/>
	<key>ProcessType</key>
	<string>Background</string>
	<!-- launchd throttles respawns; the 10s default would also delay every
	     explicit restart by that much. 1s still damps a crash loop. -->
	<key>ThrottleInterval</key>
	<integer>1</integer>
	<key>StandardOutPath</key>
	<string>$(ih_log)</string>
	<key>StandardErrorPath</key>
	<string>$(ih_log)</string>
</dict>
</plist>
PLIST
  hint "launchd job -> $(ih_plist) (loads at login; the weights still load on demand)"

  if [ "$DRY_RUN" = "1" ]; then
    printf '  %swould run:%s launchctl bootstrap + kickstart %s\n' "$IH_DIM" "$IH_RESET" "$(ih_label)" >&2
    return 0
  fi
  ih_service_stop >/dev/null 2>&1 || true
  ih_service_start
  hint "service loaded; the first request starts a daemon if none is serving yet"

  # Assert that the daemon *answering* is this build. A process started by an MCP
  # front end before this install keeps the socket (the launched job then exits 3
  # without binding), so the install can look perfect while every answer still comes
  # from the previous binary. `ih_service_stop` reaps it, but say so if it survived.
  #
  # "It answered without a version" and "it did not answer" are different things, and
  # the second one used to be reported as if it were the first: `ih_status` prints
  # "daemon unreachable" and exits 1, which this check read as a version mismatch.
  local status_out serving
  if ih_socket_listening; then
    status_out="$(ih_status 2>/dev/null || true)"
    serving="$(printf '%s\n' "$status_out" | awk -F= '$1=="project_version"{print $2}')"
    if [ "$serving" = "$IH_VERSION" ]; then
      hint "daemon $serving is serving pid $(printf '%s\n' "$status_out" | awk -F= '$1=="pid"{print $2}')"
    else
      warn "the daemon answering on $(ih_socket) is ${serving:-an older build}, not $IH_VERSION — run: imagehive restart"
    fi
  else
    warn "nothing is answering on $(ih_socket) yet — the launchd job starts it on demand; check $(ih_log)"
  fi
}

wire_clients() {
  # Dry runs should read like English, not like an internal call.
  wire_one() {
    if [ "$DRY_RUN" = "1" ]; then
      printf '  %swould wire:%s %s\n' "$IH_DIM" "$IH_RESET" "$1" >&2
      return 0
    fi
    ih_client_try "$1"
  }
  case "$CLIENTS_CHOICE" in
    none) return 0 ;;
    auto)
      step "MCP clients"
      local any=0 failed=0 name
      for name in $(ih_clients_detected); do
        if wire_one "$name"; then any=1; else
          warn "could not wire $name — wire it later with: imagehive clients add $name"
          failed=$((failed + 1))
        fi
      done
      if [ "$any" = "0" ] && [ "$failed" = "0" ]; then
        warn "no known MCP client detected — here is the snippet:"
        ih_print_snippet
      fi
      ;;
    *)
      step "MCP clients"
      local name
      for name in ${CLIENTS_CHOICE//,/ }; do
        wire_one "$name" \
          || warn "could not wire $name — see Docs/CLIENTS.md, then: imagehive clients add $name"
      done
      ;;
  esac
}

smoke_test() {
  step "smoke test"
  if [ "$DRY_RUN" = "1" ]; then
    printf '  %swould run:%s %s --status\n' "$IH_DIM" "$IH_RESET" "$(ih_mcp)" >&2
    return 0
  fi
  local tools
  tools="$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' \
    | "$(ih_mcp)" 2>/dev/null \
    | python3 -c 'import json,sys
for line in sys.stdin:
    names = [t["name"] for t in json.loads(line).get("result", {}).get("tools", [])]
    if names:
        print(" ".join(names))
        break' 2>/dev/null || true)"
  [ -n "$tools" ] || die "the MCP front end did not answer tools/list — check $(ih_log)"
  hint "tools: $tools"
  ih_status | sed 's/^/  /'

  if [ "$DO_SMOKE_GENERATE" = "1" ]; then
    say ""
    say "generating a test image (this also proves the weights load)…"
    # No --tier: the CLI picks whichever artifact this machine has installed.
    "$(ih_cli_path)" generate --prompt "a small brass compass on a dark wooden desk, soft light"
  fi
}

summary() {
  step "done"
  say "  service   $(ih_label)   ($(ih_daemon))"
  say "  command   $(ih_cli_path)"
  say "  home      $(ih_home)"
  say "  models    $(ih_models)"
  say "  output    $(ih_out_dir)"
  say "  logs      $(ih_log)"
  # A non-default home is invisible to a later shell: the CLI resolves the layout
  # from the environment and from <home>/service.conf, and with --home that file is
  # not where the defaults look. Say so here rather than letting `imagehive status`
  # report a different (or missing) service afterwards.
  if [ "$(ih_home)" != "$IH_DEFAULT_HOME" ] || [ "$(ih_prefix)" != "$IH_DEFAULT_PREFIX" ]; then
    say ""
    say "Note: this install is not in the default location, so a new shell needs the"
    say "      layout in its environment before imagehive finds it (the MCP entries"
    say "      written for the clients already carry it):"
    # Plain `if`s, not `[ … ] && …`: with `set -e` a false test as the last command of
    # the block would end the install here.
    if [ "$(ih_home)" != "$IH_DEFAULT_HOME" ]; then
      say "        export IMAGEHIVE_HOME=\"$(ih_home)\""
    fi
    if [ "$(ih_prefix)" != "$IH_DEFAULT_PREFIX" ]; then
      say "        export IMAGEHIVE_PREFIX=\"$(ih_prefix)\""
    fi
  fi
  if [ -d "$OLD_LAYOUT_HOME/bin" ] && [ "$DRY_RUN" = "0" ]; then
    say ""
    say "Note: $OLD_LAYOUT_HOME keeps compatibility wrappers for MCP clients wired"
    say "      before this change. Restart those clients, then delete that directory."
  fi
  say ""
  say "Next:"
  say "  imagehive doctor        check every moving part"
  say "  imagehive models        see which artifacts are installed"
  say "  imagehive clients list  see which clients are wired"
  # The command is installed into ~/.local/bin, which is not on PATH by default
  # on macOS. Say so here rather than letting the next command fail with
  # "command not found".
  case ":$PATH:" in
    *":$(ih_prefix)/bin:"*) ;;
    *) say ""
       say "Note: $(ih_prefix)/bin is not on your PATH, so type the whole path:"
       say "      $(ih_cli_path) doctor"
       say "      or add this to ~/.zprofile:  export PATH=\"$(ih_prefix)/bin:\$PATH\"" ;;
  esac
  say ""
  say "Then restart your agent (Codex, Claude, opencode, QwenPaw, …) so it picks"
  say "up the new MCP entry, and ask it for an image. The first call loads the"
  say "weights (~5 s); they are released again after 10 minutes idle."
}

main() {
  say "${IH_BOLD}imagehive${IH_RESET} — resident local image service for MCP agents, installer $IH_VERSION"
  [ "$DRY_RUN" = "1" ] && warn "dry run: nothing will be changed"
  preflight
  migrate_brand_home
  migrate_legacy
  fetch_models
  write_daemon_config
  build_binaries
  install_binaries
  retire_legacy_names
  link_legacy_home
  write_conf_and_service
  wire_clients
  smoke_test
  summary
}

main
