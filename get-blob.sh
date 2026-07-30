#!/bin/bash
# Fetch libfpcbep.so, the proprietary host-side matcher this driver needs.
#
#   ./get-blob.sh            -> blob/libfpcbep.so
#
# The sensor does no matching itself. It captures an image, encrypts it to the
# host over TLS-PSK, and a closed userspace library decrypts it, runs the
# biometric algorithm and stores the template. That library is libfpcbep.so and
# it is NOT redistributable, so it is not in this repository. It is however
# published by Lenovo as a normal public driver download, and the file is
# byte-identical to the one FPC ships to every OEM using this sensor family:
#
#   https://download.lenovo.com/pccbbs/mobiles/r1slm01w.zip
#   -> FPC_driver_linux_27.26.23.39/install_fpc/libfpcbep.so
#   md5 f7136fd774d5208e629bbeaa4974543a   (1650656 bytes)
#
# This script downloads that archive to a temporary directory, extracts the one
# file, checks the md5 and drops it in blob/. Nothing else from the archive is
# used -- it also contains Lenovo's own prebuilt libfprint, which is the thing
# this project replaces.
#
# If your machine is offline, or the URL has rotted, put a copy of
# libfpcbep.so in blob/ by hand and everything else works unchanged.

set -euo pipefail

URL="${FPCBEP_URL:-https://download.lenovo.com/pccbbs/mobiles/r1slm01w.zip}"
INNER="FPC_driver_linux_27.26.23.39/install_fpc/libfpcbep.so"
MD5_EXPECTED="f7136fd774d5208e629bbeaa4974543a"

SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="$SRC/blob/libfpcbep.so"

if [ -f "$DEST" ]; then
  if [ "$(md5sum "$DEST" | cut -d' ' -f1)" = "$MD5_EXPECTED" ]; then
    echo "==> blob/libfpcbep.so already present and correct"
    exit 0
  fi
  echo "!! blob/libfpcbep.so exists but has the wrong md5 -- refetching" >&2
fi

for t in curl unzip md5sum; do
  command -v "$t" > /dev/null || { echo "need $t" >&2; exit 1; }
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> downloading $URL"
curl -fsSL --retry 3 --max-time 300 -o "$TMP/fpc.zip" "$URL"

echo "==> extracting $INNER"
unzip -p "$TMP/fpc.zip" "$INNER" > "$TMP/libfpcbep.so"

MD5_GOT="$(md5sum "$TMP/libfpcbep.so" | cut -d' ' -f1)"
if [ "$MD5_GOT" != "$MD5_EXPECTED" ]; then
  cat >&2 <<EOF
!! md5 mismatch
     expected $MD5_EXPECTED
     got      $MD5_GOT

   Lenovo may have refreshed the package. A different build of libfpcbep.so is
   not automatically wrong, but patches/0009 is pinned to the disassembly of
   this one -- see docs/INVESTIGATION.md section 18.3. It will detect the
   mismatch at run time and disable itself, which means captures will be
   rejected again. Read that section before forcing this.

   To use it anyway: FPCBEP_SKIP_MD5=1 ./get-blob.sh
EOF
  [ "${FPCBEP_SKIP_MD5:-0}" = "1" ] || exit 1
fi

install -d -m 0755 "$SRC/blob"
install -m 0644 "$TMP/libfpcbep.so" "$DEST"
echo "==> blob/libfpcbep.so   ($(stat -c %s "$DEST") bytes, md5 $MD5_GOT)"
