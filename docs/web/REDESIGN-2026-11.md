# Page redesign, 2026-11: the design, what the engine supports, and the build order

Written 2026-11-16 from a design session with the operator. Status: DECIDED,
nothing built. `PROJECT_HANDOFF.md` is still the authority for what is
installed; this file is the plan it points to.

The design was worked out as a clickable mockup. Its files are in
`docs/web/mockup/` (see "The mockup" at the end). The mockup is the
specification, not code to ship: it is written for a design canvas, with
inline styles and simulated behaviour. The real page is rebuilt in this
repository's own form (plain ES modules, `style.css`, no build step).

The engine facts below come from three read-only surveys of this repository
made on 2026-11-16 at commit 94b3d79. Line references were reported by those
surveys and were not re-checked one by one; confirm a reference before
relying on it.

## The design in one page

Four top-level tabs.

- **Status.** Five cards (clock, sample rate, computer, network audio,
  running preset) and three meter rows: from the computer (16), to the
  network (Dante outputs), from the network (Dante inputs).
- **Control Room.** Operation, not setup. Everything is instant, is not part
  of a preset, and is kept on the device across restarts.
  - A card per speaker set and per headphones: level knob with LED ring,
    typed level, Dim, Mute, Ref (go to reference), Set (store reference),
    output meters, "Listen as" fold-downs, subwoofers on/off.
  - With more than one speaker set: one main volume, a trim per set, and a
    switch for which set plays.
  - Sources grid: which source each speaker set or headphones hears; Sum to
    hear several; Follow so headphones track the speakers; a cue level per
    source for headphones; talkback.
  - Speaker overview: the room seen from above, a tile per speaker with
    meter, solo and mute; group solo and mute; pre/post-fader meters;
    calibration noise.
  - Keyboard shortcuts.
- **Processor.** Setup, saved in a preset. A change bar shows what is pending
  and whether it is heard at once or needs a restart. Undo and redo.
  - Outputs: level, delay, polarity, EQ (16 bands), solo, on/off per output;
    align by distance; bypass, reset, import and export EQ.
  - Sources: sources beyond the main computer feed, from USB or Dante, mono
    to 16 wide, with level, gate and input EQ; a processing budget.
  - Routing: computer channels to outputs; outputs to Dante outputs; Dante
    inputs to the computer's inputs.
  - Speakers & headphones: the speaker sets and headphones, their sizes,
    whether an added set shares the main subwoofer.
  - Bass management: redirection, crossover, LFE, per-speaker crossover and
    high-pass, sub sends.
  - New preset and "change speaker layout" (keeps the preset).
- **System.** Versions and health, display (larger controls), level safety
  (knob maximum, level at power-up, reference lock), actions (restart audio,
  restart clock, support bundle, change password, reboot, shut down), presets
  on the device (run, rename, duplicate, export, import, remove), logs, a
  timeline of what happened.

### One model for the controls that used to overlap

- **Level** lives in three places only: each output (saved), each speaker
  set's trim (Control Room), and the knob (Control Room).
- **On/Off versus Mute.** The saved per-output switch is On/Off. Mute exists
  only in the Control Room and is never saved. Solo is one shared state.
- **Speaker sets.** One switch chooses which set plays. An added set shares
  the main subwoofer unless the operator chooses none or its own.
- **Naming.** "Speaker set", "headphones", "output". "Bus" is not used in
  labels.
- **The sample rate is never set from the page.** It is changed from the
  computer or Dante Controller, as now.

## What the engine does today

Dante path, owner `dante/owner/main.cpp` with `DspStage` from
`dsp-core/src/bridge_core.cpp`.

- **Channels.** 16 USB each way and 16 Dante each way. 16 is a constant in
  about ten places: `kChannels` in the owner and in `bridge_core.hpp`, the
  Inferno hw_params, the DSP stage's arrays and loader, the meter taps, the
  Inferno config (`RX_CHANNELS` / `TX_CHANNELS`), the compiler
  (`CHANNELS=16` in `web-ui/model.mjs`), and the page's meter reader.
- **Where the DSP sits.** On the computer-to-Dante direction only. The
  Dante-to-computer direction is copied unchanged and only metered.
- **What the DSP computes.** An arbitrary sparse mix from 16 inputs to up to
  48 internal channels, up to 64 biquads per internal channel, an arbitrary
  sparse mix to 16 outputs, then per output up to 64 biquads, a whole-sample
  delay (at most rate/100, so 10 ms), and a gain. A negative gain inverts;
  gain 0 mutes.
- **Live changes.** Any number (coefficient, mix gain, output gain, delay)
  can change without a restart as long as the shape (routing rows and
  section counts) is unchanged. The owner polls a file every 50 ms. Changes
  switch at a block boundary with **no ramp**. A page edit reaches that file
  through the web service, the inbox and the applier's guards.
- **Meters.** Three taps of 16 channels (computer in, Dante out, Dante in):
  peak, RMS and clip count over 50 ms.
- **Not in the engine at all:** master volume, dim, solo, source selection,
  talkback, a test-signal generator, a gate or any dynamics, more than one
  16-channel output, processing on the return direction.
- **Budget.** About 300 µs of each 1 ms wake. The 308-biquad `loaded` preset
  measures `dsp_us_max` 169 at 48 kHz. At 96 kHz the same load went over
  budget in 22 of 365 windows.
- **Applier 1.9.0 request kinds:** profile, preset, remove, live, commit,
  shutdown. Rate is taken only from the audio service's own request file.
  There is no reboot, no service restart, no clock restart, no password
  change and no support bundle.
- **Preset model v2** (`web-ui/model.mjs`): per output gain, delay 0-10 ms,
  mute, invert, 16 EQ bands (bell, low shelf, high shelf), role, source;
  per input crossover; a 16x16 send matrix to subs; LFE; buses of kind
  speakers or headphones (pair or downmix).

## Feature by feature

"Page" means it can ship as a change to `web-ui/` (and at most the compiler),
accepted under the light rule. "Applier" needs a new request kind. "Engine"
changes the audio path and needs the full battery.

| Feature in the design | Needs | Note |
|---|---|---|
| Status cards, 16-channel meters | Page | Data already in `/api/health` and `/api/meters`. |
| Outputs: level, on/off, EQ, polarity, delay | Page | In the model today. Delay is capped at 10 ms, not the mockup's 50. |
| Align by distance | Page | Arithmetic on the delay fields; 10 ms covers about 3.4 m of path difference. |
| Bypass / reset / import / export EQ | Page | Mostly present today. |
| Routing: computer channels to outputs | Page | The `source` and send fields. |
| Speakers & headphones (one speaker set, headphones) | Page | The bus model today. |
| Bass management | Page | Crossovers are per input in the model; the per-speaker view needs mapping. |
| New preset, change layout, save as, rename, duplicate, export, import | Page | Preset store CRUD exists; rename and duplicate are compositions of it. |
| Undo and redo, change bar, larger controls | Page | Page state only. |
| Peak hold, clip latch | Page | From the existing taps. |
| Shut down, logs | Page | Exist today. |
| Reboot, restart audio, restart clock, support bundle, change password | Applier | New request kinds; the web service stays unprivileged. |
| Control Room knob, dim, mute, solo | Engine | Possible as live gain edits, but with no ramp and an applier round trip a knob would click and lag. Needs a ramped monitor block with a direct control path. |
| Fold-downs, speaker-set switch, trims, shared subwoofer | Engine | Same monitor block. An extra speaker set also needs the compiler to emit it within the 16 outputs. |
| Level safety, reference | Engine | Part of the monitor block; persisted on the Pi outside presets. |
| Dante inputs as sources, talkback, cue mixes | Engine | The return direction is not processed today. |
| "To the computer" patch | Engine | A channel map on the return direction. |
| 32 or 64 Dante channels, the 16x64 grids, 64-channel Status meters | Engine | Probe first; Dante and USB counts must be separated. May not be reachable. |
| Gate | Engine | No dynamics exist. |
| Input EQ on a USB source | Page | Branch biquads on an input exist. On a Dante source it waits for sources. |
| Calibration noise | Engine | No generator exists. |
| Processing budget readout | Page | `dsp_us_max` is reported; the mockup's percentages were invented. |

## Build order

Each phase is its own branch and pull request. Nothing is installed without
the operator's go-ahead.

0. **Record the design** (this file and `docs/web/mockup/`).
1. **New page on today's engine.** Status, Processor (Outputs with delay and
   polarity, Routing, Speakers & headphones, Bass management), System,
   presets, undo, align by distance, larger controls, peak hold and clip
   latch. A feature the engine lacks is left out, not shown disabled. No
   Control Room tab and no Sources tab yet.
2. **System actions.** Reboot, restart audio, restart clock, support bundle,
   password change as applier request kinds, with tests and `ACCESS.md`.
3. **Monitor block in the engine.** Ramped volume, dim, mute, solo, set
   switch, fold-downs, level safety, on a direct control path. Unlocks the
   Control Room for the computer source.
4. **Dante inputs into the mix.** Sources, talkback, cue mixes, the "To the
   computer" patch.
5. **More than 16 Dante channels.** Run the no-USB Inferno probe at 32 and
   64 first.
6. **Gate, input EQ on Dante sources, calibration noise.**

Stopping after phase 1 is a complete result: the Pi has the new page with
everything it can do today.

## Things to settle while building

- **Styles.** The web service sends a content security policy on every
  response. The mockup uses inline styles throughout; the port needs classes
  in `style.css`. Check the policy before choosing how tabs are rendered.
- **Install pinning.** Any change to the page, the web service, the applier
  or their units fails `stage-access.sh` and `test-access.sh` until
  `install/dev-unit/access.sha256` is re-pinned. `install-access.sh` lists
  the web binaries it will upgrade from (1.7.0 and 1.7.1). A Pi on 1.7.2
  needs no entry there while the bundle's web service is still 1.7.2: a
  file that is already the bundle's counts as installed, and a bundle with
  a newer page replaces the page alone (`test-access.sh` has the case).
  When the web service itself changes (phase 2), add the hash it replaces,
  5b374f74, to that list. Corrected 2026-11-16: this paragraph first said
  the list had to be extended for 1.7.2.
- **Model version.** Phase 1 stays on preset model v2. Speaker sets, trims
  and sources are a v3 with a migration, when the engine can carry them.
- **Budget.** Phases 4 to 6 spend the DSP budget. They may not all fit at
  96 kHz.
- **Stale documents noticed by the surveys.** `web-control/README.md` opens
  with statements that predate the apply routes; `docs/web/ACCESS.md` says
  nothing has been run on a Pi; `web-ui/stage-page.sh` is an older page-only
  copy script.

## Acceptance

- **Phases 1 and 2** leave the audio path alone: behavioural checks, a noise
  probe at 32, and `measure-candidate.sh soak 120 32`.
- **Phases 3 onward** change the audio path: four loaded 800-impulse runs
  and a ten-minute sixteen-channel soak, with `dsp_us_max` recorded.
- **Every phase:** `node --test web-ui/*.test.mjs`,
  `node --test dsp-compiler/*.test.mjs`,
  `python3 -m unittest discover -v -s web-control -p 'test_*.py'`,
  `install/test-render.sh`, `install/dev-unit/test-access.sh`.

## The mockup

`docs/web/mockup/` holds the design as last published on 2026-11-16:

- `Main.dc.html`: the page frame and all the behaviour (one class,
  `renderVals()` computes everything the tabs show).
- `Status`, `ControlRoom`, `Outputs`, `Sources`, `Routing`, `Buses`
  (Speakers & headphones), `Bass`, `Chooser` (new preset and layout),
  `System`: the layout of each tab.
- `canvas.json`: the design canvas index.

They need the design tool's own runtime to run and will not open as plain
web pages. Read them for layout, wording, sizes and the behaviour of each
control.

What in the mockup is invented and must not be taken as fact: every signal
level and meter movement, the processing budget percentages, the split
between "heard as you change it" and "needs a restart", the fold-down
behaviour, the 50 ms delay range, the caps of eight sources and four input
EQ bands, the downmix defaults, uptime, temperature and log lines, and every
System action's timing.
