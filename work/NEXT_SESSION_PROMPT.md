# Next-session pickup prompt

Paste the block below into a fresh Codex or Claude Code session to resume work.
It points at `PROJECT_HANDOFF.md`, `work/aes67-bridge/DEPLOYMENT_PLAN.md` and
`work/SAP_DISCOVERY_FINDING.md`, which are authoritative where they conflict
with this summary.

Rewritten 2026-09-02 after the pull-burst instrumentation found the RAVENNA
packet skip, the combined operating point was accepted on four loaded runs, and
the deployment plan was written.

---

```text
Raspberry Pi 5 USB 16x16 / AES67 bridge. Repo: ~/Development/USB 16x16
(github.com/squeaksquad/usb-16x16-aes67, main, pushed and clean).

Read work/aes67-bridge/DEPLOYMENT_PLAN.md first; it is the task. Then read
PROJECT_HANDOFF.md from "ACCEPTED: the combined point" backwards through
"MEASURED: the RAVENNA device skips one packet about every minute". Older
Phase 4 sections are chronological and several carry retraction notes at the
top; trust the note, keep the measurement.

NOTHING IS BROKEN. Phase 4 is accepted. The task is deployment, and the plan
says to start by asking the seven decisions listed in it, in one batch.

WHAT IS ACCEPTED (2026-09-02)
Bridge 0254348c, target 128, buffer 192 with RAVENNA playback 384, TX prime
288, RX prime 144, sink delay 576. Four 600 s runs at 800 impulses:
29.146 ms x3 and 28.146 ms x1, score 0.945-0.967, spread 9-10 samples, zero
restarts, tx_qfloor 158/193/196/197, rx_qfloor 60-61. That is 3.6 ms under
the stopgap's re-baselined 32.729 ms with a third of its spread.

THE FAILURE MODE, MEASURED AND COVERED
The RAVENNA device's steady pull runs about 15 ppm below its long-term rate
and catches up by skipping one packet every 56-69 s. Each skip is a 144-frame
pull (three packets) inside one 2 ms bridge wakeup gap, and it moves about
40 frames of depth from TX to RX with the sum conserved. A skip that lands at
the minimum of TX's 96-frame push sawtooth needs 144 frames in hand; every
earlier XRUN was that. The accepted point keeps TX's sampled floor above 144
in all four runs. RX's consumer never skips and RX has never failed.

FOUR EXPLANATIONS WERE RETRACTED ON THE WAY, EACH BY MEASUREMENT. Do not
re-propose them: the "startup lottery" (the 1 Hz tx_queue print is a
stroboscope on 1 ms packet pulls; both runs toggled 285/237); a slow
restoring force on depth (there is no leak, and a slow loop cannot cancel a
periodic 48-frame skip); the live sink-delay lever (a live PUT changes the
round trip by up to 2.3 ms non-monotonically and the bridge's depth never
moves; 144 at startup lands on the same sample as 144 live); the earlier
three in the handoff (CoreAudio teardown, sustained load, prime state).

INSTRUMENTS THAT NOW EXIST, ALL BEHAVIOUR-FREE, ALL IN bridge.log
tx/rx_pullmax and _pullhist (device consumption between wakeups, 48-frame
bins), tx/rx_gapmax_us (longest wakeup gap), tx/rx_dmean and _qmean
(per-second means of ring+queue and queue; the conservation test),
tx/rx_caphist (capture backlog per packet bin), DEPTHSTEP lines when the
depth floor drops by a packet, RECOVER lines with the last sampled queue and
gap, and SUMMARY *_before_recovery floors. On a failed run read floors from
those, never from the plain SUMMARY floors, which the recovery cascade
contaminates.

KNOBS THAT NOW EXIST
Bridge: --ravenna-playback-buffer (per-PCM request; 0 = --buffer).
Wrapper positionals: seconds period buffer ring target prime trim txprime
rxprime ravenna_playback_buffer sink_delay. Shim env:
USB16X16_PHASE4_{BUFFER,RING,TARGET,PLAYBACK_PRIME,TX_PLAYBACK_PRIME,
RX_PLAYBACK_PRIME,RAVENNA_PLAYBACK_BUFFER}_FRAMES, USB16X16_PHASE4_SINK_DELAY,
USB16X16_READY_MAX_SPREAD_SAMPLES (readiness spread limit; the shim sets 9
because buffer 192 has an 8-sample bimodality and the old limit of 2 passed
only by luck). work/aes67-candidate/sweep-phase4-sink-delay.sh runs one
candidate and rewrites sinks live between points.

MEASUREMENT STANDARDS
800 impulses (200 s) for anything you intend to trust; 40 impulses is a ten
second window. Never compare a 40-impulse score against an 800-impulse one.
Report tx_qfloor and tx_pullmax alongside latency. Acceptance for any new
point: four 800-impulse runs, zero failures, tx_qfloor above 144 in all.
Latency at buffer 192 moves in 48-sample steps run to run; quote the mode
and the range, not one run.

HOW TO WORK ON THIS - EARNED THE HARD WAY
1. INSTRUMENT BEFORE YOU FIX. Every real advance came from a ten-line
   counter. The pull-burst counter found in 9 s what four sessions missed.
2. DO NOT DO ALGEBRA ON AGGREGATES. Put a counter at the exact point.
3. SEPARATE THE OBSERVATION FROM THE EXPLANATION. Retract explanations
   freely; retract measurements only when the measurement is shown flawed.
4. A 1 Hz PRINT OF A SAWTOOTH IS A STROBE. Use the per-iteration floors and
   the per-second means; the print is for eyeballing only.
5. SUSPICIOUSLY ROUND NUMBERS ARE A TELL, AND SO ARE MULTIPLES OF 48.
   48 frames is one AES67 packet and one USB frame.
6. ENUMERATE EVERY PIN BEFORE ASKING FOR AN INSTALL. Bridge hash in the
   wrapper and the installer; wrapper hash in the installer. Changing the
   wrapper changes its own hash.
7. BUDGET THE USER'S PASSWORD. Batch, verify staged hashes, then give one
   command.
8. CHECK THE PROVENANCE OF ANY NUMBER YOU COMPARE AGAINST.
9. NEVER BUILD ON THE PI WHILE A RUN IS MEASURING.
10. GUARD EVERY SCRIPTED EDIT AND CHAIN THE COMMIT BEHIND IT.
11. LONG RUNS: the tool's background timeout is shorter than a run. Launch
    with python3 subprocess.Popen(start_new_session=True) to a log file,
    watch with a polling Monitor that exits on a line starting with exit=,
    and make the launcher print that marker on its own line. A killed
    Mac-side run leaves the Pi wrapper running to its limit and it cannot be
    stopped without the password.
12. A pgrep -f FOR THE BRIDGE INSIDE AN ssh COMMAND MATCHES THE ssh SHELL
    ITSELF. Anchor it: pgrep -f "^/usr/local/libexec/usb16x16-rt-bridge".

GOTCHAS
1. IGMP snooping is OFF on the GS305EP, deliberately, since 2026-09-01. Time
   to audio after a daemon restart is at most ~52 s. If you see ~260 s,
   check snooping. See SAP_DISCOVERY_FINDING.md.
2. Latency figures are not comparable across that change.
3. The GS305EP's QoS mode was changed off Port-based on 2026-09-02; the
   handoff's "AoIP switch QoS" section predates that. Confirm and record the
   active mode before reasoning about the network.
4. NEVER gate a measurement on sink flags.
5. Keep --maximum-lag-ms under 250.
6. Sink delay: live PUT changes register but are not a latency lever under
   Phase 4; the startup value is a wrapper argument now, also not a lever.
7. bridge.log has no timestamps; 1 Hz lines. DEPTHSTEP and RECOVER carry
   t_us since bridge start.
8. Dante Controller holds UDP 9875; set USB16X16_SAP_WATCH=0.
9. The devices renegotiate buffers: request 192 -> ravenna 128/288,
   usb 96/384 (USB ignores requests). Read NEGOTIATED. RAVENNA playback can
   be requested alone and comes back 128/384 for 384.
10. The wrapper validates TX prime against the RAVENNA playback request when
    one is given, otherwise against the shared buffer request.
11. The Pi wrapper refuses to start over a running daemon or bridge, and the
    future service must refuse over a running candidate. Stop one before
    the other.

ENVIRONMENT
- Pi: eth0 169.254.92.97 is AoIP; wlan0 192.168.1.201 is SSH.
  ssh -o HostKeyAlias=audio-dev.local bdimaio@192.168.1.201
- Installed: bridge 0254348c, wrapper 1baa88a9. Verify:
    ssh -o HostKeyAlias=audio-dev.local bdimaio@192.168.1.201 \
      'sha256sum /usr/local/libexec/usb16x16-rt-bridge /usr/local/sbin/run-phase4-candidate-safe.sh'
- Build (no libasound2-dev; vendored headers), source in ~/usb-16x16-work/
  phase4-build, staging in phase4-install:
    cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
      -DALSA_INCLUDE_DIR=/home/bdimaio/usb-16x16-work/deps/libasound2-dev/usr/include \
      -DALSA_LIBRARY=/usr/lib/aarch64-linux-gnu/libasound.so.2
- Install (password, once):
    ssh -t -o HostKeyAlias=audio-dev.local bdimaio@192.168.1.201 \
      'sudo ~/usb-16x16-work/phase4-install/install-candidate.sh \
       ~/usb-16x16-work/phase4-install/usb16x16-rt-bridge \
       ~/usb-16x16-work/phase4-install/run-phase4-candidate-safe.sh'
- The accepted point, run form (~15 min):
    USB16X16_SAP_WATCH=0 USB16X16_PHASE4_TARGET_FRAMES=128 \
    USB16X16_PHASE4_BUFFER_FRAMES=192 \
    USB16X16_PHASE4_RAVENNA_PLAYBACK_BUFFER_FRAMES=384 \
    USB16X16_PHASE4_PLAYBACK_PRIME_FRAMES=96 \
    USB16X16_PHASE4_TX_PLAYBACK_PRIME_FRAMES=288 \
    USB16X16_PHASE4_RX_PLAYBACK_PRIME_FRAMES=144 \
    work/aes67-candidate/measure-phase4-roundtrip.sh 600 64 800 200
- Stopgap, for comparison:
    USB16X16_SAP_WATCH=0 USB16X16_TARGET_USEC=3000 USB16X16_SINK_DELAY=576 \
    work/aes67-candidate/measure-aes67-roundtrip.sh 600 64 800 200
- Mac harness: work/latency-harness. Per-impulse data is in the result JSON
  under correlation.perImpulseDelaySamples; read it.

RULES
The USB module, usb-16x16.service, and setup script are immutable baselines;
AES67 work must never disturb USB enumeration. Never run ptp4l beside the
daemon. One variable at a time. Every figure is reconnaissance until it is
loaded and repeated.
```

---

## Still open, not covered by the prompt

- **Deployment.** Designed, not built: `work/aes67-bridge/DEPLOYMENT_PLAN.md`,
  including the profile mechanism and the tiered latency roadmap after it.
- **Tier one latency levers**, after deployment: RAVENNA period 48 and RAVENNA
  capture avail_min 48, one run each; see the plan.
- **RX's floor is a draw of the prime overshoot**, 45-93 observed, and has
  never caused a failure. Recorded, not addressed.
- **The rate regression's free intercept** sets where the TX/RX split rests
  and is the last source of run-to-run scatter (floor 158 vs 193-197 on one
  configuration). A small differential bias would address it. Not started.
- **AoIP switch QoS.** Mode changed off Port-based on 2026-09-02; the handoff
  section is stale until the active mode is recorded.
- **The 31.9 s first-RX-stream stall** inside `MergingRavennaALSA`, n=13,
  deterministic, only ever the first sink after `insmod`.
- **Two small daemon items**: PTP "lock" takes exactly 10.00 s every time, a
  fixed dwell rather than convergence; and the daemon defers its first
  current-version SAP announcement by a full 30 s interval.
- **Soak channel loading.** Soaks carry digital silence on the 15
  non-measurement channels.
