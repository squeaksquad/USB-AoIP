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
| `work/` | Everything that runs: bridge source, service, web UI and its backend, wrappers, harness, tuning. | Doing anything. |
| `outputs/latency/` | Measurement evidence, ~500 top-level entries, ~4,400 files. Cited by the handoff by run timestamp. | Verifying a number or re-analysing a run. |
| `outputs/architecture.md`, `outputs/pi-baseline.md` | 2026-08-30 snapshots (CamillaDSP-era design, first Pi inspection). Superseded. | Historical context only. |
| `outputs/screenshots/` | Two 2026-08-31 Audio MIDI Setup label screenshots. | Channel-name evidence. |
| `outputs/analyze-usb-channel-id.py`, `outputs/usb-channel-id-16ch.wav` | Channel-identity test media and analyser from the first day. | Re-checking channel mapping. |
| `Pi Testing/` | Local Pro Tools session and audio. Gitignored, private. | Never from a session. |

## `work/` by role

Bridge and service (what runs on the Pi):

- `work/phase4-bridge/` — the single-process real-time bridge `usb16x16-rt-bridge` (C++, CMake). `src/bridge_core.cpp` is the controller, `src/main.cpp` the CLI, `tests/bridge_tests.cpp` the unit tests, `artifacts/pi-aarch64/` the pinned build, `install-candidate.sh` the hash-guarded installer. README is the design note; its "Status" paragraph is stale. `AOIP_LOOP_DESIGN.md` (2026-09-12, design only, nothing built) is the AoIP -> DSP -> AoIP plan: one `--mode aoip-loop` direction on the RAVENNA card, the supervisor's four USB-host detectors decided per profile `MODE`, the Ferrofish feedback loop broken by an attenuating measurement preset, measured on the wire with the bridge's own injector; it ends with the operator's open questions, answered 2026-09-12; `build-aoip-candidate.sh` builds the loop candidate on the Pi with the service stopped. `DSP_MODE_DESIGN.md` is the step-4 design: the filtering goes inside the bridge, where the stage sits, the real-time budget that is its main risk (the aligned prime has 46 µs of slack and cannot filter), and how the compiler's second output lets the bridge's own filtering be checked against CamillaDSP sample for sample. `DspStage` in `bridge_core` is that stage — load an artifact off the audio path, `process()` in place with no allocation, locks or throws; since 2026-09-13 its numbers sit in two sets and `publish()` swaps them live when `shape_key()` matches (Mac-tested, not built on the Pi) — and `src/dsp_offline.cpp` builds `usb16x16-dsp-offline`, a file-to-file runner linking the core only (no ALSA, so it builds on the Mac) that lets the `work/dsp-compiler` harnesses drive the bridge unchanged. Wired into `main.cpp` behind `--dsp-preset`, on `usb-to-ravenna` only: the preset loads before any device is opened, the aligned prime renders unfiltered and the stage engages on the next render, and the bridge reports `dsp_us_max` on the BRIDGE line and in the SUMMARY. ACCEPTED 2026-09-14: bridge 7e8f1064 (DSP stage + meter tap + live coefficients) is the installed point of record; `artifacts/pi-aarch64/usb16x16-rt-bridge` is that binary, 947e8b4d kept beside it. `work/aes67-candidate/run-dsp-candidate-safe.sh` runs a candidate with a preset (or `none` for the direct control) and `measure-dsp-roundtrip.sh` measures against it. `LIVE_COEFFICIENTS_DESIGN.md` (2026-09-13, design only, nothing built) is the live EQ / bass-management preview plan: the compiler emits a fixed shape so knob moves change only numbers, `DspStage` holds two coefficient sets swapped by one atomic index with filter state kept, a control thread created before capture polls a root-written file under `/run/usb16x16/`, the applier gains `live` and `commit` request kinds, and the UI classifies each edit as live or restart by a shape key shared by all three. All five steps are built and Mac-tested (2026-09-13); `LIVE_INSTALL_PLAN.md` is the install, battery and rollback sequence and `install-live-set.sh` the hash-guarded bridge+supervisor installer it uses. Installed and measured through all eight steps on 2026-09-13 (bridge 7e8f1064 in service); `live-toggle-push.sh` is the root-side swap pusher for the soak.
- `work/aes67-bridge/` — the persistent service: `usb16x16-aes67-supervisor` (bash, subcommands `run`, `cleanup`, `status`, `profiles`, `switch-profile`), the systemd unit, `aes67.conf` (profiles as data, each block carries its own measured history in comments), `install-aes67-service.sh`, `DEPLOYMENT_PLAN.md` (the design, acceptance criteria, and the profile/latency roadmap). README has the install and rollback commands.
- `work/pi-tuning/` — Phase 5/6 levers: `setup-usb-16x16-req` (gadget script parameterised on `req_number`, installed 2026-09-04), `stall-tuning.sh` (runtime governor and IRQ pinning), `usb16x16-governor.service` and its installer; `usb16x16-wlan-keepalive.service` (installed 2026-09-12: pings the Mac from wlan0 every 20 s so the access point keeps the management path; the Mac's addresses are hard-coded in it).
- `work/protected-baseline-2026-08-31/` — the immutable USB rollback set: known-good `usb_f_uac2.ko`, `setup-usb-16x16`, `SHA256SUMS`. Never edit.
- `work/uac2-discrete-channels/` — the kernel patch that gives macOS channel labels `1`..`16`. Complete and installed 2026-09-01.

Web control (the appliance UI and its backend, one subsystem in two halves):

- `work/web-control/` — the read-only control service `usb16x16-web` (Python stdlib, unprivileged): serves the UI plus `/api/health`, `/api/logs` and a preset store under `~/usb-16x16-work/web-presets`. One collector thread owns every Pi read and publishes a cached snapshot; it never reads `/api/sink/status/N`, whose arrival-lead minimum resets on read. `usb16x16-web.service` and the hash-guarded `install-web-control.sh` install it; README has the API, the load tiers, rollback, and what the service deliberately cannot do. Staged 2026-09-09 at `~/usb-16x16-work/web-control/`; installing it is a separate sudo step.
- `work/web-ui/` — the browser UI (ES modules, no build). `app.mjs` renders and owns events; `model.mjs`, `workflows.mjs`, `buses.mjs`, `eq-tools.mjs`, `profiles.mjs`, `reset-band.mjs`, `live.mjs` (the live-edit debounce queue, 2026-09-13) hold the testable logic, each with a `*.test.mjs` beside it (`node --test work/web-ui/*.test.mjs`). `crossover-notes.mjs` says which crossovers a preset actually applies and raises the 12 dB/oct polarity advisory, shared with `work/dsp-compiler` so the UI and the compiler cannot disagree. `backend.mjs` is the client for `work/web-control`: it probes once, polls health, and falls back to a standalone prototype with browser-storage presets when nothing answers. README is the scope, the interaction notes and the verification log; it is long, read it by section. Meters are synthetic in both modes and DSP mode is a draft — no CamillaDSP compiler or engine service exists.

- `work/dsp-compiler/` — the preset-to-CamillaDSP compiler (step 3, offline and inert): `compile.mjs` is the pure compiler, `yaml.mjs` a small deterministic emitter, `usb16x16-dsp-compile` the CLI, `compile.test.mjs` the unit tests. Five file-to-file engine harnesses: `verify-run.py` (staggered impulses: routing, delay, polarity, gain, mute — also the headphone buses), `verify-tone.py` (a 20 Hz tone: the bass matrix and LFE trim, which impulses cannot measure through a ringing low-pass), `verify-response.py` (one impulse, DFT: the PEQ magnitude against `eqResponse`; it flags its own truncation, since an undecayed response reads low at the band centre), `verify-crossover.py` (the same impulse kept complex: crossover magnitude, phase, asymptotic slope and the sum of the two branches, which is what decides the 12 dB/oct polarity question) and `verify-clip.py` (a full-scale signal: bit transparency, and saturation versus wrapping past 0 dBFS). `verify-presets.mjs` builds the presets these run on and `verify-presets.test.mjs` pins their compiled shape, so a harness command line cannot drift from the preset it names. `coefficients.mjs` turns bands and crossovers into biquad coefficients (the same expressions `model.mjs` draws its curve with, and the Butterworth-squared cascade the engine was measured against) and `bridge-artifact.mjs` serialises a compiled pipeline as the flat artifact the bridge loads — emitted from the same compilation as the YAML, never a second one. `measure-load.py` and `run-load.sh` measure what a configuration costs the Pi. `run-headtohead.sh` builds the bridge core on the Pi and runs both engines against each other on the same inputs, `compare-engines.py` compares their raw output sample by sample, and `bridge-engine-shim` is the adapter that lets the harnesses drive the bridge's offline runner unchanged. `run-verifications.sh` compiles on the Mac (the Pi has no node), stages, and runs the three outstanding verifications in one pass; it refuses while `usb16x16-aes67.service` is up. Results land in `outputs/dsp-verify/`. README carries the pipeline shape, the headroom policy, what the compiler refuses to decide (12 dB/oct polarity, devices, applying), and — importantly — what is and is not verified end to end. Nothing here is installed on the Pi; the engine `--check` and the verification runs use the pinned CamillaDSP 4.1.3 there.

Measurement (what runs on the Mac, or drives the Pi from the Mac):

- `work/latency-harness/` — Swift CoreAudio tool `usb16x16-latency` (`inspect`, `list`, `measure`, `continuous`, `bitexact`). `bitexact` (`BitExact.swift`, 2026-10-10) is the bit-transparency check from the Mac: full-scale noise on all sixteen outputs, so monitors muted first; it allows for the 0.999998 gain macOS applies each way on this device. Core in `Sources/USB16x16LatencyCore/` (`Correlation.swift`, `LiveImpulseMeasurement.swift`, `CoreAudioDevice.swift`). Env knobs: `USB16X16_DUMP`, `USB16X16_IMPULSE_LEN`. Since 2026-10-10 the report carries the IOProc's output-minus-input offset (`ioOffset*Samples`), which is the whole difference between the harness and RTL Utility; `work/dante-mode/measure-candidate.sh` prints the sum as `daw_timeline`. `build-app.sh` makes the signed app identity the mic permission needs. `measure-usb-only.sh` and `sweep-usb-only.sh` are the Phase 1 USB-only loop (Pi `alsaloop`). `read-rtl-log.sh [COUNT] [HARNESS] [BUFFER]` reads RTL Utility's own measurements log (`~/Library/Logs/RTL Utility/`), validates the newest readings as the standard one and saves them as evidence; its header has the procedure for taking a reading from a session.
- `work/aes67-candidate/` — orchestration wrappers. Pi side: `run-phase4-candidate-safe.sh` (bridge), `run-dsp-candidate-safe.sh` (bridge with a preset), `run-aoip-candidate-safe.sh` (the AoIP loop mode: no USB gate, the bridge's own impulse injector, a bounded eth0 capture; its Mac reader is `analyze-aoip-loop.sh`), `run-aes67-candidate-safe.sh` (older dual `alsaloop`), `run-bridge-hold-safe.sh`. Mac side: `measure-under-service.sh FRAMES IMPULSES [LABEL]` (measure against the running service, the current standard), `measure-phase4-roundtrip.sh`, `measure-aes67-roundtrip.sh`, the `sweep-*.sh` scripts, `sap-watch.py`, `multicast-rate-watch.sh`, `igmp-querier-probe.py`.
- `work/ravenna-latency/` — reversible wrapper around the upstream RAVENNA platform latency test.
- `work/inspect-pi.sh` — read-only Pi inventory (produced `outputs/pi-baseline.md`).

Findings and pickups:

- `work/dante-mode/PLAN.md` — planned Inferno-based Dante mode: native bidirectional Controller routing, persistent endpoint lifecycle, isolated USB integration, latency comparison and rollback. Stage 2 begun 2026-10-08: `SOURCES.lock` pins Inferno 9767558e and the Statime fork 244f20a5, `RESULTS.md` holds the two source reads (ALSA contract, the dither setting, where threads are created, the crossed latency knobs; what Statime does to the Pi's clocks and the first-run config) and what is still owed; the checkout is `upstream/`, gitignored. Both built on the Pi 2026-10-09 by `build-candidate.sh` (hashes in `SOURCES.lock`, staged in `~/usb-16x16-work/dante-mode/`); `probe/inferno-probe.c` (the bridge's ALSA call set against the plugin with no USB: contract, thread inventory, sample-for-sample pattern check) with `probe/run-probe.sh` and `config/` was run 2026-10-09 (results in `RESULTS.md`: contract works at periods 32 and 64, bit transparency passed with the dither off, an xrun costs about 6 s of audio); `run-alsaloop-prototype.sh [SECONDS] [LATENCY_USEC] [INFERNO_LATENCY_NS]` is the USB-to-Inferno `alsaloop` prototype (run as root with Statime up and the AES67 service stopped; `SYNC=pitch` steers the gadget pitch controls instead of resampling), first read 19.708 ms at 32 frames on 2026-10-09; `measure-candidate.sh` is the Mac harness wrapper for the Dante stack (impulse runs and the `noise` hole probe). `diag/eth-tx-watch.py` (2026-10-11) is an unprivileged 2 kHz watcher of eth0's in-flight bytes and transmit counter for the Pi, written for the Dante-side holes; the diagnostic owner build (`OWNER_BIN=usb16x16-dante-owner-diag`) prints `out_holes` / `back_holes`, and `run-owner.sh` takes `OWNER_CPUS=`. `OWNER_DESIGN.md` (2026-10-09, design only) is the plan for the process that replaces `alsaloop` and, on this path, the bridge: one long-lived `usb16x16-dante-owner` that never re-prepares the Inferno PCM, a USB half that comes and goes, depth held in the device buffers with the bridge's mode 2 servo, and seven steps each with its check; it ends with open questions for the operator. Steps 1 to 3 passed on 2026-10-09 and `owner/main.cpp` is the network half (`--no-usb`, step 4; built on the Pi with one g++ line, run by `run-owner.sh` with `config/asound-inferno-owner.conf`); the USB half is not written. `patches/0002` (subscriptions retried after 1 s) is a third artifact, `plugins/xrun-option-retry1/`, built by `build-patched.sh NAME PATCH...`. Open since 2026-10-09 23:30 UTC: the harness level steps down at every owner start (RESULTS.md, "The level is a draw at each owner start"). The enablers: the probe's `--free-run`, and `patches/0001` (the plugin's `XRUN_REPORT` option) built by `build-patched.sh` into `plugins/xrun-option/` beside `plugins/stock/` on the Pi (`INFERNO_PLUGIN_DIR` / `INFERNO_CONFIG` on `run-probe.sh` select them). Since 2026-10-09 the operator develops this path as the main line and leaves the AES67 service stopped; nothing is installed as a service. ACCEPTED 2026-10-10: owner 22fd2622 with plugin 5c6b1c0a (`plugins/xrun-option-retry1`, the `run-owner.sh` default) is the Dante point of record (handoff tail), plugin 55dee5d8 and owner d4ebd576 kept as fallbacks; started from a session through `/etc/sudoers.d/usb16x16-dante`.
- `work/SAP_DISCOVERY_FINDING.md` — resolved 2026-09-01: the discovery delay was switch IGMP snooping.
- `work/NEXT_SESSION_PROMPT.md` — pickup prompt rewritten 2026-09-06 after the budget day (the transmit-slot fix); the handoff tail is still authoritative where they differ.
- `work/ravenna-lead-export/` — the RAVENNA module's arrival-lead export (patch 0002 on top of the transmit-slot fix): the patch, README (mechanism, units, how to read `sink_min_time`, build, install, rollback), `build.sh` for the Pi, `read-lead.sh` for the Mac. Staged 2026-09-07, not built.
- `work/ravenna-tx-fix/` — the RAVENNA module's transmit-slot fix: the patch, README (mechanism, build, install, rollback), the built module in `artifacts/`. Installed 2026-09-06; the supervisor loads it from `~/usb-16x16-work/ravenna-tx-fix-install/`.

Vendored and archived:

- `work/aes67-linux-daemon/` — upstream checkout, gitignored, pinned revisions in the handoff. Driver source under `3rdparty/`; read `audio_driver.c` and `manager.c` for RAVENNA stream start and timing.
- `work/camilladsp/` — one config from the CamillaDSP-era design. Not used by the bridge. The 4.1.3 binary is staged on the Pi but nothing runs it; see `work/web-ui/README.md` for what DSP mode still needs.
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
grep -n '^\*\*\(MEASURED\|ACCEPTED\|INSTALLED\|FOUND\|ROOT CAUSE\|CORRECTION\|DEFERRED\|SOAKED\|IMPLEMENTED\|STAGED\|DONE\|DECIDED\)' PROJECT_HANDOFF.md
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
| 2026-10-08 / 09 Dante entries (`DONE`, `DECIDED`, at the tail) | Inferno stage 2, the `alsaloop` prototype's figures, the decision to develop Dante and leave the AES67 service stopped, state at close. | Current. Start here; the detail is in `work/dante-mode/RESULTS.md`. |
| Next-session checklist, Clean manual shutdown, Rollback rules | Operating rules. | Binding; the checklist's item 5 is stale, later items are patched in place. |

Fastest orientation on a new session: read the Rollback rules, then the last
ACCEPTED entry and everything after it, then the `aes67.conf` comment block for
the profile in `PROFILE=`. Since 2026-10-09 the work is the Dante path: read the
tail's `DONE` and `DECIDED` entries and `work/NEXT_SESSION_PROMPT.md` first; the
AES67 material is the rollback.

## `outputs/latency/` naming

- `<label>-roundtrip-<N>f-<UTC>.json` — one harness run of N CoreAudio frames. Label is the profile or experiment (`service`, `both240`, `both240rx120`, `rx120req4`, `rx120req4soak`). Sidecars `-api/` hold daemon API snapshots, `readiness-probe-*`, `settle.log`, `sap-timeline.log`.
- `phase4-candidate-<UTC>/` — one wrapper session of the bridge: `bridge.log`, `daemon.log`, `metadata.txt`, PTP and sink API snapshots. The harness JSON for that session is a top-level `*-roundtrip-*.json`.
- `phase4-sink-sweep-<UTC>/` — one sink-delay sweep: `delay-<N>.{json,log}`, `probe-d<N>-<k>.*`, and the nested candidate directory it ran in. `aes67-candidate-<UTC>/`, `ravenna-latency-<UTC>/`, `ferrofish-channel-scan-<UTC>/` are older wrappers.
- `stage-trace-20260906/` — the impulse-trace day: `bridge-<label>-session-<UTC>.log` full-rate logs with IMPULSE lines, `impulse-stages.py` (stage split from a log), `rtp-impulses.py` (the impulse in an eth0 capture, both ways), `stamp-phase.py` (each stream's stamp phase against the driver's frame grid from a capture, and the free sink-delay range; `stamp-phase-20260906-captures.txt` is its evidence).
- `phase6-gapbar-20260907/` — Phase 6, the pull-gap bar under the TX prime: `gap-bar.py` (floors, gaps, pulls, re-primes and the priced TX prime from a bridge log or the wrapper's subset), `read-bar.sh` (the daily read-only read from the Pi into `reads/`), `historical-sessions.txt` (the analyser over the saved session logs).
- `usb-holes-20260904/` — the USB drop and 41-sample-hole campaign: `<label>-noise-ch2-<N>f-100imp.{json,diag.txt,zeros.txt}`, analysers `zeros.py` and `gaps2.py` alongside.
- `usb-only-*`, `coreaudio-usb16x16-baseline*.json` — Phase 1.
- `2026-08-31-latency-results.md` — the only prose in here; Phase 1 summary.
- `.wav`, `.log`, `.pcap` are gitignored except the bridge/daemon logs and API logs the handoff cites.

Timestamps in the handoff (`143219Z`, `180438Z`) are the UTC time part of these directory names.

## Working rules the repo encodes

- The USB gadget module, `setup-usb-16x16`, and `usb-16x16.service` are the protected baseline. Experiments use distinct names and carry restore commands.
- Installers verify pinned SHA-256 hashes and refuse otherwise. When a script or bridge changes, its hash is recorded in the handoff and in the installer.
- Change one variable at a time; record hashes, commands, logs, and results for every accepted point.
- Measurements gate on a detected return signal, never on sink flags. The standard figure is RTL Utility at 32 CoreAudio frames; the harness level is independent of buffer size. Since 2026-10-10 the harness's `daw_timeline` line (lag plus the measured IOProc offset, steady) is accepted by the operator as that figure.
- Any new operating point needs four loaded 800-impulse runs and a ten-minute sixteen-channel soak before ACCEPTED.
- Long measurement runs are launched detached and polled; a bridge RECOVER during a service measurement is counted, not fatal.
