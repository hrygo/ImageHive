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
    --home)         IMAGEHIVE_HOME="${2:-}"; shift 2 ;;
    --label)        IMAGEHIVE_LABEL="${2:-}"; shift 2 ;;
    --prefix)       IMAGEHIVE_PREFIX="${2:-}"; shift 2 ;;
    -h|--help)      usage; exit 0 ;;
    *)              usage; die "unknown option: $1" ;;
  esac
done

ih_load_conf

run() {
  if [ "$DRY_RUN" = "1" ]; then
    printf '  %swould run:%s %s\n' "$IH_DIM" "$IH_RESET" "$*" >&2
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
  say "${IH_BOLD}Uninstall${IH_RESET} — $(ih_label)"
  say ""
  say "will remove:"
  say "  launchd job   $(ih_label) ($(ih_plist))"
  say "  binaries      $(ih_bin_dir)/imagehived, imagehive-mcp, *.bundle"
  say "  command       $(ih_cli_path), $(ih_prefix)/share/imagehive"
  say "  MCP entries   any client wired to '${IH_SERVER_NAME}'"
  if [ -d "$IH_LEGACY_SHARE" ] || [ -e "$IH_LEGACY_CLI" ] || [ -f "$HOME/Library/LaunchAgents/$IH_LEGACY_LABEL.plist" ]; then
    say "  pre-0.6 names the command, its wrappers, the old launchd job and its MCP entries"
  fi
  if [ "$PURGE_MODELS" = "1" ]; then
    say "  models        $(ih_models) (--purge-models)"
  else
    say ""
  say "will keep:"
    say "  models        $(ih_models) ($(ih_dir_size "$(ih_models)"))"
    say "  config/logs   $(ih_config), $(ih_conf), $(ih_log)"
    if [ -d "$IH_LEGACY_HOME" ]; then
      say "  old app home  $IH_LEGACY_HOME ($(ih_dir_size "$IH_LEGACY_HOME")) — delete it yourself once you are sure"
    fi
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
  for name in $(ih_client_list); do
    ih_client_detect "$name" || continue
    ih_client_has "$name" 2>/dev/null && ih_client_remove "$name" || true
  done

  # Anything left under the pre-0.6 names. A daemon still running there is a
  # second copy of the weights, and its socket is a second socket: uninstalling
  # only the new name would leave the machine serving from the old one.
  ih_service_reap_legacy
  # Found by content, not by name: the label was user-settable (`--label`), so the
  # default name is only one of the shapes a pre-0.6 job can have.
  local plist label
  for plist in "$HOME/Library/LaunchAgents"/*.plist; do
    [ -f "$plist" ] || continue
    grep -qE "$IH_LEGACY_DAEMON|$IH_LEGACY_SHARE" "$plist" 2>/dev/null || continue
    label="$(basename "$plist" .plist)"
    step "the pre-0.6 job"
    run launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true
    run rm -f "$plist"
    say "removed the pre-0.6 job $label"
  done
  if [ -d "$IH_LEGACY_SHARE" ]; then
    run rm -rf "$IH_LEGACY_SHARE"
    say "removed the pre-0.6 command tree $IH_LEGACY_SHARE"
  fi
  if [ -e "$IH_LEGACY_CLI" ] || [ -L "$IH_LEGACY_CLI" ]; then
    run rm -f "$IH_LEGACY_CLI"
    say "removed the pre-0.6 command name $(basename "$IH_LEGACY_CLI")"
  fi
  step "service"
  if ih_service_loaded; then
    run launchctl bootout "gui/$(id -u)/$(ih_label)" || warn "could not stop the launchd job"
    say "stopped $(ih_label)"
  else
    hint "launchd job was not loaded"
  fi
  [ -f "$(ih_plist)" ] && { run rm -f "$(ih_plist)"; say "removed $(ih_plist)"; }
  # Scoped to this layout: the daemon holding *this* socket, and the front ends
  # started from *this* install's binaries. A blunt `pkill -f imagehived` would also
  # end a daemon belonging to another --home install — and the real one when this
  # script runs inside a sandbox HOME.
  ih_service_reap_stray
  local stray
  for stray in $(pgrep -f "$(ih_bin_dir)" 2>/dev/null || true); do
    kill "$stray" 2>/dev/null || true
  done
  # The daemon unlinks its socket on SIGTERM, but a wedged or SIGKILLed process
  # leaves the file behind — and "is anything answering on this socket?" is the
  # readiness check used by both installers, so a dead file outliving the service
  # makes the next install's verdict unreliable. Remove it once nothing owns it.
  if [ -S "$(ih_socket)" ]; then
    local waited=0
    while [ "$waited" -lt 20 ] && [ -n "$(ih_socket_owner_pids)" ]; do
      sleep 0.25
      waited=$((waited + 1))
    done
    run rm -f "$(ih_socket)"
    say "removed the leftover socket $(ih_socket)"
  fi

  step "binaries"
  local bin; bin="$(ih_bin_dir)"
  for target in "$bin/imagehived" "$bin/imagehive-mcp"; do
    [ -e "$target" ] && { run rm -f "$target"; say "removed $target"; }
  done
  if [ -d "$bin" ]; then
    local bundle
    for bundle in "$bin"/*.bundle; do
      [ -e "$bundle" ] && { run rm -rf "$bundle"; say "removed $(basename "$bundle")"; }
    done
  fi
  [ -L "$(ih_cli_path)" ] || [ -f "$(ih_cli_path)" ] && { run rm -f "$(ih_cli_path)"; say "removed $(ih_cli_path)"; }
  [ -d "$(ih_prefix)/share/imagehive" ] && {
    run rm -rf "$(ih_prefix)/share/imagehive"; say "removed $(ih_prefix)/share/imagehive"; }

  if [ "$PURGE_MODELS" = "1" ]; then
    step "artifacts"
    for dir in "$(ih_models)"/*; do
      [ -d "$dir" ] && { run rm -rf "$dir"; say "removed $dir"; }
    done
  fi

  step "done"
  say "The service is gone."
  if [ "$PURGE_MODELS" = "0" ]; then
    say "Artifacts are still on disk ($(ih_dir_size "$(ih_models)")) so a reinstall is quick:"
    say "  ./install.sh --model none"
    say "Remove them with: ./uninstall.sh --purge-models"
  fi
}

main
