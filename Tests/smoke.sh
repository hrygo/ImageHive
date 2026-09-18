#!/usr/bin/env bash
# End-to-end smoke test for the local image service.
#
#   tests/smoke.sh            # protocol + shared-weights assertions (one generation)
#   tests/smoke.sh --quick    # protocol only, no model needed (CI default)
#
# Runs against a private daemon on a private socket, so it never disturbs an
# installed service. Artifacts are taken from the installed configuration when
# they exist; without them the generation part is skipped and the protocol part
# still runs.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../cli/lib/common.sh
. "$REPO_DIR/cli/lib/common.sh"

QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1
for arg in "$@"; do [ "$arg" = "--quick" ] && QUICK=1; done

work="$(mktemp -d)"
daemon_pid=""
cleanup() {
  if [ -n "$daemon_pid" ]; then
    kill "$daemon_pid" 2>/dev/null || true
    wait "$daemon_pid" 2>/dev/null || true   # reap it, so no "Terminated" notice
  fi
  rm -rf "$work"
}
trap cleanup EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

served="$REPO_DIR/.build/release/sensenova-served"
mcp="$REPO_DIR/.build/release/sensenova-mcp"
[ -x "$served" ] || served="$(sv_served)"
[ -x "$mcp" ] || mcp="$(sv_mcp)"
[ -x "$served" ] || fail "sensenova-served not found — run: swift build -c release"
[ -x "$mcp" ] || fail "sensenova-mcp not found — run: swift build -c release"

export SENSENOVA_HOME="$work/home"
export SENSENOVA_SOCKET="$work/served.sock"
export SENSENOVA_TTL_SECONDS=30
export SENSENOVA_MIN_WARM_SECONDS=5
mkdir -p "$SENSENOVA_HOME"

# Point the private daemon at whatever artifacts the installed service uses.
host_home="$HOME/Library/Application Support/SenseNovaU1"
[ -f "$host_home/config.json" ] || host_home="$HOME/Models/SenseNova-U1.5"   # pre-0.2 layout
models_root="$(awk -F= '/^SENSENOVA_MODELS=/{v=$2; gsub(/^'\''|'\''$/,"",v); print v}' \
  "$host_home/service.conf" 2>/dev/null || true)"
[ -n "$models_root" ] || models_root="$host_home/models"
[ -d "$models_root" ] || models_root="$host_home/artifacts"                   # pre-0.2 layout
fast_dir=""
quality_dir=""
if [ -f "$host_home/config.json" ]; then
  # Two lines, not two words: the paths live under "Application Support".
  { read -r fast_dir; read -r quality_dir; } <<< "$(python3 -c '
import json, os, sys
config = json.load(open(sys.argv[1]))
models = sys.argv[2]
def absolute(value):
    return value if os.path.isabs(value) else os.path.join(models, value)
print(absolute(config.get("fast_artifact", "")))
print(absolute(config.get("quality_artifact", "")))
' "$host_home/config.json" "$models_root")"
fi
[ -n "$fast_dir" ] && [ -f "$fast_dir/config.json" ] || fast_dir=""
[ -n "$quality_dir" ] && [ -f "$quality_dir/config.json" ] || quality_dir=""
export SENSENOVA_FAST_ARTIFACT="${fast_dir:-$SENSENOVA_HOME/artifacts/missing-fast}"
export SENSENOVA_QUALITY_ARTIFACT="${quality_dir:-$SENSENOVA_HOME/artifacts/missing-quality}"

json_call() { # <id> <method> [params]
  printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":$1,\"method\":\"$2\"${3:+,\"params\":$3}}"
}

echo "== protocol"
out="$( { json_call 1 tools/list; json_call 2 server/discover; } | "$mcp" 2>/dev/null )"
tools="$(printf '%s\n' "$out" | python3 -c '
import json, sys
for line in sys.stdin:
    message = json.loads(line)
    if message.get("id") == 1:
        print(" ".join(t["name"] for t in message["result"]["tools"]))
' 2>/dev/null || true)"
versions="$(printf '%s\n' "$out" | python3 -c '
import json, sys
for line in sys.stdin:
    message = json.loads(line)
    if message.get("id") == 2:
        print(",".join(message["result"]["supportedVersions"]))
' 2>/dev/null || true)"
[ -n "$tools" ] || fail "tools/list returned nothing"
case "$tools" in *generate_image*edit_image*describe_image*model_status*unload_model*) ;; *) fail "unexpected tools: $tools";; esac
echo "   tools: $tools"
case "$versions" in *2026-07-28*) echo "   server/discover: $versions";; *) fail "server/discover did not advertise 2026-07-28";; esac

echo "== daemon lifecycle"
"$served" >/dev/null 2>"$work/daemon.log" &
daemon_pid=$!
for _ in $(seq 1 60); do [ -S "$SENSENOVA_SOCKET" ] && break; sleep 0.25; done
[ -S "$SENSENOVA_SOCKET" ] || fail "daemon did not bind $SENSENOVA_SOCKET (see $work/daemon.log)"

second="$(SENSENOVA_SOCKET="$SENSENOVA_SOCKET" "$served" 2>&1 || true)"
case "$second" in *"another instance is live"*) echo "   second instance refused" ;; *) fail "second instance was not refused: $second";; esac

status="$("$mcp" --status)"
case "$status" in *resident_tier=cold*) echo "   $(echo "$status" | tr '\n' ' ')" ;; *) fail "expected a cold start, got: $status";; esac

if [ "$QUICK" = "1" ] || [ -z "$fast_dir" ]; then
  [ "$QUICK" = "1" ] && echo "== quick mode: skipping the generation assertions" \
    || echo "== no fast artifact on this host: skipping the generation assertions"
  echo "PASS (protocol)"
  exit 0
fi

echo "== shared weights under concurrency"
"$mcp" --unload >/dev/null
client_pids=()
for i in 1 2 3; do
  (
    { json_call "1$i" tools/call "{\"name\":\"generate_image\",\"arguments\":{\"prompt\":\"test pattern $i\",\"tier\":\"fast\",\"width\":256,\"height\":256,\"seed\":$i}}"; } \
      | "$mcp" 2>/dev/null > "$work/client$i.json"
  ) &
  client_pids+=($!)
done
# Wait for the clients only: a bare `wait` would also wait for the background
# daemon, which never exits.
for pid in "${client_pids[@]}"; do wait "$pid"; done
for i in 1 2 3; do
  text="$(python3 -c '
import json, sys
message = json.loads(open(sys.argv[1]).read().split("\n")[0])
print(message["result"]["content"][0]["text"])
' "$work/client$i.json" 2>/dev/null || true)"
  case "$text" in Wrote*) echo "   client$i: $text" ;; *) fail "client$i produced no image: $text";; esac
done

loads="$("$mcp" --status | awk -F= '$1=="loads_total"{print $2}')"
[ "$loads" = "1" ] || fail "expected exactly one load for three concurrent clients, got $loads"
residents="$(pgrep -f "sensenova-served" 2>/dev/null | wc -l | tr -d ' ' || true)"
[ "$residents" -ge 1 ] || fail "daemon disappeared"
echo "   loads_total=$loads with three concurrent clients"

echo "== release"
"$mcp" --unload | sed 's/^/   /'
"$mcp" --status | grep -q 'resident_tier=cold' || fail "unload did not return to cold"

echo "PASS"
