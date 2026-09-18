#!/usr/bin/env bash
# One-command install of the local SenseNova-U1.5 image service.
#
#   ./install.sh                    # default: 4-bit fast tier, wire detected clients
#   ./install.sh --model both       # also pull the bf16 quality tier (~33 GiB)
#   ./install.sh --model none       # use artifacts you already have
#   ./install.sh --dry-run          # print every action, change nothing
#   bash install.sh ...             # works even when the copy is quarantined
#
# Where things go (Docs/LAYOUT.md; every path is overridable):
#   ~/Library/Application Support/SenseNovaU1/  config.json, service.conf, served.sock, models/
#   ~/.local/bin/sensenova-u1                   the command (~/.local/share/sensenova-u1 holds it)
#   ~/Library/Logs/SenseNovaU1/served.log       daemon log
#   ~/Pictures/SenseNovaU1/                     generated images
#
# Steps: preflight -> model artifacts -> build -> install binaries -> config ->
# LaunchAgent -> MCP clients -> smoke test. Safe to re-run: every step is
# idempotent and only reports what it changed.

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

# Everything after line 1 up to the first non-comment line is the usage text.
usage() { awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "${BASH_SOURCE[0]}"; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)     DRY_RUN=1; shift ;;
    --yes|-y)      ASSUME_YES=1; shift ;;
    --model)       MODEL_CHOICE="${2:-}"; shift 2 ;;
    --source)      SOURCE="${2:-}"; shift 2 ;;
    --clients)     CLIENTS_CHOICE="${2:-}"; shift 2 ;;
    --home)        SENSENOVA_HOME="${2:-}"; shift 2 ;;
    --models)      SENSENOVA_MODELS="${2:-}"; shift 2 ;;
    --out)         SENSENOVA_OUT="${2:-}"; shift 2 ;;
    --prefix)      SENSENOVA_PREFIX="${2:-}"; shift 2 ;;
    --label)       SENSENOVA_LABEL="${2:-}"; shift 2 ;;
    --legacy-home) SENSENOVA_LEGACY_HOME="${2:-}"; shift 2 ;;
    --fast-artifact)    SENSENOVA_FAST_ARTIFACT="${2:-}"; shift 2 ;;
    --quality-artifact) SENSENOVA_QUALITY_ARTIFACT="${2:-}"; shift 2 ;;
    --skip-build)  DO_BUILD="no"; shift ;;
    --smoke-generate) DO_SMOKE_GENERATE=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *)             usage; die "unknown option: $1" ;;
  esac
done

sv_load_conf

# Previous layout: everything (weights, binaries, images, config) in one
# directory. Detected and migrated below; overridable for unusual setups.
LEGACY_HOME="${SENSENOVA_LEGACY_HOME:-$HOME/Models/SenseNova-U1.5}"

run() { # every mutating action goes through here, so --dry-run is honest
  if [ "$DRY_RUN" = "1" ]; then
    printf '  %swould run:%s %s\n' "$SV_DIM" "$SV_RESET" "$*" >&2
    return 0
  fi
  "$@"
}

write_file() { # <path> ; content on stdin
  local path="$1"
  if [ "$DRY_RUN" = "1" ]; then
    printf '  %swould write:%s %s\n' "$SV_DIM" "$SV_RESET" "$path" >&2
    cat >/dev/null
    return 0
  fi
  mkdir -p "$(dirname "$path")"
  cat > "$path"
}

# Files that arrive from a download — a release tarball, a browser, AirDrop —
# carry com.apple.quarantine. Gatekeeper then refuses to run the Mach-O binaries
# this installer puts in place: the process blocks on a consent dialog that a
# terminal install never shows (measured: a quarantined sensenova-mcp hangs in
# `syspolicyd` until the user answers), and BSD `install`/`cp` propagate the flag
# to the copies. Shell scripts read by bash are not gated, which is why
# `bash install.sh` still works on a freshly downloaded copy.
#
# Clearing the flag from the files this installer owns is the whole fix; it needs
# no signing identity and no notarisation. Only our own install targets are
# touched, never the user's other files.
dequarantine() { # <path ...> ; prints the paths that were actually quarantined
  [ "$DRY_RUN" = "1" ] && return 0
  sv_have xattr || return 0
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
  [ "$(sv_host_arch)" = "arm64" ] || die "this service needs Apple silicon (MLX); found $(sv_host_arch)"

  local macos; macos="$(sv_macos)"
  case "$macos" in
    2[6-9].*|[3-9][0-9].*) hint "macOS $macos" ;;
    *) die "macOS $macos is too old: the package targets macOS 26+" ;;
  esac

  local ram; ram="$(sv_host_ram_gb)"
  if [ "$ram" -ge 32 ]; then
    hint "unified memory ${ram}GB"
  elif [ "$ram" -ge 18 ]; then
    warn "unified memory ${ram}GB — the 4-bit tier fits, but close other heavy apps"
  elif [ "$MODEL_CHOICE" = "none" ]; then
    # No weights are being installed, so nothing here will ever be run. The gate
    # belongs to the moment an artifact is chosen (`sensenova-u1 models`), and
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
    [ -x "$REPO_DIR/prebuilt/sensenova-served" ] \
      || die "--skip-build needs prebuilt/sensenova-served and prebuilt/sensenova-mcp"
  else
    sv_have swift || die "Swift toolchain not found — install Xcode 27 (xcode-select --install is not enough for Metal)"
    if ! xcrun -find metal >/dev/null 2>&1; then
      die "Metal toolchain missing. Run: xcodebuild -downloadComponent MetalToolchain   (Xcode 27 splits it into a separate download)"
    fi
    hint "swift $(swift --version 2>/dev/null | head -1 | awk '{print $4}'), metal toolchain present"
  fi

  # python3 is not a nicety: the artifact downloader parses the ModelScope /
  # Hugging Face listings with it, the client wiring edits JSON/JSONC configs with
  # it, and the CLI reads config.json with it. Saying so here beats dying twenty
  # minutes into a 33 GiB download.
  if ! sv_have python3; then
    die "python3 is required and was not found.
       macOS ships python3 with the Command Line Tools:  xcode-select --install
       (about 1.5 GB, one time), or with Homebrew:        brew install python"
  fi
  sv_have curl || die "curl not found"

  local need_gb=6 avail_gb
  case "$MODEL_CHOICE" in
    both) need_gb=48 ;;
    none) need_gb=4 ;;
    *)    need_gb=16 ;;
  esac
  # Weights are the big tenant, so measure the volume that will hold them.
  local disk_root; disk_root="$(sv_models)"
  while [ ! -d "$disk_root" ] && [ "$disk_root" != "/" ]; do disk_root="$(dirname "$disk_root")"; done
  avail_gb="$(df -g "$disk_root" 2>/dev/null | awk 'NR==2{print $4}')"
  if [ -n "$avail_gb" ] && [ "$avail_gb" -lt "$need_gb" ]; then
    die "not enough disk space: ${avail_gb}GB free, this install needs about ${need_gb}GB (plus the build tree)"
  fi
  hint "disk: ${avail_gb:-?}GB free"
}

# ------------------------------------------------------------------- models --

migrate_legacy() {
  [ -d "$LEGACY_HOME" ] || return 0
  step "migrating the previous layout"
  hint "$LEGACY_HOME -> $(sv_home) (+ $(sv_models), $(sv_out_dir))"
  run mkdir -p "$(sv_home)" "$(sv_models)" "$(sv_out_dir)"

  local entry moved=0
  if [ -d "$LEGACY_HOME/artifacts" ]; then
    for entry in "$LEGACY_HOME/artifacts"/*; do
      [ -e "$entry" ] || continue
      [ -e "$(sv_models)/$(basename "$entry")" ] && { hint "already there: $(basename "$entry")"; continue; }
      run mv "$entry" "$(sv_models)/" && moved=1
    done
  fi
  if [ -d "$LEGACY_HOME/src" ] && [ ! -e "$(sv_models)/src" ]; then
    run mv "$LEGACY_HOME/src" "$(sv_models)/src" && moved=1
  fi
  if [ -d "$LEGACY_HOME/out" ]; then
    for entry in "$LEGACY_HOME/out"/*; do
      [ -e "$entry" ] || continue
      [ -e "$(sv_out_dir)/$(basename "$entry")" ] && continue
      run mv "$entry" "$(sv_out_dir)/" && moved=1
    done
  fi

  # A daemon started before the move still holds the socket and would keep
  # looking for artifacts under the old paths, so let it go; front ends start a
  # fresh one (with the new paths) on their next request. Only when something
  # actually moved: a re-run on an already-migrated machine must not kill a
  # serving daemon for nothing.
  if [ "$moved" = "1" ] && pgrep -f "sensenova-served" >/dev/null 2>&1; then
    hint "stopping the daemon that is still running with the old paths"
    sv_service_stop >/dev/null 2>&1 || true
    run pkill -f "sensenova-served" || true
  fi
  [ "$moved" = "1" ] || hint "nothing left to move — only the compatibility wrappers remain"

  # The old config pinned artifacts as "artifacts/<name>" (relative to the old
  # home) or as absolute paths underneath it. Under the new layout a bare name
  # is relative to the models root, which is where those files just moved.
  if [ "$DRY_RUN" = "0" ] && [ -f "$LEGACY_HOME/config.json" ] && [ ! -f "$(sv_config)" ]; then
    # NB: the alternation below means the delimiter cannot be "|".
    if sed -E -e 's#("(fast_|quality_)?artifact"[[:space:]]*:[[:space:]]*)"artifacts/#\1"#' \
              -e "s#(\"(fast_|quality_)?artifact\"[[:space:]]*:[[:space:]]*)\"$LEGACY_HOME/artifacts/#\\1\"#" \
              "$LEGACY_HOME/config.json" > "$(sv_config)"; then
      hint "wrote $(sv_config) from the old config (artifact paths adjusted)"
    else
      rm -f "$(sv_config)"
      warn "could not rewrite $LEGACY_HOME/config.json — a fresh one will be written"
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
    all) sv_preset_names ;;
    *) sv_preset_entry "$MODEL_CHOICE" >/dev/null || die "unknown model preset: $MODEL_CHOICE (fast|quality|both|all|none)"
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
    sv_download_preset "$preset" "$SOURCE"
  done
}

write_daemon_config() {
  local presets; presets="$(choose_presets)"
  if [ -z "$presets" ] && [ -f "$(sv_config)" ]; then
    step "daemon config"
    hint "keeping $(sv_config) (--model none)"
    return 0
  fi
  local fast quality
  if printf '%s\n' "$presets" | grep -q '^fast-'; then
    # Artifact names are relative to the models root, not to the app home.
    fast="$(sv_preset_repo fast-4bit | tr '/' '-')"
    [ -d "$(sv_models)/$fast" ] || fast="$(sv_preset_repo fast-8bit | tr '/' '-')"
  else
    fast="$(sv_fast_artifact)"
  fi
  if printf '%s\n' "$presets" | grep -q '^quality-'; then
    quality="$(sv_preset_repo quality-bf16 | tr '/' '-')"
  else
    quality="$(sv_quality_artifact)"
  fi
  if [ "$(sv_artifact_dir fast)" = "$(sv_artifact_dir quality)" ]; then
    die "fast and quality would point at the same artifact — pass --model none or pick a second tier"
  fi
  if [ -z "$presets" ]; then
    # --model none without an existing config: write what we know and say so.
    warn "no model was selected, so the tier paths below may not exist yet;"
    warn "download one with: sensenova-u1 models pull fast-4bit"
  fi

  step "daemon config"
  write_file "$(sv_config)" <<JSON
{
  "ttl_seconds": 600,
  "min_warm_seconds": 60,
  "fast_artifact": "$fast",
  "quality_artifact": "$quality"
}
JSON
  hint "$(sv_config): fast=$fast quality=$quality (relative to $(sv_models))"
  for dir in "$(sv_models)/$fast" "$(sv_models)/$quality"; do
    [ -f "$dir/config.json" ] || warn "artifact not present yet: $dir"
  done
  # One artifact is a supported setup: the daemon serves the tiers whose artifact
  # is missing from the one that is installed, at that artifact's own recipe, and
  # says so in the reply. Worth a line, since the config names two paths.
  local have=""
  [ -f "$(sv_models)/$fast/config.json" ] && have="fast"
  [ -f "$(sv_models)/$quality/config.json" ] && have="${have:+$have }quality"
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
    printf '  %swould run:%s swift build -c release (both products)\n' "$SV_DIM" "$SV_RESET" >&2
    return 0
  fi
  ( cd "$REPO_DIR" && swift build -c release --product sensenova-served )
  ( cd "$REPO_DIR" && swift build -c release --product sensenova-mcp )
}

install_binaries() {
  step "install"
  local bin; bin="$(sv_bin_dir)"
  run mkdir -p "$bin"
  local out="$REPO_DIR/.build/release"
  [ "$DO_BUILD" = "no" ] && out="$REPO_DIR/prebuilt"
  [ -x "$out/sensenova-served" ] || die "missing build product: $out/sensenova-served"

  run install -m 0755 "$out/sensenova-served" "$bin/sensenova-served"
  run install -m 0755 "$out/sensenova-mcp" "$bin/sensenova-mcp"
  if [ "$DRY_RUN" = "0" ]; then
    local bundle
  for bundle in "$out"/*.bundle; do
    [ -e "$bundle" ] || continue
    rm -rf "$bin/$(basename "$bundle")"
    cp -R "$bundle" "$bin/"
  done
  fi
  dequarantine "$bin/sensenova-served" "$bin/sensenova-mcp" "$bin"/*.bundle
  hint "binaries + MLX resource bundles -> $bin"

  # The management CLI keeps its helper scripts next to it in share/.
  local share; share="$(sv_prefix)/share/sensenova-u1"
  run mkdir -p "$share" "$(sv_prefix)/bin"
  run cp -R "$REPO_DIR/cli/." "$share/"
  run chmod +x "$share/sensenova-u1" "$share"/lib/*.py
  run ln -sf "$share/sensenova-u1" "$(sv_cli_path)"
  dequarantine "$share" "$(sv_cli_path)"
  hint "command installed: $(sv_cli_path)"
}

# MCP entries written before the layout change point at <legacy>/bin/* with
# SENSENOVA_HOME=<legacy>. Those paths live in client configs and in sessions
# that are already running, so leave small wrappers that re-export the new
# paths and exec the real binary: old entries keep working, and every session
# stays on ONE socket — which is what keeps it to one copy of the weights.
# Delete the legacy directory once the clients have been restarted.
link_legacy_home() {
  [ -d "$LEGACY_HOME" ] || return 0
  [ -d "$LEGACY_HOME/bin" ] || return 0
  if [ "$DRY_RUN" = "1" ]; then
    printf '  %swould write:%s %s/bin/{sensenova-mcp,sensenova-served} (compatibility wrappers)\n' \
      "$SV_DIM" "$SV_RESET" "$LEGACY_HOME" >&2
    return 0
  fi
  local product
  for product in sensenova-mcp sensenova-served; do
    [ -e "$(sv_bin_dir)/$product" ] || continue
    cat > "$LEGACY_HOME/bin/$product" <<SHIM
#!/bin/sh
# Compatibility wrapper for the pre-$SV_VERSION layout: the service moved to
# ~/Library/Application Support/SenseNovaU1 (see Docs/LAYOUT.md). Re-run
# ./install.sh, restart the MCP clients, then delete $LEGACY_HOME.
export SENSENOVA_HOME="$(sv_home)"
export SENSENOVA_MODELS="$(sv_models)"
export SENSENOVA_OUT="$(sv_out_dir)"
export SENSENOVA_SOCKET="$(sv_socket)"
exec "$(sv_bin_dir)/$product" "\$@"
SHIM
    chmod 0755 "$LEGACY_HOME/bin/$product"
  done
  hint "compatibility wrappers left in $LEGACY_HOME/bin (old client entries keep working)"
}

write_conf_and_service() {
  step "configuration"
  if [ "$DRY_RUN" = "0" ]; then
    sv_write_conf
    hint "wrote $(sv_conf)"
  else
    printf '  %swould write:%s %s\n' "$SV_DIM" "$SV_RESET" "$(sv_conf)" >&2
  fi

  # This heredoc is deliberately unquoted so $(sv_*) expands. That also means
  # backticks or $( ) anywhere in the body — comments included — are executed,
  # so keep the template free of both.
  write_file "$(sv_plist)" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$(sv_label)</string>
	<key>ProgramArguments</key>
	<array>
		<string>$(sv_served)</string>
	</array>
	<key>EnvironmentVariables</key>
	<dict>
		<key>HOME</key>
		<string>$HOME</string>
		<key>SENSENOVA_HOME</key>
		<string>$(sv_home)</string>
		<key>SENSENOVA_MODELS</key>
		<string>$(sv_models)</string>
		<key>SENSENOVA_OUT</key>
		<string>$(sv_out_dir)</string>
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
	<string>$(sv_log)</string>
	<key>StandardErrorPath</key>
	<string>$(sv_log)</string>
</dict>
</plist>
PLIST
  hint "launchd job -> $(sv_plist) (loads at login; the weights still load on demand)"

  if [ "$DRY_RUN" = "1" ]; then
    printf '  %swould run:%s launchctl bootstrap + kickstart %s\n' "$SV_DIM" "$SV_RESET" "$(sv_label)" >&2
    return 0
  fi
  sv_service_stop >/dev/null 2>&1 || true
  sv_service_start
  hint "service loaded; the first request starts a daemon if none is serving yet"
}

wire_clients() {
  # Dry runs should read like English, not like an internal call.
  wire_one() {
    if [ "$DRY_RUN" = "1" ]; then
      printf '  %swould wire:%s %s\n' "$SV_DIM" "$SV_RESET" "$1" >&2
      return 0
    fi
    sv_client_try "$1"
  }
  case "$CLIENTS_CHOICE" in
    none) return 0 ;;
    auto)
      step "MCP clients"
      local any=0 failed=0 name
      for name in $(sv_clients_detected); do
        if wire_one "$name"; then any=1; else
          warn "could not wire $name — wire it later with: sensenova-u1 clients add $name"
          failed=$((failed + 1))
        fi
      done
      if [ "$any" = "0" ] && [ "$failed" = "0" ]; then
        warn "no known MCP client detected — here is the snippet:"
        sv_print_snippet
      fi
      ;;
    *)
      step "MCP clients"
      local name
      for name in ${CLIENTS_CHOICE//,/ }; do
        wire_one "$name" \
          || warn "could not wire $name — see Docs/CLIENTS.md, then: sensenova-u1 clients add $name"
      done
      ;;
  esac
}

smoke_test() {
  step "smoke test"
  if [ "$DRY_RUN" = "1" ]; then
    printf '  %swould run:%s %s --status\n' "$SV_DIM" "$SV_RESET" "$(sv_mcp)" >&2
    return 0
  fi
  local tools
  tools="$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' \
    | "$(sv_mcp)" 2>/dev/null \
    | python3 -c 'import json,sys
for line in sys.stdin:
    names = [t["name"] for t in json.loads(line).get("result", {}).get("tools", [])]
    if names:
        print(" ".join(names))
        break' 2>/dev/null || true)"
  [ -n "$tools" ] || die "the MCP front end did not answer tools/list — check $(sv_log)"
  hint "tools: $tools"
  sv_status | sed 's/^/  /'

  if [ "$DO_SMOKE_GENERATE" = "1" ]; then
    say ""
    say "generating a test image (this also proves the weights load)…"
    # No --tier: the CLI picks whichever artifact this machine has installed.
    "$(sv_cli_path)" generate --prompt "a small brass compass on a dark wooden desk, soft light"
  fi
}

summary() {
  step "done"
  say "  service   $(sv_label)   ($(sv_served))"
  say "  command   $(sv_cli_path)"
  say "  home      $(sv_home)"
  say "  models    $(sv_models)"
  say "  output    $(sv_out_dir)"
  say "  logs      $(sv_log)"
  if [ -d "$LEGACY_HOME/bin" ] && [ "$DRY_RUN" = "0" ]; then
    say ""
    say "Note: $LEGACY_HOME keeps compatibility wrappers for MCP clients wired"
    say "      before this change. Restart those clients, then delete that directory."
  fi
  say ""
  say "Next:"
  say "  sensenova-u1 doctor        check every moving part"
  say "  sensenova-u1 models        see which artifacts are installed"
  say "  sensenova-u1 clients list  see which clients are wired"
  # The command is installed into ~/.local/bin, which is not on PATH by default
  # on macOS. Say so here rather than letting the next command fail with
  # "command not found".
  case ":$PATH:" in
    *":$(sv_prefix)/bin:"*) ;;
    *) say ""
       say "Note: $(sv_prefix)/bin is not on your PATH, so type the whole path:"
       say "      $(sv_cli_path) doctor"
       say "      or add this to ~/.zprofile:  export PATH=\"$(sv_prefix)/bin:\$PATH\"" ;;
  esac
  say ""
  say "Then restart your agent (Codex, Claude, opencode, QwenPaw, …) so it picks"
  say "up the new MCP entry, and ask it for an image. The first call loads the"
  say "weights (~5 s); they are released again after 10 minutes idle."
}

main() {
  say "${SV_BOLD}SenseNova-U1.5 local image service${SV_RESET} — installer $SV_VERSION"
  [ "$DRY_RUN" = "1" ] && warn "dry run: nothing will be changed"
  preflight
  migrate_legacy
  fetch_models
  write_daemon_config
  build_binaries
  install_binaries
  link_legacy_home
  write_conf_and_service
  wire_clients
  smoke_test
  summary
}

main
