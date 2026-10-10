# Next-session pickup prompt

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
