#!/usr/bin/env bash
# Remove the service, its LaunchAgent, its binaries and its MCP registrations.
#
#   ./uninstall.sh --dry-run         # show exactly what would be removed
#   ./uninstall.sh                   # asks before removing anything
#   ./uninstall.sh --yes             # no prompt (for scripts)
#   ./uninstall.sh --purge-models    # also delete downloaded artifacts
#
# Downloaded artifacts are kept by default: they are the expensive part and
# re-downloading them is the slowest step of a reinstall.

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
PURGE_MODELS=0

usage() { sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)      DRY_RUN=1; shift ;;
    --yes|-y)       ASSUME_YES=1; shift ;;
    --purge-models) PURGE_MODELS=1; shift ;;
    --home)         SENSENOVA_HOME="${2:-}"; shift 2 ;;
    --label)        SENSENOVA_LABEL="${2:-}"; shift 2 ;;
    --prefix)       SENSENOVA_PREFIX="${2:-}"; shift 2 ;;
    -h|--help)      usage; exit 0 ;;
    *)              usage; die "unknown option: $1" ;;
  esac
done

sv_load_conf

run() {
  if [ "$DRY_RUN" = "1" ]; then
    printf '  %swould run:%s %s\n' "$SV_DIM" "$SV_RESET" "$*" >&2
    return 0
  fi
  "$@"
}

confirm() {
  [ "$ASSUME_YES" = "1" ] && return 0
  printf 'Remove these? [y/N] '
  local answer=""
  read -r answer || true
  case "$answer" in [yY]*) return 0 ;; *) die "cancelled" ;; esac
}

main() {
  say "${SV_BOLD}Uninstall${SV_RESET} — $(sv_label)"
  say ""
  say "will remove:"
  say "  launchd job   $(sv_label) ($(sv_plist))"
  say "  binaries      $(sv_bin_dir)/sensenova-served, sensenova-mcp, *.bundle"
  say "  command       $(sv_cli_path), $(sv_prefix)/share/sensenova-u1"
  say "  MCP entries   any client wired to '${SV_SERVER_NAME}'"
  if [ "$PURGE_MODELS" = "1" ]; then
    say "  models        $(sv_models) (--purge-models)"
  else
    say ""
    say "will keep:"
    say "  models        $(sv_models) ($(sv_dir_size "$(sv_models)"))"
    say "  config/logs   $(sv_config), $(sv_conf), $(sv_log)"
  fi
  say ""

  if [ "$DRY_RUN" = "1" ]; then
    warn "dry run: nothing will be changed"
    run true
    return 0
  fi
  confirm

  step "clients"
  local name
  for name in $(sv_client_list); do
    sv_client_detect "$name" || continue
    sv_client_has "$name" 2>/dev/null && sv_client_remove "$name" || true
  done

  step "service"
  if sv_service_loaded; then
    run launchctl bootout "gui/$(id -u)/$(sv_label)" || warn "could not stop the launchd job"
    say "stopped $(sv_label)"
  else
    hint "launchd job was not loaded"
  fi
  [ -f "$(sv_plist)" ] && { run rm -f "$(sv_plist)"; say "removed $(sv_plist)"; }
  pkill -f "sensenova-served" >/dev/null 2>&1 || true
  pkill -f "sensenova-mcp" >/dev/null 2>&1 || true
  # The daemon unlinks its socket on SIGTERM, but a wedged or SIGKILLed process
  # leaves the file behind — and "is anything answering on this socket?" is the
  # readiness check used by both installers, so a dead file outliving the service
  # makes the next install's verdict unreliable. Remove it once nothing owns it.
  if [ -S "$(sv_socket)" ]; then
    local waited=0
    while [ "$waited" -lt 20 ] && [ -n "$(sv_socket_owner_pids)" ]; do
      sleep 0.25
      waited=$((waited + 1))
    done
    run rm -f "$(sv_socket)"
    say "removed the leftover socket $(sv_socket)"
  fi

  step "binaries"
  local bin; bin="$(sv_bin_dir)"
  for target in "$bin/sensenova-served" "$bin/sensenova-mcp"; do
    [ -e "$target" ] && { run rm -f "$target"; say "removed $target"; }
  done
  if [ -d "$bin" ]; then
    local bundle
    for bundle in "$bin"/*.bundle; do
      [ -e "$bundle" ] && { run rm -rf "$bundle"; say "removed $(basename "$bundle")"; }
    done
  fi
  [ -L "$(sv_cli_path)" ] || [ -f "$(sv_cli_path)" ] && { run rm -f "$(sv_cli_path)"; say "removed $(sv_cli_path)"; }
  [ -d "$(sv_prefix)/share/sensenova-u1" ] && {
    run rm -rf "$(sv_prefix)/share/sensenova-u1"; say "removed $(sv_prefix)/share/sensenova-u1"; }

  if [ "$PURGE_MODELS" = "1" ]; then
    step "artifacts"
    for dir in "$(sv_models)"/*; do
      [ -d "$dir" ] && { run rm -rf "$dir"; say "removed $dir"; }
    done
  fi

  step "done"
  say "The service is gone."
  if [ "$PURGE_MODELS" = "0" ]; then
    say "Artifacts are still on disk ($(sv_dir_size "$(sv_models)")) so a reinstall is quick:"
    say "  ./install.sh --model none"
    say "Remove them with: ./uninstall.sh --purge-models"
  fi
}

main
