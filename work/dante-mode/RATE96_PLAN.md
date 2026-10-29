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
