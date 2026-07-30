# The hardware

Everything here was measured on the device, from USB captures, the driver's own
logs, and the disassembly of the host matcher. If you have a different laptop
with a Fingerprint Cards match-on-host sensor, this is the page to compare
against.

## Identity

| | |
|---|---|
| USB id | `10a5:a900` |
| Vendor | `10a5` = Fingerprint Cards AB (FPC) |
| Product string | `FPC Sensor Controller L:0002 FW:22.26.2.29` |
| `bcdUSB` | `0x0110` — **full speed**, so 64-byte bulk packets are legal |
| Interface | 1 interface, 1 alt setting |
| Bulk IN | endpoint `0x82` |
| Control | vendor requests, `bmRequestType 0x40` (out) and `0xC0` (in) |
| Found in | HONOR MagicBook series (the Windows package that matches this firmware is `HONOR MagicBook X14&X16_FingerPrint_20241225`) |
| Sibling | `10a5:9800`, the same architecture, in various Lenovo ThinkBook/IdeaPad models |

`lsusb` output looks like:

```
Bus 003 Device 017: ID 10a5:a900 Fingerprint Cards AB
```

## Sensor

The controller reports its own geometry in the init event, and the host matcher
independently agrees:

| | |
|---|---|
| Hardware id | `0x331` |
| FPC sensor type | **7** (from the matcher's own hwid table: `(hwid & 0xff0f) == 0x0301`) |
| Revision | 3 (`(hwid & 0x00f0) >> 4`) |
| Image | **64 x 176**, 8 bits per pixel, 11264 bytes |
| Firmware version string | `22.26.2.29` |

You can confirm this against the matcher without any hardware, using
`tools/probe-blob.c`:

```
$ gcc -o probe tools/probe-blob.c -ldl && ./probe
hw_details(0x331) -> 0 : type=7 w=64 h=176
enclave_init(0x331) -> 0
fpc_bep_image_get_size -> 11264
```

The matcher's own version string, for reference:

```
FPCBEP: fpc_pc_1035_lenovo_cs23_27.26.23.39 (Apr 26 2023 10:07:08)
```

It carries a static table of 25 sensor types with geometries. Types with a
populated algorithm-parameter row are supported; several rows are all zero.
Useful if you are checking whether a *different* FPC sensor stands a chance:

| type | geometry | | type | geometry |
|---|---|---|---|---|
| 1 | 192 x 192 | | 12 | 64 x 80 |
| 2 | 160 x 160 | | 14 | 64 x 80 |
| 3 | 112 x 88 | | 15 | 35 x 160 |
| 4 | 56 x 192 | | 16 | 96 x 96 |
| **7** | **64 x 176** | | 19 | 36 x 160 |
| 8 | 64 x 80 | | 20 | 36 x 160 |
| 9 | 128 x 112 | | 21 | 32 x 160 |
| 11 | 60 x 128 | | 23 | 32 x 132 |
| | | | 24 | 80 x 100 |

## Architecture: match on host

This is the part that surprises people. **The sensor does no matching.** It has
no template storage and no biometric algorithm. It captures an image and ships
it to the host, and a closed userspace library does everything else.

```
   sensor firmware                    host
   ---------------                    ----
   capture image
   ---- TLS-PSK 1.2 ------------->    libfpcbep.so
                                        decrypt
                                        run biometric algorithm
                                        build / match template
   <--- TLS-PSK 1.2 --------------      enrol and identify commands
                                      fprintd stores the template in
                                      /var/lib/fprint/<user>/fpcmoh/
```

Consequences worth knowing:

- **The fingerprint image crosses the USB bus.** It is encrypted, but the key
  material lives in a userspace library on the same machine.
- **No blob, no fingerprint reader.** There is no fallback path. The image
  format is not documented and the algorithm is not reimplementable in any
  practical sense.
- **Templates are host-side files**, not sensor-side slots, so
  `/var/lib/fprint` is the whole of your enrolled data.

### The TLS session

The **sensor is the TLS client and the host is the server**, which is the
opposite of what you would expect. The pre-shared key lives inside
`libfpcbep.so`; the identity string on the wire is `Disum PSK`.

| | |
|---|---|
| Version | TLS 1.2 (`0x0303`) |
| Cipher suite | `0x00AE` = `TLS_PSK_WITH_AES_128_CBC_SHA256` |
| Record overhead | 16 byte explicit IV + 32 byte HMAC + 1..16 pad |

The same PSK covers both `a900` and `9800`, which is how this project got as far
as a working TLS session before anything else was understood.

## Protocol sketch

Control commands, `bmRequestType 0x40`, `bRequest` as follows (from merge
request 396's header, confirmed on the wire):

| `bRequest` | name |
|---|---|
| `0x01` | init |
| `0x02` | arm / start capture |
| `0x03` | abort |
| `0x05`, `0x06` | TLS handshake transport |
| `0x08` | indicate system power state |
| `0x09` | get image |
| `0x0A` | dead pixel data |
| `0x0C` | get KPI |

Everything else — enrol, identify, template storage — is not a USB command. It
is an application-level message *inside* the TLS session, handled by the matcher.

### Bulk records

Reads on endpoint `0x82` return framed records:

```
struct evt_hdr { be32 cmdid; be32 length; be32 status; }   /* 12 bytes */
followed by length-12 bytes of payload
```

`length` **includes** the 12-byte header. `cmdid 5` records carry TLS bytes;
`cmdid 6` is an event with no payload.

One capture on this device is:

| records | bytes each | what |
|---|---|---|
| 11 | 1009 | image, records 1-11 |
| 1 | 993 | image, record 12 |
| 1 | 81 | dead-pixel message |
| 1 | 12 | `cmdid 6`, capture complete |

**Merge request 396 reads only eleven**, because it has eleven fixed read states.
That single fact caused every symptom this project originally chased: the sensor
does not service endpoint 0 while it still has data queued, so the next control
command times out, and ~1.08 s later a firmware watchdog resets the sensor and it
re-enumerates at a new address. `patches/0006` fixes it by reading until the
sensor stops.

### The image message

Inside TLS, the twelve `cmdid 5` records concatenate into one application
message:

```
be32 type    = 8          (FPC_EVT_IMG)
be32 length  = 11288      whole message, this header included
be32 status
...  metadata at offsets 0x0c .. 0x15
...  2 bytes
     pixels, 11264 bytes, starting at offset 24
```

`11288 - 11264 = 24`, so the prefix is 24 bytes. **The matcher expects 34.** It
computes `img_len = recv_len - 0xa - 0x18`, compares that against
`fpc_bep_image_get_size()` and returns `-1` when they differ — and merge request
396 discards that return value, so the algorithm silently never runs, every
sample comes back `IMAGE_LOW_QUALITY`, and enrollment appears to succeed while
producing a template that matches nothing.

`patches/0009` opens a ten-byte gap at offset 24 after the first record lands,
which is the layout the matcher was built for. `docs/INVESTIGATION.md` sections
17 and 18 have the full derivation.

## If you have different hardware

Rough order of things to check:

1. **`lsusb | grep 10a5`.** No `10a5` device means this project is not for you.
   FPC's match-on-*chip* sensors use different ids and a different driver
   (`fpc_mod`, or nothing at all).
2. **Is your id in the driver?** Merge request 396 ships `9800`; `patches/0001`
   adds `a900`. Another id needs one more line in `id_table` plus a probe case.
3. **What geometry does it report?** Enable debug logging and look for
   `fpc_init_evt_handler: hwid(0x...), img_w N, img_h M`. Compare against the
   type table above. If your hwid decodes to a type whose algorithm row is all
   zeros, this matcher build cannot process your images.
4. **How many records per capture?** `(img_w * img_h + prefix)` divided by ~943
   bytes of TLS plaintext per record. If it is not eleven, you need
   `patches/0006`.
5. **What prefix does your firmware send?** Compare `total` in the debug log
   against `img_w * img_h`. If the difference is 34, you need no relayout at all
   and `patches/0009` will correctly disable itself. If it is 24, you are in the
   same position as this device. Anything else and you need to adjust
   `FPC_IMG_MSG_PREFIX_HAVE`.

`patches-debug/0008` is the instrumentation that answers 4 and 5 in one run.
