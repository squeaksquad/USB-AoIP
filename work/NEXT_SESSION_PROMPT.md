# Next-session pickup prompt

Paste the block below into a fresh Codex or Claude Code session to resume work.
It points at `PROJECT_HANDOFF.md` and `work/SAP_DISCOVERY_FINDING.md`, which are
authoritative where they conflict with this summary.

Rewritten 2026-09-01 (evening) after the mmap reorder landed, the ring/queue
split was tuned, and the remaining defect was traced to the initial settle.

---

```text
Raspberry Pi 5 USB 16x16 / AES67 bridge. Repo: ~/Development/USB 16x16
(github.com/squeaksquad/usb-16x16-aes67, main).

Read PROJECT_HANDOFF.md first. The Phase 4 sections were substantially rewritten
on 2026-09-01; start at "Phase 4 implementation status" and read forward through
"ROOT CAUSE: the initial settle is a lottery".

NOTHING IS BROKEN AND NOTHING IS HALF-FINISHED. The previous session's assigned
fix landed, was verified, and is committed. What is open is a decision and a
design problem, not a repair.

WHAT IS DONE AND CONFIRMED
1. The XRUN's original cause is fixed. render_to_playback now calls
   snd_pcm_mmap_begin BEFORE resampler.render and renders exactly what ALSA
   granted. tx_dropped and rx_dropped have read 0 in every run since. TX went
   from an impossible exact 1.000000000 to tracking its commanded ppm with RX
   mirroring it. There is no rate bug and no servo bug; three sessions thought
   otherwise and all three were wrong.
2. The pipeline is instrumented end to end: capture backlog, elastic ring,
   playback queue. Counters are behaviour-free and in SUMMARY plus 1 Hz
   telemetry.
3. Latency went 43.313 -> ~28 ms by tuning the prime depth.

THE OPEN DEFECT - read this before proposing anything
Total pipeline depth is set at prime time and then CONSERVED, because the
playback queue has no restoring force. The servo regresses ring+queue; the
control law regulates the ring alone. Measured three separate ways.

Applied to startup that means: whatever depth a run loses in its first ~30 s is
lost for the life of the process. Two runs of one configuration, priming
identically to TX depth 480:

  224517Z  shed 48 frames by t=30  ->  tx_qfloor 89   ->  XRUN at 563 s
  225802Z  shed  5 frames by t=30  ->  tx_qfloor 126  ->  clean 600 s

So a Phase 4 point's entire safety margin is decided in its first thirty
seconds by a transient nothing regulates. tx_qfloor scatters 89/104/124/126
across identical runs. About one run in four lands low enough to fail.

THREE EXPLANATIONS WERE FALSIFIED BY MEASUREMENT before this one, and each cost
a run: CoreAudio teardown (clean runs survived 441 s and 228 s post-teardown),
sustained load (a clean 800-impulse run exists), and prime state (both runs
prime identically). Do not re-propose them.

THE REAL FIX is a restoring force on the playback queue. THE NAIVE VERSION HAS
ALREADY BEEN TRIED AND FAILED CATASTROPHICALLY: regulating the queue to target
while letting the ring float drained the ring to the interpolator's 8-frame
reserve and XRUNed at 22 s against 331 s for the original law. Any correct
version must act slowly and must never draw the ring below its reserve. The
ring IS the jitter reservoir; that is not negotiable.

MITIGATION UNDER TEST: raising TX's prime so a bad draw is survivable. Results
are in PROJECT_HANDOFF.md. This does not fix the lottery, it only makes losing
survivable, and it costs latency.

MEASUREMENT STANDARDS - THE PREVIOUS SESSION GOT THIS WRONG
--impulses 40 at 250 ms spacing measures a TEN SECOND window. Soaks run with
40 impulses carried 10 s of impulse traffic in 600 s and were called "loaded".
They were not. Use 800 impulses (200 s) for anything you intend to trust.
Correlation score is impulse-count sensitive: a 40-impulse run usually catches
one latency level and scores 1.000; an 800-impulse run catches level changes and
scores lower. NEVER compare a 40-impulse score against an 800-impulse score.

Report tx_qfloor alongside latency. It is the safety metric and it varies run to
run, so one clean soak establishes nothing. Repetition is the only way to
characterise it.

STATE OF THE COMPARISON
Stopgap, re-baselined 2026-09-01 at 800 impulses: 32.729 ms median, spread
0.333 ms. Its documented 20.688 ms is STALE - not comparable across the IGMP
snooping change, exactly as gotcha 2 warns. Its documented 12 ms bimodal defect
DID NOT REPRODUCE; the whole spread is now 16 samples. The old "FAILED on
stability" verdict against the stopgap should be rechecked before it is used to
justify anything.

Phase 4 measures ~27.7-28.0 ms at buffer 192 with TX/RX prime 192/96 - about
4.8 ms faster than the stopgap and tighter - but it is NOT deployable while one
run in four can XRUN.

Beware: a figure of "32.792 ms" appears in older commits and in the
PROJECT_HANDOFF latency table as the stopgap. It is wrong in provenance - it is
the sink-delay-48 row, a configuration documented as unusable on this path. It
happens to land within 0.06 ms of the true current value.

THERE IS NO DEPLOYMENT MECHANISM. Neither the stopgap nor Phase 4 runs as a
service. usb-16x16.service is the USB gadget baseline and is immutable. Phase 4
has only ever run under run-phase4-candidate-safe.sh, which is time-limited to
60-1200 s and tears down afterwards. "Deploying" means designing something that
does not exist. Ask before building it.

HOW TO WORK ON THIS - EARNED THE HARD WAY, PLEASE READ
1. INSTRUMENT BEFORE YOU FIX. A counter cannot make anything worse and costs
   one run. A fix costs a build, an install that interrupts the user for a
   password, a run, and possibly a revert. Every real advance in this project
   came from a ten-line counter: consumed_frames, dropped_frames,
   short_begin_frames, queue_floor, capture_backlog.

2. DO NOT DO ALGEBRA ON AGGREGATES. Put a counter at the exact point you care
   about instead of deriving it from three others.

3. A CORRECT COMPONENT DOES NOT MEAN A CORRECT SYSTEM. A unit test proved
   FarrowResampler exact; the bug was between the component and the system.

4. SEPARATE THE OBSERVATION FROM THE EXPLANATION. Retract explanations freely;
   retract measurements only when the measurement itself is shown flawed. This
   session retracted two explanations (the prime overshoot was "waste"; the
   48-sample steps were "quantisation") while their measurements stood.

5. SUSPICIOUSLY ROUND NUMBERS ARE A TELL. Exactly 1.000000000 while being
   commanded -27 ppm meant something was cancelling.

6. A FIX THAT MAKES THINGS MUCH WORSE IS DATA. The prime-trim experiment caused
   673 XRUNs and thereby proved the overshoot is the startup runway, not waste.

7. ENUMERATE EVERY VERSION PIN BEFORE ASKING FOR AN INSTALL. The binary hash
   lives in TWO places: install-candidate.sh and run-phase4-candidate-safe.sh.
   Changing the wrapper changes its own hash, which is pinned in the installer.

8. BUDGET THE USER'S PASSWORD. Batch changes, verify staged hashes before
   asking, prefer observational builds when the next step is uncertain.

9. CHECK THE PROVENANCE OF ANY NUMBER YOU COMPARE AGAINST. This session
   propagated a wrong stopgap figure through a dozen commits because it came in
   via a pickup prompt and was never traced to source. The handoff contradicted
   itself and nobody had noticed.

10. NEVER BUILD ON THE PI WHILE A RUN IS MEASURING. Compile load on a SCHED_FIFO
    measurement can manufacture an XRUN and waste the run.

11. ADD A GUARD TO EVERY SCRIPTED EDIT, AND CHAIN IT. An anchor that silently
    fails to match writes nothing; if the commit is not chained behind the
    edit's exit status you will commit an unrelated diff under a message
    describing changes that never happened. It happened once here.

GOTCHAS THAT WILL OTHERWISE COST YOU HOURS
1. IGMP snooping is OFF on the GS305EP as of 2026-09-01, deliberately. Time to
   audio after a daemon restart went from 263-267 s to at most 52 s. If you see
   the old ~260 s behaviour, check snooping first. See SAP_DISCOVERY_FINDING.md.
2. Latency figures are NOT comparable across that snooping change. Re-baseline
   rather than compare. This bit the stopgap figure; see above.
3. NEVER gate a measurement on sink flags. receiving_rtp_packet: true occurs
   during pure silence and on a broken path.
4. "return signal ready after N probes" is NOT when the path came up. Read
   readiness-probe-*.json capturedAt. Settle time varies a lot run to run
   (152 s and 343 s observed for identical configurations) and correlates with
   how well that run settled.
5. Keep --maximum-lag-ms under 250. Impulses repeat every 250 ms.
6. Do NOT pass alsaloop --period/--buffer. --tlatency is the real control.
7. Sink delay changes live via PUT /api/sink/{0,1}; tlatency does not. Read
   sinks back via GET /api/sinks; GET /api/sink/N returns 404.
8. bridge.log has no timestamps but emits at 1 Hz (48000 frames per line).
9. Dante Controller holds UDP 9875, so sap-watch cannot bind while it is open.
   Set USB16X16_SAP_WATCH=0 when you do not need the SAP timeline.
10. The devices renegotiate ALSA buffers. Asking for 192 yields
    ravenna=128/288 and usb=96/384 - USB ignores the request entirely. Read
    NEGOTIATED before assuming a run tested what you asked for.
11. The wrapper validates per-direction prime against the REQUESTED buffer, not
    the negotiated one, so a prime above the request is rejected even when the
    device could hold it. Request the larger buffer instead.

ENVIRONMENT
- Pi: eth0 169.254.92.97 is AoIP; wlan0 192.168.1.201 is SSH and management.
  SSH working says nothing about AoIP health.
  ssh -o HostKeyAlias=audio-dev.local bdimaio@192.168.1.201
- libasound2-dev is NOT installed. Build against the vendored copy:
    cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
      -DALSA_INCLUDE_DIR=/home/bdimaio/usb-16x16-work/deps/libasound2-dev/usr/include \
      -DALSA_LIBRARY=/usr/lib/aarch64-linux-gnu/libasound.so.2
  Source syncs to ~/usb-16x16-work/phase4-build, staging in phase4-install.
- Installed bridge is ae1cf9ba (per-direction prime, prime-trim flag, queue and
  depth floors, capture backlog). Verify before assuming:
    ssh -o HostKeyAlias=audio-dev.local bdimaio@192.168.1.201 \
      'sha256sum /usr/local/libexec/usb16x16-rt-bridge'
- Installing needs the user's password by design. Give them exactly one command:
    ssh -t -o HostKeyAlias=audio-dev.local bdimaio@192.168.1.201 \
      'sudo ~/usb-16x16-work/phase4-install/install-candidate.sh \
       ~/usb-16x16-work/phase4-install/usb16x16-rt-bridge \
       ~/usb-16x16-work/phase4-install/run-phase4-candidate-safe.sh'
- Phase 4 run form (~13 min, 800-impulse standard):
    USB16X16_SAP_WATCH=0 \
    USB16X16_PHASE4_BUFFER_FRAMES=192 \
    USB16X16_PHASE4_PLAYBACK_PRIME_FRAMES=96 \
    USB16X16_PHASE4_TX_PLAYBACK_PRIME_FRAMES=192 \
    USB16X16_PHASE4_RX_PLAYBACK_PRIME_FRAMES=96 \
    work/aes67-candidate/measure-phase4-roundtrip.sh 600 64 800 200
  Other knobs: USB16X16_PHASE4_PRIME_TRIM (leave 0; turning it on causes 673
  XRUNs, see the handoff), USB16X16_PHASE4_RING_FRAMES, _TARGET_FRAMES.
- Stopgap run form, for comparison on equal footing:
    USB16X16_SAP_WATCH=0 USB16X16_TARGET_USEC=3000 USB16X16_SINK_DELAY=576 \
    work/aes67-candidate/measure-aes67-roundtrip.sh 600 64 800 200
- Mac harness: work/latency-harness (Swift, CoreAudio impulse correlation).
- Per-impulse data is in the result JSON under correlation.perImpulseDelaySamples.
  Read it. The median alone hides multi-level distributions.

RULES
The USB module, usb-16x16.service, and setup script are immutable baselines;
AES67 work must never disturb USB enumeration. One variable at a time. Every
figure is reconnaissance until it is soaked under sustained load AND repeated,
because the failure mode varies run to run.
```

---

## Still open, not covered by the prompt

- **Deployment mechanism.** Nothing persistent exists for either the stopgap or
  Phase 4. This is unbuilt design work, not a missing config.
- **The stopgap's stale verdict.** Its "FAILED on stability" rests on a 12 ms
  bimodal defect that no longer reproduces. Its acceptance status deserves a
  fresh look now that it re-baselines at 32.729 ms with 0.333 ms of spread.
- **Host channel-name requirement.** Untouched. macOS still reports UAC2
  speaker positions rather than `1` through `16`.
- **Soak channel loading.** Soaks carry digital silence on the 15
  non-measurement channels, which is not a literal satisfaction of the
  acceptance criterion.
- **AoIP switch QoS.** GS305EP is in `Port-based` mode, which ignores the DSCP
  marks AES67 already sets. No measurable gain expected at current load.
- **The 31.9 s first-RX-stream stall** inside `MergingRavennaALSA`, n=13,
  deterministic, only ever the first sink after `insmod`.
- **Two small daemon items**: PTP "lock" takes exactly 10.00 s every time, a
  fixed dwell rather than convergence; and the daemon defers its first
  current-version SAP announcement by a full 30 s interval.
- **The settle gate's spread test** is coupled to SRC convergence and will fail
  outright at a higher steady-state ppm. Worth making drift-aware.
