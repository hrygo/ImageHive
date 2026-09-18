#!/usr/bin/env bash
# Build the local service products, then restart the daemon if launchd owns it.
#
#   ./scripts/deploy.sh
#
# Overridable: SENSENOVA_LAUNCHD_LABEL (default com.hrygo.sensenova-u1).

set -euo pipefail

cd "$(dirname "$0")/.."
label="${SENSENOVA_LAUNCHD_LABEL:-com.hrygo.sensenova-u1}"

swift build -c release --product sensenova-served
swift build -c release --product sensenova-mcp

if launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1; then
  launchctl kickstart -k "gui/$(id -u)/$label"
  echo "restarted $label"
else
  echo "$label is not bootstrapped; the MCP front end will start the daemon on demand"
fi

echo "built: $(pwd)/.build/release/sensenova-served, $(pwd)/.build/release/sensenova-mcp"
