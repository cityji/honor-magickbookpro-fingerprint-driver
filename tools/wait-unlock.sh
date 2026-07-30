#!/bin/bash
# Wait for session 4 to come back from the lock screen, then report what
# authenticated it. Started after run-lock-test.sh gave up too early.
set -uo pipefail
cd "$(dirname "$0")" || exit 1
START="$1"; LABEL="$2"
for _ in $(seq 1 600); do
  [ "$(loginctl show-session 4 -p LockedHint --value)" = "yes" ] || break
  sleep 1
done
if [ "$(loginctl show-session 4 -p LockedHint --value)" = "yes" ]; then
  echo "!! still locked after 10 minutes"; exit 3
fi
echo "==> unlocked"
sleep 2
sudo journalctl --since "$START" --no-pager 2>&1 | tee "lock-$LABEL-all.log" > /dev/null
echo
echo "===== fprintd / pam_fprintd during the locked window ====="
awk '/fprintd|pam_fprintd|fingerprint|relayout|verify|Verify|match/ {
       sub(/^[A-Z][a-z]{2} +[0-9]+ [0-9:]+ [^ ]+ /,""); print "    "$0 }' \
    "lock-$LABEL-all.log" | tail -45
echo
echo "===== how the unlock authenticated ====="
awk '/pam_unix|pam_fprintd|gkr-pam|Authenticat|session opened|unlock|Unlock/ {
       sub(/^[A-Z][a-z]{2} +[0-9]+ [0-9:]+ [^ ]+ /,""); print "    "$0 }' \
    "lock-$LABEL-all.log" | tail -25
echo
echo "wrote: lock-$LABEL-all.log"
