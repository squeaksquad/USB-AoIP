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
