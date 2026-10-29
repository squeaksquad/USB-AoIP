# The gadget reports the Mac's last set rate (plan, 2026-10-28)

Status: steps 1-4 DONE (trace; patch, build and arbiter guard written and built, see
"Built" at the end); the bounded test PASSED 2026-10-28 23:22-23:26 UTC (see "Bounded test" at the
end). Step 1 (the trace) DONE 2026-10-28 18:36-18:40 UTC with a clear
answer, and the operator's answers are in (see "Results and decisions" at the
end, which amends the steps above it). Nothing is built or installed.
Open item 1 of `work/NEXT_SESSION_PROMPT.md` (2026-10-28), the operator's
question "can the gadget just report the last set sample rate?".

## The gap

The owner (`work/dante-mode/owner/main.cpp`, `read_gadget_rates`) and the
arbiter (`work/web-control/usb16x16-apply`, `host_rates`) learn the Mac's rate
from the gadget card's `Capture Rate` / `Playback Rate` controls. With nothing
streaming they read 0 (seen 2026-10-28 on the Pi: both `values=0`), and both
readers take 0 as "not known". So with the Mac idle:

1. A Dante-side set (Controller, patch 0005) is checked against nothing and is
   accepted against the Mac's choice.
2. A Mac-side change (Audio MIDI Setup) reaches the Pi only when an app next
   opens the device.

## What the Pi's kernel does today (6.18.34, read 2026-10-28)

Source: `~/src/linux-6.18.34/drivers/usb/gadget/function/u_audio.c` on the Pi
(the tree the label module was built from; `u_audio.ko` itself is the stock
in-tree module, `kernel/drivers/usb/gadget/function/u_audio.ko.xz`, SHA-256
`dde02c49a3f843b2404e762a969a8d145e36d6e2d16a0f341553571b7b2fc9b6`).

- `struct uac_rtd_params` holds `int srate` ("selected samplerate") and
  `int active` (stream running), per direction, under `prm->lock`.
- SET_CUR on the clock lands in `f_uac2.c:uac2_cs_control_sam_freq`, which with
  the shared clock calls both `u_audio_set_playback_srate` and
  `u_audio_set_capture_srate`. Each stores `prm->srate` if the value is in the
  configured list (else `-EINVAL`, nothing stored). It sends no control notify.
- `g_audio_setup` starts `srate` at the first listed rate (48000).
- `u_audio_start_*` / `u_audio_stop_*` (alt 1 / alt 0) and `u_audio_suspend`
  only flip `active` through `set_active()`, which notifies the rate control.
  `srate` survives all of them, including a disconnect.
- The getter, `u_audio_rate_get` (u_audio.c:1126):

  ```c
  if (prm->active)
          ucontrol->value.integer.value[0] = prm->srate;
  else
          /* not active: reporting zero rate */
          ucontrol->value.integer.value[0] = 0;
  ```

- `f_uac2.c:afunc_disable` (called by the composite layer on disconnect, bus
  reset and a new SET_CONFIGURATION) calls `u_audio_stop_capture` and
  `u_audio_stop_playback`, exactly as `afunc_set_alt(alt 0)` does for one
  direction. **Inside `u_audio` a disconnect and an idle Mac look the same.**
  That decides the patch's shape: the "forget" has to come from `f_uac2`.

So the kernel already holds the Mac's last rate; the getter hides it, and it
has no notion of "since this connection", so simply dropping the `active` test
would report a stale rate (or the 48000 default) after a disconnect.

From the 2026-10-18 03:03 trace (`outputs/latency/rate882-dirtest-20261018/`,
`trace.sh`, `trace-seqT.log`): every CoreAudio rate set made **while the Mac
held both interfaces at alt 1** sent SET_CUR (`sam_freq`, `p_srate`, `c_srate`
with the new value) between the stop and the start of both streams. Not yet
seen: what an idle Mac (interfaces at alt 0, controls 0) sends on a rate set.
That is the first step below, and the whole value of the patch rests on it.

## Step 1 — the trace (read-only, operator's sudo)

Question: with the Mac idle (both interfaces at alt 0), does a rate set in
Audio MIDI Setup still send SET_CUR to the gadget? Secondary: what the Mac
sends at enumeration and on a stream start from idle, how long after the last
client closes the Mac drops to alt 0, and whether `afunc_disable` /
`afunc_suspend` fire when expected.

Instrument: `trace.sh` from 2026-10-18 as it is, with four probes added
(copy it as `outputs/latency/rate-report-trace-<date>/trace.sh`; a new name,
the old one stays the evidence of that day):

```
"p:uac/disable usb_f_uac2:afunc_disable"
"p:uac/suspend usb_f_uac2:afunc_suspend"
"p:uac/u_suspend u_audio:u_audio_suspend"
"p:uac/rate_get u_audio:u_audio_rate_get"
```

(`rate_get` shows each control read, so the owner's once-a-second reads mark
the timeline. If it is too noisy, drop it.) Every probe is per event, never per
packet; the reader writes `/dev/shm/<dir>/trace.log` as before.

Setup: Mac at 48000, every app using the USB 16x16 quit. Stop the endpoint for
the trace so no rate change can move the stack (`sudo systemctl stop
usb16x16-dante`; Statime may stay up). Wait until `amixer -c UAC2Gadget cget
iface=PCM,name='Capture Rate'` reads 0 (unprivileged; note how long that took
after the last app quit). Then `sudo trace.sh on`.

Sequence (Mac side with `setrate.swift` from the 2026-10-18 directory, or Audio
MIDI Setup; 30 s apart):

| # | Mac | Look for |
|---|---|---|
| T1 | 48 -> 44.1, idle | `sam_freq`, `p_srate`/`c_srate srate=44100`; any `set_alt` around it |
| T2 | 44.1 -> 48, idle | the same with 48000 |
| T3 | start the silent hold client (`holdopen-20261028/hold.swift`, `usb-hold "USB 16x16" 32`), 10 s, quit it, wait until the controls read 0 | whether SET_CUR precedes `set_alt alt=1` on a start from idle; the idle drop time |
| T4 (optional) | unplug the USB-C cable for 5 s, plug it back | `disable` on the unplug; what the Mac sends at enumeration (SET_CUR? at which rate?) |

Then `sudo trace.sh off`, start `usb16x16-dante`, start check ok, noise probe
at 32 (the closing routine of 2026-10-18). Mac left at 48000.

Reading: if T1 and T2 show SET_CUR with no stream start, the patch closes both
gaps. If the idle Mac sends nothing until a stream starts, the patch closes
gap 1 only (the arbiter sees the Mac's last streamed rate) and gap 2 stays as
today; the operator then decides whether that alone is worth a kernel module.
If T4 shows no SET_CUR at enumeration, the controls read 0 after a replug until
the Mac's next rate set or stream: the safe direction.

## Step 2 — the patch

Two modules change, both from the sources the label module was built from;
no other file. Patch file: `uac2-rate-report-6.18.34.patch`, applied on top of
`uac2-shared-clock-6.18.34.patch` and `uac2-discrete-channel-names-6.18.34.patch`.

`u_audio.c`:

- `struct uac_rtd_params` gains `bool srate_set; /* host set srate on this
  connection */` beside `srate`. `kzalloc` in `g_audio_setup` starts it false,
  so before the first SET_CUR the control reads 0 as it does now, never the
  48000 default.
- `u_audio_set_{capture,playback}_srate`: on a listed rate, under the lock, set
  `srate` and `srate_set = true`; if the stream is not active and the reported
  value changed (`!was_set || old != srate`), `snd_ctl_notify` the rate control
  after the unlock (the same call `set_active` makes; it is already made from
  this interrupt context). An unlisted rate changes nothing, as now.
- `u_audio_rate_get`: report `srate` when `active || srate_set`, else 0.
- New `void u_audio_forget_srate(struct g_audio *)`, `EXPORT_SYMBOL_GPL`: for
  each direction present (`params->c_chmask` / `p_chmask`, the same guard the
  rest of the file uses, since an absent direction's lock is never
  initialised), clear `srate_set` under the lock and notify if the reported
  value went to 0. `srate` itself is kept, so the stream code is untouched.

`u_audio.h`: the prototype.

`f_uac2.c`: `afunc_disable` calls `u_audio_forget_srate(&uac2->g_audio)` after
the two stops. That is the disconnect, bus reset and SET_CONFIGURATION path;
`afunc_set_alt(alt 0)` is not touched, so an idle Mac keeps its rate.

Suspend (`afunc_suspend` -> `u_audio_suspend`) keeps `srate_set`: a resume
without a reset is the same host session, and a Mac that resets the bus on
wake goes through `afunc_disable` anyway. (Operator question 2.)

Nothing in the data path changes: packet sizing, feedback, pitch and the
`active` flag behave exactly as now. The exported CRCs of the existing symbols
do not change (`struct uac_rtd_params` is private to `u_audio.c`, `u_audio.h`
only gains a prototype), which has one consequence: the stock or baseline
`usb_f_uac2.ko` would load against the patched `u_audio.ko` and never call the
forget, so the rate would survive a disconnect. Every rollback therefore takes
the patched `u_audio.ko` out together with the patched `usb_f_uac2.ko`.

Rejected alternatives, one line each: a `u_audio`-only patch cannot tell a
disconnect from an idle Mac (above); reading `gadget->state` in the stop path
depends on callback ordering (the UDC core sets `DEFAULT` after the reset
callback); a persistent kprobe watcher in user space is a root tracing service
on an appliance; a client app on the Mac is ruled out by the operator.

## Step 3 — owner and arbiter with the patch

No code change is needed in either; both already read the controls and treat
0 as "not known".

Owner (`rate_check.hpp`, `judge_gadget_rate(capture, playback, wanted)`):

- Mac idle at the owner's rate: `match` (today `unknown`); the USB half opens
  as it does now.
- Mac idle at another rate, half closed: `mismatch` -> `USBRATE refused`, the
  half stays closed and `rate=N source=usb` goes to the arbiter, which moves
  the endpoint (~20 s to `done`). Gap 2 closed, no app needed on the Mac.
- Mac goes idle and then changes rate while the half is open: the once-a-second
  check in the loop sees `mismatch` and hands the half back (rate7 path), then
  the same. Item 2 of the open list (100 ms checks) still applies unchanged.
- After a disconnect or bus reset: 0, `unknown`, as today; a stale Mac never
  blocks anything.
- Only the header comment changes ("0 while the host has the interface down"
  becomes "0 until the host has set a rate on this connection"), in the next
  owner build; no rebuild for this.

Arbiter (`validate_rate`, `all(value in (0, rate))` with `RATE_HOST_WAIT_S` 5 s):

- A Dante-side set with the Mac idle at another rate now waits 5 s for the Mac
  to agree and is then **refused** ("the Mac's USB 16x16 is at N Hz; the Mac
  decides the rate"). Today it is accepted. This is the "Mac decides" rule
  applied when idle too; it is a behaviour change (operator question 1).
- Dante Switcher sets the Dante devices and the USB 16x16 in parallel
  (`SyncEngine.swift`, step 2), so the Mac's SET_CUR should land inside the 5 s
  wait. Checked in the battery, not assumed.
- `usb_rate_request_line` and the reversal guard are unchanged.

## Step 4 — the build (on the Pi, as `bdimaio`, no root)

The label module was built with `make -C "$KDIR" M="$MODDIR" usb_f_uac2.ko` in
`~/src/linux-6.18.34/drivers/usb/gadget/function` (its `f_uac2.c` is the
patched label source). This build must not touch that tree, which is the label
module's provenance. `build-rate-report.sh` (new, in this directory):

1. Make `~/usb-16x16-work/gadget-ratereport/build/`; copy `u_audio.c`,
   `u_audio.h`, `u_uac2.h`, `uac_common.h` and the label `f_uac2.c` from the
   tree; check the label `f_uac2.c` equals `f_uac2.c.before-shared-clock` with
   the two committed patches applied (refuse otherwise).
2. Control build first: the unmodified copies with a two-line Kbuild
   (`obj-m := u_audio.o usb_f_uac2.o`, `usb_f_uac2-y := f_uac2.o`), `make -C
   /lib/modules/$(uname -r)/build M=$PWD modules`. Record whether
   `usb_f_uac2.ko` reproduces 87989337 (not required; a mismatch is compared
   with `modinfo` and section sizes, and noted).
3. Apply `uac2-rate-report-6.18.34.patch`, build both modules the same way
   (`usb_f_uac2`'s versions resolve against the local `u_audio` Module.symvers).
   `CONFIG_MODVERSIONS=y`, no module signing, `xz` compression in the tree;
   the candidates are installed uncompressed under `updates/`, as the label
   module is.
4. Print `sha256sum`, `modinfo -F vermagic` (must be `6.18.34+rpt-rpi-2712`)
   and `srcversion` of both; these go into the installer and the handoff.

## Step 5 — bounded test, then the installer

First contact is bounded, like the label module's `test-on-pi.sh`:
`test-rate-report.sh CANDIDATE_DIR [WINDOW_SECONDS]` (root) refuses unless both
candidate hashes, the installed `usb_f_uac2.ko` (87989337), the stock
`u_audio.ko.xz` (dde02c49), `setup-usb-16x16` (b11fd358, the req_number script installed 2026-09-04; d3031e22 is the 2026-08-31 baseline copy) and
`setup-usb-16x16-rates` (d4f0ee7b) all match; stops `usb16x16-dante` and
`usb-16x16.service`; `rmmod usb_f_uac2 u_audio`; `insmod` the candidate
`u_audio.ko` then `usb_f_uac2.ko`; starts the gadget; requires
configured/high-speed in 10 s; holds the window; then restores by `rmmod` and
`modprobe` (which loads the installed modules) and starts `usb16x16-dante`
again. Ctrl-C restores too. In the window: battery items B1-B3 below.

Persistent: `install-rate-report.sh install|rollback|status` (root), the
`install-on-pi.sh` pattern:

- Pins: kernel release; candidate `u_audio.ko` and `usb_f_uac2.ko` hashes;
  installed label `usb_f_uac2.ko` 87989337; stock `u_audio.ko.xz` dde02c49
  (never written); both setup scripts. Refuses while `alsaloop`,
  `aes67-daemon` or the bridge run.
- `install`: keep the label module as
  `updates/usb-16x16/usb_f_uac2.ko.pre-rate-report` (hash-checked if it
  exists); stop `usb16x16-dante` and `usb-16x16.service`; `rmmod usb_f_uac2
  u_audio`; write `updates/usb-16x16/u_audio.ko` and `usb_f_uac2.ko` by
  temp-and-rename; `depmod -a`; `modprobe usb_f_uac2`; check
  `/sys/module/u_audio/srcversion` and `/sys/module/usb_f_uac2/srcversion`
  equal the candidates'; start the gadget, configured/high-speed in 20 s;
  start `usb16x16-dante`, start check ok. Any failure restores the label
  module and removes `updates/usb-16x16/u_audio.ko` (so the stock one loads),
  then starts both services.
- `rollback`: the same swap backwards: remove `updates/usb-16x16/u_audio.ko`,
  restore the label `usb_f_uac2.ko` from `.pre-rate-report`, `depmod`, reload,
  verify the stock `u_audio` srcversion is loaded, start both services. The
  protected rollback (`usb_f_uac2.ko.pre-discrete-channels`, the 2026-08-31
  set) keeps working only with the patched `u_audio.ko` gone, so the handoff's
  rollback rules gain one line: "`install-rate-report.sh rollback` before any
  older module rollback".
- `status`: hashes on disk, srcversions loaded, the two controls' values.

## Step 6 — the battery

At 48 kHz unless a line says otherwise; the operator's Pro Tools setup stays at
48. Mac idle means every client quit and the controls of the stock module
would read 0 (check by `/sys/module/u_audio/srcversion` that the patched
module is the one loaded).

- B1 Controls, idle: after load, both read 0 until the Mac sets a rate; Mac
  idle 48 -> 44.1 -> 48 reads 44100 then 48000 within a second each, with no
  app open (only if step 1 showed SET_CUR when idle).
- B2 Controls, streaming: the hold client open: 48000 as now; quit: stays
  48000 (today 0).
- B3 Disconnect: unplug, the controls read 0 while out; replug: 0 or the
  Mac's enumeration rate, as step 1 T4 predicts. A Mac reboot (bus reset) the
  same. Mac sleep and wake: recorded (keeps or clears, per question 2).
- B4 Owner and arbiter, Mac side: Mac idle 48 -> 44.1: owner `USBRATE refused`,
  arbiter `done` at 44.1 (~20 s), with no app opened; back to 48 after the 30 s
  guard (or rate8's retry): `done` at 48. Noise probe at 32 at each rate.
- B5 Arbiter, Dante side: Mac idle at 48, `set-rate-one.py` asks the Pi for
  44.1: refused with the "Mac decides" message, endpoint untouched. Then Dante
  Switcher 48 -> 44.1 -> 48 with the Mac idle: both moves `done` (the parallel
  Mac set lands inside the 5 s wait).
- B6 Disconnect never blocks: Mac at 44.1 idle, endpoint at 44.1, unplug: the
  controls read 0 and a Dante-side set to 48 is accepted as today.
- B7 The point-of-record battery for a new kernel module (CLAUDE.md rule): four
  loaded 800-impulse runs and a ten-minute sixteen-channel soak at 48
  (`work/dante-mode/measure-candidate.sh`), level inside 330-365 /
  `daw_timeline` 480-515; `usb16x16-latency bitexact` (monitors muted); one
  loaded run at 44.1; Audio MIDI Setup still shows one `USB 16x16` duplex
  device with labels 1-16.

Then ACCEPTED or rolled back; the handoff entry records both module hashes,
srcversions and the evidence directory; `CLAUDE.md`'s map gets the new files.

## Operator questions

1. With the Mac idle at another rate, a Dante-side set (Controller, `netaudio`)
   will be refused instead of accepted. Is that wanted ("the Mac decides",
   applied when idle too)? Dante Switcher is not affected if it sets the Mac
   within 5 s, which B5 checks.
2. Keep the rate through a USB suspend (planned), or clear it there too?
3. When to run the step 1 trace (needs your sudo and about 10 minutes with the
   endpoint stopped; T4 needs a cable pull and is optional).

## Results and decisions (2026-10-28, later the same day)

**Step 1 DONE, 18:36-18:40 UTC: an idle Mac sends SET_CUR on every rate set.**
Evidence `outputs/latency/rate-report-trace-20261028/` (`trace.sh` 2b89117a,
operator's sudo on and off; `trace.txt` is the kprobe log, `controls-T3.txt` the
control reads). Endpoint stopped 18:35:53 for it, Mac idle at 48000 with both
controls at 0.

| # | Mac | Gadget | Controls |
|---|---|---|---|
| T1 | 48 -> 44.1, idle | `sam_freq`, `p_srate`/`c_srate srate=44100`, nothing else (no `set_alt`, no stream start) | 0 / 0 |
| T2 | 44.1 -> 48, idle | the same with 48000 | 0 / 0 |
| T3 | hold client opened | `set_alt alt=1` on both interfaces, both streams start; **no SET_CUR** before them | 48000 / 48000 |
| T3 | hold client killed | `set_alt alt=0` on both within 4 ms | 0 at once |

So the kernel receives the Mac's rate whenever it changes and only the getter
hides it: the patch closes both gaps. Two corrections to what was assumed:

- The Mac sends the rate only when it changes, not at a stream start. The
  patch's "remember since the last SET_CUR" is therefore required, not an
  optimisation (a getter that asked the Mac would get nothing).
- An idle Mac does not keep the interfaces at alt 1: they drop the moment the
  last client closes (the 2026-10-18 note "the Mac keeps both streaming
  interfaces at alt 1 between clients" held for clients seconds apart, not for
  an idle Mac). That is why the controls read 0 with nothing open.

No `afunc_disable` or suspend fired (none was provoked; T4, the cable pull,
was skipped). They are checked in the battery (B3). Close: trace off by the
operator (no reader left), `usb16x16-dante` started 22:58:46 UTC, start check
ok 22:59:51, noise probe at 32 clean
(`ratereport-aftertrace-noise-ch2-32f-20261028T230009Z`: no zero runs, no
discontinuities). Mac at 48000.

**Operator's answers.**

1. **"No, if Dante changes the Mac side should change."** The arbiter must keep
   accepting a Dante-side set with the Mac idle at another rate, and the Mac
   should then follow. This amends step 3: with the patch alone, an idle Mac
   at 48 after a Dante set to 44.1 reads 48, the owner refuses and asks the
   arbiter for 48 (`source=usb`), and rate8's retry moves the endpoint back
   once the 30 s reversal guard lifts: a tug-of-war the Mac would win. Two
   parts are needed:
   - **The guard (with the patch, required).** At each Dante-sourced move the
     arbiter records the host's rate as it read it (`rate-history.json` gains
     `host`). A later `source=usb` request for that same rate is refused while
     the controls still show it, with "the Mac has not changed since the Dante
     set; waiting for it to follow". A Mac that is set again (a new SET_CUR to
     a different rate) is a new choice and wins as now. The 5 s host wait in
     `validate_rate` is dropped for `source=dante`. Small change in
     `usb16x16-apply` with tests beside `test_dante_apply.py`; the owner is not
     changed (its retries are refused cheaply). Until the Mac follows, the USB
     half stays closed: USB audio never plays at a rate the two ends disagree on.
   - **Making the Mac follow (experiment, after the patch is accepted).** The
     gadget already has the means: `f_uac2.c` has an interrupt endpoint and
     `afunc_notify(agdev, unit_id, cs)` (used today for volume and mute
     changes made on the Pi), and it answers the Mac's GET_CUR on the clock
     from `u_audio`'s `srate`. A second patch would add a writable control
     (for example `Device Rate Request`) that stores the new rate as `srate`
     and sends the clock source's SAM_FREQ interrupt, as an interface does
     when it follows external clock; the arbiter writes it after a Dante move.
     Whether macOS (AppleUSBAudio) re-reads the clock and changes its nominal
     rate on that interrupt is unknown and is the experiment's question, run
     with the bounded test (`test-rate-report.sh` pattern) before anything is
     installed. If macOS ignores it, the fallback is on the Mac: Dante
     Switcher (which already sets the USB 16x16) or a small agent that follows
     the Pi's rate from `/api/health`.
2. **Suspend: keep the rate if it works.** As planned; B3 checks a sleep and
   wake, and if the rate comes back wrong the forget moves to
   `afunc_suspend` too.
3. **Trace: done** (above).

**Order from here.** (a) The report patch, build, bounded test, installer and
battery as in steps 2-6, with B5 changed: a Dante-side set with the Mac idle at
48 is accepted, then the guard is checked (the owner's `source=usb` asks for 48
are refused, the endpoint stays at 44.1, the USB half closed) and the Mac is
set to 44.1 by hand (the half opens, no arbiter move). The guard ships in the
same step as the module, since the module alone causes the tug-of-war. (b) The
Mac-follow experiment as its own plan section once (a) is accepted.

## Built (2026-10-28, evening)

**Step 2 and 4 DONE.** `uac2-rate-report-6.18.34.patch` (f_uac2.c +1 line,
u_audio.c, u_audio.h) as specified in step 2, with `set_srate()` and
`forget_srate()` as the two helpers. Built on the Pi by `build-rate-report.sh`
in `~/usb-16x16-work/gadget-ratereport/build/` (no root, the kernel tree only
read):

- Provenance: the tree's `f_uac2.c` is the shared-clock source only; the label
  source is `f_uac2.c.before-shared-clock` plus the two committed patches, and
  the control build of exactly that **reproduces the installed label module
  byte for byte** (87989337, srcversion E40AF448...). The control `u_audio.ko`
  (d93a088c, srcversion 773071F7...) differs from the stock in-tree one
  (srcversion 0F2DD68C...): an out-of-tree build, same source file.
- Candidate: `u_audio.ko` **b2f5c6cd**7c4e25a0d62f6e603ce974b598a269688a3ef79db8c884c7994b4446
  (srcversion DD2DD5108A06E3270F336AF), `usb_f_uac2.ko`
  **fa8bed12**4e6755695f056a24b448d2fda0027ef1e19fe2fa512533eb3db1f093
  (srcversion C647475B059D8F6DB983CED), vermagic 6.18.34+rpt-rpi-2712, no
  warnings. The exported CRCs of every existing `u_audio_*` symbol equal the
  kernel's Module.symvers; the only addition is `u_audio_forget_srate`
  (0x9093d4c9).

**Step 5, the bounded test, staged:** `test-rate-report.sh` (7cb4bf6c) beside
the build. It pins both candidates, the installed label module, the stock
`u_audio.ko.xz`, both setup scripts and the loaded srcversions; stops
`usb16x16-dante` and the gadget, swaps the modules by `insmod`, starts both
again, holds the window, and restores by `rmmod` + `modprobe` (on the window's
end, Ctrl-C, or `touch /dev/shm/rate-report-test.end`). Writes nothing under
`/lib/modules`. Not run.

**The arbiter guard, written and Mac-tested:** `usb16x16-apply` 1.6.0
(c3c14505; installed is 1.5.0 4a4aef82). `validate_rate`: a `dante` or `page`
change is taken even when the Mac stays at another rate through the 5 s wait,
and that rate goes into `rate-history.json` as `overrode`; a `usb` request for
the `overrode` rate is refused ("the Mac has not followed yet") until the
owner's journal for the running start has `USBOPEN ... host_rate=match`
(`mac_followed`), which is the owner joining the Mac at the new rate. A `usb`
request with the Mac at a third rate is refused as before. Tests:
`test_a_dante_set_overrides_the_mac_and_waits_for_it_to_follow`,
`test_a_mac_request_the_mac_no_longer_agrees_with_is_refused`,
`test_a_host_with_no_known_rate_overrides_nothing` replace
`test_the_mac_decides`; 46 pass, and `test_apply`, `test_web`,
`test_dante_web`. Known limit: "followed" is read from the running start only,
so after a restart for another reason, a Mac that had followed and then went
back to the overridden rate is refused until a Dante-side or page change; the
operator can set the rate from the Dante side then.

Next: the bounded test (operator's sudo), then `install-rate-report.sh` (the
modules and applier 1.6.0 together, each with its rollback) and the battery.

## Bounded test (2026-10-28 23:22-23:26 UTC): PASSED

`test-rate-report.sh build/rate-report 600` (7cb4bf6c), operator's sudo; ended
early with the end file. Evidence `outputs/latency/rate-report-bounded-20261028/`
(`journal.txt`, the endpoint, arbiter and gadget units; times there are EDT)
and the two noise probes named below. Owner rate8 and applier 1.5.0 as
installed; no Dante-side set was made.

- Load: candidates in at 23:22:32 (srcversions DD2DD510... / C647475B...), USB
  configured/high-speed, `usb16x16-dante` started.
- After enumeration, nothing open on the Mac: controls **48000/48000** (the Mac
  sends its rate at enumeration; the stock module reads 0 here). The owner
  opened with `host_rate=match`.
- B1 + B4, Mac idle, 48 -> 44.1 at 23:22:52: controls 44100 within 2 s; the
  owner (half open) logged `USBRATE changed ... while open`, handed the half
  back, refused the reopen and asked for 44100; the arbiter `done` and the owner
  restarted at 44100 by 23:22:56 and opened with `host_rate=match`. **A Mac-side
  change with no app open moved the endpoint in about 4 s.**
- Back, Mac idle, 44.1 -> 48 at 23:24:36 (past the 30 s guard): `done`, owner
  at 48000, `host_rate=match`, by 23:24:40.
- B2: the hold client open reads 48000; closed, it still reads 48000/48000
  (the stock module drops to 0 at once).
- Noise probe at 32 on the candidates: clean
  (`ratereport-candidate-noise-ch2-32f-20261028T232528Z`: no zero runs, no xrun
  lines).
- Restore at 23:26:38: stock `u_audio` 0F2DD68C... and label `usb_f_uac2`
  E40AF448... loaded, configured/high-speed, endpoint active, nothing under
  `/lib/modules` changed (87989337, 8e9907d3 only); start check ok 23:27:42;
  idle controls 0/0 again; owner.conf at 48 (no `RATE=`); noise probe at 32
  clean (`ratereport-afterrestore-noise-ch2-32f-20261028T232742Z`). Mac at 48000.

Not covered: B3 (disconnect needs a cable pull or Mac reboot; restarting the
gadget unit builds a new function instance and would prove nothing), B5/B6
(need the guard, applier 1.6.0, installed), B7 (the full battery).
Next: `install-rate-report.sh` (modules and applier 1.6.0 together, each
with its rollback), then B3, B5, B6 and B7 on the installed set.

## Installer staged (2026-10-28)

`install-rate-report.sh` (a4de9995), staged in
`~/usb-16x16-work/gadget-ratereport/` with the applier copy `usb16x16-apply`
(1.6.0, c3c14505) beside `build/rate-report/`. Not run.

- `install`: pins the kernel, both candidates, the applier copy, the installed
  label module (87989337) and applier 1.5.0 (4a4aef82), the stock
  `u_audio.ko.xz`, both setup scripts and the loaded srcversions; refuses while
  an AES67 candidate, `test-rate-report.sh`, or an apply or rate operation
  (`usb16x16-apply.service`, `usb16x16-dante-rate.service`) is running. Keeps
  `updates/usb-16x16/usb_f_uac2.ko.pre-rate-report` and
  `/usr/local/bin/usb16x16-apply.pre-rate-report` (0644); stops the endpoint
  and the gadget; `rmmod`; writes `updates/usb-16x16/u_audio.ko` and
  `usb_f_uac2.ko` and the applier by temp-and-rename; `depmod`; `modprobe`;
  requires the candidate srcversions, configured/high-speed in 20 s and, if
  the endpoint was running, its start check `ok` for the new start within
  150 s. Any failure puts all three back.
- `rollback`: refuses unless both kept files verify and the installed module
  and applier are one of the two known versions; removes the patched
  `u_audio.ko`, restores the label module and applier 1.5.0, `depmod`,
  reloads, requires the stock srcversions, healthy USB and the start check.
- `status` (no root): hashes on disk, which pair is loaded, USB state, the two
  controls, the endpoint.

Install command (operator's sudo):
`cd ~/usb-16x16-work/gadget-ratereport && sudo ./install-rate-report.sh install`.
Then B3, B5, B6, B7 on the installed set.

## INSTALLED 2026-10-28 (start check ok 23:40:15 UTC); B5 passed

`sudo ./install-rate-report.sh install` (a4de9995) by the operator: `u_audio.ko`
b2f5c6cd and `usb_f_uac2.ko` fa8bed12 under `updates/usb-16x16/`,
`usb16x16-apply` 1.6.0 c3c14505; kept `usb_f_uac2.ko.pre-rate-report`
(87989337) and `usb16x16-apply.pre-rate-report` (4a4aef82). Loaded pair
DD2DD510.../C647475B..., configured/high-speed, idle controls 48000/48000.
Evidence `outputs/latency/rate-report-installed-20261028/` (`b5-journal.txt`,
times EDT; `idle-controls-20min.txt`, 2,353 reads 23:58-00:18 UTC, all
configured at 48000/48000 with nothing open on the Mac).

B5, Mac idle at 48, Dante-side set to 44.1 (`set-rate-one.py 169.254.92.97
44100`, 23:51:44):
- taken over the Mac's 48 (the 5 s wait, then `done`); endpoint at 44.1 by
  23:51:50; `rate-history.json` `overrode` 48000;
- the owner: `USBRATE refused host 48000 rate=44100`, requests for 48000 at
  10, 20 and 40 s (rate8); the arbiter refused them with "the Mac has not
  followed yet", also past the 30 s reversal window: no tug-of-war, the USB
  half closed;
- Mac set to 44.1 by hand (23:53:34): `USBRATE cleared`, `USBOPEN ...
  host_rate=match` at once, no restart;
- Mac back to 48 (23:53:49): a new choice (the owner had joined at 44.1),
  `done`, owner at 48000, `host_rate=match`, by 23:53:53.

Still owed: B3/B6 (a cable pull; two loggers ran 4 and 20 minutes without one),
B7 (four loaded 800-impulse runs, the ten-minute soak, bitexact, one loaded run
at 44.1, labels). Rollback: `sudo ./install-rate-report.sh rollback`.

## B3 and B7 on the installed set (2026-10-29 00:29-01:08 UTC)

**B3: the Pi never sees an unplug.** Two cable reseats by the operator
(00:29:51 and 00:32:18 UTC, `dwc2 ... new device is high-speed` in the kernel
log). A 0.5 s logger across the second (`b3-controls.txt`, 1,764 reads
00:30:40-00:45:39) read `configured` and 48000/48000 throughout: the gadget's
dwc2 (peripheral mode, the Pi on PoE) has no VBUS sense, so a pulled cable
is not a disconnect; only the replug's bus reset is seen. That reset runs
`afunc_disable` (and the forget), and the Mac sends its rate again within
milliseconds of enumerating, too fast for the logger: **the forget is not
observed**. A kprobe on `u_audio_forget_srate` (operator's sudo) would show it.
Consequence: while the cable is out the controls keep the Mac's last rate
(the stock module does too if the Mac was streaming when pulled). Under the
operator's rule this blocks nothing: a Dante-side set is taken regardless,
and the guard refuses the Mac's old rate until the owner joins the Mac. The
endpoint rode through both reseats (no USBCLOSE, no faults, no restart).

**B7 (`b7.log`).** Four loaded 800-impulse runs at 32, clean on the Pi (no
xrun, lag or error lines): 329 (two levels, 323 x389) / `daw_timeline` 481,
372 / 524, 359 / 511, 335 / 487. Run 2 is 7 samples above the
point of record's 330-365 (480-515); the level is drawn per USB open and the
patch does not touch the data path.
Soak 1 (00:47:29): FAIL on a Mac-side skipped IO cycle (discontinuities 1/1,
a 36-sample run on all 16 channels together): rerun by the rule.
Soak 2 (00:57:57): **FAIL, a 32-sample zero run on 12 of 16 channels (not 2,
4, 8, 12), no Mac discontinuity**, no xrun, lag or error lines; the owner's
cumulative counters did not move during it (`out_holes` 2/36, `back_holes`
3/36, `playback_faults` 1, `tx_lost` 22 all from before 00:57). Unexplained;
32 frames is one Mac IO buffer. Not ACCEPTED: owed a clean soak (with an eth0
capture of the Dante flows if it repeats, `diag/dante-pcap-zeros.py`),
bitexact (monitors muted), one loaded run at 44.1, and the labels.
