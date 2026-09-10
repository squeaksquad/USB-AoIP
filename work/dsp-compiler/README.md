# `usb16x16-dsp-compile` — preset to CamillaDSP

Turns a USB 16x16 UI preset into a CamillaDSP configuration. Step 3 of the
delivery sequence in `work/web-ui/README.md`.

Offline and inert. It reads a preset, writes YAML and a JSON report, and exits.
It does not talk to the Pi, start an engine, own a PCM device, or apply
anything. Nothing in this directory is installed on the Pi.

## Use

```sh
node --test work/dsp-compiler/*.test.mjs
work/dsp-compiler/usb16x16-dsp-compile preset.json -o config.yml --report report.json
work/dsp-compiler/run-verifications.sh          # the engine runs, on the Pi
```

Exit status is `0` on success, `1` when an output can clip (the configuration is
still written), `2` for bad arguments, `3` for an unreadable preset, `4` when the
preset cannot be compiled.

`--target file` (the default) emits `RawFile`/`File` devices for offline
verification. `--format` takes a name the engine knows, which is not the ALSA
spelling: CamillaDSP 4.1.3 accepts `S16_LE`, `S24_4_RJ_LE`, `S24_4_LJ_LE`,
`S24_3_LE`, `S32_LE`, `F32_LE` and `F64_LE`, and rejects the configuration
outright otherwise. The two defaults are both on that list; `F64_LE` is what
the DFT-based harnesses want. `--target alsa --capture DEV --playback DEV` emits ALSA devices and
stamps the file with a warning: **capture/playback selection, clock ownership and
rate matching have not been validated**, and the accepted transport is still the
existing bridge.

## Pipeline shape

```
16 capture channels
  -> expand mixer   headroom trim; one internal channel per branch actually used
                      main   = an input, later high-passed
                      bass   = an input, later low-passed (LFE uses its own LP + trim)
                      phones = an input pair member, or a downmix sum, full range
  -> branch filters the crossover (BiquadCombo Linkwitz-Riley)
  -> assign mixer   internal channels -> the 16 outputs, with sub sends and bus level/mute
  -> output filters 16 PEQ bands (Biquad), alignment delay, gain/polarity/mute
  -> 16 playback channels
```

Two things follow from this shape and are worth stating:

- **Crossovers never consume one of the user's 16 PEQ bands.** They live on the
  branch channels, upstream of the assign mixer; the bands live on the physical
  outputs, downstream of it.
- **Filter steps before `assign` index internal channels; steps after it index
  physical outputs.** The two numberings overlap and are told apart only by
  position in the pipeline. The generated file says so in its header and lists
  the internal channel map.

Only branches something consumes are allocated. The default 7.2.4 preset uses 23
internal channels (11 main, 12 bass); inputs 13–16 drive nothing there and cost
nothing. Two outputs sharing a speaker source share one main branch.

## Headroom policy

`headroomDb` is applied **exactly once**, in the expand mixer, to every branch of
every input. Nothing downstream re-applies it. The LFE trim is applied once too,
on the LFE bass branch only. Sub sends, bus gain and output gain all come after,
so a preset can still be driven into clipping.

`worstCaseDbfs` in the report is the coherent full-scale sum at each output: a
sum of magnitudes that ignores filter response, phase, and the fact that real
content is not coherent. It is a **ceiling**, so an output it calls safe cannot
clip from summing alone; it is not a measured or true-peak figure. Any output
over 0 dBFS is named in the warnings and sets exit status 1. The default preset's
subs reach −2.43 dBFS, which is the −18 dB trim doing its job.

## What the compiler will not decide for you

- **12 dB/oct Linkwitz-Riley.** Its two branches sit 180° apart at the crossover
  frequency, so main and sub usually need opposite polarity to sum. The compiler
  warns and **inverts nothing**. Set polarity per output and verify acoustically.
  The same note appears in the UI's Bass management panel, from the same module
  (`work/web-ui/crossover-notes.mjs`), so the two cannot drift. That module also
  decides which crossovers are *active*: a 12 dB/oct slope on an input that
  drives nothing is not flagged, and the LFE branch is scored on the LFE
  low-pass slope rather than its input row's.
- **Devices.** `compile()` requires a devices section from the caller. Choosing
  capture and playback is an integration decision the compiler has no basis to
  make.
- **Applying anything.** There is no apply path, here or in `work/web-control`.

## Verification

Unit tests (30) cover the compiled structure: branch allocation and sharing,
headroom and LFE trim applied once, send gains, crossover/PEQ separation, slope
to Linkwitz-Riley order, flat and disabled bands emitting nothing, EQ bypass,
whole-sample delay, gain/polarity/mute, silent unused outputs, bus gain and mute,
bass redirection off, full-range mains keeping their sends, headphone pair and
downmix modes, worst-case arithmetic and clipping warnings, direct-mode refusal,
determinism, and that every mixer source and filter name resolves.

Against the **real engine, CamillaDSP 4.1.3 (05e9cfc) on the Pi**, `--check`
accepts eight presets: the default, one with all 256 bands shaped plus delays,
inverts and gains, LR12, LR48, bass off, EQ bypass, a headphone downmix, and a
deliberately clipping one.

**End-to-end through the engine**, file-to-file. Five harnesses, because no one
signal checks everything: `verify-run.py` uses staggered impulses for the
per-output processing, `verify-tone.py` a low-frequency tone for the sub path
(an 80 Hz LR4 low-pass rings far past any window short enough to keep one
input's response out of the next), `verify-response.py` a single impulse whose
DFT gives the whole PEQ magnitude response with no settling to wait out,
`verify-crossover.py` the same impulse kept complex, so the crossover's phase
and the sum of its two branches can be read as well as their magnitudes, and
`verify-clip.py` a full-scale signal, which is the only way to ask what the
engine does when a preset is driven past 0 dBFS.

The presets these run on are built by `verify-presets.mjs` and pinned by
`verify-presets.test.mjs`. The earlier runs used ad-hoc presets that were not
kept, so their figures could not be reproduced without rebuilding the preset by
hand; these can be. `run-verifications.sh` compiles them on the Mac -- the Pi
has no node -- stages the configurations and harnesses, and runs the three
outstanding verifications in one pass. It refuses to run while
`usb16x16-aes67.service` is up, for the reason in the correction below.

Impulses, on an identity-routed preset:

| Property | Expected | Measured |
| --- | --- | --- |
| Routing | out *j* ← in *j* | exact, one event per output |
| Channel isolation | no leakage | exactly one event per output, no other input's window |
| Shared source | out 7 ← in 1 | fired in input 1's window |
| Delay 10 ms | +480 samples | sample 2480 (impulse at 2000) |
| Delay 2.5 ms | +120 samples | sample 6120 (impulse at 6000) |
| Polarity invert | ratio −1 | −1.000000 |
| Gain −6 dB | ratio 0.501187 | 0.501187 |
| Mute | silence | no events |

Tone, on the default 7.2.4 preset with an LFE trim of −4 dB, driving one input
per segment at 20 Hz and −12 dBFS, then several in phase:

| Property | Expected | Measured |
| --- | --- | --- |
| Send at 0 dB (5 inputs per sub) | −18.00 dB rel drive | −18.034 |
| Send at −6 dB (centre) | −24.00 | −24.034 |
| LFE: −6 dB send **and** −4 dB trim | −28.00 | −28.007 |
| Matrix isolation | inputs 1,5,7,9,11 → sub 4 only; 2,6,8,10,12 → sub 13 only | exact, no leakage |
| Inputs 13–16 | silent everywhere | silent |
| Main outputs at 20 Hz | −18 trim − 48.20 HP = −66.20 | −66.2 |
| Coherent sum of 7 inputs | ≤ compiler's −2.71 dBFS ceiling | −2.751 dBFS |

The residuals are not slop: −0.034 dB is exactly the analytic LR4 low-pass
passband loss at 20 Hz for an 80 Hz corner, and −0.007 dB is the same figure for
the LFE's 120 Hz corner. That the LFE reads −0.007 and not −0.034 is independent
evidence the LFE branch uses its own low-pass. The coherent sum lands 0.04 dB
*below* the reported ceiling, which is the direction a ceiling should err.

Band response, on a preset shaping each output differently, comparing the
engine's magnitude against `eqResponse` in `work/web-ui/model.mjs` at 50
frequencies from 20 Hz to 20 kHz — 800 comparison points:

| Output | Configuration | Max deviation |
| --- | --- | --- |
| 1 | flat control | 0.0000 dB |
| 2–4 | bells: +6 @1k Q1, −9 @100 Q2, +3 @8k Q4 | 0.0000 dB |
| 5–6 | low shelves: +6 @100 Q0.707, −6 @200 Q1 | 0.0000 dB |
| 7–8 | high shelves: +6 @5k Q0.707, −6 @3k Q1.5 | 0.0000 dB |
| 9 | three overlapping bells | 0.0000 dB |
| 10 | extremes: +18 @40 Q6 and −18 @12k Q0.5 | 0.0000 dB |
| 11 | all 16 bands shaped, 13 active | 0.0000 dB |
| 12 | bands shaped but output EQ switched off | 0.0000 dB (flat) |
| 13 | one disabled +12 dB band among enabled ones | 0.0000 dB (absent) |

Worst deviation anywhere: **5×10⁻⁵ dB**. The engine's `Peaking`, `Lowshelf` and
`Highshelf` biquads therefore use the same W3C cookbook **Q** parameterization as
the curve the UI draws — the shelf convention was the real risk here, since the
cookbook also defines shelves by slope S, and a mismatch would have made the UI's
plot quietly wrong.

A trap worth recording: at a 16,384-sample capture, output 10 read 0.62 dB low at
exactly its 40 Hz band centre. That was the measurement, not the engine — a
+18 dB Q6 band at 40 Hz needs about 110,000 samples to decay, and truncating an
IIR response biases it low, worst at the centre where it looks most like a real
disagreement. `verify-response.py` now reports `truncated` per output and warns
on stderr, so a short capture cannot be mistaken for a discrepancy again.

### MEASURED 2026-09-10: crossover, full scale and the headphone buses

The three gaps above are closed. Run `dsp-verify-20260910T164810Z`, CamillaDSP
4.1.3 (05e9cfc) on the Pi, `usb16x16-aes67.service` stopped for the duration,
RECOVER count 3 before and 3 after. The headphone table was measured in the
preceding run of the same afternoon and is identical.

Each harness was first exercised on the Mac against purpose-built stand-in
engines -- one that saturates and one that wraps, and independent
re-implementations of the Linkwitz-Riley cascades and the phones mixers -- so
that a pass was known to be distinguishable from the failure being looked for
before the engine was asked anything.

**Crossover magnitude, phase and summation**, four pairs in one run:

| Outputs | Crossover | At Fc | Phase difference | Main slope | Sub slope | Sum |
| --- | --- | --- | --- | --- | --- | --- |
| 1, 2 | LR4 @ 80 Hz | −6.0206 / −6.0206 | 0.0° | 24.081 | 24.141 | flat, 0.0 dB |
| 3, 4 | LR2 @ 80 Hz | −6.0206 / −6.0206 | 180.0° | 12.035 | 12.539 | **−202.76 dB at 80 Hz** |
| 5, 6 | LR2 @ 80 Hz, sub inverted | −6.0206 / −6.0206 | 0.0° | 12.035 | 12.539 | flat, 0.0 dB |
| 7, 8 | LR8 @ 200 Hz | −6.0206 / −6.0206 | 0.0° | 48.132 | 48.179 | flat, 0.0 dB |

Rows 2 and 3 are the same crossover differing only in the sub's polarity. Every
branch is −6.02 dB at its corner and the two sit exactly 180° apart, so matched
polarity cancels to −202.76 dB -- double-precision zero -- and inverting the sub
returns a flat sum. **The 12 dB/oct advisory the compiler and the UI both carry
is now a measurement rather than received wisdom**, and 24 and 48 dB/oct are
confirmed not to need it.

Against the analytic Linkwitz-Riley model -- a Butterworth of half the order,
applied twice, bilinear-transformed -- the deviation is **0.0 dB** on all eight
branches, over 45 to 85 comparison points each above a −80 dB floor. That
settles a question the unit tests could only assume: CamillaDSP's `order`
parameter is the Linkwitz-Riley order, not the Butterworth order the combo is
built from, which is what `SLOPE_ORDER` in `compile.mjs` maps 12/24/48 dB/oct
onto.

The sub slopes read a little steep (12.539 where 12 is the asymptote). That is
the measurement geometry, not the filter: the low-pass octave sits high enough
that the bilinear transform's frequency warping has begun to steepen it. The
high-pass slopes, measured at 1.25–100 Hz where there is no warping to speak of,
read 12.035, 24.081 and 48.132. That the analytic *digital* model agrees to
0.0 dB is what settles which of the two it is.

**Behaviour at and past full scale.** Not a theoretical worry: the bridge had
this exact defect, and it was audible. `float_to_s32` rounded before it clamped,
so `0.9999999999999999 * 2^31` became `2147483648`, and the `int32_t` cast turned
that into negative full scale -- a click on every clipped peak of 0 dBFS
material, gone at −3 dB. The engine does not share it.

| Output | Path | Result |
| --- | --- | --- |
| 1 | unity from input 1 | **bit transparent**, 24,240 of 24,240 samples, including at ±full scale |
| 2 | +6 dB from input 2 | 16,099 samples saturated, 0 wrapped |
| 3 | +12 dB from input 3 | 20,281 saturated, 0 wrapped |
| 4 | four inputs summed | 20,137 saturated, 0 wrapped, peak internal +12.041 dBFS |
| 5 | unity from input 8, inverted | 40 rail samples saturated correctly, 0 wrapped |

Every clipped output lands exactly on both rails, −2147483648 and 2147483647,
which is the signature of saturation; a wrapping converter never reaches either.
Output 5 is the one that matters most: the integer range is asymmetric, so
negating −2³¹ asks for a value that does not exist, and the engine returns
+2147483647 rather than folding back to negative. Note that output 1 stayed bit
transparent under *both* stand-ins, saturating and wrapping alike -- a unity
path alone would not have caught this class of bug.

Two things worth carrying into the service work. The engine **counts and reports
clipping itself**: `Clipping detected, 2369 samples clipped, peak +12.04 dB
(400.0%)`, per chunk, on stderr. An Apply operation has that available without
adding a meter. And its measured peak of +12.04 dB is the same number
`worstCaseDbfs` predicted for that output, +12.04 dBFS, which is an independent
check on the ceiling arithmetic rather than a restatement of it.

**Headphone bus paths**, both source modes in one run, with a 2.5 ms delay on
one output and a polarity invert on another so the per-output stage is exercised
on a phones path rather than assumed to behave as it does on a speaker path:

| Output | Bus | Measured |
| --- | --- | --- |
| 1 | pair, ear 1 | in1 at 1000, −9.000 dB |
| 2 | pair, ear 2 | in2 at 2120, −9.000 dB — the 120-sample delay, exactly |
| 3 | downmix L, bus −3 dB | in1 −12.000, in3 −15.000, in4 −18.000, in5 −13.500, in7 −21.000 |
| 4 | downmix R, bus −3 dB, inverted | in2 −12.000, in3 −15.000, in4 −18.000, in6 −13.500, in7 −24.000, all inverted |
| 5–16 | — | silent |

Every value is exact. Input 2 is absent from the left ear and input 1 from the
right, so the matrix is using the column it should; a downmix that quietly read
the wrong one would still have looked plausible on level alone. Crossovers are
switched on at the inputs even though a phones bus is pre-crossover, and every
event came back as a single unrung impulse, which is the evidence that the
crossover never reached this path.

### MEASURED 2026-09-10: what the configurations cost the Pi

Run `load-20260910T165857Z`, same engine and conditions: service stopped, four
cores at the performance governor and 2.4 GHz, otherwise idle, 47 °C at the
start. `measure-load.py` runs two durations and reports the *marginal* cost of
the audio between them, because a fast configuration finishes a short file in
less time than the process takes to start and the measurement would otherwise
be a measurement of process startup.

| Configuration | Chunk | Cores needed | Realtime factor | Peak temp |
| --- | --- | --- | --- | --- |
| `default` — routing and 23 crossovers, every band flat | 1024 | 0.0184 | 54.4× | 50.1 °C |
| `loaded` — 16 outputs, 256 bands, 26 crossovers | 1024 | 0.0607 | 16.5× | 49.0 °C |
| `loaded` | 256 | 0.0640 | 15.6× | 50.1 °C |
| `loaded` | 48 | 0.0923 | 10.8× | 51.2 °C |

`loaded` is the acceptance criterion in `work/web-ui/README.md` built as a
preset: every output active, all 256 bands shaped, crossovers and multiple sub
sums, with the bands varied in type, Q and sign so no shortcut a uniform filter
might allow can flatter the result.

Three things follow.

**The Pi is not the constraint.** The full acceptance load costs about **6% of
one core**, and 9% even in 48-frame chunks — the quantum the bridge already
works in. The 12.288 million biquad evaluations per second the sizing
arithmetic in `work/web-ui/README.md` predicted are real, and they cost about
0.042 cores between the two rows: roughly 0.16 millicores per biquad. Nothing
about step 4 needs to be designed around processing cost.

**Small chunks are affordable.** Going from 1024 to 48 frames costs 0.032
cores, about half as much again in relative terms and almost nothing in
absolute ones. A low-latency DSP mode does not have to trade chunk size against
CPU on this hardware.

**None of this is a latency result.** File to file has no period deadlines, no
interrupt contention, and no bridge competing for cores or IRQs; the numbers are
an upper bound on throughput and a necessary condition, not a demonstration that
a deadline can be held. `coresNeeded` is the sum across CamillaDSP's threads,
which is why it can exceed what the wall-clock factor alone would suggest.

RECOVER count was 3 before and 3 after, and nothing was throttled.

### MEASURED 2026-09-10: the bridge's own stage against CamillaDSP, on the Pi

Run `headtohead-20260910T173732Z`. Both engines on the same machine, on the
same input files, from the same compilation of the same preset -- the YAML for
CamillaDSP and the coefficient artifact for the bridge, emitted together so
they cannot describe different pipelines. The bridge core and
`usb16x16-dsp-offline` were built on the Pi for the run; the core suite passes
there as well as on the Mac. Service stopped, RECOVER count 3 before and 3
after.

This compares the raw output files sample by sample rather than the harnesses'
derived numbers, which leaves nowhere for a difference to hide.

| Preset | Format | Frames | Worst difference, relative to the signal that made it |
| --- | --- | --- | --- |
| `crossover` | F64_LE | 16,384 | −145.2 dB |
| `phones` | S32_LE | 19,000 | −151.7 dB |
| `loaded` — 16 outputs, 256 bands, 26 crossovers | S32_LE | 19,000 | −114.1 dB |

The headline number is the wrong one to read on its own, so here is the right
one. **Across all 28 channels of all three runs, no sample differs by more than
one unit in the last place** — one float32 ULP at that channel's own level, or
one LSB of the integer container, whichever is larger. Zero exceptions.

That is as close as two implementations can come without being the same
arithmetic, and they are not: the bridge carries float32 samples through
`playback_scratch` and sums in a different order, while CamillaDSP keeps double
throughout. Bitwise identity was never available. One ULP is the floor.

The `loaded` run's −114 dB looks worse than the others and is not. Outputs 4
and 13 peak at −69.5 and −72.6 dBFS, and their worst difference is −186.6 dBFS,
which is exactly one LSB of the 32-bit container: a rounding tie broken the
other way at the final integer conversion. A quiet channel makes one LSB a
larger fraction of its own peak, which is all that number is saying.

Read through the harnesses instead of sample by sample, the two agree exactly
wherever there is signal to agree about — 0.000 dB at every one of 356
magnitude points above −40 dB, and identical impulse tables for the headphone
buses. The differences appear only below −40 dB and grow in inverse proportion
to level, which is the signature of a precision floor rather than a filter
disagreement.

**What this establishes.** The filtering the bridge would apply is the
filtering that was verified against a real engine in the runs above: the same
crossover corners, slopes, phase and summation, the same band responses, the
same routing and delay and polarity, and the same behaviour at full scale.
**What it does not establish** is anything about the bridge applying it in real
time, which is the whole of the remaining risk and is untouched by a
file-to-file comparison.

### Still not verified end to end

- **Anything about CPU cost, latency, or running against ALSA devices.** No
  timing claim is established by this compiler, and none of the runs above
  establishes one either: they are file-to-file, unclocked, and as fast as the
  Pi can read and write.
- **The `--target alsa` device section**, which remains stamped unvalidated for
  capture/playback selection, clock ownership and rate matching.

### CORRECTION 2026-09-10: an engine run did disturb the bridge

An earlier version of this section said the bridge was unchanged across every
run. That is **withdrawn**. At 2026-09-10T00:20:41Z the bridge took a RECOVER
pair — `ravenna-to-usb playback-avail` and `usb-to-ravenna capture-avail`, both
`Broken pipe` with both PCMs in XRUN, so a system-wide stall rather than one
direction failing. Session recoveries went 3 to 5 and PCM restarts 2/1 to 3/2.
It recovered immediately and none has followed.

Queue floors were untouched (TX 28 / RX 66, depth floors 79/123), but the
re-prime landed deeper: `tx_dmean` moved from about 200–240 to about 260–280. By
the standing rule that the measured level follows the bridge start depth one for
one, a round-trip figure taken now will read high until the next fresh anchor.

It coincided with the band-response runs, and I first wrote that the
262,144-frame F64 capture just before it — 33.5 MB of output — was the likely
cause. **The gap-bar analyser disagrees, and it has better evidence.** It
classifies this as the record's device open/close signature: a both-PCM XRUN
pair meaning a gadget PCM restart, which is a Mac-side open/close of the USB
audio device, not CPU or writeback pressure on the Pi. It is the only such pair
in the 26.3 h session. So the Pi-load attribution is probably wrong, and the
honest statement is that the cause was not established.

The sizing point stands on its own merits regardless: `verify-response.py`
truncates each channel's sum where its response has decayed, so the *analysis*
is cheap, but the **capture** costs whatever it is told to cost. Size it from
the slowest band under test — 262,144 frames was chosen without checking that
131,072 would do — and prefer running these between measurement sessions.

The measurements themselves stand: the band-response run completed before the
RECOVER, and the figures below were taken from it.

---

All three harnesses run on the Pi because that is where the pinned engine version
is. They open no audio device; they read and write files. That is not the same as
being free: see the correction above.
