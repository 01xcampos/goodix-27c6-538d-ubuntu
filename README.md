# Goodix 27c6:538d fingerprint reader on Ubuntu (Dell Inspiron 5402)

Make the built-in fingerprint reader work on Linux — log in, unlock the screen,
and (optionally) authenticate `sudo`.

Tested end to end on:

| | |
|---|---|
| Laptop | Dell Inspiron 5402 |
| Sensor | Goodix `27c6:538d` (USB, vendor-specific class) |
| Distro | Ubuntu 24.04.5 LTS |
| Kernel | 7.0.0-38-generic |
| fprintd | 1.94.3 (libfprint 1.94.7) |

The same sensor appears in other Dell models (Inspiron 5409/7506, Latitude 3410,
Vostro 3500). The procedure is the same — but **check your USB ID first**, because
Goodix reuses the `27c6` vendor ID across many incompatible sensors.

---

## Why it does not work out of the box

Ubuntu ships two things that look like they should handle this reader:

- `libfprint`'s `goodixmoc` driver — speaks Match-on-Chip;
- the Dell/Somerville TOD driver `libfprint-2-tod1-goodix` — but its udev rules
  name only `538c`, `533c`, `530c` and `5840`. **`538d` is not in that list.**

The `538d` speaks a *TLS* protocol, so the daemon claims the device and gives up:

```
fprintd: Ignoring device due to initialization error:
         USB error on device 27c6:538d : Invalid parameter [-2]
$ fprintd-list "$USER"
No devices available
```

That is a userspace protocol mismatch, not a broken port or a missing kernel
module. The fix is the community `goodixtls53xd` driver, which lives in forks of
libfprint, plus a one-time initialisation of the sensor itself.

---

## Requirements

- Ubuntu/Debian with `apt` (the scripts install build dependencies).
- Internet access (the scripts clone two GitHub repositories).
- `sudo`.
- About 5 minutes, and a finger.

Confirm the sensor:

```bash
lsusb -d 27c6:
# Bus 003 Device 002: ID 27c6:538d Shenzhen Goodix Technology Co.,Ltd. FingerPrint
```

If the product ID is not `538d`, **stop** — a different PID needs a different
driver, and none of this applies.

---

## Quick start

```bash
git clone https://github.com/01xcampos/goodix-27c6-538d-ubuntu.git
cd goodix-27c6-538d-ubuntu

sudo ./install-driver.sh     # build the driver, install it side by side
sudo ./init-sensor.sh        # one-time sensor initialisation (see risks below)
```

Then, as your normal user:

```bash
fprintd-list "$USER"                       # should list the 53XD sensor
fprintd-enroll -f right-index-finger       # press and hold, lift, repeat
fprintd-verify                             # should print verify-match
```

Enable it in **Settings → Users → Fingerprint Login** if the toggle is off.

---

## What each step does

### 1. `install-driver.sh`

1. Refuses to run unless `27c6:538d` is on the bus.
2. Installs `meson`, `ninja`, `libglib2.0-dev`, `libusb-1.0-0-dev`,
   `libpixman-1-dev`, `libnss3-dev`, `libgudev-1.0-dev` and a compiler.
3. Clones [`infinytum/libfprint`](https://github.com/infinytum/libfprint),
   branch `driver/538d`, and builds it with meson/ninja.
4. Proves the artifact is the right one: its
   `fprint-list-supported-devices` must contain `27c6:538d`, and its SONAME must
   be `libfprint-2.so.2`.
5. Installs it **side by side**, without replacing any distro file:

   | Path | Purpose |
   |---|---|
   | `/usr/lib/x86_64-linux-gnu/libfprint-goodix-53xd/` | the library |
   | `/etc/ld.so.conf.d/00-goodix-53xd.conf` | makes the loader prefer it |
   | `/etc/udev/rules.d/99-goodix-538d.rules` | `plugdev` + `uaccess` for the sensor |

   The `00-` prefix matters: `ld.so.conf.d` entries are read in filename order
   and the first match wins. A `99-` entry would silently lose to the distro's
   own `x86_64-linux-gnu.conf`.
6. Reloads the loader and udev, restarts `fprintd`, then prints what `fprintd`
   actually loads and which devices libfprint offers.

Expected, the important line being the path:

```
$ ldd /usr/libexec/fprintd | grep libfprint
  libfprint-2.so.2 => /usr/lib/x86_64-linux-gnu/libfprint-goodix-53xd/libfprint-2.so.2

$ fprintd-list "$USER"
found 1 devices
Using device /net/reactivated/Fprint/Device/0
User you has no fingers enrolled for Goodix TLS Fingerprint Sensor 53XD.
```

> `fprintd-list` with no argument prints `Usage: fprintd-list <username>`. That
> is a missing argument, not a missing device.

### 2. `init-sensor.sh` — the one-time step

A listed sensor is not yet a working sensor. The first enrolment fails against
the device itself:

```
fprintd: MCU has no config
fprintd: failed during activation: Invalid device PSK: 0x… (code: 35)
fprintd: Device reported an error during identify for enroll: Invalid device PSK
```

The driver cannot fix that: the sensor needs its MCU config and pairing key
written once, with [`goodix-fp-dump`](https://github.com/goodix-fp-linux-dev/goodix-fp-dump).

On this sensor the dump tool also has a known first-command failure:

```
ValueError: Invalid message protocol
```

It is not a wrong build. The tool receives a stale frame because `fprintd` holds
the same device and the device was not reset. The maintainer's remedy
([issue #13](https://github.com/goodix-fp-linux-dev/goodix-fp-dump/issues/13),
confirmed by the reporter) is a **USB device reset with the daemon stopped** —
which is exactly what this script does, in this order:

1. finds the device node from sysfs (bus/device numbers move);
2. compiles and runs a ten-line `usbreset` (`USBDEVFS_RESET`);
3. stops `fprintd` for the duration, and restarts it on exit;
4. creates the tool's venv with the **distro** Python (3.12), because one of its
   dependencies, `spidev`, does not build on very new interpreters;
5. runs `run_538d.py`.

The tool asks for a bot-check number, may flash the firmware, and then waits for
a finger. Press and hold until it tells you to lift.

#### Risks — read this

- Upstream's own README says: *"we do not recommend using this for now. This is
  very unstable."*
- It may **erase and rewrite the sensor firmware**. Small, real brick risk.
- It **resets the pairing key**, so **Windows Hello has to re-pair** on the next
  Windows boot.
- It creates `clear-0.pgm` / `clear-1.pgm` in its directory; those are just
  calibration images and can be deleted.

If you use Windows on this laptop and cannot afford to re-pair Hello, stop
before this step and uninstall the driver (see below). The fingerprint will then
stay a Windows-only feature.

### 3. Enrol and verify

```bash
fprintd-enroll -f right-index-finger
```

The 53XD is a **press** sensor, not a swipe: place the finger flat, cover the
sensor, hold still, lift when prompted, and repeat from slightly different angles.
Enrolling the same finger **two or three times** improves the match rate:

```bash
fprintd-enroll -f right-index-finger    # again, adds another print
fprintd-list "$USER"
fprintd-delete "$USER" -f right-index-finger   # remove one finger
```

`fprintd-verify` prints `verify-match` or `verify-no-match` — use it to test
without going through a login prompt.

---

## Security notes (please read)

This is a community driver. Know what you are accepting:

- **The TLS pairing is effectively disabled** — the tool writes a public
  white-box PSK, so the link between host and sensor is not authenticated the
  way Windows Hello does it.
- **The matcher is more permissive than the vendor's.** This branch ships
  `bz3_threshold = 24`; other forks use 18, and one guide argues for 30. On this
  unit, with one print enrolled, a **non-enrolled finger was refused** at 24 —
  but you must run that test yourself before trusting the reader:

  ```bash
  # enrol one finger, then present a different finger to
  fprintd-verify
  # expected: verify-no-match
  ```

- **Fingerprint login here is convenience, not strong authentication.** Keep
  your password required for disk encryption, and do not use the fingerprint as
  the only factor for anything remote.

---

## Enable it for `sudo` (optional)

A stock Ubuntu 24.04 wires `pam_fprintd` only into `/etc/pam.d/gdm-fingerprint`,
so the greeter and lock screen can use the finger while `sudo` cannot. The
packaged profile is disabled by default:

```bash
sudo pam-auth-update --enable fprintd
```

Trade-off: every password prompt then waits for a finger first (it falls back to
the password after a failure or timeout). To undo:

```bash
sudo pam-auth-update --disable fprintd
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `No devices available` | `fprintd` is loading the distro library | `ldd /usr/libexec/fprintd \| grep libfprint` must show `libfprint-goodix-53xd`; re-run `sudo ./install-driver.sh` |
| `Ignoring device due to initialization error: … Invalid parameter [-2]` | stock drivers, wrong protocol | the driver is not installed/loaded |
| `MCU has no config` / `Invalid device PSK` on enrol | sensor never initialised | `sudo ./init-sensor.sh` |
| `ValueError: Invalid message protocol` from the dump tool | daemon holds the device, or it needs a reset | use `init-sensor.sh`, not `run_538d.py` directly |
| `Failed to detect minutiae: No minutiae found` | finger placement, one bad capture | centre the finger, cover the sensor; the print can still enrol |
| Sensor listed but not offered at login | PAM profile off | `sudo pam-auth-update --enable fprintd`, or the Settings toggle |
| Worked, then stopped after `apt upgrade` | a libfprint update changed loader precedence | check `ldd`; re-run `sudo ./install-driver.sh` |
| Works in Windows but not Linux (or vice versa) | pairing key changed | re-run `sudo ./init-sensor.sh`, then enrol again |

Logs:

```bash
journalctl -u fprintd -f        # live
journalctl -u fprintd -n 50     # recent
```

---

## Uninstall

```bash
sudo ./install-driver.sh --uninstall
```

Removes the library directory, the loader entry and the udev rule, then reloads
the loader and restarts `fprintd`. No distro file was ever replaced, so the
reader simply goes back to being unsupported. Enrolled prints stay under
`/var/lib/fprint/<user>/`; remove them with `fprintd-delete` if you want.

---

## How it works, in one paragraph

libfprint is a userspace library; `fprintd` is the daemon that talks to it over
D-Bus, and PAM/GDM ask the daemon. Putting a second, patched `libfprint` in its
own directory and putting that directory first in the loader search path means
`fprintd` picks it up without any distro package being touched. The patched copy
contains the `goodixtls53xd` driver, which speaks the TLS protocol this sensor
uses, and declares `{.vid = 0x27c6, .pid = 0x538d}`. The one-time initialisation
is needed because a sensor that shipped configured for Windows carries a pairing
key the community driver cannot know.

---

## Credits

- [`infinytum/libfprint`](https://github.com/infinytum/libfprint), branch
  `driver/538d` — the driver this builds.
- [`lbssousa/libfprint`](https://github.com/lbssousa/libfprint) and the
  [`goodix-fp-linux-dev`](https://github.com/goodix-fp-linux-dev) community —
  drivers and the dump tool.
- [`jahedcuet/goodix-538d-linux`](https://github.com/jahedcuet/goodix-538d-linux)
  and [`ELY3M/fix-goodix-538d-fingerprint`](https://github.com/ELY3M/fix-goodix-538d-fingerprint)
  — packaging and documentation that mapped this path first.
- The `usbreset` snippet follows the example in
  [`knauth/goodix-521d-explanation`](https://github.com/knauth/goodix-521d-explanation).

## Licence

The scripts in this repository are MIT (see `LICENSE`). The library built by
`install-driver.sh` is **not** distributed here: it is compiled on your machine
from libfprint, which is LGPL-2.1-or-later, and inherits that licence.

## Disclaimer

Community work, no warranty. Flashing firmware can brick the sensor and will
invalidate the Windows Hello pairing. You run this at your own risk.
