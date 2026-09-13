# AoIP → DSP → AoIP — the loop mode design

Status: **built and measured 2026-09-12 (see the MEASURED section at the end);
not installed, not accepted, the service untouched.** Earlier that day: The bridge change (`--mode aoip-loop`, `--loop-impulse`),
the `loop-measure` preset (compiled, hash 1e417960), the candidate wrapper
`work/aes67-candidate/run-aoip-candidate-safe.sh`, the Pi build script
`build-aoip-candidate.sh` beside this note, the wire analyser's `--loop`
pairing and the Mac-side `analyze-aoip-loop.sh` exist; the wrapper refuses to
run until the Pi build's hash is pinned into it. The operator's answers of
2026-09-12 to the questions at the end: the -40 dB preset breaks the loop
(and a real deployment would not route the output back to its own input),
the stream-stop test is wanted, one binary with the dsp-direct re-measure,
the `tx_` keys reused, the service may stop at any time for builds. This
is the item `DSP_MODE_DESIGN.md` set aside under "What this design does not
cover", picked up after the meter tap was accepted (handoff ACCEPTED
2026-09-11 23:55). It decides the shape, names what has to be true before a
line of code is written, and ends with the questions only the operator can
answer. Where it and the handoff tail differ, the handoff wins.

## What the mode is

One direction inside the existing bridge: **RAVENNA capture → DspStage →
RAVENNA playback**, on the same card, with no USB device opened at all.

```text
Ferrofish flows 31/32 -> sink 0/1 -> RAVENNA capture -> ring -> DSP -> RAVENNA playback -> source 0/1 -> multicast
```

The daemon, the module, the two sinks with the profile's sink delay, the two
sources, PTP and the link watch are the accepted stack, unchanged. What is
removed is everything the USB host contributed: the gadget PCMs, the pitch
servo and its estimator, the RX direction, the host's frame grid and the
supervisor's model of a host that comes and goes.

The duplex bridge stays what it is. The point of record (dsp-direct on bridge
947e8b4d, 703 at 64 / RTL 32 18.563 ms) is what every change below is
measured against, and the mode must be absent from it in behaviour when the
flag is absent from the command line.

## The decision

**Loop mode is a `--mode aoip-loop` flag on the one bridge binary**, not a
second program and not a separate transport.

| Option | Why not |
| --- | --- |
| A separate binary from a split-out transport library | `Pcm`, `Direction`, `capture_into_ring`, `render_to_playback` and the aligned prime all live in `main.cpp`, not the core. Extracting them is a refactor of the accepted code path for no measured gain, and the accepted binary is rebuilt either way. |
| CamillaDSP on `hw:RAVENNA` capture/playback with `alsaloop`-style ownership | Re-introduces the engine the step-4 decision rejected, and with it a second clock owner and a queue nobody has primed or measured. The stage that is verified sample for sample against CamillaDSP is already in the bridge. |
| Keep the duplex bridge running and add the loop beside it | Two processes owning `hw:RAVENNA` capture and playback. The card has one 16-channel capture and one 16-channel playback; the loop consumes the same channels the RX direction would. Exclusive by construction. |

The cost of the chosen option is stated up front: **any change to the bridge
binary moves the supervisor's pinned hash, and dsp-direct is re-measured on
the new build before anything is accepted** (4 x 800 impulses, a ten-minute
sixteen-channel soak, RTL at 32 on a fresh anchor), exactly as 947e8b4d was
after 406699bd. That battery is the price of adding the mode and it is paid
whether or not the loop itself is ever accepted.

## What changes in the bridge

Read `src/main.cpp` with these in hand: `run()` at about line 2483 opens the
four PCMs unconditionally; `Direction tx` / `rx` are wired at 2564; the
aligned start block from 2716 assigns `tick_source` between them; the loop
from 2789 drives both; `publish_telemetry` (2096) and the SUMMARY (about
2990–3040) read both by reference. `rx` is named 153 times in the file, most
of them in those three places.

1. **Options.** `mode` with two values, `usb-duplex` (the default, and the
   only behaviour when the flag is absent) and `aoip-loop`. Validation at
   parse time: `aoip-loop` refuses `--usb-pitch-servo` other than 0,
   `--pitch-seed`, `--level-shift`, `--tx-depth` / `--rx-depth`, the RX
   alignment and prime options and the phase window, each with a message
   that says why (no gadget, no second clock). It accepts `--dsp-preset`,
   `--meter-file`, `--zero-run-detect`, `--impulse-trace` and the TX
   alignment set.
2. **Devices.** In loop mode `usb_capture` and `usb_playback` are not
   constructed. `Pcm` opens in its constructor, so the two become
   `std::optional<Pcm>` (or are constructed inside the duplex branch) and
   `poll_descriptors` is built from RAVENNA capture alone.
3. **One direction.** `Direction loop("ravenna-to-ravenna", ravenna_capture,
   ravenna_playback, ring)` with `capture_stage = "ravenna-capture"` and
   `playback_stage = "ravenna-playback"`, the stage names the meters, the
   zero-run detector and the impulse trace already know. The DSP stage and
   the meters attach to it exactly as they attach to `tx` today; the prime
   render stays unfiltered (`renders_after_prime`) for the same reason and
   with the same measured margin, since the playback device and its prime
   are the ones the 46 µs figure was taken on.
4. **`rx` becomes a placeholder.** As written: in loop mode `rx` is a
   `Direction` constructed on the RAVENNA PCMs and never driven (no
   capture, no render, no restart), so `publish_telemetry`, the telemetry
   thread and the SUMMARY keep their accepted signatures and read its
   zeros. The loop body skips its capture and render, the telemetry frame
   counts `tx` alone, the playback-delay read takes `tx` alone, and the
   servo block (regression, `LevelServo`, 2818–2900) is skipped whole: it
   has no meaning without a second clock. This is the part of the change
   that touches accepted code, and it is why the re-measure is not
   optional.
5. **The clock.** Both PCMs are on the RAVENNA card, so the resampler ratio
   is the constant 1.0 that the pitch-servo profiles already run the
   converters at (bit transparent, measured 2026-09-02) and the drift
   estimator is never constructed. The ring depth is then constant by
   construction. A depth that walks is a fault, not drift: the BRIDGE line
   reports it and the SUMMARY carries the min/max so a walk is visible.
6. **Aligned start.** `align_ravenna_capture` (the RX alignment, RAVENNA
   capture started first and alone) is reused as is: it is the loop's own
   capture. The playback trigger and prime reuse the TX alignment set with
   `tick_source` pointing at the loop direction itself, so its own fresh
   wakes carry the reference forward. This is the accepted TX mechanism on
   the same device and the same driver grid, which is why the first
   candidate should run it with dsp-direct's TX values verbatim
   (`ALIGN_TX_OFFSET_US=950`, `TX_PLAYBACK_PRIME=192`,
   `ALIGN_PRIME_AGE_MARGIN_US=50`) rather than with alignment off: those
   are the measured levers for this playback, and a missed target is
   reported and costs one period, not a run. Whether the same offset is
   right when the capture and the playback share a card is a measurement,
   and it is the first lever to sweep once the mode runs at all.
7. **Reporting.** In loop mode `NEGOTIATED` carries `mode=aoip-loop` in
   place of the two USB fields and every BRIDGE line starts
   `mode=aoip-loop loop_impulses=N`; the SUMMARY gains `mode` and
   `loop_impulses`. The single direction reports under the `tx_` keys. The
   `rx_` keys are present and read the idle placeholder's zeros (floors
   -1) rather than being omitted: as written, `rx` is a `Direction` that is
   constructed on the RAVENNA PCMs and never driven, which keeps
   `publish_telemetry`, the telemetry thread and the SUMMARY at their
   accepted signatures. Reasoning for the key reuse: `tx_` in this bridge has meant "the direction
   whose playback is RAVENNA" since Phase 4, the loop is that direction,
   and every consumer of the line (the supervisor's frozen-input test, the
   web collector, `gap-bar.py`, `impulse-stages.py`, `meter_battery.py`)
   parses `tx_*` first and treats a missing `rx_*` as absent already or can
   be made to with a one-line guard. The alternative, a third key prefix,
   would be more honest to read and would touch every one of those parsers
   for a mode that has not yet been shown to run. This is a naming choice
   the operator can overrule before code (see the questions).
8. **Nothing else.** No new thread (the meter publisher is created before
   capture start as it must be; the 2026-09-11 lesson stands), no
   allocation on the audio path, no change to `bridge_core`.

## What changes in the supervisor

The problem `DSP_MODE_DESIGN.md` named: the failure model at
`usb16x16-aes67-supervisor` is built around the USB host in four places, and
a mode with no host needs each of them decided, not relaxed.

The decision is **one `run` path with a per-profile `MODE` field**, default
`usb-duplex`, so every existing block validates and behaves exactly as today
with no edit to any of them. A second supervision path would duplicate the
stack lifecycle (module, daemon, PTP lock, sinks, readback, link watch,
settle, backoff), which is the part that is proven and must not fork.

| Point | Today (`usb-duplex`) | In `aoip-loop` |
| --- | --- | --- |
| **Start gate** (line ~640): waits for `udc` configured at high-speed, `usb-16x16.service` active, eth0 carrier at 1000. | Unchanged. | Waits for the link only. `usb-16x16.service` is not consulted: the gadget stays bound and the protected baseline is untouched, but a host that never enumerates must not hold the loop at the gate. |
| **Frozen input** (line ~738): `tx_input` unchanged across an advancing `tx_qn` means the USB capture stopped. | Arms the storm rule. | The same test now means *the AoIP input stopped*: the sink is not delivering. What the bridge sees then is not yet known (see the open question); until it is, a frozen input on its own is a `STAGE` line with a counter, and a decision after the measurement. |
| **Storm** (line ~755): ≥10 RECOVERs in a second, held for three ticks; with a frozen input or three seconds sustained → `host_absent`. | Unchanged. | Never calls `host_absent`, which waits on `dwc2 ... new device` lines that cannot come. A sustained storm with the link up is a stream or PTP fault: `fail 36 "AoIP stream storm"`, the stack stops, systemd restarts it, the three-in-five-minutes backoff applies as to any failure. The link watch already runs before the storm test on every tick, so a link storm is `fail 38` first, as it is today. |
| **Host retry** (60 s, `host_absent` loop). | Unchanged. | Not reached. |
| Settle restart, RECOVER-per-minute limit, protected-config watch, daemon exit, bridge exit. | Unchanged. | Unchanged. They are stack properties, not host properties. |

`validate_profile` gains the mode's own rules: `MODE=aoip-loop` requires
`USB_PITCH_SERVO=0`, `PITCH_SEED_PPM=0`, `LEVEL_SHIFT_FRAMES=0`, `TX_DEPTH` /
`RX_DEPTH` 0, `ALIGN_RX_TRIGGER=0`, `ALIGN_RX_PRIME=0`, `RX_PRIME_TRIM=0` and
no phase window, and the existing relationship checks apply to the TX side
only. `bridge_arguments` appends `--mode aoip-loop`. `cmd_status` and
`cmd_profiles` print the mode. The conf gains one block, `aoip-direct`,
`STATUS=experimental`, transport fields copied from dsp-direct's TX side, with
its own `MEASURED` empty until it is.

The web control service needs the health snapshot to carry `mode` and the
meters endpoint to tolerate two taps instead of four; the page's Settings
profile list then shows the block like any other, and Apply refuses it until
it is `accepted`, which is the existing rule doing the right thing.

## The rig, and the loop that must not close

This is the finding that decides how the first run can be made at all.

In the measurement rig the Ferrofish's matrix routes `Input 49-64` to
`Output 49-64` 1:1 (handoff, "Ferrofish return path status: RESOLVED"): the
Pi's sources come back as flows 31/32 into the Pi's sinks. That is the
digital return the whole latency record is built on. **In loop mode it is a
feedback loop through the DSP.** With no preset, or the transparent preset,
the loop gain is unity to within the preset's own trim, and anything that
enters — an impulse, dither, rounding noise — recirculates without decaying.
The clip counters and the meters would show it; nothing would stop it.

Three ways to break it, in the order I would take them:

1. **An attenuating measurement preset.** The compiler's output gain is
   per-output and already verified (`verify-run.py`). A `loop-measure`
   preset in `verify-presets.mjs`: the transparent bands, every output at
   -40 dB. Each pass round the loop then decays by 40 dB; the impulse the
   instrument correlates against is the first pass, and the second is
   40 dB down and below the trace threshold. No Ferrofish change, no Mac
   involvement, and the preset is pinned like every other artifact.
2. **The Ferrofish front panel**, unassigning the 49-64 loop, which is the
   operator's and cannot be scripted. Right for a real deployment; costly
   to flip for each measurement.
3. **A mute-all preset** for the first transport-only run, which proves the
   PCMs, the prime and the floors and says nothing about audio.

Option 1 is the recommendation. It leaves the rig exactly as it is for the
duplex profiles.

## How it is measured with no USB host

The Mac harness cannot see this mode: it measures through the gadget. Two
instruments that already exist can, and one small addition makes the first
of them self-contained.

- **The impulse trace** (`--impulse-trace 1`, stages `ravenna-capture` and
  `ravenna-playback`) gives the bridge's own capture-to-playback dwell per
  impulse, and `impulse-stages.py` splits it.
- **`rtp-impulses.py` on an eth0 capture** finds the same impulse in the
  incoming flow and the outgoing one and gives the wire-to-wire figure,
  which is the number this mode is actually for: AoIP in at the Pi's port to
  AoIP out at the Pi's port, including both driver legs and the sink delay.
  The stamp-phase reading (`stamp-phase.py`) applies unchanged. The script
  needs one addition: today it pairs each *outgoing* full-scale impulse
  with the next *returning* one (the Ferrofish loop). The loop figure is
  the other pairing, returning impulse to its re-emission, and with the
  -40 dB preset that re-emission is 0.0025 of full scale, below the 0.25
  pattern the script matches. Written: `--loop` classifies outgoing hits by
  magnitude (injected at or over 0x100000, re-emitted from `--loop-minimum`
  0x2000 up), pairs each return with the next re-emission, and prints the
  figure in wall time and in media-clock samples (the Pi's stamp of the
  re-emitted sample minus the Ferrofish's stamp of the returned one); with
  the bridge log it adds the bridge's own dwell, capture frame to the
  re-emission's write. Checked on a synthetic capture; the incoming
  detection and the duplex pairing are untouched.
- **The impulse itself** has to come from somewhere. The rig's only source
  today is the Mac over USB. Written: `--loop-impulse CH,PERIOD_S`, loop
  mode only, writes one 0.25 full-scale sample (the harness level the
  analyser matches) into the playback scratch of channel CH every PERIOD_S
  seconds of output, after the DSP stage, from one period after the first
  filtered render of each prime; counted as `loop_impulses` on the BRIDGE
  line and in the SUMMARY. The supervisor never passes it. The wrapper runs
  the trace at `--impulse-threshold 0.002 --impulse-holdoff 96` so the
  re-emission (0.0025) is stamped on `ravenna-playback` as well as the
  return on `ravenna-capture`; the IMPULSE line's `value=` tells them
  apart. The impulse leaves on the wire, returns through
  the Ferrofish, and is traced on the way in and the way out; with the
  -40 dB preset it dies on the second pass. The alternative sources —
  Dante Virtual Soundcard on the Mac routed through the Ferrofish's matrix,
  or an analogue input — measure the Ferrofish and DVS as much as the Pi
  and need front-panel work each time.

RTL Utility has no meaning here and is not quoted. The mode's figure is the
wire-to-wire number, with the bridge dwell and the sink delay as its split.

What the number should contain, without my adding it up: the sink delay
(103 samples at the accepted floor for phase 41), the driver's receive leg,
the ring target (48), the playback queue as the prime and its aligned drop
leave it, the driver's transmit leg, and the preset's own alignment delay if
any. The stage-trace day (`outputs/latency/stage-trace-20260906/`) priced
each of these on the duplex path; the loop's first run measures them on the
loop rather than inheriting them.

## Acceptance

The existing rules, plus what is specific to this mode:

1. **The duplex path is unchanged.** dsp-direct on the new binary, the full
   battery, at its figure within the fresh-anchor spread; the supervisor's
   journal under a duplex run shows the same stage lines it shows today and
   the Phase 6 bar reads the same. The `MODE` default and the absent
   `--mode` flag are the whole of the loop's footprint on it.
2. **The loop runs.** A candidate session with the `loop-measure` preset:
   zero RECOVERs, the aligned start and the prime making their targets, the
   ring depth flat over the run, `dsp_us_max` and `meter_us_max` reported,
   floors quoted.
3. **The loop is measured.** The wire-to-wire figure from `rtp-impulses.py`
   over a run of impulses with its spread, and the bridge dwell from the
   trace, on a stated preset with a stated sink delay.
4. **A ten-minute soak** with the injector running on all sixteen channels
   at a low rate and the meter tap on, zero RECOVERs, no clipped samples.
5. **The supervisor's loop path is exercised, not only written**: at least a
   stream stop and a link drop, each producing the stage line and the
   restart the table above says it should, on the candidate wrapper before
   the service ever runs the mode.
6. A profile switch from `aoip-direct` back to dsp-direct through the
   applier, verified and receipted, since that is the rollback the UI will
   offer.

Nothing here is a latency target. A number is not known until it is
measured, and the first one is a candidate draw like every first one.

## Steps, each with its gate

1. **This note**, and the operator's answers below. *Gate: the questions.*
2. **Bridge:** `--mode`, the placeholder `rx`, the loop wiring,
   `--loop-impulse`, the reporting. *Done 2026-09-12:* syntax-checked clean
   on the Mac (clang, `-Wall -Wextra -Wpedantic -Werror` against the Pi's
   ALSA headers, the standing method); `bridge_tests` unchanged since the
   core is untouched. `build-aoip-candidate.sh` builds it on the Pi from a
   staged copy, refuses while the service is active, runs the core tests
   and four parser self-checks that open no device, and prints the hash.
   *Gate: the operator's go for the service stop and the build.*
3. **Preset:** *Done:* `loop-measure` in `verify-presets.mjs`, shape pinned
   in `verify-presets.test.mjs` (48 compiler tests pass), compiled on the
   Mac to `outputs/dsp-service/aoip-loop-20260912/loop-measure.dsp`, hash
   `1e417960b8df91483d839814d66a3a27241fca45752bddfd9a09c18f2b594b3c`; the
   same compile reproduces the pinned `transparent.dsp` (ad69598) byte for
   byte.
4. **Candidate wrapper:** *Done:* `run-aoip-candidate-safe.sh` (no USB
   gate, the mode flag with dsp-direct's TX levers verbatim, the injector,
   the preset pinned, `none` refused unless `USB16X16_AOIP_LOOP_OPEN=1`, a
   bounded tcpdump of both channel-1 streams to tmpfs moved into the
   result directory after the bridge exits) and `analyze-aoip-loop.sh` on
   the Mac (fetch after DONE, SUMMARY, the wire instrument). The wrapper's
   bridge hash is `FILL-AFTER-PI-BUILD` until step 2's build prints it.
5. **First run**, then the alignment offset sweep if the first run says the
   TX value is wrong for a shared card. *Gate: acceptance items 2 and 3.*
6. **Supervisor `MODE`, the conf block, web-control's `mode` and two-tap
   meters.** `bash -n`, `load_conf` on the Pi's bash, the Python tests.
7. **Install** through the dsp-service bundle (`deploy.py`, service stopped,
   the three pinned files together), then dsp-direct's battery on the new
   binary. *Gate: acceptance item 1. This is the step that needs sudo and a
   stated command.*
8. **Failure-path exercise, soak, ACCEPTED entry** (items 4–6), labels into
   the conf, the pickup prompt.

## Open questions, the operator's

1. **The loop and the source.** Is the attenuating `loop-measure` preset
   plus the bridge's own injector the right way to break the feedback and
   make the measurement, or should the Ferrofish's matrix change for this
   mode (and if so, what feeds `Output 49-64` instead)?
2. **What the capture does when the stream stops.** The frozen-input policy
   depends on whether the RAVENNA capture keeps delivering (zeros, pointer
   advancing) or stalls when the sink stops receiving with the link up.
   Nothing in the record says. The test is one unsubscribe of a Ferrofish
   flow in Dante Controller during a *candidate* run, never the service.
   Without it the loop policy in the table above stays "count and report".
3. **One binary.** Adding the mode to the bridge means dsp-direct is
   re-measured on the new build before anything is accepted. That is the
   standing rule and the recommendation; it is also a full battery on the
   point of record, and it should be a deliberate yes.
4. **Key naming.** `tx_*` reused for the single direction, or a third
   prefix and every parser touched. The recommendation is the reuse; say if
   the read matters more than the diff.
5. **When the service can stop** for the Pi build and the install. Every
   stop is a restart and a new draw for dsp-direct.

## MEASURED 2026-09-12: the loop's first run

Run `phase4-aoip-candidate-20260912T132437Z` (`outputs/latency/`), bridge
0a39f4a6 (main.cpp 59cf978d: 947e8b4d's source plus the mode), module
bc694c24, preset `loop-measure` 1e417960, dsp-direct's TX levers verbatim,
sink delay 103, 360 s, the injector on channel 1 every 2 s, the trace at
threshold 0.002 / holdoff 96, a 30 s eth0 capture from +15 s. Service
stopped throughout; the accepted binary untouched.

**The mode runs as designed.** `ALIGN status=ok` on the second attempt, the
prime and the aligned trigger landing where they land in duplex mode
(`front_age_frames=296`, `align_dropped=39`, `slack_us=844`), `DSP engaged`
on the render after the prime, 179 impulses injected, each stamped three
times (out at 0.25, back at 0.25, out again at 0.0025). `dsp_us_max`
88.4 µs, mean 49.5 (transparent's cost, as in duplex), zero clipped and
dropped frames, `tx_pull_max` 48, `tx_gap_max_us` 1096.

**The figure.** From the wire, the Pi's port to the Pi's port:

| Leg | Median | Min | Max | n |
| --- | --- | --- | --- | --- |
| packet back -> `ravenna-capture` frame (driver receive leg) | 1.724 ms | 1.614 | 1.802 | 15 |
| `ravenna-capture` frame -> `ravenna-playback` write (bridge dwell) | 1.596 ms | 1.591 | 1.604 | 179 |
| `ravenna-playback` write -> packet out (TX queue and driver transmit leg) | 4.907 ms | 4.899 | 4.907 | 14 |
| **AoIP in -> AoIP out, wall clock** | **8.227 ms** | 8.116 | 8.305 | 15 |

The three legs sum to the whole to the microsecond. On the Pi's own RTP
stamps the round trip injected sample -> re-emitted sample is **504
samples, every one of 15 pairs** (10.500 ms), which with the wall-clock
Ferrofish wire loop of 1.774 ms removed puts the loop at about **419
samples, 8.73 ms** on the media clock; the 0.5 ms between that and the
wall figure is packet granularity (the injected sample sat at frame 6 of
its packet, the re-emission at frame 30). A constant to the sample over
the capture, which is what a shared clock should give.

**Where it sits.** The TX queue never moved: `tx_queue=198` on every
BRIDGE line, `tx_qfloor=150` from the first line to the last, mean 175,
`tx_depth` 249 flat. In duplex mode the same prime gives a TX floor of
83 because the USB capture's arrival jitter eats into it; on the loop the
capture and the playback share the tick and the queue sits at the prime.
About 4.1 ms of the 8.2 is that queue (198 frames), 1.6 ms is the ring
(target 48 plus the block in hand, 77 frames), and the rest is the driver
each way with the sink delay inside the receive leg. The prime is sized
for a jitter the loop does not have: `TX_PLAYBACK_PRIME` is the first
lever, not the trigger offset this note guessed at.

**One RECOVER at t=56.4 s**, a capture XRUN with both PCMs in XRUN,
`ring=51 last_gap_us=82`, re-primed identically (`front_age_frames=296`)
and clean for the remaining 304 s. It coincided with an ssh read of the
bridge log from the Mac, the pattern the record already has for ssh work
during a run; counted, not attributed to the mode, and the next run takes
no reads at all.

### What this run does not establish

- **No soak, one run, n=15 on the wire.** The bridge dwell has n=179 and
  a 13 µs spread; the wire legs have the 30 s capture's fifteen.
- **No meter tap:** the wrapper passes no `--meter-file`, so the two-tap
  publisher is unexercised in loop mode.
- **The SUMMARY mislabels the loop's capture-side counters:** the loop
  direction is `tx`, so its capture zero runs and impulse events print
  under `zero_usb_capture` / `impulse_usb_capture` and the `ravenna_capture`
  keys read the idle placeholder's zeros. `zero_usb_capture` =
  1074/74160/169/183 is the loop's capture: the silence between impulses
  (183 long runs) and, at the -80 dB second pass, LSB-level tails
  interleaved with exact zeros (the 1074 short runs), a property of the
  measurement signal and not holes. To be fixed in the bridge (name the
  keys from the direction's stage) in the next build, with the rest of the
  lessons of this run.
- **The stream-stop behaviour** is still unknown; it is the next run.

## MEASURED 2026-09-12: the stream-stop test, and two more runs

Three loop runs in all (`phase4-aoip-candidate-20260912T{132437,221521,
223248}Z`), the same set each time. The wire figure held: 8.227 / 8.240 ms
wall on the two captured runs, 504 samples on the Pi's stamps on every pair
of both.

**A lost source is silence, not a stall.** With both sinks deleted for 30 s
during the third run, the RAVENNA capture kept delivering zeros at exactly
48 kHz, the ring and the queue never moved, no RECOVER, and the loop
resumed by itself when the sinks came back, with no re-prime and the same
dwell. So the open question in the supervisor table is decided: in loop
mode the frozen-input test is meaningless (it cannot fire) and no restart is
wanted on silence. The loop policy is: act on the link (already) and on
RECOVER storms (fail the run), report silence at the input from the
capture zero-run detector's long-run count, never restart for it. The
"count and report" placeholder in the table above becomes exactly that.

**One RECOVER per run, cause open** (handoff FOUND 2026-09-12 22:33): the
audio thread absent for over 4 ms once per six-to-seven-minute run, at
56 s, 380 s and 44.5 s. The tcpdump window (t=19-49 s) is a suspect for two
of the three and cannot explain the third; the first run's ssh read is
cleared. A control run without the capture is queued before any lever is
turned, and no acceptance claim is made while the count stands.

**Known behaviour seen on the loop:** the RAVENNA playback's three-packet
skip (a 3.3 ms gap, a 144-frame pull) took the floor from 150 to 54 once in
run 2 with no consequence, as the duplex record says it does; and one
978 µs `dsp_us_max` in run 2, a preemption mid-call, against 88 and 121 in
the other runs.

**Control without the capture (run 4, 23:32 UTC): zero RECOVERs in 420 s.**
Consistent with the tcpdump window as the cause of the one-per-run events,
not proof of it. Lever runs go without the capture from here; one captured
run at the chosen point closes each lever, with the window late in the run.
