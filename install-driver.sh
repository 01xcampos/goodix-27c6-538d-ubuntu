#!/usr/bin/env bash
# Build and install the community goodixtls 53xd driver for the Goodix
# 27c6:538d fingerprint reader, side by side with the distro's libfprint.
#
#   sudo ./install-driver.sh              build + install
#   sudo ./install-driver.sh --uninstall  remove everything this script added
#
# Nothing from the distro is overwritten: the library lives in its own
# directory and a loader entry puts that directory first.
set -euo pipefail

FORK_URL="https://github.com/infinytum/libfprint.git"
FORK_BRANCH="driver/538d"
WORKDIR="${WORKDIR:-/var/tmp/goodix-53xd-build}"

LIBDIR=/usr/lib/x86_64-linux-gnu/libfprint-goodix-53xd
CONF=/etc/ld.so.conf.d/00-goodix-53xd.conf
RULE=/etc/udev/rules.d/99-goodix-538d.rules

VID=27c6
PID=538d

info() { printf '\n== %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run with sudo: sudo $0 ${1:-}"

if [ "${1:-}" = "--uninstall" ]; then
  info "removing the 53xd driver"
  rm -f "$CONF" "$RULE"
  rm -rf "$LIBDIR"
  ldconfig
  udevadm control --reload-rules || true
  systemctl try-restart fprintd || true
  echo "Done. fprintd uses the distro libfprint again."
  exit 0
fi

info "checking for the sensor (${VID}:${PID})"
if ! lsusb -d "${VID}:${PID}" >/dev/null 2>&1; then
  echo "No ${VID}:${PID} on the bus. Detected Goodix devices:"
  lsusb -d "${VID}:" || true
  die "this script only handles ${VID}:${PID}; a different PID needs a different driver"
fi

info "installing build dependencies"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  git meson ninja-build pkg-config gcc \
  libglib2.0-dev libusb-1.0-0-dev libpixman-1-dev libnss3-dev libgudev-1.0-dev \
  >/dev/null

info "fetching the driver source (${FORK_BRANCH})"
rm -rf "$WORKDIR"
git clone --depth 1 -b "$FORK_BRANCH" "$FORK_URL" "$WORKDIR/src"

info "building"
meson setup "$WORKDIR/build" "$WORKDIR/src" --prefix=/usr >/dev/null
ninja -C "$WORKDIR/build" >/dev/null
SO="$WORKDIR/build/libfprint/libfprint-2.so.2.0.0"
[ -f "$SO" ] || die "build produced no library at $SO"

info "verifying the artifact carries ${PID}"
"$WORKDIR/build/libfprint/fprint-list-supported-devices" | grep -qi "${VID}:${PID}" \
  || die "the built library does not list ${VID}:${PID}"
objdump -p "$SO" | grep -q 'SONAME.*libfprint-2\.so\.2' || die "unexpected soname in $SO"

info "installing into $LIBDIR"
install -d -m 755 "$LIBDIR"
install -m 644 "$SO" "$LIBDIR/libfprint-2.so.2.0.0"
ln -sfn libfprint-2.so.2.0.0 "$LIBDIR/libfprint-2.so.2"
ln -sfn libfprint-2.so.2 "$LIBDIR/libfprint-2.so"

# 00- sorts before x86_64-linux-gnu.conf, so this directory is searched first.
echo "$LIBDIR" > "$CONF"

cat > "$RULE" <<'EOF'
# Goodix 27c6:538d (TLS, goodixtls 53xd driver): let the daemon and the desktop
# session reach the sensor without root.
SUBSYSTEM=="usb", ATTRS{idVendor}=="27c6", ATTRS{idProduct}=="538d", ATTR{power/control}="auto", MODE="0660", GROUP="plugdev", TAG+="uaccess"
EOF

ldconfig
udevadm control --reload-rules || true
udevadm trigger --subsystem-match=usb --attr-match=idVendor="${VID}" || true
systemctl restart fprintd || true
sleep 1

info "verification"
echo "-- library fprintd loads --"
ldd /usr/libexec/fprintd 2>/dev/null | grep -i libfprint || echo "(could not read fprintd's links)"
echo
echo "-- devices libfprint offers --"
fprintd-list "${SUDO_USER:-$USER}" || true

cat <<'NEXT'

The sensor should now be listed as "Goodix TLS Fingerprint Sensor 53XD".
If it is listed but enrolment fails with "Invalid device PSK" or
"MCU has no config", run the one-time initialisation:

    sudo ./init-sensor.sh
NEXT
