# USB 16x16 Phase 4 real-time bridge

Status (2026-09-11): accepted and in service. Bridge 406699bd is the accepted
transport bridge of 2026-09-02 onward (sd103 profile, handoff ACCEPTED
2026-09-07 22:25 UTC) plus the DSP stage of `DSP_MODE_DESIGN.md`, accepted
2026-09-11 under the reference-events-v1 criterion; the service runs the
`dsp-direct` profile, so no preset is loaded unless one is selected. The
paragraph that used to sit here described the 2026-09-01 candidate and is
superseded by the handoff.

Staged 2026-09-11, not built and not installed: the level meter tap
(`--meter-file PATH`). `LevelMeter` in the core reads each block at the four
stage points (USB capture, RAVENNA playback after the DSP stage, RAVENNA
capture, USB playback), accumulates per-channel peak, sum of squares and
full-scale count over a 2400-frame window, and publishes the closed window
through a seqlock'd preallocated snapshot; a SCHED_OTHER publisher thread
rewrites PATH atomically every window (25 ms poll). The prime render is not
metered, like it is not filtered. The tap is timed on the audio thread and
reported as `meter_us_max` / `meter_us_mean` on the BRIDGE line and in
SUMMARY. `usb16x16-meter-bench` (core only, not installed) measures it in
memory: 0.21 us median per 48-frame block on the Mac. With no `--meter-file`
nothing in the audio path changes.

This candidate replaces two independent `alsaloop` processes with one process
that owns all four raw ALSA directions:

```text
USB S24_3LE capture -> elastic ring -> near-unity ASRC -> RAVENNA S32 playback
RAVENNA S32 capture -> elastic ring -> near-unity ASRC -> USB S24_3LE playback
```

There is exactly one `SharedDriftEstimator`. It estimates `USB rate / RAVENNA
rate` from a fixed-window linear regression of the differential depth of the
two complete pipelines: each elastic ring plus its ALSA playback delay, sampled
once per second. The regression is corrected by the time integral of the ratio
already applied, so it estimates the required clock ratio while that ratio is
changing instead of feeding its own correction back as apparent drift. Its
intercept removes startup phase, unequal hardware periods, and fixed queue
depth. It begins steering after 60 observations, keeps at most 120 seconds,
filters the observed rate, and limits changes to 2 ppm per update. The TX
converter consumes the ratio and the RX converter consumes its reciprocal.
There are no direction-local estimators or servos; any direction recovery
rejects an acceptance run and restarts the observation window.

The audio thread uses raw hardware devices, `MMAP_INTERLEAVED`, locked memory,
`SCHED_FIFO`, preallocated buffers, fused packed-24/S32 conversion, and a short
four-point cubic Farrow converter intended only for near-unity clock errors.
Logging runs on a separate telemetry thread. A direction can be prepared and
re-primed without touching the other direction or USB enumeration; any restart
still rejects an acceptance run.

Only capture descriptors drive the audio-thread poll. Playback descriptors are
intentionally excluded because they remain writable when their elastic ring has
no excess; polling them would create a SCHED_FIFO busy loop.

## Build

The Pi needs ALSA headers only while compiling. They can be extracted into a
temporary sysroot without installing a package:

```bash
apt-get download libasound2-dev
dpkg-deb -x libasound2-dev_*.deb /tmp/alsa-dev
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
  -DALSA_INCLUDE_DIR=/tmp/alsa-dev/usr/include \
  -DALSA_LIBRARY=/usr/lib/aarch64-linux-gnu/libasound.so.2
cmake --build build -j4
ctest --test-dir build --output-on-failure
```

The pinned aarch64 candidate is in `artifacts/pi-aarch64/` with SHA-256
`406699bd4cf5763defb3560dca3d447d1dd2e8928dc370a643f1a080be026c88` (2026-09-11: the accepted 05f37bd9 source plus the DSP stage; 05f37bd9 is the rollback, kept by the review-20260911 bundle)
(2026-09-07: `--align-prime-age-margin-us N`, the prime margin's 5 frames:
the aligned prime's front age is priced at N + 2 ticks - offset instead of
the 150 us placement margin's 1200 us, so at 50 the TX front age is 296
instead of 301 and the drop may leave the ring up to 5 under the prime
level in the sessions whose wait exceeds 1104 us (PRIMED `under_prime=`);
default 150, at most 150, needs an aligned prime; the summary JSON carries
`align_prime_age_margin_us`; behaviour identical to `913d623b` with the
flag absent).
Previous binary `913d623b` (2026-09-06: `--rx-prime-trim 0|1`, the RX prime overshoot lever: the
ravenna-to-usb prime alone discards `ring_at_prime - intended` from the
ring's front at prime time, the trim `--prime-trim` runs for both
directions gated to RX; usb-to-ravenna keeps its aligned drop and is not
trimmed; refused with `--align-rx-prime 1`; the summary JSON carries
`rx_prime_trim`; behaviour identical to `0d8cccfa` with the flag off).
Previous binary `0d8cccfa` (2026-09-06: `kAlignPrimeMarginNs` 150 us instead of 200, the aligned wait
allowance lever paired with `--align-tx-offset-us 950`; the ALIGN trigger
line carries `target=prime|prime-missed|next` and `slack_us=`; otherwise
`c1ca48c5`. Its predecessor `0c7e0b0c`, one session, had the margin at
50 us, under the prime path's own 104 us).
Previous binary `c1ca48c5` (2026-09-06: the impulse trace's playback stages query the ALSA delay on the
blocks that carry a hit, `depth_src=delay`, so the queue terms are exact;
otherwise `21c0e9f2`).
Previous binary `21c0e9f2` (2026-09-06: the impulse trace, `--impulse-trace 1` with `--impulse-channel`,
`--impulse-threshold` and `--impulse-holdoff`: every block entering and
leaving the bridge is scanned on one channel for a sample over the
threshold and each hit is an `IMPULSE` line with its stage, stream
position, block and monotonic time; off by default, behaviour identical to
`2a158386` when off).
Previous binary `2a158386` (2026-09-05: the RX prime phase window's hold drains the ring to a whole
number of capture periods below the prime level, so a held prime lands
the ring where an unheld start does; `PRIME window` reports `ring=`;
otherwise `abab6732`).
Previous binary `abab6732` (2026-09-05: grid-phase instrument, `phase_us` on every BRIDGE line and
`grid_phase_us` on both PRIMED lines, the RAVENNA tick against the USB
frame grid; and `--rx-prime-phase-window LOW,HIGH` with
`--rx-prime-phase-timeout-s N`, which holds the RX prime, discarding ring
excess, until that phase is inside the window; window off by default,
behaviour identical to `98eeb083` apart from the telemetry field).
Previous binary `98eeb083` (2026-09-05: aligned RX trigger and prime, `--align-rx-trigger`,
`--align-rx-offset-us`, `--align-rx-prime`: the USB playback triggers on
the host's 1 ms frame grid read as the USB capture's fresh wakes, and the
RX prime drops from the ring's front so the front frame's age at the
first host frame after the trigger is a constant, the TX method with the
roles swapped; the prime holds up to 5 ms for the first USB reference;
all off by default, behaviour identical to `006fc65e` when off).
Previous binary `006fc65e` (2026-09-05: `--level-shift FRAMES`, Phase 5 Stage B3: in mode 1 the
differential setpoint captured at engagement is lowered by twice FRAMES,
moving that many frames of servo-held depth from usb-to-ravenna to
ravenna-to-usb; 0 = unchanged, behaviour identical to `e6bc98ac` at 0).
Previous binary `e6bc98ac` (2026-09-05: `--pitch-seed PPM`, Phase 5 Stage B2: with the pitch servo
on, both gadget pitch controls and the shared estimator start at the seed
before the prime instead of at nominal, removing the 46-frame warm-up
drift every session showed; `PITCHSERVO seeded ppm= pitch=` line, 0 =
off, behaviour identical to the previous binary at 0).
Previous binary `b65b84ee` (2026-09-04: zero-run detector, `--zero-run-detect 1`, with
`--zero-run-min` and `--zero-run-max` (8 and 480 frames): every block
read from a capture and written to a playback is scanned per channel for
runs of exact zeros, and each run inside the window is logged as a
`ZERORUN` line naming its stage, `usb-capture`, `ravenna-playback`,
`ravenna-capture` or `usb-playback`, with its start position on that
direction's frame count, its length, the channel mask, the start's phase
on the 48-frame grid and a UTC stamp; BRIDGE carries
`zr_usbcap/zr_ravplay/zr_ravcap/zr_usbplay` as
events/frames/longest/long-runs and SUMMARY the same plus the line
counts. Runs longer than the maximum are silence, counted not reported;
a direction restart forgets its open runs. Behaviour-free: the audio
path is identical with the flag off, which is the default).
Previous binaries: `40bec748` (aligned TX prime: the TX prime waits for
one more period of ring, computes the trigger target and the first tick
from the measured grid, and drops from the ring's front the frames that
make the front frame's age at that first tick a constant; PRIMED carries
`align_dropped prime_phase_us first_tick_wait_us front_age_frames`),
`ee3b5286` (aligned TX trigger), `38f44de9` (aligned
start with the retry and the aligned RX recovery), `99f37408`
(aligned start with the retry, unaligned recovery), `767ae43d` (aligned start without the retry),
`170b1081` (split servo at gain 0.05, `--level-gain`),
`da7df1c2` (split servo at gain 0.01, dead zone), `f7226238` (wrap fix, servo mode 1) and
`0254348c` (last resampler-only accepted binary).

## Candidate installation and measurement

`install-candidate.sh` installs the binary and safe wrapper root-owned and adds
one exact-command NOPASSWD rule. It does not modify the USB service, module, or
setup script. Installation intentionally needs the Pi sudo password once.

The default candidate is a 96-frame request, 384-frame ALSA buffer, 768-frame
rings, 192-frame elastic target, sink delay 576, and a 480-second window. Run it from
the Mac with:

```bash
../aes67-candidate/measure-phase4-roundtrip.sh 480 64 40 200
```

The orchestrator waits for three consecutive signal-bearing probes. Sink flags
are recorded for diagnosis only. A clean reconnaissance point must be followed
by a ten-minute run with `USB16X16_OTHER_CHANNEL_LOAD_AMPLITUDE=0.05` before it
can be accepted.

The dual-`alsaloop` runner remains installed and unchanged as the stopgap and
before/after baseline.
