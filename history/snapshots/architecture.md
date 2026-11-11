# USB 16×16 DSP and AES67 architecture

## Recommendation

Use two independent CamillaDSP instances around a PTP-clocked AES67 ALSA endpoint. The open-source RAVENNA driver is the smallest current prototype endpoint; it is not yet the production timing choice because it does not use the Pi NIC's hardware timestamps.

```text
Mac USB outputs 1–16
        │
        ▼
UAC2 ALSA capture ── CamillaDSP TX + adaptive resampling ── RAVENNA ALSA playback
                                                               │
                                                               ▼
                                                    2 × 8-channel AES67 TX

                                                    2 × 8-channel AES67 RX
                                                               │
                                                               ▼
UAC2 ALSA playback ◀─ CamillaDSP RX + adaptive resampling ── RAVENNA ALSA capture
        │
        ▼
Mac USB inputs 1–16
```

This keeps USB and AES67 as independent clock domains. CamillaDSP absorbs their long-term drift instead of trying to force the USB host onto PTP or allowing buffers to walk into underrun/overrun.

## Why two CamillaDSP instances

CamillaDSP has one capture endpoint and one playback endpoint per process. The bridge contains two independent signal directions and each direction has a different playback clock:

| Instance | Capture clock | Playback clock | Rate-adjust result |
|---|---|---|---|
| TX | USB/Mac | PTP/RAVENNA | Resample USB input to the PTP media rate |
| RX | PTP/RAVENNA | USB/Mac | Resample received AES67 audio to the USB host rate |

Each instance should use `enable_rate_adjust: true` with `AsyncSinc`/`Balanced` once the RAVENNA PCM exists. The current direct USB identity loop uses no resampler because both endpoints are the same UAC2 card and clock.

## Incremental test ladder

### 1. Completed: direct CamillaDSP compatibility

- Direct ALSA access, no PipeWire/JACK/ALSA plug layer.
- 16 capture and 16 playback channels.
- 48 kHz, packed 24-bit.
- Explicit identity mixer.
- 60-second run passed without reported errors.

### 2. Next: channel identity and longer USB soak

- Play the supplied 16-channel channel-ID file from the Mac to USB outputs 1–16.
- Record USB inputs 1–16 on the Mac while the CamillaDSP identity loop runs.
- Analyze the recording: segment N must appear only on channel N with at least 40 dB separation from every other channel.
- Then run 30–60 minutes and inspect CamillaDSP logs, ALSA status, USB state, and kernel logs.

This validates the full 16×16 DSP layer before any AES67 component owns audio.

### 3. PTP-only validation

Prerequisite: wired Ethernet carrier and a visible PTPv2 grandmaster.

1. Install only `linuxptp`.
2. Run `ptp4l` manually in foreground on `eth0` using hardware timestamping.
3. Record port state, selected grandmaster, mean path delay, frequency correction, and offset statistics for at least 10 minutes.
4. Stop `ptp4l` after the test. Do not run it alongside the AES67 daemon because the daemon/driver has its own PTP slave.

Pass criterion: stable `SLAVE` state with no resets or large offset excursions under the intended switch topology.

This validates the NIC, switch, and grandmaster. It does not validate the RAVENNA driver timing path: current driver source does not use the PHC or hardware packet timestamps.

### 4. RAVENNA/AES67 loopback platform test

Use upstream AES67 daemon master commit `77c97c3` with RAVENNA driver v2.1 commit `e8579da` as the smallest interoperability prototype.

1. Build against the exact running kernel; this compile check already passes.
2. Install the driver as a separate, clearly named override without replacing `usb_f_uac2`.
3. Load it manually only; do not enable boot persistence yet.
4. Run the upstream loopback/platform test on `lo` before binding it to `eth0`.
5. Confirm the new `RAVENNA` ALSA card can independently play and capture 16 channels at 48 kHz.
6. Unload it and verify USB remains enumerated and configured.

This is a scoped additional module, not a USB kernel change. Installation and rollback must be documented before it is loaded.

### 5. One AES67 direction at a time

AES67's common interoperable mode is 1–8 channels per RTP stream. AIMS describes the typical interoperable setup as 48 samples/packet, 1–8 channels, 24-bit, 48 kHz. Therefore carry 16 channels as two eight-channel streams, not one proprietary 16-channel flow. See the [AIMS AES67 FAQ](https://aimsalliance.org/aes67-faq/index.html).

Initial stream profile:

| Property | TX/RX stream A | TX/RX stream B |
|---|---|---|
| Channel map | 1–8 | 9–16 |
| Codec | L24 | L24 |
| Sample rate | 48 kHz | 48 kHz |
| Samples/packet | 48 | 48 |
| Packet time | 1 ms | 1 ms |
| RTP payload type | Unique dynamic value | Different unique dynamic value |
| Destination | Unique administratively scoped multicast group | Different multicast group |
| RTP DSCP | AF41 / 34 | AF41 / 34 |
| PTP domain | Match facility grandmaster | Match facility grandmaster |
| PTP DSCP | EF / 46 | EF / 46 |
| Discovery | SDP plus SAP initially | SDP plus SAP initially |

The daemon supports L24, 48-sample packets, channel maps, SDP, SAP, multicast/unicast, DSCP, and PTP status. Its own [daemon documentation](https://github.com/bondagit/aes67-linux-daemon/blob/master/daemon/README.md) uses DSCP 46 for PTP and 34 for standard AES67 media.

Validate transmit before receive:

- PTP locked.
- Two SDP descriptions identify the same PTP grandmaster/domain.
- RTP sequence numbers are continuous.
- RTP timestamps advance by exactly 48 per packet.
- Each UDP payload is 8 channels × 48 samples × 3 bytes = 1,152 bytes, safely below a standard 1,500-byte Ethernet MTU.
- Receiver proves channel order and absence of cross-channel contamination.

Then reverse the test for receive. Do not combine directions until each runs independently.

### 6. Combined bridge

- Start RAVENNA/PTP and prove lock.
- Start CamillaDSP TX and RX as separate processes and ports.
- Enable rate adjustment on both.
- Observe CamillaDSP buffer level and resampling ratio; it should settle instead of walking toward a boundary.
- Run full-duplex channel-ID, latency, and multi-hour soak tests.

## Prototype versus production

| Area | Prototype | Production-ready direction |
|---|---|---|
| CamillaDSP | User-home binary, manual foreground run, 1,024-frame chunks | Version-pinned binary, two restricted system services, measured chunk/buffer tuning, watchdog and logs |
| GUI | None initially | Optional CamillaGUI on management/Wi-Fi only; audio continues if GUI fails |
| AES67 | Manual RAVENNA driver/daemon, SAP/SDP, one direction | Select an engine or hardware endpoint that explicitly consumes `eth0` hardware timestamps/PHC; then version-pin, add health checks, and complete interoperability testing |
| Clocking | Default CPU governor and limits | Apply only measured RT/CPU/IRQ tuning; adaptive resampling at each USB↔PTP boundary |
| Network | Flat test LAN | Managed Gigabit switch, IGMP snooping with querier, QoS queues, documented PTP domain/VLAN/multicast allocation |
| Discovery/control | AES67 daemon WebUI and SAP | Restrict control interface; retain SDP artifacts; consider NMOS only if the facility requires it |
| USB identifiers | Existing prototype VID/PID | Obtain an assigned production VID/PID before shipping |
| Redundancy | Single link | Optional SMPTE ST 2022-7 only after single-link stability; requires a second independent interface/path |

## CamillaGUI decision

Defer CamillaGUI until the audio and clock paths pass. It is useful for meter visibility, configuration editing, and filter management, but it is not required for the real-time path. With two CamillaDSP processes, use distinct WebSocket ports and treat GUI access as management-plane functionality. No GUI failure may stop audio.

## Rollback boundaries

- The verified `usb-16x16.service`, setup script, and custom `usb_f_uac2.ko` are immutable baselines.
- CamillaDSP currently exists only under `/home/bdimaio/usb-16x16-work`; deleting that directory removes the prototype.
- The compiled RAVENNA module currently exists only in the same work tree and is not loaded.
- Before installing RAVENNA, record every destination file, module dependency, configuration, system setting, and service enablement. Provide an unload/disable/remove procedure and verify USB afterward.
- Never run `ptp4l` and the AES67 daemon's PTP slave on `eth0` simultaneously.

## Current go/no-go gates

| Gate | State |
|---|---|
| USB gadget invariant | Pass |
| CamillaDSP format/open/60-second run | Pass |
| 16-channel identity | Pending |
| Wired carrier | Blocked: cable/link absent |
| Hardware PTP capability | Pass by capability inspection |
| Live PTP lock | Pending wired link and grandmaster |
| RAVENNA exact-kernel compile | Pass |
| Candidate AES67 engine uses `eth0` PHC | No: production gap identified |
| RAVENNA module load/platform test | Pending rollback package |
| AES67 TX | Pending |
| AES67 RX | Pending |
| Combined full duplex | Pending |
