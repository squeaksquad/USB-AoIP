# Raspberry Pi 5 USB 16x16 / AES67 bridge handoff

**Authoritative state:** 2026-08-31

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

| Design | Expected digital round trip at a 64-sample DAW buffer |
|---|---:|
| Tuned dual `alsaloop` | approximately 20-35 ms |
| Single optimized real-time bridge | approximately 15-25 ms |
| PTP-disciplined USB plus optimized bridge | potentially 8-15 ms |

Sub-10 ms is plausible only near the best end of CoreAudio safety offsets, USB scheduling, AES67 receiver buffering, and Ferrofish behavior. A reliable 10-20 ms result remains a successful fallback.

## Next-session checklist

1. Power the Pi from PoE and connect the USB data cable.
2. Verify `usb-16x16.service` is active/enabled and UDC is `configured/high-speed`.
3. Confirm macOS sees 16 inputs and 16 outputs at 48 kHz.
4. Confirm the current channel labels and capture screenshots before changing descriptors.
5. Verify the current Pi address and SSH access.
6. Confirm the RAVENNA module and daemon are not already running unexpectedly.
7. Preserve copies/hashes of the current USB module and setup script.
8. Begin with the Mac CoreAudio/impulse measurement harness—not persistent service installation.
9. Establish USB-only and RAVENNA-only latency floors.
10. Tune current buffers one variable at a time.
11. Only then decide whether to prototype shared USB hardware-rate control or a PTP-aware kernel feedback servo.
12. After latency architecture selection, implement and validate the persistent service plan.
13. After the low-latency service is stable, implement DSP / Content mode as a separate optional profile and validate its bounded latency and synchronization.

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
