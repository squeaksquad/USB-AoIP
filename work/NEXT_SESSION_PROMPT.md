# Next-session pickup prompt

Paste the block below into a fresh Codex or Claude Code session to resume work.
It is a condensed pointer to `PROJECT_HANDOFF.md` and
`outputs/latency/2026-08-31-latency-results.md`, which remain authoritative
where they conflict with this summary.

Written 2026-09-01, against `main` @ `d85844f`.

---

```text
Raspberry Pi 5 USB 16x16 / AES67 bridge. Repo: ~/Development/USB 16x16
(github.com/squeaksquad/usb-16x16-aes67, main @ d85844f).

Read PROJECT_HANDOFF.md and outputs/latency/2026-08-31-latency-results.md
first — they are authoritative and current as of 2026-09-01.

WHERE THINGS STAND
The full digital round trip (Mac -> USB -> Pi -> AES67 -> Ferrofish -> back) is
measured, tuned, and soak-tested. Accepted stopgap: alsaloop --tlatency 3000,
AES67 sink delay 576, driver-default ALSA buffering, 64-frame CoreAudio
buffer = 20.688 ms median. Ten-minute soak was clean on every integrity
measure. Known defect: a bimodal 12 ms step (one 576-frame buffer) in ~10% of
samples, so do not publish a fixed latency to delay compensation.

TASK: Phase 4 — replace the two alsaloop processes with one purpose-built
real-time bridge using ONE shared clock-drift estimator across both
directions. Everything else has been measured and eliminated:
- Parameter tuning has hit its floor (tlatency 2000 and 1000 fail with
  continuous RAVENNA playback underruns).
- Scheduler latency has 14.5x headroom (cyclictest: 184 us worst case loaded
  vs a 2667 us period), so NO PREEMPT_RT kernel and most of Phase 6 is off the
  critical path. A kernel change would force rebuilding both the patched
  usb_f_uac2 and the RAVENNA prototype LKM.
- The bimodal step is two independent SRC servos fighting, which is exactly
  what Phase 4's shared estimator is meant to fix.
Validate against the existing harness so before/after is comparable.

GOTCHAS THAT WILL OTHERWISE COST YOU HOURS
1. After the AES67 daemon restarts, audio takes ~3.5 minutes to start flowing
   (Ferrofish re-resolving subscriptions). Sometimes faster — never assume.
2. NEVER gate a measurement on sink flags. receiving_rtp_packet: true with
   clean seq/SSRC/payload flags occurs while the peer sends pure silence and
   while the path is broken. Gate on a detected return signal, requiring
   several consecutive passing probes.
3. Keep --maximum-lag-ms under 250. Impulses repeat every 250 ms and the
   correlator will otherwise lock a period late and report a plausible but
   wrong result. Tell: high score with large per-impulse spread.
4. Do NOT pass alsaloop --period/--buffer. The driver rounds up to a 2304-frame
   buffer, worse than the 960 it picks by default. --tlatency is the real
   buffer control.
5. Sink delay 48 is unusable in any order — it breaks established streams too.
6. Read sinks back via GET /api/sinks. GET /api/sink/N returns 404.
7. Sink delay is changeable live via PUT /api/sink/{0,1} without a restart;
   tlatency is not.

ENVIRONMENT
- Pi: eth0 169.254.92.97 is the AoIP network; wlan0 192.168.1.201 is SSH and
  management. SSH working says nothing about AoIP health.
  ssh -o HostKeyAlias=audio-dev.local bdimaio@192.168.1.201
- Passwordless sudo is configured for five root-owned wrappers in
  /usr/local/sbin (run-aes67-candidate-safe.sh, run-selfloop-candidate-safe.sh,
  run-bridge-hold-safe.sh, run-ravenna-latency-safe.sh,
  run-cyclictest-safe.sh). Tuning vars cross via env_keep, so the form is
  VAR=value sudo -n /usr/local/sbin/script. Updating a wrapper needs a
  password because they are root-owned — that is the safety property.
- Mac harness: work/latency-harness (Swift, CoreAudio impulse correlation).
  Orchestrator: work/aes67-candidate/measure-aes67-roundtrip.sh

RULES
The USB module, usb-16x16.service, and setup script are immutable baselines;
AES67 work must never disturb USB enumeration. Change one variable at a time.
Every figure so far is reconnaissance except the one soak — a new operating
point needs its own ten-minute soak before acceptance.
```

---

## Still open, not covered by the prompt

- **Host channel-name requirement.** Untouched. macOS still reports UAC2
  speaker positions (`Front Left`, `Front Right`, ...) rather than `1` through
  `16`. See the "Host channel-name requirement" section of the handoff.
- **Soak channel loading.** The soaks carried digital silence on the 15
  non-measurement channels. All 16 streamed end to end with identical packet
  sizes and buffer traffic, and resampling cost is data-independent, so
  transport load is equivalent — but this is not a literal satisfaction of the
  acceptance criterion, which asks for representative program material.
- **AoIP switch QoS.** The GS305EP is in `Port-based` mode with the Pi's port
  set to `Low`. The fix is the QoS mode, not the port priority, since
  `Port-based` ignores the DSCP marks AES67 already sets. No measurable gain
  expected at current network load.
