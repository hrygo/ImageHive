#!/usr/bin/env bash
# Compatibility entry point: rebuild, reinstall into $SENSENOVA_HOME/bin and
# restart the daemon. install.sh is the source of truth — it does everything
# this script used to do (and wires clients), so this is now a thin wrapper.
#
#   ./scripts/deploy.sh                       # == install.sh --model none --clients none
#   ./scripts/deploy.sh --clients auto        # also (re)wire detected MCP clients
#
# Keeps existing artifacts (never downloads a model) and keeps the install
# layout recorded in $SENSENOVA_HOME/service.conf.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "$REPO_DIR/install.sh" --model none --clients none "$@"
