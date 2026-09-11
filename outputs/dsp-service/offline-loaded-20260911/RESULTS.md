# Loaded channel-4 zero-run diagnosis — 2026-09-11

The pinned loaded DSP and deterministic stimulus reproduce seven consecutive
wire zeros offline without an interruption. The DSP float samples are nonzero;
the run appears when the RAVENNA L24 converter discards the low S32 byte.
This establishes a filter/quantization mechanism sufficient to trip the existing
gate. It strongly supports that explanation for the live observation, but does
not identify the original event: the live run saved no sample neighborhood.
The acceptance battery remains FAILED under its declared gate.

## Method

`work/dsp-service/replay-loaded.cpp` links the unchanged DSP core and bridge
sample converters. It processes 600 seconds at 48 kHz, 16 channels, amplitude
0.1, seed `0x9e3779b9`, excluding the first 96,000 frames from statistics. The
first 32 Float32 stimulus bit patterns match the actual Swift generator. The
308-biquad artifact remains pinned at
`2b6baa0484a7d9a7d7a39f189d772a6864a473163c6e8098723954b652bb456c`.

Two input models were evaluated: Float32 directly, and Float32 rounded through
the bridge S24 converter before DSP. The latter models a nearest-rounded USB
boundary; the actual host conversion policy was not measured. Each starts with
zero filter state and uses 48-frame calls. Output calls `float_to_s32`, then
retains the high three bytes, as the driver's
`MTConvertMappedInt32ToBigEndianInt24Interleave` does. A nearest-rounded S24
output is included only as a diagnostic comparison, not a proposed change.

The saved loaded configuration has `USB_PITCH_SERVO=1`; `main.cpp` consequently
uses a resampler step of 1.0. The offline model does not reproduce live startup
sample offsets, the bypassed prime block, block scheduling, host/device behavior
or Ferrofish processing. It is not an exact live reconstruction or a new hardware
acceptance run. No Pi connection, profile switch or audio open occurred.

## Results

Both input models produced the same longest-run pattern on the modeled wire:
channel 4 = 7, every other channel = 1. Every DSP float channel had zero exact-zero
samples after warmup, finite samples and peak below full scale.

| Channel 4 result | S24-rounded input | Float32 input | Original live soak |
| --- | --- | --- | --- |
| Longest wire zero run | 7 | 7 | 7 |
| Wire RMS | 0.001343348921 | 0.001343348942 | 0.001343305752 |
| Wire peak | 0.006487965584 | 0.006487965584 | 0.0064879525 |
| Longest float-output zero run | 0 | 0 | Not captured |
| Longest nearest-S24 comparison run | 3 | 3 | Not applicable |

Each replay has three channel-4 wire events of at least four zeros, at identical
zero-based source frame indices in both input models:

| Start frame | Source time | Length |
| --- | --- | --- |
| 3,304,775 | 68.849479 s | 7 |
| 7,147,268 | 148.901417 s | 4 |
| 9,705,774 | 202.203625 s | 5 |

The first event is after the 60-second preflight duration, consistent with the
short pass and longer failure. These are offline source times, not measured
live input timestamps. Both JSON reports retain eight preceding samples, each
run sample before/after conversion, and the first nonzero successor.

In the seven-sample event with S24-rounded input, DSP output rises from
`2.9688203e-9` to `8.4152802e-8` and falls to `9.5081392e-9`, all positive and
below one L24 LSB (`1.1920928955078125e-7`). The preceding and following samples
are negative and become -1 LSB. Copying the high three S32 bytes maps the seven
small positive values to zero. There is no floating-point silence in that span.

Channel 4 sums low-pass bass from inputs 1, 3, 4, 5, 7, 9 and 11 (one-based),
with -6 dB assignment gains on inputs 3 and 4 after shared -18 dB headroom.
Input 4's LFE branch uses 120 Hz; the other six use 80 Hz. The sum then passes
through output 4's 16 EQ sections. This narrow-band signal can stay within one
quantization bin across several samples.

## Implication and next step

The fewer-than-four-zero gate can reject an uninterrupted loaded bass signal.
Do not alter coefficients, conversion, dither or thresholds merely to pass this
stimulus. Do not retrospectively pass the battery or make new latency/reserve
stability claims. UI Apply remains disabled and profiles remain experimental.

Before further hardware work, add bounded event capture to the continuous
harness: zero-run frame indices, CoreAudio sample times, nearby samples on all
16 returns and output-frame/stimulus alignment information. Verify it with
synthetic natural-quantization and injected-loss cases. Then prepare one loaded
capture long enough to include the first predicted event, with a fresh
process-bound preflight and playback coordination, and compare the returned
neighborhood with the offline reference. Any revised acceptance criterion must
be declared prospectively and distinguish quantization from inserted silence or
missing/repeated samples. A full battery rerun is not the next step.

## Verification

Warnings-as-errors replay build and existing bridge core tests passed. Checks
verified the artifact hash, Swift stimulus bits, 28,704,000 analyzed frames per
channel, all-channel run patterns, three retained neighborhoods and independent
S32 byte-copy conversion of each retained sample. `verification.json` records
source/compiler provenance and report hashes. `s24.json` and `float.json` retain
complete bounded statistics and neighborhoods. Reproduction commands are in
`work/dsp-service/README.md` under Loaded zero-run replay.
