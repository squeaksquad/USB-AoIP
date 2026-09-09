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

**End-to-end through the engine**, file-to-file with staggered impulses
(`verify-run.py`), on an identity-routed preset:

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

### Not yet verified end to end

The unit tests pin the emitted mixer gains and filter parameters, and the engine
run above proves the engine applies them, but these have **not** been measured
through the engine:

- **Bass matrix and LFE gain.** Sub summing with crossovers active needs a
  low-frequency tone rather than impulses, because an 80 Hz LR4 impulse rings far
  past the 1000-sample window this harness uses.
- **Band response.** That the emitted biquads produce the designed magnitude
  needs a sweep or tone set compared against `bandResponse` in `model.mjs`.
- **Coherent worst case with all channels driven**, and true output clipping.
- **Anything about CPU cost, latency, or running against ALSA devices.** No
  timing claim is established by this compiler.

`verify-run.py` runs on the Pi because that is where the pinned engine version
is. It opens no audio device; it reads and writes files. Runs are kept short and
the bridge was unchanged across every run in this pass (recoveries 3, PCM
restarts 2/1, queue floors 28/66).
