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

**MEASURED: acceptance run 2 of 4 on `servo-aligned`,
`phase4-candidate-20260903T220840Z`, same arguments: median 1421 samples,
29.604 ms, all 800 on one sample, score 1.000**, zero restarts, zero
clips, zero pitch write errors, `tx_qfloor` 163, `rx_qfloor` 109,
`tx_pullmax` 48, gaps 1.1/1.5 ms, pitch 1000015, bias 0.5 ppm, `ALIGN
wake_to_prepare_us=617 prepare_us=12`; SAP timeline recorded this time
(Dante Controller closed). Five aligned sessions at 96: 1453, 1448,
1438, 1416, 1421. Two loaded runs remain. Service restarted on
`servo-aligned` afterwards, aligned at 617 us.

**MEASURED: acceptance run 3 of 4 on `servo-aligned`,
`phase4-candidate-20260903T222751Z`, same arguments: median 1416 samples,
29.500 ms, all 800 on one sample, score 1.000**, zero restarts, zero
clips, zero pitch write errors, `tx_qfloor` 160, `rx_qfloor` 133 (the RX
floor sat a period higher than the 107-109 of the earlier runs, the
prime's overshoot landing differently), `tx_pullmax` 48, gaps 1.0/1.5 ms,
pitch 1000015, bias -0.05 ppm, `ALIGN wake_to_prepare_us=615
prepare_us=10`. Six aligned sessions at 96: 1453, 1448, 1438, 1416, 1421,
1416; the three loaded 800-impulse runs read 1416, 1421, 1416. One
loaded run remains. Service restarted on `servo-aligned` afterwards,
aligned at 617 us.

**MEASURED: acceptance run 4 of 4 on `servo-aligned`,
`phase4-candidate-20260903T224111Z`, same arguments: median 1400 samples,
29.167 ms, all 800 on one sample, score 1.000**, zero restarts, zero
clips, zero pitch write errors, `tx_qfloor` 161, `rx_qfloor` 107,
`tx_pullmax` 48, gaps 1.0/1.8 ms, pitch 1000015, bias -0.05 ppm, `ALIGN
wake_to_prepare_us=617 prepare_us=18`. Service restarted on
`servo-aligned` afterwards, aligned at 616 us.

**ACCEPTED 2026-09-03: profile `servo-aligned`** (period 48, target 128,
primes 288/144, RAVENNA playback 384, USB pitch servo mode 1, aligned
start at 600 us, sink delay 96), on four loaded 800-impulse runs: 1416,
1421, 1416, 1400 samples (29.2-29.6 ms), every impulse on one sample in
every run, zero restarts, zero clips, TX floor 159-163 over the
144-frame skip bar, RX floor 107-133, worst gaps 1.8 ms, the alignment
615-618 us after the reference wakeup in every start including the
service's own. Seven aligned sessions at 96 span 1400-1453 (53 samples,
1.1 ms), no lap structure, against 1352-1598 at 576. It is the first
accepted point with the audio path bit transparent and the RX playout
fixed at start. The conf's `servo-aligned` block now says so (STATUS
accepted, COVER, MEASURED; conf `40496730`, `7c08af39` joins the
unedited-shipped list); it is staged in `phase4-align-install/` and
needs one more `install-aes67-service.sh` with the service stopped; the
running service's behaviour is unchanged by it. Rollback stays
`switch-profile servo` (sink delay 576, historical start) or `safe`
(the resampler).

**INSTALLED 2026-09-03 18:56 local by the user: conf `40496730`
(`servo-aligned` marked accepted), service restarted on `servo-aligned`.**
`status` now reads `servo-aligned (accepted, cover: TX floor 159-163 over
the 144-frame skip bar, RX 107-133, measured: 29.5 ms (29.2-29.6), 4 x
800 impulses, zero spread)`. `/etc/usb16x16/aes67.conf`, the repo copy
and `install-aes67-service.sh` are all at `40496730`; nothing is staged
that is not installed.

**STAGED, not installed: the persistent form of lever 1,
`work/pi-tuning/usb16x16-governor.service` (unit `00644010`) with
`install-governor-unit.sh`.** Nothing in userspace on this Pi sets the
governor at boot (no `raspi-config` unit, no `cpufrequtils`, no
`/etc/default/cpufrequtils`), so the kernel's `ondemand` default is what
the runtime lever has been overriding since 2026-09-02 23:19 and what a
reboot would restore. The unit is a `oneshot` with `RemainAfterExit`,
`Before=usb16x16-aes67.service`, `ExecStart` calling the installed,
root-owned, hash-pinned `usb16x16-stall-tuning governor performance` and
`ExecStop` calling `governor ondemand`, so the lever still lives in one
script and `systemctl disable --now usb16x16-governor.service` is the
rollback. The installer pins the unit's hash and refuses unless the
installed stall-tuning script is the `bde240b8` one; it enables and
starts the unit, which writes the value the runtime lever already holds.
Staged in `~/usb-16x16-work/governor-install/`; needs the password once.
The IRQ-pinning lever (2) stays runtime-only and unused.

**INSTALLED AND VERIFIED BY REBOOT 2026-09-03 about 19:20 local: the
governor is persistent.** The user installed `usb16x16-governor.service`
(unit `00644010`, enabled); reboot at 77499 s of uptime. On the new boot:
`usb16x16-governor.service` started at 6.96 s and set `performance` at
7.20 s, `usb16x16-aes67.service` started at 15.40 s, all four CPUs
`performance` at 2.4 GHz, UDC `configured/high-speed`, `usb-16x16.service`
active, PTP locked in 10 s, sinks applied at 58 s, bridge running at 62 s
on profile `servo-aligned`. Lever 1 no longer depends on anyone remembering
it. (The script's "runtime only" wording in the journal line is the pinned
stall-tuning script's own message; the unit is what makes it persist.)

**FOUND on the same cold boot: the aligned start does not survive the
known cold-boot XRUN.** The service's bridge logged `ALIGN status=failed
reason=drain` and ran unaligned, then took three RX recoveries (USB
playback XRUN at bridge 1.7, 4.2 and 7.6 s, the cold-boot cascade the
record already describes) before settling with zero further recoveries.
`drain` means the RAVENNA capture returned an error other than EAGAIN
before the first wakeup was timed, which on a cold boot is the capture
XRUN every boot starts with; the bridge gave up after one attempt, by
design, and the session's RX playout is therefore one draw of the old
lottery until the next service restart. Fix to make: on a drain or avail
error the alignment should recover the capture (drop, prepare, start) and
try again a few times before giving up, and the ALIGN line should carry
the ALSA error text. Warm restarts (every `systemctl start` today, seven
of them) aligned every time; only the cold boot fails.

**IMPLEMENTED, staged, not installed: the alignment retry, bridge
`99f37408`.** `align_ravenna_capture` now runs its observation in
attempts: one that meets an ALSA error (the cold-boot XRUN) recovers the
capture (drop, prepare, start) and tries again, up to four, each bounded
at about 200 ms; only when all fail is the capture restarted unaligned.
The ALIGN line and SUMMARY carry `attempts`, and a failure reason names
the stage and the ALSA error as a number (`drain error=-32` is EPIPE, the
XRUN) rather than its text, because the candidate wrapper treats "broken
pipe" in the log as a failure marker and an XRUN the alignment recovers
from before any audio is primed is not one. Warm starts still align on
attempt 1. ctest clean on the Mac and the Pi, built with the service
stopped. Wrapper `2f2354e1` and supervisor `16308997` differ from the
installed ones only by the bridge hash; conf `40496730` unchanged;
installers and README re-pinned. Staged in
`~/usb-16x16-work/phase4-align2-install/`; install order as before,
service stopped: `install-candidate.sh` then `install-aes67-service.sh`.
The proof is the next cold boot's ALIGN line reading `status=ok
attempts=2` or so; the previous bridge `767ae43d` stays installed until
then.

**INSTALLED 2026-09-03 about 19:25 local by the user: bridge `99f37408`,
wrapper `2f2354e1`, supervisor `16308997`; VERIFIED BY COLD BOOT.** Reboot
at the user's request; on the new boot the governor unit set
`performance` at 7.0 s, the service was running at 60.7 s on
`servo-aligned`, and the bridge logged **`ALIGN status=ok attempts=2
tick_period_us=999 wake_to_prepare_us=614 prepare_us=8`**: the first
attempt met the cold-boot XRUN, the second aligned, and the phase landed
where every warm start has (614-618 us). The cold-boot cascade then took
one TX recovery (RAVENNA playback XRUN at bridge 5.3 s) and settled with
no further recoveries; a TX recovery re-primes the RAVENNA playback and
leaves the aligned RAVENNA capture untouched, so the RX playout of this
session is the aligned one. Known gap, unchanged: an RX recovery
re-prepares the RAVENNA capture through the ordinary unaligned path, so a
session that takes one is back in the old lottery until the next start;
aligning the recovery path is a small follow-up if RX recoveries turn
out to happen outside cold boots (none has in the accepted runs).

State at the end of 2026-09-03: service on the accepted `servo-aligned`
profile, bridge `99f37408`, governor persistent through
`usb16x16-governor.service`, everything installed matching the repo
(`install-candidate.sh`, `install-aes67-service.sh`,
`install-governor-unit.sh`), nothing staged that is not installed.

**IMPLEMENTED, staged, not installed: the aligned RX recovery, bridge
`38f44de9`.** The start procedure cannot run at a recovery (its 8 ms of
observation would take the live TX direction down), so the tick phase is
kept instead: on every loop iteration the RX direction notes the
iteration's start time when its RAVENNA capture holds exactly one period
after an empty look (a fresh tick, not a backlog serviced late;
`last_fresh_wake_ns`). An RX recovery then drops both PCMs, prepares the
playback, and sleeps on the monotonic clock to the next `wake + offset +
n * tick` (`next_aligned_time` in the core, unit-tested; the tick is the
one the start alignment measured) that is at least 50 us away, at most
one tick, before preparing and starting the capture. It logs `ALIGN
recovery direction=ravenna-to-usb wake_age_us= wake_to_prepare_us=
prepare_us=` on the RECOVER path and SUMMARY counts `align_recoveries`.
The reference carries the loop's service latency (tens of us) where the
start procedure's does not, so a recovered session may sit a few samples
from a started one; still one tick phase, not a draw. With align off, or
before the first fresh wake, the recovery is the historical one; TX
recovery is untouched. ctest clean on the Mac and the Pi, built with the
service stopped. Wrapper `5979bdcf`, supervisor `d8e5729b` (bridge hash
only), conf `40496730` unchanged, installers and README re-pinned. Staged
in `~/usb-16x16-work/phase4-align3-install/`; install order as before.
Proof after the install: an induced 10 ms pause of the service's bridge
(`kill -STOP`, `sleep 0.01`, `kill -CONT` as root) forces both directions
to recover, and the RX RECOVER must be followed by the `ALIGN recovery`
line with `wake_to_prepare_us` near 600.

**INSTALLED 2026-09-03 19:37 local by the user: bridge `38f44de9`,
wrapper `5979bdcf`, supervisor `d8e5729b`; VERIFIED by an induced pause.**
Service start aligned on attempt 1 (615 us). The user paused the
service's bridge for about 20 ms (`kill -STOP`, `sleep 0.02`,
`kill -CONT`) at bridge second 57.7: both directions recovered from
capture XRUN (TX first, RX 63 us later), and the RX recovery logged
**`ALIGN recovery direction=ravenna-to-usb wake_age_us=38607
wake_to_prepare_us=607 prepare_us=23 sleep_result=0`**: the re-prepare
landed 607 us after the tick grid the start had chosen (600 asked, 7 us
of sleep overshoot), one tick at most after the decision, then both
directions re-primed. Exactly one recovery per direction, floors 205/109
afterwards, worst gaps 1.0/1.1 ms since, service running. So an RX
recovery now keeps the session on the aligned phase; the recovered
session's RX playout should sit within a few samples of a started one
(the reference carries the loop's service latency), and the only way
left back into the old lottery is align failing four times at start.

State at the end of 2026-09-03: service on the accepted `servo-aligned`
profile, bridge `38f44de9`, governor persistent, everything installed
matching the repo, nothing staged that is not installed. Not yet
measured: the round trip of a session after an aligned recovery, which
would need a sweep-style run with an induced pause in it; expected
within a few samples of 1416-1453.

**MEASURED 2026-09-03 19:44 local: the round trip of the session after
the aligned recovery, `service-roundtrip-64f-20260903T234418Z`
(measure-under-service.sh 64 800, no stack restart).** The session is the
one above: warm start on bridge `38f44de9` aligned at 615 us, then the
induced 20 ms pause at bridge second 57.7 that recovered both directions,
TX re-primed and RX re-prepared on the tick grid at 607 us. **Median 1320
samples, 27.500 ms, all 800 impulses on one sample, score 1.000**, zero
RECOVERs during the run, zero discontinuities, `tx_qfloor` 168,
`rx_qfloor` 109, `tx_pullmax` 48, gaps 1.1/1.6 ms, pitch 1000015, bias
-0.1 ppm, `tx_clip`/`rx_clip` 0. The expectation above ("within a few
samples of 1416-1453") did not hold: the recovered session sits 96
samples, exactly two packets, below the accepted mode of 1416 and 80
below the accepted window's floor of 1400, with the same zero spread and
the same floors. Observation only; the pause recovered both directions,
so the 96 could be the TX re-prime (the RAVENNA playback trigger, the one
draw the aligned start does not pin) or the RX re-prepare phase, and one
session does not say which is repeatable. 1320 is arithmetically the
accepted sessions' `latency = C + delay` line at delay 0 (C = 1320/1325/
1320/1304 for 1416/1421/1416/1400), noted, not claimed. Whether a
recovered session is consistently two packets faster is a second induced
pause and a second run; whether the term is TX's is the aligned TX
trigger, the candidate already on the list.

**Chosen 2026-09-03 evening by the user as the next phase: the aligned
TX trigger.** The record's own candidate for the residual window (seven
aligned sessions 1400-1453 at sink delay 96, and the 1320 after a
recovery above): the RAVENNA playback trigger is the one start-time draw
the aligned capture start does not pin.

**READ first, in the driver source (`audio_driver.c`, `manager.c`): the
trigger phase is the TX draw.** `mr_alsa_audio_pcm_trigger(START)` calls
`start_interrupts`, which only mutes the output buffer and sets
`m_bIsPlaybackIO`; `prepare` zeroes `playback_buffer_pos`. Nothing about
time is captured at the trigger. The next TIC after it copies the period
at position 0 into the live-out ring and the sender stamps it `SAC - 48`
whatever its age, so the time the primed frames wait before their first
tick is the phase between the bridge's `snd_pcm_start` and the tick
grid, uniform inside 1 ms: up to 48 frames, per session and per TX
recovery. The same 1 ms timer drives the capture ticks the aligned
start already measures, so the grid is known to the bridge.

**IMPLEMENTED, staged, not installed: the aligned TX trigger, bridge
`ee3b5286`.** `--align-tx-trigger 0|1` (default 0, needs
`--align-start 1`) and `--align-tx-offset-us N` (default 600, at most
10000, a non-default value needs the trigger on). With it on, the
RAVENNA playback trigger, at start and at every TX recovery (a TX
recovery re-primes and re-triggers through the same path), sleeps on the
monotonic clock to the next `reference + offset + n * tick` at least
50 us away (`next_aligned_time`, the tick the start measured) before
`snd_pcm_start`, at most one tick of sleep on the audio thread, which the
aligned RX recovery already relies on. The reference is the RX
direction's last fresh RAVENNA capture wake (`last_fresh_wake_ns`,
read through a `tick_source` pointer), seeded with the start
alignment's own reference wake (`AlignResult::reference_ns`, new) for a
trigger before the loop has seen a fresh wake; a reference older than
100 ms is refused (the tick is known to 1 us, so projecting a grid
100 ms forward can be off by 50 us) and the trigger runs unaligned and
says so. One line on stderr per trigger: `ALIGN trigger
direction=usb-to-ravenna status=ok source=fresh-wake|start-reference
wake_age_us= wake_to_start_us= sleep_result= t_us=`, or
`status=unaligned reason=no-reference|stale-reference`. SUMMARY gains
`align_tx_trigger`, `align_tx_triggers`, `align_tx_unaligned_triggers`,
`align_tx_wake_to_start_us` (last). Off, the TX path is byte-for-byte
the installed binary's; the RX alignment and its recovery are untouched
(the seed is a separate field, so RX's recovery behaviour with the
trigger off is unchanged). Expected: `wake_to_start_us` about 600-620
at every start and TX recovery, and the session level the same across
sessions to a few samples.

Built on the Pi in `~/usb-16x16-work/phase4-align4-src` (source hashes
match the repo), clean under `-Werror`, ctest clean on the Mac and the
Pi, the four invalid option combinations refused (`--align-tx-trigger`
without `--align-start`, value 2, a non-default offset without the
trigger, offset above 10000). **Caveat:** the compile ran with the
service running (no measurement or stall experiment in flight; the
memory's rule is compile with the service stopped or say so).

Wired through: wrapper `228018b2` (positionals 18/19 `align_tx_trigger`,
`align_tx_offset_us`, defaults 0/600, validated like the bridge, in
`metadata.txt`; `USB16X16_PHASE4_ALIGN_TX_TRIGGER` /
`USB16X16_PHASE4_ALIGN_TX_OFFSET_US` on the Mac side in
`measure-phase4-roundtrip.sh` and both sweeps), supervisor `ab34a5d6`
(optional profile keys `ALIGN_TX_TRIGGER` / `ALIGN_TX_OFFSET_US`, absent
= off / 600, shown by `profiles` as `tx trigger 1/600 us`; bridge hash
re-pinned), conf `59a23d5e` (new experimental profile
`servo-aligned-both`: the `servo-aligned` block plus the trigger on at
600; `PROFILE=servo-aligned` unchanged, 34 lines added and none
changed), unit `77837e60` unchanged, `install-candidate.sh` `4211df76`,
`install-aes67-service.sh` `55a419df` with `40496730` added to the
unedited-shipped list. Every profile validates through the staged
supervisor's parser against the staged conf, and the staged conf differs
from the installed one by the new block only.

**FOUND on the way, a conf hazard now written into the conf's comment:**
the block was first named `servo-aligned-tx`, whose keys spell
`PROFILE_SERVO_ALIGNED_TX_...`, the same strings as the accepted
`servo-aligned` block's `TX_PLAYBACK_PRIME` and `TX_DEPTH` fields; the
staged supervisor's `profiles` listing showed `servo-aligned` with its
TX prime silently read as 96. A profile name must never be another
profile's name plus `tx` or `rx`. Caught by reading the listing before
anything was installed; the installed conf was never touched.

Staged in `~/usb-16x16-work/phase4-align4-install/`; install order as
before with the service stopped: `install-candidate.sh` then
`install-aes67-service.sh`. The service keeps `servo-aligned`, whose
behaviour the new binary does not change; `servo-aligned-both` is the
candidate. Measurement plan, wrapper runs, one variable: (1) two
sessions with the trigger on at 600 us, 200 impulses each, against the
1400-1453 window: the level should repeat to a few samples; (2) one
session each at 300 and 850 us: if the trigger phase is the lever, the
level must fall 14-15 samples (0.3 ms) per 300 us of later trigger,
sample-exact, which also places the safe deployable offset; (3) four
loaded 800-impulse runs at the chosen offset for acceptance, then
`switch-profile servo-aligned-both`.

**INSTALLED 2026-09-03 about 20:00 local by the user: bridge `ee3b5286`,
wrapper `228018b2`, supervisor `ab34a5d6`, conf `59a23d5e`; service left
stopped for the sessions.**

**MEASURED 2026-09-04 00:03-00:23 UTC: four wrapper sessions with the
aligned TX trigger, candidates `000317Z`, `000817Z`, `001319Z`,
`001831Z` (240 s, 200 impulses at 64 frames, load 0.05, the
`servo-aligned` point).** Every session: `ALIGN status=ok attempts=1`
at 614-616 us, `ALIGN trigger status=ok source=fresh-wake` at the
commanded phase to 1-2 us (601, 602, 302, 851), `ring_at_prime` 432 in
all four (the USB capture's fill after the aligned start is
deterministic), zero restarts, zero clips, every impulse on one sample,
score 1.000, `tx_pullmax` 48.

| session | trigger offset | samples | ms | tx_qfloor | rx_qfloor |
|---|---:|---:|---:|---:|---:|
| 1 | 600 | 1339 | 27.896 | 210 | 109 |
| 2 | 600 | 1350 | 28.125 | 216 | 109 |
| 3 | 300 | 1349 | 28.104 | 216 | 96 |
| 4 | 850 | 1299 | 27.062 | 160 | 96 |

**The trigger's phase inside a tick is not the lever; the model was
wrong and the driver source says why.** The tick that follows the
trigger copies ALSA position 0 whatever the trigger's phase inside that
tick, so moving the trigger from 300 to 600 us changes nothing (1349
against 1339/1350), and a later trigger only changes *which* tick comes
first: at 850 us the session read one lap lower (1299, 40-51 under the
others) with its TX floor one period lower (160 against 210-216), the
level and the floor moving together. The 300/600 pair is not
sample-exact either: 1339, 1350, 1349, an 11-sample residual that the
aligned trigger did not touch. What sets the TX playout is the age of
the ring's front frame at the first tick after the trigger, and that age
is the prime instant (a USB capture wake, whose phase against the tick
grid is a per-session draw of one tick) plus the wait to that tick; the
aligned trigger made the trigger's phase a constant and left the prime's
where it was, so the draw survived, with a lap flip added at the
offset's edge. Note the level with the trigger on (1299-1350) sits 50-100
samples under the accepted profile's 1400-1453 window for a reason the
record does not yet hold; the recovered session's 1320 is in the same
band. Observation; not explained.

**IMPLEMENTED, staged, not installed: the aligned TX prime, bridge
`40bec748`.** `--align-tx-prime 0|1` (default 0, needs
`--align-tx-trigger 1`). With it on, the TX prime (at start and after a
TX recovery) holds until the ring holds `prime + longest wait - shortest
wait` (468 at this point, so the 480 fill), computes the trigger target
(`next_aligned_time` from the grid, 200 us ahead to cover the prime's
own rendering) and the first tick after it, and drops from the ring's
front `ring + wait - (prime + longest wait)` frames, so the front
frame's age at that first tick is `prime_frames + longest wait` = 419 +
70 = 489 frames whatever this session's wait (450-1450 us at offset
600). The trigger then sleeps to the same target. Deterministic by
construction at the top of the present draw band (about +10 samples on
the 600 us sessions' mean), which is the stability-first trade the sink
delay already made. **With the flag off the prime is byte-for-byte the
previous behaviour but PRIMED now carries the instrument:**
`align_dropped prime_phase_us first_tick_wait_us front_age_frames
capture_wake_age_us`, so a flag-off session logs the wait the model says
its level follows; SUMMARY gains `align_tx_prime`,
`align_tx_prime_dropped`, `align_tx_prime_phase_us`,
`align_tx_first_tick_wait_us`, `align_tx_front_age_frames`. Built on
the Pi in `phase4-align5-src` with the service stopped and no run
measuring, clean under `-Werror`, ctest clean on both, the two invalid
combinations refused. Wrapper `009e3b75` (positional 20
`align_tx_prime`, `USB16X16_PHASE4_ALIGN_TX_PRIME` on the Mac side),
supervisor `fe49f406` (`ALIGN_TX_PRIME`, absent = 0), conf `2029ef8f`
(`servo-aligned-both` now carries `ALIGN_TX_PRIME=1`; `59a23d5e` joins
the unedited-shipped list), `install-candidate.sh` `647bdd32`,
`install-aes67-service.sh` `62d279b7`. Staged in
`~/usb-16x16-work/phase4-align5-install/`, install order as before.

Measurement plan after the install: (1) two sessions with the trigger
on and the prime **off**: the instrument alone; the levels must follow
`first_tick_wait_us` (48 samples per ms) and `front_age_frames`, which
tests the model before the fix is trusted; (2) three sessions with the
prime on at 600 us: `front_age_frames` 489 every time and the level the
same to a few samples; the residual 11 is then whatever is left on the
USB side or the Ferrofish; (3) four loaded 800-impulse runs for
acceptance and `switch-profile servo-aligned-both`.

**INSTALLED 2026-09-03 about 20:45 local by the user: bridge `40bec748`,
wrapper `009e3b75`, supervisor `fe49f406`, conf `2029ef8f`.** The
service installer started the service; the user stopped it again for the
sessions (the candidate wrapper refuses over the daemon, and the first
launch did: "aes67-daemon is already running").

**MEASURED 2026-09-04 00:40-01:05 UTC: five wrapper sessions on bridge
`40bec748`, trigger at 600 us, 240 s, 200 impulses, load 0.05.**

| session | prime | candidate | prime phase | first-tick wait | dropped | front age | samples | ms | tx_qfloor |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|
| 1 | off | `004023Z` | 542 us (derived) | 1443 us (derived) | 0 | 501 (derived) | 1345 | 28.021 | 216 |
| 2 | off | `004522Z` | 587 us (derived) | 1398 us (derived) | 0 | 499 (derived) | 1344 | 28.000 | 216 |
| 3 | on | `005023Z` | 562 us | 1437 us | 52 | 496 | 1339 | 27.896 | 206 |
| 4 | on | `005523Z` | 650 us | 1349 us | 48 | 496 | 1330 | 27.708 | 206 |
| 5 | on | `010023Z` | 596 us | 1401 us | 51 | 496 | 1339 (199), 1331 (1) | 27.896 | 205 |

Every session: aligned start on attempt 1 at 614-617 us, trigger at
601-603 us, zero restarts, zero clips, `tx_pullmax` 48, score 0.997-1.000.

**Instrument defect in `40bec748`:** with the prime flag off the PRIMED
line prints `prime_phase_us=-1 first_tick_wait_us=-1 front_age_frames=-1`;
the fields are only computed inside the flag's branch, so the claim above
that a flag-off session logs the instrument is wrong. The flag-off values
in the table are derived from the logged times instead: the reference
wake is the trigger's `t_us` minus its `wake_age_us`, the first tick after
the trigger is that wake plus 2000 us minus the 15 us wake latency, and
the wait is that minus the PRIMED `t_us`. A source fix (compute the
fields whenever the grid is known, drop only with the flag) was written,
passed the core tests, and was reverted unbuilt so the repo matches the
installed binary; it is a five-line change for the next build.

**The model holds on all six trigger-on sessions and the drop does what
it was built to do.** Sessions 1 and 2 (prime off) differ by 45 us of
wait and 1 sample; the prime-on sessions held `front_age_frames` at 496
against waits of 1349-1437 us by dropping 48-52 frames, and read 1339,
1330, 1339 where the age arithmetic predicts about 5 samples under the
prime-off pair (1344-1345): measured 1339. The earlier four trigger
sessions fit the same arithmetic: the prime lands 540-650 us after its
reference wake in every session (it is the USB fill after the aligned
start, not a uniform draw), so at trigger offsets 300 and 600 the first
tick is the same tick and the level the same (1339-1350), and at 850 the
trigger catches the tick before it, one lap lower (1299).

**What is left: the 8-sample bimodality, not a draw.** Session 5 put 199
impulses on 1339 and one on 1331; sessions 3 and 4 sat on 1339 and 1330
with the same front age. That is the 8-9 sample bimodality the readiness
limit already allows for at buffer 192 (`USB16X16_READY_MAX_SPREAD_SAMPLES`
9), on the USB or Mac side, and it is the whole residual: three prime-on
sessions span 9 samples against 53 for seven aligned-start sessions and
216 lap-structured at 576. Acceptance runs follow on the installed
binary and the `servo-aligned-both` profile as installed.

**ACCEPTED 2026-09-04 01:05-01:50 UTC: profile `servo-aligned-both`**
(period 48, target 128, primes 288/144, RAVENNA playback 384, USB pitch
servo mode 1, aligned RAVENNA capture start at 600 us, aligned TX
trigger at 600 us, aligned TX prime, sink delay 96), on four loaded
800-impulse runs of 600 s at 64 frames on the installed bridge
`40bec748`:

| run | candidate | prime phase | first-tick wait | dropped | front age | samples | ms | tx_qfloor | rx_qfloor |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | `010528Z` | 447 us | 1552 us | 58 | 496 | 1333 | 27.771 | 206 | 96 |
| 2 | `011641Z` | 426 us | 1571 us | 59 | 496 | 1324 | 27.583 | 201 | 96 |
| 3 | `012754Z` | 660 us | 1339 us | 48 | 496 | 1321 | 27.521 | 207 | 109 |
| 4 | `013907Z` | 422 us | 1577 us | 59 | 496 | 1318 | 27.458 | 205 | 96 |

Every impulse on one sample in every run, score 1.000, zero restarts,
zero clips, zero pitch write errors, `tx_pullmax` 48, worst gaps
1.0/1.8 ms, aligned start on attempt 1 at 615-617 us, trigger at 602 us,
pitch 1000014-1000015. TX floor 201-207 over the 144-frame skip bar. It
is 1.7-2.0 ms under the accepted `servo-aligned` (1400-1453) with the
front-frame age at the first tick held at 496 frames by construction
against waits of 1339-1577 us. Conf `ea9158ab` marks the block accepted
(STATUS, COVER, MEASURED; `2029ef8f` joins the unedited-shipped list;
`install-aes67-service.sh` `75a024c7`); `PROFILE=servo-aligned` is
unchanged in the conf, so the switch is a `switch-profile` after the
conf install. Staged in `phase4-align5-install/`.

**Two observations on the residual, recorded, not explained.** (1) The
seven prime-on sessions read 1339, 1330, 1339, 1333, 1324, 1321, 1318:
every one is 1 mod 3, a 3-sample grid (62.5 us at 48 kHz, half a
high-speed microframe), six steps wide, and no session with the age
pinned has landed off it. (2) They fall with wall-clock time: 1339 at
00:50, 1318 at 01:39 UTC, 21 samples in 50 minutes, with the age, the
floors and the pitch unchanged; the earlier `servo-aligned` acceptance
runs went 1416, 1421, 1416, 1400 over 45 minutes, a similar drift. The
term is set at session start on the USB or Mac side (the level is fixed
inside a session to the sample) and moves between sessions on a slow
clock; the harness's own device open is a candidate, so is the Mac's
CoreAudio cycle phase against the USB frame grid. A run of sessions
with the Mac-side device held open, or the same session measured twice
an hour apart under the service, would separate the two.

**Standard changed by the user 2026-09-04: RTL Utility at 32 CoreAudio
frames is the reference measurement going forward.** The user reports
30.542 ms round trip with it on the running service. RTL at 32 reads the
harness's sample count plus the Mac-side cost of 188 samples (3.9 ms);
at 64 the cost was 252. All figures above this line are the harness at
64 frames; a harness run at 32 frames (`--buffer-frames 32`,
`measure-under-service.sh 32 800`) is 64 samples (1.33 ms) under the
same run at 64, and about 3.9 ms under RTL at 32. Quote which.

**Next lever, chosen by the user: the TX prime**, 288 to 240 first, on
the record's own arithmetic (TX floor 201-207 over the 144-frame skip
bar; `tx_pullmax` 48 in every period-48 run). The user sets it and
observes it himself before a session tests it.

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

**ACCEPTED 2026-09-04 02:23-02:57 UTC: profile `servo-aligned-both-240`**
(servo-aligned-both with `TX_PLAYBACK_PRIME=240`, one variable), on four
loaded 800-impulse runs in one service session on the installed bridge
`40bec748`, no stack restart between runs. The user added the block to
the live conf and ran `switch-profile servo-aligned-both-240` himself at
about 02:20 UTC and read RTL Utility at 32 frames at 29.292 ms (30.542 on
`servo-aligned-both`, 60 samples less). The session's PRIMED line: TX
`queue_prime=240 align_dropped=48 prime_phase_us=650
first_tick_wait_us=1347 front_age_frames=448` (496 minus the 48 the
prime gave up, as predicted); aligned start on attempt 1 at 616 us,
trigger at 602 us.

| run | file | frames | samples | ms | levels | score | tx_qfloor | rx_qfloor | tx_pullmax | RECOVERs |
|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|
| 1 | `both240-roundtrip-32f-20260904T022331Z` | 32 | 1210 | 25.208 | 1210 x641, 1218 x159 | 0.446 | 159 | 96 | 48 | 0 |
| 2 | `both240-roundtrip-64f-20260904T024546Z` | 64 | 1218 | 25.375 | 1218 x800 | 1.000 | 159 | 96 | 48 | 0 |
| 3 | `both240-roundtrip-64f-20260904T024926Z` | 64 | 1218 | 25.375 | 1218 x800 | 1.000 | 159 | 96 | 48 | 0 |
| 4 | `both240-roundtrip-64f-20260904T025306Z` | 64 | 1218 | 25.375 | 1218 x800 | 1.000 | 159 | 96 | 48 | 0 |

Zero restarts, zero clips, worst gaps 1.1/1.8 ms, pitch 1000014-1000018,
`tx_pullmax` 48 throughout. The TX floor read 205 unloaded (the same
201-207 band as prime 288) and fell to 159 in the first minute of the
first loaded run, 15 frames over the 144-frame skip bar, and held there
for the rest of the session; the handoff's arithmetic (153-159) was for
the loaded floor. Conf `81e8c092` carries the block as accepted (`ea9158ab`
joins the unedited-shipped list, installer `fb0eff86`); staged on the Pi
in `~/usb-16x16-work/phase4-prime240-install/` with the installed bridge
and the unchanged unit and supervisor. `PROFILE=servo-aligned` is
unchanged in the shipped conf, as before. The live conf is
operator-edited (it carries the experimental block the user pasted), so
the installer will keep it and write the shipped one to
`/etc/usb16x16/aes67.conf.new`; the running profile is unaffected by the
install either way. 192 is not on the table until a skip counter over
hours of service time shows no pull above 48 at period 48.

**Correction: the harness level does not depend on `--buffer-frames`.**
The line above that says a run at 32 frames is 64 samples under the same
run at 64 is wrong. The harness works in device sample time: on
2026-09-02 runs at 32 and 64 both read 1423, and on 2026-09-04 probes at
32, 48, 64, 96 and 512 all read 1210-1218 on this profile. Run 1 at 32
and runs 2-4 at 64 are the same measurement. RTL at 32 reads roughly
harness + 190 samples (29.292 ms = 1406 samples against 1210-1218).

**Level against `servo-aligned-both`, recorded, not explained.** The
accepted runs read 1318-1333 at 01:05-01:50 UTC; this profile reads
1210-1218 at 02:23-02:57, 100-123 samples lower, of which the prime
accounts for 48. RTL moved 60. The recorded session drift is about 20
samples an hour, which does not cover the rest. The 1210/1218 pair in run
1 is the 8-sample bimodality again, switching in runs of about four
impulses (about once a second) inside a probe; runs 2-4 sat on 1218 alone.

**Mac-side defect during the session, unexplained.** From 02:27 UTC the
harness at 32 frames captured digital silence (zero energy over a full
10 s probe, every channel pair), and the readiness gate failed 40 probes
in a row twice (runs 2 and 3 of the first chain); probes at 64, 96 and
512 passed intermittently at first and then reliably. The Pi was clean
throughout (zero RECOVERs, floor 159, UDC configured/high-speed). Quitting
RTL Utility, REAPER and iZotope RX changed nothing. RTL Utility itself
had measured fine at 32 at about 02:17, and run 1 at 32 measured 800
impulses at 02:23-02:27. Runs 2-4 were therefore taken at 64 frames. A
run at 64 takes about 3.6 minutes (800 impulses at 250 ms), not 10.

**Within-session drift measured 2026-09-04: none.** Two more 800-impulse
runs at 64 frames on the same `servo-aligned-both-240` session, no
restart, one hour apart: `both240drift-roundtrip-64f-20260904T031550Z`
median 1218 (1218 x690, 1210 x110) and `...T041926Z` median 1218 (1218
x571, 1210 x229), both zero RECOVERs, `tx_qfloor` 159, `rx_qfloor` 96,
`tx_pullmax` 48. With run 1 at 02:23 (1210 x641, 1218 x159) and runs 2-4
(1218 x800), the session's level has not moved in two hours; the only
thing that moves is the share of impulses on each side of the 8-sample
pair. The 20-samples-an-hour figure recorded earlier is therefore a
between-session term, set at the session start (bridge start or the
harness's own device open), not a clock drifting while a session runs.
The unexplained 60 of the 100-123 drop against `servo-aligned-both` is
of that kind too. Service time on this profile at 04:23 UTC: two hours,
zero RECOVERs, `tx_pullmax` 48 (the pull watch for prime 192 continues
from here).

**ACCEPTED 2026-09-04 10:52-11:07 UTC: profile `servo-aligned-both-240-rx120`**
(servo-aligned-both-240 with `RX_PLAYBACK_PRIME=120`, one variable), on
four loaded 800-impulse runs at 64 frames in one service session on the
installed bridge `40bec748`, no stack restart between runs. The user
appended the block to the live conf at 10:43 UTC and ran `switch-profile
servo-aligned-both-240-rx120` at 10:47; the service came up on attempt 1
(ALIGN ok at 618 us, TX trigger ok at 602 us). The session's PRIMED lines:
RX `queue_prime=120 intended=251 ring_at_prime=288 overshoot=37
front_age_frames=-1` (the flag-off instrument, fix still unbuilt); TX
`queue_prime=240 align_dropped=58 overshoot=3 prime_phase_us=453
front_age_frames=448`.

| run | file | frames | samples | ms | levels | tx_qfloor | rx_qfloor | tx_pullmax | RECOVERs |
|---|---|---:|---:|---:|---|---:|---:|---:|---:|
| 1 | `both240rx120-roundtrip-64f-20260904T105221Z` | 64 | 1168 | 24.333 | 1164 x400, 1172 x400 | 158 | 96 | 48 | 0 |
| 2 | `both240rx120-roundtrip-64f-20260904T105601Z` | 64 | 1168 | 24.333 | 1164 x400, 1172 x400 | 154 | 96 | 48 | 0 |
| 3 | `both240rx120-roundtrip-64f-20260904T105941Z` | 64 | 1168 | 24.333 | 1164 x400, 1172 x400 | 152 | 96 | 48 | 0 |
| 4 | `both240rx120-roundtrip-64f-20260904T110322Z` | 64 | 1168 | 24.333 | 1164 x400, 1172 x400 | 150 | 96 | 48 | 0 |

Zero restarts, zero clips, zero discontinuities, worst gaps 1.06/1.63 ms,
pitch 1000014-1000016, `tx_pullmax` 48 throughout (pull histogram
4127148/1193112/0/0/0/0). RTL Utility at 64 frames read 29.667 ms against
30.625 on `servo-aligned-both-240` a few minutes earlier (RTL at 32 errored
on the Mac both times; 30.625 at 64 is 29.292 at 32 plus the 64 samples
the buffer adds, to the digit). Conf `2fa48cb6` carries the block as
accepted (`81e8c092` joins the unedited-shipped list, installer
`3edf5f40`); staged on the Pi in `~/usb-16x16-work/phase4-rx120-install/`
with the installed bridge, unit and supervisor (all three byte-identical
to what is installed). The live conf is operator-edited (it carries the
two pasted blocks, hash `001b0d20`), so the installer will keep it and
write the shipped one to `/etc/usb16x16/aes67.conf.new`. `PROFILE=` in the
shipped conf is unchanged.

**Three things the runs said that the prediction did not.**

1. *The level moved 50 samples, not 24.* 1218 to 1168 on the harness, 46
   samples (0.958 ms) on RTL at 64. The prime change was 24 frames. The
   other 24-26 are unexplained; they are of the same size as the
   unexplained 60 in the 240 acceptance and may be the same session-start
   term.
2. *`rx_qfloor` did not move.* 96 loaded and unloaded, the same as at prime
   144, while `rx_queue` at 1 Hz dropped by exactly 24 (192 to 168). The
   RX floor is set by something other than the prime, so the change took
   0.5 ms of latency and cost no RX margin. `rx_pullmax` 96 as before.
3. *The TX floor is 8-9 frames lower than the night before and still
   falling slowly.* 158 unloaded at four minutes, then 154, 152, 150 at
   the end of each loaded run (a running minimum), 6 over the 144 bar at
   the end. The TX side is nominally untouched by this change; what
   differs is `align_dropped=58` against 48 in the 240 session: the
   aligned TX prime gave up 10 more frames at start, and the floor sits
   about that much lower (159 minus 10 is 149). The align drop is a
   session-start variable, so the TX margin over the bar is set at each
   start and is thin on this session. Check `tx_qfloor` before relying
   on this profile after any restart; if a session starts with
   `align_dropped` much over 58 the floor will sit at the bar.

**The 1164/1172 pair alternates impulse by impulse.** (Corrected below,
"USB drops at small IO sizes": the pair is dropped audio, not a harness
phase; 1172 is the level and 1164 marks a lost impulse. The paragraph is
kept as written.) All 800 impulses in all four runs went a, b, a, b
with no run longer than one. The 250 ms impulse spacing is 12000 samples,
187.5 buffers of 64, so successive impulses land on opposite half-buffer
phases; the 8-sample pair is the two phases quantizing to different
levels. Last night's drift runs at 64 already showed the same strict
alternation in stretches, mixed with stretches on 1218 alone (both phases
on one level), and the 32-frame run switched in runs of 3-43. The median
of an even split is the midpoint, 1168, which is on the 3-sample grid
only by accident (1164 and 1172 are 8 apart, 1168 is not on the 1210/1218
grid). Compare profiles by the pair's midpoint or by RTL, not by which
side of the pair a run lands on.

`tx_pullmax` read 48 at 8 h 05 min of service time on `servo-aligned-both-240`
(10:25 UTC, pull histogram 90940284/29098162/0/0/0/0) before the switch;
the pull watch for TX prime 192 restarts from the 10:47 session start.

**FOUND 2026-09-04 11:15-12:05 UTC: the Mac's USB audio path drops
isochronous data at CoreAudio IO sizes of 64 frames and below, and the
fix is the gadget's request depth.** Chasing "RTL Utility errors at 32
frames" with the harness patched to dump its raw capture
(`USB16X16_DUMP=path`, `USB16X16_IMPULSE_LEN=n`, and a `diag:` line on
stderr; committed with this entry). With deterministic noise on channel 2
(`--other-channel-load-amplitude 0.1`, captured on channel 2) the returned
stream matched the generator sample for sample where present, with no
timing shift, and was exact zeros elsewhere. On the installed gadget
(`req_number=2`), with the bridge clean and the music paused, 100-impulse
probes read:

| frames | zeros in the returned stream | zero runs |
|---:|---:|---|
| 512 | 0.0% | none in 26 s |
| 128 | 0.0% | none in 26 s |
| 64 | 75.0% | 32-55 samples, one per 64, phase-stable |
| 32 | 86.9% | about 331 samples |

The same 64-sample periodicity showed at 64, 128 (earlier, with RTL
Utility open at 32), 256 and 512, so it is the device's running IO size
that matters, not the probe's; the user heard the outgoing music break up
while RTL Utility held the device at 32 and heard it clean the moment it
was quit. macOS logs nothing (coreaudiod is not in the unified log); the
Pi logs nothing (zero RECOVERs, all four PCMs running, PTP locked, jitter
6). The daemon's sink flags read sticky `rtp_seq_id_error`,
`rtp_sac_error` and `all_muted` on both sinks throughout; as the record
says, they gate nothing.

*What the harness had been reporting.* The correlator's peak search
radius is 8. An impulse that never returns leaves an all-zero window and
the per-impulse delay comes out as the true lag minus 8. Impulses are
12000 samples apart, 32 modulo 64, so successive impulses alternate
between the live and dead halves of the 64-sample cycle. Every "8-sample
pair" since 2026-09-04 02:23 UTC was this: 1218 real / 1210 lost, 1172
real / 1164 lost. Fraction of impulses lost per run: servo-aligned-both
00:55-01:39 UTC six runs 0%; both240 02:23 (32 frames) 80%; both240
02:45-02:53 0%; drift pair 13% and 28%; rx120 10:52-11:07 50% in each of
four. The medians, 1218 and 1168, and "zero spread" claims for the
alternating runs are therefore wrong by 0-8 samples; the levels stand as
the upper value of each pair. The servo-aligned-both acceptance was the
last one measured on a clean loop. The harness now prints a `diag:` line
with `rawInputPeak`, `copiedFrames`, `placementMisses` and the marker
indices on every run; a run whose levels split 8 apart is a dropped-audio
run, not a bimodal one.

*The lever.* The UAC2 function was bound with `req_number=2` (the kernel
default) and `p_hs_bint=c_hs_bint=0` (auto). dwc2 debugfs shows the
streaming endpoints at 624-byte packets, 13 frames of 16 x 24-bit, a
250 us interval, so two queued requests were 500 us of slack per
direction against the host's scheduling. The user stopped the AES67
service and the gadget unit and rebound the gadget from
`~/usb-16x16-work/gadget-req4/setup-usb-16x16-req start 4`, a copy of the
installed script (`d3031e22`, identical to the protected baseline) that
takes the request count as its second argument (copy in
`work/pi-tuning/setup-usb-16x16-req`, hash `b11fd358`). The supervisor
then waited on `systemctl is-active usb-16x16.service`, which a hand-bound
gadget does not satisfy; a runtime drop-in
`/run/systemd/system/usb-16x16.service.d/req4.conf` (`ExecStart=` reset
to the staged script with `start 4`) and `systemctl start usb-16x16`
cleared it. That drop-in is what holds `req_number=4` now; a reboot
returns to the installed script and 2.

| frames | req 2 | req 4 |
|---:|---:|---:|
| 512 | 0.0% | 0.0% |
| 128 | 0.0% | 0.0% |
| 64 | 75.0% | 0.02% (five 41-sample runs in 1.24 M samples) |
| 32 | 86.9% | 0.0% |
| 16 | not run | 0.0% |

Impulse probes on channel 1 at 512, 64 and 32 with req 4: 1314 samples
(27.375 ms) on every one of 300 impulses, no phantoms; RTL Utility at 32
read 31.292 ms and 16-frame runs completed. Pi: zero RECOVERs,
`tx_qfloor` 160-167, `rx_qfloor` 96, `tx_pullmax` 48, pitch 1000015.
The user chose to keep 4 (12:05 UTC).

*The cost.* About 150 samples: the clean-loop level on
`servo-aligned-both-240-rx120` was 1159-1172 with req 2 and is 1314 with
req 4, and RTL at 32 is 31.292 against an expected 28.1. Two extra
250 us requests per direction account for about 1 ms of that; the rest is
unexplained. The bridge's queues did not change. Next levers, each one
stop/rebind/start: `req_number=3` to see whether the latency scales per
request and 32 stays clean; `req_number=8` to see whether the five
residual holes at 64 go; an explicit `p_hs_bint`/`c_hs_bint` of 1
(125 us packets, 6 frames) with 4 requests for the same slack at half the
queued time. Every future harness gate should be preceded by one noise
probe (`--input-channel 2 --other-channel-load-amplitude 0.1`, the
`zeros.py` in `outputs/latency/usb-holes-20260904/`) reading 0.0% at the
gate's buffer size, and the gate itself can now run at 32 or 64; a level
split 8 apart means the loop is dropping again.

*Phase 5 and 6.* Neither addresses this. Phase 6 is Pi scheduling; Phase
5 changes the rate the host follows through the gadget's feedback, not the
request depth against host jitter, and it is measured with exactly the
64- and 32-frame runs this corrupted. Request depth first, clean loop
verified, then Phase 5.

The `servo-aligned-both-240-rx120` block's comment and MEASURED string
are corrected to say 1172 at req 2 and 1314 at req 4: conf `e6f91364`,
installer `20f7c719` (`2fa48cb6` joins the unedited-shipped list), staged
in `~/usb-16x16-work/phase4-rx120-record-install/` with the unchanged
bridge, unit and supervisor; a documentation-only install, whenever the
service is next stopped.

Made permanent 12:20 UTC: the user installed the staged script over
`/usr/local/sbin/setup-usb-16x16` (now `b11fd358`, root 755; its default
is 4 with no second argument) and removed the drop-in; the unit's
ExecStart is the plain `start`, so a reboot binds with 4. The original
script is `work/protected-baseline-2026-08-31/setup-usb-16x16`
(`d3031e22`) for rollback. Gadget at 4, service clean, no rebind was
needed.

**DEFERRED 2026-09-04 12:20 UTC: the req_number sweep.** Read at 12:16
UTC on the running service (bridge session since 11:54:56 UTC, gadget at
4, script `b11fd358`): `tx_pullmax` 48, `tx_qfloor` 160, `rx_qfloor` 96,
TX `align_dropped` 49, zero RECOVERs; RX PRIMED still prints
`front_age_frames -1`. The user chose to keep 4 and move on: the 150-sample
cost is a latency question, at most about 2 ms recoverable, and the only
accuracy residual is the five 41-sample holes at 64 frames (0.02%), which
can be re-checked without touching the gadget by one more channel-2 noise
probe at 64 on the running service; only if they recur is `req_number=8`
worth a stop. TX prime 192 waits on `tx_pullmax` reading 48 after a day.

If the sweep is run later, one variable per stop, in this order: 3, 8,
then 4 with `p_hs_bint=c_hs_bint=1`. The unit passes no second argument,
so the edit is the default in `REQ_NUMBER=${2:-4}` (line 17 of the
installed script); the bint edit flips the two `printf '%s\n' 0 >
"$F/[pc]_hs_bint"` lines (80 and 85). Per point: `sudo systemctl stop
usb16x16-aes67`, the edit, `sudo systemctl restart usb-16x16`, `sudo
systemctl start usb16x16-aes67`, confirm `req_number` and
`configured/high-speed`, wait for PRIMED, then noise probes at 512/64/32/16
(`USB16X16_DUMP=<raw> usb16x16-latency measure --device "USB 16x16"
--buffer-frames N --output-channel 1 --input-channel 2
--other-channel-load-amplitude 0.1 --impulses 100 --maximum-lag-ms 200`,
then `zeros.py <raw> N`), impulse probes on channel 1 at 64 and 32, and
the journal's `tx_qfloor`/`rx_qfloor`/`tx_pullmax`/RECOVERs. Rollback
copy of `b11fd358`: `~/usb-16x16-work/gadget-req4/setup-usb-16x16-req`.
The documentation-only conf install in
`~/usb-16x16-work/phase4-rx120-record-install/` still waits for the next
service stop.

**ACCEPTED 2026-09-04 12:31-12:47 UTC: `servo-aligned-both-240-rx120` on
the clean loop, gadget `req_number=4`.** The 10:52-11:07 UTC acceptance of
this profile was measured while the USB path dropped every second impulse,
so it was re-run on the same service session (bridge `40bec748`, session
since 11:54:56 UTC, TX `align_dropped=49`), no stack restart, harness
alone (`measure-under-service.sh 64 800 rx120req4`, the same arguments as
every acceptance since `servo-aligned-both`). Gate first: one channel-2
noise probe at 64 frames (`accept-noise-ch2-64f-100imp` in
`outputs/latency/usb-holes-20260904/`) read 0.0% zeros and no zero run of
4 or more in 1.24 M samples; the five 41-sample holes of the 11:58 UTC
probe did not recur, so `req_number=8` has nothing to fix.

| run | file | frames | samples | ms | levels | score | tx_qfloor | rx_qfloor | tx_pullmax | RECOVERs |
|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|
| 1 | `rx120req4-roundtrip-64f-20260904T123205Z` | 64 | 1314 | 27.375 | 1314 x800 | 1.000 | 160 | 96 | 48 | 0 |
| 2 | `rx120req4-roundtrip-64f-20260904T123549Z` | 64 | 1314 | 27.375 | 1314 x800 | 1.000 | 160 | 96 | 48 | 0 |
| 3 | `rx120req4-roundtrip-64f-20260904T123931Z` | 64 | 1314 | 27.375 | 1314 x800 | 1.000 | 160 | 96 | 48 | 0 |
| 4 | `rx120req4-roundtrip-64f-20260904T124319Z` | 64 | 1314 | 27.375 | 1314 x800 | 1.000 | 160 | 96 | 48 | 0 |

3200 impulses on one sample, zero spread, zero discontinuities, zero
restarts, zero clips, pitch 1000011-1000017 (1000015 modal), worst gaps
1.539/1.861 ms (session maxima, unchanged by the runs), `tx_pullmax` 48
with the pull histogram still all in the first two bins. The TX floor held
160 for the whole session (align_dropped 49, 16 over the 144 bar), against
150-158 on the align_dropped-58 session. This is the level the corrected
conf `e6f91364` already records (1314 at req 4, RTL at 32 31.292 ms), so
no further conf edit is needed.

**SOAKED 12:50-13:01 UTC, sixteen channels loaded.** `measure-under-service.sh`
gained an optional `USB16X16_OTHER_LOAD` (deterministic noise on the other
15 channels for the main run only; the readiness probes stay unloaded).
`USB16X16_OTHER_LOAD=0.1 measure-under-service.sh 64 2400 rx120req4soak`:
`rx120req4soak-roundtrip-64f-20260904T125026Z`, 600 s, 2400 impulses at
64 frames with channels 2-16 at 0.1, all 2400 on **1314 samples
(27.375 ms)**, spread 0, score 1.000, zero discontinuities, zero RECOVERs,
zero restarts, `tx_clip`/`rx_clip` 0, `tx_dropped`/`rx_dropped` 0,
`tx_qfloor` 160 and `rx_qfloor` 96 on all 66 telemetry lines in the
window, `tx_pullmax` 48, pitch 1000010-1000018 (1000015 modal). Checklist
item 9 is met for this operating point.

**Lever 1 verdict, read 2026-09-04 13:10 UTC: governor `performance` is
clean over 17.5 hours.** This boot (2026-09-03 23:22 UTC, governor set by
`usb16x16-governor.service` at 7 s) has three RECOVER lines, all in the
cold-boot cascade and the 23:39 UTC profile switch on 2026-09-03; none in
the four service sessions since (23:39 UTC yesterday through 13:10 UTC
today, restarts at 10:47, 11:13 and 11:47 UTC), which include the two
acceptances and the soak. IRQ affinity is still stock (`irq 34`
`1000480000.usb` and `irq 108` `eth0` on 0-3, both serviced on CPU 0 in
practice), so lever 2, `usb16x16-stall-tuning irqs pin` (both to CPU 1,
runtime only, `irqs unpin` reverts), is the next single variable, judged
the same way over hours of service time.

**DONE 2026-09-04 13:12-13:13 UTC by the user: documentation-only conf
install and lever 2, IRQ pinning.** With the service stopped he ran the
`phase4-rx120-record-install` installer: supervisor `fe49f406` and unit
`77837e60` reinstalled byte-identical, the live operator-edited conf
`001b0d20` kept, shipped `e6f91364` written to `/etc/usb16x16/aes67.conf.new`.
Service back at 13:13:25 UTC on `servo-aligned-both-240-rx120`, ALIGN ok
on attempt 1 at 600 us, TX PRIMED `align_dropped=55 prime_phase_us=510
first_tick_wait_us=1487 front_age_frames=448`, RX `front_age_frames=-1`
as before. Then `usb16x16-stall-tuning irqs pin`: `irq 34`
(`1000480000.usb`) and `irq 108` (`eth0`) now on CPU 1 and their CPU 1
counters climbing (1.7 M and 270 k at 13:20 UTC), governor `performance`,
gadget `req_number=4`. Judge by RECOVERs over hours of service; `irqs
unpin` reverts.

Probes on the pinned session (`irqpin-*` in `usb-holes-20260904/`):
channel-1 impulses at 64 read **1287 samples (26.812 ms)** on all 100,
which is 27 under the 1314 of the 11:54 session with `align_dropped` 55
against 49; the session-start term again, 1287-1314 is the band for this
profile at req 4. Noise probes: 64 at 13:16 UTC one 41-sample zero run at
3.6 s into the capture (0.003%); 64 again at 13:19 and 32 at 13:20 clean.

*The 41-sample hole is a session-start event, not a lever effect.* Every
hole seen so far is exactly 41 samples and falls in the first minutes of
a bridge session: five at 11:58 UTC (session 11:54), one at 13:16 (session
13:13, before and after the pin the counters are the same); none at 12:31
(37 min in), none at 13:19-13:20, none across the 600 s soak. The bridge
reports `tx_dropped`/`rx_dropped`/`tx_qlow`/`rx_qlow` 0 throughout and
the pitch servo is still converging in those minutes (1000021 at 13:15
falling to 1000015 by 13:17). `gaps2.py` on the 13:16 dump: the 41 samples are
zero-substituted in place, the generator realigns after the run with a
delta change of 0, so audio was lost and silence put in its place with no
timing shift, the same signature as the req 2 drops at 64, at a far lower
rate. That points at the USB path in the session's first minutes (the
pitch servo is still moving the feedback rate then), not at the bridge's
queues. 41 samples is not a multiple of the 13-frame packet. Tested 15:33-15:44 UTC on a
fresh session (restart by the user at 15:32 UTC, same profile, pin still
on, ALIGN ok attempt 1, TX `align_dropped=53`): 64-frame noise probes at
+60 s, +300 s and +600 s after PRIMED (`start60s-`, `start300s-`,
`start600s-noise-ch2-64f-100imp`) all read 0.0% with no zero run at all.
So the holes are not a session-start effect. Tally so far: 6 holes in
10 probes of 26 s each, clustered (five in one probe, one in another,
none in the other eight), all exactly 41 samples, all at 64 frames, none
at 32/16/512, none seen by the impulse runs or the soak. Sporadic and
unexplained; the Mac side is the open suspect since the Pi's counters
never move. `req_number=8` remains the only lever with a mechanism behind
it, untested. Session telemetry at +10 min: `tx_qfloor` 153, `rx_qfloor`
96, `tx_pullmax` 48, pitch 1000019, zero RECOVERs; the pull watch and the
lever-2 clock restart from 15:33 UTC.

**FOUND 2026-09-04 15:50-16:00 UTC: the 41-sample holes sit on the Pi's
48-frame grid, not on the USB packet grid.** Campaign on the 15:33 UTC
session (`camp64-1..5`, `camp128-1..5`, `drop1`, each a 26 s channel-2
noise probe): at 64 frames one hole in 130 s, at 128 frames three holes
in 130 s, all exactly 41 samples, so the holes are not an IO-size effect
(128 was clean in every earlier probe by chance). Timestamps: 15:54:53.640
UTC (64 frames) and 15:55:36.147/.151/.156 UTC (128 frames, three holes
whose starts are 192 and 240 samples apart). Every hole in a session
starts at the same phase on the 48-sample grid relative to the loop's
return point (offset 29 for all four holes of this session, offset 10 for
the 13:16 hole of the previous session) while the phase on the 13-frame
USB packet grid is random (3, 4, 5, 2, 8). A fixed 48-frame phase per
bridge session is the bridge period and the RAVENNA packet; the Mac's
isochronous scheduling has no 1 ms grid. So the zeros are made on the
Pi side of the loop and `req_number` is not the lever; it never was for
these.

What the Pi shows at those instants: nothing. Bridge `tx_dropped`,
`rx_dropped`, `tx_qlow`, `rx_qlow` 0, restarts 0, gap maxima unchanged,
floors 153/96, no journal line from any unit within 15 s of either
instant, no ssh login within 59 s. `eth0` `rx_dropped` climbs at about
0.5/s all the time (29935 at 16:00 UTC over 16.6 h, 14 in a 27 s probe
that had no hole), so it is background, not the signal; `rx_missed`,
`rx_over`, `rx_fifo`, softnet drops all 0. Sink flags are the sticky
`rtp_seq_id_error`/`rtp_sac_error`/`all_muted` as always. The Mac's
unified log around the 13:15:43.8 UTC hole has nothing from
`usbaudiod`, `AppleUSBAudio` or `IOUSBHost` beyond the routine 2 s
microframe calibration lines, and coreaudiod's RTAID lines are periodic
RMS reports, not glitch reports.

Working hypothesis: a late RTP packet concealed as silence by the
RAVENNA driver (a 48-frame packet arriving about 41 samples, 0.85 ms,
after its playout point leaves 41 zeros and 7 real samples), on either
leg of the Ferrofish loop; three holes 4-5 ms apart would be one late
burst. 41 is constant across sessions and IO sizes, which fits a fixed
receive window better than random jitter. The Ferrofish's own late-packet
counter and peak (it read zero late over 12:22 with a 1.4 ms peak at a
2 ms receive setting on 2026-09-02) is the cheapest check and is the
user's to read. On the Pi the next instrument is a bridge-side zero-run
detector on the RAVENNA capture and on the USB capture, which would name
the leg; it is a build, so it waits for a service stop. Until then the
holes are a 0.003-0.01% concealment residual, inaudible on the loop
tests, and not a stability matter.

*Inbound leg cleared 16:20-16:29 UTC.* The user opened Dante Controller's
Latency tab for FF-PULSE-16-DX (streams 239.69.16.1 and .2 at the 2 ms
receive setting) while twenty back-to-back 64-frame noise probes ran
(`ff-01..20`, 520 s). One hole, 41 samples, at 16:25:48.185 UTC in
`ff-14`, phase 29 on the 48 grid like every other hole of this session.
The Ferrofish read late 0 on both streams across the window, peak 1.3 ms
against average 1.2 ms, so no packet from the Pi arrived even 0.1 ms off
its mean. The zeros are therefore made on the return leg or inside the
Pi: the Ferrofish's transmit, the switch, the RAVENNA driver's receive
(sink delay 576, so a 0.85 ms late packet would not be late there
either), or the bridge's own ravenna-to-usb path. A bridge-side zero-run
detector on the RAVENNA capture, with a matching one on the USB capture,
names the point where the zeros first appear; that is the next build.
Rate in this session: 6 holes in 1030 s of probing, about one per 3 min,
in bursts.

**IMPLEMENTED, staged, not installed: the zero-run detector, bridge
`b65b84ee`.** `--zero-run-detect 0|1` (default 0), `--zero-run-min N`
(default 8) and `--zero-run-max N` (default 480, at most 48000; the two
lengths need detect 1). With it on, the block read from each capture
(`usb-capture`, `ravenna-capture`) and the block written to each playback
(`ravenna-playback`, `usb-playback`) is scanned per channel for runs of
exact zeros. A run that ends with a length inside the window is one
`ZERORUN` line on stderr: `stage direction start length channels nchan
start_mod48 events t_us utc`. Channels whose runs share a start and a
length are coalesced into one line with a mask (an all-channel hole is one
line, `channels=0xffff nchan=16`); runs longer than the maximum are
silence, counted as `long_runs` and not reported; an undriven channel
never reports; a direction restart forgets its open runs. The audio path
is byte-for-byte the previous behaviour with the flag off or on; the cost
is one float compare per sample at the four points. BRIDGE gains
`zr_usbcap zr_ravplay zr_ravcap zr_usbplay`, each
events/frames/longest/long_runs; SUMMARY the same as `zero_usb_capture`
and so on, plus `zero_run_detect`, `zero_run_min`, `zero_run_max`,
`zero_run_lines` (cap 4096 per direction), `zero_run_lines_suppressed`
and `zero_run_dropped_events` (an 8-event queue per stage; a drop is
counted, never blocks). `start` is the direction's cumulative frame count
(input frames for a capture, output frames for a playback), so
`start_mod48` is the hole's phase on the bridge's own 48-grid, a
per-session constant if the holes sit on the packet grid as the Mac-side
analysis says; `utc` is `CLOCK_REALTIME` at the line, so a hole sets
beside the Mac's dump stamps without the journal. Reading the stages: a
hole at `ravenna-capture` (and then `usb-playback`) but not `usb-capture`
is made on the return leg before the Pi, the Ferrofish's transmit, the
switch or the driver's receive; at `usb-playback` only, in the bridge's
ravenna-to-usb path; at neither while the Mac sees it, on the USB
playback gadget or the Mac. Core tests add seven cases (a 41-frame hole
split across two reads, the window edges, coalescing against a shorter
run ending on the same frame, reset, queue overflow, one driven channel);
ctest clean on the Mac (clang 21) and the Pi (gcc 14, `-Werror`); the two
invalid flag combinations refused. Wrapper `6282b108` (positional 21
`zero_run_detect`, `USB16X16_PHASE4_ZERO_RUN_DETECT` on the Mac side),
supervisor `5c3c4004` (`ZERO_RUN_DETECT`, absent = 0, shown by
`profiles`), conf `85ccc0fe` (`servo-aligned-both-240-rx120` carries
`ZERO_RUN_DETECT=1`; `e6f91364` joins the unedited-shipped list), unit
unchanged `77837e60`, `install-candidate.sh` `64ef9da0`,
`install-aes67-service.sh` `cf6222bc`. The live conf `001b0d20` is
operator-edited, so the installer will keep it and write the shipped one
to `aes67.conf.new`: for the detector to run under the service, add
`PROFILE_SERVO_ALIGNED_BOTH_240_RX120_ZERO_RUN_DETECT=1` to the live
block by hand (absent means off). Source in
`~/usb-16x16-work/phase4-zerorun-src/`, staged in
`~/usb-16x16-work/phase4-zerorun-install/`, hashes verified there;
install order as before, with the service stopped: `install-candidate.sh`
then `install-aes67-service.sh`.

**Build incident 19:47 UTC, and a rule.** The bridge was built on the Pi
with the service running, `nice -n 19 taskset -c 0`, one job, against the
convention of building with the service stopped. The first attempt
(19:47:01-11 UTC) failed on GCC's `-Wformat-truncation`, which clang had
not raised. At 19:47:27, sixteen seconds after it ended, both captures
XRUNned together (RECOVER `capture-avail` on both, `last_gap_us` 3550 on
rx, `rx_gapmax_us` 3550, `tx_gapmax_us` 3009), three RECOVER pairs by
19:47:33, eight inside the minute, and the supervisor restarted the stack
at 19:47:34; the new session was running at 19:48:37 UTC with zero
RECOVERs since and the IRQ pinning still in place (irq 34 and 108 on CPU
1). The second build (19:47:41-46) ran during the restart. That was the
first RECOVER in the 4.2 h session and in the whole lever-2 window, so a
build-induced stall is the likely reading (990 MB of RAM, about 480 MB
available, a g++ run on the 2000-line `main.cpp` is enough to force
reclaim) though not proven; the lever-2 judgment restarts from 19:48:37
UTC. Rule from here: no builds on the Pi while the service runs, whatever
the nice level; syntax-check on the Mac first (the Pi's ALSA headers plus
stubs for `endian.h`, `clock_nanosleep`, `TIMER_ABSTIME` and `ESTRPIPE`
let clang check the whole file), then build with the service stopped.

**Measurement plan after the install.** (1) Start the service with
`ZERO_RUN_DETECT=1` in the live block; the journal must show the
`ZERORUN enabled min_frames=8 max_frames=480` line and BRIDGE the four
`zr_*` fields at `0/0/0/0`. (2) Run the channel-2 noise probes as before
(26 s back to back, or `measure-under-service.sh 64 100` in a loop) and
wait for holes; every Mac-side hole from `zeros.py` should match a
`ZERORUN` line by `utc` to within a second, and the set of stages that
carry it names the leg. (3) With music on all channels, `nchan` says
whether a hole is all-channel; `long_runs` climbs on every gap in the
material and means nothing on its own.

**STALL 2026-09-04 19:47:27 UTC on the IRQ-pinned session, during a
parallel bridge build on the Pi; the supervisor restarted the service.**
The 15:33 UTC session ran 4 h 14 min with zero RECOVERs, then
`DEPTHSTEP direction=ravenna-to-usb ... pull=144 gap_us=3550` at
19:47:27 UTC, both captures in XRUN (`Broken pipe`) at once, RECOVER and
re-prime, again at 19:47:29 (gaps 895/1100 us) and 19:47:33, eight
direction restarts in 60 s, `FAIL more than 5 direction restarts in 60 s
(8)`, SUMMARY `tx_restarts 4 rx_restarts 4`, exit 35, systemd restart
counter 1, service back at 19:47:51 UTC and the bridge PRIMED at 19:48:33
(ALIGN ok attempt 1, TX `align_dropped=52`, floors 164/96 at 19:50, pin
and governor intact). The 3.55 ms gap is the 4-6 ms stall family.

What was happening on the Pi: a second session (not this one) was
building a bridge in `~/usb-16x16-work/phase4-zerorun-src/` with the
service running: sources edited 19:42-19:43 UTC, a fresh cmake configure
at 19:47:01, `bridge_core.cpp.o` and the test binary at 19:47:03-05,
`main.cpp` edited 19:47:31, the bridge binary (`b65b84ee`) linked
19:47:46, and `phase4-zerorun-install/` staged 19:49:23; ssh logins from
the Mac at 19:38, 19:40 (a refused `sudo true`), 19:45, 19:46:45,
19:46:47 and 19:47:01 besides this session's 5-minute watch. The stall
landed 22 s after the compile burst. This is the third time a stall has
followed a build or ssh burst on the Pi within seconds (2026-09-03: 14 s
after an incremental compile, 6 s after a burst of ssh sessions). Still
not proven as a cause, but three for three; treat a build on the Pi
while the service runs as an expected stall, and do not count this event
against lever 2 (IRQ pinning), whose clock restarts from 19:48:33 UTC.
The `phase4-zerorun` work is the bridge-side zero-run detector this
record asked for; its install is the next service stop.

**INSTALLED 2026-09-04 20:18 UTC by the user: the zero-run detector
bridge `b65b84ee`, ZERORUN enabled on the rx120 profile.** Service up at
20:18:29 UTC, `NEGOTIATED` then `ZERORUN enabled min_frames=8
max_frames=480 stages=usb-capture,ravenna-playback,ravenna-capture,usb-playback`,
`PITCHSERVO enabled`, ALIGN ok attempt 1, TX `align_dropped=54`, pin and
governor intact, zero RECOVERs, `zr_*` all 0/0/0/0 at start. A 24-probe
64-frame noise campaign is running to catch a hole and read the stage it
flags.

*RX floor dropped to 13 this session start, a single early RAVENNA skip.*
`rx_pullmax=144` (a triple-packet pull, the device skip the record
describes) landed about 20 s in, at 20:19:23 UTC, while the RX cushion was
still building, and pinned the running-minimum `rx_qfloor` at 13 for the
session; `rx_queue` is 168, occupancy 144, zero drops, zero RECOVERs. Not
a regression (the skip is RAVENNA behaviour, unrelated to the new binary)
and not a live danger, but 13 frames (0.27 ms) is the thinnest RX margin
recorded, against the usual 96, and shows an early skip can bring the RX
side within a quarter millisecond of an underrun. The RX floor is a
running minimum from session start, so it reflects that one early event,
not steady state.

**INSTALLED 2026-09-04 20:18 UTC by the user: bridge `b65b84ee`, wrapper
`6282b108`, supervisor `5c3c4004`; live conf `001b0d20` kept and given
`ZERO_RUN_DETECT=1` by hand.** On the way he stopped `usb-16x16` instead
of `usb16x16-aes67` (20:15 UTC): the gadget went to `not attached`, the
Mac lost the device, and the service fell into its wait-for-host loop;
`systemctl start usb-16x16` brought the gadget back and the Mac
re-enumerated, no harm. Service running at 20:19:16 UTC on
`servo-aligned-both-240-rx120`, `ZERORUN enabled min_frames=8
max_frames=480`, ALIGN ok attempt 1 (tick 999 us), TX PRIMED
`align_dropped=54 front_age_frames=448`, servo engaged at 60 s, zero
RECOVERs. First readings: all four `zr_*` at `0/0/0/0` for two minutes
while the Mac sent silence (a run that never ends is never counted), then
from 20:21:10 UTC the fourth field, `long_runs`, climbing at 4 per second
on every stage in lockstep (20, 60, 100, ..., 532 by 20:23:13) with the
first three still 0: that is the impulse harness, one impulse every 250 ms
on one channel with silence between, each 12000-frame gap ending as one
long run, present at every stage because the stage counters see the same
signal round the loop; it is the expected reading and says nothing about
holes. No `ZERORUN` line yet in the first four minutes. One thing to
watch: this session's `tx_pullmax`/`rx_pullmax` read 144 with
`tx_gapmax_us` 3005 and `rx_gapmax_us` 3054 from the first ten seconds
(`rx_qfloor` 13, `rx_qlow` 1), a 3 ms stall at start that did not
RECOVER; the previous session read 1098/1642 after a minute. If a later
BRIDGE line shows the gap maxima moving, the stall family is back.

**First ZERORUN, 20:28:55 UTC: the Mac, not a hole.** The moment Apple
Music started, one 19-frame run on channel 1 alone (`channels=0x0001`)
appeared at `usb-capture` (start 28018532, utc .976), then
`ravenna-playback` (.979), `ravenna-capture` (start 28019542, .995) and
`usb-playback` (.999), same length and channel at every stage. Zeros
already present in the USB capture were made on the Mac: the first
milliseconds of a fade-in below one 24-bit LSB on the left channel. The
instrument is validated end to end on a real event: a run entering at
the first stage is carried through the other three with its length and
channel intact. The stamps put USB capture to RAVENNA capture at about
19 ms with 1 ms read granularity, so the Mac and the two USB legs share
roughly 12 ms of the 31.3 ms RTL at 32. A real hole reads 41, is absent
from `usb-capture`, and with music on both channels carries `nchan=2`.

**ANSWERED 2026-09-04 20:28-20:31 UTC: the 41-sample holes are on the
AES67 return leg, not USB.** The zero-run detector caught two holes on the
live streams during a 24-probe noise campaign (the Mac probes captured
channel 2 and missed both; the detector reads all 16). Read the four
stages in loop order: usb-capture (Mac->Pi USB OUT), ravenna-playback
(Pi->Ferrofish), ravenna-capture (Ferrofish->Pi return), usb-playback
(Pi->Mac USB IN).

*20:31:00 UTC, length 41, channels ch1+ch2, `start_mod48=0`.* Present at
`ravenna-capture` and `usb-playback` (both `direction=ravenna-to-usb`),
ABSENT at `usb-capture` and `ravenna-playback`. So it was injected when
the bridge read the Ferrofish return through the RAVENNA driver; the
outbound half of the loop was clean at that instant. The start is on the
48-frame RAVENNA packet grid. The Ferrofish transmit late counter reads 0
(user confirmed on Dante Controller), so the Ferrofish sent on time, and
the sink playout buffer is 576 frames, so a merely late packet would
still land: this is a return packet that never arrived, dropped at the
switch or the Pi NIC and concealed as 41 zeros by the RAVENNA receive.
This is the 41-sample hole the record chased since 11:58 UTC. It is not
USB, not the bridge queues, not the Mac. `req_number` (3/8) cannot touch
it; that lever is closed for these holes (and, with the 19-sample event
explained as music content below, closed entirely). The eth0 `rx_dropped` counter
climbing ~0.5/s is the standing suspect (most of it unrelated multicast,
a tiny fraction the audio return); the GS305EP switch's handling of the
return multicast is the thing to look at next, and a longer detector soak
gives the true rate and whether it is bursty.

*20:28:55 UTC, length 19, channel ch1.* Present at all four stages, first
at `usb-capture`, carried around the whole loop. The parallel session
(commit `32db65f`) identified this as the start of Apple Music playback:
Mac source material, genuine content silence on the left channel, not a
dropped-audio hole. So it is not a defect and not on any leg the bridge
owns. With event 1 explained as content and event 2 as return-leg loss,
there is no evidence of a USB OUT drop at `req_number=4` at all, and the
req sweep (3/8) has nothing left to fix on either count. Close it.

Detector counters at 20:31 UTC: `zr_usbcap=1/19/19/...`
`zr_ravcap=2/60/41/...` (events/frames/longest/long_runs; `long_runs` is
the undriven silent channels, correctly not reported). Zero RECOVERs, the
detector's audio path byte-identical to before. The bridge stays on
`b65b84ee` with ZERORUN on; it can be left on (one float compare per
sample) or the profile reverted to the shipped bridge once the return-leg
question is closed.

**FOUND 2026-09-04 20:31-20:53 UTC: the 41-sample holes enter the Pi
in the RAVENNA capture, on both music channels, at phase 0 of the
capture's 48-frame period; the Mac, the bridge and the USB gadget are
cleared.** Apple Music on the loop from 20:28 UTC with the detector live.
Pairing every `ravenna-capture` run against the `usb-capture` runs of the
same length and channel 900-1200 frames earlier (the loop offset measured
1010-1187): 100 of 104 return-side runs have a Mac-side partner and are
the material itself, single-channel runs of 8-207 exact zeros in the
tracks (the flood the user saw at 20:46:45 is one of those, lengths 8-64,
channels `0x0001`/`0x0002` separately, `tx_clip` and `rx_clip` 0, so not
clipping). The four unmatched runs are the holes: 20:31:00.605,
20:40:37.430, 20:49:58.115, 20:50:12.311 UTC, every one `length=41
channels=0x0003 nchan=2 start_mod48=0` at `ravenna-capture` (starts
34000848, 61688448, 88601184, 89282592, all multiples of 48), each
reappearing at `usb-playback` with start minus 1 and nothing at
`usb-capture` or `ravenna-playback`. So the zeros are already in the
RAVENNA capture buffer when the bridge reads it, they begin on the
driver's period boundary and cover 41 of the 48 frames, and the bridge
hands them to the Mac unchanged. What is left as the maker: the
Ferrofish's transmit, the switch, the Pi's NIC and the RAVENNA driver's
receive (a packet 41 samples late against the reader, or a packet lost
and the slot read before its replacement, fits the 41/7 split; the driver
has no counter to say which). Rate in this session 4 in 31 min of music,
about one per 8 min, two of them 14 s apart. Two coincidences checked and
dismissed: the 20:50:12 hole landed in the same second as an ssh login
(systemd session scope creation on the Pi), so twenty logins 3 s apart
were made 20:52:24-20:53:29 UTC and produced one hole (20:52:38.036, the
same signature), against 0.14 expected at the background rate: logins are
not a trigger, or a weak one at most. Nothing else in the journal within
4 s of any hole; `eth0 rx_dropped` at its 0.5/s background (38671),
`rx_errors` and `rx_missed_errors` 0. Note also a login every five
minutes at hh:m4:13 UTC from 192.168.1.58 that is not the user's shell.

Next lever, the user's call: the RX playout margin. The profile runs
sink delay 96, exactly two packets. If a late packet is the maker, a
larger margin absorbs it: a copy of `servo-aligned-both-240-rx120` with
`SINK_DELAY=144` (one variable) is staged in the repo conf as
`servo-aligned-both-240-rx120-sd144`, experimental; the live conf is
operator-edited, so the block goes in by hand and `switch-profile`
restarts the stack. Holes gone at 144 says late packet, margin was the
lever, cost 1 ms; holes unchanged at 144 and at 576 says lost packet or
a driver-side artefact independent of margin, and the next instrument is
on the wire (a capture on the switch mirror or the Pi NIC with the RTP
sequence numbers).

**MEASURED 2026-09-04 20:57-21:32 UTC: sink delay 144 stops the holes.**
The user switched to `servo-aligned-both-240-rx120-sd144` (the running
profile with the RX playout margin at 144 instead of 96, one variable) at
20:57:27 UTC and played Apple Music on both channels. In 34.5 minutes:
299 zero runs at `ravenna-capture`, every one paired to a `usb-capture`
run of the same length and channel 900-1200 frames earlier (the material
itself, first at 21:01:48, last at 21:27:58, so the signal was continuous),
zero unpaired, zero of length 41, zero RECOVERs, gap maxima 1058/1715 us
(no start stall this session), TX floor 151, RX floor 96. The previous
session at 96 made four holes in 31 minutes of the same music; at that
rate 4.4 were expected here and none came, about a 1 in 80 chance if 144
had changed nothing, and the earlier probe sessions ran nearer one per
3 minutes. Reading: the holes are packets arriving late against the
reader by up to about 41 samples beyond the 96-sample margin, and one
more packet of margin covers them, at a cost of 48 samples (1 ms) on the
round trip. One session; the A/B that closes it is a return to 96 with
the holes back, then 144 again. Where the lateness is made (Ferrofish
transmit, switch, Pi NIC or driver receive) is still open, and it only
matters now if the 1 ms is wanted back. The sd144 profile stays
experimental until it has its four loaded 800-impulse runs and the
sixteen-channel soak; its level should read about 1362 at 64 frames,
48 over rx120's 1314.

**ACCEPTED 2026-09-04 21:39-21:54 UTC: profile
`servo-aligned-both-240-rx120-sd144`, gadget `req_number=4`, bridge
`b65b84ee`.** Measured against the running service (session since
20:57:27 UTC), Apple Music paused, harness alone,
`measure-under-service.sh 64 800 sd144`, the same arguments as every
acceptance since `servo-aligned-both`. Gate first: one channel-2 noise
probe at 64 frames (`sd144accept-noise-ch2-64f-100imp` in
`outputs/latency/usb-holes-20260904/`) read 0.0% zeros and no zero run of
4 or more in 1.24 M samples.

| run | file | frames | samples | ms | levels | score | tx_qfloor | rx_qfloor | tx_pullmax | RECOVERs |
|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|
| 1 | `sd144-roundtrip-64f-20260904T213931Z` | 64 | 1352 | 28.167 | 1352 x800 | 1.000 | 151 | 96 | 48 | 0 |
| 2 | `sd144-roundtrip-64f-20260904T214312Z` | 64 | 1352 | 28.167 | 1352 x800 | 1.000 | 151 | 96 | 48 | 0 |
| 3 | `sd144-roundtrip-64f-20260904T214652Z` | 64 | 1352 | 28.167 | 1352 x800 | 1.000 | 151 | 96 | 48 | 0 |
| 4 | `sd144-roundtrip-64f-20260904T215033Z` | 64 | 1352 | 28.167 | 1352 x800 | 1.000 | 151 | 96 | 48 | 0 |

3200 impulses on one sample, zero spread, zero discontinuities, zero
restarts, zero clips, zero drops, pitch 1000011-1000018, worst gaps
1074/1725 us (session maxima, unchanged by the runs), `tx_pullmax` 48
(`rx_pullmax` 96 once in the window). 1352 is 38 samples over rx120's
1314 at the same gadget, not the 48 one packet of sink delay predicts;
the 10-sample difference is a reader-phase term against the packet grid,
the same kind the 96/120/144 sweep of 2026-09-03 showed (five samples
apart on the line there), recorded, not explained.

**SOAKED 21:54-22:04 UTC, sixteen channels loaded.**
`USB16X16_OTHER_LOAD=0.1 measure-under-service.sh 64 2400 sd144soak`:
`sd144soak-roundtrip-64f-20260904T215413Z`, 600 s, 2400 impulses at 64
frames with channels 2-16 at 0.1, all 2400 on **1352 samples
(28.167 ms)**, spread 0, score 1.000, zero discontinuities, zero
RECOVERs, zero restarts, `tx_clip`/`rx_clip` 0, `tx_dropped`/`rx_dropped`
0, `tx_qfloor` 151 and `rx_qfloor` 96 on all 1620 telemetry lines of the
27-minute chain, pitch 1000011-1000018. The zero-run detector ran
throughout and saw no unpaired run at `ravenna-capture` from 21:39 to
22:05 UTC; with fifteen channels of continuous noise for the 600 s soak
that is a second hole-free window at 144 on top of the 34.5 min of music,
45 min of continuous signal in all against four holes in 31 min at 96.
Checklist item 9 is met for this operating point; the conf block is
`accepted` (conf `46fd274f`, installer repinned, staged on the Pi; the
live operator conf carries the block the user pasted, `STATUS=experimental`
there until he edits it). Still owed: the A/B back to 96 that closes the
late-packet reading, and the standard RTL Utility figure at 32 frames,
which the user reads (expect about 32.1 ms, 0.8 ms over 31.292).

**RTL Utility at 32 frames on `servo-aligned-both-240-rx120-sd144`, read
by the user 2026-09-04 about 22:15 UTC: 32.083 ms**, 0.79 ms over the
31.292 of rx120 at sink delay 96, the same 38 samples the harness read
(1352 against 1314). This is the standard figure for the accepted point.

**A/B started 22:20:44 UTC: back to `servo-aligned-both-240-rx120`
(sink delay 96)** by `switch-profile`, sinks read 96, ALIGN ok, zero
RECOVERs, the detector live, Apple Music on the loop. Watching for the
holes to return; the result closes or reopens the late-packet reading.

**A/B result, 22:33-23:01 UTC: the holes come back at 96.** The music
reached the device from 22:33 (Apple Music's playback session on the USB
16x16 began then, not at the switch), and stopped at about 23:01. In
those 28 minutes: one hole, 22:43:03.862 UTC, `length=41 channels=0x0003`
at `ravenna-capture` with no `usb-capture` partner, the same signature as
the four of the earlier 96 session; zero RECOVERs; 45 material runs paired
to the Mac. Pooled over both 96 sessions: 5 holes in 59 minutes of music,
about one per 12 minutes, bursty. At 144: 0 in 45 minutes of continuous
signal (34.5 of music, 10 of fifteen-channel noise). The chance of 0 in
45 minutes at the 96 rate is about 1 in 40. The reading stands: a packet
arriving late against the RAVENNA reader by up to about 41 samples beyond
a 96-sample margin, covered by one more packet of margin at 0.79 ms
(RTL at 32: 32.083 against 31.292). Where the lateness is made
(Ferrofish transmit, switch, Pi NIC or driver receive) is still open and
is now a latency question only, worth 0.79 ms. The accepted operating
point is `servo-aligned-both-240-rx120-sd144`; the service was left on
`servo-aligned-both-240-rx120` (96) at the end of the A/B and needs
switching back.

**DONE 2026-09-04 23:19-23:25 UTC: the service is back on
`servo-aligned-both-240-rx120-sd144`** (switch at 23:19:44 UTC, sinks
144, zero RECOVERs) and the user carried the accepted labels into the
live conf: the block's DESCRIPTION, STATUS (`accepted`), COVER and
MEASURED lines copied from the shipped `46fd274f` by a root python
one-liner with an atomic replace, four lines changed, live conf now
`398a06b9`, no restart (labels only), `profiles` shows the block as accepted.
The operating point of record is sd144: 1352 samples at 64 frames
(28.167 ms), RTL Utility at 32 32.083 ms, gadget `req_number=4`, bridge
`b65b84ee` with the zero-run detector on. Open: where the late packets
are made (0.79 ms on the table), the RX PRIMED `front_age_frames -1`
fix, the req 3/8 sweep, and TX prime 192 behind a day of `tx_pullmax`.

**MEASURED 2026-09-05 00:02-00:06 UTC: `req_number=3`, the first point of
the sweep, costs nothing against 4 and is clean down to 16 frames.** The
user stopped the AES67 service (23:55:33 UTC, the sd144 session of 23:19
with zero RECOVERs), held 3 with a runtime drop-in
(`/run/systemd/system/usb-16x16.service.d/req3.conf`, `ExecStart=` reset to
`/usr/local/sbin/setup-usb-16x16 start 3`; the installed script stays
`b11fd358`, a reboot returns to 4), `daemon-reload`, restarted the gadget
(bound 23:58:11 UTC, `req_number=3`, `configured`, high-speed; a first
attempt without the drop-in directory rebound at 4 and was redone) and
started the service at 00:02:06 UTC on `servo-aligned-both-240-rx120-sd144`
(ALIGN ok attempt 1, TX `align_dropped=49`, RX PRIMED still
`front_age_frames=-1`). RTL Utility at 32 frames, read by the user right
after: **32.042 ms**, 2 samples under the 32.083 of `req_number=4`. Then,
harness alone, RTL Utility idle, 100 impulses each, in
`outputs/latency/usb-holes-20260904/` as `req3-*`:

| probe | frames | result |
|---|---:|---|
| noise ch2 | 512 | 0.0% zeros, no run of 4 or more in 1.24 M samples |
| noise ch2 | 64 | 0.0%, no run (req 4's first probe at 64 had five 41-sample runs) |
| noise ch2 | 32 | 0.0%, no run |
| noise ch2 | 16 | 0.0%, no run |
| impulse ch1 | 64 | **1350** on all 100, score 1.000, no discontinuities |
| impulse ch1 | 32 | **1350** on all 100, score 1.000, no discontinuities |

Pi over the pass (session 4 minutes old, unloaded apart from the probes):
zero RECOVERs, zero restarts, zero drops, zero clips, `tx_qfloor` 159,
`rx_qfloor` 107, `tx_pullmax` 48, `rx_pullmax` 85, gaps 1.08/1.91 ms,
pitch 1000013, detector 0 runs at every tap.

Reading. The level is 1350 against 1352 at req 4 on the same profile, so
the request count from 3 to 4 costs about 2 samples, not the 48 per
request the "two extra 250 us requests per direction" arithmetic
predicted, and the ~150-sample step between req 2 (1159-1172) and req 4
(1314) is not per-request. Either it all lands between 2 and 3, or the
req 2 level was itself an artefact of a loop that was dropping every
second impulse and the true clean-loop level at 2 was never measured.
Request count is therefore not a latency lever above 2; point 8 of the
sweep has nothing left to answer (it existed for the five residual holes,
which did not recur at 4 and do not exist at 3). The one point that still
tests something is the packet interval: `p_hs_bint=c_hs_bint=1` (125 us
packets, 6 frames) with 4 requests, the same slack in half the queued
time, one variable against the accepted point. Also noted, not explained:
`rx_qfloor` reads 107 here against 96 on every req 4 session, and
`rx_pullmax` 85 against 96; the RX floor, which did not follow the RX
prime, may follow the USB playback request depth. A loaded floor needs the
800-impulse runs, which this point did not get: 3 is measured, not
accepted, and the service is left on 3 pending the next point.

**MEASURED 2026-09-05 00:12-00:17 UTC: `p_hs_bint=c_hs_bint=1` (125 us
packets) with `req_number=4` reads 1337, 15 samples under the accepted
point, clean at 512/64/32/16 on the noise probes, with one CoreAudio
discontinuity pair in the 32-frame impulse probe.** The user stopped the
service at the end of the req 3 session (SUMMARY at 00:10:54 UTC: zero
restarts, `tx_queue_floor` 159, `rx_queue_floor` 107, `rx_pull_max` 85,
zero RECOVERs, detector 0 runs), repointed the same drop-in at
`~/usb-16x16-work/gadget-bint1/setup-usb-16x16-bint1 start 4` (hash
`21b8a687`: `b11fd358` with lines 80 and 85 writing 1 instead of 0 to
`p_hs_bint` and `c_hs_bint`, nothing else changed, staged from the Mac,
syntax-checked on both), restarted the gadget (bound 00:11:14 UTC,
`req_number=4`, `p_hs_bint=1`, `c_hs_bint=1`, high-speed, the Mac
enumerated it) and started the service at 00:12:07 UTC on
`servo-aligned-both-240-rx120-sd144` (ALIGN ok attempt 1, TX
`align_dropped=50`). RTL Utility, read by the user first: **errors at 32
frames**, and **32.354 ms at 64**. Then the six-probe pass, harness alone,
RTL Utility idle, 100 impulses each, `bint1-*` in
`outputs/latency/usb-holes-20260904/`:

| probe | frames | result |
|---|---:|---|
| noise ch2 | 512 | 0.0% zeros, no run of 4 or more in 1.24 M samples |
| noise ch2 | 64 | 0.0%, no run |
| noise ch2 | 32 | 0.0%, no run |
| noise ch2 | 16 | 0.0%, no run |
| impulse ch1 | 64 | **1337** on all 100, score 1.000, no discontinuities |
| impulse ch1 | 32 | **1337** on all 100, score 1.000, **1 input and 1 output discontinuity** |

Pi over the pass: zero RECOVERs, restarts, drops or clips, `tx_qfloor`
158, `rx_qfloor` 109, `tx_pullmax` 48, `rx_pullmax` 49, gaps 1.08/1.74 ms,
pitch 1000014, detector 0 runs at every tap; nothing in the journal at the
time of the discontinuity. The daemon logged its usual "configured PTP
grand master clock doesn't match the PTP clock in SDP" warning at start.

Reading. Halving the packet interval took 15 samples (0.31 ms) off the
round trip: 1337 against 1352 (bint 0, req 4) and 1350 (bint 0, req 3) on
the same profile and the same day. RTL at 64 reads 32.354 against the
32.75 that 32.083 at 32 implies at 64, 0.4 ms, the same direction. The
noise probes see every sample at every IO size, so the loop is not
dropping audio the way req 2 did; but four 125 us requests are 500 us of
queued time, the same as req 2's two 250 us requests, and at 32 frames
the Mac reported one glitch in 26 s and RTL Utility would not complete a
measurement, where bint 0 at req 3 and req 4 gave zero discontinuities
and RTL completed at 32 and 16. So the host's tolerance looks like queued
time rather than request count, and this point is short of it at 32
frames. The next single-variable point is `req_number=8` at bint 1: the
same 1 ms of queued time as the accepted point, in 125 us packets, one
edit to the drop-in (`start 8`). Given that 3 to 4 cost 2 samples, 8
should keep most of the 15. If 32 comes back clean there with RTL
completing, that is the candidate for the four loaded runs and the soak;
if not, bint 1 is not worth 0.3 ms and the accepted point stands. The
service is left on bint 1 / req 4, measured, not accepted; rollback is
removing the drop-in, `daemon-reload`, gadget restart.

**MEASURED 2026-09-05 01:04-01:09 UTC: `req_number=8` at bint 1 reads
1368, 16 over the accepted point, clean everywhere; the sweep closes with
the accepted point standing.** A first attempt at 00:37 UTC restarted the
AES67 service without the gadget (the drop-in said `start 8`, the unit
had last run `start 4`), so RTL's error at 32 then was bint 1 / req 4
again; redone at 01:03:08 UTC (`gadget bound with req_number=8`, bint
1/1, high-speed), service running at 01:04:15 UTC (ALIGN ok, TX
`align_dropped=49`). RTL Utility, read by the user: **errors at 32
frames**, **about 33 ms at 64**. The six-probe pass, harness alone,
`bint1req8-*` in `outputs/latency/usb-holes-20260904/`:

| probe | frames | result |
|---|---:|---|
| noise ch2 | 512 / 64 / 32 / 16 | 0.0% zeros, no run of 4 or more, all four |
| impulse ch1 | 64 | **1368** on all 100, score 1.000, no discontinuities |
| impulse ch1 | 32 | **1368** on all 100, score 1.000, no discontinuities |

Pi over the pass: zero RECOVERs, restarts, drops or clips, `tx_qfloor`
159, `rx_qfloor` 109, `tx_pullmax` 48, `rx_pullmax` 49, gaps 1.12/1.72 ms,
pitch 1000015, detector 0 runs.

The sweep in one table, all on `servo-aligned-both-240-rx120-sd144`,
bridge `b65b84ee`, 2026-09-04/05:

| gadget | 64-frame level | noise 512/64/32/16 | 32-frame impulse probe | RTL Utility |
|---|---:|---|---|---|
| bint 0, req 4 (accepted) | 1352 | clean | clean | 32.083 at 32 |
| bint 0, req 3 | 1350 | clean | clean | 32.042 at 32 |
| bint 1, req 4 | 1337 | clean | 1 in + 1 out discontinuity | errors at 32, 32.354 at 64 |
| bint 1, req 8 | 1368 | clean | clean | errors at 32, about 33 at 64 |

Reading. Request count above 2 costs nothing at 250 us (3 to 4: 2
samples) but 31 samples from 4 to 8 at 125 us, so the queued requests do
sit on the path once there are enough of them. The packet interval at
125 us is worth 15 samples only at four requests, where the Mac glitches
at 32 frames; at eight requests, where it is clean, it is 16 samples
worse than the accepted point. And at both bint 1 points RTL Utility
cannot complete a measurement at 32 frames even though the harness at
the same IO size sees every sample and, at req 8, no discontinuity; the
standard figure is unreadable there, which disqualifies bint 1 on its
own. The three levers the sweep existed for are spent: `req_number=3` is
equivalent to 4, `req_number=8` has nothing to fix, and bint 1 is not a
net gain. The 150-sample step between req 2 and req 4 remains
unexplained and is most likely not a clean-loop number at all (the req 2
level was measured while the loop dropped every second impulse). The
accepted point stays `req_number=4`, bint 0, script `b11fd358`. Also on
the record from the three sessions: `rx_qfloor` 107-109 at every point
that was not bint 0 / req 4, against 96 on every bint 0 / req 4 session,
unloaded in all three; the RX floor moves with the gadget's endpoint
configuration and is worth a loaded look when the RX side is next
instrumented. The service was left on bint 1 / req 8 at the end of the
pass; rollback to the accepted gadget is removing the drop-in, a
`daemon-reload`, and a gadget restart with the service stopped.

**ACCEPTED 2026-09-05 01:22-01:37 UTC: profile
`servo-aligned-both-240-rx120-sd144-tx192`** (sd144 with
`TX_PLAYBACK_PRIME=192`, one variable), gadget `req_number=4`, bint 0,
script `b11fd358`, bridge `b65b84ee`. The lever the record had parked
behind a skip counter: `tx_pullmax` has read 48 on every session at period
48 since 2026-09-03 with the pull histogram empty above the second bin, so
the three-packet pull the 144-frame bar covered is absent at this period
and the TX prime can drop by one period. Staged in the repo conf as
experimental (`82614fdf`, installer repinned, `46fd274f` to the
unedited-shipped list), the block copied to the Pi as
`~/usb-16x16-work/tx192-block.conf` (`9bd5408e`) and checked with
`profiles` against a copy of the live conf; the user appended it to the
live conf (`9690340e`) and ran `switch-profile` at 01:21 UTC. Session:
ALIGN ok attempt 1, TX PRIMED `queue_prime=192 align_dropped=56
overshoot=5 front_age_frames=400`, RX PRIMED unchanged, `STAGE running`
01:21:10 UTC. Gate first: channel-2 noise probe at 64
(`tx192gate-noise-ch2-64f-100imp` in `usb-holes-20260904/`) 0.0% zeros,
no run of 4 or more in 1.24 M samples. Then `measure-under-service.sh 64
800 tx192` four times in one chain, harness alone, RTL Utility idle:

| run | file | frames | samples | ms | levels | score | tx_qfloor | rx_qfloor | tx_pullmax | RECOVERs |
|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|
| 1 | `tx192-roundtrip-64f-20260905T012225Z` | 64 | 1318 | 27.458 | 1318 x800 | 1.000 | 112 | 109 | 48 | 0 |
| 2 | `tx192-roundtrip-64f-20260905T012601Z` | 64 | 1318 | 27.458 | 1318 x800 | 1.000 | 105 | 109 | 48 | 0 |
| 3 | `tx192-roundtrip-64f-20260905T012937Z` | 64 | 1318 | 27.458 | 1318 x800 | 1.000 | 105 | 109 | 48 | 0 |
| 4 | `tx192-roundtrip-64f-20260905T013312Z` | 64 | 1318 | 27.458 | 1318 x800 | 1.000 | 105 | 109 | 48 | 0 |

3200 impulses on one sample, zero spread, zero discontinuities, zero
restarts, zero clips, zero drops, gaps 1.05/1.62 ms (session maxima),
`tx_pullmax` 48 (histogram 5495487/1591169/0/0/0/0 at the end of the
session), pitch 1000014-1000016. **1318 is 34 samples (0.71 ms) under
sd144's 1352**, not the 48 of the prime change; the 14-sample residue is
the same session-start term the rx120 step carried (24 predicted, 50
measured, there in the other direction), recorded, not explained. The TX
floor fell from 197 unloaded to 112 in the first loaded run and 105 from
the second onward, 2 over the 103 predicted from sd144's 151, over a bar
of one period plus the worst wakeup gap (48 + about 96); `tx_qlow` 0 on
every telemetry line.

**SOAKED 01:37-01:47 UTC, sixteen channels loaded.** `USB16X16_OTHER_LOAD=0.1
measure-under-service.sh 64 2400 tx192soak`:
`tx192soak-roundtrip-64f-20260905T013703Z`, 600 s, 2400 impulses at 64
frames with channels 2-16 at 0.1, all 2400 on **1318 samples (27.458
ms)**, spread 0, score 1.000, zero discontinuities, zero RECOVERs, zero
restarts, `tx_clip`/`rx_clip` 0, `tx_dropped`/`rx_dropped` 0, `tx_qfloor`
105 and `tx_qlow` 0 on all 160 BRIDGE lines of the 26-minute session,
`rx_qfloor` 109, the zero-run detector 0 runs at every stage (its only
line is the enable line at start). Checklist item 9 is met for this
operating point. Conf `848cc08d` carries the block as accepted
(installer `17c41b98`, `82614fdf` joins the unedited-shipped list); the
live conf carries the user's pasted block with `STATUS=experimental` until
he edits the labels, as for sd144. Still owed: the standard RTL Utility
figure at 32 frames, which the user reads (expect about 31.4 ms, 0.7 ms
under 32.083). Rollback is `switch-profile
servo-aligned-both-240-rx120-sd144`.

Noted on the way: `rx_qfloor` read 109 for this whole session on the
accepted gadget, where the sd144 acceptance read 96 and the 01:17 UTC
session on the same gadget read 96 within its first minute. So the 96/109
split is not the gadget's endpoint configuration after all (retracting
the reading in the sweep entries above); it is set per session by
something at RX start, unloaded and loaded alike, and it is the next
thing to instrument on the RX side together with the `front_age_frames
-1` fix.

**RTL Utility at 32 frames on `servo-aligned-both-240-rx120-sd144-tx192`,
read by the user 2026-09-05 about 01:50 UTC: 31.375 ms**, 0.708 ms (34
samples) under the 32.083 of sd144, the harness difference (1318 against
1352) to the sample. This is the standard figure for the accepted point.
Conf `ec4b587b` carries it in the block's MEASURED string (installer
`d3b49785`, `848cc08d` joins the unedited-shipped list). The operating point of
record is now tx192: 1318 samples at 64 frames (27.458 ms), RTL Utility at
32 31.375 ms, gadget `req_number=4`, bint 0, bridge `b65b84ee`, sink delay
144, TX prime 192, TX floor 105. Open, in order of what they are worth:
the RX floor's per-session 96/109 and the RX PRIMED `front_age_frames -1`
fix (up to 2 ms hiding on the RX side, unknown until instrumented); where
the late packets are made (0.79 ms); and, with the TX floor now at 105
over a bar near 96, no further TX prime step without a lower bar, which
would need the worst wakeup gap measured over days, not sessions.

**DONE 2026-09-05 02:03 UTC by the user: the accepted labels are in the
live conf.** `copy-tx192-labels.py` (staged in
`~/usb-16x16-work/aes67-tx192-install/` beside the shipped conf
`ec4b587b`, installer `d3b49785`, and the unchanged supervisor `5c3c4004`
and unit `77837e60`) replaced the tx192 block's STATUS, COVER and MEASURED
lines with the shipped ones by an atomic replace, DESCRIPTION already
identical, three lines changed, mode and owner kept (root 644). Live conf
now `50fe5b49`, `PROFILE=servo-aligned-both-240-rx120-sd144-tx192`,
`profiles` shows the block as accepted, no restart: the service session
of 01:20:23 UTC continues, zero RECOVERs.

**And the RX floor question answers part of itself: `rx_qfloor` read 96
at 02:05 UTC on this same session**, after reading 109 on every line
through the acceptance and the soak (01:21-01:47). So 109 is not a
per-session value either; the RX floor is a running minimum that takes
somewhere between 26 and 44 minutes of service time to reach 96, and the
acceptance windows were too short to see it. Both earlier readings are
withdrawn: not the gadget (the sweep entries), not per session (the
ACCEPTED entry above). What remains is why it takes that long, which a
timestamped log of `rx_qfloor` changes would show; unloaded and loaded
alike, RX cover stays 96 over the 48-frame push, as every accepted profile
has read.

**Phase 5 Stage A, 2026-09-05 02:12-02:25 UTC: the clock terms priced, the
kernel module step closed.** Phase 5's userspace half shipped on 2026-09-02
as `--usb-pitch-servo 1` (the Mac follows the RAVENNA rate through the
gadget's pitch controls, both converters at exactly 1.0), so before any
exact-source `usb_f_uac2` work the question was what clock-related depth
the servo leaves behind. `outputs/latency/phase5-20260905/servo-start.py`
reads bridge logs (full-rate tmpfs, candidate `bridge.log`, or a journal
export split by PID) and reports per session the warm-up drift, pitch
settle, post-settle band, ring extremes and floors; `servo-start-results.md`
holds its output over the running tx192 session's full-rate log
(`bridge-tx192-session-20260905T012106Z.log`, 3056 s from 01:21:10 UTC,
copied from `/run/usb16x16/bridge.log`), every service session in the
journal since the servo binary (42 sessions, 2026-09-02 22:32 to
2026-09-05 01:21 UTC, one BRIDGE line in ten) and the 17 aligned mode-1
candidate runs of 2026-09-03/04. Frames per direction, 48 = 1 ms.

1. *Warm-up drift: 46 frames TX, 43 RX, every session.* The estimator
   needs 60 observations before it steers, and pitch sits at nominal for
   those 60 s while the clocks differ by about 15 ppm, so TX's depth mean
   falls 46 (351 to 305 on this session, 407 to 361 on the 288-prime
   sessions) and RX's rises 43 to 45, in 39 of 42 service sessions and all
   17 candidates within 3 frames (the three outliers are the 2026-09-03
   19:06 and 19:23 UTC restart storms and one 13:40 session at 66). The
   level loop then captures the drifted split as its setpoint and holds it
   for the session, so the 46 frames are permanent: on this session
   `tx_qfloor` read 197 for the first 27 s (prime 192 plus overshoot 5) and
   149 from 01:21:38 UTC, before any load. Pitch then settles to 1000014-17
   in 26-150 s (median 95) with a 4-8 ppm overshoot. This is 1 ms of TX
   prime that a seeded pitch (the converged 15 ppm written at prime,
   estimator reset to it) would keep; RX's 43 goes into its ring (`rx_occ`
   131 to 144-192) and touches no floor.
2. *Post-settle quantisation band: about 10 frames per direction.*
   Unloaded stretches after settle hold the TX-minus-RX differential in a
   9-30 frame band (this session idle 1560-2100 s: -29..-8) with the bias
   term inside +-1.1 ppm. That band, 0.2 ms, is the only term a kernel-side
   fine-pitch or PTP-derived feedback would touch. Under the plan's bar of
   20 frames per direction the exact-source module step of Phase 5 is
   closed; `DEPLOYMENT_PLAN.md` tier three carries the correction.
3. *The ring reserve has never been used.* `tx_occ` minimum 131 and
   `rx_occ` minimum 131 (target 128 plus 3) in every one of the 59 sessions
   and runs; the RX ring rises to 192 as the sink for RX-side wander. The
   2026-09-03 target-128 run moved the round trip 1:1 with the target
   (64 per direction, 2.67 ms), so target 64 and then 48 are the next
   profile-only levers, worth up to 160 frames (3.3 ms) on the device
   timeline if the aligned prime keeps the floors where the 2026-09-03 run
   could not. Risk to check first: the prime waits on ring level, and the
   Farrow history.
4. *The loaded TX floor is set by transient dips, not the sawtooth.* On the
   full-rate log the differential dips to -105..-110 about ten times during
   loaded runs 2-4 and the soak (291-1553 s), never in run 1 (-28..-6),
   never idle; each dip is 60-100 frames for a few seconds with the bias
   clamped at -3 ppm, `tx_gapmax_us` steady at 1035-1064 so the bridge did
   not stall, and `tx_qfloor` went 149 to 113 two seconds into run 1
   (01:22:27) and to 105 at 382 s in run 2. The 1 Hz `tx_queue` minimum in
   those windows is 154-156 against the floor's 105, so the intra-second
   sawtooth under load is about 50 deep. Where the dips are made (the Mac's
   OUT stream under harness load, or the Pi's USB capture) is not assigned;
   it matters because the harness is also the instrument, and a DAW may or
   may not produce them. Observation only.
5. *RX floor 96 is a 96-frame host pull, to the second.* `rx_qfloor` went
   109 to 96 at 2155 s, 01:57:05 UTC, on the line where `rx_pullmax` first
   read 96 (49 before), `rx_queue` 180 to 144, the differential -21 to +41
   in one second and the bias slammed to +3.0: the Mac took two IN packets
   in one pull, the RX queue lost one period, and the running minimum
   recorded it. The 02:05 UTC reading in the entry above is that event
   seen through the journal's one-in-ten sampling. So the RX floor is
   96 whenever the host makes one double pull, and 109 until it does; the
   time-to-floor is the time to the first such pull, not a slow process.
   The positive excursions from 2125 s on (+30..+59, five of them to
   02:05 UTC) are the same kind of host event, after the loaded windows.

Where Phase 5 stands: the lever left in the clock path is the seed (1 ms of
TX prime, a bridge flag plus a profile key); the lever the servo made safe
is the ring target (up to 3.3 ms, profile only); the kernel step is closed
on this evidence. Order: ring target 64 block first (no build, the larger
number), then the seed, then the prime retrim. The plan is in the
conversation record of 2026-09-05 and summarised in `DEPLOYMENT_PLAN.md`
tier three. Nothing installed, nothing changed on the Pi; the service
session of 01:20:23 UTC continues.

**STAGED 2026-09-05 02:40 UTC: Phase 5 Stage B1, profile
`servo-aligned-both-240-rx120-sd144-tx192-target64`** (tx192 with
`TARGET=64` instead of 128, one variable; experimental). The bridge's own
bounds allow it (`target >= period`, `ring >= target + 8`, the prime
threshold is `target + queue_prime + 3`, the Farrow needs three frames of
ring and the ring is held at target + 3), and the supervisor's validation
passes: repo conf `d2648790` (installer `4286e393`, `ec4b587b` joins the
unedited-shipped list), the block alone as
`~/usb-16x16-work/target64-block.conf` (`7401ce58`), both checked with
`profiles` against a copy of the live conf (`50fe5b49`) and against the
repo conf on the Pi, exit 0, the block listed with `target 64` and every
other key equal to tx192. Expected from the 2026-09-03 1:1 result: about
1190 samples at 64 frames (24.8 ms), RTL at 32 about 28.7 ms. The floors
are the acceptance question: the 2026-09-03 run lost 33 frames of TX floor
to the prime overshoot when the target fell, before the aligned prime
existed. Gate as usual: noise probe at 64, four `measure-under-service.sh
64 800 target64` runs, the 600 s soak, RTL at 32 by the user. Retire the
block if the floors follow the target. Nothing installed; the live conf
is operator-edited, so the block goes in by hand (`cat` append) and
`switch-profile` restarts the stack. Rollback is `switch-profile
servo-aligned-both-240-rx120-sd144-tx192`.

**MEASURED 2026-09-05 02:27-03:06 UTC: `servo-aligned-both-240-rx120-sd144-tx192-target64`
passes every acceptance run at 1127 samples (23.479 ms), 191 under tx192;
the RX floor is 77 and is arithmetic.** The user appended the block to the
live conf (`73ef23f0`) and ran `switch-profile` at 02:26 UTC; STAGE running
02:27:01, ALIGN ok attempt 1, TX PRIMED `queue_prime=192 align_dropped=65
overshoot=12 front_age_frames=336` (400 on tx192: exactly the 64), RX
PRIMED `intended=187 ring_at_prime=192 overshoot=5` (251/288/37 on tx192).
RTL Utility at 32 frames, read by the user right after the switch: **27.396
ms**, 3.979 ms (191 samples) under tx192's 31.375. Gate first: channel-2
noise probe at 64 (`target64gate-noise-ch2-64f-100imp` in
`usb-holes-20260904/`) 0.0% zeros, no run of 4 or more in 1.24 M samples.
Then `measure-under-service.sh 64 800 target64` four times in one chain
and the soak, harness alone:

| run | file | frames | samples | ms | levels | score | tx_qfloor | rx_qfloor | tx_pullmax | RECOVERs |
|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|
| 1 | `target64-roundtrip-64f-20260905T024053Z` | 64 | 1127 | 23.479 | 1127 x800 | 1.000 | 109 | 77 | 48 | 0 |
| 2 | `target64-roundtrip-64f-20260905T024428Z` | 64 | 1127 | 23.479 | 1127 x800 | 1.000 | 109 | 77 | 48 | 0 |
| 3 | `target64-roundtrip-64f-20260905T024804Z` | 64 | 1127 | 23.479 | 1127 x800 | 1.000 | 108 | 77 | 48 | 0 |
| 4 | `target64-roundtrip-64f-20260905T025140Z` | 64 | 1127 | 23.479 | 1127 x800 | 1.000 | 108 | 77 | 48 | 0 |
| soak | `target64soak-roundtrip-64f-20260905T025516Z`, `USB16X16_OTHER_LOAD=0.1`, 600 s | 64 | 1127 | 23.479 | 1127 x2400 | 1.000 | 108 | 77 | 48 | 0 |

5600 impulses on one sample, spread 0, zero discontinuities, zero
RECOVERs (`/run/usb16x16/recovers` empty, no RECOVER line in the full-rate
log), zero restarts, `tx_clip`/`rx_clip` 0, `tx_dropped`/`rx_dropped` 0,
`tx_qlow` and `rx_qlow` 0 on all 2341 BRIDGE lines of the 39-minute
session, zero-run detector 0 runs, gaps 1.12/1.64 ms, pitch 1000012-1000020
after settle, `tx_pullmax` 48 with the histogram empty above the second
bin. Full-rate log saved as
`outputs/latency/phase5-20260905/bridge-target64-session-20260905T022701Z.log`.

*Where the 191 came from.* TX depth fell exactly the 64 of the target
(`front_age_frames` 400 to 336; the aligned prime sets the drop from the
grid, so the TX floor did not follow: 156 unloaded after warm-up against
tx192's 149, 108-109 loaded against 105). RX depth fell 96, not 64: the RX
prime is unaligned and the RX ring fills to the next multiple of 48 above
`target + queue_prime + 3`, so the threshold 187 is crossed at 192 where
251 was crossed at 288. Together 160 samples, and the residue to 191 is
the session-start band (1287-1318 on rx120, 31 wide). The RX floor follows
the same arithmetic: `ring_at_prime - target - 51`, which gives 109 for
288/128 (every tx192 and sd144 session), 109 for 288/128 with prime 144
(the 2026-09-04 candidates) and 77 for 192/64 here. It is not a draw. It
also means the RX prime value matters only through which 48-frame bin
`target + prime + 3` lands in: at target 64, any RX prime from 126 to 173
fills the ring to 240 and gives RX floor 125 at +48 frames (1 ms) of
depth, and 120 gives 77 at the depth measured here. That is Stage B3's
RX-side table, and the `front_age_frames -1` fix (an aligned RX prime)
would make RX depth continuous instead of quantised.

*The RX floor question.* The staged block's comment asked for `rx_qfloor`
96 or better. The session read 77 from second 1 and never lower through
25 minutes loaded, 1433 RX pulls of 49-95 frames (the same 0.6/s both
sessions show; tx192's histogram carried 1912) and one 96-frame pull at
1632 s (02:54 UTC) that did not move it, with `rx_qlow` 0 throughout. The
96 quoted for RX elsewhere in the record is a floor reading that already
includes the 48-frame push, so the comparison is 77 against 96 of cover
after the push, 19 frames (0.4 ms) less than any accepted point has run
with. The block stays `experimental` with its MEASURED and COVER strings
filled (conf `bc674a29`, installer `598829ea`, `d2648790` joins the
unedited-shipped list); accepting it, or moving the RX prime to the 240
bin for RX floor 125 at 1 ms back, is the user's call. The live conf
carries the block as pasted (`STATUS=experimental`) either way. Rollback is
`switch-profile servo-aligned-both-240-rx120-sd144-tx192`.

**ACCEPTED 2026-09-05 03:15 UTC by the user, at RX floor 77:
`servo-aligned-both-240-rx120-sd144-tx192-target64`.** The operating point
of record is now target64: 1127 samples at 64 frames (23.479 ms), RTL
Utility at 32 27.396 ms, gadget `req_number=4`, bint 0, bridge `b65b84ee`,
sink delay 144, TX prime 192, RX prime 120, ring target 64, TX floor 108
loaded, RX floor 77 (arithmetic, see the MEASURED entry above). Conf
`f4ba358f` carries the block as accepted (installer `8b053272`, `bc674a29`
joins the unedited-shipped list). Staged on the Pi in
`~/usb-16x16-work/aes67-target64-install/` (shipped conf, installer,
supervisor `5c3c4004` and unit `77837e60` unchanged) with
`copy-target64-labels.py`, the tx192 label copier with the target64 prefix:
labels only, atomic replace, dry run without `--apply`. Rollback is
`switch-profile servo-aligned-both-240-rx120-sd144-tx192`. Phase 5 next:
the pitch seed (Stage B2, a bridge build, so it waits for a service stop),
then the RX prime bin and TX prime retrim (B3); target 48 is a further
block if wanted, bounded by `target >= period`, at RX floor 93 by the same
arithmetic unless the RX prime moves bins.

**DONE 2026-09-05 03:10 UTC by the user: the accepted labels are in the
live conf.** `copy-target64-labels.py --apply` replaced the target64
block's STATUS, COVER and MEASURED lines with the shipped ones, three lines,
mode and owner kept (root 644). Live conf now `b60ea8e6`,
`PROFILE=servo-aligned-both-240-rx120-sd144-tx192-target64`, `profiles`
shows the block as accepted, a second dry run reports nothing to change,
no restart: the service session of 02:27:01 UTC continues, zero RECOVERs.

**IMPLEMENTED 2026-09-05 03:40 UTC, not yet built: Phase 5 Stage B2, the
pitch seed.** Bridge `--pitch-seed PPM` (double, -250..250, default 0,
needs `--usb-pitch-servo`): with the servo enabled and before any capture
starts, both pitch controls are written nominal minus PPM, the telemetry
thread's wanted and applied values are set to that pitch so it neither
rewrites it nor reads it as new, the estimator is reset to PPM, and a
`PITCHSERVO seeded ppm= pitch=` line is printed; the enabled line carries
`seed_ppm=` and SUMMARY `pitch_seed_ppm`. The regression's applied-ratio
correction integrates `nominal - applied_pitch` from t=0, so the seed is
accounted for from the first observation, and because that regression
measures the required ratio rather than the residual, a seed equal to the
converged value is confirmed by the first observation without a slew (unit
test `test_estimator_seed`). Sign: every session since 2026-09-03 has
converged to pitch 1000014-1000017, which is estimator ppm -14..-17, so
the seed is **-15**. Supervisor: optional profile key `PITCH_SEED_PPM`
(absent means 0; must be a number; non-zero needs `USB_PITCH_SERVO`),
passed as `--pitch-seed`, shown by `profiles` as `seed N ppm`
(`ca2fffb2`). Conf `196786be` adds profile
`servo-aligned-both-240-rx120-sd144-tx192-target64-seed15` (target64 with
`PITCH_SEED_PPM=-15`, experimental); the new supervisor validates the
repo conf and the live conf (`b60ea8e6`) on the Pi, exit 0, target64
listed `seed 0 ppm` and seed15 `seed -15 ppm`. All three sources
syntax-check clean on the Mac (clang, `-Wall -Wextra -Wpedantic -Werror`,
the Pi's ALSA headers as system headers, the endian/clock stubs). Not
built: the Pi build waits for a service stop (three for three stalls on
builds under the live service). Expected effect: `tx_dmean` flat through
the first minute instead of falling 46, TX floor about 150 loaded, no
settle overshoot, level unchanged at 1127; the 1 ms is cashed by a TX
prime 144 block afterwards (B3).

**BUILT and STAGED 2026-09-05 03:44-03:50 UTC: bridge `e6bc98ac`
(`--pitch-seed`), the B2 install set.** The user stopped the service at
about 03:42 UTC (the USB gadget stays up); built on the Pi from
`~/usb-16x16-work/phase4-seed-src` (`main.cpp` `146ed8d8`, Release,
`-Wall -Wextra -Wpedantic -Werror`, zero warnings), ctest 1/1 passed
including `test_estimator_seed`, binary SHA-256
`e6bc98ac967d5958261db410bf7a4057a1c40498f0d9d4d2f595ac2152f280fe`,
copied to `work/phase4-bridge/artifacts/pi-aarch64/` (README updated;
`b65b84ee` is the previous binary). Behaviour at `--pitch-seed 0`, which
every existing profile gets from the supervisor's default, is the previous
binary's. Installers repinned: `install-candidate.sh` `765ce364` (bridge
`e6bc98ac`, wrapper `6282b108` unchanged), `install-aes67-service.sh`
`2e2a8f64` (supervisor `ca2fffb2`, unit `77837e60` unchanged, conf
`196786be`, bridge `e6bc98ac`; `f4ba358f` joins the unedited-shipped
list). Staged on the Pi: `~/usb-16x16-work/phase4-seed-install/` (binary,
wrapper, installer) and `~/usb-16x16-work/aes67-seed15-install/`
(supervisor, unit, conf, installer). The live conf (`b60ea8e6`) is
operator-edited, so the service installer will keep it and leave the
shipped conf beside it as `.new`; the seed15 block goes in by hand as
before. Install order, service stopped: `install-candidate.sh`, then
`install-aes67-service.sh`, then start. Rollback: the previous binary
`b65b84ee` is in git history and `switch-profile` to any block without
`PITCH_SEED_PPM` runs the new binary at seed 0.

**CORRECTION 2026-09-05 03:55 UTC: the B2 install failed on the
supervisor's own bridge pin.** The user ran both installers and appended
the seed15 block (live conf `d9843c95`, `PROFILE=...-target64-seed15`);
the service then failed five times in 300 s with exit 27, `FAIL Phase 4
bridge hash or ownership mismatch`: the supervisor pins the bridge hash
itself (`expected_bridge_sha256`, line 43) and the staged supervisor
`ca2fffb2` still carried `b65b84ee`. Missed when the two installers were
repinned. Fixed: supervisor `45651a81` (pin `e6bc98ac`, nothing else
changed), service installer `1912e86e`, both restaged in
`~/usb-16x16-work/aes67-seed15-install/`, `profiles` against the live conf
exit 0. The user re-runs `install-aes67-service.sh` and restarts the
service. Add to the repin list for any new binary: the supervisor's pin as
well as both installers.

**MEASURED 2026-09-05 03:49-04:21 UTC: Phase 5 Stage B2, the pitch seed
works, and it moves the margin from RX to TX rather than creating it.**
After the supervisor fix the user re-ran `install-aes67-service.sh` and
restarted; session 03:49:10 UTC on
`servo-aligned-both-240-rx120-sd144-tx192-target64-seed15` (bridge
`e6bc98ac`, supervisor `45651a81`, live conf `d9843c95`): `PITCHSERVO
seeded ppm=-15 pitch=1000015`, ALIGN ok attempt 1, TX PRIMED
`queue_prime=192 align_dropped=71 overshoot=6 front_age_frames=336`, RX
PRIMED `ring_at_prime=192 overshoot=5`, `PITCHSERVO engaged
setpoint_frames=160 ppm=-14.8021` at 60 s: the first rate observation
landed on the seed, no slew, no overshoot, pitch 1000011-1000018 for the
whole session. `tx_dmean` 289 at 1 s, 297 at 60 s, 293 at 120 s, 294 at
the end: the 46-frame warm-up fall is gone, as designed. RTL Utility at 32
frames, read by the user at session start: **26.875 ms**. Gate probe
(`seed15gate-noise-ch2-64f-100imp` in `usb-holes-20260904/`) 0.0% zeros,
no run of 4 or more. Then the chain, harness alone:

| run | file | frames | samples | ms | levels | score | tx_qfloor | rx_qfloor | tx_pullmax | RECOVERs |
|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|
| 1 | `seed15-roundtrip-64f-20260905T035625Z` | 64 | 1102 | 22.958 | 1102 x800 | 1.000 | 160 | 51 | 48 | 0 |
| 2 | `seed15-roundtrip-64f-20260905T040001Z` | 64 | 1102 | 22.958 | 1102 x800 | 1.000 | 160 | 50 | 48 | 0 |
| 3 | `seed15-roundtrip-64f-20260905T040337Z` | 64 | 1102 | 22.958 | 1102 x800 | 1.000 | 160 | 50 | 48 | 0 |
| 4 | `seed15-roundtrip-64f-20260905T040712Z` | 64 | 1102 | 22.958 | 1102 x800 | 1.000 | 160 | 50 | 48 | 0 |
| soak | `seed15soak-roundtrip-64f-20260905T041048Z`, `USB16X16_OTHER_LOAD=0.1`, 600 s | 64 | 1102 | 22.958 | 1102 x2400 | 1.000 | 160 | 50 | 48 | 0 |

5600 impulses on one sample, spread 0, zero RECOVERs (recovers file
empty, no RECOVER line), zero restarts, clips, drops, `tx_qlow` and
`rx_qlow` 0 on all 1771 BRIDGE lines of the 30-minute session, detector 0
runs, gaps 1.06/1.63 ms, `tx_pullmax` 48, `rx_pullmax` 49 (no 96 pull this
session). Full-rate log
`outputs/latency/phase5-20260905/bridge-seed15-session-20260905T034910Z.log`.

*The floors.* TX: 198 primed, 162 from 16 s, 160 loaded and held through
every run and the soak, against target64's 108 loaded: the seed kept the
46 the warm-up drift used to take, plus a few. RX: 77 at prime as the
arithmetic says, 74 at 6 s, then 71, 69, 67, 66 through the first loaded
run and 50 at 586-587 s (03:58:57 UTC, during run 1), held there for the
rest. On target64 RX gained 43 frames during warm-up and its floor never
moved from 77; here RX stays at its primed level and carries the loaded
dips alone. Depth is conserved and the seed only chooses the split: the
level loop holds the differential where it sat at engagement (160 here,
67 on target64, both by design), so the seed moved about 50 frames of
loaded margin from RX to TX. One 96-frame host pull at the worst phase
would leave RX 2. Not a point of record on its own.

*The level.* 1102, 25 under target64's 1127, and RTL 26.875 against
27.396, the same 25 on both instruments. Servo-held depth is invisible on
the device timeline, so this should have been 1127; the difference is
inside the session-start band (31 wide on rx120) and is one session. A
seeded session cannot slide its USB phase against the tick grid during the
first minute (rates locked from t=0, where an unseeded one slides a full
period in about 67 s at 15 ppm), which is a candidate mechanism for the
band itself. Recorded, not explained.

*What B3 is now.* With the seed the split is set by the primes and held.
Three ways to spend the 50 TX frames, all conf-only: (a) TX prime 144
alone: floors about 112/50, level about 1054, RX too thin; (b) RX prime
into the 240 bin (126-173) alone: floors 160/98, level about 1150; (c)
both: floors about 112/98, level unchanged at about 1102, both over
their bars. Or (d) a bridge flag for an explicit mode-1 level setpoint
(the differential bias of the 2026-09-02 record, now pointed the other
way) that moves servo-held depth from TX to RX for free on the device
timeline: about 30 frames each way gives floors about 130/80 at 1102
with no prime change. (c) is the conf-only path; (d) is the one that pays
without giving anything back. Conf `ed23c829` carries the seed15 block
with its MEASURED and COVER strings (installer `71513f2b`, `196786be`
joins the unedited-shipped list), `STATUS=experimental`.

**STAGED 2026-09-05 04:35 UTC: Phase 5 Stage B3, profile
`servo-aligned-both-240-rx120-sd144-tx192-target64-seed15-primes144`**
(seed15 with `TX_PLAYBACK_PRIME=144` and `RX_PLAYBACK_PRIME=144`, the two
primes moved as one step because they trade against each other;
experimental). The user's direction: the lowest latency that is still
stable. seed15 holds the level (1102) but leaves RX at floor 50; this block
hands 48 of the seed's TX surplus to RX through the primes, so the level
should stay at 1102 with both floors over their bars: TX about 112 loaded
(160 minus 48), RX 125 at prime (the RX prime lands `target + prime + 3 =
211` in the 240 bin) and about 98 after the loaded dips. The alternative,
a mode-1 level-setpoint flag, would give about 130/80 at the same level
but needs a build and leaves RX where target64 ran; this one is conf-only
and more even. Repo conf `1099fbe1` (installer `289e543e`, `ed23c829`
joins the unedited-shipped list); block staged as
`~/usb-16x16-work/aes67-seed15-install/primes144-block.conf` (`00ec9db8`)
and validated with `profiles` against the live conf plus the block and
against the repo conf on the Pi, exit 0, listed `prime 96/tx 144/rx 144
... seed -15 ppm`. Goes in by hand and `switch-profile` restarts the
stack. Rollback is `switch-profile
servo-aligned-both-240-rx120-sd144-tx192-target64` (accepted, floors
108/77) or `...-target64-seed15` (160/50).

**GATE FAILED, then a Mac-side hole state, 2026-09-05 10:52-11:02 UTC:
`...-target64-seed15-primes144` is unmeasured, and a new rule.** The user
appended the block (live conf `f0c14c0e`) and switched at 10:52 UTC; RTL
Utility at 32, read at session start: 26.667 ms. The session primed as
designed: RX PRIMED `intended=211 ring_at_prime=240 overshoot=29
queue_prime=144` (the 240 bin), TX PRIMED `queue_prime=144
align_dropped=69 front_age_frames=288`, `PITCHSERVO seeded` and engaged on
-14.78 at 60 s, `rx_qfloor` 96 and `tx_qfloor` 115 unloaded, zero
RECOVERs. The 64-frame gate probe then read **8.4% zeros**, 14839 runs of
4-9 samples at offsets 4 and 36 mod 64, and a second probe 12.0% at 0 and
32 (`primes144gate-` and `primes144gate2-noise-ch2-64f-100imp` in
`usb-holes-20260904/`); the chain was not launched. On the Pi the zero-run
detector (its first real use) placed the holes: 8 exact zeros every 96
frames on channels 1-2 at `usb-capture`, the Mac-to-Pi leg, from
10:54:08.972 UTC, the second my first probe opened the device, carried
unchanged through `ravenna-playback`, round the Ferrofish and back
(`ravenna-capture`, `usb-playback`), about 500 events a second, the
8192-line cap reached; `tx_qfloor`/`rx_qfloor`/pitch/RECOVERs untouched,
so the frame rate was right and the zeros were inside the frames the Mac
sent. The user heard it as jitter and a digital mismatch on playback. The
gadget's OUT path advances by `req->actual` and never zero-fills (Pi
`u_audio.c`), which put the maker on the Mac's output engine. Rolled back
to target64 at 10:58:31 UTC: the holes continued on the fresh session
(15501 events in its first 31 s), so not the profile. Cleared by the user
at about 11:02 UTC with `sudo killall coreaudiod` on the Mac and `sudo
systemctl restart usb-16x16` on the Pi in immediate succession (which one
did it is not known); the AES67 stack restarted itself on the host loss
and the target64 session of 11:02:20 UTC runs with `zr_usbcap` 0, floors
154/77 unloaded, gadget re-bound `req_number=4`, `configured/high-speed`.
The short counters (`tx_short`/`rx_short`) that looked alarming read the
same in every session and are the behaviour-free mmap-begin accounting,
not a symptom. Logs:
`outputs/latency/phase5-20260905/bridge-primes144-session-20260905T105239Z.log`.

What is different about this probe: it was the first gate ever run while
the user's playback was live on the device (every earlier probe ran with
the Mac idle apart from the harness). The stopgap reading is that two
CoreAudio clients, one changing the IO buffer to 64, put AppleUSBAudio's
output into a state that survived the Pi-side restarts. **Rule: no harness
probe or measurement while the user is playing audio through the device;
ask first.** primes144 is unmeasured, not failed: the point primed and
held exactly as predicted before the probe, and its acceptance runs need
a clean Mac (playback idle) and a fresh session. Conf `6ce387f4`
(installer `f25b8689`, `1099fbe1` joins the unedited-shipped list) carries
that in the block's MEASURED string. The point of record stays target64.

**MEASURED 2026-09-05 11:06-12:05 UTC: `...-target64-seed15-primes144`
is stable with both floors over their bars, and 29 samples slower than
target64.** Second session of the block, playback idle throughout (the new
rule), switch at 11:06 UTC: `PITCHSERVO seeded`, RX PRIMED `intended=211
ring_at_prime=240 overshoot=29 queue_prime=144`, TX PRIMED `queue_prime=144
align_dropped=74 overshoot=3`, engaged on -14.77 at 60 s. Gate probe
(`primes144gate3-noise-ch2-64f-100imp`) 0.0% zeros, no runs. The chain's
first launch never ran (the chain script had only been written inside the
branch the spoiled gate skipped; 30 minutes idle, nothing else affected);
relaunched 11:39 UTC:

| run | file | frames | samples | ms | levels | score | tx_qfloor | rx_qfloor | tx_pullmax | RECOVERs |
|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|
| 1 | `primes144-roundtrip-64f-20260905T113932Z` | 64 | 1156 | 24.083 | 1156 x800 | 1.000 | 110 | 98 | 48 | 0 |
| 2 | `primes144-roundtrip-64f-20260905T114308Z` | 64 | 1156 | 24.083 | 1156 x800 | 1.000 | 110 | 98 | 48 | 0 |
| 3 | `primes144-roundtrip-64f-20260905T114644Z` | 64 | 1156 | 24.083 | 1156 x800 | 1.000 | 110 | 98 | 48 | 0 |
| 4 | `primes144-roundtrip-64f-20260905T115021Z` | 64 | 1156 | 24.083 | 1156 x800 | 1.000 | 110 | 98 | 48 | 0 |
| soak | `primes144soak-roundtrip-64f-20260905T115357Z`, `USB16X16_OTHER_LOAD=0.1`, 600 s | 64 | 1156 | 24.083 | 1156 x2400 | 1.000 | 110 | 96 | 48 | 0 |

5600 impulses on one sample, spread 0, zero RECOVERs, restarts, clips,
drops, `tx_qlow` and `rx_qlow` 0 on all 3524 lines of the 59-minute
session, detector 0 runs, gaps 1.44/1.63 ms, pitch 1000010-1000019,
`tx_pullmax` 48, one 96-frame RX pull at 1729 s (11:35 UTC) that took
`rx_qfloor` from 98 to 96 exactly. Full-rate log
`outputs/latency/phase5-20260905/bridge-primes144-session-20260905T110616Z.log`.

*Floors:* TX 147 primed, 111 from 16 s, 110 loaded (the 144 prime gave
back 50 of seed15's 160, as priced). RX 125 at prime, exactly the
`240 - 64 - 51` the bin arithmetic predicted, 117 by 12 s, 98 through the
loaded runs, 96 after the double pull: the first point whose RX floor sits
at the 96 bar with a double pull already absorbed. Stable by every gate
this record uses.

*Level:* 1156, 29 over target64 (1127) and 54 over seed15 (1102). The RX
bin move shows at its full 48 and the TX prime step, which moved
`front_age_frames` 336 to 288, did not give its 48 back on the device
timeline. Not explained. Two more things the level says: the earlier
primes144 session (10:52 UTC) read RTL 26.667 at 32 before its gate was
spoiled, which is 1092-1102 in harness terms, so this profile's level
differs by about 55 between its two sessions, well outside the 31-wide
session-start band seen on rx120; and on this session `tx_dmean` rose 48
over the hour (238 to 285) while `rx_dmean` fell 26, with the level loop
holding its 61-frame setpoint, which is servo-held motion and by the
2026-09-03 result invisible to the harness. The RTL reading for this
session is owed.

*Standing:* three points now measured on the seed binary. target64 (1127,
floors 108/77, accepted) is the lowest stable level; seed15 (1102, 160/50)
is lower but RX-thin; primes144 (1156, 110/96) is the safest and 0.6 ms
slower. The conf-only rebalance therefore does not pay on latency. The
lever left in B3 is the mode-1 explicit level setpoint (a bridge flag):
move about 30 frames of servo-held depth from TX to RX on seed15, floors
about 130/80 at 1102, no prime change, invisible on the device timeline by
the 2026-09-03 result. Conf `1ae47899` (installer `d0605556`, `6ce387f4`
joins the unedited-shipped list) carries the block's MEASURED and COVER
strings, `STATUS=experimental`.

**RTL Utility at 32 frames on the primes144 session of 11:06 UTC, read by
the user at about 12:10 UTC: 28.000 ms**, 0.604 ms (29 samples) over
target64's 27.396, the harness difference (1156 against 1127) to the
sample. So the level of that session is confirmed on both instruments, and
the 26.667 read on the block's first session (10:52 UTC, gate spoiled) is
a real 64-sample difference between two sessions of one block, twice the
31-wide band seen on rx120. Recorded; the session-start term is now the
largest unexplained number in the budget.

**IMPLEMENTED 2026-09-05 12:20 UTC, not yet built: Phase 5 Stage B3 by the
level lever, bridge `--level-shift FRAMES` and profile
`...-target64-seed15-shift30`.** Bridge: `--level-shift FRAMES` (double,
-480..480, default 0, mode 1 only; refused with mode 2 or without the
servo): the mode-1 setpoint captured at engagement becomes the captured
differential minus twice FRAMES, so a positive shift walks FRAMES of
servo-held depth from usb-to-ravenna to ravenna-to-usb at the level loop's
3 ppm clamp (about 200 s for 30); the `PITCHSERVO engaged` line now carries
`captured_frames=` and `level_shift=`, the enabled line `level_shift=`,
SUMMARY `level_shift_frames`. `main.cpp` `29e7c9b7`, syntax-checked clean
on the Mac. Supervisor: optional key `LEVEL_SHIFT_FRAMES` (absent 0,
number, non-zero needs `USB_PITCH_SERVO=1`), passed as `--level-shift`,
shown by `profiles` as `shift N` (`710a0d71`). Conf `705c7906` adds the
block (seed15 with `LEVEL_SHIFT_FRAMES=30`, experimental; installer
`e55c0e41`, `1ae47899` joins the unedited-shipped list), validated on the
Pi against the repo conf and the live conf plus the block, exit 0. Source
in `~/usb-16x16-work/phase4-shift-src`, block and supervisor in
`~/usb-16x16-work/aes67-shift30-install/`. Premise, from the 2026-09-03
depth sweep: servo-held depth does not move the round trip, so the level
should stay at seed15's 1102 with floors about 130/80; the level not
moving is itself part of the acceptance. Build waits for a service stop.
Repin list for the new binary: `install-candidate.sh`,
`install-aes67-service.sh`, and the supervisor's own
`expected_bridge_sha256`.

**BUILT and STAGED 2026-09-05 12:30 UTC: bridge `006fc65e`
(`--level-shift`), the B3 install set, all three pins moved.** Service
stopped by the user at about 12:27 UTC; built on the Pi from
`~/usb-16x16-work/phase4-shift-src` (`main.cpp` `29e7c9b7`, Release,
zero warnings), ctest 1/1, binary SHA-256
`006fc65e5ae4d61b81e3aa2dbd468182ca2644f07deb11c30e8edc169511d622`, in
`work/phase4-bridge/artifacts/pi-aarch64/` (README updated, `e6bc98ac`
previous). At `--level-shift 0`, the supervisor default for every block
without `LEVEL_SHIFT_FRAMES`, behaviour is `e6bc98ac`'s. Pins: supervisor
`expected_bridge_sha256` (the one missed on B2) now `006fc65e`, supervisor
`d46202b0`; `install-candidate.sh` `c3843e21` (bridge `006fc65e`, wrapper
`6282b108`); `install-aes67-service.sh` `ac55c1ea` (supervisor `d46202b0`,
unit `77837e60`, conf `705c7906`, bridge `006fc65e`). Staged:
`~/usb-16x16-work/phase4-shift-install/` and
`~/usb-16x16-work/aes67-shift30-install/` (with `shift30-block.conf`
`45d22160`); the new supervisor validates the live conf, exit 0. Install
order, service stopped: `install-candidate.sh`, `install-aes67-service.sh`
(keeps the operator-edited live conf), append the block, `switch-profile`
(writes PROFILE only while inactive), `systemctl start`.

**HARD STOP 2026-09-05 12:13:20 UTC, unexplained; then MEASURED
12:19-12:51 UTC: `...-target64-seed15-shift30` is stable at 1154, and the
seed binary's level sits on two shelves 52 apart with identical primed
depths.** The user ran the B3 installs (bridge `006fc65e`, supervisor
`d46202b0`, wrapper `6282b108`, all verified on the Pi afterwards),
appended the block (live conf `d23ed9ed`), selected shift30 and started
the service at about 12:13:05 UTC. The journal of that boot ends
mid-line at 12:13:20, the daemon answering its API poll normally, no
kernel message, no shutdown: about ten seconds after the stack started
and within a second of when the bridge would have launched. The Pi came
back at 12:18:02 on its own (the user did not power-cycle it), so a
hang-plus-watchdog or a power event; nothing in either boot's kernel log
says which. First hard stop in the record, coincident with the first
start of `006fc65e`; the same binary and profile then started cleanly on
the new boot and ran the whole measurement below, so it is not
deterministic. wlan0 failed at boot (`no-secrets` race in
NetworkManager) and reconnected on its own retry at about 12:22 UTC; the
Pi was reached over `eth0` `169.254.92.97` meanwhile. Watch for a repeat
before trusting the binary in service.

The 12:19:54 UTC session on shift30: seeded, RX PRIMED `ring_at_prime=192
overshoot=5 queue_prime=120`, TX PRIMED `align_dropped=65
front_age_frames=336` (both identical to the seed15 session of 03:49),
`PITCHSERVO engaged setpoint_frames=117 captured_frames=177
level_shift=30`; the level loop walked at its clamp and then hunted
between -2.3 and +3.0 ppm under load. RTL Utility at 32, read by the user
at about 12:24 UTC: **27.958 ms**. Gate probe
(`shift30gate-noise-ch2-64f-100imp`) 0.0% zeros (RTL Utility had been
open moments before; no harm this time). Chain:

| run | file | frames | samples | ms | levels | score | tx_qfloor | rx_qfloor | tx_pullmax | RECOVERs |
|---|---|---:|---:|---:|---|---:|---:|---:|---:|---:|
| 1 | `shift30-roundtrip-64f-20260905T122549Z` | 64 | 1154 | 24.042 | 1154 x800 | 1.000 | 156 | 66 | 48 | 0 |
| 2 | `shift30-roundtrip-64f-20260905T122924Z` | 64 | 1154 | 24.042 | 1154 x800 | 1.000 | 156 | 66 | 48 | 0 |
| 3 | `shift30-roundtrip-64f-20260905T123259Z` | 64 | 1154 | 24.042 | 1154 x800 | 1.000 | 156 | 66 | 48 | 0 |
| 4 | `shift30-roundtrip-64f-20260905T123634Z` | 64 | 1154 | 24.042 | 1154 x800 | 1.000 | 156 | 66 | 48 | 0 |
| soak | `shift30soak-roundtrip-64f-20260905T124009Z`, `USB16X16_OTHER_LOAD=0.1`, 600 s | 64 | 1154 | 24.042 | 1154 x2400 | 1.000 | 119 | 66 | 48 | 0 |

5600 impulses on one sample, spread 0, zero RECOVERs, restarts, clips,
drops, `tx_qlow` and `rx_qlow` 0 on all 1867 lines, detector 0 runs, gaps
1.14/1.63 ms, pitch 1000010-1000020, one 96 RX pull. Log
`outputs/latency/phase5-20260905/bridge-shift30-session-20260905T121954Z.log`.
RTL 27.958 against target64's 27.396 is 27 samples, the harness
difference (1154 against 1127) to the sample.

*Floors:* TX 156 unloaded, 119 in the soak; RX 66 from 16 s and never
lower under any load (seed15 went to 50): the shift bought RX 16 and
cost TX 41 and did not reach its 30, because the loaded dips kept the
level loop at its clamp. Stable by every gate, and no better than
target64 (108/77) on RX.

*Level, the finding:* 1154 with primed depths identical to the seed15
session that measured 1102 (same RX ring fill 192, same TX
`front_age_frames` 336, same `align_dropped`). Either the servo-held
shift moved the round trip, against the 2026-09-03 depth sweep, or the
seeded binary's sessions land on two shelves: 1092-1102 (seed15 03:49,
primes144 10:52 by its RTL 26.667) and 1154-1156 (primes144 11:06,
shift30 12:19), 52-64 apart, one period plus a few. The 2026-09-03 sweep
moved servo depth by 48 inside one session and the level did not move,
so the shelves reading is the one the record supports, and their size
points at the one start phase the bridge does not align: the RX prime
(`front_age_frames -1`, the open item since 2026-09-04). A session that
draws the low shelf is 1.1 ms better than one that draws the high one,
which is more than any lever measured today. Aligning the RX prime is
therefore the next build: it makes the RX side's start phase a constant
like TX's, and if the shelves are that phase, every session lands on the
low one.

*Standing:* target64 (1127, RTL 27.396, floors 108/77, accepted) remains
the point of record. seed15 (1102, 160/50), primes144 (1156, 110/96) and
shift30 (1154, 119/66) are measured and stay experimental. Conf
`3f087d41` (installer `323becec`, `705c7906` joins the unedited-shipped
list). Rollback for service is `switch-profile
servo-aligned-both-240-rx120-sd144-tx192-target64`.

**RTL Utility at 32 frames on target64, session of 12:53 UTC, read by the
user: 28.104 ms**, 0.708 ms (34 samples) over the 27.396 the point was
accepted on. So the session lottery is on the accepted point too, with
the same PRIMED numbers, and it is about a period wide: the record's
"session-start term" is not a seed effect and not a bridge-depth effect.

**IMPLEMENTED 2026-09-05 13:10 UTC, not yet built: the aligned RX trigger
and prime, bridge `--align-rx-trigger`, `--align-rx-offset-us`,
`--align-rx-prime`, and profile `...-target64-rxalign`.** Reading of the
shelves: every point measured today lands 34-64 samples apart between
sessions with identical PRIMED numbers (target64 27.396 and 28.104; seed15
1102 and shift30 1154 with the same ring fill 192, overshoot 5, TX
`front_age_frames` 336 and `align_dropped` 65). The RX playout is drained
by the host on its own 1 ms USB frames, and the RAVENNA tick grid is
redrawn at every stack start, so the phase between the two is a
per-session draw of up to one frame on RX: the one start phase the bridge
never aligned (the `front_age_frames -1` item open since 2026-09-04). The
build mirrors TX with the roles swapped. Bridge: RX gets
`tick_source = &tx` (the USB capture's fresh wakes, its period wakes being
locked to the host's frames), a fixed 1 ms tick (`kUsbFrameTickNs`, 48
frames at 48 kHz whatever the negotiated period), the same
`align_playback_trigger` before the USB playback start and the same
prime-time drop computation, so RX PRIMED reports `prime_phase_us`,
`first_tick_wait_us`, `front_age_frames` and `align_dropped` like TX. RX
has no start-alignment seed for that grid, so a prime that finds no fresh
USB wake yet holds for up to 5 ms (`kAlignPrimeReferenceWaitNs`, five
frames, within the ring) and then primes unaligned with an `ALIGN prime
... status=unaligned reason=no-reference-wake` line; TX's path is
unchanged (it always has a seed). Options validated like TX's
(`--align-rx-trigger` needs `--align-start 1`, the prime needs the
trigger, offset 0..10000). SUMMARY carries `align_rx_*`. `main.cpp`
`91fbea05`, syntax-checked clean on the Mac. Supervisor: keys
`ALIGN_RX_TRIGGER`, `ALIGN_RX_OFFSET_US`, `ALIGN_RX_PRIME` (absent 0/600/0,
validated like the TX keys), passed through, shown by `profiles` as `rx
trigger N/M us prime P` (`6c97e61b`). Conf `db094139` adds the block on
the accepted target64 base with the three RX keys on, no seed, one lever
(installer `8f85ea4f`, `3f087d41` joins the unedited-shipped list);
validated on the Pi against the repo conf and the live conf plus the
block, exit 0. Source in `~/usb-16x16-work/phase4-rxalign-src`, block and
supervisor in `~/usb-16x16-work/aes67-rxalign-install/`. Acceptance for
this lever is different: two sessions, each with the gate, four loaded
800-impulse runs and the soak, and the two levels equal; below or at
target64's 27.4 is the expectation. Build waits for a service stop; the
pin list is the supervisor's `expected_bridge_sha256` and both installers.

**BUILT and STAGED 2026-09-05 13:20 UTC: bridge `98eeb083` (aligned RX
trigger and prime), the rxalign install set, all three pins moved.**
Service stopped by the user at about 13:17 UTC; built on the Pi from
`~/usb-16x16-work/phase4-rxalign-src` (`main.cpp` `91fbea05`, Release,
zero warnings), ctest 1/1, binary SHA-256
`98eeb083a80900b6234f610adc5566af1bc00fb7e1a461dbc1b2245366bb69c5`, in
`work/phase4-bridge/artifacts/pi-aarch64/` (README updated, `006fc65e`
previous). With the three RX keys absent, which every existing block has,
behaviour is `006fc65e`'s. Pins: supervisor `expected_bridge_sha256`
`98eeb083`, supervisor `a2caefbf`; `install-candidate.sh` `8ecf130b`
(bridge `98eeb083`, wrapper `6282b108`); `install-aes67-service.sh`
`a997bab7` (supervisor `a2caefbf`, unit `77837e60`, conf `db094139`,
bridge `98eeb083`). Staged: `~/usb-16x16-work/phase4-rxalign-install/`
and `~/usb-16x16-work/aes67-rxalign-install/` (with `rxalign-block.conf`
`3bac7e74`); the new supervisor validates the live conf, exit 0. Install
order, service stopped: `install-candidate.sh`, `install-aes67-service.sh`
(keeps the operator-edited live conf), append the block, `switch-profile`
(writes PROFILE only while inactive), `systemctl start`. The previous
binary's first start coincided with the hard stop of 12:13 UTC; watch
this one's first start the same way.

**MEASURED 2026-09-05 13:04-13:59 UTC, two sessions: the aligned RX
prime holds its constant (RX `front_age_frames` 264 from two different
draws), the sessions land 13 samples apart where unaligned points landed
34-64 apart, and the constant costs 75-88 over target64's low draw.**
Installs by the user (bridge `98eeb083`, supervisor `a2caefbf`, live conf
with the rxalign block), profile `...-target64-rxalign`, playback idle
throughout, no hard stop this time.

Session 1 (13:04:30 UTC): RX PRIMED `ring_at_prime=234 overshoot=47
align_dropped=6 prime_phase_us=362 first_tick_wait_us=637
front_age_frames=264` (the prime held for the first USB reference, so the
ring took one more push), `ALIGN trigger direction=ravenna-to-usb
status=ok source=fresh-wake wake_to_start_us=602`; TX PRIMED
`align_dropped=64 front_age_frames=336`. Gate
(`rxalign1gate-noise-ch2-64f-100imp`) 0.0% zeros. Session 2 (13:33:40
UTC, `systemctl restart`): RX PRIMED `ring_at_prime=190 overshoot=3
align_dropped=50 prime_phase_us=454 first_tick_wait_us=1545
front_age_frames=264`, trigger ok fresh-wake 602 us; TX `align_dropped=69
front_age_frames=336`. Gate (`rxalign2gate-`) 0.0% zeros. Different
draws of the wait (637 and 1545 us), different drops (6 and 50), the same
front age both times: the mechanism does what the TX one does.

| session | run | file | samples | ms | levels | score | tx_qfloor | rx_qfloor | RECOVERs |
|---|---|---|---:|---:|---|---:|---:|---:|---:|
| 1 | 1-4 | `rxalign1-roundtrip-64f-20260905T130714Z`, `131049Z`, `131424Z`, `131759Z` | 1215 | 25.312 | 1215 x800 each | 1.000 | 109 | 96 | 0 |
| 1 | soak | `rxalign1soak-roundtrip-64f-20260905T132134Z`, 600 s loaded | 1215 | 25.312 | 1215 x2400 | 1.000 | 109 | 96 | 0 |
| 2 | 1-4 | `rxalign2-roundtrip-64f-20260905T133429Z`, `133805Z`, `134140Z`, `134515Z` | 1202 | 25.042 | 1202 x800 each | 1.000 | 107 | 96 | 0 |
| 2 | soak | `rxalign2soak-roundtrip-64f-20260905T134850Z`, 600 s loaded | 1202 | 25.042 | 1202 x2400 | 1.000 | 107 | 96 | 0 |

11200 impulses, spread 0 within each session, zero RECOVERs, restarts,
clips, drops, `tx_qlow` and `rx_qlow` 0 on all 1658 + 1545 lines,
detector 0 runs, `tx_pullmax` 48, gaps 1.10/1.64 ms. Logs
`outputs/latency/phase5-20260905/bridge-rxalign1-session-20260905T130430Z.log`
and `bridge-rxalign2-session-20260905T133340Z.log`.

*Floors:* RX 96 from the first second on both sessions and never lower
under any load, the first point to hold the RX bar through everything
(target64 reads 77 by the bin arithmetic; the aligned prime's held ring
puts RX in the next bin at 264 - 64 - 51 = 149 minus the loaded dips).
TX 109/107 loaded, as target64.

*Level:* 1215 and 1202. The 13-sample residue is the lottery that remains
(two microframes' worth; the host's 125 us pull grain or the Ferrofish
side), against 34 on target64 and 52-64 on the seed points. The cost is
the constant itself: the aligned prime holds the front frame's age at
`prime + longest wait` (187 + 77 = 264), so every session pays the
worst-case draw where target64 pays its actual draw (1127 on a good day,
1161 on a bad one). Structurally a deterministic RX cannot beat the
lottery's best draw this way; it can only match its worst, and at
`margin 200 us + 2 ticks - offset 600 us = 1.6 ms` of wait allowance it
sits 40-50 above even that. Two ways to spend this: (a) tighten the
allowance (offset 950 us and a 50 us margin bring the longest wait from
77 to about 50 frames, worth about 25), conf plus a constant; (b) the
other use of a measured phase: instead of paying for the worst draw,
re-roll it. The RAVENNA tick grid is redrawn at every bridge start (the
driver logs `base period set` on each PCM open), so a bridge that exits
with a distinct code when its RX prime phase falls outside a chosen
window, and a supervisor that restarts the bridge alone on that code
(one second, no stack restart), would land every session on the best
draw, about 1127 or below, at RX floor 96. That is the lever this
measurement makes possible and it is where the record points next. Conf
`c7092ea1` carries the block's MEASURED and COVER (installer `3d7b5da8`,
`db094139` joins the unedited-shipped list), `STATUS=experimental`.

*Standing for service:* target64 (accepted, 1127-1161 by the draw, RX
77) remains the lowest; rxalign (1202-1215, RX 96) is the most
predictable and the safest. The user's call which runs tonight.

**RTL Utility at 32 frames on rxalign session 2, read by the user at
about 14:00 UTC: 28.958 ms**, 1.562 ms (75 samples) over target64's
27.396, the harness difference (1202 against 1127) to the sample.

**IMPLEMENTED 2026-09-05 14:20 UTC, not yet built: the grid-phase
instrument and the RX prime phase window (the re-roll, done as a wait).**
Why a wait and not a restart: the RAVENNA tick grid follows PTP and the
host's USB frame grid is the Mac's own crystal, so their phase slides
through a full 1 ms cycle at the offset the pitch servo corrects in the
data rate, about 15 ppm, one cycle per 67 s or so. A bridge restart
takes two seconds and would land where it started; holding the prime
until the phase is where the level is best is the mechanism that picks
the draw. Nothing in the record maps phase to level yet, so the build is
two parts. (1) Instrument, always on: `phase_us` in every BRIDGE line,
the RX capture's last fresh wake against the USB capture's last fresh
wake modulo one USB frame (`grid_phase_ns` in `bridge_core.hpp`, unit
tested with `phase_in_window`), and `grid_phase_us=` on both PRIMED
lines, so every session from here records the phase it primed at and
the harness level then maps it. (2) `--rx-prime-phase-window LOW,HIGH`
(microseconds, HIGH < LOW wraps) with `--rx-prime-phase-timeout-s N`
(default 80, at least one full slide): the RX prime holds while the phase
is outside the window, popping the ring down to the prime level each
wake so the capture never overflows it (the discarded frames are
counted; no playback has started), then primes with a `PRIME window
direction=ravenna-to-usb status=hit|timeout phase_us= waited_ms=
discarded=` line. Needs `--align-start 1`; independent of the RX
alignment flags, so it can run on the plain target64 base where the
level follows the draw. SUMMARY carries `rx_prime_grid_phase_us`,
`rx_prime_phase_window`, `rx_prime_phase_discarded`. `main.cpp`
`687db660`, `bridge_core.hpp` and `bridge_tests.cpp` changed,
syntax-checked clean on the Mac. Supervisor: optional keys
`RX_PRIME_PHASE_WINDOW` (`LOW,HIGH`, needs `ALIGN_START=1`) and
`RX_PRIME_PHASE_TIMEOUT_S` (1..600, default 80), passed only when a
window is set, shown by `profiles` as `phase window LOW,HIGH/N s`
(`f3e2b55f`, installer `baa523a5`, conf `c7092ea1` unchanged); validated
on the Pi against the repo conf and the live conf, exit 0. No new
profile block yet: the first use is observation on target64 (the level
follows the draw there), several sessions with `grid_phase_us` and the
harness level, then a window block. Source in
`~/usb-16x16-work/phase4-phase-src`, supervisor in
`~/usb-16x16-work/aes67-phase-install/`. Build waits for a service stop;
pin list as before.

**BUILT and STAGED 2026-09-05 14:35 UTC: bridge `abab6732` (grid-phase
instrument and RX prime phase window), all three pins moved.** Service
stopped by the user at about 14:32 UTC; built on the Pi from
`~/usb-16x16-work/phase4-phase-src` (`main.cpp` `687db660`, Release,
zero warnings), ctest 1/1 including `test_grid_phase`, binary SHA-256
`abab6732b1425e41dad29efde9a5c52dfc70819bf7332b0ce82a0ffed2608900`, in
`work/phase4-bridge/artifacts/pi-aarch64/` (README updated, `98eeb083`
previous). With no window key, which every existing block has, behaviour
is `98eeb083`'s plus the `phase_us` field. Pins: supervisor
`expected_bridge_sha256` `abab6732`, supervisor `f94aa06f`;
`install-candidate.sh` `b733552f`; `install-aes67-service.sh` `de1e40f3`
(supervisor `f94aa06f`, unit `77837e60`, conf `c7092ea1`, bridge
`abab6732`). Staged: `~/usb-16x16-work/phase4-phase-install/` and
`~/usb-16x16-work/aes67-phase-install/`; the new supervisor validates
the live conf, exit 0. Install order, service stopped:
`install-candidate.sh`, `install-aes67-service.sh` (keeps the live
conf), `switch-profile ...-target64` (PROFILE only while inactive), then
`systemctl start`. First use: target64 for several sessions, reading
`grid_phase_us` on the RX PRIMED line and the harness level of each.

**MEASURED 2026-09-05 14:10-14:40 UTC: the grid phase is recorded and
slides as predicted, three target64 sessions drew a 160 us band and the
window is how the rest of the cycle gets sampled.** Bridge `abab6732`
installed by the user, target64. Session 1 (14:10 UTC): RX PRIMED
`grid_phase_us=548`; `phase_us` in telemetry 638, 623, 509, 479, 506, 334
over the first 15 s, about 20 us per second, one cycle in under a minute,
the slide the record predicted from the crystal offset. Harness, 200
impulses at 64 frames: 1137 (`phase1-roundtrip-64f-20260905T141709Z`).
Session 2 (restart): phase 382, level 1132 (`phase2-...T142...Z`).
Session 3 (restart): phase 544, level 1134 (`phase3-...`). All spread 0,
zero RECOVERs. Three draws inside 380-550 us and levels within 5: the
restart sequence takes about the same time every round, so the phase it
lands on clusters, which is why sessions have looked like shelves rather
than a uniform lottery. The rest of the cycle is sampled by choosing it:
profile `...-target64-pw850` (target64 with `RX_PRIME_PHASE_WINDOW=850,950`,
a mapping probe, one 200-impulse read is its deliverable) is staged
(`pw850-block.conf` in `~/usb-16x16-work/aes67-phase-install/`, validated
against the live conf plus the block, exit 0).

**CORRECTION 2026-09-05 14:50 UTC: the pw850 block's window value must be
quoted.** The conf grammar takes bare values from `[A-Za-z0-9_.:/+-]`
only, so `RX_PRIME_PHASE_WINDOW=850,950` is a "bad line" and
`switch-profile` refused it at 14:28 UTC (the user's switch left
`PROFILE=` on target64 and the session running); my `profiles` check
before staging had read the exit code and not the missing listing. Fixed
as `RX_PRIME_PHASE_WINDOW="850,950"` in the repo conf (`b74b9330`,
installer `f1f2b9ec`, `e8ae5e69` joins the unedited-shipped list) and in
the staged block; a copy of the live conf with the line quoted validates
with zero bad lines and lists the block. The live conf gets the same
one-line edit in place. Rule for the record: a window value in a block is
always `"LOW,HIGH"`.

**MEASURED 2026-09-05 14:36-14:42 UTC: the window works, phase 944 read
1150 with 43 frames of hold overshoot on it, and the hold is fixed to
leave the ring where an unheld start does (implemented, not built).**
After the quoting fix the user switched to pw850 at about 14:35 UTC.
Bridge log: `PRIME window direction=ravenna-to-usb status=hit
phase_us=944 window_us=850,950 waited_ms=29338 discarded=1408229`, then
`PRIMED direction=ravenna-to-usb grid_phase_us=944 ring_at_prime=235
overshoot=48` (the plain draws prime at 192, overshoot 5); TX PRIMED
`front_age_frames=336` as always. Harness, 200 impulses at 64
(`pw850-roundtrip-64f-20260905T144013Z`): **1150**, spread 0, zero
RECOVERs; `rx_qfloor` 120 against 77 on every unheld target64 session,
`tx_qfloor` 150. The 43 of extra RX floor is the extra ring: the hold
drained the ring only to the 187 threshold, so the push that crossed it
landed at 235 rather than 192, one 48-frame bin more RX depth, which the
level carries 1:1. Corrected, phase 944 is about 1107, under every unheld
draw (1132-1137 at 382-548 us) by 25-30, so the mapping has the sign the
slide predicted and the far side of the cycle is the low side. Fix
(`main.cpp` `d9502f07`, syntax-checked clean): while holding, the ring is
drained to the largest whole number of capture periods below the prime
level (144 for 187 at period 48), so the crossing push lands at 192
exactly as an unheld start; the `PRIME window` line now also reports
`ring=`. Source staged in `~/usb-16x16-work/phase4-hold-src`. Build
waits for a service stop; then the pw850 read repeats clean, and two more
windows (say 700-800 and 50-150) place the minimum.

**BUILT and STAGED 2026-09-05 15:05 UTC: bridge `2a158386` (hold drains
to whole periods), all three pins moved.** Service stopped by the user at
about 15:02 UTC; built from `~/usb-16x16-work/phase4-hold-src`
(`main.cpp` `d9502f07`, zero warnings), ctest 1/1, SHA-256
`2a1583866f57aeaa7ae986e1ac27705b826347fe86e1f3225dd893107088fcd7`, in
`work/phase4-bridge/artifacts/pi-aarch64/` (README updated, `abab6732`
previous). Pins: supervisor `expected_bridge_sha256` `2a158386`, and both
installers (`install-candidate.sh`, `install-aes67-service.sh`) carry the
new bridge and supervisor hashes; conf unchanged. Staged in
`~/usb-16x16-work/phase4-hold-install/` and
`~/usb-16x16-work/aes67-hold-install/`; the new supervisor validates the
live conf with zero bad lines, exit 0. Install order, service stopped:
`install-candidate.sh`, `install-aes67-service.sh`, then `systemctl
start` (PROFILE is already pw850 in the live conf, so the start lands on
the window and the clean 944 read follows).

**MEASURED 2026-09-05 14:47-14:55 UTC on bridge `2a158386`: the held prime
lands the ring at 192 and phase 944 reads 1107.** Installs by the user,
start on pw850 (the live conf already selected it): `PRIME window
direction=ravenna-to-usb status=hit ring=192 phase_us=944
window_us=850,950 waited_ms=27271 discarded=1309056`, then `PRIMED
direction=ravenna-to-usb grid_phase_us=944 ring_at_prime=192 overshoot=5`,
the unheld numbers exactly; TX `front_age_frames=336`; `rx_qfloor` 77,
`tx_qfloor` 151 unloaded, zero RECOVERs. Harness, 200 impulses at 64
(`pw850b-roundtrip-64f-...`): **1107**, spread 0, the corrected prediction
from the overshoot session (1150 - 43) to the sample. So at phase 944 the
level is 1107 (23.06 ms) against 1132-1137 at 382-548 and target64's
accepted 1127: the window chooses the draw, and the far side of the
cycle is worth 25-30 samples over the plain restarts and 20 over the
best plain draw on record. Two more probes staged to place the minimum:
`...-target64-pw700` (`RX_PRIME_PHASE_WINDOW="700,800"`) and
`...-target64-pw100` (`"50,150"`), block files in
`~/usb-16x16-work/aes67-hold-install/`, validated against the live conf
plus both blocks with zero bad lines. Noted from the previous (old-binary)
pw850 session's last line: `tx_qfloor` 65 late in that session, on the
binary whose hold left the RX ring one bin high; not seen on `2a158386`
(151 at the read); watch it.

**MEASURED 2026-09-05 15:00 UTC: pw700 reads 1094 at phase 765.** `PRIME
window ... status=hit ring=192 phase_us=765 window_us=700,800
waited_ms=40474`, `PRIMED ring_at_prime=192 overshoot=5`, TX
`front_age_frames=336`, floors 150/77 unloaded, zero RECOVERs. Harness,
200 impulses at 64 (`pw700-roundtrip-64f-...`): **1094** (22.79 ms),
spread 0. The map so far: 382 -> 1132, 544 -> 1134, 548 -> 1137, 765 ->
1094, 944 -> 1107. Not a straight 48-per-millisecond ramp: 43 samples
fall between 548 and 765 and 13 rise between 765 and 944, so the level
steps down somewhere between 550 and 765 and climbs slowly after; the
minimum is at or just past that step. pw100 (50-150) is next for the
wrap side; a 600-700 probe may then bracket the step.

**MEASURED 2026-09-05 15:08 UTC: pw100 reads 1157 at phase 67, RX floor
125; the map is a sawtooth and pw600 brackets its step.** `PRIME window
... status=hit ring=192 phase_us=67 window_us=50,150 waited_ms=4`,
`PRIMED ring_at_prime=192 overshoot=5`, TX `front_age_frames=336`,
`rx_qfloor` 125 (the RX queue one bin higher at this phase, as the
aligned RX prime's 240 fill gave), `tx_qfloor` 202, zero RECOVERs.
Harness (`pw100-roundtrip-64f-...`): **1157** (24.10 ms). The map: 67 ->
1157, 382 -> 1132, 544 -> 1134, 548 -> 1137, 765 -> 1094, 944 -> 1107.
High from the wrap through about 550, a drop of about 43 between 550 and
765, a slow climb after. The minimum is just past the drop; pw600
(`RX_PRIME_PHASE_WINDOW="600,700"`, conf `52e82dcb`, installer
`127dc23f`, `c9cce445` joins the unedited-shipped list) brackets it.

**MEASURED 2026-09-05 15:16 UTC: pw600 reads 1098 at phase 695; the map is
complete enough and the operating window is 730-800.** `PRIME window ...
status=hit ring=192 phase_us=695 window_us=600,700 waited_ms=34458`,
`PRIMED ring_at_prime=192 overshoot=5`, TX `front_age_frames=336`, floors
157/77, zero RECOVERs. Harness (`pw600-roundtrip-64f-...`): **1098**
(22.88 ms). The map on bridge `2a158386`, all at ring 192, TX front age
336, 200 impulses each, spread 0:

| phase at RX prime (us) | level | RX floor |
|---:|---:|---:|
| 67 | 1157 | 125 |
| 382 | 1132 | 77 |
| 544 | 1134 | 77 |
| 548 | 1137 | 77 |
| 695 | 1098 | 77 |
| 765 | 1094 | 77 |
| 944 | 1107 | 77 |

A sawtooth: high through about 550, a drop of about 40 between 548 and
695, the floor from 695 to about 950 with its minimum near 765, and the
climb back over the wrap. Plain restarts land in the 380-550 band. The
operating block `...-target64-phase760` (`RX_PRIME_PHASE_WINDOW="730,800"`,
conf `d6f463a6`, installer `6e4765fa`, `52e82dcb` joins the
unedited-shipped list) puts every session on the floor with about 35 us
of margin each side; expected about 1094, RTL at 32 about 26.7 ms. Its
acceptance is the full set plus a second session on the same level.

**MEASURED 2026-09-05 15:30-15:58 UTC: `...-target64-phase760` passes
every run at 1083 (22.562 ms), and its TX floor is 60: the level's
sawtooth and the TX cover's are the same sawtooth.** Switch at about
15:30 UTC: `PRIME window ... status=hit ring=192 phase_us=735
window_us=730,800 waited_ms=33412`, `PRIMED ring_at_prime=192
overshoot=5`, TX `align_dropped=65 front_age_frames=336`. Gate
(`phase760agate-noise-ch2-64f-100imp`) 0.0% zeros. Four 800-impulse runs
(`phase760a-roundtrip-64f-20260905T153328Z`, `153704Z`, `154039Z`,
`154414Z`) and the soak (`phase760asoak-...T154749Z`, 600 s loaded): all
5600 on **1083**, spread 0, zero RECOVERs, restarts, clips, drops,
`tx_qlow` and `rx_qlow` 0 on all 1565 lines, detector 0 runs, gaps
1.15/1.27 ms. Log
`outputs/latency/phase5-20260905/bridge-phase760a-session-20260905T153030Z.log`.
44 under target64's accepted 1127 and the lowest level in the record.

*Floors:* RX 77, as target64. TX 156 unloaded, then 108 at the first run
(78 s), 71, 65 and 60 from 175 s: 48 under target64's loaded 108. The
probes said the same in their unloaded TX floors: about 200 at phases
67-550 (the high shelf) and about 150 at 695-944 (the low shelf). The
phase that puts the level on the floor of its sawtooth puts the TX queue
on the floor of its own, and the two move together by one period: the
session lottery the record has been chasing since the shelves appeared
was a TX-cover lottery all along, and target64's good draws (1127, floor
108) and bad draws (1161, floor about 156) were the same trade. No
underrun in 26 loaded minutes at 60, but 60 is under the bar of one
period plus the worst wakeup gap (about 96-101) and the record does not
accept a point there.

*The operating block that follows:* `...-target64-phase760-tx240`
(phase760 with `TX_PLAYBACK_PRIME=240`, one variable; conf `5a2de43b`,
installer `52257cc5`, `d6f463a6` joins the unedited-shipped list).
48 more TX prime at this phase restores the cover, so the expected level
is about 1131 at floors about 108/77: target64's best draw made
repeatable on every session instead of drawn. If that measures as
expected, the phase window's value is determinism, worth up to 34
samples against the bad draws, and not a lower floor; the lower floor
is only there with less TX cover, which is the same trade every lever
today has run into.

**MEASURED 2026-09-05 16:08-17:15 UTC, two sessions:
`...-target64-phase760-tx240` repeats its level within 4 samples (1122 and
1118) and its TX floor lands at 68-70 on both.** Session 1 (16:08 UTC):
`PRIME window ... status=hit ring=192 phase_us=775 waited_ms=36539`, TX
PRIMED `queue_prime=240 align_dropped=68 front_age_frames=384`. Session 2
(`systemctl restart`, 16:47 UTC): hit at 799 after 25 s, TX
`front_age_frames=384`. Gates (`tx240agate-`, `tx240bgate-`) 0.0% zeros.

| session | phase | runs 1-4 | soak | level | ms | tx_qfloor | rx_qfloor | RECOVERs |
|---|---:|---|---|---:|---:|---:|---:|---:|
| 1 | 775 | `tx240a-roundtrip-64f-20260905T161100Z`, `161436Z`, `161811Z`, `162146Z` | `tx240asoak-...T162522Z` | 1122 | 23.375 | 68 | 77 | 0 |
| 2 | 799 | `tx240b-roundtrip-64f-20260905T164947Z`, `165322Z`, `165658Z`, `170033Z` | `tx240bsoak-...T170408Z` | 1118 | 23.292 | 69 | 77 | 0 |

11200 impulses, spread 0 within each session, zero RECOVERs, restarts,
clips, drops, `tx_qlow` and `rx_qlow` 0 on all 1537 + 1531 lines,
detector 0 runs, `tx_pullmax` 48, gaps 1.10/1.72 ms. Logs
`outputs/latency/phase5-20260905/bridge-tx240a-session-20260905T160830Z.log`
and `bridge-tx240b-session-20260905T164700Z.log`.

*Level:* 1122 and 1118, 4 apart at phases 775 and 799 (the slow climb
of the sawtooth's floor runs the other way over that span, so the
residue is the two-microframe grain seen on rxalign). Both under
target64's accepted 1127 and 39-43 under its bad draw. The window does
what it was built for: one level, every session.

*Floors:* RX 77. TX 201-202 unloaded, 105-106 through the first loaded
minutes (target64's number exactly, the 48 of prime restoring the
unloaded cover), then one dip on each session (314 s and 411 s) to 68
and 70, held as the running minimum after. target64's accepted session
took the same loaded dips and its floor stopped at 105; here they reach
37 lower. So the TX prime restored the level's 48 but not the dips'
depth: at this phase the loaded TX minimum is about 37 under target64's
for about the same level. Read together with phase760 (1083 at TX 60)
and the probes' unloaded TX floors (about 200 at phases 67-550, about
150 at 695-944), the picture is one sawtooth, not two: the level and
the TX cover move together with the phase, and every point measured
today lies on the line level = TX cover + constant. The window chooses
where on that line a session lands; it cannot move the line.

*Standing:* three ways to run the service, all measured on `2a158386`:
target64 (accepted; by the draw 1127 at TX 105 or 1161 at TX about 156,
RX 77); phase760-tx240 (1118-1122 every session, TX 68-70, RX 77);
phase760 (1083 every session, TX 60, RX 77, not accepted). The
deterministic point with target64's full cover would be a window on the
high shelf with TX prime 192 (about 1134 at TX about 105, every
session): the plain draws already land there most of the time, so it
is target64 with the lottery removed at the cost of 7 samples against
its best day; unmeasured, one block away (`RX_PRIME_PHASE_WINDOW="380,550"`
on target64). Conf `9428db88` (installer `e50e0307`, `5a2de43b` joins the
unedited-shipped list) carries phase760-tx240's MEASURED and COVER,
`STATUS=experimental`.

**STAGED 2026-09-05 17:25 UTC: profile `...-target64-phase450`** (target64
with `RX_PRIME_PHASE_WINDOW="380,550"`, the band the plain restarts land
in and the accepted 1127 came from; experimental). The user switched the
service back to target64 for the night at about 17:20 UTC. Expected about
1134 on every session at TX floor about 105 and RX 77: target64 with the
lottery removed and its cover kept, for about 7 samples against its best
draw. Conf `dc3fa097` (installer `7305020a`, `9428db88` joins
the unedited-shipped list); block `phase450-block.conf` in
`~/usb-16x16-work/aes67-hold-install/`, validated against the live conf
plus the block. Acceptance as for phase760-tx240: the full set on two
sessions, one level.

**MEASURED 2026-09-05 22:37-23:34 UTC: `...-target64-phase450` session 1
reads 1089 at TX floor 108, which breaks the one-sawtooth reading; its
soak carries the USB drop signature; a PTP master reset opened the
session.** The user switched at about 22:37 UTC; the kernel logged
`ResetPTPMaster` on both ports at 22:37:08-09 as the stack came up.
`PRIME window direction=ravenna-to-usb status=hit ring=192 phase_us=401
window_us=380,550 waited_ms=0` (the plain draw was already inside the
band), `PRIMED ring_at_prime=192 overshoot=5`, TX `align_dropped=67
front_age_frames=336`. My wait loop keyed on the stage file reading
`running`, which the supervisor replaces after 120 s, so the gate ran at
23:08, 31 minutes into the session; a rule for the loop, not the record.
Gate (`phase450agate-noise-ch2-64f-100imp`) 0.0% zeros. Runs
(`phase450a-roundtrip-64f-20260905T230908Z`, `231244Z`, `231620Z`,
`231956Z`): all 3200 on **1089** (22.688 ms), spread 0, zero RECOVERs.
Soak (`phase450asoak-...T232332Z`, 600 s loaded): median 1089, minimum
1081, spread 8, score 0.980, zero RECOVERs: 2304 impulses on 1089 and 96 on
1081, 4% of them 8 samples early, the dropped-impulse signature of the 2026-09-04 USB
campaign, on no other soak today. Pi side clean throughout: `tx_qfloor`
108 loaded from 189 s, `rx_qfloor` 77, `tx_qlow`/`rx_qlow` 0, no drops,
no clips, gaps 1.12/1.63 ms. Log
`outputs/latency/phase5-20260905/bridge-phase450a-session-20260905T223751Z.log`.

*Two things this session says.* (1) 1089 at floors 108/77 is the lowest
level ever measured at target64's full cover, 38 under the accepted
1127, at a phase (401) the afternoon map placed at 1132. So the level
is not one sawtooth in the USB-grid phase with the TX cover riding on
it: there is a third term, about 43-48, that moved between the
afternoon and now with the floors unchanged. The PTP master reset at
this session's start is the candidate: the packet-arrival lead against
the RAVENNA read slot on the Ferrofish side of the bridge (the
"arrival lead" of the 2026-09-02 record), which the aligned start
fixes relative to the tick but which the PTP side can move by a slot
when it re-locks. It is not controlled by anything in the profile yet
and it decides whether a session gets 1089 or 1132 at the same phase
and cover. (2) The Mac side: the zero-run detector logged 844 runs of
8-12 zeros on channel 1 alone at `usb-capture` between 22:39:20 and
22:56 UTC, none since; something was sent to the device on channel 1
in that window with holes in it. The soak's 8-sample-early impulses
under the sixteen-channel load are a second Mac-side symptom of the
kind cleared on 2026-09-05 11:02 UTC by the coreaudiod kill and gadget
re-bind. The profile is not the cause (the Pi side is clean and every
earlier soak today was spread 0) and it is not accepted on this soak.
Conf `0ae3617b` (installer `28860f82`, `dc3fa097` joins the
unedited-shipped list) carries session 1 in the block. Next: a
Mac-side reset, then the soak again and a second session, watching
whether the third term holds across a restart without a PTP reset.

**CORRECTION 2026-09-05 23:45 UTC: the 22:39-22:56 UTC channel-1 zero runs
were RTL Utility's own signal.** The user was running RTL Utility briefly
in that window (comparing against Dante Virtual Soundcard on the laptop),
with no music playing; its test signal is a click train on channel 1
whose gaps between clicks fall inside the detector's 8-480 window. So
those 844 runs are the instrument reading a legitimate signal, not holes,
and the detector needs to be read with that in mind whenever RTL Utility
is up. What remains Mac-side and open is only the soak's 96 impulses 8
samples early under the sixteen-channel load. The 1089 at full cover and
the PTP-side third term stand as written.

**2026-09-06 00:05-00:20 UTC: a host-side stream stop restarted the stack,
the second phase450 session reads 1107 at TX floor 61, and the PTP-reset
reading is withdrawn.** RTL Utility at 32 on the first phase450 session,
read by the user at about 23:45 UTC: 26.979 ms, which is 1107 on the
harness scale (every pair today is 3.917 ms apart) and not the 1089 of
the runs. A 200-impulse read at 23:51 confirmed **1107**
(`phase450check-roundtrip-64f-...`), and the Pi explained it: at
00:05:57 UTC the bridge logged `RECOVER usb-to-ravenna playback-avail
Broken pipe` then repeated `RECOVER ravenna-to-usb capture-ring-full
ring=768`: the host stopped pulling the IN stream, the RX ring filled,
TX underran, 13 RECOVERs in 60 s, and the supervisor restarted the
stack (`FAIL more than 5 direction restarts in 60 s (13)`), up again
00:07:02 UTC. The user was comparing RTL Utility against Dante Virtual
Soundcard on a laptop around then; a Mac-side device change is the
likely stop. The new session: `PRIME window ... status=hit ring=192
phase_us=501 window_us=380,550 waited_ms=48878`, TX `align_dropped=64
front_age_frames=336`, and its TX floor went 157, 109, 72, 63, **61** by
199 s with RX 77; level 1107. The PTP grandmaster (`gmid`
00-1D-C1-FF-FE-1D-27-DC) did not change at either session start; the
kernel's `ResetPTPMaster` lines are the driver re-locking at every
stack start, so the PTP-reset explanation for the third term in the
entry above is withdrawn. `sink_min_time` reads 0 on both sinks, as
it always has.

*What the two phase450 sessions say together:* same profile, same
window, same primed depths (ring 192, TX front age 336):

| session | phase | level | TX floor loaded | RX floor |
|---|---:|---:|---:|---:|
| 1 (22:37 UTC) | 401 | 1089 | 108 | 77 |
| 2 (00:07 UTC) | 501 | 1107 | 61 | 77 |

18 apart in level and 47 apart in TX cover, in the same window and
with the bridge's own numbers identical. The term that moves between
sessions is neither the USB-grid phase (held) nor anything the PRIMED
lines carry, and it moves the level and the TX cover independently
(session 1 had the lower level and the higher cover). It is not PTP.
Candidates left, all outside the bridge's accounting: where the
Ferrofish's packets land against the RAVENNA read slot at the aligned
start (fixed relative to the tick but not to the packets), and the Mac
side's own phase after a device change. The instrument for the first
is the driver's arrival lead, which `sink_min_time` does not report;
the next build is a bridge-side measure of it (the RAVENNA capture's
backlog at its fresh wake against the tick, which the driver's
`capture_buffer_pos` fixes at prepare). Conf `101c41ec` (installer
`6a915eae`, `fb6739aa` joins the unedited-shipped list) carries
both sessions in the block, `STATUS=experimental`.

*Standing at the end of 2026-09-05:* target64 is the accepted point
(1127 at TX 105 on its good draw). The phase window removes one of the
session terms and is proven (rxalign, phase760, tx240 and phase450 all
repeat their USB-grid phase); the level still moves by a second,
unexplained term of about 18-48 between sessions, and the TX cover by
up to 47. DVS on the laptop reads 11.312 ms at 32 frames; this loop
reads 26.6-27.0 at its best today, 15.7 ms away.

**BUDGET 2026-09-06 00:40 UTC, from the record: where the 15.7 ms to DVS
sits, and what the bridge can reach.** Read-only pass over the Phase 5
day, the driver source and the saved session logs; no measurement, no
change on the Pi. Samples at 48 kHz on target64's good draw (RTL Utility
at 32 frames 27.396 ms = 1315 samples; harness 1127 on the device
timeline):

| term | samples | ms | basis |
|---|---:|---:|---|
| Mac IO buffers, 2 x 32 | 64 | 1.33 | 32-vs-64 table, 2026-09-02 |
| Mac constant | 124 | 2.58 | same table; equals the CoreAudio safety offsets 74 + 50 exactly |
| bridge TX start depth (front age) | 336 | 7.00 | prime 192 + ring 67 + longest aligned wait 77; 1:1 with the level |
| bridge RX start depth | 192 | 4.00 | queue 120 + ring 72, the 192 bin; 1:1 with the level |
| outside the bridge, device timeline | 599 | 12.48 | 1127 - 528; never split by measurement |
| total | 1315 | 27.40 | |

*The 599 is where the plan's floor is wrong.* `DEPLOYMENT_PLAN.md` put
the Mac, the Ferrofish and the RAVENNA device together at 12-13 ms; the
measured remainder outside the bridge is 12.5 ms before the Mac's 3.9 ms
is added. Its known pieces: sink delay 144 (3 ms, exact on the line), the
Ferrofish about 3.5 ms (Dante Controller), the RAVENNA playback stamp of
one packet (`SAC - 48`), up to one period of bridge read grain. That
leaves about 4-5 ms for the two Pi USB legs together. The only direct
measurement of those legs is the 2026-08-31 USB-only loop, 264 samples
at a 240-frame `alsaloop` target (0.5 ms), on the req 2 gadget. The
~150-sample step between req 2 and req 4 that the 2026-09-05 sweep set
aside (the req 2 loop was dropping impulses) is therefore probably
real, and it is the largest unpriced number in the budget. One
USB-only run on the req 4 gadget prices it: expect about 264 at the
5 ms target if the legs are cheap, about 410 if the step is real.

*Against DVS (11.312 ms at 32 = 543 samples).* The Ferrofish is common
to both loops (about 168), so DVS's own driver and receive buffering is
about 311 samples (6.5 ms) for the job this design does in 1083. The
gap decomposes as Mac constant 124 + bridge start depth 528 + Pi USB and
RAVENNA driver legs about 431 - DVS's 311 = 772 on this draw.

*Reachable without the USB module.* Not reachable: the Mac constant,
the gadget's share of the 599 whatever it is (req 3 = req 4; bint 1
unreadable on RTL at 32; sweep closed), the buffers. Reachable and
priced: the aligned wait allowance 77 -> about 50 frames (offset 950 us,
margin 50 us; about 25 samples, conf plus one constant); ring target 64
-> 48, the bridge's bound (about 16); sink delay 144 -> 120 (24, a
per-session gamble against a 192 lap until the arrival lead is known);
the second session term (18-48) once instrumented. Not reachable by
profile: the TX prime, because every lever today landed on the line
`level = TX cover + constant` and the TX floor of 105-108 sits over a
bar of one period plus the Pi's worst wakeup gap; only a days-long gap
measurement (Phase 6) can lower that bar, and it is the one place
another 1-2 ms exists on the Pi side. Realistic floor of this design at
RTL 32: about 25 ms; about 23 with a proven smaller worst gap. DVS's
11.3 is not reachable on this architecture.

*The second term: the bridge's start numbers are identical.* Pulled the
`ALIGN`, `PRIMED` and trigger lines from the saved logs of target64,
phase450, phase760, tx240a/b, rxalign1/2, seed15, shift30, primes144:
TX front age 336 (384 on tx240, 288 on primes144), ring 192, overshoot 5,
trigger `wake_to_start_us` 601-603, `wake_to_prepare_us` 614-622 on
every one. The term is outside the bridge's accounting, as the record
says.

*Three findings from the driver source that change what to build.*
(1) The arrival lead is already computed in the kernel:
`RTP_audio_stream.c` `ProcessRTPAudioPacket` (line ~787 in the vendored
checkout) computes each packet's time ahead of its use and keeps a
running minimum `m_ui32MinSinkAheadTime`, compiled in because
`DEBUG_CHECK` is 1 (`RTP_stream.h:39`, `RTP_audio_stream.h:49`). It never
leaves the module: the only exporter, `GetMinSinkAheadTime`
(`RTP_streams_manager.c:751`), has no message case in `manager.c` and
the daemon never asks; `set_sink_min_time` has no caller, so the API's
`sink_min_time` is the constructor's zero. One line in the status
update (`RTP_audio_stream.c` ~1123, set `m_StreamStatus.sink_min_time`
from the minimum / 10 and reset it) would carry it through the existing
`memcpy` to the daemon and `GET /api/sink/status/N` with no daemon or
bridge change. That is a RAVENNA module rebuild on the rollback path
(separately named `.ko`, the supervisor's `module_binary` path, restore
commands); the Pi builds from `~/usb-16x16-work/aes67-source/
ravenna-alsa-lkm-v2.1`, to be compared to the vendored checkout first,
and the unit conversion mixes microseconds and 100 ns and needs
checking on the Pi. (2) A bridge-side arrival lead cannot exist: the
driver copies the jitter slot into the ALSA buffer at every tick whether
or not the packet has landed (`audio_driver.c:668`), so ALSA always
shows exactly one period and a late packet is only visible as a
192-frame lap. (3) The arrival lead cannot explain an 18-48 term anyway;
it explains laps. The instrument that splits the second term is a stage
timestamp logger in the bridge on the zero-run detector's hook: log the
monotonic time and frame index when the harness impulse (channel 1,
0.25 full scale) passes `usb-capture`, `ravenna-playback`,
`ravenna-capture` and `usb-playback`. That gives per session the bridge
TX dwell, the AES67 loop from write to read, the bridge RX dwell, and by
subtraction from the harness level the two USB legs together. If the
term moves in the AES67 segment it is Ferrofish or driver side; if in
the USB remainder, the Mac or gadget side, which the record already
favours (the term re-drew at the 00:05:57 UTC host stream stop; the
rxalign residue was two microframes). Flag off by default,
behaviour-free, the usual three pins.

*Order:* (1) the USB-only loop on the req 4 gadget
(`work/latency-harness/measure-usb-only.sh`, service stopped, playback
idle, no build, no root change); (2) the stage logger build; (3) the
`sink_min_time` plumbing only if (2) points at the AES67 segment, which
is also what makes sink delay 120 deterministic.

**IMPLEMENTED 2026-09-06 00:48 UTC, not yet built: the impulse trace,
bridge `--impulse-trace 0|1`, and profile `...-target64-trace`.** The
stage instrument from the BUDGET entry above. Core: `ImpulseTraceDetector`
in `bridge_core.hpp`/`.cpp` (one channel, magnitude threshold, hold-off
in frames, fixed 8-event queue, real-time safe, unit test
`test_impulse_trace_detector`). Bridge: `--impulse-trace 0|1` (default 0),
`--impulse-channel N` (1..16, default 1), `--impulse-threshold F` (default
0.15: above the 0.1 noise load, below the 0.25 harness impulse),
`--impulse-holdoff N` (default 2400 frames, 50 ms); the three sub-options
need the flag, as the zero-run pair does. On the same two blocks the
zero-run detector scans, each hit is an `IMPULSE` line: `stage=`
(`usb-capture`, `ravenna-playback`, `ravenna-capture`, `usb-playback`),
`direction=`, `position=` (the direction's stream count), `value=`,
`block_first=`, `block_frames=`, `offset=`, `depth=` (the capture backlog
the wake found, or the playback queue as last sampled at 1 Hz),
`block_ns=` (the capture wake, or the write, monotonic), `now_ns=`,
`events=`, `t_us=`. Per-direction line cap 200000; a direction restart
re-arms the hold-off. `IMPULSE enabled` line at start, SUMMARY carries
`impulse_trace`, the three settings, per-stage event counts,
`impulse_lines`, `impulse_lines_suppressed`, `impulse_dropped_events`.
Audio path untouched with the flag off or on. `main.cpp` `99133ae5`,
`bridge_core.cpp` `9c24251a`, `bridge_core.hpp` `226fe0ee`,
`bridge_tests.cpp` `46f03dcf`; syntax-checked clean on the Mac (clang,
`-Wall -Wextra -Wpedantic -Werror`, the Pi's ALSA headers, the endian /
clock_nanosleep / ESTRPIPE stubs), core tests pass on the Mac. Supervisor:
optional key `IMPULSE_TRACE` (0/1, absent 0), passed as `--impulse-trace`,
shown by `profiles` as `impulse-trace N` (`bddc97fd`). Conf `98b467ea`
adds `servo-aligned-both-240-rx120-sd144-tx192-target64-trace` (target64
with `IMPULSE_TRACE=1`, experimental). Analyser
`outputs/latency/stage-trace-20260906/impulse-stages.py`: groups the four
stages per impulse and reports `bridge_tx` (usb-capture frame time to
ravenna-playback write), `tx_queue` (write to estimated play), `aes67`
(estimated play to ravenna-capture frame time), `bridge_rx`, `rx_queue`,
`pi_total`, in ms and samples, with `--level N` giving the two USB legs
together as level minus `pi_total`; the queue terms come from the 1 Hz
depth samples and carry up to a period of error. Staged on the Pi:
`~/usb-16x16-work/phase4-trace-src` (source, hashes verified) and
`~/usb-16x16-work/aes67-trace-install/` (supervisor, unit, conf,
`trace-block.conf` `6a589802`); the new supervisor validates the repo
conf and the live conf (`d55fe0b3`, `PROFILE=...-target64`) plus the block
on the Pi, exit 0, zero bad lines. Build waits for a service stop; the
USB-only run (BUDGET entry, order item 1) goes in the same stop window
first, then the build, then the three pins and the installs.

**MEASURED 2026-09-06 00:55 UTC: the USB-only loop on the req 4 gadget reads
262 samples at the 240-frame `alsaloop` target; the Pi USB legs cost about
22 frames and the req 2 to req 4 step is retired.** Service stopped by the
user at about 00:53 UTC (module unloaded, gadget `configured/high-speed`,
`req_number=4`, bint 0), playback idle. `measure-usb-only.sh 5000 64 100
200` (the harness refuses `--maximum-lag-ms` at or above 250, so 200, its
default; the 2026-08-31 point used the same wrapper): `alsaloop` on
`hw:UAC2Gadget` both ways, `Latency 240 frames`, pitch 1.0;
`usb-only-5000us-64f-20260906T005507Z.json`: **262 samples (5.458 ms)** on
all 100 impulses, spread 0, zero input or output discontinuities,
`rawInputPeak` 0.25. The 2026-08-31 run on the req 2 gadget read 264. So
the gadget's request queue does not sit on the path at four requests,
the ~150-sample step between req 2 and req 4 in the 2026-09-04 record was
the dropping loop's artefact as suspected, and the two Pi USB legs
together are about 22 frames (0.46 ms) beyond whatever ALSA buffer the
process on the Pi holds. The 599 samples outside the bridge in the BUDGET
entry are therefore the bridge's USB capture read grain (up to 48), about
22 of gadget, and about 530-550 (11-11.5 ms) between the RAVENNA playback
write and the RAVENNA capture read: the RAVENNA device, the wire, the
Ferrofish and the wire back. The known pieces of that (sink delay 144 =
3 ms, the Ferrofish about 3.5 ms, the `SAC - 48` stamp 1 ms) leave about
3.5-4 ms on the AES67 side that the record has never placed, and the
impulse trace's `aes67` term measures exactly that segment. Order item 1
done; the build follows in the same stop window.

**BUILT and STAGED 2026-09-06 00:57 UTC: bridge `21c0e9f2` (impulse
trace), the trace install set, all three pins moved.** Service stopped by
the user at about 00:53 UTC; the USB-only run above came first in the
window, then the build on the Pi from `~/usb-16x16-work/phase4-trace-src`
(`main.cpp` `99133ae5`, Release, the same cmake configuration as the
previous builds, zero warnings), ctest 1/1 including
`test_impulse_trace_detector`, binary SHA-256
`21c0e9f21d15dfd6c2f07779c9f15de2b2871241d4924312d5a6c66830af0d9e`, in
`work/phase4-bridge/artifacts/pi-aarch64/` (README updated, `2a158386`
previous). With `--impulse-trace 0`, the supervisor default for every
block without `IMPULSE_TRACE`, behaviour is `2a158386`'s. Pins: supervisor
`expected_bridge_sha256` `21c0e9f2`, supervisor `5bff36a6`;
`install-candidate.sh` `a627ad87` (bridge `21c0e9f2`, wrapper `6282b108`
unchanged); `install-aes67-service.sh` `82cf0631` (supervisor `5bff36a6`,
unit `77837e60`, conf `98b467ea`, bridge `21c0e9f2`; `101c41ec` joins the
unedited-shipped list). Staged: `~/usb-16x16-work/phase4-trace-install/`
(binary, wrapper, installer) and `~/usb-16x16-work/aes67-trace-install/`
(supervisor, unit, conf, installer, `trace-block.conf`); the repinned
supervisor validates the live conf plus the block, exit 0, zero bad
lines. Install order, service stopped: `install-candidate.sh`,
`install-aes67-service.sh` (keeps the operator-edited live conf), append
the block, `switch-profile ...-target64-trace` (PROFILE only while
inactive), `systemctl start`. First use: one target64-trace session,
gate probe, one 200-impulse harness run at 64, the analyser on the
full-rate log; then the acceptance-length runs if the numbers hold.

**MEASURED 2026-09-06 01:00-01:05 UTC: the first impulse-trace session
splits the device timeline by stage; the AES67 loop from the RAVENNA
playback write to the RAVENNA capture read is about 12 ms, and the
bridge's four holdings sum to its start depth.** Installs by the user
(bridge `21c0e9f2`, supervisor `5bff36a6`, wrapper `6282b108` verified;
live conf `8fa62e25` with the trace block appended,
`PROFILE=...-target64-trace`), start at 01:00:31 UTC. Session: `IMPULSE
enabled channel=1 threshold=0.15 holdoff_frames=2400`, ALIGN ok attempt
2, RX PRIMED `grid_phase_us=520 ring_at_prime=192 overshoot=5` (a plain
draw in the 380-550 band), TX PRIMED `align_dropped=72 overshoot=5
front_age_frames=336`, trigger ok 602 us. Gate
(`tracegate-noise-ch2-64f-100imp` in `usb-holes-20260904/`) 0.0% zeros,
no runs, no discontinuities. `measure-under-service.sh 64 200 trace1`
(`trace1-roundtrip-64f-20260906T010143Z`): **1126** on all 200, spread
0, score 1.000, `tx_qfloor` 112, `rx_qfloor` 77, `tx_pullmax` 48, gaps
1.07/1.63 ms, zero RECOVERs; target64's accepted 1127 to a sample. The
trace stamped every impulse at all four stages (1296 lines, 324 complete
impulses including the gate's and the readiness probes'); no line
suppressed, no event dropped. Full-rate log
`outputs/latency/stage-trace-20260906/bridge-trace1-session-20260906T010040Z.log`,
analyser `impulse-stages.py --after-us 60000000 --level 1126` on the
harness window (229 impulses):

| term | median | min | max | how |
|---|---:|---:|---:|---|
| `bridge_tx`, usb-capture frame to ravenna-playback write | 74 | 67 | 114 | measured both ends |
| `tx_queue`, ravenna-playback write to its play | 220 | 197 | 245 | 1 Hz depth sample |
| `aes67`, that play to the ravenna-capture frame | 576 | 561 | 627 | inherits the `tx_queue` estimate |
| `bridge_rx`, ravenna-capture frame to usb-playback write | 82 | 74 | 106 | measured both ends |
| `rx_queue`, usb-playback write to its play | 161 | 147 | 189 | 1 Hz depth sample |
| `write_to_read`, ravenna-playback write to ravenna-capture frame | 814 | 771 | 826 | measured both ends |
| `cap_to_write`, usb-capture frame to usb-playback write | 971 | 953 | 992 | measured both ends |

Samples at 48 kHz; frame times take the last frame of a capture block as
fresh at its wake, and the play times add the queue to the write.
`pos_tx` -73 and `pos_rx` -1 on every impulse: the frame-index mapping
through each direction is a constant. Readings: (1) the bridge's two
ring dwells and two queues sum to about 537 against its 528 of start
depth, so the bridge's share of the device timeline is what the PRIMED
arithmetic says, not more. (2) The level minus `cap_to_write` is 155,
which is the RX queue at the write (about 144-161) plus the two Pi USB
legs (about 22 from the USB-only run); the accounting closes. (3) The
AES67 loop, from the RAVENNA playback consuming the frame to the bridge
reading it back, is about 576 samples (12.0 ms), and even its
in-session minimum of 561 is far above the 360 the record's pieces make
(sink delay 144, the Ferrofish's 3.5 ms from Dante Controller, the
`SAC - 48` stamp). The Phase 1 RAVENNA-only platform loop read 5-6 ms,
so the Ferrofish's AES67 in-to-out costs about 6-8 ms here, not 3.5: that
is where the plan's floor was short. (4) The queue terms from the 1 Hz
sample are up to a period off at the write instant (the sum overshoots
the harness by 12 and `aes67` spreads 66); fixed in the source, not
built: on a block that carries a hit the bridge now queries the
playback delay itself (`depth_src=delay` on the line, `sampled`
otherwise), `main.cpp` `6d3586fd`, `bridge_core.hpp` `0b9ea9837`
(`pending()` accessor), syntax-checked clean, core tests pass; the
analyser gains `write_to_read` and `cap_to_write`. Next: the exact-queue
build (a service stop), then two trace sessions to place the second
session term by stage, and a packet capture on `eth0` to split the 12
ms between the Pi's RAVENNA driver and the Ferrofish.

**MEASURED 2026-09-06 01:55-01:57 UTC: the second trace session and the
packet capture. The AES67 segment is 12.1 ms from the RAVENNA playback
write to the packet leaving `eth0`, 2.7 ms round the Ferrofish with both
wires, 2.2 ms from the packet back to the bridge's read; the missing 7 ms
is the RAVENNA driver's transmit path on the Pi, one playback buffer
behind.** What happened first: at 01:54:51 UTC the trace session of
01:00:40 took a RECOVER storm of the host-stream-stop shape (TX
`playback-avail` XRUN with `last_queue=5`, then twelve RX
`capture-ring-full ring=768`: the Mac stopped sending and pulling), the
supervisor failed the stack at 13 restarts in 60 s (exit 35) and restarted
it; bridge up 01:55:52 (RX PRIMED `grid_phase_us=556`, TX `align_dropped=74
front_age_frames=336`), `STAGE running` 01:55:56. The user's `sudo timeout
75 tcpdump -i eth0 -s 1500 -B 65536 -w /tmp/trace1-rtp.pcap 'udp and dst
port 5004 and (dst host 239.69.16.1 or dst host 239.69.121.9)'` ran
01:55:15-01:56:30 (`eth0 entered promiscuous mode` at 01:55:15, before
the bridge started; no effect on the stack). My first harness attempt
(01:55:39) found no signal because the bridge was not yet up. The second,
`measure-under-service.sh 64 100 trace1cap`
(`trace1cap-roundtrip-64f-20260906T015559Z`): **1156** on all 100,
spread 0, score 1.000, zero discontinuities, on the fresh session before
any RECOVER (its impulses sit at bridge seconds 8-45). Then two RECOVER
pairs of the all-four-PCMs-XRUN shape: at 01:56:38 (bridge second 46,
when the harness closed the device) and at 01:57:40 (second 107, nothing
running on the Mac); each re-primed cleanly (RX phase 58 then 73, TX
front age 336), `STAGE stable` at 01:57:56. Full-rate log
`outputs/latency/stage-trace-20260906/bridge-trace2-session-20260906T015510Z.log`
(the 01:00:40 session's log is `bridge-trace1-...`, restored from the
01:05 copy after this one overwrote it).

*Stage split, session 2 (124 impulses, `impulse-stages.py --level 1156`),
against session 1 (229 impulses at 1126):*

| term | session 1 (1126) | session 2 (1156) | how |
|---|---:|---:|---|
| `bridge_tx` | 74 | 85 | exact ends |
| `write_to_read` | 814 | 813 | exact ends |
| `bridge_rx` | 82 | 103 | exact ends |
| `cap_to_write` | 971 | 998 | exact ends |
| level minus `cap_to_write` | 155 | 158 | RX queue at write plus USB legs |

Samples. The 30 between the sessions is not in the AES67 segment
(`write_to_read` equal to a sample, and it contains the TX queue) and not
in the RX queue plus USB legs (155 against 158); it sits in the two ring
dwells, +11 TX and +21 RX. Where within the bridge's timing it comes from
needs the exact queues (the build below), because the sampled queue terms
here (`tx_queue` 220 then 272, `rx_queue` 161 then 112) are 1 Hz samples
and cannot be trusted at that resolution.

*The capture (`rtp-impulses.py`, impulse 0x1FFFFC on the wire, the
harness's 0.25 after the Mac's 24-bit quantisation; 93 impulses seen both
ways, the Pi's stream starting at sequence 0 at the bridge start):*

| segment | median | min | max |
|---|---:|---:|---:|
| ravenna-playback write to the packet out on `eth0` | 12.141 ms | 11.937 | 13.344 |
| packet out to the Ferrofish's packet back (both wires and the Ferrofish) | 2.732 ms | 1.708 | 2.857 |
| packet back to the ravenna-capture frame at the bridge | 2.160 ms | 2.016 | 2.850 |

Sum 17.03 ms against `write_to_read` 16.95 ms (813 samples): the
segment is accounted for. The Ferrofish's stamp for the impulse is its
media-clock offset plus 89-137 samples over the Pi's, 1.9-2.9 ms, the
same loop seen in the SAC domain. So: the Ferrofish and both wires are
2.7 ms, what Dante Controller said. The RAVENNA capture side is 2.2 ms
(sink delay 144 less the arrival lead of about 40 frames). And the RAVENNA
*playback* side is 12.1 ms from the bridge's write to the wire, of which
the TX queue is about 4-5.5 ms; the other 7-8 ms, about 336-360 frames,
is inside the Merging driver's transmit path. Driver reading, from the
vendored source: the TIC interrupt copies the frame at the ALSA hw
pointer into the live-out ring at `playback_buffer_pos` and advances it
(`audio_driver.c:731-754`); the source's packet builder asks for the
slot of "the previous TIC" but gets `playback_buffer_pos` itself
(`manager.c:1417`, `get_playback_buffer_offset`; `RTP_audio_stream.c:845`),
whose length is the ALSA playback buffer in frames (`manager.c:1390`).
If the writer has advanced when the sender reads, the packet carries the
slot one ring behind: buffer minus one period, 336 frames at 384, 7 ms,
which is the number measured. It is also the mechanism behind two old
findings the record left open: "RAVENNA playback at 384 alone costs
1.67 ms" over 288 (96 frames of buffer, 80 measured) and the 5.33 ms the
2026-09-01 buffer change removed "from no buffer this process owns".
Consequences: (1) the RAVENNA playback buffer is a 1:1 transmit-latency
term, conf-only: 288 should read about 96 lower (2 ms) with the TX floor
ceiling at 192 over the loaded floor of about 105; 240 about 144 lower
(3 ms) with the ceiling at 144. (2) A driver fix that sends the slot just
written instead of the next would remove the whole 336 at any buffer,
about 7 ms, the largest single lever in the record; it is a RAVENNA
module change on the rollback path, the same class as the `sink_min_time`
plumbing. Blocks for (1) are staged below; (2) is a proposal.

**STAGED 2026-09-06 02:20 UTC: profiles `...-target64-trace-rp288` and
`...-target64-trace-rp240`** (target64-trace with `RAVENNA_PLAYBACK_BUFFER`
288 and 240 instead of 384, one variable each, the trace kept on so the
write-to-wire term can be read again; experimental). Expected about 1031
(21.5 ms) and 983 (20.5 ms) at 64 frames if the transmit term is the
buffer 1:1, TX floor ceilings 192 and 144 over the loaded floor of about
105. Conf `3fb76a98` (installer `86e37bb6`, `98b467ea` joins the
unedited-shipped list); blocks `rp288-block.conf` `0fcfdeca` and
`rp240-block.conf` `ad146fb2` in `~/usb-16x16-work/aes67-trace-install/`,
validated with `profiles` against the live conf plus both blocks and
against the repo conf on the Pi, exit 0, zero bad lines. Order: the
exact-queue bridge build first (instrument only), then rp288 with the
full gate and runs, then rp240 if rp288 holds its floor.

**CONFIRMED 2026-09-06 02:25 UTC in the driver source: the transmit lag is
one playback buffer minus one period, by call order.** `manager.c`
`AudioFrameTIC` (lines 1578-1586 in the vendored checkout):
`frame_process_begin`, then `pcm_interrupt(capture)`, then
`pcm_interrupt(playback)`, which copies the frame at the ALSA hw pointer
into the live-out ring at `playback_buffer_pos` and advances that by a
period (`audio_driver.c:731-754`), then `frame_process_end`, which calls
`SendRTPAudioPackets` (`RTP_streams_manager.c:1014`); the sender's read
offset is `get_live_out_jitter_buffer_offset`, which returns
`playback_buffer_pos` as it stands after the advance (`manager.c:1417`,
the SAC argument is not used: "in reality this var is always equal to
zero"). So every packet carries the ring slot written `L - 48` frames
earlier, `L` being the ALSA playback buffer in frames: 336 frames, 7 ms,
at 384, and the stamp `SAC - 48` describes it as last tick's audio. A
fix is one expression: read at `playback_buffer_pos - frame_size` modulo
`L`, or send before the playback interrupt. Not built: a separately
named RAVENNA module on the rollback path, the user's call.

**BUILT and STAGED 2026-09-06 02:14-02:35 UTC: bridge `c1ca48c5` (exact
queue terms) and the RAVENNA transmit-slot fix, module `cc6852f0`, as two
install steps.** Service stopped by the user at about 02:10 UTC (the
01:54:51 stream stop is explained: Pro Tools crashed at that moment,
releasing the device; every harness close now costs a RECOVER pair while
nothing on the Mac holds the device open). Step A, the bridge: built on
the Pi from `phase4-trace-src` (`main.cpp` `6d3586fd`, `bridge_core.hpp`
`0b9ea983`), zero warnings, ctest 1/1, SHA-256
`c1ca48c544b9c6fe0fccf03a438bf73ac7e9f616dd44127a11718a8bba529323`, in
`artifacts/pi-aarch64/` (README updated, `21c0e9f2` previous); behaviour
identical to `21c0e9f2` on the audio path. Pins: supervisor
`expected_bridge_sha256` `c1ca48c5`, supervisor `7c7c9132`;
`install-candidate.sh` `af5ccfc2`; `install-aes67-service.sh` `436f717f`
(supervisor `7c7c9132`, conf `3fb76a98`, bridge `c1ca48c5`). Staged in
`phase4-trace-install/` and `aes67-trace-install/`, the supervisor
validating the live conf, exit 0. Step B, the module: `work/ravenna-tx-fix/`
holds the patch (`0001-send-the-slot-just-written.patch`: in
`get_live_out_jitter_buffer_offset` return the slot the playback
interrupt just wrote, `(pos + length - frame) % length`), the README with
the mechanism, build, install and rollback, and the built module in
`artifacts/`. Built on the Pi in a separate tree
`~/usb-16x16-work/ravenna-tx-fix-src` (copy of `ravenna-alsa-lkm-v2.1`,
whose `manager.c`, `audio_driver.c`, `RTP_streams_manager.c` and
`RTP_audio_stream.c` hash identically to the vendored checkout; patched
`manager.c` `9cbbc5a8`), `make modules` against the running kernel's
headers, zero warnings, vermagic `6.18.34+rpt-rpi-2712` like the installed
module, SHA-256
`cc6852f0721343732c80d770a2f5a32d019dbfe20f1d361629c8fce2ff98bf55`, copied
to `~/usb-16x16-work/ravenna-tx-fix-install/MergingRavennaALSA.ko`. The
step-B supervisor (`892dd189`, in the repo now) points `module_binary` at
that path with `expected_module_sha256` `cc6852f0`; the original module
stays at its path (`f65a4955`) for rollback; service installer
`59fc9d1c`, staged in
`~/usb-16x16-work/aes67-txfix-install/`. Order: A installed and one exact
read on `target64-trace`; then `rp288-trace` for the 1:1 check; then B
with the full acceptance on `target64-trace`, expected about 336 samples
(7 ms) under 1127, and `rp288-trace` again, which should then read the
same as 384.

**MEASURED 2026-09-06 02:19-02:24 UTC: session 3 on bridge `c1ca48c5`, the
exact queue terms close the Pi-side accounting to within a period.**
Installs by the user (bridge `c1ca48c5`, supervisor `7c7c9132`), start
02:19:13 UTC on `target64-trace`: RX PRIMED `grid_phase_us=407`, TX
`align_dropped=67 overshoot=10 front_age_frames=336`, ALIGN ok attempt
2. `measure-under-service.sh 64 100 trace3`
(`trace3-roundtrip-64f-20260906T022008Z`): **1160** on all 100, spread 0,
score 1.000, zero discontinuities, zero RECOVERs during the run,
`tx_qfloor` 117, `rx_qfloor` 77. Every playback-stage IMPULSE line carries
`depth_src=delay`. Log
`outputs/latency/stage-trace-20260906/bridge-trace3-session-20260906T021900Z.log`,
138 impulses:

| term | median | min | max |
|---|---:|---:|---:|
| `bridge_tx` | 99 | 73 | 111 |
| `tx_queue` (exact) | 175 | 159 | 242 |
| `aes67` | 611 | 594 | 620 |
| `bridge_rx` | 104 | 69 | 106 |
| `rx_queue` (exact) | 134 | 102 | 166 |
| `pi_total` | 1121 | 1113 | 1126 |
| `write_to_read` | 786 | 767 | 853 |
| `cap_to_write` | 988 | 948 | 1022 |

Samples. `pi_total` 1121 against the harness 1160 leaves 39 samples
(0.81 ms) for the two USB legs, against 22 from the USB-only loop plus
the capture-grain modelling; the Pi-side sum now tracks the level to
within 13 across the run. Three sessions at the same profile now read
1126 (phase 520), 1156 (556) and 1160 (407) with identical PRIMED
numbers, the session term as before. A caution on reading the stage
terms across sessions: they are time-domain dwells, and the harness
impulses sit at one fixed offset inside the 48-frame blocks in a given
session (12000 is a multiple of 48), so `bridge_tx` and `bridge_rx` carry
a per-session offset-dependent component of up to a period that is not
latency on the device timeline (the frame-index maps `pos_tx` and
`pos_rx` are constant); only their sum with the queues, `pi_total`, is
the level's counterpart. Placing the session term by stage therefore
wants the index domain (the RTP stamps in a capture against the bridge's
positions), a later step. The lever the record now holds is the
transmit slot; next the `rp288` 1:1 check, then step B.

**MEASURED 2026-09-06 02:33-02:36 UTC: `...-target64-trace-rp288` reads 1057,
99 under session 2's 1156 at the same RX phase, for 96 frames of buffer:
the transmit-slot term is 1:1.** The user appended the rp288 and rp240
blocks to the live conf and switched at about 02:32 UTC; NEGOTIATED
`ravenna_playback=48/288`, RX PRIMED `grid_phase_us=557`, TX
`align_dropped=74 overshoot=3 front_age_frames=336`, ALIGN ok.
`measure-under-service.sh 64 100 rp288`
(`rp288-roundtrip-64f-20260906T023413Z`): **1057** (22.021 ms) on all
100, spread 0, score 1.000, zero discontinuities, zero RECOVERs during
the run, `tx_qfloor` 147 (unloaded, under the 192 ceiling), `rx_qfloor`
77. Trace (124 impulses, exact queues): `bridge_tx` 84, `tx_queue` 177,
`aes67` 527 (against 611 on session 3 at 384: -84), `bridge_rx` 102,
`rx_queue` 125, `pi_total` 1017 (against 1121: -104), `write_to_read`
709 (against 786), `cap_to_write` 893. Log
`outputs/latency/stage-trace-20260906/bridge-rp288-session-20260906T023335Z.log`.
So the RAVENNA playback buffer is a transmit-latency term at 1:1, as the
driver reading said, and the 2026-09-02 "1.67 ms for 384 over 288" was
it. RTL at 32 owed by the user; the acceptance set not run: step B
supersedes this block if the fix holds. Conf `3cda845d` (installer
`62e0e764`, `3fb76a98` joins the unedited-shipped list) carries the
block's MEASURED and COVER.

**MEASURED 2026-09-06 02:49-02:56 UTC: step B, the transmit-slot fix, module
`cc6852f0`: `target64-trace` reads 819 samples (17.06 ms) at 64 frames,
308 under the accepted 1127, the AES67 term 333 shorter; floors
unchanged.** Installs by the user (supervisor `892dd189` loading
`~/usb-16x16-work/ravenna-tx-fix-install/MergingRavennaALSA.ko`, pin
`cc6852f0`; `/sys/module/MergingRavennaALSA/srcversion`
`30FAF28C0EFD06CC8591C2B`, the patched build), profile switched back to
`target64-trace` (buffer 384, so the module is the one variable), start
02:48:52 UTC: `STAGE insmod` clean, NEGOTIATED `ravenna_playback=48/384`,
RX PRIMED `grid_phase_us=516` (session 1's 520), TX `align_dropped=72
overshoot=5 front_age_frames=336`, ALIGN ok. Gate
(`txfixgate-noise-ch2-64f-100imp` in `usb-holes-20260904/`) 0.0% zeros,
no runs, no discontinuities. `measure-under-service.sh 64 100 txfix1`
(`txfix1-roundtrip-64f-20260906T025359Z`): **819** on all 100, spread 0,
score 1.000, zero discontinuities, zero RECOVERs during the run,
`tx_qfloor` 112, `rx_qfloor` 77, `tx_pullmax` 48, gaps 1.07/1.63 ms.
Trace (224 impulses, exact queues), against session 3 at 384 on the old
module:

| term | old module (s3, 1160) | fixed module (819) | change |
|---|---:|---:|---:|
| `bridge_tx` | 99 | 77 | |
| `tx_queue` | 175 | 188 | |
| `aes67` | 611 | 278 | **-333** |
| `bridge_rx` | 104 | 91 | |
| `rx_queue` | 134 | 144 | |
| `pi_total` | 1121 | 779 | -342 |
| `write_to_read` | 786 | 468 | -318 |
| level minus `pi_total` (USB legs) | 39 | 40 | |

The whole change is in the AES67 term, 333 against the 336 the driver
reading predicted; the bridge's dwells and queues and the USB legs are
what they were. The AES67 segment from the RAVENNA playback consuming a
frame to the bridge reading it back is now 278 samples, 5.8 ms: the
Ferrofish with both wires (2.7), the RAVENNA capture side (2.2), the
tick and stamp. Log
`outputs/latency/stage-trace-20260906/bridge-txfix1-session-20260906T024934Z.log`.
Expected RTL Utility at 32: about 819 + 188 = 1007 samples, 21.0 ms.
Acceptance chain (four loaded 800-impulse runs and the 600 s soak)
launched next; the packet capture during it re-reads the write-to-wire
term, expected about 5 ms (the queue alone) against 12.1.

*RTL reading owed a home:* the user read RTL Utility 23.479 ms (1127
samples) after the rp288 session; no RECOVER was journaled at the read,
and it matches neither rp288's expected 25.9 (1057 + 188) nor this
session's expected 21.0; which session and IO size it was read on is
asked, and it is recorded here unassigned.

**MEASURED 2026-09-06 03:05 UTC: the wire term on the fixed module is 6.0 ms
from the bridge's write to the packet, against 12.1 on the old one; the
acceptance chain's first three runs all read 819.** Capture by the user
(`/tmp/txfix-rtp.pcap`, 75 s, 74880 packets each way, 290 impulses seen
both ways, taken during run 2 of the chain), `rtp-impulses.py` against
the live log: ravenna-playback write to the packet out **6.037 ms**
(min 4.009, max 6.348; the ALSA queue of about 188 frames plus a tick
or two, where the old module read 12.141), packet out to the Ferrofish's
packet back 1.839 ms (min 1.730, max 2.831), packet back to the
ravenna-capture frame 2.576 ms. The Ferrofish's stamp sits 89-137
samples over the Pi's for the same impulse as before. So the transmit
path now costs what its queue costs. Chain
(`txfix-roundtrip-64f-...`, four times `measure-under-service.sh 64 800
txfix` then the soak): runs 1-3 (02:54, 02:58, 03:01 UTC) **819** on all
800 each, spread 0, score 1.000, zero discontinuities, zero RECOVERs
during the runs, `tx_qfloor` 112/109/108, `rx_qfloor` 77, `tx_pullmax`
48; the RECOVER pairs the device closes cause between runs (five lines
in the session log so far) re-primed onto the same level each time.
Run 4 and the soak in progress.

**RUN 4 OF THE CHAIN SPOILED BY MY OWN TRANSFER, 2026-09-06 03:05-03:09 UTC,
and a rule.** Run 4 (`txfix-roundtrip-64f-...`, 03:05:21 UTC) read
16.896 ms (811) min=807 max=819 spread=12 score=0.843 count=800, levels 811x568 807x216 819x16, with five RECOVERs during the run: two all-four-PCM
XRUN pairs at uptime 53261 s and 53327 s and one RX `playback-avail`,
`tx_gapmax_us` 4951, `tx_pullmax` 192, `tx_qfloor` 22. At 03:05:30-03:06:30
UTC I was copying the 183 MB capture and the bridge log off the Pi over
`wlan0` with `scp`, which is the CPU and IRQ load the record already
knows stalls the bridge (the 2026-09-04 build rule). Run 4 is discarded
and will be repeated after the soak with nothing else touching the Pi.
**Rule: no large transfers from the Pi, no builds, no captures being
copied, while a measurement runs; copy captures and logs between runs.**
The soak started 03:08:57 UTC before the discard was known; it stands or
falls on its own RECOVER count.

**SOAKED 2026-09-06 03:08-03:19 UTC on the fixed module: 811 on all 2400
impulses, sixteen channels loaded, zero RECOVERs during the soak; the
session's floors are unreadable after the run 4 stall, so the acceptance
set is repeated on a fresh session.** `USB16X16_OTHER_LOAD=0.1
measure-under-service.sh 64 2400 txfixsoak`
(`txfixsoak-roundtrip-64f-...`, 600 s): **811** (16.896 ms) on all 2400,
spread 0, score 1.000, zero discontinuities, zero RECOVERs during the
run; 811 is the level the loop re-primed onto during the spoiled run 4
(819 before it). The wrapper's `tx_qfloor` 22 and `tx_pullmax` 192 are
the session's running minima from the stall and say nothing about the
soak. Standing on the fixed module at target64: three clean 800-impulse
runs at 819 (floors 108-112, RX 77), one clean 2400-impulse soak at 811,
one 100-impulse read at 819, the wire term at 6.0 ms; measured, not yet
accepted. Next: RTL Utility at 32 by the user on this session (expected
about 20.8 ms), then a stack restart and the four runs plus soak again
with nothing else touching the Pi.

**RTL Utility at 32 frames on the fixed module, read by the user: 20.812 ms
on the soaked session (level 811), and 19.688 ms on the fresh session
after the restart.** 20.812 ms is 999 samples, 811 plus the Mac's 188, to
the sample: the standard figure for the fixed module at the point of
record's profile, 6.584 ms under target64's accepted 27.396. The fresh
session (restart at about 05:35 UTC, RX PRIMED `grid_phase_us=457`, TX
`align_dropped=69 overshoot=8 front_age_frames=336`, floors 115/77
before load) read 19.688 ms, 945 samples, which puts its device timeline
at about 757, 62 under the previous session's 819: the session draw,
now on a loop 4 ms shorter. The clean acceptance chain (four loaded
800-impulse runs, then the soak) was launched on it at 05:37:59 UTC with
nothing else touching the Pi.

**ACCEPTED 2026-09-06 06:03 UTC: target64 on the fixed RAVENNA module,
profile `servo-aligned-both-240-rx120-sd144-tx192-target64-trace`, module
`cc6852f0`, bridge `c1ca48c5`: 757 samples at 64 frames (15.771 ms), RTL
Utility at 32 frames 19.688 ms, TX floor 107 loaded, RX floor 77.** The
clean chain on the fresh session of 05:35 UTC (RX PRIMED
`grid_phase_us=457`, TX `align_dropped=69 overshoot=8 front_age_frames=336`,
ALIGN ok attempt 1), nothing else touching the Pi:

| run | file | samples | ms | levels | score | tx_qfloor | rx_qfloor | tx_pullmax | RECOVERs |
|---|---|---:|---:|---|---:|---:|---:|---:|---:|
| 1 | `txfix2-roundtrip-64f-20260906T053759Z` | 757 | 15.771 | 757 x800 | 1.000 | 109 | 77 | 48 | 0 |
| 2 | `txfix2-roundtrip-64f-20260906T054135Z` | 757 | 15.771 | 757 x800 | 1.000 | 109 | 77 | 48 | 0 |
| 3 | `txfix2-roundtrip-64f-20260906T054511Z` | 757 | 15.771 | 757 x800 | 1.000 | 109 | 77 | 48 | 0 |
| 4 | `txfix2-roundtrip-64f-20260906T054847Z` | 757 | 15.771 | 757 x800 | 1.000 | 107 | 77 | 48 | 0 |
| soak | `txfix2soak-roundtrip-64f-20260906T055223Z`, `USB16X16_OTHER_LOAD=0.1`, 600 s | 757 | 15.771 | 757 x2400 | 1.000 | 107 | 77 | 48 | 0 |

5600 impulses on one sample, spread 0, zero discontinuities, zero
RECOVERs in the whole 28-minute session (none at the device closes
between runs this time), `tx_qlow` and `rx_qlow` 0 on all 1668 BRIDGE
lines, gaps 1.13/1.63 ms, `tx_clip`/`rx_clip` 0. RTL at 32 read by the
user at session start 19.688 ms, 945 samples, 757 plus 188 to the
sample; 7.708 ms under target64's accepted 27.396 on the original
module. Full-rate log
`outputs/latency/stage-trace-20260906/bridge-txfix2-session-20260906T053530Z.log`;
trace over 5750 impulses: `aes67` 258, `write_to_read` 441,
`cap_to_write` 629, `pi_total` 787 (30 over the level, where the two
earlier sessions ran 39-40 under it: the time-domain sum closes to
within a period, not better, the block-offset component again).
Checklist item 9 is met. Conf `302d1a1f` carries the block as accepted
with a header note that every MEASURED string written before 2026-09-06
was read on the original module (installer `e26081ea`, `3cda845d` joins
the unedited-shipped list); `copy-trace-labels.py` (the target64 copier
with the trace prefix, shipped conf in `aes67-txfix-install/`) applies
the four label lines to the live conf (`85414b06`) atomically, dry run
without `--apply`. The point of record is now this: the audio path of
target64 on the fixed module, 757 at 64 frames. The session draw stands
(819, 811, 757 across the fixed module's sessions). For service the
trace can stay on (behaviour-free; music on channel 1 fills the
200000-line cap in about 40 minutes per direction and then only a
counter moves) or plain `target64` can be selected, which is the same
audio path and a stack restart. Rollback of the module is the previous
service installer in `~/usb-16x16-work/aes67-trace-install/` (supervisor
`7c7c9132`, module `f65a4955` at its original path), service stopped.

**MEASURED 2026-09-06 06:06:04 UTC, read from the live log at 12:22 UTC: the
accepted session's worst wakeup gap so far is 3.3 ms, and TX prime 192
covered it with 10 frames to spare.** Three minutes after the acceptance
chain ended, the bridge logged `DEPTHSTEP direction=usb-to-ravenna
t_us=1814938376 depth_floor=125 ring=67 queue=58 avail=326
capture_backlog=0 pull=144 gap_us=3344` (journal 06:06:04 UTC). The
session's running minima went from `tx_qfloor` 107 / `rx_qfloor` 77 at
the end of the chain to **`tx_qfloor` 10, `rx_qfloor` 29, `tx_pullmax`
144, `tx_gapmax_us` 3344** on that one event and had not moved by 12:22
UTC; no RECOVER, no direction restart, nothing else in the Pi journal at
that second. The nearest activity was two short ssh logins from the Mac
at 06:05:29-30 UTC (the post-acceptance hash checks), 35 s earlier, and
the copy of the session log at 06:03:38 UTC; neither is close enough to
call causal. This is the first Phase 6 datum on the accepted point: one
3.3 ms gap (160 frames) in seven idle hours, the TX queue at 10 frames
under it. The TX prime cannot come down on this evidence; the next
levers remain the aligned wait allowance and the ring target, as the
BUDGET entry ordered them, and the gap count over days is what earns a
prime step.

*CORRECTION 2026-09-06 13:10 UTC: the co-open reading below is withdrawn.
The three runs with RTL Utility closed failed the same way, the noise
probes then showed the Mac's USB output zeroing 88 samples in every 96 at
32 frames, and the "zero runs of 28-59 between RTL Utility's peaks" in
the trace at 12:17:35 were those same holes: the Mac output was already
in that state when RTL Utility opened the device, so RTL Utility's
scatter is the holes, not its method, and the co-open changed nothing.
Bracket for the onset: after the clean gate and chain (06:03 UTC),
before 12:17:35. The measurements below stand; see the next entry. The
rule that the harness and RTL Utility never share the device is kept as
hygiene, not as a finding.*

**FOUND 2026-09-06 12:17-12:57 UTC: RTL Utility's readings at 32 frames
scatter 67 samples below the model within one bridge session while the
loop itself does not move; and a harness run at 32 frames with RTL
Utility holding the device open loses three impulses in four, at a
strict one-second period.** The user read RTL Utility at 32 frames six
times on the accepted session (RTL Utility launched 08:17:26 EDT =
12:17:26 UTC; bursts at 12:17:35-43, 12:17:59-12:18:04, 12:33:14-12:34:43
and 12:42:55-59): 19.688, 18.979, 19.646, 18.312, 19.708, 19.438 ms =
945, 911, 943, 879, 946, 933 samples. The top of the band is the model
to the sample, harness 757 + two 32-frame buffers 64 + safety offsets
124 = 945, as on the two earlier sessions (811 + 188 = 999 = 20.812);
the other four sit 2-66 under it, which a CoreAudio client cannot see
if the driver's timestamps hold. Evidence that the loop did not move:
(1) the impulse trace stamped 62 of RTL Utility's own burst peaks (0.50
full scale, zero runs of 28-59 between them) at all four stages across
the first three sittings, `pos_tx` -70 and `pos_rx` -1 on every one,
`pi_total` 799-820, zero re-primes and zero RECOVERs; (2) the harness
across separate opens on one session reads one sample: five opens at 64
in the acceptance chain (757 x5600), and at 32 the two service runs of
2026-09-02 16:24 and 16:32 UTC (1423 both, min 1415 max 1425 both). RTL
Utility auto-correlates one short burst and its documentation names no
time base; its scatter is its own. *Standard-figure rule from this:*
quote RTL Utility at 32 as the reading that matches harness + 188, or
quote harness-at-32 + 188 directly, which is deterministic; a single RTL
run is not the figure.

*The co-open runs.* To confirm the loop at 32 on this session the
harness was run three times with RTL Utility left open (its process
holding the device since 12:17:26 UTC, so no re-prime at the closes),
playback off, `measure-under-service.sh 32 100 rtlcheck`: run 1
(12:43:39 UTC) **never passed three consecutive readiness probes in 40**
(probes alternating `rawInputPeak` 0.25 and 0.0, exit 6); run 2
(12:46:42, ready after 16 probes; `rtlcheck-roundtrip-32f-20260906T124642Z`)
**749 x90, 757 x10, score 0.316**, the 757s at impulse indices 60, 64,
..., 96; run 3 (12:48:23, ready after 12 probes;
`rtlcheck-roundtrip-32f-20260906T124823Z`) **749 x98, 757 x2, score
0.141**; zero CoreAudio discontinuities either way, zero RECOVERs, gadget
live at `req_number` 4, bint 0, nothing in the Pi kernel log or the Mac
unified log. Reading: the harness's per-impulse search radius is 8, so
749 is the centre of a flat window (no return) and 757 the true level at
its edge; only one impulse in four came back, and the bridge agrees: it
stamped 90 complete four-stage impulses in the window, every one at
0.25 on channel 1 with the same `pos_tx` -70 / `pos_rx` -1, the
usb-capture hits **1000 ms apart** where the harness sends every 250 ms.
So three impulses in four never reached the bridge's USB capture from
the Mac, the survivor periodic at 1 s, with RTL Utility as a second
client on the device at 32 frames; the loop carried what it received on
the accepted index maps. A 64-frame control run started at 12:53:28 UTC
with RTL Utility still open sat at readiness probe 12 (three suffice on
a clean session) when the user quit RTL Utility mid-run, and was stopped
as confounded. Every standard read in this record was taken "harness
alone, RTL Utility idle"; this is the first co-open at 32. **Rule: the
harness runs with RTL Utility closed, and RTL Utility reads with the
harness idle; neither figure is valid with the other client on the
device.** The clean 32-frame re-run with RTL Utility closed follows.

**FOUND 2026-09-06 12:54-13:06 UTC: the Mac's USB output is zeroing 88
samples in every 96 at 32 frames and about 1 in 100 at 64, on every
channel it sends, since some time between 06:03 and 12:17 UTC; the Pi
side is clean and carries the holes round unchanged; RTL Utility's
scatter and the failed 32-frame runs are this.** With RTL Utility quit,
`measure-under-service.sh 32 100 rtlcheck2` three times: run 1 (12:54:44
UTC) passed readiness after 8 probes and then saw nothing for the whole
main run (`rawInputPeak` 0.0, `outputFrames` = `copiedFrames` = 1245600:
output rendered and input captured continuously, exit 2, no JSON); runs
2 (12:55:48) and 3 (12:58:49) never passed three consecutive probes in
40. The Pi in that window: 44 usb-capture impulse hits, in pairs 1000
ms apart out of probes sent every 250 ms, all at 0.25, zero RECOVERs,
zero DEPTHSTEPs, gadget `configured`, `req_number` 4, bint 0. The
64-frame control alone (`rtlcheck64-roundtrip-64f-20260906T130231Z`,
13:02:31 UTC): ready after 3 probes, **757 x92, 749 x8** (the 749s at
indices 42, 44, ..., 56: every second impulse over four seconds, then
clean), score 0.959, zero discontinuities; the accepted chain read 757
x5600 at score 1.000 this morning. Then the record's noise probes
(`--output-channel 1 --input-channel 2 --other-channel-load-amplitude
0.1`, 100 impulses, `zeros.py` on the channel-2 dump,
`rtlcheck-noise-ch2-{32,64}f-100imp.*` in `usb-holes-20260904/`):

| probe | zeros in the returned noise | zero runs >= 4 | run lengths | run starts |
|---|---:|---:|---|---|
| 32 frames, 13:04:10 UTC | **88.9%** | 25936 | 28-31 and 56-59 (pairs summing to 88) | 23990 of them at offset 17 mod 32 |
| 64 frames, 13:04:40 UTC | 1.1% | 1069 | 4 (902) and 5 (167) | all at offset 49 mod 64 |
| reference `txfixgate` 64, 02:50 UTC | 0.0% | 0 | | |

The Pi's zero-run detector in the 32-frame probe's window (13:04-13:06
UTC, 7724 lines): **1932 runs at `usb-capture`**, the Mac-to-Pi leg,
`channels=0xfffe nchan=15` (every loaded channel at once), lengths
30/58/29/57/48/49, starts at `start_mod48` 37 and 21, and the same
1930 runs at `ravenna-playback`, `ravenna-capture` and `usb-playback`:
the loop passes what it receives, the bridge's counters (`tx_dropped`,
`rx_dropped`, queues, pitch, floors) untouched, the frame rate right and
the zeros inside the frames the Mac sends, as on 2026-09-05. At 32
frames the Mac delivers 8 valid samples in every 96 (two USB frames);
on 2026-09-05 it zeroed 8 in every 96. The harness impulses (one
sample, 12000 apart) survive one in four at 32 and, in episodes, one in
two at 64, which is what the failed runs and the 749/757 splits were;
RTL Utility's readings of 879-946 on a burst with nine samples in ten
zeroed are its correlator landing on the wrong peak, and the trace's
"zero runs between RTL's peaks" at 12:17:35 were these holes, so the
state was there before RTL Utility opened the device. What is known of
the onset: the gate and the whole chain were clean to 06:03 UTC; the
device was not opened by anything known between 06:03 and 12:17:26;
the Mac did not sleep (`pmset -g log`); the Pi's 06:06:04 gap is on
both bridge directions (`tx_gapmax_us` 3344, `rx_gapmax_us` 3447) and
so a Pi wakeup gap, not tied to this. The unified log carries nothing
from `coreaudiod` or AppleUSBAudio. The 2026-09-05 clear was `sudo
killall coreaudiod` on the Mac and `sudo systemctl restart usb-16x16`
on the Pi in succession, which one did it unknown; this time the Mac
kill goes first alone, then the 64-frame noise probe, and the gadget
re-bind only if the holes remain, so the record learns which side holds
the state. Either ends the accepted 757 session (the host stream stop
restarts the stack), and the next session is a new draw. **Rule: a
noise probe at the gate's buffer size precedes every RTL Utility read
and every harness figure, and a level split 8 apart or an RTL scatter
means holes, not latency.** Files: the rtlcheck and rtlcheck2 readiness
sidecars, `rtlcheck-roundtrip-32f-20260906T12{4642,4823}Z.json`, the
64-frame control, the two noise probes.

**CLEARED 2026-09-06 13:09 UTC by `sudo killall coreaudiod` on the Mac
alone: the hole state was the Mac's; both noise probes read 0.0% after it,
and three 32-frame opens on the new draw read 828 on every impulse.** The
kill at about 13:09:07 UTC stopped the host streams; the bridge took the
host-stream-stop storm (TX `playback-avail` XRUN, then RX
`capture-ring-full` in a loop, 152 RECOVER lines in 30 s), the supervisor
called it at 13:09:10 (`STAGE host absent: 49 recoveries in one second,
storm 3s, USB input frozen 0s (episode 1); stopping the bridge and
waiting`), the Mac re-enumerated and the supervisor started the bridge
alone at 13:09:27 (`host enumerated after 15s`), `STAGE running`
13:09:31; the daemon (PID 931541) and the module were not touched, the
service instance is still 01:35 EDT's. New draw: ALIGN ok attempt 1, RX
PRIMED `grid_phase_us=166`, TX `ring_at_prime=281 overshoot=22
align_dropped=55 front_age_frames=336`, floors 109/77 unloaded,
`tx_pullmax` 96. Then, with nothing else on the device: noise probes
(`postkill-noise-ch2-{64,32}f-100imp.*` in `usb-holes-20260904/`) at
13:09:43 and 13:10:10 UTC, **0.0% zeros, no run at all, at both 64 and
32**, and the Pi's zero-run detector logged nothing in the new bridge log
through the probes and the runs. Then `measure-under-service.sh 32 100
postkill` three times, 13:10:54, 13:11:35, 13:12:18 UTC
(`postkill-roundtrip-32f-20260906T13{1054,1135,1218}Z`): **828 x100,
828 x100, 828 x100**, spread 0, score 1.000, ready after 3 probes each,
zero discontinuities, zero RECOVERs after the prime pair; the bridge
stamped 572 channel-1 impulses at usb-capture, every one the probes and
runs sent (300 + 72 + 200). So the gadget re-bind was not needed and
the state lived in coreaudiod / AppleUSBAudio; the record now knows
which side. The answer to the morning's question stands as measured:
across separate opens at 32 frames the loop reads one sample, and RTL
Utility on this draw should read 828 + 188 = 1016 samples, 21.167 ms,
every time, once it is the only client. 828 against the accepted 757 is
the session draw again, 71 wide this time, on a bridge restart after a
host loss (no PTP reset, no stack restart). The accepted point is
unchanged; this draw is not a new acceptance. Files as named, plus the
sidecars.

**RTL Utility at 32 frames on the post-kill draw, read by the user with
the harness idle: 21.167 ms = 1016 samples = 828 + 188, to the sample.**
The third session in a row on which RTL at 32 equals the harness level
plus the Mac's fixed 188 (two 32-frame buffers 64 plus safety offsets
74 + 50) exactly: 811 + 188 = 20.812, 757 + 188 = 19.688, 828 + 188 =
21.167. With the device clean and RTL Utility the only client, the RTL
figure is deterministic and is the harness figure in another form; the
morning's scatter (18.312-19.708 on the 757 draw) was the hole state,
now cleared. Standing: accepted point 757 / 19.688 (05:35 UTC session,
ended by the 13:09 coreaudiod kill); current draw 828 / 21.167.

**FOUND 2026-09-06 13:20-13:45 UTC, from the saved logs and the two eth0
captures still on the Pi, no measurement and no root change: the session
draw is not on the Pi's audio path and not in the AES67 segment; it sits
between the gadget's PCM instants and the Mac's device timeline, and the
accepted 757 is the outlier there, 61-77 samples under every other draw
on the fixed module.** Method: a new analyser,
`outputs/latency/stage-trace-20260906/impulse-index.py`, reads the IMPULSE
lines per prime epoch (a new epoch at each PRIMED line after impulses; the
bridge's `position` counters are the directions' cumulative input/output
counts and do not reset together at a RECOVER, so index differences are
only comparable within an epoch or between fresh starts) and, with a pcap
and the boot's monotonic offset (`CLOCK_REALTIME - CLOCK_MONOTONIC` =
1788610677.9746 s, one boot since 2026-09-05 12:16 UTC, so it covers both
captures and the running service), fits the Pi's RTP stamps to its
realtime clock over every outgoing packet (+0.5 to +1.1 ppm, send-time
residual under 0.16 ms) and splits the AES67 segment in the stamp domain.
The Ferrofish's stream carries `a=mediaclk:direct=531217786` (the API
sidecars), the Pi's 0, which makes the stamp difference absolute. The two
captures were copied off the Pi rate-limited between runs with the service
idle (`/tmp/trace1-rtp.pcap` 01:55:52-01:56:30 UTC, session trace2;
`/tmp/txfix-rtp.pcap` 03:05:31-03:06:46 UTC, session txfix1 across its
run-4 re-primes; both are in the Pi's tmpfs and go at the next reboot);
the live log of the post-kill session was copied as
`bridge-postkill-session-20260906T130927Z.log`. Run 4's per-impulse
sequence in time order is 819 x16, 811 x49, 807 x216, 811 x519, which
matches the epochs' impulse counts exactly, so txfix1's four epochs read
819, 811, 807, 811.

*Index chain on fresh starts (exact per impulse, spread 0 within every
epoch):*

| session (level) | module | `pos_tx` | `pos_aes67` | `pos_rx` | `pos_pi` | level - `pos_pi` |
|---|---|---:|---:|---:|---:|---:|
| trace1 (1126) | f65a4955 | -73 | 1017 | -1 | 943 | 183 |
| trace2 (1156) | f65a4955 | -75 | 1017 | -1 | 941 | 215 |
| trace3 (1160) | f65a4955 | -68 | 1017 | -1 | 948 | 212 |
| rp288 (1057) | f65a4955, buffer 288 | -75 | 921 | -1 | 845 | 212 |
| txfix1 (819) | cc6852f0 | -73 | 681 | -1 | 607 | 212 |
| txfix2 (757) | cc6852f0 | -70 | 681 | -1 | 610 | 147 |

`pos_aes67` (ravenna-capture position minus ravenna-playback position for
the same impulse) is the same to the frame on every fresh start of a
given module and buffer: 1017 on the original module, 921 at buffer 288
(96 less, the transmit-slot term 1:1), 681 on the fixed module for the
819 and the 757 draws alike. `pos_rx` is -1 everywhere; `pos_tx` is the
TX ring occupancy, 68-75. The 62 between 819 and 757 is entirely in the
remainder, which is the two USB legs plus where the two gadget PCMs'
starts fall on the Mac's timeline.

*Time domain, every epoch, all sessions with the exact queue at the write
(bridge `c1ca48c5` reads `snd_pcm_delay` on the blocks that carry a hit,
`depth_src=delay`; trace1 is on `21c0e9f2` with the 1 Hz sample and is
listed for shape only):*

| epoch (level) | RX `grid_phase_us` | `write_to_read` | `cap_to_write` | `pi_total` | level - `pi_total` |
|---|---:|---:|---:|---:|---:|
| trace1 (1126) | 520 | 809 | 970 | 1140 (sampled) | -14 (sampled) |
| trace2 (1156) | 556 | 813 | 998 | 1119 | 37 |
| trace3 (1160) | 407 | 786 | 988 | 1121 | 39 |
| rp288 (1057) | 557 | 709 | 893 | 1017 | 40 |
| txfix1 e0 (819) | 516 | 450 | 650 | 781 | 38 |
| txfix1 e1 (811) | 290 | 509 | 662 | 775 | 36 |
| txfix1 e2 (807) | 89 | 501 | 658 | 772 | 35 |
| txfix1 e3 (811) | 815 | 502 | 671 | 780 | 31 |
| txfix2 (757, accepted) | 457 | 441 | 629 | **787** | **-30** |
| postkill (828, running) | 166 | 455 | 649 | 781 | 47 |

`pi_total` is the Pi's whole path, from the usb-capture frame instant to
the usb-playback play instant (write plus the exact queue plus the hit's
offset). On the fixed module it spans 772-787 across six draws whose
levels span 757-828; the accepted 757 draw has the longest Pi path of the
six. The remainder, the two USB legs on the device timeline, is 31-47 on
five draws and -30 on the accepted one. So `level = pi_total + usb`,
with `pi_total` moving by at most 15 and `usb` by 77, and the good draw
is the USB-side term 61-77 under the cluster, not a shorter Pi path.
Nothing logged at the prime tracks it: RX grid phase 457 for the -30
against 407/516/556 for the cluster, TX `prime_phase_us` 552 against
491/596/442, `ring_at_prime`/`overshoot`/`align_dropped` 267/8/69 against
264/5/72 and 262/3/74. Where the term moved: at the Pi-only re-primes of
run 4 (both directions at 03:05:39 and 03:06:45, RX alone at 03:05:51)
it moved 38 -> 36 -> 35 -> 31; the two large steps, 38 -> -30 (the 05:35
stack restart, after RTL Utility's open and quit on the previous session)
and -30 -> 47 (the coreaudiod kill, which also restarted the bridge), are
both boundaries at which the Mac's audio engine had started afresh. The
gadget cannot supply a step of this size: `p_hs_bint`/`c_hs_bint` are 0
(auto) and at high speed sixteen channels of 24-bit at 48 kHz exceed a
1024-byte packet per millisecond, so the endpoints run at microframe
intervals (6 or 12 frames a packet; the usb-capture blocks of 39 and 47
frames confirm sub-period delivery), and the bridge's own wake-versus-
arrival phase is bounded by one period. The step is 64 plus the Pi's
usual scatter, and RTL Utility at 32 frames carried it too (19.688 on the
757 draw), so it is not the harness's IO size. Hypothesis, not yet
proven: the term is AppleUSBAudio's anchoring of the input stream against
the output stream on the device timeline, set when the Mac's engine
starts, two states 64 apart; the Pi-only re-primes reshuffle only the
bridge's part (a few samples).

*Stamp domain (the two captures; `tx_lead + loop + rx_lag = write_to_read`
to the sample on every impulse):*

| epoch (level) | `tx_lead` (write to its stamp) | `loop` (Ferrofish in-to-out, its own stamps) | `rx_lag` (stamp to the bridge's read) | packet out -> back |
|---|---:|---:|---:|---:|
| trace2 (1156), f65a4955 | 613 | **105** | 96 | 2.73 ms |
| txfix1 e0 (819) | 241 | **105** | 96 | 1.84 ms |
| txfix1 e1 (811) | 307 | **105** | 96 | 1.84 ms |
| txfix1 e2 (807) | 299 | **105** | 99 | 1.84 ms |

The Ferrofish's in-to-out is exactly 105 samples (2.19 ms) on all 381
matched impulses of both captures, both modules, every epoch; the 2.7 ms
against 1.8 ms "wire loop" in the time domain is the Pi's packet leaving
at a different phase against a stamp-timed playout, not a latency change.
The RAVENNA capture placement is 96-99 (sink delay 144 less an arrival
lead of 45-48). The transmit side is the queue at the write plus the
driver's slot: 613 on the original module (336 of it the slot), 241 on
the fixed one, and the re-prime at 03:05:39 moved it to 307 while the RX
queue fell by 37, so the Pi total held within 6: the aligned start
conserves the total and re-splits it. Between the fixed module's 819 and
757 sessions the AES67 segment differs by 9 in the time domain and by 0
in the index domain. Nothing on the AES67 side draws.

*What this closes and opens.* The "second session term of 18-48" of the
2026-09-05 standing is this USB-side term; on the fixed module it is
61-77 wide with the good state on the accepted draw. It is not reachable
by a bridge or conf rule from the evidence so far, because nothing the
Pi logs moves with it; the next data is a run of stack restarts with the
Mac idle, each followed by the gate probe and a 100-impulse read at 64
(no RTL needed, the model holds), to learn the term's value set over
6-8 draws and whether a Pi-only restart ever reaches the low state
without a Mac engine start; the bridge log of each (copied between runs)
goes through `impulse-index.py --level N` so each draw is split into
`pi_total` and `usb` on the spot. If the low state never appears
Pi-only, the lever is on the Mac and the operating rule is a level read
after any coreaudiod start; if it appears, the value set and the log
fields of the low draws are the rule. The pcaps are in the Pi's `/tmp`
(tmpfs) and in the Mac session's scratch; nothing else was written to
the Pi. Bridge and service untouched: the post-kill draw (828) was
running through all of this, zero RECOVERs after its prime pair,
`tx_gapmax_us` 2479 from that pair.

**MEASURED 2026-09-06 14:16-14:38 UTC, five stack restarts by the user with
the Mac idle, then one coreaudiod kill: the session draw is set on the Mac
at its audio engine's start; the Pi's restarts move the level by a few
samples inside a band, and the kill moved the band by 30 with the Pi path
unchanged.** Each draw: the user's `sudo systemctl restart
usb16x16-aes67.service` with playback off, `STAGE running`, the channel-2
gate probe at 64 frames with the 0.1 load (`draw<k>-noise-ch2-64f-100imp.*`
in `usb-holes-20260904/`, 0.0% zeros and no run on all five, except the
Pi-side event under draw 3), `measure-under-service.sh 64 100 draw<k>`, the
bridge log copied between runs
(`stage-trace-20260906/bridge-draw<k>-session-<UTC>.log`) and split with
`impulse-index.py --level N`. Every read 100 impulses on one sample, spread
0, score 1.000, zero discontinuities. Then the user killed coreaudiod at
about 14:35:20 UTC (`STAGE host absent`, the supervisor restarted the bridge
alone at 14:36:22, running 14:36:26, daemon and module untouched); the
`kill2` gate probe and read (files `kill2-noise-ch2-64f-100imp.*`,
`kill2-roundtrip-64f-20260906T143721Z`, log
`bridge-kill2-session-20260906T143622Z.log`) followed on that session.

| draw | bridge start UTC | RX grid / TX prime phase | level | `pi_total` | USB-side term | RECOVERs |
|---|---|---:|---:|---:|---:|---:|
| draw1 | 14:16:09 | 370 / 635 | 793 | 772 | 21 | 0 |
| draw2 | 14:19:55 | 442 / 565 | 801 | 780 | 21 | pair at 14:21:19 in the run's last 6 s, re-primed onto 801 (784 / 17) |
| draw3 | 14:24:30 | 494 / 511 | 773 (after the RX re-prime) | 757 | 16 | RX alone at 14:24:56, see below |
| draw4 | 14:29:41 | 485 / 521 | 797 | 779 | 19 | 0 |
| draw5 | 14:32:37 | 344 / 659 | 790 | 775 | 15 | 0 |
| kill2 (after the coreaudiod kill) | 14:36:26 | 454 / 548 | **826** | 779 | **47** | the host-loss storm only |
| for reference: post-kill 13:09 | 13:09:27 | 341 then 166 / 659 then 840 | 828 | 781 | 47 | prime pair |

The AES67 index chain read 681 on all six, the TX ring dwell 65-72, the RX
dwell -1. Five Pi-only restarts: levels 790-801 on the clean fresh starts,
the USB-side term 15-21 on all five, the Pi path 772-780; the accepted
draw's -30 did not appear once. The kill: the Pi path 779, inside the
same 772-787 every fixed-module draw has read, and the USB-side term 47,
to the sample what the 13:09 kill produced. So the term is the Mac's,
fixed at its audio engine's start and held across Pi restarts and across
the harness's own opens; the Pi's restart re-draws only its own path
(15 wide) and the ring split. What has started the Mac's engine on this
record and where the term landed: the two coreaudiod kills, 47 and 47;
the stretch after RTL Utility's open and quit at 13:16 UTC (the only Mac
client between the 13:09 kill and draw1), 15-21; the stretch after RTL
Utility's read before the 05:35 restart, -30 (the accepted draw); the
02:49 stretch, 31-38; the original-module stretches 37-40. The prime
schedule is rigid (TX trigger 4565-4579 us after the RX prime on every
fresh start) and no PRIMED field tracks the term, as expected now.
Consequence for the record's numbers: the accepted 757 is target64 on
the fixed module plus a Mac state that read 66 under today's, and 77
under the post-kill state; the Pi's contribution to the round trip is
772-787 at 64 frames on every draw. Consequence for the lever: it is a
Mac-side procedure at the engine's start, not a conf or bridge rule; the
next test is Mac-only and free: with the Pi session untouched, open and
quit RTL Utility (the client that preceded both low stretches), then the
gate and a 100-impulse read, repeated a few times, to learn whether that
open re-draws the term, what values it takes, and whether -30 is
reachable on demand.

*Phase 6, RX side, 14:24:56 UTC (draw 3, one minute into the session,
during the gate probe):* a 3.7 ms Pi wakeup gap (`tx_gapmax_us` 3717,
`tx_pullmax` 144). The TX direction under prime 192 covered it with the
queue at 54. The RX direction under prime 120 did not: `RECOVER
direction=ravenna-to-usb stage=playback-avail` (usb-playback XRUN, ring
192, `last_queue` 125), re-primed at grid phase 970, a 276-sample hole
in the probe's return, nothing at usb-capture. Two gaps over 3.3 ms in
one day (06:06:04 and 14:24:56), and this one was a casualty on the RX
prime, which the record has not been watching; the TX prime was not the
binding one. The RX prime is the smaller of the two by design (rx120)
and its cover against the worst gap is now measured at less than 3.7 ms.

**FOUND 2026-09-06 14:42-15:19 UTC: the session draw is the Mac's USB audio
timeline drift, applied at the gadget's PCM restart. The level the Mac
reports = the fresh-anchor level (Pi path + 47) minus the drift usbaudiod
had accumulated at the moment of the last Pi restart; the physical loop
never moved, and the accepted 757 is this loop read on a timeline 71
samples adrift.** Sequence and evidence, all on the same conf, bridge
`c1ca48c5` and module `cc6852f0`:

1. *RTL Utility's open is not the trigger.* With the post-kill session
   untouched, the user opened and quit RTL Utility (14:42 UTC); gate
   0.0%, `rtl1-roundtrip-64f-20260906T144326Z` **826 x100**, USB-side
   term 47.2, Pi path 778 (`rtl1-*` sidecars; the session log re-copied as
   `bridge-kill2-session-20260906T143622Z.log`).
2. *The Mac's USB audio is `usbaudiod`* (`/System/Library/Audio/Plug-Ins/
   usbaudio.bundle`, the user-space USB audio daemon), not a kernel engine;
   both streaming interfaces read `Inactive` whenever no client is open, so
   the host stream stops at every close. The unified log shows one
   `usbaudiod`/`coreaudiod` lifetime from the 13:09 kill to the 14:35 kill
   (pids 130/110), so the 47 -> 21 change of 13:12-14:16 UTC was inside
   one lifetime; the 14:35 kill did not re-enumerate the gadget (the
   supervisor waited 60 s without an enumeration) yet landed on 47 like
   the 13:09 kill, which did. Neither respawn nor enumeration is the
   mechanism.
3. *What usbaudiod logs.* Once per device creation: `setStartingUSBFrame
   IN/OUT @ F` (the timeline anchor; 13:09:25 and 14:35:34 UTC). At every
   stream start: `AUAInputTransferManager_inputResync
   startingSampleNumber N`, on a sample counter that runs across idle. And
   `AUAAudioDevice_updateTimeStamp ioDriftNS D at sampleTime S`: D grows in
   steps of exactly 20833 ns, one sample, about one step every 2-3 minutes
   (about 6-8 ppm, the host's frame clock against the gadget's servoed
   clock), streaming or idle. Read as samples, the drift on each lifetime
   at the time of each level in the record:

| level read | drift then | 47 - drift | USB-side term measured | Pi restart since the previous read? |
|---|---:|---:|---:|---|
| post-kill 13:10-13:12 (828) | 1 | 46 | 47 | yes (host loss) |
| draw1 14:17 (793) | 25 | 22 | 21 | yes |
| draws 2-5 (801, 773, 797, 790) | 27-30 | 20-17 | 21, 16, 19, 15 | yes, each |
| kill2 14:38 (826) | 1 | 46 | 47 | yes (host loss) |
| rtl1 14:43, drift1 14:53, drift2 15:03 (826, 826, 826) | 2, 5, 11 | 45, 42, 36 | 47, 47, 47 | **no**: held |
| draw6 15:18 (803) | 17-20 (last step logged 15:08) | 30-27 | **29** | yes |
| the accepted chain 05:37-06:03 (757 x5 opens) | 71-79 | -24..-32 | -30, held across five opens | restart at 05:35, none inside |
| rtlcheck64 13:02 (757, after 7 h idle) | large | | held | no |

   The drift is not applied live (826 at drift 1, 5 and 11 with no Pi
   restart; 757 across five opens at drift 71-79) and not at a stream
   start; it is applied when the gadget's PCMs restart, and the level then
   holds until the next one. Draw 6 was the prediction test: 47 - 18 = 29
   predicted, 29.3 read (`draw6-roundtrip-64f-20260906T151814Z`, log
   `bridge-draw6-session-20260906T151744Z.log`, gate `draw6-noise-*` 0.0%).
   Reading: the gadget's sample stream re-registers against the host's
   USB frames at its PCM start, and the host's timeline, anchored once per
   device and stepped by the drift tracker, then places the input against
   the output with the accumulated drift baked in; the physical round trip
   (the Pi path 772-787 plus the USB legs) is untouched.

*Consequences for the record.* (1) The "session draw" of 18-77 since the
Phase 5 day is this: not the Pi's prime, not the AES67 segment, not the
bridge; a host timestamp offset that grows at 6-8 ppm of elapsed time
and is captured by every Pi restart or RECOVER re-prime. (2) The accepted
757 at 64 frames / 19.688 ms RTL at 32 was target64 on the fixed module
read with 71 samples of drift baked in at the 05:35 restart. The
fresh-anchor reading of the same loop is 826-828 at 64 frames, RTL at 32
about 21.2 ms (826 + 188 = 1014 = 21.125; 828 + 188 = 21.167 as read
by the user at 13:16). The Pi's own figure, the audio path from the USB
capture frame to the USB playback play instant, is 772-787 on every
draw. (3) The record's standard figure needs its drift stated: quote the
level with usbaudiod's `ioDriftNS` (in samples) at the last Pi restart,
or read it on a fresh anchor (right after a coreaudiod restart, which
storms the bridge and re-primes it at drift 0). (4) For a DAW this is an
alignment error that grows with the Mac's uptime on the device and is
frozen in at each bridge restart; reading it low is not a shorter loop.
(5) The lever named in the budget, "the session draw, 0-71, the largest
deterministic gain left", is withdrawn: nothing on the Pi can pin what
the Mac's timeline drift sets, and the drifted low readings are not
latency. The Pi levers stand as priced (aligned wait allowance, ring
target, sink delay after the arrival-lead export) and are now measurable
without the draw confounding them: compare draws at equal drift, or on
fresh anchors.

*Also this afternoon.* The RX prime 120 was the casualty of the 3.7 ms
wakeup gap at 14:24:56 UTC (draw 3) while TX prime 192 held with 54
spare; the RX prime is the binding cover, see the previous entry. The
Pi side ended the afternoon as it started: services active, no
installs, the draw6 session running.

**MEASURED 2026-09-06 15:27-15:31 UTC: a gadget re-bind resets the Mac's
anchor from the Pi side; the reported level returns to the fresh-anchor
figure (821, term 45) with no Mac-side action.** The user ran `sudo
systemctl restart usb-16x16.service` at 15:27:55 UTC (the accepted setup
script, dwc2 "new address 4"). Mac side: `usbaudiod` (same pid 40206, no
respawn) logged `Found an audio device` and fresh `setStartingUSBFrame
IN/OUT` at 15:27:56-57 UTC. Pi side: the bridge saw its USB capture
DISCONNECTED and exited with status 1; the supervisor took that as a
failure (`STAGE failed: Phase 4 bridge exited with status 1`, daemon
stopped, `stopped (cleanup)`), not the host-absent wait, and systemd's
`Restart=on-failure` (10 s) brought the whole stack back: PTP locked
15:28:21, `STAGE running` 15:28:55, RX PRIMED grid 558, TX ring 262. So a
re-bind costs a full stack restart, about a minute to audio, and the
service comes back by itself. Gate `rebind1-noise-ch2-64f-100imp.*`
0.0%; `rebind1-roundtrip-64f-20260906T152926Z` **821 x100**, spread 0,
zero RECOVERs; drift 1 at the read; split (`bridge-rebind1-session-
20260906T152855Z.log`): AES67 chain 681, Pi path 776, USB-side term
45.2 against 47 and 47 after the two coreaudiod kills. Fresh-anchor
readings of this loop now: 828, 826, 821 at 64 frames, the Pi's own
spread; RTL at 32 about 21.0-21.2 ms.

*Procedure that makes the reported latency fixed, as far as today's
evidence goes:* any stack restart goes through the gadget re-bind (the
AES67 service restarts itself behind it), so every session starts at
drift 0 and reads 821-828. What it does not cover: a RECOVER re-prime
during service re-applies the drift current at that moment (draw2's
re-prime at drift 27 held the term within 4), so a long-running session
that re-primes after hours on one Mac anchor reads low by that drift
(the 757 case, 71). The size of that creep beyond drift 81 is unmeasured;
bridge-only restarts spaced over one Mac anchor's evening would map it
(about 0.4 samples a minute at today's 6-8 ppm). The drift itself is the
Mac's frame clock against the gadget's PTP-servoed clock; only steering
the gadget to the host's clock instead (re-introducing rate conversion on
the RAVENNA side, which Phase 5 removed) would make it zero, and that is a
design change, not a lever for tonight. Service ends the entry on the
re-bound session, all three services active, no installs.

*CORRECTION 2026-09-06 17:45 UTC to the two entries above: "level = Pi path
+ 47 - drift at the last Pi restart" is withdrawn as a predictor. It fitted
nine points on the 13:09 and 14:35 anchors and failed on the 15:28 one.
What stands: a fresh anchor reads the USB-side term 45-47 (three for
three); an aged anchor reads something else, 15-55 today and -30 last
night, and the ioDriftNS count does not predict which.*

**MEASURED 2026-09-06 17:36-17:40 UTC, the creep test: a plain stack
restart on the 15:28 anchor at drift 25 read 835, USB-side term 55, where
the model predicted 21.** `sudo systemctl restart usb16x16-aes67.service`
at 17:36:51 UTC (RX PRIMED grid 513, TX ring 264), gate
`creep1-noise-ch2-64f-100imp.*` 0.0%, `creep1-roundtrip-64f-20260906T173807Z`
**835 x100**, spread 0, zero RECOVERs; split
(`bridge-creep1-session-20260906T173651Z.log`): AES67 chain 681, Pi path
780, term 55.2. Bridge pitch on this session 1000017 (observed -18.0
ppm), the same band as every session today (1000012-1000019). The
usbaudiod drift series on this anchor (EDT): steps 1-3 at 11:29-11:41,
nothing for 35 minutes, steps 4-25 at 12:16-13:18 at one per 1.5-3
minutes, nothing until the restart at 13:36; the tracker is bursty, its
sign is not in the log, and a stream start (`inputResync`) at 11:36:11
with no further starts until the restart says something streamed for
that stretch. Draw1 on the 13:09 anchor at the same count, 25, read the
term 21. So the count is not the variable, or not the only one.

*What the day proves, kept narrow.* (1) The loop is deterministic: Pi
path 772-787 and the AES67 chain 681 on every draw. (2) The reported
level is set on the Mac at each gadget PCM restart and held until the
next one (826 at three reads over drift 1-11 with no restart; 757 across
five opens; 757 after seven idle hours). (3) A fresh usbaudiod anchor,
by coreaudiod kill or by gadget re-bind, reads the term 45-47 and the
level 821-828 (three of three). (4) On an aged anchor the term at a
restart is not reproducible from anything logged so far (15, 21, 21, 16,
19, 29, 55, -30). (5) Therefore the only restart that reads a known
figure is the one that goes through the gadget re-bind, and a RECOVER
re-prime in service lands on an unknown term until the next re-bind.
Open question that one more restart answers: whether the aged-anchor
term is stable for a given anchor state (a second plain restart now
reads about 55 again) or is drawn afresh at every PCM restart (it reads
something else). The first would mean a Pi-side variable exists to find;
the second would mean only the re-bind pins it.

**MEASURED 2026-09-06 18:17-18:21 UTC, the second plain restart on the
15:28 anchor: 849, USB-side term 44, Pi path 805; the aged-anchor term is
not stable for a given anchor state (55 then 44), and the Pi's re-prime
split is its own variable of about 25.** `sudo systemctl restart
usb16x16-aes67.service` at 18:17:32 UTC; the bridge took an RX
`capture-avail` RECOVER at its prime and re-primed (RX grid 41, TX ring
270), gate `creep2-noise-ch2-64f-100imp.*` 0.0%,
`creep2-roundtrip-64f-20260906T181848Z` **849 x100**, spread 0, zero
RECOVERs after the prime; split (`bridge-creep2-session-20260906T1819Z.log`): AES67 chain 489
(counters shifted by the re-prime), Pi path **805** (773-787 on every
fresh-primed session today), term 43.6. Two conclusions. (1) The term on
an aged anchor is drawn at each gadget PCM restart, not held per anchor
state: 55 and 44 an hour apart on one anchor; the day's aged-anchor
terms are 15, 21, 21, 16, 19, 29, 55, 44 and last night's -30, against
45-47 on the three fresh anchors. No Pi-side variable exists to find for
it in the logs; only the re-bind (fresh anchor) has read a repeatable
term, and that on three samples. (2) The Pi's own path has a second
mode: a re-prime at start (an RX RECOVER before the first PRIMED pair)
lands the RX split deeper and the Pi path at 805 instead of 773-787; the
aligned start conserves the total only within a prime, not across a
re-prime. That 25 is the Pi's contribution to the session scatter and is
the bridge's to fix (a re-prime that restores the fresh-start split), not
the Mac's.

*Standing procedure for a known figure:* restart the stack through the
gadget re-bind (`sudo systemctl restart usb-16x16.service`; the AES67
service restarts itself), then a gate probe and a read; expected 821-828
at 64 frames on a clean prime. Three more re-bind reads would make the
fresh-anchor claim a statistic rather than three samples. A RECOVER
re-prime in service lands on an unknown term and possibly the deeper
Pi split; how often that happens over days is the Phase 6 count. Service
ends on the creep2 session, all three services active, no installs.

**MEASURED 2026-09-06 18:33-18:41 UTC, the re-bind series: six restarts
through the gadget re-bind read 828, 826, 821, 818, 824, 823 at 64 frames,
a band of 10 samples, against 757-849 (a band of 92) for the nine plain
restarts of the last day. The restart procedure that gives a known
figure is settled.** Three more `sudo systemctl restart usb-16x16.service`
by the user (18:33:10, 18:36:44, 18:39:11 UTC); each time usbaudiod found
a new device and logged fresh `setStartingUSBFrame` lines, the bridge
exited 1 on the disconnected capture, the supervisor stopped the stack
and systemd's on-failure restart brought it back to `STAGE running` in
60-62 s, on a clean prime each time (RX grid 372/495/500, TX ring
271/265/264, no RECOVER). Gates `rebind{2,3,4}-noise-ch2-64f-100imp.*`
0.0%; reads `rebind{2,3,4}-roundtrip-64f-...` **818, 824, 823** x100,
spread 0, zero RECOVERs; splits (`bridge-rebind{2,3,4}-session-*.log`):
AES67 chain 681 every time, Pi path 784/780/780, USB-side term 34/44/43.
With the two coreaudiod kills (828, 826) and the first re-bind (821), the
fresh-anchor set is six reads, 818-828, median 823.5, RTL at 32 about
21.0-21.2 ms. The USB-side term on fresh anchors is 34-47, so it is not
a constant either, but it and the Pi path (776-784) sum to within 10.

*Standing at the end of 2026-09-06.* The loop is deterministic (AES67
chain 681, Pi path 773-787 on every clean prime, 805 once after a
re-prime at start). The figure the Mac reports depends on the state of
usbaudiod's device timeline at the moment the gadget's PCMs restart: a
fresh anchor gives 818-828 (six of six); an aged anchor gives anything in
757-849 and the value is drawn afresh at each restart, not predictable
from the drift count or from anything the Pi logs. Procedure: restart the
stack through the gadget re-bind (the AES67 service restarts itself
behind it, about a minute to audio), then the gate probe and a read.
Open: a RECOVER re-prime during service lands on an unknown term, and a
re-prime at start can land the Pi path 25 deeper (creep2); the count of
such re-primes over days on the running service (Phase 6, with the RX
prime as the binding cover) says how often the figure moves in use, and
a supervisor rule to re-bind after a re-prime storm is the remedy if it
is often. The accepted 757 / 19.688 stays in the record as what it was:
the same loop read on an aged anchor. Service ends the day on the
rebind4 session, all three services active, no installs, nothing pending
on the Pi.

**RTL Utility at 32 frames on the rebind4 session, read by the user at
about 18:45 UTC: 21.062 ms = 1011 samples = 823 + 188, to the sample.**
The fresh-anchor figure of the loop in the standard instrument.

**IMPLEMENTED and STAGED 2026-09-06 19:05 UTC, not yet built: lever 1 of
the BUDGET entry, the aligned wait allowance 77 -> 53 frames. Profile
`servo-aligned-both-240-rx120-sd144-tx192-target64-trace-txoff950`
(`ALIGN_TX_OFFSET_US=950`, everything else target64-trace's) and bridge
`main.cpp` `caac4e1d` (`kAlignPrimeMarginNs` 200000 -> 50000, plus
`target=` and `slack_us=` on the ALIGN trigger line).** Mechanism, from
the aligned TX prime in `main.cpp`: the prime's shortest and longest waits
from its decision to the first tick are margin + tick - offset and one
tick more; the ring is held until it can absorb the longest wait (age
minus the shortest, 308 frames, unchanged by this lever) and dropped from
the front so the front frame's age at the first tick is intended (259)
plus the longest wait: 77 frames at 600/200 (waits 600-1600 us), 53 at
950/50 (100-1100 us). TX front age 336 -> 312, so the level should read
24 lower, about 794-804 at 64 frames on a fresh anchor against 818-828
for target64-trace; the Pi path by the same 24. The trigger itself is
`next_aligned_time(wake + offset, tick, now + margin)`: the playback start
lands 50 us before the driver's next tick instead of 400. Two risks, both
priced in the budget, both now observable: (1) the prime renders 192
frames between placing its target and sleeping to it; a render longer
than the margin misses the target, and `align_playback_trigger` then
takes the next grid point at now + 50 us, one tick later, so that
session's front age is 48 higher. The saved logs show the trigger landing
1-3 us after its target (`wake_to_start_us` 601-603 on every session)
but never the render time, so the ALIGN trigger line now carries
`target=prime|prime-missed|next` and `slack_us` (the prime's target minus
the trigger's entry time, negative on a miss); the render time is
`first_tick_wait_us - 50 - slack_us`. (2) The TX floor's phase term:
whether a USB write lands between the start and the driver's first
consumption, a 400 us window before and 50 us now; watch `tx_qfloor` and
`tx_pullmax` across the chain against the bar of one period plus the
3.7 ms worst gap. TX prime 192 and RX prime 120 untouched. Behaviour
identical to `c1ca48c5` except the margin and the two log fields.
Syntax-checked clean on the Mac (clang `-std=c++20 -Wall -Wextra
-Wpedantic -Werror`, the Pi's ALSA headers, the endian / clock_nanosleep
/ ESTRPIPE shims); core tests pass on the Mac (`bridge_core` unchanged).
Conf `07b213f1` adds the block (experimental, expected 794-804, the
watch list in its comment); installer `94bcf496` (conf pin `07b213f1`,
`302d1a1f` joins the unedited-shipped list; the supervisor and bridge
pins move after the build). The tag `txoff950` prefixes no field key
(the 2026-09-05 naming rule: a name must not be another's plus `tx` or
`rx`). Staged on the Pi: `~/usb-16x16-work/phase4-txoff950-src/` (source,
hashes verified there: `main.cpp` `caac4e1d`, `bridge_core.cpp`
`9c24251a`, `bridge_core.hpp` `0b9ea983`, tests `46f03dcf`; its
`build.sh` is the trace build's cmake configuration, Release, `-j4`, and
refuses while the service is active) and
`~/usb-16x16-work/aes67-txoff950-install/` (shipped conf, unit,
`txoff950-block.conf` `5b6f8ff9`); the installed supervisor `892dd189`
lists the block from the repo conf and from the live conf plus the block,
exit 0. Next, in one service-stop window: `sudo systemctl stop
usb16x16-aes67` by the user, `build.sh`, the three pins
(`install-candidate.sh`, `install-aes67-service.sh`, the supervisor's
`expected_bridge_sha256`) and the bridge README, then by the user
`install-candidate.sh`, `install-aes67-service.sh` (keeps the
operator-edited live conf), append the block, `switch-profile
...-txoff950` (PROFILE only while inactive), `sudo systemctl restart
usb-16x16.service` for the fresh anchor; gate probe, one 100-impulse read
at 64 with the split (level, pi_total, front_age_frames 312,
wake_to_start_us about 951, target=prime, slack_us), then the acceptance
set if it holds. The service ran the accepted profile throughout;
nothing installed.

**BUILT and STAGED 2026-09-06 19:12 UTC: bridge `0c7e0b0c` (aligned
prime margin 50 us, `target=`/`slack_us=`), the txoff950 install set,
all three pins moved.** Service stopped by the user at about 19:08 UTC
(playback off); build on the Pi from `~/usb-16x16-work/phase4-txoff950-src`
(`main.cpp` `caac4e1d`, Release, the trace build's cmake configuration,
zero warnings), ctest 1/1, binary SHA-256
`0c7e0b0c72c1d1b9e83b50013cd24cd97f95676c8ee57c38d44ce00773c48da1`, in
`work/phase4-bridge/artifacts/pi-aarch64/` (README updated, `c1ca48c5`
previous). Behaviour is `c1ca48c5`'s except the margin and the two log
fields. Pins: supervisor `expected_bridge_sha256` `0c7e0b0c`, supervisor
`4550cd00`; `install-candidate.sh` `289d502a` (wrapper `6282b108`
unchanged); `install-aes67-service.sh` `65ee37b3` (supervisor `4550cd00`,
unit `77837e60`, conf `07b213f1`, bridge `0c7e0b0c`). Staged:
`~/usb-16x16-work/phase4-txoff950-install/` (binary, wrapper, installer)
and `~/usb-16x16-work/aes67-txoff950-install/` (supervisor, unit, conf,
installer, `txoff950-block.conf` `5b6f8ff9`), hashes verified there; the
staged supervisor validates the live conf plus the block, exit 0.
Rollback of the bridge: `~/usb-16x16-work/phase4-trace-install/`
(`c1ca48c5`) and `~/usb-16x16-work/aes67-trace-install/` (supervisor
`892dd189`), or `switch-profile ...-target64-trace` alone for the conf
side. (`build.sh` in the source tree aborts after the link on a
zero-warning count, a `grep -c` under `set -e`; ctest and the hash were
run by hand.) Install order, service stopped: `install-candidate.sh`,
`install-aes67-service.sh` (keeps the operator-edited live conf), append
the block, `switch-profile ...-txoff950`, then the gadget re-bind for the
fresh anchor.

**MEASURED 2026-09-06 19:13-19:18 UTC, lever 1 on a fresh anchor: 793 x100
at 64 frames (16.521 ms), spread 0, zero RECOVERs; Pi path 746 against
776-784, the 24-30 the budget priced. The TX floor moves with it 1:1
(83 against 104-107), so the lever spends TX cover, and the prime render
is about 104 us against the 50 us margin, so about one prime in twenty
would miss its target and read 48 higher.** Installs by the user at
about 19:10 UTC (bridge `0c7e0b0c`, supervisor `4550cd00`, wrapper
`6282b108`; live conf with the txoff950 block appended,
`PROFILE=...-target64-trace-txoff950`), then `systemctl start` and the
gadget re-bind; usbaudiod logged `Found an audio device` and fresh
`setStartingUSBFrame IN/OUT` at 19:13:16 UTC (fresh anchor), `STAGE
running` on a clean prime. Session start
(`bridge-txoff950-session-20260906T1913Z.log`): ALIGN ok attempt 2, RX
PRIMED grid 390 ring 192 overshoot 5, TX PRIMED `ring_at_prime=294
overshoot=35 align_dropped=42 prime_phase_us=609 first_tick_wait_us=390
front_age_frames=312` (336 on every target64-trace session: the 24 the
lever removes), ALIGN trigger `wake_to_start_us=952 target=prime
slack_us=236`. Gate `txoff950-noise-ch2-64f-100imp.*` 0.0% zeros, no
run. Read `txoff950-roundtrip-64f-20260906T191536Z` **793 x100**, spread
0, zero RECOVERs, in/out discontinuities 0. Split (`impulse-index.py
--level 793`, 257 impulses): AES67 index chain 633 (681 on every earlier
session: the TX PCM's start moved one period in the driver's index
domain, `pos_tx` -43 against -73, the sum `pos_pi` 589 against 607),
`pi_total` 746.2 (779.8 on rebind4 at 823), `usb_time` 46.8 (43.2 on
rebind4; the fresh-anchor term 34-47 again), `tx_depth` median 137 (151.5
on rebind4), `rx_depth` 127 (113). Level 793 against the six fresh-anchor
reads 818-828 (median 823.5): 25-35 lower, 1 under the 794-804
predicted. RTL at 32 would read about 981 = 20.44 ms by the +188 rule,
not yet read.

*Two findings that decide what to do with it.* (1) The TX floor: 90 at
the end of the read, 83 two minutes later and still the running minimum
(`tx_qlow` 0, `rx_qlow` 0, `tx_pullmax` 48, `tx_gapmax_us` 1047, RX
floor 77, pitch 1000018), against 104-107 loaded through the whole
target64-trace acceptance. The TX queue's steady level is the front age
less the ring, so 24 frames off the front age is 24 frames off the queue
(151 -> 137 median at the impulse writes) and off its floor (107 -> 83):
the aligned wait allowance was TX cover, and this lever spends it. The
3.7 ms gap that TX prime 192 held with about 54 spare on 2026-09-06 would
be held with about 30. The BUDGET entry's line, "every lever today landed
on the line level = TX cover + constant", holds for this one too; what
the budget missed is that the allowance is part of the cover, not a term
beside it. Whether 30 spare over the worst gap seen is enough cover is
the user's call under the stability-first rule; the acceptance set
(four loaded 800-impulse runs and the soak) would give the loaded floor
and the RECOVER count but not a worse gap than the day produced. (2) The
margin: at the prime the target was 340 us ahead (`first_tick_wait_us`
390 less the 50 us between the target and the first tick) and the
trigger entered with 236 us of slack, so the prime path from placing the
target to entering the trigger (the ring drop, the PRIMED line, the
192-frame render, the commit) takes about 104 us, twice the margin. A
prime whose grid point falls 50-104 us ahead misses it and takes the next
grid point one tick later: `target=prime-missed`, a negative `slack_us`,
and that session 48 higher (and its TX queue 48 deeper). About 5% of
primes, and every in-service RECOVER re-prime draws again. Margin 150 us
covers it with 46 spare at a cost of 5 frames (longest wait 58 instead of
53); margin 200 us at offset 950 costs 7 (60) with 96 spare. A
restructure that renders before placing the target would keep 50 us of
real slack, but that is a change to the prime's order, not a constant.

*Standing.* Service running txoff950 on the 19:13 anchor, zero RECOVERs,
floors 83/77; the trace and the new log fields live. Not accepted: no
acceptance set run, RTL at 32 not read. Options in order of the
priority list: (a) return to target64-trace (`switch-profile`, the
installed bridge is behaviour-identical there with 200 us of margin
replaced by 50, which target64-trace's own offset 600 covers with 550 us
of wait: no rebuild needed to go back); (b) rebuild at margin 150 and run
the acceptance set on it, taking 20 of the 25 and watching the loaded TX
floor at about 88; (c) accept the 5% draw and run the acceptance set on
`0c7e0b0c` as is. Levers 2 and 3 untouched.

**RTL Utility at 32 frames on the txoff950 session (margin 50 us build),
read by the user at about 19:25 UTC: 20.438 ms = 981 samples = 793 + 188,
to the sample.** Against 21.062 on rebind4 (target64-trace, fresh
anchor): 0.62 ms.

**IMPLEMENTED and STAGED 2026-09-06 19:30 UTC, not yet built: the margin
150 us rebuild, `main.cpp` `9db24804` (`kAlignPrimeMarginNs` 150000; no
other change from `caac4e1d`).** The user chose option (b). Arithmetic
at 950/150: waits 200-1200 us, 9-58 frames, TX front age 317 (312 at 50
us, 336 at 600/200), ring hold level 308 unchanged; expected level about
798 on this anchor's terms (793 + 5), 799-809 on fresh anchors; TX floor
about 88; 46 us of slack over the 104 us prime path. Syntax-checked
clean on the Mac. Conf `66f92ed0`: the txoff950 block's comment, DESCRIPTION,
COVER and MEASURED rewritten for margin 150 with the 50 us session as
history (keys unchanged, so the live block is functionally identical and
is replaced at acceptance with the labels); installer conf pin moved,
`07b213f1` joins the unedited-shipped list. Staged on the Pi:
`~/usb-16x16-work/phase4-txoff950m150-src/` (source, `build.sh` with the
zero-warning count fixed). Build waits on the service stop; then the
three pins, the README, the install set in
`~/usb-16x16-work/aes67-txoff950m150-install/`, the user's install, the
re-bind, gate, read, and the acceptance set on the same session if it
holds.

**BUILT and STAGED 2026-09-06 19:36 UTC: bridge `0d8cccfa` (aligned
prime margin 150 us), the txoff950m150 install set, all three pins
moved.** Service stopped by the user at about 19:33 UTC (playback off);
build on the Pi from `~/usb-16x16-work/phase4-txoff950m150-src`
(`main.cpp` `9db24804`, Release, the same cmake configuration, zero
warnings), ctest 1/1, binary SHA-256
`0d8cccfaac5926fbb18ac847b95e271515d7bbe36ae8556895a64e1aec30bf60`, in
`work/phase4-bridge/artifacts/pi-aarch64/` (README updated, `0c7e0b0c`
previous, one session). Pins: supervisor `expected_bridge_sha256`
`0d8cccfa`, supervisor `731fe129`; `install-candidate.sh` `0e6d4e80`
(wrapper `6282b108` unchanged); `install-aes67-service.sh` `ffd99517`
(supervisor `731fe129`, unit `77837e60`, conf `66f92ed0`, bridge
`0d8cccfa`). Staged: `~/usb-16x16-work/phase4-txoff950m150-install/`
(binary, wrapper, installer) and
`~/usb-16x16-work/aes67-txoff950m150-install/` (supervisor, unit, conf,
installer, the rewritten `txoff950-block.conf`); the staged supervisor
validates the live conf, whose txoff950 block is key-identical, exit 0.
Rollback of the bridge: `phase4-txoff950-install/` (`0c7e0b0c`, margin
50) or `phase4-trace-install/` (`c1ca48c5`) with their service
installers. Install order, service stopped: `install-candidate.sh`,
`install-aes67-service.sh` (keeps the operator-edited live conf; no block
append, the live block's keys are unchanged), `systemctl start`, the
gadget re-bind; then gate, read, split, and the acceptance set on that
session if the numbers hold (expected about 798 on this anchor's terms,
front age 317, TX floor about 88).

**MEASURED 2026-09-06 19:25-19:29 UTC, margin 150 on a fresh anchor: 797
x100 at 64 frames (16.604 ms), spread 0, zero RECOVERs, one under the 798
predicted; Pi path 754; TX floor 98 after the read.** Installs by the user
at about 19:23 UTC (bridge `0d8cccfa`, supervisor `731fe129`, wrapper
`6282b108`; live conf untouched, `PROFILE=...-txoff950`), `systemctl
start`, then the gadget re-bind at 19:25:20 UTC; usbaudiod logged `Found
an audio device` and fresh `setStartingUSBFrame IN/OUT` at 19:25:21
(fresh anchor); `STAGE running` 19:26:02 on a clean prime. Session start
(`bridge-txoff950m150-session-20260906T1925Z.log`): ALIGN ok attempt 2,
RX PRIMED grid 399 ring 192 overshoot 5, TX PRIMED `ring_at_prime=298
overshoot=39 align_dropped=38 prime_phase_us=603 first_tick_wait_us=396
front_age_frames=317`, ALIGN trigger `wake_to_start_us=951 target=prime
slack_us=263` (the target was 346 us out, so the prime path took 83 us
this time, 104 at 19:13; both inside 150). Gate
`txoff950m150-noise-ch2-64f-100imp.*` 0.0% zeros, no run. Read
`txoff950m150-roundtrip-64f-20260906T192650Z` **797 x100**, spread 0,
zero RECOVERs, discontinuities 0. Split (`impulse-index.py --level 797`,
224 impulses): AES67 index chain 633, `pos_tx` -39, `pos_pi` 593,
`pi_total` 754.1 (746.2 at margin 50, 779.8 on rebind4), `usb_time` 42.9,
`tx_depth` median 137, `rx_depth` 115. The chain of three fresh-anchor
sessions, front age 336 / 312 / 317, reads 823 / 793 / 797 and Pi path
780 / 746 / 754: the level follows the front age to within the
fresh-anchor scatter. Floors at the end of the read: TX 98 (83 at margin
50 two minutes after its read; 104-107 on target64-trace), RX 77,
`tx_qlow` 0, `tx_pullmax` 48, `tx_gapmax_us` 1062, pitch 1000012.
Acceptance set launched 19:30 UTC on this session, detached: four
800-impulse runs at 64 with `USB16X16_OTHER_LOAD=0.1` (the txfix2 set ran
its four unloaded and only the soak loaded; this set loads all five), then
the 600 s soak (`txoff950m150soak`, 2400 impulses); results below.

**SOAKED 2026-09-06 19:28-19:53 UTC: the txoff950 acceptance set on the
margin-150 build, all on the 19:25 fresh-anchor session: four loaded
800-impulse runs 797 x800 each and the 600 s sixteen-channel soak 797
x2400, spread 0 on all 5,300, zero RECOVERs, TX floor 88 loaded
throughout, RX 77.** Chain launched detached at 19:28:11 UTC
(`USB16X16_OTHER_LOAD=0.1` on every run, the four 800s included):
`txoff950m150-roundtrip-64f-20260906T{192811,193149,193526,193905}Z`
**797 x800** each, `txoff950m150soak-roundtrip-64f-20260906T194242Z`
**797 x2400**, score 1.000, in/out discontinuities 0, `recovers during
run` 0 on all five, `nrestarts` 0. Floors after each run and at the end
(`bridge-txoff950m150-session-20260906T1925Z.log`, 25,436 lines, 23,775
IMPULSE lines, no RECOVER): `tx_qfloor` 88, `rx_qfloor` 77, `tx_qlow` 0,
`rx_qlow` 0, `tx_pullmax` 48, `tx_gapmax_us` 1117, `rx_gapmax_us` 1146,
pitch 1000012-1000014, TX queue 189-193 at the 1 Hz samples. Split over
the whole session (`impulse-index.py --level 797`, 5,941 impulses):
`pos_pi` 593 on every impulse, `pi_total` median 753.0 (736-767),
`usb_time` 44.0, `tx_depth` median 140 (90-192), `rx_depth` 120
(89-156). The TX floor landed on the 88 the block predicted from the 1:1
rule (107 - 19), so the cover accounting stands: this point holds about
35 spare over the 3.7 ms worst gap of 2026-09-06 against target64-trace's
54, and one period plus the 1.1 ms gaps the set produced with 40 to
spare. Against target64-trace's acceptance on the same instrument: 757
x5 opens on an aged anchor then; fresh-anchor 818-828 for that loop, 797
for this one, 21-31 lower, the 19 the front age gives plus the
fresh-anchor scatter. RTL at 32 by the user is the last item; the
predicted figure is 797 + 188 = 985 = 20.521 ms. The conf block's
strings and STATUS follow the RTL read. Service ends the set on the
19:25 session, zero RECOVERs, the txoff950 profile on bridge `0d8cccfa`.

**ACCEPTED 2026-09-06 20:00 UTC: lever 1, the aligned wait allowance,
profile `servo-aligned-both-240-rx120-sd144-tx192-target64-trace-txoff950`
on bridge `0d8cccfa` (aligned prime margin 150 us) and module `cc6852f0`:
797 at 64 frames on a fresh anchor, RTL Utility at 32 frames 20.521 ms =
985 = 797 + 188 to the sample, read by the user at about 19:58 UTC.** The
point of record moves from target64-trace (fresh anchor 818-828, RTL
21.062) to txoff950: 0.54 ms at RTL 32, 21-31 samples at 64, for 19
frames of TX cover (floor 107 -> 88, the 1:1 rule). Acceptance set:
the entry above (4 x 800 loaded and the 600 s soak all 797, zero
RECOVERs, TX floor 88, RX 77). Conf `cb6151e4`: the block's STATUS
accepted, COVER and MEASURED filled; installer `2b583011` (conf pin
`cb6151e4`, `66f92ed0` joins the unedited-shipped list). Live conf: the
block's keys are already live; the four label lines are copied by
`copy-txoff950-labels.py` (staged in `aes67-txoff950m150-install/` beside
the shipped conf; dry run without `--apply`). Yardsticks: DVS 11.312 ms
at 32; the day started at 21.062 (target64-trace, fresh anchor) and the
record's 19.688 was that loop on an aged anchor.

*What the session gained and what it settled.* (1) 0.54 ms at RTL 32 on
a fresh anchor, deterministic (5,300 impulses on one level), with the
cover accounted: the wait allowance was TX cover, and the 19 frames came
off the TX floor. (2) The prime margin is a real term: the prime path
takes 83-104 us, the 50 us build would have missed one prime in twenty,
and 150 us covers it for 5 frames; the ALIGN trigger line now shows it
(`target=`, `slack_us=`). (3) The level follows the TX front age 1:1 on
fresh anchors (336 / 312 / 317 -> 823 / 793 / 797), which is the budget's
"level = TX cover + constant" with the allowance inside the cover. Next
levers by the budget: ring target 64 -> 48 (about 16, conf only, the
bridge's bound) and sink delay 144 -> 120 after the arrival-lead export;
both spend cover elsewhere and take the same set. Service ends the
session on txoff950, the 19:25 anchor, zero RECOVERs, nothing pending on
the Pi but the label copy.

**STAGED 2026-09-06 20:10 UTC: lever 2, profile
`servo-aligned-both-240-rx120-sd144-tx192-target48-trace-txoff950`
(txoff950 with `TARGET=48` instead of 64, one variable, conf only).**
Labels copied into the live conf by the user at about 20:05 UTC
(`copy-txoff950-labels.py --apply`, 4 lines). Premise from the record:
the elastic ring is held at target + 3 in each direction and everything
over it is rendered at each capture wake, so it is a fixed depth term on
both sides; 192 -> 128 -> 64 moved the level 1:1 with the target per
direction (target64 read 191 under tx192 for 64 per direction, 2026-09-05),
and `tx_occ` / `rx_occ` have sat at target + 3 in every session (67 at
64, 131 at 128). Expected: TX front age 301 (192 + 51 + 58), RX 171 (120 +
51), about 32 under txoff950, **about 765 at 64 frames on a fresh anchor,
RTL at 32 about 19.85 ms**; floors unchanged (TX 88 loaded, RX 77),
because the queue depth is the front age less the ring and both fall by
16. Bounds: target at least one period (48 exactly, `target_frames <
requested_period` is the refusal), ring at least target + 8, prime
threshold target + queue prime + 3 (TX 243, RX 171), the Farrow needs
three frames of ring and looks eight ahead of the 51 held. Watch `tx_occ`
/ `rx_occ` 51, the PRIMED `intended` / `ring_at_prime`, the floors, and
`tx_pullmax` 48. Conf `0cfff8ac` (installer `b2999941`, conf pin moved,
`cb6151e4` joins the unedited-shipped list); block alone
`target48-block.conf` `8f92f83d`. Staged in
`~/usb-16x16-work/aes67-target48-install/` (shipped conf, block); the
installed supervisor `731fe129` lists the block from the repo conf and
from the live conf plus the block, exit 0. No bridge or supervisor
change, so no installer run: the user appends the block to the live
conf, `switch-profile` (restarts the stack), then the gadget re-bind for
the fresh anchor; gate, read, split, the acceptance set if it holds.
Rollback is `switch-profile ...-target64-trace-txoff950`. Service on the
19:25 session, zero RECOVERs.

**MEASURED 2026-09-06 20:41-20:46 UTC, lever 2 (ring target 48) on a
fresh anchor: 785 x100 at 64 frames (16.354 ms), spread 0, zero
RECOVERs; 12 under txoff950, not the 32 predicted, because the RX prime
still lands at ring 192 and its 16 moved from ring to queue (RX floor 77
-> 93) instead of leaving.** The user appended the block, ran
`switch-profile` and the gadget re-bind; usbaudiod logged fresh
`setStartingUSBFrame IN/OUT` at 20:41:54 UTC; `STAGE running` on a clean
prime. Session start (`bridge-target48-session-20260906T2041Z.log`):
ALIGN ok attempt 1, RX PRIMED `intended=171 ring_at_prime=192
overshoot=21` (the RX prime is checked at capture wakes and the ring
reaches 192 whatever the threshold, so the overshoot is permanent depth
in the RX total), TX PRIMED `intended=243 ring_at_prime=286 overshoot=43
align_dropped=50 first_tick_wait_us=332 front_age_frames=301` (317 on
txoff950: the TX side gave its 16), ALIGN trigger `wake_to_start_us=952
target=prime slack_us=181` (target 282 us out, prime path 101 us, inside
150). `tx_occ` / `rx_occ` 51. Gate `target48-noise-ch2-64f-100imp.*` 0.0%
zeros, no run. Read `target48-roundtrip-64f-20260906T204323Z` **785
x100**, spread 0, zero RECOVERs, discontinuities 0. Split (224 impulses):
AES67 chain 633, `pos_tx` -51 (-39 on txoff950), `pos_pi` 581 (593),
`pi_total` 740.0 (753.0), `usb_time` 45.0, `tx_depth` median 143,
`rx_depth` 129 (120 on txoff950: the 16 that moved into the RX queue,
less scatter). Floors after the read: TX 99 (running, loaded set to
come), RX **93** (77 on every profile since rx120), `tx_qlow` / `rx_qlow`
0, `tx_pullmax` 48, `tx_gapmax_us` 1073, pitch 1000011.

*Why the RX half did not pay, and what would make it.* The RX prime holds
until the ring reaches `intended` (171) and is only checked at the USB
capture's wakes, where the ring grows by 96 per wake on this session
(ring_at_prime 192 with intended 187 and now 171 alike); the aligned TX
prime drops its own overshoot from the front to hit its age, the RX prime
has no such drop, so the RX overshoot becomes permanent queue. The
existing `PRIME_TRIM` would discard it, but it is one flag for both
directions and on TX it would trim again after the aligned drop, so it
is not a clean lever here (and the record's "do not turn it on" of
Phase 4 stands for the prime-96 regime it was written in). The clean
form is an RX-side trim in the bridge, or an aligned RX prime that drops
to `intended` the way TX does: a build, about 16 more samples, for
another service-stop window. As it stands target48 is a strictly better
point than txoff950: 12 lower, TX unchanged, RX cover 16 higher.
Acceptance set launched 20:47 UTC on this session, detached, the same
five loaded runs; results below.

**SOAKED 2026-09-06 20:45-21:10 UTC: the target48 acceptance set, all on
the 20:41 fresh-anchor session: four loaded 800-impulse runs 785 x800
each and the 600 s sixteen-channel soak 785 x2400, spread 0 on all
5,300, zero RECOVERs, TX floor 94 loaded, RX 93.** Chain launched
detached at 20:45:13 UTC (`USB16X16_OTHER_LOAD=0.1` on every run):
`target48-roundtrip-64f-20260906T{204513,204851,205228,205606}Z` **785
x800** each, `target48soak-roundtrip-64f-20260906T205944Z` **785 x2400**,
score 1.000, discontinuities 0, `recovers during run` 0 on all five,
`nrestarts` 0. Floors after each run and at the end
(`bridge-target48-session-20260906T2041Z.log`, 25,477 lines, 23,776
IMPULSE lines, no RECOVER): `tx_qfloor` 94 (88 on txoff950's set: the TX
total is unchanged by the ring target, the 6 is scatter), `rx_qfloor` 93
(77 on every profile since rx120: the RX ring's 16 now in the queue),
`tx_qlow` 0, `rx_qlow` 0, `tx_pullmax` 48, `tx_gapmax_us` 1146,
`rx_gapmax_us` 1169, pitch 1000011-1000015; `tx_occ` 51 on every 1 Hz
sample, `rx_occ` 51 on 1533 of about 1580 and 86-87 on the rest (the RX
ring rising as the sink for RX-side wander, as it did to 192 at target
128). Split over the session (5,943 impulses): `pos_pi` 581 on every
impulse, `pi_total` median 741.4 (724-757), `usb_time` 43.6, `tx_depth`
median 144 (94-192), `rx_depth` 138 (105-180). RTL at 32 by the user is
the last item; predicted 785 + 188 = 973 = 20.271 ms.

**ACCEPTED 2026-09-06 21:15 UTC: lever 2, the ring target 48, profile
`servo-aligned-both-240-rx120-sd144-tx192-target48-trace-txoff950` on
bridge `0d8cccfa` and module `cc6852f0`: 785 at 64 frames on a fresh
anchor, RTL Utility at 32 frames 20.271 ms = 973 = 785 + 188 to the
sample, read by the user at about 21:13 UTC.** The point of record moves
from txoff950 (797 / 20.521) to target48: 0.25 ms at RTL 32, 12 samples
at 64, TX cover unchanged (floor 94 against 88), RX cover up 16 (93
against 77). Acceptance set: the entry above. Conf `1647df1a`: STATUS
accepted, COVER and MEASURED filled; installer `952f9e91` (conf pin
`1647df1a`, `0cfff8ac` joins the unedited-shipped list). Live conf: the
block is live as appended; the four label lines are copied by
`copy-target48-labels.py` (staged in `aes67-target48-install/` beside
the shipped conf; dry run without `--apply`).

*The day, 2026-09-06, in RTL at 32 on fresh anchors:* target64-trace
21.062 (the record's 19.688 was the same loop on an aged anchor), lever
1 txoff950 20.521, lever 2 target48 20.271; 0.79 ms in two conf blocks
and one bridge constant, both accepted on full sets with zero RECOVERs.
DVS 11.312. Left on the table, priced: the RX prime overshoot (about 16,
an RX-side trim or an aligned RX drop in the bridge, a build), the prime
margin's 5 frames (a render-before-target restructure, a build), sink
delay 144 -> 120 (24, after the arrival-lead export, a module rebuild).
Service ends the day on target48, the 20:41 anchor, zero RECOVERs;
nothing pending on the Pi but the label copy.

**DONE 2026-09-06 21:20 UTC: target48 labels copied into the live conf by
the user (`copy-target48-labels.py --apply`, 3 lines), playback back on;
`work/NEXT_SESSION_PROMPT.md` rewritten for the pickup (the RX prime
overshoot build first, then the render-before-target margin, then sink
delay after the arrival-lead export).** Service on the 20:41 anchor,
zero RECOVERs, nothing pending on the Pi.

**IMPLEMENTED and STAGED 2026-09-06 21:37 UTC, not yet built: the RX
prime overshoot lever, `--rx-prime-trim` in the bridge (`main.cpp`
`77450aaa`), the conf key `RX_PRIME_TRIM`, and profile
`servo-aligned-both-240-rx120-sd144-tx192-target48-trace-txoff950-rxtrim`
(target48 with `RX_PRIME_TRIM=1`, one variable).** Mechanism, from the
prime in `render_to_playback`: the RX prime is checked at the USB
capture's wakes, where the ring grows 96 per wake, so it lands at ring 192
whatever `intended` is (187 at target 64, 171 at 48) and the overshoot is
permanent RX depth; on target48 the RX queue started 21 over its 120
prime (ring 192 less the 51 held, rendered at the prime) and the RX floor
read 93 against 77. The aligned TX prime drops its own overshoot from the
front; the RX prime had no cut. The lever is the trim code already there
(`direction.prime_trim`, one pop from the ring's front before the render,
which the aligned TX drop proved safe at the same point), gated for RX
alone: a new option `rx_prime_trim`, `--rx-prime-trim 0|1`, sets
`rx.prime_trim = prime_trim || rx_prime_trim`; TX keeps `prime_trim`
alone (0: its overshoot after the aligned drop is the wait allowance and
must stay). `--rx-prime-trim 1` with `--align-rx-prime 1` is refused
(both cut the RX ring at prime time). No new state: `restart_direction`
resets `primed` and clears the ring, so a RECOVER re-prime runs the same
trim. The summary JSON gains `rx_prime_trim`. Expected on a fresh anchor:
RX PRIMED `ring_at_prime=192 trimmed=21`, the RX queue starting at 120
exactly, level about 764 at 64 frames (785 less 21), RTL at 32 about 19.83
ms; TX front age 301 and the TX floor (94 loaded) unchanged; RX floor
about 72, not the 77 the pickup prompt expected, because the 77 of every
rx120 profile carried the 5-frame overshoot of intended 187 and the trim
to intended takes that 5 as well (if 77 is to be kept, `RX_PLAYBACK_PRIME`
125 is the conf way, outside this lever). Syntax-checked clean on the Mac
(clang `-std=c++20 -Wall -Wextra -Wpedantic -Werror`, the Pi's ALSA
headers, the endian / clock_nanosleep / ESTRPIPE shims); core tests pass
on the Mac (`bridge_core` unchanged, `9c24251a`). Supervisor `48e3fd19`:
`rx_prime_trim()` (absent means 0), validation (0 or 1; refused with
`ALIGN_RX_PRIME=1`), `--rx-prime-trim` after `--prime-trim` in
`bridge_arguments`, `rx trim` in the profiles listing. Conf `a2db5efb`
adds the block after target48's (experimental, the expected figures and
the watch list in its comment; the tag `rxtrim` prefixes no field key);
installer `0347c537` (conf pin `a2db5efb`, supervisor pin `48e3fd19`,
`1647df1a` joins the unedited-shipped list; the bridge pin `0d8cccfa`
moves after the build, and until it does the staged installer must not be
run: the new supervisor passes `--rx-prime-trim` to whatever bridge is
installed and `0d8cccfa` rejects the flag). Staged on the Pi:
`~/usb-16x16-work/phase4-rxtrim-src/` (`main.cpp` `77450aaa`,
`bridge_core.cpp` `9c24251a`, `bridge_core.hpp` `0b9ea983`, tests
`46f03dcf`, no AppleDouble files; `build.sh` pinned to `77450aaa`,
refuses while the service is active) and
`~/usb-16x16-work/aes67-rxtrim-install/` (supervisor, unit, shipped conf,
installer, `rxtrim-block.conf` `b077097f`). Validated on the Pi: the
installed supervisor `731fe129` and the staged one list the block from the
repo conf and from the live conf plus the block, exit 0; the staged
supervisor's `validate_profile` on the rxtrim profile passes and its
`bridge_arguments` carry `--prime-trim 0 --rx-prime-trim 1` (the accepted
target48 profile gets `--rx-prime-trim 0`); `RX_PRIME_TRIM=2` and
`RX_PRIME_TRIM=1` with `ALIGN_RX_PRIME=1` are refused. Next, in one
service-stop window: `sudo systemctl stop usb16x16-aes67` by the user
(playback off), `build.sh`, the three pins (`install-candidate.sh`,
`install-aes67-service.sh`, the supervisor's `expected_bridge_sha256`) and
the bridge README, the install sets, then by the user `install-candidate.sh`,
`install-aes67-service.sh` (keeps the operator-edited live conf), append
the block, `switch-profile ...-rxtrim` (PROFILE only while inactive),
`sudo systemctl restart usb-16x16.service` for the fresh anchor; gate,
one 100-impulse read at 64 with the split, then the acceptance set if it
holds. The service ran target48 on the 20:41 anchor throughout, zero
RECOVERs; nothing installed.

**BUILT and STAGED 2026-09-06 23:06 UTC: bridge `913d623b`
(`--rx-prime-trim`), the rxtrim install sets, all three pins moved.**
Service stopped by the user at 23:04 UTC (playback off; the journal's
`STAGE stopped (cleanup)`); build on the Pi from `~/usb-16x16-work/phase4-rxtrim-src` (`main.cpp` `77450aaa`,
Release, the same cmake configuration, zero warnings), ctest 1/1, binary
SHA-256
`913d623b0b58b5c60e00fcb7424627dedf8601406cbd958b8a3de5f6da8bb620`, in
`work/phase4-bridge/artifacts/pi-aarch64/` (README updated, `0d8cccfa`
previous). Smoke on the Pi without devices: `--help` lists the flag,
`--rx-prime-trim 2` and `--rx-prime-trim 1` with `--align-rx-prime 1` are
refused with the intended messages. Behaviour is `0d8cccfa`'s with the
flag off. Pins: supervisor `expected_bridge_sha256` `913d623b`, supervisor
`431cf0c5`; `install-candidate.sh` `d85b6da7` (wrapper `6282b108`
unchanged); `install-aes67-service.sh` `eb12bced` (supervisor `431cf0c5`,
unit `77837e60`, conf `a2db5efb`, bridge `913d623b`). Staged:
`~/usb-16x16-work/phase4-rxtrim-install/` (binary, wrapper, installer) and
`~/usb-16x16-work/aes67-rxtrim-install/` (supervisor, unit, shipped conf,
installer, `rxtrim-block.conf` `b077097f`), hashes verified there; the
staged supervisor validates the rxtrim profile and lists the live conf,
exit 0. Rollback of the bridge: `phase4-txoff950m150-install/`
(`0d8cccfa`) with `aes67-txoff950m150-install/` (supervisor `731fe129`),
or `switch-profile ...-target48-trace-txoff950` alone for the conf side
(the new bridge and supervisor run the accepted profile unchanged, flag
0). Install order, service stopped: `install-candidate.sh`,
`install-aes67-service.sh` (keeps the operator-edited live conf), append
the block, `switch-profile ...-rxtrim` (PROFILE only while inactive),
`systemctl start`, the gadget re-bind for the fresh anchor; then gate,
read, split, and the acceptance set on that session if the numbers hold
(expected about 764 at 64, RX PRIMED `trimmed=21`, RX floor about 72, TX
front age 301).

**MEASURED 2026-09-06 23:10-23:15 UTC, the RX prime trim on a fresh
anchor: 770 x100 at 64 frames (16.042 ms), spread 0, zero RECOVERs; 15
under target48's 785; the RX prime landed at 171 (`trimmed=21`), the RX
floor 72, the TX side unchanged.** Installs by the user at about 23:08
UTC (bridge `913d623b`, supervisor `431cf0c5`, wrapper `6282b108`; the
rxtrim block appended to the live conf, `switch-profile ...-rxtrim`),
`systemctl start`, then the gadget re-bind; usbaudiod logged `Found an
audio device` and fresh `setStartingUSBFrame IN/OUT` at 23:10:46 UTC
(fresh anchor); `STAGE running` 23:11:23 on a clean prime, the bridge
started with `--prime-trim 0 --rx-prime-trim 1`. Session start
(`bridge-rxtrim-session-20260906T2311Z.log`): RX PRIMED `intended=171
ring_at_prime=192 overshoot=21 trimmed=21` (the lever, on the first
prime), TX PRIMED `intended=243 ring_at_prime=280 overshoot=37
trimmed=0 align_dropped=56 first_tick_wait_us=447 front_age_frames=301`
(301 on target48: TX untouched), ALIGN trigger `wake_to_start_us=951
target=prime slack_us=315`; `tx_occ` / `rx_occ` 51. Gate
`rxtrim-noise-ch2-64f-100imp.*` 0.0% zeros, no run, discontinuities 0.
Read `rxtrim-roundtrip-64f-20260906T231336Z` **770 x100**, spread 0,
zero RECOVERs, discontinuities 0. Split (`impulse-index.py --level 770`,
224 impulses): AES67 chain 633, `pos_tx` -57 (-51 on target48), `pos_rx`
-22 (-1: the 21 trimmed, to the frame), `pos_pi` 554 (581), `pi_total`
726.9 (741.4 on target48's session, 740.0 at its read), `usb_time` 43.1
(43.6), `rx_depth` median 121 (138 / 129 on target48), `tx_depth` 139
(144). Floors after the read: TX 96 (94 loaded on target48), RX **72**
(93 on target48, 77 on every profile since rx120: the 21 came out of the
RX queue as the arithmetic in the staged entry said, the 16 lever 2
moved there and the 5 of intended 187's overshoot that the rx120 floor
always carried), `tx_qlow` / `rx_qlow` 0, `tx_pullmax` 48,
`tx_gapmax_us` 1050, `rx_gapmax_us` 1068, pitch 1000015. Level against
the prediction: 764 expected (785 - 21), 770 read; the index chain moved
the full 27 in `pos_pi` (21 RX, 6 TX ring scatter) but the device-timeline
terms moved 15 (`pi_total` 14.5, level 15), so the `usb` remainder read
216 against 204, inside the fresh-anchor scatter the six target64-trace
re-binds showed (818-828). The chain of fresh anchors on target48's TX
side: 785 -> 770. RTL at 32 predicted 770 + 188 = 958 = 19.958 ms.
Acceptance set launched 23:15 UTC on this session, detached
(`USB16X16_OTHER_LOAD=0.1` on every run): four 800-impulse runs at 64,
then the 600 s soak (`rxtrimsoak`, 2400 impulses); results below. What
the set decides is the RX cover: 72 loaded against the 77 the record
accepted since rx120 (the RX bar was never derived; 72 covers a 1.5 ms
refill gap at 48 frames per ms, and the soak's `rx_gapmax_us` says what
the session drew). If 77 is required, `RX_PLAYBACK_PRIME` 125 restores
it for 5 samples, a conf change outside this lever.

*Aside, from the old session's log before the stop.* The 20:41 target48
session, which ended its acceptance set with zero RECOVERs, carried two
RECOVERs at 21:35:54 UTC (both directions, `capture-avail` Broken pipe,
both PCMs in XRUN, then a clean re-prime), 53.5 min in, during the tar
and scp of the rxtrim staging to the Pi (21:30-21:37 UTC). The
2026-09-04 rule ("no transfers during measurement", an scp off the Pi
stalled the bridge) held only for measurements; earlier stagings today
(19:05, 20:10) were single scps and drew no RECOVER, this one sent the
whole source tree as one tar stream over ssh. Not proven causal, one
event; noted so the next staging while the service runs is done file by
file or in the service-stop window.

**SOAKED 2026-09-06 23:15-23:40 UTC: the rxtrim acceptance set, all on
the 23:10 fresh-anchor session: four loaded 800-impulse runs 770 x800
each and the 600 s sixteen-channel soak 770 x2400, spread 0 on all
5,300, zero RECOVERs, TX floor 87 loaded, RX 72.** Chain launched
detached at 23:15:03 UTC (`USB16X16_OTHER_LOAD=0.1` on every run):
`rxtrim-roundtrip-64f-20260906T{231503,231842,232220,232558}Z` **770
x800** each, `rxtrimsoak-roundtrip-64f-20260906T232937Z` **770 x2400**,
score 1.000, discontinuities 0, `recovers during run` 0 on all five,
`nrestarts` 0. Floors after each run and at the end
(`bridge-rxtrim-session-20260906T2311Z.log`, 25,544 lines, 23,780
IMPULSE lines, 2 PRIMED, no RECOVER): `tx_qfloor` 92 / 91 / 90 / 90 / 87
(94 on target48's set, 88 on txoff950's: the TX total is not touched by
this lever, the scatter is the session's), `rx_qfloor` **72** on every
sample from the read onward (93 on target48, 77 on every profile since
rx120: the 21 trimmed, and no further creep), `tx_qlow` / `rx_qlow` 0,
`tx_pullmax` 48, `tx_gapmax_us` 1143, `rx_gapmax_us` 1178 (the worst
refill gap the set drew: 57 frames against the floor of 72), pitch
1000000-1000022 settling at 1000014; `tx_occ` 51 on every 1 Hz sample,
`rx_occ` 51 on 1629 of about 1680 and 65-75 on the rest (the RX ring as
the sink for RX-side wander, as on target48). Split over the session
(`impulse-index.py --level 770`, 5,941 impulses): `pos_pi` 554 on every
impulse, `pi_total` median 725.8 (710.6-740.3; 741.4 on target48),
`usb_time` 44.2, `rx_depth` median 132 (108-173; 138 on target48),
`tx_depth` 138 (90-181; 144). The lever paid 15 at the level and 21 in
the RX index chain, exactly the trim; the TX side (front age 301, floor
87-96, `pos_tx` -57) is the target48 point. RX cover is the open item
for acceptance: 72 loaded, 15 over the worst refill gap the set drew
(57 frames in 1.178 ms) and under the 77 the record has carried since
rx120 by the 5 that intended 187's overshoot always added; the RX bar
was never derived from a measured gap the way TX's was, so the number to
weigh is 72 against `rx_gapmax_us` over the sets (1146 / 1169 / 1178
today). RTL at 32 by the user is the last item; predicted 770 + 188 =
958 = 19.958 ms. Service ends the set on the 23:10 session, zero
RECOVERs, the rxtrim profile on bridge `913d623b`.

**ACCEPTED 2026-09-06 23:50 UTC: the RX prime trim, profile
`servo-aligned-both-240-rx120-sd144-tx192-target48-trace-txoff950-rxtrim`
on bridge `913d623b` (`--rx-prime-trim`), supervisor `431cf0c5` and
module `cc6852f0`: 770 at 64 frames on a fresh anchor, RTL Utility at 32
frames 19.958 ms = 958 = 770 + 188 to the sample, read by the user at
about 23:47 UTC.** The point of record moves from target48 (785 /
20.271) to rxtrim: 0.31 ms at RTL 32, 15 samples at 64, TX cover
unchanged (floor 87-96 loaded against 94), RX cover 72 against 93 (77
before lever 2), which is the 21 the RX prime no longer carries.
Acceptance set: the entry above (4 x 800 loaded and the 600 s soak all
770, zero RECOVERs). Conf `c8515d93`: STATUS accepted, COVER and MEASURED
filled, the measured line added to the block's comment; installer
`3f4b6320` (conf pin `c8515d93`, `a2db5efb` joins the unedited-shipped
list; the supervisor and bridge pins are the installed `431cf0c5` and
`913d623b`, so the installer is not re-run). Live conf: the block is live
as appended; the three label lines are copied by `copy-rxtrim-labels.py`
(staged in `aes67-rxtrim-install/` beside the shipped conf `c8515d93`;
dry run shows 3 lines, applied with `--apply` by the user). The RX cover
call: 72 loaded stands as accepted with the record's number for it, the
worst RX refill gap of the day's three sets at 57 frames (1.178 ms); if
77 is wanted back, `RX_PLAYBACK_PRIME` 125 restores it for 5 samples as
a conf-only block on this one.

*The day, 2026-09-06, in RTL at 32 on fresh anchors:* target64-trace
21.062, txoff950 20.521, target48 20.271, rxtrim 19.958; 1.10 ms in two
conf blocks and two bridge constants-plus-a-flag, each on a full set with
zero RECOVERs; the level followed the bridge's start depth 1:1 every
time (TX front age 336 / 312 / 317 / 301, then the RX prime 192 -> 171).
DVS 11.312. Left on the table, priced: the prime margin's 5 frames (a
render-before-target restructure, a build), sink delay 144 -> 120 (24,
after the arrival-lead export, a module rebuild). Service ends the day
on rxtrim, the 23:10 anchor, zero RECOVERs; nothing pending on the Pi but
the label copy.

**DONE 2026-09-07 00:00 UTC: rxtrim labels copied into the live conf by
the user (`copy-rxtrim-labels.py --apply`, 3 lines; the live block reads
STATUS accepted); `work/NEXT_SESSION_PROMPT.md` already rewritten for the
pickup (the prime margin's 5 frames first, a render-before-target build,
then sink delay after the arrival-lead export).** Service on the 23:10
anchor, zero RECOVERs, nothing pending on the Pi.

**OBSERVED 2026-09-07 13:00 UTC, from the running service's log: the
rxtrim session that ended 2026-09-06 with zero RECOVERs took three
overnight, playback on, no measurement; the 23:10 anchor is aged.** From
`/run/usb16x16/bridge.log` and the journal (Pi clock UTC-4): (1) 08:19:52
UTC, 9 h 8.5 min in (`t_us` 32913496960): both directions `capture-avail`
Broken pipe, both PCMs in XRUN, ring 51, `last_queue` 143 / 144,
`last_gap_us` 105 / 126, then a clean re-prime (RX PRIMED `ring_at_prime=192
trimmed=21`, TX PRIMED `front_age_frames=301 align_dropped=63`, ALIGN
trigger `target=prime slack_us=457`). Two captures in XRUN at once with the
last observation gaps at about 100 us means the audio thread did not run
for longer than a capture buffer (192 frames, 4 ms): a Pi-side stall, like
2026-09-04's; the journal around it holds only the daemon's SAP
announcements and the recovery's own PCM stop / prepare lines. (2)
12:48:56 UTC, 13 h 37.5 min in (`t_us` 49057204993): usb-to-ravenna alone,
`playback-avail` Broken pipe, capture RUNNING, playback XRUN, ring 51,
`last_queue` 31, `last_gap_us` 4; the DEPTHSTEP line 1 ms before it:
`depth_floor=82 ring=51 queue=31 avail=353 capture_backlog=0 pull=48
gap_us=985`; the 1 Hz line 10 s before: `tx_queue=222 tx_qfloor=87
tx_pullmax=48`. The TX queue fell from about 222 to 31 inside 10 s with the
device still pulling 48 per observation and no long observation gap
(`tx_gapmax_us` 1384 for the session), so the writer's input fell short by
about 190 frames, 4 ms: a USB capture shortfall on the Mac or gadget side,
not a refill gap, and no queue floor under 190 would have held it. The
re-prime: TX PRIMED `ring_at_prime=249 overshoot=6 align_dropped=87
front_age_frames=301`, ALIGN trigger `target=prime slack_us=937`. Since
then `tx_restarts=2 rx_restarts=1`, `tx_qfloor` 31 (set by the drain),
`rx_qfloor` 63 (the session the first re-prime drew; 72 before it, the RX
side's own per-session draw), `tx_qlow` 3, `tx_pullmax` 48, pitch about
1000015. Nothing to act on: the profile, bridge and supervisor are the
accepted ones; but every RECOVER restarts the gadget PCMs, so the level
this session would read is a new draw and the next read starts with the
procedure's fresh anchor as always. Both events bear on the cover call
below only negatively: neither was a refill gap that 5 frames of TX floor
would decide.

**IMPLEMENTED and STAGED 2026-09-07 13:10 UTC, not yet built: the prime
margin's 5 frames as `--align-prime-age-margin-us` in the bridge
(`main.cpp` `daaa3eb7`), the conf key `ALIGN_PRIME_AGE_MARGIN_US`, and
profile
`servo-aligned-both-240-rx120-sd144-tx192-target48-trace-txoff950-rxtrim-age50`
(rxtrim with the key at 50, one variable).** *The mechanism, corrected
from the pickup prompt.* The prompt's lever was a reorder: render the TX
prime before placing the trigger target, so the 150 us placement margin
becomes 50 us of real slack and the longest wait 53 frames instead of 58.
Read against the code, the reorder changes nothing about which tick starts
a session: the target is the first grid point at least the margin ahead of
the prime instant, and a render done before the target is placed only
moves the placement to the same grid point when the render finished in
time or to the next one when it did not, which is exactly what placing
the target 150 us ahead already picks (the sessions whose grid point falls
50-150 us after the prime instant are the ones the reorder would miss).
What the margin actually costs is in the front age's arithmetic alone:
the aligned prime makes the front frame's age at the first tick a constant
equal to the prime depth (243) plus the longest wait it allows for, and
that allowance is computed from the placement margin (150 + 2 ticks - 950
= 1200 us, 58 frames, front age 301) because the drop is clamped so the
ring after it never sits under the prime level. The 100 us between 150
and 50 is the render path's own time (83-104 us measured 2026-09-06): it
must lie inside the placement margin, but nothing requires the age to
carry it. So the lever is: price the age at a 50 us margin (50 + 2000 -
950 = 1100 us, 53 frames, front age 296) while the target keeps its 150 us
placement, and let the drop leave the ring under the prime level by the
difference (5 frames) in the sessions whose wait exceeds 1104 us, about
one in ten. In those sessions the render hands the RAVENNA playback queue
188-192 frames instead of 193-241, and the USB capture wake that falls
inside the trigger sleep in exactly those sessions (the wait is over a
tick there; the sleep runs from about 100 us after the wake to the target)
refills it at the start, within tens of microseconds of the first pull
either way; the queue's momentary minimum at the first pull is 188 against
193 today, over the 87 floor by a hundred. Every other session is the
2026-09-06 prime with 5 more frames dropped. The expected level moves 5
(the level follows the TX front age 1:1 on fresh anchors), the TX queue
sits 5 shallower everywhere, and the TX floor gives 5, which is the TX
cover this lever spends. *The code.* `--align-prime-age-margin-us N`
(default 150, the placement margin, so the flag absent is `913d623b`'s
behaviour to the frame; at most 150; any other value needs
`--align-tx-prime 1` or `--align-rx-prime 1`), `Direction::
align_prime_age_margin_ns` set for both directions; in the aligned prime
the wait bounds split into the placed pair (`min_wait`, `max_wait`, from
`kAlignPrimeMarginNs`, unchanged: the hold level and the wait draw) and the
aged bound (`aged_wait` from the age margin), `age_frames = prime +
aged_wait_frames`, the drop limit `ring - prime + (max_wait_frames -
aged_wait_frames)`; the overshoot no longer underflows when the ring sits
under the prime level, and the PRIMED line gains `under_prime=` (0, or
1-5 in a long-wait session, after `front_age_frames=`); the summary JSON
gains `align_prime_age_margin_us`. At 950/1000/150/50: hold level 287
(292 before), so the ring at prime lands at 288 or 336 (336 before), the
drop absorbs either; waits 200-1200 us as before, `slack_us` unchanged.
Core untouched (`bridge_core.cpp` `9c24251a`, `.hpp` `0b9ea983`, tests
`46f03dcf`). Syntax-checked clean on the Mac (clang `-std=c++20 -Wall
-Wextra -Wpedantic -Werror`, the Pi's ALSA headers, the endian /
clock_nanosleep / ESTRPIPE shims); core tests pass on the Mac.
*Supervisor `ad7dcb72`:* `align_prime_age_margin()` (absent means 150),
validation (unsigned integer up to 150; not 150 needs `ALIGN_TX_PRIME=1`
or `ALIGN_RX_PRIME=1`), `--align-prime-age-margin-us` after
`--align-rx-prime` in `bridge_arguments`, `age margin N us` in the
profiles listing. *Conf `e083c0e9`:* the age50 block after rxtrim's
(experimental; the mechanism, the expected figures and the watch list in
its comment; the tag `age50` prefixes no field key). *Installer
`fc6be5d4`:* conf pin `e083c0e9`, supervisor pin `ad7dcb72`, `c8515d93`
joins the unedited-shipped list; the bridge pin `913d623b` moves after the
build, and until it does the staged installer must not be run: the new
supervisor passes `--align-prime-age-margin-us` to whatever bridge is
installed and `913d623b` rejects the flag. *Staged on the Pi*, file by
file with the service running (eight scps, the RECOVER count 3 before and
after): `~/usb-16x16-work/phase4-age50-src/` (`main.cpp` `daaa3eb7`,
`bridge_core.cpp` `9c24251a`, `bridge_core.hpp` `0b9ea983`, tests
`46f03dcf`, CMakeLists, README, no AppleDouble files; `build.sh`
`13b18037` pinned to `daaa3eb7`, refuses while the service is active) and
`~/usb-16x16-work/aes67-age50-install/` (supervisor `ad7dcb72`, unit
`77837e60`, shipped conf `e083c0e9`, installer `fc6be5d4`,
`age50-block.conf` `3c581d6f`). *Validated on the Pi:* the staged
supervisor lists the staged conf (59 profiles, exit 0) and the live conf
plus the block (exit 0, `PROFILE` still rxtrim); the installed supervisor
`431cf0c5` lists the live conf plus the block, exit 0 (it ignores the
key); the staged supervisor's `validate_profile` passes the age50 profile
on the staged conf and on the live conf plus the block, its
`bridge_arguments` carry `--align-prime-age-margin-us 50` for age50 and
`150` for rxtrim (the accepted profile runs unchanged); `200`, `5x`, and
`50` with `ALIGN_TX_PRIME=0` are refused with the intended messages.
*Expected on a fresh anchor:* TX PRIMED `front_age_frames=296`
(`ring_at_prime` 288 or 336, `under_prime=0`, or 1-5 when
`first_tick_wait_us` exceeds 1104), ALIGN trigger `target=prime` with
`slack_us` as before; **about 765 at 64 frames** (770 - 5), RTL at 32
about 19.85 ms (953 = 765 + 188); TX floor about 82 loaded (87-96 on
rxtrim), RX untouched (72, PRIMED `trimmed=21`). The cover call is the
user's: 3.7 ms was the worst TX refill gap of 2026-09-06 and TX prime 192
holds about 30 spare over it now, about 25 after; the overnight events
above were not refill gaps. Next, in one service-stop window: `sudo
systemctl stop usb16x16-aes67` by the user (playback off), `build.sh`,
the three pins (`install-candidate.sh`, `install-aes67-service.sh`, the
supervisor's `expected_bridge_sha256`), the bridge README and the
artifact, the install sets (`phase4-age50-install/` with the wrapper
`6282b108`), then by the user `install-candidate.sh`,
`install-aes67-service.sh` (keeps the operator-edited live conf), append
`age50-block.conf` to the live conf, `switch-profile ...-rxtrim-age50`
(PROFILE only while inactive), `systemctl start`, `sudo systemctl restart
usb-16x16.service` for the fresh anchor; gate, one 100-impulse read at 64
with the split, then the acceptance set if it holds. Rollback: `switch-
profile ...-rxtrim` alone (the new bridge and supervisor run it unchanged,
flag 150), or `phase4-rxtrim-install/` with `aes67-rxtrim-install/` for
the binaries. Service unchanged throughout: rxtrim on `913d623b`, the
aged 23:10 anchor.

**BUILT and STAGED 2026-09-07 13:15 UTC: bridge `05f37bd9`
(`--align-prime-age-margin-us`), the age50 install sets, all three pins
moved.** Service stopped by the user at about 13:11 UTC (playback off);
build on the Pi from `~/usb-16x16-work/phase4-age50-src` (`main.cpp`
`daaa3eb7`, Release, the same cmake configuration, zero warnings), ctest
1/1, binary SHA-256
`05f37bd911c4f9960eb6f2150accc8603dc4ac92e26622a397706619eea7a233`, in
`work/phase4-bridge/artifacts/pi-aarch64/` (README updated, `913d623b`
previous). Smoke on the Pi without devices: `--help` lists the flag, `200`
is refused (0..150), `50` without an aligned prime is refused with the
intended message, and with `--align-tx-prime 1` the run proceeds to the
device open. Behaviour is `913d623b`'s with the flag absent. Pins:
supervisor `expected_bridge_sha256` `05f37bd9`, supervisor `7a5d2362`;
`install-candidate.sh` `a324aeb7` (wrapper `6282b108` unchanged);
`install-aes67-service.sh` `bdb5319f` (supervisor `7a5d2362`, unit
`77837e60`, conf `e083c0e9`, bridge `05f37bd9`). Staged:
`~/usb-16x16-work/phase4-age50-install/` (binary, wrapper, installer) and
`~/usb-16x16-work/aes67-age50-install/` (supervisor, unit, shipped conf,
installer, `age50-block.conf` `3c581d6f`), hashes verified there; the
staged supervisor lists the staged conf and the live conf plus the block,
exit 0. Rollback of the bridge: `phase4-rxtrim-install/` (`913d623b`)
with `aes67-rxtrim-install/` (supervisor `431cf0c5`), or `switch-profile
...-rxtrim` alone for the conf side (the new bridge and supervisor run
the accepted profile unchanged, flag 150). Install order, service
stopped: `install-candidate.sh`, `install-aes67-service.sh` (keeps the
operator-edited live conf), append the block, `switch-profile
...-rxtrim-age50` (PROFILE only while inactive), `systemctl start`, the
gadget re-bind for the fresh anchor; then gate, read, split, and the
acceptance set on that session if the numbers hold (expected about 765 at
64, TX PRIMED `front_age_frames=296`, `under_prime` 0 or 1-5, TX floor
about 82).

**MEASURED 2026-09-07 13:19-13:32 UTC, the prime age margin on two fresh
anchors: 748 x100 on the first (an anchor whose draw and start stall made
it unusable), 766 x100 on the second (the lever's number, one over the
prediction), spread 0 and zero RECOVERs on both; TX PRIMED
`front_age_frames=296 under_prime=0` on both.** Installs by the user at
about 13:17 UTC (bridge `05f37bd9`, supervisor `7a5d2362`, wrapper
`6282b108`; the age50 block appended to the live conf, `switch-profile
...-rxtrim-age50`), `systemctl start`, then the gadget re-bind; usbaudiod
logged fresh `setStartingUSBFrame IN/OUT` at 13:18:53 UTC; `STAGE running`
13:19:36, the bridge started with `--align-prime-age-margin-us 50`.
*First session* (`bridge-age50-session-20260907T1319Z.log`): RX PRIMED
`intended=171 ring_at_prime=192 trimmed=21`, TX PRIMED `ring_at_prime=270
overshoot=27 align_dropped=18 first_tick_wait_us=542 front_age_frames=296
under_prime=0` (the ring crossed the new hold level 287 at 288, one wake
earlier than before; 270 + 26 = 296), ALIGN trigger `target=prime
slack_us=412`. Gate `age50-noise-ch2-64f-100imp.*` 0.0% zeros, no run,
discontinuities 0. Read `age50-roundtrip-64f-20260907T132056Z` **748
x100**, spread 0, zero RECOVERs: 22 under rxtrim's 770 against the 5 the
lever prices. Split (`--level 748`, 224 impulses): `pos_tx` -19 (-57 on
rxtrim: the drop difference, 56 - 18 = 38, to the frame), `pos_aes67`
585 (633: a whole period shorter), `pos_rx` -22 (unchanged), `pos_pi` 544
(554), `pi_total` 714.4 (725.8), `usb_time` 33.6 (44.2), `tx_depth` 127,
`rx_depth` 120. The bridge's start was as designed and 5 of the 22 is the
lever; the other 17 sat in the terms the bridge does not set (the AES67
chain's period and the USB legs), the largest fresh-anchor draw the record
has. The session was also unusable for cover: in its first second, before
any Mac activity, both devices pulled 96 in one gap (`tx_pullmax` 96,
`rx_pullmax` 96 in 1648 us), an audio-thread stall at start that set
`rx_qfloor` 24 and `tx_qfloor` 123 immediately (the TX floor later 86 by
an ordinary 889 us pull at 176 s; the RX floor stayed masked at 24). Not
the lever's doing (it changes the drop arithmetic alone), but the first
start of the day that stalled; rxtrim's first second had pulls of 48.
*Second session*, the user's re-draw (`sudo systemctl restart
usb-16x16.service` at about 13:29 UTC, `setStartingUSBFrame` 13:29:35,
`STAGE running` 13:30:51; `bridge-age50b-session-20260907T1330Z.log`): RX
PRIMED `ring_at_prime=192 trimmed=21`, TX PRIMED `ring_at_prime=276
overshoot=33 align_dropped=12 first_tick_wait_us=433 front_age_frames=296
under_prime=0` (276 + 20 = 296), ALIGN trigger `target=prime
slack_us=302`; first second clean (pulls 48, `rx_qfloor` 72, `tx_qfloor`
129). Gate `age50b-noise-ch2-64f-100imp.*` 0.0% zeros, no run,
discontinuities 0. Read `age50b-roundtrip-64f-20260907T133142Z` **766
x100** (15.958 ms), spread 0, zero RECOVERs: 4 under rxtrim's 770, one
over the 765 predicted. Split (`--level 766`): `pos_tx` -13 (the drop 12
plus one), `pos_aes67` 585, `pos_rx` -22, `pos_pi` 550 (554: -4),
`pi_total` 720.1 (725.8: -5.7), `usb_time` 45.9 (44.2), `tx_depth` median
130 (138), `rx_depth` 120. So on this anchor the lever paid its 5 on the
Pi path and the USB remainder read as rxtrim's; the AES67 chain reads 585
on both age50 sessions against 633 on every 2026-09-06 session, with
`pos_tx` taking the difference (the position chain's split moved with
the drop, its sum did not: 550 against 554). Floors after the read: TX
92 (87-96 on rxtrim; the 5 the lever spends shows in `tx_depth`, not yet
in a floor drawn from a 90-impulse minute), RX 72, `tx_pullmax` 48,
`tx_occ` / `rx_occ` 51, pitch 1000013. Acceptance set launched 13:32:46
UTC on this session, detached (`USB16X16_OTHER_LOAD=0.1` on every run):
four 800-impulse runs at 64, then the 600 s soak (`age50bsoak`, 2400
impulses); results below. RTL at 32 predicted 766 + 188 = 954 = 19.875
ms. The two-anchor lesson stands beside yesterday's: the level follows
the TX front age 1:1 only when the rest of the draw holds, and the first
anchor's 17 was the rest of the draw; the fresh-anchor procedure reads
one anchor, and an anchor whose first second stalls is re-drawn.

**RTL Utility at 32 frames on the age50 session, read by the user at
about 13:34 UTC: 19.875 ms = 954 = 766 + 188, to the sample.** Read while
the acceptance chain's run 1 held the device; run 1 finished on 766 x800
with zero discontinuities, so the overlap cost nothing, but the rule
stands: the harness and RTL Utility do not share the device.

**SOAKED 2026-09-07 13:32-13:58 UTC: the age50 acceptance set, all on
the 13:29 fresh-anchor session: four loaded 800-impulse runs 766 x800
each and the 600 s sixteen-channel soak 766 x2400, spread 0 on all 5,600,
zero RECOVERs, TX floor 81 loaded, RX 72.** Chain launched detached at
13:32:46 UTC (`USB16X16_OTHER_LOAD=0.1` on every run):
`age50b-roundtrip-64f-20260907T{133247,133626,134005,134344}Z` **766
x800** each, `age50bsoak-roundtrip-64f-20260907T134723Z` **766 x2400**,
score 1.000, discontinuities 0, `recovers during run` 0 on all five,
`tx_restarts` / `rx_restarts` 0. Floors after each run and at the end
(`bridge-age50b-session-20260907T1330Z.log`, 25,465 lines, 23,793
IMPULSE lines, 2 PRIMED, no RECOVER, no ZERORUN event): `tx_qfloor` 81 from
run 1 onward (87 on rxtrim's set: the 5 the lever spends came off the TX
floor as priced, plus one of scatter), `rx_qfloor` **72** on every sample
(RX untouched), `tx_qlow` / `rx_qlow` 0, `tx_pullmax` 48, `rx_pullmax` 49,
`tx_gapmax_us` 1214, `rx_gapmax_us` 1283, `tx_occ` 51 on every 1 Hz
sample, `rx_occ` 51 on 1542 of about 1600 and 65-75 on the rest (as on
rxtrim), pitch 1000014-1000016. Split over the session
(`impulse-index.py --level 766`, 5,948 impulses): `pos_tx` -13, `pos_aes67`
585, `pos_rx` -22, `pos_pi` 550 on every impulse (554 on rxtrim), `pi_total`
median 726.2 (706.2-743.1; 725.8 on rxtrim), `usb_time` 39.8 (44.2),
`tx_depth` median 134 (86-144; 138 on rxtrim), `rx_depth` 138 (108-172;
132). The position chain moved 4 and the level 4; the time-domain median
over the whole set is rxtrim's within a sample, with the lever's 5 in
`tx_depth` and the floor.

**ACCEPTED 2026-09-07 14:05 UTC: the prime age margin, profile
`servo-aligned-both-240-rx120-sd144-tx192-target48-trace-txoff950-rxtrim-age50`
on bridge `05f37bd9` (`--align-prime-age-margin-us 50`), supervisor
`7a5d2362` and module `cc6852f0`: 766 at 64 frames on a fresh anchor, RTL
Utility at 32 frames 19.875 ms = 954 = 766 + 188 to the sample.** The
point of record moves from rxtrim (770 / 19.958) to age50: 0.083 ms at RTL
32, 4 samples at 64, for 5-6 frames of TX cover (floor 87 -> 81); RX
cover unchanged (72). Acceptance set: the entry above (4 x 800 loaded
and the 600 s soak all 766, zero RECOVERs). Conf `5c12cb6f`: STATUS
accepted, COVER and MEASURED filled, the measured line and the first
anchor's 748 added to the block's comment; installer `0b14329d` (conf pin
`5c12cb6f`, `e083c0e9` joins the unedited-shipped list; the supervisor
and bridge pins are the installed `7a5d2362` and `05f37bd9`, so the
installer is not re-run). Live conf: the block is live as appended; the
label lines are copied by `copy-age50-labels.py` (staged in
`aes67-age50-install/` beside the shipped conf `5c12cb6f`; the dry run
shows 3 lines, the DESCRIPTION being unchanged; applied with `--apply` by
the user). The cover call: TX 81 loaded stands as accepted, 23 over the
worst TX refill gap of the day's sets (1214 us, 58 frames) and about 25
over the 3.7 ms bar the record carries for the prime; the 2026-09-07
overnight events (a thread stall and a 190-frame drain) were not refill
gaps and no floor under 190 would have held the drain. Rollbacks by
`switch-profile`: `...-rxtrim` (770; the installed bridge runs it
unchanged, flag 150) or `...-target48-trace-txoff950` (785); bridge sets
`phase4-age50-install/` (current), `phase4-rxtrim-install/` (`913d623b`)
with `aes67-rxtrim-install/` (supervisor `431cf0c5`).

*What the lever settled.* (1) The prime margin's cost was in the front
age's arithmetic, not in the prime's order: pricing the age at 50 us
while the target keeps its 150 us placement took the 5 frames, and
`under_prime` read 0 on all three primes of the day (waits 433-542 us,
under the 1104 us where the long-wait sessions begin), so the under-prime
case is still unobserved. (2) Two fresh anchors twelve minutes apart
read 748 and 766 with identical bridge start numbers: the level follows
the TX front age 1:1 only when the rest of the draw holds, and the first
anchor's stalled first second (both devices pulling 96 in one gap) was
the tell to re-draw. (3) The chain on fresh anchors in RTL at 32:
target64-trace 21.062, txoff950 20.521, target48 20.271, rxtrim 19.958,
age50 19.875; DVS 11.312. Left on the table, priced: sink delay 144 ->
120 (24, after the arrival-lead export, a module rebuild). Service ends
the set on age50, the 13:29 anchor, zero RECOVERs; nothing pending on the
Pi but the label copy.

**DONE 2026-09-07 14:15 UTC: age50 labels copied into the live conf by
the user (`copy-age50-labels.py --apply`, 3 lines; the live block reads
STATUS accepted, the dry run now shows 0), playback back on.** Service on
the 13:29 anchor, zero RECOVERs, nothing pending on the Pi.
`work/NEXT_SESSION_PROMPT.md` points at the handoff tail; the next lever
is sink delay 144 -> 120 after the arrival-lead export.

**IMPLEMENTED and STAGED 2026-09-07 14:25 UTC, not yet built: the
arrival-lead export, RAVENNA module patch 0002 in `work/ravenna-lead-export/`
on top of the transmit-slot fix; the prerequisite the BUDGET entry set for
sink delay 144 -> 120.** Read-only on the Pi throughout; the service ran
age50 on the 13:29 anchor, zero RECOVERs before and after. *Two findings
that correct the BUDGET entry's "one line".* (1) The driver's arrival-lead
arithmetic mixed units by a thousand, not by ten: `MTAL_LK_GetCounterTime()`
counts 100 ns and `MTAL_LK_GetCounterFreq()` returns 1e9, so the
`* 1000000 / freq` conversions put the TIC's counter time and now in 100 us
units against the SAC term's 100 ns; the reported minimum was the packet's
first-frame SAC minus the TIC's SAC in microseconds (whole milliseconds),
with the phase inside the TIC (up to 1 ms) lost, and a late packet wrapped
the unsigned difference and never reached the minimum. (2) The running
minimum was never seeded: the seed branch runs when the two reset counters
differ, both are zero after `Init`'s memset, and the only bumper
(`GetStats_SinkAheadTime`) has no caller, so the minimum sat at zero for the
life of the stream and the "one line" alone would have exported 0. *The
patch* (`0002-export-arrival-lead.patch` `e45b16b6`, `RTP_audio_stream.c`
`5d479dda` and `.h` `d4e9fbc8` after it; `manager.c` `9cbbc5a8` from 0001;
the daemon untouched: `get_RTPStream_status`'s memcpy already copies the
whole `TRTP_stream_status` and `session_manager.cpp` / `json.cpp` carry
`sink_min_time` to `GET /api/sink/status/N`): the packet path computes the
lead in 100 ns, signed (the TIC's counter time plus the SAC difference,
minus now; negative when the packet arrived after the TIC that copies its
first sample into the ALSA capture buffer), the minimum is `int32_t`;
`Create` arms the seed and sets `sink_min_time` -1; `PrepareBufferLives`
closes an interval when the daemon has fetched the status (sets -1, bumps
the reset counter so the next packet re-seeds) and otherwise publishes the
minimum in microseconds once seeded. So the API field is, per sink, the
least lead over the packets since the previous GET of that sink; -1 with no
packet since; every GET starts the next interval, so it is read in pairs
around a run (`read-lead.sh [label]` on the Mac prints both sinks with a
UTC stamp; tested against the live daemon, 0 / 0 on module `cc6852f0` as
expected). Nothing in the audio path, the stamp, the send instant or the
netlink structures changes. *Staged on the Pi*, three scps with the
service running (RECOVER count 0 before and after):
`~/usb-16x16-work/ravenna-lead-src/` holds 0001 (`a7e9bc28`), 0002
(`e45b16b6`) and `build.sh` (`72543be6`: refuses while the service is
active, copies the pristine v2.1 `common` and `driver`, cleans, applies
both patches, checks the three patched files by hash, `make modules`,
prints the warning count, the vermagic against the running kernel and the
module hash, copies the module to `~/usb-16x16-work/ravenna-lead-install/`).
Both patches dry-run clean on the Pi's pristine v2.1 tree and on a copy of
the vendored tree with 0001 applied; the six driver files compared are
byte-identical between the two. Nothing compiles on the Mac: the Pi build
is the syntax gate. *What sink delay 120 needs from it:* at 144 the lead
should read about 3 ms less the packet's lateness against its stamp less
one frame of ring grain; 120 takes 500 us off. The minimum over a loaded
800-impulse run and the 600 s soak at 144 decides it: over 1 ms, 120 keeps
0.5 ms; 0.5-1 ms, 120 is the edge the 41-sample holes at 96 showed; under
0.5 ms, the lever is closed. *Aside:* at 14:12 UTC the live API read
`rtp_seq_id_error` and `rtp_sac_error` true on both sinks and `all_muted`
true on sink 1, flags accumulated since whatever GET came before (the
status resets on fetch); the reads made here reset them, so a later GET
says whether they recur. Not gated on, per the rule. *Next, in one
service-stop window by the user:* `sudo systemctl stop usb16x16-aes67`
(playback off), `~/usb-16x16-work/ravenna-lead-src/build.sh`; then the pins
(supervisor `module_binary` to `ravenna-lead-install/` and
`expected_module_sha256` to the built hash, `install-aes67-service.sh`'s
supervisor pin, the module into `work/ravenna-lead-export/artifacts/` and
the README), `aes67-lead-install/` staged (supervisor, unit, shipped conf,
installer; profile, bridge and conf untouched), the user's
`install-aes67-service.sh`, `systemctl start`, `sudo systemctl restart
usb-16x16.service` for the fresh anchor; gate, one 100-impulse read at 64
(766 expected, the PRIMED lines as accepted), `read-lead.sh` before and
after it and around every run of the acceptance set (4 x 800 loaded, the
600 s soak), RTL at 32 by the user; then the sink delay 120 block, or not,
from the lead. Rollback: the previous supervisor (`7a5d2362`, module
`cc6852f0` from `ravenna-tx-fix-install/`) through `aes67-age50-install/`,
service stopped. `CLAUDE.md`'s map carries the new directory.

**BUILT and STAGED 2026-09-07 14:35 UTC: RAVENNA module `bc694c24` (the
transmit-slot fix plus the arrival-lead export), the lead install set, the
supervisor's module pins moved.** Service stopped by the user at about
14:28 UTC (playback off); `build.sh` on the Pi from
`~/usb-16x16-work/ravenna-lead-src` (both patches applied to a fresh copy
of the pristine v2.1 tree; patched `manager.c` `9cbbc5a8`,
`RTP_audio_stream.c` `5d479dda`, `.h` `d4e9fbc8` checked by the script),
`make modules` against `6.18.34+rpt-rpi-2712`, zero warnings, vermagic
`6.18.34+rpt-rpi-2712 SMP preempt mod_unload modversions aarch64` (the
running kernel), SHA-256
`bc694c24c77893836dd3a3cfa0c9105e68b556d19dd51a84bf9ee5ca3f1b98ff`, in
`~/usb-16x16-work/ravenna-lead-install/` and, gitignored like every
module, `work/ravenna-lead-export/artifacts/`. (`build.sh` ran as
`72543be6` and could not find `modinfo` on the user's PATH, cosmetic; it
now calls `/usr/sbin/modinfo`, `a4ca94d2`, re-staged.) Pins: supervisor
`module_binary` at `ravenna-lead-install/`, `expected_module_sha256`
`bc694c24`, comment naming both rollbacks; supervisor `631e88e1`;
`install-aes67-service.sh` `12a6972d` (supervisor pin `631e88e1`; unit
`77837e60`, conf `5c12cb6f`, bridge `05f37bd9` unchanged). Staged
`~/usb-16x16-work/aes67-lead-install/` (supervisor, unit, shipped conf,
installer), hashes verified there; the staged supervisor lists the repo
conf and the live conf (90 lines, `PROFILE` still age50), exit 0; the
installed bridge is `05f37bd9`, the installed supervisor `7a5d2362`. The
profile, bridge and conf are untouched: the live conf is not rewritten by
the installer (operator-edited, kept). Install order, service stopped, by
the user: `install-aes67-service.sh` from `aes67-lead-install/`,
`systemctl start usb16x16-aes67`, `sudo systemctl restart
usb-16x16.service` for the fresh anchor; the supervisor's own hash check
gates the `insmod`. Then gate, one 100-impulse read at 64 (766 expected,
PRIMED as accepted), `read-lead.sh` before and after, and the acceptance
set with a lead pair around every run. Rollback: `aes67-age50-install/`'s
installer (supervisor `7a5d2362`, module `cc6852f0`), service stopped.

**MEASURED 2026-09-07 14:49-14:53 UTC, module `bc694c24` on a fresh
anchor: the arrival lead reads, per sink, about 1.02-1.06 ms at sink delay
144, steady and identical on both sinks; 759 x100 at 64 frames (15.812
ms), spread 0, zero RECOVERs, the bridge's start numbers the accepted
ones.** Installs by the user at about 14:45 UTC
(`aes67-lead-install/install-aes67-service.sh`: supervisor `631e88e1`,
module `bc694c24` loaded through the supervisor's own hash check; bridge
`05f37bd9` and the live conf untouched, `PROFILE` age50), `systemctl
start`, then the gadget re-bind; usbaudiod logged fresh
`setStartingUSBFrame IN/OUT @ 582299529` at 14:48:58 UTC (fresh anchor);
journal `STAGE ptp locked in 10s`, `sinks applied, delay 144`, `STAGE
running` 14:49:26, the bridge started with the age50 arguments. Session
start (`bridge-lead-session-20260907T1449Z.log`): RX PRIMED `intended=171
ring_at_prime=192 overshoot=21 trimmed=21`, TX PRIMED `ring_at_prime=269
overshoot=26 align_dropped=19 first_tick_wait_us=576 front_age_frames=296
under_prime=0`, ALIGN trigger `target=prime slack_us=445`; first second
clean (pulls 48, `rx_qfloor` 72, `tx_qfloor` 170). *The lead, the number
this module exists for* (`read-lead.sh`, each line the minimum since the
previous GET of that sink): since stream start 1023 / 1029 us (sinks 0 /
1), the next 24 s idle 1056 / 1059, over the gate probe 1034 / 1043, over
the 100-impulse read 1017 / 1027. So at sink delay 144 (3.0 ms) the
packets of both Ferrofish streams arrive about 1.95-2.0 ms after their
stamp at the worst over an interval (1 ms of it inherent: a 1 ms packet
cannot leave before its last sample), which puts the lead at sink delay
96 at about 0 and explains the 41-sample holes there to the number; at
120 the lead would be about 0.52-0.56 ms, the edge the BUDGET entry
priced, with one refill gap's worth of margin at most. The number over
the loaded set decides it (below). Gate `lead-noise-ch2-64f-100imp.*`
0.0% zeros, no run, discontinuities 0, `placementMisses` 0. Read
`lead-roundtrip-64f-20260907T145129Z` **759 x100**, spread 0, zero
RECOVERs, discontinuities 0; floors after it TX 85, RX 72, `tx_pullmax`
48, `tx_gapmax_us` 1073, `rx_gapmax_us` 1095. Split (`impulse-index.py
--level 759`, 224 impulses): `pos_tx` -20 (-13 on age50b: the drop 19
against 12, to the frame), `pos_aes67` 585, `pos_rx` -22, `pos_pi` 543
(550), `pi_total` 711.3 (726.2), `usb_time` 47.7 (39.8), `rx_depth`
median 120, `tx_depth` 128.5. Seven under age50's 766 on a clean first
second: the module touches no audio path and the bridge's start is the
accepted one to the frame, so the 7 is the anchor's draw of the terms the
bridge does not set (the Pi path read 15 under, the USB remainder 8 over),
inside the scatter the record carries for fresh anchors (748 / 766 on
2026-09-07, 818-828 on the 2026-09-06 re-binds). RTL at 32 predicted 759
+ 188 = 947 = 19.729 ms, to be read by the user after the chain.
Acceptance chain launched detached at 14:53:08 UTC on this session
(`USB16X16_OTHER_LOAD=0.1` on every run): four 800-impulse runs at 64
(`lead`), then the 600 s soak (`leadsoak`, 2400 impulses), with a
`read-lead.sh` pair around every run; results below.

**SOAKED 2026-09-07 14:53-15:18 UTC: the module `bc694c24` acceptance set,
all on the 14:48 fresh-anchor session: four loaded 800-impulse runs 759
x800 each and the 600 s sixteen-channel soak 759 x2400, spread 0 on all
5,600, zero RECOVERs, TX floor 76 loaded, RX 72; the arrival lead's
minimum over the set 930 us (run 4, sink 0), the soak 984 / 988.** Chain
launched detached at 14:53:08 UTC (`USB16X16_OTHER_LOAD=0.1` on every
run, a `read-lead.sh` pair around each):
`lead-roundtrip-64f-20260907T{145308,145647,150027,150407}Z` **759 x800**
each, `leadsoak-roundtrip-64f-20260907T150747Z` **759 x2400**, score
1.000, discontinuities 0, `recovers during run` 0 on all five,
`nrestarts` 0. *The lead per run* (the minimum over the run's packets,
sinks 0 / 1, microseconds): before run 1 1009 / 1034 (idle since the
read), run 1 1014 / 1022, run 2 994 / 1001, run 3 988 / 995, run 4 **930
/ 943**, the soak 984 / 988. The two Ferrofish streams read within 7-25
us of each other on every interval; the worst packet of 35 loaded
minutes arrived 2.07 ms after its stamp, the typical worst of a 3 min run
about 2.0 ms. Floors after each run and at the end
(`bridge-lead-session-20260907T1449Z.log`, 25,545 lines, 23,772 IMPULSE
lines, 2 PRIMED, no RECOVER, no ZERORUN event): `tx_qfloor` 76 from run
1 onward (85 after the read; 81 on age50's set, 87 on rxtrim's: the TX
total is not touched by the module, the session drew its floor by an
ordinary 885-960 us pull, DEPTHSTEP at 31 s and 207 s), `rx_qfloor` 72 on
every sample, `tx_qlow` / `rx_qlow` 0, `tx_pullmax` 48, `rx_pullmax` 49,
`tx_gapmax_us` 1124, `rx_gapmax_us` 1165, `tx_occ` 51 on every 1 Hz
sample, `rx_occ` 51 on 1626 of about 1680 and 64-67 on the rest, pitch
1000014. Split over the session (`impulse-index.py --level 759`, 5,938
impulses): `pos_tx` -20, `pos_aes67` 585, `pos_rx` -22, `pos_pi` 543 on
every impulse (550 on age50b), `pi_total` median 715.6 (696.8-731.0;
726.2 on age50b), `usb_time` 43.4 (39.8), `rx_depth` median 136
(108-168), `tx_depth` 126 (79-170). The audio path is age50's to the
frame; the level is this anchor's draw, 7 under. RTL at 32 by the user is
the last item; predicted 759 + 188 = 947 = 19.729 ms. *What the lead says
about sink delay 120:* at 144 the worst lead over the set was 930 us; 120
takes 500 us off, leaving about 430 us (21 samples) at the set's worst
packet and about 500 us on a typical run, against a per-interval minimum
that fell run by run (1014, 994, 988, 930) as the sample grew. At 96 the
same packets would have read about -70 us, which is the 41-sample holes
of 2026-09-04 to the number, so the instrument and the record agree. The
call is the user's: 120 is a conf-only block, one variable, reversible by
`switch-profile`, and with the export in place a late packet shows as a
negative `sink_min_time` and in the zero-run detector rather than as a
mystery hole; the risk is that the lateness tail beyond 35 minutes
reaches 0.5 ms, and each such packet costs one lap of the sink's jitter
slot. An intermediate 132 (12 samples, 0.25 ms) would keep about 0.68 ms
at the same worst packet.

**ACCEPTED 2026-09-07 15:25 UTC: RAVENNA module `bc694c24` (the
transmit-slot fix plus the arrival-lead export) as the point of record's
module, profile `...-target48-trace-txoff950-rxtrim-age50` unchanged on
bridge `05f37bd9` and supervisor `631e88e1`: 759 at 64 frames on a fresh
anchor, RTL Utility at 32 frames 19.729 ms = 947 = 759 + 188 to the
sample, read by the user at about 15:22 UTC.** The point of record's
figures stay age50's (766 / 19.875 on the 13:29 anchor; this anchor drew
759 / 19.729 with the bridge's start identical, the fresh-anchor draw the
record carries): the module changes no audio path and the set (the entry
above: 4 x 800 loaded and the 600 s soak all 759, zero RECOVERs, TX floor
76, RX 72) is its stability acceptance, and `GET /api/sink/status/N`
`sink_min_time` is now a measured number, the least arrival lead per
sink since the previous fetch. Pins as installed: supervisor `631e88e1`
(`module_binary` `ravenna-lead-install/`, `expected_module_sha256`
`bc694c24`), installer `12a6972d`; conf `5c12cb6f` and the live conf
untouched. Rollbacks: `aes67-age50-install/` (supervisor `7a5d2362`,
module `cc6852f0`), service stopped; the original module `f65a4955`
stays in the v2.1 tree. *Open, priced by the lead:* sink delay 144 -> 120
(24 samples; about 430 us of lead left at the set's worst packet, 500
typical) or 132 (12 samples; about 680 us), a conf-only block either way,
the user's call; the export reads it live and a late packet shows as a
negative `sink_min_time`. Service ends the set on the 14:48 anchor, zero
RECOVERs; nothing pending on the Pi. Playback may go back on.

**STAGED 2026-09-07 15:45 UTC, conf only: sink delay 144 -> 132, profile
`servo-aligned-both-240-rx120-sd144-tx192-target48-trace-txoff950-rxtrim-age50-sd132`
(age50 with `SINK_DELAY=132`, one variable), chosen by the user over 120
for the margin the lead export priced (about 680 us at the set's worst
packet against about 430).** Sink delay changes no audio: it is the
driver's playout hold, and its only failure is a packet arriving after
its TIC, which the TIC copies as a stale slot (the 41-sample holes at 96);
at 144 the worst packet of 35 loaded minutes kept 930 us. Conf `d853a5d3`
(the block after age50's: mechanism, the lead figures, the expected
numbers and the watch list in its comment; STATUS experimental, COVER as
age50 until measured, MEASURED not yet; the tag `sd132` prefixes no field
key); `sd132-block.conf` `e3cd8431`; installer `0a4ce3ba` (conf pin
`d853a5d3`, `5c12cb6f` joins the unedited-shipped list; supervisor
`631e88e1`, unit `77837e60`, bridge `05f37bd9` unchanged, so the installer
is not run for this lever). Staged on the Pi with the service running
(five scps, RECOVER count 0 before and after):
`~/usb-16x16-work/aes67-sd132-install/` (shipped conf, the block,
installer, supervisor, unit). Validated on the Pi with the installed
supervisor `631e88e1`: the staged conf lists 93 lines with the sd132
profile (`sink delay 132`, everything else age50's), exit 0; the live
conf plus the block likewise, `PROFILE` still age50. Expected on a fresh
anchor: level 12 under age50's (about 754; 747 against the 14:48 anchor's
759), RTL at 32 about 0.25 ms under, `pos_aes67` 585 -> 573,
`sink_min_time` about 0.68-0.81 ms per interval and never negative, the
bridge's PRIMED lines and floors unchanged. Next, by the user, playback
off: `sudo systemctl stop usb16x16-aes67`, append the block (`sudo tee
-a /etc/usb16x16/aes67.conf < ~/usb-16x16-work/aes67-sd132-install/sd132-block.conf`),
`sudo usb16x16-aes67-supervisor switch-profile ...-age50-sd132` (PROFILE
only while inactive), `sudo systemctl start usb16x16-aes67`, `sudo
systemctl restart usb-16x16.service` for the fresh anchor; then gate,
read, split, a lead pair around everything, the acceptance set, RTL at
32; then a day of lead reads before the label moves. Rollback:
`switch-profile ...-rxtrim-age50` (conf only).

**MEASURED 2026-09-07 17:19-17:23 UTC, sink delay 132 on a fresh anchor:
747 x100 at 64 frames (15.562 ms), 12 under the 14:48 anchor's 759 to the
sample, spread 0, zero RECOVERs; and the arrival lead did not move (1037 /
1039 us over the gate, 1006 / 1016 over the read, against 1034 / 1043 and
1017 / 1027 at 144), so the 12 samples cost no cover at all.** By the
user: service stopped 17:17:55 UTC (playback off), the block appended to
the live conf (1165 lines), `switch-profile ...-age50-sd132`, `systemctl
start` (`STAGE running` 17:18:59), then the gadget re-bind at 17:19:01;
usbaudiod logged fresh `setStartingUSBFrame IN/OUT @ 591304021` at
17:19:03 UTC (fresh anchor); the service restarted itself after the
re-bind (systemd's restart counter 1, which is that mechanism), `STAGE
sinks applied, delay 132`, both sinks reading back `"delay": 132`,
`STAGE running` 17:20:02. Session start
(`bridge-sd132-session-20260907T1719Z.log`): RX PRIMED `ring_at_prime=192
trimmed=21`, TX PRIMED `ring_at_prime=269 overshoot=26 align_dropped=19
first_tick_wait_us=577 front_age_frames=296 under_prime=0`, ALIGN trigger
`target=prime slack_us=445`: the same draw as the 14:48 anchor to the
microsecond (269 / 19 / 576 / 445), so the two sessions compare directly.
Gate `sd132-noise-ch2-64f-100imp.*` 0.0% zeros, no run, discontinuities
0, no ZERORUN event. Read `sd132-roundtrip-64f-20260907T172213Z` **747
x100**, spread 0, zero RECOVERs, discontinuities 0; floors after it TX
85, RX 72 (85 / 72 at the same point of the 14:48 session), `tx_pullmax`
48. Split (`impulse-index.py --level 747`, 224 impulses): `pos_tx` -20,
`pos_aes67` **573** (585 at 144: the lever's 12, to the frame), `pos_rx`
-22, `pos_pi` 531 (543), `pi_total` 701.8 (711.3), `usb_time` 45.2
(47.7), `rx_depth` 121.5, `tx_depth` 128. RTL at 32 predicted 747 + 188
= 935 = 19.479 ms.

*CORRECTION to the sink-delay pricing in the BUDGET entry, the
`ravenna-lead-export` README and the sd132 block's comment ("at 120 about
430 us would be left, at 132 about 680").* The lead is measured, and the
packet is consumed, at TIC-frame granularity: the driver places the
packet's first sample at stamp plus delay and rounds that down to the
48-sample frame whose TIC copies it (`ProcessRTPAudioPacket`,
`ui64UsedSAC`; the capture interrupt reads the ring at the global SAC), so
the deadline moves only when the stamp's phase within the frame plus the
delay crosses a 48-sample boundary. Lowering 144 to 132 moved the data 12
samples earlier inside the same frame and left the deadline where it was:
12 samples of latency for zero lead, as measured. The cost is a step, not
a slope: at some delay between 132 and 96 the boundary is crossed and the
deadline jumps a whole frame earlier (lead about 40 us, which is the
41-sample holes at 96), and every delay above that crossing is free. The
crossing is at 144 less the Ferrofish stamp phase (the lead at 132 says
the phase is at least 12 samples); below it nothing between 96's lead and
144's exists. 120 would therefore read either 144's lead (phase at least
24) or 96's, never "430 us left". The stamp phase is readable from an
`eth0` capture (RTP timestamp mod 48, `rtp-impulses.py` territory) or by
one more conf-only step; both sinks share `mediaclk:direct=531217786` and
read within 10 us of each other, so one phase covers both. Priced
correctly: the remaining free sink-delay samples are the phase minus 12,
at most 35, and worth one conf block once the phase is known.
Acceptance chain launched detached at 17:23:38 UTC on this session
(`USB16X16_OTHER_LOAD=0.1` on every run, a `read-lead.sh` pair around
each): four 800-impulse runs at 64 (`sd132`), then the 600 s soak
(`sd132soak`); results below.

**SOAKED 2026-09-07 17:23-17:48 UTC: the sd132 acceptance set, all on the
17:19 fresh-anchor session: four loaded 800-impulse runs 747 x800 each and
the 600 s sixteen-channel soak 747 x2400, spread 0 on all 5,600, zero
RECOVERs, TX floor 75 loaded, RX 72; the lead's minimum over the set 959
us (the soak, sink 0), every interval within the 144 set's range.** Chain
launched detached at 17:23:38 UTC (`USB16X16_OTHER_LOAD=0.1` on every
run, a `read-lead.sh` pair around each):
`sd132-roundtrip-64f-20260907T{172338,172718,173058,173439}Z` **747 x800**
each, `sd132soak-roundtrip-64f-20260907T173819Z` **747 x2400**, score
1.000, discontinuities 0, `recovers during run` 0 on all five. *The lead
per run* (sinks 0 / 1, microseconds): before run 1 1003 / 1009, run 1 977
/ 991, run 2 961 / 966, run 3 974 / 993, run 4 986 / 997, the soak **959 /
968**; at 144 the same set read 930-1014, so the deadline is the same
frame and nothing was spent. Floors after each run and at the end
(`bridge-sd132-session-20260907T1719Z.log`, 25,533 lines, 23,777 IMPULSE
lines, 2 PRIMED, no RECOVER, no ZERORUN event): `tx_qfloor` 75 from run
1 onward (76 on the 144 set of the same day, 81 on age50's: the session's
draw, the bridge does not see the sink delay), `rx_qfloor` 72 on every
sample, `tx_qlow` / `rx_qlow` 0, `tx_pullmax` 48, `rx_pullmax` 49,
`tx_gapmax_us` 1152, `rx_gapmax_us` 1182, `tx_occ` 51 on every 1 Hz
sample, `rx_occ` 51 on 1608 of about 1680 and 64-75 on the rest, pitch
1000015. Split over the session (`impulse-index.py --level 747`, 5,944
impulses): `pos_tx` -20, `pos_aes67` 573, `pos_rx` -22, `pos_pi` 531 on
every impulse (543 at 144), `pi_total` median 702.1 (685.9-719.1; 715.6 at
144), `usb_time` 44.9 (43.4), `rx_depth` median 133, `tx_depth` 127. The
lever's 12 sits in the AES67 chain on every one of 5,944 impulses. RTL at
32 by the user is the last item; predicted 747 + 188 = 935 = 19.479 ms.

**ACCEPTED 2026-09-07 17:55 UTC: sink delay 132, profile
`servo-aligned-both-240-rx120-sd144-tx192-target48-trace-txoff950-rxtrim-age50-sd132`
on bridge `05f37bd9`, supervisor `631e88e1` and module `bc694c24`: 747 at
64 frames on a fresh anchor, RTL Utility at 32 frames 19.479 ms = 935 =
747 + 188 to the sample, read by the user at about 17:52 UTC.** The point
of record moves from age50 (766 / 19.875 on its own anchor; 759 / 19.729
on the 14:48 anchor the sd132 session matched) to sd132: 0.25 ms at RTL
32, 12 samples at 64, for no cover at all (the lead's frame deadline
unchanged: 959-1009 us per interval against 930-1014 at 144; TX floor 75
against 76 on the same day's 144 set, RX 72). Acceptance set: the entry
above (4 x 800 loaded and the 600 s soak all 747, zero RECOVERs, no
ZERORUN event). Conf: STATUS accepted, COVER and MEASURED filled, the
block's comment carries the CORRECTION (the deadline moves in whole TIC
frames; the pricing the block was chosen on was wrong) and the measured
line; installer pin moved (`d853a5d3` joins the unedited-shipped list);
`copy-sd132-labels.py` for the live conf (labels only, dry run without
`--apply`; the live block is otherwise the appended one). Rollbacks by
`switch-profile`: `...-rxtrim-age50` (144; the same bridge, supervisor
and module run it unchanged), conf only.

*What the lever settled.* (1) Sink delay's cost is a step of one TIC
frame, taken when the Ferrofish stamp phase plus the delay crosses a
48-sample boundary, and zero otherwise; the lead export shows which side
of the step a delay sits (unchanged lead: free; near zero or negative:
crossed). (2) The chain on fresh anchors in RTL at 32: target64-trace
21.062, txoff950 20.521, target48 20.271, rxtrim 19.958, age50 19.875,
the 144 anchor of the day 19.729, sd132 19.479; DVS 11.312. (3) Left on
the table, priced: the rest of the free sink-delay range, 144 less the
stamp phase, between 0 and 35 more samples, one conf-only block once the
phase is read (an `eth0` capture's RTP timestamps mod 48, or a step to
120 read by the lead: unchanged means the phase is at least 24). Service
ends the set on sd132, the 17:19 anchor, zero RECOVERs; nothing pending
on the Pi but the label copy. Playback may go back on.

**DONE 2026-09-07 18:10 UTC: sd132 labels copied into the live conf by the
user (`copy-sd132-labels.py --apply`, 3 lines; the live block reads STATUS
accepted, the dry run now shows 0); playback on.** Service on the 17:19
anchor, zero RECOVERs, nothing pending on the Pi.
`work/NEXT_SESSION_PROMPT.md` rewritten 18:05 UTC for the sd132 point of
record; the next lever is the rest of the free sink-delay range, priced
by the Ferrofish stamp phase.

**FOUND 2026-09-07 21:30 UTC, from the 2026-09-06 captures: the Ferrofish
stamp phase is 41 against the RAVENNA driver's frame grid, so the free
sink-delay range runs from 144 down to 103 and 103 is the lowest free
value (41 samples under 144, 29 under 132, the same frame deadline).**
Read-only on the Pi throughout; the service ran sd132 on the 17:19 anchor,
zero RECOVERs before and after. *The captures.* `/tmp/trace1-rtp.pcap`
(01:55:15-01:56:30 UTC, module `f65a4955`) and `/tmp/txfix-rtp.pcap`
(03:05:31-03:06:46 UTC, module `cc6852f0`) are still in the Pi's tmpfs,
world-readable; the first 1.5 MB of each and 2 MB chunks at 25/50/75/99 %
were copied to the Mac (a few MB, the service idle, no measurement). *The
arithmetic, from the driver source.* The receive path takes the 32-bit RTP
timestamp, subtracts the stream's `mediaclk:direct` offset in 32-bit
arithmetic, widens the result with the high 32 bits of the global 64-bit SAC
(`ProcessRTPAudioPacket`, the wrap correction either side of 2^32), adds the
playout delay and writes the samples at that SAC into the live-in ring; the
TIC copies whole 48-sample frames at the global SAC, which is the TIC count
times 48 (`PTP.c` 955-961), so the grid is the absolute multiples of 48 and a
packet's deadline is the frame holding first-sample SAC plus delay. 2^32 is
16 mod 48, so a stream's wire phase, ((timestamp - offset) mod 2^32) mod 48,
is its grid phase shifted by 16 times the SAC high word, and that shift moves
16 every 2^32 / 48000 s = 24.855 h. The Pi's own source is stamped with the
global SAC minus one frame (`SendRTPAudioPackets`, line 845), a multiple of
48, so its wire phase is the shift alone, and the grid phase of the Ferrofish
stream is its wire phase minus the Pi's, mod 48: no epoch, no PTP time, no
root. *The reading* (`outputs/latency/stage-trace-20260906/stamp-phase.py`,
new; evidence `stamp-phase-20260906-captures.txt` beside it): sink 0's
stream `239.69.121.9` (offset 531217786) wire phase 9 on every packet of
every chunk of both captures, stamps stepping 48, no sequence gap; the Pi's
`239.69.16.1` (offset 0) wire phase 16 on every packet; grid phase (9 - 16)
mod 48 = **41**, the same across 70 minutes, a bridge restart and the module
reload between the captures. A first pass that took (timestamp - offset)
mod 48 in signed arithmetic read 9 on trace1 and 41 on txfix and looked like
a phase change; it was the 32-bit wrap (the txfix stamps sit below the
offset), corrected before anything was concluded. *Two independent checks
agree with 41.* (1) 132 measured 144's lead today, which needs a phase of
12 or more; 41 satisfies it, the alternatives the same captures would allow
without the Pi reference (9, 25) do not (9) or need a lateness the
capture rules out (25). (2) Against the Pi's own packets in the same
captures, the Ferrofish's packets arrive within -0.16..+0.04 ms of where
the Pi's arrive for the same SAC difference; the Pi sends a packet stamped
S at the TIC of S + 48, so the Ferrofish's packets arrive about 1.0-1.1 ms
after the PTP time of their first sample, not the 2 ms the lead export's
first reading was taken to mean. With phase 41 the deadline at 144 is
(144 - 41) / 48 = 2.146 ms after the first sample and the lead about 1.0
ms says the worst packet is about 1.15 ms late, consistent; with phase 9 the
deadline would be 2.81 ms out and the lead would have read 1.7-1.8 ms. So
the "packets arrive about 2 ms after their stamp" in the 14:49 UTC entry
and the export README is corrected to about 1.0-1.15 ms, and the frame
step stands. *Sink 1* (`239.69.193.115`) was not in either capture (the
filter took sink 0's group and the Pi's). Its lead has read 5-25 us above
sink 0's on every one of the 17 interval pairs at 144 and at 132, and one
sample of phase difference would show as 20.8 us with the sign set by the
direction, so its phase is 41 within a sample; the fresh capture below
settles it exactly. *What it prices.* For phase p the delays 144 - p ..
191 - p share 144's deadline frame; at 41 that is 103..150, so 132 was
free by 29 samples of slack and **103 is the lowest free delay**: 29 more
samples (0.604 ms) with the deadline of 144 and 132 exactly (103 + 41 =
144); 102 crosses to the frame before (the 41-sample holes of 96). Below
the crossing nothing between exists, as the 17:23 UTC CORRECTION said. *The
one risk any delay under 144 carries* is the Ferrofish flow re-drawing its
phase (a flow restart; the phase was constant across everything the Pi did
between the captures and, by the lead, since): 132 is crossed by 12 of the
48 possible draws, 103 by 41 of them; the lead export shows a crossing in
one read (near zero or negative on both sinks), the detector shows the
holes, and the rollback is `switch-profile` to 144, conf only. The 24.855 h
wire-phase shift is not a risk: the driver's widening cancels it, which is
why the difference against the Pi's stream is the right reading and a bare
"timestamp mod 48" is not.

**STAGED 2026-09-07 21:45 UTC, conf only: sink delay 132 -> 103, profile
`servo-aligned-both-240-rx120-sd144-tx192-target48-trace-txoff950-rxtrim-age50-sd103`
(sd132 with `SINK_DELAY=103`, one variable), gated on a fresh capture
reading phase 41 on both Ferrofish streams.** Conf `e3c3e83b` (the block
after sd132's: the mechanism, the reading, the sink 1 inference, the gate,
the expected numbers, the watch list and the restart risk in its comment;
STATUS experimental, COVER as sd132 until measured; the tag `sd103`
prefixes no field key; the block differs from sd132's in SINK_DELAY and
the four labels alone); `sd103-block.conf` `49fa061e`; installer
`fca4ddcf` (conf pin `e3c3e83b`, `ff05b089` joins the unedited-shipped
list; supervisor `631e88e1`, unit `77837e60`, bridge `05f37bd9` unchanged,
so the installer is not run for this lever). `work/ravenna-lead-export/README.md`
gains the phase-reading paragraph, `CLAUDE.md`'s map the tool. Staged on
the Pi with the service running (five scps, RECOVER count 0 before and
after): `~/usb-16x16-work/aes67-sd103-install/` (shipped conf, the block,
installer, supervisor, unit). Validated on the Pi with the installed
supervisor `631e88e1`: the staged conf lists the sd103 profile (`sink delay
103`, everything else sd132's), exit 0; the live conf plus the block
likewise, `PROFILE` still sd132. Expected on a fresh anchor whose PRIMED
lines match the 17:19 anchor's (269 / 19 / 577 / 445): level 29 under
sd132 (about **718 at 64 frames**), RTL at 32 about **18.875 ms** = 718 +
188, `pos_aes67` 573 -> 544, `pi_total` about 673, `usb_time` and the USB
remainder unchanged, `sink_min_time` the same 0.93-1.06 ms per interval on
both sinks and never negative, the bridge's PRIMED lines and floors
unchanged. *Next, by the user, in this order.* (1) The phase gate, service
running, playback on or off (a 4 s root capture of the four streams, as the
2026-09-06 captures were taken during runs without effect):

```bash
sudo timeout 4 tcpdump -i eth0 -s 1500 -B 65536 -c 8000 -w /tmp/phase-$(date -u +%Y%m%dT%H%M%SZ).pcap 'udp and dst port 5004'
```

then from the Mac the first 1.5 MB of it through `stamp-phase.py` (as
`ssh bdimaio@192.168.1.201 'head -c 1500000 /tmp/phase-*.pcap' > FILE;
python3 outputs/latency/stage-trace-20260906/stamp-phase.py FILE`): both
Ferrofish streams must read grid phase 41 with the Pi's streams as the
reference. 41 on both: install as staged. A different phase on either sink:
the value becomes 144 minus the smaller phase, re-staged conf only (a phase
under 12 means the flow has restarted since sd132's acceptance and 132
itself is crossed: roll back to 144 first). (2) Playback off, `sudo
systemctl stop usb16x16-aes67`, append the block (`sudo tee -a
/etc/usb16x16/aes67.conf < ~/usb-16x16-work/aes67-sd103-install/sd103-block.conf`),
`sudo usb16x16-aes67-supervisor switch-profile
servo-aligned-both-240-rx120-sd144-tx192-target48-trace-txoff950-rxtrim-age50-sd103`
(PROFILE only while inactive), `sudo systemctl start usb16x16-aes67`, `sudo
systemctl restart usb-16x16.service` for the fresh anchor; journal `sinks
applied, delay 103`, both sinks reading back `"delay": 103`. (3) The first
lead pair, gate, read, split, the acceptance set with a lead pair around
every run, RTL at 32. Rollback: `switch-profile ...-rxtrim-age50-sd132`
(132) or `...-rxtrim-age50` (144), conf only. Service unchanged
throughout: sd132 on the 17:19 anchor, zero RECOVERs; playback on.

**GATE PASSED 2026-09-07 21:44 UTC: the fresh capture reads grid phase 41 on
both Ferrofish streams; sd103 may be installed as staged.** The user's
`/tmp/phase-20260907T214350Z.pcap` (4 s, 9.8 MB, `udp and dst port 5004`,
service running sd132, RECOVER count 0 before and after); the first 1.5 MB
read on the Mac with `stamp-phase.py` (evidence
`stamp-phase-20260907T2143Z-gate.txt`): sink 0 `239.69.121.9` and sink 1
`239.69.193.115` both wire phase 25 on every packet, the Pi's `239.69.16.1`
and `.2` wire phase 32 on every packet, grid phase **41 on both sinks**;
stamps stepping 48, no sequence gap on either Ferrofish stream. The
capture also confirms the arithmetic outright: since the 2026-09-06
captures every wire phase moved by exactly 16 (Pi 16 -> 32, Ferrofish 9 ->
25), one SAC high-word increment in the 43 hours between, and the grid
phase did not move. So the sink 1 inference is now a reading, the free
range 103..150 holds for both sinks, and 103 is the value. (The Pi's own
streams show one 96-sample stamp step at sequence 40228 -> 40230 on both
streams at the same TIC, a packet missing from the capture, not a
Ferrofish event; the bridge log has no RECOVER.) Next: the install steps of
the STAGED entry above, by the user, playback off.

**MEASURED 2026-09-07 21:45-21:50 UTC, sink delay 103 on a fresh anchor:
719 x100 at 64 frames (14.979 ms), 28 under sd132's 747, spread 0, zero
RECOVERs; `pos_aes67` 544 (573 at 132: the lever's 29, to the frame); the
arrival lead unchanged (1079 / 1081 us since stream start, 971 / 978 over
the read, against 959-1039 at 132), so the frame deadline is 144's as the
phase said.** By the user: service stopped (playback off), the block
appended to the live conf (1233 lines), `switch-profile ...-age50-sd103`,
`systemctl start` (ActiveEnter 21:45:32 UTC), then `sudo systemctl restart
usb-16x16.service` at 21:45:36; usbaudiod logged fresh `setStartingUSBFrame
IN/OUT @ 607298717` at 21:45:38 UTC (fresh anchor). The re-bind fell inside
the daemon's PTP-lock window (`STAGE ptp locked in 11s` at 21:45:43), before
the bridge had opened the gadget PCMs, so the service did not need to
restart itself (systemd's restart counter 0) and the PCMs first opened on
the fresh enumeration: `session_manager:: media 0 playout delay 103`,
`STAGE sinks applied, delay 103`, both sinks reading back `"delay": 103`,
`STAGE running` 21:46:19. Session start
(`bridge-sd103-session-20260907T2146Z.log`): RX PRIMED `intended=171
ring_at_prime=192 overshoot=21 trimmed=21`, TX PRIMED `ring_at_prime=270
overshoot=27 align_dropped=18 first_tick_wait_us=546 front_age_frames=296
under_prime=0`, ALIGN trigger `target=prime slack_us=417` (the 17:19 anchor
read 269 / 19 / 577 / 445, the 13:19 anchor 270 / 18 / 542 / 412: one frame
of drop apart); first second clean (pulls 48, `rx_qfloor` 72, `tx_qfloor`
171). First lead pair 1079 / 1081 us (sinks 0 / 1, since stream start). Gate
`sd103-noise-ch2-64f-100imp.*` 0.0% zeros, no run, discontinuities 0,
`placementMisses` 0, no ZERORUN event. Read
`sd103-roundtrip-64f-20260907T214902Z` **719 x100**, spread 0, zero
RECOVERs, discontinuities 0; lead after it 971 / 978; floors after it TX 86,
RX 72, `tx_pullmax` 48, `rx_pullmax` 49, `tx_gapmax_us` 1049, `rx_gapmax_us`
1069, `tx_occ` / `rx_occ` 51, pitch 1000014. Split (`impulse-index.py
--level 719`, 224 impulses): `pos_tx` -19 (-20 at 132: the drop 18 against
19), `pos_aes67` **544** (573), `pos_rx` -22, `pos_pi` 503 (531), `pi_total`
673.3 (701.8: -28.5), `usb_time` 45.7 (45.2), `rx_depth` median 120,
`tx_depth` 130. So the lever's 29 sits in the AES67 chain to the frame, the
level moved 28 (the drop's one frame the other way), and the USB remainder
read as sd132's: the anchor compares directly. RTL at 32 predicted 719 +
188 = 907 = 18.896 ms, to be read by the user after the chain. Acceptance
chain launched detached at about 21:51 UTC on this session
(`USB16X16_OTHER_LOAD=0.1` on every run, a `read-lead.sh` pair around
each): four 800-impulse runs at 64 (`sd103`), then the 600 s soak
(`sd103soak`); results below.

**SOAKED 2026-09-07 21:50-22:15 UTC: the sd103 acceptance set, all on the
21:45 fresh-anchor session: four loaded 800-impulse runs 719 x800 each and
the 600 s sixteen-channel soak 719 x2400, spread 0 on all 5,600, zero
RECOVERs, TX floor 78 loaded, RX 72; the arrival lead's minimum over the
set 947 us (run 2, sink 0), every interval inside the 144 and 132 sets'
range, so the deadline is the same frame and nothing was spent.** Chain
launched detached at 21:50:16 UTC (`USB16X16_OTHER_LOAD=0.1` on every run,
a `read-lead.sh` pair around each):
`sd103-roundtrip-64f-20260907T{215016,215357,215739,220121}Z` **719 x800**
each, `sd103soak-roundtrip-64f-20260907T220502Z` **719 x2400**, score 1.000,
`recovers during run` 0 on all five, `nrestarts` 0. *The lead per run*
(sinks 0 / 1, microseconds): before run 1 1022 / 1032, run 1 985 / 989,
run 2 **947 / 958**, run 3 967 / 974, run 4 953 / 971, the soak 951 / 964;
at 144 the same set read 930-1014, at 132 959-1009. *One Mac-side event in
the soak, reported, not the lever's.* The soak's harness JSON carries one
input and one output discontinuity (every other run of the day 0), and the
bridge log has one ZERORUN event, at 22:09:02.397 UTC: a 128-frame zero run
on the 15 loaded channels (`channels=0xfffe`) that entered at `usb-capture`
first (`start_mod48=24`), then `ravenna-playback`, `ravenna-capture` and
`usb-playback` within 10 ms, the same 128 frames at every stage. A hole
that enters at the Pi's USB capture is the Mac's output going silent for
two 64-frame IO cycles, which is what the harness's discontinuity pair says
from its side; a late RAVENNA packet would have entered at
`ravenna-capture` alone and shown as a negative `sink_min_time`, and the
lead over the soak was 951 / 964. The level held 719 on all 2400 impulses
around it (score 1.000) and the bridge took no RECOVER. The sd132 soak of
the same afternoon read 0 discontinuities and no ZERORUN event; the record
carries Mac hole states as the Mac's (`no-probes-during-live-playback`).
Floors after each run and at the end
(`bridge-sd103-session-20260907T2146Z.log`, 25,578 lines, 23,777 IMPULSE
lines, 2 PRIMED, no RECOVER): `tx_qfloor` 86 after the read, 78 from about
run 3 onward by an ordinary 963 us pull (DEPTHSTEP at 32.7 s and later; 75
on sd132's set, 76 on the 144 set, 81 on age50's: the session's draw, the
bridge does not see the sink delay), `rx_qfloor` **72** on every sample,
`tx_qlow` / `rx_qlow` 0, `tx_pullmax` 48, `rx_pullmax` 49, `tx_gapmax_us`
1120, `rx_gapmax_us` 1167, `tx_occ` 51 on every 1 Hz sample (1782), `rx_occ`
51 on 1704 of about 1740 and 66-75 on the rest (as on every set), pitch
1000017. Split over the session (`impulse-index.py --level 719`, 5,944
impulses): `pos_tx` -19, `pos_aes67` **544**, `pos_rx` -22, `pos_pi` 503 on
every impulse (531 at 132), `pi_total` median 677.8 (649.1-692.8; 702.1 at
132: -24.3), `usb_time` 41.2 (44.9), `rx_depth` median 132 (108-172),
`tx_depth` 129 (79-171). The lever's 29 sits in the AES67 chain on every
one of 5,944 impulses. RTL at 32 by the user is the last item; predicted
719 + 188 = 907 = 18.896 ms.

NOTE 2026-09-10: the comparison this entry rests on is undersampled. The
acceptance set below is four runs plus a soak on one anchor, which measures
run-to-run stability, not draw-to-draw reproducibility; sd103 has since
drawn 722 on a second fresh anchor and 670/697 on plain restarts, a spread
wider than the 28 samples separating sd103 from sd132. The measurements
stand; see FOUND 2026-09-10 00:40 UTC at the tail.

**ACCEPTED 2026-09-07 22:25 UTC: sink delay 103, profile
`servo-aligned-both-240-rx120-sd144-tx192-target48-trace-txoff950-rxtrim-age50-sd103`
on bridge `05f37bd9`, supervisor `631e88e1` and module `bc694c24`: 719 at
64 frames on a fresh anchor, RTL Utility at 32 frames 18.896 ms = 907 = 719
+ 188 to the sample, read by the user at about 22:20 UTC.** The point of
record moves from sd132 (747 / 19.479 on its own anchor, the same day) to
sd103: 0.583 ms at RTL 32, 28 samples at 64, for no cover at all (the
lead's frame deadline unchanged: 947-1032 us per interval against 959-1039
at 132 and 930-1014 at 144; TX floor 78 loaded against 75 on sd132's set,
RX 72). Acceptance set: the SOAKED entry above (4 x 800 loaded and the 600
s soak all 719, zero RECOVERs; the soak's one Mac-side 128-frame gap
reported there, not the lever's). Conf `556cc2b6`: STATUS accepted, COVER
and MEASURED filled, the block's comment carries the gate, the measured
line and "102 crosses"; installer `21448108` (conf pin `556cc2b6`,
`e3c3e83b` joins the unedited-shipped list; the supervisor, unit and bridge
pins are the installed `631e88e1`, `77837e60` and `05f37bd9`, so the
installer is not re-run). Live conf: the block is live as appended (1233
lines, `PROFILE` sd103); the label lines are copied by
`copy-sd103-labels.py` (`88fc0a99`, staged in `aes67-sd103-install/` beside
the shipped conf `556cc2b6` and the installer; the dry run shows 3 lines,
the DESCRIPTION being unchanged; applied with `--apply` by the user). Staged
on the Pi with the service running (three scps, RECOVER count 0 before and
after); the installed supervisor lists the shipped conf, exit 0. Rollbacks
by `switch-profile`, conf only: `...-rxtrim-age50-sd132` (132),
`...-rxtrim-age50` (144); the same bridge, supervisor and module run all
three unchanged.

*What the lever settled.* (1) The Ferrofish stamp phase is a reading, not
an inference: 41 against the driver's frame grid on both streams, from the
Sep 6 captures and the user's fresh one, constant across a module reload,
several bridge restarts and 43 hours (the FOUND entry of 21:30 UTC has the
arithmetic; `stamp-phase.py` reads it from any `eth0` capture that holds
the Pi's own stream). (2) With the phase known the sink delay is priced
exactly: 103..150 share 144's deadline frame, 103 is the floor of the free
range, 102 crosses; the lever is closed on the Pi side unless the phase
changes. (3) The chain on fresh anchors in RTL at 32: target64-trace
21.062, txoff950 20.521, target48 20.271, rxtrim 19.958, age50 19.875, the
144 anchor of the day 19.729, sd132 19.479, **sd103 18.896**; DVS 11.312.
The day took 1.06 ms off RTL at 32 (19.958 to 18.896) and 51 samples at 64
(770 to 719). (4) The standing exposure: any delay under 144 is crossed if
the Ferrofish flow restarts with a phase under 144 minus the delay (103:
41 of 48 draws; 132: 12 of 48). After any Ferrofish, switch or Dante
Controller change, and after any unexplained ravenna-capture zero runs,
read the lead pair first: near zero or negative on both sinks means the
phase moved, `switch-profile ...-rxtrim-age50` (144) is the rollback, and
`stamp-phase.py` over a fresh capture prices the new floor. (5) Left on
the table, priced: nothing by profile on the Pi side. The TX prime (192)
sits over a bar of one period plus the Pi's worst wakeup gap (Phase 6, a
days-long gap measurement); the Mac constant (188 at RTL 32 over the
harness level, 124 plus the buffers) and the gadget's share of the USB
legs are not reachable by profile. Service ends the set on sd103, the
21:45 anchor, zero RECOVERs; nothing pending on the Pi but the label copy.
Playback may go back on.

**DONE 2026-09-07 22:40 UTC: sd103 labels copied into the live conf by the
user (`copy-sd103-labels.py --apply`, 3 lines; the live block reads STATUS
accepted, the dry run now shows 0; 1233 lines).** Service on the 21:45
anchor, zero RECOVERs, nothing pending on the Pi. `work/NEXT_SESSION_PROMPT.md`
rewritten 22:30 UTC for the sd103 point of record; no priced lever remains
on the Pi side by profile, and the standing rule for the sink delay (read
the lead pair after any Ferrofish, switch or Dante change; a re-drawn phase
means `switch-profile` to 144 and `stamp-phase.py` over a fresh capture) is
in the ACCEPTED entry and the prompt.

**STARTED 2026-09-07 23:05 UTC: Phase 6, the pull-gap bar under the TX
prime, as a days-long passive read of what the bridge already logs; the
rule for a prime cut stated before the data; the first read and the 30
saved session logs priced: on the worst clean floor of the current lineage
(75) the TX prime 192 could drop 24 to 168, and 144 would need a floor of
96 that no session has drawn.** Read-only on the Pi throughout (a few KB
over ssh, no transfer); the service on sd103, the 21:45 anchor, zero
RECOVERs, playback on. *What the bar is.* The RAVENNA playback queue is
primed to the TX prime (192; the queue starts at 219 with the untrimmed
overshoot), the TIC pulls 48 frames per millisecond whatever the bridge
does, and the bridge refills it on each USB capture wake, so the queue's
running floor is the prime less the worst drawdown the process has drawn,
and the queue is what underruns (0 is a RECOVER: audible, and a re-drawn
level). The pitch servo conserves total depth, so a prime cut of X lowers
the floor by X and nothing else: the lever is priced on the floor
directly, not on a gap model. RX is read but is not a lever (the B2 seed
experiment moved the RX floor and not the level; its floor 72 is 120 less
one pull on every session since rxtrim). *The instrument is already in
the bridge.* The once-per-second `BRIDGE` line carries, since process
start, `tx_qfloor` / `rx_qfloor` (the running queue floors), `tx_dfloor`
/ `rx_dfloor`, `tx_gapmax_us` / `rx_gapmax_us` (the longest interval
between queue observations), `tx_pullmax` / `rx_pullmax` with the gap each
came in, the pull histograms (0, 1-48, 49-96, 97-144, 145-192, 193+),
`tx_qlow` / `rx_qlow` (observations under one period: cover breached) and
the restart counters; `DEPTHSTEP` lines mark each step of the depth floor
by 24 or more with the gap that drew it; `PRIMED` counts re-primes and
`RECOVER` the underruns. The supervisor writes one log per bridge process
(`/run/usb16x16/bridge.log`, rotated once at 64 MB to `.1`, about two to
four days at the idle rate) and keeps the latest line in
`/run/usb16x16/last-bridge`, so the bar is readable at any moment without
a build, a root change or a service stop. A RECOVER contaminates the
running floor (the floor after an underrun is the underrun's), so a
session with one is priced on its `DEPTHSTEP` trail before it and flagged.
*Tools* (`outputs/latency/phase6-gapbar-20260907/`, new): `gap-bar.py`
(reads full session logs or the subset the wrapper saves; per log the
primes and the PRIMED draw, runtime, floors, gaps, largest pulls, the pull
histograms, restarts, RECOVER and ZERORUN counts, the floor trails, and
the priced prime; over several logs the worst clean floor, the longest
gap and the priced prime), `read-bar.sh [label]` (the marker lines and
the latest `BRIDGE` line from the Pi into `reads/bar-<label>-<UTC>.txt`,
then `gap-bar.py` on it; run between measurement runs, never during one),
`historical-sessions.txt` (the analyser over the 30 saved session logs).
*The rule, stated now.* A conf-only TX prime block only when the worst
floor over three or more days of real use plus the loaded acceptance set
leaves at least one period (48) at the new prime, cuts in steps of 24:
new prime = 192 - floor((worst floor - 48) / 24) x 24. A profile tag for it
must not be `tx168` (the tag would prefix the `TX_` field keys); `prime168`.
*First read, 23:03 UTC* (`reads/bar-first-20260907T230309Z.txt`, the
21:45 anchor, 1.28 h): TX floor **78**, RX 72, `tx_qlow` / `rx_qlow` 0,
gaps 1120 / 1167 us, largest pull TX 48, RX **85** at a 916 us gap (49
through the whole acceptance set; the 85 arrived during the hour of
playback after it, with the RX floor unmoved: the first tail event of the
read), TX pulls 15,978,712 of 0 and 4,613,580 of 1-48, none larger; TX
floor trail queue 219 at start, 171 at +0.0 s, 123 at +32.7 s (gap 963
us), 84 at +5.9 min (gap 887 us), so the floor was drawn by ordinary
one-millisecond gaps inside six minutes and has held since; zero
re-primes, zero RECOVERs, the soak's one 128-frame ZERORUN. Priced: 168
on this draw (30 over one period). *The saved sessions*
(`historical-sessions.txt`: 30 logs, 5.3 h, 24 clean). On the current
prime path (front age 296-317, target 48: rxtrim, target48, txoff950,
txoff950m150, age50, age50b, lead, sd132, sd103) the TX floors are 75,
76, 78, 81, 83, 84, 87, 88 and 94 over nine sessions, worst sd132's 75;
the 2026-09-06 target64 lineage (front age 336, the queue starting at
depth 214-224) read 107-155 and is not comparable. The longest gap in a
clean session is **1629 us** (age50 13:19 UTC, the stalled-first-second
anchor that was re-drawn: a 96 pull on both directions in the first
second, RX floor 24 and `rx_qlow` 1, TX floor 84 because the queue was
still at its start depth). So a 1.6 ms gap exists on this Pi; had it
fallen at the steady floor it would have drawn about 30 more, to about
48, which is exactly the cover 168 keeps and 144 does not. The gaps over
2 ms in the record (2479, 3717, 4951 us) all sit in sessions with
RECOVERs from the 2026-09-06 kill and rebind experiments, and each first
appears on the `BRIDGE` line at its session's RECOVER (+2.0 s against
the RECOVER at +1.8 s, +25.0 against +24.6, +978 inside txfix1's five
RECOVERs from +965), so they are the recovery path's, not the running
bar's. Priced on the
worst clean floor 75: **168** (24 samples, 0.5 ms at RTL 32); 144 needs
96. *Protocol.* `read-bar.sh` once a day between runs (the floors are per
process: a service restart starts a new draw, and each is counted on its
own), the reads committed as evidence; the re-prime count over days (the
open Phase 6 stability item) comes from the same read. After three or
more days on one process with the floor still at or above 72, the
`prime168` block (sd103 with `TX_PLAYBACK_PRIME=168`, one variable, conf
only, expected 24 under 719 on a matching anchor, TX floor about 54) goes
through the usual acceptance; a floor under 72 in the days closes the
lever at 192 and the record says so.

**RELOCATED 2026-09-07 23:20 UTC: the unit moved on a clean shutdown and
a cold boot; the service came back on sd103 with the accepted start, the
lead pair 989 / 996 us (the Ferrofish phase survived the move); then at
17.5 s into the process both gadget PCMs went XRUN with no host stream
stop in the Mac's log and no bridge stall, the bridge re-primed both, and
the user's RTL at 32 read 20.104 ms: a plain-restart draw on the right
profile, not a profile fault.** By the user: `shutdown -h now`, USB then
PoE unplugged, the move, power. The Mac's usbaudiod logged the
enumeration's `performStartIO` / `performStopIO` / `performStartIO` at
23:21:44-46 UTC with `setStartingUSBFrame IN/OUT @ 613066629` at 23:21:46
(a fresh anchor) and nothing after. The Pi (up at about 23:20 UTC) brought
the service up on `PROFILE` sd103: `STAGE ptp locked in 10s` (23:22:09),
`session_manager:: media 0 playout delay 103`, `STAGE sinks applied,
delay 103`, both sinks reading back 103, the bridge's arguments the
sd103 set, `ALIGN status=ok attempts=1` (no cold-boot XRUN retry this
time), `STAGE running` 23:22:45 (ActiveEnter 23:21:58 UTC, `NRestarts`
1: the re-bind mechanism), the service restart counter otherwise 0. The
start draw: RX PRIMED `intended=171 ring_at_prime=192 trimmed=21` (the
accepted line), TX PRIMED `ring_at_prime=279 overshoot=36
align_dropped=9 first_tick_wait_us=357 front_age_frames=296
under_prime=0`, ALIGN trigger `target=prime slack_us=203` (the tightest
slack on record, still hit; the front age 296 as designed). Lead pair
after the move (`read-lead.sh relocate`, 23:23:58 UTC, since stream
start): 989 / 996 us, the standing rule's first check passed, sd103 stands.
*The pair.* At `t_us=17533598` (23:22:58.5 UTC) `RECOVER
direction=ravenna-to-usb stage=playback-avail code=-32 ... ring=99
last_queue=168 last_gap_us=14` and 1.1 ms later `RECOVER
direction=usb-to-ravenna stage=capture-avail code=-32 ... ring=51
last_queue=132 last_gap_us=1055`, both PCMs `XRUN`; the bridge re-primed
both (RX 171 / 192 / 21 again; TX `ring_at_prime=280 overshoot=37
align_dropped=8 first_tick_wait_us=343 front_age_frames=296`, trigger
`target=prime slack_us=88`), and the RX re-align's own 144-frame zero
run on channel 2 (`channels=0x0002`, the only channel carrying signal)
entered at `ravenna-capture` and left at `usb-playback` 5 ms after the
RECOVER: the re-prepare of the RAVENNA capture, not a late packet (the
lead's minimum since stream start stayed at 989 / 996). `tx_gapmax_us`
1097, `rx_gapmax_us` 1120, no stall; usbaudiod logged no `stopIO` or
`startIO` at that time, so the host did not stop the stream. The cause is
not established; it is the both-PCM XRUN signature the record calls the
device open/close pair, and its consequence is the record's: a gadget PCM
restart re-draws the level on the aged anchor. The user's RTL Utility at
32 frames then read **20.104 ms** = 965 = **777 + 188**, inside the
plain-restart band (757-849), on the right profile with the right sink
delay. The fix is the fresh anchor (playback off, `sudo systemctl restart
usb-16x16.service`, STAGE running, the bridge log holding exactly two
PRIMED lines and no RECOVER) before any RTL read. *Watch:* if the pair
recurs about 17 s after a start with no host event, the USB path after
the move (cable, port) is the suspect. *Phase 6 consequence.* The day-0
read of the new process (`reads/bar-day0-20260907T232401Z.txt`, 0.02 h):
TX floor 132, RX 72, `tx_qlow` / `rx_qlow` 0, gaps 1097 / 1120 us, the
floors not drawn by the pair; the count runs from whichever process the
fresh anchor leaves (a re-bind restarts the bridge process and the
floors). `gap-bar.py` refined on this: every PRIMED line and every ALIGN
trigger are printed (the re-prime draw is the Phase 6 stability count);
the pair signature (TX `capture-avail` with RX `playback-avail` inside
one second) is counted and named without asserting its cause; the floor
is contaminated only by an observation under one period (`tx_qlow` /
`rx_qlow`) or by a TX floor step inside the two seconds before a RECOVER
(start steps excluded), since a pair re-primes without draining a queue;
the summary's longest gap is quoted from RECOVER-free sessions. The
historical run regenerated: 28 of 30 uncontaminated (draw3 by its 3717
us stall step at +23.6 s, txfix1 by `tx_qlow` 1), one pair session
(postkill, the 2026-09-06 coreaudiod kill), worst floor 75 and the priced
168 unchanged, longest RECOVER-free gap 1629 us. `DAILY_READ_PROMPT.md`
carries the pair-versus-drain rule: a pair keeps the count and re-draws
the level (a fresh anchor before any RTL read); any other RECOVER, any
`qlow` above 0, or a step before a RECOVER counts against the lever.

**FOUND 2026-09-07 23:28-23:33 UTC: the AES67 link (`eth0`, the PoE cable
at the new location) flapped 12 times in five minutes after the
relocation; the daemon lost its address and PTP, the bridge's TX ring
filled, and the supervisor read the RECOVER storm as a USB host absence
and cycled the bridge through three episodes; the user reseated the
cable and restarted the gadget, and the stack came back on sd103 with a
fresh anchor at 23:33:57 UTC.** Read-only throughout; the reading came
from the user's Dante Controller (the Ferrofish's subscriptions to the
Pi's two transmit flows unresolved, the Pi's transmitters flapping) and
the question whether this session had touched the device (it had not:
greps, `systemctl show`, GETs of the daemon API). *The link.* `macb
1f00100000.ethernet eth0: Link is Down` at 23:28:37 UTC, then down/up
ten times to 23:31:35 with up periods of 1-15 s, one renegotiation at
100 Mbps (23:32:00) among the 1 Gbps ones, two more drops after the
first reseat (23:31:47, 23:33:02), up at 1 Gbps since 23:33:07;
`carrier_down_count` 12. The Pi is powered over the same cable and
never lost power, so the data pairs or the port were marginal, not the
supply. *What the stack did.* The daemon logged `Cannot retrieve IP
address for interface eth0` every second from 23:28:44 (26 lines), PTP
read `unlocked`; the bridge, with no RAVENNA consumer, hit
`capture-ring-full` RECOVERs at 40-41 per second (`ring=768`), and the
supervisor's host-absent rule stopped it and waited: episode 1 at
23:28:41, a retry after 60 s (running 23:29:47), episode 2 at 23:30:15,
"host enumerated after 35s" and running 23:30:56, episode 3 at 23:30:59
(246 RECOVERs in that process, the RECOVER-storm line cap engaged). The
rule cannot tell a dead AoIP link from a missing USB host: a link-state
check (`/sys/class/net/eth0/carrier`) before the host-absent verdict,
and a wait on the link rather than on an enumeration, is an open
supervisor item; the record's "SSH working says nothing about AoIP
health" is the same lesson. *Recovery, by the user.* Cable reseated
(link up 23:33:07), `systemctl restart usb-16x16.service` at about
23:33:56: usbaudiod `setStartingUSBFrame IN/OUT @ 613798129` at 23:33:57
UTC (a fresh anchor), the AES67 service restarted itself (`NRestarts`
3, ActiveEnter 23:34:11), `STAGE ptp locked in 10s`, `sinks applied,
delay 103`, both sinks 103, `STAGE running` 23:34:57 on the sd103
arguments. Start lines (`reads/bar-day0b-20260907T233537Z.txt`): RX
PRIMED 171 / 192 / trimmed 21 (the accepted line), TX PRIMED
`ring_at_prime=274 overshoot=31 align_dropped=14 first_tick_wait_us=473
front_age_frames=296 under_prime=0`, ALIGN trigger `target=prime
slack_us=341`; 2 PRIMED, 0 RECOVER, 0 ZERORUN; PTP locked, jitter 6.
Lead pair 23:35:35 UTC (since stream start): **1045 / 1050 us**, sd103's
frame deadline intact through the flapping (the Ferrofish flow did not
re-draw its phase). Day-0 read on this process at 0.01 h: TX floor 127,
RX 72, gaps 1096 / 1116 us. The Phase 6 count runs from this process
(ActiveEnter 23:34:11 UTC) if the link holds; the earlier day-0 read of
the 23:21:58 process (floors 132 / 72, the both-PCM XRUN pair at +17.5
s) stands as a session in the record. RTL at 32 by the user is the next
read; a 719-class figure (about 18.9 ms) is expected on this anchor.
*Watch:* `carrier_down_count` above 12 means the cable or port is still
marginal; the 100 Mbps negotiation at 23:32:00 is the cable-quality sign.

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
    acceptance soak with all sixteen channels loaded. Done 2026-09-04 22:04
    UTC for `servo-aligned-both-240-rx120-sd144` at gadget `req_number=4`
    (see "SOAKED 21:54-22:04 UTC"), and earlier that day for rx120 at
    sink delay 96, which the 41-sample holes then retired; any new
    operating point needs its own.
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

**STAGED 2026-09-08 22:10 UTC, supervisor and conf, not installed: the AoIP
link watched every second of the run, and a settle restart of the bridge
alone.** Two findings of the day drove it (day-1 read, commits f070732 and
dbb1935, notes in `outputs/latency/phase6-gapbar-20260907/reads/day1-notes-20260908.md`):
the day-0b process died at 06:43 EDT on a 32-flap `eth0` storm that the
supervisor read as four host absences (the open item from the relocation
day); its successor ran 10 h on a 100 Mbit link (the fallback at 06:51:57
EDT, after the start gate had passed during a 1 Gbps window) and died at
17:03 EDT with no link or PTP event (cause open); the restart then sat at
the start gate on `speed=100` until the cable was reseated. The process
started after the cable swap (17:34:56 EDT, sd103, PTP lock in 10 s, sink 0
added only after four minutes, lead 988-1119 once settled) took two RX
underruns at +4.5 s and +7.9 s and a drained open/close pair at +79 s (TX
gap 7671 us, queue to 39, `tx_qlow` 1): its floors are contaminated from
minute two and the Phase 6 count cannot start on it.

The change: `work/aes67-bridge/usb16x16-aes67-supervisor` `427982dc` (from
`631e88e1`), `aes67.conf` `4d423b2b` (from `556cc2b6`), installer pins
updated, unit unchanged.

1. `link_ok` (carrier 1 and speed 1000, the start gate's own test) runs on
   every tick of the supervise loop before any RECOVER is read, and on every
   probe of the host-absent wait. A miss is `fail 38`: the stack stops,
   systemd restarts the unit after 10 s, the start gate waits for the link.
   A link storm can no longer be read as a host absence, and a fall to 100
   Mbit is a restart within a second, not a 10 h session and a stuck gate.
   The three-in-five-minutes backoff applies as to any failure.
2. Settle: a RECOVER inside `BRIDGE_SETTLE_SECONDS` (90) of a bridge start
   restarts the bridge alone, at most `BRIDGE_SETTLE_RESTARTS` (2) times per
   bridge start, never while a storm is pending. The daemon, module and
   sinks stay, so the sink dead time is not paid twice. The floors start
   clean for the Phase 6 count. The level is re-drawn as by any gadget PCM
   restart, which the RECOVER had already done. 0 seconds disables it. A
   harness run that starts inside the first 90 s of a bridge start can now
   see a bridge restart instead of a counted RECOVER: start measurements
   after the "stable for 120s" stage line, as the wrappers already wait.

Tested: `bash -n` on the Mac; `load_conf` on the Pi's bash 5 with the new
keys (parsed, a non-integer refused, 0 accepted, the profile validates,
`link_ok` true on the live link), no RECOVER during the test. The loop
branches themselves are untested until installed. The installed conf
(`306cfa85`) is operator-edited (sd103 selected by `switch-profile`), so the
installer keeps it and writes the shipped conf as `aes67.conf.new`; the
profile cannot flip, and the two keys take the supervisor's defaults until
copied in. Install needs his sudo and a stack restart; acceptance is a
fresh anchor and a day-0 read showing either no RECOVER in the first two
minutes or one settle restart followed by none. Rollback: reinstall
`631e88e1` with the installer at commit dbb1935.

**READ 2026-09-09 00:16 UTC: stamp phase 41 on both Ferrofish streams after
the cable swap and the supervisor install; sd103 stays at its floor.** The
user's `/tmp/phase-20260909T001643Z.pcap` (4 s, 9.8 MB, the gate's tcpdump
line), first 1.5 MB read with `stamp-phase.py` (evidence
`stamp-phase-20260909T0016Z-postswap.txt`): sink 0 `239.69.121.9` and sink
1 `239.69.193.115` wire phase 9 on every packet, the Pi's `239.69.16.1` and
`.2` wire phase 16, grid phase **41 on both**, stamps stepping 48, no
sequence gap on any stream, RECOVER count 0 before and after. The wire
phases are the 2026-09-06 values again (Pi 16, Ferrofish 9) rather than
yesterday's 32 and 25: the driver's SAC high word restarted with today's
reboots, which moves every wire phase alike and the grid phase not at all,
as the arithmetic says. Lead pair on the same process 1079/1080. The
standing rule (lead pair, then phase, after any Ferrofish, switch or cable
change) is satisfied for the new cable; an RTL figure may be quoted against
sd103 on this anchor.

**MEASURED 2026-09-09 ~00:20 UTC, RTL Utility at 32 frames on the new cable
and the installed supervisor: 18.438 ms = 697 + 188, 22 under sd103's
accepted 719 / 18.896 ms.** Read by the user on the process of 22:11:14 UTC
(supervisor 427982dc, sd103, lead 1079/1080, phase 41 re-read at 00:16).
The process before and after: zero RECOVERs, no re-prime (the two start
PRIMED lines only), no ZERORUN event (the bridge saw no zero run in any
stage during the read), floors TX 84 / RX 72, tx_qlow 0, so the RTL open
and close did not re-draw the level and the Phase 6 count stands. Anchor
caveat: the gadget's anchor is the 17:30 EDT cold boot (21:30 UTC); the
AES67 service was restarted twice since (17:38 for a clean process, 18:10
for the install), so this is a plain-restart draw against that anchor, not
the fresh-anchor procedure that read 719. Plain restarts have read 757-849
before; 697 is the lowest figure in the record for any draw. Whether the
user ran the noise probe before the read is not recorded here; the figure
is a session draw, a data point for the "level follows the bridge start
depth" rule (this start: TX prime overshoot 35, align_dropped 10,
first_tick_wait 394 us; the 719 start: overshoot 37, align_dropped 8,
first_tick_wait 341 us), not a new accepted level. A repeat on a fresh
anchor is the way to make it one.

**READ 2026-09-09 11:00 UTC: noise probe clean, so both overnight RTL draws
stand; Phase 6 day 1 on the 22:11 UTC process, floors TX 83 / RX 66, one
open/close pair at +7.65 h, uncontaminated.** (1) The user read RTL Utility
at 32 a second time about 00:30 UTC: **17.875 ms = 670 + 188**, 27 under
the 18.438 of an hour earlier on the same process; the record's rule reads
two figures in one session as Mac holes, so the probe was run first thing:
`day0d-noise-ch2-64f-100imp.*` in `usb-holes-20260904/` (gate settings,
RTL Utility quit, Pro Tools open but not holding the device): 0.0 % zeros,
no run in 1,244,628 returned samples, discontinuities 0, `placementMisses`
0, RECOVER count unchanged across it. The Mac is clean, so the two figures
are two draws, not holes; the second was itself re-drawn at 05:50 UTC
(below) and neither is a fresh-anchor figure. (2) Day 1 read
(`bar-day1-20260909T110047Z.txt`, 12.83 h): TX floor 83, RX 66, `tx_qlow`
/ `rx_qlow` 0, gaps 1137 / 1179 us, largest pull TX 48, RX 96 (gap 1039
us); TX trail unchanged since +2.3 m (93 -> the 83 floor drawn later
without a 24-step). Two RECOVERs at +7.65 h (05:50:28 UTC): both PCMs
`capture-avail` Broken pipe in the same 68 us, queues 142 and 161, no
drain; a device open/close variant (both directions on capture-avail,
where the record's signature names capture-avail with playback-avail;
`gap-bar.py` counts it as no pair but finds no drain either), the floors
stand, the count continues, the level re-drawn. No link event, speed
1000, no settle restart (the pair was hours past the 90 s window). Lead
pair on that interval 817 / 829 (it spans the re-prime; the next read is
the clean one). Priced: 83 leaves 35 over one period, 168 possible on this
draw. Day count: day 1 of three on this process.

CORRECTION 2026-09-10 03:10: this entry's claim that "no accepted point in
this record has been drawn twice" is **withdrawn**. Six draws were taken on
2026-09-06 (`draw1`..`draw6-roundtrip-64f-20260906*`, levels 793, 801, 773,
797, 790, 803) and analysed with the impulse trace in the "pi_total" table
above, which already established with better instrumentation than tonight's
that **nothing logged at the prime tracks the level** — naming
`ring_at_prime`, `overshoot` and `align_dropped` specifically — and that the
moving term is the USB side, not the Pi path. I proposed and ran tonight's
campaign without searching for that work first. The rest of this entry
stands: the acceptance gate is still four runs on one anchor, and the
sd103-over-sd132 comparison is still one draw each.

**FOUND 2026-09-10 00:40 UTC: the acceptance gate measures run-to-run
stability, not draw-to-draw reproducibility, so the sd103-over-sd132
comparison rests on one draw each and is not established.** Raised by the
user asking why a re-draw matters if the draw is random. It matters
operationally — the draw is fixed once taken, so selecting a good one buys
real persistent latency — but the same fact undermines how the levels have
been compared.

(1) Today's draw, for the record. Fresh anchor at 00:30:41 UTC (coreaudiod
killed on the Mac after the session depth went deep; the supervisor's
host-absent detector stopped the bridge at 48 recoveries in one second and
restarted it, a new bridge session and a new Phase 6 count). Harness 64
frames / 800 impulses: **722**, min 722, max 722, spread 0, score 1.000,
`levels=722x800`, 0 discontinuities, 0 RECOVERs during the run. RTL
Utility at 32: **18.958 ms = 910 = 722 + 188 to the sample**. Noise probes
first, clean at both sizes (`anchor20260910-noise-ch2-{32,64}f-100imp.*`
in `usb-holes-20260904/`): 0.0 % zeros, no run >= 4, matching
`accept-noise-ch2-64f`. So 722 is neither a Mac hole nor instrument
variance. Evidence `anchor20260910-roundtrip-64f-20260910T004003Z.json`.

(2) The gate. The sd103 acceptance set is "4 x 800 loaded and the 600 s
soak all 719". All five reads were on one anchor, where the level cannot
vary: today's run confirms the mechanism, 800 impulses at spread 0 on one
anchor. Four runs agreeing is therefore evidence of run-to-run stability
and says nothing about whether a second anchor on the same profile would
read 719 again. No accepted point in this record has been drawn twice.

(3) The spread on a fixed profile. Draws on sd103, unchanged conf, bridge
and module: **670**, **697** (both on the 2026-09-08 22:11 process, the
second re-drawn from the first by the +7.65 h open/close pair; the record
classes both as plain-restart, not fresh-anchor), **719** (fresh, the
accepted figure) and **722** (fresh, today). 52 samples end to end, and
n = 2 for fresh-anchor draws. Note also that 697 and 670 sit *below* both
fresh-anchor figures, against the record's own "plain restarts have read
757-849" expectation, which remains unexplained.

(4) Why that matters for sd103 over sd132. The point of record moved on
719 against sd132's 747 — 28 samples, each a single draw on its own
anchor, read as "sink delay's cost is a whole-frame step". The observed
draw spread on sd103 alone is at least 52 samples. The claimed effect is
smaller than the noise measured on one profile, so two single draws cannot
separate the lever from the draw. This does not retract 719 or 747: both
were measured cleanly. It says the *comparison* between them is
undersampled.

(5) The explanatory model does not close the gap either. The record
attributes the draw to the bridge start depth one for one. Across the
three draws whose prime figures are recorded, `overshoot + align_dropped`
is conserved at 45 — 719: overshoot 37, align_dropped 8; 697: 35, 10;
722: 30, 15 — while the levels span 52 samples. Equal effective start
depth, different levels. Whatever sets the draw is not captured by that
sum.

(6) What would settle it: N fresh-anchor draws per profile, comparing
distributions rather than single figures, with the noise probe before each
read. Cost per draw is about 60 s of audio plus a Phase 6 count restart,
which is why it has not been done. Until it is, re-drawing to obtain a
lower figure and recording it as the profile's latency reports an order
statistic as a system property, and should not be done. sd103 at 719
stands as the accepted operating point; 722 is filed as a draw.


**MEASURED 2026-09-10 00:30-03:02 UTC: six fresh-anchor draws on sd103 span
716-725, nine samples; a prime-based model was proposed, predicted, and
falsified on the first out-of-sample test; and four coreaudiod kills in
forty-five minutes wedged the stack, recovered by a gadget restart.**

(1) The draws. All on the live sd103 profile, conf, bridge and module
unchanged, harness 64 frames / 800 impulses, noise probe before each read
except where noted. Levels with the TX prime figures that go with them:

| draw | level | overshoot | align_dropped | first_tick_wait |
| --- | --- | --- | --- | --- |
| 09-07 accepted | 719 | 37 | 8 | 341 |
| 00:30:41 | 722 | 30 | 15 | 488 |
| 01:33:56 | 720 | 28 | 17 | 522 |
| 01:48:57 | 720 | 28 | 17 | 538 |
| 02:05:58 | 725 | 33 | 12 | 419 |
| 02:59:58 | 716 | 36 | 9 | 358 |

Every draw read spread 0 across its 800 impulses with score 1.000, and
`overshoot + align_dropped` is 45 in all six. Evidence:
`{anchor,draw1,draw2b,draw3,predict}20260910-roundtrip-64f-*.json` and the
matching `*-noise-ch2-64f-100imp.*` in `usb-holes-20260904/`.

(2) The spread is **9 samples, about 190 us**, mean near 720. That is much
tighter than the 757-828 the six 2026-09-06 draws spanned on the
transmit-slot-fix module, but the two are not comparable: different module,
profile and era. What it does bound is the current configuration, and 9
samples is roughly a third of the 28 that separated sd103 from sd132.

(3) A model was proposed and falsified. Four draws (720/28, 720/28, 722/30,
725/33) fit `level = overshoot + 692` exactly, which looked like the
"level follows the bridge start depth" rule finally parameterised
correctly. It predicted 728 for the 02:59 session's overshoot of 36. The
session **measured 716**, off by 12. The fit rested on three distinct
overshoot values with one duplicated point flattering the count. This is
the second time this hypothesis has been rejected: the 2026-09-06 trace
analysis had already named `overshoot` and `align_dropped` as not tracking
the level, from a decomposition of the path rather than a fit to six
points. The prediction was recorded before the measurement, which is the
only reason the failure is unambiguous.

(4) The procedure has a cost that was not in the record. A fresh anchor by
`killall coreaudiod` storms the bridge: about 335 recoveries in the storm,
the supervisor's host-absent detector stopping it, and a 60 s wait before
retry. Most attempts did not re-enumerate on the first try. The
host-absent episode counter ran 4, 10, 18, 26, 29 across the campaign, and
after the fourth kill the Mac's USB audio engine wedged: `udc` reported
`configured`/`high-speed` while `tx_input_frames` stayed 0 through repeated
60 s retries, and the harness hung waiting for input, so holding the device
open from the Mac did not clear it. **Audio was down about fifteen
minutes.** Recovery was `sudo systemctl restart usb-16x16.service`, after
which the stack came back clean: 0 recoveries, 0 restarts, 0 drops, 0
clipped, `tx_input` flowing. The 716 draw is on that post-restart session,
which the record also counts as a fresh anchor, and it is the lowest figure
of the night.

**How to apply:** a fresh-anchor draw is not the cheap operation the earlier
notes imply. Budget a storm, a possible 60 s dead wait, and a real chance of
needing a gadget restart. Do not run several in succession, and do not
script them. Take the daily gap-bar read first, as was done here: the read
`bar-day1b-20260910T002741Z.txt` is the only reason the 26.3 h session was
not lost.

Nothing is accepted or retracted by this entry. sd103 at 719 stands. The 716
and 725 are draws, not new operating points.
**PREPARED 2026-09-11: fixed-preset DSP service package and corrected validation,
not installed or accepted.** `work/dsp-service/README.md` is the current DSP
procedure; the older pickup's full loaded-preset impulse battery is superseded.
The bundle `outputs/dsp-service/review-20260911/` contains the existing candidate
bridge 406699bd, direct rollback 05f37bd9, pinned loaded/transparent presets,
experimental profiles copied from the live selected sd103 block, and an installer
that verifies the live baseline and applies/restores the files with AES67 stopped.
It does not alter the USB gadget, unit, sudoers, module or daemon.

Read-only Pi snapshot in this session: service active; installed bridge 05f37bd9,
supervisor 427982dc, config 306cfa85; zero direction restarts, TX/RX floors 83/72.
The latter two files were copied as the exact rollback. The older pickup's
631e88e1 supervisor is stale. No hardware audio test, service stop, install,
profile change or root operation was performed in this preparation session.

Local verification: 9 Python integration/integrity/failure tests and 7 Swift
harness tests pass; release harness builds; shell syntax and bundle integrity
checks pass. The new continuous command drives all 16 outputs through one device
open and reports bounded activity/silence/clipping/timestamp statistics. Hardware
validation is still pending. `validate.py` requires an explicit execute flag,
physically returned input list and short preflight before longer tests; it has no
readiness retries or remote polling during a measurement. UI Apply remains disabled.

Evidence correction: separate-start 1042/1061 results do not prove zero added DSP
latency. Loaded filtering invalidates the original impulse correlation method;
its re-probe/recovery explanation is still to be confirmed by continuous testing.
Use direct/transparent for impulse latency and manual RTL, loaded for continuous
stability. Within-session repeats do not measure startup-to-startup variation.
The next checkpoint is review of the prepared package, playback off, controlled
installation and three short preflights. Do not begin another latency-tuning or
repeated-anchor campaign.


**INSTALLED / SHORT PREFLIGHTS PASSED 2026-09-11 UTC: DSP bridge under the
service, direct/transparent/loaded, full acceptance still pending.**
The reviewed bundle was installed after user confirmed playback off and refreshed
sudo authentication. Installed bridge 406699bd, supervisor cdc0768d; pinned DSP
presets under /etc/usb16x16/dsp. Unit, sudoers, daemon, module and USB gadget unchanged.
Baseline rollback bundle remains intact (05f37bd9 / 427982dc / 306cfa85).

Three separate 60-second continuous, single-open CoreAudio service preflights
passed: direct TX/RX floors 89/72, transparent 86/72, loaded 88/72. All had zero
recoveries, direction restarts, drops, clips, low-queue events and input/output
timestamp discontinuities. Required return inputs were 1/2; all 16 outputs were
driven, and all 16 returns additionally showed clean activity on post-run review.
Both DSP starts engaged after their successful aligned prime (TX front age 296,
under_prime 0, target=prime). Transparent DSP mean/max 43.408/116.554 us per call;
loaded 308-biquad DSP 58.588/200.445 us. Packet-lead minima by sink: direct
1000/1004 us, transparent 1016/1029, loaded 1034/1042. These are short stability
results, not latency, routing, frequency-response or long-soak acceptance.

The loaded single-open run supports, but does not prove, the prior explanation
that readiness-probe retries caused its recoveries. No impulse/RTL measurement
was taken. Full acceptance battery, manual RTL on transparent/direct, and UI Apply
remain pending. Do not initiate another latency-tuning/repeated-anchor campaign.

Final state: returned to dsp-direct; verified active/running, candidate bridge and
supervisor hashes match, no DSP loaded, zero recoveries. This is DSP disabled on
the newly installed binary, not a binary rollback. Playback may resume. A future
battery needs a fresh preflight receipt on its selected arm/process.

Evidence: outputs/dsp-service/PREFLIGHT_RESULTS.md, preflight-results-20260911.json,
the three *-preflight-coreaudio-20260911 directories, and final-state.json. The
initial direct-preflight-installed-20260911 attempt is VOID: the sandbox exposed
zero CoreAudio devices and no audio opened. Outside-sandbox inspection confirmed
native 48 kHz 16x16 with labels 1–16, and all valid captures used that access.
Installation initially refused before file changes because the process guard
matched an audio-binary path in the parent SSH command; an isolated deployment
command succeeded without changing the guard or the reviewed bundle.


**DSP ACCEPTANCE BATTERY COMPLETED 2026-09-11: overall FAILED, no retry.**
Authoritative report: outputs/dsp-service/acceptance-20260911/RESULTS.md.
All 16 returns were required. Direct and transparent passed 60 s preflight,
4 x 800 impulses (725 and 766 samples, zero spread), and 600 s soak. User RTL at
32 frames: 19.021 and 19.875 ms. Separate starts prevent causal attribution;
trace includes a 48-sample AES67 index step. Do not claim latency neutrality.
Transparent's much later after-RTL snapshot had lower floors and larger gaps
without recovery; preserve its separate operating-interval classification.
Loaded preflight passed; soak failed because input 4 longestZeroRun=7 (limit <4).
All other inputs longestZeroRun=1; no nonfinite/fullscale samples, invalid buffers,
timestamp discontinuities or bridge recovery/drop/clip/low-queue counters.
Loaded TX floor decreased 87 to 82, RX stayed 72. DSP mean/max50.548/134.738 us.
Aggregate statistics cannot locate or explain the seven-zero event. Next is
bounded offline channel-4 signal/filter/conversion analysis, followed only if
needed by a targeted evidence-preserving capture. No full-battery retry, gate
relaxation, transport tuning or UI Apply. Profiles remain experimental.
Candidate binary and immutable rollback bundle are unchanged. Service restoration
to dsp-direct is recorded in campaign final-state.json; this is not binary rollback.

Final state: dsp-direct restored and verified active/running, matching candidate
bridge/supervisor/config, no DSP loaded or calls, zero recoveries and error
counters. See final-state.json. Playback may resume. This is DSP disabled on the
candidate binary, not a baseline binary rollback.

**OFFLINE DSP DIAGNOSIS 2026-09-11: loaded zero-run pattern reproduced by
filtering and L24 quantization.** Read
outputs/dsp-service/offline-loaded-20260911/RESULTS.md. A new local replay links
the unchanged DSP core, uses the pinned loaded artifact and the continuous
harness's deterministic noise. Both Float32 and S24-rounded input models produce
channel 4 longestZeroRun=7 and every other channel=1 over 600 s. DSP float output
has no exact zeros; the RAVENNA high-three-byte S32-to-L24 conversion creates the
run at source frame 3304775 (68.849479 s). Sample neighborhoods, statistics and
source hashes are retained. Swift stimulus bit checks, independent byte-copy
checks and existing bridge core tests passed.

This establishes a quantization mechanism sufficient to fail the existing gate,
not the identity of the original live event. The battery remains FAILED;
production DSP, gate, profiles and UI Apply are unchanged. No live access or
restart occurred. Next: bounded continuous-harness event capture with sample
times and all-channel neighborhoods, synthetic quantization/loss verification,
then one targeted loaded capture with preflight and playback coordination. Any
new criterion must be declared prospectively; do not loosen the old gate or
repeat the full battery. Latency and queue-reserve questions remain separate.

**EVENT CAPTURE IMPLEMENTED 2026-09-11: signed harness built; hardware run pending.**
Continuous reports now retain up to 32 zero-run events, each with all 16 return
channels, input frame/sample times, paired output callback stimulus indices and
sample times, and exact sample bits. Four zeros trigger recording; the old
failure gate remains unchanged. Windows target 16 preceding/following frames and
cap at 96 total, with explicit capacity, incomplete-window and omitted-event
indicators. Capture buffers are preallocated; reports are built after audio stops.
Known timestamp/buffer discontinuities split event tracking. Invalid timestamp
flags now fail validation; nonfinite samples preserve their bits in JSON and end
exact-zero runs rather than joining zeros across the invalid value.

Eleven Swift and eleven Python tests passed. The release app was rebuilt and
its ad-hoc signature verified; build-app.sh hit the nested SwiftPM sandbox
restriction, so the same build used --disable-sandbox and the existing app was
copied/signed/verified directly. No service or audio device was opened.
Build/source hashes: outputs/dsp-service/event-capture-20260911/build-verification.json.
Next is playback coordination, a fresh loaded 60-second process-bound preflight,
then one 90-second validate.py --phase capture run, preserving its old-gate
failure and neighborhoods, followed by verified restoration to dsp-direct.

**LIVE EVENT CAPTURE COMPLETED 2026-09-11: quantization signature confirmed.**
Read outputs/dsp-service/event-capture-20260911/RESULTS.md. User confirmed playback
stopped and RTL closed. One loaded service start, fresh all-16-input 60-second
preflight (passed), then one 90-second capture. Input 4 had seven zeros; every
other input longest run=1. The complete 39-frame channel-4 event neighborhood
matches all predicted nearest L24 codes, with raw maximum difference
0.000068665 LSB. The other 15 returns remain nonzero across the window. No event
omissions/truncation, timestamp gaps, invalid timestamps/buffers, nonfinite or
full-scale samples. Recovery/restart/drop/clip/low-queue/pitch-error counters
stayed zero; TX/RX floors stayed 86/96. This identifies the captured event as
the expected filter/L24 quantization trajectory, not interruption evidence.

The unchanged gate still fails; do not retrospectively pass acceptance. The
989-frame source/input index alignment is not a loaded impulse latency result.
All-channel raw reference difference reaches 1.5625 LSB, so no all-channel
bit-exactness claim. Reference source/output, analysis and comparison hashes
are retained with the capture. No retries, resets or transport tuning occurred.
Direct mode was restored and verified active/stable, matching candidate hashes,
with no DSP or error counters; final-state.json and run-status.json record it.
Playback may resume. Next is prospective reference-aware loaded-signal validation,
with existing transport checks and reserve review retained. UI Apply remains
disabled and a full battery rerun is not the next step.

**REFERENCE EVENT CHECKER IMPLEMENTED LOCALLY: prospective activity criterion.**
Read work/dsp-service/REFERENCE_VALIDATION.md. reference_check.py and the bounded
reference-export.cpp replay the pinned core/preset through S24 input and S32/L24
output conversion. Alignment uses independent pre-event channel samples within
a fixed 9600-frame bound; exactly one offset must explain every channel/event.
All retained samples must meet a fixed 2-LSB bound; triggering zero runs must
match exact predicted L24 zeros and nonzero boundaries. No gain/time fitting.
Incomplete, omitted, ambiguous, malformed or unaligned evidence cannot clear
the gate. The two-LSB model limit is diagnostic, not a universal error proof.

The saved live event matched its regenerated full search interval (39 frames,
offset 989, maximum all-channel difference 1.5625 LSB). Inserted silence and
missing/repeated frames in that saved window were rejected; 26 tests also cover
randomized fixtures, strict zero matching, channel/gain changes, cross-window
offset changes, metadata failures, pins and the prospective validator path.
Evidence: outputs/dsp-service/reference-check-20260911/verified/result.json and
the parent directory's fault/final verification records. No new hardware work.

validate.py defaults to legacy. Explicit --signal-criterion reference-events-v1
is loaded-only and requires all 16 returns. It clears only explained zero-run
objections; all activity/transport integrity checks remain. New preflight
receipts bind criterion/checker/exporter/validator hashes as well as the existing
bundle/harness/process identity. Legacy receipts are not reusable for this mode.
Historical failure results remain untouched. New reports explicitly state
window coverage and wholeRunValidated=false: samples outside retained windows
are not compared, so this is not general missing/repeated-sample proof.
Next: one coordinated fresh loaded preflight and 600-second soak under the new
criterion, queue-reserve review, then verified direct restoration. UI Apply and
overall acceptance remain pending; no full battery or transport tuning campaign.

**PROSPECTIVE LOADED ACTIVITY RUN COMPLETED 2026-09-11: preflight and soak PASS;
reserve stability and latency remain open.** Read
outputs/dsp-service/reference-v1-live-20260911/RESULTS.md and review.json.
One fresh loaded start, 60-second preflight then 600-second soak, using frozen
criterion loaded-event-reference-v1 (2e6592b9). All three channel-4 events
(7, 4, 5 zeros) matched exact predicted L24 zero codes and boundaries; all 16
channels' 112 retained frames were within 1.5625 LSB of reference. One common
1,011-frame source/input offset is alignment evidence, not loaded impulse latency.
No omitted/truncated windows, timestamp/invalid-sample errors, recovery, direction
restart, drop, clip, low-queue or pitch errors. No threshold tuning or retries.

TX floor fell 86 to 81; RX stayed 72. First/last 60-row TX queue means were
176.533/159.583 frames, with the drop late in the run. DSP mean/max at soak end
50.512/138.461 us, packet lead minima 977/989 us. The signal gate passes, but
this is not a clean queue-reserve stability result. Historical acceptance stays
failed under its original rule; separate direct/transparent latency findings
remain unresolved. Unsaved samples were not compared (wholeRunValidated=false).

All 26 Python and 11 Swift tests passed. Direct mode restored and verified
active/stable with candidate hashes, zero error counters and no DSP calls;
CoreAudio still native 48 kHz 16x16 labels 1–16, UDC configured/high-speed.
Playback may resume. No binary rollback occurred. Next: inspect saved queue
history and bridge timing code for the late reserve change before proposing
further live work. UI Apply stays disabled; profiles remain experimental.

**FOUND 2026-09-11 19:32 UTC: the "late reserve change" in the reference-v1 soak is
the tick phase of the once-per-second sample, not lost reserve; the same
phase reading explains when every TX floor step lands.** Evidence:
outputs/dsp-service/reference-v1-live-20260911/queue-phase.py and its output
queue-phase.txt, run over that soak and the three acceptance-20260911 soaks.
No live work; the Pi was read once, read-only (service active, NRestarts 0,
dsp-direct, supervisor cdc0768d, bridge pinned 406699bd).

(1) What tx_queue on the BRIDGE line is. The audio loop stores one
snd_pcm_delay of the RAVENNA playback device every 480 output frames
(main.cpp, the `have_playback_delays` block near line 2627), and the
telemetry thread prints whatever value was last stored, once a second, at
its own cadence. The TIC pulls 48 frames every millisecond and the bridge
refills 48 on every USB wake, so within each millisecond the queue is a
48-frame sawtooth, and a single sample of it reads either side of a pull
depending on where the bridge's wake sits against the tick. The line's
phase_us is exactly that: grid_phase_ns of the RAVENNA-driven wake against
the USB-driven wake, modulo the 1 ms USB frame tick (main.cpp line 2734,
bridge_core.hpp line 264). It walks at the servo's ppm (about 14 us per
second here) and is re-based every 18-20 s by the servo's +37-frame
correction row.

(2) The dips are the phase, in every arm. Rows reading more than 30 frames
under their block's median, and how many of those had phase_us within
100 us of the wrap: reference-v1 loaded soak 46 of 56; acceptance direct
239 of 244; acceptance transparent 316 of 317; acceptance loaded 49 of 49.
On the other rows phase_us stayed 98-942 in the reference-v1 soak. The
direct soak had these dips from its third minute on (its phase visited the
wrap in every block); the two loaded soaks and the reference-v1 soak had
them only late, because their phase kept away from the wrap until then.
The "first/last 60-row TX means 176.5 / 159.6" in the campaign's
queue-review.json are therefore the sampled sawtooth changing which side of
the pull it reads, not depth leaving the queue. The per-observation window
means the same line carries moved by about 5 frames over the run (tx_qmean
141.4 -> 135.6/137.8, tx_dmean 203.7 -> 199.3/201.3), and they are phase-
sampled too, only more finely. The reserve figures that are not phase-
sampled stayed put: tx_pullmax 48, tx_gapmax_us 994, tx_qlow 0, rx floor 72,
no RECOVER, direction restart or drop.

(3) The floor step 86 -> 81 is the same phase. tx_qfloor is the running
minimum over every queue observation (main.cpp line 1619), so it is drawn
only when an observation lands just after a pull, with the sawtooth at its
bottom and a long wake gap behind it. Its DEPTHSTEP at +719.45 s (pull 48,
gap 864 us) sits on the row whose phase_us read 37 with the wrap on the
next row; the acceptance direct soak's steps landed on phase 58, 61, 84,
55, 57, the loaded soak's on 30 and 93, the transparent soak's on 976, 0,
976. Across the age50/rxtrim lineage the recorded floors are 76-88 and
their trails show the last step at +2.9 m, +3.1 m, +3.5 m, +6.2 m
(outputs/latency/phase6-gapbar-20260907/historical-sessions.txt): a step
at +12 m is that draw, later. 81 leaves 33 over one period; gap-bar.py
prices the reference-v1 soak at "the prime could drop 24 to 168 on this
draw", the same as the record's candidate. Nothing about the DSP stage is
in this: the direct arm, with no preset loaded, shows the strongest form
of it.

(4) Consequence for the campaign's open items. The reserve-stability
question the RESULTS.md left open is closed by analysis; no live
experiment is needed for it. First/last-window means of tx_queue should
not be used as a reserve metric again; the floors, the pull and gap
maxima, tx_qlow and the RECOVER count are the reserve evidence, as Phase 6
already uses them. A future bridge could store the delay at a fixed point
in the wake (after the commit) so the sample stops straddling the pull;
that is a telemetry change and not a lever, and it is not proposed now.

(5) The direct/transparent 725 versus 766, read against the record. The
whole difference is in the AES67 index segment: pos_aes67 544 -> 592
(+48, one TIC frame), pos_pi 510 -> 561, usb_time 44.2 -> 45.3 (the same),
tx_depth at the write 133 -> 183. In the transparent start the TX queue
was already one period deeper at its first DEPTHSTEP (queue 229 at
t_us 3922) than in the direct start (178 at 3966), and that row precedes
"DSP engaged" at t_us 4562, the stage's first filtered render; the prime
renders unfiltered by construction (renders_after_prime). Direct's 725 is
inside the six fresh-anchor draws on the same profile without DSP
(716-725, MEASURED 2026-09-10); 766 is that plus one period, the size of
step the record has on this profile between plain restarts (670, 697,
719, 722). So the 41 is a start draw of the TX queue depth, the kind the
record already documents, and nothing in the stage's audio path can have
placed it there. That is consistent with latency neutrality; it is still
n = 1 per arm, so the statement stays "no added depth was observed and
the observed difference is accounted for", not "proven equal". No
re-draw campaign is proposed; the record's rule against re-drawing for a
figure stands.

**ACCEPTED 2026-09-11 19:47 UTC: the DSP bridge 406699bd with the dsp-direct /
dsp-transparent / dsp-loaded profiles is the point of record, under the
reference-events-v1 criterion; the service runs dsp-direct.** The user's
decision, taken on the evidence of the two 2026-09-11 campaigns and the
FOUND entry above, with the original zero-run gate left FAILED on the loaded
arm by policy (work/dsp-service/REFERENCE_VALIDATION.md). What is accepted:

- Bridge 406699bd: the accepted 05f37bd9 source plus the DspStage, wired
  behind --dsp-preset on usb-to-ravenna only; the aligned prime renders
  unfiltered. Supervisor cdc0768d (the repo supervisor with the bridge pin
  moved; byte-identical to the installed file). Presets loaded.dsp 2b6baa04
  and transparent.dsp ad695984 under /etc/usb16x16/dsp/. Installed on
  2026-09-11 by the review-20260911 bundle's deploy.py; the rollback is
  deploy.py rollback to 05f37bd9 / 427982dc / 306cfa85 from the same
  bundle, never the legacy installers for this set.
- The figures: dsp-direct 725 at 64 on its anchor, RTL at 32 19.021 ms =
  725 + 188, 4 x 800 spread 0, 600 s all-16 soak, floors 84 / 96;
  dsp-transparent 766 / 19.875 ms = 766 + 188, the same battery, floors
  133 / 72, dsp max 161.6 us, the +48 over direct a TX queue start draw
  (FOUND above); dsp-loaded 60 s preflight and 600 s all-16 soak under
  reference-events-v1, three channel-4 zero events all the pinned filter /
  L24 quantization, floors 81 / 72, dsp mean / max 50.5 / 138.5 us, lead
  977 / 989 us, zero RECOVERs in every arm. Direct's 725 sits inside the
  six no-DSP fresh-anchor draws on sd103 (716-725), so the transport point
  of record is unchanged in substance; sd103 at 719 remains its figure.
- Default profile dsp-direct: identical audio to sd103, a preset is
  applied on purpose (a profile switch is a service restart, a new draw).
  dsp-loaded has no impulse latency figure by construction; latency is read
  through dsp-transparent.

Repo brought to the accepted set in this entry: work/aes67-bridge/aes67.conf
(PROFILE=dsp-direct, the three blocks with their MEASURED / COVER / STATUS
and a 2026-09-11 comment; hash 9af00275), the supervisor pin (cdc0768d),
install-aes67-service.sh pins (supervisor, conf, bridge),
install-candidate.sh pin, artifacts/pi-aarch64/ now 406699bd, the README
status paragraphs of phase4-bridge, DSP_MODE_DESIGN.md and dsp-service. The
repo conf was validated by the supervisor's parser on the Pi
(USB16X16_AES67_CONF=~/usb-16x16-work/aes67-dsp-accept.conf ... profiles).
The live conf stays c9be6585: it carries the same three blocks without the
comment and without the repo's BRIDGE_SETTLE_* lines (the supervisor
defaults them), and deploy.py rollback's baseline check wants it unchanged.
Nothing else on the Pi was touched. Next: UI Apply (step 5) as a staged
stop / switch-profile / start / verify / rollback operation on this set.

**STAGED 2026-09-11 20:30 UTC, not installed: UI Apply (step 5), a switch between
accepted profiles from the Settings page, as two halves with a file between
them.** The user's three decisions, taken after the ACCEPTED entry above: the
privilege comes from a root systemd path unit on a spool file (the web service
keeps NoNewPrivileges and gains one ReadWritePaths entry, no sudo, no socket);
the first version switches between accepted profiles only (dsp-direct /
dsp-transparent / dsp-loaded, everything already on the Pi and pinned), it
installs no preset and edits no block; and a failed verification rolls back to
the previous profile automatically.

What was written (work/web-control unless noted):
- usb16x16-apply (Python, root): reads web-apply/request.json, refuses a
  profile whose block is not STATUS=accepted, a stale page (the browser names
  the profile it believes is live), a request older than 120 s or already
  receipted; then systemctl stop, the supervisor's own switch-profile,
  systemctl start; waits up to 150 s for STAGE running, up to 15 s more for
  the first BRIDGE line, checks it is fresh with zero direction restarts,
  the RECOVER count is zero, and the bridge log has the DSP loaded / DSP
  engaged lines the profile calls for (or none); holds 30 s; on any failure
  returns to the previous profile through the same steps. Every step lands
  in web-apply/current.json, the outcome in web-apply/receipts/<id>.json
  with the bridge's start lines (NEGOTIATED / ALIGN / PRIMED / DSP) so the
  draw can be read afterwards. --check validates without acting.
- usb16x16-apply.service (oneshot, TimeoutStartSec 480) and
  usb16x16-apply.path (PathChanged on the request file). The path unit is
  the switch: disabled, the UI reports Apply as not installed.
- usb16x16-web 1.2.0: POST /api/apply/profile writes the request file
  atomically after the same checks against its cached snapshot (400 / 409 /
  503 with the reason), GET /api/apply/status reads current.json; the
  health snapshot gains profile.selected, profile.profiles[] (status,
  description, measured, cover, preset, from the world-readable conf) and
  control.apply (available = the path unit active). Nothing else changed:
  no device is opened, no command runs on a request.
- usb16x16-web.service: ReadWritePaths gains the spool. install-web-control.sh
  installs the five files, creates the spool (bdimaio) and receipts/ (root),
  pins all five hashes.
- work/web-ui: a "Service profile" panel on the Settings page (live profile
  with its status and measured string, a select of the other accepted
  profiles, Apply with a confirm that says audio stops for about a minute
  and the level is re-drawn, the operation's steps as they land, the
  receipt line); backend.mjs carries the client and the pure formatters.
  Draft and applied state stay distinct: the editor's preset never reaches
  the Pi, only a profile name does.

Verified on the Mac: 20 Python tests (the applier's state machine against a
scripted stack: happy path, seven refusals, start failure, RECOVER in the
settle window, wrong or missing DSP lines, switch refusal, double failure,
late first BRIDGE line, no BRIDGE line; the request writer and state reader)
and 85 web-ui tests; the service run locally with a fake systemctl and conf
answered 202 / 409 / 409 / 400 as designed, the real applier driven against
a file model of the stack produced a done receipt (and, before the grace
wait existed, the failure it should have: the first BRIDGE line follows
STAGE running by a second), and the panel rendered both. Not yet run on
the Pi. README sections in work/web-control and work/web-ui updated.

Install (root, the user's): stage work/web-control/* and work/web-ui/* file
by file into ~/usb-16x16-work/web-control/ and web-ui/, then
sudo ~/usb-16x16-work/web-control/install-web-control.sh,
sudo systemctl restart usb16x16-web.service,
sudo systemctl enable --now usb16x16-apply.path. The first Apply on the Pi
is the acceptance test of this step: playback off, dsp-direct ->
dsp-transparent -> dsp-direct from the browser, each receipt read, the
supervisor's journal clean, zero RECOVERs after each start. Rollback is in
the README (disable the path unit; or remove the five files).

**DONE 2026-09-11 20:42 UTC: UI Apply installed, armed, and its first round trip on
the Pi passed; the acceptance labels copied into the live conf.** The user
ran install-web-control.sh, restarted usb16x16-web and enabled
usb16x16-apply.path (~20:34 UTC), playback off. Evidence:
outputs/dsp-service/apply-roundtrip-20260911/ (the three receipts and the
journal window).

(1) The first request (e7ef3cb1, dsp-direct -> dsp-transparent) was REFUSED
in 0 s, nothing touched: the live conf still labelled the three DSP blocks
STATUS=experimental, because the ACCEPTED entry moved the labels in the repo
conf only. That is the applier doing exactly its job, and the omission was
the record's own post-acceptance step. Fixed the record's way: a labels-only
copy, work/aes67-bridge/dsp-accept-labels/copy-dsp-labels.py (the form of
copy-sd103-labels.py: DESCRIPTION / STATUS / COVER / MEASURED of the three
blocks from the shipped repo conf, atomic replace, no other line), dry run
12 lines, applied by the user with sudo. The live conf is now 976a6080 (was
c9be6585); the bundle's deploy.py rollback compares the conf byte for byte
apart from PROFILE= and will refuse from here, so the baseline conf goes
back by hand from outputs/dsp-service/review-20260911/baseline/ if ever
needed (bridge and supervisor rollback are unaffected).

(2) The round trip, driven from this session by writing the request file
into the spool as bdimaio (the web service's exact write; the Basic-auth
UI path is the user's to exercise): 3c9300fc dsp-direct -> dsp-transparent,
validating 20:38:15, stop 6 s, switch-profile, start, STAGE running at
20:39:08 (47 s), 30 s settle, done 20:39:38; the receipt's start lines show
DSP loaded transparent.dsp 256 biquads, ALIGN ok, TX PRIMED front_age 296
under_prime 0 overshoot 31 dropped 14, DSP engaged at t_us 4546. Then
7efd287f dsp-transparent -> dsp-direct, the same shape, STAGE running at
20:41:17 (48 s), done 20:41:47, no DSP lines, overshoot 28 dropped 17
(overshoot + dropped 45 on both starts, as the record has it). Zero
RECOVERs and zero direction restarts after each start, the supervisor's
journal has no recover / fail / error line in the window, the applier's
journal one line per operation. The service is back on dsp-direct, running,
a fresh draw (a profile switch is a restart; the level was not measured
and is not claimed).

Step 5's first cut is therefore in service: profile switches between the
accepted set from the Settings page, verified and receipted, with rollback
built in and untested on real hardware because nothing failed (its path is
covered by the Mac tests). Still the user's: one Apply from the browser
itself, which also exercises the 202 / poll / receipt display. Next on the
DSP side, if wanted: a browser-compiled preset reaching the bridge, which
needs artifact validation on the Pi first; metering; AoIP -> DSP -> AoIP.

**DONE 2026-09-11 20:49 UTC: the user's own Apply from the browser (Basic
auth, the Settings panel) completed: b2cfc5bf, dsp-direct -> dsp-loaded,
requestedBy bryan, STAGE running 47 s after start, 30 s settle, done at
20:48:43, zero RECOVERs; the Immersive stereo-subs preset loaded (308
biquads) and engaged at t_us 4471, TX PRIMED front_age 296 overshoot 31
dropped 14, dsp_us mean 62.7 / max 201.5 on the first minute. The service
runs dsp-loaded from here, filtering, until the next Apply; its level is a
fresh draw and unmeasured (the loaded preset cannot be read by the impulse
harness). Receipt in outputs/dsp-service/apply-roundtrip-20260911/. Step 5's
first cut is complete on all three paths: ssh-driven, browser-driven, and the
refusal.**

**STAGED 2026-09-11 21:35 UTC, not installed: browser-compiled presets reaching the
bridge, as the second Apply request kind.** The user's three decisions:
guards instead of a soak (a user preset is STATUS=user, never accepted; the
applier writes its block itself with dsp-direct's transport fields copied
verbatim, loads the artifact through the bridge's own loader, requires every
biquad section stable and the total at or under 308, the count the loaded
soak passed); the compile happens in the browser with the verified compiler
(work/dsp-compiler's pure ES modules, served beside the UI as
web-ui/compiler/, symlinks in the repo); one slot per preset name, eight at
most, a re-apply of the same name replaces its block and file.

What was written:
- work/aes67-bridge/usb16x16-aes67-supervisor (f3f099b9): validate_dsp_profile
  accepts /etc/usb16x16/dsp/user-<slug>.dsp beside transparent and loaded;
  the ownership, hash and bridge-pin checks are unchanged. One regex, the
  install-aes67-service.sh pin moved. NOT installed: the running supervisor
  is still cdc0768d, and a user block would fail its validation until this
  is installed (service stopped, the user's sudo).
- work/web-control/usb16x16-apply 1.1.0: request kinds profile / preset /
  remove. For a preset: hash recomputed; parse_artifact walks the artifact
  exactly as DspStage::load does with its bounds (channels 16, internal <=
  64, sections <= 64 per chain, delay <= 480, rows bounded) and adds
  stability (|a2| < 1, |a1| < 1 + a2), a gain bound and the 308 cap; slug
  rules (1-24 [a-z0-9-], no dash-prefix of another user slug: the
  supervisor addresses fields as PROFILE_<KEY>_<FIELD>, so user-a's
  TX_PLAYBACK_PRIME would read as user-a-tx's PLAYBACK_PRIME); the cap;
  then usb16x16-dsp-offline ARTIFACT --bench 1 (the runner from the dsp-verify
  build of the accepted source, hash 8469c2e8, installed by the package to
  /usr/local/libexec, refused-if-absent); the file installed root:644 by
  rename; the block rendered from the live dsp-direct lines re-keyed
  PROFILE_USER_<KEY>_ plus DESCRIPTION / STATUS=user / COVER / MEASURED /
  DSP_PRESET / DSP_SHA256 and a marker comment; the whole file validated by
  the supervisor's own `profiles` on a temporary copy; replaced atomically;
  then the existing stop / switch-profile / start / verify / rollback. A
  profile request may target a user block only while its installed file
  still hashes to the block's pin. Remove refuses the live profile,
  otherwise strips the block, validates, replaces, deletes the file.
- usb16x16-web 1.3.0: POST /api/apply/preset (name, artifact text,
  optional hash, expectedProfile; the artifact lands in web-apply/presets/
  beside the request), DELETE /api/apply/preset/<slug>; health rows carry a
  user flag; the DSP note updated. The installer creates the presets spool,
  /etc/usb16x16/dsp, and installs the offline runner with its pin.
- work/web-ui: backend.mjs compileDraft (dynamic import of ./compiler/),
  presetSummary (the confirm: sections, bands, crossovers, headroom, delay,
  the compiler's warnings, the not-soaked notice), requestPreset,
  removePreset, userPresets; the Service profile panel gains "This draft on
  the Pi" (Compile & apply this draft, DSP mode only) and the list of user
  presets with Remove; the profile select offers user blocks too.

Verified on the Mac: 33 Python tests (parser on the shipped transparent
artifact and on broken copies: wrong channel count, missing end, an
unstable section, the cap; install and switch, bad hash, missing file,
loader refusal leaving nothing installed, replace rewrites one block,
slug conflict, the cap of eight, remove while live refused then done,
tampered file refuses a profile switch) and 30 + 55 node tests
(compileDraft on the shipped layout, the request shapes, the lists; the
compiler's own suite still passes through the symlinks). End to end
locally: the service answered 202 for the node-compiled shipped layout,
the real applier against the fake stack installed user-immersive-stereo-subs
(46 biquads, 23 internal channels), wrote the block, validated, switched,
verified, done; DELETE answered 409 while live and 202 after; remove ran;
the panel rendered the live user preset, the draft block and the list. On
the Pi, read-only: the offline runner loads transparent.dsp with --bench 1
in 125 us and exits 0. Nothing installed.

Install (the user's, in this order): stop usb16x16-aes67, install the
supervisor from ~/usb-16x16-work/aes67-user-presets-install/, start; then
sudo ~/usb-16x16-work/web-control/install-web-control.sh and restart
usb16x16-web (the path unit stays enabled; the applier binary is replaced
in place). First live test: with playback off, Settings -> Compile & apply
this draft on the shipped layout, the receipt read (stats, loaderLine,
start lines: DSP loaded user-…dsp), then Apply profile back to dsp-direct,
then Remove.

**CORRECTION 2026-09-11 21:47 UTC to the STAGED entry above: a user block is
STATUS=experimental, not STATUS=user.** Installed by the user (supervisor
f3f099b9 with the service stopped, then the web-control package, ~21:40
UTC), the first live draft apply (c55762df, the shipped layout, 46 biquads,
23 internal channels) passed every guard on the Pi: hash, parser, the
offline runner's load (14.7 us per 48-frame block), the file installed, the
block written, the supervisor's parser validating the file; then the
supervisor's switch-profile refused it: "STATUS must be accepted or
experimental" (supervisor line 409, a check the applier's `profiles` pass
does not exercise). The applier rolled back to dsp-direct cleanly (STAGE
running after 47 s, 30 s settle, zero RECOVERs). Fixed by writing
STATUS=experimental, the supervisor's own word for a profile it will switch
to without an acceptance; the user identity is the user-<slug> name (the
applier's user_profile_ok and the service's user flag both key on it). The
stale STATUS=user block left in the live conf is replaced by the next apply
of the same name. Not a supervisor change. Also fixed since the STAGED
entry: the service serves /web-ui/<file> from its static root so the
compiler's ../web-ui imports resolve in the browser (the first attempt
failed to fetch model.mjs). Second live attempt pending.

**DONE 2026-09-11 22:11 UTC: browser-compiled presets reach the bridge; the full
cycle passed on the Pi from the user's browser.** Evidence:
outputs/dsp-service/user-preset-20260911/ (four receipts). All by bryan,
playback off, after the corrected package (usb16x16-web b3adaf1f,
usb16x16-apply c7f2a162, supervisor f3f099b9) was installed at ~22:00 UTC:
- c55762df 21:45 (the first attempt, before the correction): every guard
  passed, switch-profile refused STATUS=user, rolled back clean.
- cbc7a994 22:05:26 -> 22:06:51 preset: the shipped layout compiled in the
  browser, 46 biquads / 23 internal channels, loader 14.7 us per block,
  installed replacing the stale block, supervisor-validated, switched;
  STAGE running after 48 s, 30 s settle, zero RECOVERs; start lines show
  DSP loaded user-immersive-stereo-subs.dsp and DSP engaged at t_us 4466;
  dsp_us mean 13.9 / max 80.4 on the first minute.
- c8728c33 22:09:04 -> 22:10:27 profile: back to dsp-direct, done, zero
  RECOVERs.
- eeba6cc9 22:10:33 -> 22:10:35 remove: block stripped, conf validated and
  replaced, file deleted, no restart. /etc/usb16x16/dsp holds the two
  packaged presets again; the conf has no PROFILE_USER_ line.
The service runs dsp-direct. Installed set now: bridge 406699bd, supervisor
f3f099b9 (user-<slug>.dsp paths; install-aes67-service.sh pin moved),
usb16x16-web 1.3.0, usb16x16-apply 1.1.0, usb16x16-dsp-offline 8469c2e8 in
/usr/local/libexec, path unit armed. The Settings layout was tidied twice
during the day (live panels only refreshed on a poll, overview back to one
column, receipt steps collapsible). A user preset is STATUS=experimental,
never accepted; its level is a draw and unmeasured, as every profile switch
is. Open on the DSP side: metering (the benchmarked tap), AoIP -> DSP ->
AoIP; on the UI side, showing which user preset is live inside the editor
(the draft and the applied state are still only related by name).

**STAGED 2026-09-11 22:45 UTC, not built and not installed: the level meter tap,
the DSP roadmap's metering item, as a benchmarked tap in the bridge published
through a preallocated snapshot, never a second ALSA stream.** The three
halves, all in the repo and staged on the Pi under
~/usb-16x16-work/meters-20260911/ (phase4-src, aes67, web-control, web-ui;
staged hashes checked against the repo's); nothing live was touched.

(1) The bridge. `LevelMeter` in bridge_core (hpp 9d1fb083, cpp df7ccee0):
one pass over a block already in hand, sixteen lanes of peak, float square
sum and full-scale count (the same test exceeds_full_scale makes, so the
per-channel clip counts add up to tx_clip / rx_clip), folded into a window
that closes on the first block boundary at or past 2400 frames (50 ms) and
carries its own frame count; the closed window is published through a
seqlock (odd while the writer copies, even otherwise, the reader keeps a
copy only when the word was even and unchanged across it, eight tries then
"no snapshot"); clip counts are cumulative since start so a reader slower
than a window loses no overload, peaks are per window. main.cpp (031138b4):
`--meter-file PATH`, off by default, in which case no block is read and the
audio path is the accepted one; on, both directions tap their capture block
after the ring push and their playback block after the write loop (after the
DSP stage on TX, so the output meters read the wire), the prime render
excluded like it is unfiltered (renders_after_prime now counts in direct
mode too, behaviour-free: it is only read by the stage); each observe is
timed with the two clock reads the stage uses, reported as `meter_us_max`
and `meter_us_mean` on the BRIDGE line (after dsp_calls) and in SUMMARY
(`meter_us_max`, `meter_us_mean`, `meter_calls`); a publisher thread,
demoted to SCHED_OTHER (a std::thread inherits FIFO 90), polls the four taps
every 25 ms and rewrites PATH by rename when any window moved: a `METERS
v=1 t_us= window_frames= writes=` line and one `TAP stage= seq= frames=
position= peak_dbfs= rms_dbfs= clip=` line per stage, dB to one decimal,
silence floored at -144. `usb16x16-meter-bench` (src/meter_bench.cpp
3aaff8a8, CMakeLists 8b023e0c; core only, not installed) times observe() in
memory. Mac figures (Apple silicon, hot cache): 48 frames 0.21 us median /
0.33 p99, 96 0.42 / 0.63, 192 0.83 / 1.17, 512 2.25 / 7.1; the maxima
(24-54 us) are macOS preemption. Two taps per direction per cycle, so on
the Pi expect a few microseconds against the stage's 68 us median at 48
frames; the Pi figure is the one to record, at the build.

(2) The supervisor (70af8abb) and conf (b01588df). Global key `METERS`
(0/1, absent 1) passes `--meter-file /run/usb16x16/meters`; the file is
removed at run start, at bridge start and in cleanup; `status` shows
meter_us_max. The conf documents the key with its default. Validated: the
staged supervisor's `profiles` over the staged conf on the Pi (read-only)
lists the seven blocks unchanged. install-aes67-service.sh pins moved for
the supervisor and the conf; the bridge pin (406699bd) and install-candidate.sh
stay until the build. The live conf keeps its labels-copy divergence.

(3) usb16x16-web 1.4.0 (172b7032; install-web-control.sh pin moved) and
the UI. `GET /api/meters`: the file parsed once per version (mtime cache),
fresh on every request, `available:false` with the reason when the file is
missing (bridge stopped or METERS=0), unparseable, or older than 1 s; the
health fast tier carries `meters` (available, endpoint, stages, windowMs)
and the bridge block gains `meterUsMax` and `dspUsMax`. The page
(app.mjs 630b9fdf, backend.mjs 904a8a23, style.css 39b3f54b): while
health says a tap exists and the Outputs tab is visible it reads
/api/meters at up to 10 Hz, one request in flight, draws the window's peak
in dBFS on the input bank (usb-capture: the host's USB output, before the
stage) and the output bank (ravenna-playback: the wire, after it), holds a
clip mark 1.5 s when a channel's cumulative count moves, and says "live"
in the summary, the toggle and the connection line; absent or stale for
1.5 s it returns to the synthetic activity, labelled as such. Mutes and
roles do not shape live values.

Verified on the Mac: bridge core tests 30 (four new: a window's peak / RMS
/ clip arithmetic including that +1.0 clips and -1.0 does not, window
closing on block boundaries and a 512-frame straddle, cumulative clips, and
a writer thread against a reader with no torn snapshot in thousands of
reads); main.cpp syntax-checked clean (clang -std=c++20 -Wall -Wextra
-Wpedantic -Werror, the Pi's ALSA headers from
~/usb-16x16-work/deps/libasound2-dev, the endian / clock_nanosleep /
TIMER_ABSTIME / ESTRPIPE shims); 94 web-ui node tests (four new); test_web
13 (four new: the parser on the four-stage text, refusals, missing / fresh
/ stale / garbage file, the health fast tier) and test_apply unchanged;
supervisor bash -n. Not run anywhere: the bridge with the tap (no ALSA on
the Mac; no builds on the Pi while the service runs).

RECOVER pair 22:23:51 UTC, recorded against this session: both directions
capture-avail XRUN at t_us 838.6 s of the 22:09:52 process (the user's
Apply back to dsp-direct), re-primed and aligned at once, zero since. It
coincided with a read-only `find /usr -name asoundlib.h` over ssh from
this session, looking for the ALSA headers (they are not under
/usr/include; the deb is unpacked under deps/). The same class as the
record's transfer stalls: a filesystem walk on the Pi counts as a load
during a run and joins the rule. The file-by-file staging at 22:33 added
none (the count read 2 before and after). The service runs dsp-direct,
its level a fresh draw, unmeasured, as it was since the Apply.

Next, the user's, in order: stop usb16x16-aes67; build in
~/usb-16x16-work/meters-20260911/phase4-src with the README's cmake recipe
(ALSA include from deps/libasound2-dev), run usb16x16_bridge_tests and
usb16x16-meter-bench at 48 / 96 / 192 / 512 and record the Pi figures;
record the bridge hash, move the three bridge pins (install-candidate.sh,
install-aes67-service.sh, the supervisor) and copy the binary into
artifacts/pi-aarch64/; install the bridge, then the supervisor and conf
(install-aes67-service.sh), start; install-web-control.sh, restart
usb16x16-web, copy the three web-ui files into ~/usb-16x16-work/web-ui/.
Acceptance for a bridge change stands: on dsp-direct with METERS=1, the
journal's `METERS enabled` line, meter_us_max on the BRIDGE line, `cat
/run/usb16x16/meters`, /api/meters from the browser and the Outputs page
live; then four loaded 800-impulse runs and a ten-minute sixteen-channel
soak on a fresh anchor against 725 / 19.021 ms and floors 84 / 96, zero
RECOVERs, meter_us_max recorded; METERS=0 is the same binary untapped, the
control if the figure moves. Rollback: METERS=0 in the conf and a restart
(untapped), or the previous binary 406699bd through the pinned installers.

**BUILT 2026-09-11 23:05 UTC, not yet installed: the meter-tap bridge 3503a48c.**
Built by the user on the Pi with the service stopped, in
~/usb-16x16-work/meters-20260911/phase4-src (Release, ALSA headers from
deps/libasound2-dev). Core tests pass on the Pi. usb16x16-meter-bench,
200,000 runs each, median / p99 / max in us: 48 frames 1.815 / 1.852 /
23.6; 96 3.574 / 3.612 / 24.6; 192 7.093 / 7.13 / 28.4; 512 18.888 /
27.87 / 1156.9. So 1.8 us per 48-frame block, two taps per direction per
millisecond cycle: about 3.6 us of the 1000, 0.36 % duty, against the
stage's 67.8 us median. The 512-frame maximum is one preemption of the
unpinned SCHED_OTHER bench process, not the tap; the bridge's own
meter_us_max under SCHED_FIFO is the figure to read. Pins moved to
3503a48c in install-candidate.sh (0a310415), install-aes67-service.sh
(9d82830e, supervisor pin 645ea54e) and the supervisor (645ea54e, both
places); artifacts/pi-aarch64/ is now 3503a48c, the previous 406699bd
remains in git history and installed until step 3. The three re-pinned
files re-staged under meters-20260911/, hashes checked.

**FOUND 2026-09-11 23:20 UTC: the first meter-tap build (3503a48c) took a RECOVER
pair in both captures at every start; not installed further, fixed in
main.cpp fb68c0ee, rebuild pending.** Installed by the user at 22:50 UTC
(bridge 3503a48c, supervisor 645ea54e, conf b01588df), the service started
on dsp-direct and each of three bridge starts (22:51:25, :31, :38; the
supervisor's two settle restarts) read `capture-avail code=-32` in both
directions within the first tick after NEGOTIATED, ring 0, before any
prime; the third bridge then ran with tx/rx restarts 1/1, floors 98 / 24.
The tap itself worked: `METERS enabled`, the file rewritten every window
(139 / 142 / 799 writes, 0 failures), meter_us_max 6.074 us and mean
1.699 us on the audio thread, the four TAP lines at -144 with playback
off. The user stopped the service at 23:10 UTC.

Reading: the only thing the build adds at that instant is a second
std::thread created after the captures are running, under
mlockall(MCL_FUTURE), which populates and locks the thread's 8 MB default
stack at creation: a few milliseconds of the main thread's time inside a
4 ms capture buffer. The telemetry thread has always been created there
too and fits alone; two do not. Fix (fb68c0ee, syntax-checked, staged):
the publisher is created before either capture starts and before memory
is locked, as a pthread with a 256 KB stack; the elapsed_us() stamp is
ordered after process_started by the seqlock on the first published
window. The telemetry thread is left where it is (one variable). The
reading is tested by the rebuild: a clean start with zero RECOVERs on
dsp-direct is the pass. The 3503a48c pins are moot: the rebuilt hash
replaces them before any further install.

**INSTALLED 2026-09-11 23:16 UTC: meter-tap bridge 947e8b4d, supervisor 23e40f8c,
conf b01588df; the service runs dsp-direct with the tap on; clean start.**
The rebuild with the publisher created before capture start (main.cpp
fb68c0ee) started once: NEGOTIATED, `METERS enabled`, RX PRIMED (overshoot
21 trimmed 21, as always), TX PRIMED (overshoot 27, align_dropped 18), no
RECOVER, no settle restart; at +75 s tx/rx restarts 0/0, floors 123 / 72,
meter_us_max 24.333 us, meter_us_mean 1.700 us, the file at 932 writes
(seq 775 at t_us 38.8 s), all sixteen channels at -144 dBFS on every stage
with playback off. That confirms the FOUND reading: the RECOVER pairs were
the thread creation, not the tap. The 24 us maximum against a 1.7 us mean
is one call's wake jitter on the audio thread in the first minute, the
same shape the stage's 105 us max against 52 us mean had; read it over the
soak. Pins: install-candidate.sh ba753185, install-aes67-service.sh
6170cff4, supervisor 23e40f8c (bridge pin 947e8b4d, both places),
artifacts/pi-aarch64/ 947e8b4d. Web control 1.4.0 and the page not yet
installed; the acceptance battery not yet run. Rollback: METERS=0 in the
live conf and a restart (untapped), or 406699bd from git history through
the pinned installers of commit 47a6f42.

**DONE 2026-09-11 23:30 UTC: live meters in the browser; the metering item is in
service, pending the battery.** The user installed usb16x16-web 1.4.0
(install-web-control.sh, restart) and copied the three page files into
~/usb-16x16-work/web-ui/. From the browser: both banks move under
playback, the input bank on usb-capture (the host's USB output, before
the stage) and the output bank on ravenna-playback (the wire, after it),
peaks in dBFS under each strip, the summary, toggle and connection line
reading live. The full path is therefore in service: the tap on the audio
thread, the seqlock'd window, the publisher's file, /api/meters, the page
at 10 Hz. Not yet done: the standing battery for a bridge change on
dsp-direct (four loaded 800-impulse runs, the ten-minute sixteen-channel
soak, RTL at 32, fresh anchor, noise probe first) against 725 / 19.021 ms
and floors 84 / 96, with meter_us_max read over the soak; until it passes,
947e8b4d is INSTALLED, not ACCEPTED, and dsp-direct's MEASURED string in
the conf still describes 406699bd. Open on the DSP side after that:
AoIP -> DSP -> AoIP; on the UI side, the live user preset inside the
editor; and the meters' remaining wish, peak hold and RMS on the strips
(the data is already in /api/meters).

**MEASURED 2026-09-11 23:52 UTC: the meter-tap bridge 947e8b4d on dsp-direct,
METERS=1, fresh anchor: 703 at 64 (4 x 800, spread 0), floors 83 / 72, zero
RECOVERs through the whole battery; RTL at 32 pending.** The user restarted
usb-16x16.service at 23:26:33 UTC (the AES67 service restarted itself; stable
at 23:29); playback off, device idle. Battery driven from this session by
work/dsp-service/meter_battery.py (new: validate.py's snapshot() and issues()
without a bundle, since no review bundle carries this set; the same harness
commands and gates as accept.py; --execute opens audio; no retry). Evidence:
outputs/dsp-service/meters-accept-20260911/ (battery.log, per phase the
before/after snapshots, harness logs, audio JSON and summary.json).
- Preflight, 60 s continuous on all 16 returns at load 0.1: PASS, longest
  zero run 1 sample on every return (the noise probe: clean), leads 1031 /
  1038 us.
- Latency, 4 x 800 at 64 frames: 703 / 703 / 703 / 703 samples, every run
  min = max, peak 0.25; leads 980-1025 us across the runs.
- Soak, 600 s continuous on all 16: PASS, every return at peak 0.1, longest
  zero run 1; leads 1000 / 1010 us at the end.
- Counters at the end of the soak: restarts 0/0, dropped 0/0, clip 0/0,
  qlow 0/0, RECOVER 0; floors TX 83 / RX 72 from the first snapshot to the
  last, depth floors 137 / 123, pull max 48 / 85, gaps 1082 / 1129 us;
  meter_us_mean 1.36 us, meter_us_max 56.1 us (stepped 27 -> 56 once, during
  latency run 2; the mean is the tap, the max is the audio thread's wake
  jitter on one call, as the stage's 105 us max against a 52 us mean).
703 is 22 under the record's 725 for this profile on a fresh anchor and
inside the six no-DSP fresh-anchor draws' neighbourhood (716-725 before the
DSP bridge; 670-722 on plain restarts): a start draw, read as one, n = 1.
No claim that the tap moved the level either way. Expected RTL at 32:
703 + 188 = 891 samples = 18.563 ms.

**ACCEPTED 2026-09-11 23:55 UTC: the meter-tap bridge 947e8b4d with METERS=1 on
dsp-direct is the point of record; RTL at 32 18.563 ms = 703 + 188 to the
sample.** The user read RTL Utility at 32 frames right after the battery
(harness closed, device otherwise idle) and quit it. The set: bridge
947e8b4d, supervisor 23e40f8c, conf b01588df live (repo conf now carries
the new dsp-direct labels: COVER "TX floor 83 over one period, RX 72; zero
RECOVERs; meter tap 1.4 us mean", MEASURED "703 at 64 (4 x 800, spread 0),
RTL at 32 18.563 ms; 600 s soak; bridge 947e8b4d METERS=1 (was 725 /
19.021 on 406699bd)", and a dated comment; install-aes67-service.sh conf
pin moved), usb16x16-web 1.4.0 with /api/meters, the page live. The
dsp-transparent and dsp-loaded blocks keep their 406699bd figures; they
run on 947e8b4d unmeasured until someone re-measures them (a profile
switch is a restart and a draw in any case). Rollback: METERS=0 and a
restart (the same binary untapped); or 406699bd from commit 47a6f42's
installers. The live conf is one labels copy behind the repo (the
MEASURED / COVER lines and the comment); install-aes67-service.sh from a
re-staged copy, or copy-dsp-labels.py's form, brings it across without a
restart. The DSP roadmap's metering item is closed; open after it:
AoIP -> DSP -> AoIP, the live user preset inside the editor, peak hold and
RMS on the strips.

**DONE 2026-09-12 00:05 UTC: dsp-direct's labels copied into the live conf.**
copy-dsp-labels.py (now taking the shipped conf as its first argument) run by
the user with --apply: the two lines above changed, nothing else; live conf
37fc790f (the repo's 55e86fe5 differs only by the dated comment and the
METERS documentation block's position, which the copy does not carry). The
service was not restarted: active, zero RECOVERs, the same 23:29 process
the battery ran on. Nothing pending on the Pi.

**STAGED 2026-09-12 (design and step 2), not built and not installed: the
AoIP -> DSP -> AoIP loop mode.** `work/phase4-bridge/AOIP_LOOP_DESIGN.md`
is the design: one `--mode aoip-loop` direction inside the bridge, RAVENNA
capture -> DspStage -> RAVENNA playback, no gadget PCM opened, converters
at 1.0 with no estimator and no servo, the aligned start and the aligned TX
trigger and prime reusing the direction's own capture wakes as the grid;
the supervisor's four USB-host detectors decided per profile `MODE`
(default `usb-duplex`, every existing block unchanged): the start gate
waits on the link alone, a storm fails the run instead of waiting for a
dwc2 line, the host retry is never reached, settle and the RECOVER limit
stay. The rig's Ferrofish matrix returns the Pi's output to its own input,
so any pass-through preset would close a unity feedback loop through the
DSP: the measurement preset `loop-measure` (transparent, every output at
-40 dB) breaks it, and the bridge injects its own 0.25 full-scale impulse
after the stage (`--loop-impulse CH,SECONDS`, a candidate tool the
supervisor never passes) so the wire instrument can read AoIP in -> AoIP
out at the Pi's port without a host. The user's decisions: the -40 dB
preset (a real deployment would not route back), the stream-stop test
wanted, one binary with dsp-direct re-measured on it, the `tx_` keys
reused for the single direction (`rx_` reads an idle placeholder's zeros,
`mode=aoip-loop` first on every BRIDGE line), the service may stop for
builds. Written: `main.cpp` (`--mode`, `--loop-impulse`, the placeholder
`rx`, loop wiring, reporting; syntax-checked clean on the Mac by the
standing method, the accepted binary untouched), `verify-presets.mjs`
`loop-measure` with its shape pinned in the test (48 compiler tests pass),
compiled on the Mac to `outputs/dsp-service/aoip-loop-20260912/
loop-measure.dsp` `1e417960` (the same compile reproduces the pinned
`transparent.dsp` `ad69598` byte for byte), `work/aes67-candidate/
run-aoip-candidate-safe.sh` (no USB gate, dsp-direct's TX levers verbatim,
the injector, trace at threshold 0.002 / holdoff 96, `none` refused unless
`USB16X16_AOIP_LOOP_OPEN=1`, a bounded tcpdump of the two channel-1
streams to tmpfs moved into the result directory after the bridge exits;
bridge hash pin `FILL-AFTER-PI-BUILD`), `work/phase4-bridge/
build-aoip-candidate.sh` (refuses while the service is active, core tests,
four parser self-checks that open no device, prints the hash),
`analyze-aoip-loop.sh` (fetch after DONE), `rtp-impulses.py --loop`
(pairs each return with its re-emission, wall time and media-clock
samples, plus the bridge dwell from the IMPULSE `value=`; checked on a
synthetic capture). Nothing on the Pi. Next: stage and build with the
service stopped, pin the hash, the first candidate run, the stream-stop
test during a candidate, then the supervisor `MODE` and the `aoip-direct`
block (design steps 5-8); dsp-direct's battery on the new binary before
any acceptance.

**FOUND 2026-09-12 13:00-13:15 UTC (09:00-09:13 EDT): the Pi's Ethernet
controller stopped transmitting after a 2 s link drop, and the supervisor
cannot see that failure.** `macb 1f00100000.ethernet eth0: Link is Down`
09:00:47 EDT, `TX stall detected on queue 0 (tail=569398338
head=569398340); re-kicking TSTART` 09:00:49, `Link is Up - 1Gbps/Full`
09:00:51; the link watch failed the run (38) and the stack restarted,
settled with one bridge restart at +5 s, and reported running and stable
from 09:03:58. From then until 09:12 eth0's TX packet counter stood at
569,398,294 while RX advanced at stream rate: PTP locked (received Sync
alone), the sinks received the Ferrofish flows, the bridge ran with
`tx_restarts=0`, and nothing the Pi sent reached the wire -- no SAP, no
source RTP (the Mac's receive-only join of 239.69.16.1 counted 0 packets
in 4 s against 4001 from the Ferrofish's group), no ping reply on eth0.
Dante Controller lost the device; the user also lost wireless ssh for a
while, which was the access point (the Pi held 192.168.1.201 on the
5 GHz radio with the Mac in its neighbour table and no unicast reply
path; it cleared on its own and is unrelated to eth0). First `TX stall`
line in the retained journals, kernel 6.18.34+rpt-rpi-2712; the driver's
own re-kick did not recover the queue. Fix, run by the user: `sudo ip
link set eth0 down && sleep 2 && sudo ip link set eth0 up` at 09:12:00
EDT; the link watch failed the run, the stack restarted, TX at
2002 packets/s, the Ferrofish answers ping on eth0, the Mac hears SAP
(6 in 35 s) and the source stream (4001 in 4 s); running from 09:13:02,
floors TX 131 / RX 72, zero restarts. Consequence for the supervisor: a
TX stall is invisible to every detector it has (link up at 1000, RECOVERs
zero, USB input moving) and to the bridge's counters; the one cheap
signal on the Pi is `ip -s link show eth0`'s TX packet count not moving
across a second while the bridge runs, and on the Mac a receive-only
join of the Pi's source group. Not automated; noted for the supervisor
work the loop mode needs anyway (a per-tick TX-counter check beside
`link_ok` would catch it). The level is a new draw, unmeasured.

**MEASURED 2026-09-12 13:24-13:32 UTC: the AoIP -> DSP -> AoIP loop's
first candidate, 8.227 ms wall / about 419 samples on the media clock at
the Pi's port, the mode running as designed.** Bridge 0a39f4a6 (main.cpp
59cf978d, built by the user with the service stopped; zero warnings, core
tests and the four parser refusals verified), module bc694c24, preset
loop-measure 1e417960, dsp-direct's TX levers verbatim, sink delay 103,
360 s, injector on channel 1 every 2 s, trace at 0.002 / 96, a 30 s eth0
capture. `ALIGN status=ok`, prime and trigger as in duplex
(front_age_frames=296, align_dropped=39), DSP engaged after the prime, 179
impulses each stamped three times, dsp max 88.4 / mean 49.5 us, zero
clipped, zero dropped. The wire split (rtp-impulses.py --loop, saved as
wire-analysis.txt in the run): packet back -> capture frame 1.724 ms,
bridge dwell 1.596 ms (n=179, spread 13 us), playback write -> packet out
4.907 ms, total 8.227 ms (8.116-8.305, n=15); on the Pi's own stamps the
injected -> re-emitted round trip is 504 samples on every pair, about 419
after the 1.774 ms Ferrofish wire loop. The TX queue sat at 198 on every
BRIDGE line, floor 150 from the first line, depth 249 flat: the prime is
sized for USB jitter the loop does not have, so TX_PLAYBACK_PRIME is the
first lever (about 4.1 ms of the 8.2 is queue). One RECOVER at t=56.4 s
(capture XRUN, ring 51, gap 82 us), re-primed identically, clean for the
remaining 304 s; it coincided with my ssh read of the log from the Mac, the
known pattern, and the next run takes no reads. Not established: no soak,
n=15 on the wire, no meter tap in the wrapper, the stream-stop behaviour
(next run). Wart: the SUMMARY prints the loop's capture counters under the
usb_capture keys (the loop is tx); fix in the next build. Evidence
`outputs/latency/phase4-aoip-candidate-20260912T132437Z/` (the pcap
gitignored, the analysis text kept). Design note: MEASURED section
appended. Service restarted by the user at 13:32 UTC on dsp-direct, a new
draw. Session rules kept: no ssh reads during a run from here on.

**DONE 2026-09-12 22:13 UTC: the stream-stop candidate did not run; the
service was stopped 13:38-22:10 UTC and that, not a fault, is why the Pi
was invisible in Dante Controller.** The user stopped the service for the
test, was away, and found the Mac's ssh gone and the Pi absent from Dante
Controller; a ping from the Pi (Pi Connect shell) to the Mac restored ssh,
and `systemctl restart usb16x16-aes67.service` at 22:10 UTC brought the
announcements back (running from 22:11:26, stable). Read-only check
afterwards: one loop result directory only, no eth0 link event or TX
stall line since the morning's, eth0 transmitting at 2011 packets/s, the
stage file "stable for 120s". The wireless drop is the morning's pattern
(the Pi holds its address and the Mac in its neighbour table, the AP's
path back to the Mac goes stale; wlan0 power save is on) and a packet
from the Pi's side clears it; turning power save off on wlan0 is the
candidate fix, not applied. The stream-stop test is still the next run,
with the same three commands.

**MEASURED 2026-09-12 22:15-22:23 UTC: a second loop run, the stream-stop
test not performed (the deletes landed 100 s after the bridge had exited;
my timing instruction was relative to READY and the stack takes over a
minute to reach it).** `phase4-aoip-candidate-20260912T221521Z`, the same
set (bridge 0a39f4a6, loop-measure, 420 s): ALIGN ok first attempt, prime
and trigger as before (front_age 296), 209 impulses, zero clipped. Two
things the first run did not show, both known classes: a 3333 us gap with
a 144-frame pull at t=214 s (the RAVENNA playback's three-packet skip of
the duplex record) took the queue floor from 150 to 54 (198 - 144) with
no consequence; and dsp_us_max 978 us at t=76 s, a preemption of the
audio thread mid-call (cron.hourly ran at t=58 s; not proven). One
RECOVER at t=380 s, playback XRUN with ring 99 and last_gap 10 us (the
thread not scheduled for over the queue's 4 ms), re-primed identically;
nothing in the journal at that time, no ssh from the Mac during the run.
One RECOVER per loop run so far, in line with the DSP candidate history
(0-1 without the harness). Wireless: power save turned off on wlan0 by
the user (NetworkManager profile `netplan-wlan0-The Snack Goblins`,
powersave 2, and `iw` for the running interface). The stream-stop test is
now scripted, `work/aes67-candidate/aoip-stream-stop.sh` (e8059fb8), timed
by the wrapper's ready file, staged at ~/usb-16x16-work/aoip-loop/.

**FOUND 2026-09-12 22:33-22:41 UTC: with no stream arriving, the RAVENNA
capture keeps its clock and delivers silence; the loop bridge sees nothing,
needs nothing, and resumes on its own when the stream returns.** Run
`phase4-aoip-candidate-20260912T223248Z` (the same set, 420 s), the sink
deletes at 22:34:35.7 UTC (bridge t=65.0 s) and the re-adds at 22:35:05.8
(t=95.1 s) by `aoip-stream-stop.sh` on the wrapper's ready file. In the
30 s with both sinks gone: `tx_input` advanced at exactly 48,000 frames
per second on every BRIDGE line, the ring and the queue held 51 / 198, no
RECOVER, the injector kept firing (its impulses left and never came back:
no `ravenna-capture` return from t=64.5 to t=96.5 s, the only gap in 194),
and the capture zero-run counters stood still because the input was one
continuous run of zeros. At the re-add the daemon answered both PUTs in
40 ms (`media 0 sink addr` at 18:35:05.775 and .812 EDT) and the returns
resumed at t=96.5 s with no re-prime and the bridge dwell unchanged
(1.076 ms median by the block-to-block reading, before and after, n 19 /
162). Consequence for the supervisor's loop policy (design step 6): the
frozen-input test cannot fire on a lost source, because the driver's
capture runs on PTP and delivers zeros; a lost source is silence, not a
fault, and restarting anything would only add the sink dead time. The
loop path therefore takes no action on input; what is worth reporting is
the capture zero-run detector's long-run count (`zr_usbcap`'s fourth
field, mislabeled until the next build) or a silence flag derived from it,
so the UI can say "no signal at the input" while the stack stays up.
Separately: **one RECOVER per loop run, cause open.** Run 1 at t=56.4 s
(capture XRUN), run 2 at 380.0 (playback XRUN), run 3 a pair at 44.50 and
44.52 (capture then playback), each the audio thread not running for over
the 4 ms the queue and the capture buffer cover, each re-primed
identically. The tcpdump window is t=19.1-49.0 s in every run: run 3's
pair lies inside it, run 1's 7 s after, run 2's far outside, so the
capture is a suspect and not a cause; the run-1 ssh read is cleared as an
explanation, since run 3 had none. The journal at each event carries only
the bridge's own re-prepare lines. Next: a loop run with
`USB16X16_AOIP_CAPTURE_SECONDS=0` as the control for the capture, then the
TX prime lever; and the count stays in view before any acceptance. Wire
figure of this run, unchanged: 8.240 ms wall, 504 samples on the Pi's
stamps, about 420 on the loop.

**INSTALLED 2026-09-12 23:20 UTC: `usb16x16-wlan-keepalive.service`
(work/pi-tuning, 05e3b8c1), the wireless management keepalive.** After the
third loss of the Mac's ssh path in a day (the Pi holding 192.168.1.201,
the Mac in its neighbour table, the internet reachable, power save
already off on wlan0, the Mac's ARP for the Pi resolved and still no
reply), each cleared by one packet from the Pi's side, the unit pings
the Mac's two addresses (192.168.1.58 wired, 192.168.1.67 Wi-Fi) from
wlan0 every 20 s so the access point's forwarding state for the Pi never
goes stale. Management only, nothing on eth0 or the stack; installed by
the user with `install`, `daemon-reload`, `enable --now`; active. The
addresses are the Mac's of today and must follow it if the router moves
them. The AP itself (a locally administered BSSID one step off the
router's) is the real place to fix this.

**MEASURED 2026-09-12 23:32-23:40 UTC: the capture-off control, zero
RECOVERs in 420 s.** `phase4-aoip-candidate-20260912T233211Z`, the same
set with `USB16X16_AOIP_CAPTURE_SECONDS=0`: ALIGN ok, prime and trigger
as before (front_age 296), 209 impulses, zero clipped, zero dropped,
dsp max 204.3 / mean 49.5 us, the 144-frame skip once (gap 2995 us,
floor 150 -> 54, depth floor 201), `tx_restarts=0`. Against one RECOVER
in each of the three captured runs (t=56.4, 380.0, 44.5 s; window
19-49 s), consistent with the tcpdump capture as the cause and not proof
of it (n=1, and run 2's event lay outside its window). Standing
practice from here: lever runs without the capture, one captured run at
the chosen point at the end, and the capture moved late in the run so a
RECOVER it causes cannot contaminate the floors. The wrapper gained
`USB16X16_AOIP_TX_PRIME` (48..384, default 192; fda618cf staged).
