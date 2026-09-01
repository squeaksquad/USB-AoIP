# USB 16x16 CoreAudio latency harness

This native macOS command-line tool reads CoreAudio directly. It does not rely on
`system_profiler`, which returned an empty audio-device list during the 2026-08-31
baseline even though Audio MIDI Setup and IOKit saw the device.

The first implemented stage records the measurement metadata required by the
project handoff:

- input and output channel counts and CoreAudio channel names;
- nominal and actual sample rates;
- current and supported buffer-frame sizes;
- input/output device latency and safety offsets;
- per-stream latency and virtual stream format.

## Build and test

```bash
swift test
swift build -c release
```

## Inspect USB 16x16

```bash
.build/release/usb16x16-latency inspect \
  --device "USB 16x16" \
  --output ../../outputs/latency/coreaudio-usb16x16-baseline.json
```

The JSON is written atomically and also printed to standard output. Inspection is
read-only. The correlation library is tested independently with deterministic
synthetic delays and is the analysis core for the live impulse recorder.

## Measure a live loopback

Build the local app identity once:

```bash
./build-app.sh
```

The app bundle supplies the stable privacy identity and
`NSMicrophoneUsageDescription` required for CoreAudio input. A bare executable
launched as a child of another app can block inside `AudioDeviceCreateIOProcID`
on macOS; `coreaudiod` reports that case as `bad client object`.

Start a verified USB capture-to-playback loopback on the Pi, then run the
executable inside the app bundle:

```bash
".build/USB16x16 Latency.app/Contents/MacOS/usb16x16-latency" measure \
  --device "USB 16x16" \
  --buffer-frames 64 \
  --output-channel 1 \
  --input-channel 1 \
  --impulses 20 \
  --maximum-lag-ms 500 \
  --output ../../outputs/latency/usb-only-64f.json
```

The tool sends sparse 0.25-full-scale impulses on one channel while keeping the
other 15 channels silent. It measures delay from CoreAudio's device sample-time
timestamps, reports every impulse delay plus median/p95/p99/maximum, counts input
and output timestamp discontinuities, and restores the original device buffer
frame size before exiting.

macOS asks once for microphone access to `USB16x16 Latency`. The measurement
cannot begin until the user approves that operating-system privacy prompt.

## Automated USB-only run

After microphone access is approved, the wrapper handles Pi loopback startup,
measurement, cleanup, log retrieval, and post-test USB verification:

```bash
./measure-usb-only.sh 80000 64 20 500
```

Arguments are Pi `alsaloop` target latency in microseconds, CoreAudio buffer
frames, impulse count, and maximum correlation lag in milliseconds. The wrapper
refuses to run if any `alsaloop` process already exists. Its exit trap stops only
the exact process it started, then verifies `configured/high-speed` and the
independent `usb-16x16.service` before succeeding.

For a quick one-variable reconnaissance sweep:

```bash
./sweep-usb-only.sh 80000 40000 20000 10000 5000
```

The sweep continues after an individual failure and returns the number of failed
operating points. These short impulse runs identify candidates; they do not
replace the required ten-minute clean acceptance soak.

## Scope boundary

Inspection never changes the device. Live measurement temporarily requests the
chosen CoreAudio buffer and restores the prior value. It does not start the Pi
AES67 daemon, load the RAVENNA module, or alter `usb-16x16.service`. The Pi-side
loopback must be temporary and explicitly stopped after each run.
