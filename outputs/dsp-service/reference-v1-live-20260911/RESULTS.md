# Loaded reference-event preflight and soak — 2026-09-11

The new 60-second preflight and 600-second soak **passed the prospectively
declared activity criterion**. Overall DSP acceptance remains pending: the TX
queue floor fell during the soak, and the earlier latency difference remains
unresolved. The historical acceptance battery remains failed under its original
criterion. No failed test was retried or threshold changed during this run.

## Frozen procedure

One loaded service start, all 16 physical returns, 48 kHz, 64-frame CoreAudio
buffers and amplitude 0.1 deterministic continuous noise. The signed harness ran
outside the filesystem sandbox. No Pi polling, transfers or reference generation
occurred during audio. Reference generation and analysis followed audio closure.

Criterion `loaded-event-reference-v1`:
`2e6592b9609a9f721b4a44fcc5f7400010825754f85e8e74536b887ee80d7e2b`.
The fixed two-LSB tolerance, exact predicted-zero requirement and common alignment
rule were unchanged. `frozen-verification.json` records the source state at start;
later documentation updates do not change the criterion identity. The preflight
and soak used the same bundle, harness, service invocation and bridge process.
The installed candidate bridge/preset/supervisor were unchanged.

## Signal evidence

| Phase | Input/output frames | Events | Reference coverage | Activity gate |
| --- | ---: | ---: | ---: | --- |
| Preflight, 60 s | 2,880,000 each | 0 | 0 frames | Pass |
| Soak, 600 s | 28,800,000 each | 3 | 112 frames, all 16 channels | Pass |

The preflight had no qualifying events and longestZeroRun=1 on every channel;
its reference status is explicitly inconclusive with zero waveform coverage.
Existing continuous activity and transport checks pass it under the declared rule.

All three soak events occurred on channel 4 and matched the pinned reference:

| Input start frame | Reference source start frame | Consecutive zeros | Retained frames | Maximum error, L24 LSB |
| ---: | ---: | ---: | ---: | ---: |
| 3,305,786 | 3,304,775 | 7 | 39 | 1.5625 |
| 7,148,279 | 7,147,268 | 4 | 36 | 1.5625 |
| 9,706,785 | 9,705,774 | 5 | 37 | 1.5625 |

Channel 1 independently aligned each event. One input/source offset of 1,011
frames explains all channels and events. This index alignment is not a loaded
impulse latency measurement. Triggering zero runs and their nonzero boundaries
match exact predicted L24 codes; no window was omitted, truncated or unfinished.
Every other channel had longestZeroRun=1. Input/output discontinuities, invalid
buffers/timestamps, nonfinite samples and full-scale samples were all zero.

This identifies all retained zero events as the expected filter/quantization
trajectory. **Only 112 retained frames were compared**, not all 28.8 million.
`wholeRunValidated` remains false. The fixed error bound is diagnostic, not a
universal proof of conversion accuracy. The original zero-gate objection remains
in the new reference result for provenance.

## Transport and queue review

Service/bridge identities stayed fixed. Recovery, direction restart, drop, clip,
low-queue and pitch-error counters remained zero. Packet lead minima at soak end
were 977/989 us. DSP mean/max was 50.512/138.461 us per call. Cumulative TX/RX
maximum pull gaps were 994/1181 us.

The preflight TX/RX floors stayed 86/72. During the soak, TX fell **86 to 81**;
RX stayed 72. First/last 60-row queue means were TX 176.533/159.583 frames and
RX 139.300/143.783. TX means were approximately 176 frames for the first eight
minute blocks, then 173.200 and 158.783. This is a late reserve change, not a
clean reserve-stability result, despite zero low-queue or recovery counters.

`preflight/queue-review.json` and `soak/queue-review.json` use 1 Hz BRIDGE rows
bounded inclusively by the saved before/after `tx_input` counters. The soak has
602 rows because snapshot boundaries enclose the audio interval. Means use the
first/last 60 rows; the ten block means use nonoverlapping complete 60-row groups.
Raw queue histories are retained. No transport tuning or additional draw was run.

## Verification and handoff

26 Python tests and 11 Swift tests passed; outputs are retained beside this
report. Generated local reference executables are excluded from Git; exporter
source, compile recipe, ranges, raw reference codes and hashes are retained.
`run-soak.py` is a one-use campaign record with overwrite and source guards.
Do not rerun it or the historical capture wrapper.

Direct restoration is recorded in `run-status.json` and `final-state.json`.
The service is verified active/stable with zero error counters and no DSP calls;
UDC is configured/high-speed. `device-after.json` confirms native 48 kHz 16x16
with labels 1–16. Playback may resume.
Restoring `dsp-direct` disables DSP on the installed candidate; it does not roll
back the binary. The final device and service checks are retained separately.

Next: diagnose the late queue-reserve change from the saved transport history
and existing bridge timing code before proposing another live experiment. Keep
the separate direct/transparent latency finding open. Profiles remain experimental
and UI Apply remains disabled; this activity pass does not establish full acceptance.
