# Next-session pickup prompt

## Current pickup — 2026-10-12: the Dante service has DSP, an applier and a page; its owed list is done. Start here.

**Added 2026-10-12 03:45 UTC: the three fault paths were run direct; read
this before the CHOSEN block below.** Handoff tail (two FOUND, one
MEASURED) and the last three sections of `work/dante-mode/RESULTS.md`.
Controller restart: PASS, no cost. Mac sleep, three times: the service
rides through (silence and a new level each time), but the first wake left
four-sample zero runs on a 32-sample grid on the return for at least nine
minutes; not reproduced in two more sleeps, hop not located; RESULTS.md
says what to do on a recurrence before touching anything. eth0 down 20 s
(software, the cable is the PoE feed): **FAIL**, Statime exits, the owner
restarts with it, panics three times with no IPv4 address and the unit's
start limit leaves it `failed` until a manual start (fixed the same hour,
next paragraph). The service is `direct` with meters.
**Unit fix, installed 04:02 UTC:** `/etc/systemd/system/usb16x16-dante.service`
is now 27b68877 (`service/usb16x16-dante-dsp-linkwait.service`: after the
clock wait, wait without limit for eth0's carrier and address; rollback
`install-dante-unit-update.sh rollback` to 9f5289dd). On it the 20 s bounce
comes back unaided on one start, `NRestarts` 0, 9 s after the link returns,
level stepping 2 (498 on the 04:02:43 process). So Ethernet loss now
passes at the cost of an endpoint restart. Open, the operator's to choose:
the sleep episode (do the recurrence procedure if it shows); making Statime
survive a link loss so the owner is not restarted; a loss of minutes; a
real carrier loss; the three paths with a preset.
**INSTALLED 04:15 UTC and measured:** `service/90-usb16x16-eth0-carrier.conf`
(NetworkManager `ignore-carrier` for eth0; `install-eth0-carrier.sh
rollback` removes it). A real 23 s pull of the Pi's cable then rode
through: same owner and Statime processes, no resync, level 488 before and
after, silence for the pull plus 2 s. The Pi stays up on the Mac's USB
port with the PoE cable out (rail lowest 4.92 V, no undervoltage flag), so
real pulls are a usable test here. Statime is not patched (handoff, the
STAGED entry of 04:12, says why). Battery and loaded hour PASSED on it 04:30-05:47 UTC (509 /
`daw_timeline` 697, 14.521 ms; the band is now 465 to 509); ACCEPTED by
the operator 2026-10-12: this form is the Dante point of record. Next, in
another session by his choice: the owner's stalls.
**Since then (11:30-11:55 UTC):** the operator turned AES67 mode off on
the Ferrofish and rebooted it. The service rode through; the level read
605 afterwards and 507 after a gadget restart: the Dante clock moved while
the leader rebooted and two transmit re-primes left about 94 frames on the
USB side (RESULTS.md, last two sections). A leader reboot therefore wants
a fresh anchor afterwards. The AES67 rollback now also needs AES67 mode
back on and a Ferrofish reboot. Level 507 on the 11:50:22 anchor.

**INSTALLED 2026-10-13 01:31 UTC, newest: the low-latency set is in
service and passed the battery and a loaded hour on the installed form:
343, `daw_timeline` 531 (11.062 ms).** Handoff tail. Config a91f5766,
wrapper 882f48ac, `transport.conf` 821bc306, Ferrofish 1.0 msec, start
check installed. Awaiting the operator's ACCEPTED (ask; do not assume).
Owed with it: a boot on these files, a preset and the fault paths at
these settings. Then, his stated order: explore the issues, which are the
start-drawn loss of return packets (cause between the Ferrofish, the
GS305EP and the Pi's port; the start check is the stopgap) and the owner
stall (4.4 ms at 20:58 UTC on 2026-10-12). Rollback
`install-dante-lowlatency.sh rollback`.

**STAGED 2026-10-13 01:18 UTC, newest: both latency gains, measured and
ready.** Both Inferno knobs at 1 ms plus the return queue at 96 read 328,
`daw_timeline` 516 (10.750 ms) through a battery and a loaded hour on a
candidate start, about 3 ms under the service. Installer
`service/install-dante-lowlatency.sh` (2328c77e, on the Pi; three files,
one rollback), the operator's sudo. First check what is installed:
`sha256sum /etc/usb16x16/dante/asound-inferno-owner.conf
/usr/local/libexec/usb16x16-dante/usb16x16-dante-start` (924cfa99 +
1f83825b is the old pair, a91f5766 + 882f48ac the new) and `cat
/etc/usb16x16/dante/transport.conf`. If installed: owed the battery and a
loaded hour on the installed form, on a start the check has passed
(`state=ok` in the status file), then his ACCEPTED. RESULTS.md's last
section says what the figures rest on and what the lower queue gives up.

**INSTALLED 2026-10-12 23:01 UTC, newest: the start check is in service
and has acted once** (a short start at 23:03:45 restarted after 65 s, the
next read whole). Handoff tail. Before any measurement after an endpoint
start, wait for `state=ok` with the current InvocationID in
`/run/usb16x16-dante-startcheck/status`. Owed: a boot with it; the stop at
four restarts on the real unit; the operator's ACCEPTED. In service:
Ferrofish 1.0 msec, config 924cfa99 (2 ms), 494 / 682 on the 23:06:15
anchor. Still open underneath: the cause of the loss; the owner stall;
the return queue at 96; 1 ms on both knobs.

**STAGED 2026-10-12 22:00 UTC, newest.** A start check for the service
(`service/usb16x16-dante-startcheck`, its oneshot unit, and
`install-dante-startcheck.sh`, on the Pi, the operator's sudo): after each
endpoint start it reads eth0's received audio frame rate and restarts the
endpoint if a flow is losing packets, at most four times. Check whether it
is installed: `systemctl is-enabled usb16x16-dante-startcheck`. If it is,
owed: watch it act on a short start (`journalctl -u
usb16x16-dante-startcheck`, `/run/usb16x16-dante-startcheck/status`), and a
boot; and remember that an endpoint restart may now be followed about 65 s
later by another one, so wait for `state=ok` in the status file before
measuring. `usb16x16-dante-startcheck --dry-run` judges a start without
root. The operator keeps the Ferrofish at 1.0 msec; the switch is the
Netgear GS305EP.

**MEASURED 2026-10-12 21:40 UTC, newest; read with the block under it.**
The Ferrofish's device latency is now 1.0 msec (operator): it sends
16-frame packets, 3,000 a second a flow. The loss is unchanged in count
(about 807 packets a second on 3 starts of 9), so a bad start now has
16-sample holes. START CHECK, replaces the noise probe (which hears only
channel 2 and missed holes on channels 5 to 12): on the Pi, `ethtool -S
eth0 | grep rx_256_511_byte_frames` twice ten seconds apart must give
6,000 a second; about 800 short is a bad start, restart and re-check.
Cause still between the Ferrofish, the switch and the Pi's port: next is
a view of the wire that is not the Pi's (switch port counters or mirror;
a multicast flow captured on a second machine), or a start-check in the
service as a stopgap. In service: start 21:34:19 at full rate, soak PASS,
472 / 660.

**FOUND 2026-10-12 21:05 UTC. READ THIS FIRST.** The four-sample holes are
located: on a start with holes, one of the Ferrofish's two return flows
(8 channels, 4-frame packets, 12,000 a second) is missing the packet due
80 to 120 us after the Pi's own transmit burst, about half the time, and
those packets never reach the Pi's port (MAC counters clean). The Pi's
transmit is whole. RESULTS.md's last section; `diag/dante-pcap-zeros.py`
reads a capture (tcpdump needs the operator's sudo; the command pattern
is in that section's evidence and the tool's header). Proposed and
awaiting the operator: Ferrofish device latency 1 msec in Dante
Controller (AES67 mode stays off), then one capture to see the packet
size and ten starts with noise probes. If he has done it, check first
what the Ferrofish's packets look like now. Until the loss is gone: a
noise probe after every endpoint start, restart on holes. In service:
config 924cfa99 (2 ms), 488 on the 21:02:42 UTC anchor. Open besides: the
owner stall (4.4 ms at 20:58:49, during a capture's noise run); the
return queue at 96 (owed five anchors an arm); 1 ms on both knobs (388 /
576 on a clean start, worth retrying once starts are clean).

**FOUND 2026-10-12 17:00 UTC. READ THIS FIRST; it overrides the two blocks
under it where they differ.** The four-sample holes (about 5 % of
samples, one position modulo 32, Dante side of the owner, Ferrofish 0
late) are drawn by endpoint starts at 2 ms as well: 4 service starts of
12 on the point of record's config, against 3 of 7 at 1 ms. Not unequal
knobs, not 1 ms as such. First seen 12:40 UTC on 2026-10-12; before that
day dozens of probed starts had none. Untested suspects: the Ferrofish
out of AES67 mode since 11:29 UTC that day; some forty endpoint restarts
minutes apart. RESULTS.md's last section has the counts and four ways to
locate it (Pi self-subscribed in Controller; Ferrofish back in AES67
mode; eth0 capture; spaced starts). RULE: a noise probe after every
endpoint start before reading anything; on holes, restart and probe
again. After about twenty endpoint restarts the Mac's input goes silent
(harness: no return, `rawInputPeak` 0.0, while the owner's `back_peak`
shows signal); a gadget restart fixes it. In service at 17:00 UTC: config
924cfa99 (2 ms), start 16:51:32, probe clean.
Also done that afternoon: a queue-depth sweep (RESULTS.md, the section
before last). `--rx-queue` 96 was clean on one start (return floor 44),
expected gain 48 samples, not yet shown: owed five anchors an arm, then
battery and hour. `--tx-lead` below 128 made 2 ms holes; leave it.

**FOUND 2026-10-12 15:20 UTC, read before the DONE block: 1 ms is NOT fit
for service.** Installed at 1 ms / 1 ms the service had four-sample holes
(5.7 % of samples, one position modulo 32, Ferrofish 0 late) on two starts
of five; with the candidates, three starts of seven. It is a draw at each
endpoint start, not unequal knobs: that reading in the DONE block is
retracted. RESULTS.md's last section. First thing: `sha256sum
/etc/usb16x16/dante/asound-inferno-owner.conf` (a91f5766 is 1 ms and
means the rollback has not been run: `sudo ./install-dante-latency.sh
rollback`, his; 924cfa99 is the point of record) and a noise probe on
whatever start is running. A noise probe after EVERY endpoint start from
now on. Next if 1 ms is wanted: locate the phase (eth0 capture on a start
with holes and one without; `flows_tx.rs`, how the first timestamp is
chosen). `TX_LATENCY_NS` alone at 1 ms (about 40 samples) was clean on
one start only. The 02:02 UTC sleep episode has the same signature.

**DONE 2026-10-12 12:00-14:56 UTC: the 1 ms experiment below was run; its
result is STAGED, not installed. Read this before the CHOSEN block.**
RESULTS.md's last section and the handoff's last two entries. Both knobs
at 1 ms (`config/asound-inferno-owner-both1ms.conf`, a91f5766) passed five
anchors (374 to 392), the battery and a loaded hour on a candidate start:
388, `daw_timeline` 576 (12.000 ms), about 100 samples under the day's
control (470 to 511). `TX_LATENCY_NS` alone at 1 ms was clean (438 to
463). `RX_LATENCY_NS` alone at 1 ms FAILED with four-sample holes on 5 %
of samples while the Ferrofish reported 0 late: keep the two equal, always;
why is not read. Staged: `service/install-dante-latency.sh` (b4d984be, on
the Pi), the operator's sudo, then `systemctl restart usb16x16-dante` and
a gadget restart. Check first whether it is installed (`sha256sum
/etc/usb16x16/dante/asound-inferno-owner.conf`: 924cfa99 is 2 ms,
a91f5766 is 1 ms). Owed after install: noise + 4 x 800 + 3,600 s on the
installed form, then his ACCEPTED; the Ferrofish's Peak and Late over the
candidate's hour (his read, asked for); a preset and the fault paths at
1 ms (a 4.6 ms owner stall is five windows late there); the mechanism of
the unequal-knob holes. The service runs the accepted 2 ms form, 474 on
the 14:54:02 UTC anchor. Rule from the day: after many gadget restarts
the Mac can stop listing the device; one more gadget restart restored it.
The anchor script used is not in the repo: per anchor, gadget restart,
30 s, `measure-candidate.sh noise 32`, `USB16X16_OTHER_LOAD=0.1
measure-candidate.sh 32 400`.

**CHOSEN 2026-10-12 for the next session: Inferno latency at 1 ms.**
Before-reads first (`journalctl -u usb16x16-dante -n 3`, `NRestarts`, the
neighbour entry, a noise probe for the level: 507 on the 11:50:22 UTC
anchor unless something has re-primed since; the stalls move it by 2).
The Ferrofish's own device latency reads 0.25 msec and it applies 2 msec
to the Pi's flows because that is what the Pi advertises; its Latency tab
for those flows read peak 583 us, average 550 us on 2026-10-12 with AES67
mode off. Both `RX_LATENCY_NS` and `TX_LATENCY_NS` are 2,000,000
in `/etc/usb16x16/dante/asound-inferno-owner.conf` (repo
`work/dante-mode/config/asound-inferno-owner.conf`); 2 ms is the only
value below the 10 ms default ever run, nothing at 1 ms is in the record.
Each is a receive latency for one direction and the two knobs are crossed
in this Inferno revision (RESULTS.md, "Latency settings as wired"): after
each change check which direction moved (Controller shows the Ferrofish's
figure for the Pi's flows as "USB-16x16-Inferno @ N msec"). Expected gain
about 48 samples per direction, 96 (2 ms) for both. The risk is the Pi to
Ferrofish direction: a packet later than the setting is dropped silently
(holes, not a latency change), and the Ferrofish's Latency tab has shown
the Pi's packets peaking at 708 us (2026-10-12) with a cluster near 0.9 ms
on an earlier night, so 0.1 to 0.3 ms of margin at 1 ms. How: one
direction at a time, the Pi's receive side first; a copy of the config
with one value changed, run through `usb16x16-dante-candidate start
<binary> CONFIG=...` with the service stopped, nothing installed; judge by
the noise probe, a soak and the Ferrofish's Late count read by the
operator, then the battery and an hour before anything is proposed. Any
level comparison needs the same kind of anchor on both arms (a gadget
restart under the running process), since a candidate start is itself a
new draw; the expected gain per direction (48) is about the size of the
draw band (465 to 509), so read several anchors per arm or compare within
one process if the setting can be changed without a re-prime (it cannot
through the config file: it is read at open). Check
first whether the Ferrofish accepts 1 ms at all for these flows. A five-minute pull also rode through (11:10 UTC, 511 before
and after). FOUND the same night: an unexplained 4.6 ms owner stall at
idle at 06:26:05 UTC, a 91-frame resync, level 509 to 511 (RESULTS.md,
last section): the loop-gap item, now also away from a start. Untested: a
pull during audio, the fault paths with a preset, the sleep episode's
cause.

## Current pickup — 2026-10-09: Dante (Inferno) is the development line; the alsaloop prototype reads level with AES67

Read the handoff's last two entries (`DONE 2026-10-08 / 09` and `DECIDED
2026-10-09`), then `work/dante-mode/RESULTS.md` from "Stage 2 gates after the
first night" to its end, then `work/dante-mode/PLAN.md` stage 3a. The sections
below this one describe the AES67 service; they are the rollback, not the
work.

**Do not be misled by the Pi's state.** `usb16x16-aes67.service` is stopped on
purpose and stays stopped. It is still enabled, so if the Pi has rebooted it
will be running against routing that no longer feeds it: a silent return and
host-absent cycling there are expected, not a fault to chase. Check uptime
first. The operator has given standing permission for `sudo systemctl start`
and `stop` of that one unit; every other root command on the Pi still needs
his go, and Statime and the prototype are root processes he starts in his own
terminals.

**What exists.** On the Pi under `~/usb-16x16-work/dante-mode/`: the Statime
fork and the Inferno ALSA plugin, built; the probe; the prototype wrapper;
configs. In the repo under `work/dante-mode/`: the same scripts,
`measure-candidate.sh` for the Mac harness (impulse runs, `noise`, `soak`),
`SOURCES.lock`, `RESULTS.md`, `PLAN.md`. Nothing is a service and nothing
starts at boot.

**How to bring the Dante path up** (the operator runs the two sudo lines):

1. `sudo systemctl stop usb16x16-aes67` if it is active. Never with Statime
   already running: they use the same PTP ports.
2. Terminal 1: `sudo ~/usb-16x16-work/dante-mode/statime/target/release/statime -c ~/usb-16x16-work/dante-mode/config/statime-first-run.toml`.
   Its repeating `got DelayReq, master operation not implemented` warning is
   noise.
3. Terminal 2: `sudo SYNC=pitch ~/usb-16x16-work/dante-mode/run-alsaloop-prototype.sh 3600 5000 2000000`
   (seconds, `alsaloop` microseconds per direction, Inferno latency in ns).
4. In Dante Controller the device is `USB-16x16-Inferno`. If the Pi's receive
   cells stay orange, reload device information before concluding anything.
5. If `USB 16x16` is missing from the Mac's audio devices although USB shows
   it, `sudo killall coreaudiod` on the Mac.

**Figures to hold on to** (all from one night, prototype, conditions in
RESULTS.md): RTL at 32 frames 884 samples, 18.417 ms; harness 705 samples,
four loaded 800-impulse runs, spread 0; 600 s sixteen-channel soak PASS; noise
probe clean. AES67 record for scale: 703 / 891 (18.563 ms). Bit transparency
of the Inferno endpoint itself passed over 30 minutes with
`TX_SOURCE_BIT_DEPTH=24`. An xrun with audio flowing costs about 5.7 s.

**Rules the night produced.**

- One process per Inferno device: stop the prototype before running the probe
  and the reverse.
- Never design a recovery that re-prepares the Inferno PCM; it is a
  six-second dropout.
- The harness and RTL Utility never share the device; ask for RTL to be
  closed before `measure-candidate.sh`.
- `dns-sd` browsing from the Mac is not a stand-in for what Controller sees.
- Background measurement commands piped through `grep` show nothing until
  they end; do not read silence as a hang.
- A `sudo` over ssh from Claude Code was blocked once by the permission layer
  and passed later; if it is blocked, hand him the command.

**Added 2026-10-09 ~14:45 UTC (second session, no audio run).** Item 3 below
now has its design, `work/dante-mode/OWNER_DESIGN.md`: read it whole before
touching the owner, and RESULTS.md's last section for what it rests on. Two
readings changed the picture: an ioplug only xruns when the plugin's pointer
says so, and the transmit thread sends whatever the mmap buffer holds, so a
late write is an echo of the previous lap, not zeros. Steps 1 to 3 of
the design PASSED the same day (17:58-18:08 UTC, RESULTS.md's last three
sections): the free-run resync on the stock and the patched plugin (a 100 ms
stall cost about 21 ms beyond itself against 5.7 s), and the stale-lap
reading confirmed with the zero-behind rule as its fix. The operator accepted
the patch and running as root by hand. On the Pi: probe 381f348c
(`--free-run`, `--hold-forward`, `--zero-behind`), patched plugin 55dee5d8 in
`plugins/xrun-option/` (select with `INFERNO_PLUGIN_DIR` and
`INFERNO_CONFIG=.../config/asound-inferno-freerun.conf`), stock ca99efd7
still in `inferno/target/release`. Steps 4 passed (an hour as root, zero resyncs) and the USB half is written and
has run once as root: owner 48d51783 on the Pi, `sudo
~/usb-16x16-work/dante-mode/run-owner.sh [SECONDS] --log-every 1` (`NO_USB=1`
for the network half alone), RTL 14.646 ms at 32 by the operator on its first
start (one reading, servo still settling). Read RESULTS.md's last three
sections and the "Changes made while building the USB half" block at the top
of OWNER_DESIGN.md. **Done 21:13-21:39 UTC on one start with `--seed-ppm -15`: noise probe clean, 4 x 800 loaded impulses all 516 samples (10.750 ms) spread 0, 600 s soak PASS; the return-queue reading is an artefact, not delay.** Still owed from the list that follows: RTL on a battery start, (c) and (d), bit transparency through the owner, the extended hour, and taking the artefact out of the return servo's input. The list as written before the battery: (a) `measure-candidate.sh noise 32`
then `measure-candidate.sh 32 800` against a running owner, RTL closed: spread
0 or impulses 37 apart settles the return-queue question; (b) start with
`--seed-ppm -15` (the Mac read 15.3 ppm slow) and check both depths start and
stay at 128 / 144; (c) the open/close, DAW quit and `usb-16x16.service`
restart checks of step 5, none of which has been exercised: the Mac held both
streams for the whole first run; (d) three starts, harness and RTL on each.
The resync must
forward a margin past the deficit (the clock moved 4 to 5 frames in between).

**Added 2026-10-10 15:16 UTC.** The Mac is healthy after the reboot (noise
probe clean) and a third fresh anchor is in: owner d4ebd576 started after the
reboot reads harness 482, RTL 670 (13.958 ms) at 32, plus 188 exactly. Fresh
anchors are 507 / 489 / 482 harness, 695 / 677 / 670 RTL, span 25, mean 493 /
681 (14.18 ms); quote the three, not one. The first two items of the owed
list below are done, except that the `usb-16x16.service` restart under a
running owner (the untested fault path) was not the way this anchor was
drawn and is still owed, as is the battery on one fresh anchor. The
`error_lines` in `measure-candidate.sh` output are Inferno refusing unknown
control opcodes, not faults. Bring-up after a Mac reboot is only Statime and
`run-owner.sh` on the Pi.

**ACCEPTED 2026-10-11 09:15 UTC: the installed services are the Dante point
of record (465 / `daw_timeline` 653, 13.604 ms; band 465 to 507). Start
here.** Both services are running and enabled at boot. The next work is DSP
for the Dante owner (`work/phase4-bridge/DSP_MODE_DESIGN.md` and
`LIVE_COEFFICIENTS_DESIGN.md` describe the stage in the AES67 bridge;
`OWNER_DESIGN.md` says where it would sit in the owner, which today copies
integers and has no float stage). Before relying on the candidate launcher:
check which copy is on the Pi (`sha256sum /usr/local/sbin/usb16x16-dante-candidate`): 8afe885c and earlier cannot start an owner (the last of three faults: `/run` is noexec); if it is not e20b9874 ask the operator to run
`sudo ~/usb-16x16-work/dante-mode/service/install-dante-candidate-launcher.sh`, then try it once with the accepted binary as in the
09:05 block below. Rules that this day produced: an acceptance needs a
3,600 s soak; check `ip -s neigh` stays REACHABLE for any Dante receiver;
the Mac cannot send true full scale; `daw_timeline` is the accepted RTL
figure; the session cannot reboot the Pi or add sudo rules by itself.

**Added 2026-10-11 09:05 UTC.** The installed services passed everything
owed on them: a reboot coming up on Dante unaided, then on a fresh anchor
noise + 4 x 800 (465 / `daw_timeline` 653, 13.604 ms) + a 3,600 s soak PASS.
Awaiting only the operator's ACCEPTED for the installed form. Fresh draws
now span 465 to 507. The candidate launcher on the Pi is the buggy 252c07d8
(refuses every start); the fixed 8b4b5d92 is staged in
`~/usb-16x16-work/dante-mode/service/` for his `sudo
./install-dante-candidate-launcher.sh`, then try it: stop the service,
`sudo -n /usr/local/sbin/usb16x16-dante-candidate start
/home/bdimaio/usb-16x16-work/dante-mode/owner/usb16x16-dante-owner
--log-every 1`, check it runs as `usb16x16-dante` with FIFO threads, `...
stop`, start the service. This supersedes the "owed" list of the block
below.

**INSTALLED 2026-10-11 07:45 UTC. Read this first.** ACCEPTED by the
operator the same morning: owner 22fd2622 on plugin 0ee61f2f is the Dante
point of record, 472 / `daw_timeline` 660 (13.750 ms) at 32 frames, with a
loaded hour behind it. It now runs as two services on the Pi, enabled at
boot: `usb16x16-statime.service` and `usb16x16-dante.service` (user
`usb16x16-dante` with two capabilities; `work/dante-mode/service/`). Operate
with `sudo -n /usr/bin/systemctl start|stop|restart usb16x16-dante` (and
`usb16x16-statime`); fresh anchor: `sudo -n /usr/bin/systemctl restart
usb-16x16.service`; logs: `journalctl -u usb16x16-dante`. The old
`run-owner.sh` sudo rule is gone. Owed on the installed form: a reboot test
(operator's), then noise + 4 x 800 + 3,600 s soak on a fresh anchor, then
his ACCEPTED. Candidate builds: once the operator has run
`install-dante-candidate-launcher.sh`, stop the service and use `sudo -n
/usr/local/sbin/usb16x16-dante-candidate start <binary under
dante-mode/owner/> [PLUGIN_DIR=...] [CONFIG=...] [options]`, `... stop`,
then start the service again. Next work: DSP for the Dante owner; the web
page still reads the AES67 service's state. Open: the early-start loop gap.

**Added 2026-10-11 06:15 UTC. Read this first.** Fixed, as far as two hours
show. Owner 22fd2622 on plugin 0ee61f2f (patch 0003), unpinned, passed the
battery and a 3,600 s loaded soak on one fresh anchor: 472 / `daw_timeline`
660 (13.750 ms), soak PASS; an hour on the diagnostic owner before it also
clean. Awaiting the operator: ACCEPTED for 22fd2622 + 0ee61f2f, and making
`plugins/xrun-option-retry1-confirm` the `run-owner.sh` default (today it
still defaults to 5c6b1c0a, which has the ARP fault, so start the owner with
`INFERNO_PLUGIN_DIR=/home/bdimaio/usb-16x16-work/dante-mode/plugins/xrun-option-retry1-confirm`).
IRQ pinning is removed. Open: the early-start stall (a loop gap of some ms
in the first 30 s of some starts); persistence.

**Added 2026-10-11 03:55 UTC. Read this first; it supersedes the 02:50
block's suspect.** The holes are ARP, not the Ethernet controller: the
Ferrofish ignores the Pi's unicast ARP probes, the neighbour entry failed
every 8 s and each re-resolution queued all flows' packets (now and then
for 5-10 ms). Shown by `eth-tx-watch.py` (zero bytes in flight during a
hole) and `ip -s neigh show 169.254.248.189 dev eth0` (DELAY/PROBE cycle).
Fix: `patches/0003` (MSG_CONFIRM after each keepalive), plugin 0ee61f2f in
`plugins/xrun-option-retry1-confirm/`; the entry now stays REACHABLE. A
loaded hour on it started 03:54:38 UTC on the diagnostic owner (pinned,
`OWNER_CPUS=2,3`, IRQs on CPU 1). To do: read that hour; a second hour;
then accepted owner 22fd2622 + 0ee61f2f unpinned: battery and loaded hour;
make it the `run-owner.sh` default only after that; undo the IRQ pinning
(`sudo -n /usr/local/sbin/usb16x16-stall-tuning irqs unpin`) unless needed.
Check the neighbour state first whenever a Dante receiver changes.

**Added 2026-10-11 02:50 UTC. Read this first.** Pinning (IRQs to CPU 1,
owner to CPUs 2-3) did not stop the holes: one in its hour. The suspect is
now the Pi 5's Ethernet controller: a known RP1 MACB transmit stall (missed
TSTART), one `TX stall detected ... re-kicking TSTART` in this boot's kernel
log, upstream patch thread June 2026. `work/dante-mode/diag/eth-tx-watch.py`
watches eth0's in-flight bytes and tx counter at 2 kHz without root; run it
on CPU 0 beside a soak and match its EVENT lines to the owner's `back_holes`
times. State on the Pi: IRQ pinning in place (`sudo -n
/usr/local/sbin/usb16x16-stall-tuning irqs unpin` reverts), diagnostic owner
0d13ee3c with `OWNER_CPUS=2,3` on plugin 5c6b1c0a.

**Added 2026-10-11 01:40 UTC. Read this first.** A hole is a burst of the
Pi's transmit packets reaching the Ferrofish up to 10 ms late (Dante
Controller, Ferrofish Latency tab: peak 10.1 ms, Late 52 = 13 packets x 4
flows for one hole; the other direction 0 late). Plugin 55dee5d8 has it too
(one hole in its hour), so the retry patch is cleared. Inferno's TX thread
reports no lag and the clock did not move: the delay is after `send` (Pi
kernel TX path, NIC, or switch). Unmeasured hypothesis: eth0's IRQ lives on
CPU 0 with ordinary-priority softirq work while FIFO 79-81 threads float.
Next: eth0 capture across a hole (root), or a per-core starvation monitor,
then try pinning (IRQ and threads) as the fix, an hour each.

**Added 2026-10-11 00:35 UTC. Read this first.** The holes are located to
the Dante side: diagnostic owner 0d13ee3c (`OWNER_BIN=usb16x16-dante-owner-diag`,
prints `out_holes=N/max back_holes=N/max`) counted none on the stream from
the Mac and both of an hour's two holes on the stream back from Inferno.
Mac, USB and the owner's copy are cleared. Left: Inferno TX, network to the
Ferrofish, Ferrofish + Metric Halo loop, network back, Inferno RX. Inferno
logs nothing when it happens. To separate next, one variable at a time, an
hour each: plugin 55dee5d8; the Ferrofish looping without the Metric Halo
(operator's routing); and read the Ferrofish's late-packet counts in Dante
Controller. The diagnostic owner is what is running on the Pi.

**Added 2026-10-10 23:30 UTC. Read this first.** The loaded hour FAILED: two
holes of 224 and 352 zeros on all sixteen channels in 3,600 s, nothing on
the Pi. Two more of the same in the bit-exact runs (the 22:15 block's
"checker's allocation" attribution is withdrawn). Four in about 100 minutes,
each a multiple of 32 samples, not located: Mac output, or consecutive Dante
packets lost or late in one direction. All on plugin 5c6b1c0a, with too
little all-channel time on 55dee5d8 to compare. Ten-minute soaks cannot see
this. First job: a diagnostic owner build counting all-channel zero runs on
the gadget stream and the Dante stream, then a soak until a hole occurs;
then an hour on 55dee5d8 if the hole is on the Dante side.

**Added 2026-10-10 22:15 UTC.** Bit transparency through the owner: PASS for
every code a Mac can send (`usb16x16-latency bitexact --seconds 600`, 460.8 M
samples, 16 channels). FOUND on the way: macOS multiplies by 0.999998 on
output and again on input for this device, so nothing from a CoreAudio float
client is bit-exact and codes beyond +/-8388590 cannot be sent; the returned
0.25 impulse has read 0.24999902 since 2026-09-03 for this reason. The
`bitexact` signal is full-scale noise on all sixteen outputs: have the
monitors muted. Owed: the loaded hour, persistence.

**Added 2026-10-10 20:31 UTC.** Plugin 5c6b1c0a is in service (operator's
decision) and passed the full battery on a fresh anchor: 473 / `daw_timeline`
661 (13.771 ms), soak PASS. `run-owner.sh` defaults to it now. Running on the
Pi: 22fd2622 on 5c6b1c0a from 20:04:22 UTC, detached. ACCEPTED by the operator:
that pair is the point of record. Owed: bit transparency through the owner, the
loaded hour, persistence. This supersedes the 19:58 block.

**Added 2026-10-10 19:58 UTC.** Plugin 5c6b1c0a as root: sixteen receive
channels in 28 to 31 s against 69 s, no resync. Not in service: no audio
measurement on it yet; select it with `run-owner.sh 0
INFERNO_PLUGIN_DIR=.../plugins/xrun-option-retry1 --log-every 1` (the script
now takes NAME=value arguments). In service: 22fd2622 on 55dee5d8 from
19:53:25 UTC, level 492 / 680 on that start. Owed: decide on 5c6b1c0a and
battery it; bit transparency through the owner; the loaded hour;
persistence.

**Added 2026-10-10 19:40 UTC.** 22fd2622 passed the full battery on a fresh
anchor (gadget restart): harness 506, `daw_timeline` 694 (14.458 ms), soak
PASS; four clean starts since its one 6 ms stall. ACCEPTED by the operator
the same evening: 22fd2622 is the point of record, d4ebd576 the fallback. Fresh draws span 470 to 507: quote the band. The session can now
run the Pi side alone: `/etc/sudoers.d/usb16x16-dante` allows, without a
password, exactly `sudo -n /home/bdimaio/usb-16x16-work/dante-mode/run-owner.sh
...`, the Statime binary, `sudo -n /usr/bin/pkill -INT -x usb16x16-dante-`,
`/usr/bin/pkill -INT -x statime` and `/usr/bin/systemctl restart
usb-16x16.service` (full paths, as written). Start the owner detached with
`setsid -f sudo -n .../run-owner.sh 0 --log-every 1 </dev/null
>/dev/shm/run-owner-ssh.log 2>&1`. Owed: plugin 5c6b1c0a as root, bit
transparency, the loaded hour, persistence.

**Added 2026-10-10 18:56 UTC.** The harness prints the RTL figure itself:
`measure-candidate.sh 32 N` ends with `daw_timeline=<ms> (<samples>) = <lag>
+ io_offset 188 (steady)`. The 188 (252 at 64) is the IOProc's output minus
input buffer sample time, now measured every callback. Checked against RTL
Utility on one start: 654 / 654 at 32, 718 / 718 at 64. DECIDED by the operator the
same day: `daw_timeline` with a steady offset counts for an acceptance. RTL Utility was
quit afterwards.

**Added 2026-10-10 17:30 UTC.** RTL readings can be taken from the session:
RTL Utility logs every measurement to `~/Library/Logs/RTL Utility/RTL Utility
measurements log.txt`. Set Input USB 16x16 FIRST, then Output, then buffer 32
(needs screen control), check the application log says both sides `Opened:
USB 16x16`, press Measure RTL, run `work/latency-harness/read-rtl-log.sh 1
<harness>`. First such reading: 654 (13.625 ms) on harness 466. The operator
decides whether these count for acceptance. Standing permission now covers
owner, services, Statime and installs on the Pi.

**Added 2026-10-10 17:18 UTC.** Owner 22fd2622 (source e53c8407) is the
binary on the Pi: the host stop goes idle at once and tops up with silence,
no resync (checked by a cable pull). Not accepted; d4ebd576 is kept beside
it and is still the point of record (`OWNER_BIN=usb16x16-dante-owner-d4ebd576`).
Its first start had an unexplained 6.0 ms loop gap at 4.2 s and a 3.7 ms gap
at the cable replug; its second start had neither. Levels: 470 after the
replug, 466 after an owner restart (a step of 4; the restart on the reboot's
young anchor did not step). The operator now allows owner and service
starts, stops and restarts without asking; an owner started over ssh is
detached, stop it with `sudo pkill -INT -x usb16x16-dante-`. Owed, in order:
a few more starts of 22fd2622 watching the first ten seconds, then a fresh
anchor (`usb-16x16.service` restart) and its battery with RTL; plugin
5c6b1c0a as root; bit transparency; the loaded hour; persistence.

**Added 2026-10-10 16:50 UTC.** `sudo systemctl restart usb-16x16.service`
under the running owner: gadget gone and back, audio in 1.8 s, no Inferno
prepare, the Mac resumed without a coreaudiod kill. New draw 476 harness, 664
RTL (13.833 ms). Fresh draws on d4ebd576: 507 / 489 / 482 / 476, span 31;
the accepted record stays 482 / 670. Draw fresh anchors this way, not by
killing coreaudiod. Owed, in order: top up with silence when the host stops
(owner change); why a stop/start cost frames on aged anchors (it did not on
a young one today); plugin 5c6b1c0a as root; bit transparency through the
owner; the loaded hour; persistence.

**ACCEPTED 2026-10-10 (after the 16:15 block below).** The operator read RTL
13.958 ms (670) on the battery's start and accepted it: the Dante point of
record is owner d4ebd576, plugin 55dee5d8, lead 128 / queue 144 / Inferno
2 ms, **harness 482, RTL 670 (13.958 ms) at 32 frames**, 221 samples under
the AES67 record. Owed: the `usb-16x16.service` restart under the running
owner; bit transparency through the owner; the loaded hour; persistence.

**Added 2026-10-10 16:15 UTC.** The battery passed on one owner start
(d4ebd576, 15:49:01 UTC, `run-owner.sh 0`): noise clean, 4 x 800 loaded at
482 spread 0, 600 s soak PASS. That start was an owner restart on the
reboot's anchor and read 482 like the start before it: no step at the
restart this time. Not marked ACCEPTED, the operator's call. Owed: his
decision; the `usb-16x16.service` restart under the running owner; bit
transparency; the loaded hour. This supersedes the 15:47 block's last
sentence.

**Added 2026-10-10 15:47 UTC.** Four loaded 800-impulse runs on the 482
anchor all read 482, spread 0 (3,200 impulses over 53 minutes of one owner
start). The soak was not run: the owner's 3,600 s timer ran out. Start the
owner with `run-owner.sh 0 --log-every 1` when a battery is intended, draw
the fresh anchor (`sudo systemctl restart usb-16x16.service` under the
running owner, which is also the untested fault path), then noise probe,
four loaded runs and `measure-candidate.sh soak` on that one start.

**State 2026-10-10 14:40 UTC (the Mac was rebooted here; this supersedes the
23:30 block below it).** Owner d4ebd576 on the Pi (`run-owner.sh`; older
builds kept beside it, `OWNER_BIN=`). Read RESULTS.md from "the harness finds
no return on most opens" to the end. What is established: (1) the level is a
frame count fixed when a direction is primed; the pitch servos only move
frames between the Pi's queues and the Mac's driver, so depths can move 15
frames with the level unchanged. (2) Fresh anchors (coreaudiod restart with
the owner running) at lead 128 / queue 144 / Inferno 2 ms, 32 frames: harness
507 and 489, RTL 695 (14.479 ms) and 677 (14.104 ms), each harness + 188;
AES67 record 703 / 891. Two anchors, 18 apart: a third is owed before a
figure is quoted. (3) The fault path works: host stop and return with no
Inferno prepare, no flow loss, return queue held at 144 while idle. (4)
Yesterday's aged-anchor figures (516 down to 412) and "3.9 ms" are withdrawn.
(5) After twenty-odd owner starts the Mac sent silence on most opens; after
four coreaudiod restarts in an hour CoreAudio stopped listing the device and
the operator rebooted the Mac. Do not draw anchors by killing coreaudiod
repeatedly. **Owed, in order:** confirm the Mac is healthy after the reboot
(noise probe); a third fresh anchor by `sudo systemctl restart
usb-16x16.service` with the owner running (also the untested fault path);
top up with silence instead of 98 resyncs in the 100 ms after the host stops;
find why each owner stop/start costs the Mac's input a few frames against its
output (read u_audio's behaviour at PCM close/open); plugin 5c6b1c0a (retry
after 1 s) under root; bit transparency; the loaded hour.

**State 2026-10-09 23:30 UTC, read this before the lists above it.** Owner
f013b1fd on the Pi (live gadget pointer, depth filter, ppm state file;
`OWNER_BIN=` on `run-owner.sh` picks an older build kept beside it). The
harness level steps DOWN 3 to 9 samples at every owner start (516 to 412 over
seventeen starts on one evening), spread 0 inside a start, cause not known:
RESULTS.md's last section. Every Dante level read so far is on an aged
anchor, so no comparison with the AES67 record is valid yet. First job: three
root starts with `measure-candidate.sh 32 400` on each; then a fresh anchor
(`sudo systemctl restart usb-16x16.service`, the operator's) and three more.
Also waiting: build `patches/0002` (`build-patched.sh xrun-option-retry1 0001
0002`) and re-time the subscriptions; the fault-path checks; bit transparency.

**Owed, in order.**

1. Per-start level: harness and RTL on the same start, three starts.
2. PLAN stage 3a step 1: the subscription-resolution baseline with the probe
   at `RUST_LOG=debug`, three cold starts, and what Controller shows unprompted.
3. The endpoint owner process (design first): long-lived, never re-prepares,
   clears its capture buffer, calls the poll revents function, detects capture
   overruns itself, carries the bridge's pitch servo, opens Inferno before USB.
4. Bit transparency from the Mac through that owner.
5. PTP lock evidence, timesyncd on and off, hardware timestamps separately.
6. Persistence: Controller restart, Ethernet reconnect, cold boot, Mac sleep.
7. Decide what the Pi does at boot: the AES67 unit is enabled and the Dante
   stack is hand-started.

## Earlier pickup (AES67 service, now the rollback) — 2026-09-15: user-immersive-one-sub (7.1.4) live from the page; shutdown set installed, its press owed

Read the handoff from `ACCEPTED 2026-09-14` to the tail (the fan curve, the
STAGED shutdown entry and its CORRECTION, the 01:46 UTC install and the page
rework). The 2026-09-14 pickup below still holds for the live-coefficient
mechanism and its rules; this section is what changed on top of it.

**In service.** Unchanged bridge 7e8f1064 and supervisor 8b42e4ec. Web set
now `usb16x16-apply` e6e7e844 (1.3.0, sixth request kind `shutdown`) and
`usb16x16-web` 207ff5cb (health reports 1.4.0; the middle-dot store name
fix is in it, so the reinstall the old item 3 asked for is done). Page files
in `~/usb-16x16-work/web-ui/`: app.mjs 0f16dfb5, style.css b1578d6b,
backend.mjs e6f590ee, live.mjs c6d2287a. The live profile is
`user-immersive-one-sub`, a 7.1.4 fixed-shape user preset (shape 2b31e8d3,
302 biquads, `DSP_LIVE=1`), installed from the page at 01:46:40Z in nine
clean steps; `user-immersive-stereo-subs` (7.2.4, shape 064ef631) is
installed beside it and is one row-Switch away. The compiler warned that the
7.1.4 draft's output 4 (LFE) can reach +3.6 dBFS from coherent full-scale
inputs; the operator accepted it, nothing has been trimmed.

**What the page does now.** The bus card's button is "Apply format to
draft": a bus format is a shape change, it edits only the draft, and the
toast and the panel note name Compile & apply as the step that reaches the
Pi (the 7.2.4 to 7.1.4 change had looked as if it did not take for exactly
that reason; the receipts directory showed nothing had been sent). Compile &
apply asks for the preset name first, prefilled with the draft name; the
answer becomes the draft name and the `user-<slug>`. The Service profile
panel leads with a Running now card, then the user presets as rows with
their own Switch and Remove and this draft as the last row beside Compile &
apply; the accepted profiles sit behind a disclosure, the servo-aligned
lineage in one select with the prefix trimmed. Every switch still goes
through `applyProfile` and its confirm. A Power box on the System overview
posts `/api/apply/shutdown` (confirm word required).

**Owed, in this order.**

1. The real Shut down press, playback stopped: then, after PoE brings the
   Pi back, the receipt under `~/usb-16x16-work/web-apply/receipts/` (kind
   `shutdown`, steps validating / stopping / powering-off, state done) and
   the journal order (AES67 stop before poweroff). The same boot also
   settles whether the 2026-09-14 fan-curve entry's pending reboot has
   happened.
2. The edit tally on the reworked page: `POST /api/apply/live` 202 vs 409
   in the web journal against `DSPLIVE applied` in the bridge journal, on
   the 7.1.4 preset. Bar unchanged: every edit applied within a second.
3. `dsp_us_max` over a quiet hour (item 1 of the 2026-09-14 list, still
   unread).
4. The criterion-aware soak on a preset arm (item 2 of that list). The
   7.1.4 preset routes 12 of 16 outputs, so the legacy activity gate still
   fails on it; thread `--signal-criterion reference-events-v1` through the
   battery or soak on a preset that routes all 16.
5. If the LFE warning matters in practice: lower the sub sends or the LFE
   gain on the draft and Compile & apply again (same name replaces).

**Rules learned on 2026-09-14/15.** When a page action "does not take",
read `~/usb-16x16-work/web-apply/receipts/` and the web journal's POST
lines first: they say whether anything reached the Pi at all before any
page code is suspected. The connected-page mock must serve
`/compiler/*.mjs` from `work/dsp-compiler` and `/web-ui/*.mjs` from
`work/web-ui` or compileDraft fails with "compiler is not served"; the
browser pane caches `style.css` and modules across server restarts, so
`fetch(url, {cache: 'reload'})` before `location.reload()`. Light theme is
what the operator sees: colours in new CSS must come from the theme
variables or translucent values, never dark literals. A `<details>` in the
Settings page keeps its open state across the 1 Hz rebuild by class name,
so give each one a class.

**Not started.** AoIP-only, the Dante mode plan (unchanged from below).

---


## Previous pickup (2026-09-14) — live coefficient updates are ACCEPTED; owed: two reads and one reinstall

Read the handoff from `STAGED 2026-09-13 (design only)` to the tail: one
day, about thirty entries, ending in ACCEPTED 2026-09-14. Then
`work/phase4-bridge/LIVE_COEFFICIENTS_DESIGN.md` (its Corrections and
Results sections carry what changed against the plan) and
`work/phase4-bridge/LIVE_INSTALL_PLAN.md` (the sequence that ran).

**In service.** Bridge 7e8f1064 (the meter-tap bridge plus two coefficient
sets in `DspStage`, a control thread polling `/run/usb16x16/dsp-live.dsp`,
the `DSPLIVE` status line, `dsp_live_*` on BRIDGE and SUMMARY), supervisor
8b42e4ec (pins 7e8f1064, passes the live file for blocks with `DSP_LIVE=1`,
DSP-build check is a list), `usb16x16-web` df9490b8 and `usb16x16-apply`
c9bd9181 1.2.0 (kinds `live`, `commit`, `revert`; drains queued requests;
units e11f0fc9 / 6d53b053 without a start limit), the page files staged
under `~/usb-16x16-work/web-ui/` (app.mjs c2c1500b, backend.mjs 9c949398,
live.mjs c6d2287a, compiler copies). The service runs
`user-immersive-stereo-subs`, a fixed-shape user preset (shape 064ef631)
with `DSP_LIVE=1`, committed by the operator; every page edit is a live
preview until Commit preview. The accepted transport figure on this bridge
is dsp-direct 746 at 64 (4 x 800, spread 0), 600 s soak, floors 85 / 96
(`outputs/dsp-service/live-direct-20260913/`). Repo artifact pin moved;
947e8b4d kept beside it. Rollback: `~/usb-16x16-work/live-install-20260913/
install-live-set.sh rollback` plus `rollback/web-control/` copies (switch to
dsp-direct first if a user block is live: the old supervisor does not know
`DSP_LIVE`).

**Owed, in this order.**

1. `dsp_us_max` over a quiet hour, page closed then open. It crept 133 ->
   334 us across the evening's live session with the mean flat at ~53 us;
   candidates are the first cold read of a freshly published set and the
   page's ~10 Hz `/api/meters` polling. Read-only: BRIDGE line via
   `/run/usb16x16/last-bridge`.
2. A criterion-aware soak on the preset arm. `meter_battery.py` applies the
   legacy activity gate, which fails on a preset's low-passed subs and unused
   outputs (as the 2026-09-11 loaded arm did); either thread validate.py's
   `--signal-criterion reference-events-v1` through the battery or soak on a
   preset that routes all 16 outputs. Transport counters of the 2026-09-13
   swap soak were clean (~340 swaps, zero RECOVERs, cost unmoved).
3. Reinstall the web-control set once (`~/usb-16x16-work/web-control/
   install-web-control.sh`, operator's sudo): the staged `usb16x16-web`
   396a2fa0 lets the preset store accept the shipped draft's middle-dot
   name; the page saves as "Immersive - stereo subs" meanwhile.
4. Repeat the edit tally after any page change: count `POST /api/apply/live`
   202 vs 409 in the web journal against `DSPLIVE applied` in the bridge
   journal. The bar is every edit applied within a second; the day ended at
   43 of 43.

**Rules learned on 2026-09-13, all in memory too.** Page changes must be
tried in a browser against a mock of the control service (the scratchpad
pattern: serve `work/web-ui` with a fake `/api/health` built from the real
profile row, on a fresh port each time because the browser pane caches
modules); Node's tests cannot see `crypto.subtle` missing on plain HTTP,
timers called with the wrong receiver, or the 1 Hz Settings rebuild. Two
writers to the live file (a pusher and the page) make the page's
expected-hash guard refuse; the page now answers a foreign state once and
retries a stale refusal once. Candidate wrapper runs log the bridge to
tmpfs (an SD-card log stalled the audio thread on the 5 s writeback and
three runs aborted before that was found). A `pgrep -f` over ssh matches
its own command line. The applier is one process per request; the units
carry no start limit and it drains what is queued.

**Not started.** AoIP-only (the entry below), the Dante mode plan, the
`--shape` runner is not needed by the applier.

---


## Current DSP pickup — the meter tap is ACCEPTED; next is AoIP-only or the UI items

Read the handoff's 2026-09-11 entries from FOUND onward (the last fifteen).
Accepted: DSP bridge 406699bd with dsp-direct / dsp-transparent / dsp-loaded
under reference-events-v1. In service: UI Apply (profile switches, verified,
receipted, rolled back on failure) and browser-compiled user presets (the
page compiles with the verified compiler served as web-ui/compiler/, the
applier validates by loading through the bridge's own runner, installs
user-<slug>.dsp and a STATUS=experimental block copied from dsp-direct's
transport, the supervisor validates the file, then the switch). The full
cycle passed from the user's browser (outputs/dsp-service/user-preset-
20260911/). Installed: supervisor f3f099b9, usb16x16-web 1.3.0,
usb16x16-apply 1.1.0, usb16x16-dsp-offline 8469c2e8; the service runs
dsp-direct. Read work/web-control/README.md before touching any of it.

The level meter tap is ACCEPTED (2026-09-11 23:55 UTC): bridge 947e8b4d on
dsp-direct with METERS=1, 703 at 64 (4 x 800, spread 0), RTL at 32
18.563 ms = 703 + 188, floors 83 / 72, zero RECOVERs, meter tap 1.4 us
mean / 56 us max on the audio thread; supervisor 23e40f8c, conf b01588df
live (repo conf carries the new labels, one copy behind), usb16x16-web
1.4.0 with /api/meters, the page drawing live peaks. The battery runner is
work/dsp-service/meter_battery.py (no bundle). Lesson kept: never create a
std::thread after capture start in the bridge. dsp-transparent and
dsp-loaded keep their 406699bd figures, unmeasured on 947e8b4d.
Rollback: METERS=0 and a restart, or 406699bd from commit 47a6f42.
No filesystem walks, transfers or builds on the Pi during a run.

AoIP -> DSP -> AoIP, 2026-09-12: designed, built (bridge 0a39f4a6 at
~/usb-16x16-work/phase4-aoip-src/build, hash pinned in the wrapper) and
measured once: 8.227 ms wall / ~419 samples at the Pi's port, TX queue flat
at 198 so TX_PLAYBACK_PRIME is the first lever; handoff MEASURED 2026-09-12
13:24 and the design note's MEASURED section. Not installed, not accepted. Three runs by 22:41 UTC: the stream-stop test
answered (a lost source is silence, the capture keeps delivering zeros, the
loop resumes by itself; the supervisor takes no action on input in loop
mode), one RECOVER per run with the cause open (tcpdump window a suspect:
the capture-off control read zero in 420 s). Prime 96 measured 5.844 ms
but is unsafe (queue to 6 on a 96-frame pull, one RECOVER; the driver's
144-frame skip bounds the prime at 192): the loop's figure is 8.2 ms at
192. The Ferrofish's stamp phase moved 41 -> 11 (a 44.1 kHz Logic session via
the Metric Halo, 2026-09-12 23:34 UTC) and the lead shrank to 0.64 ms,
but sink delay 103 does NOT cross: lead positive, zero ravenna-capture
zero runs in four minutes of 15-channel noise (handoff CORRECTION
2026-09-13 02:00). No switch. Read the lead pair at the start of every
measuring day; a lead under ~0.3 ms or any ravenna-capture zero-run
event under signal triggers a >=133 profile. The frame model of
stamp-phase.py disagreeing with the measured lead is an open item. The Wi-Fi keepalive unit is installed (work/pi-tuning). aoip-stream-stop.sh is the timed helper for the sink test. Read work/phase4-bridge/AOIP_LOOP_DESIGN.md first (status
paragraph, then "Steps"). Bridge --mode aoip-loop with --loop-impulse in
main.cpp (syntax-checked on the Mac, the accepted binary untouched),
loop-measure preset 1e417960 (outputs/dsp-service/aoip-loop-20260912/),
work/aes67-candidate/run-aoip-candidate-safe.sh (hash pin FILL-AFTER-PI-BUILD),
work/phase4-bridge/build-aoip-candidate.sh, analyze-aoip-loop.sh, and
rtp-impulses.py --loop. Next: stage and build on the Pi with the service
stopped, pin the hash, first candidate run, then the stream-stop test and
the supervisor MODE work (steps 5-8 of the design).

Rules that stand: a user preset is never accepted and never soaked unless
the user asks; every profile switch is a restart and a new draw; Pi root
changes are stated and waited for; no coreaudiod kills; no measurement
campaign without a stated purpose. Open, in the record's order: AoIP -> DSP -> AoIP (the supervisor's failure
model waits on the USB host); in the UI, showing which user preset is live
inside the editor rather than only by name in Settings.

The earlier battery remains FAILED under its original zero-run criterion:
`outputs/dsp-service/acceptance-20260911/RESULTS.md`. Direct/transparent passed
preflights, 4 x 800 impulses and ten-minute soaks at 725/766 samples; user RTL
at 32 frames was 19.021/19.875 ms. The 48-sample AES67 index step between
those two starts is read in the handoff's FOUND 2026-09-11 entry as a TX queue
start draw that predates the stage's first filtered render; n = 1 per arm, so
"accounted for", not "proven equal". Keep it separate from the now-explained
filter/quantization events.

Implementation and policy: `work/dsp-service/REFERENCE_VALIDATION.md`.
The legacy gate remains default; new receipts bind the chosen criterion,
checker/exporter/validator hashes, bundle, harness and service/bridge identity.
Only retained event windows are compared; wholeRunValidated=false. No general
whole-stream integrity proof is claimed. 26 Python and 11 Swift tests pass.
Earlier replay/capture evidence is in `offline-loaded-20260911/`,
`event-capture-20260911/` and `reference-check-20260911/` under outputs/dsp-service.
Do not rerun the one-use historical wrappers or reuse their receipts.

Candidate bridge 406699bd / supervisor cdc0768d remain installed. Direct
restoration is recorded in the newest campaign's final-state.json and
run-status.json. dsp-direct disables DSP on the candidate, not a binary rollback.
Baseline rollback remains 05f37bd9 / 427982dc / 306cfa85.

Corrections to older claims below:
- 1042 versus 1061 on separate starts does not establish latency neutrality.
- Do not run the loaded preset through the impulse latency/RTL battery.
  Use the continuous 16-output stability test, with explicit returned inputs.
- Readiness-probe retries plausibly explain the loaded-arm recoveries;
  a single-open continuous test must confirm that, rather than assuming it.
- The four impulse runs per direct/transparent arm test within-session
  stability, not four independent startup draws. Do not repeat restart campaigns.
- The package installs the three pinned files together with service stopped;
  use its deploy.py and rollback, not the historical legacy installer recipe.

For any future hardware arm, obtain a fresh process-bound preflight. No coreaudiod kill,
remote polling during audio, or attempt to enable UI Apply before service
validation. The detailed older session record follows for provenance.


Paste the block below into a fresh Codex or Claude Code session to resume work.
It points at `PROJECT_HANDOFF.md`, which is authoritative where it conflicts
with this summary.

Updated 2026-09-11 01:00 UTC: step 4 of the DSP roadmap -- the filter
stage inside the bridge -- is built, verified against CamillaDSP, and
measured under the harness, but NOT installed and NOT accepted. That is
this file's live work; see THE DSP STAGE and THE DSP BATTERY. Phase 6 (the pull-gap
bar under the TX prime) is still a standing daily read. The sd103
acceptance of 2026-09-07 is untouched and is still what the service runs.
Where this summary and the handoff tail differ, the handoff wins.

---

Raspberry Pi 5 USB 16x16 / AES67 bridge. Repo: ~/Development/USB 16x16
(github.com/squeaksquad/usb-16x16-aes67, main, pushed and clean).

If you are picking up the DSP work, read first:
work/phase4-bridge/DSP_MODE_DESIGN.md whole (the decision, where the stage
sits, the real-time budget, the acceptance criteria, and the three MEASURED
sections at the end -- the last one carries what is and is not established),
then work/dsp-compiler/README.md's verification sections, then
work/aes67-candidate/run-dsp-candidate-safe.sh (the wrapper's four
differences from run-phase4-candidate-safe.sh are in its header comment),
and the DspStage block in work/phase4-bridge/include/usb16x16/bridge_core.hpp
plus its use in src/main.cpp (search --dsp-preset, renders_after_prime and
dsp_us_max). The transport work below is unchanged and still applies.

Read the Rollback rules at the end of PROJECT_HANDOFF.md, then everything
from "FOUND 2026-09-07 21:30 UTC" to the end (the phase arithmetic, the
gate, the sd103 set and its acceptance)
(chronological, bold lead-ins; a CORRECTION paragraph wins over the entry
it amends), then the BUDGET entry "BUDGET 2026-09-06 00:40 UTC" for the
lever pricing (its sink-delay pricing is corrected in the 17:23 UTC
MEASURED entry of 2026-09-07), then work/aes67-bridge/aes67.conf's blocks
for ...-rxtrim-age50-sd132 and ...-rxtrim-age50-sd103 (the point of record),
work/ravenna-lead-export/README.md (the export: units, what sink_min_time
means, the frame step, how the phase is read),
outputs/latency/stage-trace-20260906/stamp-phase.py (its docstring is the
phase arithmetic) and stamp-phase-20260906-captures.txt beside it, and
work/phase4-bridge/src/main.cpp: the aligned
TX prime (the hold, the front drop, the target, kAlignPrimeMarginNs and
kAlignPrimeAgeMarginDefaultUs near line 85-100, the prime itself from
about 1400), the PRIMED overshoot/trim code just after it, and
align_playback_trigger (about 1325, target= and slack_us=).

NOTHING IS BROKEN. The service runs the accepted profile (sd103 on
bridge 05f37bd9, supervisor 631e88e1, module bc694c24) with zero RECOVERs,
restarted 2026-09-11 00:55 UTC after the DSP session. The DSP work changed
nothing it runs: the installed binary is still 05f37bd9 and the supervisor
still pins it. The sd103 labels are copied; nothing pending on the Pi.
Every read starts with a fresh anchor as always. Playback is on.

THE DSP STAGE (built and measured 2026-09-10/11, NOT installed, NOT accepted)
Step 4 of work/web-ui/README.md's sequence. The filtering goes inside the
bridge rather than into a separate engine; DSP_MODE_DESIGN.md has the
reasoning and the three alternatives it rejected.

What exists. DspStage in bridge_core (load an artifact off the audio path,
process() in place with no allocation, locks or throws; double arithmetic,
float only at the buffer boundary). Wired into main.cpp behind
--dsp-preset, usb-to-ravenna only. The aligned prime renders unfiltered --
renders_after_prime is the gate, because the prime block falls through to
the same render call and `primed` is already true by then -- and the stage
engages on the next render. The bridge reports dsp_us_max and dsp_us_mean
on the BRIDGE line and in SUMMARY. work/dsp-compiler emits the coefficient
artifact from the same compilation as the CamillaDSP YAML, so the two
cannot describe different pipelines.

What is proven.
- The bridge's filtering and CamillaDSP 4.1.3 differ by no more than one
  unit in the last place -- one float32 ULP at the channel's own level, or
  one LSB of the integer container -- on all 28 channels of three presets,
  compared sample by sample on the Pi (headtohead-20260910T173732Z).
- The stage is latency-neutral: transparent arm 1042 samples against the
  direct arm's 1061, 800 of 800 impulses identical in both, correlation
  peaks 0.250031 and 0.249999. Separate candidate starts draw their own
  level, and a stage adding transport depth could only move it up.
- Its cost is 0.0046-0.0048 us per frame per biquad, flat across idle and
  harness-loaded runs at 256 and 308 biquads. The mean scales with biquad
  count and nothing else. (The "+32% under load" of an earlier note is
  RETRACTED: that compared two maxima, and the maximum tracks the largest
  block rendered plus any re-prime disturbance.)
- The prime bypass works and the aligned start is undisturbed: ALIGN
  status=ok, target=prime, PRIMED front_age_frames 296 under_prime 0, the
  age50 figures exactly.

What is NOT established, and what the next session is for.
- Every level measured is an aged-anchor CANDIDATE draw. 1042 and 1061 are
  internally consistent and are NOT comparable with the accepted 719.
- Candidate runs, not service runs. The accepted figures come from
  measure-under-service.sh against usb16x16-aes67.service.
- One run per arm, no soak, no RTL figure. The battery asks for four
  800-impulse runs and a 600 s soak per arm.
- The Mac-side hole check has no valid result: zeros.py is for the
  continuous-noise probes, and run on an impulse capture its "100% zeros
  inside the span" is the silence between impulses.

INSTALLED ON THE PI BY THE DSP SESSION (root changes, still in place)
/usr/local/sbin/run-dsp-candidate-safe.sh (55c70ab4, root:root:755) and
/etc/sudoers.d/usb16x16-dsp, one NOPASSWD line for it, because
measure-aes67-roundtrip.sh launches candidates with sudo -n. Remove both to
revert. Nothing else was installed.

STAGED ON THE PI, NOT INSTALLED
~/usb-16x16-work/dsp-verify/: the candidate bridge
bridge-build/usb16x16-rt-bridge (406699bd = the accepted 05f37bd9 source
plus the stage), the build tree, usb16x16-dsp-offline, the verification
harnesses, and the compiled presets loaded.dsp (2b6baa04, 308 biquads),
transparent.dsp (ad695984, 256 biquads at 0.01 dB, no crossovers, no
delay), crossover.dsp and phones.dsp. The wrapper accepts loaded and
transparent by hash; a new preset needs its hash added to
expected_dsp_sha256_list.

THE POINT OF RECORD (accepted 2026-09-07 22:25 UTC)
Profile servo-aligned-both-240-rx120-sd144-tx192-target48-trace-txoff950-rxtrim-age50-sd103
(TARGET 48, ALIGN_TX_OFFSET_US 950, RX_PRIME_TRIM 1, ALIGN_PRIME_AGE_MARGIN_US
50, SINK_DELAY 103; the "sd144" in the name is historical) on bridge
05f37bd9 (--align-prime-age-margin-us, default 150 = the older
behaviour), supervisor 631e88e1 (module_binary ravenna-lead-install/,
expected_module_sha256 bc694c24), module bc694c24 (the transmit-slot fix
0001 plus the arrival-lead export 0002; rollbacks cc6852f0 in
ravenna-tx-fix-install/ and the original f65a4955 in the v2.1 tree), conf
556cc2b6, installer 21448108. Fresh anchor: 719 at 64 frames, RTL
Utility at 32 frames 18.896 ms = 719 + 188 to the sample; 4 x 800 loaded
and the 600 s soak all on 719, zero RECOVERs; TX floor 78 loaded, RX 72,
tx_pullmax 48, tx_occ / rx_occ 51; TX PRIMED front_age_frames 296
under_prime 0, RX PRIMED ring_at_prime 192 trimmed 21, ALIGN trigger
target=prime; split pos_tx -19 / pos_aes67 544 / pos_rx -22 / pos_pi 503,
pi_total about 678, usb_time about 41-46; the arrival lead 947-1032 us per
interval on both sinks. The day's chain on fresh anchors, RTL at 32:
age50 19.875 (766), the 14:48 anchor at 144 on the new module 19.729
(759), sd132 19.479 (747), sd103 18.896 (719). Yardstick: Dante Virtual
Soundcard 11.312 ms at 32. Rollbacks by switch-profile, conf only:
...-rxtrim-age50-sd132 (132), ...-rxtrim-age50 (144), ...-rxtrim (age
margin 150), ...-target48-trace-txoff950 (no RX trim). Bridge and
supervisor sets: phase4-age50-install/ (current bridge),
aes67-sd103-install/ (current conf, installer, labels script),
aes67-age50-install/ (supervisor 7a5d2362 with module cc6852f0: the module
rollback, service stopped).

WHAT THE RECORD SETTLED (do not re-derive)
- The Mac reports a level set on usbaudiod's timeline at each gadget PCM
  restart; only a fresh anchor (sudo systemctl restart usb-16x16.service;
  the AES67 service restarts itself, systemd's restart counter shows it,
  about 60 s to STAGE running) reads a known figure. The level follows
  the bridge's start depth 1:1 only when the rest of the draw holds: two
  anchors with identical PRIMED lines read 748 and 766 on 2026-09-07 (the
  748 had a stalled first second, both devices pulling 96 in one gap: re-
  draw such anchors); 759 and 747 the same afternoon differed by exactly
  the lever. Compare levers by the index chain (pos_aes67, pos_pi) and
  pi_total, and by the level only across anchors whose PRIMED lines match.
- The aligned wait allowance is TX cover; the ring target is not; the RX
  prime overshoot was permanent RX depth (trimmed since rxtrim); the
  prime margin's age is priced at 50 us while the target keeps 150
  (age50). Floors: TX 75-87 loaded across the accepted sessions (the
  session's own draw of pull gaps, worst gap about 1.15 ms), RX 72.
- The arrival lead: the RAVENNA driver computes, per packet, how long
  before the TIC that copies its first sample it arrived; the export
  (module bc694c24) fixed its units (100 ns against 100 us, a factor of
  1000), seeded its minimum, and carries it to GET /api/sink/status/N as
  sink_min_time, the least lead in microseconds since the previous GET of
  that sink, -1 with no packet, negative for a late packet (a hole). Read
  it in pairs around a run (work/ravenna-lead-export/read-lead.sh
  [label]). Both Ferrofish sinks read within 25 us of each other:
  0.93-1.06 ms per interval at 144 and at 132, worst 930 us over 35
  loaded minutes.
- Sink delay's cost is a step of one TIC frame, not a slope: the driver
  places a packet at stamp plus delay and rounds down to the 48-sample
  frame whose TIC copies it, so the deadline moves only when the
  Ferrofish stamp phase plus the delay crosses a frame boundary. 132 read
  144's lead (free, 12 samples); 96 had crossed (lead about 40 us, the
  41-sample holes of 2026-09-04). The BUDGET entry's "120 leaves 430 us"
  was wrong: below the crossing nothing between 96's lead and 144's
  exists.
- Sink delay changes no audio at any value; its only failure is a late
  packet, copied as a stale slot.
- The Ferrofish stamp phase is 41 (handoff FOUND 2026-09-07 21:30 UTC):
  read from the two 2026-09-06 eth0 captures still in the Pi's tmpfs as
  the sink 0 stream's wire phase ((RTP timestamp - mediaclk offset) mod
  2^32, mod 48) minus the Pi's own source's, mod 48. The Pi's source is
  stamped with the TIC SAC minus one frame, a multiple of 48, so its wire
  phase (16) is the 2^32 mod 48 = 16 shift of the SAC high word, which
  moves every 24.855 h and cancels in the difference; a bare "timestamp
  mod 48" is wrong by that shift and by the 32-bit wrap. The same 41 on
  every packet of both captures, 70 minutes apart across a module
  reload; consistent with 132 reading 144's lead (needs 12 or more) and
  with the Ferrofish's packets arriving about 1.0-1.15 ms after the PTP
  time of their first sample (measured against the Pi's own packets in
  the same captures; the earlier "about 2 ms" is corrected). For phase
  p the free delays are 144 - p .. 191 - p: at 41, 103..150, so 103 is
  the lowest free value (29 under 132, 0.604 ms) and 102 crosses. Sink 1
  was not in the captures; its lead within 5-25 us of sink 0's on every
  interval puts its phase within a sample of 41. Any delay under 144 is
  exposed to a Ferrofish flow restart re-drawing the phase (132 to 12 of
  48 draws, 103 to 41); the lead export shows it in one read, the
  rollback is switch-profile to 144.
- Nothing compiles the RAVENNA module on the Mac; the Pi build in a
  service-stop window is the syntax gate (build.sh in ravenna-lead-src/
  refuses while the service is active).

THE PROCEDURE (every measurement session starts with it)
1. Playback off (ask). Nothing on the Mac holds the device open; the
   harness and RTL Utility never share it.
2. Fresh anchor: the user runs sudo systemctl restart usb-16x16.service.
   usbaudiod logs fresh setStartingUSBFrame lines (/usr/bin/log show
   --last 10m --predicate 'process == "usbaudiod"'; the bare word log is
   a zsh builtin). Wait for STAGE running on the Pi (journal: "sinks
   applied, delay N", both sinks' "delay" read back), read the ALIGN,
   PRIMED and ALIGN trigger lines: front_age_frames 296, under_prime,
   intended 171, ring_at_prime 192, trimmed 21, target=prime, slack_us;
   the first second's pulls (48, not 96). Take the first lead pair.
3. Gate: channel-2 noise probe at 64 (--input-channel 2 --output-channel
   1 --other-channel-load-amplitude 0.1, 100 impulses, USB16X16_DUMP to
   the scratchpad, zeros.py in outputs/latency/usb-holes-20260904/): 0.0%
   zeros, no run. A Mac hole state is cleared by sudo killall coreaudiod
   on the Mac (itself a fresh anchor).
4. Read: work/aes67-candidate/measure-under-service.sh 64 100 <label>,
   a lead read after it. Then copy /run/usb16x16/bridge.log into
   outputs/latency/stage-trace-20260906/ (between runs, never during)
   and split it: python3 outputs/latency/stage-trace-20260906/impulse-index.py
   <log> --level <N>. Report level, pi_total, usb_time, pos_aes67, the
   PRIMED lines, the lead.
5. Acceptance: four 800-impulse runs and the 600 s soak, all with
   USB16X16_OTHER_LOAD=0.1, detached (Popen start_new_session, a Monitor
   polling the log for an exit= line; the chain scripts of 2026-09-07
   put a read-lead.sh pair around every run), zero RECOVERs inside runs,
   no negative lead, floors reported, RTL at 32 by the user, on one
   fresh-anchor session; then the block's MEASURED/COVER/STATUS, the conf
   pin, and a copy-<tag>-labels.py for the live conf (labels only, dry
   run without --apply).

THE DSP BATTERY (the next session's job, if the DSP work continues)
Run it ONCE, properly, rather than repeating tonight's candidate runs. What
makes it acceptable rather than reconnaissance:
1. Cold start, so the anchor is fresh without a coreaudiod kill.
2. Install the candidate bridge so it is service-versus-service, the way
   the accepted figures were taken. That moves THREE pins (see BUILD AND
   INSTALL RULES) and the supervisor's expected_bridge_sha256, and the
   rollback is the artifact in work/phase4-bridge/artifacts/pi-aarch64/.
   Without this every figure carries the candidate caveat.
3. The channel-2 noise probe FIRST (procedure step 3). It is the only form
   that answers the Mac-hole question; an impulse capture cannot.
4. Three arms, interleaved rather than four-of-one-then-four-of-the-other,
   because separate starts draw their own level and interleaving makes the
   drift hit both arms equally: no preset (direct), transparent.dsp
   (latency), loaded.dsp (cost and stability). Four 800-impulse runs and
   the 600 s soak per arm, USB16X16_OTHER_LOAD=0.1.
5. RTL at 32 by the user, per arm, never sharing the device with the
   harness.
Latency may only be read through transparent.dsp. loaded.dsp cannot
measure it at all: its 80 Hz high-pass means the impulse the harness
correlates against is not in the signal, and the 2090 it produced is a
smeared peak 13 dB down, not transport depth. That also causes its
RECOVERs -- the attenuated impulse fails the harness's signal gate, it
re-probes, and every probe closes and reopens the device, which is the
recorded both-PCM XRUN pair. Expect zero RECOVERs on the other two arms.

THE LEVERS, IN ORDER, ONE AT A TIME
(The transport levers below are paused while the DSP work is live. They are
unchanged and still correct.)
1. Phase 6 is running (handoff STARTED 2026-09-07 23:05 UTC): the TX
   prime (192) sits over a bar of one period plus the Pi's worst pull
   gap, and the RAVENNA playback queue's running floor (tx_qfloor on the
   bridge's once-per-second line, since process start) prices it
   directly: a prime cut of X lowers the floor by X. Daily, between
   runs, never during one: outputs/latency/phase6-gapbar-20260907/read-bar.sh
   [label] (read-only, a few KB over ssh; saves reads/bar-<label>-<UTC>.txt
   and prices it with gap-bar.py; commit the read). The rule, stated
   before the data: a conf-only block only when the worst floor over
   three or more days of real use plus the loaded set leaves one period
   (48) at the new prime, in steps of 24. The record so far: floors
   75-94 over nine sessions of the current lineage, 78 on the live
   process after 1.3 h, longest clean-session gap 1629 us (a
   stalled-first-second anchor), so 168 is the candidate (24 samples,
   0.5 ms at RTL 32) and 144 is out unless the days say otherwise. A
   floor under 72 closes the lever at 192. The block when the days
   allow: sd103 with TX_PLAYBACK_PRIME=168, one variable, tag prime168
   (not tx168: a tag must prefix no field key), the usual acceptance,
   expected 24 under 719 on a matching anchor. The sink delay is at its
   floor for the Ferrofish stamp phase 41 (103; 102 crosses); the Mac
   constant (188 over the harness level at RTL 32) and the gadget's
   share of the USB legs are not reachable by profile.
2. Standing rule for the sink delay: after any Ferrofish, switch or Dante
   Controller change, and after unexplained ravenna-capture zero runs,
   read the lead pair first (work/ravenna-lead-export/read-lead.sh). Near
   zero or negative on both sinks means the flow re-drew its phase:
   switch-profile ...-rxtrim-age50 (144), then a fresh 4 s root capture
   (sudo timeout 4 tcpdump -i eth0 -s 1500 -B 65536 -c 8000 -w
   /tmp/phase-$(date -u +%Y%m%dT%H%M%SZ).pcap 'udp and dst port 5004')
   read with stamp-phase.py (the Pi's own streams must be in it) gives
   the new floor, 144 minus the phase, as one conf-only block.
3. If a measurement session is wanted for its own sake: the procedure
   above on the sd103 profile; expect 719-class levels on anchors whose
   PRIMED lines match (the fresh-anchor draw of the USB remainder is
   about +-10).

DSP BUILD AND MEASUREMENT RULES (learned the expensive way on 2026-09-10)
- Prove a changed wrapper with a 60 s candidate over ssh before any 480 s
  measured run: sudo -n /usr/local/sbin/run-dsp-candidate-safe.sh 60 none.
  Check metadata.txt has direction_restarts, the bridge log has DSP loaded
  and DSP engaged with the right biquad count, and RECOVERs is 0. Three
  minutes. Skipping this cost two 40-minute runs to a $2 collision and an
  unbound variable under set -u.
- Touch NOTHING on the Pi between launching a measured run and its
  completion -- no ssh, no pgrep, no scp. Watch the Mac-side output file
  only.
- pgrep -f matches its own ssh command line. "candidate up" was reported
  twice from a pattern matching the very command asking the question. Use
  pgrep -c -x with exact names, or check for an artifact (a result
  directory, a log line) instead of a process.
- A direction restart under the harness is COUNTED, not fatal: the
  readiness probes open and close the device and every close re-primes the
  gadget PCM. The wrapper counts them, records direction_restarts, and
  fails only above USB16X16_DSP_RESTART_LIMIT (8). Its post-run marker
  check excludes RECOVER lines for the same reason.
- The Pi has no ALSA dev package. Build the bridge there with the README's
  temporary sysroot: apt-get download libasound2-dev, dpkg-deb -x to
  /tmp/alsa-dev, then -DALSA_INCLUDE_DIR=/tmp/alsa-dev/usr/include
  -DALSA_LIBRARY=/usr/lib/aarch64-linux-gnu/libasound.so.2. No sudo
  needed. The Pi has no node, so presets and artifacts compile on the Mac.
- The Pi has no bc. The supervisor's mawk is there; use awk.
- work/dsp-compiler/run-headtohead.sh re-runs the CamillaDSP comparison and
  refuses while the service is up; run-verifications.sh and run-load.sh the
  same.

BUILD AND INSTALL RULES
- Syntax-check bridge changes on the Mac first: clang++ -std=c++20
  -fsyntax-only -Wall -Wextra -Wpedantic -Werror with the Pi's ALSA
  headers as system includes (~/usb-16x16-work/deps/libasound2-dev/usr/include/alsa
  on the Pi; copies in earlier scratchpads under
  /private/tmp/claude-501/-Users-bryandimaio-Development-USB-16x16/*/
  scratchpad/alsa-include) and shims for endian.h, clock_nanosleep /
  TIMER_ABSTIME and ESTRPIPE (86). Core tests build on the Mac without
  ALSA. Build on the Pi only with the service stopped (the user stops
  it); stage the source in a fresh ~/usb-16x16-work/phase4-<tag>-src/
  with a build.sh that refuses while the service is active (copy
  phase4-age50-src/build.sh). Module changes: a patch on top of 0001 and
  0002, work/ravenna-lead-export/build.sh's form, ~/usb-16x16-work/
  ravenna-<tag>-src/ and ravenna-<tag>-install/, the supervisor's
  module_binary and expected_module_sha256 moved after the build. No
  transfers while a measurement runs; stage file by file while the
  service runs, not as one tar stream.
- A new bridge binary needs THREE pins moved: install-candidate.sh,
  install-aes67-service.sh (bridge and supervisor pins, the full 64-hex
  hash), and the supervisor's expected_bridge_sha256; the artifact in
  work/phase4-bridge/artifacts/pi-aarch64/ and the README paragraph.
  Stage phase4-<tag>-install/ (binary, wrapper 6282b108, installer) and
  aes67-<tag>-install/ (supervisor, unit, conf, installer, block); the
  user installs (state the exact sudo commands and wait). A supervisor
  that passes a new flag must never be installed ahead of the bridge
  that accepts it. A conf-only block needs no installer run: the user
  appends the block (sudo tee -a), switch-profile with the service
  stopped, start, then the fresh anchor.
- Conf values with a comma must be double-quoted; a trailing comment on
  a value line is a parse error. A profile tag must prefix no field key
  (never another's name plus tx or rx). The supervisor's parser needs
  bash 4: validate on the Pi with USB16X16_AES67_CONF=<file>
  usb16x16-aes67-supervisor profiles, against the repo conf and against
  the live conf plus the block. The harness refuses --maximum-lag-ms at
  or above 250; use 200.
- Pi commands are given bare (the user has an ssh session open); from
  this tool use ssh bdimaio@192.168.1.201 (scp without -q; the Pi's
  modinfo is /usr/sbin/modinfo). Pi root changes and Mac daemon kills
  are the user's. Each accepted step is committed and pushed with its
  evidence (harness JSON and -api/ dirs; bridge logs and .ko files are
  gitignored).

OPEN, NOT THIS SESSION'S WORK
On the DSP side: metering (still needs the separately benchmarked tap the
web-control README asks for; the filter stage is a natural place to take it
from and a natural place to make the audio thread late); Apply from the UI
(step 5, nothing exposes a control surface yet); AoIP -> DSP -> AoIP, whose
supervision is largely a separate problem because the supervisor's failure
model is built on the USB host down to host_absent waiting on dwc2
enumeration lines; the --target alsa device section, still stamped
unvalidated; and coefficient double-buffering for live preset changes,
designed in DSP_MODE_DESIGN.md but not implemented -- today a preset is
loaded once at startup and a change is a restart.
On the transport side: a supervisor rule to re-bind after a re-prime storm (the re-prime count
over days now comes from the Phase 6 daily read); the Pi's re-prime split (805
once after an RX RECOVER at start); the Mac constant and the gadget's
share of the USB legs (not reachable by profile); the sink status flags
(rtp_seq_id_error, rtp_sac_error, all_muted on sink 1) that read true
on 2026-09-07 14:12 UTC, accumulated since an earlier fetch and reset by
it, never gated on.
