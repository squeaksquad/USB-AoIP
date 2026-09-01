# Raspberry Pi 5 USB 16x16 / AES67 bridge handoff

**Authoritative state:** 2026-09-01

This document is the starting point for a fresh development session. It supersedes earlier architecture and baseline snapshots where they conflict. Do not infer that a planned service or latency optimization has already been implemented.

## Objective

Build a native, class-compliant 16-input/16-output USB audio interface on a Raspberry Pi 5 that bridges all channels bidirectionally to standards-compliant AES67 at 48 kHz/24-bit, with robust PTP synchronization and professional low-latency behavior.

Current priorities, in order:

1. Preserve the verified USB implementation and rollback path.
2. Establish sample-accurate latency measurements at a 64-sample Pro Tools buffer.
3. Pursue a sub-10 ms digital round-trip research target; accept 10-20 ms if the full system cannot reliably reach sub-10 ms.
4. After choosing the final timing architecture, package the bridge as persistent, recoverable services.
5. Add an optional higher-latency DSP/content mode after the low-latency transport is complete and protected.

CamillaDSP is not required for the primary low-latency bridge. It remains the leading candidate for a later DSP/content mode where filtering, mixing, delay, level control, and routing matter more than performer-monitoring latency.

## Protected USB baseline

Do not make broad or speculative kernel changes. Do not replace or edit these components without an explicit reversible experiment:

- Kernel: `6.18.34+rpt-rpi-2712`, Raspberry Pi OS Lite 64-bit.
- Custom module: `/lib/modules/6.18.34+rpt-rpi-2712/updates/usb-16x16/usb_f_uac2.ko`
- Module SHA-256: `8e9907d3363d80d3c93e8b24b5576e7dbd683cd6cb415580970364bc20c320e4`
- Service: `usb-16x16.service`, enabled and proven across reboots.
- Setup script: `/usr/local/sbin/setup-usb-16x16`
- Gadget: `/sys/kernel/config/usb_gadget/studio_audio`
- Product: `USB 16x16`
- Manufacturer: `Bryan DiMaio`
- Serial: `AUDDEV001`
- Format: 16 inputs, 16 outputs, 48 kHz, packed 24-bit (`S24_3LE`).
- USB speed: High Speed.

The exact-source `usb_f_uac2` patch makes playback and capture advertise one shared UAC2 clock source. macOS enumerates the device without an Aggregate Device. A prior 60-second 16x16 USB full-duplex test passed, and the implementation survived reboot.

Current configfs values include:

- `p_chmask=65535`
- `c_chmask=65535`
- `p_srate=48000`
- `c_srate=48000`
- `p_ssize=3`
- `c_ssize=3`
- `c_sync=async`
- `req_number=2`
- `fb_max=5`

The USB service must remain independent of any AES67 service so that an AES67 failure cannot prevent USB enumeration.

## Host channel-name requirement

The computer-facing channels must appear as discrete channels named simply:

```text
1, 2, 3, ... 16
```

They must not appear as Front Left, Front Right, Center, LFE, surround, height, or other speaker-position names.

The current `p_chmask=65535` and `c_chmask=65535` encode the first 16 standardized UAC2 speaker-position bits, which is why macOS can expose speaker-role names.

Do **not** solve this by writing zero to `p_chmask` or `c_chmask`. In the current Linux UAC2 gadget implementation, endpoint enablement and channel count are derived from the mask; a zero mask disables that direction.

Linux exposes `p_it_ch_name` and `c_it_ch_name` as the first channel-name strings, but the stock function still derives `bNrChannels` from the number of set mask bits. The likely clean solution is an exact-source, reversible descriptor patch that:

1. Keeps `bNrChannels=16` independently of spatial assignments.
2. Advertises `bmChannelConfig=0` for discrete/unpositioned channels.
3. Supplies sequential UAC2 channel-name strings `1` through `16` through `iChannelNames` if macOS honors them.
4. Retains the shared-clock patch unchanged.
5. Is tested as a separate module before replacing the known-good module.

Verification must include Audio MIDI Setup and Pro Tools. If macOS ignores the descriptor strings, retain discrete channel configuration at the USB layer and use Pro Tools I/O path labels `1`-`16` as the host fallback.

Relevant upstream references:

- Linux UAC2 configfs ABI: <https://github.com/torvalds/linux/blob/master/Documentation/ABI/testing/configfs-usb-gadget-uac2>
- Linux UAC2 function source: <https://github.com/torvalds/linux/blob/master/drivers/usb/gadget/function/f_uac2.c>

## Power and network baseline

- PoE HAT: 52Pi EP-0241.
- Switch: NETGEAR GS305EP, Pi on port 1.
- PoE negotiation: 802.3at Class 4, stable.
- Ethernet: `eth0`, 1 Gb/s full duplex.
- Previous link-local address: `169.254.92.97`.
- Mac AoIP interface: previously `en12`, `169.254.29.68`.
- Pi Ethernet hardware timestamp provider: precise IEEE 1588 quality, `/dev/ptp0`.
- Temperature during the 10-minute full-duplex soak: 46.6 C.
- `vcgencmd get_throttled`: `0x0`.

The previous session ended with instructions for a clean shutdown. At the next session, verify the actual power/state, connect PoE and USB as needed, and do not assume the previous link-local address is unchanged.

## AES67 implementation and paths

RAVENNA ALSA module:

```text
/home/bdimaio/usb-16x16-work/aes67-source/ravenna-alsa-lkm-v2.1/driver/MergingRavennaALSA.ko
```

AES67 daemon:

```text
/home/bdimaio/usb-16x16-work/aes67-daemon-src/build-daemon/aes67-daemon
```

Configuration and saved streams:

```text
/home/bdimaio/usb-16x16-work/aes67-daemon-src/runtime/daemon-eth0.conf
/home/bdimaio/usb-16x16-work/aes67-daemon-src/runtime/status.json
```

Logs:

```text
/home/bdimaio/usb-16x16-work/logs/
```

The RAVENNA module creates duplex ALSA card `RAVENNA`. The daemon performs its own PTP slave operation. Never run an external `ptp4l` instance on `eth0` concurrently with the daemon.

Earlier source inspection found that this RAVENNA prototype does not consume the NIC PHC or hardware packet timestamps; it uses its own software/kernel timing path. Its stable PTP lock and successful soak establish interoperability, not production-grade hardware-timestamp use. Treat explicit PHC integration as a production gap unless later source changes and measurements prove otherwise.

## Verified AES67/PTP state

- PTPv2 domain: 0.
- Grandmaster: `00-1D-C1-FF-FE-1D-27-DC`.
- Observed daemon PTP jitter: as low as 3 ns.
- Media: L24, 48 kHz, 8 channels per RTP stream, 48 samples/packet, 1 ms packet time.
- Media DSCP: 34.
- PTP DSCP: 46.
- SAP discovery works in Dante Controller.

Pi transmit streams:

| Stream | Channels | Address | Payload type |
|---|---:|---|---:|
| `USB 16x16 TX 01-08` | 1-8 | `239.69.16.1:5004` | 98 |
| `USB 16x16 TX 09-16` | 9-16 | `239.69.16.2:5004` | 99 |

Ferrofish receive streams configured on the Pi:

| Pi sink | Ferrofish source | Channels | Address |
|---|---|---:|---|
| `FF-PULSE RX 49-56` | `FF-PULSE-16-DX : 32` | 49-56 -> 1-8 | `239.69.121.9:5004` |
| `FF-PULSE RX 57-64` | `FF-PULSE-16-DX : 31` | 57-64 -> 9-16 | `239.69.193.115:5004` |

The use of Ferrofish channels 49-64 is intentional in the current test configuration.

## Known daemon startup race

The daemon loads strict-GMID receive sinks from `runtime/status.json` before PTP locks. During that interval it reports that the configured grandmaster does not match the SDP, rejects both sinks, and does not retry automatically.

Observed recovery:

1. Wait until `GET /api/ptp/status` reports `locked` and the expected GMID.
2. Reapply the exact sink definitions from `runtime/status.json` with `PUT /api/sink/0` and `PUT /api/sink/1`.
3. Opening RAVENNA capture clears the initial latched sequence/timestamp flags.

The persistent supervisor must automate this order.

## Validated prototype transport

The working prototype uses two independent `alsaloop` processes:

```text
USB capture -> adaptive SRC -> RAVENNA playback -> AES67 TX
AES67 RX -> RAVENNA capture -> adaptive SRC -> USB playback
```

Common settings:

- 48 kHz.
- 16 channels.
- `S32_LE` inside `plughw`; ALSA converts to/from USB packed 24-bit.
- `-S samplerate -A sincfastest`.
- `-t 80000`, an intentionally conservative 80 ms target.
- Real-time round-robin priority 99 when run with `sudo`.

Validated layers:

1. USB capture alone: pass.
2. USB playback alone: pass.
3. Direct USB full duplex: pass.
4. PTP lock: pass.
5. AES67 transmit packet structure and SAP discovery: pass.
6. AES67 receive to a 20-second 16-channel WAV: pass.
7. USB -> AES67 live, including a five-minute one-way test: pass.
8. AES67 -> USB live: pass after restoring the physical USB connection.
9. Combined 90-second 16x16 full duplex: pass.
10. Combined 10-minute 16x16 full-duplex soak: pass.

The 10-minute soak produced:

- No XRUNs, overruns, underruns, broken pipes, or reported audio failures.
- No RTP sequence, SSRC, payload, or timestamp flags.
- USB remained `configured` and High Speed.
- PTP remained locked.
- Temperature 46.6 C.
- No throttling.
- Correct meters and channel activity in Pro Tools, Dante Controller, and the Ferrofish.

The `Exit 124` results from the soak commands were expected because GNU `timeout` ended the processes after 600 seconds.

## USB enumeration incident

An apparent USB playback failure produced immediate ALSA `EIO` errors. Pro Tools and QuickTime were initially suspected, but macOS no longer saw the device at the USB layer. After the gadget service was rebound, the Pi correctly reported `UDC=not attached` and `speed=UNKNOWN`, revealing a physical connection issue. Restoring the physical USB link returned `configured/high-speed`, and both silence and the captured AES67 WAV played to macOS without error.

Lesson: before debugging audio software, compare macOS USB enumeration with:

```text
/sys/class/udc/*/state
/sys/class/udc/*/current_speed
```

`not attached/UNKNOWN` is a cable, port, or physical link problem. Do not treat stale `configured` state alone as proof that macOS currently owns the device.

## Earlier persistent-service plan

No persistent AES67 service has been installed yet.

Planned project directory:

```text
/Users/bryandimaio/Development/USB 16x16/work/aes67-bridge/
```

Planned files:

- `usb16x16-aes67-bridge`
- `usb16x16-aes67.service`
- `install.sh`
- `README.md`

Planned supervisor behavior:

1. Load the existing exact-kernel RAVENNA module without modifying `usb_f_uac2`.
2. Start the existing daemon.
3. Wait for its HTTP API.
4. Wait for PTP lock and the expected GMID.
5. Reapply the exact saved receive sinks after lock.
6. Wait for the USB gadget to report `configured`.
7. Start both validated audio directions.
8. If the daemon or either audio direction exits, fail the supervisor so systemd restarts the complete AES67 stack.
9. Wait safely while network, PTP, or USB is unavailable.
10. Leave `usb-16x16.service` independent and undisturbed.

Prototype limitations to document:

- Hard-coded development paths.
- Root execution for real-time scheduling/module loading.
- Kernel-specific RAVENNA module.
- Static multicast flows and maps.
- 80 ms adaptive-SRC latency.
- No production VID/PID.

### Revised sequencing decision

Do not finalize the persistent 80 ms service before latency research. First build the measurement harness and select the intended clock/buffer architecture. The eventual service should expose latency mode and buffer parameters instead of baking in 80 ms.

## Latency objective and measurement definition

The preferred Pro Tools hardware buffer is 64 samples.

North-star digital round-trip path:

```text
Pro Tools output
-> USB 16x16
-> Pi
-> AES67
-> Ferrofish internal digital loop
-> AES67
-> Pi
-> USB 16x16
-> Pro Tools input
```

Initial conditions:

- 48 kHz.
- 64-sample Pro Tools buffer.
- All 16 channels active.
- One channel carries repeated impulses/MLS for measurement.
- Other channels carry representative audio or noise load.
- No plugins.
- No analog conversion until the digital floor is established.
- Record median, p95, p99, maximum, and dropout/XRUN count.
- Require at least a 10-minute clean run at each candidate operating point.

Targets:

- Research target: under 10 ms measured digital round trip.
- Strong fallback: 10-20 ms.
- Anything above 20 ms requires identifying the dominant buffer before accepting it.

At 48 kHz, a 64-sample DAW buffer is 1.333 ms per I/O buffer. CoreAudio device latency, stream latency, and input/output safety offsets must be queried because the Pro Tools buffer is not the complete Mac contribution.

## Latency research roadmap

### Phase 1: measurement and decomposition

Build a Mac-side utility or script that records:

- CoreAudio buffer frame size and range.
- Input and output safety offsets.
- Device latency.
- Stream latency.
- Actual measured sample rate.
- Sample-accurate impulse/correlation round-trip delay.

Measure independently:

1. USB-only round trip.
2. RAVENNA loopback using the upstream platform latency test.
3. USB -> RAVENNA one way.
4. RAVENNA -> USB one way.
5. Complete Ferrofish digital round trip.

The upstream AES67 Linux Daemon documentation reports approximately 6 ms RAVENNA loopback with a 96-frame buffer on a NanoPi NEO2. Use the Pi 5 to test 384, 192, 144, and 96-frame candidates and record actual results rather than assuming the example transfers directly.

### Phase 2: current-stack buffer floor

Change one variable at a time:

```text
alsaloop target: 80 -> 40 -> 20 -> 10 -> 5 ms
AES67 sink delay: 576 -> 288 -> 144 -> 96 -> 48 samples
RAVENNA period: 384 -> 192 -> 144 -> 96 frames
```

Use explicit ALSA period and buffer sizes rather than accepting the current automatic 341-frame USB and 384-frame RAVENNA periods. Retain the last clean configuration after each soak.

### Phase 3: USB service interval experiments

Inspect the descriptors actually presented to macOS before changing them. Relevant UAC2 controls include:

- `p_hs_bint`
- `c_hs_bint`
- `req_number`

High-speed `bInterval` controls the isochronous service interval. `req_number` controls preallocated/queued USB requests. Too few requests risks starvation; too many may increase queued latency. Test any change only in a separate rollback-ready gadget module/configuration.

### Phase 4: replace dual `alsaloop`

If the current stack cannot reach the target, build one purpose-specific real-time bridge that:

- Opens all four ALSA directions itself.
- Uses memory-mapped audio and locked memory.
- Transfers 48- or 96-frame blocks.
- Uses one clock-drift estimator shared by both directions.
- Uses small lock-free elastic buffers.
- Fuses packed-24/S32 conversion into the transfer.
- Keeps logging/control off the audio thread.
- Restarts one direction cleanly without disrupting USB enumeration.

If ASRC remains necessary, the observed clock error is only tens of ppm. Investigate a low-delay near-unity asynchronous converter, such as a short Farrow/fractional-delay or compact polyphase design, rather than a general arbitrary-ratio resampler.

#### Phase 4 implementation status — 2026-09-01

The bridge is implemented, not stubbed, under `work/phase4-bridge/`. It owns all
four raw ALSA directions in one `SCHED_FIFO` process, uses locked/preallocated
memory, MMAP I/O, fused S24_3LE/S32 conversion, two elastic rings, reciprocal
near-unity Farrow conversion, and exactly one `SharedDriftEstimator`. The safe
wrapper and the existing Mac impulse harness provide comparable guarded runs;
any ALSA recovery rejects the candidate without touching USB enumeration.

**`96/384/768/192` has now passed its ten-minute loaded soak.** Run
`phase4-candidate-20260901T182239Z`, 600 s, zero restarts, zero drops, both
directions applying the commanded rate, measured 43.313 ms at correlation score
1.000 with zero spread. That clears the acceptance bar this project sets for a
new operating point, and it is the first Phase 4 point to do so.

It does **not** displace the stopgap. At 43.313 ms it is 10.5 ms slower than
the soaked dual-`alsaloop` point's 32.792 ms, so the stopgap remains the
deployed configuration. What Phase 4 now has is a correct, stable base to tune
from. See "The reorder fix, and what it did".

The earlier best clean reconnaissance run,
`phase4-candidate-20260901T132356Z`, completed 480 seconds with zero direction
recoveries and a valid 40-impulse result. Its `tx_queue` fell by 336 frames,
which was read at the time as frame loss; the instrumentation build later
showed it was a shrinking ALSA playback queue and not a loss at all, so that
run is **not** disqualified. See "Frame accounting from the instrumentation
build" below. The following pipeline-depth estimator run,
`phase4-candidate-20260901T134118Z`, reached an RX USB-playback XRUN after 393
seconds. Its latency snapshot is reconnaissance
only; its durable value is the first passive SAP discovery timeline captured
on the same wall clock as readiness.

#### Frame accounting from the instrumentation build — run 143219Z

The instrumentation build has now produced a candidate run,
`phase4-candidate-20260901T143220Z`, at the same operating point as the best
clean run (`96/960/1536/192`, sink delay 576, 480 s). Only the binary changed.
It resolved the open frame question and exposed a larger one.

**The 336-frame TX loss was not a loss.** In `132356Z`, `tx_queue` fell 960 ->
624, a difference of exactly 336, and that build had no input counters to
distinguish a shrinking ALSA playback queue from vanished frames. With
`tx_input` present, TX conserves exactly: `tx_input - tx_frames` is pinned at
288 and `tx_occ` at 195 for the whole run. **Run `132356Z` is therefore not
disqualified by frame loss**, and is the best Phase 4 candidate on record.

**The TX asymmetry is real, and now measured directly.** It was briefly
retracted on the strength of a component test showing `FarrowResampler` tracks
its requested step exactly, which it does. That was the wrong conclusion to draw:
the component is fine, but the direction still does not apply the ratio it is
handed. The `consumed_frames` counter added to the resampler settles it from the
resampler's own accounting rather than from residual algebra. Run `170748Z`,
over 265 s of steady running:

| Direction | consumed | produced | achieved step | commanded |
|---|---:|---:|---|---|
| TX | 12,722,400 | 12,722,400 | **1.000000000 (+0.00 ppm)** | -31.68 ppm |
| RX | 12,722,803 | 12,722,400 | 1.000031676 (+31.68 ppm) | +31.68 ppm |

RX matches `1.0 / ratio` exactly. TX should be -31.68 ppm and is exactly 1:1.

**ROOT CAUSE CONFIRMED 2026-09-01, run `172034Z`.** `snd_pcm_mmap_begin`
returns fewer frames than requested on the RAVENNA playback device, and the
resampler has already consumed ring input for the full produced count, so the
remainder is silently discarded.

| | dropped | apparent step | corrected for drops | commanded |
|---|---:|---:|---:|---:|
| TX | **583** | +31.29 ppm | **-16.97 ppm** | -27.17 ppm |
| RX | **0** | +16.88 ppm | +16.88 ppm | +27.17 ppm |

Removing the drops flips TX from +31.29 ppm to -16.97 ppm, against RX's
+16.88 ppm. **Those are mirror images to within 0.5%.** The shared estimator was
applying a correct reciprocal pair the whole time; the drops inverted the
apparent TX ratio and hid it. There is no rate-correction bug, and no servo bug.

Three consequences, all of which this explains:

1. **Real audio is lost** — 583 frames is 12.1 ms of discarded samples in 252 s
   on the RAVENNA side.
2. **It starves the TX playback queue.** Input is consumed but not all of it
   reaches the device, so the queue drains with the ring healthy at target.
   This run XRUNed at 252 s in `usb-to-ravenna` -- the dropping direction.
3. **It corrupted every rate measurement on TX**, which is what sent two
   separate investigations down dead ends: the occupancy-guard explanation and
   the retraction that followed it.

**The fix is a reorder, not new logic.** Call `snd_pcm_mmap_begin` first to
learn how many frames ALSA will accept, then render exactly that many. Once
input has been consumed it cannot be un-consumed, which is why the present order
can only drop. **Implemented and confirmed in `62125cb`; see the next
subsection.**

The evidence below is what led here.

**Prime suspect, code-visible, since confirmed.** In `render_to_playback`:

```c
snd_pcm_uframes_t frames = produced;
snd_pcm_mmap_begin(handle, &areas, &offset, &frames);   // ALSA may REDUCE frames
...
direction.output_frames += frames;                       // counts frames, not produced
```

`snd_pcm_mmap_begin` may return fewer frames than requested when the playback
buffer wraps. The resampler has already consumed input for the full `produced`
count, so the difference is silently discarded. That both drops real samples and
inflates `consumed / output_frames` above the commanded step, which is exactly
the TX signature. Confirm by counting `produced - frames` per direction before
changing anything; it is a two-line counter and it either explains the whole
asymmetry or eliminates the suspect.

**Earlier figures, from residual algebra (weaker method, same conclusion).**
Over 200 s of steady running:

| Direction | input frames | output frames | out - in | applied |
|---|---:|---:|---:|---|
| TX (USB capture -> RAVENNA playback) | 9,601,440 | 9,601,440 | **+0** | **0.00 ppm** |
| RX (RAVENNA capture -> USB playback) | 9,601,680 | 9,601,440 | -240 | -25.00 ppm |

Over that window the estimator commanded -33.6 to -30.1 ppm. TX transfers
frames 1:1; RX carries the entire correction, and even RX's applied ratio does
not track the commanded ppm.

**The real defect, visible in the code rather than inferred: the servo and the
control law regulate different quantities.**

- The servo regresses `tx.ring + tx_playback_delay - rx.ring - rx_playback_delay`
  — ring *plus* ALSA queue.
- `render_to_playback` regulated `direction.ring.size()` alone. The ALSA
  playback queue depth, `playback.buffer() - available`, was never regulated.

So the playback queue had no restoring force, and the estimator cannot supply
one: with a single ppm applied reciprocally, raising it drains one direction and
fills the other by equal amounts, leaving the frames in flight overall
unchanged. **Common mode is structurally uncontrollable.** A queue that drifted
down kept drifting until it underran — exactly the monotonic drain measured in
both directions, with the ring sitting at target throughout.

**Attempted and reverted, 2026-09-01, binary `d702fbae`.** Regulating the
playback queue toward the target and letting the ring float made things
markedly worse: **XRUN at 22 s against 331 s for the original law.** The
telemetry shows why — `tx_occ` and `rx_occ` sat at exactly 8, the interpolator's
lookahead reserve, for the whole run. The law drained the elastic ring to
nothing and left the pipeline with no jitter absorption anywhere, so the first
scheduling hiccup underran. It inverted the design: the ring is meant to *be*
the reservoir, and this made it the first thing emptied.

Reverted in `ca2d0c7b`, which restores the original control law and keeps the
`consumed_frames` counter added to `FarrowResampler`, so the achieved step per
direction can now be read from `bridge.log` directly rather than inferred.

**The failed attempt did produce a real finding.** Total pipeline depth went
from roughly 580 frames to about 200, and measured latency fell from 41.625 ms
to 23.229 ms — below the 32.792 ms stopgap. So the current law is carrying
roughly 380 frames of slack, and the ring/queue split is worth tuning
deliberately. The lesson is that the slack cannot simply be removed from the
ring: some of it is the jitter absorption the bridge depends on. A tuned split
that keeps a real reserve in the ring while trimming the rest is the open
opportunity, and it is worth more than it sounds, because 23 ms was measured
rather than estimated.

The diagnosis that the servo measures ring plus playback delay while the
control law regulates the ring alone still stands as an observation about the
code. What is now clear is that it is not, on its own, the cause of the XRUN --
correcting it in the obvious direction made things worse.

**The RX XRUN is a fast starve, not a slow drift.** The recovery at 346 s is
preceded by a 9-second linear drain of the RX ALSA playback queue, 876 -> 780 ->
684 -> 540 -> 492 -> 300 -> 204 -> 108 -> XRUN, about 96 frames/s or 2 ms/s.
Ring occupancy stayed healthy at ~196 against a target of 192 throughout, so the
converter had input available and simply stopped feeding playback fast enough.
Chase the converter's output scheduling, not the ring sizing.

#### The XRUN is one defect, and it follows the uncorrected direction

Run `160859Z` re-tested `96/384/768/192` on the instrumented binary. The XRUN
reproduced at 331 s, but in the **other direction**: `usb-to-ravenna`, where
every large-buffer run failed `ravenna-to-usb`. The signature is identical --
the ALSA playback queue drains monotonically to nothing while the elastic ring
sits healthy at target:

| | drains | ring occupancy |
|---|---|---|
| `96/960/1536/192`, RX | `rx_queue` 876 -> 108 | `rx_occ` ~196 vs target 192 |
| `96/384/768/192`, TX | `tx_queue` 384 -> 288 -> 240 -> 192 -> 144 -> 96 | `tx_occ` 195 vs target 192 |

So this is **one defect, not two**. The direction that fails is whichever
playback queue runs out of headroom first, which is why larger buffers moved it
from TX to RX rather than fixing it.

It connects directly to the rate asymmetry, which reproduced here too: TX
residual pinned at 93 for the whole run, RX residual growing ~1.4 frames/s
(~29 ppm). Because TX transfers frames 1:1 with no correction applied, nothing
holds its playback queue stable and it drains at the raw USB-versus-PTP clock
difference until it underruns. The observed drain of roughly 0.9 frames/s is the
right order of magnitude for an uncorrected ~29 ppm offset; it is not an exact
match, and the commanded ppm wandered between -21 and -33 during the run, so
treat the arithmetic as consistent rather than proven.

**Prediction tested and confirmed** by run `180438Z` below: with the drops
removed, the XRUN disappeared and TX now applies the ratio it is handed.

#### The reorder fix, and what it did — run 180438Z

Binary `0c527d8d`, commit `62125cb`, `96/384/768/192`, sink delay 576, 480 s.
`render_to_playback` now calls `snd_pcm_mmap_begin` before `resampler.render`
and renders exactly the frames ALSA granted; the remainder arrives on the next
pass instead of being discarded. The estimator and the control law are
untouched.

| | `172034Z` (before, 252 s) | `180438Z` (after, 480 s) |
|---|---:|---:|
| `tx_dropped` | 583 | **0** |
| `rx_dropped` | 0 | **0** |
| XRUN | 331 s, `usb-to-ravenna` | **none, ran to completion** |
| restarts / `RECOVER` | — | 0 / 0 |

**The rate asymmetry is gone**, which is the result that matters, because it is
what two earlier sessions chased into dead ends. Measured over the 449 s after
convergence:

| Direction | achieved step | commanded (mean, same window) |
|---|---:|---:|
| TX | **-13.69 ppm** | -13.69 ppm |
| RX | **+13.64 ppm** | +13.64 ppm (mirror) |

TX previously read exactly `1.000000000` while being commanded -31.68 ppm. It
now tracks the command to 0.00 ppm, and RX mirrors it to 0.05 ppm. The
cancellation is resolved and the diagnosis holds: the shared estimator was
correct throughout.

**The playback-queue drain is gone.** `tx_queue` held 336-384 and ended at 384,
against a previous monotonic 384 -> 288 -> 240 -> 192 -> 144 -> 96 -> XRUN.
`rx_queue` sat pinned at 300 for the whole run.

**New counter: `tx_short` / `rx_short`**, the frames `snd_pcm_mmap_begin`
declined to grant. It reads 1,249,363 on TX and **0** on RX. That direction
asymmetry is the same one the 583-vs-0 drops showed, on the same device, which
is strong corroboration. **Do not compare 1,249,363 against the old 583** --
they count different things. `dropped_frames` fired only when `produced >
granted`; `short_begin_frames` counts every grant smaller than the request,
most of which the resampler would never have filled. Its job is to distinguish
"the fix absorbed the short begins" from "the wrap condition did not occur this
run", which `dropped=0` alone cannot say. `dropped_frames` is retained as a
structural-zero regression guard on the ordering.

**What the fix did not buy: latency.** `180438Z` measured 44.3125 ms and the
soak `182239Z` measured 43.3125 ms, both inside the 40.375-44.313 band already
seen at this operating point. Correctness and stability, not speed. The
ring/queue split remains the path to beating the 32.792 ms stopgap, and it is
now safe to attempt on a pipeline that no longer drops frames.

**The ten-minute soak, run `182239Z`.** Same binary, same operating point, 600 s,
sink delay 576 confirmed on both sinks by readback:

| | `180438Z` (480 s) | `182239Z` (600 s soak) |
|---|---:|---:|
| restarts / `RECOVER` | 0 / 0 | **0 / 0** |
| `tx_dropped` / `rx_dropped` | 0 / 0 | **0 / 0** |
| TX achieved | -13.69 ppm | **-14.24 ppm** |
| RX achieved | +13.64 ppm | **+14.21 ppm** |
| commanded (mean) | -13.69 ppm | **-14.21 ppm** |
| `tx_queue` | 336-384 | **336-384** |
| `rx_queue` | 300 flat | **300 flat** |
| `tx_short` / `rx_short` | 1,249,363 / 0 | 1,860,240 / 0 |
| median | 44.313 ms | **43.313 ms** |
| score / spread | 1.000 / 0 | **1.000 / 0** |

Both runs reproduce the same picture: TX tracks the commanded ppm, RX mirrors
it, neither direction drops a frame, and neither playback queue drains. The
`curl` failure to port 8080 early in `182239Z` is the daemon API not yet up;
the wrapper retried and the sink readback confirms delay 576 was applied.

#### Tuning the ring/queue split — the `--playback-prime` knob

Total pipeline depth is **set at prime time and then conserved**, because there
is no restoring force on the common mode. `render_to_playback` waited for the
ring to reach `target + playback_buffer + 3` before priming, so the playback
buffer size set the permanent depth. The measured soak carried 1349 frames
round trip, 28.09 ms of the 43.313 ms.

`--playback-prime FRAMES` decouples that from the ALSA buffer: the elastic ring
still holds `--target` as the jitter reservoir, and this sets how much sits in
the device queue behind it. Zero, the default, keeps the historical
whole-buffer behaviour. It is threaded through the safe wrapper as a validated
sixth positional argument and through the measure script as
`USB16X16_PHASE4_PLAYBACK_PRIME_FRAMES`.

A `PRIMED` line per direction reports `intended`, `ring_at_prime` and
`overshoot` once at startup, so the overshoot is measured rather than inferred
from occupancy later.

| | soak baseline | `184056Z` buffer 192 | `185418Z` **prime 192** |
|---|---:|---:|---:|
| median | 43.313 ms | 35.729 ms | **35.3125 ms** |
| score / spread | 1.000 / 0 | 0.912 / 8 | **1.000 / 0** |
| round-trip depth | 1349 fr (28.09 ms) | 1238 fr (25.80 ms) | **970 fr (20.21 ms)** |
| restarts / drops | 0 / 0 | 0 / 0 | **0 / 0** |
| TX / RX achieved ppm | -14.24 / +14.21 | -13.97 / +13.92 | -14.48 / +14.43 |

**Reducing `--buffer` is the wrong knob.** `184056Z` asked for 192 and the
devices negotiated `usb=96/384` (the request ignored outright) and
`ravenna=128/288`. Only TX's prime moved; RX stayed pinned at 726 frames. It
also dropped the correlation score to 0.912 with 8 samples of spread. Run
`185418Z` put the buffers back to 384 and changed only the prime: **score
returned to 1.000 with all forty impulses at exactly 1695 samples.** So the
score loss was the shallow ALSA buffer, not the shallow queue. Prime depth is
the safe knob; buffer size is not.

**In the isolated run, depth accounts for the latency.** -379 frames = -7.88 ms
of depth against -8.00 ms measured, closing to 0.12 ms.

**There is a second lever, still unquantified.** `184056Z` and `185418Z` measure
within 0.42 ms of each other while differing by 268 frames of depth (5.6 ms), so
roughly 5 ms of `184056Z`'s gain came from something not counted here. That run
also moved `ravenna_capture` 384 -> 288, and **capture-side buffering is not
instrumented at all** -- the depth metric is ring plus playback queue only.
Recorded as an observation, not a mechanism. Instrument it before acting on it.

**93 frames per direction of prime overshoot, now measured:**

```
PRIMED direction=usb-to-ravenna intended=387 ring_at_prime=480 overshoot=93 queue_prime=192
PRIMED direction=ravenna-to-usb intended=387 ring_at_prime=480 overshoot=93 queue_prime=192
```

The ring is only checked on capture wakeups, so it sails past the threshold by
most of a capture period before priming runs. That is 186 frames round trip,
**3.9 ms of permanent startup waste**. Trimming the ring to `intended` at prime
time would recover it and is harmless at startup, before audio matters. Not yet
implemented; it needs a code change and an install.

`rx_short` went 0 -> 274,821 at prime 192: the shallower queue makes USB
playback short-change `snd_pcm_mmap_begin` too, and `rx_dropped` stayed 0. The
reorder fix is now exercised on both devices rather than only RAVENNA.

**`prime 96` reaches the stopgap, and its soak passes.** Two runs at
`buffer 384, prime 96`, both score 1.000 with zero spread:

| run | duration | median | round-trip depth | `tx_queue` min |
|---|---:|---:|---:|---:|
| `190400Z` | 480 s | 31.0625 ms | 768 fr | 48 |
| `191326Z` **soak** | **600 s** | **32.0625 ms** | 768 fr | 48 |

Both clean: zero restarts, zero drops, rates mirrored, `rx_occ` steady at
195-196 against target 192.

**Two cautions, and they matter more than the headline.**

1. **The margin is inside the run-to-run scatter.** Those two runs are the same
   binary, the same settings and the same 768-frame depth, and they measure
   1.000 ms apart. The soak beats the 32.792 ms stopgap by 0.73 ms, which is
   less than that scatter. Phase 4 is at **parity-to-slightly-better**, not a
   decisive win. Do not quote 31.06 ms as the figure; quote the soak, and quote
   the scatter with it.
2. **`prime 96` buys latency by spending safety margin.** `tx_queue` bottoms at
   48 frames and spends 50 of 570 samples below one RAVENNA period (128), 13 of
   them below 96. It held for 600 s. It is thin, and the elastic ring is doing
   all the absorbing (`tx_occ` min 195, healthy).

**The overshoot trim is the principled way to get the same latency with the
margin back.** `--prime-trim 0|1` discards the ring overshoot once at prime
time, so the pipeline starts at exactly `intended`. It runs before the playback
queue is started and before the resampler has rendered, so nothing audible is
lost and the resampler's position still refers to the front of the ring;
`restart_direction` clears `primed`, so a recovery re-trims rather than
re-accumulating. It is a flag, defaulting to the historical behaviour, so **one
install buys both arms of the A/B** at a fixed prime depth.

Predicted from the conservation these runs demonstrate -- total round-trip depth
is the sum over directions of `intended + overshoot`, which read 2 x 384 = 768
against a measured 768 -- removing 93 per direction takes depth to 582 frames
(12.1 ms):

| | predicted median | `tx_queue` floor |
|---|---:|---:|
| `prime 96` + trim | ~27.2 ms | 48 (unchanged, still thin) |
| `prime 192` + trim | ~31.4 ms | **192** |

`prime 192` + trim is the interesting one: about the same latency as bare
`prime 96`, with four times the playback runway. Not yet measured.

#### RETRACTED: the prime overshoot is not waste, it is the startup runway

Run `192813Z`, `prime 96` with `--prime-trim 1`, **failed immediately**: 673
recoveries, every one `stage=playback-avail code=-32` (broken pipe) with
`playback_state=XRUN`, in both directions, restarting in a loop from the first
second. The USB baseline was unaffected -- `configured`, `high-speed`, service
active -- so the guard did its job.

The trim did exactly what it was written to do. That is what makes the result
informative:

```
PRIMED direction=usb-to-ravenna intended=291 ring_at_prime=384 overshoot=93 trimmed=93 queue_prime=96
PRIMED direction=ravenna-to-usb intended=291 ring_at_prime=336 overshoot=45 trimmed=45 queue_prime=96
```

**The mechanism, and why the earlier claim was wrong.** The first render after
priming commits `ring.size() - target - 3` frames. Untrimmed that is
`384 - 195 = 189` frames; trimmed it is exactly `291 - 195 = 96`. Ninety-six
frames is 2 ms, and **below one RAVENNA period (128)**, so both devices
underran before the next capture wakeup could refill them. This is precisely
the failure the existing comment in `render_to_playback` predicted: "a
period-sized initial write leaves only a couple of milliseconds of runway and
both directions can underrun in lockstep before the next capture wakeup."

**So "93 frames per direction of permanent startup waste" is retracted.** The
overshoot is load-bearing. What remains true, because it was measured rather
than reasoned: total round-trip depth is conserved after priming, and it did
read 768 frames against a predicted 2 x 384. The observation stands; the
explanation built on it does not.

**The deeper reason a trim at prime time cannot work:** in this design the
initial commit size and the steady-state depth are *the same quantity* --
`ring_at_prime - target - 3` sets both. Lowering the steady-state depth by
trimming necessarily shrinks the initial commit by the same amount. Separating
them would mean trimming *after* playback has started and stabilised, not at
prime.

**Do not assume that would work either.** `tx_queue` already bottoms at 48
frames at depth 768. Removing a further 186 frames of depth would very
plausibly drive it negative, i.e. straight back to this XRUN, just later in the
run. The remaining slack looks like runway too. Instrument the queue floor
against depth before spending another install on it.

`--prime-trim` is retained, defaulting to 0. It costs nothing when off, and it
is the measurement that established the above. **Do not turn it on.**

#### The queue floor against depth, measured — the sweep

Three 480 s runs on the instrumented binary `b91a5d08`, buffer fixed at 384,
only the prime varied. `prime 384` reproduced 44.3125 ms and `prime 192`
reproduced 35.3125 ms, matching the pre-instrumentation runs exactly, so the
counters are behaviour-free.

| prime | median | `tx_qfloor` | `rx_qfloor` | `tx_dfloor` | `rx_dfloor` | TX under a period | RX under a period |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 384 | 44.3125 ms | 240 | 288 | 513 | 684 | **0%** | 0% |
| 192 | 35.3125 ms | 113 | 285 | 312 | 480 | 6.44% | 0% |
| 96 | 31.0625 ms | **27** | 93 | 223 | 350 | **49.83%** | 2.64% |

Sampled every loop iteration, ~620k samples per run, against the 480 the 1 Hz
print gives.

**The accepted `prime 96` point is far thinner than it looked.** The 1 Hz
telemetry reported `tx_queue` min 48; the true floor is **27 frames, 0.56 ms**,
and TX sits below one RAVENNA period for **half of all samples**. The 600 s
soak did pass, and 32.0625 ms is a real measurement, but its safety margin was
overstated by the statistic used to judge it. Treat `prime 96` as marginal.

**The floor does not plateau; it tracks depth toward zero.** That settles the
open question: the remaining slack is runway, not waste, and `prime 96` is
effectively the wall for this design. The `--prime-trim` failure was not bad
luck, it was this wall being hit from the other side.

**Latency tracks depth floor closely.** Total depth floor 1197 -> 792 -> 573
frames against 44.31 -> 35.31 -> 31.06 ms; the deltas are 8.44 vs 9.00 ms and
4.56 vs 4.25 ms.

**The two directions are not alike, but not in the way that helps.** RX's floor
is flat from prime 384 to 192 (288 -> 285) and then falls with it (93 at prime
96); TX falls throughout (240 -> 113 -> 27). RX is the roomier direction at
every point. But mixing does not buy latency: TX 192 with RX 96 predicts a
depth floor near 662 frames, so roughly **32.9 ms -- worse than 31.06** -- while
buying TX a 113-frame floor instead of 27. Per-direction prime is therefore a
**safety-versus-latency knob, not a latency win**. Do not expect it to beat
`prime 96`; expect it to make a near-`prime 96` point survivable.

`--tx-playback-prime` and `--rx-playback-prime` implement this, each falling
back to `--playback-prime` and then to that direction's own negotiated buffer.
Validation is now per direction against the buffer that direction actually
negotiated, rather than against the larger of the two -- the devices do not
always agree, and the buffer-192 run had RAVENNA at 288 with USB at 384.

#### The capture stage is 1.6 ms, and the buffer effect is NOT in this process

Two 480 s runs, prime fixed at 96, only the ALSA buffer request varied, on the
capture-instrumented binary `ae1cf9ba`.

| | buffer 384 | buffer 192 | delta |
|---|---:|---:|---:|
| median | 32.0625 ms | **26.729 ms** | **-5.33 ms** |
| capture backlog mean | 77.2 fr (1.61 ms) | 75.0 fr (1.56 ms) | -0.05 ms |
| depth floor total | 520 fr (10.83 ms) | 573 fr (11.94 ms) | **+1.11 ms** |
| score / spread | 1.000 / 0 | **0.884 / 9** | |
| negotiated RAVENNA | 128/384 | 128/288 | |
| negotiated USB | 96/384 | 96/384 | unchanged |

**The capture hypothesis is falsified.** The entire capture stage is 1.6 ms --
mean backlog 37.6 frames on TX and 39.6 on RX, peaks 96 and 144. It moved
0.05 ms. It cannot explain 5 ms under any circumstances, so the gap the earlier
confounded run left unaccounted for is not capture buffering.

**The effect is not in any buffer this process owns.** Latency fell 5.33 ms
while the fully counted depth floor went **up** 1.11 ms. Capture backlog,
elastic ring and playback queue are now all instrumented, and their total moves
in the *wrong direction*. Whatever the RAVENNA ALSA buffer size does, it does
not do it through occupancy inside the bridge.

What tracks it is `ravenna_capture` and `ravenna_playback` going 384 -> 288;
USB is unaffected, staying at 384 because it ignores the request outright. The
RAVENNA device is the aes67-daemon's virtual ALSA endpoint, so the daemon and
driver coupling is **where to look** -- stated as a location, not a mechanism.
Two mechanisms have already been proposed here and both were wrong; instrument
it before believing anything.

**26.729 ms is the best figure the project has produced, 6.06 ms below the
32.792 ms stopgap.** Its 600 s soak has since passed -- see below -- so this
point is now accepted.

**On the "1 ms scatter".** Every buffer-384 run lands all forty impulses on the
same sample, and buffer-384 runs at identical settings differ by exactly 48
samples -- one 1.000 ms step, with no within-run variation. That looked like
quantisation in the correlation. **It is not a general rule:** the two
buffer-192 runs land 12 samples apart (1283 and 1295), so whatever produces the
48-sample steps does not apply everywhere. Treat the run-to-run spread as
unexplained rather than as known quantisation, and confirm against the harness
rather than with more bridge runs.

#### ACCEPTED: buffer 192, prime 96 -- 26.979 ms, soaked

Run `211118Z`, 600 s, binary `ae1cf9ba`, `96/192/768/192` with
`--playback-prime 96`, sink delay 576.

| | 480 s `202405Z` | **600 s soak `211118Z`** |
|---|---:|---:|
| median | 26.729 ms | **26.979 ms** |
| score / spread | 0.884 / 9 | **0.988 / 0** |
| restarts / drops | 0 / 0 | **0 / 0** |
| `tx_queue_floor` | 36 | **25** |
| `rx_queue_floor` | 93 | 165 |
| depth floor total | 573 fr | 699 fr |
| capture mean | 75.0 fr | 75.8 fr |

**5.81 ms below the stopgap, on a full ten-minute loaded soak.** All forty
impulses landed on exactly 1295 samples.

**The jitter concern did not survive contact with the longer run.** The 480 s
run's 0.884 score and 9-sample spread looked like the price of the smaller
buffer; the soak scored 0.988 with zero spread. That spread was not a stable
property of the configuration, so it is not an argument against this point.

**The standing caution is TX's queue floor: 25 frames, 0.52 ms, with 50% of
samples under one RAVENNA period.** Thin by any normal standard. Against that,
the floor has measured 25-36 frames across roughly 2000 s of cumulative running
at `prime 96` with no underrun. It is the first thing to suspect if this
configuration ever fails in the field, and the reason `--tx-playback-prime`
exists: raising TX alone buys floor back at a known latency cost.

**Depth stayed decoupled from latency for the third time.** Depth floor went
573 -> 699 frames (+2.6 ms) while latency moved +0.25 ms. This point's latency
is not governed by the buffering this process owns, which is consistent with
the 5.33 ms buffer effect living outside the bridge.

#### Pricing the safer point: TX 192 / RX 96 costs 0.75 ms

Run `214847Z`, 480 s, buffer 192, `--tx-playback-prime 192
--rx-playback-prime 96`. First use of the per-direction knob; `PRIMED`
confirms it resolved as intended, `usb-to-ravenna queue_prime=192` and
`ravenna-to-usb queue_prime=96`.

| | accepted soak `211118Z` | **TX 192 / RX 96** | change |
|---|---:|---:|---:|
| median | 26.979 ms | **27.729 ms** | **+0.75 ms** |
| `tx_queue_floor` | 25 fr | **104 fr** | **x4.2** |
| TX under one period | 50.07% | **10.71%** | **/4.7** |
| `rx_queue_floor` | 165 fr | 93 fr | prime unchanged |
| restarts / drops | 0 / 0 | **0 / 0** | |
| score / spread | 0.988 / 0 | 0.898 / 8 | 480 s only |

**0.75 ms buys 4.2x the TX runway.** That is a far better trade than the depth
model predicted (~2 ms), and it is the fourth time depth has under-predicted at
this buffer: depth floor rose 699 -> 760 frames (+1.3 ms) against +0.75 ms of
latency.

At 27.729 ms it still beats the stopgap by 5.06 ms while moving TX off the
25-frame floor that is the one standing risk in the accepted point.

**Discount the 0.898 score.** The accepted point's own 480 s run scored
0.884 with 9 samples of spread and then soaked at 0.988 with zero spread.
Spread at 480 s has not been predictive at this operating point.

**Recommendation: adopt TX 192 / RX 96 over the 26.979 ms point**, subject to
its own 600 s soak. That soak has since passed -- see below -- but it also
corrects the price quoted here. **The +0.75 ms above is wrong**: it compares a
480 s run against a 600 s soak. Like for like the cost is +1.75 ms.

#### ACCEPTED: TX 192 / RX 96 -- 28.729 ms soaked, and two corrections

Run `221301Z`, 600 s, buffer 192, `--tx-playback-prime 192
--rx-playback-prime 96`. Zero restarts, zero drops, rates mirrored at
-13.78 / +13.75 ppm.

| 600 s soaks, like for like | median | `tx_queue_floor` | TX under a period |
|---|---:|---:|---:|
| `211118Z` prime 96 | **26.979 ms** | 25 fr | 50.07% |
| `221301Z` **TX 192 / RX 96** | 28.729 ms | **124 fr** | **0.01%** |

**The safety goal is achieved decisively:** TX's floor is 124 frames and it is
under one RAVENNA period for 0.01% of samples, against 50.07% at prime 96. The
cost is **+1.75 ms**, and 28.729 ms is still 4.06 ms below the stopgap.

**Correction: the spread at buffer 192 is real, and was dismissed too quickly.**
The note above discounts the 480 s scores on the grounds that `211118Z` soaked
at 0.988 with zero spread. That generalised from one run. All four buffer-192
runs:

| run | score | spread |
|---|---:|---:|
| `202405Z` 480 s prime 96 | 0.884 | 9 |
| `211118Z` 600 s prime 96 soak | **0.988** | **0** |
| `214847Z` 480 s TX 192 / RX 96 | 0.898 | 8 |
| `221301Z` 600 s TX 192 / RX 96 soak | 0.924 | 8 |

Three of four sit at 8-9 samples and ~0.9. **The clean run is the outlier**,
not the rule, and every buffer-384 run scores 1.000 with zero spread. So buffer
192 does trade real impulse jitter for latency, which was the original reading
before one soak overturned it. Do not treat `211118Z`'s perfect score as
characteristic of its configuration.

**Both points are now soaked and accepted.** The choice is 26.979 ms at a
25-frame TX floor against 28.729 ms at 124, with ~0.17 ms of impulse spread
either way. For unattended operation the safer point is the better default; the
faster one is available if the floor is accepted deliberately.

#### Phase 4 latency is not yet competitive

| Operating point | run | median | score | spread |
|---|---|---:|---:|---:|
| `96/192/768/192` prime 96 | **211118Z, 600 s soak PASSED, ACCEPTED** | **26.979 ms** | **0.988** | **0 samples** |
| `96/192/768/192` TX 192 / RX 96 | **221301Z, 600 s soak PASSED, ACCEPTED** | **28.729 ms** | 0.924 | 8 samples |
| `96/192/768/192` TX 192 / RX 96 | 214847Z, 480 s, unsoaked | 27.729 ms | 0.898 | 8 samples |
| `96/192/768/192` prime 96 | 202405Z, 480 s | 26.729 ms | 0.884 | 9 samples |
| `96/384/768/192` prime 96 | **191326Z, 600 s soak PASSED** | **32.063 ms** | **1.000** | **0 samples** |
| `96/384/768/192` prime 96 | 190400Z, 480 s | 31.063 ms | 1.000 | 0 samples |
| `96/384/768/192` prime 192 | **185418Z, `--playback-prime` `02d2153c`** | **35.313 ms** | **1.000** | **0 samples** |
| `96/192/768/192` | 184056Z, buffer 192, confounded | 35.729 ms | 0.912 | 8 samples |
| `96/384/768/192` | **182239Z, reorder fix `0c527d8d`, 600 s soak PASSED** | **43.313 ms** | **1.000** | **0 samples** |
| `96/384/768/192` | **180438Z, reorder fix `0c527d8d`, first clean 480 s** | **44.313 ms** | **1.000** | **0 samples** |
| `96/384/768/192` | **160859Z, instrumented binary** | **41.625 ms** | **1.000** | **0 samples** |
| `96/384/768/192` | 113600Z, 120034Z, 121252Z (older binaries) | 40.2-42.6 ms | | |
| `96/960/1536/192` | 151450Z | 84.291 ms | 0.987 | 8 |
| `96/960/1536/192` | 143219Z | 76.917 ms | 0.320 | 16 |
| dual `alsaloop` tlatency 3000 (accepted stopgap) | soaked | **32.792 ms** | | |

Run `160859Z` is the cleanest measurement in the dataset: correlation score
1.000 with all forty impulses at exactly 1998 samples, zero spread. The small
buffers halve the latency *and* measure far more cleanly than the large ones.
The gap to the stopgap is 8.8 ms rather than the 51 ms the large-buffer point
suggested.

Every run above except `180438Z` exited 33, so all of those are reconnaissance.
`180438Z` is the first Phase 4 run to complete without a restart, which makes
its 44.313 ms the first Phase 4 latency figure that is not taken from a run
that later failed. The larger buffers were adopted for stability, but they did
not buy stability -- they only moved the XRUN from TX to RX -- and they cost
roughly 43 ms. **`96/384/768/192` is the operating point to carry forward.**

The dual-`alsaloop` `tlatency=3000`, sink-delay-576 point remains the deployed
configuration, but it is no longer the best measured one. **Phase 4 at
`96/192/768/192` with `--playback-prime 96` is soaked at 26.979 ms, 5.81 ms
faster than the stopgap's 32.792 ms**, with zero restarts, zero drops and zero
impulse spread. Switching is now a real decision rather than an aspiration; the
open question is not latency but whether TX's 25-frame queue floor is
acceptable for unattended operation.

### Phase 5: PTP-disciplined USB research

This is the highest-upside path for sub-10 ms.

Current architecture:

```text
Mac/USB clock <-> adaptive sample-rate conversion <-> PTP/AES67 clock
```

Research architecture:

```text
PTP hardware/media clock
-> shared USB sample counter and feedback servo
-> macOS follows the PTP-derived UAC2 device rate
```

The UAC2 gadget already exposes playback/capture pitch controls and asynchronous feedback. First test whether one common ALSA rate-shift servo can discipline the shared USB clock toward PTP. Do not run two independent pitch servos that can fight each other.

If userspace controls are insufficient, create a separate exact-source `usb_f_uac2` experiment that derives USB feedback and capture packet sample counts from the PTP sample counter. The known-good module remains installed and recoverable throughout. If USB and AES67 share one long-term rate, continuous dual ASRC may be removed and only small scheduling-jitter buffers retained.

### Phase 6: real-time tuning

Only after measuring the default system:

- Pin the RAVENNA timer and bridge audio thread to an isolated Pi core.
- Place Ethernet and USB interrupts intentionally.
- Use the performance governor.
- Lock bridge memory.
- Evaluate real-time scheduler throttling.
- Keep web UI, logging, SSH, and management work off the audio core.
- Measure scheduler wake-up latency under network and CPU load.

### Higher sample rates

Do not run only the Pi internally at 96 kHz while USB and AES67 remain at 48 kHz. That adds two conversion stages and does not reduce buffers specified in milliseconds.

At a 64-sample DAW buffer:

- 48 kHz: 1.333 ms per buffer.
- 96 kHz: 0.667 ms per buffer.

End-to-end 96 kHz may eventually save roughly 1-3 ms, but only if the USB descriptors, AES67 peer, Ferrofish mode, packetization, and all processing operate natively at 96 kHz. Revisit it after the optimized 48 kHz design approaches 10-15 ms.

### Optional monitoring mode

If all 16 channels cannot meet the most aggressive target, consider a separate low-latency monitoring mode or priority subset while retaining a safe 16x16 recording mode. Direct monitoring on the Pi or Ferrofish is a fallback for performer monitoring, not a substitute for measuring the bridge itself.

## Future DSP/content mode

Implement this only after the low-latency bridge has a measured, stable operating point and independent rollback. DSP mode must be optional and must never become a dependency of USB enumeration, AES67 discovery, or the low-latency transport.

Proposed architecture:

```text
CamillaDSP TX: USB capture -> DSP/routing + adaptive SRC -> RAVENNA playback
CamillaDSP RX: RAVENNA capture -> DSP/routing + adaptive SRC -> USB playback
```

Use two CamillaDSP processes because the two directions have different capture/playback clock ownership. Do not return to the original single-process USB-to-USB loopback architecture as the production design.

Operating profiles should be explicit:

| Mode | Purpose | Priority |
|---|---|---|
| Low Latency | Tracking, live interaction, performer monitoring | Minimum stable round-trip latency; DSP bypassed or limited to the custom bridge |
| DSP / Content | Playback, streaming, installed sound, broadcast/content consumption | More processing headroom and stability with bounded, deterministic delay |

DSP/content latency requirements:

- Target no more than approximately 20 ms of **additional one-way delay** over the low-latency path where practical.
- Initial acceptance ceiling: 50 ms total one-way USB-to-AES67 or AES67-to-USB latency, measured rather than inferred.
- Delay must be stable; low jitter and drift are more important than achieving the lowest isolated number.
- All channels in a direction must remain sample-aligned.
- If DSP and bypass signals can be heard together, automatically delay the faster path to prevent comb filtering and echoes.
- Report the measured latency in samples and milliseconds so Pro Tools, video, or downstream systems can compensate.
- Do not market or select DSP/content mode for performer monitoring unless its measured round trip is acceptable for that use.
- For audio accompanying video, validate lip sync with actual program material and configure an explicit video/audio offset when needed rather than relying on perceptual tolerance.

CamillaDSP implementation goals:

- Version-pinned binary and configuration schema.
- Separate TX and RX configurations and service identities.
- Conservative chunks/buffers selected from measurements, not the earlier experimental defaults.
- Adaptive rate adjustment for each USB/PTP clock-domain crossing.
- Identity routing as the baseline, followed by optional EQ, FIR/IIR, delay, gain, mixing, and channel remapping.
- Optional CamillaGUI on the management interface only; GUI failure must not stop audio.
- Atomic profile changes or controlled restart with mute/fade behavior to avoid bursts and discontinuities.
- A true bypass/rollback path that returns to the low-latency bridge without changing the USB gadget.

DSP-mode validation:

1. Re-test each CamillaDSP direction independently for at least ten minutes.
2. Confirm that the earlier capture-stall/playback-underrun behavior does not recur with distinct USB/RAVENNA endpoints.
3. Run 16x16 full duplex for at least one hour with representative filters and processing load.
4. Measure impulse latency, channel alignment, resampling ratio, buffer occupancy, and latency variation.
5. Validate audio/video synchronization with representative content.
6. Verify clean switching between Low Latency and DSP / Content modes.
7. Confirm that stopping or breaking CamillaDSP cannot disturb `usb-16x16.service`.

## Expected latency ranges

These are research estimates, not measured claims:

| Design | Expected digital round trip at a 64-sample DAW buffer | Measured |
|---|---:|---:|
| Tuned dual `alsaloop` | approximately 20-35 ms | **32.792 ms on 2026-09-01** |
| Single optimized real-time bridge | approximately 15-25 ms | not built |
| PTP-disciplined USB plus optimized bridge | potentially 8-15 ms | not built |

The dual `alsaloop` estimate proved accurate. The measured 32.792 ms sits in the
upper half of its predicted band, which means the remaining architectures are
still required to reach the fallback target.

Sub-10 ms is plausible only near the best end of CoreAudio safety offsets, USB scheduling, AES67 receiver buffering, and Ferrofish behavior. A reliable 10-20 ms result remains a successful fallback.

## 2026-08-31 latency work completed

The Mac measurement harness and reversible Pi test wrappers now exist under
`work/latency-harness/` and `work/ravenna-latency/`. Raw results and a concise
interpretation are in `outputs/latency/2026-08-31-latency-results.md`.

Measured reconnaissance floors at a 64-frame CoreAudio buffer:

- USB-only dual `alsaloop`: 80.5, 40.5, 20.5, 10.5, and 5.5 ms for targets
  80, 40, 20, 10, and 5 ms respectively. These were short 20-impulse runs,
  not acceptance soaks.
- RAVENNA-only platform loopback with sink delay 576: 20.001, 11.999,
  7.000, and 5.999 ms for 384, 192, 144, and 96-frame periods.
- At a fixed 96-frame period, sink delays 288, 144, and 96 measured about
  6.000 ms; delay 48 measured 4.999 ms. The 576-delay repeat XRUNed early and
  is rejected despite printing a numeric result.

Accepted RAVENNA-only point: 96-frame period and sink delay 48 completed a
600-second run with 28,800,000 captured frames, final playback/capture states
both `RUNNING`, no XRUN/failure marker, and 4.999 ms measured end-to-end
latency. Cleanup removed the test processes/module, restored the original
sysctls, and left USB active and `configured/high-speed`.

This is not yet the full bridge result. The next measurement boundary is the
combined USB -> AES67, AES67 -> USB, and Ferrofish digital-return path with the
64-frame Mac buffer. Do not treat the 4.999 ms RAVENNA-only figure as the
complete Mac/USB/AES67 round trip.

**Superseded by the 2026-09-01 session results below; retained for history.**

The first combined probe did not yield a measurement. The installed
`alsaloop` rejected short `-E`/`-B` options despite listing them in help; the
temporary supervisor is now corrected to use accepted `--period`/`--buffer`
long options but has not been rerun. At measurement time macOS also no longer
listed `USB 16x16` in CoreAudio or the USB inventory while the Pi still showed
`configured/high-speed`. Re-establish Mac-side USB enumeration first. The
failed probe cleaned up the daemon, both loops, and the RAVENNA module and left
the protected USB service healthy.

## 2026-08-31 second session: combined probe unblocked

Both blockers on the combined probe are cleared and verified:

- macOS enumeration is restored. A read-only CoreAudio inspection reproduces
  the original baseline exactly (16x16, 48 kHz, input 74/74 frames, output
  50/50 frames, stream latency 0).
- The corrected long options parse on this Pi build; only the invalid card
  errored, with no invalid-option message. The Pi copy of
  `run-aes67-candidate-safe.sh` hashes identically to the repository copy, so
  no resync is needed.
- The Pi is clean: no `alsaloop`, `aes67-daemon`, or `ptp4l`, RAVENNA module
  unloaded, `usb-16x16.service` active, UDC `configured/high-speed`.

New Mac-side orchestrator:

```text
work/aes67-candidate/measure-aes67-roundtrip.sh [seconds] [frames] [impulses] [max_lag_ms]
```

It sequences the two components that already exist rather than adding a new
measurement method. It runs pre-flight checks on both machines, starts the
existing reversible Pi candidate, waits for that wrapper's `READY` marker,
runs the existing CoreAudio impulse harness, retrieves the Pi logs, and
verifies that the Pi cleaned up and the protected USB baseline survived. It
reports the correlation score and captured peak alongside the statistics so a
silent capture cannot be mistaken for a low-latency result.

The one interactive step is the Pi `sudo` password, which the script prompts
for on the real terminal. Granting a narrowly scoped `NOPASSWD` sudoers entry
for the two test wrappers would make the whole probe unattended; that is a
system security change and is left to the operator.

The orchestrator also snapshots the daemon HTTP API immediately before and
after the measurement and prints a verdict on the receive path. The Pi wrapper
samples sink status only once, right after the sink PUT and before the loops
open RAVENNA capture, when the receive flags are still latched; the mid-run
snapshots are what actually show whether audio is returning. Endpoints
captured: `ptp/status`, `sources`, `sinks`, `sink/status/0`, `sink/status/1`,
and `browse/sources/all`.

### Verified network and receive configuration

Addresses confirmed this session rather than assumed:

- `eth0` is the AES67 network at `169.254.92.97/16`, unchanged from the
  previous session, and carries the `224.0.0.0/4` multicast route.
- `wlan0` at `192.168.1.201/24` holds the default route and is the SSH and
  management path. SSH reaching the Pi therefore says nothing about AoIP
  health; check `eth0` separately.
- The daemon binds `interface_name: eth0` with `http_port: 8080`.

The Pi receive side needs no manual configuration. Both sinks are already
persisted in `runtime/status.json` with complete SDPs:

| Sink | Name | Source SDP | Multicast | Format | USB channels |
|---:|---|---|---|---|---|
| 0 | `FF-PULSE RX 49-56` | `FF-PULSE-16-DX : 32` | `239.69.121.9:5004` | L24/48000/8 | 1-8 |
| 1 | `FF-PULSE RX 57-64` | `FF-PULSE-16-DX : 31` | `239.69.193.115:5004` | L24/48000/8 | 9-16 |

Both use `use_sdp: true` with `ignore_refclk_gmid: false` and carry
`a=ts-refclk:ptp=IEEE1588-2008:00-1D-C1-FF-FE-1D-27-DC:0`, which matches the
expected grandmaster. That strict GMID match is the cause of the documented
startup race, and the candidate wrapper already reapplies both sinks by `PUT`
after PTP lock. The Ferrofish SDP origin is `169.254.248.189`, consistent with
the same link-local AoIP segment.

Because both Ferrofish source SDPs were learned through SAP discovery, the
Ferrofish is already transmitting flows 31 and 32. The only unconfirmed
question is what audio those flows carry.

Note that the candidate wrapper points `status_file` at a temporary copy so it
cannot disturb the production configuration. Any change made through the
daemon web UI during a probe run is therefore discarded when the run ends. Use
the documented manual foreground daemon procedure for persistent
configuration changes.

### AES67 self-loop measurement boundary

The Ferrofish internal routing turned out to be the one unverifiable segment:
the unit answers on the AoIP segment (`169.254.248.189`, no packet loss) but
exposes no web configuration port, so its matrix is front-panel only, and
Dante Controller manages subscriptions rather than internal routing.

Rather than block on it, the round trip is now closed on the Pi itself. The
daemon subscribes to its own transmit streams:

```text
USB capture -> RAVENNA playback -> source 0/1 -> multicast
            -> sink 0/1 -> RAVENNA capture -> USB playback
```

This is the same technique the upstream `run_latency_test.sh` uses. That
script builds sinks whose `source` is
`http://127.0.0.1:8080/api/source/sdp/0` with an SDP pointing at the daemon's
own multicast group, then loops `-P hw:RAVENNA -C hw:RAVENNA`. Multicast
self-reception is therefore already proven on this hardware; it is what
produced the accepted 4.999 ms platform figure.

Implementation: `work/aes67-candidate/run-selfloop-candidate-safe.sh`,
deployed to `/home/bdimaio/usb-16x16-work/` with matching SHA-256
`4d4c2e8a340fd6d9616ad89b8c507ee6683e72af88162fe45ec9e5dc73c8920a`. It reuses
every safety property of the Ferrofish candidate wrapper and differs only in
sink construction:

- the temporary `status.json` keeps the two validated sources unchanged and
  starts with an empty sink list, so nothing loads before PTP lock and the
  strict-GMID startup race cannot occur;
- after lock, each sink is built from the daemon's own published SDP via
  `GET /api/source/sdp/{0,1}`, so no SDP text is hand-written;
- sinks use `ignore_refclk_gmid: true`, `delay` 48, and maps `0-7` and `8-15`,
  matching the source maps exactly;
- because sources only transmit once RAVENNA playback is streaming, the
  self-loop is verified *after* the audio directions start and *before* the
  `READY` marker, so a failed loop aborts with exit 36 instead of yielding a
  meaningless correlation.

Run it from the Mac with `work/aes67-candidate/measure-selfloop.sh`, which
reuses the same orchestrator through
`USB16X16_REMOTE_CANDIDATE`/`USB16X16_REMOTE_READY_FILE`.

#### Result: the self-loop does not work on `eth0`

Tested 2026-09-01, run `selfloop-20260901T005454Z`. **Rejected.**

An earlier note in this document claimed multicast self-reception was already
proven on this hardware by the upstream latency test. That was wrong in a
material way. Upstream's `test/daemon.conf` sets `interface_name: "lo"` and
`ip_addr: 127.0.0.1`, and its script starts `ptp4l -i lo` as a local master.
The self-subscription is proven **on loopback only**. The accepted 4.999 ms
platform figure was measured there, not over `eth0`.

Everything up to reception worked on `eth0`:

- daemon started, PTP locked to the expected grandmaster;
- both sinks built from the published source SDPs and accepted with
  `PUT /api/sink/{0,1}` returning 200, `add RTP stream success`;
- IGMP joined `239.69.16.1` and `239.69.16.2` on `169.254.92.97`;
- both `alsaloop` directions ran, and the RAVENNA card started playback and
  capture at 16 channels.

Both sinks nevertheless reported `receiving_rtp_packet: false`. The RAVENNA
driver transmits directly to the interface, and a switch does not return a
frame out of its ingress port, so nothing comes back. The run aborted at the
verification gate with exit 36 before any measurement, then tore down cleanly:
daemon exit 0, module removed, `usb-16x16.service` untouched and the UDC still
`configured/high-speed`.

The gate is the reusable lesson. Verifying reception after the audio
directions start and before the `READY` marker converted a silent bad
measurement into a fast, unambiguous negative.

`run-selfloop-candidate-safe.sh` is retained as a documented negative result
and as the basis for a possible loopback-mode variant. Do not rerun it against
`eth0` expecting a different outcome.

A loopback-mode variant remains possible: daemon on `lo` with a local
`ptp4l -i lo` master, mirroring upstream. It would measure the two `alsaloop`
directions, RAVENNA, and RTP packetization, but not the NIC, the switch, or
the real PTP domain. It was deferred in favour of the real Ferrofish path.

### Ferrofish return path status: RESOLVED

The Ferrofish internal routing was completed on 2026-09-01. Multicast flow
membership, read from Dante Controller Device View, is:

| Flow | Ferrofish transmit channels | Address | Pi sink | USB channels |
|---:|---|---|---:|---|
| 32 | `Output 49-56` | `239.69.121.9:5004` | 0 | 1-8 |
| 31 | `Output 57-64` | `239.69.193.115:5004` | 1 | 9-16 |

The loop is `Input 49-64` to `Output 49-64`, a straight 1:1 assignment in the
Ferrofish matrix. Dante Controller cannot make this connection; it manages
subscriptions between devices, not a device's internal receive-to-transmit
path. The Ferrofish exposes no web configuration port, so this is front-panel
work.

All sixteen channels were verified returning, 1:1 with nothing crossed, worst
misalignment 4 samples. Artifacts in
`outputs/latency/ferrofish-channel-scan-20260901T011505Z/`.

## 2026-09-01 session results

### Headline

The complete Mac to USB to Pi to AES67 to Ferrofish and back round trip is
measured, tuned from 74.146 ms to **20.688 ms**, and soak-tested.

**Accepted stopgap operating point:** `alsaloop --tlatency 3000`, AES67 sink
delay 576, driver-default ALSA buffering, 48 kHz, 16 channels, 64-frame
CoreAudio buffer. Measured median 20.688 ms.

This is a stopgap pending Phase 4, not a final design. Its known defect is
documented under "Accepted stopgap" below and must be understood before anyone
relies on a fixed reported latency.

| Configuration | Round trip |
|---|---:|
| Forced `--period 96 --buffer 288`, sink delay 576 | 74.146 ms |
| Driver-default buffering, sink delay 576 | 44.292 ms |
| **Driver-default buffering, sink delay 48** | **32.792 ms** |

This lands inside the 20-35 ms band this document predicted for a tuned dual
`alsaloop` design. It is still above the 10-20 ms fallback and far above the
sub-10 ms research goal. Full tables and provenance are in
`outputs/latency/2026-08-31-latency-results.md`.

### Accepted stopgap: tlatency 3000, sink delay 576

Ten-minute acceptance soak, 31 measurements of 24 impulses over 605 seconds.

**Transport integrity was flawless.** Zero XRUN, underrun, overrun, and broken
pipe on both directions. Zero daemon RTP sequence, SSRC, and payload errors.
Zero CoreAudio discontinuities. PTP locked at 9 ns. USB `configured/high-speed`
throughout. 47.7 C, `get_throttled` `0x0`. No measurement rejected.

**Known defect: a bimodal 12 ms latency step.**

| Cluster | Samples | Range |
|---|---:|---|
| Low | 28 of 31 | 20.062 to 21.250 ms |
| High | 3 of 31 | 32.833 to 32.958 ms |

The step is 590 samples, 12.29 ms, which is one 576-frame ALSA buffer of
12.00 ms. It occurred roughly every 70 to 150 seconds and recovered each time.
Nothing underruns; the queue simply settles one buffer deeper for a while, so
no error is logged anywhere.

Consequences for anyone using this stopgap:

- Do not publish a single fixed latency figure to Pro Tools or to downstream
  delay compensation. The true value is 20.7 ms about 90 percent of the time
  and 32.9 ms otherwise.
- It is acceptable for development, verification, and non-critical monitoring.
  It is not suitable for critical tracking where a sudden 12 ms shift matters.
- Audio is never lost. Across ten minutes there were no dropouts.

### Rejected operating points

| Point | Round trip | Why rejected |
|---|---:|---|
| `tlatency` 5000, delay 48 | 33.625 ms | Only 29 percent of measurements usable. Writing delay 48 to an established stream caused a two-minute outage, then unstable per-impulse timing, and both sinks ended `all_muted`. |
| `tlatency` 2000 and 1000 | none | Continuous `underrun for playback plughw:CARD=RAVENNA`. 384-frame and 192-frame buffers are below what the RAVENNA playback path sustains. |

`tlatency` 5000 with delay 576, 44.292 ms, is the untested conservative
fallback. It has never been soaked. Adopt it only after its own soak.

**Sink delay 48 is not usable on this path in any order.** An earlier note
calling the muting a startup-ordering constraint was wrong; writing 48 to a
fully established stream also breaks it, after a delay long enough that a short
sweep does not see it.

Note that none of these failures produce an ALSA or daemon error. Only impulse
correlation reveals them.

### Scheduler latency measured: no real-time kernel needed

`cyclictest` v2.60, priority 99, all cores, 250 us interval, 300 seconds per
pass, 1.2 million samples per thread. Stock kernel, governor `ondemand`.

| Pass | Avg | Worst of four threads |
|---|---:|---:|
| Idle | 2 us | 62 us |
| Bridge live at `tlatency` 3000 | 2-3 us | **184 us** |

Zero histogram overflows in both passes. Against the 128-frame period of
2667 us that is **14.5x headroom**, and still 5.4x against a hypothetical
48-frame period.

**Do not pursue a PREEMPT_RT kernel.** Scheduling determinism is nowhere near
the binding constraint, and a kernel change would require rebuilding and
revalidating both the patched `usb_f_uac2` module and the RAVENNA prototype
LKM. That prototype does kernel-side RTP and timing, exactly the code
PREEMPT_RT locking changes tend to break. High risk to the protected rollback
path for no measurable gain.

**The `tlatency` 2000 underruns were not a scheduling failure.** A 384-frame
buffer is an 8000 us period against a 184 us worst case, 43x headroom, and it
still failed with continuous `underrun for playback plughw:CARD=RAVENNA`. The
buffer floor is set by the RAVENNA driver, the `plughw` conversion chain, or
per-period SRC work. Tightening buffers is not a scheduling problem.

**Most of Phase 6 also drops off the critical path.** IRQ affinity, core
isolation, and the governor all target a number already at 184 us; the entire
idle-to-loaded delta is 122 us against a 2667 us period. Setting the governor
to `performance` remains a trivial reversible change but is not a priority.

Caveat: `cyclictest` measures timer wake-up for an ordinary RT thread. It does
not measure NIC interrupt servicing, USB gadget completion, or RAVENNA's
internal scheduling. Necessary rather than sufficient evidence, but the margin
is wide enough that scheduling cannot explain anything observed.

### AoIP switch QoS

The NETGEAR GS305EP is in `Port-based` QoS mode with port 1, which carries the
Pi, set to `Low`. Every other port is higher. This is backwards, though it is
currently harmless: the Ferrofish reported zero late packets over 12:22 at a
2 ms receive setting with a 1.4 ms peak, no sink reported RTP errors, and PTP
jitter stayed between 3 and 11 ns on a gigabit link carrying roughly 25 to
30 Mbps.

The correct fix is not the port priority but the QoS mode. AES67 and Dante
already mark media as DSCP 34 and PTP as DSCP 46, and `Port-based` mode ignores
those marks, so PTP and media are treated identically. Switching to the
802.1p/DSCP mode makes the switch honour the existing marks and prioritise the
clock above audio. Expect no measurable latency change today; this is headroom
for when the network carries more.

Do not enable Broadcast Filtering casually, since some implementations also
affect multicast and SAP discovery runs on `239.255.255.255`. Treat the
MULTICAST menu with more caution still: IGMP snooping without a working querier
can black-hole multicast and take the streams down.

### Operational fact that dominates all testing

**This was fixed on 2026-09-01 by disabling IGMP snooping on the GS305EP.**
Time to first return signal went from 263-267 s to at most 52.4 s, and the
Mac's first sight of the Pi's SAP announcement from +282.3 s to +1.20 s. The
current operating point of the network is **IGMP snooping OFF**. Every figure
in this document recorded before that change was measured with snooping ON.

Historical description, retained because it explains the tooling and the
gotchas below:

**Audio took 263-267 seconds to start flowing after the AES67 daemon
restarted, and it was a fixed timer, not a device backoff.** Measured across
seven runs from `readiness-probe-*.json`: 263, 266, 265, 263, 267, 263, 263 s.

The mechanism is **not** the Ferrofish re-resolving subscriptions. The Pi's
daemon announces its sessions at T0 + 42.4 s (n=13, deterministic to ~100 ms),
and the audio path comes up ~220 s later. The best-supported explanation is the
IGMP group membership interval, `2 x 125 + 10 = 260 s`, on a link-local segment
with **no querier**: with snooping enabled and nothing to maintain membership
state, the GS305EP withholds the groups until that interval expires and then
falls back to flooding. See `work/SAP_DISCOVERY_FINDING.md` for the full split
and the falsifiable A/B this predicts.

Practical consequence: this was a *network* cost, not a daemon cost, and no
amount of daemon or bridge work would have shortened it. The Pi itself is ready
in about 42 seconds, and with snooping off that is now the binding constraint.

**Current network configuration and its one open risk.** Snooping is off, so
the switch floods all multicast to every port: a measured 68 Mbps. That is
under 7% of link for the Pi, Mac, Ferrofish and ULN-2, all of which are gigabit
or better. It is **68% of link for the 100 Mb Dante AVIO on port 4**, and at
96 kHz it would roughly double to 110-135 Mbps, exceeding that port's line
rate. Egress drops there would take out the AVIO's own Dante audio and PTP, not
just the traffic it never wanted.

Note that re-enabling snooping does **not** mitigate this. With no querier,
hosts report only at join time, entries age out at ~260 s and are never
re-learned, and with `Block Unknown Multicast Address` off the steady state is
flooding regardless. Snooping on would add a 260 s broken window and then flood
anyway. The only real mitigations are a querier, disabling port 4, or VLAN
isolation. This inference is consistent with every measurement but has not been
directly confirmed by measuring the flood rate with snooping on.

Consequences that must be respected by any future harness or service:

- A measurement fired shortly after the bridge reports ready will capture
  nothing. Five runs were lost to this before it was found.
- Any sweep that restarts the daemon costs about 4 minutes per point.
- **Sink delay is changeable live** through `PUT /api/sink/{0,1}` without
  touching sources, so the Ferrofish never re-subscribes and each point settles
  in seconds. Sweep parameters live wherever possible.
- `alsaloop` target latency is *not* live-changeable and requires the restart.

### Readiness gating: what does not work

`receiving_rtp_packet: true` with clean sequence, SSRC, payload, and SAC flags
is **not** a readiness gate. Every failed run showed exactly that state. This
is the same distinction that appeared when the Ferrofish was transmitting
digital silence: packet acceptance is not audio.

The only valid gate is a probe that detects the returned signal. Use short
impulse bursts and require both a captured peak well above the noise floor and
a tight per-impulse delay spread.

### Buffering

The `alsaloop` explicit period and buffer request is **counterproductive on
this driver** and must not be used.

| Request | Negotiated `buffer_size` | Round trip at delay 576 |
|---|---:|---:|
| `--period 96 --buffer 288` | 2304 frames, 48 ms | 74.146 ms |
| none, driver default | 960 frames, 20 ms | 44.292 ms |

The driver rounds the requested period up to 128 or 144 and settles on an
18-period buffer. This inverts an earlier assumption: the original probe's
rejection of the short `-E`/`-B` options was not a defect, and the defaults it
fell back to are better than what the corrected long options produce.

### Sink playout delay

Additive at close to 1:1. A configured span of 528 samples produced a measured
span of 514 samples.

| Sink delay | Round trip, driver-default buffering |
|---:|---:|
| 576 | 44.292 ms |
| 288 | 38.000 ms |
| 144 | 34.479 ms |
| 96 | 33.312 ms |
| 48 | 32.792 ms |

**Startup ordering constraint:** delay 48 applied before the receive stream
exists causes both sinks to report `all_muted: true`. Applied to an established
stream it works fine. Start conservative and tighten once audio is flowing.

### Ferrofish contribution

From Dante Controller, measured over a 12:22 window: receive latency setting
2 ms on both Pi flows, observed peak 1.4 ms, average 1.2-1.3 ms, **zero late
packets**, device latency 0.25 ms, PCM 24 at 48 kHz with AES67 enabled.

The Ferrofish costs roughly 3.5 ms including packetization. It is not a tuning
target, and its 2 ms setting has margin.

### Latency budget at the 32.792 ms operating point

| Term | Cost | Basis |
|---|---:|---|
| Mac, USB, one `alsaloop` at 5 ms target | 5.5 ms | measured USB-only |
| Second `alsaloop` direction | about 5 ms | its own target |
| Ferrofish receive plus device latency | about 3.5 ms | Dante Controller |
| Sink playout delay 48 | 1 ms | measured, additive |
| **Unattributed** | **about 18 ms** | remainder |

The unattributed term is dominated by the 960-frame, 20 ms ALSA buffer plus
RAVENNA period handling. It cannot be attacked by requesting an explicit
period or buffer, which is already measured to be worse.

A sweep of `alsaloop` target latency at 3000, 2000, and 1000 us was in progress
at the end of this session; see the results file for its outcome. If that
target proves not to be the gate, the 960-frame buffer is a floor of the
`plughw` plus adaptive-SRC path and **Phase 4, the single purpose-built
real-time bridge, is the real route to 10-20 ms.** Note that upstream describes
a 1000 us target as heavy CPU usage, so instability at that point is plausible
and is itself a useful floor.

### Measurement pitfall: correlation aliasing

The harness emits impulses every 250 ms, or 12000 samples. With
`--maximum-lag-ms` above that interval the correlator can lock one impulse
period late and report a plausible-looking but wrong result, for example 313 ms
where the truth was 63 ms. **Keep `--maximum-lag-ms` below 250.** A high score
with a large per-impulse spread is the tell.

### Unattended operation

A sudoers drop-in at `/etc/sudoers.d/usb16x16-latency` grants `bdimaio`
NOPASSWD execution of exactly four wrappers, now installed root-owned at
`/usr/local/sbin/`:

```text
run-aes67-candidate-safe.sh
run-selfloop-candidate-safe.sh
run-bridge-hold-safe.sh
run-ravenna-latency-safe.sh
```

Tuning variables cross the boundary through an `env_keep` list, so the
invocation form is `VAR=value sudo -n /usr/local/sbin/script` and `/usr/bin/env`
is never granted. **The scripts must stay root-owned**: NOPASSWD on a
user-writable script is equivalent to unrestricted root for that user.
Consequence: test runs are unattended, but deploying a script change requires a
password. That friction is the safety property, not a defect.

### Harness defects found and fixed

| Defect | Symptom | Fix |
|---|---|---|
| `alsaloop -s` not honored | loops ran indefinitely; wrapper blocked in `wait` | wrapped in `timeout -k 5 -s INT`, accepting 124/130/143 |
| `HUP` not trapped | dropping ssh left daemon, loops, and module loaded | `trap cleanup EXIT INT TERM HUP` in all wrappers |
| Readiness gated on sink flags | measured before audio existed; five runs lost | gate on a real signal probe |
| Settle log truncated | `measure` `2>` overwrote the diagnostic | separate `settle.log` in the API snapshot directory |
| Tuning env vars not forwarded | `USB16X16_SINK_DELAY` never reached the Pi | orchestrator forwards and echoes each variable |

Signal propagation note: killing the local ssh does **not** reliably deliver
`HUP` to the remote wrapper. Stop runs through a bounded window or the API
rather than relying on signals.

### Tooling added this session

| Path | Purpose |
|---|---|
| `work/aes67-candidate/measure-aes67-roundtrip.sh` | orchestrates the full round-trip measurement, forwards tuning variables, snapshots the daemon API, verifies cleanup |
| `work/aes67-candidate/run-bridge-hold-safe.sh` | brings the bridge up and holds it for interactive routing, printing live sink status |
| `work/aes67-candidate/sweep-sink-delay.sh` | Phase 2 sink-delay sweep wrapper |
| `work/aes67-candidate/run-selfloop-candidate-safe.sh` | retained negative result, see below |
| `work/latency-harness/watch-return-signal.sh` | fires repeated impulse bursts and reports lock or silence; the tool that first found the time-to-audio, later measured at 263-267 s |
| `work/aes67-candidate/measure-phase4-roundtrip.sh` | runs the single-process Phase 4 bridge through the same signal-gated harness |
| `work/aes67-candidate/sap-watch.py` | passively timestamps SAP announcements so discovery and subscription resolution can be separated |
| `work/phase4-bridge/` | implemented shared-estimator real-time bridge, guarded installer, tests, and pinned Pi artifact |

`run-bridge-hold-safe.sh` still hard-codes `--period 96 --buffer 288` and
therefore the worse 2304-frame buffering. Make it match the candidate wrapper's
env-tunable, default-omitted behavior before using it for measurement.

### Withdrawn claims

- The first orchestrator-driven sink-delay sweep is **void**. All four points
  failed because of the readiness gate, not the parameter. The control at the
  known-good delay 576 failed identically, which is what exposed the harness
  fault.
- "Sink delay 48 is too aggressive for a real peer" is **wrong as stated**. It
  is a startup-ordering constraint only.
- The AES67 self-loop on `eth0` remains rejected and should not be retried; see
  the section above.

## Next-session checklist

1. Verify `usb-16x16.service` is active and the UDC is `configured/high-speed`.
2. Confirm macOS exposes `USB 16x16` through CoreAudio before any measurement.
3. Confirm the Pi is clean: no `ptp4l`, `aes67-daemon`, or `alsaloop`, and the
   RAVENNA module unloaded.
4. Remember that `eth0` at `169.254.92.97` is the AES67 network and `wlan0` at
   `192.168.1.201` is management. SSH working says nothing about AoIP health.
5. **Continue Phase 4 estimator diagnosis.** Every other lever has been measured and eliminated.
   Parameter tuning of the dual `alsaloop` stack has reached its floor, and
   scheduling latency has 14.5x headroom, so the single purpose-built bridge
   with one shared clock-drift estimator remains the only route to a stable
   10-20 ms. Start with the input/output/playback-consumption counter evidence
   in the currently pinned diagnostic build; do not treat the bridge as an
   accepted replacement yet.
6. Validate Phase 4 against the same harness that produced these numbers so the
   before-and-after comparison is meaningful.
7. Budget about 4 minutes of dead time per daemon restart, and prefer live
   `PUT /api/sink/{0,1}` changes for anything that supports them.
8. Never gate a measurement on sink flags. Gate on a detected return signal.
9. Once an operating point is chosen, run the required ten-minute clean
   acceptance soak with all sixteen channels loaded; every figure recorded so
   far is reconnaissance, not an acceptance soak.
10. Then implement the persistent service plan, exposing latency mode and buffer
    parameters rather than baking in fixed values.
11. The host channel-name requirement is complete. macOS reports `1` through
    `16` in both directions on the same native duplex `USB 16x16` device; the
    setup script and `usb-16x16.service` remain unchanged.
12. After the low-latency service is stable, implement DSP / Content mode as a
    separate optional profile.

## Clean manual shutdown

When the daemon is running in the foreground, press `Ctrl+C` and wait for `main:: end` so `status.json` is saved. Confirm no `alsaloop` processes remain, then run:

```bash
sudo shutdown -h now
```

After SSH disconnects and activity stops, unplug the USB data cable first and then the PoE Ethernet cable.

## Rollback rules

- The verified USB module, service, and setup script are immutable baselines.
- Every experimental module must use a distinct path/name and have explicit restore commands.
- Never remove the known-good module before the alternate build passes cold-boot and macOS enumeration tests.
- AES67 service stop/disable/removal must leave `usb-16x16.service` active.
- Never run external `ptp4l` beside the daemon PTP slave.
- Change only one clock, descriptor, buffer, scheduler, or IRQ variable at a time.
- Record hashes, commands, logs, and latency results for every accepted configuration.
- DSP-mode services/configurations must remain separately disableable and must not replace the low-latency rollback path.
