#!/usr/bin/env bash
# End-to-end test for the command-line front end.
#
#   Tests/cli.sh            # everything (needs one installed artifact)
#   Tests/cli.sh --quick    # argument handling and help only, no model
#
# Runs the repo's own CLI against a private daemon on a private socket with its own
# HOME, PREFIX and output directory, so the installed service is never touched. The
# generation assertions are skipped when this host has no artifact to run.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

QUICK=0
for arg in "$@"; do [ "$arg" = "--quick" ] && QUICK=1; done

work="$(mktemp -d /tmp/snv-cli.XXXXXX)"
daemon_pid=""
cleanup() {
  [ -n "$daemon_pid" ] && { kill "$daemon_pid" 2>/dev/null || true; wait "$daemon_pid" 2>/dev/null || true; }
  /usr/bin/trash "$work" >/dev/null 2>&1 || true
}
trap cleanup EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok()   { printf '   %s\n' "$*"; }

served="$REPO_DIR/.build/release/sensenova-served"
mcp="$REPO_DIR/.build/release/sensenova-mcp"
[ -x "$served" ] || fail "sensenova-served not found — run: swift build -c release"
[ -x "$mcp" ] || fail "sensenova-mcp not found — run: swift build -c release"

# The CLI finds the front end through PREFIX, so point a throwaway prefix at the
# binaries this checkout just built.
mkdir -p "$work/prefix/share/sensenova-u1/bin" "$work/home" "$work/out"
ln -sf "$served" "$work/prefix/share/sensenova-u1/bin/sensenova-served"
ln -sf "$mcp" "$work/prefix/share/sensenova-u1/bin/sensenova-mcp"

# Whatever the installed service uses is what this test can run.
host_home="$HOME/Library/Application Support/SenseNovaU1"
models_root="$(awk -F= '/^SENSENOVA_MODELS=/{v=$2; gsub(/^'\''|'\''$/,"",v); print v}' \
  "$host_home/service.conf" 2>/dev/null || true)"
[ -n "$models_root" ] || models_root="$host_home/models"
artifact="$(python3 -c '
import json, os, sys
try:
    config = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
value = config.get("quality_artifact", "")
if not value:
    sys.exit(0)
path = value if os.path.isabs(value) else os.path.join(sys.argv[2], value)
print(path if os.path.exists(os.path.join(path, "config.json")) else "")
' "$host_home/config.json" "$models_root" 2>/dev/null || true)"

export SENSENOVA_HOME="$work/home"
export SENSENOVA_PREFIX="$work/prefix"
export SENSENOVA_SOCKET="$work/served.sock"
export SENSENOVA_OUT="$work/out"
export SENSENOVA_QUALITY_ARTIFACT="${artifact:-$work/missing-quality}"
export SENSENOVA_FAST_ARTIFACT="$work/missing-fast"
cli=(bash "$REPO_DIR/cli/sensenova-u1")

echo "== help and argument handling (no service needed)"
# Captured, not piped into `grep -q`: grep exiting on the first match kills the
# writer with SIGPIPE, which pipefail reports as a failure (measured).
generate_help="$("${cli[@]}" generate --help)"
case "$generate_help" in
  *--seed*) ;;
  *) fail "generate --help does not mention --seed" ;;
esac
case "$generate_help" in
  *"multiples of 32"*) ;;
  *) fail "generate --help does not state the size rule" ;;
esac
models_help="$("${cli[@]}" models --help)"
case "$models_help" in
  *"models pull"*) ;;
  *) fail "models --help says nothing about pulling" ;;
esac
"${cli[@]}" unload --help >/dev/null || fail "unload --help failed"
ok "subcommands answer --help"

wrong_size="$("${cli[@]}" generate --prompt x --width 1000 --height 512 2>&1 || true)"
case "$wrong_size" in
  *"multiple of 32"*"992 or 1024"*) ok "$(printf '%s' "$wrong_size" | head -1)" ;;
  *) fail "a size that is not a multiple of 32 was not caught before the request: $wrong_size" ;;
esac
"${cli[@]}" generate --prompt x --width 1000 --height 512 >/dev/null 2>&1 \
  && fail "a bad width exited 0"

if [ "$QUICK" = "1" ] || [ ! -f "$SENSENOVA_QUALITY_ARTIFACT/config.json" ]; then
  [ "$QUICK" = "1" ] && echo "== quick mode: skipping everything that needs a model" \
    || echo "== no artifact on this host: skipping everything that needs a model"
  echo "PASS (cli, no model)"
  exit 0
fi

echo "== the service the CLI talks to"
"$served" >/dev/null 2>"$work/daemon.log" &
daemon_pid=$!
for _ in $(seq 1 60); do [ -S "$SENSENOVA_SOCKET" ] && break; sleep 0.25; done
[ -S "$SENSENOVA_SOCKET" ] || fail "the daemon did not bind $SENSENOVA_SOCKET"

echo "== what the service accepts"
options_text="$("${cli[@]}" options)"
case "$options_text" in
  *"multiples of 32"*) ;;
  *) fail "options did not report the size rule" ;;
esac
ok "$(printf '%s\n' "$options_text" | head -1)"

echo "== a fixed seed, a sidecar, and structured output"
args=(generate --prompt "cli probe" --seed 4242 --width 256 --height 256 --steps 4)
first="$("${cli[@]}" "${args[@]}" --json)"
second="$("${cli[@]}" "${args[@]}" --json)"
python3 - "$first" "$second" <<'PY' || fail "the CLI's JSON output did not hold up (see above)"
import hashlib, json, os, sys

a, b = json.loads(sys.argv[1]), json.loads(sys.argv[2])
assert a.get("ok") is True, a
assert a.get("seed") == 4242 and a.get("seed_source") == "explicit", a
assert a.get("metadata", "").endswith(".png.json"), a.get("metadata")
record = json.load(open(a["metadata"]))
assert record["prompt_sha256"] == hashlib.sha256(record["prompt"].encode()).hexdigest()
same = open(a["path"], "rb").read() == open(b["path"], "rb").read()
assert same, "the same seed produced different bytes"
print("   --json: seed=%s %sx%s steps=%s cfg=%s same-bytes=%s"
      % (a["seed"], a["width"], a["height"], a["steps"], a["cfg"], same))
PY

echo "== one line per image, and --out moves image + metadata together"
text="$("${cli[@]}" "${args[@]}" --out "$work/named")"
case "$text" in "Wrote $work/named/"*) ok "$(printf '%s' "$text" | head -c 120)..." ;;
  *) fail "--out did not rewrite the reported path: $text" ;;
esac
count="$(ls -1 "$work/named" | wc -l | tr -d ' ')"
[ "$count" = "2" ] || fail "expected a PNG and its sidecar in $work/named, found $count files"

echo "== several images in one call"
batch="$("${cli[@]}" "${args[@]}" --seed 500 --n 2 --json --out "$work/batch")"
python3 - "$batch" "$work/batch" <<'PY' || fail "the batch run did not produce two images (see above)"
import json, os, sys
items = json.loads(sys.argv[1])
assert isinstance(items, list) and len(items) == 2, items
assert [i["seed"] for i in items] == [500, 501], [i.get("seed") for i in items]
files = sorted(os.listdir(sys.argv[2]))
assert len(files) == 4, files          # two PNGs, two sidecars
print("   seeds %s, files %s" % ([i["seed"] for i in items], len(files)))
PY

echo "== a request the daemon refuses does not take the service down"
"${cli[@]}" generate --prompt x --width 1000 --height 512 >/dev/null 2>&1 || true
"${cli[@]}" status >/dev/null || fail "the service stopped answering after a refused request"
ok "still answering"

echo "PASS (cli)"
