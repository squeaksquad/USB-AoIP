# Repo map: USB 16x16 / AES67 bridge

Orientation index for a fresh session. It says where things are and how to
read them; it holds no measurements. `PROJECT_HANDOFF.md` is the authoritative
project state and wins over this file, every README, and every older snapshot.
Keep this file a map: when the layout changes, update the map, not the facts.

## What the project is

Raspberry Pi 5 running a class-compliant UAC2 gadget (`USB 16x16`, 16 in /
16 out, 48 kHz, packed 24-bit) bridged in both directions to AES67 (RAVENNA
ALSA driver + `aes67-linux-daemon`) with a Ferrofish as the digital loop
return. The Mac measures the digital round trip with a CoreAudio impulse
correlation harness. Priority order: protect the verified USB baseline,
sample-accurate latency measurement, then a sub-10 ms research target, then
persistent services, then an optional DSP mode.

Hosts and paths that every script assumes:

- Pi: `bdimaio@192.168.1.201`, ssh alias `audio-dev.local` (`wlan0`, management).
- Pi AoIP interface: `eth0` at `169.254.92.97`. SSH working says nothing about AoIP health.
- Pi work directory: `/home/bdimaio/usb-16x16-work` (staging for everything installed).
- Installed service names: `usb-16x16.service` (gadget, protected), `usb16x16-aes67.service` (bridge), `usb16x16-governor.service`.
- Remote: `github.com/squeaksquad/usb-16x16-aes67`, branch `main`.

## Top level

| Path | What it is | Read it when |
|---|---|---|
| `PROJECT_HANDOFF.md` | Authoritative, append-only chronological log, ~4,500 lines and growing. | Always, but by section (see below). Never whole. |
| `README.md` | Four-line pointer to the handoff. Its "next priority" sentence is stale. | Never needed. |
| `work/` | Everything that runs: bridge source, service, wrappers, harness, tuning. | Doing anything. |
| `outputs/latency/` | Measurement evidence, ~500 top-level entries, ~4,400 files. Cited by the handoff by run timestamp. | Verifying a number or re-analysing a run. |
| `outputs/architecture.md`, `outputs/pi-baseline.md` | 2026-08-30 snapshots (CamillaDSP-era design, first Pi inspection). Superseded. | Historical context only. |
| `outputs/screenshots/` | Two 2026-08-31 Audio MIDI Setup label screenshots. | Channel-name evidence. |
| `outputs/analyze-usb-channel-id.py`, `outputs/usb-channel-id-16ch.wav` | Channel-identity test media and analyser from the first day. | Re-checking channel mapping. |
| `Pi Testing/` | Local Pro Tools session and audio. Gitignored, private. | Never from a session. |

## `work/` by role

Bridge and service (what runs on the Pi):

- `work/phase4-bridge/` — the single-process real-time bridge `usb16x16-rt-bridge` (C++, CMake). `src/bridge_core.cpp` is the controller, `src/main.cpp` the CLI, `tests/bridge_tests.cpp` the unit tests, `artifacts/pi-aarch64/` the pinned build, `install-candidate.sh` the hash-guarded installer. README is the design note; its "Status" paragraph is stale.
- `work/aes67-bridge/` — the persistent service: `usb16x16-aes67-supervisor` (bash, subcommands `run`, `cleanup`, `status`, `profiles`, `switch-profile`), the systemd unit, `aes67.conf` (profiles as data, each block carries its own measured history in comments), `install-aes67-service.sh`, `DEPLOYMENT_PLAN.md` (the design, acceptance criteria, and the profile/latency roadmap). README has the install and rollback commands.
- `work/pi-tuning/` — Phase 5/6 levers: `setup-usb-16x16-req` (gadget script parameterised on `req_number`, installed 2026-09-04), `stall-tuning.sh` (runtime governor and IRQ pinning), `usb16x16-governor.service` and its installer.
- `work/protected-baseline-2026-08-31/` — the immutable USB rollback set: known-good `usb_f_uac2.ko`, `setup-usb-16x16`, `SHA256SUMS`. Never edit.
- `work/uac2-discrete-channels/` — the kernel patch that gives macOS channel labels `1`..`16`. Complete and installed 2026-09-01.

Measurement (what runs on the Mac, or drives the Pi from the Mac):

- `work/latency-harness/` — Swift CoreAudio tool `usb16x16-latency` (`inspect`, `list`, `measure`). Core in `Sources/USB16x16LatencyCore/` (`Correlation.swift`, `LiveImpulseMeasurement.swift`, `CoreAudioDevice.swift`). Env knobs: `USB16X16_DUMP`, `USB16X16_IMPULSE_LEN`. `build-app.sh` makes the signed app identity the mic permission needs. `measure-usb-only.sh` and `sweep-usb-only.sh` are the Phase 1 USB-only loop (Pi `alsaloop`).
- `work/aes67-candidate/` — orchestration wrappers. Pi side: `run-phase4-candidate-safe.sh` (bridge), `run-aes67-candidate-safe.sh` (older dual `alsaloop`), `run-bridge-hold-safe.sh`. Mac side: `measure-under-service.sh FRAMES IMPULSES [LABEL]` (measure against the running service, the current standard), `measure-phase4-roundtrip.sh`, `measure-aes67-roundtrip.sh`, the `sweep-*.sh` scripts, `sap-watch.py`, `multicast-rate-watch.sh`, `igmp-querier-probe.py`.
- `work/ravenna-latency/` — reversible wrapper around the upstream RAVENNA platform latency test.
- `work/inspect-pi.sh` — read-only Pi inventory (produced `outputs/pi-baseline.md`).

Findings and pickups:

- `work/dante-mode/PLAN.md` — planned Inferno-based Dante mode: native bidirectional Controller routing, persistent endpoint lifecycle, isolated USB integration, latency comparison and rollback. Documentation only; no candidate installed.
- `work/SAP_DISCOVERY_FINDING.md` — resolved 2026-09-01: the discovery delay was switch IGMP snooping.
- `work/NEXT_SESSION_PROMPT.md` — pickup prompt rewritten 2026-09-06 after the budget day (the transmit-slot fix); the handoff tail is still authoritative where they differ.
- `work/ravenna-lead-export/` — the RAVENNA module's arrival-lead export (patch 0002 on top of the transmit-slot fix): the patch, README (mechanism, units, how to read `sink_min_time`, build, install, rollback), `build.sh` for the Pi, `read-lead.sh` for the Mac. Staged 2026-09-07, not built.
- `work/ravenna-tx-fix/` — the RAVENNA module's transmit-slot fix: the patch, README (mechanism, build, install, rollback), the built module in `artifacts/`. Installed 2026-09-06; the supervisor loads it from `~/usb-16x16-work/ravenna-tx-fix-install/`.

Vendored and archived:

- `work/aes67-linux-daemon/` — upstream checkout, gitignored, pinned revisions in the handoff. Driver source under `3rdparty/`; read `audio_driver.c` and `manager.c` for RAVENNA stream start and timing.
- `work/camilladsp/` — one config from the CamillaDSP-era design. Not used by the bridge.
- `work/generate-channel-id.py` — made the channel-identity wav.

## How to read `PROJECT_HANDOFF.md`

It is chronological. Sections are appended, never rewritten. Corrections are
added as later paragraphs and as RETRACTED / CORRECTION notes at the top of the
section they amend: trust the note, keep the measurement. The current state is
therefore always at the tail; the header's "Authoritative state" date lags.

Get live line numbers with:

```bash
grep -n '^#\{2,4\} ' PROJECT_HANDOFF.md
```

The 2026-09-02-evening section onward uses bold lead-ins instead of headings.
List those with:

```bash
grep -n '^\*\*\(MEASURED\|ACCEPTED\|INSTALLED\|FOUND\|ROOT CAUSE\|CORRECTION\|DEFERRED\|SOAKED\|IMPLEMENTED\|STAGED\|DONE\)' PROJECT_HANDOFF.md
```

Section map, in file order, with what each is for:

| Section | Contains | Status |
|---|---|---|
| Objective, Protected USB baseline, Host channel-name requirement, Power and network baseline | Priorities, the immutable USB artifacts and their hashes, the label patch, PoE and network facts. | Stable reference. |
| AES67 implementation and paths, Verified AES67/PTP state, Known daemon startup race, Validated prototype transport, USB enumeration incident | Daemon/driver pins, PTP facts, the dual-`alsaloop` prototype, one enumeration scare. | Reference; transport superseded by Phase 4. |
| Earlier persistent-service plan, Latency objective and measurement definition, Expected latency ranges | How latency is defined and gated (signal-gated, never on sink flags). | Definitions still binding. |
| Latency research roadmap, Phases 1 to 6 | Phase 1 measurement, Phase 2 buffer floor, Phase 3 USB interval, Phase 4 (the bridge, ~1,800 lines of measured tuning under `####` headings ending "Phase 4 latency is not yet competitive"), Phase 5 PTP/USB pitch servo, Phase 6 real-time tuning. | Phase 4 accepted 2026-09-02; Phases 5 and 6 partly done, tracked in the tail. |
| Future DSP/content mode | Deferred CamillaDSP mode. | Not started. |
| 2026-08-31 sessions | Phase 1 and 2 results, self-loop boundary, Ferrofish return path. | Historical. |
| 2026-09-01 session results | Stopgap operating point, scheduler latency, switch QoS, the ~4 min restart dead time, harness defects, tooling table, withdrawn claims. | Historical; the tooling table is still accurate. |
| 2026-09-02 evening onward (one long section) | Crackle root cause and full-scale wrap fix; pitch servo; split servo; aligned start; aligned TX trigger and prime; the `servo-aligned*` profile lineage and each acceptance; the RTL-at-32 standard; USB drops at small IO sizes and `req_number`; the 41-sample holes. | Current. Read from the tail backwards to the last ACCEPTED. |
| Next-session checklist, Clean manual shutdown, Rollback rules | Operating rules. | Binding; the checklist's item 5 is stale, later items are patched in place. |

Fastest orientation on a new session: read the Rollback rules, then the last
ACCEPTED entry and everything after it, then the `aes67.conf` comment block for
the profile in `PROFILE=`.

## `outputs/latency/` naming

- `<label>-roundtrip-<N>f-<UTC>.json` — one harness run of N CoreAudio frames. Label is the profile or experiment (`service`, `both240`, `both240rx120`, `rx120req4`, `rx120req4soak`). Sidecars `-api/` hold daemon API snapshots, `readiness-probe-*`, `settle.log`, `sap-timeline.log`.
- `phase4-candidate-<UTC>/` — one wrapper session of the bridge: `bridge.log`, `daemon.log`, `metadata.txt`, PTP and sink API snapshots. The harness JSON for that session is a top-level `*-roundtrip-*.json`.
- `phase4-sink-sweep-<UTC>/` — one sink-delay sweep: `delay-<N>.{json,log}`, `probe-d<N>-<k>.*`, and the nested candidate directory it ran in. `aes67-candidate-<UTC>/`, `ravenna-latency-<UTC>/`, `ferrofish-channel-scan-<UTC>/` are older wrappers.
- `stage-trace-20260906/` — the impulse-trace day: `bridge-<label>-session-<UTC>.log` full-rate logs with IMPULSE lines, `impulse-stages.py` (stage split from a log) and `rtp-impulses.py` (the impulse in an eth0 capture, both ways).
- `usb-holes-20260904/` — the USB drop and 41-sample-hole campaign: `<label>-noise-ch2-<N>f-100imp.{json,diag.txt,zeros.txt}`, analysers `zeros.py` and `gaps2.py` alongside.
- `usb-only-*`, `coreaudio-usb16x16-baseline*.json` — Phase 1.
- `2026-08-31-latency-results.md` — the only prose in here; Phase 1 summary.
- `.wav`, `.log`, `.pcap` are gitignored except the bridge/daemon logs and API logs the handoff cites.

Timestamps in the handoff (`143219Z`, `180438Z`) are the UTC time part of these directory names.

## Working rules the repo encodes

- The USB gadget module, `setup-usb-16x16`, and `usb-16x16.service` are the protected baseline. Experiments use distinct names and carry restore commands.
- Installers verify pinned SHA-256 hashes and refuse otherwise. When a script or bridge changes, its hash is recorded in the handoff and in the installer.
- Change one variable at a time; record hashes, commands, logs, and results for every accepted point.
- Measurements gate on a detected return signal, never on sink flags. The standard figure is RTL Utility at 32 CoreAudio frames; the harness level is independent of buffer size.
- Any new operating point needs four loaded 800-impulse runs and a ten-minute sixteen-channel soak before ACCEPTED.
- Long measurement runs are launched detached and polled; a bridge RECOVER during a service measurement is counted, not fatal.
