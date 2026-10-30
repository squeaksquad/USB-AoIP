# Host-driver spike: is a driver-anchored round trip deterministic?

2026-10-30. Design and plan; nothing built yet. The handoff is authoritative
for results.

## Why

At 48 kHz the DAW-timeline figure is fixed for as long as an app keeps the
device open, and drawn anew at each open: 481 to 525 samples on 2026-10-28,
513 to 555 on 2026-10-29, a band of about one USB frame. Three results place
the draw on the Mac:

- Fixing the owner's pickup phase to a packet (`rate6`) left the range as wide.
- A silent client holding the device open fixed the figure, until that client
  restarted.
- Counting frames per stream on the Pi (`--open-phase`, handoff 2026-10-29
  23:42) gives a Pi-side figure that is fixed within an open but does not
  predict the harness across opens (two opens with the same Pi figure read 525
  and 555).

So the class driver (`usbaudiod` / AppleUSBAudio) anchors its input and output
timelines independently at each IO start. A vendor driver owns that anchoring.
The spike asks, before any DriverKit or ASIO work, whether owning it is enough.

## The question

If the host starts the IN and OUT isochronous streams on the same bus frame
and numbers samples from that frame, is the round trip (IN index minus OUT
index of the same impulse) the same on every open?

## Phases

0. **Probe.** Take the gadget's audio interfaces from the class driver with
   IOUSBHost (`IOUSBHostObjectInitOptions.deviceSeize`, as root). Apple
   documents seizing as needing `com.apple.vm.device-access`, a restricted
   entitlement, so this may be refused. Fallback: an experiment gadget whose
   audio interfaces report vendor class `0xFF`, so no Apple driver claims them
   (a small `f_uac2` patch beside the installed module set, own name, bounded
   test, rollback). Either way the Mac has no USB-AoIP device during the spike.
1. **Stream.** Clock to 48 kHz (class `SET_CUR`), alt 1 on both streaming
   interfaces, the feedback endpoint (16.16) sizes each OUT packet, both pipes
   queued with microframe transaction lists that begin on the same bus frame.
   Counts of OUT samples sent and IN samples received from that frame. Late
   queues are counted as dropped microframes, never folded into the lag.
2. **Measure.** Each open sends impulses on channel 1 at known OUT indices and
   finds them on IN channel 1; lag = IN index minus OUT index, the same for
   every impulse in an open or the open is invalid. 20+ opens a run, each a full
   stop and restart of both pipes.
3. **Phase A** (no Pi change): beside the owner with `--open-phase`. Pass: the
   tool's lag minus the owner's per-open sum (`x` + `rx_mean`) is constant
   across opens.
4. **Phase B** (own decision): an owner candidate with `--count-anchor N`,
   which corrects the return queue once per open so that frames written minus
   frames sent is N. Pass: the tool's lag is identical (at most 1 sample) over
   20+ opens. This is an audio-path change; nothing is installed from the spike.
5. **Phase C:** the same across endpoint and gadget restarts, to see whether
   the per-owner-start draw of 2026-10-09 remains (if so, the owner also anchors
   its transmit side to Dante's media clock, planned then).
6. **Write-up:** go / no-go for a DriverKit driver (macOS) and an ASIO driver
   over WinUSB (Windows), both presenting the device as `USB-AoIP`.

## Names and identity

The device is `USB-AoIP` (configfs `usb-aoip`) from
`work/pi-tuning/install-gadget-usb-aoip.sh`. VID/PID stay `0x1d6b:0x0104`
(Linux Foundation, prototype only) until pid.codes assigns a product ID under
`0x1209`; the repo is public and Apache-2.0, which pid.codes requires. Open
question for the real driver, not the spike: whether Apple grants the DriverKit
USB transport entitlement for the shared `0x1209` vendor ID.

## Verification

- `swift build -c release` here; `probe` says how the interfaces were taken.
- One `stream`: zero dropped microframes, OUT feedback near 6 samples a
  microframe, the impulse back on channel 1.
- `measure 24`: a JSON per open and a summary; pass is a spread of 0 (at most 1)
  in the phase's figure.
- After: the class driver has the device again (or the vendor-class rollback
  ran), `usb16x16-dante` active with the start check ok, a noise probe at 32
  clean.

## Results

**Step 0, probe: PASS (2026-10-30 00:53 UTC).** `sudo usb-aoip-spike probe` captured the device
from the class driver (`IOUSBHostObjectInitOptionsDeviceCapture` as root, no entitlement, as
`IOUSBHostDefinitions.h` says), opened both streaming interfaces at alt 1 and released it; the
release reset the device (Pi kernel: new address 11 at 00:53:05) and `USB-AoIP` came back to the
class driver. The vendor-class fallback is not needed. What the host gets at alt 1:

| Interface | Endpoint | Type | Size | Interval |
|---|---|---|---|---|
| 1 (Mac output) | 0x01 OUT data | isochronous, async | 624 bytes | bInterval 1: every 125 us microframe |
| 1 | 0x82 IN feedback | isochronous | 4 bytes (16.16) | bInterval 4: every 8 microframes (1 ms) |
| 2 (Mac input) | 0x83 IN data | isochronous, async | 624 bytes | bInterval 1 |

624 bytes is 13 frames of 16 channels x 3 bytes, the size the rate list (96 kHz) sets at every
rate; at 48 kHz a microframe carries 6 frames on average, the feedback saying when it is 5 or 7.
The bus frame number (626613725 at the probe) counts 1 ms frames; microframe placement comes
from the transaction-list form of the isochronous request (`IOUSBHostIsochronousTransaction`).
While the probe held alt 1 the owner counted one return prime and 24 frames of `rx_overflow`:
selecting alt 1 alone starts the gadget's IN side.

**Step 1, stream: PASS (2026-10-30 01:01-01:02 UTC).** `sudo usb-aoip-spike stream 10`, three
opens on the installed endpoint (owner a15a9d84), each 10 s, both directions anchored on one bus
frame: 80,192-80,224 transactions each way, none failed; feedback one transaction per 1 ms frame
(bInterval 4), 6.0000-6.0001 frames a microframe; 90 impulses sent and found in each open.

| Open | Lag (samples) | Spread within the open | Owner `tx_prime_found` |
|---|---|---|---|
| 1 | 382 | 0 | 90 |
| 2 | 371 | 0 | 107 |
| 3 | 372 | 0 | 106 |

Across opens: 11 samples, against 37-44 under the class driver. The first run (4.3 s, lag 396 x33)
ended on a late feedback request (IsoTooOld) when the queue was 12 ms deep; feedback lateness is
now skipped and the queues are 32 ms deep. The owner's transmit prime moved with the lag in all
three opens (higher found, lower lag), so what is left looks like the Pi's per-open start; Phase A
reads it with `--open-phase`.
