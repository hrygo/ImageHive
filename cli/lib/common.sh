#!/usr/bin/env bash
# Shared helpers for the imagehive CLI and the installers. Sourced, not run.

IH_VERSION="0.6.0"
# Layout (see Docs/LAYOUT.md). macOS conventions, every path overridable:
#   app data  ~/Library/Application Support/ImageHive  (config, socket, weights)
#   logs      ~/Library/Logs/ImageHive
#   commands  ~/.local/bin, private executables ~/.local/share/imagehive
#   images    ~/Pictures/ImageHive
IH_DEFAULT_HOME="$HOME/Library/Application Support/ImageHive"
IH_DEFAULT_LABEL="local.imagehive"
IH_DEFAULT_PREFIX="$HOME/.local"
IH_DEFAULT_OUT="$HOME/Pictures/ImageHive"
IH_DEFAULT_FAST="SenseNova-U1.5-8B-MoT-8step-4bit"
IH_DEFAULT_QUALITY="SenseNova-U1.5-8B-MoT-bf16"

# --- the previous name --------------------------------------------------------
# Up to 0.5.2 this project shipped as `sensenova-u1` (command, LaunchAgent label,
# app home, environment prefix) with a `sensenova-served` daemon and a
# `served.sock`. Those names still exist on any machine that installed an earlier
# release, and a daemon left running under them is not "the old service" — it is a
# *second* daemon holding a second copy of the weights, the one thing a machine
# must never have. So the old layout is named here, once, and everything that
# starts, replaces or removes a daemon reaps it too (ih_service_reap_legacy).
IH_LEGACY_HOME="$HOME/Library/Application Support/SenseNovaU1"
IH_LEGACY_OUT="$HOME/Pictures/SenseNovaU1"
IH_LEGACY_LOG_DIR="$HOME/Library/Logs/SenseNovaU1"
IH_LEGACY_LABEL="local.sensenova-u1"
IH_LEGACY_SHARE="$HOME/.local/share/sensenova-u1"
IH_LEGACY_CLI_NAME="sensenova-u1"
IH_LEGACY_CLI="$HOME/.local/bin/$IH_LEGACY_CLI_NAME"
IH_LEGACY_SOCKET_NAME="served.sock"
IH_LEGACY_DAEMON="sensenova-served"
IH_LEGACY_MCP="sensenova-mcp"
IH_LEGACY_BRAND="sensenova"

# The new label for an old one: a user who chose `--label com.hrygo.sensenova-u1`
# chose the `com.hrygo.` prefix and inherited the brand token, so only the token
# changes — `com.hrygo.imagehive`. A label with no brand token in it
# (`com.example.custom-daemon`) has nothing to carry over and prints nothing.
ih_rename_legacy_label() { # <label> -> the new label, on stdout
  local label="$1"
  case "$label" in
    *"$IH_LEGACY_CLI_NAME"*) printf '%s\n' "${label//$IH_LEGACY_CLI_NAME/imagehive}" ;;
    *"$IH_LEGACY_BRAND"*)    printf '%s\n' "${label//$IH_LEGACY_BRAND/imagehive}" ;;
    *) return 1 ;;
  esac
}

if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
  IH_BOLD=$'\033[1m'; IH_DIM=$'\033[2m'; IH_RED=$'\033[31m'; IH_GREEN=$'\033[32m'
  IH_YELLOW=$'\033[33m'; IH_RESET=$'\033[0m'
else
  IH_BOLD=""; IH_DIM=""; IH_RED=""; IH_GREEN=""; IH_YELLOW=""; IH_RESET=""
fi

say()  { printf '%s\n' "$*"; }
step() { printf '\n%s==> %s%s\n' "$IH_BOLD" "$*" "$IH_RESET" >&2; }
hint() { printf '%s%s%s\n' "$IH_DIM" "$*" "$IH_RESET" >&2; }
warn() { printf '%swarning:%s %s\n' "$IH_YELLOW" "$IH_RESET" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$IH_RED" "$IH_RESET" "$*" >&2; exit 1; }

# --- paths -------------------------------------------------------------------

ih_home()     { printf '%s\n' "${IMAGEHIVE_HOME:-$IH_DEFAULT_HOME}"; }
ih_models()   { printf '%s\n' "${IMAGEHIVE_MODELS:-$(ih_home)/models}"; }
ih_config()   { printf '%s\n' "$(ih_home)/config.json"; }
ih_conf()     { printf '%s\n' "$(ih_home)/service.conf"; }
ih_bin_dir()  { printf '%s\n' "$(ih_prefix)/share/imagehive/bin"; }
ih_daemon()   { printf '%s\n' "$(ih_bin_dir)/imagehived"; }
ih_mcp()      { printf '%s\n' "$(ih_bin_dir)/imagehive-mcp"; }
ih_out_dir()  { printf '%s\n' "${IMAGEHIVE_OUT:-$IH_DEFAULT_OUT}"; }
ih_log()      { printf '%s\n' "$HOME/Library/Logs/ImageHive/imagehived.log"; }
ih_plist()    { printf '%s\n' "$HOME/Library/LaunchAgents/$(ih_label).plist"; }
ih_socket()   { printf '%s\n' "${IMAGEHIVE_SOCKET:-$(ih_home)/imagehived.sock}"; }
ih_label()    { printf '%s\n' "${IMAGEHIVE_LABEL:-$IH_DEFAULT_LABEL}"; }
ih_prefix()   { printf '%s\n' "${IMAGEHIVE_PREFIX:-$IH_DEFAULT_PREFIX}"; }
ih_cli_path() { printf '%s\n' "$(ih_prefix)/bin/imagehive"; }

# The daemon reads the tiers from config.json, so the CLI must read the same
# file — two sources of truth here means `doctor` reports a tier the service is
# not actually using. Environment still wins, which is how install.sh drives it.
ih_config_value() { # <key> — value from <app home>/config.json, empty if absent
  local file; file="$(ih_config)"
  [ -f "$file" ] || return 1
  ih_have python3 || return 1
  python3 -c '
import json, sys
try:
    value = json.load(open(sys.argv[1])).get(sys.argv[2], "")
except Exception:
    value = ""
print(value if isinstance(value, str) else "")
' "$file" "$1"
}

# Whether <app home>/config.json parses at all. The daemon answers the built-in
# defaults when it does not and says so in its log and in `status`; without this
# check `doctor` reported the file as present and the user had no way to learn that
# every setting in it was being ignored.
ih_config_parses() {
  local file; file="$(ih_config)"
  [ -f "$file" ] || return 1
  ih_have python3 || return 0
  python3 -c '
import json, sys
try:
    json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
' "$file"
}

ih_fast_artifact() {
  local value
  value="$(ih_config_value fast_artifact 2>/dev/null || true)"
  printf '%s\n' "${IMAGEHIVE_FAST_ARTIFACT:-${value:-$IH_DEFAULT_FAST}}"
}

ih_quality_artifact() {
  local value
  value="$(ih_config_value quality_artifact 2>/dev/null || true)"
  printf '%s\n' "${IMAGEHIVE_QUALITY_ARTIFACT:-${value:-$IH_DEFAULT_QUALITY}}"
}

ih_artifact_dir() { # fast|quality -> absolute path
  local rel
  case "${1:-quality}" in
    fast|8step|fast8) rel="$(ih_fast_artifact)" ;;
    *)                rel="$(ih_quality_artifact)" ;;
  esac
  case "$rel" in
    /*) printf '%s\n' "$rel" ;;
    *)  printf '%s\n' "$(ih_models)/$rel" ;;
  esac
}

# Tiers are a preference, not a requirement. Installers offer a lightweight
# artifact (fast) and a quality artifact, and a machine that installed only one
# of them serves every request from it — that is a supported setup, not a broken
# install — so "which tiers are installed" is the question worth asking, and
# "this tier is missing" on its own is not an error. The daemon answers it from
# the same two files (Sources/imagehived/main.swift, artifactReady).
ih_tier_ready() { # fast|quality
  local dir; dir="$(ih_artifact_dir "$1")"
  [ -f "$dir/config.json" ] && [ -f "$dir/tokenizer.json" ]
}

ih_installed_tiers() { # space-separated, best-quality-last order the daemon uses
  local tier out=""
  for tier in fast quality; do
    ih_tier_ready "$tier" && out="${out:+$out }$tier"
  done
  printf '%s\n' "$out"
}

# The tier to use when the caller did not name one: the lightweight artifact is
# the better default while it is installed (drafts and iteration are the common
# case), otherwise whatever this machine does have.
ih_default_tier() {
  local tier
  for tier in fast quality; do
    if ih_tier_ready "$tier"; then printf '%s\n' "$tier"; return 0; fi
  done
  printf '%s\n' fast
}

# --- service.conf ------------------------------------------------------------

# Loads <home>/service.conf, then re-applies any IMAGEHIVE_* values that were
# already set in the environment: env wins over the file.
#
# The file is parsed, never sourced: a malformed line can then only produce a
# wrong value, not execute something surprising or abort the script.
ih_load_conf() {
  local keep_home="${IMAGEHIVE_HOME:-}" keep_prefix="${IMAGEHIVE_PREFIX:-}"
  local keep_label="${IMAGEHIVE_LABEL:-}" keep_socket="${IMAGEHIVE_SOCKET:-}"
  local keep_models="${IMAGEHIVE_MODELS:-}" keep_out="${IMAGEHIVE_OUT:-}"
  local file line key value
  file="$(ih_conf)"
  if [ -f "$file" ]; then
    while IFS= read -r line; do
      case "$line" in
        IMAGEHIVE_[A-Z_]*=*) ;;
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
        IMAGEHIVE_HOME)              IMAGEHIVE_HOME="$value" ;;
        IMAGEHIVE_PREFIX)            IMAGEHIVE_PREFIX="$value" ;;
        IMAGEHIVE_LABEL)             IMAGEHIVE_LABEL="$value" ;;
        IMAGEHIVE_SOCKET)            IMAGEHIVE_SOCKET="$value" ;;
        IMAGEHIVE_MODELS)            IMAGEHIVE_MODELS="$value" ;;
        IMAGEHIVE_OUT)               IMAGEHIVE_OUT="$value" ;;
        # Tiers live in config.json (the daemon's own file); ignore the legacy
        # keys so there is exactly one place a file can set them.
        IMAGEHIVE_FAST_ARTIFACT|IMAGEHIVE_QUALITY_ARTIFACT) ;;
      esac
    done < "$file"
  fi
  [ -n "$keep_home" ] && IMAGEHIVE_HOME="$keep_home"
  [ -n "$keep_prefix" ] && IMAGEHIVE_PREFIX="$keep_prefix"
  [ -n "$keep_label" ] && IMAGEHIVE_LABEL="$keep_label"
  [ -n "$keep_socket" ] && IMAGEHIVE_SOCKET="$keep_socket"
  [ -n "$keep_models" ] && IMAGEHIVE_MODELS="$keep_models"
  [ -n "$keep_out" ] && IMAGEHIVE_OUT="$keep_out"

  # Export what was just resolved, so the front end this CLI spawns (and anything
  # else it starts) resolves the *same* service. Without this a child falls back to
  # the built-in defaults: on an install under a custom --home or --prefix,
  # `imagehive status` would answer from — or silently start — a daemon in
  # ~/Library/Application Support/ImageHive, which is a second copy of the weights
  # and the one thing this project must not do (measured 2026-09-18: an installer
  # with a custom home started a second daemon on the default socket).
  export IMAGEHIVE_HOME="$(ih_home)"
  export IMAGEHIVE_MODELS="$(ih_models)"
  export IMAGEHIVE_OUT="$(ih_out_dir)"
  export IMAGEHIVE_SOCKET="$(ih_socket)"
  export IMAGEHIVE_PREFIX="$(ih_prefix)"
  export IMAGEHIVE_LABEL="$(ih_label)"
  return 0
}

# ih_write_conf [key=value ...] — rewrites service.conf from current settings
# plus the overrides given on the command line.
ih_write_conf() {
  local override
  for override in "$@"; do
    case "$override" in
      IMAGEHIVE_HOME=*)           IMAGEHIVE_HOME="${override#*=}" ;;
      IMAGEHIVE_PREFIX=*)         IMAGEHIVE_PREFIX="${override#*=}" ;;
      IMAGEHIVE_LABEL=*)          IMAGEHIVE_LABEL="${override#*=}" ;;
      IMAGEHIVE_SOCKET=*)         IMAGEHIVE_SOCKET="${override#*=}" ;;
      IMAGEHIVE_MODELS=*)         IMAGEHIVE_MODELS="${override#*=}" ;;
      IMAGEHIVE_OUT=*)            IMAGEHIVE_OUT="${override#*=}" ;;
      IMAGEHIVE_FAST_ARTIFACT=*|IMAGEHIVE_QUALITY_ARTIFACT=*)
        die "tier paths live in $(ih_config) — edit that file instead"
        ;;
      *) die "unknown setting: $override" ;;
    esac
  done
  local home; home="$(ih_home)"
  mkdir -p "$home"
  local tmp; tmp="$(mktemp)"
  # Single quotes so paths with spaces (the default socket lives under
  # "Application Support") survive the round trip. %q would work too, but it
  # escapes every space with a backslash and the escaping piles up on each
  # rewrite; a single-quoted value is stable under repeated writes.
  {
    printf '# Written by imagehive %s — safe to edit.\n' "$IH_VERSION"
    # The daemon and the MCP front end read this: without it they can only say
    # "unknown", and a generated file could not be traced back to a build. They used
    # to hard-code a version of their own (0.1.0) that matched no release at all.
    printf 'IMAGEHIVE_VERSION=%s\n' "$(ih_quote "$IH_VERSION")"
    printf 'IMAGEHIVE_HOME=%s\n' "$(ih_quote "$home")"
    printf 'IMAGEHIVE_PREFIX=%s\n' "$(ih_quote "$(ih_prefix)")"
    printf 'IMAGEHIVE_LABEL=%s\n' "$(ih_quote "$(ih_label)")"
    printf 'IMAGEHIVE_SOCKET=%s\n' "$(ih_quote "$(ih_socket)")"
    printf 'IMAGEHIVE_MODELS=%s\n' "$(ih_quote "$(ih_models)")"
    printf 'IMAGEHIVE_OUT=%s\n' "$(ih_quote "$(ih_out_dir)")"
  } > "$tmp"
  mv "$tmp" "$(ih_conf)"
}

# ih_quote <value> — one shell-safe word, stable when read back by ih_load_conf.
ih_quote() {
  local value="$1"
  value="${value//\'/\'\\\'\'}"
  printf "'%s'\n" "$value"
}

# Timestamped backup; prints the backup path, or nothing when the file is absent.
ih_backup() {
  [ -e "$1" ] || return 0
  local backup="$1.bak-$(date +%Y%m%d-%H%M%S)"
  cp "$1" "$backup"
  printf '%s\n' "$backup"
}

# --- host facts --------------------------------------------------------------

ih_host_ram_gb() { printf '%s\n' "$(( $(sysctl -n hw.memsize) / 1073741824 ))"; }
ih_host_arch()   { uname -m; }
ih_macos()       { sw_vers -productVersion; }

# --- launchd -----------------------------------------------------------------

ih_service_loaded() {
  launchctl print "gui/$(id -u)/$(ih_label)" >/dev/null 2>&1
}

ih_service_start() {
  local domain="gui/$(id -u)" label err tries=0 waited=0
  label="$(ih_label)"
  err="$(mktemp)"
  # Refuse early when the job was never installed, instead of letting launchctl fail
  # on a plist that does not exist and echoing its raw "Try re-running the command as
  # root for richer errors." back at the user.
  if ! ih_service_loaded && [ ! -f "$(ih_plist)" ]; then
    rm -f "$err"
    die "the launchd job is not installed ($(ih_plist) is missing) — run: install.sh"
  fi
  if ih_service_loaded; then
    # Already in the domain: ask launchd for a restart, which is what `-k` means.
    launchctl kickstart -k "$domain/$label" 2>"$err" || true
  else
    # A fresh `bootstrap` starts the job by itself (RunAtLoad). Sending
    # `kickstart -k` straight after it kills the instance launchd just created and
    # races the replacement against the corpse — measured as `runs = 2, last exit
    # code = 3` with nobody listening, which then fails the installer's smoke
    # test on a machine that is perfectly fine. So: bootstrap and wait.
    launchctl bootstrap "$domain" "$(ih_plist)" 2>"$err" || true
    # `bootstrap` can report success while the job is not in the domain yet (it is
    # discarded when a previous bootout has not finished settling), so trust
    # `launchctl print` over the exit status.
    while ! ih_service_loaded; do
      tries=$((tries + 1))
      if [ "$tries" -ge 20 ]; then
        # launchctl's own text helps here, except for its "try as root" line: this is a
        # per-user LaunchAgent, so running as root is never the fix.
        local detail
        detail="$(grep -v '^Try re-running the command as root' "$err" 2>/dev/null || true)"
        if [ -n "$detail" ]; then
          while IFS= read -r line; do [ -n "$line" ] && warn "launchctl: $line"; done <<< "$detail"
        fi
        rm -f "$err"
        die "could not load $label — inspect it with: launchctl print $domain/$label"
      fi
      sleep 0.25
    done
  fi
  rm -f "$err"
  # Leave the caller with a daemon that *answers*, not merely a socket file that
  # exists: a killed daemon leaves the file behind, and every check in this CLI used
  # to be satisfied by it. Measured 2026-09-18 — an install reported its service up,
  # then failed its own smoke test, because the daemon it had just started was still
  # binding while the socket file it inherited from the previous one was already there.
  while [ "$waited" -lt 160 ]; do
    if ih_socket_listening; then return 0; fi
    waited=$((waited + 1))
    sleep 0.25
  done
  warn "the job is loaded but nothing is answering on $(ih_socket) after 40s — check $(ih_log)"
  return 0
}

# True when something is actually accepting connections on <path>. The file
# existing is not that: a daemon killed with SIGKILL (or one that has not unlinked
# its socket yet) leaves a dead file behind.
ih_socket_listening_at() { # <socket path>
  # Without python3 fall back to the weaker test rather than waiting 40s for a
  # probe that can never run.
  ih_have python3 || { [ -S "$1" ]; return; }
  python3 - "$1" <<'PY' >/dev/null 2>&1
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(0.5)
try:
    s.connect(sys.argv[1])
except OSError:
    sys.exit(1)
finally:
    s.close()
PY
}

ih_socket_listening() { ih_socket_listening_at "$(ih_socket)"; }

# What `start`, `stop` and `restart` say. A start is only a start if something
# answers afterwards, and a stop is only a stop if nothing does; both used to be
# reported from the exit status of launchctl, which knows about the job and not about
# the service.
ih_service_announce() { # <verb>
  local verb="$1" pid=""
  if ih_socket_listening; then
    pid="$(ih_daemon_pid 2>/dev/null || true)"
    if [ "$verb" = "stopped" ]; then
      warn "$verb $(ih_label), but something is still answering on $(ih_socket)${pid:+ (pid $pid)}"
      return 0
    fi
    say "$verb $(ih_label)${pid:+ (pid $pid)}"
  else
    if [ "$verb" = "stopped" ]; then
      say "$verb $(ih_label)"
    else
      warn "$verb $(ih_label), but nothing is answering on $(ih_socket) — check $(ih_log)"
    fi
  fi
  return 0
}

# bootout returns before the job is actually gone, so wait for the domain to
# settle; bootstrapping into a domain that is still tearing down is what makes
# the restart below flaky in the first place.
#
# bootout only ends the process launchd started. The daemon is *normally* started
# by an MCP front end (`spawnDaemon`), and that one outlives every front end, so
# it keeps the socket while the job fails to bind (exit 3) — measured 2026-09-18:
# after a reinstall, `options` answered `unknown cmd` because the process serving
# the socket was the previous build, and nothing in the output said so.
ih_service_stop() {
  local domain="gui/$(id -u)" label tries=0
  label="$(ih_label)"
  if ih_service_loaded; then
    launchctl bootout "$domain/$label" >/dev/null 2>&1 || true
    while ih_service_loaded && [ "$tries" -lt 40 ]; do
      sleep 0.25
      tries=$((tries + 1))
    done
  fi
  ih_service_reap_stray
  ih_service_reap_legacy
  return 0
}

# PIDs of a daemon left by the install *this layout* is upgrading from: the one at
# the pre-0.6 prefix of this HOME, or whoever holds the pre-0.6 socket of this
# HOME. Deliberately scoped — a daemon started from some other --home/--prefix is a
# different install, and an installer has no business signalling it. (Measured
# 2026-09-18: a machine-wide match here meant that running install.sh inside a
# sandbox HOME killed the real, installed service on the author's machine.)
ih_legacy_daemon_pids() {
  local sock="$IH_LEGACY_HOME/$IH_LEGACY_SOCKET_NAME" pid cmd
  for pid in $(pgrep -f "$IH_LEGACY_DAEMON" 2>/dev/null || true); do
    cmd="$(ps -o command= -p "$pid" 2>/dev/null || true)"
    case "$cmd" in
      *"$IH_LEGACY_SHARE"*) printf '%s\n' "$pid" ;;
    esac
  done
  [ -S "$sock" ] || return 0
  for pid in $(lsof -t "$sock" 2>/dev/null || true); do
    cmd="$(ps -o command= -p "$pid" 2>/dev/null || true)"
    case "$cmd" in
      *"$IH_LEGACY_DAEMON"*) printf '%s\n' "$pid" ;;
    esac
  done
  return 0
}

# Every process on this machine still running the pre-0.6 binary, this layout's or
# not. Read-only, and used only to *report*: `doctor` and the installer name what
# they see, so a daemon from an unrelated layout is not silently ignored — it is a
# second copy of the weights, which is the thing this project exists to avoid.
ih_legacy_daemon_pids_anywhere() {
  pgrep -f "$IH_LEGACY_DAEMON" 2>/dev/null || true
}

# Ends a pre-0.6 daemon and clears the socket file it leaves in the old home.
# Silent when there is nothing to do — the usual case after one upgrade.
ih_service_reap_legacy() {
  local pid pids tries=0
  pids="$(ih_legacy_daemon_pids)"
  if [ -n "$pids" ]; then
    say "stopping the pre-0.6 daemon ($IH_LEGACY_DAEMON: $(printf '%s' "$pids" | tr '\n' ' '))"
    for pid in $pids; do kill "$pid" 2>/dev/null || true; done
    while [ -n "$(ih_legacy_daemon_pids)" ] && [ "$tries" -lt 60 ]; do
      sleep 0.25
      tries=$((tries + 1))
    done
    [ -z "$(ih_legacy_daemon_pids)" ] \
      || warn "a pre-0.6 daemon is still running: $(ih_legacy_daemon_pids | tr '\n' ' ')"
  fi
  # A SIGTERM'd daemon leaves its socket file behind; the migration would move it
  # into the new home, where it would satisfy every "does the socket exist" check.
  local old_socket="$IH_LEGACY_HOME/$IH_LEGACY_SOCKET_NAME"
  if [ -S "$old_socket" ] && ! ih_socket_listening_at "$old_socket"; then
    rm -f "$old_socket"
  fi
  # Whatever is left running the old binary somewhere else. Not signalled (that
  # would be another install's service) but named, because two of these on one
  # machine is exactly the "two copies of the weights" case.
  local others; others="$(ih_legacy_daemon_pids_anywhere | tr '\n' ' ')"
  if [ -n "${others// /}" ]; then
    warn "a pre-0.6 daemon from another layout is still running (pid ${others% }):"
    warn "  it holds its own copy of the weights — stop it with: kill ${others% }"
  fi
  return 0
}

# PIDs that hold the daemon socket open. Asking the OS rather than the daemon:
# a build older than the `pid` field cannot report one, and that is exactly the
# case that needs reaping.
ih_socket_owner_pids() {
  local sock pid
  sock="$(ih_socket)"
  [ -S "$sock" ] || return 0
  for pid in $(pgrep -f 'imagehived' 2>/dev/null || true); do
    lsof -p "$pid" 2>/dev/null | grep -qF "$sock" && printf '%s\n' "$pid"
  done
  return 0
}

# Ends whatever is serving the socket but is not the current launchd job, so that
# `stop`, `restart` and a reinstall actually hand the socket to the new binary.
# Only processes whose command line names imagehived are signalled.
ih_service_reap_stray() {
  local pid cmd tries=0
  [ -n "$(ih_socket_owner_pids)" ] || return 0
  for pid in $(ih_socket_owner_pids); do
    cmd="$(ps -o command= -p "$pid" 2>/dev/null || true)"
    case "$cmd" in
      *imagehived*) kill "$pid" 2>/dev/null || true ;;
      *) warn "pid $pid holds $(ih_socket) but is not imagehived — leaving it alone" ;;
    esac
  done
  while [ "$tries" -lt 60 ]; do
    [ -z "$(ih_socket_owner_pids)" ] || { sleep 0.25; tries=$((tries + 1)); continue; }
    return 0
  done
  warn "a daemon is still serving $(ih_socket) after SIGTERM: $(ih_socket_owner_pids | tr '\n' ' ')"
  return 0
}

# --- talking to the daemon ---------------------------------------------------

# Reads the daemon through the MCP front end, so the CLI exercises exactly the
# path the agents use. Prints key=value lines.
ih_status() {
  local mcp; mcp="$(ih_mcp)"
  [ -x "$mcp" ] || die "not installed: $mcp (run install.sh)"
  "$mcp" --status
}

ih_unload() {
  local mcp; mcp="$(ih_mcp)"
  [ -x "$mcp" ] || die "not installed: $mcp (run install.sh)"
  "$mcp" --unload
}

ih_peak_mb() { ih_status 2>/dev/null | awk -F= '$1=="last_peak_mb"{print $2}'; }
ih_resident() { ih_status 2>/dev/null | awk -F= '$1=="resident_tier"{print $2}'; }
# Which build is answering, and which process. Empty on a daemon older than the
# `pid` / `project_version` fields, which is itself the signal that the socket is
# held by a binary from before the last install.
ih_daemon_version() { ih_status 2>/dev/null | awk -F= '$1=="project_version"{print $2}'; }
ih_daemon_pid()     { ih_status 2>/dev/null | awk -F= '$1=="pid"{print $2}'; }

# --- misc --------------------------------------------------------------------

# ih_dir_size <path> -> human size, or "-" when missing
ih_dir_size() {
  [ -d "$1" ] || { printf '%s\n' "-"; return 0; }
  du -sh "$1" 2>/dev/null | awk '{print $1}'
}

ih_have() { command -v "$1" >/dev/null 2>&1; }
