# Temporary combined USB/AES67 candidate

This experiment starts the existing kernel-specific RAVENNA driver and daemon
on `eth0`, then runs the two previously validated 16-channel `alsaloop`
directions with one candidate timing set:

- 48 kHz, `S32_LE` inside ALSA `plughw`;
- adaptive `sincfastest` conversion in each direction;
- 5 ms `alsaloop` target;
- 96-frame explicit period and 288-frame buffer;
- 48-sample AES67 sink delay in a temporary copy of `status.json`.

The wrapper refuses unexpected audio/PTP processes, verifies pinned daemon and
module hashes, waits for the expected PTP grandmaster, reapplies the saved
Ferrofish receive sinks after lock, and verifies USB health. It never edits the
saved daemon config/status or the protected USB implementation. On exit it
stops both audio directions and the daemon, unloads the RAVENNA module, and
deletes only its validated temporary directory.

The default 180-second run is reconnaissance. A successful Pi bridge run does
not by itself prove the Ferrofish is digitally returning the transmitted
impulse; the Mac correlation harness provides that end-to-end check.

## Phase 4 candidate

`run-phase4-candidate-safe.sh` uses the same pinned daemon, RAVENNA module,
temporary status file, PTP lock ordering, sink reapply, USB health checks, and
cleanup boundary, but launches one root-owned `usb16x16-rt-bridge` instead of
two `alsaloop` processes. Sink delay is fixed at the validated 576-sample value.

`measure-phase4-roundtrip.sh` selects that wrapper and the Phase 4 ready file.
Readiness requires three consecutive real-signal probes. The correlator limit
defaults to 200 ms and rejects values at or above the 250 ms impulse interval.

## SAP discovery timeline

`sap-watch.py` timestamps SAP session announcements on the AoIP segment. It
exists to split the documented ~3.5 minute post-restart delay, which currently
conflates two independent things: how long the Pi takes to announce a session,
and how long the Ferrofish then takes to resolve its subscription to it.

`measure-aes67-roundtrip.sh` starts it just before the Pi candidate and writes
`sap-timeline.log` into the run's API directory, so it shares a wall clock with
`settle.log` and the two can be read together. Set `USB16X16_SAP_WATCH=0` to
skip it. It is not on the measurement path; a failure is logged and ignored.

The watcher is passive. It joins `239.255.255.255:9875` and reads, transmitting
nothing but the IGMP join, and never touches the daemon, the sinks, or the
sources. The field that matters is the SDP origin version on each `o=` line: a
receiver re-resolves a subscription when a session's version changes, so a
`CHANGE` row is the event that starts the Ferrofish clock. A stable session
repeats the same version indefinitely, as the Ferrofish's own flows do.

It also runs standalone against a live segment:

```zsh
python3 work/aes67-candidate/sap-watch.py --duration 120
```

Announcements repeat about every 30.5 seconds, so allow at least one full
interval before concluding that a source is silent.
