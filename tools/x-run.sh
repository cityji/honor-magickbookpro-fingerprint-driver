#!/bin/bash
# Run ONE post-capture-recovery experiment for FPC 10a5:a900 (patches/0005).
#
#   ./x-run.sh <label> [FPC_X_FOO=bar ...]
#
# Writes the requested FPC_X_* variables into a systemd drop-in, RELOADS
# (daemon-reload, not just restart -- a restart alone keeps the old
# environment and silently runs experiment N under experiment N-1's settings),
# restarts fprintd, echoes the environment the daemon actually got, captures
# usbmon + the daemon debug log for one enroll, and prints a summary.
#
# Needs the temporary polkit rule; see the hint printed on failure.
#
# NB: awk, never grep. grep on this system is ugrep, which treats usbmon
# traces as binary (they contain NUL bytes) and silently matches nothing.

set -uo pipefail
cd "$(dirname "$0")" || exit 1

LABEL="${1:-}"
[ -n "$LABEL" ] || { echo "usage: $0 <label> [FPC_X_VAR=value ...]" >&2; exit 1; }
shift
[ -e "usbmon-$LABEL.txt" ] && { echo "label '$LABEL' already used -- pick a fresh one" >&2; exit 1; }

DROPIN=/etc/systemd/system/fprintd.service.d/30-fpc-x.conf
BUS=$(lsusb -d 10a5:a900 | sed -E 's/Bus 0*([0-9]+).*/\1/')
[ -n "$BUS" ] || { echo "sensor 10a5:a900 not found on USB" >&2; exit 1; }

echo "==> experiment '$LABEL' on bus $BUS: ${*:-<baseline, no FPC_X_* set>}"

{ echo "[Service]"
  echo "Environment=G_MESSAGES_DEBUG=all"
  for kv in "$@"; do echo "Environment=$kv"; done
} | sudo tee "$DROPIN" > /dev/null

sudo systemctl daemon-reload
sudo modprobe usbmon 2>/dev/null
sudo systemctl restart fprintd
sleep 1

# fprintd is D-Bus activated and may not be running yet; poke it so the
# environment check below has a process to look at.
fprintd-list "$USER" >/dev/null 2>&1
PID=$(pidof fprintd)
echo "==> daemon environment actually in effect (pid ${PID:-none}):"
if [ -n "${PID:-}" ]; then
  sudo tr '\0' '\n' < "/proc/$PID/environ" | awk '/^(FPC_X_|G_MESSAGES_DEBUG)/{print "    "$0}'
else
  echo "    (fprintd not running yet -- it will start with this drop-in)"
fi

START=$(date +"%Y-%m-%d %H:%M:%S")
sudo sh -c "timeout 600 cat /sys/kernel/debug/usb/usbmon/${BUS}u > usbmon-$LABEL.txt" &
CAP=$!
sleep 1

echo "=============================================="
echo "  PRESS AND LIFT your finger on every prompt."
echo "=============================================="

fprintd-enroll 2>&1 | tee "enroll-$LABEL.log"

if awk '/PermissionDenied|Not Authorized/{f=1} END{exit !f}' "enroll-$LABEL.log"; then
  cat >&2 <<'HINT'

--------------------------------------------------------------------
Not authorized -- this run captured nothing. COSMIC registers no
polkit agent on this machine and pkttyagent cannot cover
fprintd-enroll's subject. Apply the temporary rule, re-run, remove it:

  sudo tee /etc/polkit-1/rules.d/49-fpc-test.rules > /dev/null << 'EOF'
  polkit.addRule(function(action, subject) {
      if (action.id == "net.reactivated.fprint.device.enroll" && subject.user == "'"$USER"'")
          return polkit.Result.YES;
  });
  EOF
  sudo systemctl restart polkit
--------------------------------------------------------------------
HINT
fi

sleep 2
sudo pkill -f "cat /sys/kernel/debug/usb/usbmon/${BUS}u" 2>/dev/null
sudo kill "$CAP" 2>/dev/null; wait "$CAP" 2>/dev/null
sudo journalctl -u fprintd --since "$START" --no-pager 2>&1 | tee "fprintd-$LABEL.log" > /dev/null

echo
echo "===== USB summary ====="
awk -v b=":$BUS:" '
  $4 ~ b {
    if ($3=="S" && $6=="40" && $7=="02")  arm++
    if ($3=="S" && $6=="40" && $7=="09")  getimg++
    if ($3=="C" && $6=="40" && $7=="02" && $5!="0") armfail++
    if ($3=="C" && $4 ~ /:2$/ && $5=="0") { bulkc++; bulkb+=$6 }
  }
  # hub port-status reads: did the sensor actually leave the bus?
  $3=="C" && $4 ~ /:001:0$/ && $6=="4" {
    if ($8 ~ /^00/) disc++          # wPortStatus low byte 0x00 -> not connected
  }
  END {
    printf "arm commands (40 02) sent    : %d\n", arm+0
    printf "  of which failed/cancelled  : %d\n", armfail+0
    printf "get-image commands (40 09)   : %d\n", getimg+0
    printf "bulk-IN completions / bytes  : %d / %d\n", bulkc+0, bulkb+0
    printf "hub reported not-connected   : %d\n", disc+0
  }' "usbmon-$LABEL.txt"

echo
echo "===== port-status timeline (disconnect hunt) ====="
awk '$3=="C" && $4 ~ /:001:0$/ && $6=="4" {print "    "$2" portstatus "$8}' \
    "usbmon-$LABEL.txt" | head -20

echo
echo "===== driver state machine ====="
awk 'tolower($0) ~ /a900-x|send cmdid|entering state|enroll|error|timed out|failed/' \
    "fprintd-$LABEL.log" | tail -45

echo
echo "wrote: usbmon-$LABEL.txt  enroll-$LABEL.log  fprintd-$LABEL.log"
