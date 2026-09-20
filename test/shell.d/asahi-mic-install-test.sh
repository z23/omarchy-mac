#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
test_home="$test_tmp/home"
runtime="$test_tmp/runtime"
calls="$test_tmp/calls"
mic_script="$test_tmp/mic.sh"
mkdir -p "$stub_bin" "$test_home" "$runtime"
: >"$calls"

cat >"$stub_bin/omarchy-hw-apple" <<'SH'
#!/bin/bash
exit 0
SH

cat >"$stub_bin/omarchy-audio-asahi-mic-map" <<'SH'
#!/bin/bash
exit 0
SH

cat >"$stub_bin/systemctl" <<'SH'
#!/bin/bash
printf 'systemctl %s\n' "$*" >>"$CALLS"
if [[ $1 == --user && -z ${XDG_RUNTIME_DIR:-} ]]; then
  echo "Failed to connect to user scope bus via local transport: \$DBUS_SESSION_BUS_ADDRESS and \$XDG_RUNTIME_DIR not defined" >&2
  exit 1
fi
exit 0
SH

chmod +x "$stub_bin"/*

# Redirect the legacy fallback into the fixture so this also catches regressions
# on headless machines without a real /run/user/$UID/bus.
sed 's|/run/user/\$UID|'"$runtime"'|g' \
  "$ROOT/install/user/hardware/apple/mic.sh" >"$mic_script"
python3 - "$runtime/bus" <<'PYTHON'
import socket, sys
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.bind(sys.argv[1])
PYTHON

run_mic() {
  : >"$calls"
  HOME="$test_home" OMARCHY_PATH="$ROOT" CALLS="$calls" PATH="$stub_bin:$PATH" \
    bash -eE -c 'source "$1"' bash "$mic_script"
}

# The guided --resume path: owner is logged in on tty1, sudo -i cleared
# XDG_RUNTIME_DIR, but /run/user/$UID/bus exists. Skip the user-bus call.
unset XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS
run_mic
if grep -q '^systemctl' "$calls"; then
  fail "mic setup does not call systemctl --user without XDG_RUNTIME_DIR" "$(cat "$calls")"
fi
mic_wants="$test_home/.config/systemd/user/graphical-session.target.wants/omarchy-asahi-mic.service"
[[ -L $mic_wants && $(readlink "$mic_wants") == "../omarchy-asahi-mic.service" ]] ||
  fail "mic setup keeps the service enabled for the next graphical session"
pass "mic setup defers the enabled user unit when XDG_RUNTIME_DIR is unset"

XDG_RUNTIME_DIR="$runtime" run_mic
grep -Fx 'systemctl --user daemon-reload' "$calls" >/dev/null ||
  fail "mic setup reloads the user manager when the session bus is reachable"
grep -Fx 'systemctl --user start omarchy-asahi-mic.service' "$calls" >/dev/null ||
  fail "mic setup starts the mapper when the session bus is reachable"
pass "mic setup starts the mapper when XDG_RUNTIME_DIR points at the session bus"

XDG_RUNTIME_DIR="$test_tmp/missing-runtime" run_mic
if grep -q '^systemctl' "$calls"; then
  fail "mic setup does not call systemctl --user without a bus socket" "$(cat "$calls")"
fi
pass "mic setup skips systemctl when XDG_RUNTIME_DIR has no bus"
