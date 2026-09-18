#!/usr/bin/env bash
# Build the local service products, install them where the machine expects them,
# then restart the daemon if launchd owns it.
#
#   ./scripts/deploy.sh
#
# Installed to $SENSENOVA_HOME/bin (default ~/Models/SenseNova-U1.5/bin) so the
# LaunchAgent and the MCP client registrations never point into a build tree.
#
# Overridable: SENSENOVA_HOME, SENSENOVA_LAUNCHD_LABEL (default com.hrygo.sensenova-u1).

set -euo pipefail

cd "$(dirname "$0")/.."
label="${SENSENOVA_LAUNCHD_LABEL:-com.hrygo.sensenova-u1}"
home="${SENSENOVA_HOME:-$HOME/Models/SenseNova-U1.5}"
bin="$home/bin"

swift build -c release --product sensenova-served
swift build -c release --product sensenova-mcp

mkdir -p "$bin"
install -m 0755 .build/release/sensenova-served "$bin/sensenova-served"
install -m 0755 .build/release/sensenova-mcp "$bin/sensenova-mcp"

# MLX resolves its Metal library from a resource bundle that must sit next to
# the executable; installing the binary alone gives "Failed to load the default
# metallib" and every generation dies.
for bundle in .build/release/*.bundle; do
  [ -e "$bundle" ] || continue
  rm -rf "$bin/$(basename "$bundle")"
  cp -R "$bundle" "$bin/"
done

echo "installed: $bin/sensenova-served, $bin/sensenova-mcp, $(ls -d "$bin"/*.bundle | wc -l | tr -d ' ') resource bundle(s)"

if launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1; then
  launchctl kickstart -k "gui/$(id -u)/$label"
  echo "restarted $label"
else
  echo "$label is not bootstrapped; the MCP front end will start the daemon on demand"
fi
