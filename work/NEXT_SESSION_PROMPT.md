# Next-session pickup prompt

Paste the block below into a fresh Codex or Claude Code session to resume work.
It points at `PROJECT_HANDOFF.md`, which is authoritative where it conflicts
with this summary.

Rewritten 2026-09-06 late: three levers accepted on the day (RTL at 32 from
21.062 to 19.958 ms on fresh anchors), the fresh-anchor procedure holds to
the sample, and the next lever is the prime margin's 5 frames, a bridge
build that reorders the aligned TX prime.

---

Raspberry Pi 5 USB 16x16 / AES67 bridge. Repo: ~/Development/USB 16x16
(github.com/squeaksquad/usb-16x16-aes67, main, pushed and clean).

Read the Rollback rules at the end of PROJECT_HANDOFF.md, then everything
from "IMPLEMENTED and STAGED 2026-09-06 21:37 UTC" to the end
(chronological, bold lead-ins; a CORRECTION paragraph wins over the entry
it amends), then the BUDGET entry "BUDGET 2026-09-06 00:40 UTC" for the
lever pricing, then work/aes67-bridge/aes67.conf's blocks for
servo-aligned-both-240-rx120-sd144-tx192-target48-trace-txoff950 and
...-target48-trace-txoff950-rxtrim, and work/phase4-bridge/src/main.cpp:
the aligned TX prime (~1345-1445: the hold, the front drop, the target,
kAlignPrimeMarginNs at ~85), the PRIMED overshoot/trim code just after
it (rx_prime_trim gates it for RX), and align_playback_trigger
(~1275-1325, target= and slack_us=).

NOTHING IS BROKEN. The service runs the accepted profile on a fresh
anchor with the labels copied. No installs pending. Playback is on.

THE POINT OF RECORD (accepted 2026-09-06 23:50 UTC)
Profile servo-aligned-both-240-rx120-sd144-tx192-target48-trace-txoff950-rxtrim
(target48 plus RX_PRIME_TRIM=1: ALIGN_TX_OFFSET_US 950, TARGET 48, the
RX prime trimmed to intended) on bridge 913d623b (--rx-prime-trim; the
aligned prime margin 150 us; the ALIGN trigger line carries
target=prime|prime-missed|next and slack_us=), supervisor 431cf0c5
(RX_PRIME_TRIM key), module cc6852f0 (loaded from
~/usb-16x16-work/ravenna-tx-fix-install/; original f65a4955 for
rollback). Fresh anchor: 770 at 64 frames, RTL Utility at 32 frames
19.958 ms = 770 + 188 to the sample; 4 x 800 loaded and the 600 s soak
all on 770, zero RECOVERs; TX floor 87 loaded (scatter 87-96), RX 72,
tx_pullmax 48, tx_occ / rx_occ 51; Pi path 726, AES67 index chain 633,
RX PRIMED ring_at_prime 192 trimmed 21. The day's chain on fresh
anchors: target64-trace 823 / 21.062, txoff950 797 / 20.521, target48
785 / 20.271, rxtrim 770 / 19.958. Yardstick: Dante Virtual Soundcard
11.312 ms at 32. Rollbacks by switch-profile: ...-target48-trace-txoff950
(785; the installed bridge runs it unchanged, flag 0) or
...-target64-trace-txoff950 (797); bridge sets phase4-rxtrim-install/
(current), phase4-txoff950m150-install/ (0d8cccfa, no flag),
phase4-trace-install/ (c1ca48c5) with their aes67-*-install/ installers
(the supervisor must match the bridge: 431cf0c5 passes --rx-prime-trim,
which 0d8cccfa rejects).

WHAT THE DAY SETTLED (do not re-derive)
- The Mac reports a level set on usbaudiod's timeline at each gadget PCM
  restart; only a fresh anchor (sudo systemctl restart usb-16x16.service,
  the AES67 service restarts itself, about 60 s to STAGE running) reads a
  known figure. Every read today landed where the arithmetic said.
- The level follows the TX front age 1:1 on fresh anchors (336 / 312 /
  317 / 301 -> 823 / 793 / 797 / 785).
- The aligned wait allowance was TX cover: the TX queue's level is the
  front age less the ring, so lever 1 took 19 off the TX floor (107 ->
  88). The ring target is not cover: lever 2 left the TX total alone.
- The prime path from placing its target to entering the trigger takes
  83-104 us (the drop, the PRIMED line, the 192-frame render, the commit);
  a margin under that misses primes, and a miss moves the start one tick
  (+48 that session). 150 us covers it; slack_us shows it every session.
- The RX prime is checked at USB capture wakes and the ring grows 96 per
  wake, so it lands at ring 192 whatever intended is (187 or 171); the
  overshoot was permanent RX depth. The rxtrim lever pops it (21 at
  intended 171) before the render: the RX index dwell moved by exactly
  21, the level by 15 (the remainder outside the bridge read 12 higher,
  fresh-anchor scatter), the RX floor 93 -> 72. The 77 every rx120
  profile carried had the 5 of intended 187's overshoot inside it; 72 is
  the trimmed cover, 15 over the worst RX refill gap of the day's sets
  (57 frames in 1.178 ms). RX_PLAYBACK_PRIME 125 would restore 77 for 5
  samples, conf only, if wanted.
- After the gadget re-bind the AES67 service restarts itself and the
  stage file passes through "ptp locked" before "running"; the PRIMED
  lines in /run/usb16x16/bridge.log before that are the old session's.
- The old target48 session took two RECOVERs at 21:35 UTC while the rxtrim
  source tree was sent to the Pi as one tar stream over ssh (service
  running, no measurement). One event, not proven causal; stage file by
  file, or in the service-stop window.

THE PROCEDURE (every measurement session starts with it)
1. Playback off (ask). Nothing on the Mac holds the device open; the
   harness and RTL Utility never share it.
2. Fresh anchor: the user runs sudo systemctl restart usb-16x16.service.
   usbaudiod logs fresh setStartingUSBFrame lines (/usr/bin/log show
   --last 10m --predicate 'process == "usbaudiod"'; the bare word log is
   a zsh builtin). Wait for STAGE running on the Pi, read the ALIGN,
   PRIMED and ALIGN trigger lines: front_age_frames, intended,
   ring_at_prime, overshoot, target=prime, slack_us.
3. Gate: channel-2 noise probe at 64 (--input-channel 2 --output-channel
   1 --other-channel-load-amplitude 0.1, 100 impulses, USB16X16_DUMP to
   the scratchpad, zeros.py in outputs/latency/usb-holes-20260904/): 0.0%
   zeros, no run. A Mac hole state is cleared by sudo killall coreaudiod
   on the Mac (itself a fresh anchor).
4. Read: work/aes67-candidate/measure-under-service.sh 64 100 <label>.
   Then copy /run/usb16x16/bridge.log into
   outputs/latency/stage-trace-20260906/ (between runs, never during) and
   split it: python3 outputs/latency/stage-trace-20260906/impulse-index.py
   <log> --level <N>. Report level, pi_total, usb_time, pos_aes67, the
   PRIMED lines. Compare levers by pi_total and by the level on fresh
   anchors only.
5. Acceptance: four 800-impulse runs and the 600 s soak, all with
   USB16X16_OTHER_LOAD=0.1, detached (Popen start_new_session, a Monitor
   polling the log for an exit= line), zero RECOVERs inside runs, floors
   reported, RTL at 32 by the user, on one fresh-anchor session; then the
   block's MEASURED/COVER/STATUS, the conf pin, and a copy-<tag>-labels.py
   for the live conf (labels only, dry run without --apply).

THE LEVERS, IN ORDER, ONE AT A TIME (all builds; pricing from BUDGET)
1. The prime margin's 5 frames: render the TX prime before placing the
   trigger target (compute the drop from the grid phase at the prime
   wake, render the 192 frames, then place the target with the margin as
   real slack, 50 us), so the longest wait is 53 frames instead of 58 and
   the TX front age 296. Expect about 765 at 64 on a fresh anchor and the
   TX floor 5 lower (about 82-91 loaded); the TX cover is the thing to
   watch, 3.7 ms was the worst gap of 2026-09-06 and TX prime 192 holds
   about 30 spare over it now. The measured prime path is 83-104 us, so
   the render must be inside the wait between the drop and the target; the
   ALIGN trigger's target= and slack_us= are the check. Done RX prime
   trim: main.cpp 77450aaa is the base.
2. Sink delay 144 -> 120, 24 samples, only after the arrival lead is
   exported (the one-line sink_min_time plumbing in RTP_audio_stream.c, a
   module rebuild on the rollback path); at 96 the 41-sample holes came
   back, at 144 zero in 45 min.
Do not touch the TX prime (192), the RX prime (120), the offset (950),
the ring target (48) or the RX trim inside this work.

BUILD AND INSTALL RULES
- Syntax-check on the Mac first: clang++ -std=c++20 -fsyntax-only -Wall
  -Wextra -Wpedantic -Werror with the Pi's ALSA headers as system
  includes (~/usb-16x16-work/deps/libasound2-dev/usr/include/alsa on the
  Pi; copies in earlier scratchpads under
  /private/tmp/claude-501/-Users-bryandimaio-Development-USB-16x16/*/
  scratchpad/alsa-include) and shims for endian.h, clock_nanosleep /
  TIMER_ABSTIME and ESTRPIPE (86). Core tests build on the Mac without
  ALSA. Build on the Pi only with the service stopped (the user stops
  it); stage the source in a fresh ~/usb-16x16-work/phase4-<tag>-src/
  with a build.sh that refuses while the service is active (copy
  phase4-rxtrim-src/build.sh). No transfers while a measurement runs;
  stage file by file while the service runs, not as one tar stream.
- A new bridge binary needs THREE pins moved: install-candidate.sh,
  install-aes67-service.sh (bridge and supervisor pins, the full 64-hex
  hash), and the supervisor's expected_bridge_sha256; the artifact in
  work/phase4-bridge/artifacts/pi-aarch64/ and the README paragraph.
  Stage phase4-<tag>-install/ (binary, wrapper 6282b108, installer) and
  aes67-<tag>-install/ (supervisor, unit, conf, installer, block); the
  user installs (state the exact sudo commands and wait). A supervisor
  that passes a new flag must never be installed ahead of the bridge
  that accepts it.
- Conf values with a comma must be double-quoted; a trailing comment on
  a value line is a parse error. A profile tag must prefix no field key
  (never another's name plus tx or rx). The supervisor's parser needs
  bash 4: validate on the Pi with USB16X16_AES67_CONF=<file>
  usb16x16-aes67-supervisor profiles, against the repo conf and against
  the live conf plus the block. The harness refuses --maximum-lag-ms at
  or above 250; use 200.
- Pi commands are given bare (the user has an ssh session open); from
  this tool use ssh bdimaio@192.168.1.201. Pi root changes and Mac daemon
  kills are the user's. Each accepted step is committed and pushed with
  its evidence (harness JSON and -api/ dirs; bridge logs are gitignored).

OPEN, NOT THIS SESSION'S WORK
The count of in-service re-primes over days (Phase 6) and a supervisor
rule to re-bind after a re-prime storm; the Pi's re-prime split (805
once after an RX RECOVER at start); the Mac constant and the gadget's
share of the USB legs (not reachable by profile).
