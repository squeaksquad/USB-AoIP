# Sample rate from either end: design

2026-10-16. Design only; nothing built, nothing installed.

Goal (operator, 2026-10-16): the Dante endpoint's sample rate can be set
from Dante Controller's Device Config tab *and* from the Mac (Audio MIDI
Setup / the DAW), and whichever end changes it, the other end follows.
Today both are fixed at 48 kHz: Inferno reads `SAMPLE_RATE "48000"` once at
start, the gadget offers only `c_srate=p_srate=48000`, and the owner refuses
any other rate (`owner/main.cpp`, `kRate`).

## What already exists

Dante side, from reading Inferno 9767558e and netaudio (chris-ritsen/
network-audio-controller, Unlicense, read 2026-10-16):

- Board info (`info_mcast_server.rs`, `send_board_info`) carries capability
  flags. Byte `0x17` is commented "Identify device, Sample rate & encoding
  configuration, Reboot, Factory reset (was 0xdb)"; Inferno sends 0. This
  is most likely what greys the dropdown out. Which bit is "sample rate"
  is not known: the device Inferno copied had `0xdb`.
- Rate status is a conmon publication, opcode `0x0080`, on the
  control/monitoring multicast: content
  `0018 | count:u16 | current:u32 | 0:u32 | 00020000 | rates:u32[count]`.
  Inferno has it written out but commented ("probably response to
  0738008100000064"); netaudio's virtual device sends it
  (`publications.rs`, `PublicationBody::Audio`).
- Rate query and set are settings packets (protocol `PROTOCOL_SETTINGS`)
  sent to the device's settings port (8700, which Inferno's
  `info_request_port` socket owns): body `0000 | device_id[8] | "Audinate"
  | sep | suffix | kind:u16=0x0081 | 100:u32 | mode:u32 | value:u32`, mode 0
  query, mode 1 set. netaudio sends a set with suffix `0x27` and
  pseudo-MAC `"RT"0000`. Inferno's `run_server` sees these today and logs
  them as `unknown request to multicast port` with the raw payload, so the
  real Dante Controller's packet can be read from the owner's journal with
  no capture.
- ARC opcode `0x1100` ("device settings"; `0x1101` is its set) is answered
  with 110 zero bytes. netaudio parses a sample rate out of the real reply,
  so Device Config may read this too.
- Encoding (`0x0082`/`0x0083`) and latency (ARC set) have the same shape;
  out of scope here, but the work makes them cheap later.

USB side, read from the Pi 2026-10-16 (read-only):

- Kernel 6.18.34. `f_uac2` there takes a comma list in `c_srate`/`p_srate`
  and exposes the host's choice as the ALSA controls `Capture Rate` and
  `Playback Rate` on card `UAC2Gadget` (0 while the host has the
  interface down). The owner can therefore *see* a Mac-side change.
- The gadget cannot *make* the Mac change. A UAC2 device reports its
  clock's current rate (GET_CUR), but the host decides; whether macOS
  adopts the device's reported rate on re-enumeration is not known.
- The gadget and its module are the protected baseline. A multi-rate
  gadget is a new setup script under a new name, never an edit to
  `setup-usb-16x16`.

What is rate-bound downstream (every place that assumes 48 kHz must either
follow the rate or refuse cleanly):

- The owner: `kRate`, its period and queue depths in samples
  (`transport.conf`'s `RX_QUEUE=96` is 2 ms at 48 kHz, 1 ms at 96 kHz).
- DSP: biquad coefficients and delays are computed for 48 kHz in
  `work/dsp-compiler` (`coefficients.mjs`, `compile.mjs`,
  `bridge-artifact.mjs`); the artifact must carry its rate and the owner
  must refuse one that does not match.
- Meters (window lengths), the start check (it judges a flow by its
  received audio frame rate), `diag/dante-pcap-zeros.py`, the harness.
- The Ferrofish and every other device in the Dante domain: a rate change
  on the Pi alone breaks its subscriptions until they match. That is
  normal Dante behaviour and Controller shows it; it is not ours to fix.

## Shape

One arbiter on the Pi owns the rate. Neither surface changes anything
directly; each one *asks*:

```
 Dante Controller --set 0x0081--> Inferno (in owner) --request--> arbiter
 Mac (AMS / DAW) --SET_CUR-----> gadget "Capture Rate" --watch--> arbiter
                                                                    |
            stop owner -> rewrite rate in owner.conf/Inferno conf ->
            recompile/refuse DSP -> (gadget re-enumerate if needed) ->
            start owner -> publish 0x0080 + board info at the new rate
```

- The arbiter is a small root service beside the start check, driven by
  a spool like the applier's (a request file under `/run/usb16x16-dante/`),
  so Inferno never needs privilege: the owner process only writes the
  request, the arbiter does the restart. It may simply be a new request
  kind in `usb16x16-apply` (`rate`), which already rewrites `owner.conf`
  and restarts the unit.
- Rates offered: every Dante rate (operator, 2026-10-16): 44.1, 48,
  88.2, 96, 176.4, 192 kHz. The last two depend on step 5: sixteen 24-bit
  channels at 192 kHz is 1,152 bytes per microframe, above one high-speed
  isochronous transaction, and on what the Ferrofish carries at that
  rate. Each needs its own battery before it
  is offered; until then the offered list is the measured list, which on
  day one is `[48000]`.
- A change is a full endpoint restart, the same cost as a profile switch.
  No live rate change, ever.

### Mac-initiated change

Gadget offers all rates. The Mac sets one; the gadget's `Capture Rate`
changes; the owner (which already holds the gadget card) sees it, keeps
its USB half closed, and asks the arbiter for that rate. Endpoint
restarts at the new rate; Controller sees the new `0x0080`.

### Controller-initiated change

Inferno receives `0x0081` mode 1. The owner acks and asks the arbiter.
Endpoint restarts at the new rate. The Mac is still at the old rate, and
there are two ways to bring it along, to be decided by experiment (step 5):

- (a) Re-enumerate the gadget with the new rate as its clock's current
  value and let macOS adopt it, if it does.
- (b) Re-enumerate with the new rate as the *only* rate offered, so the
  Mac has no other choice; offer the full list again on the next
  re-enumeration. Cost: while in (b), the Mac cannot change the rate.

A Controller change is a transaction (operator, 2026-10-16: the Pi refuses
a change if anything does not work). The arbiter keeps the old rate, tries
the new one, and commits only when every stage confirms it: Inferno up at
the new rate, the DSP artifact for that rate loaded, the gadget
re-enumerated and `Capture Rate`/`Playback Rate` reading the new rate
within a timeout. Any stage failing puts the whole stack back at the old
rate, re-sends `0x0080` with the old rate (which is how Controller learns
of the refusal) and records why in the page's status. USB audio is never
played at a rate the two ends disagree on.

### Who wins

Last writer wins, with the arbiter serialising: a request that arrives
while a change is in progress waits and is applied after it, if it still
differs. A change that would be undone at once by the other end (the Mac
re-asserting its old rate after (a) fails) is detected by the arbiter
seeing the opposite request within N seconds of finishing, and it stops
and reports instead of looping.

## Steps, each with its check

1. **Read Controller's packets.** Candidate Inferno with board-info byte
   `0x17` bits set one at a time and the `0x0080` publication sent with
   `[48000]`. Check: Device Config's dropdown enables and shows 48 kHz;
   picking 48 kHz again makes the owner log the raw `0x0081` set packet.
   No rate ever changes in this step. Hand-run through the candidate
   launcher with the service stopped, then put back.
   Written 2026-10-16, not yet built: `patches/0004-sample-rate-status.patch`
   (config keys `SUPPORTED_SAMPLE_RATES`, `BOARD_FLAGS_17`; a set is logged
   and answered with the unchanged status), built by
   `build-patched.sh xrun-option-retry1-confirm-rate 0001 0002 0003 0004`,
   run with `config/asound-inferno-owner-both1ms-rate.conf` (the installed
   config plus `44100,48000`, `db`, and DEVICE_ID `88a29e8b01e40000` with
   STATE_ID the old ID). DONE 2026-10-16, RESULTS.md "Sample rate, step 1":
   Controller and netaudio both read the rate and send a set; netaudio
   needed a DEVICE_ID it can decode as a MAC. The patch already answers as
   step 2 describes, except that 44.1 is offered and refused.
2. **Answer at 48 kHz only.** Inferno patch `0004`: board flag, `0x0080`
   publication (at start and on any query), `0x0081` query answered, set
   to the current rate acked, set to anything else refused (logged,
   status re-sent). Optional: fill `0x1100` with the rate if step 1
   shows Controller reads it. Check: Controller shows 48 kHz locked; a
   battery and noise probe show no change to the audio path. Installable
   on its own, useful on its own (the "is everyone at 48k?" check becomes
   visible in Controller).
   2026-10-16: the form is plugin d3a6b40a with
   `config/asound-inferno-owner-rate48.conf` (flags 0x18, 48000 only, the
   MAC-form DEVICE_ID); candidate battery and hour PASS, 356 / 544;
   `service/install-dante-rate-status.sh`; INSTALLED and ACCEPTED 2026-10-16
   (355 / 543 in service).
3. **Make the stack rate-aware at 48 kHz.** Owner takes `--rate`
   (default 48000) instead of `kRate` and checks the gadget's rate
   controls; DSP artifact carries its rate and the owner refuses a
   mismatch; start check, meters and diag tools take the rate. Check:
   the existing tests plus new ones; battery at 48 kHz unchanged.
   DSP follows the rate automatically (operator, 2026-10-16). The
   compiler is JavaScript and the Pi has no node, so the page compiles
   each preset at every offered rate when it is saved or applied and the
   store keeps one artifact per rate; the arbiter picks the one for the
   new rate. A preset with no artifact for the requested rate makes the
   change refuse, never fall back silently.
   2026-10-16: written and Mac-tested, nothing built on the Pi (RESULTS.md,
   "Sample rate, step 3"): owner `--rate` and `owner/rate_check.hpp` (the
   gadget's rate controls read before each open), `DspStage::load(text,
   rate)` refusing another rate, the compiler and `compileDraftRates` per
   rate, the start check's `--rate`, the pcap tool reading the rate from
   the capture. 48 kHz artifacts byte-identical to before. Owed: the owner
   built on the Pi with the service stopped and the 48 kHz battery.
   2026-10-17: candidate owner 6068cfd3 (step 3 + the unity-skip core) built
   on the Pi; battery and loaded hour PASS at 48 kHz direct, 363 /
   `daw_timeline` 551 on its anchor; the gadget-rate check read
   `host_rate=match` and, after a gadget restart, `unknown` as designed.
   Not installed (RESULTS.md, 2026-10-17 04:43).
4. **The arbiter at 48 kHz.** `rate` request kind in the applier (or a
   separate service), wired from the owner. Check: a set to 48 kHz from
   Controller round-trips through the arbiter and restarts nothing (no
   change); a set to 96 kHz is refused because 96 is not yet offered.
5. **Multi-rate gadget, and the macOS question.** New setup script
   (`setup-usb-16x16-multirate`, distinct name, its own rollback to the
   protected one) offering 44.1/48/88.2/96. Answers by experiment: does
   the Mac pick the device's current rate on enumeration (decides (a)
   versus (b))? does Audio MIDI Setup's change show up in
   `Capture Rate`/`Playback Rate` as expected? does a 16-channel
   24-bit gadget at 96 kHz hold without drops at 32 frames (bandwidth
   doubles; the req_number lesson applies)?
6. **One more rate, end to end.** Probably 96 kHz: DSP compiled at 96,
   Ferrofish at 96, a full battery and an hour. Then 44.1 and 88.2 the
   same way. Each rate joins the offered list only after its battery.
7. **Both directions live.** Arbiter acts on Mac and Controller requests.
   Check: each direction changes the other end; the loop guard stops a
   tug-of-war; a reboot comes back at the last rate.

Steps 1 and 2 touch only Inferno; 3 and 4 change nothing audible; the
protected gadget is untouched until step 5, and then only by a parallel
setup script.

## Open questions for the operator

Answered 2026-10-16 (operator): (1) all rates matter; (2) yes, a change is
allowed with a DAW session open, it drops out; (3) the Pi refuses the
change if any part does not work (the transaction above); (4) presets
recompile automatically (one artifact per rate, above); (5) yes, (b) is
acceptable if (a) fails. The text above is written to these answers.

1. Which rates matter? If only 48 and 96, step 6 is half the work.
2. Should a rate change also be allowed while a DAW session is open on
   the Mac (it will drop out), or only from an idle Mac?
3. When Controller changes the rate and the Mac does not follow, is
   silence on USB with a page warning acceptable, or should the Pi refuse
   the Controller change instead?
4. The DSP presets: recompile automatically at the new rate (the compiler
   runs on the Mac / in the browser today, not on the Pi), or fall back
   to direct until a preset is re-applied?
5. Option (b) (offer only the new rate after a Controller change) locks
   the Mac out of rate changes until the next re-enumeration. Acceptable
   if (a) fails?

## Transparent switching, and DSP that keeps up at every offered rate (plan, 2026-10-16)

Operator, 2026-10-16: switching rates must be transparent to the user, and
the DSP must keep up without issue. This section is the plan for that. It
keeps steps 1 to 3, revises 4 to 7 and adds DSP steps. Design only; nothing
here is built.

### What "transparent" means here

The user changes the rate in one place, the way they already do (the DAW
session, Audio MIDI Setup, or MIOConsole3d on the Metric Halo). After a
dropout of a few seconds, every device is running at the new rate: the Mac's
USB 16x16 device, the Pi, the Ferrofish and the rest of the Dante domain,
with the same DSP preset compiled for the new rate. The user does nothing
else: no Dante Controller, no page, no re-applying a preset. If any part
cannot follow, nothing changes on the Pi: it stays at the old rate, and the
user is told why in one line (a Dante Switcher notification and the page).

A rate change is never silent. Every Dante device re-clocks, and the Pi's
endpoint restarts (no live rate change, as above). The target is audio back
within about 10 s of the change. That is the one measured restart
(subscriptions back 5 to 18 s after a device returned, RESULTS.md part 2),
plus the extra start the start check forces about one time in three or four.

### One source of truth: the Mac

Most of the machinery already exists, on the Mac.
`~/Development/Dante Switcher` (its PLAN.md, 2026-10-16; its own private
repository since 2026-10-17, `github.com/squeaksquad/dante-switcher`) is a menu-bar agent
that follows the Metric Halo's rate (CoreAudio listener, a 2 s debounce)
and sets every Dante device's rate with the same `0x0081` settings packet
Controller sends: the Pulse (the leader) first, a wait for its word clock
to lock, then everyone else. It already lists the Inferno device as a
target, and patch 0004 is what lets the Pi report a rate and receive that
set.

The plan rests on that agent:

1. **The Mac decides; the Pi follows or refuses.** The Pi's arbiter accepts
   a rate only when the USB host is at that rate, or the host has the
   interface down. A Controller set to a rate the Mac is not at is
   refused: the status is re-sent at the old rate, so Controller shows it
   snap back. This drops the gadget re-enumeration of "Controller-initiated
   change" (options (a) and (b)) altogether. The gadget never has to push a
   rate onto macOS, which it cannot do reliably, and it is never
   re-enumerated for a rate change.
2. **Dante Switcher sets the USB 16x16 too.** Beside the Dante devices it
   sets the USB 16x16's `kAudioDevicePropertyNominalSampleRate` through
   CoreAudio. That is a UAC2 SET_CUR to the gadget, which the Pi sees as
   `Capture Rate` / `Playback Rate`. It should also watch the USB 16x16 as
   a rate source beside the Metric Halo, because a DAW session that uses the
   USB 16x16 sets that device's rate, not the Metric Halo's. This is a
   change to that project, not to this one (open question 1).
3. **The arbiter makes one restart from two signals.** For one user change
   the Pi gets a Dante `0x0081` set and a gadget rate change, in either
   order and up to a few seconds apart. The arbiter treats the first as
   "rate R wanted", waits up to a settle window (default 5 s) for the
   other to agree (or for the host to read 0), and then restarts once.
   The two disagreeing past the window is a refusal. "Who wins" above stays
   as the guard for a tug-of-war.

### The sequence on the Pi

```
 0x0081 set R  ──┐
                 ├─> arbiter: R offered? preset has an artifact for R that fits
 gadget rate R ──┘   the DSP budget? transport settings for R? host at R or idle?
                       │ no ──> refuse: status re-sent at old rate, reason on the page
                       │ yes
                       v
   write rate R: owner.conf RATE, Inferno SAMPLE_RATE, artifact path for R
   restart the endpoint: owner --rate R loads the R artifact before any open
                       │
   verify within T: Inferno publishes R; DSP loaded rate=R; USBOPEN host_rate=match
   (or host idle); start check state=ok at R
                       │ any fails ──> write the old rate back, restart, refuse
                       v
   commit: the rate is persisted, so a reboot comes back at R
```

Nothing is compiled during a change. Every artifact the change needs was
compiled when the preset was saved (next section), so the DSP part of a
change is loading a file, which takes milliseconds. An uncommitted live
edit is dropped by a rate change: the endpoint comes back on the committed
preset at the new rate, and the page says so.

### DSP: one artifact per rate, all six, at save time

- The page compiles each preset at **all six Dante rates** when it is saved
  or applied, not only the offered ones (`compileDraftRates` with
  `DANTE_RATES`). It costs six small artifacts per preset. A rate that is
  offered later then never finds a preset without its artifact, and no
  compiler is needed on the Pi, which has no node.
- The store keeps `/etc/usb16x16/dsp/<slug>@<rate>.dsp`, each with its own
  hash. `owner.conf` keeps naming the preset (`DSP_PRESET` for the slug,
  `DSP_SHA256` per rate), and the start wrapper picks the file for `RATE`.
  A rate with no artifact is a refusal, as step 3 says. The applier's
  48 kHz-only check becomes "the artifact's rate is the rate it is filed
  under".
- A live edit compiles at the running rate only, for the preview. Commit
  compiles all six.

### DSP: keeping up

What is measured, all at 48 kHz on the owner's loop thread (RESULTS.md
2026-10-11): the loaded preset (308 biquads) costs `dsp_us_mean` about 95 µs
for each 1 ms of audio, and `dsp_us_max` 169 in a 180 s run. The
transparent preset (256 biquads) over an hour: mean 80, worst minute 93,
max 150, and 300 once. The work is per frame, so it scales with the rate.
Extrapolated, **not measured**, as a share of one core's real time:

| Rate | Mean (loaded) | Typical max | Worst seen, scaled |
|---|---|---|---|
| 44.1 / 48 kHz | 9-10 % | 17 % | 30 % |
| 88.2 / 96 kHz | 19 % | 34 % | 60 % |
| 176.4 / 192 kHz | 38 % | 68 % | 120 % (misses the deadline) |

MEASURED 2026-10-17 (RESULTS.md, "Sample rate, step 4b"): the table above
was pessimistic. On the Pi the stage's arithmetic alone, heaviest preset, is
7 % of the period at 48 kHz, 15 % at 96, 29 to 33 % at 192 (median to max),
linear in the rate. With conversions and meters scaled the same way, about
25 to 30 % at 96 kHz and 50 to 55 % at 192 kHz before the loop's other
work. The worker thread (item 4) is probably not needed; an owner run at
192 kHz decides.

So 96 kHz probably fits as things are, with less margin than anything
accepted so far, and 192 kHz does not fit on the loop thread. The plan, in
order of risk (least first). Each item is a change on its own with its own
check:

1. **Measure before changing anything.** `usb16x16-dsp-offline --rate R
   --bench N` on the Pi, service stopped, for `transparent`, `loaded` and
   a worst-case 16 x 16-band preset at each rate. That gives the cost per
   section-frame that the admission rule below needs, and replaces the
   table above with numbers.
2. **Skip unity sections.** A user preset is the fixed shape: 256 band
   slots, most of them unity. When a coefficient set is built (at load and
   at each publish, on the control thread), the stage marks which sections
   are exactly unity. The audio thread runs those as a history shift (x1,
   x2, y1, y2 updated, no arithmetic). That keeps filter state exact, so a
   band switched on live does not click. Output is bit-identical (unity is
   y = x). Expected to cut a typical preset's cost by more than half. The
   check: the existing DSP tests, the CamillaDSP head-to-head
   (`run-headtohead.sh`) unchanged, and the bench.
   2026-10-17: written and Mac-tested (RESULTS.md, "step 4c (first half)"):
   byte-identical output to the previous core, live switches included; the
   default preset 2.6 to 2.7 times faster on the Mac, a fully loaded one
   2 to 5 % slower. Pi bench and head-to-head owed. On the Pi that first form
   cost presets without unity 40 to 48 %; the corrected form (48f871e,
   running-section lists, sample by value) is exact and faster for every
   preset at every rate on the Pi: default 3.4 to 3.5 times, loaded 5 to 7 %,
   transparent 9 to 10 % (RESULTS.md, 2026-10-17 04:19). Head-to-head
   against CamillaDSP on the Pi (04:38): every figure identical to the
   pre-skip core and to September's, the fixed shape included.
3. **Two channels at a time.** Run the per-channel chains for output pairs
   as NEON double2. Each channel's arithmetic order is unchanged, so the
   output is the same sample for sample; the head-to-head harness proves
   it. Roughly 1.6 to 2 times.
4. **Only if 2 and 3 are not enough for 192 kHz:** a DSP worker thread on a
   core of its own. It is created with the other threads before the device
   opens (rule 3: never a thread after capture start). One block of
   pipeline costs one wake (about 1 ms) of added latency. Operator,
   2026-10-16: acceptable if it is what makes 192 kHz possible, and then
   **at every rate**, so the latency does not change with the rate (read as
   one pipeline everywhere; at 48 kHz that is about 1 ms on top of today's
   11.3 ms). It is a separate candidate with its own battery at 48 kHz as
   well as at 192 kHz, and it is the last resort because it adds latency.
   Decided by the bench (step 4b) and items 2 and 3: if they bring 192 kHz
   inside the budget on the loop thread, there is no worker and no added
   latency anywhere.
5. **Admission, so a rate never runs a preset that does not fit.** The page
   estimates each artifact's cost per rate (active sections x frames a
   second x the measured cost per section-frame from item 1). When saving,
   it shows per rate "fits" or "too heavy at 192 kHz". The arbiter refuses a
   change whose artifact is over budget, with the reason. The budget is
   what has been soaked: a rate's worst-case `dsp_us_max` share must stay
   under what 48 kHz has run accepted with (30 % of the period) until a
   battery at that rate says otherwise.
6. **Watch it in service.** `dsp_us_max` per minute against the budget is
   on the page. Going over is logged and shown, never silently degraded
   (no bypass, no direct fallback).

### Transport per rate

Queue depths and periods are frames (step 3), so at 96 kHz `RX_QUEUE=96` is
1 ms of margin instead of 2. `transport.conf` gains per-rate keys
(`RX_QUEUE_96000=...`). A rate without its own entry takes the 48 kHz figure
scaled to the same time. Each rate's figures come from its battery (step 6),
as 96 frames did at 48 kHz.

### What bounds the offered list

- **USB:** sixteen 24-bit channels at 192 kHz is 1,152 bytes a microframe,
  more than one 1,024-byte high-speed transaction, so the gadget needs a
  high-bandwidth endpoint, if `f_uac2` can do that at all (step 5).
- **The domain:** the D2USB stops at 96 kHz. The Pulse goes to 192 kHz.
  Dante Switcher already reports "unsupported" for each device.
- **DSP:** the table above.

Realistically the offered list is 44.1, 48, 88.2 and 96 kHz. 88.2 has a
macOS-side condition: nothing may start audio on the USB 16x16 for 10 s
after a switch to it, or macOS can pass only silence until the next change
(`work/pi-tuning/MULTIRATE_GADGET_PLAN.md`, "88.2 kHz and macOS"; Dante
Switcher holds that long). The arbiter's restart of the endpoint after an
88.2 change has to respect the same wait. 176.4 and 192
kHz only if the gadget, the domain and the DSP all clear them (the DSP by
items 2 and 3, or by the worker thread at every rate, as answered).

### Revised steps (1 to 3 as above)

4. **Arbiter at 48 kHz.** As before, plus the settle window that turns two
   signals into one restart, and the "Mac decides" rule. Check: a set to 48
   from Controller or Dante Switcher restarts nothing; a set to 96 is
   refused with the reason; the old rate is re-sent.
   2026-10-17: written and Mac-tested (RESULTS.md, "Sample rate, step 4"):
   the applier's `rate` kind with verify and rollback of owner.conf and the
   Inferno config together, Inferno patch 0005 (not compiled), the owner's
   `--rate-request-file`, the path unit, health reporting the rate. Not
   built on the Pi, not installed.
   INSTALLED 2026-10-17 17:12 UTC by the operator with steps 3 and 4d
   (owner c8b484ac, plugin c6b012ae with 0005, applier 1.5.0, web 1.6.0):
   battery and hour PASS, 345 / `daw_timeline` 533; a set to 48 restarts
   nothing and a set to 96 is refused. ACCEPTED 2026-10-17 (operator).
4b. **DSP bench at every rate** (DSP item 1). Mac code exists. A Pi run
   with the service stopped, the operator's go.
4c. **Unity skip, then NEON pairs** (DSP items 2 and 3), each a candidate
   with the head-to-head harness, the bench, and the 48 kHz battery and
   hour (no audible change allowed).
4d. **Per-rate preset store and admission** (DSP items 5 and 6): the page
   compiles all six, the applier files them by rate, the start wrapper
   picks by `RATE`.
   2026-10-17: the store written and Mac-tested, not installed (RESULTS.md,
   "step 4d"): `rateArtifacts` from page to web service to applier,
   `dante-<slug>@<rate>.dsp` beside the 48 kHz file, `RATE=` in owner.conf
   passed as `--rate`, the running rate's file switched to and pinned.
   Admission (the per-rate cost estimate) is still to do.
5. **Multi-rate gadget** (as before, protected gadget untouched). The
   experiment shrinks to: does a CoreAudio rate set reach `Capture Rate`
   cleanly, does the Mac re-open without the device vanishing, and does
   16 x 24-bit hold at 32 frames at 96 kHz. Re-enumeration on a Controller
   change is no longer needed.
6. **96 kHz end to end** (then 44.1 and 88.2): the domain at 96 via Dante
   Switcher, the full battery and an hour on the loaded preset, DSP inside
   its budget. Each rate joins `OFFERED_RATES` (page) and the arbiter's
   list only after its battery.
7. **Transparent, both ways.** Dante Switcher sets the USB 16x16 and the
   Pi, and the arbiter coalesces. Mac side written 2026-10-17 in
   `~/Development/Dante Switcher` (its PLAN.md, Phase 3 step 2): the USB
   16x16 is a CoreAudio target and a rate source, the Metric Halo follows
   first when it is not the source, and `dante-sync watch` follows a change
   that holds for 2 s; checked read-only, not run live. Check: a rate change in Logic, in AMS
   and in MIOConsole3d each brings the whole system to the new rate with
   no other action, audio back within the target, the preset in force at
   the new rate. A Controller set the Mac is not at is refused. A reboot
   comes back at the last committed rate.

### Open questions for the operator (this plan)

Answered 2026-10-16 (operator): (1) yes, Dante Switcher owns the Mac side,
setting and watching the USB 16x16; (2) yes, the Mac decides, replacing the
earlier answer (5): no gadget re-enumeration for a Controller change; (3)
yes, about 10 s per change is acceptable, rate changes are infrequent; (4)
192 kHz is worth a worker thread's 1 ms if that is what makes it possible,
provided the latency is the same at every rate (DSP item 4 above).

1. Dante Switcher becomes part of the path: it would set the USB 16x16's
   CoreAudio rate and watch it as a source beside the Metric Halo. Is that
   the right home for the Mac side (recommended: it already debounces,
   orders the leader first and verifies), or should the Pi do more?
2. "The Mac decides" replaces the earlier answer (5): a Controller change
   the Mac is not at is refused instead of forcing the gadget onto the new
   rate. Acceptable?
3. A dropout of about 10 s per change, longer when the start check retries:
   acceptable as "transparent"?
4. 176.4 and 192 kHz: worth a DSP worker thread (adds about 1 ms of latency
   at those rates only), or cap the offered list at 96 kHz?
