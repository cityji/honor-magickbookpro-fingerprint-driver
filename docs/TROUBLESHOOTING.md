# Troubleshooting

Work down the list; each step assumes the ones above it passed.

## Is the right library even loaded?

```bash
fprintd-verify & sleep 2; sudo awk '/fpc-a900|libfpcbep/' /proc/$(pidof fprintd)/maps
```

You want two lines, one for `/opt/fpc-a900/lib/libfprint-2.so.2.0.0` and one for
`/opt/fpc-a900/lib/libfpcbep.so`. Nothing means the systemd drop-in is not in
effect:

```bash
systemctl cat fprintd | tail -20        # should show 10-fpc-a900.conf
sudo systemctl daemon-reload && sudo systemctl restart fprintd
```

## `No devices available`

```bash
lsusb | awk '/10a5/'                    # is the sensor on the bus at all?
sudo journalctl -u fprintd -b | tail -40
```

If `lsusb` shows nothing, the sensor is not powered or not present, and no
software here can help. Some machines only power it after a full shutdown rather
than a reboot, and some hide it behind a BIOS setting.

If `lsusb` shows it but fprintd does not, the driver did not claim it — check
that your id is in `id_table`:

```bash
python3 - /opt/fpc-a900/lib/libfprint-2.so.2.0.0 <<'EOF'
import sys
d = open(sys.argv[1],'rb').read()
e = (0xa900).to_bytes(4,'little') + (0x10a5).to_bytes(4,'little')
print("10a5:a900 in id_table:", bool(d.count(e)))
EOF
```

## `fprintd` will not start after installing a prebuilt bundle

Almost always an ABI mismatch — the bundle was built against a different
glib/gusb/nss than your distro ships.

```bash
LD_LIBRARY_PATH=/opt/fpc-a900/lib ldd /opt/fpc-a900/lib/libfprint-2.so.2.0.0 | awk '/not found/'
```

Fix by building from source, which is the supported path anyway:

```bash
sudo ./uninstall.sh
./bootstrap.sh
```

## Enrollment "succeeds" but verify never matches

This is the exact failure this project was created to fix, so if you see it,
something is off with the relayout. Turn on debug logging:

```bash
sudo mkdir -p /etc/systemd/system/fprintd.service.d
printf '[Service]\nEnvironment=G_MESSAGES_DEBUG=all\n' |
  sudo tee /etc/systemd/system/fprintd.service.d/30-debug.conf
sudo systemctl daemon-reload && sudo systemctl restart fprintd
fprintd-enroll
sudo journalctl -u fprintd -b | awk '/relayout|tee_enroll|end_enroll/'
```

Healthy output, per sample:

```
fpc_img_msg_relayout: image message 11288 bytes for a 11264 byte image,
                      opened a 10 byte gap at offset 24 (recv_len 942 -> 952)
fpc_read_dead_pixels: fpc_tee_enroll -> 1, remaining 15 (0 accepted, 0 rejected)
```

Two failure shapes:

- **No `relayout` line at all.** The fixup disabled itself. Either the blob is a
  different build (check `md5sum /opt/fpc-a900/lib/libfpcbep.so` against
  `f7136fd774d5208e629bbeaa4974543a`) or your firmware declares a different
  prefix. Look for `total` in the `patches-debug/0008` instrumentation.
- **`fpc_tee_enroll -> 6` every time, `remaining` frozen.** The matcher is
  rejecting every image. `6` is `IMAGE_LOW_QUALITY`. If it is *every* sample with
  a frozen counter, it is a format problem, not a dirty finger — see
  `INVESTIGATION.md` section 17.

Remove the drop-in when done: `sudo rm /etc/systemd/system/fprintd.service.d/30-debug.conf`

## Some samples are rejected during enrollment

Normal. `remove-and-retry` means the matcher did not like that image — usually
`TOO_SIMILAR` (result 5), i.e. you pressed in the same spot twice. Move the
finger slightly between presses.

Note the matcher gives you **16 attempts, not 16 good samples** — `remaining`
counts calls, and rejections consume it. If you rack up too many rejections the
enrollment ends without enough data. Just enrol again.

## The lock screen never asks for a fingerprint

Check PAM first:

```bash
awk '/pam_fprintd/' /etc/pam.d/common-auth /etc/pam.d/system-auth 2>/dev/null
```

Nothing? Enable it:

```bash
sudo pam-auth-update                              # Debian/Ubuntu, tick Fingerprint
sudo authselect enable-feature with-fingerprint    # Fedora
```

If it *is* enabled and still nothing happens, note the default arguments:

```
auth [success=2 default=ignore] pam_fprintd.so max-tries=1 timeout=10
```

**Ten seconds, one attempt**, and several desktops — COSMIC among them — print no
"place your finger" prompt at all. So unless your finger is already moving when
the lock screen appears, the window closes silently and you get the password
field with no explanation. Confirm from the log:

```bash
sudo journalctl -b | awk '/VerifyStart|VerifyStop|verify-match/'
```

`VerifyStart` followed by `VerifyStop` exactly ten seconds later, with no capture
in between, is the timeout — not a hardware or matching failure. Widen it by
editing the `timeout=` value in `/etc/pam.d/common-auth`. Keep a backup, and
keep `pam_unix` behind it so a mistake cannot lock you out.

## `gkr-pam: no password is available for user`

Not an error. Fingerprint authentication produces no password, so the GNOME login
keyring cannot be unlocked with it. Applications that need the keyring will
prompt separately. This is inherent to fingerprint login everywhere, not specific
to this driver.

## Enrolling from a terminal fails with `Not Authorized`

Your desktop has no polkit agent running that can cover `fprintd-enroll`. On
COSMIC, neither `pkttyagent --process $$` nor the `$BASHPID` + `exec` variant gets
matched. Temporary rule:

```bash
sudo tee /etc/polkit-1/rules.d/49-fpc-test.rules > /dev/null <<EOF
polkit.addRule(function(action, subject) {
    if (action.id.indexOf("net.reactivated.fprint.device.") == 0 &&
        subject.user == "$USER")
        return polkit.Result.YES;
});
EOF
sudo systemctl restart polkit
```

**Remove it when you are done.** While it is in place, anything running as you
can enrol or delete fingerprints without authenticating.

```bash
sudo rm /etc/polkit-1/rules.d/49-fpc-test.rules && sudo systemctl restart polkit
```

Enrolling from your desktop's Settings UI needs no rule.

## The sensor disappears from the bus mid-use

```bash
sudo journalctl -k -b | awk '/10a5|usb 3-2/' | tail
```

If the device re-enumerates at a new address roughly one second after a capture,
you are running without `patches/0006`. That is the firmware watchdog firing on
an abandoned bulk transfer. Rebuild with the full patch set.

## Starting over

```bash
sudo ./uninstall.sh
sudo rm -rf /var/lib/fprint/$USER          # deletes enrolled fingerprints
rm -rf build dist                          # deletes the build tree
./bootstrap.sh
```

## Filing a useful bug report

Include:

```bash
lsusb -d 10a5: -v 2>/dev/null | head -40
md5sum /opt/fpc-a900/lib/libfpcbep.so
sudo journalctl -u fprintd -b | awk '/hwid|relayout|tee_enroll|end_enroll|verify/'
```

The `hwid(...)` line and the `total` from the relayout log are the two numbers
that identify a new variant of this hardware.
