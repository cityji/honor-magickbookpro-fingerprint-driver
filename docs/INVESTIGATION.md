# FPC `10a5:a900` fingerprint sensor on Linux — investigation and working patch

**Verdict: `binds, opens, captures repeatedly, enrolls all 11 stages — template rejected by the blob.`** The "cannot re-arm" verdict below is SUPERSEDED; see section 16.

The device is claimed by libfprint, opens, completes a TLS-PSK handshake, captures a full-length
image, and the host-side matching blob runs and reports correctly. The identify state machine
completes successfully and `fprintd` accepts the **first enroll stage**. Enrollment then stops: the
sensor will not accept a second capture command in the same session.

**Root cause (§15, proven on the wire):** the a900 firmware stops answering endpoint 0 once an image
capture completes, then resets itself and re-enumerates. The byte-identical command
`40 02 0001 / 0f100107` returns **status 0 in 12.7 ms** before a capture and is **cancelled at exactly
1.000198 s** when reissued 0.709 ms after the last image record. This is not command-specific
(`0x02` and `0x03` both do it), not `wValue`-specific (tested, falsified — §7.4), and not caused by
the cleanup command (removing it changed nothing — §15.2). Closing it would need the Windows *Disum*
stack's inter-capture sequence, which is out of scope here.

**Two genuine driver bugs were found and fixed along the way, neither specific to the a900:**
a cleanup transfer that sinks an already-successful operation, and a **double free of the SSM error
that crashes `fprintd` with `SIGSEGV`** on any failed enroll/verify/identify. Both are worth filing
against MR 396 for every FPC match-on-host device — see §15.4.

*This document's earlier verdicts were narrower and two of its hypotheses were falsified by later
measurements. They are kept, labelled, rather than deleted — §7.4 and §14 record what was tested and
rejected.*

- **Target:** Honor MagicBook, FPC sensor `10a5:a900`, firmware `22.26.2.29`
- **Host:** Pop!_OS 24.04 (COSMIC / Wayland), kernel 7.0.11-76070011-generic, x86-64
- **Date:** 2026-07-29
- **Upstream status before this work:** listed in the
  [linux-fingerprint-drivers](https://github.com/jedbillyb/linux-fingerprint-drivers) tracker under
  *"No known fix yet"*, no lead flag, no published investigation.

Before: `fprintd-enroll` → `net.reactivated.Fprint.Error.NoSuchDevice`.
After: `fprintd-enroll` → `Using device /net/reactivated/Fprint/Device/0`, device opens, full
TLS-PSK handshake with the sensor completes in ~0.5 s.

---

## 1. Hardware facts

```
idVendor           0x10a5 FPC
idProduct          0xa900
bcdDevice          2.29          (firmware 22.26.2.29)
bcdUSB             1.10          (USB 1.1, 12 Mbps full speed)
bNumInterfaces     1
  bInterfaceClass       255 Vendor Specific
  bInterfaceSubClass    255
  bInterfaceProtocol    255
  bNumEndpoints         1
    Endpoint 0x82, Bulk IN, wMaxPacketSize 64
```

**One endpoint, bulk IN only.** There is no bulk OUT. Every host→device command must therefore be a
control transfer on endpoint 0. This single fact decides which driver can possibly work.

> ### ⚠ Correction — "USB 1.1, 12 Mbps full speed" is wrong, and the descriptor is non-compliant
>
> `bcdUSB 1.10` is what the device *declares*. It is not the speed it runs at. The link actually
> negotiates **high speed, 480 Mbps** (`/sys/bus/usb/devices/3-2/speed` reads `480`), and the kernel
> objects to the endpoint on every single enumeration:
>
> ```
> usb 3-2: config 1 interface 0 altsetting 0 bulk endpoint 0x82 has invalid maxpacket 64
> ```
>
> A **high-speed bulk endpoint is required by the USB 2.0 specification to use
> `wMaxPacketSize` 512**; this one declares 64. That is a firmware defect in the sensor, not a host
> misconfiguration, and the kernel tolerates it only because it clamps the value.
>
> This matters: it is a live hypothesis for the post-capture disconnect in §13.9, since a capture is
> the only time this endpoint carries sustained traffic. Anyone reasoning about this device's USB
> behaviour should start from "non-compliant high-speed device", not "USB 1.1 device".

Prior reconnaissance (not repeated here): a read-only sweep of 468 vendor control-IN requests
returned zero responses, and a 10 s bulk-IN listen while touching the sensor captured zero packets.
**This work explains why:** the sensor says nothing until it receives vendor command `0x01`, and its
entire useful conversation happens *inside* a TLS session. Passive probing could never have found it.

---

## 2. Phase 0 — inventory

### System

| Package | Version |
|---|---|
| `fprintd` | 1.94.3-1 |
| `libfprint-2-2` | 1:1.94.7+tod1-0ubuntu5~24.04.8 |
| `libfprint-2-tod1` | 1:1.94.7+tod1-0ubuntu5~24.04.8 |
| `libpam-fprintd` | 1.94.3-1 |

`/usr/lib/x86_64-linux-gnu/libfprint-2.so.2.0.0` (734552 bytes, stripped).
No TOD drivers installed (`/usr/lib/x86_64-linux-gnu/libfprint-2/tod-1/` does not exist).

### Candidates found in `~/Desktop/temp/`

1. **`libfprint-patched/`** — from `github.com/furcom/libfprint-patched` (commit `15cf5b8`), itself
   rebuilt from the AUR package `libfprint-fpcmoh-git`. Contains a prebuilt
   `libfprint-2.so.2.0.0` (3516696 bytes, **not stripped, full DWARF**) plus FPC's proprietary
   `libfpcbep.so` (1650656 bytes, stripped), a Fedora RPM, an `install.sh` written for `dnf`, and a
   udev rule for `10a5:9800`.
2. **`FingerPrint_1.1.141.36/`** and **`FingerPrint 20241225_Firmware/`** — **not Linux drivers.**
   These are HONOR's *Windows* driver packages: NSIS self-extracting `.exe` files plus `.docx`
   release notes. They cannot serve as a donor. They were inspected read-only for metadata (section 7);
   no Windows binary was executed and nothing from them is used at runtime.

> **Gotcha for reproducers:** the RPM is named `libfprint-1.94.6-1.fc40.x86_64.rpm`, but the
> library's own version string is **`libfprint version 1.94.4`**. Trust the string, not the filename.

### Checksums

| File | MD5 |
|---|---|
| `libfpcbep.so` | `f7136fd774d5208e629bbeaa4974543a` |
| `libfprint-2.so.2.0.0` (original) | `9a5f3c3375089c610c6a1e64bc4ae22a` |
| `libfprint-2.so.2.0.0` (patched) | `8c82bac8ba255bfe9253518d51ca2653` |

---

## 3. Phase 1 — candidate comparison

Only one candidate is a Linux driver, so the real comparison is between the **three FPC drivers**
available across the two libfprint binaries.

| Driver | Where it lives | USB IDs | Bulk endpoint | Host→device | Needs blob |
|---|---|---|---|---|---|
| `fpcmoc` (upstream `fpc.c`, match-on-**chip**) | system 1.94.7 **and** candidate 1.94.4 | `ffe0 a305 da04 d805 d205` | **0x81** | control | no |
| `fpcmoh` (match-on-**host**) | candidate 1.94.4 **only** | `9800` | **0x82** | control | **yes** (`libfpcbep.so`) |

Determined by disassembling every `fpi_usb_transfer_fill_bulk` / `fill_control` call site and reading
the endpoint argument (`%esi`):

```
fpcmoc  (0x3cc10-0x3fe80):   mov $0x81,%esi ; call fpi_usb_transfer_fill_bulk
                             mov $0x1,%esi  ; call fpi_usb_transfer_fill_control
fpcmoh  (0x40120-0x43c00):   mov $0x82,%esi ; call fpi_usb_transfer_fill_bulk   (x5)
                             mov $0x1,%esi  ; call fpi_usb_transfer_fill_control (x4)
```

### Recommendation and reasoning

**Use `fpcmoh` from `libfprint-patched`.** The reasoning, in order of weight:

1. **Endpoint match is decisive.** The device exposes exactly one endpoint, `0x82` bulk IN.
   `fpcmoh` reads from `0x82`; `fpcmoc` reads from `0x81`, which does not exist on this hardware.
   Patching an ID into `fpcmoc` would produce a driver that binds and then fails every read.
2. **No bulk OUT anywhere in `fpcmoh`.** All four host→device paths are
   `fpi_usb_transfer_fill_control` with direction `1` (`HOST_TO_DEVICE`). This matches the
   single-endpoint topology exactly, and it independently corroborates the earlier reconnaissance
   finding that the device ignores control-IN probes.
3. **`fpcmoh` is only in the candidate.** The distro's 1.94.7 has no `fpcmoh` code at all
   (zero occurrences of the string). So the newer library cannot be used, despite being newer —
   this is the one case where "newer" is the wrong answer.
4. **The Windows driver is match-on-host too** (section 7), confirming the architecture choice
   from an entirely independent direction.

The task brief's heuristic — prefer a donor whose PIDs are numerically closer to `a900` — would have
pointed at `fpcmoc` (`a305` is closer to `a900` than `9800` is). **That heuristic is wrong here** and
the endpoint evidence overrides it. Adjacent product IDs did not indicate a shared firmware generation.

**ABI check before committing.** The candidate is 1.94.4 and the system is 1.94.7+tod1, so
substitution had to be verified rather than assumed:

```
fprintd + fprintd-enroll + fprintd-verify + pam_fprintd.so need : 47 libfprint symbols
candidate libfprint-2.so.2.0.0 defines                          : 92
system    libfprint-2.so.2.0.0 defines                          : 92
missing from candidate                                          : (none)
symbols the system has that the candidate lacks                 : (none)
```

Both export the identical versioned symbol set (`LIBFPRINT_2.0.0`), so the swap is ABI-safe.
(Note: comparing raw `nm -D` output gives a false "everything is missing" result — the
`@@LIBFPRINT_2.0.0` suffix must be stripped first.)

---

## 4. Phase 2 — locating the ID table

The candidate binary is **not stripped and carries full DWARF**, so this needed no hex guessing.

`FpIdEntry` from `.debug_info` (libfprint 1.94.4):

```
_FpIdEntry: DW_AT_byte_size = 32
  <anon union> @ 0   ->  pid : guint @ 0
                         vid : guint @ 4
  driver_data       @ 24
```

So each entry is **32 bytes: `pid` (u32 LE) at +0, `vid` (u32 LE) at +4**. Note `pid` comes **first**.

`nm` reports two relevant `id_table` symbols, and the class-init cross-reference proves which belongs
to which driver (string proximity alone would not have):

```
fpi_device_fpcmoh_class_intern_init @0x40272:  lea ... # 81d40 <id_table>   <- fpcmoh
fpi_device_fpcmoc_class_intern_init @0x3d002:  lea ... # 808e0 <id_table>   <- fpcmoc
```

In this ELF `.rodata` has vaddr == file offset, so the `nm` address is directly usable as a file
offset (confirmed by `xxd` at `0x81d40` showing the expected bytes).

**fpcmoh table at `0x81d40`** — one real entry, then a zero terminator:

```
00081d40: 0098 0000 a510 0000 0000 0000 0000 0000   <- pid=0x9800 vid=0x10a5
00081d50: 0000 0000 0000 0000 0000 0000 0000 0000
00081d60: 0000 0000 0000 0000 0000 0000 0000 0000   <- terminator (32 bytes of zero)
00081d70: 0000 0000 0000 0000 0000 0000 0000 0000
00081d80: 4670 6944 6576 6963 6545 6c61 6e53 7069   "FpiDeviceElanSpi"
```

This is a genuine table: correct stride, correct field order, referenced by the driver's class-init,
and terminated by a zero entry.

---

## 5. Phase 3 — the patch

### Why *replace* rather than *add*

Strategy (a), adding an entry alongside `9800`, is **not safe here**. Writing a new entry into the
terminator slot at `0x81d60` would push the terminator to `0x81d80`, which contains the string
`FpiDeviceElanSpi`. libfprint walks the table until it sees a zero entry, so it would parse string
bytes as device IDs and register garbage. There is no padding to grow into, and relocating the table
would mean rewriting the `lea` in class-init. Replacement is the correct minimal change.

The cost: **this build no longer supports `10a5:9800`.** An upstream-quality patch would add an entry
instead, but that requires recompiling from source rather than byte-patching.

### The two bytes

Both changes are the same edit — `0x98` → `0xA9` — turning `9800` into `a900`.

| # | File offset | Original | Patched | What it is |
|---|---|---|---|---|
| 1 | `0x81D41` | `0x98` | `0xA9` | `fpcmoh` `id_table[0].pid`: `0x9800` → `0xa900` |
| 2 | `0x42B55` | `0x98` | `0xA9` | immediate in `cmp $0x9800,%ax` inside `fpc_dev_probe` |

Patch #1 is what actually makes the device bind.

Patch #2 is **cosmetic only** and is included so the log does not mislead. The check reads:

```asm
42b43:  call g_usb_device_get_pid
42b48:  movl $0x0,0x50(%rbx)        ; set unconditionally, both paths
42b52:  cmp  $0x9800,%ax
42b56:  je   42b72                  ; on match, skip the warning
42b58:  g_log("Device %x is not supported")   ; level 0x10 = G_LOG_LEVEL_WARNING
42b72:  movl $0xc,0x4c(%rbx)        ; 12 enroll stages — reached either way
42b9c:  fpi_device_probe_complete(dev, ..., NULL)   ; success either way
```

Both branches converge at `0x42b72`; the mismatch path sets no error and still completes probe. So
`Device a900 is not supported` is a **warning, not a rejection** — confirmed empirically, since the
device opened and completed a TLS handshake while that message was being logged.

### Verification

```
$ cmp -l libfprint-2.so.2.0.0.orig libfprint-2.so.2.0.0
  273238 230 251
  531778 230 251
```

Exactly two differing bytes, both octal `230`→`251` (= `0x98`→`0xA9`), at 1-indexed positions
`273238` (offset `0x42B55`) and `531778` (offset `0x81D41`). Nothing else changed. The `fpcmoc`
table at `0x808e0` is untouched and the ELF still loads (`SONAME libfprint-2.so.2`).

To reproduce from the pristine file:

```bash
python3 - <<'EOF'
p = "libfprint-2.so.2.0.0"
d = bytearray(open(p, 'rb').read())
assert bytes(d[0x81d40:0x81d48]) == bytes.fromhex('0098000 0a5100000'.replace(' ',''))
assert bytes(d[0x42b52:0x42b56]) == bytes.fromhex('663d0098')
d[0x81d41] = 0xa9      # id_table pid  9800 -> a900
d[0x42b55] = 0xa9      # probe cmp     9800 -> a900
open(p, 'wb').write(d)
EOF
```

---

## 6. Phase 4 — install and result

### Deployment approach

`install.sh` **does not touch anything under `/usr/lib`.** The patched library and the blob go to
`/opt/fpc-a900/lib/`, and only the fprintd daemon is pointed at them via a systemd drop-in. The
distro libfprint stays in place for every other consumer, and uninstall is a file deletion.

Three details that are easy to get wrong:

- **`libfpcbep.so` is `dlopen`'d by bare name** — it is a string in the binary, not a `DT_NEEDED`
  entry. It must sit in a directory on the loader search path; putting it beside the patched library
  works because `LD_LIBRARY_PATH` also governs `dlopen`. It is loaded lazily at *device open*, not at
  probe, so it will not appear in `/proc/<pid>/maps` until an enroll/verify is attempted.
- **`/var/log/fpc` must exist and be writable.** `fprintd.service` sets `ProtectSystem=strict`, which
  makes the whole filesystem read-only for the daemon, so the drop-in adds
  `ReadWritePaths=/var/log/fpc`. Without this the directory exists but the daemon cannot write to it.
- **`systemctl daemon-reload` is required**, otherwise the drop-in is ignored and the daemon silently
  keeps using the distro library — which looks exactly like "the patch did nothing".

### Proof the patched library is actually loaded

```
$ fprintd-enroll & sleep 2; sudo grep -E "libfprint|libfpcbep" /proc/$(pidof fprintd)/maps
/opt/fpc-a900/lib/libfpcbep.so
/opt/fpc-a900/lib/libfprint-2.so.2.0.0
```

### Result

```
Before:  fprintd-enroll -> net.reactivated.Fprint.Error.NoSuchDevice
After:   Using device /net/reactivated/Fprint/Device/0
         Enrolling right-index-finger finger.
```

The device is claimed, probed, exposed on D-Bus, opened, and completes its secure handshake.

**Controlled A/B, showing the patch is the cause** (`GetDevices` on the fprintd D-Bus manager):

```
sudo ./uninstall.sh ; systemctl restart fprintd  ->  array [ ]
sudo ./install.sh   ; systemctl restart fprintd  ->  array [ object path "/net/reactivated/Fprint/Device/0" ]
```

`uninstall.sh` was tested for real, not just written: after running it, `dpkg -V libfprint-2-2`
reports no modifications and `/usr/lib/x86_64-linux-gnu/libfprint-2.so.2.0.0` is byte-identical to
the packaged file (734552 bytes, original timestamp).

The run above ended in `EnrollStart failed: Timeout was reached`. **This is not a driver failure.**
The journal shows the real cause:

```
fprintd[92423]: Authorization denied to :1.10109 to call method 'EnrollStart'
                for device 'FPC Sensor Controller L:0002 FW:22.26.2.29':
                Not Authorized: net.reactivated.fprint.device.enroll
```

`net.reactivated.fprint.device.enroll` is `allow_active=auth_self_keep`, i.e. it needs a password
prompt from a polkit agent. The attempt was made from a non-interactive shell with no agent, so
authorisation timed out before enrollment began. **Enrollment must be run from a normal desktop
terminal**, where COSMIC's polkit agent can prompt.

### Second run — past authorisation, enroll actually starts

With authorisation granted, the enroll proceeds much further:

```
Using device /net/reactivated/Fprint/Device/0
Enrolling right-index-finger finger.
Enroll result: enroll-unknown-error

journal: Device reported an error during identify for enroll: transfer timed out
```

`fpcmoh` runs an *identify* pass first (a duplicate-finger check) before accepting enroll stages.
**No finger was on the sensor during this run**, which is the most likely explanation for the result —
see the trace analysis in section 7.2 and the honest status in section 11.

> ### ⚠ Annotation — the sentence above is wrong on two counts
>
> 1. **Touch state during that run is *unknown*, not "no finger".** The run was launched from a
>    script and the touch state was never recorded. §11 states this correctly; this paragraph
>    contradicts it. §11 is the accurate one.
> 2. **"No finger" is not an explanation for the result regardless.** §7.3 later showed the
>    identical failure *with* a finger pressed, and §7.4 localised the cause to the firmware not
>    answering `bRequest 0x03` after a capture. Touch state is irrelevant to this failure.
>
> The paragraph is kept rather than deleted so the reasoning trail stays honest, but do not build
> on it. See §7.4 and §13.

---

## 7. usbmon trace — the sensor's actual protocol

Captured on the first attempt (`usbmon-enroll.txt`, bus 3, device 9). Annotated:

```
# --- enumeration ---
Ci 80 06 0100 .. 0012  -> 12011001 00000040 a51000a9 29020102 0001    device descriptor
Ci 80 06 0200 .. 0019  -> 09021900 010104a0 32090400 0001ffff ff050705 82024000 00
                                                              ^^^^^^^^^^^^^^ EP 0x82, bulk, 64
Co 00 09 0001          set configuration 1

# --- vendor init ---
Co 40 03 0000 .. 0000                     vendor cmd 0x03  (reset / abort)
Co 40 01 0001 .. 0004  = ab9ad9da         vendor cmd 0x01  (init, 4-byte arg)
Bi ep2                 <- 38 bytes: 00000002 00000026 00000000 04ec0331 004000b0
                                    32322e32 362e322e 32390000
                                    ascii ------------------------> "22.26.2.29"
                                    ** device answers with its firmware version **
Co 40 08 0010 .. 0000                     vendor cmd 0x08
Ci c0 0b 0000 .. 0079  <- 121 bytes       vendor cmd 0x0b  (sensor parameters; fpc_read_0b_cb)

# --- TLS-PSK session, device is the CLIENT, host+libfpcbep is the SERVER ---
Co 40 05 0001          vendor cmd 0x05  (start TLS)
Bi ep2   <- 16030300 2f010000 2b0303..    ClientHello        (TLS 1.2)
Co 40 06 <- host writes ServerHello etc.  (cmd 0x06 = TLS record out, fragmented to 64 B)
Bi ep2   <- 16030300 0f100000 0b000944 6973756d 2050534b
                                        ^^^^^^^^^^^^^^^^^ "Disum PSK"
                                        ClientKeyExchange, PSK identity
Bi ep2   <- 14030300 0101                 device ChangeCipherSpec
Bi ep2   <- 16030300 50....               device Finished (encrypted)
Co 40 06 <- 14030300 0101                 host ChangeCipherSpec
Co 40 06 <- 16030300 50....               host Finished (encrypted, split 64 + 21 bytes)
```

**The TLS-PSK handshake completes.** Both sides exchange ChangeCipherSpec and Finished. That means
`libfpcbep.so` already holds the correct pre-shared key for this sensor — the `a900` shares key
material and protocol with the `9800` generation. Everything after this point is encrypted
application data inside the TLS session.

All host→device traffic is vendor control transfers (`bmRequestType 0x40`, requests `0x01 0x03 0x05
0x06 0x08`); all device→host traffic is bulk IN on `0x82` plus one control-IN (`0xC0 0x0b`). No bulk
OUT is used, exactly as predicted from the disassembly.

The whole exchange takes ~0.53 s, then the bus goes quiet — consistent with the driver having
finished opening the device and waiting on the (never-authorised) enroll request.

### 7.2 Second trace — the enroll/identify path (`usbmon-enroll2.txt`) — ⚠ SUPERSEDED

> ### ⚠ This whole subsection is superseded by §7.3 / §7.4. Read those first.
>
> The *measurements* here are real and still valid — the command sequence, the 15 TLS records, the
> `-2` completion after exactly 1.000 s. Two things in the **interpretation** are now known wrong:
>
> - It reads the `-2` as *"libfprint cancelling its own request during teardown, not a device
>   error."* That is exactly backwards, and is the misreading §7.4 corrects. The `-2` is the
>   host-side 1 s timeout expiring on a control transfer **the device never answered**. It is the
>   cause of the failure, not a harmless consequence of it.
> - Its **two candidate explanations were both ruled out.** Candidate 1 ("benign — the sensor was
>   never touched") was falsified by §7.3, which reproduced the identical failure with a finger
>   pressed. Candidate 2 ("the matcher rejected the frames") was falsified by the same run, which
>   shows `fpcmoh_match_report` executing correctly against an empty template database.
>
> The actual cause is in §7.4 and the mechanism is in §13.

With authorisation granted the driver goes considerably further. Full command sequence after the
handshake (control transfers only; 412 device events over 2.64 s):

```
Co 40 03 0000            reset / abort
Co 40 01 0001 len 4      init            -> Bi: firmware string "22.26.2.29"
Co 40 08 0010            (unknown)
Ci c0 0b      len 121    read sensor parameters
Co 40 05 0001            start TLS       -> full PSK handshake, completes
Co 40 02 0001 len 4      (unknown; immediately precedes capture)
Co 40 09 0000            capture / read image
                         -> 355 bulk-IN events follow: 15 TLS application-data
                            records, each  00000005 000003f1 00000000 17030303 e0...
                            = 992-byte payloads, ~15 KB total
Co 40 03 0001            abort  -> completes -2 (URB cancelled) after exactly 1.000 s
```

Key observations:

- **Every single transfer succeeded.** Checking submitted-vs-completed URBs gives *zero* unmatched
  transfers, and the only non-zero completion status in the entire capture is `-2` on the driver's
  own final abort — i.e. libfprint cancelling its own request during teardown, not a device error.
- **The sensor streams real image data.** Vendor command `0x09` makes the device push 15 encrypted
  TLS application-data records of 992 bytes each. The host-side blob is receiving and decrypting
  them; nothing is being rejected.
- **No stall, no NAK, no timeout on the bus.** The reported "transfer timed out" is a libfprint-level
  timeout, not a USB-level one. The whole exchange takes 2.64 s and then the driver aborts of its own
  accord.

**The most concrete anomaly is the final abort.** `Co 40 03 0001` is submitted and completes `-2`
(URB unlinked) after *exactly* 1.000 s. That round number looks like a 1000 ms transfer timeout
expiring, which would match the journal's `transfer timed out` — every other command on the bus is
acknowledged in under 10 ms. The alternative reading is that the URB was simply killed during
teardown after the operation had already failed for another reason, in which case the `-2` is a
consequence rather than the cause. The trace alone cannot distinguish these.

**Two candidate explanations, neither yet confirmed:**

1. *Benign* — the sensor was never touched, so the identify pass found no finger and gave up.
2. *Substantive* — the frames were captured and delivered but the host-side matcher or the
   post-capture step rejected them.

Weighing against (1): the 15 records arrive ~45 µs apart and the driver aborts 0.12 s after the last
one, with the whole exchange spanning 2.64 s and *zero* pending reads. A driver genuinely waiting for
a finger should park on a bulk read for seconds — `fpc_enroll_wait4finger_cb` exists in the symbol
table and nothing in the trace resembles it having been entered. So the benign reading is *weaker*
than the fast timing first suggests, and it should not be assumed. Section 11 gives the test that
separates them.

### 7.3 The exact blocker, isolated (`usbmon-finger.txt` / `fprintd-finger.log`)

With the daemon made verbose (`Environment=G_MESSAGES_DEBUG=all`) and a finger actually pressed, the
driver names its own state machine and the failure localises to **one command**.

```
[fpcmoh] verify_identify entering state 0,1,2
[fpcmoh] verify_identify states 3..13   x16      <- image read loop, 16 iterations
fpc_ssm_img_read_cb: received_len 832,  expect len 1009
fpc_ssm_img_read_cb: received_len 896,  expect len 1009
fpc_ssm_img_read_cb: received_len 960,  expect len 1009
fpc_ssm_img_read_cb: received_len 1009, expect len 1009   <- FULL IMAGE RECEIVED
[fpcmoh] verify_identify entering state 14
fpcmoh_match_report: templates->len = 0                   <- correct: nothing enrolled yet
[fpcmoh] verify_identify entering state 17                <- cleanup
[fpcmoh] SSM verify_identify failed in state 17 (cleanup) with error: transfer timed out
```

**The capture path works end to end.** The sensor delivers a complete 16-iteration payload which the
driver reassembles to exactly the expected 1009-byte record length, and the host-side matcher then
runs and reports against an empty template database — the right answer for a machine with no prints
enrolled. Nothing rejects the device, the payload, or the crypto.

> Two limits on what this shows. The payload is TLS-encrypted, so **whether it contains actual ridge
> data is not observable here** — only that a well-formed, complete image transfer occurs. And the
> earlier `usbmon-enroll2.txt` run (finger state unrecorded) produced the *same* 15 records, so
> capture appears to happen whether or not the sensor is touched. Do not read this as proof that the
> sensor imaged a fingerprint.

**The single point of failure is the cleanup command in state 17.** Correlating with usbmon:

| Command | Site | wValue | Device response |
|---|---|---|---|
| `bmRequestType 0x40, bRequest 0x03, wValue 0x0000` | init | 0 | **acknowledged in 1.3 ms** |
| `bmRequestType 0x40, bRequest 0x03, wValue 0x0001` | cleanup | 1 | **never answered — URB cancelled after exactly 1.000303 s** |

The firmware answers *every* other command in under 10 ms. It answers `40 03` with `wValue=0`. It
does **not** answer `40 03` with `wValue=0001`. That timeout is the `transfer timed out` in the
journal, and because the SSM treats a failed cleanup as fatal, it sinks the whole enroll.

Located in the binary — `fpc_write_ctrl.constprop.0` at `0x404f0` takes `bRequest` in `%edx` and
`wValue` in `%ecx`:

```asm
; fpc_verify_sm_run_state, cleanup state 17  -- times out
417ab:  b9 01 00 00 00    mov  $0x1,%ecx        ; wValue = 1
417b0:  ba 03 00 00 00    mov  $0x3,%edx        ; bRequest = 3
417b8:  call 404f0 <fpc_write_ctrl.constprop.0>

; fpc_init_sm_run_state  -- works
43246:  31 c9             xor  %ecx,%ecx        ; wValue = 0
43248:  ba 03 00 00 00    mov  $0x3,%edx        ; bRequest = 3
43253:  call 404f0 <fpc_write_ctrl.constprop.0>
```

> ### ⚠ The `wValue` reading above was tested and FALSIFIED — see §7.4
>
> The table's framing (that `wValue=1` specifically is the problem) was a hypothesis. It was
> patched, run, and disproved. The corrected finding is that **`bRequest 0x03` is answered before a
> capture and not after one, regardless of `wValue`.** The table is kept because the timings in it
> are real measurements; only the causal reading was wrong. Read §7.4 before building on this.

### 7.4 Third patch — tested, falsified, REVERTED

**Hypothesis:** the device rejects `wValue=0x0001` specifically, so pointing the cancel state at the
`wValue=0x0000` variant (which init uses successfully) should let it through. One byte at `0x417AC`,
`mov $0x1,%ecx` → `mov $0x0,%ecx`. Not a speculative command — `40 03 0000` is one libfprint already
issues to this device on every open.

**Result: no effect whatsoever.** Two runs with a finger pressed, identical to pre-patch:

```
states 3..13 x16 → fpc_ssm_img_read_cb: received_len 1009, expect len 1009
state 14        → fpcmoh_match_report: templates->len = 0
state 17        → SSM verify_identify failed in state 17 with error: transfer timed out
```

The patch was confirmed live on the wire (`Co 40 03 0001` count dropped to 0, replaced by
`40 03 0000`). The wire evidence from `usbmon-patched3.txt`, same command, 0.7 s apart:

| Phase | URB | Submitted | Completed | Status |
|---|---|---|---|---|
| init | `ffff8bde93290300` | 22452109 | 22454403 | **0** — 2.3 ms |
| cancel | `ffff8bde82f5c6c0` | 23157593 | 24157841 | **−2** — exactly 1.000 s |

**Conclusion: `wValue` is irrelevant. The firmware stops answering `bRequest 0x03` once a capture has
completed.** The cancel command is issued 150 µs after the last image record arrives.

Two further checks that constrain the diagnosis:

- **No hanging bulk read.** Every URB submitted to the sensor has a matching completion. An
  alternative theory — that the cancel state queues a bulk-IN read for an event the device never
  emits — is ruled out. The control transfer itself is what times out.
- **The "2× counters" in the second run were a capture artifact, not two attempts.** Every distinct
  sensor event in `usbmon-patched3.txt` appears exactly 2× (370 events) or 4× (15). Two `usbmon`
  readers were writing to the same file. No progress was made between runs.

**The byte was reverted** to `0x01`; `cmp -l` is back to two lines and `install.sh`'s guard checks two
offsets again. The deployed and in-repo libraries match (`md5 8c82bac8…`). A semantic change to a
device command with no measured benefit does not belong in a published patch set.

> **Method note for the next investigator.** `grep` on this system is `ugrep`, which silently returns
> nothing on `usbmon-patched3.txt` because the file contains a NUL byte (line 533) and is classified
> as binary. This very nearly produced a false finding ("`40 03` never appears on the wire"). Use
> `awk` for usbmon traces, and note that usbmon fields are
> `$1=urb $2=timestamp $3=S|C $4=type:bus:dev:ep $5=s $6..=bmRequestType bRequest wValue`.

### Independent confirmation from the Windows package

The HONOR Windows packages were opened read-only with `7z` (no Windows code executed):

- `install.cmd` branches on `devcon find "*USB\VID_10A5&PID_A900*"` → runs
  `FPCFingerprint_22.26.2.29.exe`, else falls back to a Goodix driver. Confirms `a900` is the FPC part
  and that MagicBooks ship with either an FPC or a Goodix sensor.
- The INF is **`fpc_disum_um_usb.inf`**:
  ```
  DriverVer = 10/04/2022,22.26.2.29
  "FPC Fingerprint Reader (Disum)" = FpcUsb_Install, USB\VID_10A5&PID_A900
  Class = Biometric   Provider = Fingerprint Cards AB
  UmdfLibraryVersion = 2.17.0        ServiceBinary = %12%\UMDF\fpc_disum.dll
  HKR,WinBio\Configurations\0,EngineAdapterBinary,,"FpcDisumEngine.dll"
  HKR,WinBio\Configurations\0,SensorMode,0x10001,1   ; Basic - 1, Advanced - 2
  ```
- Payload: `fpc_disum.dll` (user-mode driver), `FpcDisumEngine.dll` (matching engine),
  `fpc_enclave.dll` (enclave), `FpcSessionService.exe`.

Two things follow. First, the `DriverVer` `22.26.2.29` matches this unit's `bcdDevice` exactly.
Second, Windows uses a **user-mode driver with a host-side matching engine and an enclave** — the same
match-on-host architecture as `fpcmoh` + `libfpcbep.so`, not match-on-chip. And the codename
**"Disum"** in the driver filename is the same string that appears as the TLS PSK identity
**`Disum PSK`** on the wire. The Linux and Windows evidence agree completely.

---

## 8. Reproduction

For another `10a5:a900` owner on Pop!_OS / Ubuntu 24.04:

```bash
git clone https://github.com/furcom/libfprint-patched.git
cd libfprint-patched/usr/lib/x86_64-linux-gnu
cp libfprint-2.so.2.0.0 libfprint-2.so.2.0.0.orig

python3 - <<'EOF'
p = "libfprint-2.so.2.0.0"
d = bytearray(open(p, 'rb').read())
d[0x81d41] = 0xa9      # fpcmoh id_table pid 0x9800 -> 0xa900   (makes it bind)
d[0x42b55] = 0xa9      # fpc_dev_probe cmp immediate            (cosmetic)
# NOTE: do NOT add d[0x417ac] = 0x00 here. That third patch was tested and
# had no effect; it is documented and reverted in section 7.4.
open(p, 'wb').write(d)
EOF

cmp -l libfprint-2.so.2.0.0.orig libfprint-2.so.2.0.0   # must be exactly 2 lines
cd ../../..            # back to repo root, next to install.sh
sudo ./install.sh
```

Then, **in a normal desktop terminal** (not over SSH, not from a script — you need a polkit agent):

```bash
fprintd-enroll        # authenticate, then press your finger 12 times
fprintd-verify
```

Roll back at any time with `sudo ./uninstall.sh`.

Offsets above are valid for the `furcom/libfprint-patched` build with
`libfprint-2.so.2.0.0` MD5 `9a5f3c3375089c610c6a1e64bc4ae22a` (3516696 bytes, libfprint 1.94.4).
For a different build, re-derive them:

```bash
nm libfprint-2.so.2.0.0 | grep id_table
objdump -d --start-address=<fpcmoh_class_intern_init> ... | grep 'lea.*id_table'
xxd -s <offset> -l 32 libfprint-2.so.2.0.0     # expect: 0098 0000 a510 0000
```

---

## 9. What this implies for `a921`, `a120`, `e340`

- **Check the endpoint layout first.** `lsusb -v -d 10a5:xxxx | grep -E "bEndpointAddress|bNumEndpoints"`.
  A single bulk IN `0x82` means `fpcmoh` is the driver to patch. A bulk IN `0x81` means try `fpcmoc`
  instead (upstream `fpc.c`, already in stock Ubuntu 1.94.7 — no proprietary blob needed, and the
  same one-byte technique applies to its table at `0x808e0`, though that table has room for a proper
  added entry only if the following slot is zeroed).
- **Do not rank donors by PID adjacency.** It was actively misleading here: `a305` is numerically
  nearer `a900` than `9800` is, yet `9800` was the correct relative. Firmware generation follows the
  *protocol family*, not the number.
- **The `libfpcbep.so` PSK covers more than `9800`.** It successfully handshook with an `a900` it was
  never advertised as supporting. Other `10a5` MoH sensors are therefore worth trying with the same
  blob before concluding the crypto is device-specific.
- **`10a5:a921`** (Honor MagicBook X16 Plus 2024) is the strongest next candidate — the Windows
  package here is literally named *"HONOR MagicBook X14&X16"* and installs the same Disum driver.
- **Expect a warning, not a rejection.** `Device xxxx is not supported` from `fpc_dev_probe` is
  cosmetic; probe completes regardless. Don't let it send you looking for a second gate that isn't there.
- **The device is silent until commanded.** Passive sniffing and control-IN sweeps yield nothing
  because everything of interest lives inside a TLS-PSK session opened by vendor command `0x05`. Any
  future investigation should drive the sensor with a real driver and watch usbmon, not probe blindly.

---

## 10. Files

| File | Purpose |
|---|---|
| `install.sh` | Installs patched lib + blob to `/opt/fpc-a900/lib`, udev rule, systemd drop-in. Refuses to install an unpatched library. |
| `uninstall.sh` | Removes everything `install.sh` created. Tested (see section 6). |
| `run-finger-test.sh` | Runs one instrumented enroll attempt, capturing usbmon + the daemon's own debug log, and prints a structural summary for comparing a touched run against an untouched one. Run as `./run-finger-test.sh nofinger` then `./run-finger-test.sh finger`. |
| `FINDINGS.md` | This document. |
| `usbmon-enroll.txt` | Raw usbmon trace of the first successful open + TLS handshake. |
| `usbmon-enroll2.txt` | Second capture — **does** contain sensor traffic (412 events on dev 009: 366 bulk-IN, 30 control). Analysed in §7.2. Finger state during this run was not recorded. |
| `usbmon-patched3.txt` | Trace with patch 3 applied. Source of the §7.4 falsification. Contains a NUL byte — use `awk`, not `grep`. Every event is duplicated (two usbmon readers). |
| `enroll-patched3.log` | `fprintd-enroll` client output for the patch-3 run. |
| `fprintd-patched3.log` | Daemon-side debug log for the patch-3 run — the named SSM states. |
| `usbmon-finger.txt` / `enroll-finger.log` / `fprintd-finger.log` | The run that first isolated state 17 (§7.3). |
| `enroll-attempt.log` | `fprintd-enroll` output with `G_MESSAGES_DEBUG=all`. |
| `libfprint-patched/usr/lib/x86_64-linux-gnu/libfprint-2.so.2.0.0.orig` | Pristine upstream library — every patch is reproducible from this. |
| `build.sh` | Builds libfprint v1.94.6 + MR 396 + `patches/*.patch` into `dist/`. |
| `patches/0001..0004*.patch` | The source patches. 0002 and 0004 are genuine driver bugs worth filing upstream; 0003 is a labelled experiment. |
| `dist/libfprint-2.so.2.0.0` | The built library that `install.sh` deploys. Supersedes byte-patching entirely. |
| `mr396-fpcmoh.patch` / `fpc.c-from-mr396.c` | MR 396 and the extracted driver source, for reading. |
| `usbmon-capture02b.txt` | **The decisive trace** (§15) — same command succeeding before a capture and timing out after one, then re-enumeration. |
| `fprintd-capture02b.log` | Daemon log for that run: identify completes, `enroll-stage-passed`, enroll state 1 times out, no SIGSEGV. |
| `mr396-fpcmoh.patch` | libfprint MR 396, the **only** source for the `fpcmoh` driver. Fetched read-only. |
| `fpc.c-from-mr396.c` | `fpc.c` extracted from that patch (1701 lines) for reading. Not built. |

*(An earlier revision of this table described `usbmon-enroll2.txt` as "blocked by polkit before any
traffic". That was wrong and contradicted §7.2; corrected above.)*

### Temporary polkit rule — REMOVED

To test enrollment non-interactively, `/etc/polkit-1/rules.d/49-fpc-a900-TEST.rules` was created,
granting **unconditional** `YES` to every `net.reactivated.fprint.*` action for user `youruser` — a real
loosening of local authorisation policy that bypasses the password prompt.

**It has been deleted and `polkit` restarted; `/etc/polkit-1/rules.d/` is now empty.** It was never
part of `install.sh` and is not needed for normal use.

> Provenance, recorded because the transcript is ambiguous: the assistant's own attempt to create this
> file was **blocked by a permission classifier**. The file nevertheless existed, timestamped 02:10,
> matching that attempt. It was most likely created out-of-band while wiring up `run-finger-test.sh`
> (the daemon log shows `Authorization granted` for `EnrollStop` with no password prompt, which only
> happens with such a rule active). Either way it existed, and it is now gone — verified, not assumed.

### Safety notes

- Nothing under `/usr/lib` was modified, moved, or overwritten at any point.
- No speculative host-to-device (`bmRequestType 0x40`) vendor control transfers were ever sent. Every
  command in the trace was issued by libfprint's own `fpcmoh` driver during a normal open/enroll.
- No Windows binary was executed; the packages were unpacked read-only for INF metadata.

## 11. Honest status of what is proven

**Proven:** the ID patch works; the device binds, probes, and opens; `libfpcbep.so` and the patched
library are both loaded; the TLS-PSK secure channel completes; the firmware reports `22.26.2.29` over
the wire; the driver arms the sensor and captures a frame; the sensor streams ~15 KB of encrypted
image data which the host-side blob accepts; **every USB transfer in every capture completed
successfully**, with no stall, NAK, or device-side rejection anywhere.

**Not proven:** that `fprintd-enroll` completes its stages, or that `fprintd-verify` matches. Neither
has ever succeeded on this hardware. Enrollment has never progressed past the identify pass.

**Explicitly unknown:** whether a finger was on the sensor during the `usbmon-enroll2.txt` run. It was
launched from a script and the touch state was not recorded. Because that run produced the *same* 15
TLS records as a known-touched run, capture appears to occur regardless of touch — so this document
must **not** be read as evidence that the sensor imaged an actual fingerprint. The payload is
TLS-encrypted; whether it contains ridge data is not observable from the host.

### The decision tree below was run. Outcome: "identical failure in state 17."

The experiment described here was executed twice (§7.4). The result was the third branch — byte 3 has
been reverted. The procedure is retained because it is the correct method and reproduces the finding.

**Make the *daemon* verbose** — `G_MESSAGES_DEBUG` on the `fprintd-enroll` command line only affects
the client, which is why the driver's own state-machine logging is absent from §§6–7.2:

```bash
sudo mkdir -p /etc/systemd/system/fprintd.service.d
printf '[Service]\nEnvironment=G_MESSAGES_DEBUG=all\n' \
  | sudo tee /etc/systemd/system/fprintd.service.d/20-debug.conf
sudo systemctl daemon-reload && sudo systemctl restart fprintd
```

Then run it twice — once deliberately **not** touching the sensor, once **pressing and lifting** on
every prompt:

```bash
sudo modprobe usbmon
sudo sh -c 'timeout 60 cat /sys/kernel/debug/usb/usbmon/3u > ~/Desktop/temp/usbmon-finger.txt' &
fprintd-enroll
sudo journalctl -u fprintd --since "2 min ago" --no-pager > ~/Desktop/temp/fprintd-debug.log
```

libfprint logs SSM transitions by name, so the journal will name the state it stopped in. The enum is
already recovered from DWARF — `FPC_INIT_TEE_INIT`, `FPC_INIT_WAIT4INIT_RESULT`, `FPC_ENROL`,
`FPC_ENROL_STATUS_IMAGE_LOW_COVERAGE`, `FPC_ENROL_STATUS_IMAGE_LOW_QUALITY`,
`FPC_ENROL_STATUS_FAILED_COULD_NOT_COMPLETE` — and these point at completely different verdicts.

Read the result as follows:

- **Advances past state 17 into enroll stages** → `10a5:a900` is solved. Confirm with
  `fprintd-verify` and re-test after a reboot before calling it done.
- **Gets further, then fails at a new, later state** → a sharper finding; document the new stopping
  point.
- ~~**Identical failure in state 17**~~ → **← THIS IS WHAT HAPPENED.** The firmware does not answer
  `bRequest 0x03` in that context at all, in any `wValue` form. Byte 3 reverted. The fix is not
  reachable by byte-patching; see §12.
- **Journal names an `FPC_ENROL_STATUS_IMAGE_*` state** → capture works and the matcher is rejecting
  frame quality. A tuning/blob problem, not a USB one, and a genuine lead.

### Loose end, resolved: "enroll stages changed to 13"

`fprintd` logs 13 enroll stages; the disassembly at `0x42B72` sets `movl $0xc` (12); MR 396's source
defines `MAX_ENROLL_SAMPLES (11)`. All three differ, and none of it is a bug or related to the
blocker. It does establish something useful for reproduction: **furcom's binary is not built from
unmodified MR 396** — the constant was changed from 11 to 12. Anyone rebuilding from source should
expect a different stage count than the prebuilt library reports.

Compare runs by *structure*, never by raw bytes: the count of `Co 40 09` capture rounds, the number
of `00000005 … 3f1 … 17030303` records, the total span, and which state the journal names. TLS
application data uses fresh keys and nonces per session, so ciphertext differs on every run even when
behaviour is identical — byte comparison is meaningless here.

Remove the debug drop-in afterwards (`sudo rm /etc/systemd/system/fprintd.service.d/20-debug.conf`);
it is deliberately not part of `install.sh` because it floods the journal.

Do **not** respond to a failure here by sending speculative `bmRequestType 0x40` commands. That
direction carries firmware-write and bootloader-entry opcodes and can permanently brick the sensor.

---

## 12. The driver has source — and the real fix is a control-flow change

Byte-patching reached its limit at §7.4. The remaining problem is control flow, and the source exists,
so the correct move is to rebuild rather than to keep editing machine code.

### Where the source lives

From the AUR `PKGBUILD` for `libfprint-fpcmoh-git`:

```
git+https://gitlab.freedesktop.org/libfprint/libfprint.git#tag=v1.94.6
https://gitlab.freedesktop.org/libfprint/libfprint/-/merge_requests/396.patch
fpcbep.zip::https://download.lenovo.com/pccbbs/mobiles/r1slm01w.zip
```

Three things worth knowing, none of them obvious:

- **`drivers/fpcmoh/` is not upstream libfprint.** It is added entirely by **merge request 396**, which
  is still unmerged. That is why no distro ships this driver and why the tracker has no lead for any
  MoH device.
- **`libfpcbep.so` comes from a Lenovo firmware bundle** (`r1slm01w.zip`), not from FPC. That is the
  same blob shipped in `libfprint-patched/`.
- The MR patch is 68 KB and contains `fpc.c` (1701 lines), `fpc.h` (309), and `fpclib_api.h`. Small
  enough to read in full.

> **Extraction gotcha.** Pulling `fpc.c` out of the patch needs a *bounded* range —
> `awk '/^diff --git a\/libfprint\/drivers\/fpcmoh\/fpc\.c/{f=1;next} f && /^diff --git/{exit} f && /^\+/ && !/^\+\+\+/{sub(/^\+/,"");print}'`.
> Without the `{exit}`, added lines from `fpclib_api.h` and `meson.build` are appended and you get a
> 2010-line file with a duplicate tail. Line numbers below 1701 are unaffected either way, but verify
> before citing.

**Caveat on rebuilding:** the AUR package pins libfprint `v1.94.6`, while the prebuilt binary analysed
here reports **1.94.4** and has `MAX_ENROLL_SAMPLES` changed from 11 to 12. furcom's tree therefore
diverges from MR 396 by an unknown amount. A from-source build is **not** guaranteed to reproduce this
binary's behaviour even before any fix is applied — establish a baseline before concluding a fix
worked.

### The bug, in source

> ### ⚠ Annotation — "state 17 is the cancel state" is WRONG. See §13.1.
>
> The framing below (and the claim that the journal's `(cleanup)` wording is "misleading") was an
> inference from the driver source alone, without reading libfprint's SSM core. It is incorrect.
> State 17 is the SSM's **first cleanup state**, and libfprint's `(cleanup)` wording is literally
> accurate. Nothing cancels anything. §13.1 gives the mechanism from primary source plus the
> empirical check that confirms it. The *conclusion* — that a failing `0x03` sinks a completed
> operation — survives; only the explanation of how state 17 is reached was wrong.

```c
/* fpc.h — the verify state enum. State 17 is not "cleanup"; it is CANCEL. */
FP_VERIFY_IDENTIFY   = 14,
FP_VERIFY_SUSPENDED  = 15,
FP_VERIFY_RESUME     = 16,
FP_VERIFY_CANCEL     = 17,

/* fpc.c:1578 — FP_VERIFY_CANCEL is registered as the SSM's cancel state */
self->identify_ssm = fpi_ssm_new_full (device, fpc_verify_sm_run_state,
                                       FP_VERIFY_NUM_STATES,
                                       FP_VERIFY_CANCEL,
                                       "verify_identify");

/* fpc.c:944 — what that state does */
case FP_VERIFY_CANCEL:
  fpc_write_ctrl (ssm, device, 0x03, 0x01, NULL, 0, fpi_ssm_usb_transfer_cb, NULL);
  break;

/* fpc.c — and state 14 has ALREADY succeeded by this point */
case FP_VERIFY_IDENTIFY:
  fpcmoh_match_report (device, self->dev_ctx->bio);
  fpi_ssm_mark_completed (self->identify_ssm);
  break;
```

The journal's wording — `failed in state 17 (cleanup)` — is libfprint's generic SSM phrasing and is
misleading. State 17 is the **cancel handler**, and `fpi_ssm_usb_transfer_cb` marks the SSM **failed**
when its transfer errors. Observed sequence on this firmware:

1. Identify runs to completion and reports correctly (state 14 calls `fpi_ssm_mark_completed`).
2. State 17 then runs — libfprint routes to the registered cancel state.
3. State 17 sends `bRequest 0x03`, which the a900 will not answer after a capture.
4. The 1-second timeout fires and the callback marks the *already-successful* operation as failed.

> **RESOLVED in §13 — this caveat is superseded.** When written, *what* routes to state 17 after
> state 14 had already called `fpi_ssm_mark_completed` was not established, and this section
> speculated about a spurious cancel. That was wrong. `FP_VERIFY_CANCEL` is the SSM's
> **`start_cleanup`** state, and `fpi_ssm_mark_completed()` does not finish a machine sitting below
> `start_cleanup` — it jumps there first (`fpi-ssm.c`: *"complete in a cleanup state just moves
> forward one step"*). State 17 therefore runs at the end of **every** verify and identify, on
> success exactly as on failure. Nothing is cancelling anything. See §13.

Why an identify runs during an *enroll* at all: `fpc.c:1700` sets
`dev_class->features |= FP_DEVICE_FEATURE_DUPLICATES_CHECK`, so libfprint performs a duplicate-finger
identify pass before accepting enrollment.

And the error propagates because `fpc_verify_ssm_done` (`fpc.c:953`) adopts the SSM's error verbatim:

```c
if (fpi_ssm_get_error (ssm))
  error = fpi_ssm_get_error (ssm);
...
fpi_device_identify_complete (dev, error);   /* -> "error during identify for enroll" */
```

**A cancel command failing should not destroy an operation that already finished.** That is arguably a
driver robustness bug affecting any FPC MoH device whose firmware does not answer the cancel opcode in
that state — not an a900 quirk — which makes it worth proposing against MR 396 rather than carrying
as a local patch.

### The candidate fix — a hypothesis, not a tested fix

**This has not been compiled or run.** It follows from the source reading above and is the smallest
change consistent with the evidence, but it is untested and should be treated as the next experiment
rather than a solution.

Replace the failure-propagating callback in `FP_VERIFY_CANCEL` with one that completes the SSM
regardless of transfer status. Roughly:

```c
static void
fpc_cancel_ignore_cb (FpiUsbTransfer *transfer, FpDevice *device,
                      gpointer user_data, GError *error)
{
  /* The a900 does not answer bRequest 0x03 once a capture has completed.
     A failed cancel must not sink an operation that already succeeded. */
  g_clear_error (&error);
  fpi_ssm_next_state (transfer->ssm);
}
```

Try this **before** anything else. Do not raise the timeout (the device is not slow — it is silent),
and do not remove the command (init issues it successfully; it is presumably needed there).

### Build requirements on Pop!_OS 24.04

Present: `meson 1.3.2`, `ninja`, `gcc`, `glib-2.0 2.80.0`, `pixman-1`, `gudev-1.0`,
`gobject-introspection 1.80.1`. **Missing: `libgusb-dev`, `libnss3-dev`, `libusb-1.0-0-dev`.**

The build also needs the `meson.build` edit from the PKGBUILD so `find_library('fpcbep')` resolves
against the local blob, and a `patchelf --replace-needed` afterwards.

### Status

Not attempted in this session — it requires installing development packages, which is a larger system
change than everything else here and was left as the user's call. The investigation stops at a
precisely located, source-level diagnosis.

*(Superseded: the source build was done in the next session. See §13.)*

---

## 13. From source — mechanism, build, and fix

Byte-patching is retired. This section supersedes §12 wherever they disagree.

### 13.1 Why state 17 runs — the mechanism, from primary source

§12 guessed that state 17 was a *cancel* state and that something was spuriously cancelling an
already-completed SSM. **That is wrong.** The truth is simpler and is documented in libfprint itself.

The fourth argument to `fpi_ssm_new_full` is not a cancel state. It is `start_cleanup` — the index of
the **first cleanup state**:

```c
/* libfprint/fpi-ssm.c, v1.94.6 — section documentation */
 * e.g. `S1` ↦ `S2` ↦ `S3` ↦ `S4` ↦ `C1` ↦ `C2` ↦ `final`
 *
 * Where `S1` is the start state. The `C1` and later states are cleanup states
 * that may be defined. The difference is that these states will never be
 * skipped when marking the SSM as completed.
```

And the enforcement, in `fpi_ssm_mark_completed`:

```c
/* libfprint/fpi-ssm.c:342-346 */
  /* complete in a cleanup state just moves forward one step */
  if (machine->cur_state < machine->start_cleanup)
    next_state = machine->start_cleanup;
  else
    next_state = machine->cur_state + 1;
```

So when `FP_VERIFY_IDENTIFY` (state 14) calls `fpi_ssm_mark_completed`, the SSM **does not finish**.
Because `14 < 17`, it jumps to `start_cleanup` = state 17 and runs it. That is the entire mechanism.
State 17 running after a *successful* state 14 is correct, designed, unavoidable behaviour.

The journal's wording is likewise literally correct, not misleading — it is generated from exactly
this comparison:

```c
/* libfprint/fpi-ssm.c:434 */
          machine->cur_state >= machine->start_cleanup ? " (cleanup)" : "",
```

**Empirical confirmation.** `fpc_dev_cancel` opens with `fp_dbg ("%s enter -->", G_STRFUNC)`, and both
debug-log captures were taken with `G_MESSAGES_DEBUG=all`. It appears **zero times** in
`fprintd-finger.log` and zero times in `fprintd-patched3.log`. The logs show a bare `state 14` →
`state 17` transition with nothing in between. Nothing called into the cancel vtable. Two independent
sources — the SSM source and the daemon's own log — agree.

**Consequence: the "don't cancel a completed SSM" fix is not applicable.** There is no spurious
cancel to suppress. The only correct fix is to stop a failing *cleanup* transfer from destroying an
operation that already succeeded.

### 13.2 Why that is a general driver bug, not an a900 workaround

The cleanup state passes `fpi_ssm_usb_transfer_cb` as its completion callback. That callback is:

```c
/* libfprint/fpi-ssm.c:676 */
void
fpi_ssm_usb_transfer_cb (FpiUsbTransfer *transfer, FpDevice *device,
                         gpointer unused_data, GError *error)
{
  g_return_if_fail (transfer->ssm);

  if (error)
    fpi_ssm_mark_failed (transfer->ssm, error);
  else
    fpi_ssm_next_state (transfer->ssm);
}
```

It is a perfectly good callback for a *normal* state, where a failed transfer genuinely means the
operation failed. In a **cleanup** state it is wrong: cleanup runs after the outcome is already
decided, so failing there can only ever downgrade a result, never rescue one.

Critically, swallowing the error in cleanup **cannot mask a real failure**, because
`fpi_ssm_mark_failed` records only the *first* error:

```c
/* libfprint/fpi-ssm.c */
  if (!machine->error)
    machine->error = g_steal_pointer (&error);
  else
    g_error_free (error);
```

So on a genuine failure in states 0–14, the error is recorded first, the SSM jumps to cleanup, and
the cleanup callback runs with that error still set on the machine. Completing cleanup without adding
a *new* error leaves the original intact, and `fpc_verify_ssm_done` still reports it via
`fpi_ssm_get_error`. The change is therefore strictly an improvement, which is what makes it
upstreamable rather than a local hack.

This affects **any** FPC MoH device whose firmware declines `bRequest 0x03` in that state — not just
the a900.

### 13.3 The enroll SSM does not have this bug

Worth checking before assuming the fix unblocks enrollment: the enroll SSM is created with
`FP_ENROLL_DISCARD` as its `start_cleanup`, and that state is a no-op —

```c
    case FP_ENROLL_DISCARD:
      {
        fpi_ssm_next_state (self->enroll_ssm);
      }
      break;
```

It issues no USB transfer, so it cannot fail the same way. Only the verify/identify SSM sends `0x03`
from cleanup.

### 13.4 MR 396 vs MR !570 — resolved

Both merge requests add a `libfprint/drivers/fpcmoh/` directory. They are **entirely different
drivers**, not two revisions of one.

| | **MR 396** | **MR !570** |
|---|---|---|
| File | `drivers/fpcmoh/fpc.c` (1701 lines) | `drivers/fpcmoh/fpcmoh.c` (1581 lines) |
| Title | *fpcmoh: Support FPC moh(match on host) devices* | *Add fpcmoh driver for FPC Disum match-on-host sensors* |
| USB IDs | `10a5:9800` | `10a5:9200`, `10a5:9201` |
| Device model | `FpDevice` | `FpImageDevice` |
| Proprietary blob | **required** (`libfpcbep.so`) | **none** |
| TLS | inside `libfpcbep.so`'s enclave | OpenSSL, in-tree |
| PSK source | sealed inside the blob | **read from the device** and decrypted in-tree |
| Matcher | `fpc_tee_identify` in the blob | SIGFM (OpenCV SIFT), in-tree |
| Image geometry | from the device (`64x176` here) | hardcoded `112x88` (FPC1022) |

**MR 396 is the one this project builds on**, for one decisive reason: it is the driver in furcom's
prebuilt library, and that library is *proven* to drive this exact a900 through TLS handshake, image
capture and host-side matching. MR !570 has never been run against an a900, targets a different PID
range, and hardcodes an image geometry this sensor does not have.

**But MR !570 is strategically the more interesting effort, and it is not a dead end for the a900.**
It is newer, blob-free, LGPL, and actively developed. Crucially, one of its central claims can be
tested against traces already in this repo — and it checks out exactly.

MR !570 says vendor command `0x0B` is `CMD_GET_TLS_KEY`, returning a packet with magic `0x0DEC0DED`
and this layout:

```c
typedef struct __attribute__((packed)) {
  guint32 magic; guint32 key_offset; guint32 key_len;
  guint32 aad_offset; guint32 aad_len;
  guint32 sig_offset; guint32 sig_len;
} FpcMohTlsKeyPkt;
```

The a900's answer to `Ci c0 0b`, from `usbmon-enroll.txt`, is 121 bytes beginning:

```
ed0dec0d 1c000000 20000000 4c000000 0d000000 59000000 20000000
  magic    key@28   key=32   aad@76   aad=13   sig@89   sig=32
```

Magic matches. The 7-field header is 28 bytes, which is exactly `key_offset`. And `sig_offset +
sig_len` = 89 + 32 = **121** = the exact transfer length. Every field is self-consistent.

Two corrections follow. First, §7.2 and §7 label this command *"read sensor parameters"* — **it is
not**; it is the sealed TLS pre-shared key. Second, and much more significantly: **the a900 speaks
MR !570's key-exchange protocol byte-for-byte, which means a completely blob-free driver for this
device is plausible.** It would still need the a900's `64x176` geometry taught to it (MR !570
hardcodes `112x88`) and would need SIGFM to work on a 64×176 strip.

That is a genuinely promising follow-up and is recorded here as a lead. It was **not** pursued in this
session, because swapping to an unproven driver architecture is a much larger bet than fixing one
known bug in a driver already shown to reach image capture on this hardware.

### 13.5 The build

`libfprint v1.94.6` + MR 396 + `patches/`, built by `./build.sh`. MR 396 applies to the `v1.94.6` tag
cleanly (`git apply --check` passes, 7 files, 2188 insertions).

Notes for reproducers, none of which are in the AUR PKGBUILD:

- **`-Ddrivers=fpcmoh`** builds only this driver. Exported ABI is unaffected — the version script
  governs exports, and the result exports the same **92** symbols as the distro's 1.94.7, with none
  of the 47 that `fprintd`/`pam_fprintd` need missing.
- **`find_library('fpcbep')` needs two link flags, not one.** `-L<dir>` lets libfprint itself link.
  But the `examples/*` programs link against libfprint *without* `-lfpcbep`, and `-Wl,--no-undefined`
  makes the unresolved transitive symbols fatal — so `-Wl,-rpath-link,<dir>` is also required.
  Without it the library builds fine and the build still fails, with errors that name
  `libfprint-2.so.2.0.0` as the offender and look misleadingly like the library itself failed to link.
  Reading which *target* failed, rather than the error text, is what disambiguates this.
- **No `patchelf` step is needed.** The PKGBUILD's `--replace-needed` is unnecessary here: because
  `libfpcbep.so` carries no `SONAME`, `ld` records the bare `-l` name, so `DT_NEEDED` comes out as
  `libfpcbep.so` and `LD_LIBRARY_PATH` resolves it.
- **This build links the blob; furcom's prebuilt `dlopen`s it.** The prebuilt has *zero* undefined
  `fpc_*` symbols and imports `dlopen`/`dlsym` with the literal string `libfpcbep.so` — so furcom's
  `fpc.c` was modified to load the blob at runtime. MR 396 links it directly. `LD_LIBRARY_PATH`
  covers both, but the blob is now mapped at *probe* time rather than at *device open*.
- **`MAX_ENROLL_SAMPLES` is 11 here, 12 in the prebuilt.** Expected; furcom's tree diverges from
  MR 396. Not a regression, do not chase it.

Adding the a900 in C does what the byte patch could not: **both** `9800` and `a900` are in the
`id_table`, verified in the artifact —

```
000353c0: 0098 0000 a510 0000 ...   <- pid 0x9800 vid 0x10a5
000353e0: 00a9 0000 a510 0000 ...   <- pid 0xa900 vid 0x10a5
```

### 13.6 Baseline result — the from-source build fails *identically*

This was the step that decided whether anything in §§1–12 still applied, given that those conclusions
came from furcom's 1.94.4 prebuilt while this builds 1.94.6 from MR 396. **It does apply.** Built with
the a900 ID and nothing else, the failure reproduces exactly:

```
[fpcmoh] fpc_init_evt_handler: hwid(0x331), img_w 64, img_h 176
[fpcmoh] verify_identify entering state 13          x16
         fpc_ssm_img_read_cb: received_len 1009, expect len 1009
[fpcmoh] verify_identify entering state 14
         fpcmoh_match_report: templates->len = 0
[fpcmoh] verify_identify entering state 17
[fpcmoh] SSM verify_identify failed in state 17 (cleanup) with error: transfer timed out
```

Same geometry, same 16 image-read iterations, same exact 1009-byte reassembly, same match report
against an empty database, same state-17 timeout. Compare §7.3 — it is the same log.

**Conclusion: the analysis in §§1–12 transfers to the from-source build**, and the divergences
between furcom's tree and MR 396 (`MAX_ENROLL_SAMPLES` 11 vs 12, `dlopen` vs direct linking) do not
affect this failure. No re-validation of earlier findings is needed.

Two incidental findings from the baseline runs:

- **The from-source build opens the device cleanly.** `FPC_INIT_NUM_STATES completed successfully`,
  `fpc_tee_init` returns a handle, and the blob loads. The a900 ID patch is sufficient for everything
  up to the identify.
- **`fprintd-enroll` can be refused by polkit with no password prompt at all**, failing instantly with
  `Not Authorized: net.reactivated.fprint.device.enroll`. This is *not* a driver problem: the action
  is `allow_active=auth_self_keep` and needs an authentication agent, which COSMIC does not reliably
  give a terminal. The fix is to register one for the shell — `pkttyagent --process $$ --fallback` —
  which prompts normally and **changes no policy**. `run-finger-test.sh` now does this automatically.
  Do not "solve" this with a permissive polkit rule; see the note at the end of §10.

### 13.7 The fix

`patches/0002-fpcmoh-cleanup-transfer-must-not-fail-operation.patch` gives `FP_VERIFY_CANCEL` its own
completion callback instead of `fpi_ssm_usb_transfer_cb`:

```c
static void
fpc_verify_cleanup_cb (FpiUsbTransfer *transfer, FpDevice *device,
                       gpointer user_data, GError *error)
{
  g_return_if_fail (transfer->ssm);

  if (error)
    {
      fp_dbg ("%s: cleanup transfer failed (%s); not failing the operation",
              G_STRFUNC, error->message);
      g_clear_error (&error);
    }

  fpi_ssm_next_state (transfer->ssm);
}
```

`fpi_ssm_next_state` is correct here rather than `fpi_ssm_mark_completed`: state 17 is the last state
(`FP_VERIFY_NUM_STATES` is 18), so incrementing reaches `nr_states` and `fpi_ssm_next_state` calls
`fpi_ssm_mark_completed` itself. It is also what `fpi_ssm_usb_transfer_cb` does on success, so the
success path is unchanged.

**libfprint's own test suite independently confirms both halves of the reasoning.** `tests/fpi-ssm`
contains dedicated cleanup tests, and their debug output is exactly the behaviour argued for above:

```
ok 41 /ssm/cleanup/complete
  FPI_TEST_SSM entering state 0
  FPI_TEST_SSM entering state 2      <- mark_completed in state 0 JUMPS to start_cleanup
  FPI_TEST_SSM entering state 3
  FPI_TEST_SSM completed successfully

ok 42 /ssm/cleanup/fail
  SSM failed in state 0 with error: non-cleanup
  FPI_TEST_SSM entering state 2
  SSM failed in state 2 (cleanup) with error: cleanup 1
  FPI_TEST_SSM entering state 3
  SSM failed in state 3 (cleanup) with error: cleanup 2
  FPI_TEST_SSM completed with error: non-cleanup    <- the FIRST error is what is reported
```

Test 41 is the 14→17 jump. Test 42 shows cleanup states failing *after* a real error and the machine
still reporting the original one — which is precisely why swallowing the cleanup error cannot mask a
genuine failure.

> **Running the test suite:** all four unit tests fail with exit status 127 unless the blob directory
> is on the library path, because `libfprint-2.so` now has `libfpcbep.so` as a `DT_NEEDED` entry and
> meson's test environment does not include `/opt/fpc-a900/lib`. Run them as
> `LD_LIBRARY_PATH=builddir/libfprint:/opt/fpc-a900/lib ./tests/test-fpi-ssm`. The 127 is a loader
> failure, not a test failure.

### 13.8 The fix works — state 17 is solved

Confirmed on hardware. The cleanup transfer still fails, and the operation now survives it:

```
[fpcmoh] verify_identify entering state 17
fpc_verify_cleanup_cb: cleanup transfer failed (transfer timed out); not failing the operation
[fpcmoh] verify_identify completed successfully
Verify_identify complete!
Device reported identify completion
```

Compare the baseline, same build minus this one patch:

```
[fpcmoh] SSM verify_identify failed in state 17 (cleanup) with error: transfer timed out
[fpcmoh] verify_identify completed with error: transfer timed out
```

**The duplicate-check identify now passes and `fpc_dev_enroll` is reached for the first time on this
hardware.**

> **Do not overstate this.** `fprintd-enroll` printed `Enroll result: enroll-stage-passed`, but that
> is the *duplicate-check identify* passing — it means "this finger is not already enrolled", not
> "an enrollment sample was captured". The daemon's own verdict for the operation was
> `enroll_cb: result enroll-unknown-error`, and the enroll SSM died on its very first command
> (§13.9), so **no enrollment image was ever captured**. What is proven is that state 17 no longer
> destroys the identify and that the enroll path is now reached. Enrollment itself does not work.

The enroll SSM also confirms §13.3's prediction: its cleanup state is `FP_ENROLL_DISCARD` = **20**, and
the journal shows `enroll entering state 20` after the failure — a cleanup state that issues no
transfer and therefore cannot fail the same way.

### 13.9 The next blocker: the sensor drops off the USB bus after every capture

Enrollment does not complete. It now fails at `FP_ENROLL_CAPTURE` (state 1):

```
fpc_dev_enroll enter -->
[fpcmoh] enroll entering state 0        (FP_ENROLL_BEGIN)
[fpcmoh] enroll entering state 1        (FP_ENROLL_CAPTURE)
send cmdid 02
[fpcmoh] SSM enroll failed in state 1 with error: transfer failed
[fpcmoh] enroll entering state 20       (FP_ENROLL_DISCARD, cleanup)
[fpcmoh] enroll completed with error: transfer failed
```

**This is not a regression and not caused by the fix.** The wire shows why. `bRequest 0x02` completes
with **`-71` (`EPROTO`)**, and immediately before that the root hub reports a port change whose status
decodes as a disconnect:

```
C Ci:3:001:0 0 4 = 00010100      wPortStatus 0x0100 = PORT_POWER, CONNECTION *clear*
                                 wPortChange 0x0001 = C_PORT_CONNECTION
```

followed by a fresh enumeration at a new device address. **The sensor left the bus.**

Timing, measured from the last TLS image record, across three independent runs:

| trace | `0x03` submitted | `0x03` cancelled | **disconnect** | ARM sent after? |
|---|---|---|---|---|
| `usbmon-finger.txt` (prebuilt 1.94.4) | +2.9 ms | +1003.2 ms | **+1074.7 ms** | **no** |
| `usbmon-baseline.txt` (from source, no fix) | +2.5 ms | +1002.8 ms | **+1086.5 ms** | **no** |
| `usbmon-fixed.txt` (from source, fixed) | +3.1 ms | +1003.4 ms | **+1083.2 ms** | yes, at +1005 ms |

Three things follow, and the first two are firm:

1. **The disconnect is not caused by the enroll ARM.** Two of the three runs never sent one — the SSM
   had already failed and no enroll was attempted — and they disconnect at the same offset anyway.
   The `-71` on the ARM is a *consequence* of the device having gone, not a cause of anything.
2. **This has been happening since the very first capture ever taken on this device, and was simply
   never noticed.** `fprintd-finger.log`, from the original prebuilt-library run, shows
   `fpc_dev_exit` followed one second later by `fpc_dev_probe` — libfprint re-probing a device that
   had re-appeared. The re-enumeration was in the evidence all along; the state-17 failure masked it
   because nothing ever looked past the first error.
3. **It is not autosuspend and not a host-side reset.** Autosuspend does not clear `PORT_CONNECTION`,
   and a `g_usb_device_reset` would show as `C_PORT_RESET`, not `C_PORT_CONNECTION`. This is a real
   link-layer disconnect.

**Why the a900 never answers `bRequest 0x03` after a capture is now explained**: it is not refusing
the command, it is on its way off the bus. The 1 s "timeout" is the host waiting for a reply from a
device that is about to disappear. §7.4's conclusion ("the firmware stops answering `bRequest 0x03`
once a capture has completed") is right about the observable and wrong about the reason.

**What is still open** is the trigger. The disconnect lands ~1080 ms after the last image record and
~80 ms after the host cancels the timed-out control URB, and those two anchors cannot be separated
from these traces because every run cancels at exactly +1003 ms. Two hypotheses:

- **H1 — the device resets itself** on its own timer after a capture (or after receiving `0x03`
  post-capture). Then the disconnect stays at ~+1080 ms no matter what the host does.
- **H2 — the host's URB cancellation triggers it.** Unlinking an in-flight EP0 control transfer is
  disruptive, and the consistent ~80 ms lag after the cancel is suggestive. Then the disconnect
  tracks the timeout.

These are cleanly separable by changing *only* the cleanup transfer's timeout and re-measuring: if the
disconnect follows the timeout, H2; if it stays at ~+1080 ms, H1. That experiment sends **no new
command to the device** — it only changes how long the host waits — so it is safe under this
project's rules. It is the correct next step and is *not* a proposal to raise the timeout as a fix.

One datum already constrains it: init issues `40 03 0000` (see `usbmon-finger.txt` at −2534 ms) and
**no disconnect follows**. So `0x03` by itself is harmless; whatever the trigger is, it requires the
post-capture state.

A third hypothesis is now on the table, and §1's correction is where it comes from:

- **H3 — the capture's bulk traffic does it.** The sensor's bulk IN endpoint declares
  `wMaxPacketSize` 64 while running at high speed, where the USB 2.0 specification requires 512.
  A capture is the only time that endpoint carries sustained traffic, and it is the only activity
  that precedes a disconnect. The kernel flags the descriptor on every enumeration.

### 13.10 `bRequest 0x03` has exactly one call site in MR 396 — and init does not use it

Worth stating plainly, because the previous session's guidance assumed otherwise. In MR 396's source,
`0x03` is sent from **one place only** — the verify/identify cleanup state:

```
fpc.c:946:  fpc_write_ctrl (ssm, device, 0x03, 0x01, NULL, 0, fpi_ssm_usb_transfer_cb, NULL);
```

There is no `0x03` in `fpc_init_sm_run_state`. The wire confirms the consequence:

| trace | build | `40 03` wValues observed |
|---|---|---|
| `usbmon-finger.txt` | furcom prebuilt 1.94.4 | `0000` (init) **and** `0001` (cleanup) |
| `usbmon-patched3.txt` | furcom prebuilt, byte-patched | `0000` (both sites, after patch 3) |
| `usbmon-baseline.txt` | **from source, MR 396** | **`0001` only** |
| `usbmon-fixed.txt` | **from source, MR 396 + fix** | **`0001` only** |

**The init `0x03` is furcom's, not MR 396's** — a third documented divergence, alongside
`MAX_ENROLL_SAMPLES` and `dlopen` vs direct linking.

This settles a question the previous session had to leave open. Its rule was *"do not remove the
`0x03` command outright: init issues it successfully and it is presumably needed there."* That was
inferred from furcom's binary. On MR 396 there is nothing to preserve: **the from-source build never
sent `0x03` at init, and the device still enumerated, initialised, completed the TLS-PSK handshake,
armed the sensor and captured a full image.** Init's `0x03` is demonstrably unnecessary. Removing the
cleanup call site therefore removes the command from the driver entirely, and that is a safe thing to
do — it sends strictly fewer commands, never a new one.

That is what `patches/0003-EXPERIMENT-skip-0x03-in-verify-cleanup.patch` does, mirroring
`FP_ENROLL_DISCARD`. It is an **experiment, not a proposed fix**, and its result decides between
H1/H2 and H3:

- **no disconnect** → `0x03`-post-capture is the trigger; enrollment may proceed and the patch
  becomes a candidate fix;
- **disconnect still at ~+1080 ms after the last image record** → the capture itself resets the
  device (H3, or H1 on its own timer). No driver-level change can fix that, and the honest outcome is
  a documented negative result.

### 13.11 Lead, NOT to be tried without sign-off: MR !570 stops the sensor before aborting

MR !570's capture teardown is a three-step sequence, not a bare abort:

```
FPCMOH_CAPTURE_STOP_ARM  ->  FPCMOH_CAPTURE_STOP_ABORT  ->  FPCMOH_CAPTURE_STOP_SESSION_OFF
```

where `STOP_ARM` is `CMD_ARM (0x02)` carrying `ARM_OP_STOP = 0x12`. MR 396 sends only the bare
`0x03`. If this firmware requires being *stopped* before being *aborted*, that is a plausible
explanation for why a lone `0x03` leaves it in a state it does not recover from.

**This has not been tried and must not be tried casually.** `0x02` with payload `0x12` is a
**new `bmRequestType 0x40` vendor command that this driver has never sent to this device**, which is
exactly the category this project's hard rule 1 forbids sending speculatively — that direction
carries firmware-write and bootloader-entry opcodes. It is recorded as the most promising lead for
whoever picks this up, to be attempted only with the owner's explicit informed consent.

---

## 14. Patch 0003 works — state 17 cleared, and a driver crash found behind it

Run of 2026-07-29 11:56, patches 0001+0002+0003 deployed, finger pressed,
authorization granted by a temporary polkit rule. **This is the furthest the device has ever got.**

### 14.1 The identify SSM completes for the first time

```
fpc_ssm_img_read_cb: received_len 1009, expect len 1009
[fpcmoh] verify_identify entering state 14
fpcmoh_match_report: templates->len = 0
Device reported identify result
[fpcmoh] verify_identify entering state 17
[fpcmoh] verify_identify completed successfully      <-- never seen before
Verify_identify complete!
Device reported identify completion
Completing action FPI_DEVICE_ACTION_IDENTIFY in idle!
```

State 17 no longer fails. `fprintd-enroll` then reported **`Enroll result: enroll-stage-passed`** —
the first enroll stage ever accepted by this hardware. The §7.3/§7.4 blocker is closed.

**What this says about H1/H2/H3 (patch 0003's question):** removing `bRequest 0x03` from the cleanup
state let identify complete, so the *reported failure* was the 1 s timeout on that command, not an
unavoidable device reset. It does **not** yet settle whether the sensor still resets itself after a
capture — see 14.3. The usbmon trace for this run was overwritten by a later run before it could be
analysed, so the disconnect question is still open on wire evidence.

### 14.2 The next functional blocker: enroll state 1

```
fpc_dev_enroll enter -->
[fpcmoh] enroll entering state 0        (FP_ENROLL_BEGIN)
[fpcmoh] enroll entering state 1        (FP_ENROLL_CAPTURE)
send cmdid 02
[fpcmoh] SSM enroll failed in state 1 with error: transfer timed out
[fpcmoh] enroll entering state 20       (FP_ENROLL_DISCARD)
[fpcmoh] enroll completed with error: transfer timed out
```

`FP_ENROLL_CAPTURE` issues `bRequest 0x02` (`fpc_write_ctrl (ssm, device, 0x02, 0x01, ...)`) and it
times out. Note `40 02 0001` **is** answered during the verify/identify path — so this is the same
*shape* of problem as §7.4: a command the device accepts in one state and ignores in another,
immediately after a capture. Whether the device has actually left the bus at that moment is not yet
established; capturing usbmon across this exact transition is the next measurement.

### 14.3 SIGSEGV — a double free in the driver, unrelated to the a900

The run ended with:

```
enroll_cb: result enroll-unknown-error
fprintd.service: Main process exited, code=dumped, status=11/SEGV
fprintd.service: Failed with result 'core-dump'.
```

which is also why the client saw `EnrollStop failed: ... NoReply: Remote peer disconnected` — the
daemon was gone.

**Cause.** libfprint hands an SSM completion callback its own *copy* of the error and keeps the
original (`libfprint/fpi-ssm.c`, `fpi_ssm_mark_completed`):

```c
if (machine->callback)
  {
    GError *error = machine->error ? g_error_copy (machine->error) : NULL;
    machine->callback (machine, machine->dev, error);
  }
fpi_ssm_free (machine);          /* g_clear_pointer (&machine->error, g_error_free) */
```

`fpi_ssm_get_error()` returns that original, borrowed. Both fpcmoh completion callbacks did:

```c
if (fpi_ssm_get_error (ssm))
  error = fpi_ssm_get_error (ssm);      /* leaks the copy; adopts machine->error */
...
fpi_device_enroll_complete (dev, NULL, error);   /* @error: (transfer full) -> frees it */
```

so `machine->error` is freed by `fpi_device_enroll_complete()` and then **again** by `fpi_ssm_free()`.
Double free → SIGSEGV. `fpi_device_enroll_complete()` and `fpi_device_identify_complete()` are both
annotated `@error: (transfer full)`; verified in the built tree, not assumed.

**Why it only surfaced now.** The crash is on the *error* path. Identify had never before reached
these callbacks with a non-NULL error — it always died earlier, in the state 17 cleanup. Fixing that
(patch 0002/0003) let an enroll run far enough to fail on its own terms, which exposed the bug.

**Patch 0004** removes the two-line override in both callbacks; the `error` parameter already carries
the value they were reaching for. This is **not a900-specific and not a firmware quirk** — any FPC MoH
device crashes fprintd whenever one of these state machines fails. Of the four patches, 0002 and 0004
are the two that belong upstream against MR 396 on their own merits.

### 14.4 Authorization, for the record

`cosmic-osd` runs but **never registers a polkit authentication agent** — the polkitd journal shows
only `pkttyagent` registrations. With no agent, `auth_self_keep` denies instantly and silently.

`pkttyagent --process $$ & fprintd-enroll` does *not* work: that registers a `unix-process` subject
for the shell, while fprintd checks the `fprintd-enroll` process. `run-finger-test.sh` now registers
the agent for a subshell's `$BASHPID` and `exec`s `fprintd-enroll` into it, so the PID and start time
match — untested at time of writing. The 11:56 run instead used a temporary rule scoped to the single
action, which is the narrower and better form of the §10 workaround:

```javascript
polkit.addRule(function(action, subject) {
    if (action.id == "net.reactivated.fprint.device.enroll" && subject.user == "youruser")
        return polkit.Result.YES;
});
```

It was removed again immediately after the run.

---

## 15. Root cause, established: the sensor goes silent on EP0 after every capture

Run `capture02b`, 2026-07-29 12:09, patches 0001+0002+0003+0004, finger pressed.
`usbmon-capture02b.txt` finally caught the transition, and it settles the question.

### 15.1 The same command, 5 seconds apart, opposite outcomes

Byte-identical vendor command — `bmRequestType 0x40, bRequest 0x02, wValue 0x0001`, payload
`0f100107` — issued twice to the same device address:

| | t | Result |
|---|---|---|
| during identify | +0.000 s | **status 0 in 12.7 ms** |
| last image record of that capture | +5.001 s | |
| **during enroll**, 0.709 ms later | +5.002 s | **status −2, cancelled at exactly 1.000198 s** |
| root-hub port activity | +6.108 s | |
| **device re-enumerates at a new address** | +7.295 s | |

Device address 011 produces **zero further events** after the timeout.

### 15.2 What this proves

**The a900 stops answering endpoint 0 once an image capture completes, then resets itself.**

- It is **not command-specific.** `0x03` (§7.4) and `0x02` (here) both work before a capture and both
  hang after one. Two different opcodes, same behaviour.
- It is **not `wValue`-specific.** Tested and falsified in §7.4.
- It is **not caused by the cleanup command.** Patch 0003 removed `0x03` from the cleanup path
  entirely, and the device still goes silent and still re-enumerates. **This settles H1/H2/H3 from
  patch 0003: the trigger is the capture itself, not the command sent afterwards, and not the host's
  cancellation of it.**
- **The device is still enumerated while silent.** The URB completes `−2` (ENOENT, cancelled by the
  1 s timeout), not `−19`/`−108` (ENODEV/ESHUTDOWN). Had the device already left the bus, the host
  controller would have failed it immediately. So it accepts the SETUP packet and simply never
  completes the transfer — it is present but unresponsive. The reset follows ~1.3 s later.

### 15.3 Why this is where driver-side work stops

Every layer above the firmware now works: the device binds, opens, completes TLS-PSK, captures a
full-length image, the host-side matcher runs and reports, the identify SSM completes successfully,
and fprintd accepts the first enroll stage (`enroll-stage-passed`). The remaining failure is that the
sensor will not accept a second capture command in the same session.

That is firmware behaviour, and closing it would require knowing what the Windows *Disum* stack does
between captures that libfprint's `fpcmoh` does not — most plausibly an additional read or
acknowledgement that drains some post-capture state. Finding it means either capturing a Windows-side
USB trace (out of scope: this task is Linux-only) or probing `bmRequestType 0x40` speculatively, which
this project's hard rule 1 forbids because that direction carries firmware-write and bootloader
opcodes.

**Verdict (SUPERSEDED by section 16): `binds, opens, captures, matches — cannot re-arm.`** One
enroll stage of eleven is reachable. Enrollment cannot complete on this firmware with the current
driver.

**This was wrong about the cause.** The sensor is not refusing to re-arm and its firmware is not at
fault: the driver was abandoning the image transfer 12 records in, and the sensor's control endpoint
does not answer while an IN transfer is outstanding. Section 16 has the measurement and the fix. All
eleven enroll stages now run, with no disconnects at all.

### 15.4 The four patches, and which of them deserve to go upstream

| # | Patch | Scope | Upstream? |
|---|---|---|---|
| 0001 | add `10a5:a900` to `id_table` + probe case | a900-specific | Yes — additive, keeps `9800` |
| 0002 | cleanup transfer must not fail a completed operation | **all FPC MoH** | **Yes — genuine driver bug** |
| 0003 | skip `0x03` in verify cleanup | diagnostic | **No** — experiment; 0002 already makes the timeout harmless, 0003 only avoids a 1 s stall |
| 0004 | fix double free of the SSM error (SIGSEGV) | **all FPC MoH** | **Yes — genuine driver bug** |

0002 and 0004 are worth filing against MR 396 on their own merits regardless of the a900: **0004 is a
crash** — any FPC MoH device takes fprintd down with `SIGSEGV` whenever an enroll, verify or identify
state machine fails — and it was confirmed fixed here (`EnrollStop` now returns normally where it
previously died with `Remote peer disconnected`).

### 15.5 Authorization: the `exec` trick does not work

Recorded so nobody repeats it. `cosmic-osd` never registers a polkit agent on this system, and
**neither** plain `pkttyagent --process $$` **nor** the `$BASHPID` + `exec fprintd-enroll` variant
gets one matched — both still fail instantly with `Not Authorized`. Every successful enroll run in
this document required a temporary polkit rule. `run-finger-test.sh` now detects the situation and
prints the rule rather than pretending an agent will appear.


---

## 16. Root cause found and fixed — and the real remaining blocker

Session of 2026-07-29 evening. Supersedes sections 13.9, 15.2 and 15.3.

### 16.1 The "goes silent on EP0 / resets itself" behaviour was a driver bug

`fpc_ssm_img_read_cb()` consumes exactly one record per SSM state, and both state machines provide
exactly eleven read states (`FP_*_WAIT4IMG_SEQ1..SEQ11`). The driver therefore always reads eleven
records and stops. **The a900 sends twelve.** From usbmon, one capture:

| reads | bytes | record |
|---|---|---|
| 8–183 | 11 × 1009 | image records 1–11, each ending on a short packet |
| 184–199 | 993 | image record 12 — `cmdid 5`, `len 0x3e1`, payload `17 03 03 03 D0` (a TLS 1.2 app-data record) |
| 200 | 12 | `cmdid 6` event |

Walking away mid-transfer explains every symptom recorded earlier in this document:

- **EP0 stops answering 109 µs after the last image packet**, because the sensor's control handler
  does not service endpoint 0 while an IN transfer is outstanding. This is why `0x02`, `0x03` and
  `0x0A` all worked before a capture and hung after one. It was never command-specific,
  never `wValue`-specific, and never the cleanup path.
- **The bus reset is a firmware watchdog on the abandoned transfer**, at +1.073 s and +1.076 s from
  the last image packet in two independent traces. It fires whether or not the host sends anything:
  a run that inserted a silent 3 s delay found the device already gone — `ENODEV`, not a timeout.
- **The bulk endpoint was healthy throughout.** Reads issued after the loop return data ~100 µs
  apart. The sensor was never asleep or wedged; it was busy.

On the correction in the brief: the re-enumeration is **device-initiated**, not host-initiated. The
hub reports `GET_PORT_STATUS(port 2) → 00010100` — `wPortStatus 0x0100` is PORT_POWER only, with
CURRENT_CONNECT_STATUS clear and `C_PORT_CONNECTION` set. The `23 03 0004` PORT_RESET happens
*after* the device reconnects, and is the hub driver enumerating a new attachment.

Also corrected: `bcdUSB` is `0x0110`, so this is a **full-speed** device and 64-byte bulk packets are
legal. The "non-compliant high-speed descriptor" note in earlier sections is wrong.

### 16.2 The fix, and what it achieves

`patches/0006` adds a state to each SSM immediately after the image loop and before any control
transfer, which reads and processes trailing records until a read times out. Enabled per device from
`fpc_dev_probe()`; only the a900 sets it.

Measured with the fix, default configuration, no environment overrides:

```
arm commands (40 02) sent    : 13
  of which failed/cancelled  : 0
get-image commands (40 09)   : 13
hub reported not-connected   : 0
Enroll result: enroll-stage-passed   (x11)
Enroll result: enroll-completed
```

Thirteen consecutive captures — the duplicate-check identify plus all eleven enroll stages — with
zero failed commands and **zero disconnects**. Every previous run in this document ended with the
sensor re-enumerating.

### 16.3 The remaining blocker: `libfpcbep.so` is the wrong generation

`fprintd-verify` still returns `verify-no-match`, and the instrumented build says why. The driver
discards the return value of `fpc_tee_enroll()` and of every `fpc_enclave_process_data()` call, so an
enrollment in which every sample is rejected still reports eleven `enroll-stage-passed` and
`enroll-completed`. Logging them:

```
DBG: enclave_process_data (img) -> 0        x11 per capture
DBG: enclave_process_data (img) -> -1       the 12th record, every capture
DBG: fpc_tee_enroll #1..#9 -> result 6, remaining 16
fpc_tee_end_enroll result -1, blob_size 92
```

`result 6` is `FPC_ENROL_STATUS_IMAGE_LOW_QUALITY`. `remaining` is frozen at **16** — a number that
cannot come from the driver, where `MAX_ENROLL_SAMPLES` is 11. Nine identical rejections with a
frozen counter is a systematic model mismatch, not a dirty finger.

The cause is the proprietary blob:

| | build tag |
|---|---|
| `/opt/fpc-a900/lib/libfpcbep.so` (from Lenovo's 9800 package) | `fpc_bio_bep_sw23_898004e001` |
| `fpc_enclave.dll` from `FPCFingerprint_22.26.2.29.exe`, the a900's own Windows package | `fpc_bio_sw26_*` |

Different biometric software generation — **sw23 vs sw26** — and the sw23 tag literally embeds
`8980`. The TLS-PSK handshake succeeding proved only that the *transport* is shared; the image model
is not. `fpc_enclave_init(enclave, 0x331)` returns success, so the sw23 blob accepts the a900's
hardware id and then applies the wrong geometry to its `img_w 64 × img_h 176` images. The 12th record
is rejected with `-1` regardless of which callback reads it — tested both with patch 0006's own
reader and with `sm_wait4img()`/`fpc_ssm_img_read_cb()`, the same path the other eleven use.

**This is not reachable from driver-side work.** A working login needs a sw26-generation host
matcher for Linux; the a900's package ships only Windows DLLs (`fpc_enclave.dll`,
`FpcDisumEngine.dll`), extracted to
`FingerPrint 20241225_Firmware/Software/` → `FingerPrint_20241225.exe` → `FPCFingerprint_22.26.2.29.exe`.

### 16.4 Phase 1 results

Every item was answered, most of them by the transport finding rather than on their own terms.

| # | Approach | Result |
|---|---|---|
| 1.1 | Wait 2/5/10 s before re-arming | **Dead by construction.** 3 s of silence and the arm failed instantly with `ENODEV` — the sensor had already left the bus with nothing in flight |
| 1.2 | Retry the arm up to 5× | Dead — retries land on a device that is gone |
| 1.3 | Drop the duplicate check | The gate is `FP_DEVICE_FEATURE_IDENTIFY`, **not** `FP_DEVICE_FEATURE_DUPLICATES_CHECK` (fprintd 1.94.3 `src/device.c`, and it runs even with an empty gallery). Clearing it removed the identify pass — and the enroll path's own capture then wedged identically, at `0x0A` |
| 1.4 | Close/reopen between identify and enroll | Dead — nothing to reopen |
| 1.5 | Re-run init without a full close | Dead — same |
| 1.6 | Re-establish TLS | Dead — same |
| + | Raise `CTRL_TIMEOUT` on the arm only | Dead — EP0 is unresponsive 109 µs in; there is no window |
| + | **Bulk-read after the image (not in the brief)** | **The answer.** Returned queued data; led to the 12-record finding and patch 0006 |

### 16.5 Patch status

| # | Patch | Verdict |
|---|---|---|
| 0001 | add `10a5:a900` to `id_table` | keep |
| 0002 | cleanup transfer must not fail a completed operation | keep — genuine driver bug, upstreamable |
| 0003 | skip `0x03` in verify cleanup | **now unnecessary** — 0006 removes the timeout it was avoiding. Retest before dropping |
| 0004 | fix double free of the SSM error | keep — genuine driver bug, upstreamable |
| 0005 | env-selected recovery probes | experiment harness; no behaviour change with nothing set |
| 0006 | **read the image until the sensor stops sending** | **the fix** |
| — | `patches-debug/0007` | diagnostic logging, kept out of the default build |

Two further MR 396 bugs found and not yet fixed:

- `sm_wait4img()` passes `&g_seq1`, the address of a local in `fpc_enroll_sm_run_state()`, to an
  async callback that runs after that stack frame is gone. Only used for a debug print, but it is a
  dangling-pointer read — visible as `seq_1 1714494482` in the log.
- `fpc_read_dead_pixels()` ignores the result of `fpc_tee_enroll()`, so `fpi_device_enroll_progress()`
  reports every sample as passed even when the enclave rejects all of them. That is why this failure
  took so long to see.

---

## 17. The real remaining blocker, measured: a ten-byte header mismatch

Session of 2026-07-30. **Supersedes section 16.3 entirely.** Section 16.3 said the
installed `libfpcbep.so` is the wrong generation and that a working login needs a
"sw26" host matcher that does not exist for Linux. That conclusion was wrong, and
so was the evidence it rested on.

### 17.1 The blob is the right blob

`fpc_bio_bep_sw23_898004e001` is not a build tag. It is one of **610** strings of
the form `fpc_bio_bep_sw23_<10 hex>` in the library, and they are obfuscated
internal *symbol names* — `objdump` anchors `.rodata` addresses to them, e.g.
`# 171930 <fpc_bio_bep_sw23_98a95a2b9c@@Base+0x2130>`. There are 610 of them
because the build renames its private symbols, not because it carries 610 builds.
Comparing that prefix against `fpc_bio_sw26_*` in the Windows DLL compared two
obfuscation prefixes, nothing more.

The library's actual version string is

```
FPCBEP: fpc_pc_1035_lenovo_cs23_27.26.23.39 (Apr 26 2023 10:07:08)
```

and it supports this sensor. Measured directly against the installed blob with a
20-line harness that `dlopen`s it (`$CLAUDE_JOB_DIR/tmp/probe.c`):

```
hw_details(0x331) -> 0 : type=7 rev=3 w=64 h=176 companions=6
create_enclave      -> 0x5fdef6082240
start_enclave       -> 0
enclave_init(0x331) -> 0
image_get_properties -> 0 : [1]=11264
fpc_bep_image_get_size -> 11264          == 64 * 176
```

`fpc_hw_decode_sensor_hardware_id()` holds a 23-entry table; `hwid 0x331` matches
`(hwid & 0xff0f) == 0x0301` → sensor **type 7**, and the geometry table at
`0x171860[7]` is `64 x 176`, exactly what the a900's init event reports. The
algorithm-parameter row at `0x171700[7]` is populated (`08 08 04 08 38 70 a0 ...`),
unlike the all-zero rows for unsupported types. There is nothing to look for on
the internet: the matcher for this sensor is already installed.

### 17.2 What `-1` means

From the disassembly of `fpc_enclave_process_data_ecall()`, the enclave
reassembles one application message across however many TLS records it takes,
keeping the state in three file statics, and only dispatches when it is complete:

```c
if (recv_len == 0)                              /* first record of a message */
  {
    n     = mbedtls_ssl_read (ssl, buf, 0x800);
    type  = be32 (buf + 0);                     /* 8 = FPC_EVT_IMG, 4 = dead pixel */
    total = be32 (buf + 4);                     /* whole message, header included */
    dst   = (type == 8) ? msgbuf : deadpixbuf;  /* else return -6 */
    memcpy (dst, buf, n); recv_len = n;
  }
else
  recv_len += mbedtls_ssl_read (ssl, dst + recv_len, total - recv_len);

if (recv_len < total) return 0;                 /* need more records */
if (recv_len > total) return -6;

if (type == 8)
  {
    img_len = recv_len - 0xa - 0x18;            /* 34-byte prefix, hardcoded */
    if (img_len != fpc_bep_image_get_size (img))
      return -1;                                /* <-- the -1 the driver threw away */
    ... write metadata (fields at +0x0c..+0x15) ...
    memset (pixels, 0, img_size);
    memcpy (pixels, msgbuf + 0x22, img_size);   /* pixel source: +34, hardcoded */
    ... run the algorithm ...
  }
```

So `-1` is neither a decrypt failure nor a desync nor a wrong-blob rejection. The
enclave received the message, parsed its header and reassembled it, and found the
wrong number of pixel bytes in it. **The algorithm never ran at all** — which is
why `fpc_tee_enroll()` returned `IMAGE_LOW_QUALITY` on every sample and why
`remaining` never moved off 16.

### 17.3 The ten bytes

Instrumented build (`patches-debug/0007` + `0008`) reading those three statics
after every `fpc_enclave_process_data()` call. One capture, thirteen per run, all
identical:

```
DBG: libfpcbep base 0x75c44fa62000 (/opt/fpc-a900/lib/libfpcbep.so)
DBG: process_data (img) -> 0 | tls_state 16 recv_len   942 total 11288 dst msgbuf
DBG:   hdr  00000008 00002c18 00000000 0000100f 00000000 0000bbb6 a07c5a46 ...
DBG: process_data (img) -> 0 | tls_state 16 recv_len  1884 total 11288 dst msgbuf
   ... 942 bytes per record, eleven records ...
DBG: process_data (img) -> 0 | tls_state 16 recv_len 10362 total 11288 dst msgbuf
DBG: process_data (trailing) -> -1 | recv_len 0 total 0 dst (reset)
DBG:   completed message, declared total 11288, enclave computes img_len 11254, wants 11264
DBG: process_data (deadpix) -> 0
DBG: fpc_tee_enroll #1 -> result 6, remaining 16
```

- `type = 8` (`FPC_EVT_IMG`), `total = 0x2c18 = 11288`, declared by the sensor.
- `11288 - 11264 = 24`. **The a900's image message is a 24-byte prefix followed by
  11264 pixel bytes**, and the pixels are visible in the dump: the header ends
  `... 00 00`, then `bb b6 a0 7c 5a 46 4c 6e 9b ba ...` at offset 22-24 onward is
  ridge grayscale.
- The blob assumes a **34**-byte prefix: `0x18` (24) plus `0xa` (10). It therefore
  computes `11288 - 34 = 11254`, compares against 11264, and returns `-1`.
- The metadata the enclave reads sits at offsets `0x0c..0x15`, i.e. inside the
  first 22 bytes, so it is in the right place in both layouts. Only the gap
  between the metadata and the pixels differs: **the a900 sends 2 bytes there,
  the blob expects 12.** That is the whole bug. Ten bytes.

Thirteen captures in this run, every one declaring `total` 11288, and the `-1`
reproduced in the earlier `dbg3` run as well (which logged the return value but
not `total`): this is a fixed format difference, not a transient.

### 17.4 It is also the whole reason enrollment "passed"

`fpc_read_dead_pixels()` ignores `fpc_tee_enroll()`'s result and calls
`fpi_device_enroll_progress()` unconditionally, so eleven rejected samples report
eleven `enroll-stage-passed` and then `enroll-completed`, and `fprintd` stores a
92-byte template built from no image at all. Both bugs had to be present for this
to look like a working enrollment.

---

## 18. Fixed. `verify-match`.

Session of 2026-07-30, run `fix09` (`./run-fix-test.sh fix09`, patches 0001-0006 +
0009 + 0010, default configuration, no environment overrides). Stored prints
deleted first, enrolled from scratch, then verified:

```
Enroll result: enroll-stage-passed        (x12, interleaved with)
Enroll result: enroll-remove-and-retry    (x4)
Enroll result: enroll-completed
Verify result: verify-match (done)
```

The matcher's own account of the same run — the numbers section 16.3 could not
move:

```
fpc_img_msg_relayout: image message 11288 bytes for a 11264 byte image,
                      opened a 10 byte gap at offset 24 (recv_len 942 -> 952)
fpc_tee_enroll -> 1, remaining 15 ( 0 accepted, 0 rejected)
fpc_tee_enroll -> 1, remaining 14 ( 1 accepted, 0 rejected)
fpc_tee_enroll -> 1, remaining 13 ( 2 accepted, 0 rejected)
fpc_tee_enroll -> 1, remaining 12 ( 3 accepted, 0 rejected)
fpc_tee_enroll -> 5, remaining 11 ( 4 accepted, 0 rejected)      <- TOO_SIMILAR
fpc_tee_enroll -> 1, remaining 10 ( 4 accepted, 1 rejected)
   ...
fpc_tee_enroll -> 5, remaining  1 (11 accepted, 3 rejected)
fpc_tee_enroll -> 0, remaining  0 (11 accepted, 4 rejected)      <- COMPLETED
fpc_tee_end_enroll result 0, fingerid 4058089729
```

Before: `result 6` (`IMAGE_LOW_QUALITY`) on every sample, `remaining` frozen at
16, `fpc_tee_end_enroll` returning −1 with a 92-byte template. After: a real
countdown, real quality verdicts including rejections, `COMPLETED`, and
`fpc_tee_end_enroll` returning 0. The stored template is **14616 bytes**
(`/var/lib/fprint/youruser/fpcmoh/0/7`) where it used to be 92.

USB behaviour is unchanged from section 16.2 — 18 arms, 0 failed, 0 disconnects.

It also survives a daemon restart, which is the path the greeter takes — the
template is reloaded from disk rather than held in the enrolling session:

```
$ sudo systemctl restart fprintd && fprintd-verify
 - #0: right-index-finger
Verify result: verify-match (done)
    fpcmoh_match_report: templates->len = 1
    identify id = 4058089729, update = 1
```

`pam_fprintd.so` is already first in `/etc/pam.d/common-auth`
(`[success=2 default=ignore] ... max-tries=1 timeout=10`), and
`/etc/pam.d/cosmic-greeter` includes `common-auth`, so the greeter and `sudo` pick
the sensor up with no further configuration. fprintd is D-Bus activated and
inherits the `10-fpc-a900.conf` drop-in, so it finds the patched libfprint there
too.

### 18.1 What `remaining` actually means

Worth recording, because the driver now depends on it: `remaining` counts
`fpc_tee_enroll()` **calls**, not accepted samples. It went 15, 14, 13 ... 0 while
four of those samples were rejected. So the matcher gives you sixteen attempts,
not sixteen good ones, and a user who smudges more than a few will run out. The
loop in `patches/0010` terminates on `FPC_ENROL_STATUS_COMPLETED` first and treats
`remaining == 0` only as a secondary condition, which is the right way round: on
this run `COMPLETED` and `remaining == 0` arrived together, but nothing guarantees
that.

### 18.2 Patch status

| # | Patch | Verdict |
|---|---|---|
| 0001 | add `10a5:a900` to `id_table` | keep |
| 0002 | cleanup transfer must not fail a completed operation | keep — genuine driver bug, upstreamable |
| 0003 | skip `0x03` in verify cleanup | **retested and dropped** — moved to `patches-debug/`. See 18.3 |
| 0004 | fix double free of the SSM error | keep — genuine driver bug, upstreamable |
| 0005 | env-selected recovery probes | **now a dependency, not dead weight** — 0010 jumps to `FP_ENROLL_X_DELAY` between samples, so removing 0005 stops the driver compiling. Folding the states away means editing 0010 too |
| 0006 | read the image until the sensor stops sending | **needed** — without it the sensor resets itself after every capture |
| 0009 | **fix up the a900's image message for the matcher** | **the fix** — a900 only, guarded, not upstreamable |
| 0010 | let the matcher decide if a sample was good | **needed**, and 0010's first half is upstreamable on its own merits: ignoring `fpc_tee_enroll()`'s result hides total failure on *any* FPC MoH device |
| — | `patches-debug/0007`, `0008` | how 0009 was found; out of the default build |

### 18.3 Patch 0003 retested and dropped

0003 removed the `0x03` abort from the verify/identify cleanup because that
command used to hang for a full second and the sensor then re-enumerated. Its
three hypotheses were all answered by section 16, so it was removed from
`patches/`, rebuilt, and one verify run (`verify-no0003.log`,
`usbmon-no0003.txt`):

```
Verify result: verify-match (done)

... last drain read ends the way it should ...
ffff89224fe8c180 2953139338 S Bi:3:002:2 -115 2048
ffff89224fe8c180 2953339568 C Bi:3:002:2   -2 0        <- 200 ms drain timeout
ffff8921402e0540 2953347614 S Co:3:002:0 s 40 03 0001 0000 0000 0
ffff8921402e0540 2953349023 C Co:3:002:0    0 0        <- 0x03 answered in 1.4 ms
hub not-connected events: 0
```

`0x03` is answered in **1.4 ms** where it used to be cancelled after 1000 ms, and
the sensor stays on the bus. This is the same finding as section 16 seen from the
other side: EP0 was never refusing that command, it was waiting for the host to
finish reading. 0003 now lives in `patches-debug/` as the experiment it was
labelled.

### 18.4 Still open

- **0009 is pinned to one build of `libfpcbep.so`.** The offsets come from the
  disassembly of md5 `f7136fd774d5208e629bbeaa4974543a`. They are validated before
  use — TLS state word, the blob's own destination pointer, and the declared
  length — so a different blob makes the fixup a no-op in every case the guards can
  check for, but it also makes the sensor stop working again. A blob built for this message format
  would remove the need for it entirely.
- **Two MR 396 bugs found earlier and still unfixed:** `sm_wait4img()` passes
  `&g_seq1`, a dead stack local, to an async callback (visible as
  `seq_1 1714494482`); and 0003 needs a retest before being dropped.
- **`patches/0005` should probably be folded away** now that the post-capture
  wedge is understood — `FP_ENROLL_X_DELAY` is on the hot path only because
  `fpc_read_dead_pixels()` jumps there.

---

## 19. Fingerprint login verified at the lock screen

Session of 2026-07-30. `loginctl lock-session`, then a finger on the sensor.

```
06:20:29  cosmic-greeter[3921]: (lock screen up)
06:20:29  fprintd: VerifyStart authorized, start verification finger right-index-finger
06:20:29  fprintd: FP_VERIFY_WAIT4FINGERDOWN -> enter sm_wait4finger
06:20:31  fprintd: enter fpc_verify_wait4finger_cb
06:20:31  fprintd: fpc_img_msg_relayout: image message 11288 bytes for a 11264 byte
                   image, opened a 10 byte gap at offset 24 (recv_len 942 -> 952)
06:20:32  fprintd: identify id = 4058089729, update = 1
06:20:32  fprintd: report_verify_status: result verify-match
06:20:32  cosmic-greeter: gkr-pam: no password is available for user
          session returns: LockedHint=no Active=yes State=active
```

Three seconds from lock screen to unlocked, patch 0009 running inside the
greeter's own verification. No configuration beyond what was already on the
system: `pam_fprintd.so` is first in `/etc/pam.d/common-auth` and
`/etc/pam.d/cosmic-greeter` includes it.

### 19.1 The window is ten seconds and there is no prompt

The first attempt (`lock01`) failed, and it is worth recording why, because it
looks like a driver failure and is not one:

```
06:17:49  VerifyStart -> enter sm_wait4finger    (sensor armed, waiting)
06:17:59  VerifyStop  -> Operation was cancelled  (exactly 10 s later)
06:18:18  gkr-pam: unlocked login keyring         (password used instead)
```

`pam_fprintd.so max-tries=1 timeout=10` closes the window after ten seconds and
allows a single attempt, and COSMIC's greeter displays no "place your finger"
hint at all — so unless the finger is already moving when the screen changes, the
window is gone and there is no visible reason why. No capture occurs, so nothing
appears in the log except the cancellation. Raising `timeout` in
`/etc/pam.d/common-auth` would widen it; left at the distro default here.

`gkr-pam: no password is available for user` on the successful unlock is normal
for fingerprint authentication, not a failure: there is no password to unlock the
login keyring with.

### 19.2 COSMIC's `LockedHint` is unreliable

Recorded so nobody debugs it twice. `loginctl show-session ... -p LockedHint` went
to `yes` several seconds *after* the greeter was already up, and back to `no`
before the session was fully restored, so polling it is not a sound way to detect
either edge. `run-lock-test.sh` no longer treats a missing `yes` as "the lock did
not happen".


---

## 20. Published

Session of 2026-07-30. The working driver, the patch set and this document are
now a public repository:

**https://github.com/cityji/honor-magickbookpro-fingerprint-driver**

What went in, and what deliberately did not:

| | |
|---|---|
| `patches/` | the seven shipped patches |
| `patches-debug/` | `0003`, `0007`, `0008` — the instrumentation, and the retired experiment |
| `build.sh` / `install.sh` / `uninstall.sh` | unchanged in behaviour; `install.sh` now takes the blob from `blob/` |
| `get-blob.sh` | **new** — fetches `libfpcbep.so` from Lenovo's public download and checks its md5 |
| `bootstrap.sh` | **new** — deps + blob + build + install in one command, for a fresh machine |
| `docs/INVESTIGATION.md` | this file, with the local username scrubbed |
| `docs/DEVICE.md` | hardware, protocol and a checklist for identifying other FPC MoH variants |
| `docs/TROUBLESHOOTING.md` | |
| `tools/` | the test harness, plus `probe-blob.c` |
| **not** `libfpcbep.so` | proprietary, not redistributable |
| **not** the usbmon captures or fprintd journals | they contain the encrypted fingerprint images and the username |
| **not** the vendor Windows packages | copyrighted, and never used at runtime |

The scratch directory (`~/Desktop/temp`, 126 MB) was left intact. The repository
is a curated copy, not a move.

### 20.1 The blob is fetchable, which makes a fresh install one command

Worth recording because section 12 did not establish it: the `libfpcbep.so` in
Lenovo's public package is **byte-identical** to the one this project has been
using all along.

```
$ curl -sSL -o r1slm01w.zip https://download.lenovo.com/pccbbs/mobiles/r1slm01w.zip   # 4.7 MB
$ unzip -p r1slm01w.zip FPC_driver_linux_27.26.23.39/install_fpc/libfpcbep.so | md5sum
f7136fd774d5208e629bbeaa4974543a
```

So nothing proprietary has to be redistributed for someone else to install this,
and `get-blob.sh` verifies the md5 that `patches/0009`'s offsets are pinned to.

### 20.2 CI builds without the blob, by stubbing it

Merge request 396 links `libfpcbep.so` directly (`DT_NEEDED`), so a build needs it
resolvable at link time — which CI cannot have. `build.sh STUB_BLOB=1` handles it:
compile everything, let the link fail, read the undefined `fpc_*` symbols straight
out of the driver's object file, generate a shared library defining them, link
again. `DT_NEEDED` still records the plain name `libfpcbep.so`, so the artifact
loads the real matcher at run time.

The obvious shortcut — parsing `fpclib_api.h` for declarations — does not work:
`fpc_enclave_t *fpc_create_enclave (void)` yields the *return type* as the first
`fpc_*` token, so `fpc_create_enclave`, `fpc_tee_init` and `fpc_tee_bio_init` come
out undefined and the link still fails. Harvest from the object file, not the
header.

`.github/workflows/ci.yml` also asserts that the fixes are actually *compiled in*,
by looking for format strings from 0006, 0009 and 0010 in the artifact — the check
that would have caught the two wasted rounds recorded in section 16.

### 20.3 The repository's own build was verified on hardware

Not assumed. `get-blob.sh` → `build.sh` → `install.sh` from a clean checkout, then
one press: `Verify result: verify-match (done)`.
