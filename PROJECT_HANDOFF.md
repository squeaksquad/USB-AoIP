# Raspberry Pi 5 USB 16x16 / AES67 bridge handoff

**Authoritative state:** 2026-09-02

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

**THIS ACCEPTANCE IS WITHDRAWN.** See "The 40-impulse soak is barely loaded"
below. Both soaks carried 10 s of impulse traffic in 600 s, and under 200 s of
sustained load this configuration failed.

#### The stopgap re-baselines at 32.729 ms, and its 12 ms defect did not recur

Run `223421Z`, 800 impulses over 200 s, `tlatency 3000`, sink delay 576,
driver-default buffering -- the accepted stopgap configuration.

| | documented (2026-08-31) | **re-baselined (2026-09-01)** |
|---|---:|---:|
| median | 20.688 ms | **32.729 ms** |
| p95 | 32.833 ms | 33.063 ms |
| spread | 12.896 ms (bimodal, 590 samples) | **0.333 ms (16 samples)** |
| distribution | 28/31 low, 3/31 high | 77.4% at 1571, 17.8% at 1587, 5 transitions |

**The documented 20.688 ms no longer holds.** Gotcha #2 warned that figures are
not comparable across the IGMP snooping change and that the point must be
re-baselined rather than compared. This is that re-baseline.

**The 12 ms bimodal step did not reproduce.** The documented defect was 590
samples; the entire spread today is 16 samples. The "unpublishable latency"
objection to the stopgap is therefore much weaker than the older document says.

**Correction to today's session:** the figure "32.792 ms stopgap" used
throughout the commits above is wrong in provenance -- it is the *sink delay
48* row, a configuration this document elsewhere calls unusable on this path.
It coincidentally lands within 0.06 ms of the true current value, so
conclusions drawn against it happen to survive, but they were right by luck.

#### The 40-impulse soak is barely loaded, and Phase 4 fails under real load

**`--impulses 40` at 250 ms spacing measures a 10 second window.** Every Phase 4
acceptance soak recorded above ran 600 s of bridge with **10 s** of impulse
traffic. The project rule asks for a *loaded* soak; those were not meaningfully
loaded, and every "score 1.000, zero spread" figure describes 10 s, not 600.

Run `224517Z` is the first Phase 4 run with sustained load: same
`TX 192 / RX 96` configuration, 800 impulses over 200 s.

**It failed.** `candidate_exit=33`. Zero restarts for 563 s, including the whole
measurement, then TX `playback-avail code=-32` broken pipe with
`playback_state=XRUN`, followed by a cascade of RX `capture-ring-full` at
ring=768 and repeated re-priming. 45 recoveries in the final ~37 s. USB baseline
survived.

The measurement it produced before failing was excellent -- median 27.729 ms,
88.2% of impulses on one sample, spread 10 samples (0.208 ms), score 0.929,
against the stopgap's 0.333 ms spread and 0.306 -- but it comes from a run that
then failed, so it is not a usable result.

**The obvious explanation is wrong.** Mac CoreAudio teardown after the
measurement does not explain it: the clean soaks ran 441 s and 228 s
post-teardown without incident, while this failed 19 s after a measurement that
left only 56 s. What distinguishes this run is 200 s of sustained impulse load
against 10 s. `tx_qfloor` read 89 here against 124 in the clean soak. **The
mechanism is not known and should not be guessed at.**

**Under identical 800-impulse load the stopgap completed cleanly** (`223421Z`,
`candidate_exit=0`) while Phase 4 did not. On equal footing that is a material
disadvantage for Phase 4, and it is why the acceptance above is withdrawn.

**Reproduction: it did not repeat.** Run `225802Z`, same configuration, same
800 impulses, completed cleanly at 27.979 ms with `tx_qfloor` 126. So sustained
load is **not** the cause either. What remains is one unexplained failure in
four runs of this configuration.

#### ROOT CAUSE: the initial settle is a lottery and its outcome is permanent

**EXPLANATION RETRACTED 2026-09-01, measurements retained.** See "CORRECTION:
the 1 Hz queue reading is a stroboscope" below. The 285 -> 237 reading this
section builds on is a sampling artefact that the clean run shows too; the
per-iteration floors put the two runs about ten frames apart, not 48, and the
XRUN was not preceded by any stall. The tables and counts below are still
what was measured.

Comparing the failed and clean 800-impulse runs, which prime identically:

| | at prime | by t=30-40 s | `tx_qfloor` | TX under a period | outcome |
|---|---:|---:|---:|---:|---|
| `224517Z` | 480 fr | **432 fr (-48)** | 89 | 7.2% | XRUN at 563 s |
| `225802Z` | 480 fr | **475 fr (-5)** | 126 | 0.03% | clean |

Both start at TX depth 480 with identical `PRIMED` lines, identical `tx_occ`
195 / `tx_queue` 285, and hold it for the first 20 s. **Within the first ~30 s
the failed run shed a discrete 48-frame chunk of TX depth and never recovered
it.** By t=120 its `tx_qlow` was already 7,681 against the clean run's 0.

The reason it never recovers is the structural property already documented
here: the servo regresses ring plus queue while the control law regulates the
ring alone, so **the playback queue has no restoring force** and total depth is
conserved after priming. This session measured that conservation three separate
times. Applied to the initial transient it means: **whatever depth a run has
lost by t=30 is lost for the life of the process.**

So a Phase 4 point's entire safety margin is decided in the first thirty
seconds by a transient nothing regulates. That is why `tx_qfloor` scatters
across 89 / 104 / 124 / 126 for one configuration, and why roughly one run in
four lands low enough to fail.

**Three explanations were falsified along the way**, each by measurement:
CoreAudio teardown (the clean soaks ran 441 s and 228 s post-teardown),
sustained load (`225802Z` is clean at 800 impulses), and prime state (both runs
prime identically).

**Consequences.**

- **No Phase 4 point is deployable as it stands.** The margin is not a property
  of the configuration; it is a draw.
- Raising TX's prime buys robustness against a bad draw at a latency cost.
  `--tx-playback-prime 288` is the maximum at buffer 192 and would leave ~137
  frames of floor even after a 48-frame loss, for roughly +2 ms. Untested.
- The real fix is a restoring force on the playback queue. **The naive version
  of this has already been tried and failed catastrophically** -- it drained the
  elastic ring to the interpolator's 8-frame reserve and XRUNed at 22 s. A
  correct version must act slowly and must never draw the ring below its
  reserve.
- Acceptance criteria need revisiting: a single clean soak cannot establish
  safety for a property that varies run to run. Repetition is required, and
  `tx_qfloor` should be an acceptance metric alongside latency.

#### Mitigation measured: TX prime 288 makes TX's floor invariant

Four runs, buffer 288 requested, `--tx-playback-prime 288 --rx-playback-prime
96`, 600 s each with the 800-impulse sustained load. `NEGOTIATED` returned
`usb=96/384 ravenna=128/288` -- **identical to the buffer-192 runs**, because
192 already rounds up to 288 on RAVENNA, so TX prime is the only variable.
(The wrapper validates the prime against the *requested* buffer, which is why
288 must be requested rather than 192.)

| run | median | TX overshoot | `tx_qfloor` | TX under period | RX overshoot | `rx_qfloor` |
|---|---:|---:|---:|---:|---:|---:|
| 1 | 29.979 ms | 93 | **144** | 0.000% | 45 | 45 |
| 2 | 29.979 ms | 93 | **144** | 0.000% | 93 | 93 |
| 3 | 30.979 ms | 93 | **144** | 0.000% | 93 | 93 |
| 4 | 30.979 ms | 93 | **144** | 0.000% | 93 | **45** |

Zero restarts and zero drops in all four.

**`tx_qfloor` is invariant at 144** against 89/104/124/126 at TX prime 192, and
TX never dips under one RAVENNA period. That is the result worth having: the
metric that predicted the failure has stopped varying. Four clean runs on their
own would prove little -- 0 of 4 bounds the failure rate very weakly -- but an
invariant floor sitting 48 frames clear of a period is mechanism-level
evidence rather than a pass count.

**There are two paths to the same 48-frame deficit.** Runs 1 and 2 suggested
`rx_qfloor` simply equals the prime overshoot (45 -> 45, 93 -> 93). **Run 4
refutes that**: overshoot 93 but floor 45. So a run can lose its 48 frames
either as a short draw at prime (run 1) or shortly after priming (run 4, and
the original failure `224517Z`). Do not treat the `PRIMED` line as a complete
predictor.

**RX remains exposed.** `rx_qfloor` still swings 45/93 and 45 is below USB's
96-frame period. It has not failed, but the lottery has been moved off TX, not
removed. Raising RX's prime is the same trade again and is untested.

**Latency is an independent degree of freedom.** Runs 1 and 4 share
`rx_qfloor` 45 yet measure 29.979 and 30.979 ms; runs 2 and 3 share overshoot
93 and floor 93 and also differ by one 48-sample step. Latency scatter and
safety scatter are separate phenomena and must not be reasoned about together.

**Cost.** 29.979-30.979 ms against 27.979-28.729 ms at TX 192, so roughly
+2 ms, and 1.75-2.75 ms faster than the stopgap's re-baselined 32.729 ms.

#### CORRECTION: the 1 Hz queue reading is a stroboscope, and the XRUN is a between-wakeup margin

Re-reading `224517Z` and `225802Z` from the per-iteration floors rather than
the 1 Hz print, on 2026-09-01.

**`tx_queue` at 1 Hz is not a depth measurement.** The RAVENNA playback device
pulls one AES67 packet per millisecond, 48 frames, and the 1 Hz sample lands
either side of a pull: it reads 285 or 237 and nothing between for the first
minute of *both* runs. The clean run toggles 285 -> 237 at t=40 exactly as the
failed run does at t=22. Later in a run the sample phase slides with the servo
ramp and the print wanders through 190-280. So "shed a discrete 48-frame chunk
by t=30" was the strobe, not a loss. Both runs prime identically and both
read `tx_dfloor` 432 at t=60.

**What actually separates the runs**, from floors sampled every iteration:

| | failed `224517Z` | clean `225802Z` |
|---|---:|---:|
| `tx_qfloor`, whole run before the XRUN | **116** | 126-128 |
| `tx_qlow` (samples under one RAVENNA period) | 4,920 by t=100, rising ~6k/min | 0 until t=420, then 211 |
| `tx_cappeak` | 96, never higher | 96 |
| floors on the last line before RECOVER | unchanged since t=120 | -- |

Ten frames of floor, not 48. And the failed run's queue spends roughly 12% of
iterations under a period from t=60 onward while the clean run spends none:
its sawtooth minimum sits just under 128 rather than just over. That is a
phase draw between USB's 96-frame pushes every 2 ms and RAVENNA's 48-frame
pulls every 1 ms.

**No stall preceded the XRUN.** `tx_cappeak` stayed at 96 for the whole run,
so the bridge thread never fell more than one USB period behind on capture.
The floors on the last telemetry line before the RECOVER are the same as at
t=120. The queue went from a sampled floor of 116 to empty between two
wakeups. Nothing the bridge samples can see that interval: the device-side
minimum is the sampled floor minus whatever the device pulls before the next
wakeup, and that quantity has never been measured.

**SUMMARY floors on a failed run are contaminated.** `224517Z` reports
`tx_queue_floor` 89 in SUMMARY; the last line before the first RECOVER reads
116, and 89 comes from the recovery cascade. The 89/104/124/126 scatter quoted
above mixes both. Read floors from the last pre-RECOVER line, or from the
`*_before_recovery` fields the next build adds.

**TX-288's invariant floor of 144 is the buffer ceiling.** With prime 288 plus
93 overshoot the queue is pinned full at 288 and the ring holds the surplus;
the floor is buffer minus one push minus one pull, 288 - 96 - 48 = 144, and it
cannot go higher at this buffer. The RAVENNA playback buffer of 288 frames is
the ceiling on TX safety, and the mitigation already sits at it.

**The depth floor steps down mid-run in every run**, by 48 or by 85-90
frames, at random times: `tx_dfloor` 432 -> 401 -> 316 in the failed run,
480 -> 415 -> 325 in `221302Z`, 528 -> 484 -> 396 in `232430Z`. Whether that
is depth actually lost or the device pulling early is exactly what the
existing counters cannot say, and it is the fact the restoring-force design
depends on. Instrumented next; see the pull-burst build.

**Consequences.** The failure is a razor margin everywhere, not a lottery in
the first thirty seconds. A restoring force on depth is only worth building
if the per-second mean depth is shown to leak. The levers that address the
razor directly are a larger RAVENNA playback buffer (independently of the
capture buffer) and finer wakeups if the devices advance their pointers per
packet. Both are unmeasured.

#### MEASURED: the RAVENNA device skips one packet about every minute, and the XRUN is that skip landing on the sawtooth floor

Three 600 s runs on the pull-burst binary `4791d577`, all `96/192/768/192`
with `--tx-playback-prime 192 --rx-playback-prime 96`, 2026-09-02. Two ran
without impulse load by accident (see the gate finding below), which turned
out to be useful: the device behaviour is identical with and without load.

| run | load | outcome | `tx_qfloor` | `rx_qfloor` | TX pull max | 144-pulls | TX depth mean | RX depth mean |
|---|---|---|---:|---:|---:|---:|---:|---:|
| `005914Z` | none | clean | 101 | 93 | 144 | 7 | 422 | 440 |
| `011349Z` | none | clean | 104 | 93 | 144 | 7 | 426 | 436 |
| `012708Z` | **800 impulses** | **clean, 28.479 ms** | **130** | 93 | 144 | 10 | 451 | 411 |

`012708Z`: 800 impulses, median 1367 samples, spread 10, score 0.924, with
700 impulses on 1367 and 92 on 1359. Zero restarts, zero drops in all three.

**1. The pull burst is measured, and it is three packets.** RAVENNA playback
normally consumes 96 frames, two packets, between consecutive bridge
observations. Seven to ten times per run it consumes **144 within one gap of
at most 1.94 ms**. The bridge's longest gap between observations was 2.03 ms
in any run, so this is not a stall on our side; the device took three
packets in two milliseconds. USB playback never exceeded 96.

**2. Each 144 pull is a timebase step, and the depth it moves is not lost.**
In the same second as every 144 pull, TX's per-second depth mean drops by
35-47 frames and RX's rises by the same amount. The sum of the two means sits
at 858-865 for all three runs, from the first second to the last. Total depth
is conserved exactly as this document said; what moves is the split between
directions. The RAVENNA device advanced its clock by one packet: its playback
consumed an extra 48 and its capture delivered an extra 48.

**3. The steps are quasi-periodic and threshold-driven.** In steady state
they arrive 56-69 s apart (one 262 s gap, and three doublets 4-7 s apart),
and every one fires after TX's mean has climbed to about 440-473 frames.
Between steps TX climbs at roughly 0.65 frames/s. Read as a mechanism, stated
as an observation: the device's steady pull rate runs about 15 ppm below its
long-term rate and it catches up by skipping a packet. The estimator tracks
the long-term rate, which is correct, and it is why the commanded ppm hunts
between -12.3 and -18.5 with roughly the step period. The differential is a
45-frame sawtooth around a stable mean, not a leak.

**4. This is the XRUN, and it settles the design question.** The failed run
`224517Z` had a sampled TX floor of 116. A step that lands when the queue is
at its 96-frame push sawtooth minimum needs 144 frames in hand, so survival
at these floors is a matter of phase, and about ten steps per run gives the
odds their chance. Today's floors of 101, 104 and 130 all survived 7-10
steps; that is luck with better odds, not margin.

**There is no leak to restore, so the slow restoring force proposed in the
correction above is withdrawn.** A slow loop cannot cancel a periodic
48-frame skip, and the mean it would hold is already held by the rate loop.
What the pipeline needs is a fixed device-side margin: at the sawtooth floor,
TX must hold two packets for the normal pull plus one for the skip. With the
RAVENNA playback buffer at 288 the sampled floor cannot exceed 144 (the
TX-288 point), which leaves that margin at zero. TX-288's four clean runs are
better odds, not a guarantee.

**5. Where the floor scatter comes from.** TX depth means of 422, 426 and 451
gave floors of 101, 104 and 130: the run-to-run variation is where the
differential's resting level lands, which the regression's free intercept
leaves to chance. A differential phase term could hold that split at a chosen
bias toward TX. It is worth perhaps 30 frames, paid for out of RX, whose own
floor of 93 sits under USB's 96-frame pulls. A small lever, not the fix.

**6. Capture granularity.** RAVENNA capture backlog lands in the 1-48 bin
78-93k times per run, so its pointer advances per packet. USB capture never
does; it moves in 96-frame periods. A 48-frame `avail_min` can halve RX's
push sawtooth and cannot touch TX's.

**Levers, in order.** (a) A per-PCM buffer request: RAVENNA playback at 384
with capture held at 288 raises TX's floor ceiling from 144 to 240, and
tests whether the 5 ms attributed to buffer 384 lives on the capture side.
One variable. **Implemented, untested**, in binary `0254348c`:
`--ravenna-playback-buffer FRAMES` (0 = `--buffer`), the wrapper's tenth
positional argument, and `USB16X16_PHASE4_RAVENNA_PLAYBACK_BUFFER_FRAMES` on
the measure shim. The wrapper validates the TX prime against this request
when it is given, so TX prime 288 with buffer 192 no longer needs buffer 288
requested. Read `NEGOTIATED` to confirm what the device actually granted.
(b) The differential bias above. (c) `avail_min` 48 on RAVENNA capture for
RX.

**Harness gate finding, from `011349Z`.** The readiness probe required the
eight impulses of a probe to land within 2 samples of each other. Buffer-192
points have a real 8-sample bimodality (this loaded run: 700 impulses on 1367,
92 on 1359), so a probe passed only when all eight happened to hit one level
and three consecutive passes took luck: 23 probes on `225802Z`, never in 131
probes here, while every one of those 131 probes measured 27.48 ms. The path
was fine for ten minutes and the run carried no load. Fixed:
`USB16X16_READY_MAX_SPREAD_SAMPLES`, default 2 so the stopgap path is
unchanged, and the Phase 4 shim sets 9. `012708Z` was ready after 3 probes.

**Two workflow notes.** The Pi wrapper survives the Mac-side ssh dropping and
runs to its time limit, so a killed measurement still occupies the Pi for
the full window. And a `pgrep -f` for the bridge from inside an ssh command
matches the ssh shell's own command line; anchor the pattern as the wrapper
does.

#### MEASURED: RAVENNA playback at 384 alone costs 1.67 ms and buys no floor until the prime uses it

Run `015059Z`, 600 s, 800 impulses, binary `0254348c`, buffer 192 with
`--ravenna-playback-buffer 384`, TX 192 / RX 96. `NEGOTIATED` confirms the
per-PCM request took: `ravenna_capture=128/288 ravenna_playback=128/384`,
USB unchanged at 96/384. Zero restarts, zero drops, ready after 3 probes.

| | `012708Z` RAVENNA playback 288 | **`015059Z` RAVENNA playback 384** | change |
|---|---:|---:|---:|
| median | 28.479 ms (1367) | **30.146 ms (1447)** | **+80 samples, +1.667 ms** |
| score / spread | 0.924 / 10 | 0.944 / 10 | |
| impulse levels | 700 on 1367, 92 on 1359 | 731 on 1447, 62 on 1439 | same 8-sample bimodality |
| `tx_qfloor` | 130 | **122** | ceiling moved, floor did not |
| `rx_qfloor` | 93 | 93 | |
| TX 144-pulls | 10 | 4 | |
| depth-mean sum | 862 | 862 | conserved again |

**Latency: the playback side of the buffer effect is 1.67 ms.** The earlier
runs moved both RAVENNA PCMs 384 -> 288 together and measured -5.33 ms. This
moves playback alone and measures +1.67 ms, one third of it. The remainder
sits with the capture buffer by subtraction, which is an inference from two
runs and not a measurement; a capture-only request would measure it.

**Floor: unchanged, as it had to be.** The prime still puts 192 + 93 frames
in the queue, so the sawtooth sits where it did and the floor reads 122
against 101/104/130 at buffer 288. The larger buffer only raises the
ceiling from 144 to 240; using it means raising TX's prime into the new
headroom, which costs about 1 ms per 48 frames on top of the 1.67 ms.

**The trade this fixes, priced.** For TX to hold a skip deterministically
it needs 144 frames at its sawtooth floor. At RAVENNA playback 384 that is
TX prime 288 (queue capped at 384, floor ceiling 240, margin 96) for about
+2 ms, landing near 32 ms, the stopgap's re-baselined 32.729 ms. TX prime
240 (floor 192, margin 48) lands near 31 ms. Neither is measured. The choice
is between beating the stopgap by 2-4 ms with skip survival left to phase,
or matching it with the skip covered.

**One anomaly to keep.** The fourth 144-pull at t=421 moved TX's mean *up*
17 frames and RX's down, the reverse of every other step recorded. Either
the device stepped the other way or a three-packet pull coincided with the
servo's own motion. Not explained; do not build on it.

#### MEASURED: a live sink-delay change never reaches the bridge

One 720 s candidate, `022225Z`, buffer 192, TX 192 / RX 96, RAVENNA
playback 288. After readiness, both sinks were rewritten over the daemon API
with only `delay` changed, readback confirmed, 20 s settle, three readiness
probes, then 200 impulses per point. Script:
`work/aes67-candidate/sweep-phase4-sink-delay.sh`; results in
`outputs/latency/phase4-sink-sweep-20260902T022225Z/`.

| sink delay | applied at bridge second | median | spread | score |
|---:|---:|---:|---:|---:|
| 576 (as primed) | 287 | 27.479 ms | 10 | 0.922 |
| 288 | 372 | 26.812 ms | 10 | 0.944 |
| 144 | 461 | 29.146 ms | 9 | 0.882 |
| 96 | 546 | 28.146 ms | 9 | 0.919 |

**Not additive, not monotonic, and not visible to the bridge.** In the
stopgap the sink delay was additive at close to 1:1, 11.5 ms across 576 -> 48.
Here a 480-frame span moved the median by at most 2.3 ms in either direction.
At every one of the four changes the bridge log shows nothing: zero
recoveries, no re-prime, no capture burst (`rx_cappeak` held at 144, its
normal value), and the RX ring and queue means continuing their slow servo
drift straight through the change second. The one step in any window, at
t=461, is a RAVENNA skip (`DEPTHSTEP`, pull 144) that happened to land there.

So a live `PUT` with a new `delay` re-registers the sink but does not re-time
the running capture stream the bridge reads. The scatter between points is
the same 8-sample bimodality and run-to-run drift every buffer-192 run shows.

**What this does and does not settle.** Changing the sink delay live is not a
latency lever under Phase 4. Whether the value the wrapper pins at startup
matters is still open: the stopgap's 1:1 result came from separate runs, each
started at its delay. **The wrapper now takes the sink delay as its eleventh
positional argument** (default 576, validated 48..2400, applied to both sinks
before the bridge primes, readback checked against it), and the measure shim
reads `USB16X16_PHASE4_SINK_DELAY`. Wrapper re-pinned and staged; the bridge
binary is unchanged. Untested: one run per point is the experiment.

**This run's floors are the lowest yet:** `tx_qfloor` 83, `rx_qfloor` 45, TX
depth mean about 390 against 422-451 in the previous four runs, with RX
priming at overshoot 45 rather than 93. Five 144-pulls, all survived, at a
floor 61 frames under what a skip at the sawtooth minimum needs. The draw is
now spread across 83-130 for one configuration. Nothing about the skip cover
has changed; this run is another point on the same razor.

#### MEASURED: sink delay 144 at startup lands on the same sample as 144 applied live

Run `024103Z`, 600 s, 800 impulses, sink delay 144 pinned by the wrapper
before the bridge primed, readback confirmed on both sinks, everything else
as the 28.479 ms baseline.

| sink delay | how applied | median | samples |
|---:|---|---:|---:|
| 576 | baseline `012708Z` | 28.479 ms | 1367 |
| 576 | live, sweep | 27.479 ms | 1319 |
| 288 | live, sweep | 26.812 ms | 1287 |
| 144 | live, sweep | 29.146 ms | 1399 |
| **144** | **at startup** | **29.146 ms** | **1399** |
| 96 | live, sweep | 28.146 ms | 1351 |

**The live change did take effect after all, just not through anything the
bridge counts.** Startup 144 and live 144 land on exactly the same sample.
So the sink delay is a real, reproducible input to the round trip under
Phase 4, and the bridge's ring and queue counters are simply not where it
acts. The correction above stands on its evidence and is wrong in its
conclusion: "never reaches the bridge" should read "never shows in the
bridge's depth".

**It is not a lever.** Across 576 -> 96, a span of 10 ms of configured
delay, the measured round trip moves within a 2.3 ms band and not
monotonically: 288 is the lowest point, 144 the highest. The bridge conserves
its own depth, so whatever the sink delay shifts is absorbed somewhere with
a small, setting-dependent residue. Reading a mechanism into the residue
would be algebra on aggregates; it is recorded as a curve, not explained.

This run's floors: TX 109, RX 93. Clean, ready after 3 probes.

**Sink delay is closed as a Phase 4 latency question.** 288 is worth 0.7 ms
on one live point and nothing on repetition has been tried; not worth a
run. The next lever is the ring target.

#### MEASURED: ring target 128 -- 24.479 ms, 4.0 ms faster, and it spends queue floor to get there

Run `025906Z`, 600 s, 800 impulses, `--target 128` with everything else as
the 28.479 ms baseline (buffer 192, TX 192 / RX 96, sink delay 576). Clean,
zero restarts, ready after 3 probes.

| | baseline `012708Z` target 192 | **`025906Z` target 128** | change |
|---|---:|---:|---:|
| median | 28.479 ms (1367) | **24.479 ms (1175)** | **-192 samples, -4.000 ms** |
| score / spread | 0.924 / 10 | 0.932 / 10 | |
| prime overshoot, per direction | 93 | **61** | -32 |
| depth-mean sum | 862 | **670** | -192 |
| ring occupancy min (1 Hz) | 195 | 131 | target + 3, never drawn on |
| `tx_qfloor` / `rx_qfloor` | 130 / 93 | **97 / 61** | |
| TX / RX samples under a period | 0% / 3.3% | **19% / 20%** | |
| max wakeup gap | 1.99 / 2.03 ms | 1.98 / 2.03 ms | unchanged |
| TX 144-pulls | 10 | 5 | all survived |

**Where the 4.0 ms came from.** The target fell by 64 per direction, which
is 2.67 ms round trip. The other 1.33 ms is the prime overshoot, which fell
from 93 to 61 per direction because the lower prime threshold is crossed on
a different capture phase. Depth-mean sum dropped by exactly 192 frames and
the median by exactly 192 samples. That is the fourth time depth has
predicted latency to the sample at this buffer.

**The ring itself is fine at 128.** Occupancy never went under target + 3,
and the wakeup gap maximum is unchanged at 2 ms against 128 frames of
cover. The ring reserve has still never been drawn on.

**The cost is in the queues, not the ring.** The overshoot was part of what
the queues held, so TX's floor is 97 and RX's is 61, under USB's 96-frame
period, with a fifth of all samples in both directions below one period.
Five skips were survived at a TX floor 47 frames short of what a skip at
the sawtooth minimum needs. This point is faster than anything measured
and less safe than anything measured.

**The point to run next combines the two levers.** Target 128 with RAVENNA
playback 384 and TX prime 288 restores the TX ceiling to 240 with the skip
covered, priced from the two measured deltas at roughly 28 ms: about 4.5 ms
under the stopgap with margin rather than phase. RX prime 144 would put RX's
floor back over a period for about 1 ms more. Untested.

#### MEASURED: the combined point -- 29.146 ms with TX's floor at 196, the first measured cover over the skip

Run `031504Z`, 600 s, 800 impulses: `--target 128`, RAVENNA playback
buffer 384, TX prime 288, RX prime 144, buffer 192, sink delay 576. Clean,
zero restarts, ready after 3 probes. `NEGOTIATED` confirms
`ravenna_capture=128/288 ravenna_playback=128/384`.

| | target 128 alone `025906Z` | **combined `031504Z`** | stopgap |
|---|---:|---:|---:|
| median | 24.479 ms | **29.146 ms (1399)** | 32.729 ms |
| score / spread | 0.932 / 10 | 0.947 / 9 | 0.306 / 16 |
| `tx_qfloor` | 97 | **196** | |
| TX samples under a period | 19% | **0** | |
| TX queue at 1 Hz | | 240-350 | |
| `rx_qfloor` | 61 | 60 | |
| RX samples under a period | 20% | 24% | |
| TX 144-pulls | 5 | 5, all survived | |
| max wakeup gap | 2.0 ms | 2.0 / 2.1 ms | |

**TX now carries cover.** A sampled floor of 196 against a 144-frame skip
leaves 52 frames, about 1 ms, of device-side margin at the sawtooth minimum.
Every previous point had that margin negative. It is not the full 96 the
ceiling allows: TX primed at 288 + 61 overshoot = 349, short of the 384
buffer, so the queue is not pinned full. TX prime 336 would pin it and put
the floor near 240, for about 1 ms more.

**RX prime 144 bought nothing, and the reason is a rule.** Across every run
RX's floor has equalled its prime plus its overshoot minus 96: 96+93 -> 93,
96+45 -> 45, 96+61 -> 61, and here 144+13 -> 60. The overshoot is a draw
(13/45/61/93 observed), so RX's floor is a draw too. RX's consumer is the
USB gadget, which pulls exactly 96 every 2 ms and never skips, so its
sampled floor is its true minimum and RX has never failed at floors down to
45. It is thin by design rather than by accident, but nobody chose it. To
make it deterministic RX's queue would need to be pinned full like TX's,
which on USB's 384 buffer costs about 5 ms; not recommended.

**Accounting.** Depth-mean sum 766 frames: TX 452, RX 314. The median
moved from 1175 (target 128 alone) by +224 samples for +96 TX prime, +48 RX
prime, and the overshoot draws; it matches the priced figure of "near
29 ms" from the two measured deltas.

**Status.** 3.6 ms under the re-baselined stopgap, tighter spread, every
counter clean, and TX's floor above the skip for the first time. One run.
It needs repetition before anything is claimed: the TX overshoot draw
(61 here, 93 elsewhere) moves the floor by the same amount, so expect 196
to scatter by tens of frames while staying above 144. Three more runs, and
`tx_qfloor` above 144 in all of them, is the acceptance test this document
now asks for.

#### ACCEPTED: the combined point, four runs under load, TX floor above the skip in all of them

Three repeats of `031504Z`, identical configuration: `--target 128`,
RAVENNA playback buffer 384, TX prime 288, RX prime 144, buffer 192, sink
delay 576, 600 s, 800 impulses each, run back to back on 2026-09-02.

| run | median | samples | score | spread | TX / RX overshoot | `tx_qfloor` | `rx_qfloor` | TX under a period | skips | restarts |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `031504Z` | 29.146 ms | 1399 | 0.947 | 9 | 61 / 13 | **196** | 60 | 0 | 5 | 0 |
| `034616Z` | 29.146 ms | 1399 | 0.946 | 10 | 61 / 13 | **197** | 61 | 0 | 10 | 0 |
| `035724Z` | 29.146 ms | 1399 | 0.967 | 9 | 61 / 13 | **193** | 61 | 0 | 6 | 0 |
| `040831Z` | 28.146 ms | 1351 | 0.945 | 9 | 61 / 13 | **158** | 61 | 0 | 5 | 0 |

**Acceptance as this document now defines it: four 800-impulse runs, zero
failures, and `tx_qfloor` above 144 in every one.** Passed. 26 skips
survived across the four runs, none of them by phase: TX never once
sampled under a period.

**The prime overshoot has become deterministic.** At target 192 it drew
45/61/93 per direction run to run; at target 128 it read 61 on TX and 13
on RX in all four runs. Whatever phase relationship the lower threshold
lands on, it lands on it repeatably. That removes one of the two sources
of run-to-run scatter.

**The remaining scatter is the differential's resting level.** Run
`040831Z` settled with TX's depth mean at 415 against 450-453 in the other
three, and RX correspondingly higher. That is the free intercept of the
rate regression landing 37 frames differently, and it shows up twice: TX's
floor at 158 rather than 193-197, and the median one 48-sample step lower
at 1351. So the worst observed TX margin over the skip is 14 frames, the
typical margin about 50, and the latency is 29.146 ms three times in four.
Quote 29.1 ms and a floor of 158-197.

**Against the stopgap:** 3.6 ms faster, spread 9-10 samples against 16,
score 0.95 against 0.31, and no 12 ms bimodal defect. Against the fastest
Phase 4 point measured (24.479 ms at target 128 alone): 4.7 ms slower, with
the failure mode covered instead of left to phase.

**What would widen the worst case.** TX prime 336 pins the 384 queue full
(336 + 61 = 397 > 384), which takes the floor ceiling to 240 and removes the
overshoot's influence on TX's floor entirely; the differential level would
still move it. About +1 ms. Not measured. A differential bias in the
estimator would address the level itself; small, and now the only scatter
left.

**This is the point to deploy.** Deployment does not exist and must be
designed as its own piece of work; the wrapper is time-limited to 1200 s by
design. Nothing here changes the USB baseline.

#### DEPLOYED: usb16x16-aes67.service runs the accepted point; four of seven acceptance items pass, cold boot passes with a caveat

2026-09-02. `work/aes67-bridge/` holds the supervisor, unit, profile
configuration, installer and README; `DEPLOYMENT_PLAN.md` there is the
design and records the seven decisions. Installed on the Pi as of
2026-09-02 23:00 local: supervisor `e300cc33`, unit `77837e60`,
`aes67.conf` `f2e1531f` (host retry 60 s), bridge `0254348c` unchanged.
The service is enabled and running profile `safe`. All seven acceptance
items have run; the table below and the sections after it carry the
results and the two supervisor revisions they forced.

| item | result |
|---|---|
| 2. stop/start x5 | 47-48 s to `running`, 4-6 s to stop, UDC `configured` and `usb-16x16.service` active throughout, module and processes gone after each stop |
| 3. `kill -9` daemon | failure logged, cleanup, restart, `running` 61 s after the kill, one restart counted |
| 3. `kill -9` bridge | same shape, 62 s; one RECOVER 7.4 s into the restarted bridge (below) |
| 7. coexistence measurement | stop, `20260902T114609Z`: 800 impulses, **27.646 ms** (1327), score 0.966, spread 10, `tx_qfloor` 172, 4 skips, zero restarts, gaps 2.0/2.1 ms; start again 47 s |
| 1. cold boot x3 | 61 s from kernel boot to `running` in all three, no wait stage, enabled unit, no intervention; **not clean at the bridge**, below |
| 6. soak | called a pass at 2 h 25 min by the user: 418 M frames, zero restarts, 3 RECOVERs (the startup pair plus one 4.8 ms stall), 88 skips survived, zero drops, `tx_qfloor` 189 before the stall and 122 after, `rx_qfloor` 13, ppm -16.3 |
| 4. USB unplug/replug | pass; revised supervisor: host absent 3 s after the storm, bridge alone waits, audio 8.6 s after re-enumeration, no module churn (below). First revision: 33 RECOVERs in 0.85 s at unplug, rule tripped 1.6 s later, stack restarted, audio back 35 s after replug, no intervention; the UDC state never left `configured/high-speed`, so the host-presence gate cannot see an unplug (below) |
| 5. Mac asleep | pass, five-minute form: host absent 3 s after suspend, quiet wait, no restart, audio back at the first retry after wake (below); the hour is the same path repeated |

**Two service defects found and fixed during acceptance.** The first start
failed its 4 s NEGOTIATED check because mawk buffers stdin reads on a pipe;
`-W interactive` fixed it (plain mawk had written nothing after 1 s,
interactive had the line). The sudoers entry for the bridge kill test used
`pkill -x`, which cannot match a process name longer than 15 characters;
it now matches the command line. Both needed a reinstall.

**Item 7's latency is off the grid.** 1327 samples is 72 under the 1399
mode and 24 under the 1351 run, with identical primes (61/13) and the
skip covered (`tx_qfloor` 172). It meets every acceptance criterion and
it is the lowest figure this configuration has produced. Recorded, not
explained; the quoted range for the point is now 27.6-29.1 ms.

**MEASURED: cold boot starts the bridge with a capture XRUN on both
directions.** In all three boots the bridge's first `avail` on each capture
PCM returned EPIPE, 67-158 us after start, before either direction primed:

```
RECOVER direction=usb-to-ravenna stage=capture-avail code=-32 error=Broken pipe capture_state=XRUN playback_state=PREPARED ring=0 last_queue=0 last_gap_us=0 t_us=67
RECOVER direction=ravenna-to-usb stage=capture-avail code=-32 error=Broken pipe capture_state=XRUN playback_state=PREPARED ring=0 last_queue=0 last_gap_us=0 t_us=158
```

No warm start (`systemctl start` after a stop, or a restart after a kill)
has shown this: every warm SUMMARY carries zero restarts at that point.
No surviving candidate log has a RECOVER line at all. The bridge re-primes
and boot 3 then ran clean (`tx_qfloor` 189, `rx_qfloor` 13, two RECOVERs
total at 310 s). Boots 1 and 2 did not: boot 2 stepped TX's depth floor
down 48 frames every 0.6 s from the re-prime (`pull=48`, gaps under 50 us,
so RAVENNA playback consuming normally and USB capture delivering about
1700 ppm short), took playback XRUNs at 3.5 s and 10 s, an RX
`capture-ring-full` at 18 s, and the six-in-60-s rule restarted the stack
at 74 s after boot. Boot 1 logged six RECOVERs and nothing more survives
of it. So cold boot to *stable* audio was about 61 s once and roughly two
minutes twice, with a stack restart in between. Where this lives is not
known: the service, the first open of the gadget PCM after boot, the
first load of the RAVENNA module, or the Mac re-enumerating the gadget.
Instrument before proposing.

**RECOVER after the bridge-kill restart.** 7.4 s into the restarted
bridge, RX capture XRUN with both PCMs in XRUN, while TX's DEPTHSTEP in
the same microsecond shows `gap_us=6526`, a 6.5 ms wakeup gap against a
2.1 ms maximum in every loaded run. One occurrence; the soak decides
whether it belongs to restarts after a kill.

**MEASURED: a second stall under the service, 4.8 ms, with nothing beside
it.** Soak, boot 3, monotonic 2700.27 s (about 44 min into the run, 32 s
after the journald restart that made the journal persistent): RX
`playback-avail` XRUN with `last_queue=192`, and TX's BRIDGE line for the
same second reads `tx_pullmax=192 tx_gapmax_us=4820`. RX's queue holds
about 4 ms, so any bridge wakeup gap past that empties USB playback; TX
held 314 and survived with its floor at 122. The journal shows nothing
else on the Pi in the ten seconds before it: the last ssh session had
closed at 2686.5, the daemon's 30 s SAP announcement was at 2697.3 as in
every run, no journald sync, `get_throttled` 0x0 at 47.7 C. The kernel's
RAVENNA trigger and prepare lines at 2700.269 are the recovery itself.
Bridge threads are SCHED_FIFO 90 on CPUs 2 and 3 with memory locked,
`CONFIG_PREEMPT=y`, HZ 250, IRQs unpinned, governor `ondemand`: the same
binary and kernel as every candidate run, where the largest gap in seven
600 s runs was 2.1 ms. What the service adds is stdout through a pipe to
mawk on CPU 1 and the unit's cgroup. Two stalls above 4.5 ms in about
90 minutes of service time (this one and the 6.5 ms one after the bridge
kill) against none in the candidate is not yet a rate. The soak's
RECOVER count is the stall counter and each one now carries a monotonic
time in the persistent journal.

**The 32-frame CoreAudio measurement did not produce a number: two
attempts, two different failures, neither attributable to 32 frames.**
Same frozen point, `measure-phase4-roundtrip.sh 600 32 800 200`, service
stopped under the coexistence rule each time.

- **Attempt 1, `142917Z`.** Bridge started 10:30:00.12 local, and at
  t = 5.007 s three of the four PCMs were in XRUN within 100 us with the
  bridge's own wakeup gaps at 33 and 63 us: RAVENNA capture, RAVENNA
  playback and USB playback; USB capture running. Floors before recovery
  253 / 61, queues 349 / 157. The harness's first 32-frame probe had just
  run (score 0.35, no median), every later probe found no signal, wrapper
  exit 33. The Pi's kernel log at that second holds only the recovery
  itself. 270 ms earlier an ssh session from the Mac closed
  (`session-47.scope` deactivated). The RAVENNA driver's PTP lock had
  dropped and re-locked at 10:29:28, 37 s earlier, which is its routine
  re-lock (below), not this.
- **Attempt 2, `143219Z`.** The wrapper started under sudo at
  10:32:19.985 and the Pi hard-reset within about 30 s: the persistent
  journal's last line is that sudo entry, no kernel message, no panic
  trace, `get_throttled` 0x0 after the reboot. The sequence before it,
  inside one boot: service insmod at boot, stop (rmmod), wrapper insmod
  for attempt 1, cleanup rmmod, service insmod, stop (rmmod), wrapper
  insmod, reset. Earlier boots survived more insmod/rmmod cycles than
  that. The Pi rebooted on its own, the enabled service came up in 61 s
  as designed, and wlan0 failed to associate for about 25 min
  (`CTRL-EVENT-ASSOC-REJECT`, `no-secrets`) before NetworkManager brought
  it back by itself; eth0 and mDNS were fine throughout. A 32-frame
  measurement needs a reason before a third attempt.

**MEASURED: the RAVENNA driver drops and re-acquires its PTP lock about
8 s after every module load.** Kernel `PTP lock [0] status changed`
sequence 0 -> 1 -> 2, then 2 -> 0 -> 1 -> 2 eight to nine seconds later,
in every boot and every stop/start today (08:02:52/08:03:01,
10:29:19/10:29:28, 10:30:58/10:31:07, boot 4 at 71.7/80.1 s and
1627.8/1636.3 s). The daemon reports `locked` before the re-lock and the
PUT of sink 0 then takes 32 s, so the bridge always starts about 30 s
after it; harmless as sequenced, but it is a second unlock that nothing
waits for, and it is now a known timeline feature.

**Boot 4 (unplanned), 1609 s: eight RECOVERs in 1.1 s, the rule
restarted the stack, audio back at 1672 s.** Shape: TX (RAVENNA playback)
XRUN five times with `last_queue` 14-62 and normal 2 ms gaps, each
re-prime draining in 200 ms, and RX `capture-ring-full` twice. That is
USB input stopping and USB playback not consuming for about a second,
both directions, with the bridge running and no PTP change: a host-side
pause, the same signature as boot 2's cascade. No kernel line beside the
recoveries. It began 9 s after an ssh login from the Mac over eth0 during
the outage diagnosis, and 3 s before the harness's hung ssh was killed on
the Mac. Earlier in the same boot, at 690 s, a 4.3 ms gap took TX's
sampled floor from 179 to 95 with no RECOVER and nothing in the journal.

**Three events, all within seconds of ssh session activity from the
Mac:** the 4.8 ms stall at 2700 s (14 s after a session closed), attempt
1's triple XRUN (0.27 s after a session closed), boot 4's cascade (9 s
after a login). Not a mechanism, a pattern to test: the next instrument
is a counter, not an explanation. Candidates that need no bridge change:
`tx_pullmax` already flags a 192-frame pull; the persistent journal now
timestamps every RECOVER, DEPTHSTEP, ssh session and PTP lock line on
one monotonic clock. Correlate before proposing.

**TESTED: an ssh session is not sufficient.** A fourth event made the
pattern sharper first: boot 4 at 3675.68 s, RAVENNA capture and both
playbacks in XRUN with the bridge's gaps at 32 us and 1952 us, 0.38 s
after the service watch's own ssh session closed, with nothing logged in
the 380 ms between (logind removed the session at 3675.30; the driver's
next lines are the recovery). Then two controlled tests against the
running service, 30 s apart, watch stopped: A, seven sessions running
`true`; B, six sessions each reading the unit's whole journal as the
watch does. Zero RECOVERs in either. So the two 0.3 s coincidences are
not reproduced by the session alone; whatever fires is rare (about one
per one to two hours of service time today) and the session, if it is
involved at all, is not the whole stimulus. The driver has no kernel
thread of its own in `ps -eL`, so its I/O runs from timer context, and
the bridge at SCHED_FIFO 90 sees no gap while the driver's PCMs overrun
and underrun together: whatever it is stalls the driver's timer path, not
the bridge. Left open. The journal keeps accumulating timestamps.

**CORRECTION: tests A and B were underpowered, and a third hit makes
the session close the trigger.** Series boot 5, monotonic 12934.69 s:
the same pair (RAVENNA capture XRUN and both playbacks XRUN, bridge gaps
27 and 1982 us), 0.17 s after the service watch's session closed at
12934.53, nothing else in the kernel log, six previous watch sessions
that hour clean. Three tight-coupled events now, at 0.17, 0.27 and
0.38 s after an sshd session close, out of roughly 150 sessions today:
a per-session rate near 2%, against which thirteen clean sessions prove
nothing (about three chances in four of seeing none). The chance that
three events land inside 0.4 s of a close by accident is negligible. So
the session close is involved and it fires about one time in fifty;
what makes those fifty different is the open question. Test C, sixty
sessions running the watch's exact command at 15 s spacing, watch
stopped, is the next measurement.

**Test C: zero in about 120 closes.** Sixty iterations at 15 s, each
running the watch's exact command and a second short readout session,
service watch stopped, 20:44-21:01 UTC: no RECOVER, no restart. With A
and B that is about 133 controlled closes without a hit against three
hits in about 150 natural ones. If the close triggers at all it does so
at under about 2% and something else gates it; the controlled sessions
differ from the natural ones only in spacing (15 s against 600 s) and in
what else the Pi was doing. Not resolved. The service watch's sessions
continue as the natural experiment, and every hit lands in the journal
with its offset from the nearest close.

**MEASURED: four runs against the running service, 64 and 32 frames, all
on one sample.** `measure-under-service.sh` runs the Mac harness alone
against the live service, no wrapper and no stack restart, so a RECOVER
is counted rather than fatal. 800 impulses each, back to back, 2026-09-02
16:20-16:36 UTC, service up since boot 4's restart:

| frames | median | samples | spread | score | ready | RECOVERs |
|---:|---:|---:|---:|---:|---:|---:|
| 64 | 29.646 ms | 1423 | 10 | 0.960 | 3 probes | 0 |
| 32 | 29.646 ms | 1423 | 10 | 0.954 | 3 probes | 0 |
| 64 | 29.646 ms | 1423 | 9 | 0.957 | 3 probes | 0 |
| 32 | 29.646 ms | 1423 | 10 | 0.954 | 3 probes | 0 |

Two things follow. First, provenance: the harness computes delay from
the IOProc's output and input `mSampleTime` on the device's own timeline
(`LiveImpulseMeasurement.swift`), so the Mac's IO buffer is outside the
measured path by construction. The "32-frame lever" was never measurable
with this harness; the host-side saving, 0.67 ms per direction at 32
against 64, is a DAW-side fact this loop cannot see. Second, the
32-frame open ran clean twice under the service, which takes most of the
weight off attempt 1's coincidence. Note also that all four service runs
read 1423 against 1399/1351/1327 under the wrapper for the same binary
and arguments; the quoted range for the point is now 27.6-29.6 ms, and
the service's four runs are the tightest set yet.

**MEASURED: the DAW-side number, RTL Utility at 64 and 32 frames.** Oblique
Audio's RTL Utility, output 1 to input 1 of the USB 16x16 through the same
Ferrofish return path, against the running service (2026-09-02 evening
local, service up since 19:04). It measures on the Mac's IOProc timeline,
which is what a DAW sees; the harness measures on the device's:

| CoreAudio buffer | RTL Utility | samples | CoreAudio reported | harness, device timeline | Mac-side cost |
|---:|---:|---:|---:|---:|---:|
| 64 | 34.896 ms | 1675 | 376 | 1423 | 252 (5.25 ms) |
| 32 | 33.562 ms | 1611 | 312 | 1423 | 188 (3.92 ms) |

Three things follow. The 32-frame lever exists and is worth exactly 64
samples, 1.33 ms, one buffer per direction: invisible to the harness by
construction, now measured. The Mac side beyond the two IO buffers is a
constant 124 samples (2.58 ms) at both settings, safety offsets plus USB
framing; the roadmap had estimated the whole Mac contribution at 3-4 ms
and it is 5.25 ms at 64 frames. CoreAudio's reported latency overstates
the measured Mac-side cost by that same 124 samples at both settings, so
the report is not the number to subtract. Return level -21.6 dB both
times. Quote the point as 29.6 ms on the device timeline and 34.9 ms (64
frames) or 33.6 ms (32 frames) at the DAW.

**MEASURED: five more cold boots, unattended.** Reboot, wait for ssh on
wlan0 or eth0, wait for `running`, observe for four minutes:

| series boot | to `running` | first 5 min | stable audio at | wlan0 at +30 s |
|---:|---:|---|---:|---|
| 1 | 61 s | startup pair, then 4 RX playback XRUNs in 4.6 s, rule tripped at 61.6 s, restart | 123 s | up |
| 2 | 61 s | startup pair only | 61 s | not yet, up by +5 min |
| 3 | 61 s | startup pair, TX playback XRUNs and RX ring-full, rule tripped at 77.5 s, restart | 139 s | not yet, up by +5 min |
| 4 | 61 s | startup pair only | 61 s | not yet, up by +5 min |
| 5 | 64 s | startup pair, then 4 RX playback XRUNs in 8 s, rule tripped at 68.7 s, restart | 130 s | not yet, up by +5 min |

Today's total: eight cold boots, the startup capture-XRUN pair in all
eight, a cascade with one stack restart in five of them, and every one
of the five recovered on its own to a clean second attempt. So cold boot
to stable audio is 61 s or about 125-140 s, with no intervention either
way. Two cascade shapes: boots 1 and 5 are RX only, USB playback running
dry every 0.6-3.5 s from a 157-frame prime with the bridge's gaps at
11-17 us, that is the RX queue draining a few hundred frames per second
faster than RAVENNA capture fills it; boot 3 and the morning's boot 2 are
TX playback XRUNs with RX `capture-ring-full`, USB input stopped and USB
playback not consuming. Both are USB-side rate shapes in the first
minute after boot only, and neither has appeared in a second attempt or
a warm start. Wi-Fi: associated within 30 s of boot in one of five, and
within five minutes in all five; the 25-minute outage after the hard
reset was the long tail of the same thing, not a separate fault.

**MEASURED: USB unplug and replug with the service running.** Cable
out at about 15858.6 s of series boot 5 (Pi local 21:22:20), back in at
15887.5 s, 29 s later.

- At unplug the bridge logged one TX `playback-avail` XRUN (USB capture
  stopped delivering) and then 32 RX `capture-ring-full` recoveries in
  0.85 s (RAVENNA capture arriving, USB playback not consuming, the ring
  refilling every 26 ms). The five-per-minute rule tripped at 15860.2,
  1.6 s after the unplug, the stack stopped cleanly and systemd restarted
  it at 15876.1. So "host gone" has a signature: a ring-full storm at
  about 40 per second.
- **The kernel logged nothing at the unplug and `/sys/class/udc/*/state`
  stayed `configured` at `high-speed` throughout.** The Pi 5's dwc2
  peripheral does not report the host's departure through that file, so
  the supervisor's wait-for-host gate passed immediately and the second
  attempt started with no host on the cable. Only the replug shows in
  the kernel: `dwc2: new device is high-speed`, `new address 4` at
  15887.5, the Mac re-enumerating.
- The replug landed during the second attempt's PTP and sink stage, the
  bridge started at 15918.5, negotiated, and ran clean with no startup
  XRUN pair (a warm start), audio flowing 35 s after the replug. Had the
  host stayed away, the bridge would have started anyway and the storm
  would have tripped the rule again: an absent host is a restart loop
  with a module load and unload per cycle, about every 75 s, slowing to
  about 135 s once the backoff engages. That is the shape to expect from
  the asleep-Mac test unless host suspend, unlike unplug, does change the
  UDC state; nothing measured yet says which. Given the hard reset earlier
  today sat next to module churn, a short sleep of a few minutes before
  the hour is the cheaper first measurement.
- `usb-16x16.service` stayed active and the gadget re-enumerated on its
  own. Nothing touched the USB baseline.

**MEASURED: the absent-host loop, live, and two more service defects.**
The cable was moved to a second Mac for the sleep test (2026-09-02
21:36 local). That Mac never enumerated the gadget: no `dwc2` line at
all on the Pi, not even a bus reset, through two ports and a reseat,
while moving the cable back to the first Mac produced `new device is
high-speed` within a second. Fault at the second Mac's port or cable
end; the sleep test is deferred. Meanwhile the Pi showed what an absent
host does to the service: each attempt reaches the bridge, takes a ring-
full storm (185 RX `capture-ring-full` recoveries in the first second),
trips the rule and restarts, one module load and unload per cycle at
about 65 s, with the UDC state file still reading `configured/high-speed`
from the previous host throughout. Stopped by hand after two cycles to
spare the module. Two defects for the next supervisor revision:

- **A stop during the sink PUT is killed by systemd.** `systemctl stop`
  arrived while the supervisor was inside the daemon's 32 s sink 0 PUT;
  bash defers the TERM trap until the foreground curl returns, the 25 s
  `TimeoutStopSec` expired, systemd sent SIGKILL and the unit went to
  `failed`. `ExecStopPost` still cleaned up and unloaded the module. Fix:
  run the long curls in the background and `wait`, as `pause` already
  does, and raise `TimeoutStopSec` to cover the PUT.
- **The host-presence gate is blind**, as the unplug test showed, so the
  supervisor needs the storm signature instead: a `capture-ring-full`
  rate of tens per second with USB input frozen means no host, and the
  right response is to stop the bridge and wait for a `dwc2` enumeration
  line or for USB input to move, not to churn the module every minute.
  Design to decide with the sleep result in hand.

**DEPLOYED: supervisor revision, host absence handled without module
churn.** Installed 2026-09-02 22:06 local: supervisor `cc5423e6`, unit
`77837e60`, `aes67.conf` `a039a3cc`. Changes: the sink PUT and readback
run under `wait` so a stop is honoured at once (`TimeoutStopSec` 40);
a RECOVER storm (ten or more in one second) with USB input frozen, or
sustained for three seconds, is the host gone: the bridge alone stops,
the daemon and module stay, and the supervisor waits for a `dwc2`
enumeration line in the kernel log or five minutes, then starts the
bridge again. A storm with input moving keeps the stack-restart path.

The first revision had a defect the test found at once: it required the
BRIDGE line to advance to confirm frozen input, and **during a ring-full
storm the bridge stops writing its 1 Hz BRIDGE line** (measured: the
line stayed at the same `tx_qn` for 30 s while 2900 recoveries logged),
so the branch never fired and the storm hold suppressed the old rule:
an unbounded storm at 38 recoveries a second. The sustained-storm rule
fixed it; with a host present the largest burst on record is 8 in 1.1 s.

**MEASURED: the revised path, twice, both directions.** Service started
with the cable on the non-enumerating second Mac: bridge `running` at
18355.98 s, storm, `host absent` at 18359.02 (3.0 s later), bridge
stopped, module and daemon kept, one wait line at 60 s. Cable moved back
to the first Mac: `dwc2 new device` at 18426.08, `host enumerated after
70s` at 18430.64, bridge `running` at 18434.66, USB input flowing, zero
RECOVERs on the new bridge, zero service restarts, module never
unloaded. Audio 8.6 s after the enumeration, against 35 s and a full
stack restart before. Item 4's contract is therefore met with a better
shape, and the asleep-Mac test can run without churn whatever suspend
does to the UDC state.

**MEASURED: Mac asleep five minutes (item 5, short form).** Baseline
22:10:19 local, uptime 18739. Twelve seconds later the storm and `host
absent` (episode 2, 38 recoveries in one second, storm 3 s); bridge
stopped, daemon and module kept, four quiet wait lines, UDC state
`configured/high-speed` throughout. **Suspend looks exactly like an
unplug to the Pi, and wake produces no enumeration line**: macOS resumes
the device without a bus reset, so the `dwc2` signal cannot see a wake.
The 300 s retry at 19056 fired before the Mac was awake and went back to
waiting (episode 3); the next retry at 19366 found the awake Mac
streaming again with no re-enumeration: `running` at 19369, USB input
flowing, zero RECOVERs, zero service restarts, module never unloaded.
So a sleeping host costs nothing but one bridge start and a 3 s storm
per retry, and audio after wake returns within the retry interval plus
about 8 s. Staged revision: retry 60 s, and the sampler forwards only
the first 20 RECOVER lines of a storm to the journal.

**MEASURED: the 60 s retry and the journal suppression, installed
(supervisor `e300cc33`).** Unplug at about 22673 s of series boot 5:
`host absent` at 22676.5 (episode 1, 38 in one second, storm 3 s),
journal carried 20 RECOVER lines then `RECOVER storm: further ... tmpfs
log only`, then `storm ended after 95 recoveries`. Retry at 22738.1
(61.6 s later), `running` at 22742.1, storm, `host absent` at 22745.2
(episode 2, `storm ended after 259`). Replug: `dwc2 new device` at
22775.46, `host enumerated after 30s` at 22776.73 (1.3 s later), bridge
`running` at 22780.75, USB input flowing. Zero service restarts, module
never unloaded, zero RECOVER lines in the journal after the storm
marker. Audio 5.3 s after the enumeration. The host-absence path is
now measured end to end four times today: two unplugs, one suspend, one
non-enumerating host, with both return signals (enumeration and retry).

**The sink 0 PUT takes 32 s in every start.** `session_manager:: media 0
playout delay 576` at +0 and `driver_manager:: add RTP stream success` at
+32 s, in every warm and cold start; sink 1 then takes 10 ms. That is
half the time to audio and it lives in the daemon or the driver, not the
service. Untouched.

**The Pi's journal is volatile** (`/usr/lib/systemd/journald.conf.d/40-rpi-volatile-storage.conf`,
`Storage=volatile`; `/var/log/journal` exists but is unused). Every reboot
discards the previous boot's timeline, which is why boots 1 and 2 are gone.
A persistent journal is a root change and a decision for the user; without
it, cold-boot post-mortems must be read before the next reboot.

#### ACCEPTED: period 48 (tier one, lever 1): four loaded runs, 25.6-27.3 ms, TX floor 164-193, no pull above 48

`--period 48` through the candidate wrapper (`USB16X16_PHASE4_PERIOD_FRAMES=48`),
everything else the accepted point: target 128, buffer 192, RAVENNA playback
384, TX prime 288, RX prime 144, sink delay 576, binary `0254348c`, 600 s,
800 impulses at 64 CoreAudio frames, the service stopped for the run
(2026-09-03 00:35 UTC, 2026-09-02 20:35 local).

**NEGOTIATED came back 48 on every PCM**: `usb_capture=48/192
usb_playback=48/192 ravenna_capture=48/192 ravenna_playback=48/384`. The
roadmap's premise that USB ignores period requests was wrong: the gadget
granted 48 too. So the one flag moves the period, and with it `avail_min`
(the bridge sets `min(negotiated, requested)`), on both sides at once.
Lever 2 as written, RAVENNA capture `avail_min` 48 behind its own flag, has
nothing left to test: 48 is already what period 48 gives it. What this run
does not separate is USB period 48 from RAVENNA period 48; a one-side
variant needs a per-device period option in the bridge, not built.

| run | median | samples | score | spread | TX / RX overshoot | `tx_qfloor` | `rx_qfloor` | TX under a period | `tx_pullmax` | RECOVERs | restarts |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `003546Z` | 25.563 ms | 1227 | 0.946 | 10 | 13 / 13 | **164** | 109 | 0 | **48** | 0 | 0 |
| `004724Z` | 25.563 ms | 1227 | 0.930 | 10 | 13 / 13 | **177** | 100 | 0 | **48** | 0 | 0 |
| `005836Z` | 27.313 ms | 1311 | 0.988 | **0** | 13 / 13 | **193** | 109 | 0 | **48** | 0 | 0 |
| `011007Z` | 25.813 ms | 1239 | 0.934 | 10 | 13 / 13 | **178** | 109 | 0 | **48** | 0 | 0 |

Against the accepted point (wrapper mode 1399, 29.146 ms): 172 samples,
3.6 ms faster, cover kept at 164 over the 144 bar. Per impulse: 1227 in
734 of 800, 1219 in 38, the rest within two samples. Capture means 11.5
frames both directions against 37-42 at period 96; the capture histograms
hold bins 0 and 1 only, the pointer advancing per 48-frame packet. TX's
prime overshoot fell from 61 to 13. RX's floor rose from 61 to 109 with
the same 144 prime, as the roadmap predicted for 48-frame pushes. TX's
floor settled by DEPTHSTEP from 432 at prime to 384 (7 ms), 336 (14 s) and
295 (73 s), each step with `pull=48`, then held for the remaining 527 s:
the same resting-level settle as before, now in 48-frame steps.

**Run 3 landed 84 samples higher, on one sample.** `005836Z`: every one of
the 800 impulses read 1311, the first zero-spread 800-impulse run in the
project; runs 1 and 2 carried the familiar 8-sample bimodality (1219 under
1227, 38 and 55 times). The bridge was as clean as the other two: floors
193/109, no restart, no recovery, `tx_pullmax` 48. What differs is where
TX settled: its depth floor stepped from 432 to 384 at 7 ms and to 336 at
58 s, then held, where runs 1 and 2 took a third step to 295 and 311; its
depth mean read 404 against 371 and 389. RX took its own step, 288 to 264
at 251 s, the only RX DEPTHSTEP after prime in the three runs. Bridge depth
alone does not add to 84 (TX plus RX depth means: 690, 694, 711), so part
of the shift is outside the bridge's counters. Same resting-level scatter
as the accepted point (29.1 x3, 28.1 x1), now 25.6 x2, 27.3 x1; quote the
range until run 4 says which is the mode.

**Run 4 and the verdict.** `011007Z`: 1239 (25.813 ms), 12 samples above
runs 1 and 2, the familiar bimodality (1231 under 1239, 49 times), floors
178/109, clean. **Acceptance as defined for the accepted point: four
800-impulse runs, zero failures, `tx_qfloor` above 144 in every one.
Passed**, with floors 164, 177, 193, 178 (worst margin 20 frames over
the bar, against 14 at period 96) and `tx_pullmax` 48 in all four. Latency
1227 x2, 1239, 1311: **quote 25.6-27.3 ms, mode 25.6**, against 27.6-29.6
at period 96. The level of each run is set at start: all three readiness
probes read the run's own median every time (1227, 1227, 1311, 1239), and
nothing drifted within a run. Sinks read 576/576, PTP locked on the same
grandmaster, and the daemon logs are the same shape in all four; the
scatter is the bridge's resting level and something outside its counters,
as before. Not measured here: a USB-only or RAVENNA-only period 48 (needs
a per-device period option), the service's own number at this point (the
service runs the profile, `measure-under-service.sh` reads it), and 32
CoreAudio frames, which the harness cannot see and RTL Utility can.

**DEPLOYED: period 48 as profile `safe`, 2026-09-02 21:25 local.** The
user ran the staged installer: `/etc/usb16x16/aes67.conf` `4bd2f070`
(profiles `safe` at period 48, `safe-96` the former point, `fast`),
supervisor `e300cc33`, unit `77837e60`, bridge `0254348c`, wrapper
`1baa88a9` all unchanged. The service came back in 46 s (a warm start:
insmod, daemon API 2 s, PTP locked 10 s, sinks applied at 42 s, bridge
negotiated 48/192 on every PCM, `running` at 21:25:53), no startup XRUN
pair, zero recoveries, floors 205/133 at 30 s. **RTL Utility against the
new service at 32 CoreAudio frames: 1427 samples, 29.729 ms**, reported
312, return level -21.6 dB, against 1611 at the period-96 point: 184
samples, 3.83 ms, saved at the DAW. Less the 188-sample Mac-side cost
measured at 32 frames, the device-timeline level is 1239, run 4's level.
64-frame RTL Utility and `measure-under-service.sh` at this point follow.

**MEASURED: the running service at period 48, 64 frames, 800 impulses.**
`service-roundtrip-64f-20260903T012648Z`, 90 s after the service's
two-minute stability mark: median 1239, **25.813 ms**, spread 10 (1231 to
1241), score 0.935, 1239 in 716 of 800 and 1231 in 50, zero RECOVERs,
zero restarts, `tx_qfloor` 174, `rx_qfloor` 119, `tx_pullmax` 48. The same
level as wrapper run 4 and as RTL Utility's 1427 at 32 frames less the
188-sample Mac-side cost. At period 96 the service read 1423 in all four
of its runs, so the service is 184 samples, 3.83 ms, faster at 64 frames
too: **quote the deployed point as 25.8 ms on the device timeline**,
range 25.6-27.3 from the wrapper series, and 29.7 ms at the DAW at 32
frames. **RTL Utility at 64 frames against this service: 1491 samples, 31.062 ms**,
reported 376, the predicted 1239 + 252 exactly: the Mac-side cost (two
IO buffers plus 124) did not move with the period. So the deployed point
at the DAW is 31.1 ms at 64 frames and 29.7 ms at 32, against 34.9 and
33.6 at period 96.

**MEASURED: cold boot at period 48, watched over one ssh session, and
what the self-healed boot costs.** Reboot issued 2026-09-03 01:33:39 UTC
(boot `bd91bb5e`); the new boot answered on wlan0 31 s later and the
session attached at 14 s of uptime. Timeline (seconds of uptime):
profile line 13.9, insmod 14.5, daemon API 15.6, PTP locked 24.7, sinks
applied 56.7, bridge starting 56.8, the startup capture-XRUN pair on both
directions at 56.79 (as on every cold boot), `running` 60.8, then RX
playback XRUNs at 58.7, 61.3 and 65.3 (queue 13 and 48 at the XRUN, the
boot-1/boot-5 shape: USB playback running dry from the 144 prime, RX's
depth floor stepping 288 to 144 in 24-frame pulls over the first 1.6 s
of bridge time, three re-primes to 144). Five RECOVERs in all, the rule
did not trip, no stack restart, `stable for 120s` at 180.4, no further
recovery through 374 s. So this boot took the shorter path: audio at
61 s, no second attempt.

**But TX kept the depth it gained during RX's recoveries.** At the first
BRIDGE line (57.8 s) TX read ring 131, queue 349, depth mean 450; by
67.8 s, after the three RX re-primes, ring 480 and queue 384, and it
stayed there: ring 394-468, queue pinned at 384 (full), depth mean 798
at 368 s, against 371-404 in the four wrapper runs. RX itself settled at
queue 145-183, floor 13. The bridge conserves depth after priming and the
estimator matches rate, not level, so nothing drains it. **The service
measured against this boot: `service-roundtrip-64f-20260903T014029Z`,
median 1719, 35.813 ms, all 800 impulses on one sample, zero RECOVERs
during the run**: 480 samples, ten periods, 10.0 ms above the 1239 of the
warm start measured an hour earlier, and 3.6 ms above the period-96
warm number. A cold boot that heals without a stack restart is therefore
slower than one that restarts; the period-96 service runs were all taken
after boot 4's restart, so this was never measured before.

**Warm restart, same boot: back to 1227.** `systemctl restart` at 640 s
of uptime, `running` at 693 s (53 s, no startup XRUN pair, no RECOVER),
TX ring 131, queue 251, depth mean 359 after a two-minute settle;
`service-roundtrip-64f-20260903T014732Z`: median 1227, 25.563 ms, spread 10, score 0.911, zero RECOVERs,
floors 166/109, `tx_pullmax` 48. So the deployed point's 25.6-25.8 ms
holds for any start that primes cleanly, and **a cold boot that heals
in place costs 10 ms until the next restart.** Two ways to close it,
neither built: the supervisor restarts the bridge once after the
first-minute cascade (service-side, deploy-safe, about a minute of extra
outage on the boots that need it, which is what the rule-tripped boots
already pay), or the bridge re-primes both directions when either
recovers, since the depth is gained by TX while RX re-primes. Instrument
first: two more watched cold boots with a service measurement each, to
see whether the excess is always 480 and whether a rule-tripped boot
comes back at 1227-1239. One boot so far.

**`tx_pullmax` 48, and no pull above 48 in the run.** Pull histogram
`1908067/599987/0/0/0/0` (48-frame bins: zero, 1-48, 49-96, ...): 600k
pulls of one packet at 1 kHz and nothing larger. Every period-96 run
carried the 144-frame three-packet pull (bin 3, four of them in 600 s in
`114608Z`). Either the skip does not occur at period 48, or it takes a
shape this counter does not tell from a one-packet pull. Observation, not
explanation. The 144-frame cover bar stays until the acceptance runs say
whether it recurs.

#### Phase 4 latency is not yet competitive

| Operating point | run | median | score | spread |
|---|---|---:|---:|---:|
| `48/192/768/128` **period 48**, RAVENNA playback 384, TX 288 / RX 144 | **ACCEPTED and DEPLOYED as `safe`: 003546Z, 004724Z, 005836Z, 011007Z, 800 impulses each, 0 failures, `tx_qfloor` 164-193, `tx_pullmax` 48; service 012648Z 25.813 ms** | **25.563 ms (x2), 25.813 ms, 27.313 ms** | 0.930-0.988 | 0-10 samples |
| `96/192/768/192` TX 192 / RX 96 | **012708Z, 800 impulses, pull-burst binary, clean, `tx_qfloor` 130** | **28.479 ms** | 0.924 | 10 samples |
| `96/192/768/192` TX 192 / RX 96, RAVENNA playback 384 | 015059Z, 800 impulses, clean, `tx_qfloor` 122 | 30.146 ms | 0.944 | 10 samples |
| `96/192/768/128` TX 192 / RX 96, **target 128** | **025906Z, 800 impulses, clean, `tx_qfloor` 97, `rx_qfloor` 61** | **24.479 ms** | 0.932 | 10 samples |
| `96/192/768/128` target 128, RAVENNA playback 384, TX 288 / RX 144 | **ACCEPTED: 031504Z, 034616Z, 035724Z, 040831Z, 800 impulses each, 0 failures, `tx_qfloor` 158-197** | **29.146 ms (x3), 28.146 ms (x1)** | 0.945-0.967 | 9-10 samples |
| `96/192/768/192` prime 96 | **211118Z, 600 s soak PASSED, ACCEPTED** | **26.979 ms** | **0.988** | **0 samples** |
| `96/288/768/192` TX 288 / RX 96 | **4 runs, 800 impulses, 0 failures, tx_qfloor 144 invariant** | **29.979-30.979 ms** | ~0.92 | 8-10 samples |
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

**Updated 2026-09-02:** the GS305EP is in `802.1p/DSCP` QoS mode, so the
switch honours the DSCP marks AES67 already sets (media 34, PTP 46) and
prioritises the clock above audio. This is the fix the paragraphs below
recommend; they describe the earlier `Port-based` state and are kept for
the reasoning. The change was made before the recent Phase 4 runs: the
accepted combined point and all 2026-09-02 measurements were taken in
`802.1p/DSCP` mode, so no re-baseline is needed for them. The exact
changeover time is not recorded, so treat figures from 2026-08-31 as
possibly predating it; none of them is a current comparison point anyway.

The NETGEAR GS305EP was in `Port-based` QoS mode with port 1, which carries the
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

## 2026-09-02 evening: crackle root cause, full-scale wrap fix, pitch servo staged

**Symptom reported by the user:** crackle on playback when sending music
from the Mac to the interface, clean when the Apple Music level is lowered,
plus one dropout. The user's priority for this work is stability and
accuracy first, with latency as low as that allows, and clean audio from a
0 dBFS source without lowering the level.

**ROOT CAUSE of the crackle, confirmed by test: the S32 converter wrapped
at positive full scale.** `float_to_s32` clamped the float to
`nextafter(1.0, 0)` and then rounded: `0.9999999999999999 * 2^31` rounds
to `2147483648`, which the `int32_t` cast turns into `-2147483648`.
`float_to_s24` had the same rounding (`8388607.5 -> 8388608`) but
`pack_s24le` clamps its integer, so the USB side was safe. The RAVENNA
playback side, the direction the user was listening to, was not: every
positive intersample overshoot the Catmull-Rom interpolator produced on
0 dBFS material left the bridge as a negative full-scale sample on the
AES67 wire. That is a click on every clipped peak, gone at -3 dB. Verified
with a standalone reproduction of the two conversion paths before any
edit. Fix in `bridge_core.cpp`: both converters now round first and clamp
in the integer domain; `exceeds_full_scale()` reports what would clamp,
and the bridge counts it per direction (`tx_clip`/`rx_clip` on the BRIDGE
line, `tx_clipped_samples`/`rx_clipped_samples` in SUMMARY). Regression
test `test_full_scale_conversion_does_not_wrap` covers +1.0, +1.02, +1.5,
the largest float below 1.0 (exact in S32 at 2147483520, clamped in S24),
and the negative rail. Core tests pass on the Mac and the Pi.

After the fix, a 0 dBFS source through the *resampler* path still has its
intersample overs shaved (a soft clamp, not a wrap). That residual cannot
be carried on a 24-bit wire at all; the only way to pass 0 dBFS material
untouched is to not resample it, which is what the pitch servo below does.

**The dropout: a 5.9 ms stall, in the journal.** Boot of 21:34 local, at
2116 s of uptime (about 22:09): TX `playback-avail` XRUN with
`last_queue=16 last_gap_us=5876`, RX capture and playback in XRUN at the
same instant. Same family as the 4.8 ms and 6.5 ms service stalls already
recorded; the estimator sat at -14 to -17 ppm with zero phase error and
both floors (166/109) held from the 21:45 warm restart until that moment.
Period 48 holds about 3.5 ms of TX queue, so a 6 ms stall is an XRUN by
arithmetic. The stall is not a clock problem. Observed on the Pi at the
time: governor `ondemand` at 1.7 GHz, USB gadget IRQ 34 and eth0 IRQ 108
both at affinity 0-3 and counted entirely on CPU 0, wlan0 up. The
5-minute cyclictest that deprioritised Phase 6 could not have seen a
once-per-hour stall.

**Phase 6 levers, staged as `work/pi-tuning/stall-tuning.sh`.** Runtime
only, reversible, nothing under /etc, nothing touching the USB baseline:
`governor performance|ondemand` and `irqs pin|unpin` (gadget + eth0 to
CPU 1, away from the bridge's CPUs 2-3). One lever at a time, judged by
the RECOVER count over hours (`status` prints it). Needs root; not yet
run.

**Phase 5 step 1, implemented: `--usb-pitch-servo 1`.** The 6.18 gadget
exposes `Capture Pitch 1000000` (scales the feedback frequency the Mac's
output follows) and `Playback Pitch 1000000` (scales the IN packet sizes
through a residue accumulator), both 750000..1005000 in 1 ppm steps,
confirmed in the Pi's own `u_audio.c`. With the servo on, both converters
run at exactly 1.0 (the Farrow kernel at integer phase reproduces `y1`, so
the path is bit transparent) and the shared estimator's ppm goes to the
pitch controls instead: `pitch = 1000000 - (ppm + bias)`. Sign and gain
check: a pitch offset of +pi ppm raises the differential depth at
`2 * 48000e-6` frames/s, the same magnitude as the resampler ratio with
the opposite sign, so the regression's applied-ratio correction integrates
`1000000 - applied_pitch` and the estimator logic is otherwise untouched.
`bias` is a slow level term, 0.05 ppm per frame of differential away from
the setpoint captured when the rate estimate first engaged, clamped to
+-3 ppm, which holds the 1 ppm quantisation residual to about +-10 frames
of wander (time constant about 210 s). Control writes happen on the
telemetry thread, at most once per second; the audio thread only publishes
the wanted value. Pitch is reset to nominal at start and on exit. New
telemetry: `pitch=`, `bias_ppm=`, `pitch_errors=`; new lines `PITCHSERVO
enabled` and `PITCHSERVO engaged setpoint_frames=`. Not yet run against
hardware: the service holds the PCMs and the wrapper pins the binary hash,
so the first run waits on the install below.

**Staged, not installed.** Bridge `f7226238` (was `0254348c`), built on
the Pi from `~/usb-16x16-work/phase4-servo-src`, ctest clean, copied to
`work/phase4-bridge/artifacts/pi-aarch64/`. Wrapper `3a500d92` (twelfth
positional `usb_pitch_servo`, default 0; `USB16X16_PHASE4_USB_PITCH_SERVO`
on the Mac side). Supervisor `95e5ba2f` (optional profile key
`USB_PITCH_SERVO`, absent means 0, `--usb-pitch-servo` in the argument
list, shown by `profiles`). `aes67.conf` `46995a45` adds profile `servo`
(experimental: the `safe` point with the servo on); `safe`, `safe-96` and
`fast` are unchanged and `PROFILE=safe` still. Unit `77837e60` unchanged.
Both installers carry the new hashes and `4bd2f070` joins the list of
unedited shipped configs. Everything is in
`~/usb-16x16-work/phase4-servo-install/` on the Pi. Install order, with
the service stopped: `install-candidate.sh` (bridge + wrapper), then
`install-aes67-service.sh` (supervisor + conf), then start.

**INSTALLED 2026-09-02 22:38 local by the user**, both installers, service
back on `safe`. First listening test: 0 dBFS music from Apple Music, clean,
no clicks. The live BRIDGE line four minutes in read `tx_clip=3037
rx_clip=9889`: the resampler path was clamping thousands of intersample
overs on that material, every one of which the old binary would have sent
as a negative full-scale click. A second stall of the driver-timer shape
(all four PCMs in XRUN, bridge gaps 3-26 us, at 3116 s of uptime, 22:25
local, 1000 s after the 5.9 ms one) landed before the reinstall.

**MEASURED: run 1, profile `safe` on bridge `f7226238`, servo off.**
`phase4-candidate-20260903T023841Z`, 600 s, 800 impulses at 64 frames,
load 0.05: median **1251 samples, 26.063 ms**, spread 10 (1243-1253),
score 0.934, `tx_qfloor` 191, `rx_qfloor` 109, `tx_pullmax` 48, gaps
1.0/1.3 ms, zero restarts, zero drops, `tx_clip`/`rx_clip` 0 (the harness
signal is not hot). Same level and shape as the four acceptance runs: the
wrap fix and the per-sample clip check cost nothing on the real-time path.

**MEASURED: run 2, the same point with `--usb-pitch-servo 1`.**
`phase4-candidate-20260903T024954Z`, same arguments plus the servo:
median **1239 samples, 25.813 ms, all 800 impulses on one sample, score
1.000**, the first zero-spread 800-impulse run at the period-48 point and
the cleanest run in the project. The 8-sample bimodality every resampler
run carried is gone, which reads as the fractional phase of the converter:
at ratio 1.0 the delay through the bridge is an integer and constant.
Bridge: `PITCHSERVO enabled`, `PITCHSERVO engaged setpoint_frames=72` at
60.0 s, pitch settled at 1000015 (mode; dithering 1000012-1000020 as the
level term rides the device's 48-frame skips, bias touching the -3 ppm
clamp once), `tx_consumed - tx_input` a constant 131 frames for the whole
run (the converter at exactly 1.0), `tx_qfloor` 164, `rx_qfloor` 96,
`tx_pullmax` 48, gaps 1.7/1.7 ms, zero restarts, zero drops, zero clips,
zero pitch write errors, SUMMARY ppm -15.9. Both gadget pitch controls
read 1000000 after exit. Service restarted on `safe` afterwards.

Profile `servo` therefore has one clean loaded run at 25.8 ms with the
audio path bit transparent; three more make it acceptable under the
project's rule. Nothing about the servo moves a buffer, so its latency is
the `safe` point's.

**SWITCHED 2026-09-02 23:10 local by the user: the service runs profile
`servo`.** `switch-profile servo` restarted the stack (stop at 5767 s of
uptime, `running` at 5819 s, `PITCHSERVO enabled` at 5815 s, no startup
XRUN pair). `/etc/usb16x16/aes67.conf` is `a811f5c3` (`PROFILE=servo`,
otherwise `46995a45`); the repo copy and `install-aes67-service.sh` are
pinned to it and `46995a45` joined the unedited-shipped list. The profile
is still marked experimental on one clean run; three more loaded
800-impulse runs are the remaining acceptance work, and the profile's
STATUS/COVER/MEASURED strings should be updated when they pass. Rollback
is `switch-profile safe`, the same binary with the resampler.

**Lever 1 started 2026-09-02 about 23:19 local: governor `performance`
on all four CPUs, runtime only.** Set by the user with `stall-tuning.sh`
at roughly 6300 s of uptime in the boot of 21:34; all cores now read
2.4 GHz, IRQ affinity still stock (0-3), 47.2 C. Baseline for the
comparison: 11 RECOVER lines this boot, the last at 3116 s, three stall
events (2116 s bridge gap 5.9 ms; 3116 s all four PCMs with the bridge
awake; the boot's own first-minute cascade), plus the startup pair. Judge
the lever by RECOVER lines with monotonic timestamps after 6300 s over
several hours of service time; the servo profile's BRIDGE line at the
start read gaps 1.4/1.8 ms, zero restarts, pitch 1000014, zero clips.
Does not survive a reboot.

**Decided 2026-09-02, late: the next latency step is a per-direction
level servo, to be planned on 2026-09-03 after the morning stall count.**
Tonight's servo drives Capture Pitch and Playback Pitch with one value,
which holds the TX/RX split but leaves their sum where the prime put it.
Driving the two controls separately gives each direction its own level
loop, so the prime stops mattering, the cold-boot depth excess heals in
place, and each depth can be trimmed to its required cover. Depths in
the servo run: TX 367 frames, RX 329, against a cover need near 200 and
150 if the worst wakeup gap stays at 2 ms; about 7 ms on the table, none
of it safe while 6 ms stalls exist. Open question to test first: whether
macOS tolerates its input and output rates differing by a few ppm for
minutes while levels correct. Also on the list once depths are servo-held:
re-test the sink delay (closed as a non-lever only because the conserved
depth absorbed it), the 32-frame DAW buffer (1.33 ms, measured), packet
time below 1 ms, and 96 kHz end to end. Realistic landing on this
transport: 18-20 ms device timeline.

**MEASURED overnight, 2026-09-03: lever 1 (governor `performance`)
held for 10.2 h of service time with zero stalls.** RECOVER count stayed
at 11 (last at 3116 s), worst bridge wakeup gap 1.8 ms across the whole
night on profile `servo`, zero restarts, same boot, IRQ affinity still
stock. Against three stall events in the 105 min before the lever, and
the longer history of one per one to two hours, ten quiet hours would
occur by chance well under one time in a hundred. Called at 09:33 local
with the user; the watch continues. `performance` is runtime-only and
needs a persistent form before the next reboot. The stall margin the
bridge has to cover is therefore about 2 ms, not 6. Observation from the
night: mode 1's level bias sat at its 3 ppm clamp riding the RAVENNA
device's 45-frame sawtooth, harmless but the reason mode 2 uses a lower
gain.

**MEASURED: one stall under `performance`, 09:52:34 local, monotonic
44318 s, 10.6 h after the lever.** Shape: USB capture XRUN (TX,
`last_gap_us=2457`) and USB playback XRUN (RX, `last_queue=144`,
`last_gap_us=1032`) in the same instant, RAVENNA PCMs untouched: a
USB-side event with the bridge 2.5 ms late, its largest gap since the
switch (1.8 ms overnight). Context: a burst of six short ssh sessions
from the Mac at 44296-44311 (an incremental bridge build, 6.5 s of CPU,
ending at 44304, then four sub-second scp/validation sessions), the last
closing 6.4 s before the stall. Not the tight 0.2-0.4 s coupling of the
three earlier session-close hits, and the compile had been idle for 14 s,
so it is recorded as unattributed. Rate under `performance` is now one in
12.3 h against three in 1.75 h before it: a large reduction, not zero.
Mode 1 re-primed both directions and continued (`tx_restarts=1
rx_restarts=1`); RX's queue floor after the re-prime reads 54 against 96
before, which is the case mode 2's absolute setpoints exist for.
Practice going forward: no builds or staging on the Pi during a
measurement window, and prefer the service stopped for any compile.

**IMPLEMENTED, staged, not installed: the split pitch servo,
`--usb-pitch-servo 2`, bridge `da7df1c2`.** Design, from the depth
equations: TX depth rate is r_usb(1 + pi_c) - r_rav and RX depth rate is
r_rav - r_usb(1 + pi_p), so Capture Pitch = nominal - (ppm + tx_bias)
and Playback Pitch = nominal - (ppm - rx_bias), each bias a
proportional `LevelServo` on that direction's depth (ring plus playback
queue): gain 0.01 ppm/frame, clamp 2 ppm, and a wide clamp of 8 ppm
beyond 192 frames of error so a cold-boot excess of 480 frames drains in
minutes. The shared estimator is untouched; its applied-ratio correction
integrates the mean of the two applied pitches, which is exact for the
differential. Setpoints `--tx-depth`/`--rx-depth` are absolute frames,
0 = capture at engagement; the bridge, wrapper and supervisor refuse a
TX setpoint under target + 144 + period and an RX setpoint under target
+ 2 periods, and refuse any setpoint outside mode 2. New telemetry:
`pitch_p`, `tx_bias`, `rx_bias`, `tx_set`, `rx_set`; `PITCHSERVO engaged
mode=2` carries both setpoints and depths. Modes 0 and 1 are unchanged
code paths. Core tests cover the level law (`test_level_servo`); ctest
passes on the Mac and the Pi, option validation exercised on the Pi.

Staged in `~/usb-16x16-work/phase4-split-install/`: bridge `da7df1c2`,
wrapper `c7d63ac9` (positional 13/14 `tx_depth_frames`/`rx_depth_frames`,
`USB16X16_PHASE4_TX_DEPTH_FRAMES`/`RX` on the Mac side), supervisor
`91845b6a` (optional `TX_DEPTH`/`RX_DEPTH` keys), `aes67.conf` `ba3c7a98`
(new experimental profile `servo-split`, mode 2, setpoints 0; the `servo`
profile's strings now record its one run; `PROFILE=servo` unchanged),
installers pinned, `a811f5c3` added to the unedited-shipped list. Install
order as before, service stopped: `install-candidate.sh` then
`install-aes67-service.sh`.

Runs planned, in order: (1) mode 2 with setpoints 0, 600 s, 800
impulses, loaded: the macOS tolerance test, expecting 25.8 ms, zero
spread, `pitch` and `pitch_p` within 4 ppm; (2) setpoints 48 frames under
run 1's captured levels, expecting about 1 ms less with floors over
cover; (3) a cold boot to watch the excess drain in place. Then the
`--target` reduction as its own plan.

**INSTALLED 2026-09-03 about 10:10 local by the user: bridge `da7df1c2`,
wrapper `c7d63ac9`, supervisor `91845b6a`, conf `ba3c7a98`; service back
on `servo` (mode 1).**

**MEASURED: split servo run 1, mode 2, setpoints captured.**
`phase4-candidate-20260903T141038Z`, 600 s, 800 impulses, load 0.05:
median **1268 samples, 26.417 ms, all 800 on one sample, score 1.000**,
zero restarts, zero clips. `PITCHSERVO engaged mode=2 tx_setpoint=384
rx_setpoint=324`; depth means 380/315; floors 168/96; Capture and
Playback Pitch identical for 592 of 600 s and 1 ppm apart for 8 s (max
difference 1 ppm); biases within +-0.52 ppm all run against mode 1's
3 ppm clamp-riding. **macOS tolerated the split**, at least at a 1 ppm
divergence. Total depth 695 frames, the same as run `024954Z` (696), so
the 29-sample difference from that run's 1239 is the resting-level
scatter outside the bridge (1227-1311 for this point), not the servo.

**MEASURED: split servo run 2, setpoints 48 frames lower (TX 336, RX
276): the level loop did not move the depths.** `phase4-candidate-
20260903T142307Z`: 1278 samples, 26.625 ms, zero spread, zero restarts,
zero clips, but depth means 373/322 against setpoints 336/276, biases
0.55/0.33 ppm all run, pitches 1000015/1000016. Cause: gain 0.01
ppm/frame is inside the 1 ppm pitch quantisation: a 50-frame error asks
for 0.5 ppm, which rounds away, and even a whole ppm moves a depth at
0.048 frames/s (2.9 frames/min). The per-direction loop needs the
differential loop's gain times two, not divided by five: mode 1's 0.05
on the differential is 0.1 per direction. Fix: default gain 0.05
(20 frames = 1 ppm, time constant about 420 s), and the gain is now a
wrapper positional (15, `USB16X16_PHASE4_LEVEL_GAIN`), a supervisor
profile key (`LEVEL_GAIN`, optional, absent = 0.05) and a bridge option,
so the next adjustment needs no rebuild. Rebuild pending, with the
service stopped this time.

**INSTALLED 2026-09-03 about 11:00 local: bridge `170b1081` (gain 0.05
default, `--level-gain`), wrapper `c2979d9c`, supervisor `c12d380a`, conf
`52591f6f`; service on `servo`.**

**MEASURED: split servo at gain 0.05, setpoints TX 336 / RX 276, prime
288/144.** `phase4-candidate-20260903T150250Z`: 1283 samples, 26.729 ms,
zero spread, zero restarts, zero clips. The TX loop now moves: depth 432
at engagement, 390 at 219 s, 385 at 369 s, 342 at 526 s, bias at the
2 ppm clamp while travelling and 0.3 on arrival; TX floor fell to 121
as it came down. RX mean 316 against 276: the device's 45-frame skip
each minute outruns what a 2 ppm loop removes (about 6 frames a minute),
so RX cannot be pulled 40 frames against the sawtooth at this clamp. The
impulse window (about bridge time 150-350 s) saw TX near 385, so this
run does not test depth against latency.

**MEASURED: the same with TX prime 240, so the trimmed depth is in place
before the impulses.** `phase4-candidate-20260903T153736Z`: TX depth
336 at engagement and 343-347 through the whole impulse window (RX
298-316), floors 120/109, zero restarts, zero clips, pitches within
2 ppm: **1299 samples, 27.063 ms, zero spread.** Forty frames less TX
depth than runs 141038Z/142307Z/150250Z (1268/1278/1283 at TX about
385) and the round trip went up 16-31 samples.

**CONCLUSION: the bridge's TX depth is slack, not latency.** Across the
four mode-2 runs the round trip read 1268, 1278, 1283, 1299 while TX
depth in the impulse window was 380, 373, 385, 345 and RX 315, 322,
316, 305: no relation, and the run-to-run scatter (1227-1311 across
the point's history) is larger than any depth change tried. This is the
same fact the record already held in three forms: "the level of each run
is set at start", the buffer-384-to-192 result that cut 5.3 ms while the
counted depth rose, and the sink delay that is not a lever. The
presentation time of the RAVENNA stream is fixed when the stream starts;
the queue only determines how far ahead of that deadline the bridge
writes. Trimming the queue buys margin loss and nothing else.

**What this does to the latency plan.** The lever is the start
alignment: what sets the RTP timeline relative to PTP and to the USB
timeline at the moment the RAVENNA playback starts, and the same
question for capture. That is also, almost certainly, the 84-sample
(1.75 ms) run-to-run lottery. The next work is read-only: the RAVENNA
ALSA driver's playback start path (timestamp assignment, base period,
buffer coupling) and the daemon's stream setup, to find what the
alignment depends on and whether a bridge-side start policy can pin it
low and repeatable. The `--target` reduction and any further depth trim
are off the list until that is understood. Mode 2 keeps its value as a
hold: the depth no longer depends on the prime lottery and heals after a
recovery, at the cost of nothing.

Profile `servo-split` stays experimental with setpoints 0; `servo` stays
the running profile.

**READ: how the RAVENNA driver starts and times a stream (source in
`work/aes67-linux-daemon/3rdparty/ravenna-alsa-lkm/driver`, byte-identical
to the Pi's v2.1 build).** Everything runs off one PTP-disciplined 1 ms
timer (the TIC, `tic_frame_size_at_1fs` 48) and one global sample-accurate
counter (SAC).

- **Capture (RX) is a SAC-addressed ring the size of the ALSA capture
  buffer.** An RTP packet with timestamp `s` is written into the live-in
  jitter buffer at offset `(s + sink_delay) mod L`, where `L` is the
  negotiated ALSA capture buffer in frames, 192 at the period-48 point
  (`get_live_in_jitter_buffer_offset`, `RTP_audio_stream.c:694,723`). The
  reader starts at `SAC mod L` at prepare and advances one TIC frame per
  tick (`audio_driver.c` prepare and interrupt). **So the sink delay acts
  modulo the capture buffer**: 576 is 3 x 192, which is 0. The daemon's own
  `playout_delay` is 0 and only feeds `runtime->delay` (the value
  `snd_pcm_delay` adds), not the timing. This explains three things the
  record could not: the sink delay being "not a lever" under Phase 4 (every
  value was taken modulo 192), the stopgap's additive 1:1 sink delay (its
  driver-default buffer was 960, so nothing wrapped), and the 5.33 ms that
  buffer 384 -> 192 removed "from no buffer this process owns" (576 mod 384
  is 192 frames, 4 ms, of extra playout). A packet arriving after its
  slot's read time is read one full buffer later; `sink_min_time` in
  `GET /api/sink/status/N` is the driver's minimum arrival lead in
  microseconds and reads 0 today, meaning packets arrive after their
  nominal use point at delay 0 and are played 192 frames (4 ms) after
  their content SAC. **A sink delay of (arrival lead + jitter margin) mod
  192 would move the RX playout from about 4 ms to about that margin**,
  deterministically, without touching the bridge. Candidate values 96-168;
  the 2026-09-02 live sweep saw 288 (that is 96) lowest and 144 highest,
  which is consistent with arrival landing near those slots and needs the
  within-session sweep below with `sink_min_time` recorded.
- **Playback (TX) is an ordinary DMA-style ring.** The ALSA hw pointer
  starts at 0 on prepare and advances 48 frames per TIC after trigger; each
  tick copies the frame at the hw pointer into the internal live-out ring
  and the sender stamps the packet with `SAC - 48` ("the SAC when the audio
  was produced", `RTP_audio_stream.c:845`), whatever the age of the data.
  The Ferrofish plays a packet at its RTP timestamp plus its own receive
  latency (2 ms setting). So in this design the bridge's TX queue depth is
  latency at 1:1 and the start lottery is the phase between the bridge's
  prime and the TIC grid, at most 48 frames per direction, plus the RX
  modulo above. That contradicts the four single-run mode-2 results, which
  are each one draw of an 84-sample lottery and cannot resolve a 40-frame
  effect. The next measurement is within one session.
- **The internal rings are large** (`MR_ALSA_RINGBUFFER_NB_FRAMES`); only
  the ALSA-side buffers set the modulo and the pointer behaviour above.

**Two within-session experiments, scripts ready, not run.**
`work/aes67-candidate/sweep-phase4-depth.sh`: one 1200 s candidate in mode
2 with a TX setpoint under the prime level, 200-impulse harness points at
chosen bridge seconds, each tagged with the depths, floors, pitches, biases
and `sink_min_time` at that moment. Points 120/480/840 with TX 336 give
about 385, 350, 336 frames of TX depth in one draw of the lottery; the
median must fall by the depth difference if the TX reading above is right.
Then `sweep-phase4-sink-delay.sh` at 576 96 120 144 168 with the same
tagging, to place the RX playout just above the arrival lead.

**MEASURED: the within-session depth sweep, and the verdict.**
`phase4-depth-sweep-20260903T160312Z` (candidate `phase4-candidate-
20260903T160313Z`, 1200 s, mode 2, TX setpoint 336, RX 276, gain 0.05):
three 200-impulse points in one session, readiness at bridge second 287.

| bridge s | TX depth | RX depth | median |
|---:|---:|---:|---:|
| 287-338 | 394 | 288 | 1382 |
| 480-533 | 388 | 267 | 1382 |
| 843-895 | 346 | 289 | 1382 |

Spread 0 and score 1.000 at every point, zero restarts, zero clips. TX
depth moved 48 frames under the servo inside one draw of the start
lottery and the round trip did not move one sample. **On the device
timeline, servo-driven depth is invisible in both directions.** The
driver reading above ("TX queue depth is latency at 1:1") is wrong as a
statement about what the harness, RTL Utility and a DAW measure: the
transmit schedule is a fixed map from sample index to tick fixed at
trigger, and pitching the Mac to move the queue slides the Mac's clock,
not the schedule. Prime-set depth (start time) shows, as the 2026-09-01
prime series proved at 8 ms scale; servo-set depth does not.

**Consequences.** (1) DAW-visible latency is set entirely at stream
start: primes, buffer sizes, sink delay modulo the capture buffer, and
the phase between the bridge's start and the tick grid (the 84-sample
lottery). (2) Servo-held depth is free on that timeline: start with the
smallest primes the first seconds survive, then let the servo raise the
depth to the cover it needs. Safety no longer trades against latency.
This needs a fill faster than the 2 ppm clamp, i.e. a wider clamp or a
startup fill phase; design item. (3) The RX modulo lever (sink delay of
arrival lead plus margin, mod 192, instead of 576) is a start-time
quantity and should show; it is the next sweep. (4) Open: whether the
wall-clock latency a performer hears follows the device timeline or the
queue. The bridge's depth telemetry is the wall-clock number by
definition; the harness cannot see it. One deliberate test later, with
an external clock, not now. The 1382-sample session level itself is
another draw of the lottery (1227-1382 now).

**MEASURED: the within-session sink-delay sweep, and the RX modulo lever
is exact.** `phase4-sink-sweep-20260903T164438Z` (candidate 164439Z, 900 s, profile
`servo` point, mode 1), live `PUT` per point, 20 s settle, readiness,
200 impulses, all spread 0 and score 1.000, zero restarts, zero clips:

| sink delay | delay mod 192 | median | against 576 |
|---:|---:|---:|---:|
| 576 | 0 | 1598 | |
| 96 | 96 | 1502 | **-96** |
| 120 | 120 | 1526 | **-72** |
| 144 | 144 | 1550 | **-48** |
| 168 | 168 | 1382 | -216 |

Three points sample-exact on `latency = constant + (delay mod 192)`,
with the 576 baseline reading a full lap late (packets arrive after the
zero slot is read and are taken one buffer later). The fourth point
jumped down a lap plus 24: that `PUT` re-drew the alignment, which is
also what the 2026-09-02 sweep's chaotic values look like in hindsight.
So a live change is not a reliable way to apply the value; the
profile's startup `SINK_DELAY` is (the 2026-09-02 result that startup
144 equals live 144 stands). This session's own 576 level, 1598, is
216 above the depth sweep's 1382 at the same point, so the start
lottery is at least 192 + 24 wide and lap-structured. `sink_min_time`
read 0 at every point and is not a usable indicator.

**What to deploy:** the smallest delay that still sits on the line,
plus a jitter margin. The lower sweep (576, 24, 48, 72, 96) finds the
arrival lead: the first value that lands a lap above the line instead
of on it.

**MEASURED, then discarded: the first lower sweep (576, 24, 48, 72, 96),
`phase4-sink-sweep-20260903T170050Z`.** Baseline 576 read 1564 (a third
draw: 1382, 1598, 1564 at the same point). The daemon rejected 24 with
HTTP 400, **and the rejected PUT left sink 0 removed** (`session_manager::
sink 0 not in use` from then on); the 48 and 72 points updated sink 1
only, so the harness, which listens on sink 0's channels, saw no signal.
Those two "no signal" results say nothing about the arrival lead. The 96
point failed because the candidate's 900 s clock ran out. Lessons: the
daemon's minimum sink delay is above 24 (48 is accepted), and a rejected
sink PUT is destructive, so a sweep must stay inside the accepted range.
Rerun as 576, 48, 72, 96.

**MEASURED: the lower sweep rerun, `phase4-sink-sweep-20260903T172330Z` (candidate 172330Z),
576 48 72 96, both sinks confirmed at every point, zero restarts, zero
clips, spread 0 everywhere.**

| sink delay | median | against 576 | reading |
|---:|---:|---:|---|
| 576 | 1439 | | lap late, as always at delay 0 mod 192 |
| 48 | 1487 | +48 | lap late |
| 72 | 1511 | +72 | lap late |
| 96 | 1535 | +96 | **lap late in this session**; on the line (-96) in 164438Z |

A lap-late point reads baseline plus the delay, exactly, and the audio
is intact: the reader takes the packet on its next pass, 192 frames
later, no dropout. **So the wrap costs 4 ms, never silence, and the
floor is between 96 and 144 samples of arrival lead, and it moves with
the session.** The driver fixes the reader phase at capture prepare
(`capture_buffer_pos = SAC mod L`, then 48 per tick): a packet in slot
`x` is read at `SAC = x + delta`, `delta` being the interval from the
prepare call to the next tick, anywhere in (0, 48]. The wrap condition
is `delay + delta > arrival lead`; 96 clears it in one session and not
in another, so the lead is in (96, 144). Any delay under about 144 is a
per-session gamble: 1 ms saved or 3 ms lost. 168 is safe by at least 24
frames and saves 0.5 ms; 144 saves 1 ms with a margin that can be a
single frame. Session baselines at 576 now read 1382, 1439, 1564, 1598:
a 216-sample spread, lap-structured, larger than the 48-per-direction
tick phase can make. The likeliest second lap is at the Ferrofish: the
Pi stamps packets `SAC - 48` and the Ferrofish plays at stamp + 96 (its
2 ms setting), leaving the network about 48 frames of budget against an
observed 1.4 ms peak, so some sessions' start phase would put the whole
stream one Ferrofish buffer late. Not yet measured; Dante Controller's
receive-latency view in a high session against a low one would show it.

**Design this points at: an aligned start.** The bridge controls when
the RAVENNA capture is prepared and when playback is triggered. If it
observes the tick phase first (period wakeups on RAVENNA capture arrive
once per tick) and re-prepares capture a known few tens of microseconds
after a tick, `delta` becomes a constant near zero, the sink delay can
be set to arrival lead plus a small margin (about 2 ms below today),
and one 48-sample term leaves the lottery; the same for the playback
trigger. That is a bridge change, one variable, measurable by the same
within-session sweep. Until then the deployed 576 is the predictable
choice; 168 is the safe small win.

**IMPLEMENTED, staged, not installed: the aligned start, bridge
`767ae43d`.** `--align-start 0|1` (default 0) and `--align-offset-us N`
(default 600, at most 10000; a non-default offset needs align-start 1).
With it on, the bridge starts the RAVENNA capture first and alone, goes
real-time, drains that capture, then times eight of its period wakeups
(one per driver tick) with `poll` on its descriptor alone, draining after
each so the next poll blocks until the next tick. The median of the seven
intervals (`median_wake_interval` in the core, unit-tested: a short first
interval and one late wake do not move it) is the tick period and the last
wake the reference. An absolute `clock_nanosleep` on `CLOCK_MONOTONIC` to
the reference plus the offset, then drop, prepare, start on the RAVENNA
capture, so the reader phase the driver fixes at prepare (`capture_buffer_pos
= SAC mod L`) is the same every session instead of anywhere inside a tick.
Only then does the USB capture start: one deviation from the agreed order
("after both captures are started"), because the USB capture's 192-frame
buffer is 4 ms and the observation takes 8 ms, so it would overrun and
register a direction restart before the run began, which the wrapper
rejects at startup. With align off the start order is byte-for-byte the
historical one; modes 0/1/2 and TX are untouched, and a direction
recovery still re-prepares unaligned. One `ALIGN` line on stdout:
`status=ok|failed offset_us wakeups tick_period_us wake_to_prepare_us
prepare_us intervals_us` (`wake_to_prepare_us` is measured from the
reference wake to the prepare call, after the drop; `prepare_us` is the
call's duration), plus `reason=` on failure, in which case the capture is
restarted unaligned and the run continues. SUMMARY gains `align_start`,
`align_ok`, `align_tick_period_us`, `align_wake_to_prepare_us`,
`align_prepare_us`. Built on the Pi in `phase4-servo-src` with the service
stopped (about 15 s of compile), ctest clean on the Mac and the Pi, the
option validation exercised on the Pi.

Wired through: wrapper `9af0135d` (positionals 16/17 `align_start`,
`align_offset_us`, defaults 0/600, validated like the bridge;
`USB16X16_PHASE4_ALIGN_START` / `USB16X16_PHASE4_ALIGN_OFFSET_US` on the
Mac side in `measure-phase4-roundtrip.sh`, `sweep-phase4-sink-delay.sh`
and `sweep-phase4-depth.sh`), supervisor `f0b783c4` (optional profile keys
`ALIGN_START` / `ALIGN_OFFSET_US`, absent = off / 600, shown by
`profiles`), `aes67.conf` `e662755b` (new experimental profile
`servo-aligned`: the `servo` block with `ALIGN_START=1`, `SINK_DELAY` still
576 until the sweeps below place it; `PROFILE=servo` unchanged), unit
`77837e60` unchanged, both installers re-pinned, `52591f6f` added to the
unedited-shipped list. Every profile block validates through the
supervisor's own parser. Staged in `~/usb-16x16-work/phase4-align-install/`;
install order as before with the service stopped: `install-candidate.sh`
then `install-aes67-service.sh`. Service restarted on `servo` after the
build.

**INSTALLED 2026-09-03 about 16:15 local by the user: bridge `767ae43d`,
wrapper `9af0135d`, supervisor `f0b783c4`, conf `e662755b`.** Service left
stopped for the sweeps.

**MEASURED: two within-session sink-delay sweeps with the aligned start,
`phase4-sink-sweep-20260903T202211Z` (candidate 202212Z) and
`phase4-sink-sweep-20260903T204113Z` (candidate 204114Z).** Both on the
`servo` point (period 48, target 128, primes 288/144, RAVENNA playback
384, mode 1), `--align-start 1 --align-offset-us 600`, 1080 s candidates,
live `PUT` per point, 20 s settle, readiness, 200 impulses; every point
spread 0 and score 1.000, zero restarts, zero clips, TX floors 161/163, RX
floor 109 in both, worst gaps 1.0/1.5 ms. The alignment itself was the
same to the microsecond: `ALIGN status=ok tick_period_us=1000
wake_to_prepare_us=616 prepare_us=11` and `615 / 11`, intervals 984-1001 us
with the first (the backlog wake) short, as the median is there for.

| sink delay | session 1 | session 2 | unaligned 164438Z | unaligned 172330Z |
|---:|---:|---:|---:|---:|
| 576 | 1549 | 1352 | 1598 | 1439 |
| 96 | 1453 | 1448 | 1502 | 1535 |
| 120 | 1477 | 1472 | 1526 | |
| 144 | 1501 | 1496 | 1550 | |
| 168 | 1333 | 1520 | 1382 | |

**The aligned start makes the on-line points absolutely repeatable.** 96,
120 and 144 read 1453/1477/1501 and 1448/1472/1496: sample-exact on
`latency = C + delay` in both sessions with C five samples apart, where
the two unaligned sessions had the same 96 point at 1502 and 1535, a
33-sample scatter on top of their lap flips. The remaining 5 samples
(0.1 ms) are outside the RAVENNA capture phase: the TX trigger, the USB
side or the Ferrofish, one draw each. So the design did what it was for:
one 48-sample term left the lottery and the RX playout is a constant.

**Two points sit on edges and flipped a lap between the sessions, in
opposite directions.** 576 (0 mod 192) read 1549 then 1352, one lap
above the line and then on it; 168 read 1333 then 1520, one lap below the
line and then on it. Each is within a few samples of a wrap boundary, so
a few samples of the residual draw flip the whole lap, which is also what
the 576 history says: 1352, 1382, 1439, 1549, 1564, 1598 across six
sessions, lap-structured. 168 on its low lap (1333) is the best value the
project has seen, but it is not a value that can be deployed: it is the
other side of the same coin. The lower sweep (172330Z) found no value a
lap above the line down to 48, so the smallest on-line delay is at or
below 48 and the plan's rule (that plus a 24-48 margin) gives 96, 48
below the upper edge. **Profile `servo-aligned` is set to `SINK_DELAY=96`**
(conf `14d74d92`, `e662755b` joins the unedited-shipped list): 30.2 ms,
repeatable to five samples, against the `servo` profile's 28.2-33.3 ms
draw at 576. Latency is about even with the mean of that draw; the gain is
that the number is the same every start, which is the stability-first
priority. Note that the wrap at delay 0 costs nothing audible: the reader
takes the packet on its next lap, 4 ms later, intact.

**MEASURED: the deployable point at startup,
`phase4-sink-sweep-20260903T210028Z` (candidate 210028Z, 900 s), sink
delay 96 at start, then live 576, then live 96, align on.** Startup 96:
**1438 samples, 29.958 ms**, spread 0, score 1.000; live 576: 1342 (96
below, the low lap again); live 96: 1438 on the sample. Zero restarts,
zero clips, floors 162/109, gaps 1.2/1.5 ms, `ALIGN status=ok
tick_period_us=999 wake_to_prepare_us=616 prepare_us=10`. Startup and
live 96 agree, and the excursion through 576 left nothing behind.

Across the three aligned sessions the 96 point read 1453, 1448, 1438: a
15-sample (0.3 ms) window with no lap structure, against 1352-1598 for
576 over six sessions (three aligned: 1549, 1352, 1342, so 576 lands on
its low lap two times in three and costs 4 ms the third). The sink delay
of 96 is therefore the stability-first choice: 30.0 ms every start,
2 ms above 576's good draws and 2 ms below its bad one. What is left of
the lottery (the 15 samples, plus the lap 576 and 168 ride) sits outside
the RAVENNA capture phase: the RAVENNA playback trigger, the USB side, or
the Ferrofish's receive buffer; the TX trigger is the same design applied
to the other direction and is the next candidate if 0.3 ms matters.

Service restarted on `servo` after the run. `servo-aligned` (sink delay
96, align on) is staged in `~/usb-16x16-work/phase4-align-install/`
(conf `14d74d92`, installer `461ded3b`; the bridge, wrapper and
supervisor there are the installed ones) and needs
`install-aes67-service.sh` with the service stopped, then
`switch-profile servo-aligned`. Acceptance under the project's rule is
still four loaded 800-impulse runs on the profile itself.

**INSTALLED AND SWITCHED 2026-09-03 17:36 local: the service runs profile
`servo-aligned`.** The user installed conf `14d74d92` and ran
`switch-profile servo-aligned` with the service still stopped, so the
profile took effect on the start that followed: `sinks applied, delay 96`,
`ALIGN status=ok tick_period_us=999 wake_to_prepare_us=616 prepare_us=13`,
`running` at 17:37:14, no startup XRUN pair, zero recoveries, PTP locked,
jitter 15. `/etc/usb16x16/aes67.conf` is `7c08af39` (`PROFILE=
servo-aligned`, otherwise `14d74d92`); the repo copy and
`install-aes67-service.sh` are pinned to it and `14d74d92` joined the
unedited-shipped list. Rollback is `switch-profile servo`, the same
binary with the historical start order and sink delay 576. Remaining
acceptance work: four loaded 800-impulse runs on this profile, and the
overnight stall watch continues under the `performance` governor.

**MEASURED: acceptance run 1 of 4 on profile `servo-aligned`,
`phase4-candidate-20260903T213935Z`, 600 s, 800 impulses at 64 frames,
load 0.05: median 1416 samples, 29.500 ms, all 800 on one sample, score
1.000**, zero restarts, zero clips, zero pitch write errors, `tx_qfloor`
159, `rx_qfloor` 107, `tx_pullmax` 48, gaps 1.1/1.8 ms, pitch 1000015,
bias 0.75 ppm, `ALIGN status=ok tick_period_us=1000 wake_to_prepare_us=615
prepare_us=12`. (The Mac-side SAP watcher could not bind UDP 9875 because
Dante Controller held it, so this run has no SAP timeline; nothing else
was affected.) The 96 point has now read 1453, 1448, 1438 and 1416 across
four aligned sessions: a 37-sample (0.8 ms) window with no lap structure,
wider than the 15 samples the first three suggested, against the
216-sample lap-structured spread at 576. Three loaded runs remain for
acceptance. Service restarted on `servo-aligned` afterwards, its own
start aligned at 618 us.

**Measurement plan after the install, in order.**

1. Profile `safe` with the new binary, 600 s, 800 impulses at 64 frames:
   the wrap fix alone must reproduce 25.6-27.3 ms with `tx_clip` counting
   on hot material and zero restarts. One run is the regression check;
   four is acceptance.
2. The same run with `USB16X16_PHASE4_USB_PITCH_SERVO=1`: `pitch` should
   settle near 1000015, `bias_ppm` inside +-1, `tx_clip`/`rx_clip` at zero
   on the same material, floors at or above the resampler run's, latency
   at the same level (the servo moves no buffer). Then a 0 dBFS listening
   test.
3. Governor `performance`, then IRQ pinning, one at a time, each judged
   by RECOVERs over hours of service time.

## Next-session checklist

1. Verify `usb-16x16.service` is active and the UDC is `configured/high-speed`.
2. Confirm macOS exposes `USB 16x16` through CoreAudio before any measurement.
3. Confirm the Pi is clean: no `ptp4l`, `aes67-daemon`, or `alsaloop`, and the
   RAVENNA module unloaded.
4. Remember that `eth0` at `169.254.92.97` is the AES67 network and `wlan0` at
   `192.168.1.201` is management. SSH working says nothing about AoIP health.
5. **Phase 4 is accepted at 29.1 ms with the skip covered (2026-09-02).**
   The next piece of work is the persistent service; the design and the
   pickup prompt are in `work/aes67-bridge/DEPLOYMENT_PLAN.md`. Do not
   re-tune the bridge inside that work.
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
