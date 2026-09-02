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
CoreAudio at 64 frames plus USB framing 3-4 ms. The bridge owns about 16 ms,
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

### The floor

Mac at 64 frames both ways, the Ferrofish, and the RAVENNA device's own
buffering total 10-11 ms before the bridge holds a frame. With all three
tiers done, this loop bottoms out around 14-16 ms. Below that is a 32-frame
CoreAudio buffer, a different receiver than the Ferrofish, or hardware
timestamping in the driver; none of it is Pi-side work, and the profile
mechanism above is how any of it ships if it ever does.

## Decisions to take before implementing

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

## Pickup prompt for the implementation session

Copy this into the new chat:

> Raspberry Pi 5 USB 16x16 / AES67 bridge, repo ~/Development/USB 16x16
> (github.com/squeaksquad/usb-16x16-aes67, main, clean). Read
> work/aes67-bridge/DEPLOYMENT_PLAN.md first, then PROJECT_HANDOFF.md from
> "ACCEPTED: the combined point" back through "MEASURED: the RAVENNA device
> skips one packet". The Phase 4 bridge is accepted at 29.1 ms with the skip
> covered; nothing is broken. The task is to build the persistent service the
> plan describes. Start by asking the six decisions in the plan in one batch.
> Rules that still apply: usb-16x16.service, the USB module and the setup
> script are immutable; never run ptp4l beside the daemon; installs need the
> user's password, so batch them and verify staged hashes first; never build
> or install on the Pi while a run is measuring; guard every scripted edit
> and chain the commit behind it; a pgrep -f for the bridge from inside an
> ssh command matches the ssh shell itself, anchor it like the wrapper does.
> Pi: ssh -o HostKeyAlias=audio-dev.local bdimaio@192.168.1.201; eth0 is
> AoIP, wlan0 is management. Installed bridge is 0254348c, wrapper 1baa88a9.
