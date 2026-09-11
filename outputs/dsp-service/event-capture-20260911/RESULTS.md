# Live loaded event capture — 2026-09-11

The captured seven-zero event matches the predicted filter/quantization
waveform across the full 39-frame channel-4 neighborhood. All 39 samples recover
the same nearest L24 codes as the offline reference; maximum raw Float32 error
is 0.000068665 LSB. The other 15 channels remain nonzero throughout the window.
This identifies the observed event as the expected quantization pattern, with
no evidence of an interruption in this capture.

The original acceptance battery and this diagnostic capture remain FAILED under
the unchanged fewer-than-four-zero gate. This finding does not retrospectively
pass that battery or establish long-term stability or latency neutrality.

## Run

Playback was confirmed stopped and RTL Utility closed. USB was configured at
high speed; CoreAudio reported native 48 kHz Float32 16-in/16-out, labels 1–16.
The starting direct service had clean counters and matching candidate hashes.
The standing gap-bar read and initial snapshot were retained before switching.

Loaded DSP was selected once. After the service settled, a fresh 60-second
all-16-return preflight passed. One 90-second capture followed on the same
service/bridge process and rebuilt signed harness. No retries, transport tuning,
USB/coreaudiod resets, or Pi polling during audio occurred.

| Result | 60-second preflight | 90-second capture |
| --- | --- | --- |
| Input and output frames | 2,880,000 each | 4,320,000 each |
| Longest zero run, input 4 | 1 | 7 |
| Longest zero run, other inputs | 1 each | 1 each |
| Captured events | 0 | 1 complete window |
| Timestamp gaps / invalid timestamps / invalid buffers | 0 / 0 / 0 | 0 / 0 / 0 |
| Nonfinite / full-scale samples | 0 / 0 | 0 / 0 |
| TX / RX queue floors at end | 86 / 96 | 86 / 96 |
| Sink arrival-lead minima, microseconds | 1043 / 1050 | 1043 / 1049 |

Service recovery, restart, dropped-sample, clipping, low-queue and pitch-error
counters stayed zero. Queue floors were unchanged across the capture. DSP
reported mean/max 52.081/168.239 microseconds per call at capture end; these
figures are not a deadline proof or a new long-soak result.

## Event and comparison

Input 4's event starts at zero-based input frame 3,305,764, spans seven zeros,
and ends on a nonzero sample. Its window includes 16 preceding and 16 following
frames on all 16 returns, with exact Float32 bit patterns and CoreAudio times.
There were no omitted events, window truncations or continuity breaks.

The pinned DSP core, loaded preset and S24-rounded input model predict the same
event at source frame 3,304,775. `reference-window.cpp` exports the full 39-frame
wire neighborhood. `analyze-event.py` decodes the live sample bits and compares
them with that reference; `comparison.json` retains the result and hashes.
The 989-frame input/source index offset aligns these captured waveforms; it is
not a loaded impulse latency result.

All 39 channel-4 nearest L24 codes match. Raw Float32 values are extremely close
but not bit-identical to ideal L24 decoding (maximum error 0.000068665 LSB).
Across all 16 channels the maximum raw reference difference is 1.5625 LSB, so
this is not an all-channel bit-exactness claim. The other channels provide
continuous activity and matching source context around the bass event.

The offline float DSP output is nonzero through the seven-sample span. Its small
positive values become zero when the driver's S32-to-L24 conversion discards
the low byte. The captured signal follows that predicted trajectory before,
during and after the event. The old zero-run gate therefore rejects a valid
quantized signal in this case.

## Final state and next step

Direct mode was restored and verified active/stable with matching candidate
bridge/supervisor/configuration, no DSP loaded or calls, and zero error counters.
See `final-state.json` and `run-status.json`. Playback may resume. This restores
DSP-disabled operation on the candidate binary, not the baseline binary bundle.

The event-capture implementation has now produced valid hardware evidence.
Next, define prospective loaded-signal validation that distinguishes expected
quantization from actual inserted silence or missing/repeated samples, using
the deterministic filtered reference. Keep transport counter/timestamp checks
and reserve review. Do not change filters, wire conversion or dither simply to
pass the current noise gate. UI Apply and overall DSP acceptance remain pending;
do not repeat the full battery as the next step.

The preflight/capture directories retain raw reports and before/after snapshots;
`preflight-bridge.txt` and `capture-bridge.txt` retain queue history. The build
record preserves the tested signed binary hash and synthetic test results.
