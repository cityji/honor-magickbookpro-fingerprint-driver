#!/bin/bash
# One command, fresh machine, working fingerprint reader.
#
#   curl -fsSL https://raw.githubusercontent.com/cityji/honor-magickbookpro-fingerprint-driver/main/bootstrap.sh | bash
#
# or, from a clone:
#
#   ./bootstrap.sh
#
# Does, in order: install build dependencies for your distro, fetch the
# proprietary matcher from Lenovo's public download, build libfprint from
# source, install it privately for fprintd, and tell you how to enrol.
#
# It builds from source deliberately. A prebuilt libfprint has to match your
# glib/gusb/nss ABI, and a mismatch shows up as fprintd failing to start rather
# than as a clear error. Compiling takes about a minute.
#
# Nothing under /usr/lib is modified. Removal is `sudo ./uninstall.sh`.

set -euo pipefail

REPO="${REPO:-https://github.com/cityji/honor-magickbookpro-fingerprint-driver}"
BRANCH="${BRANCH:-main}"
WORKDIR="${WORKDIR:-$HOME/.cache/fpc-a900-build}"

say () { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die () { printf '\n!! %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] || die "run as your normal user, not root -- it will call sudo when it needs to"

# --- is this even the right machine? ---------------------------------------
say "checking for the sensor"
if command -v lsusb > /dev/null && lsusb | grep -qi '10a5:a900'; then
  echo "    found 10a5:a900 -- Fingerprint Cards match-on-host sensor"
elif command -v lsusb > /dev/null && lsusb | grep -qi '10a5:9800'; then
  echo "    found 10a5:9800 -- the sibling device. The fpcmoh driver covers it,"
  echo "    but patches/0009 is written for the a900's image format. See"
  echo "    docs/DEVICE.md before relying on this."
else
  echo "    no 10a5: device found by lsusb."
  echo "    Continuing anyway -- some machines power the sensor only after a"
  echo "    reboot, and you may be preparing an image. Check docs/DEVICE.md"
  echo "    to confirm your hardware first if you are unsure."
fi

# --- dependencies -----------------------------------------------------------
say "installing build dependencies"
if command -v apt-get > /dev/null; then
  sudo apt-get update -qq
  sudo apt-get install -y --no-install-recommends \
    git curl unzip ca-certificates meson ninja-build gcc g++ pkg-config python3 \
    libglib2.0-dev libgusb-dev libnss3-dev libusb-1.0-0-dev libpixman-1-dev \
    libgudev-1.0-dev libjson-glib-dev fprintd libpam-fprintd binutils
elif command -v dnf > /dev/null; then
  sudo dnf install -y git curl unzip meson ninja-build gcc gcc-c++ pkgconf python3 \
    glib2-devel libgusb-devel nss-devel libusb1-devel pixman-devel \
    libgudev-devel json-glib-devel fprintd fprintd-pam binutils
elif command -v pacman > /dev/null; then
  sudo pacman -S --needed --noconfirm git curl unzip meson ninja gcc pkgconf python \
    glib2 libgusb nss libusb pixman libgudev json-glib fprintd binutils
elif command -v zypper > /dev/null; then
  sudo zypper --non-interactive install git curl unzip meson ninja gcc gcc-c++ \
    pkg-config python3 glib2-devel libgusb-devel mozilla-nss-devel libusb-1_0-devel \
    libpixman-1-0-devel libgudev-1_0-devel json-glib-devel fprintd fprintd-pam binutils
else
  die "unknown package manager. Install the dependencies listed in build.sh, then run ./build.sh && sudo ./install.sh"
fi

# --- source -----------------------------------------------------------------
if [ -f "$(dirname "$0")/build.sh" ] && [ -d "$(dirname "$0")/patches" ]; then
  SRC="$(cd "$(dirname "$0")" && pwd)"
  say "using this checkout: $SRC"
else
  say "fetching $REPO ($BRANCH)"
  mkdir -p "$(dirname "$WORKDIR")"
  if [ -d "$WORKDIR/.git" ]; then
    git -C "$WORKDIR" fetch --depth 1 origin "$BRANCH"
    git -C "$WORKDIR" reset --hard "origin/$BRANCH"
  else
    rm -rf "$WORKDIR"
    git clone --depth 1 --branch "$BRANCH" "$REPO" "$WORKDIR"
  fi
  SRC="$WORKDIR"
fi
cd "$SRC"

say "fetching the proprietary matcher (libfpcbep.so)"
./get-blob.sh

say "building libfprint + fpcmoh + patches"
./build.sh

say "installing"
sudo ./install.sh

# --- PAM --------------------------------------------------------------------
say "checking PAM"
if awk '/^ *auth.*pam_fprintd\.so/ {found=1} END {exit !found}' /etc/pam.d/common-auth 2>/dev/null ||
   awk '/^ *auth.*pam_fprintd\.so/ {found=1} END {exit !found}' /etc/pam.d/system-auth 2>/dev/null; then
  echo "    pam_fprintd is already in the auth stack -- login and sudo will offer the sensor"
else
  echo "    pam_fprintd is NOT in your auth stack yet. Enable it with:"
  if command -v pam-auth-update > /dev/null; then
    echo "        sudo pam-auth-update            # tick \"Fingerprint authentication\""
  elif command -v authselect > /dev/null; then
    echo "        sudo authselect enable-feature with-fingerprint"
  else
    echo "        see docs/TROUBLESHOOTING.md, \"PAM is not wired up\""
  fi
fi

cat <<EOF

$(printf '\033[1m')Done.$(printf '\033[0m')  Now enrol a finger:

    fprintd-enroll

  Press and lift on every prompt, moving the finger slightly between presses.
  The matcher asks for up to 16 samples and will reject some -- that is normal,
  it says "remove and retry" and asks again.

  Then check it:

    fprintd-verify

  A working result is exactly "Verify result: verify-match". Enrollment
  reporting success is not sufficient evidence on its own -- see
  docs/INVESTIGATION.md section 17.4 for why that used to lie.

  To remove everything:  sudo $SRC/uninstall.sh
EOF
