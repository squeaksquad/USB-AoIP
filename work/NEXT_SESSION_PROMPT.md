# Next-session pickup prompt

Paste the block below into a fresh Codex or Claude Code session to resume work.
It is a condensed pointer to `PROJECT_HANDOFF.md` and
`work/SAP_DISCOVERY_FINDING.md`, which remain authoritative where they conflict
with this summary.

Written 2026-09-01 after the instrumentation run, against `main`.

---

```text
Raspberry Pi 5 USB 16x16 / AES67 bridge. Repo: ~/Development/USB 16x16
(github.com/squeaksquad/usb-16x16-aes67).

Read in this order:
  - PROJECT_HANDOFF.md, section "Phase 4 implementation status - 2026-09-01"
    and its "Frame accounting from the instrumentation build - run 143219Z"
  - work/SAP_DISCOVERY_FINDING.md

STATE
The accepted operating point is still the dual-alsaloop stopgap: tlatency 3000,
sink delay 576, 64-frame CoreAudio buffer, 32.792 ms median, ten-minute soak
clean. No Phase 4 point is accepted.

Phase 4 is implemented, not stubbed, and has now been measured with exact
frame counters. Two things changed at the last session:

1. The "336 lost TX frames" that blocked run 132356Z was NOT a loss. It was
   tx_queue (the ALSA playback queue depth) shrinking 960 -> 624. The new
   counters show TX conserves exactly: tx_input - tx_frames pinned at 288,
   tx_occ pinned at 195, all run. Run 132356Z is the best Phase 4 candidate on
   record and is no longer disqualified.

2. Net rate transfer is asymmetric: TX applies NOTHING. Measured over 200 s
   of steady running: TX out-in = +0 frames (0.00 ppm applied) while RX out-in
   = -240 (-25.00 ppm), against a commanded -33.6 to -30.1 ppm.
   This is NOT a missing reciprocal - main.cpp:594-596 correctly passes ratio
   to TX and 1.0/ratio to RX. The likely mechanism is the occupancy guard in
   render_to_playback (safe_output_frames = excess_source_frames / source_step),
   which holds the ring at target_frames: tx_occ is pinned at 195 vs a target
   of 192 all run, so TX output tracks TX input 1:1 by feedback and cancels the
   commanded ratio. rx_occ is NOT pinned (drifts 398 -> 196), so RX carries the
   correction. Verify this mechanism before rewriting - it is inferred from the
   counters plus the code, not proven.

Phase 4 latency is not yet competitive:
  96/384/768/192   -> 40.2-42.6 ms  (3 runs)
  96/960/1536/192  -> 76.9-82.5 ms  (4 runs, current pin)
  dual alsaloop    -> 32.792 ms     (accepted, soaked)
The large buffers were adopted for stability and cost ~36 ms. Since the TX
frame loss was illusory, revisit the smaller 96/384/768/192 point before
investing more in the large one.

RX XRUNs are a fast starve, not a slow drift: the queue drains 876 -> 108 over
9 s (~96 frames/s) with ring occupancy healthy at ~196 against a target of 192.
Chase the converter's output scheduling, not ring sizing.

TASKS, in order
1. Work out why TX's commanded ratio nets to zero (see item 2 above), fix it,
   then re-run 96/384/768/192 and 96/960/1536/192 and compare. Start by
   confirming the occupancy-guard hypothesis - instrument the ring consumption
   per render call. Pure on-Pi work.
2. The 31.9 s first-RX-stream stall inside MergingRavennaALSA (see the finding
   doc). Deterministic across 13 runs, only ever the FIRST sink after insmod;
   sink 1 and both TX sources return in 0.000 s. It also holds the
   session_manager lock, delaying the first SAP announcement by 11 s. Test
   whether the cost is per-insmod or per-daemon-start, and whether adding a
   throwaway sink early moves it off the critical path.
3. A new operating point needs its own ten-minute loaded soak before acceptance.

NOTHING HERE REQUIRES BEING AT THE RACK
  The switch management UI at 169.254.0.239 answers over the Mac's en12
  (HTTP 200, ~1.7 ms). Ports are resolved: port 2 is the ULN-2 3d, port 3 is
  the Ferrofish, port 5 the Mac, port 1 the Pi.

  The IGMP snooping A/B is ready to run. Its outcome measure is the end-to-end
  first-return-signal time, NOT a per-port counter, so port identity does not
  gate it. Baseline is 263-267 s over seven runs with a 4 s spread; with
  snooping off, predict a collapse to roughly 45-75 s. One switch toggle plus
  one ~15 min harness run. It does change the network under test, so record it.

  Better still, test the FIX rather than the diagnostic: run an IGMP querier on
  the segment and see whether the 264 s collapses without disabling snooping.
  Sending queries needs raw sockets, so it needs one root step - either a Mac
  sudo or a new root-owned Pi wrapper. Both are remote, neither is physical.

  Caution when disabling port 2: MHLinkAudio.driver is a live CoreAudio device
  and the ULN-2 has no alternate path, so close any session first. Disabling 2
  or 3 cannot cut your own management path, which runs via port 5.

GOTCHAS THAT WILL OTHERWISE COST YOU HOURS
1. FIXED 2026-09-01. Audio USED to take 263-267 s to start after a daemon
   restart. IGMP snooping is now OFF on the GS305EP and it is at most 52.4 s,
   bounded by the Pi's own ~42 s startup. If you see the old 260 s behaviour,
   check whether snooping got re-enabled before you debug anything else.
2. NEVER gate a measurement on sink flags. receiving_rtp_packet: true occurs
   during pure silence and on a broken path. Gate on a detected return signal
   across several consecutive probes.
3. "return signal ready after N probes" is NOT when the path came up. The
   settle gate's spread<=2-samples test is coupled to SRC convergence and adds
   a variable 9-141 s. Read readiness-probe-*.json capturedAt for the real
   turn-on.
4. Keep --maximum-lag-ms under 250. Impulses repeat every 250 ms.
5. Do NOT pass alsaloop --period/--buffer. --tlatency is the real control.
6. Sink delay changes live via PUT /api/sink/{0,1} without a restart, so the
   Ferrofish never re-subscribes. tlatency does not. Read sinks back via
   GET /api/sinks; GET /api/sink/N returns 404.
7. Sink delay 48 is unusable in any order - it breaks established streams too.
8. bridge.log has no timestamps, but emits at 1 Hz (48000 frames per line).

ENVIRONMENT
- Pi: eth0 169.254.92.97 is the AoIP network; wlan0 192.168.1.201 is SSH and
  management. SSH working says nothing about AoIP health.
  ssh -o HostKeyAlias=audio-dev.local bdimaio@192.168.1.201
- Passwordless sudo covers six root-owned wrappers in /usr/local/sbin,
  including run-phase4-candidate-safe.sh. Form: VAR=value sudo -n /path/script.
  Updating a wrapper needs a password because they are root-owned - that is the
  safety property.
- Phase 4 run form (the 143219Z invocation):
    USB16X16_PHASE4_BUFFER_FRAMES=960 USB16X16_PHASE4_RING_FRAMES=1536 \
      work/aes67-candidate/measure-phase4-roundtrip.sh 480 64 40 200
  Defaults in measure-phase4-roundtrip.sh are buffer 384 / ring 768.
  Budget ~15 min per run: ~264 s network wait + gate lag + the run itself.
- Mac harness: work/latency-harness (Swift, CoreAudio impulse correlation).

NETWORK STATE - READ BEFORE COMPARING ANY NUMBER
IGMP snooping is OFF on the GS305EP as of 2026-09-01. Every figure recorded
before that was measured with it ON. Latency numbers in particular are NOT
comparable across the change: settle now finishes around +60 s instead of
+363 s, so the 40-impulse measurement fires ~300 s earlier in the shared
estimator's convergence, and measured latency falls as that converges. The
84.29 ms of run 151450Z (score 0.987) and the 76.92 ms of run 143219Z
(score 0.320) differ mostly for that reason, not because anything regressed.
Re-baseline before drawing conclusions.

With snooping off the switch floods 68 Mbps to every port. Fine for the four
gigabit devices; 68% of link for the 100 Mb Dante AVIO on port 4, and it would
exceed that port at 96 kHz. Re-enabling snooping does NOT fix that - with no
querier the entries age out and it floods anyway, so you would get a 260 s
broken window and the same flood. Mitigations are a querier, disabling port 4,
or a VLAN. The user runs 96 kHz infrequently and has accepted this for now.

RULES
The USB module, usb-16x16.service, and setup script are immutable baselines;
AES67 work must never disturb USB enumeration. Change one variable at a time.
Every figure to date was measured with IGMP snooping ENABLED - changing that
changes the network under test. Every figure is reconnaissance except the one
soaked stopgap.
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
- **Two small daemon-side items**, noted but not chased: PTP "lock" takes
  exactly 10.00 s in all 13 runs, which is a fixed dwell rather than measured
  convergence; and the daemon defers its first current-version announcement by
  a full 30 s interval even though it can announce immediately.
- **The settle gate's spread test** (`work/aes67-candidate/measure-aes67-roundtrip.sh`)
  is coupled to SRC convergence and should probably be widened or made
  drift-aware, since it will fail outright at a higher steady-state ppm.
