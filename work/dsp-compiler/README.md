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
```

Exit status is `0` on success, `1` when an output can clip (the configuration is
still written), `2` for bad arguments, `3` for an unreadable preset, `4` when the
preset cannot be compiled.

`--target file` (the default) emits `RawFile`/`File` devices for offline
verification. `--target alsa --capture DEV --playback DEV` emits ALSA devices and
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

**End-to-end through the engine**, file-to-file. Three harnesses, because no one
signal checks everything: `verify-run.py` uses staggered impulses for the
per-output processing, `verify-tone.py` a low-frequency tone for the sub path
(an 80 Hz LR4 low-pass rings far past any window short enough to keep one
input's response out of the next), and `verify-response.py` a single impulse
whose DFT gives the whole PEQ magnitude response with no settling to wait out.

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

### Not yet verified end to end

The unit tests pin the emitted mixer gains and filter parameters, and the engine
runs above prove the engine applies them, but these have **not** been measured
through the engine:

- **Crossover magnitude and phase** as such. The tone test measures the sub path
  at one frequency well inside the passband; the shape of the Linkwitz-Riley
  response, and the phase behaviour that decides whether branches sum, are not
  measured.
- **True output clipping** at the sample level. The coherent sum was measured
  well below full scale on purpose; what the engine does at and past 0 dBFS is
  untested.
- **Headphone bus paths**, pair and downmix, through the engine.
- **Anything about CPU cost, latency, or running against ALSA devices.** No
  timing claim is established by this compiler.

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

It coincided with the band-response runs. Causation is not proven, but the
262,144-frame F64 capture written just before it is 33.5 MB of output, far
outside the "keep runs short" discipline the rest of this file claims. The
lesson is in the harness now: `verify-response.py` truncates each channel's sum
where its response has decayed, so the *analysis* is cheap, but the **capture**
still costs whatever it is told to cost. Size it from the slowest band under
test — 262,144 frames was chosen without checking that 131,072 would do — and
prefer running these between measurement sessions, not during one.

The measurements themselves stand: the band-response run completed before the
RECOVER, and the figures below were taken from it.

---

All three harnesses run on the Pi because that is where the pinned engine version
is. They open no audio device; they read and write files. That is not the same as
being free: see the correction above.
