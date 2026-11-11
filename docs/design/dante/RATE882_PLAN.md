# Sample rate: 88.2 kHz end to end (plan, 2026-11-01)

ACCEPTED 2026-11-01 (see "Results" at the end; the handoff tail is authoritative). Written as a plan; the
sections before "Results" are that plan. 88.2 is the last
rate the gadget offers (`48000,44100,88200,96000`) that the Dante side does not.
It follows the 96 kHz path (`RATE96_PLAN.md`), which this plan reuses wherever it
can; the new part is the macOS 88.2 rule. The handoff is authoritative where this
disagrees.

## What the survey found (read-only, 2026-11-01)

Already rate-generic, nothing to change: the owner (`rate_check.hpp` lists all six
Dante rates), both start wrappers (`RATE=88200`, `KEY_88200`; the prime-drop limit
is already 96 for an 88.2 key since df6a1b0b), the start check (it handles the
non-integer packet grid at 44.1 and 88.2), the applier (`DANTE_RATES`, the
`-88200.dsp` artifacts), `usb16x16-web` (`OTHER_RATES`) and the compiler
(`DANTE_RATES`; a page preset already gets an `@88200` file). Dante Switcher sets
88.2 and holds `--usb882-settle 10` after the USB-AoIP is verified there.

Missing:

1. The Inferno config's `SUPPORTED_SAMPLE_RATES "44100,48000,96000"`: 88200 is not
   offered, so neither Controller nor the arbiter can move the endpoint there.
2. Transport keys `_88200`: without them 88.2 runs the plain (48 kHz) depths,
   half as long in time. 96's arm A depths are the starting point (same frames,
   about 9 % longer in time at 88.2).
3. A prime drop and capture drain sized for 88.2 (a sweep, as at 96).
4. Unknown: whether the Pulse, the D2USB and DVS run Dante at 88.2. The Metric Halo
   offers it (`dante-sync status`). MADI at 2x carries half the channels, so the
   loop is MADI 25-32, 8 channels, as at 96.
5. The macOS rule (`work/pi-tuning/MULTIRATE_GADGET_PLAN.md`, 2026-10-18): after the
   device is switched to 88.2, audio started on it within about 7 s puts macOS in a
   state where it passes silence both ways until the next rate change (bad 7 of 7
   at about 2.5 s; clean from about 7 s). Nothing on the Pi can make a Mac app wait.

## The question that decides 88.2: the Pro Tools case

The main use (operator, memory `rate-change-use-cases`) is a Pro Tools session
opening: it sets the rate and starts audio at once. If that reliably hits the
silent state at 88.2, 88.2 is unusable whatever the Pi does, and the work stops
here. The 2026-10-18 finding came from `setrate` plus the harness on a USB-only
`alsaloop` loop, before the rate-request kernel patch and the owner; Pro Tools'
own sequence was never measured. So this goes first. It needs no change on the
Pi: the gadget offers 88.2 today.

## Sequence

**Phase 0: does Pro Tools opening an 88.2 session put macOS in the silent state?
(operator at the Mac, about 20 minutes).** The bad state survives app restarts
until the rate changes, so it can be read after Pro Tools has quit, with no
routing inside Pro Tools:
1. Dante Switcher's Follow Rate Changes off (otherwise it moves the whole network
   when Pro Tools sets 88.2); the Mac's USB-AoIP at 48.
2. A session stops `usb16x16-dante` and runs the October USB-only loop on the Pi
   (`alsaloop -C hw:UAC2Gadget -P hw:UAC2Gadget -f S24_3LE -c 16 -r 88200`,
   `outputs/latency/rate882-dirtest-20261018/quickwin.sh`).
3. The operator opens an 88.2 session in Pro Tools with USB-AoIP as the playback
   engine, lets it play a few seconds, and quits Pro Tools.
4. The session runs the harness noise probe at 88.2 (no rate change): mostly
   zeros means the silent state, clean means not.
5. Back to 48 by hand (wait 10 s each way, the recovery), and repeat: three
   opens from 48, three from 44.1.
6. Loop stopped, service started at 48, Follow Rate Changes back on.
Outcome: the silent state on any open -> 88.2 is parked and the operator decides;
clean on all six -> Phase 1. A control at the start: the October quick change
(`quickwin.sh`) should still reproduce the bad state, or the probe proves nothing.

**Phase 1: does the domain run at 88.2? (read and set, Mac side).** `dante-sync
sync --rate 88200 --allow-band-up --no-usb` (the Pi excluded: it cannot follow
yet), then `dante-sync status`: every device at 88.2 with the leader locked. A
device that cannot is the end of 88.2 on this loop. Back with `--rate 48000`.

**Phase 2: stage, with the service running.** Mac side, with tests:
`config/asound-inferno-owner-usb-aoip-rate882.conf` (the installed 8549af7e with
`SUPPORTED_SAMPLE_RATES "44100,48000,88200,96000"`), a `transport.conf` with the
`_88200` keys (96's arm A values, no drop yet), `test-dante-start.sh transport`
extended to the 88.2 line. Copy to `~/usb-16x16-work/dante-mode/`.

**Phase 3: candidate at 88.2, arm A.** The domain to 88.2 including the Pi through a
candidate config: as the 96 work did, the installed owner as a candidate with
`CONFIG=` the staged Inferno config and the arm A arguments at `--rate 88200`,
started only after the arbiter and start check have settled (handoff 2026-11-01:
stopping the service mid-move makes the arbiter start it beside the candidate).
Every harness open waits 10 s after the rate is verified (`dante-sync` does it).
Checks: noise probe; the prime-drop sweep with capture drain, six opens of 100
impulses at D = 48, 72, 96 (the level should fall about one sample per frame of
drop, as at 96, with no unanchored prime); then the battery on the chosen D: four
loaded 800-impulse runs, 600 s soak on 1-8, `bitexact --loop-channels 8`, owner
counters clean.

**Phase 4: back to 48.** Candidate stopped, service started, `dante-sync sync
--rate 48000`, start check ok, 528.

**Phase 5 (on a passed battery): offer it.** One hash-pinned installer with a
`rollback` (at 48 only, as rate96's, since the applier rewrites `SAMPLE_RATE`):
the Inferno config and transport.conf. After it, under the service at 88.2: noise
probe, three opens, a 120 s soak; a Mac-side move to 88.2 and back through the
arbiter; a page preset following to its `@88200` file.

## What the Pi cannot do, and what is left to the operator

The 10 s rule binds the Mac, not the Pi. After the arbiter moves to 88.2 and asks
the Mac to follow, anything that starts audio on USB-AoIP in the next 10 s risks
the silent state: start audio only after `dante-sync` reports, or wait by hand.
The recovery is the slow change (48, wait 10 s, 88.2, wait 10 s). If Phase 0
shows Pro Tools is affected, the only fixes are on the Mac (a driver, or a Pro
Tools workflow that sets the rate before the session opens), which is why Phase 0
comes first.

## Rollback

Nothing is installed before Phase 5. Phase 5's installer has its own `rollback`,
which comes before install-dante-rate96-drop96.sh's.

## Questions for the operator

1. Phase 0 needs you at the Mac with Pro Tools: an 88.2 session to open with
   USB-AoIP as the playback engine, Follow Rate Changes off, monitors muted (the
   noise probe plays noise). When suits you?
2. Do the Pulse, the D2USB and DVS need to run at 88.2, or only the Pulse (the
   loop) and the Metric Halo?
3. The same 8-channel loop on MADI 25-32 as at 96?

## Results, 2026-11-01 afternoon (operator away; the Mac driven from the session)

Phase 0 replaced by a CoreAudio stand-in (operator: "set the Pi to 88.2 some other way in
CoreAudio"): `outputs/latency/rate882-macrule-20261101/` (`steps.txt`, `run-macrule.sh`,
`run-tight.sh`, `run-persist.sh`). Service stopped, the October USB-only `alsaloop` on the Pi,
Dante Switcher's app quit for the run (its follow would have moved the network).
- October's quick change (set 88.2, loop restarted, the harness open about 3.5 s after the set):
  clean on 3 of 3 from 48 and 3 of 3 from 44.1 (October: bad 7 of 7). Slow change clean.
- Tighter, nearer a DAW: the harness open about 0.3 s after the set: 94.5-95.6 % zeros on 6 of 6,
  the October signature (zero runs of 660-690 on an 8 ms cycle). But it no longer persists: the
  next two opens at 88.2, no rate change between, were clean (October: stayed bad across app
  restarts until the next rate change).
- So today: audio started within about 0.3 s of the switch is silent for that IO session only;
  reopening clears it; from about 3.5 s it is clean. Pro Tools itself still untested; if a session
  opens silent at 88.2, stopping and restarting its engine (or reopening) should clear it.

Phase 1 passed (`outputs/latency/rate882-20261101/steps.txt`): `dante-sync sync --rate 88200
--allow-band-up` with the service stopped, then `sync --source usb-aoip` for the Metric Halo (the
Pulse's word clock is unlocked until MHLink follows): the Pulse, D2USB, DVS and MHLink all at 88.2,
the Pulse locked.

Phase 3 (candidate c84e6a36 on `config/asound-inferno-owner-rate882-usb-aoip.conf` 50997640, 96's
arm A at `--rate 88200`, capture drain): the prime-drop sweep, six opens of 100 impulses each,
noise clean at every D, no unanchored prime:
- D=48 912-913; D=72 888-889; D=84 876-877 on 3 opens and 932-933 on 3 (`tx_prime_found` 236:
  the prime anchored a block later); D=96 909-920. 72 is the last drop that anchored early on
  every open. The +-1 is 88.2's non-integer packet grid.
- Battery on D=72: noise 0; four loaded 800-impulse runs 889 / 889 / 888 / 889 (10.07 ms);
  600 s soak on 1-8 PASS; `bitexact --loop-channels 8` 360 s FAIL on one event: an all-channel
  swap of two 8-frame blocks 267 s in (8 dropped at frame 23532316, 8 repeated 8 later), 2
  lost locks a channel, bit-exact before and after. The owner saw nothing (no resync, loss,
  fault, re-prime or servo rejection; `out_holes` 2/993 at the start as at 96, `back_holes`
  0/0; return queue floor 86). Not located: no capture ran (none during measurements).
- Staged, not installed: `config/asound-inferno-owner-usb-aoip-rate882.conf` (85a5256f, the
  installed 8549af7e with 88200 offered), `service/transport-rate882.conf` (add1bc21, the
  `_88200` keys with `PRIME_DROP_88200=72`), `service/install-dante-rate882.sh` (03e2d2c0; at 48
  only; its `rollback` before install-dante-rate96-drop96.sh's), `test-dante-start.sh transport`
  extended (48, 44.1 and 96 lines unchanged; passes on the Mac and the Pi).
- Repeated (`run-bitexact-rerun.sh`, the domain moved again, the same candidate): two 360 s
  `bitexact` runs PASS, 0 lost locks; owner clean (`out_holes` 4/961, two at each start). The
  swap was one event in 18 minutes of `bitexact` and did not recur; where it came from is not
  known (the far loop at 88.2 or the Dante flows; only a capture would say).
- Left at 48: service active, start check ok, 528, Dante Switcher relaunched.

Installed by the operator 2026-11-01 ~17:28 UTC (`install-dante-rate882.sh`). Phase 5 under the service
(handoff, MEASURED 2026-11-01 17:30): a Dante-side move and a Mac-side move (`setrate`, the arbiter asked by the
owner) both land at 889 at every open (three each), noise 0, 120 s soaks PASS, every prime anchored; a page preset
follows to its `@88200` file (`dsp_us_max` at most 179); 528 at 48 after each. Evidence
`outputs/latency/rate882-service-20261101/` and `outputs/latency/rate882-page-20261101/`.

ACCEPTED by the operator 2026-11-01. Pro Tools at 88.2 then used by the operator on the service: works, no silent open.
Still open: the single unlocated `bitexact` swap.
