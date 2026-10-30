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

**Phase A: the draw left with the host anchored is the owner's, not the Mac's (2026-10-30
01:04-01:08 UTC).** Twelve 15 s opens of `stream`, every one intact (no failed transaction, 140 of
140 impulses, spread 0 within the open), beside the `--open-phase` owner (aa340c10, the service's
transport; evidence `outputs/latency/spike-phaseA-20261030/owner.log`):

| Open | Lag | Pi figure `x`+queue | Lag minus Pi figure |
|---|---|---|---|
| 1 | 397 | 143.6 | 253.4 |
| 2-11 | 357, 364, 369, 368, 375, 381, 381, 387, 393, 393 | 102.8-104.4 | 253.0 rising to 289.3 |
| 12 | 351 | 55.8 | 295.5 |

The lag is a sawtooth over the session: about +6 samples an open (opens 18 s apart, about
0.34 samples/s), falling back about 48 (one millisecond) twice. The Pi figure jumps by about one
period exactly at the wraps; lag minus Pi figure rises steadily through them. Mechanism, from
`owner/main.cpp` (the wait at the top of the loop): while no host sends, the loop sleeps on a 1 ms
grid of the Pi's CLOCK_MONOTONIC, and both directions are primed on the first wakes after the host
starts; where the host's first frame falls within that millisecond sets the round trip, and that
phase drifts with the Mac's crystal against the Pi's (about 7 ppm here) and wraps every 48
samples. The host-anchored range over the twelve (351-397, 46) is the class driver's range
(481-525, 44, 2026-10-28; 513-555 on 2026-10-29): so the draw read under the class driver is most
likely this same owner phase, and the handoff's 2026-10-29 conclusion that it lies on the Mac is
in doubt. The 2026-10-28 hold-open result fits either: a held stream never restarts, so the phase
is drawn once.

Next (Phase B, revised): the owner removes the phase itself. At the first wake with both
directions flowing it knows, in Inferno positions, where host OUT frame k went (playback position
minus k, fixed after the prime) and where host IN frame j came from (capture position minus j,
fixed after the rx prime while nothing overflows); the round trip is the far loop (fixed) plus the
difference of those two offsets. One insertion of silence or drop of frames in the IN queue sets
that difference to a chosen constant, once per open. Then test it twice: with this tool (spread at
most 1 across opens), and with the class driver and the harness (`daw_timeline` spread across
opens). If the second also holds, the class driver needs no replacement for determinism.

**Phase B, step 1 (diagnostic): the drift is the gadget's IN start, in whole packets; the far loop
and the owner are constant (2026-10-30 01:31-01:34 UTC).** Owner candidate d84fe83a
(`--impulse-trace`: channel 1 onsets both ways with Inferno positions and indices; evidence
`outputs/latency/spike-imptrace-20261030/owner.log`), twelve 15 s opens of `stream`, eleven intact
(open 10 had 8 failed OUT transactions and is excluded):

| Open | Far loop q - p | Owner share w - k | Lag (tool) | Remainder (gadget) |
|---|---|---|---|---|
| 1 | 114 | 362 | 374 | 12 |
| 2-9 | 114 | 344-345 | 356, 363, 368, 369, 375, 381, 381, 387 | 12, 18, 24, 24, 30, 36, 36, 42 |
| 11-12 | 114 | 345 | 381, 387 | 36, 42 |

The remainder is the number of frames the Mac receives on IN before the first frame from the
owner's queue: 2 to 7 packets of 6, never a fraction, rising by a packet every open or two (the
sawtooth of Phase A, now resolved into packets). So the owner-side correction planned for Phase B
would not touch it. In `u_audio_iso_complete` (6.18, the installed rate-request build) an IN request
carries ring data only when the ALSA playback stream is running at its completion, else what it
held before, and data copied at one completion goes out on that request's next turn; the owner
drops and re-primes its playback stream at every host stop and primes it again before the next
start (`rx_primes` +2 an open). Which of these sets the packet count, and why it drifts with time,
is not read yet. Next: a bounded kernel trace of the IN completions at each open (status, running,
hw_ptr; kprobes on `u_audio_iso_complete`, as `outputs/latency/rate882-dirtest-20261018/trace.sh`
did for SET_CUR; needs sudo on the Pi), then a fix in the owner's priming or in `u_audio`, whichever
the trace names. Service restored 01:41 (a15a9d84, start check ok, no restart).

**Phase B, step 2 (kernel trace of the IN start, 2026-10-30 01:47-01:49 UTC).**
`trace-in-start.sh on 45` on the Pi (kprobes on `u_audio_iso_complete` and the start, stop, trigger
and alt-setting events; it switched itself off; 480,868 lines) beside two `stream 15` opens on the
installed owner a15a9d84: lags 377 and 357. Evidence (first 200 ms of each open, every event and
every failed completion): `outputs/latency/spike-instart-20261030/trace-condensed.txt`.
- The USB start was the same in both opens: the Mac's first IN token about 23.5 ms after alt 1 on
  interface 2, the first IN and the first OUT completion failed (-61, the microframe missed), every
  later one completed; IN and OUT started on the same microframe.
- `uac_pcm_trigger` resets `u_audio`'s ring position to 0 on every start and stop and zeroes the
  request buffers on stop; the owner's playback stream was running before each open (its stop and
  restart come when the host stops, 1 ms apart, and again at the device reset), so no open began
  with the stream stopped.
- Not explained by this run: the two lags differ by 20, not a multiple of 6, with identical USB
  starts, so the owner's share moved between these two opens (the installed owner does not log it).
- A lead that fits the 6-step remainder of step 1: each missed first-microframe OUT packet is 6
  frames the host counts as sent and the owner never receives, and each missed IN request removes
  a leading packet; a count of misses that varies by open would move the lag in steps of 6. Both
  opens here had one of each, so this run cannot show it.
Next, one combined run decides: the `--impulse-trace` owner (d84fe83a) with this trace on, for
120 s (six opens): per open the misses at the start, the owner's share, the far loop and the
remainder together.

**Phase B, step 3 (combined run): the owner's share is set by its transmit prime, exactly; the far
loop is constant; the gadget adds a whole packet some opens (2026-10-30 01:57-01:59 UTC).** Owner
d84fe83a (`--impulse-trace`) in place of the service, `trace-in-start.sh on 120`, six `stream 12`
opens, all intact. Evidence `outputs/latency/spike-combined-20261030/` (owner log; the trace's
first 200 ms of each open, every event and every failed completion).

| Open | Lag | Far loop | Owner share w - k | `tx_prime_found` | share + found | Gadget remainder | USB start |
|---|---|---|---|---|---|---|---|
| 1 | 374 | 114 | 362 | 104 | 466 | 12 | first IN and OUT missed, rest clean |
| 2 | 376 | 114 | 364 | 102 | 466 | 12 | same |
| 3 | 364 | 114 | 352 | 114 | 466 | 12 | same |
| 4 | 375 | 114 | 357 | 109 | 466 | 18 | same |
| 5 | 371 | 114 | 353 | 113 | 466 | 18 | same |
| 6 | 361 | 114 | 343 | 123 | 466 | 18 | same |

The same identity holds for all twelve opens of step 1 (found 104 then 121-122, share 362 then
344-345; the broken open 10 aside): **owner share = 466 - `tx_prime_found`** over 18 opens and two
owner starts. Mechanism (`owner/main.cpp`, `service_tx`, the `armed` branch): the prime lands the
host's first ordinary block (48 frames) so its newest frame ends exactly `lead` (128) ahead of the
Dante clock, dropping the block's oldest frames to fit; it drops `found - 80` of them (0 to 48),
and `found`, the Inferno depth at that wake, depends on where the Dante clock stands against the
owner's idle 1 ms grid. Every dropped frame comes off the round trip the host counts.

Fix, owner only (not written): drop a constant number D of the prime block's oldest frames and
commit the rest at the pointer where it stands, without skipping to `lead`; the host-frame to
Dante-position offset then no longer depends on `found`, and the share becomes 386 - D. D = 24
gives 362 (today's range 343-385), with the depth after the prime 104 to 152 (today 128), never
below today's floor before the next block; if `found` is ever too low to leave the margin, skip
silence as today and count the open as not anchored. The servo then takes the depth to `lead` over
the first seconds without changing the frame mapping (within an open the lag was steady through
every servo transient, spread 0 in every run).

Still open: the gadget remainder, 12 in opens 1-3 and 18 in opens 4-6 with identical USB starts in
all six (the trace shows one missed microframe each way, then clean), drifted 12 to 42 in step 1:
whole packets, set somewhere between `u_audio`'s initial requests and the owner's ring. With the
owner fixed, the lag will move only by these packets; the next look is at what the queue holds at
the host's first poll (the owner's `rx_primes` rose by 1 instead of 2 around open 4).
