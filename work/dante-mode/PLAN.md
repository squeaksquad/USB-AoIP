# Dante mode proof of concept

Status: planned only. Written 2026-09-05 UTC (2026-09-04 local).
No Dante software has been built, installed, or tested by this work.

## Goal

Give the Pi one persistent 16-transmit/16-receive endpoint in Dante Controller's routing matrix, preserving the native USB 16x16 interface and measuring whether native Dante transport can match or improve the accepted AES67 latency.

## Assumptions

- Controller usability is an independent reason to pursue this mode: both directions must be routable in the matrix without manual SDP entry or external-session setup in Device View.
- Inferno is the first experimental backend; describe it as an unofficial Dante-compatible implementation, not an Audinate-approved product.
- Keep 48 kHz, 24-bit source fidelity, channels `1` through `16`, USB product `USB 16x16`, and manufacturer `Bryan DiMaio`. Internal S32 transport is acceptable if conversion preserves the 24-bit samples.
- The network-facing experimental name may be `USB 16x16 Inferno`; it must have a stable, distinct identity. This does not rename the USB device.
- Claude's active AES67 experiments continue undisturbed. Local source research/build preparation can proceed independently; Pi tests and network routing changes require a coordinated test window after the current campaign.
- Start with the existing Ferrofish and network. Record their actual firmware, addresses, routing and clock leader before testing; saved addresses are hints, not discovery.
- This document is a future implementation plan, not authorization to start services or switch the live transport. The current task authorizes saving this plan and its repo-map pointer.
- [PROJECT_HANDOFF.md](../../PROJECT_HANDOFF.md) remains authoritative for accepted hardware/software state. The latest accepted point recorded at drafting is `servo-aligned-both-240-rx120-sd144-tx192`: harness 1318 samples at 64 frames; RTL Utility 31.375 ms at 32 frames. Refresh this before comparison because target64 runs are underway.

## Files

Changes made for this planning task:

| File | Purpose |
|---|---|
| `work/dante-mode/PLAN.md` | Scope, implementation sequence, acceptance and rollback. |
| `CLAUDE.md` | A discovery pointer to this plan; no changes to recorded measurements. |

Proposed implementation artifacts; create only as their stages are reached:

| File or directory | Purpose |
|---|---|
| `work/dante-mode/SOURCES.lock` | Exact Inferno/Statime commits, submodules, compiler versions and artifact hashes. |
| `work/dante-mode/build-candidate.sh` | Reproducible isolated build with pinned Cargo lockfiles. |
| `work/dante-mode/config/` | Application-scoped ALSA config, explicit channel/latency/identity settings and one selected PTP config. |
| `work/dante-mode/run-candidate-safe.sh` | Preflight, owned-process lifecycle, telemetry and verified rollback. |
| `work/dante-mode/measure-candidate.sh` | Existing CoreAudio harness with Dante-specific readiness and evidence collection. |
| `work/dante-mode/RESULTS.md` | Stage outcomes, commands, hashes, screenshots and measured limitations. |
| `outputs/latency/dante-<UTC>/` | Per-run configurations, raw results, event logs and Controller evidence. |

If the ALSA compatibility gate passes, use a separately built copy of the existing bridge before proposing small shared-source changes. If it fails, record the precise contract mismatch and propose a bounded adapter under `work/dante-mode/`; do not create a general transport framework preemptively. Persistent service files are specified only after the prototype passes.

## Approach

### 1. Freeze a comparison and rollback manifest

Record the accepted profile and actual live config, service state, binary/module/script hashes, kernel, USB interval/request count, CPU/IRQ tuning, Controller/Ferrofish versions, routes and clock settings. Preserve operator-edited configuration exactly. The repo's default `PROFILE=` is not evidence of what the Pi is running.

Record baseline channel identity, continuous-signal integrity, RTL Utility at 32 frames and harness results at 64. Reuse recent evidence only if the complete configuration matches. Keep raw device-timeline lag and application round-trip figures in separate columns.

Exit gate: reproducible baseline, completed active measurements and a saved restoration procedure. No shared-device tests while another run owns USB or AoIP.

### 2. Pin and inspect Inferno before integrating USB

Upstream advertises native Dante send/receive, Controller routing, ALSA support and Pi 5 testing, but calls the implementation experimental. Its documented RX and TX latency defaults are each 10 ms; TX latency advertises a requirement to downstream receivers. Configure and record both explicitly rather than assuming a low Controller setting overrides them. The project documents PTPv1 through its Statime fork and a PHC clock option. These are upstream capabilities to verify, not results on this Pi. [Inferno upstream](https://github.com/teodly/inferno)

Pin full commits and submodule revisions, including the matching clock implementation. Build in an isolated directory with locked dependencies. Check licenses before distributing a derivative; no distribution is part of this experiment.

Inspect the ALSA plugin and test its contracts with a small probe:

- One process can open capture and playback while exposing exactly one 16x16 network identity.
- Nonblocking operation, S32_LE, 48 kHz, 16 channels, mmap access, poll descriptors, `avail`, `delay`, start, prepare, recovery and close behave as the bridge expects.
- Capture positions and playback positions refer to a consistent network-paced timeline, including when no incoming routes exist.
- Persisted identity and subscription state can live in an isolated, durable directory rather than depending on a changing IP address or temporary home.

The existing [Pcm class](../phase4-bridge/src/main.cpp) requires mmap-interleaved access and uses ALSA position/delay behavior in its controller. A successful `snd_pcm_open` alone does not establish compatibility.

Exit gate: pinned artifacts and a recorded compatibility matrix. If mmap/poll/delay semantics differ, resolve that boundary before live USB integration.

### 3. Prove Controller usability with an always-running endpoint

The ALSA plugin's network identity exists only while its application owns the device; inactive playback can leave downstream streams broken. It uses signed 32-bit samples and supports explicit RX/TX channel counts. Application-scoped ALSA configuration/module paths can avoid changing system defaults. Its receive-buffer capacity must accommodate effective receive latency plus processing headroom. [ALSA plugin documentation](https://github.com/teodly/inferno/tree/dev/alsa_pcm_inferno)

Create a resident test owner that keeps both directions active, sends silence when no source is available, and consumes received audio. First prove this without opening the USB gadget. Do not equate network visibility with valid transport.

Use one clock owner on the AoIP interface. Prefer a bounded PTPv1 follower experiment with the pinned Statime fork to exercise ordinary Dante operation. Verify Pi NIC/PHC support and clock quality before selecting hardware timestamps; software timestamping is an explicitly recorded fallback. A PTPv2 experiment is separate: enabling AES67 clock announcements on the Ferrofish does not by itself mean the audio payload is AES67. Confirm the actual media transport.

Stop the AES67 stack before candidate clock ownership. Do not run its PTP slave alongside Statime or ptp4l. Do not make broad changes to system time synchronization; choose the clock domain deliberately and record any necessary temporary changes and restoration.

In Controller, route Ferrofish transmit channels to Pi receive channels and Pi transmit channels to Ferrofish receive channels entirely through the matrix. Use a safe digital test route with no unintended acoustic or digital feedback. Save screenshots showing all 16 channels in both directions and verify signal on each.

Test Controller restart, candidate process restart, and network reconnect. Verify routes restore without manual re-entry and that the device ID stays stable. Measure recovery time; do not promise instantaneous reconnection.

Exit gate: one stable 16x16 identity, actual bidirectional audio and persistent subscriptions. If this fails, stop before latency tuning: the primary usability objective is unmet.

### 4. Connect USB with the smallest viable bridge change

Proposed media path, each direction independently:

```text
Mac USB OUT -> UAC2 capture -> bridge -> Inferno TX -> Ferrofish RX
Mac USB IN  <- UAC2 playback <- bridge <- Inferno RX <- Ferrofish TX
```

Try the existing single-process bridge against the qualified ALSA endpoint in a separate candidate build. Disable RAVENNA-specific aligned-start/trigger/prime assumptions initially; its 1 ms tick and reader phase are not Inferno contracts. Do not carry the RAVENNA skip margin or buffer settings across without measurement.

Validate the shared USB pitch controller against the new position semantics. Keep both USB directions on one clock discipline. Use an explicit settling phase and verify long-term occupancy drift; avoid stacked automatic resamplers. Any temporary resampling must be recorded and tested for fidelity.

Separate the network endpoint's lifetime from USB activity. The endpoint must remain visible and keep outgoing silence valid when the Mac sleeps, closes its DAW, or disconnects. First try this within one resident process that keeps the Inferno handles alive while USB is reopened. If the current process model cannot do it, add a bounded persistent endpoint owner; assess the added queue before choosing IPC or a library integration. PipeWire is an optional diagnostic fallback, with its buffering measured separately.

Exit gate: correct 16x16 channel mapping, continuity, stable clock following and no network identity loss on USB inactivity. No kernel USB changes are needed for this stage.

### 5. Compare latency and diagnose the remaining delay

The existing [measurement wrapper](../aes67-candidate/measure-under-service.sh) checks the AES67 service and its API. Reuse the harness executable and signal-gating logic through a separate Dante wrapper; do not run the AES67 wrapper unchanged against Inferno.

Start at explicit conservative network latencies for functional qualification. Then tighten one direction at a time based on late-event counters, signal integrity and scheduling evidence. A requested setting is not a measured effective delay; record sender requirements and actual receiver settings.

Run AES67 -> Dante -> AES67 comparisons with the same USB configuration, CoreAudio buffer size, sample rate, Ferrofish digital path and host load. Give each transport its own settling period. Repeat across independent candidate starts to expose startup-dependent latency. Disable the other measuring application during each run.

Track sample age where observable: USB capture backlog, bridge occupancy, network TX deadline, network RX presentation time and USB playback depth. Relate timestamps only through a measured clock mapping; raw PTP and host monotonic values are not directly subtractable. Mark inferred contributions and unexplained remainder explicitly.

Only after this attribution consider coordinated buffer management: one desired total delay per direction, reserves distributed between ring and playback queue, and low-water recovery that preserves continuity. The existing ring minimum is enforced by its renderer, so an untouched reserve is not proof it can be removed. The prior aggressive-draining failure must remain a regression case. This redesign is optional follow-up, not a dependency of proving Dante routing.

Exit gate: separate findings for Controller usability, stable operation and latency. Matching or beating the refreshed AES67 baseline qualifies a performance candidate. A slower but usable endpoint remains a documented experimental QoL option; it does not replace the accepted low-latency mode automatically.

### 6. Package mode selection after acceptance

Keep the USB service independent. Add an explicit AES67/Inferno transport selector only after both start/stop paths are proven; do not model Inferno as an AES67 buffer profile. Exactly one transport owns the gadget streams and network clock at a time.

The implementation must stop only its owned processes, restore USB pitch, restore any changed clock configuration and leave persistent candidate state intact. Restore the captured AES67 service/profile and the saved Ferrofish routes, then verify real return audio. Do not globally kill PTP processes or recreate the gadget as routine cleanup.

Verify rollback after normal stop, failed startup and forced candidate crash. RAII cleanup alone is insufficient after SIGKILL; the launcher/service needs an independent pitch-reset and restoration path. Retain candidate artifacts separately, with pinned hashes and a startup deadline that fails cleanly.

Record installation and acceptance in the authoritative handoff only when they happen. Audinate Embedded Platform remains the official fallback if Inferno cannot satisfy interoperability or lifecycle requirements; obtain Pi/platform support and licensing details before planning an SDK integration.

## Risks / edge cases

- Endpoint visibility can pass while audio or subscription persistence fails; all three need separate checks.
- Silence from unsubscribed channels must not stop the media clock, grow queues indefinitely or trigger restart storms.
- Network clock loss, leader changes, late packets and host scheduling stalls require different recovery handling.
- Short impulse runs can miss periodic holes; continuous known signal and independent channel checks are mandatory.
- A larger allocated buffer is not automatically a larger occupied delay. Conversely, copying old queue settings may quietly add latency.
- Hardware timestamp availability does not prove the application uses it, or eliminate USB scheduling jitter.
- Full Dante Controller feature parity, DDM/Director, redundant networking, higher sample rates, DSP mode and commercial certification are outside this proof of concept.
- No claim of sub-10 ms round trip follows from native Dante discovery or a submillisecond network setting.

## Verification

Planning deliverable: inspect the two-file diff, check local Markdown links and confirm no runtime/configuration changes. There is no executable implementation to build or test in this task.

For implementation, record exact build/test commands alongside the pinned source revisions. Use Cargo `--locked` for builds/tests where supported by those workspaces; run the existing bridge CMake/CTest suite in a separate build directory if bridge code changes. Add focused tests for lifecycle/clock/PCM contract changes, rather than tests that merely repeat profile values.

| Gate | Evidence required |
|---|---|
| USB invariant | One native 16x16 CoreAudio device at 48 kHz; labels 1-16; configured/high-speed; unchanged protected hashes. |
| Controller QoL | One endpoint with 16 TX + 16 RX, matrix routing both ways, no manual external-session setup, screenshot and channel-by-channel signal verification. |
| Persistence | Subscriptions restored across three process restarts, Controller restart and Ethernet reconnect; USB unplug/replug and Mac sleep/wake keep network identity present. Schedule three cold boots only after the active campaign, with recovery times recorded. |
| Initial integrity | Known continuous signal on every channel; no missing/repeated sections, unexpected zeros, clipping or crosstalk. Verify packed-24/S32 scaling. |
| Latency candidate | Four 800-impulse runs at 64 frames, every impulse detected, per-impulse delays and discontinuities recorded; RTL Utility at 32 measured separately. No XRUNs, drops or recoveries in accepted runs. |
| Required soak | At least 600 seconds with all 16 channels loaded, continuous-signal integrity plus impulse evidence, no unexplained holes, drops, restarts or clock unlocks. |
| Extended qualification | At least one hour of continuous 16-channel transport, including representative host/system load; assess rare events beyond the known 36-minute observation window. Longer testing is needed before a production reliability claim. |
| Comparison | Matched baseline/candidate/restored-baseline records; requested and effective network latencies; startup variation; CPU, scheduling gaps and clock/queue telemetry. |
| Rollback | Original USB enumeration retained and accepted AES67 audio restored after normal exit, failed start and candidate crash. |

Completion report: list each gate as passed, failed or untested; state the measured QoL and latency tradeoff; retain AES67 as the default until an explicit mode choice is made.
