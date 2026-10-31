# USB-AoIP

A Raspberry Pi 5 that shows up on a Mac as a plain USB audio interface,
**USB-AoIP** (16 in / 16 out, class compliant, no driver; named "USB 16x16"
until 2026-10-30), and bridges those
channels in both directions onto an audio-over-IP network. The Mac sees an
ordinary sound card; the network sees a Dante (or, on the older path, AES67)
device.

```
Mac (CoreAudio) ──USB──▶ Pi 5 UAC2 gadget ──▶ bridge / owner ──▶ eth0 ──▶ Dante / AES67 network
                ◀──────────────────────────◀                  ◀──────◀   (Ferrofish as loop return)
```

The project is research-grade: every operating point is measured, hashed and
recorded before it is accepted, and the protected USB baseline can always be
restored.

## Current state (2026-10-30)

- **Active path: Dante**, through [Inferno](https://gitlab.com/lumifaza/inferno)
  (an open Dante implementation) and Statime for PTP. A single long-lived
  process, `usb16x16-dante-owner`, moves audio between the USB gadget and the
  network, with an optional DSP stage (EQ, crossovers, bass management) and
  live coefficient changes.
- **Sample rates:** the USB side offers 44.1, 48, 88.2 and 96 kHz; the Dante
  side offers 44.1 and 48 kHz. The Mac decides: a rate set on the Mac, or from
  Dante Controller / Dante Switcher, moves the endpoint through an arbiter on
  the Pi, and the Mac follows a Dante-side move. 96 kHz runs on an 8-channel
  test loop but is not yet a point of record.
- **Measured digital round trip** Mac → Pi → Dante → far loop → Pi → Mac at
  48 kHz and a 32-frame CoreAudio buffer: about **10.0 to 11.6 ms** on the DAW
  timeline. The figure is fixed for as long as an app keeps the device open,
  but each new open lands somewhere in a band of about 0.9 ms. That spread is
  set by how macOS's class driver starts its input and output streams, and the
  Pi cannot see it (2026-10-28/29). A dedicated host driver with deterministic
  latency is being explored: `work/mac-driver-spike/`.
- **AES67 path** (RAVENNA driver + `aes67-linux-daemon`) still works and is
  kept as the rollback; its service is stopped.

The authoritative, dated record of all of this is
[`PROJECT_HANDOFF.md`](PROJECT_HANDOFF.md). If anything here disagrees with it,
the handoff wins.

## Hardware and network

| Thing | Detail |
|---|---|
| Pi | Raspberry Pi 5; SSH as `bdimaio@169.254.92.97` over `eth0` (the Mac is on the audio switch); Wi-Fi `wlan0` at `192.168.1.201` (`audio-dev.local`) stays up as the backup SSH path |
| AoIP port | `eth0`, `169.254.92.97`, gigabit, on the audio switch; also the SSH path |
| Host | A Mac, connected to the Pi's USB-C port (device mode) |
| Loop return | Ferrofish converter on the Dante network, used to measure the round trip |
| Web UI | `http://192.168.1.201:8088` (Basic auth): health, meters, presets, DSP |

SSH over `eth0` shows the link is up, not that the Dante flows are healthy; check those separately, and keep bulk copies out of measurement runs. The web UI binds `wlan0`, so it stays at `192.168.1.201`.

## Repository layout

| Path | What's there |
|---|---|
| `PROJECT_HANDOFF.md` | Chronological log of every decision and measurement. Very long; read the tail first. |
| `CLAUDE.md` | Detailed map of every directory and script (written for AI sessions, but the best index there is). |
| `work/dante-mode/` | The Dante path: plan, results, Inferno patches, the owner process, its systemd services and installers. |
| `work/pi-tuning/` | USB gadget scripts (incl. the multi-rate gadget), CPU governor, Wi-Fi keepalive. |
| `work/phase4-bridge/` | The C++ real-time bridge used on the AES67 path; its DSP stage is shared with the Dante owner. |
| `work/aes67-bridge/` | The AES67 supervisor service and its profiles (rollback path). |
| `work/web-control/`, `work/web-ui/` | The Pi's control service (Python, stdlib) and the browser UI (plain ES modules). |
| `work/dsp-compiler/` | Turns a UI preset into DSP coefficients for the bridge (and CamillaDSP for verification). |
| `work/latency-harness/` | Swift CoreAudio tool that measures round-trip latency and bit transparency from the Mac. |
| `work/protected-baseline-2026-08-31/` | The known-good USB gadget module and scripts. **Never edited.** |
| `work/uac2-discrete-channels/` | Kernel patches: macOS labels the channels 1–16, the gadget reports and requests the Mac's sample rate. |
| `outputs/latency/` | Raw measurement evidence, cited in the handoff by UTC timestamp. |

## Day-to-day operation

On the Pi:

```bash
systemctl status usb-16x16.service usb16x16-statime usb16x16-dante
```

```bash
journalctl -u usb16x16-dante -f
```

```bash
cat /run/usb16x16-dante-startcheck/status
```

`usb-16x16.service` is the USB gadget, `usb16x16-statime` the PTP clock,
`usb16x16-dante` the endpoint. The service and process names keep their
`usb16x16` prefix; only the device's name changed. Wait for `state=ok` from the start check before
trusting audio after a restart. Restarting `usb-16x16.service` re-enumerates the
device on the Mac.

Every installer under `work/` checks pinned SHA-256 hashes, refuses to run on a
mismatch, and has a `rollback` subcommand that returns to the previous
accepted state.

## Measuring latency

From the Mac, build the harness once:

```bash
cd work/latency-harness && swift build -c release && ./build-app.sh
```

Then measure against the running Dante endpoint with
`work/dante-mode/measure-candidate.sh`; its `daw_timeline` line is the figure
that matches RTL Utility at 32 frames, which is the project's standard. Run a
noise probe first: a dropped sample anywhere invalidates a latency reading. See
`work/latency-harness/README.md` for the full tool.

## Ground rules

- The USB gadget module, `setup-usb-16x16` and `usb-16x16.service` are the
  protected baseline. Experiments use different names and carry restore commands.
- Change one variable at a time; record hashes, commands, logs and results.
- A new operating point needs four loaded 800-impulse runs and a soak before
  it is accepted.
- Don't build on the Pi or copy files to/from it while audio is being measured.

## Licence

Apache License 2.0 ([`LICENSE`](LICENSE)), except the patches to and binaries
built from GPL projects (the Linux kernel, the RAVENNA module, Inferno), which
keep their upstream licences; [`LICENSING.md`](LICENSING.md) lists them.
