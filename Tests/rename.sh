#!/usr/bin/env bash
# The 0.6 rename, from the point of view of a machine that ran the old name.
#
#   Tests/rename.sh     # no model, no build, nothing outside a scratch HOME
#
# The claim being tested is not "the strings changed" but that an install of
# `sensenova-u1` ends up as exactly *one* working service afterwards: the old daemon
# is reaped, the 11–66 GB of artifacts are moved rather than downloaded again, the
# old command and the old client entries can no longer start anything of their own,
# and `doctor` reports whatever is left. install.sh runs from a copy inside the
# scratch HOME with `--skip-build` (prebuilt/ symlinked at this checkout's build
# products), so nothing here builds or installs into the real home.
#
# Two things deliberately reach outside the scratch HOME, because they are
# properties of the machine and not of a HOME: the LaunchAgent is bootstrapped into
# the real GUI domain — with a label unique to this test, booted out again on the
# way out — and process lookups see every process. Both have caused real damage
# during development; see "已经让人重装过一次的坑" in AGENTS.md.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

work="$(mktemp -d /tmp/ih-rename.XXXXXX)"
home="$work/home"
src="$work/src"
OLD_SHARE="$home/.local/share/sensenova-u1"
OLD_CLI="$home/.local/bin/sensenova-u1"
# The old label is a custom one, which is what a `--label` install looks like: the
# rename has to carry its prefix over (`<prefix>.sensenova-u1` -> `<prefix>.imagehive`)
# and the test must not collide with any job the machine already has.
OLD_LABEL="local.ih-rename-test.sensenova-u1"
NEW_LABEL="local.ih-rename-test.imagehive"
scoped_pid=""
foreign_pid=""
cleanup() {
  local label
  for label in "$OLD_LABEL" "$NEW_LABEL"; do
    launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true
  done
  for pid in "$scoped_pid" "$foreign_pid"; do
    if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; fi
  done
  # Anything else this test started, matched on its scratch path.
  for pid in $(pgrep -f "$work" 2>/dev/null || true); do kill "$pid" 2>/dev/null || true; done
  /usr/bin/trash "$work" >/dev/null 2>&1 || true
}
trap cleanup EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok()   { printf '   %s\n' "$*"; }

[ -x "$REPO_DIR/.build/release/imagehived" ] \
  || fail "imagehived not found — run: swift build -c release"

# install.sh, the command and the libraries, as a release archive carries them.
mkdir -p "$src/prebuilt" "$home"
cp "$REPO_DIR/install.sh" "$REPO_DIR/uninstall.sh" "$src/"
cp -R "$REPO_DIR/cli" "$src/cli"
ln -sf "$REPO_DIR/.build/release/imagehived" "$src/prebuilt/imagehived"
ln -sf "$REPO_DIR/.build/release/imagehive-mcp" "$src/prebuilt/imagehive-mcp"
for bundle in "$REPO_DIR/.build/release"/*.bundle; do
  [ -e "$bundle" ] || continue
  ln -sf "$bundle" "$src/prebuilt/$(basename "$bundle")"
done

# ---------------------------------------------------------------- the fake past

old_home="$home/Library/Application Support/SenseNovaU1"
new_home="$home/Library/Application Support/ImageHive"
mkdir -p "$old_home/models/SenseNova-U1.5-8B-MoT-bf16" "$home/Pictures/SenseNovaU1" \
         "$home/Library/Logs/SenseNovaU1" "$OLD_SHARE/bin" "$OLD_SHARE/lib" \
         "$home/.local/bin" "$home/Library/LaunchAgents"
printf '{"ttl_seconds": 4242, "quality_artifact": "SenseNova-U1.5-8B-MoT-bf16"}\n' > "$old_home/config.json"
printf "SENSENOVA_VERSION='0.5.2'\nSENSENOVA_HOME='%s'\nSENSENOVA_LABEL='%s'\n" \
  "$old_home" "$OLD_LABEL" > "$old_home/service.conf"
printf 'weights\n' > "$old_home/models/SenseNova-U1.5-8B-MoT-bf16/config.json"
printf 'old image\n' > "$home/Pictures/SenseNovaU1/old.png"
printf 'old log\n' > "$home/Library/Logs/SenseNovaU1/served.log"
printf '#!/bin/sh\necho old cli\nexit 9\n' > "$OLD_SHARE/sensenova-u1"
printf 'lib\n' > "$OLD_SHARE/lib/common.sh"
ln -sf "$OLD_SHARE/sensenova-u1" "$OLD_CLI"
job_plist() { # <path> <label> <binary>
  printf '<?xml version="1.0"?>\n<plist version="1.0"><dict>\n<key>Label</key><string>%s</string>\n<key>ProgramArguments</key><array><string>%s</string></array>\n</dict></plist>\n' \
    "$2" "$3" > "$1"
}
job_plist "$home/Library/LaunchAgents/$OLD_LABEL.plist" "$OLD_LABEL" "$OLD_SHARE/bin/sensenova-served"
job_plist "$home/Library/LaunchAgents/local.sensenova-u1.plist" local.sensenova-u1 "$OLD_SHARE/bin/sensenova-served"

# A daemon of *this* layout — the one an upgrade has to reap, because it holds a
# second copy of the weights and its socket file would move with the app home.
cp "$REPO_DIR/.build/release/imagehived" "$OLD_SHARE/bin/sensenova-served"
IMAGEHIVE_HOME="$old_home" IMAGEHIVE_SOCKET="$old_home/served.sock" \
  "$OLD_SHARE/bin/sensenova-served" >"$work/scoped.log" 2>&1 &
scoped_pid=$!
# And one from a layout this installer is *not* upgrading: same name, other prefix.
foreign_share="$work/foreign/share/sensenova-u1/bin"
mkdir -p "$work/foreign/share/sensenova-u1/bin"
cp "$REPO_DIR/.build/release/imagehived" "$foreign_share/sensenova-served"
IMAGEHIVE_HOME="$work/foreign/home" IMAGEHIVE_SOCKET="$work/foreign/home/served.sock" \
  "$foreign_share/sensenova-served" >"$work/foreign.log" 2>&1 &
foreign_pid=$!
sleep 2
[ -S "$old_home/served.sock" ] || fail "the fake old daemon did not bind its socket"
[ -S "$work/foreign/home/served.sock" ] || fail "the fake foreign daemon did not bind its socket"

run_installer() { # <args...>
  ( cd "$src" && HOME="$home" bash ./install.sh --skip-build --model none --clients none "$@" ) \
    >>"$work/install.log" 2>&1
}

# ------------------------------------------------------------- the dry run first

echo "== a dry run must not touch anything"
: >"$work/install.log"
run_installer --dry-run || fail "install.sh --dry-run failed"
kill -0 "$scoped_pid" 2>/dev/null || fail "the dry run stopped the old daemon"
[ -d "$old_home" ] || fail "the dry run moved the old app home"
[ -L "$OLD_CLI" ] || fail "the dry run replaced the old command"
[ -f "$home/Library/LaunchAgents/$OLD_LABEL.plist" ] || fail "the dry run removed the old job"
# …and it says so in the past tense nowhere: a "removed the old launchd job" line
# beside a "would run: rm -f …" line reads as if the job were already gone.
grep -q 'would run: rm -f .*'"$OLD_LABEL"'.plist' "$work/install.log" \
  || fail "the dry run did not print the job removal as a plan"
if grep -q 'removed the old launchd job' "$work/install.log"; then
  fail "the dry run claims the old job was removed"
fi
ok "dry run: no state changed, and nothing is reported as already done"

# ------------------------------------------------------------------- the upgrade

echo "== install.sh over an install of the old name"
run_installer --yes || fail "install.sh failed (see $work/install.log)"

kill -0 "$scoped_pid" 2>/dev/null && fail "the old daemon survived the upgrade" || ok "the old daemon was reaped"
kill -0 "$foreign_pid" 2>/dev/null && ok "a daemon from another layout was left alone" \
  || fail "the installer killed a daemon that belongs to another layout"
grep -q "another layout is still running" "$work/install.log" && ok "and it was reported, not silently ignored" \
  || fail "a foreign old daemon was not reported"

[ -d "$new_home" ] || fail "the app home was not moved to $new_home"
[ -f "$new_home/models/SenseNova-U1.5-8B-MoT-bf16/config.json" ] || fail "the artifact tree did not come along"
[ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["ttl_seconds"])' "$new_home/config.json")" = "4242" ] \
  || fail "config.json content changed"
ok "app home moved (artifacts, config, socket file name all included)"
[ -f "$home/Pictures/ImageHive/old.png" ] || fail "the old images did not move"
[ -f "$home/Library/Logs/ImageHive/imagehived.log" ] || fail "the log did not move and get renamed"
ok "images and log moved to the new names"
if [ -e "$new_home/served.sock" ]; then fail "the old socket file travelled into the new home"; fi
ok "the old socket file did not travel"

if [ -f "$home/Library/LaunchAgents/$OLD_LABEL.plist" ]; then fail "the old job file is still there"; fi
if [ -f "$home/Library/LaunchAgents/local.sensenova-u1.plist" ]; then fail "the default-label old job is still there"; fi
ok "the old job files were removed"
[ -f "$home/Library/LaunchAgents/$NEW_LABEL.plist" ] || fail "the custom label was not renamed to $NEW_LABEL"
grep -q "IMAGEHIVE_LABEL='$NEW_LABEL'" "$new_home/service.conf" \
  || fail "service.conf does not carry the renamed label"
ok "the job label was renamed, keeping its prefix ($OLD_LABEL -> $NEW_LABEL)"

grep -q IMAGEHIVE_HOME "$OLD_SHARE/bin/sensenova-served" || fail "no wrapper at the old daemon path"
grep -q IMAGEHIVE_DAEMON_BIN "$OLD_SHARE/bin/sensenova-mcp" || fail "no wrapper at the old front-end path"
ok "the old binary paths forward to the new ones"
if [ -e "$OLD_SHARE/sensenova-u1" ]; then fail "the pre-0.6 command script is still installed"; fi
if [ -e "$OLD_SHARE/lib" ]; then fail "the pre-0.6 libraries are still installed"; fi
grep -q 'is now imagehive' "$OLD_CLI" || fail "the old command name is not a shim onto the new one"
printf '   the old name still works: %s\n' "$("$OLD_CLI" --version 2>&1 | tail -1)"
ok "the old command name forwards to imagehive, and the script behind it is gone"

echo "== doctor"
# HOME has to be set here too: doctor reports the pre-0.6 leftovers of *its* HOME,
# and without this it inspects the machine's real one — which on a machine that
# still runs the old name is a forest of findings.
doctor="$(env HOME="$home" "$home/.local/bin/imagehive" doctor 2>&1 || true)"
if printf '%s\n' "$doctor" | grep -q 'pre-0.6 app home'; then fail "doctor still sees the old app home"; fi
if printf '%s\n' "$doctor" | grep -q 'pre-0.6 launchd job'; then fail "doctor still sees the old job"; fi
if printf '%s\n' "$doctor" | grep -q 'pre-0.6 entry'; then fail "doctor still sees an old client entry"; fi
if printf '%s\n' "$doctor" | grep -q 'pre-0.6 daemon still running'; then
  ok "doctor reports the daemon from the other layout (it is still running on purpose)"
else
  fail "doctor did not report the pre-0.6 daemon from the other layout"
fi
ok "doctor reports no leftovers of the layout that was upgraded"

# --------------------------------------------------------- client entries, both names

echo "== client entries"
mkdir -p "$home/.cursor" "$home/.config/opencode"
printf '{\n  "mcpServers": {\n    "sensenova": {"command": "/old/imagehive-mcp"},\n    "unrelated": {"command": "/x"}\n  }\n}\n' \
  > "$home/.cursor/mcp.json"
printf '{\n  "mcp": {\n    // sensenova-u1:begin (managed by `sensenova-u1 clients`)\n    "sensenova": {\n      "type": "local",\n      "command": ["/old/imagehive-mcp"]\n    },\n    // sensenova-u1:end\n    "unrelated": {\n      "type": "local",\n      "command": ["/x"]\n    }\n  }\n}\n' \
  > "$home/.config/opencode/opencode.jsonc"
cli=(env HOME="$home" bash "$src/cli/imagehive")
"${cli[@]}" clients add cursor >/dev/null 2>&1 || fail "clients add cursor failed"
grep -q '"imagehive"' "$home/.cursor/mcp.json" || fail "cursor was not wired under the new name"
if grep -q '"sensenova"' "$home/.cursor/mcp.json"; then fail "cursor still has the old entry"; fi
grep -q '"unrelated"' "$home/.cursor/mcp.json" || fail "an unrelated cursor entry was dropped"
ok "wiring a client also drops its old entry (cursor)"
"${cli[@]}" clients add opencode >/dev/null 2>&1 || fail "clients add opencode failed"
if grep -q 'sensenova-u1:begin' "$home/.config/opencode/opencode.jsonc"; then fail "opencode still has the old marked block"; fi
grep -q 'imagehive:begin' "$home/.config/opencode/opencode.jsonc" || fail "opencode got no new block"
grep -q '"unrelated"' "$home/.config/opencode/opencode.jsonc" || fail "an unrelated opencode entry was dropped"
# Both markers, not just the opening one: an earlier version stopped skipping at
# the end marker and then kept that line, so a wiring left one more
# `// …:end` behind than it removed and the file grew on every run.
if grep -q 'sensenova-u1:end' "$home/.config/opencode/opencode.jsonc"; then fail "opencode still has the old end marker"; fi
markers() { grep -c "$1" "$home/.config/opencode/opencode.jsonc" || true; }
if [ "$(markers 'imagehive:end')" != "1" ] || [ "$(markers 'imagehive:begin')" != "1" ]; then
  fail "opencode has $(markers 'imagehive:begin') begin / $(markers 'imagehive:end') end markers, expected one of each"
fi
"${cli[@]}" clients add opencode >/dev/null 2>&1 || fail "the second clients add opencode failed"
if [ "$(markers 'imagehive:end')" != "1" ]; then
  fail "wiring opencode twice left $(markers 'imagehive:end') end markers behind"
fi
ok "opencode: the old marked block is replaced, not left beside the new one (and wiring twice adds nothing)"

# The config being edited belongs to the user's editor and it is the only copy of those
# settings, so a wiring run has to replace it whole: a truncate-and-rewrite leaves a
# half-written file behind if the process dies in between (measured 2026-09-19 — this was
# the last place in the project still writing user data in place).
inode_before="$(stat -f '%i' "$home/.config/opencode/opencode.jsonc")"
"${cli[@]}" clients add opencode >/dev/null 2>&1 || fail "the third clients add opencode failed"
inode_after="$(stat -f '%i' "$home/.config/opencode/opencode.jsonc")"
[ "$inode_before" != "$inode_after" ] \
  || fail "the config was rewritten in place; a crash mid-write would truncate it"
leftovers="$(find "$home/.config/opencode" "$home/.cursor" -name '.imagehive-*' | wc -l | tr -d ' ')"
[ "$leftovers" = "0" ] || fail "the wiring left $leftovers scratch files behind"
# And a write that cannot finish must leave the original byte-identical.
python3 - "$src" "$home/.config/opencode/opencode.jsonc" <<'PY' || fail "a failed config write damaged the file"
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "cli", "lib"))
from atomic_write import write_text

path = sys.argv[2]
directory = os.path.dirname(path)
before = open(path).read()
os.chmod(directory, 0o500)      # a temporary file can no longer be created here
try:
    write_text(path, "half a file")
except OSError:
    pass
else:
    sys.exit("a write into a directory that cannot take a temporary file was accepted")
finally:
    os.chmod(directory, 0o700)
after = open(path).read()
assert after == before, "the config changed even though the write could not finish"
assert not [n for n in os.listdir(directory) if n.startswith(".imagehive-")], "a scratch file survived"
print("   client configs are replaced whole: a write that cannot finish changes nothing")
PY

# ---------------------------------------------------------------------- uninstall

echo "== uninstall.sh, on top of all that"
( cd "$src" && HOME="$home" bash ./uninstall.sh --yes ) >>"$work/uninstall.log" 2>&1 \
  || fail "uninstall.sh failed (see $work/uninstall.log)"
if [ -d "$OLD_SHARE" ]; then fail "uninstall left the pre-0.6 command tree"; fi
if [ -e "$OLD_CLI" ]; then fail "uninstall left the pre-0.6 command name"; fi
if [ -f "$home/Library/LaunchAgents/$OLD_LABEL.plist" ]; then fail "uninstall left a pre-0.6 job"; fi
[ -d "$new_home" ] || fail "uninstall removed the app home (it holds the 33 GB of artifacts)"
[ -d "$home/Pictures/ImageHive" ] || fail "uninstall removed the images"
ok "uninstall removes the old names and keeps the artifacts and the images"

echo
echo "PASS (rename)"
