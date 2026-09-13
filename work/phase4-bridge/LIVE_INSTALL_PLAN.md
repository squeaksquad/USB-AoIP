# Installing the live-coefficient set (2026-09-13)

The plan for turning the built-and-tested live coefficient design
(`LIVE_COEFFICIENTS_DESIGN.md`, steps 1-5, all Mac-tested) into the point of
record. One root install with a prepared rollback, then the standing battery
against the service, then the design's remaining tests. Nothing here has run
yet; every gate below is a stop.

## What changes on the Pi, and what does not

| Installed file | Now | After | Rollback copy |
|---|---|---|---|
| `/usr/local/libexec/usb16x16-rt-bridge` | 947e8b4d (accepted meter-tap bridge) | 7e8f1064 (live candidate, built 2026-09-13) | `live-install-20260913/rollback/` |
| `/usr/local/sbin/usb16x16-aes67-supervisor` | 23e40f8c | 94809853 (pins 7e8f1064, passes `--dsp-live-file` for blocks with `DSP_LIVE=1`) | same |
| `/usr/local/bin/usb16x16-web` | 172b7032 | df9490b8 (live/commit routes, `dspLive`, `dspShape`) | `rollback/web-control/` |
| `/usr/local/bin/usb16x16-apply` | c7f2a162 | abeaa869 (1.2.0: `live`, `commit`, `revert`, `DSP_LIVE=1` on user blocks) | same |

Untouched: `/etc/usb16x16/aes67.conf` (37fc790f; no block changes, the
applier adds user blocks later), the three systemd units, sudoers, the
offline runner 8469c2e8 (its loader is the same code; the applier only runs
`--bench 1`), the USB gadget, the daemon, the module. The accepted profile
`dsp-direct` has no `DSP_LIVE`, so the bridge starts on it exactly as today
with no control thread. All of it is staged under
`~/usb-16x16-work/live-install-20260913/` and `~/usb-16x16-work/web-control/`
with hashes verified from the Mac; `install-live-set.sh` (3dc0a459) refuses
any other hash and refuses while the service is active.

## Sequence

Every root command is one the operator runs in the ssh session. The Mac side
is read-only until step 5.

**0. Preconditions.** Playback stopped, RTL Utility closed, nothing holding
the USB device. Read the gap bar (`outputs/latency/phase6-gapbar-20260907/
read-bar.sh`) so the day's count is on record. `cat /run/usb16x16/stage`
says stable, `last-bridge` says 0/0 restarts.

**1. Install the bridge and supervisor** (audio stops here):

```bash
sudo systemctl stop usb16x16-aes67
```

```bash
cd ~/usb-16x16-work/live-install-20260913 && sudo ./install-live-set.sh install
```

The script prints before/after hashes and runs `supervisor profiles` on the
live conf. Gate: after = 7e8f1064 / 94809853, `profiles` exit 0.

**2. Install the web-control set** (no audio impact; the web service and the
Apply path unit restart):

```bash
cd ~/usb-16x16-work/web-control && sudo ./install-web-control.sh && sudo systemctl restart usb16x16-web.service && sudo systemctl restart usb16x16-apply.path
```

Gate: `systemctl is-active usb16x16-web usb16x16-apply.path` both active;
`curl -u … http://192.168.1.201:8088/api/health` carries `dspLive` with
`available: false` (dsp-direct has no live file) and `service.version` the
new one.

**3. Start on dsp-direct, the direct control (design acceptance test 1):**

```bash
sudo systemctl start usb16x16-aes67
```

Gate (Mac, read-only): STAGE running then stable, BRIDGE line fresh with
`dsp_live_gen=0`, zero RECOVERs through settle, `DSP loaded` absent (no
preset), no `DSPLIVE` line in the journal. The transport is argument for
argument the accepted one; if anything differs here, roll back (below)
before going further.

**4. The standing battery on dsp-direct** (Mac, opens audio; ~25 min):

```bash
python3 work/dsp-service/meter_battery.py --output outputs/dsp-service/live-direct-20260913 --execute
```

Gate: preflight, four 800-impulse runs and the 600 s soak pass with zero
RECOVERs and the queue floors in their accepted range (83 / 72 on 947e8b4d).
This is what makes 7e8f1064 the transport point of record; without it the
rest is not evidence.

**5. A user preset with a live file.** In the page (Settings), *Compile &
apply this draft* on the shipped 7.2.4 preset. The applier installs
`user-<slug>.dsp` in the fixed shape (302 sections), writes its block with
`DSP_LIVE=1`, restarts on it. Gate: receipt `done`; journal shows `DSPLIVE
enabled file=/run/usb16x16/dsp-live.dsp … shape=064ef631…`; health
`dspLive.state` = `idle`; the EQ editor's state line reads **Live**.

**6. Live edits (design test 3, audibility).** With signal playing to the
Ferrofish return (or the wire-listen decoder on eth0): drag a band gain,
move a crossover frequency, mute an output. Gate: each edit reaches
`applied` in health within about a second, the receipt is `done`, and the
change is heard (or seen on the return) with no click beyond the
coefficient step; `dsp_live_refused` stays 0; zero RECOVERs.

**7. Swap-under-load against the service** (the wrapper run, service
edition). A script pushes the live-toggle pair through `POST /api/apply/
live` every 2 s while `meter_battery.py --phases soak` runs on the user
preset (600 s). Gate: ~300 applied, zero refused, zero RECOVERs,
`dsp_us_max` unmoved from the direct arm.

**8. Restart semantics (design test 4).** With a preview running and not
committed:

```bash
sudo systemctl restart usb16x16-aes67
```

Gate: the bridge comes back on the installed file (`dsp_live_gen=0`,
`DSPLIVE ignored … predates start` if the old live file was still there,
else `idle`). Then push an edit, *Commit preview*, restart again: the
committed numbers come back (`DSP loaded` names the same file, the new
`DSP_SHA256` in the block, `dsp_live_gen=0`).

**9. Record.** Hashes, receipts, the battery output directory and the
journal lines into the handoff as ACCEPTED or not; move the artifact pin
(`artifacts/pi-aarch64/usb16x16-rt-bridge` becomes 7e8f1064, the accepted
947e8b4d kept beside it) only on ACCEPTED.

## Rollback, from any step

```bash
sudo systemctl stop usb16x16-aes67
```

```bash
cd ~/usb-16x16-work/live-install-20260913 && sudo ./install-live-set.sh rollback
```

```bash
cd ~/usb-16x16-work/live-install-20260913/rollback/web-control && sudo install -o root -g root -m 0755 usb16x16-web /usr/local/bin/usb16x16-web && sudo install -o root -g root -m 0755 usb16x16-apply /usr/local/bin/usb16x16-apply && sudo systemctl restart usb16x16-web.service usb16x16-apply.path
```

If a user block was written in step 5 and the live profile is that block,
switch back first (`sudo usb16x16-aes67-supervisor switch-profile
dsp-direct`, passwordless), or the rolled-back supervisor will refuse the
`DSP_LIVE` key it does not know. Then:

```bash
sudo systemctl start usb16x16-aes67
```

The conf copy in `rollback/aes67.conf` (37fc790f) is the pre-install file if
it must be restored by hand; the applier's `remove` kind takes a user block
out cleanly while the new set is still installed.

## What is decided by this and what is not

Passing steps 3-4 makes 7e8f1064 the transport point of record; passing 5-8
makes live coefficient updates an accepted feature on user presets. Nothing
makes a user preset itself accepted: the guards stand in for a soak, as
before. The `--shape` runner and the AoIP-only work are not touched.
