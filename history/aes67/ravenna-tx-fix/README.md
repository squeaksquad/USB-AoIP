# RAVENNA transmit-slot fix

One expression in the Merging RAVENNA ALSA module (`ravenna-alsa-lkm-v2.1`,
the tree the Pi builds from, byte-identical to the vendored
`work/aes67-linux-daemon/3rdparty/ravenna-alsa-lkm/driver` for the files
touched).

## The defect

Each TIC (`manager.c` `AudioFrameTIC`) runs `frame_process_begin`, the
capture interrupt, the playback interrupt, then `frame_process_end`. The
playback interrupt copies the frame at the ALSA hw pointer into the
live-out ring at `playback_buffer_pos` and advances that position by one
frame (`audio_driver.c` playback path). `frame_process_end` then sends the
RTP packets, reading the live-out ring at
`get_live_out_jitter_buffer_offset`, which returns `playback_buffer_pos` as
it stands after the advance (its SAC argument is unused: "in reality this
var is always equal to zero"). So every packet carries the slot written one
whole ring ago: the ALSA playback buffer minus one period. At the accepted
point (playback buffer 384, period 48) that is 336 frames, 7 ms, stamped
`SAC - 48` as if it were last tick's audio.

Measured 2026-09-06 with the bridge's impulse trace and an `eth0` capture
(`outputs/latency/stage-trace-20260906/`): from the bridge's write to the
packet on the wire 12.1 ms, of which the ALSA queue is 4-5.5 ms; the
Ferrofish and both wires 2.7 ms; the packet back to the bridge's read 2.2 ms.
The record's older "RAVENNA playback at 384 costs 1.67 ms over 288" is the
same mechanism.

## The fix

`0001-send-the-slot-just-written.patch`: in `get_live_out_jitter_buffer_offset`,
return `(playback_buffer_pos + length - frame) % length`, the slot the
playback interrupt just wrote. Nothing else changes: not the stamp, not the
send instant, not the Ferrofish's timing margin, not the capture side.
Expected effect at buffer 384: the round trip falls by about 336 samples
(7 ms) and the playback buffer size stops being a latency term.

## Build (Pi, service stopped, no root)

```bash
rm -rf ~/usb-16x16-work/ravenna-tx-fix-src
mkdir -p ~/usb-16x16-work/ravenna-tx-fix-src
cp -r ~/usb-16x16-work/aes67-source/ravenna-alsa-lkm-v2.1/{common,driver} ~/usb-16x16-work/ravenna-tx-fix-src/
cd ~/usb-16x16-work/ravenna-tx-fix-src && rm -f driver/*.o driver/*.ko driver/*.mod* driver/modules.order driver/Module.symvers
patch -p1 < 0001-send-the-slot-just-written.patch
cd driver && make modules
sha256sum MergingRavennaALSA.ko
cp MergingRavennaALSA.ko ~/usb-16x16-work/ravenna-tx-fix-install/
```

Built 2026-09-06 02:14 UTC against `6.18.34+rpt-rpi-2712` (vermagic
matches the running kernel), zero warnings, SHA-256
`cc6852f0721343732c80d770a2f5a32d019dbfe20f1d361629c8fce2ff98bf55`,
copy in `artifacts/`. Patched `manager.c` `9cbbc5a8`.

## Install and rollback

The supervisor loads the module by `insmod` from `module_binary` and pins
its hash (`expected_module_sha256`). The install is a supervisor with
`module_binary` pointed at `~/usb-16x16-work/ravenna-tx-fix-install/MergingRavennaALSA.ko`
and the pin `cc6852f0`, shipped by `install-aes67-service.sh` as usual, with
the service stopped; the original module stays where it is. Rollback is the
previous supervisor (module path `aes67-source/ravenna-alsa-lkm-v2.1/driver/`,
pin `f65a4955`) through the previous service installer, service stopped.
The daemon is unchanged: the netlink structures are untouched.

## Acceptance

The full set on the point of record with the trace on: gate probe, four
loaded 800-impulse runs, the 600 s sixteen-channel soak, zero RECOVERs, the
floors as before (the ALSA queue is not touched), RTL Utility at 32 by the
user; then `rp288` against `384` reading the same level, which is the
mechanism's own check.
