#!/bin/bash
# Build libfprint with the fpcmoh driver and 10a5:a900 support, from source.
#
#   libfprint v1.94.6                       upstream, tagged release
#   + merge request 396                     adds drivers/fpcmoh/, still unmerged
#   + patches/*.patch                       this project's changes
#
# Produces dist/libfprint-2.so.2.0.0, which `sudo ./install.sh` deploys.
# Run as a normal user, NOT root.
#
# Build dependencies:
#   Debian/Ubuntu/Pop!_OS
#     sudo apt install -y git curl meson ninja-build gcc g++ pkg-config \
#          libglib2.0-dev libgusb-dev libnss3-dev libusb-1.0-0-dev \
#          libpixman-1-dev libgudev-1.0-dev libjson-glib-dev python3
#   Fedora
#     sudo dnf install -y git curl meson ninja-build gcc gcc-c++ pkgconf \
#          glib2-devel libgusb-devel nss-devel libusb1-devel pixman-devel \
#          libgudev-devel json-glib-devel python3
#   Arch
#     sudo pacman -S --needed git curl meson ninja gcc pkgconf glib2 libgusb \
#          nss libusb pixman libgudev json-glib python
#
# Environment:
#   LIBFPRINT_TAG   libfprint tag to build (default v1.94.6)
#   BLOBDIR         where libfpcbep.so lives (default: blob/, then /opt/fpc-a900/lib)
#   STUB_BLOB=1     link against a generated stub instead of the real blob.
#                   For CI, where the proprietary blob is unavailable. The
#                   result runs only if the real blob is present at run time.

set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
BUILD="$SRC/build"
TREE="$BUILD/libfprint-src"
TAG="${LIBFPRINT_TAG:-v1.94.6}"
MR_URL="https://gitlab.freedesktop.org/libfprint/libfprint/-/merge_requests/396.patch"

[ "$(id -u)" -ne 0 ] || { echo "do NOT run this as root" >&2; exit 1; }

# --- the proprietary matcher, needed at LINK time ---------------------------
# MR 396 links libfpcbep.so directly (DT_NEEDED), so it has to be resolvable
# when libfprint is linked, even though nothing in it is called until run time.
if [ "${STUB_BLOB:-0}" = "1" ]; then
  echo "==> STUB_BLOB=1: linking against a generated stub, not the real matcher"
  BLOBDIR="$BUILD/stub"
elif [ -n "${BLOBDIR:-}" ]; then
  :
elif [ -f "$SRC/blob/libfpcbep.so" ]; then
  BLOBDIR="$SRC/blob"
elif [ -f /opt/fpc-a900/lib/libfpcbep.so ]; then
  BLOBDIR=/opt/fpc-a900/lib
else
  cat >&2 <<'EOF'
ERROR: libfpcbep.so not found.

  It is the proprietary host-side matcher and cannot be shipped here. Fetch it
  from Lenovo's public driver download:

      ./get-blob.sh

  See docs/DEVICE.md for what it does and why it is required.
EOF
  exit 1
fi

mkdir -p "$BUILD"

# --- source ----------------------------------------------------------------
if [ ! -d "$TREE" ]; then
  echo "==> cloning libfprint $TAG"
  git clone --depth 1 --branch "$TAG" \
      https://gitlab.freedesktop.org/libfprint/libfprint.git "$TREE"
fi

if [ ! -f "$BUILD/mr396.patch" ]; then
  echo "==> fetching merge request 396 (the fpcmoh driver)"
  curl -fsSL --retry 3 -o "$BUILD/mr396.patch" "$MR_URL"
fi

echo "==> applying merge request 396 + patches/"
git -C "$TREE" checkout -- .
rm -rf "$TREE/libfprint/drivers/fpcmoh"
git -C "$TREE" apply "$BUILD/mr396.patch"
for p in "$SRC"/patches/*.patch; do
  [ -e "$p" ] || continue
  echo "    $(basename "$p")"
  git -C "$TREE" apply "$p"
done

# --- stub matcher for CI, part 1 -------------------------------------------
# meson's cc.find_library('fpcbep') runs at configure time, so something has to
# exist before that. Start with an empty library; the symbols get filled in
# after the first link attempt tells us exactly which ones are missing.
if [ "${STUB_BLOB:-0}" = "1" ]; then
  mkdir -p "$BLOBDIR"
  echo 'static int stub_placeholder;' > "$BUILD/stub.c"
  cc -shared -fPIC -o "$BLOBDIR/libfpcbep.so" "$BUILD/stub.c"
fi

echo "==> linking against $BLOBDIR/libfpcbep.so"

# --- configure -------------------------------------------------------------
# Two link flags are needed to build against a blob outside the default search
# path: -L so `cc.find_library('fpcbep')` and -lfpcbep resolve when libfprint
# itself is linked, and -rpath-link so the example programs can resolve it
# transitively (they do not get -lfpcbep themselves, and --no-undefined makes
# an unresolved symbol fatal). Without -rpath-link the library builds but
# examples/* fail to link.
LINKARGS="-L$BLOBDIR -Wl,-rpath-link,$BLOBDIR"

echo "==> configuring"
rm -rf "$TREE/builddir"
meson setup "$TREE/builddir" "$TREE" \
  --prefix=/opt/fpc-a900 \
  -Ddrivers=fpcmoh \
  -Dgtk-examples=false -Ddoc=false -Dintrospection=false \
  -Dc_link_args="$LINKARGS" -Dcpp_link_args="$LINKARGS"

# --- stub matcher for CI, part 2 -------------------------------------------
# Compile everything, let the link fail, and read the missing matcher symbols
# straight out of the driver's object file. Exact, unlike parsing the header --
# which quietly harvests return types such as `fpc_enclave_t` and leaves
# fpc_create_enclave() undefined.
#
# This only satisfies the linker. DT_NEEDED still records the plain name
# "libfpcbep.so", so at run time the real library is what gets loaded.
if [ "${STUB_BLOB:-0}" = "1" ]; then
  echo "==> discovering which matcher symbols the driver references"
  ninja -C "$TREE/builddir" > "$BUILD/first-pass.log" 2>&1 || true

  OBJ="$(find "$TREE/builddir" -name '*fpcmoh_fpc.c.o' -print -quit)"
  [ -n "$OBJ" ] || { echo "ERROR: driver object not built; see $BUILD/first-pass.log" >&2
                     tail -30 "$BUILD/first-pass.log" >&2; exit 1; }

  nm -u "$OBJ" | awk '$NF ~ /^fpc_/ {print $NF}' | sort -u > "$BUILD/stub-syms.txt"
  COUNT="$(wc -l < "$BUILD/stub-syms.txt")"
  [ "$COUNT" -gt 0 ] || { echo "ERROR: no fpc_* symbols undefined in $OBJ" >&2; exit 1; }
  echo "    $COUNT symbols"

  {
    echo '/* Generated by build.sh (STUB_BLOB=1). Satisfies the linker only.'
    echo '   Never install this -- it makes every matcher call return -1. */'
    while read -r s; do
      [ -n "$s" ] && echo "long $s (void) { return -1; }"
    done < "$BUILD/stub-syms.txt"
  } > "$BUILD/stub.c"
  cc -shared -fPIC -o "$BLOBDIR/libfpcbep.so" "$BUILD/stub.c"
fi

echo "==> building"
ninja -C "$TREE/builddir"

# --- stage -----------------------------------------------------------------
mkdir -p "$SRC/dist"
cp "$TREE/builddir/libfprint/libfprint-2.so.2.0.0" "$SRC/dist/libfprint-2.so.2.0.0"

echo
echo "==> dist/libfprint-2.so.2.0.0"
objdump -p "$SRC/dist/libfprint-2.so.2.0.0" |
  awk '/SONAME|NEEDED.*fpcbep/ {print "    "$0}'

# Sanity checks that are cheap and catch the two mistakes that actually happen:
# building without the driver, and building without the a900 id.
# NB: awk, not grep -- on some systems grep is ugrep, which treats `strings`
# output as binary and silently matches nothing.
if strings -a "$SRC/dist/libfprint-2.so.2.0.0" |
     awk '$0 == "FPC MOH Fingerprint Sensor" {found=1} END {exit !found}'; then
  echo "    fpcmoh driver          : present"
else
  echo "    fpcmoh driver          : MISSING -- was it built with -Ddrivers=fpcmoh ?"
  exit 1
fi

python3 - "$SRC/dist/libfprint-2.so.2.0.0" <<'PYEOF'
import sys
data = open(sys.argv[1], 'rb').read()
# FpIdEntry is { guint32 pid; guint32 vid; ... } -- pid first.
for pid, name in ((0x9800, '10a5:9800'), (0xa900, '10a5:a900')):
    entry = pid.to_bytes(4, 'little') + (0x10a5).to_bytes(4, 'little')
    print("    id_table %s      : %s" % (name, "present" if data.count(entry) else "ABSENT"))
PYEOF

echo
echo "Now:  sudo ./install.sh"
