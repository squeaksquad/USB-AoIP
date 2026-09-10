# DSP mode inside the bridge — step 4 design

Status: **measured under the transport, not installed.** The stage is wired into `usb-to-ravenna`, the bridge reports what it costs,
and audio has now been carried through it for 360 seconds on the accepted
profile. The pinned binary and the installed service are untouched, and the
supervisor still pins the old hash.

See "MEASURED 2026-09-10: the budget" at the end for what the numbers turned
out to be. Where they contradict what this note predicted, the measurement
wins and the prediction is marked.

Step 4 of the delivery sequence in `work/web-ui/README.md` is the isolated DSP
service. This note decides where the engine sits, and says what that costs, what
it risks, and what would have to be true before any of it is accepted.

## The decision

**The filtering goes inside the bridge process.** The bridge gains a filter
stage; the compiler's output becomes something the bridge loads rather than a
configuration handed to a separate engine.

Three alternatives were weighed and rejected:

| Option | Why not |
| --- | --- |
| CamillaDSP replaces the bridge on the DSP path | Discards the pitch servo, the aligned start, the TX prime and the sd103 sink-delay floor — every measured thing between 1127 and 719 — and substitutes clock handling nobody has measured. |
| `snd-aloop` between the bridge and CamillaDSP | Keeps the bridge intact but inserts a loopback buffer pair each way and creates a third PCM owner to sequence on every mode change. It adds latency to a project whose entire history is removing it. |
| AoIP → DSP → AoIP as the first mode | Genuinely the lowest-risk *first* mode and worth building later, but it does not advance the USB path, and its supervision needs are largely disjoint (see below). |

What makes the chosen option affordable is measured, not assumed: run
`load-20260910T165857Z` puts the full acceptance load — 16 outputs, 256 bands,
26 crossovers — at **0.0607 cores at 1024-frame chunks and 0.0923 at 48**, the
quantum the bridge already works in. See `work/dsp-compiler/README.md`.

## Where the stage goes

One place, on the playback side of one direction.

`render_to_playback()` in `src/main.cpp:1373` fills
`direction.playback_scratch` from the resampler at `src/main.cpp:1655`, then
converts to the device format in the loop at `src/main.cpp:1671`. The filter
stage sits between those two: after the resampler has produced `frames`, before
`exceeds_full_scale()` and `write_area_sample()` see anything.

That position is chosen for four reasons.

- `playback_scratch` is already a fixed `std::array<float, kScratchFrames *
  kChannels>` (`src/main.cpp:1098`), sized at construction. No allocation is
  introduced on the audio path.
- Clipping is already counted at exactly this point, so a preset that drives an
  output over full scale is caught by the counter that exists
  (`clipped_samples`), through converters that were fixed in 2026-09-02 to round
  before clamping rather than wrap.
- It is per-`Direction`, so `tx` (usb-to-ravenna) can carry the DSP while `rx`
  stays a pass-through, which is what "USB → DSP → AoIP" means.
- It is downstream of the resampler, so with the pitch servo engaged and both
  converters at exactly 1.0, the filter sees the same samples the USB host sent.

The one structural change: the pipeline is 16 in → *N* internal → 16 out, where
N is 26 for the acceptance preset. The stage therefore needs its own internal
buffer of `kScratchFrames * kInternalChannelsMax` floats, sized once at load
time and never resized on the audio path.

## What crosses from the compiler

**The bridge does not parse YAML.** `usb16x16-dsp-compile` gains a second
output: a flat, deterministic coefficient artifact — biquad coefficients,
mixer gains, delays and the channel map, in a fixed layout the bridge reads
without a YAML library and without allocating per-filter.

The CamillaDSP YAML stays exactly as it is, and that is the point. It is the
artifact that has been verified against a real engine — routing, delay,
polarity, gain, mute, the bass matrix, LFE trim, PEQ magnitude against the UI's
own curve, crossover magnitude, phase and summation, and behaviour at full
scale. Keeping both outputs from one compiler means:

> **The bridge's own filtering can be checked against CamillaDSP, file to file,
> on the same preset, sample for sample.**

That is the strongest verification available here, and it is only available
because the engine work in step 3 was done first. A `--dsp-offline` mode on the
bridge that reads a raw file, runs the filter stage, and writes a raw file
would let `verify-run.py`, `verify-tone.py`, `verify-response.py`,
`verify-crossover.py` and `verify-clip.py` be pointed at the bridge instead of
at CamillaDSP, with no change to any of them beyond the binary they invoke.
Agreement to the sample is then a claim that can be made rather than hoped for.

The two outputs must be generated from one compilation, not two, so they cannot
disagree; the report should carry a hash of each.

## The real-time budget, which is the risk

This is the part that decides whether the design survives contact.

The bridge's audio thread has about **1 ms** of wall time per cycle at a
48-frame period. CamillaDSP's implementation of the acceptance load costs
**92 µs of CPU per 1 ms of audio**. If the bridge's own implementation lands
anywhere near that, steady-state duty is under 10% and there is room.

**The aligned prime is the acute case, and it does not have that room.** The
comment at `src/main.cpp:80` records the prime path — the drop, the PRIMED
line, the 192-frame render, the commit — at about **104 µs**, inside a
placement margin of 150 µs, leaving **46 µs of slack**. A 192-frame render is
4 ms of audio; at 92 µs per millisecond that is roughly **369 µs of filtering**,
which would miss the prime target every single time. A missed target moves the
start to the next tick, one period later, which is precisely the aligned-start
behaviour the accepted operating point rests on.

So the design has a hard constraint:

- **The prime render must not filter.** The prime fills the queue at start;
  it can run bypassed, with the filter stage engaged after the aligned start
  has been taken and reported. This needs care so that the transition itself
  is not a discontinuity — the first filtered block starts from zeroed filter
  state, which is a transient at a point where the stream is already starting.
- **Steady-state cost must be measured on the bridge's own implementation,
  not inherited from CamillaDSP's.** 92 µs/ms is a plausible order of
  magnitude and nothing more. A per-cycle worst-case timing, reported the way
  the bridge already reports its stage timings, is a precondition for
  acceptance and not a thing to discover in a soak.
- **The margin is a latency term.** Raising `kAlignPrimeMarginNs` to buy room
  would pay for the DSP in exactly the currency the project is trying to save.
  It is not the answer.

## Coefficient updates

The audio thread must never allocate, never take a lock that a non-audio thread
holds, and never see a half-written coefficient set.

Two coefficient sets are held. A control thread fills the inactive one and
publishes it with a single release store of an index; the audio thread reads it
with an acquire load once per block and uses that set for the whole block. The
retired set is not freed until the audio thread has been observed to have moved
past it. Filter *state* is separate from coefficients and stays with the audio
thread; a coefficient swap does not reset it, so a gain change does not click.

Changing the pipeline *shape* — the channel count, the routing, the number of
active bands — is not a live operation. It stops the filter stage, swaps, and
restarts it, and the UI must say so. This is the `restart requirement` the
application contract in `work/web-ui/README.md` already anticipates.

## Mode and rollback

Direct mode is not a preset with everything switched off. It is the absence of
the stage: a single check per block, and when the stage is not loaded the
`playback_scratch` buffer is not read or written by it at all. The accepted
profile must be byte-identical in behaviour to today's with no preset loaded,
and that is testable — the same measurement, the same figure, on a build that
contains the stage.

The protected USB baseline is untouched. The bridge binary changes, so the
supervisor's pinned bridge hash changes with it, and the previous binary stays
in `artifacts/pi-aarch64/` as the rollback, per the existing rules.

## What this design does not cover

- **AoIP → DSP → AoIP.** Worth building, but its supervision is largely a
  separate problem: the existing supervisor's failure model is built around
  the USB host — the storm detector, the frozen-input detector, `host_absent`
  waiting on `dwc2 ... new device` kernel lines at
  `work/aes67-bridge/usb16x16-aes67-supervisor:846`, and the 60 s retry. A mode
  with no USB host does not need that gate relaxed so much as it needs its own
  supervision path, or a mode flag threaded through four separate detectors.
- **The `--target alsa` device section**, which stays stamped unvalidated. This
  design does not use it: the bridge owns its own devices already.
- **Metering.** Still needs the separately benchmarked tap the web-control
  README asks for. The filter stage is a natural place to take it from, and a
  natural place to make the audio thread late.
- **Apply from the UI.** Step 5. Nothing here exposes a control surface.

## Acceptance

Nothing is accepted on a page loading or a figure looking plausible. The
existing rules apply unchanged, plus what is specific to this stage:

1. The bridge's filter stage agrees with CamillaDSP sample for sample on the
   same preset, through all five existing harnesses.
2. With no preset loaded, the accepted profile measures what it measures today:
   four loaded 800-impulse runs and a ten-minute sixteen-channel soak, RTL at
   32 frames on a fresh anchor, against the current 719 / 18.896 ms.
3. With the acceptance preset loaded, the same battery, with the alignment
   delay zeroed so the preset's own delay is not read as transport latency.
4. A per-cycle worst-case timing for the filter stage, reported by the bridge,
   with the aligned prime shown to make its target.
5. Zero RECOVERs attributable to the stage; queue floors and the Phase 6 gap
   bar unchanged within their existing spread.
6. 0 dBFS material passes without a click, which is the standing requirement
   and the reason the converters were fixed in the first place.

## Open questions

- Does the bridge implement biquads directly, or link CamillaDSP as a library?
  Direct implementation is a few hundred lines, has no dependency, and can be
  made branch-free per sample; linking inherits an implementation already proven
  to match the UI's curve but drags in a Rust toolchain and its own threading.
  The cross-check above makes direct implementation verifiable, which is what
  made it seem too risky before.
- Where does the alignment delay live? A preset delay of up to 10 ms is 480
  frames of buffering that the transport does not currently carry, and it
  interacts with the queue depths the profiles are tuned around.
- Does the filter stage belong on `tx` only, or should `rx` carry a bypassed
  instance so the two directions stay structurally identical?


## MEASURED 2026-09-10: the budget

`usb16x16-dsp-offline --bench`, 20,000 calls per block on the Pi with the
service stopped, on the `loaded` preset -- 16 outputs, 256 PEQ bands, 26
crossovers, 308 biquads in total. In memory, no file and no device.

| Block | Audio | Median | p99 | Max | Worst-case duty |
| --- | --- | --- | --- | --- | --- |
| 48 frames | 1000 µs | 67.8 µs | 69.4 µs | 111.5 µs | 11.1% |
| 96 | 2000 µs | 139.6 µs | 145.3 µs | 182.0 µs | 9.1% |
| 192 | 4000 µs | 267.1 µs | 269.1 µs | 301.8 µs | 7.5% |
| 512 | 10667 µs | 733.9 µs | 741.1 µs | 822.3 µs | 7.7% |

**Steady state fits with room to spare.** At the bridge's own 48-frame quantum
the stage takes 67.8 µs of a 1000 µs cycle, 111.5 µs at its worst. The
bridge's existing render path is around 104 µs for a 192-frame prime, so a
48-frame cycle's own work is a fraction of that: the whole cycle lands near a
tenth of its budget.

**The prime still cannot filter, and now that is measured rather than
projected.** A 192-frame filtered render costs 267 µs median and 302 µs worst
against 46 µs of slack. With the render path's own 104 µs the prime would take
about 371 µs into a 150 µs margin and miss its target every time, moving the
aligned start a period later. The bypass is a requirement, not a precaution.

The bridge's own implementation is cheaper than the reference engine's per unit
of audio -- 67.8 µs per millisecond against CamillaDSP's 92 -- which is the
expected direction for a fixed pipeline with no format negotiation, and is not
a claim about CamillaDSP.

### What these numbers are not

An idle Pi, a buffer already in cache, no SCHED_FIFO contention, no interrupts,
and no other direction competing. Every one of those makes this an
underestimate of what the audio thread actually pays. It answers "can the stage
fit in a cycle at all", which was the question blocking the design, and it does
not answer "does the cycle hold its deadline".

That second question is what `dsp_us_max` in the BRIDGE line and the SUMMARY
JSON exist for. It is the maximum, never the mean, because a mean hides exactly
the cycle that missed. Until a candidate session has reported it under load,
nothing here is an acceptance.


## MEASURED 2026-09-10: 360 seconds with the stage carrying audio

Run `phase4-dsp-candidate-20260910T180122Z`, candidate bridge `406699bd` with
the `loaded` preset (308 biquads), the accepted profile's argument list taken
verbatim from the supervisor's journal, sink delay 103. The installed binary
and the service were not touched.

| | This run | Accepted profile |
| --- | --- | --- |
| RECOVERs | **0** | 0 |
| Direction restarts | 0 / 0 | 0 / 0 |
| TX queue floor | 86 | 75–81 across the set, 78 cited |
| RX queue floor | **72** | 72 |
| `tx_qlow` / `rx_qlow` | 0 / 0 | 0 / 0 |
| `tx_occ` / `rx_occ` | 51 / 51 | 51 / 51 |
| Clipped samples | 0 / 0 | — |
| Dropped frames | 0 / 0 | — |
| Zero-run events | 0 | — |

**The stage cost, from the bridge's own instrumentation:** `dsp_us_max`
**105.6 µs**, mean 52.0 µs, over **473,226 calls** and 17,276,790 frames --
47,991 frames per second, so essentially every frame went through it. The
maximum settled by about 68,000 calls and never moved again; the mean fell from
60 µs to 52 µs as the run settled.

The bridge renders what `mmap_begin` grants, which averaged **36.5 frames per
call**, not a full period. So each call had about 760 µs of wall time and used
52 µs of it, 105.6 µs at worst: a **worst-case duty of 13.9%**.

**The in-memory benchmark was not the underestimate I called it.** Scaled to
36.5 frames it predicted 51.6 µs where the bridge measured 52.0, and its
worst case of 111.5 µs was *higher* than the 105.6 µs seen on the real audio
thread. The likely reason is that the benchmark ran at normal priority while
the bridge runs SCHED_FIFO at 90, so the benchmark's tail was scheduling noise
the bridge does not suffer. The caveat stands in principle -- an idle Pi is not
a loaded one -- but it did not bite here.

**The aligned start was undisturbed.** `ALIGN status=ok`, and the TX trigger
made its target with `slack_us=412`. The TX prime read `front_age_frames=296`
and `under_prime=0`, which is exactly the figure the age50 profile is
documented to produce. The prime bypass works: `DSP engaged` is logged at
t=5045 µs against the TX `PRIMED` at t=4054 µs, so the stage came in on the
very next render after the prime, as designed.

### What this run does not establish

It was **unloaded**: no harness driving impulses, no measurement of the round
trip. The TX floor of 86 is therefore not comparable with the accepted 78,
which was taken through four 800-impulse runs and a soak -- an unloaded floor
sits higher, and 86 is consistent with that rather than with an improvement.

No latency figure was taken, and none should be inferred. Acceptance still
needs the full battery in this note's Acceptance section: the loaded runs, the
soak, RTL at 32 on a fresh anchor with the preset loaded and the alignment
delay zeroed, and the same again with no preset to show direct mode still
measures what it measures today.
