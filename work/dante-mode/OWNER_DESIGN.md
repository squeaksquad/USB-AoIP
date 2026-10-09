# Dante endpoint owner: design

Status 2026-10-09: design, with steps 1 and 2 passed; the owner itself is not
written. The operator accepted the plugin patch and running as root by hand
(questions 1 and 4). It is the plan for item 3 of the owed list in
[RESULTS.md](RESULTS.md) and replaces stage 4 of [PLAN.md](PLAN.md): the
process that takes over from the `alsaloop` prototype. Figures quoted from
RESULTS.md keep the conditions they have there. Anything marked *read* comes
from source and has not been measured.

## What it is

One long-lived process, `usb16x16-dante-owner`, that opens the Inferno device
once and keeps it running for as long as the process lives, and joins the USB
gadget to it whenever a host is streaming. It is the Dante identity (the
device in Controller exists while this process owns the PCM), the transport,
and the clock discipline. It replaces `alsaloop`, and on the Dante path it
replaces `usb16x16-rt-bridge`.

It is a separate executable, built from its own source under
`work/dante-mode/owner/` and linking `usb16x16_bridge_core` for what carries
over unchanged: the sample conversions, `WindowedLinearRegression`,
`SharedDriftEstimator`, `LevelServo`, `ZeroRunDetector`, and later `DspStage`
and `LevelMeter`. It is not a third mode of the bridge. The bridge's loop is
built on three things this endpoint forbids or does not have: a recovery that
drops and re-prepares both PCMs of a direction (`restart_direction`), a 1 ms
RAVENNA tick that every aligned start, trigger and prime is timed against,
and periods of 48 or 96. Threading "unless Inferno" through 3,500 lines would
put the accepted AES67 binary's source at risk for no shared code that the
core library does not already give. The accepted bridge and its pins are not
touched.

## What the design rests on

Measured (RESULTS.md): periods 32 and 64 and buffers 1024 and 2048 are
granted; the poll descriptor spins unless `snd_pcm_poll_descriptors_revents`
is called; capture overruns are not reported; unrouted capture channels are
not silence; threads are created in `hw_params` and replaced at every
`prepare`; a `prepare` with audio flowing costs about 5.7 s of returned audio;
the device's pointer runs at 48000 +/- 1 frames a second with or without
routes.

Read on 2026-10-09 for this design, not measured:

1. **alsa-lib decides nothing about xruns on an ioplug.** In alsa-lib 1.2.14
   (`src/pcm/pcm_ioplug.c` 57-90, 752-765) the only way an ioplug PCM enters
   `XRUN` is the plugin's `pointer` callback returning a negative value.
   There is no `stop_threshold` comparison. That is why the capture overrun
   went unreported (`avail` 4,833 on a 1,024 buffer): the plugin's pointer
   never returns an error for capture. For playback the plugin returns
   `-EPIPE` when the application pointer is behind the clock
   (`alsa_pcm_inferno/src/lib.rs` 268-286), and from then on every
   `avail_update` fails until `prepare`.
2. **The plugin already runs without reporting, for two seconds.** The same
   lines skip the `-EPIPE` while the pointer is under 100,000 frames since
   start (upstream's "workaround for pipewire"). So the unreported path is
   upstream's own code, exercised at every start.
3. **Entering `XRUN` stops nothing.** alsa-lib only sets the state; the
   plugin's `stop` is not called. The transmit thread keeps sending. The 5.7 s
   is entirely the `prepare` that a conventional recovery then calls, which
   stops and recreates the transmitter and loses the flows.
4. **A late write is not sent as zeros. It is sent as old audio.** RESULTS.md
   part 1 reads `flows_tx.rs` 162-173 as "missing samples are sent as zeros".
   That branch cannot fire for the ALSA plugin: its buffer is an
   `ExternalBuffer`, whose `unconditional_read()` is true
   (`inferno_aoip/src/ring_buffer.rs` 97-99, 393-396), so `read_at` always
   returns the full packet from wherever the timestamp lands in the mmap
   ring, written or not. Whatever the owner has not overwritten is the audio
   of one buffer length earlier: 21.3 ms at 1024 frames. A stalled owner
   therefore transmits an echo, not a hole. The part 1 sentence is corrected
   in RESULTS.md.
5. **The transmit thread reads ahead of the pointer.** Send latency is fixed
   at zero for the plugin (`flows_tx.rs` 512-520), so at each packet time it
   reads frames `next_ts .. next_ts + fpp - 1`, up to one packet ahead of the
   clock. The Ferrofish asked for 32 frames per packet; the code allows a
   receiver up to 256. The playback lead can never be under the packet size.
6. **Receive is written ahead by the latency.** A packet's samples are placed
   at their timestamp plus the receive latency (`flows_rx.rs` 229-230,
   314-315), so the frame at the capture pointer has had that long to arrive,
   and holes are closed with zeros by the receive thread itself.
7. **The pointer is a clock.** With `USE_FLOWS_CLOCK` off it is the media
   clock's sample count minus the start time, computed on each call, in both
   directions. `snd_pcm_delay` on the playback side and `avail` on the capture
   side are therefore sample-resolution readings of where the owner stands
   against the Dante clock, with no period quantisation.

## The two halves

The process is two halves that share one real-time thread and nothing else.

**The network half never stops.** From start to exit it does two things on
every wake: it keeps the Inferno playback pointer a fixed lead ahead of the
clock, and it consumes everything the Inferno capture has. Where the samples
come from and go to depends on the other half: the gadget when it is linked,
silence and the floor otherwise. No state of the USB side, and no error from
it, causes any call on an Inferno handle other than `avail_update`, `delay`,
`mmap_begin`, `mmap_commit` and `forward`. `prepare`, `drop`, `start` and
`close` on the Inferno PCMs are called at process start and exit only.

**The USB half comes and goes.** It is a state machine over the gadget's two
PCMs and its pitch controls:

| State | Entered when | Network half is fed | Leaves when |
|---|---|---|---|
| `absent` | no `UAC2Gadget` card, or an open fails | silence out, capture discarded | the card appears and both PCMs open |
| `idle` | PCMs open and prepared, host not streaming | silence out, capture discarded | gadget capture delivers frames |
| `priming` | first capture frames after `idle` | silence out; capture discarded | the two starting depths are set (below) |
| `linked` | primed | gadget capture out, Inferno capture to gadget playback | any gadget PCM error, or capture frozen for 100 ms |

Any gadget error in `linked` (the both-PCM XRUN pair a Mac device close
produces, a suspend, `-ENODEV` when `usb-16x16.service` is restarted) goes to
`idle` or `absent`: pitch controls back to 1000000, gadget PCMs dropped and
prepared (or closed), counters bumped, one `USBLINK` line. The network half
does not notice beyond its source turning to silence. This is the lifetime
rule PLAN stage 4 asked for, and it is also what makes host presence a
non-event: there is no storm to count and no `host_absent` to wait in.

Opening and closing the gadget PCMs and the control handle is done by a
steward thread created at start, not on the real-time thread: `snd_pcm_open`
parses ALSA configuration from the SD card. The two threads hand the handles
over through one atomic state word; only one of them touches a handle at a
time. `drop` and `prepare` on handles that are already open stay on the
real-time thread, as in the bridge. Their duration on the gadget has not been
measured in isolation; while they run the network half is late, which the
next section makes harmless.

## Running the Inferno device without ever preparing it

Three mechanisms. The first is a patch; the other two are the owner's.

**1. The plugin stops reporting playback xruns** (`patches/0001`): a config
key `XRUN_REPORT`, default `1` and identical to upstream; `0` logs the
underrun at `warn` and returns the pointer instead of `-EPIPE`, which is what
the grace window already does. It is the pinned tree plus that one option,
built as its own artifact with its own hash beside the stock one. Without it,
any stall of the owner longer than the lead is a six-second dropout with no
other way out.

**2. The owner resynchronises by moving its own pointer.** After a stall the
clock has passed the application pointer: playback `avail` reads more than
the buffer, by the deficit. The owner calls `snd_pcm_forward` by the deficit
(alsa-lib forwards an ioplug's application pointer without consulting the
plugin, `pcm_ioplug.c` 611-620) and then writes its lead as usual. Capture is
the same with the sign reversed: `avail` above the buffer means laps were
overwritten, the owner forwards to leave only the newest frames, and counts
the loss. Each is one `NETRESYNC` line with the frames lost. Neither creates
or destroys a thread, and the flows stay up.

**3. The owner keeps everything outside its lead zero.** Because of reading 4
the playback buffer must never hold old audio where the clock can reach it.
On every wake, the frames the clock has passed since the last wake, less a
guard, are cleared; so the buffer is zeros everywhere except from a guard
behind the pointer to the application pointer. A stall of any length then
sends silence, and a stall while unlinked sends exactly what would have been
sent anyway. The guard exists because the transmit thread may be reading a
packet it is late with (up to the 2 ms it tolerates); 256 frames to begin
with, of a 1024-frame buffer. Likewise the capture area is cleared once
before `start` (the unzeroed-buffer finding).

The lead is a setting, `--tx-lead`, in frames. Its floor by reading 5 is the
packet size plus the largest burst the gadget capture delivers in one wake
plus the owner's wake jitter: 32 + 48 + margin. First value 128; what a lower
one costs is measured.

## Where the depth lives

There is no ring. With both clocks' difference steered out at the gadget, and
with reading 7, each direction's elastic buffer is a device buffer the owner
can read exactly:

- **Out (Mac to Dante).** Gadget capture frames are converted and written
  straight into the Inferno playback buffer at the application pointer. The
  depth is the Inferno playback `delay`. `Capture Pitch` holds it at
  `--tx-lead`.
- **Back (Dante to Mac).** Everything the Inferno capture has is written
  straight into the gadget playback queue. The depth is the gadget playback
  `delay`. `Playback Pitch` holds it at `--rx-queue`.

Samples pass through `s24 -> float -> s32` and `s32 -> float -> s24` with the
core's converters, which are exact for 24-bit audio and are what the bridge's
0 dBFS behaviour was proven with; keeping float in the middle is what lets
`DspStage` and `LevelMeter` be dropped into the out direction later without
changing the path. Bit transparency through the owner is still proven end to
end, not assumed (step 6).

**Start depths are set, not drawn.** At `priming` the owner discards the
gadget capture's backlog, then on the next capture wake writes that block at
exactly clock + `--tx-lead` (a `forward` to the frame, possible because the
pointer has sample resolution), and writes `--rx-queue` frames of the newest
Inferno capture audio into the gadget playback queue, which starts it. If the
level still differs between starts after that, what is left is the Mac's
anchor and the gadget's own start, which is the question owed item 1 asks of
the prototype and which should be re-asked of the owner.

## Wake source

The loop sleeps in `poll` on the gadget capture descriptors with a 1 ms
timeout while a gadget is open, and in an absolute 1 ms `clock_nanosleep`
otherwise. The Inferno descriptors are not polled: the device is opened with
`DISABLE_POLLFD "1"`. With flows running the probe counted 17,500 wakes a
second from them, 11,400 of them spins, and by reading 7 nothing about the
Inferno side needs an event, since its state is a function of time. This also
removes the `revents` requirement. If the 1 ms grid turns out to cost depth
in the back direction, polling the Inferno capture descriptor with the
`revents` call is the alternative to measure.

## Clock discipline

The bridge's mode 2 servo, unchanged in form, with cleaner inputs:

- One `SharedDriftEstimator` fed by the regression of the differential depth
  (out depth minus back depth) with the applied correction integrated out,
  as `main.cpp` 3236-3253 does.
- Two `LevelServo`s, one per direction, on the two depths above against the
  two setpoints, with the bridge's gains to begin with (0.05 ppm per frame,
  2 ppm clamp, 8 ppm wide clamp).
- `Capture Pitch = nominal - (ppm + out_bias)`,
  `Playback Pitch = nominal - (ppm - back_bias)`, clamped to +/-250 ppm,
  written by the telemetry thread and never by the real-time thread.

Differences from the bridge: the setpoints are the two start depths, so the
servo holds what the prime set and does not adopt whatever the start
happened to leave; and it runs only in `linked`, starting from the last ppm
it held (seeded from a state file across restarts, later). On leaving
`linked` both controls go to 1000000. A launcher-side reset after a `SIGKILL`
is still needed (PLAN stage 6) and is the wrapper's job, as in the prototype.

The depth samples are taken on gadget capture wakes, which are the host's
frame grid, so the gadget playback queue's 1 ms sawtooth is read at a
constant phase.

## Threads, memory, priority

Order at start, all before any gadget PCM is opened:

1. `mlockall(MCL_CURRENT | MCL_FUTURE)` (as root; the probe's root run opened
   the plugin under the lock: 280 MB counted, 18 MB resident).
2. Create the owner's own threads with 256 KB stacks: telemetry and pitch
   writer, steward.
3. Open Inferno capture then playback, `hw_params`, `sw_params`. This creates
   the four Inferno threads. The explicit `prepare` the probe and the bridge
   follow with is **not** called: `hw_params` leaves an ioplug prepared, and a
   second prepare is a stop-and-recreate.
4. Clear the capture areas and the whole playback buffer; write the lead as
   silence; `start` both.
5. Only now raise the loop thread to `SCHED_FIFO`. The opener's policy is
   inherited by the two `Inferno main` threads (they ran at RR 99 under
   `alsaloop`); opening at normal priority leaves them at `SCHED_OTHER` with
   `flows RX` at FIFO 80 and `flows TX` at FIFO 81, as the probe's root run
   showed.
6. Release the steward to look for the gadget.

The loop thread's priority is a setting; first value 79, under the two flow
threads, because a transmit thread that is late sends stale or zero frames
whatever the owner did. Pinning is unassigned and is one variable for later.
A thread inventory (the probe's `THREADS` line) is printed after step 4, at
every `USBLINK` transition and once a minute; a changed set is logged as
such, which is the PLAN's thread-inventory gate carried into the product.

## What it logs

To a file on tmpfs, never the SD card, one line per second in `linked` and
one per ten otherwise: state, out depth and back depth (minimum, maximum,
last), both pitch values, ppm, wake gap maximum, `NETRESYNC` counts for each
direction with frames lost, `USBLINK` transitions, zero-run events at the
four points, thread count. The plugin's own lines (`RUST_LOG=warn`) go to the
same file, so `measure-candidate.sh` keeps working with its endpoint check
and log glob widened to the owner's names.

## Not in the first build

DSP and meters (the path is laid out for them); a systemd unit and anything
at boot; supervision of Statime (the owner refuses to start without the clock
socket and, once running, logs a clock that stops answering; what it should
do then is open); a control surface; AoIP-only mode. Statime's lock evidence,
hardware timestamps and the subscription-resolution work of PLAN 3a are
separate items and do not wait on this, except that the owner is their
structural answer: resolution is paid once per boot.

## Steps

Each is one change with its own check. A step that fails its check stops the
sequence.

1. **Prove the resync on the stock plugin** (no USB, no patch). The probe
   gains `--free-run`: on `avail` above the buffer it forwards and counts
   instead of recovering. Run with `--xrun-at 1 --xrun-ms 100`, which puts
   the hold inside upstream's grace window. Check: no `-EPIPE`, state stays
   `RUNNING`, no `prepare`, thread ids unchanged, the playback delay back at
   the lead on the next wake.
   *PASSED 2026-10-09 17:58 UTC (RESULTS.md): one resync per direction, state
   `RUNNING`, no prepare, thread ids unchanged.*
2. **The patch**, built as a second plugin artifact with the pinned tree
   restored afterwards. Check with the probe and the saved loop routes: a
   forced 100 ms hold at 30 s with `--free-run`; the returned pattern locks
   again within tens of milliseconds, not 5.7 s; `flows TX` keeps its thread
   id; with `XRUN_REPORT` unset the stock behaviour is unchanged.
   *PASSED 2026-10-09 18:01 UTC on plugin 55dee5d8 (RESULTS.md): sixteen channels
   locked at every report through the hold, whole again about 21 ms after it ended,
   same thread ids. Not run: the patched plugin with `XRUN_REPORT` unset. The resync must forward a margin past the deficit: the clock
   moved 4 to 5 frames in between.*
3. **Stale-audio check.** The probe gains the zero-behind rule and a mode that
   stops writing while still forwarding. Check: with the rule the loop
   returns zeros through the hold; without it the pattern's old lap comes
   back, which confirms reading 4 or retracts it.
4. **The owner, network half only** (`--no-usb`): start order above, silence
   out, capture discarded. Check: an hour as root with routes up, zero
   `NETRESYNC`, no thread change, Controller shows the device and the
   Ferrofish holds its flows throughout.
5. **The USB half.** Check first with the Mac: open and close the device ten
   times, quit and reopen a DAW, restart `usb-16x16.service` once (the
   operator's command), each a `USBLINK` pair and none a `NETRESYNC` or a
   flow loss. Then `measure-candidate.sh`: noise probe, impulse level on
   three starts with RTL on the same starts (owed item 1, asked of the
   owner).
6. **Bit transparency from the Mac through the owner** (owed item 4), both
   directions, full scale included.
7. **The battery**: four loaded 800-impulse runs and the 600 s sixteen-channel
   soak on one start, RTL at 32 by the operator. Then one variable at a time:
   `--tx-lead`, `--rx-queue`, the Inferno latencies.

## Expectation, not a claim

The prototype's 705 samples at 32 frames includes `alsaloop`'s 5 ms nominal
per direction, of which about 240 frames were seen queued toward the Mac. The
owner's first settings hold 128 out and a comparable queue back, so the first
figure should land under the prototype's by something of the order of 100 to
200 samples. That is arithmetic on configured numbers; RESULTS.md records one
occasion already where the same arithmetic assigned its parts wrongly.

## Open questions for the operator

1. **A patched plugin.** The design depends on carrying one small patch on
   the pinned Inferno tree (PLAN 3a already allows patch files beside
   `SOURCES.lock`). The alternative without a patch is an owner that guesses
   the deficit from wall-clock time and forwards before touching the pointer;
   it works until the guess is a few frames short, and then costs the six
   seconds. Is the patch acceptable?
2. **What Dante should hear when no host is streaming**: silence with the
   flows up (designed), which keeps the Ferrofish's subscriptions green.
3. **What the Mac should hear when a Dante source is unrouted or lost**:
   whatever the receive thread delivers, which by reading 6 is zeros. Nothing
   is muted or faded by the owner.
4. **Root.** The owner needs real-time priority and the memory lock, as the
   bridge has. As a hand-started process that is `sudo` in your terminal, as
   the prototype was; a unit with `LimitRTPRIO` and `LimitMEMLOCK` under a
   dedicated user is the later form.
