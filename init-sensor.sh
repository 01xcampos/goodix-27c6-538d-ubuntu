#!/usr/bin/env bash
# One-time initialisation of the Goodix 27c6:538d sensor.
#
#   sudo ./init-sensor.sh
#
# Why this exists: the driver can talk to the sensor, but the sensor itself has
# no MCU config and no valid PSK, so fprintd fails enrolment with
# "MCU has no config" / "Invalid device PSK". The community dump tool writes
# both. On this sensor its first command also fails with
# "ValueError: Invalid message protocol" unless fprintd is stopped and the
# device is reset over USB first — this script does that in the right order.
#
# Risks (read before running):
#   - the upstream tool says "we do not recommend using this, this is very
#     unstable";
#   - it can erase and rewrite the sensor firmware (small brick risk);
#   - it resets the pairing key, so Windows Hello has to re-pair on the next
#     Windows boot.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DUMP_REPO="https://github.com/goodix-fp-linux-dev/goodix-fp-dump.git"
DUMP_DIR="${DUMP_DIR:-/var/tmp/goodix-fp-dump}"
VID=27c6
PID=538d

info() { printf '\n== %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run with sudo: sudo $0"

find_node() {
  local dev
  for dev in /sys/bus/usb/devices/*; do
    [ -r "$dev/idVendor" ] || continue
    if [ "$(cat "$dev/idVendor")" = "$VID" ] && [ "$(cat "$dev/idProduct")" = "$PID" ]; then
      printf '/dev/bus/usb/%03d/%03d\n' "$(cat "$dev/busnum")" "$(cat "$dev/devnum")"
      return 0
    fi
  done
  return 1
}

NODE="$(find_node)" || die "no ${VID}:${PID} on the bus — is the driver installed and the device present?"

info "compiling usbreset"
if [ ! -x "$HERE/usbreset" ]; then
  gcc -O2 -o "$HERE/usbreset" "$HERE/usbreset.c"
fi

info "preparing the dump tool"
if [ ! -d "$DUMP_DIR" ]; then
  git clone --recurse-submodules "$DUMP_REPO" "$DUMP_DIR"
fi
# The tool's requirements include spidev, which protocol.py imports even for a
# USB sensor. It has no wheel and does not build on very new interpreters, so
# the venv must use the distro's Python (3.12 on Ubuntu 24.04).
if [ ! -x "$DUMP_DIR/.venv/bin/python3" ]; then
  /usr/bin/python3 -m venv "$DUMP_DIR/.venv"
  "$DUMP_DIR/.venv/bin/pip" -q install -r "$DUMP_DIR/requirements.txt"
fi

info "stopping fprintd for the run"
systemctl stop fprintd 2>/dev/null || true
trap 'systemctl start fprintd 2>/dev/null || true' EXIT

info "resetting the sensor at $NODE"
"$HERE/usbreset" "$NODE"
sleep 2
NODE="$(find_node)" && echo "sensor re-enumerated at $NODE"

cat <<'NEXT'

The tool will ask for a bot-check number, may flash the firmware, and then
waits for a finger. Press and hold until it tells you to lift.

NEXT

status=0
cd "$DUMP_DIR"
"$DUMP_DIR/.venv/bin/python3" run_538d.py || status=$?

cat <<NEXT

Tool exited with status ${status}.

Next steps, as your normal user (not root):

  fprintd-list \$USER
  fprintd-enroll -f right-index-finger
  fprintd-verify

Then enable it in Settings -> Users -> Fingerprint Login. Test a finger you did
NOT enrol: it must be refused.
NEXT
exit "$status"
