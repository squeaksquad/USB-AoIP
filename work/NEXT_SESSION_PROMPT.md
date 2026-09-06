# Next-session pickup prompt

Paste the block below into a fresh Codex or Claude Code session to resume work.
It points at `PROJECT_HANDOFF.md`, which is authoritative where it conflicts
with this summary.

Rewritten 2026-09-06 after the Phase 5 day: the pitch seed, the aligned RX
prime, the grid-phase instrument and the RX prime phase window were built and
measured, the session lottery was split into a controlled term and an
unexplained one, and Dante Virtual Soundcard gave the loop its yardstick.

---

```text
Raspberry Pi 5 USB 16x16 / AES67 bridge. Repo: ~/Development/USB 16x16
(github.com/squeaksquad/usb-16x16-aes67, main, pushed and clean).

Read the Rollback rules at the end of PROJECT_HANDOFF.md, then everything
from the entry "Phase 5 Stage A, 2026-09-05" to the end (about 1000 lines,
chronological, bold lead-ins; corrections are later paragraphs, trust the
note and keep the measurement). Then the conf block for PROFILE= in
work/aes67-bridge/aes67.conf.

NOTHING IS BROKEN. The service runs the accepted point.

THE POINT OF RECORD (accepted 2026-09-05 03:15 UTC)
Profile servo-aligned-both-240-rx120-sd144-tx192-target64: 1127 samples at
64 CoreAudio frames (23.5 ms), RTL Utility at 32 frames 27.396 ms, TX floor
105-108 loaded, RX floor 77, on bridge 2a158386 (the installed binary; every
new flag is off in this block so it behaves as the accepted b65b84ee did).
Its level is a per-session draw: 27.4 on a good day, 28.1 on a bad one.

THE YARDSTICK
Dante Virtual Soundcard on the user's laptop: 11.312 ms at 32 frames. This
loop at its best today: 26.6-27.0. The plan's budget puts 12-13 ms of the
gap in the Mac's USB path, the Ferrofish and the RAVENNA device before the
bridge holds a frame; every lever measured today lives in the remaining
few milliseconds.

WHAT 2026-09-05 ESTABLISHED (all measured, all in the handoff)
1. The pitch servo already runs both converters at 1.0; the kernel-side
   PTP feedback step is closed (quantisation band about 10 frames).
2. --pitch-seed (-15 ppm) removes the 46-frame warm-up drift; it moves the
   TX/RX split, it does not create margin.
3. The ring target 128 -> 64 (target64) took 191 samples off the level and
   is the accepted point.
4. RX depth and RX floor are quantised by the unaligned RX prime in 48-frame
   bins: ring fill = next multiple of 48 above target + prime + 3.
5. --align-rx-trigger/--align-rx-prime hold the RX front age constant
   (sessions 13 apart instead of 34-64) at the worst-case wait's cost.
6. phase_us telemetry: the RAVENNA tick against the host's USB frame grid
   slides about 20 us/s (the crystal offset the servo corrects in rate).
   --rx-prime-phase-window "LOW,HIGH" (quoted in a conf block) holds the RX
   prime until that phase is inside the window, discarding ring excess to
   whole periods below the prime level. The level against that phase is a
   sawtooth (1157 at 67 us, 1132-1137 at 382-548, 1094-1107 at 695-944).
   Plain restarts cluster at 380-550.
7. The window holds its phase every session (proven on rxalign, phase760,
   phase760-tx240, phase450), but a SECOND term of 18-48 samples of level
   and up to 47 of TX cover moves between sessions with identical primed
   depths and the same window (phase450: 1089 at TX 108, then 1107 at TX
   61). Not PTP (grandmaster unchanged; kernel ResetPTPMaster lines are
   normal at every stack start). Candidates: where the Ferrofish's packets
   land against the RAVENNA read slot at the aligned start, or the Mac
   side after a device change. sink_min_time reads 0 and does not report
   it. This is the open item.

MEASURED, NOT ACCEPTED, ALL BLOCKS IN THE LIVE CONF
seed15 1102 (TX 160 / RX 50); primes144 1156 (110/96); shift30 1154
(119/66); rxalign 1215/1202 (109/96, two sessions); phase760 1083 (60/77);
phase760-tx240 1122/1118 (68-70/77, two sessions); phase450 1089 then 1107
(108 then 61). Rollback for anything is
  sudo usb16x16-aes67-supervisor switch-profile servo-aligned-both-240-rx120-sd144-tx192-target64

RULES LEARNED THE HARD WAY (also in the handoff)
- No harness probe or measurement while the user plays audio through the
  device: a probe on top of live playback put the Mac's USB output into a
  state that sent 8 zeros every 96 frames until coreaudiod was killed and
  the gadget re-bound. Ask "playback off?" first. RTL Utility's click
  train shows up in the zero-run detector as 8-12 sample runs on channel
  1; that is the signal, not holes.
- A new bridge binary needs THREE pins moved: install-candidate.sh,
  install-aes67-service.sh, and the supervisor's own expected_bridge_sha256
  (missed once; exit 27 "hash or ownership mismatch").
- Conf values with a comma must be double-quoted ("380,550"); a bare comma
  is a "bad line" and switch-profile refuses silently to the terminal.
- The stage file says "running" for 120 s and "stable for ..." after; key
  wait loops on the bridge log, not the stage.
- No builds on the Pi while the service runs (three stalls for three
  builds); syntax-check on the Mac first with the Pi's ALSA headers as
  system includes and stubs for endian.h / clock_nanosleep / TIMER_ABSTIME
  / ESTRPIPE.
- The Pi hard-stopped once (2026-09-05 12:13:20 UTC, no kernel message,
  came back by itself in 5 min, wlan0 needed a retry) at the first start
  of bridge 006fc65e; not reproduced; unexplained.
- Pi root changes are the user's: state the exact sudo command and wait.

THE QUESTION TO START WITH
Where does the remaining 15.7 ms between this loop and DVS actually sit,
term by term, and which of it is reachable without touching the protected
USB module? Answer that from the record before proposing another lever.
If a lever is proposed, the second session term (item 7) is the one whose
instrument is missing: a bridge-side measure of the RAVENNA capture's
arrival lead at its fresh wake against the tick, logged at start.
```
