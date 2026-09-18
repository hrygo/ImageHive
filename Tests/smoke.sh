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
export SENSENOVA_OUT="$work/out"
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

# Which artifact this host has installed decides what the generation assertions
# can run on, and whether the single-artifact fallback is exercised. One artifact
# is a supported setup: the daemon serves a request for the missing tier from the
# installed one, at that artifact's own recipe.
installed_tiers=""
[ -n "$fast_dir" ] && installed_tiers="fast"
[ -n "$quality_dir" ] && installed_tiers="${installed_tiers:+$installed_tiers }quality"
present_tier=""
absent_tier=""
case "$installed_tiers" in
  fast)    present_tier=fast;    absent_tier=quality ;;
  quality) present_tier=quality; absent_tier=fast ;;
  "")      ;;
  *)       present_tier="${installed_tiers%% *}" ;;   # both: no fallback to prove
esac

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
case "$tools" in *generate_image*edit_image*describe_image*model_options*model_status*unload_model*) ;; *) fail "unexpected tools: $tools";; esac
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

if [ "$QUICK" = "1" ] || [ -z "$present_tier" ]; then
  [ "$QUICK" = "1" ] && echo "== quick mode: skipping the generation assertions" \
    || echo "== no artifact on this host: skipping the generation assertions"
  echo "PASS (protocol)"
  exit 0
fi

echo "== installed artifacts: ${present_tier} (missing: ${absent_tier})"

echo "== shared weights under concurrency"
"$mcp" --unload >/dev/null
client_pids=()
for i in 1 2 3; do
  (
    { json_call "1$i" tools/call "{\"name\":\"generate_image\",\"arguments\":{\"prompt\":\"test pattern $i\",\"tier\":\"$present_tier\",\"width\":256,\"height\":256,\"seed\":$i}}"; } \
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

if [ -n "$absent_tier" ]; then
echo "== request for the tier that is not installed"
{ json_call 21 tools/call "{\"name\":\"generate_image\",\"arguments\":{\"prompt\":\"fallback probe\",\"tier\":\"$absent_tier\",\"width\":256,\"height\":256,\"seed\":9}}"; } \
  | "$mcp" 2>/dev/null > "$work/fallback.json"
fallback="$(python3 -c '
import json, sys
message = json.loads(open(sys.argv[1]).read().split("\n")[0])
result = message["result"]
if result.get("isError"):
    print("ERROR " + result["content"][0]["text"])
else:
    structured = result.get("structuredContent", {})
    print("%s|%s|%s" % (structured.get("tier"), structured.get("tier_requested"),
                        result["content"][0]["text"]))
' "$work/fallback.json")"
case "$fallback" in
  ERROR*) fail "a request for the tier this host did not install was not served: $fallback" ;;
esac
fb_tier="${fallback%%|*}"; fb_requested="${fallback#*|}"; fb_requested="${fb_requested%%|*}"
fb_text="${fallback#*|*|}"
[ "$fb_tier" = "$present_tier" ] \
  || fail "expected the $present_tier artifact to answer, got tier '$fb_tier'"
[ "$fb_requested" = "$absent_tier" ] \
  || fail "the reply should name the tier that was asked for, got '$fb_requested'"
case "$fb_text" in *"tier $present_tier"*) echo "   $fb_text" ;;
  *) fail "the reply does not name the tier that answered: $fb_text" ;;
esac
else
  echo "== both artifacts installed: nothing to fall back to"
fi

echo "== release"
"$mcp" --unload | sed 's/^/   /'
"$mcp" --status | grep -q 'resident_tier=cold' || fail "unload did not return to cold"

echo "== what the model accepts (model_options)"
{ json_call 31 tools/call '{"name":"model_options","arguments":{}}'; } | "$mcp" 2>/dev/null > "$work/options.json"
options="$(python3 -c '
import json, sys
result = json.loads(open(sys.argv[1]).read().split("\n")[0])["result"]
if result.get("isError"):
    print("ERROR " + result["content"][0]["text"])
else:
    options = result.get("structuredContent", {})
    sizes = options.get("sizes", {})
    negative = options.get("negative_prompt", {})
    print("%s | negative generate=%s edit=%s"
          % (sizes.get("rule", ""), negative.get("generate"), negative.get("edit")))
' "$work/options.json")"
case "$options" in
  ERROR*) fail "model_options failed: $options" ;;
  *"multiples of 32"*"generate=True edit=False"*) echo "   $options" ;;
  *) fail "model_options did not report the size rule and the negative asymmetry: $options" ;;
esac

echo "== a size the model cannot render is refused, and the daemon survives it"
{ json_call 32 tools/call '{"name":"generate_image","arguments":{"prompt":"bad size","width":1000,"height":1000}}'; } \
  | "$mcp" 2>/dev/null > "$work/badsize.json"
bad="$(python3 -c '
import json, sys
result = json.loads(open(sys.argv[1]).read().split("\n")[0])["result"]
print(("ERROR " if result.get("isError") else "ACCEPTED ") + result["content"][0]["text"])
' "$work/badsize.json")"
case "$bad" in
  "ERROR"*"multiple of 32"*) echo "   $bad" ;;
  *) fail "a size that is not a multiple of 32 was not refused with an explanation: $bad" ;;
esac
# Until this check existed, MLX aborted the whole process on this request and every
# other client of the shared model died with it.
"$mcp" --status >/dev/null 2>&1 || fail "the daemon did not survive a size it cannot render"

echo "== the same seed writes the same bytes, and every image has a sidecar"
for n in 1 2; do
  { json_call "4$n" tools/call "{\"name\":\"generate_image\",\"arguments\":{\"prompt\":\"reproducibility probe\",\"tier\":\"$present_tier\",\"width\":256,\"height\":256,\"steps\":4,\"seed\":777}}"; } \
    | "$mcp" 2>/dev/null > "$work/seed$n.json"
done
python3 - "$work/seed1.json" "$work/seed2.json" <<'PY' || fail "seed/metadata assertions failed (see above)"
import hashlib, json, os, sys

def load(path):
    result = json.loads(open(path).read().split("\n")[0])["result"]
    if result.get("isError"):
        sys.exit("generate_image failed: " + result["content"][0]["text"])
    return result["structuredContent"]

first, second = load(sys.argv[1]), load(sys.argv[2])
for name, r in (("first", first), ("second", second)):
    assert r.get("seed") == 777, ("seed", name, r.get("seed"))
    assert r.get("seed_source") == "explicit", ("seed_source", name, r.get("seed_source"))
    assert r.get("metadata"), ("no sidecar path in the reply", name, sorted(r))

record = json.load(open(first["metadata"]))
assert os.path.basename(first["metadata"]) == os.path.basename(first["path"]) + ".json"
assert record["prompt_sha256"] == hashlib.sha256(record["prompt"].encode()).hexdigest()
for key in ("seed", "seed_source", "width", "height", "steps", "cfg", "tier", "artifact", "seconds"):
    assert key in record, ("sidecar is missing " + key, sorted(record))

same = open(first["path"], "rb").read() == open(second["path"], "rb").read()
print("   %s vs %s: identical=%s, sidecar keys=%d"
      % (os.path.basename(first["path"]), os.path.basename(second["path"]), same, len(record)))
assert same, "the same seed produced different bytes"
PY

echo "== status answers while a generation is running"
( { json_call 51 tools/call "{\"name\":\"generate_image\",\"arguments\":{\"prompt\":\"slow probe\",\"tier\":\"$present_tier\",\"width\":768,\"height\":768,\"steps\":30,\"seed\":11}}"; } \
    | "$mcp" 2>/dev/null > "$work/slow.json" ) &
slow_pid=$!
sleep 3
if kill -0 "$slow_pid" 2>/dev/null; then
  started="$(python3 -c 'import time; print(time.time())')"
  during="$("$mcp" --status)"
  took="$(python3 -c "import time; print(round(time.time() - float('$started'), 1))")"
  case "$during" in
    *"current="*) echo "   answered in ${took}s while busy: $(printf '%s' "$during" | tr '\n' ' ')" ;;
    *) echo "   answered in ${took}s (the job had already finished)" ;;
  esac
  # Queued behind the job, this call would take as long as the job does.
  python3 -c "import sys; sys.exit(0 if float('$took') < 10 else 1)" \
    || fail "status was queued behind the generation (${took}s): the actor is blocking again"
else
  echo "   (the job finished before it could be observed)"
fi
wait "$slow_pid" || true

echo "PASS"
