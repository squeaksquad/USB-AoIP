# usb16x16-aes67.service

The accepted Phase 4 operating point as a persistent service on the Pi.
Design and acceptance criteria are in `DEPLOYMENT_PLAN.md`; the measurements
behind the point are in `PROJECT_HANDOFF.md` under "ACCEPTED: the combined
point".

| file | installs to |
|---|---|
| `usb16x16-aes67-supervisor` | `/usr/local/sbin/usb16x16-aes67-supervisor` |
| `usb16x16-aes67.service` | `/etc/systemd/system/usb16x16-aes67.service` |
| `aes67.conf` | `/etc/usb16x16/aes67.conf` (kept if the operator edited it) |
| `install-aes67-service.sh` | run once with sudo from the staging directory |

The installer also writes `/etc/sudoers.d/usb16x16-aes67` so `bdimaio` can
start, stop, restart, enable and disable the unit, switch profiles, kill the
daemon or the bridge for the acceptance tests, and reboot, all without a
password. The bridge is matched by command line (`pkill -f`), because
`pkill -x` cannot see a process name longer than 15 characters. The USB gadget, `usb-16x16.service` and the setup script are not
touched by any of this.

## Install

Stage from the Mac, verify the hashes, then run the installer once:

```bash
rsync -a work/aes67-bridge/{usb16x16-aes67-supervisor,usb16x16-aes67.service,aes67.conf,install-aes67-service.sh} \
  audio-dev.local:usb-16x16-work/aes67-service/
```

```bash
ssh -t -o HostKeyAlias=audio-dev.local bdimaio@192.168.1.201 \
  'sudo ~/usb-16x16-work/aes67-service/install-aes67-service.sh'
```

The installer refuses if any staged file does not match its pinned hash, if
the installed bridge is not `0254348c`, or if the service is active.
It does not enable or start the service. An installed `aes67.conf` is
replaced if it is an unedited copy of a version the installer has shipped
before, kept (with the new version beside it as `aes67.conf.new`) if the
operator has edited it.

## Operate

```bash
sudo systemctl start usb16x16-aes67
```

```bash
sudo systemctl stop usb16x16-aes67
```

```bash
/usr/local/sbin/usb16x16-aes67-supervisor status
```

```bash
journalctl -u usb16x16-aes67 -f
```

`status` prints the unit state, the selected profile, the last supervisor
stage and its age, the last `BRIDGE` line reduced to ppm, queues, floors and
restarts, the recovery count for this session, PTP status, sink delays, the
UDC state and `usb-16x16.service`.

The journal reads as a timeline of `STAGE` lines: `insmod`, `daemon API
ready in Ns`, `ptp locked in Ns`, `sinks applied`, `bridge negotiated`,
`running`. The daemon's own output is in the same journal under the
identifier `aes67-daemon`. Every `PRIMED`, `NEGOTIATED`, `RECOVER`,
`DEPTHSTEP` and `SUMMARY` line from the bridge goes to the journal, plus one
`BRIDGE` line every 10 s. The full 1 Hz stream is at
`/run/usb16x16/bridge.log` on tmpfs, truncated at every start and rotated
once to `bridge.log.1` at 64 MB; it is the post-mortem for the current
session only and does not survive a reboot. The Pi's journal is volatile
too (Raspberry Pi OS ships `Storage=volatile`), so `journalctl -b` is the
only boot you can read unless `make-journal-persistent.sh` has been run
once with sudo (it installs a `Storage=persistent` drop-in capped at
256 MB and restarts journald).

Enable at boot once the manual acceptance items pass:

```bash
sudo systemctl enable usb16x16-aes67
```

## What the supervisor does on its own

- Waits, without failing, for the USB gadget to be `configured` at high
  speed and for `eth0` to have carrier at 1 Gb/s, logging once a minute.
  A sleeping Mac is a wait, not a restart loop.
- Refuses to start over a running candidate measurement, `ptp4l`,
  `aes67-daemon`, `alsaloop` or another bridge.
- Exits non-zero if the daemon or the bridge exits, if more than five
  `RECOVER` lines arrive in any 60 s with USB input still moving, or if
  the protected prototype config changes; systemd restarts the whole
  sequence 10 s later. After three failures inside five minutes it sleeps
  60 s before exiting, so a broken network is one journal line a minute.
- Recognises the host leaving: a `RECOVER` storm (ten or more in one
  second, `HOST_STORM_RECOVERS_PER_SECOND`) while the USB capture frame
  count in the BRIDGE line has stopped moving. The unplug measured 33-185
  in the first second, and `/sys/class/udc/*/state` never changed, so that
  file is not the signal, and during a storm the bridge stops writing its
  BRIDGE line, so a storm sustained for three seconds counts on its own).
  On a storm the supervisor stops the bridge only,
  keeps the daemon and the module up, logs `STAGE host absent`, and waits
  for a `dwc2` enumeration line in the kernel log or `HOST_RETRY_SECONDS`
  (60), then starts the bridge again. A replug re-enumerates and is seen
  within 5 s; a Mac waking from sleep does not re-enumerate, so the retry
  is the wake signal and audio returns within the retry interval plus
  about 8 s. During a storm the journal carries the first 20 RECOVER
  lines and a marker; the full stream is on the tmpfs log. A storm with USB input still moving
  is not the host leaving and takes the ordinary stack-restart path.
- A stop request during the daemon's 32 s sink PUT is honoured at once:
  the long calls run in the background under `wait`, and the trap kills
  them. `TimeoutStopSec` is 40 s.
- Two minutes of stable running clears the failure history.
- Known: every cold boot starts the bridge with a capture XRUN on both
  directions, which it re-primes through; two of three boots then needed
  one stack restart before audio was stable. See the handoff section
  "DEPLOYED: usb16x16-aes67.service".
- On stop: SIGINT to the bridge and the daemon with 5 s grace each, then
  SIGTERM, then `rmmod` with retries. `ExecStopPost` reaps anything left in
  the unit's cgroup and unloads the module, but never touches a candidate's
  processes.

## Profiles

`/etc/usb16x16/aes67.conf` carries `PROFILE=<name>` and one block per
profile. Six ship:

| profile | point | measured | cover | status |
|---|---|---:|---|---|
| `safe` | period 48, target 128, RAVENNA playback 384, TX 288, RX 144, buffer 192, sink delay 576 | 25.6 ms (25.6-27.3) | TX floor 164-193 | accepted, default |
| `safe-96` | period 96, otherwise as `safe` | 29.1 ms (28.1-29.1) | TX floor 158-197 | accepted, rollback for `safe` |
| `fast` | target 128, TX 192, RX 96, buffer 192, sink delay 576 | 24.5 ms | none, TX floor 97 | experimental |
| `servo` | as `safe` with the USB pitch servo (`USB_PITCH_SERVO=1`): converters at 1.0, bit transparent | 25.8 ms | TX floor 164 | experimental, running |
| `servo-split` | `servo` with the per-direction level servo (`USB_PITCH_SERVO=2`) | not yet | as `servo` | experimental |
| `servo-aligned` | `servo` with the aligned start (`ALIGN_START=1`) and sink delay 96: the RX playout is the same every start | 29.5-30.3 ms, 37-sample window over 6 sessions; 3 loaded runs of 4 | TX floor 161-163 | experimental |

```bash
/usr/local/sbin/usb16x16-aes67-supervisor profiles
```

```bash
sudo /usr/local/sbin/usb16x16-aes67-supervisor switch-profile fast
```

A switch rewrites the `PROFILE=` line (verified before the file is
replaced) and restarts the service if it is active. Audio is gone for
about a minute while the stack comes back. Adding a profile is a new block
in the file and its four loaded runs; nothing else changes. The supervisor
validates every block it selects with the same rules as the candidate
wrapper, and refuses a block that fails.

## Measure while the service exists

The candidate wrapper and the service refuse to run over each other. The
rule is: stop the service, measure, start it again.

```bash
ssh -o HostKeyAlias=audio-dev.local bdimaio@192.168.1.201 'sudo systemctl stop usb16x16-aes67'
```

Then the accepted-point measurement as documented in the pickup prompt
(`measure-phase4-roundtrip.sh 600 64 800 200` with the Phase 4 shim
environment), then:

```bash
ssh -o HostKeyAlias=audio-dev.local bdimaio@192.168.1.201 'sudo systemctl start usb16x16-aes67'
```

If the service is left running, the wrapper refuses with "aes67-daemon is
already running". If a candidate is running, the service logs a refusal
and retries on its backoff until the candidate ends.

## Roll back

```bash
sudo systemctl disable --now usb16x16-aes67
```

Then `rmmod MergingRavennaALSA` if `lsmod` still shows it. The stopgap
runner and the candidate wrapper remain installed and untouched. Removing
the files entirely is the three destinations in the table above plus the
sudoers fragment.
