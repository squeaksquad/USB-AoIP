# USB 16x16 latency results — 2026-08-31

All measurements are at 48 kHz, 16 channels, packed 24-bit on the Pi, and a
64-frame CoreAudio buffer where the Mac harness is involved.

## CoreAudio baseline

- Device: `USB 16x16`, native 16-input/16-output duplex.
- Current nominal and actual rate: 48 kHz.
- Buffer range: 15–4096 frames; measurement runs used 64 frames.
- Input device latency/safety offset: 74/74 frames.
- Output device latency/safety offset: 50/50 frames.
- Input/output stream latency: 0 frames.

Source: `coreaudio-usb16x16-baseline.json`.

## USB-only reconnaissance

Each point used 20 correlated impulses. Every impulse at a point produced the
same delay and both CoreAudio discontinuity counters remained zero.

| `alsaloop` target | Measured delay | Samples |
|---:|---:|---:|
| 80 ms | 80.5 ms | 3864 |
| 40 ms | 40.5 ms | 1944 |
| 20 ms | 20.5 ms | 984 |
| 10 ms | 10.5 ms | 504 |
| 5 ms | 5.5 ms | 264 |

These short points establish the floor trend; they are not ten-minute
acceptance soaks and did not load the other 15 channels with representative
audio.

## RAVENNA period reconnaissance

The upstream platform loopback ran for ten seconds per point with sink delay
576. All four points completed in `RUNNING` state without XRUN markers.

| RAVENNA period | Measured end-to-end latency |
|---:|---:|
| 384 frames | 20.001 ms |
| 192 frames | 11.999 ms |
| 144 frames | 7.000 ms |
| 96 frames | 5.999 ms |

Source directory: `ravenna-latency-20260831T220648Z`.

## AES67 sink-delay reconnaissance

The RAVENNA period was held at 96 frames while only the generated sink delay
changed. Each point requested ten seconds.

| Sink delay | Result | Disposition |
|---:|---:|---|
| 576 | 5.999 ms before early XRUN | Reject |
| 288 | 5.999 ms | Clean short run |
| 144 | 6.000 ms | Clean short run |
| 96 | 6.000 ms | Clean short run |
| 48 | 4.999 ms | Best clean short run |

The 576 result is not valid: the utility stopped after 75,216 captured frames
with both playback and capture in `XRUN`. The wrapper now rejects any log that
lacks `Success` or contains `Failure`/`XRUN`, even if it also prints a numeric
latency.

Source directory: `ravenna-latency-20260831T221400Z`.

## Accepted RAVENNA-only operating point

- Period: 96 frames.
- Sink delay: 48.
- Duration: 600 seconds.
- Captured frames: 28,800,000.
- Playback frames: 28,800,096.
- Final playback/capture state: `RUNNING`/`RUNNING`.
- End-to-end latency: **4.999 ms**.
- Result: `Success`, with no XRUN/failure marker.

After the soak, the test daemon and `ptp4l` were stopped, the RAVENNA module
was unloaded, the three changed sysctls were restored to `20`, `25`, and
`950000`, and `usb-16x16.service` remained active with UDC
`configured/high-speed`.

Source directory: `ravenna-latency-20260831T222027Z`.

## Remaining measurement boundary

The accepted 4.999 ms number is the Pi RAVENNA platform loopback floor, not the
complete Mac–USB–AES67–Ferrofish digital round trip. USB→RAVENNA,
RAVENNA→USB, and the complete Ferrofish digital return remain to be measured
with the production streams and physical routing.

A first combined probe was rejected before measurement. This Pi build accepts
the documented `alsaloop` period/buffer controls only as long options; `-E` and
`-B` printed invalid-option errors. The wrapper has been corrected to use
`--period` and `--buffer` but has not been rerun. During the same attempt,
macOS did not expose `USB 16x16` through CoreAudio or its USB inventory even
though the Pi UDC still reported `configured/high-speed`. Diagnostic logs are
in `aes67-candidate-20260831T224405Z`.

Re-reading those logs shows the rejected probe was closer to working than the
summary implied. Both `alsaloop` directions started, PTP reported `locked` to
the expected grandmaster, and both pitch servos converged. Only the explicit
period/buffer request was lost: ALSA fell back to a 960-frame buffer with
120-frame USB periods and 128-frame RAVENNA periods. The run produced no
latency number because macOS was not presenting the device, not because the
bridge failed.

## 2026-08-31 second session — probe blockers cleared

Both blockers named above are now resolved and verified rather than assumed.

- macOS enumeration is restored. A fresh read-only CoreAudio inspection
  reproduces the original baseline exactly: 16 in / 16 out, 48 kHz nominal and
  actual, input device latency and safety offset 74/74 frames, output 50/50
  frames, stream latency 0, UID
  `AppleUSBAudioEngine:Bryan DiMaio:USB 16x16:AUDDEV001:1,2`.
- The corrected long options parse on this Pi build. Invoking `alsaloop`
  with `--period 96 --buffer 288 --tlatency 5000` against a deliberately
  invalid card produced only a device-open error, with no invalid-option
  message. The Pi copy of `run-aes67-candidate-safe.sh` hashes identically to
  the corrected repository copy, so no resync is required.
- The Pi is otherwise clean: no `alsaloop`, `aes67-daemon`, or `ptp4l`
  process, the RAVENNA module is unloaded, and `usb-16x16.service` is active
  with the UDC at `configured/high-speed`.

Channel names still report the UAC2 speaker positions (`Front Left`,
`Front Right`, ...). That is the separate descriptor workstream and does not
affect latency measurement.

The combined probe still needs one interactive step, because Pi `sudo`
requires a password. `work/aes67-candidate/measure-aes67-roundtrip.sh`
sequences everything around it: pre-flight, the Pi candidate start, the wait
for its `READY` marker, the CoreAudio impulse measurement, retrieval of the Pi
logs, and post-run cleanup verification.

A valid result also depends on the Ferrofish digitally returning the Pi
transmit streams on its channels 49-64. If that return is not routed, the
harness will capture near-silence and report a low correlation score; that is a
routing gap, not a bridge failure.

## AES67 self-loop on eth0 — rejected, no measurement

Run `selfloop-20260901T005454Z`. The Pi was configured to subscribe to its own
transmit streams so the Ferrofish could be excluded from the path.

Everything up to reception succeeded: PTP locked to the expected grandmaster,
both sinks were built from the daemon's own published source SDPs and accepted
with `PUT` 200 and `add RTP stream success`, IGMP joined `239.69.16.1` and
`239.69.16.2` on `169.254.92.97`, and both `alsaloop` directions ran with the
RAVENNA card streaming 16 channels.

Both sinks reported `receiving_rtp_packet: false`. The RAVENNA driver
transmits directly to the interface and the switch does not return a frame out
of its ingress port, so no packets came back. The run aborted at its
verification gate with exit 36 before measuring, then tore down cleanly.

The premise was wrong, not the configuration. Upstream's self-subscription
runs with `interface_name: "lo"` and a local `ptp4l -i lo` master, so it proves
loopback self-reception only. The accepted 4.999 ms platform figure was
measured on loopback, not on `eth0`.

No latency number was produced and none should be inferred.

## First complete Ferrofish digital round trip — 2026-09-01

The Ferrofish internal routing (`Input 49-64` to `Output 49-64`) was completed
during this session. Multicast flow membership was confirmed in Dante
Controller Device View:

| Flow | Ferrofish transmit channels | Address | Pi sink | USB channels |
|---:|---|---|---:|---|
| 32 | `Output 49-56` | `239.69.121.9:5004` | 0 | 1-8 |
| 31 | `Output 57-64` | `239.69.193.115:5004` | 1 | 9-16 |

### Routing verification

Before the routing was completed, both sinks reported
`receiving_rtp_packet: true` with clean sequence, SSRC, and payload flags while
the captured peak was 0.000111 (about -79 dBFS) against impulses sent at 0.25
full scale. **Packet reception is not proof of audio.** The Ferrofish was
transmitting digital silence. Only the impulse correlation distinguished the
two cases, which is why both checks are required.

### Channel alignment

All sixteen channels measured with 8 impulses each, output channel N to input
channel N, at a 64-frame CoreAudio buffer. Source directory:
`ferrofish-channel-scan-20260901T011505Z`.

| Channels | Captured peak | Delay | Spread |
|---|---:|---:|---:|
| 1-7, 12-16 | 0.178 to 0.199 | 3559 samples, 74.146 ms | 0-1 samples |
| 8-11 | 0.187 to 0.192 | 3563 samples, 74.229 ms | 0-2 samples |

Every channel returned. The mapping is 1:1 with no crossed channels, and the
worst spread across the whole set is 4 samples (83 us), which is alignment
quantization rather than a routing error.

### Measured round trip: 74.15 ms — untuned

This is the first complete
Mac to USB to Pi to AES67 to Ferrofish to AES67 to Pi to USB to Mac
measurement, and it is well above the 10-20 ms fallback band.

It is **not** the tuned configuration. It was taken against
`run-bridge-hold-safe.sh`, which deliberately runs the saved production
`status.json` unmodified, so the AES67 sink delay was the stored **576
samples (12 ms)** rather than the 48 accepted during RAVENNA reconnaissance.
The candidate wrapper's 48-sample delay has not yet been measured end to end.

Roughly 35 ms of the total is accounted for by known contributors: CoreAudio
buffer and safety offsets, USB transfer, two `alsaloop` targets at 5 ms, 1 ms
packetization, and the 12 ms sink delay. The remaining ~40 ms is unattributed
and is the next thing to decompose. The Ferrofish device latency setting in
Dante Controller Device View is the leading suspect and has not yet been
inspected.

## Latency decomposition after the first round trip

### Ferrofish is not the problem

Dante Controller Device View, measured over a 12:22 window while the bridge
was live:

| Item | Value |
|---|---|
| Receive latency setting, both Pi flows | 2 ms |
| Observed peak | 1.4 ms |
| Observed average | 1.2-1.3 ms |
| Late packets | 0 |
| Device Latency | 0.25 ms |
| Encoding | PCM 24, 48 kHz, AES67 enabled |

The Ferrofish therefore contributes roughly 3.5 ms of the 74.15 ms round trip
including packetization. It is effectively free and is not a tuning target.
Zero late packets at a 2 ms setting also means the receive buffer has margin.

### The dominant term is the ALSA buffer on the Pi

The live bridge negotiated `buffer_size` **2304 frames (48 ms)** on all four
streams:

| Stream | Period | Buffer |
|---|---:|---:|
| RAVENNA playback | 128 | 2304 |
| USB capture | 144 | 2304 |
| USB playback | 144 | 2304 |
| RAVENNA capture | 128 | 2304 |

The requested `--period 96 --buffer 288` was not honored. The driver rounds the
period up to 128 or 144 and settles on an 18-period buffer.

**The explicit request is counterproductive.** The original probe, where
`-E`/`-B` were rejected as invalid options and the defaults applied, negotiated
`buffer_size` 960 frames (20 ms). Passing the corrected long options more than
doubled the buffering. This inverts the earlier assumption that the rejected
options were a defect to be fixed.

Anchoring on the measured USB-only figure of 5.5 ms at a 5 ms `alsaloop`
target, which already contains all CoreAudio and USB overhead, roughly 65 ms of
the 74.15 ms total sits in the Pi AES67 path and is dominated by these buffers.

### Change made

`run-aes67-candidate-safe.sh` now reads `USB16X16_PERIOD_FRAMES`,
`USB16X16_BUFFER_FRAMES`, `USB16X16_TARGET_USEC`, and `USB16X16_SINK_DELAY`.
An empty period or buffer omits the option entirely so the driver default
applies. The default is now to omit both. Deployed SHA-256
`c4f24fbc37d62bd68e1e340d141b0f6b13d0c3808e25e139b2d1326c01b11c07`.

Next measurement: driver-default buffering with sink delay 48, then vary one
term at a time per the Phase 2 plan.

## Sink delay 48 is too aggressive for the real Ferrofish path

Run `aes67-candidate-20260901T011927Z`: driver-default period/buffer, sink
delay 48, target 5000 us. **No measurement.** The harness reported
`capture contains no signal at any candidate impulse lag`.

The API snapshots taken before and after the measurement window explain it:

| Item | Value |
|---|---|
| PTP | `locked`, expected GMID, 7-10 ns jitter |
| sink 0 / sink 1 | `receiving_rtp_packet: true` |
| sink 0 / sink 1 | **`all_muted: true`** |
| sequence / SSRC / payload errors | none |

Packets were arriving cleanly, but both sinks were muted, so nothing reached
RAVENNA capture. The identical stack with the saved **576** sample delay ran
unmuted and produced the 74.15 ms measurement, so the delay is the
distinguishing variable. A 48 sample playout buffer is 1 ms and cannot absorb
real network and packetisation jitter from the Ferrofish.

The earlier acceptance of delay 48 came from the RAVENNA platform loopback,
which has no external sender, no switch, and a local PTP master. That result
does not transfer to a real peer.

### Consequence for the experiment

Two variables moved at once in this run, buffering and sink delay, and it
failed on the sink delay. Nothing was learned about the driver-default buffer
change. The next run should hold sink delay at the known-working 576 and change
only the buffering, giving a direct comparison against the 74.15 ms baseline.
Reduce the delay afterwards through 288, 144, and 96.

## Accepted: driver-default buffering, sink delay 576 — 44.79 ms

Measured against run `aes67-candidate-20260901T012832Z` with the bridge live
and settled.

| Configuration | `buffer_size` | Round trip |
|---|---:|---:|
| `--period 96 --buffer 288`, sink delay 576 | 2304 frames (48 ms) | 74.146 ms |
| driver default, sink delay 576 | **960 frames (20 ms)** | **44.792 ms** |

Removing the explicit period and buffer request saved **29.35 ms**, confirming
that the forced request was the dominant term. Only one variable changed
between the two rows.

Quality of the accepted measurement: correlation score 1.0, 1 sample spread
across 40 impulses, captured peak 0.2006, zero input and output
discontinuities. Repeats gave 44.792, 44.646, and 44.135 ms, so the figure is
stable within about 0.7 ms.

This is the best complete round trip measured so far and is inside the
20-35 ms expectation band for a tuned dual `alsaloop` design once the
remaining terms are addressed, though still above the 10-20 ms fallback target.

## Two harness defects found and fixed

### The measurement fired before the sinks settled

Two consecutive runs failed with `capture contains no signal at any candidate
impulse lag` despite a healthy bridge. The API snapshots showed why: 8 seconds
after `READY` the sinks reported `rtp_seq_id_error: true` and
`rtp_sac_error: true`, the latched startup flags. Minutes later the same sinks
were completely clean and measured perfectly.

The fixed 8 second settle in `measure-aes67-roundtrip.sh` is replaced by
polling the sink status until both sinks report clean sequence, SSRC, payload,
and SAC flags with `receiving_rtp_packet: true`, up to about 80 seconds.

### `alsaloop -s` is not honored, and SIGHUP skipped cleanup

The Pi wrapper passed `-s 120` and the process list confirmed the option was
present, but both `alsaloop` processes were still running after 7 minutes.
The script blocked forever in `wait`.

Compounding it, killing the controlling ssh session did **not** tear the stack
down: the trap covered `EXIT INT TERM` but not `HUP`, so an untrapped SIGHUP
killed the script with the daemon, both loops, and the RAVENNA module still
loaded. The protected USB baseline stayed healthy throughout.

Both are fixed. `alsaloop` is now wrapped in
`timeout -k 5 -s INT "$candidate_seconds"`, with 124, 130, and 143 accepted
alongside 0, and every wrapper now traps `HUP` as well.

## Root cause of the failed runs: audio takes ~3.5 minutes to start

A continuous burst-and-watch experiment against a freshly started bridge, 77
bursts over 8 minutes, found the transition precisely:

| Burst | Time | Result |
|---:|---|---|
| 1-31 | 02:03:40 to 02:07:05 | no signal |
| **32** | **02:07:12** | **first lock, peak 0.2003** |
| 33-77 | to 02:11:36 | locked, stable |

The bridge went live at about 02:03:35, so **audio first flowed 3 minutes 37
seconds later**. The most likely mechanism is the Ferrofish re-resolving its
subscriptions to the Pi transmit flows after the daemon restarts with new
session state, which matches the operator observation that the daemon "took a
while to show green in Dante Controller".

This single fact explains every failure in this session:

- the orchestrator fires its measurement about 10 seconds after `READY`;
- the 180-second sweep windows ended before audio ever started;
- the one successful measurement, 44.792 ms, was taken by hand roughly 8
  minutes into a run that had been left up.

### Withdrawn

The sink delay sweep run through the orchestrator is void. Its four "no
measurement" points said nothing about the delay. The control at the
known-good delay 576 failed identically, which is what proved the harness was
at fault rather than the parameter.

Also withdrawn: **clean sink flags are not a readiness gate.**
`receiving_rtp_packet: true` with clean sequence, SSRC, payload, and SAC flags
was observed on every failed run, and `settle.log` recorded
`sinks clean after 1 check(s)`. Packet acceptance is not audio, the same
distinction that already caught the silent-Ferrofish case. The only valid gate
is a probe that detects the returned signal.

## Valid sink delay sweep, performed live

Because a daemon restart costs 3.5 minutes, the sweep was performed on one
established bridge by rewriting the sink delay through
`PUT /api/sink/{0,1}` without restarting anything. Sources are untouched, so
the Ferrofish never needs to re-subscribe and each point settles in seconds.

| Sink delay | Round trip | Samples | Score | Spread |
|---:|---:|---:|---:|---:|
| 576 | 72.312 ms | 3471 | 0.750 | 2 |
| 288 | 65.792 ms | 3158 | 1.000 | 0 |
| 144 | 64.208 ms | 3082 | 0.829 | 1 |
| 96 | 62.500 ms | 3000 | 0.911 | 2 |
| 48 | **61.604 ms** | 2957 | 0.894 | 2 |

The delay is additive at close to 1:1. The configured span 576 to 48 is 528
samples and the measured span is 514 samples, so each sample of configured
playout delay costs about one sample of round trip.

**Delay 48 does not mute when applied to an established stream.** The earlier
muting was an artefact of setting 48 before the receive stream was
established, so it is a startup-ordering constraint rather than a floor. Set a
conservative delay at daemon start and tighten it once audio is flowing.

### Correlation aliasing

The first attempt at this sweep returned about 313 ms for the three shortest
delays. Impulses are emitted every 250 ms, or 12000 samples, and with
`--maximum-lag-ms 400` the correlator locked one impulse period late:
15025 - 12000 = 3025 samples, which is the real answer. **Keep
`--maximum-lag-ms` below the 250 ms impulse interval.** The values above were
re-measured at 200 ms and agree with the trend.

### Caveat on absolute values

This sweep ran through `run-bridge-hold-safe.sh`, which still hard-codes
`--period 96 --buffer 288` and therefore the 2304-frame buffering. That is why
the 576 point reads 72.3 ms rather than the 44.79 ms measured with
driver-default buffers. Only the deltas are transferable. Combining the
measured 29.35 ms buffer saving with the measured 10.7 ms delay saving
**projects** roughly 32 ms at driver-default buffering with delay 48. That is
a projection and has not been measured.

## Best measured configuration: 32.79 ms

Driver-default buffering with the live sink-delay sweep, waiting for genuine
returned audio rather than sink flags before measuring. Audio appeared after 26
probes, about 3.5 minutes, independently reproducing the time-to-audio finding.

| Sink delay | Round trip | Samples | Score | Spread | Peak |
|---:|---:|---:|---:|---:|---:|
| 576 | 44.292 ms | 2126 | 0.645 | 1 | 0.2002 |
| 288 | 38.000 ms | 1824 | 0.874 | 1 | 0.2001 |
| 144 | 34.479 ms | 1655 | 0.764 | 2 | 0.2006 |
| 96 | 33.312 ms | 1599 | 1.000 | 0 | 0.1559 |
| **48** | **32.792 ms** | **1574** | 0.927 | 4 | 0.2004 |

The 576 point reads 44.292 ms against the 44.792, 44.646, and 44.135 ms
measured earlier by hand in the same configuration, so the harness now
reproduces the manual result and the sweep is internally consistent.

The earlier projection of roughly 32 ms was accurate: measured 32.792 ms.

### Progress against the baseline

| Configuration | Round trip |
|---|---:|
| Forced `--period 96 --buffer 288`, delay 576 | 74.146 ms |
| Driver-default buffering, delay 576 | 44.292 ms |
| Driver-default buffering, delay 48 | **32.792 ms** |

This is a 41.4 ms improvement and lands inside the 20-35 ms band the handoff
predicted for a tuned dual `alsaloop` design. It is still above the 10-20 ms
fallback target and well above the sub-10 ms research goal.

### Where the remaining 32.79 ms sits

Using measured anchors rather than estimates:

| Term | Cost | Basis |
|---|---:|---|
| Mac, USB, one `alsaloop` at 5 ms target | 5.5 ms | measured USB-only |
| Second `alsaloop` direction | about 5 ms | its own 5 ms target |
| Ferrofish receive plus device latency | about 3.5 ms | Dante Controller |
| Sink playout delay 48 | 1 ms | measured, additive 1:1 |
| **Unattributed** | **about 18 ms** | remainder |

The unattributed term is dominated by the 960-frame ALSA buffer, which is
20 ms, plus RAVENNA period handling. That is the next target, and it cannot be
reached by requesting an explicit period or buffer, which was already measured
to make things worse.

The remaining levers in order of expected value are the `alsaloop` target
latency, currently 5000 us and untested below that on this path, and then
Phase 4, replacing the two `alsaloop` processes with one purpose-built
real-time bridge. Note that `alsaloop` target latency requires a restart and
therefore costs about 4 minutes per point, unlike sink delay which is live.
