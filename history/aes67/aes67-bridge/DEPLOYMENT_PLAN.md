# Phase 4 deployment plan

Written 2026-09-02 for implementation in a fresh session. Nothing in this
directory exists yet; this file is the design. Read `PROJECT_HANDOFF.md`
from "ACCEPTED: the combined point" backwards through "MEASURED: the RAVENNA
device skips one packet" before starting, and the "HOW TO WORK ON THIS" rules
in the pickup prompt at the end of this file.

## Goal

Run the accepted Phase 4 operating point as a persistent systemd service on
the Pi: starts at boot, survives daemon, PTP, network and USB hiccups by
restarting the AES67 stack, never touches `usb-16x16.service`, and can be
stopped so the existing candidate wrapper can still take measurements.

## The frozen operating point

| item | value |
|---|---|
| bridge binary | `/usr/local/libexec/usb16x16-rt-bridge`, SHA-256 `0254348cd21e119bd4a42a9450b616b3c2930abaff1ae836a72f5bcce3f58d5e` |
| bridge arguments | `--period 96 --buffer 192 --ravenna-playback-buffer 384 --ring 768 --target 128 --playback-prime 96 --tx-playback-prime 288 --rx-playback-prime 144 --prime-trim 0 --priority 90 --seconds 0` |
| sink delay | 576 on both sinks, applied before the bridge primes |
| daemon | `~/usb-16x16-work/aes67-daemon-src/build-daemon/aes67-daemon`, SHA-256 pinned in the wrapper (`e31ba2c4...`) |
| RAVENNA module | pinned in the wrapper (`f65a4955...`), loaded with `insmod`, removed on stop |
| PTP grandmaster | `00-1D-C1-FF-FE-1D-27-DC`, must be locked before sinks are written |
| measured | 29.146 ms x3, 28.146 ms x1, 800 impulses each, `tx_qfloor` 158-197, zero failures |

`--seconds 0` makes the bridge run until signalled; it handles SIGINT, SIGTERM
and SIGHUP already. Optional before freezing: TX prime 336 pins the RAVENNA
queue full and widens the worst-case skip margin for about 1 ms. Decide, then
measure once if changed; do not change it inside the deployment work.

## What is reused, and what is not

`work/aes67-candidate/run-phase4-candidate-safe.sh` is the validated start
sequence and stays exactly as it is, hash-pinned, for measurements. The
service reimplements the same sequence with different lifecycle semantics.
Copy the sequence; do not call the wrapper (it is time-limited to 1200 s and
rejects a run on any direction restart, which is right for a candidate and
wrong for a service).

The sequence the wrapper validates, in order:

1. Hash-check daemon, module and bridge; refuse to start if `ptp4l`,
   `aes67-daemon`, `alsaloop` or the bridge is already running.
2. Generate a daemon config pointing `status_file` at a private copy of
   `runtime/status.json` with the sink delay substituted (`"delay": 576`
   appears exactly twice in the protected file).
3. `insmod` the RAVENNA module. Start the daemon. Wait up to 30 s for
   `GET /api/ptp/status` to answer.
4. Wait up to 90 s for `"status": "locked"` with the expected GMID.
5. `PUT /api/sink/0` and `/api/sink/1` from the private status copy, then
   `GET /api/sinks` and verify both delays. This is the fix for the daemon
   startup race; the daemon does not retry rejected sinks on its own.
6. Start the bridge; within 4 s require it alive and a `NEGOTIATED` line.
7. On stop: SIGINT the bridge, wait 5 s; SIGINT the daemon, wait 5 s, then
   SIGTERM; `rmmod MergingRavennaALSA` with retries.

## Files to create, all under `work/aes67-bridge/`

| file | installs to | purpose |
|---|---|---|
| `usb16x16-aes67-supervisor` | `/usr/local/sbin/` | the sequence above as a long-running root script, stage-logged to stdout for journald |
| `usb16x16-aes67.service` | `/etc/systemd/system/` | unit; see below |
| `aes67.conf` | `/etc/usb16x16/aes67.conf` | the frozen point as `KEY=value`, read by the supervisor; the only file an operator edits |
| `install-aes67-service.sh` | run once with sudo | pins the supervisor's and the bridge's hashes, installs the three files, `daemon-reload`, does not enable or start |
| `README.md` | | operation: start, stop, status, how to measure, how to roll back |

Keep the supervisor in bash like the wrapper, so the two can be diffed. Every
scripted install edit gets a guard and the commit is chained behind it.

## Unit design

```ini
[Unit]
Description=USB 16x16 AES67 bridge (Phase 4)
After=network-online.target usb-16x16.service
Wants=network-online.target
# Deliberately no Requires= on usb-16x16.service: an AES67 failure must
# never be able to stop or restart the USB gadget.

[Service]
Type=simple
ExecStart=/usr/local/sbin/usb16x16-aes67-supervisor
ExecStopPost=/usr/local/sbin/usb16x16-aes67-supervisor cleanup
Restart=on-failure
RestartSec=10
StartLimitIntervalSec=0
KillMode=mixed
TimeoutStopSec=25
EnvironmentFile=/etc/usb16x16/aes67.conf

[Install]
WantedBy=multi-user.target
```

`StartLimitIntervalSec=0` because a Mac asleep overnight must not exhaust a
start limit and leave the service dead in the morning. The supervisor itself
backs off: after three consecutive failures inside five minutes it sleeps 60 s
before exiting non-zero, so a broken network becomes one log line a minute,
not a thrash.

## Supervisor behaviour beyond the wrapper

- **Stages are logged** with a stable prefix (`STAGE insmod`, `STAGE ptp
  locked in 31 s`, `STAGE sinks applied`, `STAGE bridge negotiated`), so
  `journalctl -u usb16x16-aes67` reads as a timeline.
- **Daemon exit or bridge exit** ends the supervisor non-zero; systemd
  restarts the whole stack. Do not try to restart one component in place;
  the sequence's ordering is the thing that works.
- **Bridge direction restarts** (`RECOVER` lines) are tolerated and counted.
  The bridge already re-primes. If more than five occur in any 60 s window,
  exit non-zero: that is the 673-recoveries-per-run failure shape and the
  stack needs a clean restart.
- **Telemetry volume.** The bridge prints a 1 Hz `BRIDGE` line of about
  600 bytes; that is 50 MB/day in the journal. Do not change the bridge.
  The supervisor pipes bridge stdout through a sampler: every `PRIMED`,
  `NEGOTIATED`, `RECOVER`, `DEPTHSTEP` and `SUMMARY` line always, and one
  `BRIDGE` line every 10 s, to the journal; the full-rate stream goes to
  `/run/usb16x16/bridge.log` on tmpfs, truncated at each start, for
  post-mortem of the last session only.
- **USB host presence.** Decision needed (below). Default in this plan: do
  not wait for the Mac. Start the stack; if the bridge cannot open or run
  the gadget PCMs it exits, systemd restarts in 10 s, and the backoff above
  keeps that quiet. Measure what actually happens with the host asleep
  before choosing otherwise.
- **`status` subcommand** prints: service active time, last `BRIDGE` line
  parsed into ppm, floors and restarts, `GET /api/ptp/status`, `GET
  /api/sinks` delays, UDC state, and `usb-16x16.service` state.

## Coexistence with measurement

The candidate wrapper refuses to start while the daemon or the bridge is
running, and the service must not start while a candidate is running.
Document one rule: `systemctl stop usb16x16-aes67` before any
`measure-phase4-roundtrip.sh` run, `systemctl start` after. Add a check to
the supervisor's first stage that refuses if the candidate ready file exists
or the wrapper is running, mirroring the wrapper's own refusal.

## Acceptance for the deployment (all of these, recorded in the handoff)

1. **Cold boot to audio** with no intervention, three times; record time to
   audio from boot (expect under two minutes; IGMP snooping is off on the
   switch, which is what makes this possible).
2. **Stop/start** five cycles clean; `usb-16x16.service` active and the UDC
   `configured` throughout.
3. **`kill -9` the daemon** and separately **the bridge**: stack restarts,
   audio returns, one journal timeline each.
4. **Unplug and replug the USB data cable** with the service running;
   record what the bridge does and whether audio returns without a manual
   restart.
5. **Mac asleep for an hour** with the service running; the journal must
   show the backoff and not a start-limit failure.
6. **Eight-hour unattended soak** with the sampled telemetry: report restarts,
   `RECOVER` count, `tx_qfloor`, skip count. Expect zero restarts. This is
   the first time the point runs longer than 20 minutes.
7. **Measurement under the coexistence rule**: stop, run the 800-impulse
   candidate at the frozen point, expect 28.1-29.1 ms, start again.

Rollback is `systemctl disable --now usb16x16-aes67` plus `rmmod`; the
stopgap runner and the candidate wrapper remain installed and untouched.

## Profiles: latency modes as data, not code

Every operating point this project has measured is the same binary with a
different argument set, and every future tier below is too. So the service
reads a named profile, and the eventual web UI switches profiles rather than
editing numbers. A profile switch is a stack restart (about a minute to
audio), which the UI must say out loud.

`/etc/usb16x16/aes67.conf` holds `PROFILE=<name>` plus one block per
profile; the supervisor expands the selected block into bridge arguments and
the sink delay. Ship two, and keep the shape open for more:

| profile | point | measured | skip cover | status |
|---|---|---:|---|---|
| `safe` | target 128, RAVENNA playback 384, TX 288, RX 144, buffer 192 | 29.1 ms | TX floor 158-197 | accepted, the default |
| `fast` | target 128, TX 192, RX 96, buffer 192 | 24.5 ms | none; TX floor 97 | measured once, survival is phase |

Each profile block carries the arguments, the sink delay, a one-line
description, and a `cover` flag the UI shows next to the name. A profile
that has not passed four loaded runs is marked `experimental` in the block
and the UI shows that too. Adding a tier later is a new block and its runs;
nothing else changes.

The web UI itself is future work. The daemon already serves an HTTP API and
page on port 8080; the bridge's `status` subcommand is designed to be the
data source a small control page reads, and the supervisor should accept a
`switch-profile <name>` subcommand from the start so the UI has one thing to
call. Do not build the page in the deployment session.

## Latency roadmap after deployment

The accepted point sits at 29.1 ms. From the measurements so far, the round
trip divides roughly as: bridge rings 5.3 ms, bridge device queues 8.8 ms,
capture backlog 1.6 ms, RAVENNA playback buffer 1.7 ms (measured),
RAVENNA capture side about 3.7 ms (inferred), Ferrofish about 3.5 ms, Mac
CoreAudio at 64 frames plus USB framing 5.25 ms (measured with RTL Utility:
252 samples at 64 frames, 188 at 32, see the handoff). The bridge owns about 16 ms,
and nearly all of the queue depth exists for one reason: the RAVENNA
device's once-a-minute three-packet pull.

### Tier one: 29 -> about 25 ms, inside the current design, deploy-safe

Two unexplored levers, one run each at 800 impulses, acceptance as for the
accepted point (four loaded runs, `tx_qfloor` above 144 in all):

1. **RAVENNA period 48.** The bridge already accepts `--period 48`; USB
   ignores period requests, RAVENNA may not. If RAVENNA negotiates 64/144 or
   similar, capture backlog and the minimum capture buffer both roughly
   halve. Read `NEGOTIATED` first; if it comes back 128/288 the lever does
   not exist and the run is still useful as a null result.
2. **RAVENNA capture `avail_min` 48.** The capture histogram shows the
   RAVENNA capture pointer advancing per packet, so waking on 48 rather than
   96 halves RX's push sawtooth. RX's floor has followed
   `prime + overshoot - 96` in every run; with 48-frame pushes that becomes
   `- 48`, and RX prime can drop by about a period for the same floor. One
   sw_params call behind a flag; a bridge rebuild and re-pin.

Expected landing: 25-26 ms with cover kept. Becomes profile `safe` once
accepted; the old `safe` block is kept under a dated name for rollback.

**Result, 2026-09-03 (handoff "ACCEPTED: period 48"):** lever 1 exists and
was accepted on four loaded runs: 25.563 ms x2, 25.813, 27.313 (1227, 1227,
1239, 1311), `tx_qfloor` 164-193, zero failures, `tx_pullmax` 48 in every
run. `NEGOTIATED` came back 48/192 on USB as well as RAVENNA, so the
premise above that USB ignores period requests was wrong, and the one flag
moved both sides. Lever 2 is subsumed: the bridge sets `avail_min` to
`min(negotiated, requested)`, so period 48 already gives RAVENNA capture
`avail_min` 48; there is no separate flag to test. Staged as profile
`safe`, the period-96 point kept as `safe-96`, conf `4bd2f070`.

### Tier two: 25 -> about 20 ms, remove the skip at its source

The RAVENNA driver's steady pull runs about 15 ppm below its long-term
rate and corrects by skipping a packet every 56-69 s (measured, sections
"MEASURED: the RAVENNA device skips one packet" and following). The handoff
also records that the prototype driver does not use the NIC's hardware
clock and times itself in software. If its media clock were disciplined
continuously rather than stepped, TX's cover requirement falls by three
packets and the queues by 3-4 ms round trip.

This is kernel work inside the Merging RAVENNA ALSA module, which is open
source but sits on the protected rollback path. Rules: a separately named
module build, the known-good module untouched and its restore commands
written down first, one variable at a time. The pull-burst counter is the
acceptance instrument: the tier is done when `tx_pull_max` reads 96 across
four loaded runs, and only then are the queues trimmed. Stop condition: if
the driver's clock path cannot be changed without touching its RTP timing,
stop; the 3-4 ms is not worth the receive path.

### Tier three: Phase 5, the USB gadget paced from PTP

Collapses the rings and the drift half of the queues, perhaps 4-5 ms, by
making the Mac follow a PTP-derived UAC2 rate through the gadget's
asynchronous feedback, so the ASRC becomes near-unity and the reservoirs
shrink to scheduling jitter. It does nothing about the skip, so it pays only
after tier two. It is the deepest change in the project: the exact-source
`usb_f_uac2` module that USB enumeration depends on. Same rules as tier two,
plus cold-boot and macOS enumeration tests before the known-good module is
ever unloaded. Handoff section "Phase 5: PTP-disciplined USB research" has
the architecture sketch.

**Corrected 2026-09-05 (handoff "Phase 5 Stage A").** The userspace half of
this tier shipped on 2026-09-02 as `--usb-pitch-servo 1`: the Mac already
follows the RAVENNA rate through the gadget's pitch controls and both
converters run at exactly 1.0. What the servo left behind was priced from
42 service sessions and 17 candidate runs
(`outputs/latency/phase5-20260905/`): a fixed warm-up drift of 46 frames
per direction while pitch sits at nominal for the estimator's first 60 s
(1 ms of TX prime, recoverable by seeding the pitch), a post-settle
quantisation band of about 10 frames per direction (0.2 ms, the only term
a kernel-side feedback would touch), and a ring reserve at target 128 that
has never been drawn below 131 in any session (up to 3.3 ms round trip,
a profile change). The kernel module step is therefore closed unless a
later measurement finds a clock term above 20 frames per direction; the
remaining bridge-side terms are the ring target, the seed, and the Pi
wakeup gap (Phase 6).

### The floor

Mac at 64 frames both ways (5.25 ms measured), the Ferrofish, and the
RAVENNA device's own buffering total 12-13 ms before the bridge holds a
frame. With all three tiers done, this loop bottoms out around 16-17 ms.

**Corrected 2026-09-06 (handoff "BUDGET", "MEASURED ... the packet
capture", "CONFIRMED ... in the driver source").** The 12-13 ms above was
not measured and was wrong by the largest term in the loop. The impulse
trace and an `eth0` capture split the device timeline: the bridge's own
holdings equal its start depth (about 528 samples at target64), the two
Pi USB legs are about 22-40 samples, the Ferrofish with both wires is
2.7 ms, the RAVENNA capture side 2.2 ms, and the RAVENNA *playback* side
was 12.1 ms from the bridge's write to the packet, because the Merging
module sent each packet from the live-out slot one playback buffer minus
one period old (336 frames, 7 ms, at 384). `work/ravenna-tx-fix/` fixes
that in one expression; on the fixed module target64 reads 819 samples
(17.1 ms) at 64 frames against 1127 before, and the RAVENNA playback
buffer stops being a latency term. Tier two above is superseded by that
fix; its "3-4 ms" was this term seen from the other side.
Below that is a 32-frame CoreAudio buffer (1.33 ms, measured), a
different receiver than the Ferrofish, or hardware
timestamping in the driver; none of it is Pi-side work, and the profile
mechanism above is how any of it ships if it ever does.

## Decisions to take before implementing

Taken 2026-09-02, all as recommended: (1) manual start first, enable after
items 2, 3 and 7 pass; (2) the supervisor waits for the UDC to be
`configured` and eth0 at 1 Gb/s before `insmod`, logging once a minute,
rather than fail-looping; (3) five RECOVER lines per 60 s; (4) one BRIDGE
line in ten to the journal, full stream on tmpfs rotated once at 64 MB;
(5, 7) `fast` ships as an experimental block, `safe` is the default;
(6) TX prime 288 frozen, 336 on the post-deployment list. The daemon logs
to the journal too. Implemented in this directory; see `README.md`.

Ask these in one batch at the start of the session:

1. Enable at boot from the first install, or manual start for the first
   days?
2. Wait for the USB host, or start regardless and let the backoff handle it?
3. Direction-restart tolerance: the five-per-minute rule above, or stricter?
4. Journal sampling rate and whether the full-rate tmpfs log is wanted.
5. Expose a second "fast" profile (target 128, TX 192 / RX 96, 24.5 ms, no
   skip cover) in `aes67.conf`, or ship only the accepted point?
6. TX prime 288 as measured, or 336 with one confirming run first?
7. Ship `fast` as a selectable profile marked experimental, or `safe` only?

## Pickup prompt for the next session (written 2026-09-03, period 48 deployed)

Copy this into the new chat:

> Raspberry Pi 5 USB 16x16 / AES67 bridge. Repo ~/Development/USB 16x16
> (github.com/squeaksquad/usb-16x16-aes67, main).
>
> Read work/aes67-bridge/README.md first, then PROJECT_HANDOFF.md from
> "DEPLOYED: usb16x16-aes67.service" forward through "ACCEPTED: period 48
> (tier one, lever 1)", then "ACCEPTED: the combined point" for the
> period-96 point it replaces. work/aes67-bridge/DEPLOYMENT_PLAN.md is the
> design; its "Latency roadmap" carries tier one's result and tiers two
> and three.
>
> NOTHING IS BROKEN. usb16x16-aes67.service is enabled at boot and running
> profile "safe" = period 48, installed 2026-09-02 21:25 local (conf
> 4bd2f070; the period-96 point is kept as "safe-96"). The task is the
> user's choice from the open items; ask which before starting.
>
> WHAT IS INSTALLED (2026-09-03 02:00 UTC)
> Bridge 0254348c, candidate wrapper 1baa88a9, supervisor e300cc33, unit
> 77837e60, /etc/usb16x16/aes67.conf 4bd2f070. Verify:
>   ssh -o HostKeyAlias=audio-dev.local bdimaio@192.168.1.201 \
>     'sha256sum /usr/local/libexec/usb16x16-rt-bridge \
>      /usr/local/sbin/run-phase4-candidate-safe.sh \
>      /usr/local/sbin/usb16x16-aes67-supervisor \
>      /etc/systemd/system/usb16x16-aes67.service /etc/usb16x16/aes67.conf'
> The Pi's journal is persistent. bdimaio can start, stop, restart, enable,
> disable the unit, switch profiles, pkill the daemon or bridge, and reboot
> without a password; anything else with sudo needs the user, so batch it,
> verify staged hashes, and give one command.
>
> THE POINT (profile safe, period 48)
> --period 48, target 128, buffer 192, RAVENNA playback 384, TX prime 288,
> RX prime 144, sink delay 576. NEGOTIATED 48/192 on USB capture, USB
> playback and RAVENNA capture, 48/384 on RAVENNA playback: USB grants 48
> too, so the flag moves both sides and avail_min with them. Four wrapper
> runs, 800 impulses each: 1227, 1227, 1239, 1311 samples (25.6-27.3 ms,
> mode 25.6), tx_qfloor 164-193, rx_qfloor 100-109, zero restarts, zero
> RECOVERs, tx_pullmax 48 in all four: the 144-frame three-packet pull seen
> in every period-96 run did not appear (observation, not explanation; the
> 144 cover bar stays). Each run's level is set at start (all readiness
> probes read the run's median) and the scatter is the resting level.
> The running service after a warm start: 1239 (25.813 ms) and 1227
> (25.563 ms), zero RECOVERs. RTL Utility against it: 31.062 ms (1491) at
> 64 frames, 29.729 ms (1427) at 32, both exactly harness plus the Mac-side
> cost. The period-96 point (safe-96): 27.6-29.6 ms, tx_qfloor 158-205.
>
> THE COLD-BOOT COST (one boot, measured 2026-09-03)
> A cold boot at period 48 took the shorter path (startup XRUN pair, three
> RX playback XRUNs by 65 s, no rule trip, audio at 61 s) but TX kept the
> depth it gained while RX re-primed: ring 400-470 and queue pinned at 384
> for the rest of the boot, depth mean 798 against 359-404. The service
> read 1719 (35.813 ms, zero spread) against that boot, 480 samples = ten
> periods = 10.0 ms above a warm start; a systemctl restart brought it
> back to 1227. Depth is conserved after priming and the estimator matches
> rate, not level. Never measured at period 96 (all service runs there
> followed a restart), so it may be old.
>
> THE DAW-SIDE NUMBER
> RTL Utility against the period-96 service: 34.896 ms (1675) at 64
> CoreAudio frames, 33.562 ms (1611) at 32; the harness read 1423 both
> times. Mac-side cost 252 samples at 64, 188 at 32: the two IO buffers
> plus a constant 124 (2.58 ms). The 32-frame lever is real and worth
> 1.33 ms at the DAW; CoreAudio's reported latency (376, 312) overstates
> the real Mac-side cost by 124 both times.
>
> WHAT THE SERVICE DOES, ALL MEASURED (at period 96; re-check at 48)
> Cold boot to running 61-64 s; about six boots in ten take one
> self-healing stack restart in the first minute (stable audio at about
> two minutes). Every cold boot starts the bridge with a capture-XRUN pair
> on both directions; warm starts never do. Daemon or bridge death: stack
> restart, audio in about a minute. Host gone (unplug, suspend, or a Mac
> that will not enumerate): a RECOVER storm, "host absent" in 3 s, the
> bridge alone stops, daemon and module stay, retry every 60 s. Host back:
> audio 5 s after a dwc2 enumeration line, or within about 70 s after a
> wake from sleep, which never re-enumerates. /sys/class/udc/*/state is
> blind to all of it (stays "configured"). A stop is honoured within
> seconds at any stage. The bridge stops writing its 1 Hz BRIDGE line
> during a storm; the journal carries 20 RECOVER lines per storm and a
> marker, the full stream is /run/usb16x16/bridge.log.
>
> OPEN ITEMS (the user picks)
> 1. The cold-boot cost. Instrument first: two more watched cold boots,
>    each followed by measure-under-service.sh 64 800, to see whether the
>    excess is always 480 and whether a rule-tripped boot (which restarts
>    the stack) comes back at 1227-1239. Then the fix, one of: the
>    supervisor restarts the bridge once after any RECOVER in the first
>    minute (service-side, deploy-safe, costs the boots that heal in place
>    the same minute the rule-tripped ones already pay), or the bridge
>    re-primes both directions when either recovers (bridge change: re-pin
>    wrapper, installer, supervisor). Operational workaround today:
>    sudo systemctl restart usb16x16-aes67 after a cold boot.
>    Roll back the profile with: sudo usb16x16-aes67-supervisor
>    switch-profile safe-96.
> 2. Tier two, from the roadmap: the driver's stepped media clock. First
>    a counter, not a fix: whether the skip still occurs at period 48 and
>    what shape it takes (tx_pullmax 48 in four runs says the three-packet
>    pull is gone or disguised; a per-pull log at the 1 kHz cadence would
>    tell). If it is gone, tier two's premise changes and the TX prime
>    (288) is the next lever, one variable at a time.
> 3. The driver XRUN pair: rare (about one per one to two hours), RAVENNA
>    capture and both playbacks in XRUN with the bridge's gaps normal, three
>    times within 0.4 s of an ssh session close, 133 controlled closes
>    without one. Needs a counter, not a theory.
> 4. The first-minute cold-boot cascade (USB-side rate shapes, two
>    variants), self-healing; a counter if the extra minute ever matters.
> 5. One hard reset with no journal trace, during a candidate start beside
>    module load/unload churn, 2026-09-02 10:32 local. Not seen since.
> 6. A one-side period 48 (USB only or RAVENNA only) needs a per-device
>    period option in the bridge; only worth building if a number needs
>    attributing. Phase 5 rate discipline only after tier two.
>
> MEASUREMENT MODES
> Wrapper (stack restart, RECOVER fatal, the acceptance instrument):
>   ssh ... 'sudo systemctl stop usb16x16-aes67'; then
>   USB16X16_SAP_WATCH=0 USB16X16_PHASE4_PERIOD_FRAMES=48 \
>   USB16X16_PHASE4_TARGET_FRAMES=128 USB16X16_PHASE4_BUFFER_FRAMES=192 \
>   USB16X16_PHASE4_RAVENNA_PLAYBACK_BUFFER_FRAMES=384 \
>   USB16X16_PHASE4_PLAYBACK_PRIME_FRAMES=96 \
>   USB16X16_PHASE4_TX_PLAYBACK_PRIME_FRAMES=288 \
>   USB16X16_PHASE4_RX_PLAYBACK_PRIME_FRAMES=144 \
>   work/aes67-candidate/measure-phase4-roundtrip.sh 600 64 800 200
>   then 'sudo systemctl start usb16x16-aes67'. About 11 minutes a run.
> Against the running service (RECOVER counted, not fatal):
>   work/aes67-candidate/measure-under-service.sh 64 800
> 800 impulses for anything you intend to trust; report tx_qfloor and
> tx_pullmax alongside latency; latency moves in 48-sample steps and
> sometimes 24 or 12; quote the mode and the range. The candidate's
> stdout reaches the Mac log only when its ssh session ends; read
> NEGOTIATED from the Pi's ~/usb-16x16-work/logs/phase4-candidate-*/
> bridge.log. Pull and capture histogram bins are 48 frames wide.
>
> HOW TO WORK ON THIS, EARNED THE HARD WAY
> Instrument before you fix. No algebra on aggregates. Separate the
> observation from the explanation; a 13-session test does not clear a 2%
> effect. A 1 Hz print is a strobe. Multiples of 48 are a tell. Enumerate
> every pin before asking for an install; changing the wrapper or the
> supervisor changes its own hash; the installer pins supervisor, unit and
> conf and keeps an edited conf. Never build or install on the Pi while a
> run is measuring. Guard every scripted edit and chain the commit. Long
> runs: python3 Popen(start_new_session=True) to a log, a polling Monitor
> that exits on a line starting with exit=, launcher prints the marker on
> its own line; a killed Mac-side run leaves the Pi wrapper running. Watch
> the Pi over ONE long ssh session, not a poll loop of sessions. A pgrep -f
> for the bridge inside an ssh command matches the ssh shell; anchor it.
> An outer bash heredoc ends at the first line matching its delimiter,
> including one inside the text you are inserting. In zsh, echo ===== is
> an equals-expansion and aborts the command list; use a quoted dash rule.
> outputs/latency/*-candidate.log and *-measure.log are gitignored.
>
> GOTCHAS
> IGMP snooping is OFF on the GS305EP (time to audio ~52 s after a daemon
> start; ~260 s means check snooping). The switch is in 802.1p/DSCP mode.
> Never gate a measurement on sink flags. Keep --maximum-lag-ms under 250.
> Sink delay is not a latency lever under Phase 4. Dante Controller holds
> UDP 9875; set USB16X16_SAP_WATCH=0. The driver drops and re-locks PTP
> about 8 s after every module load; the sink 0 PUT then takes 32 s, half
> the time to audio, and lives in the daemon or driver. The wrapper and
> the service refuse to run over each other. wlan0 can take up to a few
> minutes to associate after a reboot; eth0 169.254.92.97 answers ssh
> meanwhile. A second Mac set to "ask for new accessories" never
> enumerated the gadget; unexplained.
>
> ENVIRONMENT
> Pi: eth0 169.254.92.97 is AoIP; wlan0 192.168.1.201 is SSH.
>   ssh -o HostKeyAlias=audio-dev.local bdimaio@192.168.1.201
> Build (no libasound2-dev; vendored headers), source ~/usb-16x16-work/
> phase4-build, staging phase4-install (bridge) and aes67-service (service):
>   cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
>     -DALSA_INCLUDE_DIR=/home/bdimaio/usb-16x16-work/deps/libasound2-dev/usr/include \
>     -DALSA_LIBRARY=/usr/lib/aarch64-linux-gnu/libasound.so.2
> Bridge install: sudo ~/usb-16x16-work/phase4-install/install-candidate.sh
>   <bridge> <wrapper>   (pins in wrapper, installer and supervisor)
> Service install: sudo systemctl stop usb16x16-aes67 &&
>   sudo ~/usb-16x16-work/aes67-service/install-aes67-service.sh &&
>   sudo systemctl start usb16x16-aes67
> Mac harness: work/latency-harness; per-impulse data in the result JSON
> under correlation.perImpulseDelaySamples, statistics under
> correlation.statistics. The supervisor reads USB16X16_AES67_CONF as an
> alternate conf path, which is how a staged conf is validated before
> install (source it with the main case stripped, then select_profile
> and validate_profile per name).
>
> RULES
> The USB module, usb-16x16.service and the setup script are immutable
> baselines; AES67 work must never disturb USB enumeration. Never run ptp4l
> beside the daemon. One variable at a time. Every figure is reconnaissance
> until it is loaded and repeated. Any bridge change re-pins the wrapper,
> the candidate installer and the supervisor.
