# Fixed-preset DSP service validation

ACCEPTED 2026-09-11 under the `reference-events-v1` criterion (handoff ACCEPTED
2026-09-11); the service runs `dsp-direct`. The paragraphs below are the
campaign record and keep their original wording.

Installed; 2026-09-11 acceptance battery completed with a loaded-arm failure.
Direct/transparent passed preflight, impulse repeats and ten-minute soaks; loaded
failed its soak because input 4 had seven consecutive exact zeros (limit <4).
No retries or threshold changes. See `outputs/dsp-service/acceptance-20260911/RESULTS.md`
for the original evidence, latency difference and limitations.
Profiles remain experimental and UI Apply stays disabled.

The opt-in `reference-events-v1` activity criterion passed a new 60-second
preflight and 600-second loaded soak. All three channel-4 events match the pinned
filter/quantization reference (112 retained frames, maximum error 1.5625 LSB).
Transport checks and the default legacy gate are preserved. TX queue floor fell
86 to 81, so reserve stability and overall acceptance remain open. Read
`outputs/dsp-service/reference-v1-live-20260911/RESULTS.md` and
`REFERENCE_VALIDATION.md`. Direct restoration is recorded with the campaign.

The bridge already contains the DSP stage. This change loads a pinned preset at
service startup, only on USB → AES67. A profile switch restarts the existing
service. Direct mode passes no DSP argument. No live coefficient updates,
meters, web Apply or AoIP-only mode are introduced.

## Reviewable bundle

`outputs/dsp-service/review-20260911/manifest.json` pins every file in the bundle.
The rollback files were read from the Pi during this session, except the accepted
bridge, which is the identical repository artifact (`05f37bd9`). Live baseline:
supervisor `427982dc`, configuration `306cfa85`; active, zero direction restarts,
TX/RX queue floors 83/72. This corrects the older pickup's supervisor claim.

The candidate bridge is the existing verified build `406699bd`; no rebuild or
filter implementation change. Both presets retain their previous verified hashes.
The three experimental profiles copy the selected sd103 transport fields verbatim:
`dsp-direct`, `dsp-transparent`, `dsp-loaded`. No profile is marked accepted.

Review the supervisor diff against `baseline/supervisor` and the appended profile
blocks in `candidate/aes67.conf`. The package installer replaces bridge,
supervisor and configuration together with the service stopped. It preserves the
systemd unit, sudoers, daemon, module and USB gadget. This bundle uses one manifest
instead of the historical two-installer choreography: do not run the legacy
installers for this DSP package. Their bridge pins remain tied to the accepted
rollback binary. The repository service installer's supervisor pin is kept current.

`deploy.py check` verifies bundle integrity without touching the service.
`install` also verifies the installed baseline bytes, ownership and inactive
service state, then installs the candidate. A changed live configuration makes
it refuse: refresh and review the baseline instead of bypassing the check.
`rollback` restores the bundled baseline and removes the two packaged presets;
it allows only the expected DSP profile-selection changes to the candidate config.
Both commands leave the service stopped. File-operation failure restores previous
files where the filesystem remains writable; power loss is not an atomic multi-file
transaction. The immutable bundle remains the recovery source.

## Deployment checkpoint — audio interruption required

First stop playback and quit any application holding the device, including RTL
Utility. Record the standing gap-bar read before stopping the AES67 service.
Transfer the bundle file by file into a fresh Pi staging directory; do not transfer
while a measurement is running. Suggested destination:
`/home/bdimaio/usb-16x16-work/dsp-service-review-20260911`.

After reviewing the manifest, run on the Pi:

```sh
cd /home/bdimaio/usb-16x16-work/dsp-service-review-20260911
python3 deploy.py check
sudo systemctl stop usb16x16-aes67
sudo python3 deploy.py install
sudo systemctl start usb16x16-aes67
```

The initial profile is `dsp-direct`. Wait for stable service state. Inspect the
actual ALIGN/PRIMED lines and arrival lead before interpreting any latency.
Use one normal cold-start session; do not automate coreaudiod kills or chase a
favorable draw. A cold start reduces stale-anchor ambiguity but does not eliminate
variation between bridge starts.

Select either DSP arm using the existing supervisor, with playback off:

```sh
sudo systemctl stop usb16x16-aes67
sudo /usr/local/sbin/usb16x16-aes67-supervisor switch-profile dsp-transparent
sudo systemctl start usb16x16-aes67
```

Substitute `dsp-loaded` or `dsp-direct` as required. These are explicit stop/start
operations, not seamless mode changes. If validation fails, stop the campaign;
review its saved result and restore direct mode or the baseline.

Full rollback, from the same staging directory:

```sh
sudo systemctl stop usb16x16-aes67
sudo python3 deploy.py rollback
sudo systemctl start usb16x16-aes67
```

## Corrected test sequence

The new CoreAudio `continuous` command generates deterministic noise on all 16
outputs and holds the device open once. Memory stays bounded for a 600 s soak.
After a two-second warmup it reports per-input peak, RMS, full-scale/nonfinite
samples and longest exact-zero run, plus input/output timestamp discontinuities.
It checks the native 48 kHz 16×16 Float32 format before starting.

This is an activity/stability check, **not** proof of routing, frequency response
or transport latency. The existing offline CamillaDSP comparisons supply the
filter-response evidence. If live response or routing is questionable, retain a
known multichannel capture and compare it with the offline filtered reference;
do not turn an activity pass into a correctness claim.

`validate.py` defaults to printing the plan. `--execute` opens audio. Return inputs
must be explicitly listed: `--required-inputs 1,2` only if both are physically
returned and active under the preset. Use all 16 for a fully patched 16-channel
return. It rejects ≥4 consecutive exact zeros after warmup on required returns;
this gate applies to the continuous-noise capture, not an impulse capture.

From the repository root, initial 60 s preflight example:

```sh
python3 work/dsp-service/validate.py \
  --bundle outputs/dsp-service/review-20260911 \
  --arm direct --phase preflight --required-inputs 1,2 \
  --output outputs/dsp-service/direct-preflight
```

Review the printed plan, then add `--execute`. Repeat for transparent and loaded
only after deliberately selecting their corresponding service profiles. Use a
new output directory for every attempt; no overwrite and no automatic retry.

Run preflights before spending time on the acceptance battery. A preflight receipt
is tied to the bundle, harness, return inputs, arm and service/bridge process.
After returning to an arm, take a new 60 s preflight because its process changed.
Then use `--preflight <that-directory>/summary.json` for:

| Arm | `--phase latency` | `--phase soak` |
| --- | --- | --- |
| direct | Four runs × 800 impulses, other-channel load 0.1 | 600 s continuous 16-output load |
| transparent | Four runs × 800 impulses, other-channel load 0.1 | 600 s continuous 16-output load |
| loaded | Refused: filtering changes the correlation reference | 600 s continuous 16-output load |

### Targeted event capture

Completed once on 2026-09-11: preflight passed, and the capture retained a complete
seven-zero channel-4 event. All 39 neighboring samples match the predicted
nearest L24 codes; clean timestamps/counters and continuous other returns support
the quantization explanation. Direct mode was restored and verified. The old
gate remains failed. Read `outputs/dsp-service/event-capture-20260911/RESULTS.md`
before further hardware work; the commands below document that procedure, not
an instruction to repeat it. The subsequent reference-criterion run is summarized
at the top of this document.

The updated signed harness retains bounded zero-run neighborhoods automatically
in every continuous report. Build verification is recorded at
`outputs/dsp-service/event-capture-20260911/build-verification.json`.
The existing acceptance gate remains unchanged; retained event evidence does
not turn a failed signal check into a pass.

After playback is stopped and RTL Utility is closed, select `dsp-loaded` using
the existing stop/switch/start procedure. Obtain a new 60-second all-16-input
preflight with the rebuilt harness. Then run one 90-second diagnostic capture:

```sh
python3 work/dsp-service/validate.py \
  --bundle outputs/dsp-service/review-20260911 --arm loaded --phase capture \
  --required-inputs 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16 \
  --preflight outputs/dsp-service/event-capture-20260911/preflight/summary.json \
  --output outputs/dsp-service/event-capture-20260911/capture
```

Default is a plan only; `--execute` opens audio. Output directories must be new.
The capture requires a preflight tied to the same bundle, rebuilt harness,
service/bridge process and return inputs. Older preflight receipts cannot be
reused after rebuilding. Only before/after snapshots contact the Pi.

The offline prediction is a seven-zero channel-4 event around source time
68.85 seconds. If reproduced, this run will still return failure under the old
gate, with `1-audio.json` preserving the event's samples, bit patterns and timing.
Do not retry it. Compare the neighborhood with the offline reference, preserve
service logs, then restore and verify `dsp-direct` before playback resumes.
This capture is diagnostic only, not a replacement acceptance battery.

The four runs preserve the existing direct/transparent stability gate. They do
not provide four independent startup draws. Compare latency as session evidence;
do not infer zero added transport depth from one direct/transparent pair. If a
small difference matters, price a separate controlled comparison before taking
more starts. The historical 719 samples is a recorded draw, not an exact equality
threshold for each new start. Loaded-arm latency and RTL remain not applicable to
this impulse method; intentional delay and filter group delay are different from
transport buffering.

Only the before/after snapshots contact the Pi. During the run, watch the local
log only; disable other arrival-lead readers/UI polling so they cannot consume
the packet-lead interval. Snapshots retain service and bridge identities, binary
hashes, config, startup markers, counters, floors, DSP timings and both sink leads.
Any recovery, counter reset, process change, missing DSP activity, signal loss or
nonpositive packet lead invalidates the run. There is no signal-readiness retry
loop. Existing contaminated floors cannot be made clean by a later passing run;
review the before snapshot and start evidence.

Each executed run writes raw audio statistics, harness output, snapshots and
`summary.json`. A passed summary is a test-gate result, **not acceptance**. Finish
with manual RTL at 32 frames on direct/transparent only, never sharing the device
with the harness, and review alignment, queue floors, worst-case DSP timing,
packet lead, clipping and startup/shutdown behavior. Do not compare a max DSP call
time against an average block size as a deadline proof.

## Verification

```sh
python3 -m unittest discover -s work/dsp-service -p 'test_*.py' -v
CLANG_MODULE_CACHE_PATH=/private/tmp/usb16x16-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/usb16x16-swiftpm-cache \
swift test --disable-sandbox --package-path work/latency-harness
bash -n work/aes67-bridge/usb16x16-aes67-supervisor
bash -n work/aes67-bridge/install-aes67-service.sh
python3 outputs/dsp-service/review-20260911/deploy.py check
```

The signed local harness app must be rebuilt before hardware tests (the session
that prepared this package builds it). The continuous IO callback has now passed synthetic tests and the three short
hardware preflights; the long acceptance battery failed the loaded zero-run gate.

## Next boundary

The new loaded activity gate passes; inspect the saved late queue-reserve change
and keep the separate latency finding open before further live work. The original
battery remains failed under its original gate; overall acceptance is pending.

After the service battery passes, implement staged UI Apply using the validated
stop/configure/start/verify/rollback operation. Keep draft and applied state
separate. Do not promise live-safe editing or extend to AoIP-only until this first
mode is accepted.

Current local result: 26 Python and 11 Swift tests pass. The pinned bundle and
criterion were verified for the new hardware run; full acceptance is not claimed.

Hardware-run requirement: the signed CoreAudio harness must run outside the Codex
filesystem sandbox. Inside the sandbox it enumerated zero audio devices; that
attempt opened no audio and is invalid evidence. Do not restart the gadget or
coreaudiod to fix this execution-permission condition.

## Loaded zero-run replay

`outputs/dsp-service/offline-loaded-20260911/RESULTS.md` documents a seven-sample
zero run reproduced by the pinned filters and S32-to-L24 conversion. No float
silence occurs. Both modeled USB input conversions reproduce channel 4 = 7 and
every other channel = 1, matching the live longest-run pattern. The live event
itself cannot be identified from aggregate statistics alone; the later bounded
live capture supplies that evidence. This replay does not alter production DSP.

Build and run locally; no audio device or Pi access is needed:

```sh
clang++ -std=c++20 -O2 -Wall -Wextra -Wpedantic -Werror \
  -I work/phase4-bridge/include work/dsp-service/replay-loaded.cpp \
  work/phase4-bridge/src/bridge_core.cpp -o /private/tmp/usb16x16-replay-loaded
/private/tmp/usb16x16-replay-loaded \
  outputs/dsp-service/review-20260911/candidate/loaded.dsp 600 s24 \
  > /private/tmp/usb16x16-replay-s24.json
```

Use `float` instead of `s24` for the input-conversion sensitivity check. `s24`
rounds input through the bridge converter; the actual host rounding policy is
not established. Both variants use the actual DSP stage and S32 converter,
followed by the driver's high-three-byte L24 operation. `nearest24Comparison`
is diagnostic only. Reports keep all-channel statistics and at most 32 completed
channel-4 events of at least four zeros, with up to 64 neighborhood samples each.
An unfinished final run is reported separately. Frame indices are zero-based
source frames; startup offsets and live transport are not modeled.
