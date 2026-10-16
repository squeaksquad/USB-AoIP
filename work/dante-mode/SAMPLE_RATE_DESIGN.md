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
