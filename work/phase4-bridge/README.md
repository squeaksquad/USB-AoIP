# USB 16x16 Phase 4 real-time bridge

Status: implemented and running on the Pi, but not accepted as an operating
point. The currently pinned build adds exact capture-frame counters for the
next estimator diagnostic. Its controller is otherwise the same design that
reached an RX playback XRUN in `phase4-candidate-20260901T134118Z`; it has not
completed a candidate run or the required loaded ten-minute soak.

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
`b65b84ee2aa33cde52e99a8275730c19be2269b5d55904382aeb17b341a33118`
(2026-09-04: zero-run detector, `--zero-run-detect 1`, with
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
