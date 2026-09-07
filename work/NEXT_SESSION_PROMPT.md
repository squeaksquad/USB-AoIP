# Next-session pickup prompt

Paste the block below into a fresh Codex or Claude Code session to resume work.
It points at `PROJECT_HANDOFF.md`, which is authoritative where it conflicts
with this summary.

Rewritten 2026-09-07 18:05 UTC after the day's three acceptances (age50, the
RAVENNA arrival-lead export, sink delay 132: RTL at 32 from 19.958 to 19.479
ms on fresh anchors). Where this summary and the handoff tail differ, the
handoff wins.

---

Raspberry Pi 5 USB 16x16 / AES67 bridge. Repo: ~/Development/USB 16x16
(github.com/squeaksquad/usb-16x16-aes67, main, pushed and clean).

Read the Rollback rules at the end of PROJECT_HANDOFF.md, then everything
from "IMPLEMENTED and STAGED 2026-09-07 13:10 UTC" to the end
(chronological, bold lead-ins; a CORRECTION paragraph wins over the entry
it amends), then the BUDGET entry "BUDGET 2026-09-06 00:40 UTC" for the
lever pricing (its sink-delay pricing is corrected in the 17:23 UTC
MEASURED entry of 2026-09-07), then work/aes67-bridge/aes67.conf's blocks
for ...-target48-trace-txoff950-rxtrim-age50 and ...-rxtrim-age50-sd132,
work/ravenna-lead-export/README.md (the export: units, what sink_min_time
means, the frame step), and work/phase4-bridge/src/main.cpp: the aligned
TX prime (the hold, the front drop, the target, kAlignPrimeMarginNs and
kAlignPrimeAgeMarginDefaultUs near line 85-100, the prime itself from
about 1400), the PRIMED overshoot/trim code just after it, and
align_playback_trigger (about 1325, target= and slack_us=).

NOTHING IS BROKEN. The service runs the accepted profile (sd132 on
bridge 05f37bd9, supervisor 631e88e1, module bc694c24) on the 17:19 UTC
anchor of 2026-09-07 with zero RECOVERs at the end of the session; the
sd132 labels copy (copy-sd132-labels.py --apply) may or may not have been
run, the dry run says. Every read starts with a fresh anchor as always.
Playback is on.

THE POINT OF RECORD (accepted 2026-09-07 17:55 UTC)
Profile servo-aligned-both-240-rx120-sd144-tx192-target48-trace-txoff950-rxtrim-age50-sd132
(TARGET 48, ALIGN_TX_OFFSET_US 950, RX_PRIME_TRIM 1, ALIGN_PRIME_AGE_MARGIN_US
50, SINK_DELAY 132; the "sd144" in the name is historical) on bridge
05f37bd9 (--align-prime-age-margin-us, default 150 = the older
behaviour), supervisor 631e88e1 (module_binary ravenna-lead-install/,
expected_module_sha256 bc694c24), module bc694c24 (the transmit-slot fix
0001 plus the arrival-lead export 0002; rollbacks cc6852f0 in
ravenna-tx-fix-install/ and the original f65a4955 in the v2.1 tree), conf
ff05b089, installer a5c69f7c. Fresh anchor: 747 at 64 frames, RTL
Utility at 32 frames 19.479 ms = 747 + 188 to the sample; 4 x 800 loaded
and the 600 s soak all on 747, zero RECOVERs; TX floor 75 loaded, RX 72,
tx_pullmax 48, tx_occ / rx_occ 51; TX PRIMED front_age_frames 296
under_prime 0, RX PRIMED ring_at_prime 192 trimmed 21, ALIGN trigger
target=prime; split pos_tx -20 / pos_aes67 573 / pos_rx -22 / pos_pi 531,
pi_total about 702, usb_time about 45. The day's chain on fresh anchors,
RTL at 32: age50 19.875 (766), the 14:48 anchor at 144 on the new module
19.729 (759, the same bridge start: fresh-anchor draw), sd132 19.479
(747). Yardstick: Dante Virtual Soundcard 11.312 ms at 32. Rollbacks by
switch-profile, conf only: ...-rxtrim-age50 (144), ...-rxtrim (age margin
150), ...-target48-trace-txoff950 (no RX trim). Bridge and supervisor
sets: phase4-age50-install/ (current bridge), aes67-sd132-install/
(current conf, installer, labels script), aes67-age50-install/
(supervisor 7a5d2362 with module cc6852f0: the module rollback, service
stopped).

WHAT THE RECORD SETTLED (do not re-derive)
- The Mac reports a level set on usbaudiod's timeline at each gadget PCM
  restart; only a fresh anchor (sudo systemctl restart usb-16x16.service;
  the AES67 service restarts itself, systemd's restart counter shows it,
  about 60 s to STAGE running) reads a known figure. The level follows
  the bridge's start depth 1:1 only when the rest of the draw holds: two
  anchors with identical PRIMED lines read 748 and 766 on 2026-09-07 (the
  748 had a stalled first second, both devices pulling 96 in one gap: re-
  draw such anchors); 759 and 747 the same afternoon differed by exactly
  the lever. Compare levers by the index chain (pos_aes67, pos_pi) and
  pi_total, and by the level only across anchors whose PRIMED lines match.
- The aligned wait allowance is TX cover; the ring target is not; the RX
  prime overshoot was permanent RX depth (trimmed since rxtrim); the
  prime margin's age is priced at 50 us while the target keeps 150
  (age50). Floors: TX 75-87 loaded across the accepted sessions (the
  session's own draw of pull gaps, worst gap about 1.15 ms), RX 72.
- The arrival lead: the RAVENNA driver computes, per packet, how long
  before the TIC that copies its first sample it arrived; the export
  (module bc694c24) fixed its units (100 ns against 100 us, a factor of
  1000), seeded its minimum, and carries it to GET /api/sink/status/N as
  sink_min_time, the least lead in microseconds since the previous GET of
  that sink, -1 with no packet, negative for a late packet (a hole). Read
  it in pairs around a run (work/ravenna-lead-export/read-lead.sh
  [label]). Both Ferrofish sinks read within 25 us of each other:
  0.93-1.06 ms per interval at 144 and at 132, worst 930 us over 35
  loaded minutes.
- Sink delay's cost is a step of one TIC frame, not a slope: the driver
  places a packet at stamp plus delay and rounds down to the 48-sample
  frame whose TIC copies it, so the deadline moves only when the
  Ferrofish stamp phase plus the delay crosses a frame boundary. 132 read
  144's lead (free, 12 samples); 96 had crossed (lead about 40 us, the
  41-sample holes of 2026-09-04). The BUDGET entry's "120 leaves 430 us"
  was wrong: below the crossing nothing between 96's lead and 144's
  exists.
- Sink delay changes no audio at any value; its only failure is a late
  packet, copied as a stale slot.
- Nothing compiles the RAVENNA module on the Mac; the Pi build in a
  service-stop window is the syntax gate (build.sh in ravenna-lead-src/
  refuses while the service is active).

THE PROCEDURE (every measurement session starts with it)
1. Playback off (ask). Nothing on the Mac holds the device open; the
   harness and RTL Utility never share it.
2. Fresh anchor: the user runs sudo systemctl restart usb-16x16.service.
   usbaudiod logs fresh setStartingUSBFrame lines (/usr/bin/log show
   --last 10m --predicate 'process == "usbaudiod"'; the bare word log is
   a zsh builtin). Wait for STAGE running on the Pi (journal: "sinks
   applied, delay N", both sinks' "delay" read back), read the ALIGN,
   PRIMED and ALIGN trigger lines: front_age_frames 296, under_prime,
   intended 171, ring_at_prime 192, trimmed 21, target=prime, slack_us;
   the first second's pulls (48, not 96). Take the first lead pair.
3. Gate: channel-2 noise probe at 64 (--input-channel 2 --output-channel
   1 --other-channel-load-amplitude 0.1, 100 impulses, USB16X16_DUMP to
   the scratchpad, zeros.py in outputs/latency/usb-holes-20260904/): 0.0%
   zeros, no run. A Mac hole state is cleared by sudo killall coreaudiod
   on the Mac (itself a fresh anchor).
4. Read: work/aes67-candidate/measure-under-service.sh 64 100 <label>,
   a lead read after it. Then copy /run/usb16x16/bridge.log into
   outputs/latency/stage-trace-20260906/ (between runs, never during)
   and split it: python3 outputs/latency/stage-trace-20260906/impulse-index.py
   <log> --level <N>. Report level, pi_total, usb_time, pos_aes67, the
   PRIMED lines, the lead.
5. Acceptance: four 800-impulse runs and the 600 s soak, all with
   USB16X16_OTHER_LOAD=0.1, detached (Popen start_new_session, a Monitor
   polling the log for an exit= line; the chain scripts of 2026-09-07
   put a read-lead.sh pair around every run), zero RECOVERs inside runs,
   no negative lead, floors reported, RTL at 32 by the user, on one
   fresh-anchor session; then the block's MEASURED/COVER/STATUS, the conf
   pin, and a copy-<tag>-labels.py for the live conf (labels only, dry
   run without --apply).

THE LEVERS, IN ORDER, ONE AT A TIME
1. The rest of the free sink-delay range: 144 less the Ferrofish stamp
   phase, between 0 and 35 more samples beyond 132, conf only. Price it
   first by reading the phase: an eth0 capture on the Pi (root, the
   user; rtp-impulses.py in outputs/latency/stage-trace-20260906/ parses
   RTP) and the RTP timestamps mod 48 of either Ferrofish stream (both
   share mediaclk:direct=531217786 and read the same lead), the phase
   being how the driver's frame grid (SAC multiples of 48) sits against
   the stamps; or empirically, one conf-only step to 120 judged by the
   lead (unchanged: the phase is at least 24 and 120 is free; near zero
   or negative: crossed, roll back by switch-profile). Then one block at
   the largest free value with the usual set. Expect the level to move
   1:1 with the samples and the lead not at all.
2. After that, nothing priced remains on the Pi side by profile: the TX
   prime (192) sits over a bar of one period plus the Pi's worst wakeup
   gap and needs the days-long gap measurement (Phase 6); the Mac
   constant and the gadget's share of the USB legs are not reachable.

BUILD AND INSTALL RULES
- Syntax-check bridge changes on the Mac first: clang++ -std=c++20
  -fsyntax-only -Wall -Wextra -Wpedantic -Werror with the Pi's ALSA
  headers as system includes (~/usb-16x16-work/deps/libasound2-dev/usr/include/alsa
  on the Pi; copies in earlier scratchpads under
  /private/tmp/claude-501/-Users-bryandimaio-Development-USB-16x16/*/
  scratchpad/alsa-include) and shims for endian.h, clock_nanosleep /
  TIMER_ABSTIME and ESTRPIPE (86). Core tests build on the Mac without
  ALSA. Build on the Pi only with the service stopped (the user stops
  it); stage the source in a fresh ~/usb-16x16-work/phase4-<tag>-src/
  with a build.sh that refuses while the service is active (copy
  phase4-age50-src/build.sh). Module changes: a patch on top of 0001 and
  0002, work/ravenna-lead-export/build.sh's form, ~/usb-16x16-work/
  ravenna-<tag>-src/ and ravenna-<tag>-install/, the supervisor's
  module_binary and expected_module_sha256 moved after the build. No
  transfers while a measurement runs; stage file by file while the
  service runs, not as one tar stream.
- A new bridge binary needs THREE pins moved: install-candidate.sh,
  install-aes67-service.sh (bridge and supervisor pins, the full 64-hex
  hash), and the supervisor's expected_bridge_sha256; the artifact in
  work/phase4-bridge/artifacts/pi-aarch64/ and the README paragraph.
  Stage phase4-<tag>-install/ (binary, wrapper 6282b108, installer) and
  aes67-<tag>-install/ (supervisor, unit, conf, installer, block); the
  user installs (state the exact sudo commands and wait). A supervisor
  that passes a new flag must never be installed ahead of the bridge
  that accepts it. A conf-only block needs no installer run: the user
  appends the block (sudo tee -a), switch-profile with the service
  stopped, start, then the fresh anchor.
- Conf values with a comma must be double-quoted; a trailing comment on
  a value line is a parse error. A profile tag must prefix no field key
  (never another's name plus tx or rx). The supervisor's parser needs
  bash 4: validate on the Pi with USB16X16_AES67_CONF=<file>
  usb16x16-aes67-supervisor profiles, against the repo conf and against
  the live conf plus the block. The harness refuses --maximum-lag-ms at
  or above 250; use 200.
- Pi commands are given bare (the user has an ssh session open); from
  this tool use ssh bdimaio@192.168.1.201 (scp without -q; the Pi's
  modinfo is /usr/sbin/modinfo). Pi root changes and Mac daemon kills
  are the user's. Each accepted step is committed and pushed with its
  evidence (harness JSON and -api/ dirs; bridge logs and .ko files are
  gitignored).

OPEN, NOT THIS SESSION'S WORK
The count of in-service re-primes over days (Phase 6) and a supervisor
rule to re-bind after a re-prime storm; the Pi's re-prime split (805
once after an RX RECOVER at start); the Mac constant and the gadget's
share of the USB legs (not reachable by profile); the sink status flags
(rtp_seq_id_error, rtp_sac_error, all_muted on sink 1) that read true
on 2026-09-07 14:12 UTC, accumulated since an earlier fetch and reset by
it, never gated on.
