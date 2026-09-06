# Next-session pickup prompt

Paste the block below into a fresh Codex or Claude Code session to resume work.
It points at `PROJECT_HANDOFF.md`, which is authoritative where it conflicts
with this summary.

Rewritten 2026-09-06 after the budget day: the impulse trace and an eth0
capture split the round trip by stage, found 7 ms inside the Merging RAVENNA
driver's transmit path, and a one-expression module fix took the accepted
point from 1127 to 757 samples at 64 frames.

---

```text
Raspberry Pi 5 USB 16x16 / AES67 bridge. Repo: ~/Development/USB 16x16
(github.com/squeaksquad/usb-16x16-aes67, main, pushed and clean).

Read the Rollback rules at the end of PROJECT_HANDOFF.md, then everything
from the entry "BUDGET 2026-09-06 00:40 UTC" to the end (chronological,
bold lead-ins; corrections are later paragraphs, trust the note and keep
the measurement). Then work/ravenna-tx-fix/README.md and the conf block
for PROFILE= in work/aes67-bridge/aes67.conf.

NOTHING IS BROKEN. The service runs the accepted point.

THE POINT OF RECORD (accepted 2026-09-06 06:03 UTC)
Profile servo-aligned-both-240-rx120-sd144-tx192-target64-trace on the
fixed RAVENNA module cc6852f0 (supervisor 892dd189 loads it from
~/usb-16x16-work/ravenna-tx-fix-install/; the original module f65a4955
stays at its old path for rollback), bridge c1ca48c5: 757 samples at 64
CoreAudio frames (15.77 ms), RTL Utility at 32 frames 19.688 ms, TX floor
107 loaded, RX floor 77, four loaded 800-impulse runs and the 600 s soak
all on 757, zero RECOVERs. The audio path is target64's; the trace is an
instrument (IMPULSE lines on channel-1 hits, line cap 200000). Sessions
on the fixed module have read 819, 811 and 757: the session draw is
still there and is up to about 62 wide.

THE YARDSTICK
Dante Virtual Soundcard on the laptop: 11.312 ms at 32 frames. This loop:
19.7-20.8 ms at 32 now, 8.4-9.5 ms away, from 15.7 yesterday.

WHAT 2026-09-06 ESTABLISHED (all measured, all in the handoff)
1. Budget on the device timeline at target64 (1127): Mac buffers 64 and
   safety offsets 124 outside it; inside it the bridge's start depth 528
   (TX front age 336 + RX 192) and 599 outside the bridge.
2. The USB-only loop on the req 4 gadget reads 262 at a 240-frame target:
   the Pi USB legs are about 22-40 samples; the req 2 to req 4 step was an
   artefact.
3. The impulse trace (bridge --impulse-trace, profile key IMPULSE_TRACE,
   analyser outputs/latency/stage-trace-20260906/impulse-stages.py)
   stamps the harness impulse at usb-capture, ravenna-playback,
   ravenna-capture, usb-playback; the playback stages query the ALSA delay
   on hit blocks so the queue terms are exact; pi_total tracks the level
   within a period. The time-domain dwells carry a per-session
   block-offset component (12000 is a multiple of 48); trust the sums.
4. rtp-impulses.py on a tcpdump of eth0 (user runs it, sudo) finds the
   impulse both ways (0x1FFFFC on the wire) and, with the bridge log and
   the Pi's realtime-minus-monotonic offset, splits write-to-wire, the
   Ferrofish loop and wire-to-read. Old module: 12.1 / 2.7 / 2.2 ms.
   Fixed module: 6.0 / 1.8 / 2.6 ms.
5. The defect: in the TIC the playback interrupt copies at
   playback_buffer_pos and advances it, then frame_process_end sends from
   that advanced position, so every packet carried the slot one playback
   buffer minus one period old (336 frames at 384). Confirmed by rp288
   reading 99 under at the same RX phase, and by the fix reading 333 off
   the AES67 term. The RAVENNA playback buffer is no longer a latency
   term; rp288/rp240 blocks exist but are moot on the fixed module.
6. The sink_min_time API field is never set (the driver computes the
   arrival lead under DEBUG_CHECK but nothing exports it); a one-line
   plumbing change would surface it. Not built.
7. The session term (18-62 between sessions with identical PRIMED numbers)
   remains; the index domain (RTP stamps against bridge positions) is the
   way to place it. Candidates narrowed: not the AES67 segment beyond the
   TX queue, not the USB legs.

RULES LEARNED THE HARD WAY (also in the handoff)
- No probe or measurement while the user plays audio; ask "playback off?".
  Since Pro Tools crashed (01:54:51 UTC) nothing on the Mac holds the
  device open, so each harness or RTL open/close can re-prime the bridge
  (a RECOVER pair); measure only when the user says, run chains back to
  back, count RECOVERs inside runs only.
- No large transfers from the Pi (scp of a capture or log), no builds, no
  captures copied while a measurement runs: an scp mid-run gave a 4.95 ms
  gap and five RECOVERs. Copy between runs.
- A new bridge binary needs THREE pins moved (install-candidate.sh,
  install-aes67-service.sh, the supervisor's expected_bridge_sha256); a
  new module needs the supervisor's module_binary path and
  expected_module_sha256 and the service installer's supervisor pin.
- Conf values with a comma must be double-quoted. The harness refuses
  --maximum-lag-ms at or above 250; use 200.
- Mac syntax check of the bridge: clang -std=c++20 with the Pi's ALSA
  headers as system includes and stubs for endian.h, clock_nanosleep /
  TIMER_ABSTIME and ESTRPIPE (86).
- Pi root changes are the user's: state the exact sudo command and wait;
  sudo prompts have swallowed two stops, check is-active before acting.

WHERE THE REMAINING 8.4-9.5 ms SITS (RTL at 32, 945 samples on the best
session, DVS 543): Mac buffers 64 and safety offsets 124 (not reachable);
bridge start depth about 528 (TX prime 192 is cover against the Pi's
worst wakeup gap, the Phase 6 question; the aligned wait allowance is
worth about 25, ring target 48 about 16); AES67 segment about 278 (the
Ferrofish 2.7 ms with wires, RAVENNA capture 2.2 ms with sink delay 144,
the tick and stamp); USB legs about 40. The next lever candidates, in
order: the RX ring/queue split now that the RAVENNA side is 4 ms shorter
(re-measure the sd144 lead: sink delay 120 with the arrival lead
exported), the aligned wait allowance, and the Phase 6 gap measurement
over days to earn a TX prime step.
```
