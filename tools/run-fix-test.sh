#!/bin/bash
# One round of the only test that matters: delete every stored print, enroll from
# scratch, then verify. Enrollment reporting success has never meant anything in
# this project -- fprintd-verify returning a match is the result.
#
#   ./run-fix-test.sh <label>
#
# Writes usbmon-<label>.txt, enroll-<label>.log, verify-<label>.log and
# fprintd-<label>.log. Needs the temporary polkit rule; see FINDINGS 15.5.
#
# NB: awk, never grep. grep here is ugrep, which treats usbmon traces as binary.

set -uo pipefail
cd "$(dirname "$0")" || exit 1

LABEL="${1:-}"
[ -n "$LABEL" ] || { echo "usage: $0 <label>" >&2; exit 1; }
[ -e "usbmon-$LABEL.txt" ] && { echo "label '$LABEL' already used" >&2; exit 1; }

DROPIN=/etc/systemd/system/fprintd.service.d/30-fpc-x.conf
BUS=$(lsusb -d 10a5:a900 | sed -E 's/Bus 0*([0-9]+).*/\1/')
[ -n "$BUS" ] || { echo "sensor 10a5:a900 not found on USB" >&2; exit 1; }

printf '[Service]\nEnvironment=G_MESSAGES_DEBUG=all\n' | sudo tee "$DROPIN" > /dev/null
sudo systemctl daemon-reload
sudo modprobe usbmon 2>/dev/null
sudo systemctl restart fprintd
sleep 1

START=$(date +"%Y-%m-%d %H:%M:%S")
sudo sh -c "timeout 900 cat /sys/kernel/debug/usb/usbmon/${BUS}u > usbmon-$LABEL.txt" &
CAP=$!
sleep 1

echo "==> clearing stored prints (the last run stored one built from no image)"
fprintd-delete "$USER" 2>&1 | sed 's/^/    /'

echo
echo "=================================================================="
echo "  ENROLL. Press and lift your finger on every prompt."
echo "  Up to 16 presses now -- the matcher asks for 16, not 11."
echo "  Move the finger slightly between presses."
echo "=================================================================="
fprintd-enroll 2>&1 | tee "enroll-$LABEL.log"

echo
echo "=================================================================="
echo "  VERIFY. Press the SAME finger once."
echo "=================================================================="
fprintd-verify 2>&1 | tee "verify-$LABEL.log"

sleep 2
sudo pkill -f "cat /sys/kernel/debug/usb/usbmon/${BUS}u" 2>/dev/null
sudo kill "$CAP" 2>/dev/null; wait "$CAP" 2>/dev/null
sudo journalctl -u fprintd --since "$START" --no-pager 2>&1 | tee "fprintd-$LABEL.log" > /dev/null

echo
echo "===== the matcher's verdict, sample by sample ====="
awk '/fpc_tee_enroll ->|end_enroll result|opened a|process_data .* failed|libfpcbep at/ {
       sub(/^.*fprintd\[[0-9]+\]: /, ""); print "    " $0 }' "fprintd-$LABEL.log"

echo
echo "===== result ====="
awk '{print "    enroll: " $0}' "enroll-$LABEL.log" | tail -20
awk '{print "    verify: " $0}' "verify-$LABEL.log"

echo
echo "===== USB summary ====="
awk -v b=":$BUS:" '
  $4 ~ b {
    if ($3=="S" && $6=="40" && $7=="02")                 arm++
    if ($3=="C" && $6=="40" && $7=="02" && $5!="0")      armfail++
    if ($3=="S" && $6=="40" && $7=="09")                 getimg++
  }
  $3=="C" && $4 ~ /:001:0$/ && $6=="4" && $8 ~ /^00/ {   disc++ }
  END {
    printf "    arm (40 02) sent / failed  : %d / %d\n", arm+0, armfail+0
    printf "    get-image (40 09) sent     : %d\n", getimg+0
    printf "    hub reported not-connected : %d\n", disc+0
  }' "usbmon-$LABEL.txt"

echo
echo "wrote: usbmon-$LABEL.txt enroll-$LABEL.log verify-$LABEL.log fprintd-$LABEL.log"
