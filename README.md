# USB-AoIP

A Raspberry Pi 5 that a computer sees as an ordinary USB audio interface
(16 in / 16 out, class compliant, no driver) and that a Dante network sees as
a 16x16 device. Audio goes both ways between the two.

```
computer ──USB──▶ Pi 5 (USB audio gadget) ──▶ owner ──▶ Ethernet ──▶ Dante network
         ◀──────────────────────────────────◀       ◀────────────◀
```

**The network side is an unofficial Dante-compatible implementation.** It is
built on [Inferno](https://gitlab.com/lumifaza/inferno), an independent open
implementation of the protocol. It is not made, licensed, tested or approved
by Audinate, and "Dante" is their trademark. It works with the Dante devices
it was developed against; nothing guarantees it works with yours or keeps
working after a firmware update.

**It is a PTP follower only.** It cannot be the clock leader of a Dante
network. At least one other Dante device (a hardware interface, or Dante
Virtual Soundcard) must be on the network to lead the clock, or no audio
flows.

## What it does

- Appears on the host as `USB-AoIP`: 16 inputs, 16 outputs, 24-bit, at
  44.1, 48, 88.2 and 96 kHz.
- Appears in Dante Controller as `USB-AoIP` with 16 transmit and 16 receive
  channels, routable like any other device.
- The sample rate can be set from either side. Change it on the host (a DAW
  opening a session, Audio MIDI Setup) and the Dante side follows; change it
  in Dante Controller and the host follows.
- Optional DSP on the way out to the network: parametric EQ, crossovers, bass
  management, delay, gain, headphone buses, with changes heard live.
- A web page on the Pi for health, meters, presets and the DSP.

Measured digital round trip, host → Pi → network → a loopback on a far
device → Pi → host, at a 32-frame CoreAudio buffer, and the same at every
open of the device:

| Rate | Samples | Time |
|---|---|---|
| 44.1 kHz | 505 | 11.45 ms |
| 48 kHz | 528 | 11.00 ms |
| 88.2 kHz | 889 | 10.08 ms |
| 96 kHz | 911 | 9.49 ms |

These figures are from one network (below). The buffer depths behind them
were tuned there and are not retuned for yours.

## What you need

| Thing | Detail |
|---|---|
| Raspberry Pi 5 | Running Raspberry Pi OS (64-bit). Developed on kernel `6.18.34+rpt-rpi-2712`. |
| Power that is not the USB-C port | The USB-C port is the data connection to the host, in device mode. The development unit is powered by a PoE HAT (802.3at). |
| A host computer | Connected to the Pi's USB-C port. Developed and measured on macOS only. |
| Wired gigabit Ethernet | The Pi's `eth0`, on the same switch and subnet as the Dante devices. Dante addresses are link-local or DHCP, as on any Dante network. |
| A Dante clock leader | Another Dante device on that network. See above. |
| A second network path for management | Recommended. The web page and SSH on the development unit use Wi-Fi so they stay off the audio port. |
| Dante Controller | To route channels. Audinate's free application. |

The development network is one small PoE switch (NETGEAR GS305EP) with a
Ferrofish converter as the far device and clock leader.

## Layout

What you install and run:

| Path | What's there |
|---|---|
| [`dante/`](dante/) | The network side: the owner process, the patches to Inferno, pinned upstream revisions, systemd units, configs. |
| [`gadget/`](gadget/) | The USB side: the gadget setup script and its service drop-in, CPU governor tuning. |
| [`kernel/`](kernel/) | Patches to the kernel's USB audio gadget (channel names, rate reporting, rate requests) and their build scripts. |
| [`dsp-core/`](dsp-core/) | The DSP stage, shared C++ the owner links, and its tests. |
| [`dsp-compiler/`](dsp-compiler/) | Turns a preset from the page into the coefficients the DSP stage loads. Runs in the browser. |
| [`web-control/`](web-control/) | The service behind the page (Python, standard library only) and the root helper that applies changes. |
| [`web-ui/`](web-ui/) | The page (plain ES modules, no build step). |
| [`tools/`](tools/) | Measurement and diagnosis from the host: the latency harness, capture readers. Not installed on the Pi. |
| `work/protected-baseline-2026-08-31/` | The original known-good gadget module and script. Never edited; the last-resort rollback. |

The research record:

| Path | What's there |
|---|---|
| [`PROJECT_HANDOFF.md`](PROJECT_HANDOFF.md) | The dated, append-only log of every decision and measurement. Authoritative: where anything disagrees with it, it wins. Very long; read the tail. |
| [`docs/`](docs/) | Design documents and results for each part, and the pickup notes between work sessions. |
| [`history/`](history/) | The AES67 path that came first, superseded installers and configs, experiments. Kept as written, not needed to run anything. |
| [`EVIDENCE.md`](EVIDENCE.md) | The raw measurement evidence lives in [its own repository](https://github.com/squeaksquad/USB-AoIP-evidence). |
| [`work/MOVED.md`](work/MOVED.md) | Maps the paths the handoff cites (the layout before 2026-11-10) to where things are now. |
| [`CLAUDE.md`](CLAUDE.md) | A dense map of every directory and script, written for AI coding sessions. |

## Installing

**There is not yet a one-step install.** The development unit was built up
by a chain of about twenty incremental installers (`history/installers/`),
each pinned to the hashes of binaries built on that one Pi, with that unit's
user name and addresses written in. They are a record, not a procedure, and
will not work on another machine as they stand.

A single installer that takes a fresh Raspberry Pi OS to the current state,
with site settings in one config file and kernel modules rebuilt on kernel
upgrades, is the next piece of work. Until it lands, reproducing this means
reading these and doing by hand what they describe:

1. Kernel: build `usb_f_uac2` and `u_audio` with the patches in `kernel/`
   (`build-rate-request.sh production`). They apply to `6.18.34` and have not
   been tried on another version.
2. Gadget: `gadget/setup-usb-aoip` run by `usb-16x16.service`.
3. Network side: build Statime and the patched Inferno ALSA plugin at the
   revisions in `dante/SOURCES.lock` with `dante/patches/` applied in order,
   build the owner (the command is in the header of `dante/owner/main.cpp`),
   and install the units and configs in `dante/service/` and `dante/config/`.
4. Page: `web-control/` and `web-ui/`.

## Operating

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

`usb-16x16.service` is the USB gadget, `usb16x16-statime` the PTP clock and
`usb16x16-dante` the endpoint. (Unit and binary names keep an older
`usb16x16` prefix; the device is called `USB-AoIP` everywhere a user sees
it.)

- After the endpoint starts or restarts, wait for `state=ok` from the start
  check before trusting audio. It watches the first seconds of received
  packets and restarts the endpoint if a flow is losing them.
- Route channels in Dante Controller.
- Change the sample rate from the host or from Dante Controller, not from
  the page. The endpoint restarts at the new rate: a short outage.
- Restarting `usb-16x16.service` makes the device disappear and reappear on
  the host.
- The page is served on port 8088 of the management interface, behind a
  login.

To measure the round trip yourself, from a Mac: build
`tools/latency-harness` (`swift build -c release && ./build-app.sh`) and run
`dante/measure-candidate.sh` against a loopback on a far device. Run its
noise probe first; a dropped sample anywhere invalidates a latency reading.

## Known limits

- **Follower only.** No clock leader on the network, no audio. After the
  leader reboots under a running endpoint, audio continues but the round
  trip can sit up to about 2 ms longer until the device is next re-opened.
- **Unofficial.** No Audinate support and no guarantee of interoperability.
  Dante Domain Manager, a secondary (redundant) network and Dante's AES67
  mode were never tried on this path.
- **Starts sometimes lose packets.** On the development network roughly
  one endpoint start in three, when counted, began with a flow dropping packets from the far
  device. The start check detects it and restarts the endpoint; its
  threshold is tuned to that network.
- **88.2 and 96 kHz are measured on 8 channels**, because the far device
  used for the loop carries half its channels at those rates. All 16 run,
  only 8 were verified end to end.
- **macOS and 88.2 kHz:** audio started within about a third of a second of
  switching to 88.2 kHz can be silent for that session. Wait a few seconds
  after the switch.
- **Do not change the rate under an open DAW session.**
- **One kernel version.** The modules are built for `6.18.34+rpt-rpi-2712`.
  A kernel upgrade leaves the gadget without them until they are rebuilt.
- **Hosts other than macOS are untested.** The gadget is class compliant,
  but the per-rate latency figures and the rate-follow behaviour were only
  ever measured against Apple's driver.
- **The page uses a password over plain HTTP.** Fine on a network you
  control, not protection against anyone who can watch it.
- **Not a product.** One unit exists. The record of how it got here is
  thorough; the path for a second unit is still being written.

## Contributing and tests

The tests that do not need a Pi run in CI (`.github/workflows/ci.yml`) and
locally:

```bash
node --test web-ui/*.test.mjs dsp-compiler/*.test.mjs
```

```bash
python3 -m unittest discover -s web-control -p 'test_*.py'
```

```bash
cmake -S dsp-core -B build/dsp-core && cmake --build build/dsp-core && ctest --test-dir build/dsp-core
```

Changes that touch the audio path (the owner, the plugin or its config, the
transport depths, the gadget, the kernel patches) are accepted only after
measurement on hardware; `PROJECT_HANDOFF.md` records the rule and every
acceptance under it.

## Licence

Apache License 2.0 ([`LICENSE`](LICENSE)), except the patches to GPL
projects (the Linux kernel, Inferno, the RAVENNA module on the AES67 path)
and anything built from them, which keep their upstream licences.
[`LICENSING.md`](LICENSING.md) lists them.
