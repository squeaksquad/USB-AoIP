# Next-session pickup prompt

Paste the block below into a fresh Codex or Claude Code session to resume work.
It points at `PROJECT_HANDOFF.md`, which is authoritative where it conflicts
with this summary.

Rewritten 2026-09-06 evening: the RTL-at-32 model now holds to the sample
on three sessions, the Mac's USB output hole state is understood and its
clear is known, the TX prime is held by a measured 3.3 ms gap, and the
session draw (757-828) is the next lever.

---

Raspberry Pi 5 USB 16x16 / AES67 bridge. Repo: ~/Development/USB 16x16
(github.com/squeaksquad/usb-16x16-aes67, main, pushed and clean).

Read the Rollback rules at the end of PROJECT_HANDOFF.md, then everything
from the entry "ACCEPTED 2026-09-06 06:03 UTC" to the end (chronological,
bold lead-ins; a CORRECTION paragraph at the top of an entry wins over the
entry). Then work/ravenna-tx-fix/README.md and the conf block for PROFILE=
in work/aes67-bridge/aes67.conf.

NOTHING IS BROKEN. The service runs the accepted profile on a fresh draw.

THE POINT OF RECORD (accepted 2026-09-06 06:03 UTC, unchanged)
Profile servo-aligned-both-240-rx120-sd144-tx192-target64-trace on the
fixed RAVENNA module cc6852f0 (supervisor 892dd189 loads it from
~/usb-16x16-work/ravenna-tx-fix-install/; the original f65a4955 stays at
its old path for rollback), bridge c1ca48c5: 757 samples at 64 CoreAudio
frames, RTL Utility at 32 frames 19.688 ms, TX floor 107 loaded, RX 77,
four 800-impulse runs and the 600 s soak all on 757, zero RECOVERs. That
session ended 13:09 UTC (the coreaudiod kill below). The current draw
reads 828 at 64 frames and RTL at 32 21.167 ms: not a new acceptance.

THE YARDSTICK
Dante Virtual Soundcard 11.312 ms at 32 frames. This loop 19.7 on the
accepted draw, 21.2 on the current one.

THE MODEL THAT NOW HOLDS TO THE SAMPLE (three sessions running)
RTL Utility at 32 = harness level + 188 (two 32-frame buffers 64 + safety
offsets 74 + 50): 811+188 = 20.812, 757+188 = 19.688, 828+188 = 21.167.
The harness reads one sample across separate opens at 32 and at 64. An
RTL scatter within a session, or a harness level split 8 apart, is not
latency: it is holes.

WHAT 2026-09-06 AFTERNOON ESTABLISHED
1. The Mac's USB output engine (coreaudiod / AppleUSBAudio) enters a hole
   state on its own: zeros inside correctly timed frames, every channel,
   Pi counters and floors untouched. Onset between 06:03 and 12:17 UTC
   with the device idle; 88 of every 96 samples zeroed at 32 frames, about
   1 in 100 at 64. It made RTL scatter 18.3-19.7 on one draw and the
   32-frame harness lose 3 impulses in 4. `sudo killall coreaudiod` on
   the Mac alone cleared it (both noise probes 0.0% after); the gadget
   re-bind was not needed. The supervisor restarts the bridge alone on
   the host loss (new draw, daemon and module untouched).
2. Rules from it: a channel-2 noise probe at the gate's buffer size
   (`--input-channel 2 --other-channel-load-amplitude 0.1`, `zeros.py`)
   precedes every RTL read and every harness figure; the harness and RTL
   Utility never share the device; ask "playback off?" before any probe.
3. Phase 6 datum: one 3.3 ms Pi wakeup gap in seven idle hours on the
   accepted session (06:06:04 UTC, both bridge directions), TX queue at
   10 frames under prime 192, no RECOVER. The TX prime cannot come down
   on this evidence.
4. The session draw on the fixed module now spans 757-828 (819, 811,
   757, 828) with identical profile numbers. It is the largest
   deterministic gain left and nothing in conf controls it yet.

WHERE THE 1016 SAMPLES (RTL at 32 on the current draw) SIT
Mac 188 (not reachable). Bridge start depth about 528 (TX front age 336
= prime 192 + ring 67 + longest aligned wait 77; RX 192 = queue 120 +
ring 72). AES67 segment about 278 (Ferrofish with wires 2.7 ms, RAVENNA
capture side 2.2 ms with sink delay 144, the tick and stamp). USB legs
about 40. Session draw 0-71 on top.

NEXT WORK, IN ORDER
1. The session draw is explained and has a Pi-owned reset (FOUND
   14:42-15:19 and MEASURED 15:27-15:31 UTC, 2026-09-06): the level the
   Mac reports = Pi path (772-787 at 64 frames on every draw) + 47 -
   usbaudiod's ioDriftNS (one-sample steps, 6-8 ppm of elapsed time) at
   the last gadget PCM restart, held until the next one -- WITHDRAWN as a
   predictor at 17:45 UTC: creep1 on the 15:28 anchor at drift 25 read
   the term 55, draw1 at the same count read 21. What stands: fresh
   anchor = term 45-47 (3/3); aged anchor = 15-55 or -30, unpredictable
   so far, drawn afresh at each restart (55 then 44 on one anchor); a
   re-prime at start can also land the Pi path at 805 instead of 773-787
   (the RX split, the bridge's to fix). The accepted
   757 / 19.688 carried 71 samples of drift; the fresh-anchor figure of
   the same loop is 821-828 at 64, RTL at 32 about 21.0-21.2 ms. Reset:
   `sudo systemctl restart usb-16x16.service` re-creates the device on
   the Mac (fresh setStartingUSBFrame) and the AES67 service restarts
   itself behind it (bridge exit 1 -> on-failure restart, ~1 min); read
   after it 821 at term 45. Rule: restart the stack through the re-bind;
   quote every level with the drift at the last Pi restart (/usr/bin/log,
   process usbaudiod, AUAAudioDevice_updateTimeStamp; the bare word log
   is a zsh builtin). Open: the creep beyond drift 81 from RECOVER
   re-primes on an old anchor (map it with bridge-only restarts over one
   evening); the RX prime 120 was the casualty of a 3.7 ms wakeup gap at
   14:24:56 UTC (TX 192 held with 54 spare), the binding cover.
2. Priced conf levers, one at a time, each with the full gate: aligned
   wait allowance 77 -> about 50 (about 25 samples, conf plus one
   constant); ring target 64 -> 48 (about 16); sink delay 144 -> 120
   (24) only after the arrival lead is exported (the one-line
   sink_min_time plumbing in RTP_audio_stream.c, a module rebuild on
   the rollback path).
3. Phase 6: count wakeup gaps over days on the running service before
   any TX prime step.

RULES LEARNED THE HARD WAY (all in the handoff)
- No probe or measurement while the user plays audio; ask first. Nothing
  on the Mac holds the device open by default, so each harness open and
  close can re-prime the bridge; run chains back to back, count RECOVERs
  inside runs only.
- No large transfers from the Pi, no builds, no captures copied while a
  measurement runs. Copy between runs.
- A new bridge binary needs THREE pins moved (install-candidate.sh,
  install-aes67-service.sh, the supervisor's expected_bridge_sha256); a
  new module needs the supervisor's module_binary path and
  expected_module_sha256 and the service installer's supervisor pin.
- Conf values with a comma must be double-quoted. The harness refuses
  --maximum-lag-ms at or above 250; use 200.
- Mac syntax check of the bridge: clang -std=c++20 with the Pi's ALSA
  headers as system includes and stubs for endian.h, clock_nanosleep /
  TIMER_ABSTIME and ESTRPIPE (86).
- Pi root changes and the Mac's coreaudiod kill are the user's: state
  the exact sudo command and wait; check is-active before acting.
- Long runs are launched detached and polled; the user has an ssh session
  open, so give bare Pi commands.
