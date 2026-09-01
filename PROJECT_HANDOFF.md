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
measured and tuned from **74.146 ms to 32.792 ms**.

| Configuration | Round trip |
|---|---:|
| Forced `--period 96 --buffer 288`, sink delay 576 | 74.146 ms |
| Driver-default buffering, sink delay 576 | 44.292 ms |
| **Driver-default buffering, sink delay 48** | **32.792 ms** |

This lands inside the 20-35 ms band this document predicted for a tuned dual
`alsaloop` design. It is still above the 10-20 ms fallback and far above the
sub-10 ms research goal. Full tables and provenance are in
`outputs/latency/2026-08-31-latency-results.md`.

### Operational fact that dominates all testing

**Audio takes about 3 minutes 37 seconds to start flowing after the AES67
daemon restarts.** Measured directly with 77 timestamped impulse bursts: silent
through burst 31, first lock at burst 32, stable thereafter. The likely
mechanism is the Ferrofish re-resolving its subscriptions to the Pi transmit
flows once the daemon presents new session state.

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
| `work/latency-harness/watch-return-signal.sh` | fires repeated impulse bursts and reports lock or silence; the tool that found the 3.5 minute time-to-audio |

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
5. Read the `alsaloop` target-latency sweep outcome in the results file before
   choosing the next lever.
6. If target latency is not the gate, begin Phase 4: the single purpose-built
   real-time bridge. That is the credible route from 32.8 ms to 10-20 ms.
7. Budget about 4 minutes of dead time per daemon restart, and prefer live
   `PUT /api/sink/{0,1}` changes for anything that supports them.
8. Never gate a measurement on sink flags. Gate on a detected return signal.
9. Once an operating point is chosen, run the required ten-minute clean
   acceptance soak with all sixteen channels loaded; every figure recorded so
   far is reconnaissance, not an acceptance soak.
10. Then implement the persistent service plan, exposing latency mode and buffer
    parameters rather than baking in fixed values.
11. The host channel-name requirement remains untouched; macOS still reports
    UAC2 speaker positions rather than `1` through `16`.
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
