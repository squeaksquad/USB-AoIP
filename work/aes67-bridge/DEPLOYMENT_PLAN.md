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
