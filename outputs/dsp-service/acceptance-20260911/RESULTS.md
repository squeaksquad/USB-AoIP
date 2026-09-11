# DSP service acceptance battery — 2026-09-11

Status: battery completed, overall acceptance FAILED. Direct and transparent
passed; loaded failed the predeclared continuous-signal gate. No retry performed.

One user-performed fresh USB anchor preceded direct. The fixed reviewed package
was used throughout, with no transport tuning or test retries. Each arm declares
all 16 required return inputs. CoreAudio measurements ran outside the sandbox.

| Arm | 60 s preflight | 4 × 800 impulses | 600 s soak | User RTL at 32 frames |
| --- | --- | --- | --- | --- |
| Direct | Pass, all 16 | 725 samples, zero spread | Pass, all 16 | 19.021 ms |
| Transparent | Pass, all 16 | 766 samples, zero spread | Pass, all 16 | 19.875 ms |
| Loaded | Pass, all 16 | Not applicable | FAIL: input 4 zero run | Not applicable |

Direct and transparent had zero recoveries, direction restarts, drops, clips,
low-queue events or timestamp discontinuities during their test windows. Their
soak TX/RX floors stayed fixed at 84/96 and 133/72, respectively. Queue histories
show no sustained reserve decline across either ten-minute window. Packet lead
minima were 976/981 us and 977/979 us. Transparent DSP mean/max at soak end was
41.316/161.608 us per call.

## Latency finding

Transparent measured 41 samples (0.854 ms) above direct in this pair. Manual RTL
independently agrees with that difference; each RTL reading is approximately
188 samples above its harness result. Different service starts prevent assigning
the difference solely to DSP execution.

Saved impulse-index analysis puts a 48-sample step in the AES67 index segment:
544 direct versus 592 transparent. The total Pi index segment is 510 versus 561.
Time-domain Pi estimates are 680.8 versus 720.7 samples; corresponding USB
residuals are 44.2 versus 45.3. The evidence does not support dismissing the
increase as Mac-only timing or claiming latency neutrality. No new restart or
tuning campaign was run.

## Longer operating interval

The transparent after-RTL snapshot, taken hours after its soak, still had zero
recoveries/restarts/drops/clips/low-queue events, but cumulative TX/RX floors had
fallen to 90/65 and maximum gaps reached 2240/2385 us. The user supplied no exact
RTL measurement timestamp. These changes cannot be attributed to RTL and are
separate from the bounded soak result. Ten-minute stability does not establish
unchanging reserves over hours.

## Scope and evidence

This battery checks service startup, continuous activity on all 16 returns,
within-session impulse stability for direct/transparent, and bounded DSP load
stability. It does not independently prove live routing/filter response, startup
latency distributions, or latency neutrality. Loaded filtering changes the
impulse reference, so no loaded impulse/RTL result is claimed. UI Apply remains
outside this battery; profiles remain experimental.

Each arm retains preflight/soak summaries, raw harness statistics, before/after
snapshots and bridge logs. Direct/transparent additionally retain latency runs,
impulse-index.txt, rtl.json and after-rtl.json. The immutable package remains at
../review-20260911/; rollback hashes are 05f37bd9 / 427982dc / 306cfa85.

## Loaded failure and next step

The 600-second loaded run captured 28,800,000 frames with no input/output timestamp
discontinuities, invalid buffers, nonfinite samples or full-scale samples. Input 4
had a longest exact-zero run of 7 samples (about 146 us), violating the declared
limit of fewer than 4. All other inputs had a longest run of 1. Input 4 remained
active overall (peak 0.006488, RMS 0.001343). This is valid failure evidence,
not proof of a transport dropout or a specific DSP defect.

Service counters stayed clean. DSP mean/max was 50.548/134.738 us per call; packet
lead minima were 956/962 us. TX floor decreased from 87 to 82; RX stayed 72.
First/last 60-second mean queues were TX 177.767/166.867, RX 140.033/138.900.
These figures do not justify a clean reserve-stability claim for loaded mode.

Recommended next step: inspect the channel-4 loaded signal path and reproduce the
deterministic stimulus through the pinned filters and relevant sample conversion
offline. Distinguish filter/quantization zeros from a live-path interruption before
spending another hardware run. The current statistics do not retain the samples
or timestamp around the seven-zero event; a targeted future capture should retain
that evidence if offline analysis is inconclusive. Do not loosen the existing
gate retrospectively, repeat the full battery, or enable UI Apply yet.

Final state: dsp-direct restored and verified active/running, matching candidate
bridge/supervisor/config, no DSP loaded or calls, zero recoveries and error
counters. See final-state.json. Playback may resume. This is DSP disabled on the
candidate binary, not a baseline binary rollback.
