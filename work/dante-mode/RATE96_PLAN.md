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

CORRECTION 2026-10-27, by measurement: (1) holds for the count but not for the
loop's channels. The Pulse has 32 channels each way at 96, and the loop uses
its channels 49-64, so phase 3 found no return path. The Pulse also dropped its
receive subscriptions above 32, which had to be restored at 48. Phase 3 is
blocked until the loop is moved inside the Pulse's first 32 channels, the MADI
side included. That is the operator's routing (handoff, FOUND 2026-10-27).

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

## Revised 2026-10-27 (operator): 48 and 44.1 on the loop, 96 on an internal loop

Operator: test 48 and 44.1 kHz for now, find an internal way to test 96, and
no re-mapping of the Ferrofish on the fly.

**48 kHz** is the point of record. With the measured host gain, `bitexact`
passes there (handoff, 2026-10-27 17:44), so the 48 battery stands as
accepted plus that check.

**44.1 kHz on the real loop.** The Pulse keeps 64 x 64 at 44.1 (Dante
Switcher's `captures/pulse-matched-44k1.json`), so `Input/Output 49-64`
exist and nothing is re-mapped. Same band as 48, so the Pulse should not drop
subscriptions. This is checked after the return all the same.
- Mac side: `config/asound-inferno-owner-rate44-candidate.conf` (the 96 one at
  44100), `transparent` and `loaded` compiled at 44100.
- Transport: the 48 kHz frame figures unchanged (at 44.1 each lasts 8.8 %
  longer, the safe side).
- Move: the USB 16x16 to 44100, then `dante-sync sync --source usb16x16
  --exclude USB-16x16-Inferno` (Metric Halo, Pulse and D2USB). Candidate
  `--rate 44100`. Battery: noise probe, four loaded 800-impulse runs, 600 s
  soak, `bitexact` 360 s, the hour on `loaded`, 400 impulses after. Then back
  to 48 the same way, the Pulse's subscriptions checked, and a 48 anchor.

**96 kHz on an internal loop: the Pi subscribes to itself.** Only the Mac's
USB 16x16 moves to 96. The Dante domain, the Metric Halo and the Pulse stay at
48 and are not touched.
- The candidate runs under its own identity: `NAME
  "USB-16x16-Inferno-96"`, its own `DEVICE_ID` and `STATE_ID`. The real
  endpoint's saved subscriptions and the Pulse's subscriptions to it are left
  alone. The Pulse sees the real endpoint offline, as during any service stop.
- The candidate's `RX 1-16` is subscribed to its own `TX 1-16`
  (`netaudio subscription add --tx USB-16x16-Inferno-96 --rx
  USB-16x16-Inferno-96`), saved in its own state directory.
- What it tests: the gadget at 96, the owner and its buffer depths at 96, the
  DSP stage's cost at 96 on `loaded`, Inferno transmit and receive at 96,
  bit-exactness, the soak and the hour.
- What it does not test: the eth0 wire, the switch and the Pulse. A flow to
  the Pi's own address goes through the kernel's loopback, not the NIC. Its
  latency is the Pi's own path, not comparable to the point of record.
- Open until tried:
  - does Inferno accept a subscription to itself;
  - does an endpoint at 96 run cleanly under a 48 kHz PTP leader (PTP carries
    time, not rate, and Dante allows mixed rates in one domain).
- If self-subscription fails, the fallback is Dante Virtual Soundcard on the
  Mac at 96 as the far end, with a Mac-side loop. It has more moving parts.

**Result 2026-10-27 (handoff, 19:49):** the one-instance self-loop is impossible:
Inferno drops its own mDNS answers and advertises no self-subscription. The 96
network half ran clean under the 48 leader with nothing subscribed. Next options:
a second Inferno instance as a reflector, or a patch to the self-filter.

**Result 2026-10-27 (handoff, 21:11):** 96 kHz end to end through DVS as the far
end: the candidate is clean at 96 (nothing it sent had a hole), the loop's holes
come from DVS, and the figure (about 1900 / 19.8 ms) includes DVS's latency.

## Revised 2026-10-29 (operator): 96 kHz on the real loop with 8 channels

At 2x rates the Pulse keeps 32 Dante channels each way and MADI carries 32
instead of 64, so the loop's 49-64 cannot exist at 96. The Metric Halo's
speakers use MADI 1-20, and the Ferrofish maps freely only in blocks of 8, which
leaves **MADI 25-32: an 8-channel loop** that exists at 44.1, 48 and 96 alike.
Operator, 2026-10-29: test 96 on the real loop with fewer channels (first 12 on
MADI 21-32, then 8 for the Ferrofish's blocks); the operator does the routing.

**Routing (operator).** Pi `TX 1-8` -> the Pulse, inside its Dante channels
1-32 -> the Pulse's MADI out 25-32 -> the Metric Halo, MADI in 25-32 looped to
MADI out 25-32 -> the Pulse's MADI in 25-32 -> its Dante transmit, inside 1-32
-> Pi `RX 1-8`. Pi channels 9-16 unrouted. Check how the Metric Halo numbers
MADI channels in its 2x mode before taking 25-32 for granted. Set it up and
check it **at 48 first**: then the domain's move to 96 re-maps nothing (the
condition of 2026-10-27). The 48 point of record's 16-channel loop on 49-64
stays; only the Pi's receive subscriptions move between the two, at 48.

**What the measurement does with 8 channels (built 2026-10-29, Mac side).**
- Impulse runs (USB 1 -> 1) and the noise probe (out 1 / in 2): unchanged,
  since Pi channels 1-2 are in the loop.
- Soak: `USB16X16_LOOP_CHANNELS=8 measure-candidate.sh soak ...` judges
  channels 1-8 and still loads all 16; it says so in its output. A preset's
  zero-run check (`soak_reference.py`) assumes 16 channels, so with a narrower
  loop a zero run is a FAIL, not a reference check: run the 96 soaks on
  `direct` or `transparent`, where none is expected.
- `bitexact` and `hostgain`: `--loop-channels 8` (1...16, default 16) judges
  channels 1-8 only, the host-gain calibration included (it required all 16
  to return a steady level); the report records `loopChannels`. Harness tests
  `hostGainReadsOnlyTheLoopedChannels`, `bitExactJudgesOnlyTheLoopedChannels`;
  21 pass; the signed app rebuilt.
- The owner's `out_holes` / `back_holes` count only runs where all 16 channels
  are zero; with 9-16 silent they cannot fire on this loop, so a failure is
  located with the per-channel capture reader
  (`outputs/latency/rate-report-capture-20261029/channel-zeros.py`) instead.

**Rules.** The battery's sixteen-channel soak becomes an 8-channel soak at 96:
the operator's exception for this rate, recorded with each result. 48 and 44.1
keep the 16-channel loop and the full battery.

**Order.** (1) Routing at 48, checked with an impulse run and
`USB16X16_LOOP_CHANNELS=8` soak 120 on the 8-channel return. (2) The rest of
this plan's 96 sequence (offer 96, candidate configs, presets at 96), on this
loop instead of DVS. (3) Subscriptions back to 49-64 at 48 and a 48 anchor.

**MEASURED 2026-10-29 04:29-04:35 UTC: 96 kHz on the real loop, 8 channels, arm A: clean, and
faster than 48 on the same path.** Evidence `outputs/latency/rate96-loop8-20261029/` (`steps.txt`,
`dante-sync-to96.txt`, `subscriptions-before.json` / `-at96.json`, `owner-candidate.log`).
- Routing (operator): Pi `TX 1-8` -> Pulse `Input 17-24` -> RemoteFish `MADI OUT 25-32` <-
  `DANTE IN 17-24` -> Metric Halo strips t1-t8 (MA25-32 in, MADI Op 25-32 out, 0.0 dB) ->
  `DANTE OUT 17-24` <- `MADI IN 25-32` -> Pulse `Output 17-24` -> Pi `RX 1-8`. Pi 9-16 go via
  MADI 33-40, which does not exist at 96 (silent there).
- 48 kHz reference on this path (installed service, 04:25): 100 impulses 378 /
  `daw_timeline` 530 (11.042 ms), clean on the Pi.
- Move: `systemctl stop usb16x16-dante`; `dante-sync sync --rate 96000 --allow-band-up
  --exclude USB-16x16-Inferno` (Pulse, DVS, D2USB, the Mac's USB 16x16). It left MHLink at 48:
  with `--rate` and no `--source` the Metric Halo is the source and is not set. A second
  `dante-sync sync --source usb16x16 --exclude USB-16x16-Inferno` set MHLink to 96. Pulse word
  clock locked throughout.
- Candidate: owner rate8 a15a9d84 (the installed one), `config/asound-inferno-owner-rate96-candidate.conf`
  (same identity as the service), arm A (`--rate 96000 --period 64 --buffer 2048 --tx-lead 256
  --guard 512 --usb-period 96 --usb-buffer 960 --rx-queue 192 --rx-slack 192`), started 04:29:55;
  `USBOPEN ... rate=96000 host_rate=match`. All 64 subscriptions present and connected at 96,
  none lost (every channel the Pi uses on the Pulse is inside 1-32 now).
- Noise probe at 32: clean (`loop8-96-noise-ch2-32f-20261029T043054Z`: zero runs >= 4: 0).
- 100 impulses: **680 / `daw_timeline` 916 = 9.542 ms** (io_offset 236), against 11.042 ms at 48
  on the same path.
- Soak 120 s, `USB16X16_LOOP_CHANNELS=8`: **PASS** (`loop8-96-soak-120s-32f-20261029T043237Z`:
  channels 1-8, longest zero run 1, discontinuities 0/0).
- The owner's ` ERROR ` lines (+10, +12, +38) are all Inferno's control server logging
  `unknown opcode1` 0x00 / 0x2204 packets (Controller's queries; RESULTS.md), not audio: no xrun,
  lag, fault, overflow or re-prime in the owner's counters.
Not yet run at 96: the four loaded 800-impulse runs, the ten-minute soak, `bitexact
--loop-channels 8`, the hour on `loaded`, `dsp_us_max`.

**MEASURED 2026-10-29 04:36-05:14 UTC, same session: the 96 battery on direct; `bitexact` FAILS
on steady single-frame slips, not located.**
- Four loaded 800-impulse runs (`USB16X16_OTHER_LOAD=0.1`): 680 / 680 / 680 / 680, spread 0,
  `daw_timeline` 916 (9.542 ms) each (`loop8-96-loaded{1..4}-*`).
- 600 s soak, `USB16X16_LOOP_CHANNELS=8`: PASS, longest zero run 1, discontinuities 0/0
  (`loop8-96-soak-600s-32f-20261029T045023Z`). Owner after it: `out_holes` 0/0, `back_holes` 0/0,
  no fault, overflow or re-prime.
- `bitexact --loop-channels 8`, 360 s, host gain unity both ways, twice: **FAIL**. Every channel
  locked on its own sequence (34.56 M matches each), nothing off the 24-bit grid, no discontinuity
  or invalid buffer, but all 8 channels lost lock together: 2 events in the first run (last at
  172.13 s, `loop8-96-bitexact-360s-32f-20261029T050057Z`), 4 in the second (last at 354.54 s,
  `loop8-96-bitexact2-360s-32f-20261029T050734Z`). Each event is one wrong but valid code, then the
  sequence re-locks at once: a dropped or repeated frame on the whole flow, about one every 90 s.
  The owner logged nothing then (10 s lines: no fault, overflow, re-prime or depth jump). Zero-run
  checks cannot see a slip, which is why the soaks pass. Two nearly-locked clocks somewhere in the
  loop would do this. Not located; owed: an eth0 capture of the Dante flows during a `bitexact`
  run at 96 (which side slips), and `bitexact --loop-channels 8` at 48 on this same path (the rate
  or the new routing through the Metric Halo strips). At 48 and 44.1 on the 49-64 loop, also
  through the Metric Halo, `bitexact` passed (handoff, 2026-10-27/28).

**FOUND 2026-10-29 10:39-11:15 UTC, same session: an eth0 capture at 96 cannot locate the slips,
because the capture itself breaks the loop.** Evidence: `outputs/latency/rate96-slip-capture-20261029/`
(`run.log`, `tcpdump*.txt`, `sequence-slips.py`; the pcaps are deleted, 4.1 and 4.5 GB).
- A third `bitexact --loop-channels 8` without a capture failed the same way: 2 all-channel slips,
  last at 230.32 s (`loop8-96-bitexact3-capture-360s-32f-20261029T105511Z`, misnamed: its capture
  had no sudo). The slips reproduce on every run at 96.
- With `tcpdump` streaming the Pulse's flows to the Mac over wlan0 (about 10.7 MB/s), the host-gain
  step that opens `bitexact` failed 4 times out of 4 ("channel 1 did not return a steady level");
  without it, 4 out of 4 passed, and a 60 s 8-channel soak passed (`loop8-96-recheck-*`). `tcpdump
  -p` (no promiscuous mode) fails the same way, 3 out of 3: it is the load, not the mode.
- On the wire during that failure: every channel the Pi sends holds its host-gain level (one
  88-frame zero on all 16 at the first step edge), packets on time to 0.3 ms by the Pi's clock
  (p99.9 0.27 ms); what the Pulse returns carries 32-frame zero runs on all 8 looped channels
  together every 20-80 ms. 32 frames is one Pi transmit packet at 96 (4 channels x 32 frames per
  flow), so the Pulse is most likely treating Pi packets as late: under that load, either the
  wire timing or the Pi's PTP clock moves against the Pulse's by more than its receive latency.
  Not shown which. Soak 3 at 48 (RATE_REPORT_PLAN.md) also ran under a streamed capture and also saw
  32/64-sample zeros in what the Pi receives; that capture may have caused them too.
- So the slips are still not located, and a streamed capture is not a usable tool at 96. Left:
  `bitexact` at 48 on this path, and a capture that does not load the Pi (a mirror port on the
  switch, or a short capture to tmpfs: 473 MB is about 44 s at 96).

**MEASURED 2026-10-29 11:43-11:57 UTC, same session: a capture kept in tmpfs on the Pi does not
break the loop, but it caught a different event, not the slip.** `tmpfs-catch.sh` (beside the
evidence in `outputs/latency/rate96-slip-capture-20261029/`; log `tmpfs-catch.txt`): `tcpdump -p`
to `/dev/shm` (nothing streamed), host gain 3 of 3 under it each time, then 25-30 s `bitexact
--loop-channels 8` runs inside it, the capture kept only after a run with a lost lock.
- 22 runs, about 560 s of sequence. Two lost locks of the slip's shape (one mismatch each, no zero
  run), both 2.08 s into the run at 11:43 (`loop8-96-bitexact-tmpfs-30s-32f-20261029T114350Z`); that
  run used a 3 x 100 MB ring, which had already overwritten that second. At about one slip per 90 s
  without a capture, about six were due; two came.
- The run kept (`loop8-96-bitexact-tmpfs-25s-32f-20261029T115428Z`, capture
  `try-20261029T115428Z/all.pcap`, gitignored; `sequence-slips-115428Z.txt`) holds a different event:
  on all 8 channels one lost lock with 161 mismatches and a 160-frame zero run (128 on two). On the
  wire, all four of the Pi's transmit flows skip four packets at once: the Dante timestamp steps 160
  instead of 32, the audio steps 129 codes (128 frames never sent, none repeated), the send gap is
  1.665 ms where 0.333 is normal. What the Pulse returns has the matching 160 zeros. So once in
  about 560 s under a tmpfs capture, the Pi's transmit (Inferno or the owner feeding it) stalled
  for 1.3 ms and dropped those frames. The 600 s soak without a capture had no zero run longer
  than 1, so this may be the capture's load. The owner counts only runs on all 16 channels.
- The slip, one frame dropped or repeated on every looped channel, is still not located. Two
  facts narrow it: `bitexact` cannot tell a drop from a repeat (both re-lock after one mismatch),
  and every capture so far either breaks the loop (streamed) or adds its own events (tmpfs).

**MEASURED 2026-10-29 12:31-12:41 UTC, same session: back to 48 on the service; `bitexact` on
the same 8-channel path PASSES at 48, so the slip belongs to the 96 operating point, not the
routing.** Steps in `outputs/latency/rate96-loop8-20261029/steps.txt`: candidate stopped,
`dante-sync sync --rate 48000 --source usb16x16` (MHLink, Pulse, DVS, D2USB to 48k, verified),
then `dante-sync sync --rate 48000` for the USB 16x16 (the source is not set by the first), then
`usb16x16-dante` started; start check `state=ok rate=6015 restarts=0`; the 64 subscriptions
identical to `subscriptions-before.json` (`subscriptions-after48.json`). The candidate's last log
is `owner-candidate-final.log`.
- Noise probe at 32: zero runs >= 4: 0 (`loop8-back48-noise-ch2-32f-20261029T123328Z`).
- 100 impulses: 379 / `daw_timeline` 531 (11.062 ms), against 530 (11.042 ms) on this path before 96.
- `bitexact --loop-channels 8`, 360 s, host gain unity: **PASS** (`loop8-48-bitexact-360s-32f-
  20261029T123450Z`): 17.28 M matches per channel, no mismatch, no lost lock, nothing off the grid.
- Service counters: `back_holes` 0/0, `capture_faults` 0; `rx_overflow` 391 then 427, moving only
  with `rx_primes` at the harness's opens, as recorded before.
So on the same routing (MADI 25-32 through the Metric Halo strips), 48 is bit-exact and 96 drops
or repeats one frame about every 90 s. Suspects for 96, untested: arm A's doubled depths and the
owner's servo at 96 (one frame of drift corrected by a step, not a pitch), Inferno's 96k flows, the
Pulse's 96k receive. The `daw_timeline` 916 at 96 and the soaks stand; `bitexact` at 96 does not.

**MEASURED 2026-10-29 14:26-14:36 UTC: the 96 kHz slip is not one frame. It is a 16-frame block
returned 8 frames early (8 dropped, then 8 repeated 16 frames later) on all 8 channels together,
with no owner event near it.** Evidence `outputs/latency/rate96-slip-kind-20261029/` (`steps.txt`,
`dante-sync-to96*.txt`, `subscriptions-at96.json`, `owner-candidate.log`, `slip-align.py`,
`clock-offset-start.txt`).
- Tools (step 1 of the pickup): `bitexact` records every lost lock and names it (`slips`: frame,
  `dropped` / `repeated` / `other` / `offGrid`, frames), plus `inputStartUnixTime` (84e73ac; tests
  `bitExactSequenceStepsBackExactly`, `bitExactNamesEachSlipADropOrARepeat`, 23 pass, app rebuilt).
  Owner `--event-trace` (62037e2): an EVENT line with the wall clock at each change of the step
  counters (re-primes, primes, overflow, idle discards, resyncs, faults), a SERVO line a second.
  Candidate `usb16x16-dante-owner-rate8trace` c065b40f: rate8's source plus that; the same build line
  gives a15a9d84 from rate8's source, so the trace is the only difference. Not installed.
- Move to 96 as before (two `dante-sync` runs, MHLink to 96 by the second); candidate rate8trace,
  arm A, `--event-trace`; `USBOPEN ... host_rate=match`; 64 subscriptions as `subscriptions-before.json`
  (`subs-compare.py`); noise probe at 32 clean (`loop8-96trace-noise-ch2-32f-20261029T142816Z`,
  zero runs >= 4: 0). Pi clock about 0.08 s ahead of the Mac (ssh round trips, +-0.1 s).
- `bitexact --loop-channels 8`, 360 s, host gain unity: FAIL as before
  (`loop8-96trace-bitexact-360s-32f-20261029T142918Z`), one event at 229.292 s: on every channel
  at the same frame, 8 frames dropped, then 16 frames later 8 frames repeated (2 mismatches and 2
  lost locks per channel, 34.56 M matches). So the loop returned 16 frames that belong 8 frames
  later and then carried on in place: no frame lost or added overall, a block misplaced, not two
  clocks drifting. The "about one per 90 s" of the earlier runs counted lost locks; one event is
  two of them.
- The owner: no EVENT line within 1 s of it (none from first flow to the end), SERVO steady (pitch
  1000016 both ways, tx_mean 255, rx_mean 191).
- Where 16 frames comes from at 96: the Pulse's flows to the Pi are 8 channels x 16 frames a packet
  (`rate96-slip-capture-20261029/sequence-slips-115428Z.txt`); the Pi's own are 32 frames, the USB
  side 12 a microframe. So the block is one Pulse packet, placed half a packet early, either by
  the Pulse (or the loop behind it) or by Inferno's receive. Not yet shown which.
- Next (one variable, no capture): owner `--seq-check 8` (d3691b8; `seq_check.hpp`,
  `seq_check_test.cpp` with the shifted-block case; candidate `usb16x16-dante-owner-rate8seq`
  5f8a45b6, not installed) checks `bitexact`'s sequence where the owner sees it, as the gadget
  delivers it and as Inferno delivers it, with a SEQ line per lost lock. If Inferno's output shows
  the shift, it was made upstream of the owner (Inferno receive, the Pulse, the MADI loop).

**MEASURED 2026-10-29 14:48-14:57 UTC: the shifted block is already in what Inferno delivers to
the owner. The owner, the gadget and the Mac are cleared; the shift is made in Inferno's receive or
before it (the Pulse, the MADI loop through the Metric Halo).** Evidence
`outputs/latency/rate96-slip-kind-20261029/` (`owner-candidate-seq.log`, `subscriptions-at96-seq.json`).
- Candidate `rate8seq` 5f8a45b6 (arm A, `--event-trace --seq-check 8`), started 14:48:55;
  `host_rate=match`, 64 subscriptions as before, noise probe at 32 clean (`loop8-96seq-noise-*`,
  zero runs >= 4: 0).
- `bitexact --loop-channels 8`, 360 s: FAIL, one event at 59.600 s
  (`loop8-96seq-bitexact-360s-32f-20261029T145036Z`): all 8 channels, 8 dropped, then 8 frames later
  8 repeated (this time the misplaced window is 8 frames, half a Pulse packet; at 14:29 it was 16).
- The owner's SEQ lines at the same moment (0.08 s before the Mac's time, inside the clock
  offset's error): `point=back` (as Inferno delivers it), all 8 channels, `dropped 8` then
  `repeated 8` 8 frames later, the same shape as the Mac's. `point=out` (as the gadget delivers
  the Mac's output): clean throughout. The only other SEQ lines are `other` at the stream's start
  and stop. No EVENT line in the run, SERVO steady (pitch 1000016 both ways).
- So the misplaced block reaches the owner already misplaced: the owner's queue, the gadget, USB
  and CoreAudio do not make it. Left: Inferno's receive (where it writes a packet in its ring), or
  the Pulse's packets themselves (or the loop through MADI / the Metric Halo before them). An eth0
  capture tells those apart: the audio in the Pulse's packets against their Dante timestamps at the
  moment of a SEQ line. With the SEQ line as the trigger, a tmpfs ring of only the Pulse -> Pi
  flows can run until an event and be cut 2 s after it, rather than catching one by chance.

**CORRECTION (added 16:35 UTC the same day): "catch2 ... no owner fault in three runs" below is wrong.**
The owner's EVENT lines (`owner-candidate-seq.log`) show 10 USB playback faults in catch2's second
run, 15:15:23 to 15:20:53, about 32.7 s apart (15:15:23.99, 15:15:56.71, 15:16:29.53, 15:17:02.25, ...),
with re-primes and transmit resyncs at most of them; the Mac saw each as an `other` burst or a
`repeated 960`. Runs 1 and 3 had none near the caught block (the nearest fault is 15:20:53, the block
is at 15:23:38). Faults came only while a capture ran: none in the 14:29 or 14:50 runs, nor in catch2's
first run. So nice 19 did not stop the capture's harm; the steady 32.7 s period, the same at 5 and at
10 MB/s, points at the capture's tmpfs writes (memory pressure, as the compaction stalls of
2026-10-13), not tcpdump's CPU. Not shown. The block and the wire reading below are unaffected.

**MEASURED 2026-10-29 15:01-15:24 UTC: the misplaced block is already in the Pulse's packets on the
wire. Inferno's receive is cleared with the owner; left are what the Pi sends (Inferno's transmit)
and the far loop (the Pulse, MADI, the Metric Halo strips).** Evidence
`outputs/latency/rate96-slip-kind-20261029/` (`seq-catch.sh`, `slip-wire.py`, `catch1/`, `catch2/`;
the pcaps are gitignored).
- `seq-catch.sh`: a tcpdump ring in the Pi's `/dev/shm` (4 x 80 MB, about 60 s) of the Pulse -> Pi flows
  only, stopped 2 s after the owner's first `SEQ ... point=back ... dropped|repeated` line, while the
  Mac runs `bitexact --loop-channels 8` 360 s at a time.
- catch1 (15:01-15:08, tcpdump at normal priority, trigger on any `point=back` line): the trigger fired
  on an `other`, and the capture's own load showed: two USB playback faults in the owner 32 s apart
  (`playback_faults` 1 and 2, `gap_us_max` 2193, transmit depth down to 12), the second seen by the Mac
  as `repeated 960`, the gadget's whole playback buffer played again. Neither happened without a
  capture. Not the misplaced block.
- catch2 (15:08-15:24, tcpdump at nice 19, trigger on `dropped|repeated` only): no owner fault in
  three runs; the trigger fired in the third, `SEQ ... point=back ... dropped 8` at 15:23:38.31; 0
  packets dropped by the kernel.
- On the wire (`catch2/slip-wire.txt`): all 8 looped channels in one Pulse flow (port 61445, 8 ch x
  16 frames). The packet stamped 56878865694 breaks at sample 13 on every channel, `dropped 8`; the next
  (…710) at sample 13, `repeated 8`: a 16-frame window carrying the audio of 8 frames later, the shape
  the owner and the Mac see. Stamps run on evenly (0 irregularities in 316,924 packets per flow) and
  arrive every 0.167 ms as always. So the Pulse sent the block already misplaced, and Inferno placed it
  where its stamp says. The window starts at sample 13, not on a Pulse packet boundary.
- Next: the same catch with the Pi's own transmit flows in the ring (both directions, about 10 MB/s,
  a ring of about 30 s). If what the Pi sends is clean at the matching moment, the shift is made in the
  far loop; MADI and the Metric Halo can then be split by routing the Pulse's MADI out straight back to
  its MADI in, without the strips.

**CORRECTION (added 16:35 UTC the same day): two statements below are wrong.** "no owner fault": the
owner had USB playback faults at 16:19:52, 16:20:58 and 16:21:30 (re-primes and transmit resyncs at
the first two), the capture's load as in catch2's correction. And the outgoing flows' 16-channel
break at 16:20:58.1 (sample 31 on all four flows) is the fault at 16:20:58.16 (`tx_resyncs` +2), not
the stream's start. Neither is within 13 s of the caught block (16:21:11.49), and the outgoing flows
are unbroken from 16:21:08.66 to 16:21:13.07, so the finding stands. The same `bitexact` run also had
a second misplaced block at 16:22:15, after the ring had stopped.

**MEASURED 2026-10-29 16:19-16:21 UTC: what the Pi sends is clean at the moment the Pulse returns the
block misplaced. The whole Pi side is cleared; the 96 kHz slip is made in the far loop (the Pulse,
MADI, the Metric Halo strips).** Evidence `outputs/latency/rate96-slip-kind-20261029/catch3/`
(`seq-catch.txt`, `slip-wire.txt`; pcaps gitignored).
- `seq-catch.sh 4 both`: the same triggered tmpfs ring with the Pi's four transmit flows in it too
  (about 10.8 MB/s, a ring of about 24 s), tcpdump at nice 19. Fired in the first run, `SEQ ...
  point=back ... dropped 8` at 16:21:11.49; 0 packets dropped by the kernel; no owner fault.
- Return (Pulse -> Pi, port 61445, all 8 looped channels): the packet stamped 57210371358 breaks at
  sample 13 on every channel, `dropped 8`; the next (…374) at sample 13, `repeated 8`. Same shape and
  same place in the Pulse's packet as catch2. Stamps even in every flow (0 irregularities).
- Outgoing (Pi -> Pulse, four flows of 4 ch x 32 frames, the 16 sequences): no break on any channel
  from 16:21:08.66 to 16:21:13.07, which holds the matching moment: the loop is 144 frames (1.5 ms)
  from a Pi stamp to the Pulse's (measured from one code seen leaving on sequence 6 and returning
  on channel 6). The only breaks in the outgoing flows outside the stream's start are single-channel
  `other`s that reappear 144 frames later in the return on the same sequence: one code carried
  through the loop, consistent with the Mac's clamp of -2^23 to -2^23+1 at unity gain (the reader
  does not skip it), not a slip.
- The window starts 11 frames into a Pi transmit packet and 13 into a Pulse packet: no boundary of
  either.
- So the Pi (the owner, the gadget, Inferno both ways) sends the sequence intact and receives it
  misplaced. Left to split: the Pulse's Dante/MADI conversion at 96, the MADI link, the Metric Halo
  strips at 96. One routing change splits them: the Pulse's MADI out 25-32 straight back to its MADI
  in 25-32 (no Metric Halo), the rest as now; if the slip goes, it is the Metric Halo (or its MADI
  port) at 96; if it stays, the Pulse.

**MEASURED 2026-10-29 16:22-16:48 UTC: after the operator rebooted the Metric Halo and loaded a
lighter monitor output (far from the unit's DSP limit at 96k), `bitexact --loop-channels 8` PASSES at
96 kHz, twice.** Evidence `outputs/latency/rate96-slip-kind-20261029/` (`status-after-mh-reboot.txt`,
`subscriptions-after-mh-reboot.json`, `owner-candidate-seq.log`).
- After the reboot: every device at 96k, MHLink the clock master at 96k, the Pulse's word clock locked,
  64 subscriptions as `subscriptions-before.json`; candidate rate8seq still running.
- Noise probe at 32, first after the reboot: 6 zero runs >= 4 (four of 64 frames, one of 20, one of 8),
  arriving in what Dante returned (owner `back_holes` 19 -> 23 at 16:33:35), no owner fault, re-prime
  or resync (`loop8-96mhreboot-noise-ch2-32f-20261029T163315Z`). A second probe a minute later: 0
  (`loop8-96mhreboot2-noise-*`). Read as the far loop settling after the reboot; not shown.
- `bitexact --loop-channels 8`, 360 s, host gain unity: PASS (`loop8-96mhpreset-bitexact-360s-32f-
  20261029T163615Z`) and PASS (`loop8-96mhpreset2-bitexact-360s-32f-20261029T164234Z`): 34.56 M
  matches per channel each, no mismatch, no lost lock, longest zero run 1. The owner's sequence check
  agrees (no SEQ line inside either run but the stream's stop); no owner fault, re-prime or resync.
- Weight: without a capture, the five failing runs before (04:xx twice, 10:55, 14:29, 14:50) had 6
  misplaced blocks, about 1.2 per 360 s; two clean runs by chance at that rate is about 9 %.
- Two things changed at once, the reboot and the lighter preset (DSP load at 96k), and these runs do not
  separate them. With the earlier finding (the Pi sends the sequence intact and the Pulse returns it
  misplaced), the misplaced 16-frame block is most likely the Metric Halo's processing at 96k under a
  heavy DSP load, or a state it was in before the reboot. To separate them: the heavier preset again
  without a reboot (the slip should return if it is the load).

**MEASURED 2026-10-29 18:00-18:06 UTC: with the operator's heavy monitor preset loaded again on the
Metric Halo, without a reboot, `bitexact --loop-channels 8` still PASSES at 96 kHz.** Evidence
`outputs/latency/loop8-96mhheavy-bitexact-360s-32f-20261029T180004Z.json`, owner log
`rate96-slip-kind-20261029/owner-candidate-seq.log` (candidate rate8seq, unchanged since 14:48).
- 360 s, 34.56 M frames, no discontinuity either way, no slip; the owner's sequence check logged nothing
  inside the run but the stream's stop (SEQ n=351-358 `other 0` at the close), and no fault, re-prime or
  resync (EVENT lines only the stream's open and close).
- So the DSP load at 96k alone does not bring the misplaced block back: the change that removed it is the
  reboot, i.e. a state the Metric Halo (or the far loop with it) was in before. Three clean runs in a row
  against the earlier ~1.2 misplaced blocks per run: by chance about 3 %.
- Not shown: what put the unit in that state (the day's rate moves 48 -> 96 -> 48 -> 96 are the obvious
  suspect) or whether it comes back after the next rate change. Operating note until then: after moving
  the loop to 96k, reboot the Metric Halo before a bit-exact measurement.

**MEASURED 2026-10-29 21:00-22:02 UTC: the hour on `loaded@96000` (89759207), production owner
a15a9d84 as a candidate, real 8-channel loop. Transport clean; soak verdict INCONCLUSIVE (harness
limit); `dsp_us_max` over the planned budget in 6 % of the 10 s windows.** Candidate start: `START
rate=96000`, `DSP loaded ... biquads=308`, NETSTART, `USBOPEN host_rate=match`; all 64 subscriptions as
`subscriptions-before.json` (`rate96-slip-kind-20261029/subscriptions-dsphour.json`); noise probe at 32
clean (`loop8-96dsp-noise-ch2-32f-20261029T210031Z`). Host gain from
`loop8-96mhheavy-bitexact-360s-32f-20261029T180004Z.json`.
- Soak `loop8-96dsphour-soak-3600s-32f-20261029T210151Z`: no discontinuity either way, longest zero run
  11 (ch4), peaks 0.0046-0.0372 on channels 1-8. 46 zero runs of 4+; the harness kept 32 windows, so
  `soak_reference.py` could not judge the other 14: inconclusive, which the wrapper counts as FAIL. At
  44.1 kHz the same preset gave 8 in an hour; at 96 the low-passed output dwells near zero twice as many
  samples, so more runs cross the threshold. Harness changed to keep 512 (39f815c, 23 tests pass,
  `test_soak_reference.py` OK, app rebuilt); the hour is being rerun on the same candidate.
- Owner over the hour: no resync, loss, capture or playback fault, re-prime or servo rejection;
  `gap_us_max` at most 1349 (1.07 ms at 44.1); `back_holes` 144 (all-16 runs of 8+, channels 9-16
  not looped and the preset's output, not faults); the error lines are Inferno's unknown-opcode chatter.
- DSP cost (365 ten-second windows with audio): `dsp_us_mean` 157 (80 at 48: twice the samples, as
  expected); `dsp_us_max` 150-300 in 343 windows, over 300 in 22, worst 414 (41 % of a 1 ms wake).
  The plan's budget was 30 % (about 300 µs); at 48 the hour had 300 once. No fault or gap followed
  any of them, but the budget is not met: the loaded preset at 96 has about 0.6 ms of the wake left
  in its worst windows.
