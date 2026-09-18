#!/usr/bin/env bash
# One-command install of the local SenseNova-U1.5 image service.
#
#   ./install.sh                    # default: 4-bit fast tier, wire detected clients
#   ./install.sh --model both       # also pull the bf16 quality tier (~33 GiB)
#   ./install.sh --model none       # use artifacts you already have
#   ./install.sh --dry-run          # print every action, change nothing
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

usage() { sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)     DRY_RUN=1; shift ;;
    --yes|-y)      ASSUME_YES=1; shift ;;
    --model)       MODEL_CHOICE="${2:-}"; shift 2 ;;
    --source)      SOURCE="${2:-}"; shift 2 ;;
    --clients)     CLIENTS_CHOICE="${2:-}"; shift 2 ;;
    --home)        SENSENOVA_HOME="${2:-}"; shift 2 ;;
    --prefix)      SENSENOVA_PREFIX="${2:-}"; shift 2 ;;
    --label)       SENSENOVA_LABEL="${2:-}"; shift 2 ;;
    --fast-artifact)    SENSENOVA_FAST_ARTIFACT="${2:-}"; shift 2 ;;
    --quality-artifact) SENSENOVA_QUALITY_ARTIFACT="${2:-}"; shift 2 ;;
    --skip-build)  DO_BUILD="no"; shift ;;
    --smoke-generate) DO_SMOKE_GENERATE=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *)             usage; die "unknown option: $1" ;;
  esac
done

sv_load_conf

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
  [ "$ram" -ge 18 ] || die "unified memory ${ram}GB is too small (the smallest artifact peaks around 15GB)"
  [ "$ram" -ge 32 ] && hint "unified memory ${ram}GB" \
    || warn "unified memory ${ram}GB — the 4-bit tier fits, but close other heavy apps"

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

  sv_have python3 || warn "python3 not found — config edits for some clients will be skipped (xcode-select --install)"
  sv_have curl || die "curl not found"

  local need_gb=6 avail_gb
  case "$MODEL_CHOICE" in
    both) need_gb=48 ;;
    none) need_gb=4 ;;
    *)    need_gb=16 ;;
  esac
  avail_gb="$(df -g "$(sv_home 2>/dev/null || echo /)" 2>/dev/null | awk 'NR==2{print $4}')"
  if [ -n "$avail_gb" ] && [ "$avail_gb" -lt "$need_gb" ]; then
    die "not enough disk space: ${avail_gb}GB free, this install needs about ${need_gb}GB (plus the build tree)"
  fi
  hint "disk: ${avail_gb:-?}GB free"
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
  if [ -z "$presets" ] && [ -f "$(sv_home)/config.json" ]; then
    step "daemon config"
    hint "keeping $(sv_home)/config.json (--model none)"
    return 0
  fi
  local fast quality
  if printf '%s\n' "$presets" | grep -q '^fast-'; then
    fast="artifacts/$(sv_preset_repo fast-4bit | tr '/' '-')"
    [ -d "$(sv_home)/$fast" ] || fast="artifacts/$(sv_preset_repo fast-8bit | tr '/' '-')"
  else
    fast="$(sv_fast_artifact)"
  fi
  if printf '%s\n' "$presets" | grep -q '^quality-'; then
    quality="artifacts/$(sv_preset_repo quality-bf16 | tr '/' '-')"
  else
    quality="$(sv_quality_artifact)"
  fi
  if [ "$(sv_home)/$fast" = "$(sv_home)/$quality" ]; then
    die "fast and quality would point at the same artifact — pass --model none or pick a second tier"
  fi
  if [ -z "$presets" ]; then
    # --model none without an existing config: write what we know and say so.
    warn "no model was selected, so the tier paths below may not exist yet;"
    warn "download one with: sensenova-u1 models pull fast-4bit"
  fi

  step "daemon config"
  write_file "$(sv_home)/config.json" <<JSON
{
  "ttl_seconds": 600,
  "min_warm_seconds": 60,
  "fast_artifact": "$fast",
  "quality_artifact": "$quality"
}
JSON
  hint "$(sv_home)/config.json: fast=$fast quality=$quality"
  for dir in "$(sv_home)/$fast" "$(sv_home)/$quality"; do
    [ -f "$dir/config.json" ] || warn "artifact not present yet: $dir"
  done
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
  hint "binaries + MLX resource bundles -> $bin"

  # The management CLI keeps its helper scripts next to it in share/.
  local share; share="$(sv_prefix)/share/sensenova-u1"
  run mkdir -p "$share" "$(sv_prefix)/bin"
  run cp -R "$REPO_DIR/cli/." "$share/"
  run chmod +x "$share/sensenova-u1" "$share"/lib/*.py
  run ln -sf "$share/sensenova-u1" "$(sv_cli_path)"
  hint "command installed: $(sv_cli_path)"
}

write_conf_and_service() {
  step "configuration"
  if [ "$DRY_RUN" = "0" ]; then
    sv_write_conf
    hint "wrote $(sv_conf)"
  else
    printf '  %swould write:%s %s\n' "$SV_DIM" "$SV_RESET" "$(sv_conf)" >&2
  fi

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
	</dict>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<false/>
	<key>ProcessType</key>
	<string>Background</string>
	<!-- launchd throttles respawns; the 10s default would also stall every
	     explicit `sensenova-u1 restart` by that much. 1s still damps a crash loop. -->
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
    "$(sv_cli_path)" generate --prompt "a small brass compass on a dark wooden desk, soft light" --tier fast
  fi
}

summary() {
  step "done"
  say "  service   $(sv_label)   ($(sv_served))"
  say "  command   $(sv_cli_path)"
  say "  output    $(sv_out_dir)"
  say "  logs      $(sv_log)"
  say ""
  say "Next:"
  say "  sensenova-u1 doctor        check every moving part"
  say "  sensenova-u1 models        see which artifacts are installed"
  say "  sensenova-u1 clients list  see which clients are wired"
  say ""
  say "Then ask your agent for an image; the first call loads the weights (~5s),"
  say "and they are released again after 10 minutes idle."
}

main() {
  say "${SV_BOLD}SenseNova-U1.5 local image service${SV_RESET} — installer $SV_VERSION"
  [ "$DRY_RUN" = "1" ] && warn "dry run: nothing will be changed"
  preflight
  fetch_models
  write_daemon_config
  build_binaries
  install_binaries
  write_conf_and_service
  wire_clients
  smoke_test
  summary
}

main
