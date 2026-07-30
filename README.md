# Fingerprint driver for `10a5:a900` — HONOR MagicBook and other FPC match-on-host sensors

[![build](https://github.com/cityji/honor-magickbookpro-fingerprint-driver/actions/workflows/ci.yml/badge.svg)](https://github.com/cityji/honor-magickbookpro-fingerprint-driver/actions/workflows/ci.yml)

Working fingerprint enrollment and login on Linux for the Fingerprint Cards
`10a5:a900` sensor, which no distro supports out of the box.

```
$ fprintd-enroll
Enroll result: enroll-completed

$ fprintd-verify
Verify result: verify-match
```

Verified end to end on Pop!_OS 22.04 (COSMIC): enrollment, `fprintd-verify`,
persistence across a daemon restart, and unlocking the lock screen through PAM.

---

## Quick install

```bash
curl -fsSL https://raw.githubusercontent.com/cityji/honor-magickbookpro-fingerprint-driver/main/bootstrap.sh | bash
```

That installs build dependencies for your distro, fetches the proprietary matcher
from Lenovo's public driver download, builds libfprint from source, installs it
for `fprintd` only, and tells you how to enrol. Takes about a minute. Nothing
under `/usr/lib` is touched, and `sudo ./uninstall.sh` removes all of it.

If you would rather read before running a piped script — reasonable — see
[From source](#from-source) below. It is the same four commands.

Then:

```bash
fprintd-enroll        # press and lift on each prompt, move the finger slightly
fprintd-verify        # must print: Verify result: verify-match
```

> **`verify-match` is the only proof that matters.** `enroll-completed` on its own
> means nothing here — for the entire history of this bug, enrollment reported
> eleven passed stages and success while the matcher was rejecting every single
> image. See [why](#what-was-actually-wrong).

---

## Is this for your machine?

```bash
lsusb | grep 10a5
```

| what you see | status |
|---|---|
| `10a5:a900` | **supported** — this is the device this was built and tested for |
| `10a5:9800` | the sibling. The driver covers it and merge request 396 was written for it, but `patches/0009` targets the a900's image format. Read [docs/DEVICE.md](docs/DEVICE.md) first |
| another `10a5:` id | possibly reachable — [docs/DEVICE.md](docs/DEVICE.md) has a checklist for identifying a new variant |
| no `10a5:` device | not this project. Check [libfprint's supported device list](https://fprint.freedesktop.org/supported-devices.html) |

Hardware summary — full details in [docs/DEVICE.md](docs/DEVICE.md):

| | |
|---|---|
| USB id | `10a5:a900`, Fingerprint Cards AB |
| Product string | `FPC Sensor Controller L:0002 FW:22.26.2.29` |
| Sensor | hardware id `0x331`, FPC type 7, **64 x 176** 8-bit image |
| Architecture | **match on host** — the sensor does no matching |
| Transport | TLS-PSK 1.2, `TLS_PSK_WITH_AES_128_CBC_SHA256`, sensor is the client |
| Seen in | HONOR MagicBook series; the `9800` sibling in various Lenovo models |

---

## What this actually installs

```
/opt/fpc-a900/lib/libfprint-2.so.2.0.0      libfprint 1.94.6 + MR 396 + patches/
/opt/fpc-a900/lib/libfpcbep.so              FPC's proprietary matcher (fetched, not shipped)
/etc/systemd/system/fprintd.service.d/      LD_LIBRARY_PATH for fprintd ONLY
/etc/udev/rules.d/60-libfprint-2-device-fpc-a900.rules
/var/log/fpc/                               the matcher writes here
```

Your distro's `libfprint` stays exactly where it is and keeps serving everything
else. Only `fprintd` sees the patched build, via a systemd drop-in. That is
deliberate: it means a bad build breaks fingerprint auth and nothing else, and
uninstalling is deleting four paths.

### The proprietary part, stated plainly

This sensor **cannot work without a closed-source binary**. It captures an image,
encrypts it to the host, and a library called `libfpcbep.so` does the decryption,
the biometric algorithm and the template handling. There is no open
reimplementation and writing one is not realistic.

That library is not redistributable, so it is **not in this repository**. It is
published by Lenovo as an ordinary public driver download, and `get-blob.sh`
fetches exactly one file out of it and verifies the checksum:

```
https://download.lenovo.com/pccbbs/mobiles/r1slm01w.zip
  -> FPC_driver_linux_27.26.23.39/install_fpc/libfpcbep.so
     md5 f7136fd774d5208e629bbeaa4974543a   1650656 bytes
```

The copy in that archive is byte-identical to the one shipped for the `9800`, and
it works for the `a900` because FPC uses the same pre-shared key and the same
matcher across the family. If you are offline, drop your own copy in `blob/` and
everything else works unchanged.

---

## From source

```bash
git clone https://github.com/cityji/honor-magickbookpro-fingerprint-driver
cd honor-magickbookpro-fingerprint-driver

./get-blob.sh          # fetch libfpcbep.so from Lenovo, verify md5
./build.sh             # libfprint 1.94.6 + MR 396 + patches/ -> dist/
sudo ./install.sh      # install for fprintd only
```

`build.sh` prints what it produced and self-checks the two things that actually
go wrong — driver missing, or device id missing:

```
==> dist/libfprint-2.so.2.0.0
      NEEDED               libfpcbep.so
      SONAME               libfprint-2.so.2
    fpcmoh driver          : present
    id_table 10a5:9800      : present
    id_table 10a5:a900      : present
```

### Build dependencies

<details>
<summary>Debian / Ubuntu / Pop!_OS</summary>

```bash
sudo apt install -y git curl unzip meson ninja-build gcc g++ pkg-config python3 \
  libglib2.0-dev libgusb-dev libnss3-dev libusb-1.0-0-dev libpixman-1-dev \
  libgudev-1.0-dev libjson-glib-dev fprintd libpam-fprintd
```
</details>

<details>
<summary>Fedora</summary>

```bash
sudo dnf install -y git curl unzip meson ninja-build gcc gcc-c++ pkgconf python3 \
  glib2-devel libgusb-devel nss-devel libusb1-devel pixman-devel \
  libgudev-devel json-glib-devel fprintd fprintd-pam
```
</details>

<details>
<summary>Arch</summary>

```bash
sudo pacman -S --needed git curl unzip meson ninja gcc pkgconf python glib2 \
  libgusb nss libusb pixman libgudev json-glib fprintd
```
</details>

### Prebuilt bundles

[Releases](https://github.com/cityji/honor-magickbookpro-fingerprint-driver/releases)
carry a prebuilt library per Ubuntu release:

```bash
tar xzf fpc-a900-libfprint-v1.0.0-ubuntu-24.04.tar.gz
cd fpc-a900-libfprint-v1.0.0-ubuntu-24.04
./get-blob.sh && sudo ./install.sh
```

These are a convenience, not the supported path. A prebuilt `libfprint` has to
match your glib/gusb/nss ABI, and a mismatch shows up as `fprintd` failing to
start. Building from source always works, and takes a minute.

### Login and lock screen

`pam_fprintd` does the rest, and on most distros it is already wired up. Check:

```bash
awk '/pam_fprintd/' /etc/pam.d/common-auth /etc/pam.d/system-auth 2>/dev/null
```

If nothing comes back: `sudo pam-auth-update` (Debian/Ubuntu, tick *Fingerprint
authentication*) or `sudo authselect enable-feature with-fingerprint` (Fedora).

> **The lock screen gives you 10 seconds and one attempt**
> (`pam_fprintd.so max-tries=1 timeout=10`), and several desktops — COSMIC
> included — print no "place your finger" prompt at all. If nothing seems to
> happen, that is usually the window closing, not a failure. Have the finger
> moving as the lock screen appears, or raise `timeout=` in
> `/etc/pam.d/common-auth`.

---

## What was actually wrong

Worth reading if you are debugging a related device, because two of these are
not a900-specific.

The `fpcmoh` driver already existed — [merge request
396](https://gitlab.freedesktop.org/libfprint/libfprint/-/merge_requests/396),
unmerged since 2022. With just the device id added, the sensor bound, opened,
completed a TLS handshake, captured an image, reported eleven passed enroll
stages and `enroll-completed`... and then never matched anything. Three separate
faults:

### 1. The driver walked away mid-transfer

`fpc_ssm_img_read_cb()` consumes one record per state machine state, and there are
exactly eleven read states. **This sensor sends twelve records plus two trailing
messages.** The sensor does not service endpoint 0 while it still has data
queued, so the *next* control command — any of them — timed out, and ~1.08 s later
a firmware watchdog reset the sensor and it re-enumerated at a new address.

Every "the a900 goes silent after a capture", "resets itself", "cannot re-arm"
symptom was this one bug. `patches/0006` reads until the sensor stops.

### 2. The image was ten bytes off, and the driver never noticed

The matcher reassembles the image message and then checks its length:

```c
img_len = recv_len - 0xa - 0x18;               /* 34-byte prefix, hardcoded */
if (img_len != fpc_bep_image_get_size (img))
  return -1;
```

This firmware declares `total = 11288` for a 64×176 sensor — a **24**-byte prefix
plus 11264 pixels. The matcher wants **34**, computes `11254`, and returns `-1`.
**Merge request 396 discards that return value**, so the biometric algorithm
silently never ran at all, every sample came back `IMAGE_LOW_QUALITY`, and
`remaining` never moved off 16.

The message is TLS between the sensor's firmware and the matcher's own mbedtls, so
it cannot be changed on the wire. `patches/0009` moves it after it lands: open a
ten-byte gap at offset 24 once the first record is in, which produces exactly the
layout the matcher was built for. Guarded on three preconditions, and it disables
itself if any fail.

### 3. Enrollment reported success no matter what

`fpc_read_dead_pixels()` called `fpc_tee_enroll()`, threw the result away, and
called `fpi_device_enroll_progress()` unconditionally. So an enrollment in which
the matcher accepted *nothing* still reported every stage as passed and stored a
92-byte template built from no image. `fpc_tee_end_enroll()` returning `-1` was
also discarded. **This one is not a900-specific — it hides total failure on any
FPC match-on-host device.** `patches/0010` acts on the verdict, requests a retry
on rejected samples, and lets the matcher decide when it has enough.

### The patch set

| patch | what | scope |
|---|---|---|
| `0001` | add `10a5:a900` to `id_table` | a900 |
| `0002` | a failed cleanup transfer must not fail a completed operation | **all FPC MoH — upstreamable** |
| `0004` | fix a double free of the SSM error (`SIGSEGV` in fprintd) | **all FPC MoH — upstreamable** |
| `0005` | experiment harness; no behaviour change unless `FPC_X_*` is set | scaffolding, now a dependency of 0010 |
| `0006` | read the image until the sensor stops sending | a900, arguably general |
| `0009` | **fix up the image message for the matcher** | a900, not upstreamable |
| `0010` | let the matcher decide whether a sample was good | **first half upstreamable** |

`patches-debug/` holds the instrumentation that found all this, plus one
experiment (`0003`) that has been retested and dropped. Keep them out of a normal
build; they are the tooling for diagnosing a *new* variant.

Full teardown, including the measurements behind every claim above:
**[docs/INVESTIGATION.md](docs/INVESTIGATION.md)**.

---

## Repository layout

```
bootstrap.sh          one-command install on a fresh machine
get-blob.sh           fetch libfpcbep.so from Lenovo's public download
build.sh              libfprint 1.94.6 + MR 396 + patches/ -> dist/
install.sh            install for fprintd only, /usr/lib untouched
uninstall.sh          remove everything it installed
patches/              the shipped patch set
patches-debug/        instrumentation and retired experiments
docs/DEVICE.md        hardware, protocol, and a checklist for other models
docs/INVESTIGATION.md the full teardown, measurement by measurement
docs/TROUBLESHOOTING.md
tools/probe-blob.c    ask the matcher what geometry it expects, no hardware needed
tools/                test harness used to validate the fix
```

---

## Credits

This is a patch set on other people's work. In order of how much it owes them:

- **[Jason Huang](mailto:jason.huang@fingerprints.com) (Fingerprint Cards AB)** —
  wrote the `fpcmoh` driver in [libfprint merge request
  396](https://gitlab.freedesktop.org/libfprint/libfprint/-/merge_requests/396),
  which is the entire foundation here and has been waiting for review since
  September 2022. Everything in `patches/` is a delta on that.
- **[libfprint](https://gitlab.freedesktop.org/libfprint/libfprint)** and
  **[fprintd](https://gitlab.freedesktop.org/libfprint/fprintd)** — the stack this
  plugs into. Built against tag `v1.94.6`.
- **[furcom/libfprint-patched](https://github.com/furcom/libfprint-patched)** —
  a prebuilt libfprint + the FPC blob, packaged from the AUR
  `libfprint-fpcmoh-git`. Established that this hardware family was reachable at
  all, and pointed at where the blob comes from. Note that tree diverges from
  merge request 396 (`MAX_ENROLL_SAMPLES` 11 vs 12, `dlopen` instead of direct
  linking, an extra `0x03` at init), so do not expect a from-source build to
  match it byte for byte.
- **[jedbillyb/linux-fingerprint-drivers](https://github.com/jedbillyb/linux-fingerprint-drivers)**
  — the community tracker that made it possible to establish there was no
  existing lead for this device.
- **Lenovo** — publishes `libfpcbep.so` as part of a normal public driver
  download, which is the only reason this is installable without an NDA.
- **[mbed TLS](https://github.com/Mbed-TLS/mbedtls)** — statically linked inside
  `libfpcbep.so`; its symbol names made the transport readable.

If you have an FPC match-on-host device and this helps, please add your model and
its `hwid` / `total` numbers to an issue — that is exactly the data another owner
needs, and [docs/DEVICE.md](docs/DEVICE.md) explains how to get it in one run.

## Licence

The patches, scripts and documentation here are **LGPL-2.1-or-later**, matching
libfprint, since `patches/` are derived works of it. See [LICENSE](LICENSE).

`libfpcbep.so` is proprietary, owned by Fingerprint Cards AB, is **not**
distributed here, and is covered by whatever terms accompany the vendor package
you obtain it from.

## Disclaimer

Not affiliated with or endorsed by Fingerprint Cards AB, HONOR, Lenovo, or the
libfprint project. Reverse engineering documented here was done for
interoperability — making hardware work with the operating system it was sold
alongside — on a device I own.

`patches/0009` writes into another library's private memory at offsets derived
from its disassembly, pinned to one build (`md5 f7136fd7…`). It validates three
preconditions before doing anything and disables itself if they do not hold. It
is a workaround for a firmware/matcher format disagreement, and the honest fix
would be a matcher build that expects this message format. Understand that before
depending on it for anything that matters.
