# Next-session pickup prompt

Paste the block below into a fresh Codex or Claude Code session to resume work.
It points at `PROJECT_HANDOFF.md` and `work/SAP_DISCOVERY_FINDING.md`, which are
authoritative where they conflict with this summary.

Written 2026-09-01 after the root cause of the Phase 4 XRUN was found.

---

```text
Raspberry Pi 5 USB 16x16 / AES67 bridge. Repo: ~/Development/USB 16x16
(github.com/squeaksquad/usb-16x16-aes67, main @ 13b5c13).

Read PROJECT_HANDOFF.md first, especially "Phase 4 implementation status" and
its "Frame accounting from the instrumentation build" subsection.

YOUR FIRST TASK IS ALREADY DIAGNOSED. Implement it, do not re-investigate.

ROOT CAUSE (confirmed, run 172034Z)
snd_pcm_mmap_begin returns fewer frames than requested on the RAVENNA playback
device. render_to_playback has already called resampler.render(), which
consumed ring input for the full `produced` count, so whatever ALSA declines is
silently discarded. Measured: 583 frames dropped on TX, 0 on RX, in 252 s.

  direction  dropped  apparent step  corrected for drops  commanded
  TX             583      +31.29 ppm         -16.97 ppm    -27.17 ppm
  RX               0      +16.88 ppm         +16.88 ppm    +27.17 ppm

Corrected TX and apparent RX are mirror images to within 0.5%. The shared
estimator has been applying a correct reciprocal pair all along; the drops
inverted TX's apparent ratio and hid it. THERE IS NO RATE-CORRECTION BUG AND NO
SERVO BUG. Two earlier sessions concluded otherwise and were wrong.

It explains everything: 12.1 ms of real audio discarded per 252 s; the playback
queue draining while the ring sits healthy at target; and the XRUN, which in
that run hit usb-to-ravenna, the dropping direction.

THE FIX (not yet implemented)
A reorder, not new logic. In render_to_playback, call snd_pcm_mmap_begin FIRST
to learn how many frames ALSA will actually accept, then render exactly that
many. Once ring input has been consumed it cannot be un-consumed, which is why
the present order can only drop. Keep the dropped_frames counter afterwards; it
should read 0 in both directions, and that is your acceptance check.

Then re-run 96/384/768/192 and expect: tx_dropped=0, rx_dropped=0, and the XRUN
gone. If the XRUN survives with zero drops, the queue drain has a second cause
and you are in new territory - instrument, do not guess. See HOW TO WORK below.

STATE
Accepted operating point is still the dual-alsaloop stopgap: tlatency 3000,
sink delay 576, 64-frame CoreAudio buffer, 32.792 ms median, ten-minute soak
clean. No Phase 4 point is accepted; every Phase 4 run so far ends in an XRUN.

Phase 4 at 96/384/768/192, instrumented binary, four runs: 40.375 / 41.625 /
44.313 ms, all at correlation score 1.000 with zero spread across 40 impulses.
Use this operating point. The 96/960/1536/192 point measures 77-84 ms, was
adopted for stability on a false premise, and never delivered it.

A failed experiment showed the pipeline carries ~380 frames of slack: trimming
it took measured latency to 23.229 ms, BELOW the 32.792 ms stopgap. It XRUNed
in 22 s because the slack was taken out of the elastic ring, which is where the
jitter absorption lives. Tuning the ring/queue split deliberately, after the
drop fix, is the path to beating the stopgap. That is the real prize.

HOW TO WORK ON THIS - EARNED THE HARD WAY, PLEASE READ
The 2026-09-01 session burned several hours and four of the user's
password-protected install cycles on two fixes that were both wrong. What
actually solved it, twice, was a small behaviour-free counter. Concretely:

1. INSTRUMENT BEFORE YOU FIX. A counter cannot make anything worse and costs
   one run. A fix costs a build, an install that interrupts the user for a
   password, a run, and possibly a revert. When the diagnosis is not certain,
   the counter is strictly cheaper. Both counters that cracked this
   (consumed_frames, dropped_frames) were about ten lines.

2. DO NOT DO ALGEBRA ON AGGREGATES. The first wrong conclusion came from
   `residual = input - output - ring_occupancy`, which silently conflated ring
   drift, resampler-retained frames, and the actual rate. Put a counter at the
   exact point you care about instead of deriving it from three others.

3. A CORRECT COMPONENT DOES NOT MEAN A CORRECT SYSTEM. A unit test proved
   FarrowResampler applies its requested step exactly. That was used to
   conclude the field observation was false. Wrong move: when a component test
   and a field measurement are both sound and disagree, the bug is BETWEEN
   them. That is exactly where it was.

4. SEPARATE THE OBSERVATION FROM THE EXPLANATION. The session retracted a
   correct measurement because the mechanism proposed for it was wrong. Retract
   explanations freely; retract measurements only when the measurement itself
   is shown to be flawed.

5. SUSPICIOUSLY ROUND NUMBERS ARE A TELL. TX measured exactly 1.000000000 while
   being commanded -27 ppm. Exactness like that means something is cancelling,
   not that nothing is happening. Chase the cancellation.

6. A FIX THAT MAKES THINGS MUCH WORSE IS DATA. Driving the XRUN from 331 s to
   22 s is what revealed the ring is the jitter reservoir and that ~380 frames
   of slack exist. Record what a failure teaches before reverting it.

7. ENUMERATE EVERY VERSION PIN BEFORE ASKING FOR AN INSTALL. The binary hash
   lives in TWO places: install-candidate.sh and run-phase4-candidate-safe.sh,
   which enforces it along with root:root:755. Missing the second cost the user
   an extra password prompt.

8. BUDGET THE USER'S PASSWORD. Each install is a human interruption. Batch
   changes, verify hashes before asking, and prefer observational builds when
   the next step is uncertain.

BLOCKED ON NOTHING - the switch work is finished
Ports: 1 Pi, 2 ULN-2 3d, 3 Ferrofish, 4 Dante AVIO, 5 Mac. Switch UI at
169.254.0.239 answers over the Mac's en12.

GOTCHAS THAT WILL OTHERWISE COST YOU HOURS
1. IGMP snooping is OFF on the GS305EP as of 2026-09-01, and that is
   deliberate. Time to audio after a daemon restart went from 263-267 s to at
   most 52 s. If you see the old ~260 s behaviour, check snooping before
   debugging anything else. Snooping ON is measured NOT to protect the 100 Mb
   Dante AVIO either, because with no querier the entries age out and it floods
   anyway. See work/SAP_DISCOVERY_FINDING.md.
2. Latency figures are NOT comparable across that snooping change. Settle now
   finishes ~300 s earlier, so the measurement lands earlier in the estimator's
   convergence and reads higher. Re-baseline rather than comparing.
3. NEVER gate a measurement on sink flags. receiving_rtp_packet: true occurs
   during pure silence and on a broken path.
4. "return signal ready after N probes" is NOT when the path came up. The gate's
   spread<=2-samples test is coupled to SRC convergence. Read
   readiness-probe-*.json capturedAt for the real turn-on.
5. Keep --maximum-lag-ms under 250. Impulses repeat every 250 ms.
6. Do NOT pass alsaloop --period/--buffer. --tlatency is the real control.
7. Sink delay changes live via PUT /api/sink/{0,1}; tlatency does not. Read
   sinks back via GET /api/sinks; GET /api/sink/N returns 404.
8. bridge.log has no timestamps but emits at 1 Hz (48000 frames per line).
9. Dante Controller holds UDP 9875, so sap-watch cannot bind while it is open.
   Set USB16X16_SAP_WATCH=0 when you do not need the SAP timeline.

ENVIRONMENT
- Pi: eth0 169.254.92.97 is AoIP; wlan0 192.168.1.201 is SSH and management.
  SSH working says nothing about AoIP health.
  ssh -o HostKeyAlias=audio-dev.local bdimaio@192.168.1.201
- libasound2-dev is NOT installed. Build against the vendored copy:
    cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
      -DALSA_INCLUDE_DIR=/home/bdimaio/usb-16x16-work/deps/libasound2-dev/usr/include \
      -DALSA_LIBRARY=/usr/lib/aarch64-linux-gnu/libasound.so.2
  Source syncs to ~/usb-16x16-work/phase4-build, staging in phase4-install.
- Installing needs the user's password by design; the binary and wrapper are
  root-owned. Give them exactly one command:
    ssh -t -o HostKeyAlias=audio-dev.local bdimaio@192.168.1.201 \
      'sudo ~/usb-16x16-work/phase4-install/install-candidate.sh \
       ~/usb-16x16-work/phase4-install/usb16x16-rt-bridge \
       ~/usb-16x16-work/phase4-install/run-phase4-candidate-safe.sh'
- Run form (~10 min at this operating point):
    USB16X16_SAP_WATCH=0 work/aes67-candidate/measure-phase4-roundtrip.sh 480 64 40 200
  Defaults are 96/384/768/192, which is what you want.
- Mac harness: work/latency-harness (Swift, CoreAudio impulse correlation).

RULES
The USB module, usb-16x16.service, and setup script are immutable baselines;
AES67 work must never disturb USB enumeration. One variable at a time. Every
figure is reconnaissance except the soaked stopgap, and a new operating point
needs its own ten-minute loaded soak before acceptance.
```

---

## Still open, not covered by the prompt

- **Host channel-name requirement.** Untouched. macOS still reports UAC2
  speaker positions rather than `1` through `16`.
- **Soak channel loading.** The soaks carried digital silence on the 15
  non-measurement channels, which is not a literal satisfaction of the
  acceptance criterion.
- **AoIP switch QoS.** GS305EP is in `Port-based` mode, which ignores the DSCP
  marks AES67 already sets. No measurable gain expected at current load.
- **The 31.9 s first-RX-stream stall** inside `MergingRavennaALSA`, n=13,
  deterministic, only ever the first sink after `insmod`. On-Pi work, nobody has
  touched it.
- **Two small daemon items**: PTP "lock" takes exactly 10.00 s every time, which
  is a fixed dwell rather than convergence; and the daemon defers its first
  current-version SAP announcement by a full 30 s interval.
- **The settle gate's spread test** is coupled to SRC convergence and will fail
  outright at a higher steady-state ppm. Worth making drift-aware.
