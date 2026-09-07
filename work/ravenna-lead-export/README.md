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

At sink delay 144 the lead reads about 0.93-1.06 ms per interval on both
Ferrofish sinks (2026-09-07): the packets arrive about 2 ms after their
stamp, 1 ms of it inherent to 1 ms packets. The lead moves in whole TIC
frames, not with the delay: the packet's first sample is placed at stamp
plus delay and rounded down to the 48-sample frame whose TIC copies it,
so the deadline changes only when the stamp phase plus the delay crosses
a frame boundary. Measured 2026-09-07: 132 read the same lead as 144 and
12 samples less latency (free); 96 crossed the boundary and read about 40
us, the 41-sample holes of 2026-09-04. The free range is 144 down to 144
minus the stamp phase; 120 reads either 144's lead or 96's, nothing in
between. Read the lead after any delay change: unchanged means free, a
value near zero or negative means the boundary was crossed.

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

Accepted 2026-09-07 15:25 UTC on the age50 profile: 759 at 64 on a fresh
anchor, RTL at 32 19.729 ms = 759 + 188, 4 x 800 loaded and the 600 s
soak all 759 with zero RECOVERs; the lead over the set 930-1014 us per
run at sink delay 144 (the handoff's MEASURED / SOAKED / ACCEPTED entries
of 2026-09-07 14:49-15:25 UTC).
