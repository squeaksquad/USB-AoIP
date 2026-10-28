# The gadget reports the Mac's last set rate (plan, 2026-10-28)

Status: plan only. Nothing is built, staged or installed; the Pi was only read.
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
`u_audio.ko.xz` (dde02c49), `setup-usb-16x16` (d3031e22) and
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
