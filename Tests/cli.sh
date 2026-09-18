#!/usr/bin/env bash
# End-to-end test for the command-line front end.
#
#   Tests/cli.sh            # everything (needs one installed artifact)
#   Tests/cli.sh --quick    # argument handling, protocol and socket lifecycle only
#
# Runs the repo's own CLI against a private daemon on a private socket with its own
# HOME, PREFIX and output directory, so the installed service is never touched. The
# generation assertions are skipped when this host has no artifact to run; everything
# else (the argument contract, the socket's life and death) runs either way, which is
# what `make test-quick` and CI depend on.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

QUICK=0
for arg in "$@"; do [ "$arg" = "--quick" ] && QUICK=1; done

work="$(mktemp -d /tmp/ih-cli.XXXXXX)"
daemon_pid=""
cleanup() {
  [ -n "$daemon_pid" ] && { kill "$daemon_pid" 2>/dev/null || true; wait "$daemon_pid" 2>/dev/null || true; }
  /usr/bin/trash "$work" >/dev/null 2>&1 || true
}
trap cleanup EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok()   { printf '   %s\n' "$*"; }

served="$REPO_DIR/.build/release/imagehived"
mcp="$REPO_DIR/.build/release/imagehive-mcp"
[ -x "$served" ] || fail "imagehived not found — run: swift build -c release"
[ -x "$mcp" ] || fail "imagehive-mcp not found — run: swift build -c release"

# The CLI finds the front end through PREFIX, so point a throwaway prefix at the
# binaries this checkout just built.
mkdir -p "$work/prefix/share/imagehive/bin" "$work/home" "$work/out"
ln -sf "$served" "$work/prefix/share/imagehive/bin/imagehived"
ln -sf "$mcp" "$work/prefix/share/imagehive/bin/imagehive-mcp"

# Whatever the installed service uses is what this test can run. The pre-0.6 app
# home is in the list because a machine that has not run the 0.6 install keeps its
# service there, and this test reads the real artifacts rather than downloading any.
host_home="$HOME/Library/Application Support/ImageHive"
[ -f "$host_home/config.json" ] || host_home="$HOME/Library/Application Support/SenseNovaU1"
models_root="$(awk -F= '/^(IMAGEHIVE|SENSENOVA)_MODELS=/{v=$2; gsub(/^'\''|'\''$/,"",v); print v}' \
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

export IMAGEHIVE_HOME="$work/home"
export IMAGEHIVE_PREFIX="$work/prefix"
export IMAGEHIVE_SOCKET="$work/imagehived.sock"
export IMAGEHIVE_OUT="$work/out"
export IMAGEHIVE_QUALITY_ARTIFACT="${artifact:-$work/missing-quality}"
export IMAGEHIVE_FAST_ARTIFACT="$work/missing-fast"
cli=(bash "$REPO_DIR/cli/imagehive")

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

# Everything below runs on a cold daemon — the protocol, the argument contract, the
# socket's life and death — and only the three generation blocks need weights. The
# quick run therefore covers the daemon-side checks too (CI runs only --quick).
have_model=1
if [ "$QUICK" = "1" ] || [ ! -f "$IMAGEHIVE_QUALITY_ARTIFACT/config.json" ]; then
  have_model=0
fi

echo "== the service the CLI talks to"
# A config.json that exists but cannot be parsed. The daemon starts anyway and serves
# the built-in defaults, so nothing else in `doctor` looks wrong; before this check
# existed a truncated file, a type-wrong `ttl_seconds` and a 000-mode file all ran
# the defaults with no trace anywhere. (smoke.sh asserts the daemon's own side.)
printf '{"ttl_seconds": "600",\n' > "$IMAGEHIVE_HOME/config.json"
"$served" >/dev/null 2>"$work/daemon.log" &
daemon_pid=$!
# Detach from this shell's job table: bash otherwise prints its own
# "Terminated: 15" line when `stop` kills it. The pid is still ours to kill.
disown "$daemon_pid" 2>/dev/null || true
for _ in $(seq 1 60); do [ -S "$IMAGEHIVE_SOCKET" ] && break; sleep 0.25; done
[ -S "$IMAGEHIVE_SOCKET" ] || fail "the daemon did not bind $IMAGEHIVE_SOCKET"

echo "== doctor reports a config.json whose settings are being ignored"
doctor_text="$("${cli[@]}" doctor 2>&1 || true)"
case "$doctor_text" in
  *"config.json is not valid JSON"*) ok "flagged, where it used to print a ✓" ;;
  *) fail "doctor did not flag the malformed config.json: $(printf '%s\n' "$doctor_text" | grep config.json)" ;;
esac
rm -f "$IMAGEHIVE_HOME/config.json"

echo "== what the service accepts"
options_text="$("${cli[@]}" options)"
case "$options_text" in
  *"multiples of 32"*) ;;
  *) fail "options did not report the size rule" ;;
esac
ok "$(printf '%s\n' "$options_text" | head -1)"

if [ "$have_model" = "1" ]; then
echo "== a fixed seed, a sidecar, and structured output"
# A seed of 1 is also the sharpest test of the protocol's type handling: it is the
# number that used to be read as a boolean (see jsonIsBoolean in the daemon).
args=(generate --prompt "cli probe" --seed 1 --width 256 --height 256 --steps 4)
first="$("${cli[@]}" "${args[@]}" --json)"
second="$("${cli[@]}" "${args[@]}" --json)"
python3 - "$first" "$second" <<'PY' || fail "the CLI's JSON output did not hold up (see above)"
import hashlib, json, os, sys

a, b = json.loads(sys.argv[1]), json.loads(sys.argv[2])
assert a.get("ok") is True, a
assert a.get("seed") == 1 and a.get("seed_source") == "explicit", a
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
else
  echo "== no artifact on this host (or --quick): skipping the generation assertions"
fi

echo "== a request the daemon refuses does not take the service down"
"${cli[@]}" generate --prompt x --width 1000 --height 512 >/dev/null 2>&1 || true
"${cli[@]}" status >/dev/null || fail "the service stopped answering after a refused request"
ok "still answering"

echo "== arguments with the wrong JSON type are refused, not silently defaulted"
# Measured before this check existed: `"width":"512"` rendered 1024x1024,
# `"steps":"4"` ran 50 steps and `"seed":"126"` produced a *random* seed — a caller
# comparing two runs would never learn that its settings had been dropped.
probe() { python3 "$REPO_DIR/Tests/socket_probe.py" "$IMAGEHIVE_SOCKET" "$1"; }
# `status` indents the key=value block, so match the field anywhere in the line.
loads() { "${cli[@]}" status | grep -o 'loads_total=[0-9]*' | cut -d= -f2; }
loads_before="$(loads)"
for bad in '{"cmd":"generate","prompt":"x","width":"512"}' \
           '{"cmd":"generate","prompt":"x","steps":"4"}' \
           '{"cmd":"generate","prompt":"x","seed":"126"}' \
           '{"cmd":"generate","prompt":"x","seed":true}' \
           '{"cmd":"generate","prompt":"x","tier":3}' \
           '{"cmd":"edit","prompt":"x","images":"a.png"}'; do
  reply="$(probe "$bad")"
  case "$reply" in
    *'"ok": false'*|*'"ok":false'*) ;;
    *) fail "a wrongly typed argument was accepted: $bad -> $reply" ;;
  esac
  case "$reply" in
    *"must be a number"*|*"must be a string"*|*"must be an array"*|*"is not a tier"*) ;;
    *) fail "the refusal does not say what was wrong: $bad -> $reply" ;;
  esac
done
loads_after="$(loads)"
[ "$loads_before" = "$loads_after" ] || fail "a refused argument still loaded the model"
ok "six bad requests refused, and the model stayed unloaded (loads_total=$loads_before)"

echo "== a bare newline gets an answer instead of silence"
empty_reply="$(probe '')"
case "$empty_reply" in *"empty request"*) ok "$empty_reply" ;;
  *) fail "an empty line got no usable reply: $empty_reply" ;;
esac

echo "== a mistyped image path is an error, not an answer about nothing"
missing_reply="$(probe '{"cmd":"vqa","prompt":"what is this","images":["/nope.png"]}')"
case "$missing_reply" in *"no such image"*) ok "$missing_reply" ;;
  *) fail "a missing image did not produce a clear error: $missing_reply" ;;
esac

echo "== a request with no trailing newline is logged, not silently dropped"
python3 "$REPO_DIR/Tests/socket_probe.py" --partial "$IMAGEHIVE_SOCKET" '{"cmd":"status"}' >/dev/null
for _ in $(seq 1 20); do
  grep -q "no trailing newline" "$work/daemon.log" 2>/dev/null && break
  sleep 0.25
done
grep -q "no trailing newline" "$work/daemon.log" \
  || fail "a client that forgot the newline left no trace in the log"
ok "diagnosed in the daemon log"

echo "== status names the process and the build that answered"
serving="$("${cli[@]}" status)"
for field in "pid=" "project_version=" "protocol="; do
  case "$serving" in
    *"$field"*) ;;
    *) fail "status does not report $field — which build is answering is not visible: $serving" ;;
  esac
done
ok "$(printf '%s\n' "$serving" | grep -E '(pid|project_version|protocol)=' | tr '\n' ' ')"

echo "== stop ends a daemon that launchd never started"
# The daemon in this test was started by hand, which is exactly how the normal
# install runs it (an MCP front end forks it) — and why a plain `bootout` +
# `bootstrap` used to leave the old binary serving the socket after an upgrade.
"${cli[@]}" stop >/dev/null 2>&1 || fail "stop exited non-zero"
for _ in $(seq 1 40); do
  kill -0 "$daemon_pid" 2>/dev/null || break
  sleep 0.25
done
kill -0 "$daemon_pid" 2>/dev/null && fail "stop left the daemon running (pid $daemon_pid)"
# Reap it here too: an unwatched background job makes bash print its own
# "Terminated: 15" line into the middle of the test output.
wait "$daemon_pid" 2>/dev/null || true
daemon_pid=""
# Ask the library the CLI itself uses, so the assertion is about the same
# definition of "still owned" that `stop` reaps by.
socket_owners() {
  bash -c '. "$1/cli/lib/common.sh"; ih_socket_owner_pids' _ "$REPO_DIR" 2>/dev/null || true
}
for _ in $(seq 1 20); do
  [ -z "$(socket_owners)" ] && break
  sleep 0.25
done
[ -z "$(socket_owners)" ] || fail "the socket is still owned after stop: $(socket_owners) (pid $daemon_pid)"
# The daemon unlinks its socket on SIGTERM. Without that, the file outlives the
# process and every "is it up?" check that looks at the file alone says yes.
[ -S "$IMAGEHIVE_SOCKET" ] && fail "the stopped daemon left $IMAGEHIVE_SOCKET behind"
ok "the socket was handed back and removed"

if [ "$have_model" = "1" ]; then echo "PASS (cli)"; else echo "PASS (cli, protocol only)"; fi
