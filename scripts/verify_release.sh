#!/usr/bin/env bash
# Install a release tarball the way a user would, and check the result.
#
#   ./scripts/verify_release.sh dist/sensenova-u1-<version>-macos-arm64.tar.gz
#   make release-verify
#
# Everything happens inside a private HOME: the archive is verified against its
# .sha256, extracted, its files are put under quarantine the way a browser
# download would leave them, and then install.sh runs with --skip-build (no Xcode,
# no Swift toolchain — that is the whole point of shipping prebuilt binaries).
# The sandbox service is asked for status; its launchd job is removed again and
# the private HOME is trashed, so the machine's own installation is never touched.
#
# Expected: doctor reports "no model artifact installed" with status 1, because a
# sandbox has no 11–33 GiB of weights. That is a pass here, not a failure.
#
# SENSENOVA_VERIFY_SKIP_SERVICE=1 stops after the install, for a headless box
# (a CI runner) where there is no GUI launchd domain to bootstrap into.

set -euo pipefail

tarball="${1:-}"
[ -n "$tarball" ] || { echo "usage: $0 <tarball>" >&2; exit 2; }
[ -f "$tarball" ] || { echo "no such tarball: $tarball" >&2; exit 2; }
tarball="$(cd "$(dirname "$tarball")" && pwd)/$(basename "$tarball")"

label="${SENSENOVA_VERIFY_LABEL:-local.sensenova-u1-verify}"
# A short sandbox root on purpose: AF_UNIX socket paths are limited to 103 bytes,
# and $TMPDIR on macOS is `/var/folders/...`, long enough to blow that budget once
# a home directory is appended. A real home is short, so the sandbox mimics one.
work="$(mktemp -d /tmp/snv-verify.XXXXXX)"
sandbox_home="$work/home"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok()   { printf '   %s\n' "$*"; }

cleanup() {
  # Kill the sandbox daemon by the pid launchd knows about, before booting the job
  # out; the pattern fallback is only there for a daemon a front end spawned.
  local daemon_pid
  daemon_pid="$(launchctl print "gui/$(id -u)/$label" 2>/dev/null | awk -F'= ' '/^[[:space:]]*pid = /{print $2; exit}')"
  launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true
  [ -n "${daemon_pid:-}" ] && kill "$daemon_pid" 2>/dev/null || true
  pkill -f "$work" >/dev/null 2>&1 || true
  if ! /usr/bin/trash "$work" >/dev/null 2>&1; then
    echo "note: could not trash the sandbox; it is still at $work" >&2
  fi
}
trap cleanup EXIT

echo "== 1. the archive matches its checksum"
[ -f "$tarball.sha256" ] || fail "missing $tarball.sha256"
( cd "$(dirname "$tarball")" && shasum -a 256 -c "$(basename "$tarball").sha256" >/dev/null ) \
  || fail "archive does not match its .sha256"
tar -xzf "$tarball" -C "$work"
src="$(find "$work" -maxdepth 1 -type d -name 'sensenova-u1-*' | head -1)"
[ -n "$src" ] || fail "the archive has no top-level directory"
( cd "$src" && shasum -a 256 -c SHA256SUMS >/dev/null ) || fail "SHA256SUMS does not match"
ok "$(basename "$tarball") verified"

echo "== 2. the archive is self-contained"
for need in install.sh uninstall.sh README.md README.zh-CN.md LICENSE NOTICE CHANGELOG.md \
            prebuilt/sensenova-served prebuilt/sensenova-mcp \
            cli/sensenova-u1 cli/lib/common.sh cli/lib/models.sh cli/lib/clients.sh \
            Docs/MODELS.md Docs/LAYOUT.md Docs/CLIENTS.md Docs/DISTRIBUTING.md \
            Docs/DISTRIBUTING.zh-CN.md Docs/TROUBLESHOOTING.md BUILD-INFO.txt; do
  [ -e "$src/$need" ] || fail "missing from the archive: $need"
done
ls "$src"/prebuilt/*.bundle >/dev/null 2>&1 || fail "no MLX resource bundles (the daemon would die on the first image)"
ok "everything install.sh reads is present"

echo "== 3. quarantine the copy, as a download would leave it"
xattr -wr com.apple.quarantine "0081;00000000;Safari;" "$src"
xattr -p com.apple.quarantine "$src/prebuilt/sensenova-served" >/dev/null 2>&1 \
  || fail "could not set the quarantine flag (the test would prove nothing)"
ok "prebuilt/sensenova-served is quarantined"

echo "== 4. install it, with no Xcode and no Swift toolchain"
mkdir -p "$sandbox_home"
( cd "$src" && HOME="$sandbox_home" bash ./install.sh \
    --skip-build --model none --clients none --label "$label" --yes ) \
  || fail "install.sh failed"
for target in "$sandbox_home/.local/share/sensenova-u1/bin/sensenova-served" \
              "$sandbox_home/.local/share/sensenova-u1/bin/sensenova-mcp" \
              "$sandbox_home/.local/share/sensenova-u1/sensenova-u1" \
              "$sandbox_home/.local/bin/sensenova-u1"; do
  [ -e "$target" ] || fail "not installed: $target"
  xattr -p com.apple.quarantine "$target" >/dev/null 2>&1 \
    && fail "still quarantined after install (it would hang on first run): $target"
done
ok "binaries, bundles and the command are in place and unquarantined"

if [ "${SENSENOVA_VERIFY_SKIP_SERVICE:-0}" = "1" ]; then
  echo "== 5. skipping the service checks (SENSENOVA_VERIFY_SKIP_SERVICE=1)"
  echo
  echo "PASS: the release installs without a toolchain"
  exit 0
fi

echo "== 5. the sandbox service answers"
export HOME="$sandbox_home"
status="$( "$sandbox_home/.local/bin/sensenova-u1" status 2>&1 )" || fail "status failed:
$status"
case "$status" in *available_tiers=*) ok "$(printf '%s\n' "$status" | awk -F= '/available_tiers/{print "available_tiers="$2}')" ;;
  *) fail "status did not report available_tiers:
$status" ;;
esac

echo "== 6. doctor sees the real state of a model-less sandbox"
doctor_rc=0
doctor="$( "$sandbox_home/.local/bin/sensenova-u1" doctor 2>&1 )" || doctor_rc=$?
case "$doctor" in *"no model artifact installed"*) ok "doctor: no model artifact installed (exit $doctor_rc, expected)" ;;
  *) fail "doctor did not report the missing artifact:
$doctor" ;;
esac

echo "== 7. a socket path that does not fit says so instead of failing silently"
long_socket="$work/$(printf 'x%.0s' $(seq 1 90))/served.sock"   # 104+ bytes
long_log="$work/long-path.log"
SENSENOVA_HOME="$sandbox_home" SENSENOVA_SOCKET="$long_socket" \
  "$sandbox_home/.local/share/sensenova-u1/bin/sensenova-served" >/dev/null 2>"$long_log" || true
case "$(cat "$long_log")" in
  *"socket path is too long"*) ok "the daemon explains a too-long socket path" ;;
  *) fail "expected a 'socket path is too long' diagnostic, got:
$(cat "$long_log")" ;;
esac

echo
echo "PASS: the release installs and serves without a toolchain"
