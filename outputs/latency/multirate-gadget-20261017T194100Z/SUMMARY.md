# Multi-rate gadget, 2026-10-17: 96 kHz pass (Q3, Q1 first change)

Gadget: `setup-usb-16x16-multirate start` (c420a0b8), default list
44100,48000,88200,96000, req_number 4, bound 19:38:42 UTC, configured/high-speed.
Dante endpoint stopped. USB-only loop: Pi `alsaloop -C/-P hw:UAC2Gadget -f S24_3LE
-c 16 -r 96000 -t 20000` (user, no RT priority; it holds the control device and
steers `Capture Pitch`, read 1000005). Harness alone, monitors muted.

- Q4, first point: Mac was at 48000 before the swap; at first enumeration it came up
  at 44100 (the clock's first-listed rate, reported before any host set).
- Q1, first change: AMS 44100 -> 96000 at 19:41:29 UTC. Pi: four Capture/Playback
  Rate event pairs within 1.1 s, both controls then read 96000, no kernel reset or
  disconnect, UDC stayed configured. Gadget PCMs opened at 96000 (period 341,
  buffer 5456).
- Q3, noise probes at 96000 (100 impulses, out 1 / in 2, 0.1 load), zeros.py:

| frames asked | frames granted | zeros | runs >= 4 | in/out discontinuities |
|---|---|---|---|---|
| 512 | 512 | 0.0 % | 0 | 0 / 0 |
| 64 | 64 | 0.0 % | 0 | 0 / 0 |
| 32 | 32 | 0.0 % | 0 | 0 / 0 |
| 16 | **29** (Mac minimum at 96 kHz) | 0.0 % | 0 | 0 / 0 |
| 32 x5 | 32 | 0.0 % each | 0 | 0 / 0 |

Each probe ~2.49 M samples. Kernel log quiet throughout; alsaloop logged no xrun.
Not yet done: 48 kHz control on this gadget, 44.1/88.2, Q2 (DAW), Q4 arms, a
ten-minute soak (harness `continuous` is 48 kHz-only), Phase 0 at the close.

## 20:03-20:12 UTC: 48 / 44.1 / 88.2, and the rate-open checks

Rate changes from 20:06 on were made by a CoreAudio
`kAudioDevicePropertyNominalSampleRate` set (scratchpad `setrate`, the call AMS and
Dante Switcher make), with the operator's leave. Every change: two to four
Capture/Playback Rate event pairs within ~1 s, both controls at the new rate, UDC
configured, kernel log quiet (Q1 and the Pi half of Q2 pass at every rate).

| rate | frames | zeros | runs >= 4 | discontinuities |
|---|---|---|---|---|
| 48000 | 512 / 64 / 32 | 0.0 % each | 0 | 0 / 0 |
| 44100 | 32 | 0.0 % | 0 | 0 / 0 |
| **88200** | 32 | **75.3 %** | 3211, runs ~520-540 | 0 / 0 |
| **88200** | 512 | **36.9 %** | 9674, runs ~34 and ~95-101 | 0 / 0 |

88.2 kHz FAILS in the USB-only loop at every buffer size, silently (no CoreAudio
flags, no alsaloop underrun, no kernel message). At 88.2 alsaloop never logged a
pitch adjustment; at 96 it did, regularly. Direction not located: a Pi `arecord`
of the Mac's output read all-zero at 96 kHz too (the method is broken, not
evidence), so it was dropped after two tries.

Rate-open behaviour on this gadget:
- A PCM opened at 96000 kept running after the host moved to 48000 (one playback
  underrun logged, no error). The rate check at open is the only guard.
- Opening at 96000 with the host at 48000 does not fail: the gadget PCM offers only
  the host's current rate and `set_rate_near` silently returns 48000. The owner
  uses `set_rate_near` but then refuses a rate other than `--rate`
  (`owner/main.cpp` USB open, "negotiated sizes"), so it is protected; alsaloop is not.

Left at 48000, alsaloop stopped. Not yet done: Q2 with a DAW, Q4 arms, 88.2 cause,
96 kHz soak, Phase 0 at close.
- Controls read 0 with no stream open (20:12 UTC), as the plan expected; the 44100 read right after the swap was the Mac still streaming.

## Q2, 21:18-21:26 UTC: Logic Pro 12.2 open on the device (in and out USB 16x16, 256)

- CoreAudio set to 96000 under an open 48 kHz project (21:24:49): the set landed, both
  Pi controls followed, and Logic put its project's 48000 back within ~2 s (12 control
  events). No dialog, device kept, UDC configured, no kernel message. The DAW owns the
  rate while a project is open.
- New empty project at 96 kHz (21:25:53): Logic set the device to 96000; Pi controls
  96000 after four event pairs in 1.3 s; UDC configured; Logic kept the device (96 / 256).
- Q2 PASS: no vanish, no re-enumeration, no device re-selection, either way the rate moved.
- Unrelated: one `eth0` TX stall in the kernel log at 20:22:00 UTC (Dante stopped). Check
  eth0's TX counter before the endpoint comes back.

## Q4, re-enumeration arms

- A0 (the first swap, 19:38:42): Mac at 48000 on the protected gadget; came up at
  44100, the clock's first-listed rate.
- A1 (21:27:21, default list, clock reports 44100 first; Mac before: 96000 via Logic,
  Logic quit): Mac kept 96000; Pi controls 96000 after enumeration. The Mac set its
  remembered rate, not the clock's. (A0 vs A1: likely no stored rate for this rate list
  the first time.) The re-enumeration removes the card, so the `amixer events` logger
  dies (ERR -19) and must be restarted after each one.
- A2 (21:38:16, list `48000,44100,96000`, clock reports 48000 first; Mac before 96000):
  Mac kept 96000; Pi controls 96000. macOS accepted the unsorted list and offers it
  sorted (CoreAudio available rates 44100,48000,96000); device enumerated normally.
- A3 (22:04:27, list `96000` only, option (b); Mac before 48000): Mac took 96000
  (CoreAudio offers only 96000); Pi controls 96000. Option (b) forces the Mac as designed.
- A4a (22:06:26, default list, clock 44100 first; Mac last *chosen* 48000, then forced
  to 96000 by A3): Mac came up at 48000. A rate forced by a one-rate list is not stored
  as the Mac's choice; the last chosen rate is.
- A4b (Mac set to 44100 at 22:06:40, then `sudo killall coreaudiod`, new coreaudiod
  22:07:00 local): Mac kept 44100; Pi controls 44100; UDC configured.

Q4 answer: macOS follows its own remembered *chosen* rate for the device (kept across
re-enumeration and a coreaudiod restart), not the clock's first-listed rate, except
when it has none stored for that rate list (A0) or the remembered rate is not offered
(A3, option (b) works). "The Mac decides" holds; the gadget cannot push a rate except by
offering only that rate. Mac set back to 48000 at the end so the stored choice is 48.

## Close, 22:08-22:13 UTC

- Rollback by the operator (`setup-usb-16x16-multirate rollback`): protected gadget
  rebound 22:08:33 UTC, p_srate=c_srate=48000, req_number 4, configured/high-speed;
  CoreAudio offers 48000 only; `status` reads "experiment: not active".
- Phase 0 (run at the close, same day): protected gadget, alsaloop 48000, noise probes
  512 / 64 / 32: 0.0 % zeros, no runs, no discontinuities (`phase0-protected48-*`).
- eth0: 1000 Mb/s, address in place, TX counter moving; one TX stall in the session
  (20:22:00 UTC), none since.
- `sudo -n systemctl start usb16x16-dante` 22:10:38 UTC; start check state=ok 22:11:43
  (6015 frames/s, restarts 0); noise probe at 32 on the Dante stack
  (`close-multirate-noise-ch2-32f-20261017T221149Z`): 0.0 % zeros, no runs, owner
  xrun/lag/error lines 0, rate 48000.
- Pi logs copied here as `pi-multirate-*.log` (control events, kernel, each alsaloop).

## Answers

1. Q1 PASS: every CoreAudio set (AMS-equivalent, Logic) reaches Capture/Playback Rate,
   2-4 event pairs within ~1 s, both directions agree, no re-enumeration.
2. Q2 PASS: Logic keeps the device through rate changes either way; no vanish.
3. Q3: 96 kHz PASS at 512/64/32/29 frames (nine probes); 48 and 44.1 clean at 32;
   88.2 FAILS silently at every buffer (cause and direction open). bInterval 1 at 48 kHz
   was clean USB-only, as was the protected bInterval 2.
4. Q4: the Mac sets its own remembered chosen rate after a re-enumeration and a
   coreaudiod restart; the clock's first-listed rate matters only when nothing is stored;
   a one-rate list forces it.
Not done: ten-minute soak at 96 (harness `continuous` is 48 kHz-only); 88.2 diagnosis;
the owner on the multi-rate gadget (Phase E).
