# RAVENNA arrival-lead export

The second change to the Merging RAVENNA ALSA module (`ravenna-alsa-lkm-v2.1`,
the tree the Pi builds from, byte-identical to the vendored
`work/aes67-linux-daemon/3rdparty/ravenna-alsa-lkm/driver` for the files
touched). It sits on top of the transmit-slot fix (`work/ravenna-tx-fix`,
patch 0001) and touches only the sink statistics path: no audio path, no
stamp, no send instant, no netlink structure, no daemon change.

## Why

Sink delay is the one priced lever left in the BUDGET entry of 2026-09-06
(144 -> 120, 24 samples, 0.5 ms), and it is a gamble until the arrival lead
is known: at 96 the 41-sample holes came back, at 144 zero in 45 minutes,
and nothing said where between them the edge is. The driver already
computes, for every packet, how long before its use the packet arrived, and
keeps the running minimum (`RTP_audio_stream.c` `ProcessRTPAudioPacket`,
compiled in because `DEBUG_CHECK` is 1), but the number never left the
module: the only exporter, `GetMinSinkAheadTime`, has no message case in
`manager.c`, `set_sink_min_time` has no caller, and the API's
`sink_min_time` (`GET /api/sink/status/N`) is the constructor's zero.

## What the patch does

`0002-export-arrival-lead.patch`, two files:

- `RTP_audio_stream.c` `ProcessRTPAudioPacket`: the arithmetic in one unit.
  `MTAL_LK_GetCounterTime()` counts 100 ns and `MTAL_LK_GetCounterFreq()`
  returns 1e9, so the original `* 1000000 / freq` put the two counters in
  100 us units against the SAC term's 100 ns: the phase inside the TIC (up
  to one TIC, 1 ms) was lost, and a late packet wrapped the unsigned
  difference to a huge value that never reached the minimum. Now: the
  packet's use time is the TIC's counter time plus (first-frame SAC minus
  the TIC's SAC) in 100 ns, the lead is that minus now, signed; negative
  when the packet arrived after the TIC that consumes it.
- `RTP_audio_stream.h`: the minimum is signed (`m_i32MinSinkAheadTime`,
  was `uint32_t m_ui32MinSinkAheadTime`).
- `RTP_audio_stream.c` `Create`: arms the minimum so the first packet seeds
  it (with both reset counters at zero after `Init`'s memset the seed
  branch never ran and the minimum stayed at zero), and sets
  `sink_min_time` to -1.
- `RTP_audio_stream.c` `PrepareBufferLives` (the per-TIC status update):
  when the daemon has fetched the status since the last TIC, the interval
  closes: `sink_min_time` -1 and the packet path is told to re-seed at its
  next packet; on every TIC after a packet has seeded it, `sink_min_time`
  is the minimum in microseconds. The `memcpy` in `get_RTPStream_status`
  already copies the whole `TRTP_stream_status`, so the daemon's
  `session_manager.cpp` and `json.cpp` carry it as they are.

Patched file hashes: `RTP_audio_stream.c` `5d479dda`, `RTP_audio_stream.h`
`d4e9fbc8`, and from 0001 `manager.c` `9cbbc5a8`. Patch hashes: 0001
`a7e9bc28`, 0002 `e45b16b6`. Dry-run clean on a copy of the vendored tree
with 0001 applied (2026-09-07).

## Reading it

`sink_min_time` on `GET /api/sink/status/N` is, per sink, the least time in
microseconds that a packet arrived ahead of the TIC that copies its first
sample into the ALSA capture buffer (`audio_driver.c`, the capture
interrupt reads the live-in ring at the global SAC), over the packets since
the previous GET of that sink; negative means a packet arrived after that
TIC (a hole); -1 means no packet since the previous GET. Every GET closes an
interval and starts the next, so the number is read in pairs: once before a
run, once after it, and the second read is the minimum over the run.
`read-lead.sh [label]` on the Mac prints both sinks with a UTC stamp.

At sink delay 144 the lead should read about 3 ms less the packet's
lateness against its stamp less the ring's one-frame grain. Sink delay 120
takes 24 samples (500 us) off it. The number that decides the lever is the
minimum over a loaded 800-impulse run and the 600 s soak at 144: if it
stays over 1 ms, 120 keeps 0.5 ms; between 0.5 and 1 ms, 120 is the edge
the 41-sample holes at 96 already showed; under 0.5 ms, 120 is not safe and
the lever is closed.

## Build (Pi, service stopped, no root)

`build.sh` is the transmit-slot recipe with both patches and the hash
checks, staged with the two patches in `~/usb-16x16-work/ravenna-lead-src/`:

```bash
cd ~/usb-16x16-work/ravenna-lead-src && ./build.sh
```

It refuses while `usb16x16-aes67.service` is active, checks both patches
and the three patched files by hash, builds `make modules` from a fresh
copy of the v2.1 tree, prints the warning count, the vermagic against the
running kernel and the module's SHA-256, and copies the module to
`~/usb-16x16-work/ravenna-lead-install/`. The build is the module's
acceptance gate for the syntax: nothing here compiles on the Mac.

Built 2026-09-07 14:30 UTC on the Pi against `6.18.34+rpt-rpi-2712`
(vermagic matches the running kernel), zero warnings, SHA-256
`bc694c24c77893836dd3a3cfa0c9105e68b556d19dd51a84bf9ee5ca3f1b98ff`,
copy in `artifacts/`. (`build.sh` as run was `72543be6`; it now calls
`/usr/sbin/modinfo` by path, which the first run could not find.)

## Install and rollback

As for the transmit-slot fix: the supervisor loads the module by `insmod`
from `module_binary` and pins its hash. The install is a supervisor with
`module_binary` pointed at `~/usb-16x16-work/ravenna-lead-install/MergingRavennaALSA.ko`
and `expected_module_sha256` at the built hash, shipped by
`install-aes67-service.sh` (its supervisor pin moved) with the service
stopped; the profile, bridge and conf are untouched. Rollback is the
previous supervisor (`module_binary` at `ravenna-tx-fix-install/`, pin
`cc6852f0`) through the previous service installer, service stopped; the
original module (`f65a4955`) stays at
`aes67-source/ravenna-alsa-lkm-v2.1/driver/`.

## Acceptance

The module rebuild is on the rollback path, so the usual set on the point
of record (age50): fresh anchor, the PRIMED and ALIGN trigger lines as
accepted, gate probe, one 100-impulse read at 64 (766 expected: nothing
in the audio path changed), four loaded 800-impulse runs, the 600 s
sixteen-channel soak, zero RECOVERs, floors as before, RTL at 32 by the
user. `read-lead.sh` before and after every run gives the lead over each,
which is the measurement this module exists for; the sink delay 120 block
is written only after those numbers.
