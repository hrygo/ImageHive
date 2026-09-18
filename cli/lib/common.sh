#!/usr/bin/env bash
# Shared helpers for the sensenova-u1 CLI and the installers. Sourced, not run.

SV_VERSION="0.1.0"
SV_DEFAULT_HOME="$HOME/Models/SenseNova-U1.5"
SV_DEFAULT_LABEL="local.sensenova-u1"
SV_DEFAULT_PREFIX="$HOME/.local"
SV_DEFAULT_SOCKET="$HOME/Library/Application Support/SenseNovaU1/served.sock"
SV_DEFAULT_FAST="artifacts/SenseNova-U1.5-8B-MoT-8step-4bit"
SV_DEFAULT_QUALITY="artifacts/SenseNova-U1.5-8B-MoT-bf16"

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
sv_conf()     { printf '%s\n' "$(sv_home)/service.conf"; }
sv_bin_dir()  { printf '%s\n' "$(sv_home)/bin"; }
sv_served()   { printf '%s\n' "$(sv_bin_dir)/sensenova-served"; }
sv_mcp()      { printf '%s\n' "$(sv_bin_dir)/sensenova-mcp"; }
sv_out_dir()  { printf '%s\n' "$(sv_home)/out"; }
sv_log()      { printf '%s\n' "$HOME/Library/Logs/SenseNovaU1/served.log"; }
sv_plist()    { printf '%s\n' "$HOME/Library/LaunchAgents/$(sv_label).plist"; }
sv_socket()   { printf '%s\n' "${SENSENOVA_SOCKET:-$SV_DEFAULT_SOCKET}"; }
sv_label()    { printf '%s\n' "${SENSENOVA_LABEL:-$SV_DEFAULT_LABEL}"; }
sv_prefix()   { printf '%s\n' "${SENSENOVA_PREFIX:-$SV_DEFAULT_PREFIX}"; }
sv_cli_path() { printf '%s\n' "$(sv_prefix)/bin/sensenova-u1"; }

sv_fast_artifact()    { printf '%s\n' "${SENSENOVA_FAST_ARTIFACT:-$SV_DEFAULT_FAST}"; }
sv_quality_artifact() { printf '%s\n' "${SENSENOVA_QUALITY_ARTIFACT:-$SV_DEFAULT_QUALITY}"; }

sv_artifact_dir() { # fast|quality -> absolute path
  local rel
  case "${1:-quality}" in
    fast|8step|fast8) rel="$(sv_fast_artifact)" ;;
    *)                rel="$(sv_quality_artifact)" ;;
  esac
  case "$rel" in
    /*) printf '%s\n' "$rel" ;;
    *)  printf '%s\n' "$(sv_home)/$rel" ;;
  esac
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
  local keep_fast="${SENSENOVA_FAST_ARTIFACT:-}" keep_quality="${SENSENOVA_QUALITY_ARTIFACT:-}"
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
        SENSENOVA_FAST_ARTIFACT)     SENSENOVA_FAST_ARTIFACT="$value" ;;
        SENSENOVA_QUALITY_ARTIFACT)  SENSENOVA_QUALITY_ARTIFACT="$value" ;;
      esac
    done < "$file"
  fi
  [ -n "$keep_home" ] && SENSENOVA_HOME="$keep_home"
  [ -n "$keep_prefix" ] && SENSENOVA_PREFIX="$keep_prefix"
  [ -n "$keep_label" ] && SENSENOVA_LABEL="$keep_label"
  [ -n "$keep_socket" ] && SENSENOVA_SOCKET="$keep_socket"
  [ -n "$keep_fast" ] && SENSENOVA_FAST_ARTIFACT="$keep_fast"
  [ -n "$keep_quality" ] && SENSENOVA_QUALITY_ARTIFACT="$keep_quality"
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
      SENSENOVA_FAST_ARTIFACT=*)  SENSENOVA_FAST_ARTIFACT="${override#*=}" ;;
      SENSENOVA_QUALITY_ARTIFACT=*) SENSENOVA_QUALITY_ARTIFACT="${override#*=}" ;;
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
    printf 'SENSENOVA_FAST_ARTIFACT=%s\n' "$(sv_quote "$(sv_fast_artifact)")"
    printf 'SENSENOVA_QUALITY_ARTIFACT=%s\n' "$(sv_quote "$(sv_quality_artifact)")"
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
  local domain="gui/$(id -u)" label err tries=0
  label="$(sv_label)"
  err="$(mktemp)"
  # `launchctl bootstrap` can report success while the job is not in the domain
  # yet (it is discarded if a previous bootout has not finished settling), so
  # trust `launchctl print` over the exit status and retry the pair as a unit.
  while :; do
    tries=$((tries + 1))
    if ! sv_service_loaded; then
      launchctl bootstrap "$domain" "$(sv_plist)" 2>"$err" || true
      sleep 0.5
    fi
    if sv_service_loaded && launchctl kickstart -k "$domain/$label" 2>"$err"; then
      rm -f "$err"
      return 0
    fi
    if [ "$tries" -ge 10 ]; then
      warn "$(cat "$err")"
      rm -f "$err"
      die "could not start $label — try: launchctl bootstrap $domain $(sv_plist)"
    fi
    sleep 0.5
  done
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
