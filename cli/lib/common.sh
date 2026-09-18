#!/usr/bin/env bash
# Shared helpers for the sensenova-u1 CLI and the installers. Sourced, not run.

SV_VERSION="0.3.0"
# Layout (see Docs/LAYOUT.md). macOS conventions, every path overridable:
#   app data  ~/Library/Application Support/SenseNovaU1  (config, socket, weights)
#   logs      ~/Library/Logs/SenseNovaU1
#   commands  ~/.local/bin, private executables ~/.local/share/sensenova-u1
#   images    ~/Pictures/SenseNovaU1
SV_DEFAULT_HOME="$HOME/Library/Application Support/SenseNovaU1"
SV_DEFAULT_LABEL="local.sensenova-u1"
SV_DEFAULT_PREFIX="$HOME/.local"
SV_DEFAULT_OUT="$HOME/Pictures/SenseNovaU1"
SV_DEFAULT_FAST="SenseNova-U1.5-8B-MoT-8step-4bit"
SV_DEFAULT_QUALITY="SenseNova-U1.5-8B-MoT-bf16"

if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
  SV_BOLD=$'\033[1m'; SV_DIM=$'\033[2m'; SV_RED=$'\033[31m'; SV_GREEN=$'\033[32m'
  SV_YELLOW=$'\033[33m'; SV_RESET=$'\033[0m'
else
  SV_BOLD=""; SV_DIM=""; SV_RED=""; SV_GREEN=""; SV_YELLOW=""; SV_RESET=""
fi

say()  { printf '%s\n' "$*"; }
step() { printf '\n%s==> %s%s\n' "$SV_BOLD" "$*" "$SV_RESET" >&2; }
hint() { printf '%s%s%s\n' "$SV_DIM" "$*" "$SV_RESET" >&2; }
warn() { printf '%swarning:%s %s\n' "$SV_YELLOW" "$SV_RESET" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$SV_RED" "$SV_RESET" "$*" >&2; exit 1; }

# --- paths -------------------------------------------------------------------

sv_home()     { printf '%s\n' "${SENSENOVA_HOME:-$SV_DEFAULT_HOME}"; }
sv_models()   { printf '%s\n' "${SENSENOVA_MODELS:-$(sv_home)/models}"; }
sv_config()   { printf '%s\n' "$(sv_home)/config.json"; }
sv_conf()     { printf '%s\n' "$(sv_home)/service.conf"; }
sv_bin_dir()  { printf '%s\n' "$(sv_prefix)/share/sensenova-u1/bin"; }
sv_served()   { printf '%s\n' "$(sv_bin_dir)/sensenova-served"; }
sv_mcp()      { printf '%s\n' "$(sv_bin_dir)/sensenova-mcp"; }
sv_out_dir()  { printf '%s\n' "${SENSENOVA_OUT:-$SV_DEFAULT_OUT}"; }
sv_log()      { printf '%s\n' "$HOME/Library/Logs/SenseNovaU1/served.log"; }
sv_plist()    { printf '%s\n' "$HOME/Library/LaunchAgents/$(sv_label).plist"; }
sv_socket()   { printf '%s\n' "${SENSENOVA_SOCKET:-$(sv_home)/served.sock}"; }
sv_label()    { printf '%s\n' "${SENSENOVA_LABEL:-$SV_DEFAULT_LABEL}"; }
sv_prefix()   { printf '%s\n' "${SENSENOVA_PREFIX:-$SV_DEFAULT_PREFIX}"; }
sv_cli_path() { printf '%s\n' "$(sv_prefix)/bin/sensenova-u1"; }

# The daemon reads the tiers from config.json, so the CLI must read the same
# file — two sources of truth here means `doctor` reports a tier the service is
# not actually using. Environment still wins, which is how install.sh drives it.
sv_config_value() { # <key> — value from <app home>/config.json, empty if absent
  local file; file="$(sv_config)"
  [ -f "$file" ] || return 1
  sv_have python3 || return 1
  python3 -c '
import json, sys
try:
    value = json.load(open(sys.argv[1])).get(sys.argv[2], "")
except Exception:
    value = ""
print(value if isinstance(value, str) else "")
' "$file" "$1"
}

sv_fast_artifact() {
  local value
  value="$(sv_config_value fast_artifact 2>/dev/null || true)"
  printf '%s\n' "${SENSENOVA_FAST_ARTIFACT:-${value:-$SV_DEFAULT_FAST}}"
}

sv_quality_artifact() {
  local value
  value="$(sv_config_value quality_artifact 2>/dev/null || true)"
  printf '%s\n' "${SENSENOVA_QUALITY_ARTIFACT:-${value:-$SV_DEFAULT_QUALITY}}"
}

sv_artifact_dir() { # fast|quality -> absolute path
  local rel
  case "${1:-quality}" in
    fast|8step|fast8) rel="$(sv_fast_artifact)" ;;
    *)                rel="$(sv_quality_artifact)" ;;
  esac
  case "$rel" in
    /*) printf '%s\n' "$rel" ;;
    *)  printf '%s\n' "$(sv_models)/$rel" ;;
  esac
}

# Tiers are a preference, not a requirement. Installers offer a lightweight
# artifact (fast) and a quality artifact, and a machine that installed only one
# of them serves every request from it — that is a supported setup, not a broken
# install — so "which tiers are installed" is the question worth asking, and
# "this tier is missing" on its own is not an error. The daemon answers it from
# the same two files (Sources/sensenova-served/main.swift, artifactReady).
sv_tier_ready() { # fast|quality
  local dir; dir="$(sv_artifact_dir "$1")"
  [ -f "$dir/config.json" ] && [ -f "$dir/tokenizer.json" ]
}

sv_installed_tiers() { # space-separated, best-quality-last order the daemon uses
  local tier out=""
  for tier in fast quality; do
    sv_tier_ready "$tier" && out="${out:+$out }$tier"
  done
  printf '%s\n' "$out"
}

# The tier to use when the caller did not name one: the lightweight artifact is
# the better default while it is installed (drafts and iteration are the common
# case), otherwise whatever this machine does have.
sv_default_tier() {
  local tier
  for tier in fast quality; do
    if sv_tier_ready "$tier"; then printf '%s\n' "$tier"; return 0; fi
  done
  printf '%s\n' fast
}

# --- service.conf ------------------------------------------------------------

# Loads <home>/service.conf, then re-applies any SENSENOVA_* values that were
# already set in the environment: env wins over the file.
#
# The file is parsed, never sourced: a malformed line can then only produce a
# wrong value, not execute something surprising or abort the script.
sv_load_conf() {
  local keep_home="${SENSENOVA_HOME:-}" keep_prefix="${SENSENOVA_PREFIX:-}"
  local keep_label="${SENSENOVA_LABEL:-}" keep_socket="${SENSENOVA_SOCKET:-}"
  local keep_models="${SENSENOVA_MODELS:-}" keep_out="${SENSENOVA_OUT:-}"
  local file line key value
  file="$(sv_conf)"
  if [ -f "$file" ]; then
    while IFS= read -r line; do
      case "$line" in
        SENSENOVA_[A-Z_]*=*) ;;
        *) continue ;;
      esac
      key="${line%%=*}"
      value="${line#*=}"
      case "$value" in
        \'*\')
          value="${value#\'}"; value="${value%\'}"
          value="${value//\'\\\'\'/\'}"
          ;;
        \"*\") value="${value#\"}"; value="${value%\"}" ;;
      esac
      # Older versions wrote values with printf %q, which escaped spaces; undo
      # that so a config file from an earlier install reads back verbatim.
      value="${value//\\ / }"
      case "$key" in
        SENSENOVA_HOME)              SENSENOVA_HOME="$value" ;;
        SENSENOVA_PREFIX)            SENSENOVA_PREFIX="$value" ;;
        SENSENOVA_LABEL)             SENSENOVA_LABEL="$value" ;;
        SENSENOVA_SOCKET)            SENSENOVA_SOCKET="$value" ;;
        SENSENOVA_MODELS)            SENSENOVA_MODELS="$value" ;;
        SENSENOVA_OUT)               SENSENOVA_OUT="$value" ;;
        # Tiers live in config.json (the daemon's own file); ignore the legacy
        # keys so there is exactly one place a file can set them.
        SENSENOVA_FAST_ARTIFACT|SENSENOVA_QUALITY_ARTIFACT) ;;
      esac
    done < "$file"
  fi
  [ -n "$keep_home" ] && SENSENOVA_HOME="$keep_home"
  [ -n "$keep_prefix" ] && SENSENOVA_PREFIX="$keep_prefix"
  [ -n "$keep_label" ] && SENSENOVA_LABEL="$keep_label"
  [ -n "$keep_socket" ] && SENSENOVA_SOCKET="$keep_socket"
  [ -n "$keep_models" ] && SENSENOVA_MODELS="$keep_models"
  [ -n "$keep_out" ] && SENSENOVA_OUT="$keep_out"
  return 0
}

# sv_write_conf [key=value ...] — rewrites service.conf from current settings
# plus the overrides given on the command line.
sv_write_conf() {
  local override
  for override in "$@"; do
    case "$override" in
      SENSENOVA_HOME=*)           SENSENOVA_HOME="${override#*=}" ;;
      SENSENOVA_PREFIX=*)         SENSENOVA_PREFIX="${override#*=}" ;;
      SENSENOVA_LABEL=*)          SENSENOVA_LABEL="${override#*=}" ;;
      SENSENOVA_SOCKET=*)         SENSENOVA_SOCKET="${override#*=}" ;;
      SENSENOVA_MODELS=*)         SENSENOVA_MODELS="${override#*=}" ;;
      SENSENOVA_OUT=*)            SENSENOVA_OUT="${override#*=}" ;;
      SENSENOVA_FAST_ARTIFACT=*|SENSENOVA_QUALITY_ARTIFACT=*)
        die "tier paths live in $(sv_config) — edit that file instead"
        ;;
      *) die "unknown setting: $override" ;;
    esac
  done
  local home; home="$(sv_home)"
  mkdir -p "$home"
  local tmp; tmp="$(mktemp)"
  # Single quotes so paths with spaces (the default socket lives under
  # "Application Support") survive the round trip. %q would work too, but it
  # escapes every space with a backslash and the escaping piles up on each
  # rewrite; a single-quoted value is stable under repeated writes.
  {
    printf '# Written by sensenova-u1 %s — safe to edit.\n' "$SV_VERSION"
    printf 'SENSENOVA_HOME=%s\n' "$(sv_quote "$home")"
    printf 'SENSENOVA_PREFIX=%s\n' "$(sv_quote "$(sv_prefix)")"
    printf 'SENSENOVA_LABEL=%s\n' "$(sv_quote "$(sv_label)")"
    printf 'SENSENOVA_SOCKET=%s\n' "$(sv_quote "$(sv_socket)")"
    printf 'SENSENOVA_MODELS=%s\n' "$(sv_quote "$(sv_models)")"
    printf 'SENSENOVA_OUT=%s\n' "$(sv_quote "$(sv_out_dir)")"
  } > "$tmp"
  mv "$tmp" "$(sv_conf)"
}

# sv_quote <value> — one shell-safe word, stable when read back by sv_load_conf.
sv_quote() {
  local value="$1"
  value="${value//\'/\'\\\'\'}"
  printf "'%s'\n" "$value"
}

# Timestamped backup; prints the backup path, or nothing when the file is absent.
sv_backup() {
  [ -e "$1" ] || return 0
  local backup="$1.bak-$(date +%Y%m%d-%H%M%S)"
  cp "$1" "$backup"
  printf '%s\n' "$backup"
}

# --- host facts --------------------------------------------------------------

sv_host_ram_gb() { printf '%s\n' "$(( $(sysctl -n hw.memsize) / 1073741824 ))"; }
sv_host_arch()   { uname -m; }
sv_macos()       { sw_vers -productVersion; }

# --- launchd -----------------------------------------------------------------

sv_service_loaded() {
  launchctl print "gui/$(id -u)/$(sv_label)" >/dev/null 2>&1
}

sv_service_start() {
  local domain="gui/$(id -u)" label err tries=0 waited=0
  label="$(sv_label)"
  err="$(mktemp)"
  if sv_service_loaded; then
    # Already in the domain: ask launchd for a restart, which is what `-k` means.
    launchctl kickstart -k "$domain/$label" 2>"$err" || true
  else
    # A fresh `bootstrap` starts the job by itself (RunAtLoad). Sending
    # `kickstart -k` straight after it kills the instance launchd just created and
    # races the replacement against the corpse — measured as `runs = 2, last exit
    # code = 3` with nobody listening, which then fails the installer's smoke
    # test on a machine that is perfectly fine. So: bootstrap and wait.
    launchctl bootstrap "$domain" "$(sv_plist)" 2>"$err" || true
    # `bootstrap` can report success while the job is not in the domain yet (it is
    # discarded when a previous bootout has not finished settling), so trust
    # `launchctl print` over the exit status.
    while ! sv_service_loaded; do
      tries=$((tries + 1))
      if [ "$tries" -ge 20 ]; then
        warn "$(cat "$err")"
        rm -f "$err"
        die "could not load $label — try: launchctl bootstrap $domain $(sv_plist)"
      fi
      sleep 0.25
    done
  fi
  rm -f "$err"
  # Leave the caller with a socket that exists, so the next command (a status
  # call, the installer's smoke test) never races the start.
  while [ "$waited" -lt 160 ]; do
    if [ -S "$(sv_socket)" ]; then return 0; fi
    waited=$((waited + 1))
    sleep 0.25
  done
  warn "the job is loaded but $(sv_socket) did not appear within 40s — check $(sv_log)"
  return 0
}

# bootout returns before the job is actually gone, so wait for the domain to
# settle; bootstrapping into a domain that is still tearing down is what makes
# the restart below flaky in the first place.
sv_service_stop() {
  local domain="gui/$(id -u)" label tries=0
  label="$(sv_label)"
  sv_service_loaded || return 0
  launchctl bootout "$domain/$label" >/dev/null 2>&1 || true
  while sv_service_loaded && [ "$tries" -lt 40 ]; do
    sleep 0.25
    tries=$((tries + 1))
  done
  return 0
}

# --- talking to the daemon ---------------------------------------------------

# Reads the daemon through the MCP front end, so the CLI exercises exactly the
# path the agents use. Prints key=value lines.
sv_status() {
  local mcp; mcp="$(sv_mcp)"
  [ -x "$mcp" ] || die "not installed: $mcp (run install.sh)"
  "$mcp" --status
}

sv_unload() {
  local mcp; mcp="$(sv_mcp)"
  [ -x "$mcp" ] || die "not installed: $mcp (run install.sh)"
  "$mcp" --unload
}

sv_peak_mb() { sv_status 2>/dev/null | awk -F= '$1=="last_peak_mb"{print $2}'; }
sv_resident() { sv_status 2>/dev/null | awk -F= '$1=="resident_tier"{print $2}'; }

# --- misc --------------------------------------------------------------------

# sv_dir_size <path> -> human size, or "-" when missing
sv_dir_size() {
  [ -d "$1" ] || { printf '%s\n' "-"; return 0; }
  du -sh "$1" 2>/dev/null | awk '{print $1}'
}

sv_have() { command -v "$1" >/dev/null 2>&1; }
