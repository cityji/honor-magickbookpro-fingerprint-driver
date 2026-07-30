#!/bin/bash
# Completely remove the FPC 10a5:a900 patched-libfprint installation.
#
# install.sh never modifies anything under /usr/lib, so this only has to
# delete files it created and reload the two subsystems. Afterwards fprintd
# uses the stock distro libfprint again.
#
# Run: sudo ./uninstall.sh

set -euo pipefail

PREFIX=/opt/fpc-a900
UDEV=/etc/udev/rules.d/60-libfprint-2-device-fpc-a900.rules
DROPIN_DIR=/etc/systemd/system/fprintd.service.d
DROPIN="$DROPIN_DIR/10-fpc-a900.conf"

[ "$(id -u)" -eq 0 ] || { echo "must run as root (sudo ./uninstall.sh)" >&2; exit 1; }

echo "==> removing $DROPIN"
rm -f "$DROPIN"
# Only remove the directory if we left it empty (other drop-ins may exist).
rmdir "$DROPIN_DIR" 2>/dev/null || true

echo "==> removing $UDEV"
rm -f "$UDEV"

echo "==> removing $PREFIX"
rm -rf "$PREFIX"

echo "==> removing /var/log/fpc"
rm -rf /var/log/fpc

echo "==> reloading udev + systemd"
udevadm control --reload-rules
udevadm trigger --subsystem-match=usb
systemctl daemon-reload
systemctl restart fprintd 2>/dev/null || true
systemctl stop fprintd 2>/dev/null || true

echo
echo "Removed. fprintd is back on the distro libfprint:"
echo "  $(readlink -f /usr/lib/x86_64-linux-gnu/libfprint-2.so.2)"
echo
echo "Nothing under /usr/lib was ever touched, so there is nothing to restore."
echo "The build tree (build/) and the built artifact (dist/) are left in place;"
echo "delete them by hand if you want the working directory clean."
