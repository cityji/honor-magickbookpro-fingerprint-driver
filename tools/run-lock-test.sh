#!/bin/bash
# Lock the COSMIC session and report whether pam_fprintd authenticated the unlock.
#
#   ./run-lock-test.sh <label>
#
# Locks via logind, waits for the session to come back, then pulls the fprintd and
# cosmic-greeter journal for the window. The password path stays available the
# whole time: /etc/pam.d/common-auth is
#     auth [success=2 default=ignore] pam_fprintd.so max-tries=1 timeout=10
#     auth [success=1 default=ignore] pam_unix.so    nullok try_first_pass
# so a failed or ignored fingerprint falls through to the password prompt.
#
# NB: awk, never grep -- grep here is ugrep.

set -uo pipefail
cd "$(dirname "$0")" || exit 1

LABEL="${1:-lock}"
SESSION=$(loginctl list-sessions --no-legend | awk -v u="$USER" '$3==u{print $1; exit}')
[ -n "$SESSION" ] || { echo "no logind session for $USER" >&2; exit 1; }

locked () { [ "$(loginctl show-session "$SESSION" -p LockedHint --value)" = "yes" ]; }

cat <<'BANNER'
==================================================================
  Locking the screen in 10 seconds.

  PUT YOUR FINGER ON THE SENSOR THE MOMENT THE SCREEN CHANGES.
  The fingerprint window is only 10 seconds long (PAM's
  max-tries=1 timeout=10) and the greeter prints no prompt,
  so a late press misses it entirely.

  If it refuses, type your password -- that path is untouched.
==================================================================
BANNER
sleep 10

START=$(date +"%Y-%m-%d %H:%M:%S")
echo "==> session $SESSION, locking now"
loginctl lock-session "$SESSION"

# COSMIC hands the lock to a greetd session, so LockedHint can lag several
# seconds behind the request. Wait properly rather than declaring failure.
for _ in $(seq 1 120); do
  locked && break
  sleep 0.5
done

# COSMIC's LockedHint is not trustworthy: it has been observed going to yes
# seconds after the greeter is already up, and back to no before the session is
# fully restored. Do not treat a missing yes as "the lock never happened" -- the
# lock screen appears regardless. Wait for the window either way.
if ! locked; then
  echo "-- LockedHint never went to yes; COSMIC does not report it reliably."
  echo "   Locking happened anyway. Waiting out the window."
fi

echo "==> waiting for the unlock (up to 5 minutes)"
for _ in $(seq 1 300); do
  locked || { sleep 5; locked || break; }
  sleep 1
done

if locked; then
  echo "!! still locked after 5 minutes -- giving up on collecting a result"
  exit 3
fi

echo "==> unlocked"
sleep 2
sudo journalctl --since "$START" --no-pager \
     -u fprintd -t cosmic-greeter -t cosmic-comp -t systemd-logind \ 2>&1 |
     tee "lock-$LABEL.log" > /dev/null
sudo journalctl --since "$START" --no-pager 2>&1 | tee "lock-$LABEL-all.log" > /dev/null

echo
echo "===== did pam_fprintd run, and what did it say? ====="
awk '/fprintd|fingerprint|pam_fprintd|Verify|verify/ {
       sub(/^[A-Z][a-z]{2} +[0-9]+ [0-9:]+ [^ ]+ /, ""); print "    " $0 }' \
    "lock-$LABEL-all.log" | tail -40

echo
echo "===== authentication outcome ====="
awk '/pam_unix|pam_fprintd|Authenticat|auth could not|New session|unlock/ {
       sub(/^[A-Z][a-z]{2} +[0-9]+ [0-9:]+ [^ ]+ /, ""); print "    " $0 }' \
    "lock-$LABEL-all.log" | tail -20

echo
echo "wrote: lock-$LABEL.log lock-$LABEL-all.log"
