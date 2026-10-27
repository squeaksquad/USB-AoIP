# Sample rate, step 6: 96 kHz end to end (plan, 2026-10-27)

Plan only; nothing on the Pi or the Dante domain has changed. It answers
`SAMPLE_RATE_DESIGN.md`, "Revised steps", item 6: the domain at 96 via Dante
Switcher, the full battery and an hour on the loaded preset, DSP inside its
budget; only then does 96 join the arbiter's list and the page's
`OFFERED_RATES`. The handoff is authoritative where this disagrees.

## What the survey found (read-only, 2026-10-27 12:30 UTC)

On the Pi, as the 2026-10-18 point of record left it:

- `usb-16x16`, `usb16x16-statime`, `usb16x16-dante`, the rate path unit and
  `usb16x16-web` active; `usb16x16-aes67` inactive. Gadget rate controls both
  0 (the Mac has the interface down).
- Installed Inferno config 0a1688e1 (`asound-inferno-owner-rate48-arbiter.conf`):
  `SAMPLE_RATE "48000"`, `SUPPORTED_SAMPLE_RATES "48000"`. This line is the
  arbiter's offered list (`inferno_rates()` in `usb16x16-apply`); the applier
  rewrites only `SAMPLE_RATE` on a change.
- owner.conf: `METERS=1`, no preset, no `RATE` (direct at 48). transport.conf
  1434f79f: `RX_QUEUE=96`, `RATE_REQUESTS=1`. Owner c8b484ac, wrapper a6c3a197,
  start check 058e9177.
- `/etc/usb16x16/dsp/` holds only the four September 48 kHz artifacts. No
  `@<rate>` file exists: the per-rate store (step 4d) is installed but no
  preset has been applied through it, so nothing at 96 is on the Pi.
- Staged and unused: `~/usb-16x16-work/dante-mode/config/test-offer96-arbiter.conf`
  (2026-10-17 arbiter test: offers `48000,96000`, request file in `/dev/shm`).
  It is not in the repo.
- Left over: `/dev/shm/rate882/trace2.log` and `trace.log` (17 MB, root).

**Unattended event, 2026-10-22 18:49 UTC.** The endpoint exited after 4.6 days
(401,535 s) and systemd restarted it 6 s later. The start check judged the new
start whole (6019 / 6014 frames a second). Sequence: eth0 link up at 18:48:55
(no "Link is Down" line logged), Statime `GUARD: detected abrupt change:
-1215012810098037 ns` (the PTP time stepped back about 14 days, so the domain's
leader or its clock was reset), Inferno `severe clock discontinuity`, capture
XRUN, `NETERROR -32`, `FATAL`, exit 3. No counter was dirty before it. So a
domain-side clock step costs one endpoint restart, about 6 s plus
subscriptions, and recovers by itself. Not part of step 6; this should get its
own handoff entry (FOUND).

## What 96 kHz needs, by part

| Part | State | Needed for a candidate run | Needed to offer 96 |
|---|---|---|---|
| Gadget | Offers 96000; 16 x 24-bit at 32 frames passed a soak and bit-exact USB-only (2026-10-17) | nothing | nothing |
| Inferno plugin c6b012ae | Rate-aware (patches 0004/0005) | a config at 96 | `SUPPORTED_SAMPLE_RATES "48000,96000"` in the installed config |
| Owner c8b484ac | `--rate 96000` exists, never run at 96 | the candidate launcher with `--rate 96000` and transport options | nothing |
| Transport | Every depth is frames, so at 96 each lasts half as long | options on the candidate command line | per-rate keys in transport.conf and the wrapper |
| DSP | Artifacts compile at all six rates on the Mac; the bench says 96 fits (about 25-30 % of the period) | `transparent` and `loaded` compiled at 96000, staged | an applied preset filed `@96000` |
| Start check | `--rate` exists; the unit runs it with no rate (48000) | not involved (candidate runs bypass the unit) | the rate read from owner.conf |
| Arbiter | Refuses 96 (not offered) | not involved | the offered line above, and a live 48 -> 96 -> 48 |
| Page | `OFFERED_RATES = [48000]` (`work/dsp-compiler/compile.mjs`) | not involved | `[48000, 96000]` |
| Harness wrappers | Four 48 kHz pins (below) | fixed first | — |

## Measurement tools pinned to 48 kHz (fix first, Mac side only)

1. `work/dante-mode/measure-candidate.sh:140`: the soak's short check uses
   `(seconds - 3) * 48000`, so a short capture at 96 would pass.
2. `work/dante-mode/measure-candidate.sh:218`: `daw_timeline` milliseconds
   divide by 48.
3. `work/dante-mode/soak_reference.py:93-99`: frame totals use 48000 and it
   refuses any `nominalSampleRate` other than 48000. That means no soak on a
   preset at 96.
4. `work/dante-mode/owner/reference_export.cpp:49`: `kMaxFrames = 3600 * 48000`
   (an hour at 96 is twice that), and `dsp->load(text)` takes no rate, so a 96
   artifact is loaded as 48 or refused. It needs `--rate`, and a rebuild on the
   Pi with the service stopped.

In each case the rate comes from the harness JSON, which already records it.
These need tests beside them (`test_soak_reference.py`).

## Transport at 96: the one open variable

At 48 the owner runs `period 64, buffer 1024, tx_lead 128, guard 256,
usb_period 48, usb_buffer 480, rx_queue 96, rx_slack 96`, on a 1 ms loop. At 48
the return queue's floor measured 45-48 frames, about 1 ms of jitter used. Kept
in frames at 96, that jitter becomes about 96 frames, the whole queue.

- **Arm A (first): the same time as at 48.** Every depth doubled: `--period 128
  --buffer 2048 --tx-lead 256 --guard 512 --usb-period 96 --usb-buffer 960
  --rx-queue 192 --rx-slack 192`. This should behave like 48. The latency in
  time should be about the same, and the extra USB frames add nothing.
- **Arm B (only after A passes): one depth at a time back toward the 48 frame
  figures.** `rx_queue` first, as in October. Each change is its own candidate
  with its own anchors. This is where 96 could be lower latency than 48.

The Inferno knobs (`RX_LATENCY_NS` / `TX_LATENCY_NS`, 1 ms) are times and stay
as they are.

## Sequence

Each phase ends with a report to the operator. Nothing outward happens without
their go.

**Phase 0: Mac side, no Pi.** Fix the four pins above, with tests. Write
`config/asound-inferno-owner-rate96-candidate.conf`: the installed config with
`SAMPLE_RATE "96000"`, `SUPPORTED_SAMPLE_RATES "96000"` and no
`RATE_REQUEST_FILE`, so during the run nothing hands requests to the arbiter.
Compile `transparent` and `loaded` at 96000. Commit.

DONE 2026-10-27, Mac side only:
- `measure-candidate.sh` reads the soak's rate from `sampleRate` and the
  `daw_timeline` rate from `deviceDuring.nominalSampleRate`. On the
  2026-10-17 96 kHz evidence the soak reads 96000 and passes. The 2026-10-18
  48 kHz anchor still gives 338 / 490 (10.208 ms).
- `soak_reference.py` takes the rate from the report (the device's nominal
  rate, which `sampleRate` must agree with) and passes it to the exporter.
- `owner/reference_export.cpp` takes `RATE` (default 48000), loads the
  artifact at it, and its hour limit is in that rate.
- `test_soak_reference.py` has two new tests, 14 pass: frame counts at 96, an
  odd rate and a disagreeing report refused, a 48 kHz artifact against a
  96 kHz capture inconclusive.
- `config/asound-inferno-owner-rate96-candidate.conf` (7892fd04).
- `config/dsp-loaded@96000.dsp` (89759207) and
  `config/dsp-transparent@96000.dsp` (cc2511ac), compiled by
  `verify-presets.mjs` and `usb16x16-dsp-compile --rate 96000`. The same
  commands at 48000 reproduce the installed `loaded.dsp` (2b6baa04) and
  `transparent.dsp` (ad695984) byte for byte. Both 96 artifacts load at
  96000 and are refused at 48000.

**Phase 1: stage, with the service running.** Transfers to the Pi only; no
measurement is running. Copy the config, the two artifacts and the
reference-export source to `~/usb-16x16-work/dante-mode/`. The operator can
`sudo rm -r /dev/shm/rate882` now.

**Phase 2: the domain to 96 (operator, at the Mac).** `dante-sync sync --rate
96000 --allow-band-up`. Every Dante device moves (Pulse, DVS, D2USB, Ferrofish,
the Pi's Inferno), and some may drop channels. Then the Mac's USB 16x16 to
96000 (Audio MIDI Setup, or `setrate.swift`). Check each device's rate and
channel count in Controller before going on. The Pi's installed endpoint will
see `host_rate=mismatch` and refuse the request (the Mac decides, but 96 is not
offered). That is expected.

**Phase 3: candidate at 96, arm A.** `systemctl stop usb16x16-dante`
(password-free). Then `sudo -n usb16x16-dante-candidate start
.../owner/usb16x16-dante-owner-rate4 CONFIG=.../config/asound-inferno-owner-rate96-candidate.conf
--rate 96000 <arm A options> --meter-file ...`. Check `START rate=96000`, `NETSTART`,
`USBOPEN ... host_rate=match`, subscriptions back, and the noise probe after the
start. Then direct first, then on `loaded`:

- four loaded 800-impulse runs (`measure-candidate.sh`, `daw_timeline` at 96);
- the ten-minute sixteen-channel soak, and `bitexact` (direct);
- an hour on `loaded`, with monitors re-armed every 30 min;
- `dsp_us_max` per minute against the budget: 30 % of the period, about
  300 µs a 1 ms wake.

Judge against a same-day control at 48 (the anchors drew 328-379 across days).

**Phase 4: back to 48.** Stop the candidate, then `dante-sync sync --rate
48000`, the Mac to 48000, and `systemctl start usb16x16-dante`. Then a 48 kHz
anchor to confirm the point of record is unchanged.

**Phase 5 (only on ACCEPTED at 96): offer it.** One staged installer with a
`rollback`:

- the installed Inferno config with `SUPPORTED_SAMPLE_RATES "48000,96000"`;
- transport.conf per-rate keys (`RX_QUEUE_96000=...` etc., from arm A or B)
  and the wrapper that reads them;
- the start-check unit reading `RATE` from owner.conf;
- `OFFERED_RATES = [48000, 96000]` with web and applier re-staged.

Then the arbiter live, through Dante Switcher: 48 -> 96 restarts once and comes
up at 96 with the preset at 96, 96 -> 48 the same, and a set the Mac is not at
is refused. Then the four-run battery at 96 under the service. That is step 6
done for 96; 44.1 and 88.2 follow the same path (88.2 with its 10 s wait in the
arbiter's restart, which it does not have yet).

## Rollback

- During phases 2-4: stop the candidate, set the domain and the Mac back to
  48000, and `systemctl start usb16x16-dante`. The installed set is never
  touched before phase 5.
- After phase 5: the installer's `rollback`.

## Questions for the operator

Answered 2026-10-27 (operator): (1) yes, every device keeps 16 each way at
96 kHz, the Ferrofish included; (2) arm A first, every depth doubled; (3)
`loaded`; (4) today, with the operator at the Mac from about 4-5 hours after
12:30 UTC; (5) the Pulse had been powered off for several days and was powered
back on on 2026-10-22, which is the clock step (handoff, FOUND 2026-10-27).

1. **Channel counts at 96.** Does every device keep 16 each way at 96 kHz, in
   particular the Ferrofish's Dante card (the digital loop return)? If it
   halves, the battery cannot run sixteen channels.
2. **Transport.** Arm A first (time-scaled, expected to match 48), then B
   toward lower latency. Agreed, or start straight at the 48 frame figures?
3. **Preset for the hour.** `loaded` (308 biquads), as at 48?
4. **Window.** Phases 2-4 hold the whole Dante domain at 96 for about two
   hours. When suits?
5. **The 2026-10-22 clock step.** Anything on the domain that day (Pulse power
   cycle, switch reboot, a Controller change)?
