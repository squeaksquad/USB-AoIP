# DSP acceptance campaign — 2026-09-11

In progress. User confirmed playback/apps closed and restarted usb-16x16.service
once for a fresh anchor. Pre-existing process had two recoveries; it was not used
as acceptance evidence. No repeated anchor draws or automatic failed-test retries.

Direct automated arm passed: preflight on all 16 returns, four × 800 impulses at
725 samples (zero spread), and a 600-second continuous 16-channel soak. Zero
recovery/drop/clip/low-queue events and timestamp discontinuities. Soak queue floors
stayed TX 84 / RX 96; first/last 60-second queue means were TX 174.867/173.867,
RX 144.217/142.950 frames. No sustained reserve decline evident in these samples.
Sink lead minima during soak: 976/981 microseconds. All 16 returns had no exact-zero
run longer than one sample and no full-scale/nonfinite samples.

Direct manual RTL: user reported 19.021 ms at 32 frames = 913 samples, matching
725 + 188 to rounding precision. RTL Utility closed; after-RTL snapshot confirms
zero recoveries and unchanged queue floors 84/96. Direct arm complete.

Transparent arm is running. Loaded arm remains pending.
No latency-neutrality or full acceptance claim yet.

Transparent automated arm passed: all 3,200 impulses read 766 samples with zero
spread; all-16-return preflight and 600-second soak clean. No recovery/drop/clip/
low-queue events or timestamp discontinuities. Soak floors stayed 133/72; packet
lead minima 977/979 us. DSP mean/max at soak end 41.316/161.608 us per call.
Paused in dsp-transparent with the harness closed for manual RTL at 32 frames.

Existing impulse-index analysis places the session difference chiefly inside the
Pi/AES67 path: direct pos_aes67=544, pos_pi=510, pi_total=680.8; transparent
592, 561, 720.7 respectively (samples). Origin-free USB-time estimates 44.2 versus
45.3. A 48-sample step appears in the AES67 index segment. Do not dismiss the
41-sample total difference as Mac-only variation, or claim DSP latency neutrality.
Separate starts still confound causal attribution; no additional draw campaign
was run. Both trace-analysis text files are preserved alongside the raw logs.


Transparent manual RTL: user reported 19.875 ms at 32 frames = 954 samples,
matching 766 + 188 exactly. RTL Utility was confirmed closed before loaded arm.
The later after-RTL snapshot spans a substantially longer interval than the soak:
zero recoveries/restarts, but cumulative floors fell from 133/72 to 90/65 and
maximum gaps rose to 2240/2385 us. This is separate post-test operating evidence;
the timestamp of the RTL measurement itself was not supplied, so these changes
cannot be attributed to RTL. Do not overwrite the clean soak figures with them,
or ignore them when describing longer-running behavior. Raw snapshot preserved.

Loaded arm is now running its preflight and 600-second continuous soak. No loaded
impulse latency or RTL measurement is requested because filtering invalidates
that measurement reference.

FINAL TEST RESULT: loaded soak failed: input 4 longestZeroRun=7, threshold <4.
No nonfinite/fullscale samples or timestamp discontinuities; counters clean.
No retry. See RESULTS.md for exact evidence and bounded next step.

Final state: dsp-direct restored and verified active/running, matching candidate
bridge/supervisor/config, no DSP loaded or calls, zero recoveries and error
counters. See final-state.json. Playback may resume. This is DSP disabled on the
candidate binary, not a baseline binary rollback.
