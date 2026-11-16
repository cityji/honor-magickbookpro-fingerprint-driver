#!/bin/bash
# ASAN regression test for the init-handshake failure paths (patches 0011/0012).
# Drives the REAL fpcmoh callbacks and the REAL fpi-ssm.c -- no USB hardware,
# no root, no blob execution (matcher symbols are link-time stubs).
#
#   ./run.sh [path/to/fpc.c]
#
# Default: build/libfprint-src/libfprint/drivers/fpcmoh/fpc.c
# (run ./build.sh first -- the harness needs builddir's generated fp-enums.h).
#
# Scenarios:
#   hello      stale sensor event (cmdid 6) during TLS-hello wait
#   init_done  init SSM failure -> fpc_init_ssm_done error ownership
#   cmd_init   short init event -> fpc_cmd_init_cb failure path
#
# Without patches 0011/0012 all three fail under AddressSanitizer
# (2x heap-use-after-free in fpi_ssm_next_state, 1x double-free of the SSM
# error). With them applied all three pass: exactly one SSM completion,
# error owned exactly once. Pass a pre-fix fpc.c copy to see the failures.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(cd ../.. && pwd)"
LP="$ROOT/build/libfprint-src"
FPC="${1:-$LP/libfprint/drivers/fpcmoh/fpc.c}"
[ -f "$FPC" ] || { echo "no such file: $FPC" >&2; exit 1; }
[ -f "$LP/builddir/libfprint/fp-enums.h" ] || { echo "run ./build.sh first" >&2; exit 1; }

INC="-I$LP/libfprint -I$LP/libfprint/drivers/fpcmoh -I$LP/builddir -I$LP/builddir/libfprint"
CF="$(pkg-config --cflags glib-2.0 gobject-2.0 gio-2.0 gusb)"
LIBS="$(pkg-config --libs glib-2.0 gobject-2.0 gio-2.0 gusb) -ldl"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

gcc -fsanitize=address -g -O0 -DFPC_SRC="\"$FPC\"" $INC $CF -c test.c -o "$WORK/test.o"
gcc -fsanitize=address -g -O0 $INC $CF -c "$LP/libfprint/fpi-ssm.c" -o "$WORK/ssm.o" 2>/dev/null

# Link-time stubs for everything the driver references but the tested paths
# never execute (blob, transfer submission, other complete() handlers).
# The instrumented stubs live in test.c.
nm -u "$WORK/test.o" | awk '{print $2}' \
  | grep -vE '^(_|g_|G_|gusb|libusb|fpi_ssm_|dladdr|dlsym|memcpy|memmove|memset|strcmp|strlen)' \
  | sort -u | while read -r s; do echo "void $s(void) {}"; done > "$WORK/stubs.c"
gcc -fsanitize=address -g -O0 $INC $CF -c "$WORK/stubs.c" -o "$WORK/stubs.o"
gcc -fsanitize=address "$WORK/test.o" "$WORK/ssm.o" "$WORK/stubs.o" -o "$WORK/test" $LIBS

ASAN_OPTIONS=detect_leaks=0 "$WORK/test" all
