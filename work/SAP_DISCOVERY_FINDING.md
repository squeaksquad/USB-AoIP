# SAP discovery timeline: the post-restart delay is mostly upstream of the Ferrofish

Status: one measured run. Not yet confirmed. Read the caveats before acting.

## Why this exists

The documented "audio takes about 3 minutes 37 seconds to start flowing after
the AES67 daemon restarts" conflates two independent things:

1. **Discovery** — how long until the Pi announces its sessions by SAP.
2. **Resolution** — how long the Ferrofish then takes to act on the
   announcement and start returning audio.

`work/aes67-candidate/sap-watch.py` timestamps SAP announcements on the AoIP
segment so the two can be separated. `measure-aes67-roundtrip.sh` starts it
before the Pi candidate and writes `sap-timeline.log` into the run's API
directory, sharing a wall clock with `settle.log`. `USB16X16_SAP_WATCH=0`
skips it. It is passive and off the measurement path.

## The measurement

Run `aes67-roundtrip-64f-20260901T134118Z`, a Phase 4 candidate at
`480 96 960 1536 192`:

| Wall clock | Offset | Event |
|---|---:|---|
| 09:41:18 | +0.0 s | Harness starts; Mac joins `239.255.255.255` |
| 09:42:09 | +51 s | Probe 1. Probes 1-58 all fail |
| 09:45:55 | +276.9 s | First SAP packet of any kind, from the Ferrofish |
| 09:46:01 | +282.4 s | Pi's first announcement, `Daemon fea9615c USB 16x16 TX 01-08` / `09-16` |
| 09:46:31 | +312 s | Probe 59, first pass — **30 s after the Pi announced** |
| 09:46:40 | +322 s | Probe 61, ready |

Result: correlation score 0.328, captured peak 0.248.

## What it means

**Resolution is fast.** Audio flowed 30 seconds after the Pi's first
announcement, which is one announcement interval. The Ferrofish acted about as
quickly as it could. The earlier working theory, that the delay was Ferrofish
subscription backoff, is not supported.

**The wait is upstream of that**, in the 282 seconds before the Pi announced
anything.

**One observation in the same log is unexplained.** The Ferrofish announces
every 30.5 s unconditionally and was powered and streaming throughout, yet the
Mac saw no SAP at all for the first 276 seconds — roughly nine missed
intervals — and then received both sources within six seconds of each other.
Standalone tests on an otherwise idle segment saw the first Ferrofish
announcement within one interval. Nine consecutive misses is not announcement
phase. The likely cause is that the Mac's port was not being forwarded the
group, which points at IGMP snooping or a lost membership refresh, not at the
daemon.

The two readings are not yet distinguishable from one run:

- **A.** The Pi genuinely took ~282 s to announce, and the Ferrofish gap is a
  separate switch-side problem.
- **B.** Both sources were announcing normally and the switch was not
  forwarding the group to the Mac's port until something refreshed it, in which
  case the Mac's view understates how early the Ferrofish actually saw the Pi.

Reading B would also mean `sap-timeline.log` measures when the *Mac* could see
an announcement, not when the Pi sent it. That limit applies to every figure in
the table above.

## Next measurements, in order

1. **IGMP snooping A/B.** One candidate run with snooping disabled on the
   GS305EP, comparing the first-announcement offset against the 276.9 s above.
   This is one variable, reversible, and now has a baseline. It separates
   reading A from reading B. Note that every result in the repo to date was
   collected with snooping enabled, so this changes the network under test and
   must be recorded as such.
2. **Split the 282 seconds.** Part of it is legitimate daemon startup, module
   load, and PTP lock, none of which is a fault. The newly installed
   instrumentation-only Phase 4 wrapper writes `bridge.log` and `daemon.log`
   into each `phase4-candidate-*` directory; take the daemon-ready timestamp
   from there and subtract. Only the remainder — daemon ready but not yet
   announcing — is a real target.
3. **Repeat.** Everything above is n=1.

## AoIP segment inventory

Established this session by mDNS and ARP on `en12` ("2.5G AOIP"). The Pi's
address matches the handoff; the rest was previously unrecorded.

| Device | Link-local IP | MAC | Switch port |
|---|---|---|---|
| Raspberry Pi (`eth0`) | 169.254.92.97 | `88:a2:9e:8b:01:e4` | 1 |
| Dante USB adapter `D2USB-6152f1` (Ultimo X2, 100 Mb) | 169.254.242.82 | `00:1d:c1:61:52:f1` | 4 |
| Mac (`en12`) | 169.254.227.116 | `4c:ea:41:63:33:8f` | 5 |
| Ferrofish `FF-PULSE-16-DX` / `P16DX-1d27dc` | 169.254.248.189 | `00:1d:c1:1d:27:dc` | 2 or 3 |
| Metric Halo ULN-2 3d `MobileIO_49057` | 169.254.162.191 | `00:07:59:00:bf:a1` | 2 or 3 |
| GS305EP management | 169.254.0.239 | `54:07:7d:20:48:50` | — |

Ports 2 and 3 are still unresolved between the Ferrofish and the Metric Halo.
The switch exposes no MAC table; identify by unplugging one cable and watching
the port status page, or by correlating per-port byte counters with generated
traffic. Resolve this before the snooping A/B, since interpreting a per-port
change requires knowing which port is which.

SAP announcements on this segment repeat about every 30.5 seconds. Allow a full
interval before concluding a source is silent.
