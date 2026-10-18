# Multi-rate gadget experiment (sample-rate step 5)

Written 2026-10-17. Plan only: nothing staged on the Pi, nothing run. The
design is `work/dante-mode/SAMPLE_RATE_DESIGN.md` (step 5 and "Transparent
switching"); the handoff tail wins where they differ.

## What changes and what does not

`work/pi-tuning/setup-usb-16x16-multirate` (sha256 `c420a0b8`) is
`setup-usb-16x16-req` (`b11fd358`, installed as `/usr/local/sbin/setup-usb-16x16`)
with three differences:

- `p_srate` and `c_srate` take a rate list (default `44100,48000,88200,96000`),
  the same list both ways. The installed module's shared-clock patch needs the
  two lists identical, and one host SET_CUR sets both directions.
- `start` refuses while `usb16x16-dante` or `usb16x16-aes67` is active, or
  when `usb_f_uac2` is not one of the two known shared-clock modules
  (`8e9907d3`, `87989337`). After writing, it checks that both lists read back
  as written.
- `rollback` checks that the installed script is still `b11fd358`, then runs
  `systemctl restart usb-16x16.service`. The unit's own start tears this gadget
  down and rebuilds the protected one. Rollback then requires
  `p_srate=c_srate=48000` and `configured/high-speed` within 20 s. `status` is
  read-only.

Never installed. Nothing in `/usr/local`, `/etc` or the unit changes. The
script runs by hand from `~/usb-16x16-work/gadget-multirate/`. A reboot also
brings the protected gadget back.

**It changes the 48 kHz operating point too.** With `*_hs_bint=0`, the kernel
sizes the endpoints for the largest rate in the list (`get_max_bw_for_bint` in
`f_uac2.c`). With 96000 in the list, that is 624 bytes every 125 µs
(bInterval 1) at every rate. The protected gadget sends 624 bytes every 250 µs
(bInterval 2). 96 kHz needs 13 frames × 48 bytes every 125 µs and does not fit
at bInterval 2, so there is no choice here. This is the `bint1` point of
2026-09-05: 15 samples lower on AES67, noise probes clean, but RTL Utility
showed errors at 32 frames once. So a 48 kHz reading on this gadget is a new
point. It is not the protected gadget. A list without 88200 and 96000 keeps
bInterval 2.

**Which rate shows at enumeration.** The clock reports the first rate in the
list until the host sets one (`p_srates[0]`), and GET RANGE lists the rates in
the order written. So the list order is a variable in Q4.

**Controls read 0 while the host has the interface down.** `Capture Rate` and
`Playback Rate` show a rate only while the Mac is streaming. A change made in
Audio MIDI Setup with nothing open shows only when the next stream opens.
`amixer events` shows each change as it lands.

## Before anything (operator)

1. Stage, between runs, one file: `scp work/pi-tuning/setup-usb-16x16-multirate
   bdimaio@192.168.1.201:~/usb-16x16-work/gadget-multirate/`. Check its sha256
   on the Pi (`c420a0b8`). This is the only step that could be done from a
   session. It is a copy of a small file and does not touch USB.
2. Mac: monitors muted (the probes put 0.1 load on fifteen channels).
   RTL Utility, Pro Tools and Logic closed unless a step says otherwise.
   Dante Switcher's watcher paused, so it does not act on rate changes the
   test makes.
3. Pi, password-free: `systemctl stop usb16x16-dante` (Statime can stay up).
   From here the endpoint is down, and every step is USB-only.
4. Pi, in a terminal of its own for the whole session:
   `stdbuf -oL amixer -c UAC2Gadget events | while read -r l; do echo "$(date -u +%T.%N) $l"; done | tee /dev/shm/multirate-ctl.log`
   (`alsactl` is in `/usr/sbin`, off the user's path; `amixer events` needs no root).
   A second terminal: `journalctl -kf | tee /dev/shm/multirate-kernel.log`
   (resets, disconnects, the kernel's "may drop data" warning).
5. Evidence goes in `outputs/latency/multirate-gadget-<UTC>/`. Each harness
   run is labelled `mr<rate>-<list>-...`.

The USB-only loop used throughout: Pi `alsaloop -C hw:UAC2Gadget -P
hw:UAC2Gadget -f S24_3LE -c 16 -r <RATE> -t 20000` (as `measure-usb-only.sh`,
which hard-codes 48000), started after the Mac is at `<RATE>`. The noise probe
(the hole check): `USB16X16_DUMP=<raw> usb16x16-latency measure --device "USB
16x16" --buffer-frames N --output-channel 1 --input-channel 2
--other-channel-load-amplitude 0.1 --impulses 100 --maximum-lag-ms 200`, then
`outputs/latency/usb-holes-20260904/zeros.py <raw> N`. `measure` takes the
device's rate. `continuous` and `bitexact` are pinned to 48 kHz and refuse
any other rate (`ContinuousLoad.swift:73,157`, `BitExact.swift:168,228`).

## Phase 0: same-day control on the protected gadget (nothing changes)

`status` on the Pi (it works before the swap). Then alsaloop at 48000 and
noise probes at 512, 64 and 32. This is today's reference for "no drops".

## Phase 1: the swap (USB side, operator's sudo)

`sudo ~/usb-16x16-work/gadget-multirate/setup-usb-16x16-multirate start`
(the default list, ascending). Expect `configured/high-speed` within 20 s.
Then `status`. Read on the Mac:

- Audio MIDI Setup: is the device still `USB 16x16`, with 16 in and 16 out
  labelled `1` to `16`, one device and no aggregate? Which rates are offered?
- Which rate does the Mac pick at first enumeration? This is Q4's first data
  point: the Mac was at 48 before, and the clock reports 44100.
- `usb16x16-latency inspect --device "USB 16x16"`: nominal and actual rate,
  buffer size.

Fail and roll back: the device is missing or doubled, the labels are lost,
there is a kernel warning, or the device is not `configured`.

## Q1: does a CoreAudio rate change reach `Capture Rate` / `Playback Rate`?

For each rate in the order 48 → 96 → 44.1 → 88.2 → 48, the rate set in Audio
MIDI Setup:

1. Read the `amixer events` log: was there an event, and when?
2. Open a stream: the noise probe at 512 frames (alsaloop started at that
   rate first). During it, `amixer -c UAC2Gadget cget iface=PCM,name='Capture
   Rate'` and `'Playback Rate'` must both read the rate set. The stream needs
   the loop, since without it the probe sees no return.
3. Check that the gadget PCM refuses a rate the host is not at: alsaloop at
   48000 while the Mac is at 96000 must fail in hw_params. The owner's
   gadget-rate check relies on this as the last line of defence.

Then the same set made two other ways, at 96 and back to 48:

- A Logic project at 96 kHz with `USB 16x16` as its device. The DAW sets the
  rate.
- Dante Switcher's CoreAudio set of the USB 16x16 (its PLAN.md Phase 3
  step 2), one command, with its watcher still paused.

Pass: both controls follow every change, and only by a change event, with
one SET_CUR per change. Capture and Playback never disagree once a stream is
up. No re-enumeration in the kernel log.

## Q2: does the Mac re-open the device without it vanishing?

Run alongside Q1. With Logic open on the device (and, once, Pro Tools),
change the rate in Audio MIDI Setup:

- The Mac: the device stays in Audio MIDI Setup and in the DAW's device list.
  The DAW does not fall back to built-in output. Record any dialog the DAW
  shows. `usb16x16-latency list` before and after shows the same one device.
- The Pi: `udc` stays `configured` throughout, with no disconnect or reset
  in `journalctl -k`. A rate change is an alternate-setting cycle, not a
  re-enumeration. `amixer events` shows the interface going down (controls
  0) and coming back at the new rate.

Pass: no vanish, no re-enumeration, and audio back in the DAW without
re-selecting the device.

## Q3: do sixteen 24-bit channels at 96 kHz hold at 32 frames without drops?

Mac at 96000, alsaloop at 96000, harness alone. Noise probes at 512, 64, 32
and 16 frames, then five more at 32. Two controls the same day on this
gadget: 48000 at 512, 64 and 32 (this tests the change to bInterval 1), and
Phase 0 on the protected gadget. 44100 and 88200 get one 32-frame probe each.

Pass for 96 kHz: 0.0 % zeros and no run of 4 or more in every 32-frame probe,
no CoreAudio discontinuity flags, no kernel warning. The 64-frame
all-channel hole the Mac flags now and then (2026-10-17) is counted, not
failed, if the probe's flags show it.

If 96 drops: change one variable per stop, so `start <list> 8` (req_number 8)
next, then 16 frames is dropped from the pass. If `start 96000` alone is clean
where the full list drops, the cause is the list, not the rate.

Missing for a real soak: a ten-minute sixteen-channel run at 96 kHz needs
`continuous` to take the device's rate instead of the 48 kHz pin. That is a
small Mac-side change to the harness, written and tested before Phase 3 if
this pass is clean.

## Q4: which way does the Mac follow after a re-enumeration?

Each arm: set the Mac to the "before" rate in Audio MIDI Setup and open a
stream once, so the Mac has used it. Then re-enumerate with `sudo ...multirate
start <list>`. Read the rate Audio MIDI Setup shows, then, with a stream open,
the Pi controls.

| Arm | List (first = clock's rate) | Mac before | Tells |
|---|---|---|---|
| A1 | `44100,48000,88200,96000` | 96000 | Does the Mac keep its remembered rate or take the clock's? |
| A2 | `48000,44100,88200,96000` | 96000 | The same with 48 first. Also: does macOS accept a list not in ascending order at all (offered rates, or does the device vanish)? |
| A3 | `96000` | 48000 | Option (b): the only rate offered. The Mac must take 96. |
| A4 | the default list, then `sudo killall coreaudiod` on the Mac | 88200 | Does a fresh coreaudiod keep the remembered rate too? |

Then **rollback**, from 96 on the Mac: `sudo
~/usb-16x16-work/gadget-multirate/setup-usb-16x16-multirate rollback`. Audio
MIDI Setup must read 48000 with the device in place (the protected gadget
offers nothing else). "The Mac decides" makes the answer less important. What
matters is that a re-enumeration never leaves the Mac and the Pi at different
rates without the Pi's controls showing it.

## Optional Phase E, a separate go: the owner on the multi-rate gadget

Only with a separate go. It runs the endpoint on the new gadget. On the
default list, at 48: `systemctl start usb16x16-dante`, wait for start-check
`state=ok`, then `measure-candidate.sh noise 32`. Then set the Mac to 96 in
Audio MIDI Setup. Expected from step 4: the owner sees the host leave, reads
`host_rate=mismatch`, keeps the USB half closed and writes `rate=96000
source=usb`. The arbiter refuses (96 not offered) and nothing restarts. Set
back to 48: the USB half rejoins. This is the first live test of the step-4
path from the USB side. It is not an acceptance: the owner on bInterval 1
at 48 kHz would need its own battery and hour before the gadget could ever
replace the protected one.

## Close (always)

`sudo ...multirate rollback` (or the reboot). Then `status` must read
`p_srate=48000` and `experiment: not active`. `systemctl start
usb16x16-dante`, start-check `state=ok`, a noise probe after the endpoint
start, the Mac at 48000 and Dante Switcher's watcher back on. Copy
`/dev/shm/multirate-*.log` into the evidence directory between runs, never
during one.

## What the answers decide

- Q1 and Q2 pass, and Q3 is clean at 96: step 6 (96 kHz end to end) can use
  this gadget, the multi-rate gadget becomes a candidate for the protected
  role, and a 48 kHz battery and hour on bInterval 1 come first.
- Q3 drops at 96 even with req 8: the offered list stops at 48 (and 44.1, if
  44.1 is clean), and 88.2 and 96 wait on a different gadget transport.
- Q1 fails (controls do not follow): the owner's gadget-rate check and the
  arbiter's USB signal have no source. Rate changes would have to come from
  Dante Switcher's packet alone.

## 88.2 kHz and macOS: wait 10 s after switching (found 2026-10-18)

**The rule.** After the USB 16x16 is switched to 88.2 kHz, wait at least 10 seconds
before anything starts audio on it. That includes a DAW, the harness, RTL Utility
and the Dante endpoint's USB half. 44.1, 48 and 96 kHz need no wait.

**Why.** macOS (AppleUSBAudio / CoreAudio) can get into a state where it passes
silence on the USB 16x16 in both directions. When that happens, the USB stream keeps
running perfectly: right packet sizes, right timing, no errors. The data just never
reaches the app, so most samples are zero (75-98 % in the runs, in an 8 ms
cycle). The Pi is not at fault. A per-packet trace of the gadget showed its IN and
OUT streams identical in good and bad states, except that in a bad state the
packets the Mac sends carry zeros. It happens only at 88.2 kHz, and only when audio
starts within a few seconds of the switch: bad 7 of 7 with audio starting about
2.5 s after the set, clean every time from about 7 s. Once in the bad state it stays
there across app restarts until the rate is changed again. Evidence:
`outputs/latency/rate882-dirtest-20261018/` and `PROJECT_HANDOFF.md`, the 2026-10-18
FOUND entries.

**What does the waiting.**
- **Dante Switcher** (`~/Development/Dante Switcher`): `dante-sync sync` holds 10 s
  (`--usb882-settle`) after the USB 16x16 is verified at 88.2 kHz, before it reports
  done. Start audio only after the sync finishes.
- **A DAW that sets 88.2 kHz itself** (opening an 88.2 project) starts audio at
  once, so nothing can make it wait. `dante-sync watch` logs a warning when this
  happens.
- **By hand** (Audio MIDI Setup, the harness): wait the 10 s yourself.

**If audio on the USB 16x16 at 88.2 kHz is silent or full of holes**, recover it:
stop audio on the device, set it to 48 kHz, wait 10 s, set 88.2 kHz, wait 10 s,
then start audio. The slow change came out clean every time, including straight
after a bad state. Untested with a DAW holding the device open; quitting the app
first is the safe form.

**Not known.** Why macOS does this; whether a Linux host does it too; whether
`killall coreaudiod` clears a bad state; whether anything the gadget does
(feedback value, packet pattern) provokes it. Recheck after a macOS update with
`quickwin.sh` and `slowwin.sh` in the evidence directory, run without the trace.
