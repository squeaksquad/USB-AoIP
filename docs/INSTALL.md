# Installing USB-AoIP on a Raspberry Pi 5

From a blank SD card to a device a computer sees as a 16x16 USB audio
interface and a Dante network sees as a 16x16 device. You edit one config
file; you do not edit a script.

Read the README's "What you need" first. In short: a Pi 5 powered by
something other than its USB-C port, wired Ethernet on a network that
already has a Dante clock leader, and a second way in (Wi-Fi) for the web
page and SSH.

> **State of this document, 2026-11-10.** The installer was written and
> tested off the Pi: every file it installs is checked byte for byte against
> the development unit's, and its build steps and the kernel modules are
> built on arm64 in CI. It has **not yet been run end to end on a Pi**. The
> steps marked *(unverified on hardware)* are the ones that could not be
> checked without one; `docs/install/TO-VERIFY.md` lists them.

## 1. The SD card

1. With Raspberry Pi Imager, write **Raspberry Pi OS Lite (64-bit)**, the
   release based on Debian 13 "trixie".
2. In the Imager's settings, set a hostname, a user and password, your Wi-Fi,
   and enable SSH. The Wi-Fi is how you will reach the Pi; the wired port is
   for audio.
3. Boot the Pi with Ethernet connected to the Dante switch and power from
   PoE or the GPIO header. Do not power it from the USB-C port: that port
   becomes the connection to the computer.
4. SSH in over Wi-Fi.

## 2. Get the repository

```bash
sudo apt-get update && sudo apt-get install -y git
```

```bash
git clone https://github.com/squeaksquad/USB-AoIP.git && cd USB-AoIP
```

## 3. Write the config

```bash
sudo install/install.sh config
```

This writes `/etc/usb-aoip/install.conf` with values detected on the
machine and prints it. Check, and edit if needed:

| Key | What to check |
|---|---|
| `AUDIO_IF` | The wired port on the Dante network. `eth0` on Raspberry Pi OS. |
| `AUDIO_IF_SETUP` | `none` leaves the port's network settings alone: right when the Dante network has a DHCP server. `link-local` makes a NetworkManager connection with a 169.254.x.y address: right for a Dante network with no DHCP server, which is most small ones. *(unverified on hardware)* |
| `MGMT_IF` | Where the web page listens. `wlan0` if the Pi has Wi-Fi. |
| `DEVICE_NAME` | The name the computer and Dante Controller show. |
| `USB_SERIAL` | Derived from the Pi's serial number, so two units on one computer do not collide. |
| `DANTE_DEVICE_ID` | The wired port's MAC address followed by `0000`; unique on the network. |
| `WEB_TLS` | `self-signed` (the default) encrypts the page with a certificate made on the unit; your browser warns once. `provided` uses your own; `off` is plain HTTP. `docs/web/ACCESS.md` explains the choice. |
| `OPERATOR_USER` | Your login. It gets password-free `systemctl start/stop/restart` for the audio services and nothing else. Empty it to install no such rule. |

`install/install.conf.example` describes every key. Nothing in this file
tunes audio.

## 4. Install

```bash
sudo install/install.sh install
```

It stops twice on a fresh system, each time telling you what to do, and is
safe to run again:

1. **The kernel.** The unit runs on kernel `6.18.34+rpt-rpi-2712`, the one
   every measurement was made on, and holds it there. A fresh Raspberry Pi
   OS has a newer one. The installer installs 6.18.34 beside it and stops,
   printing the commands that remove the newer kernel packages so the Pi
   boots 6.18.34. Run them, reboot, run `install` again.
   *(unverified on hardware: how Raspberry Pi OS chooses among installed
   kernels at boot)*
2. **The USB-C port.** If the port is not yet a USB device controller, the
   installer adds `dtoverlay=dwc2,dr_mode=peripheral` to
   `/boot/firmware/config.txt` (keeping the old file beside it) and stops.
   Reboot, run `install` again. *(unverified on hardware: the development
   unit's own boot configuration is not in the record)*

Then it runs to the end, most of the time compiling Rust (the two Rust
builds took about five minutes together on the development unit):

- installs packages (compiler, cmake, ALSA headers, DKMS, ethtool);
- installs a Rust toolchain under `/var/lib/usb-aoip/build`, checked against
  its published hash;
- fetches Inferno and Statime at the pinned revisions, checks the revisions,
  submodules and lock files, applies the five Inferno patches and builds;
- builds the owner and the DSP runner from this repository;
- builds the two patched gadget modules with DKMS and checks that they, not
  the stock ones, are what `modprobe` loads;
- writes every unit, script and config with your values;
- records the hash of everything it installed in
  `/var/lib/usb-aoip/manifest`;
- enables and starts the services.

Sources and patches are verified against hashes pinned in the repository;
a mismatch is a refusal. What is built on your Pi is hashed and recorded,
not compared with anyone else's build.

## 5. The web page login

When `install` is run at a terminal it ends by asking for a password for a
first login, named after `OPERATOR_USER`. To add one later, or another:

```bash
sudo install/install.sh set-password yourname
```

It asks for the password twice and prints the page's address,
`https://<the Pi's Wi-Fi address>:8088`.

The first time a browser opens it, it warns that the certificate is not
trusted: the unit made it itself, and nobody vouches for it. The installer
printed the certificate's SHA-256 fingerprint; the browser's warning has a
"view certificate" link that shows one too. If they match, the page is your
unit and the connection is encrypted; accept it. The warning returns only
if the Pi's address changes and the certificate is remade.

Anyone with a login can do everything the page can, including shutting the
unit down. The page is for a local network, not the internet.

## 6. Check it

```bash
sudo install/install.sh status
```

Every installed file should be "as installed", the kernel the pinned one,
the modules loaded from `updates/dkms`, the services active, and the start
check `state=ok` (it takes about a minute after a start, and says `idle`
until something is sending the Pi audio).

Then:

1. Connect the computer to the Pi's USB-C port. A device named as
   `DEVICE_NAME` should appear with 16 inputs and 16 outputs.
2. In Dante Controller the same name should appear with 16 transmit and 16
   receive channels. Route channels to and from another device.
3. Play audio. If the device is there but silent, check that the network has
   a clock leader: `journalctl -u usb16x16-statime -n 20`.

## Running it

| To | Do |
|---|---|
| See the endpoint's log | `journalctl -u usb16x16-dante -f` |
| Restart the endpoint | `sudo systemctl restart usb16x16-dante`, then wait for the start check |
| Change the sample rate | From the computer or from Dante Controller. Not from the page. Not under an open DAW session. |
| Change a value in `install.conf` | Edit it, then `sudo install/install.sh install` again |
| Update | `git pull`, then `sudo install/install.sh install` again |
| Remove | `sudo install/install.sh uninstall` (keeps settings, presets and the Dante identity; `--purge` removes those too) |

## What the tuning assumes

The audio path is installed as measured. Two files hold its tuning, with
the development network's values as their contents. The installer never
overwrites them once they exist.

**`/etc/usb16x16/dante/transport.conf`: buffer and queue depths.** Every
depth is in frames, per sample rate. The values give the round trips in the
README on a network of one switch with a far device sending 1 ms packets and
a Mac as the host. They assume:

- one switch hop between the Pi and the devices it exchanges audio with;
- gigabit Ethernet throughout;
- macOS's class driver on the host. `PRIME_DROP` and `CAPTURE_DRAIN` cancel
  a start-up offset specific to it. On another host they are harmless but
  the round trip may differ from the README's and has not been measured.

On a bigger or busier network the depths may be too shallow, which shows as
dropouts, not as a wrong latency. The start wrapper refuses values outside
the ranges it knows (`dante/service/usb16x16-dante-start-transport` lists
them); it does not know what your network needs. Changing a depth is a
change to the audio path: measure before and after.

**`/etc/usb16x16/dante/startcheck.conf`: the start check.** After each
endpoint start it counts received Ethernet frames of 128 bytes and over on
the audio port and compares the rate with a whole number of Dante flows; a
start that is losing packets is restarted, at most four times. It assumes:

- Dante audio is the only steady traffic of that size on the audio port. A
  video stream or a backup running over the same port would make every
  start look wrong;
- the port's driver has per-size receive counters (`ethtool -S`); without
  them the check says so and does nothing;
- a lossy start is short by the amounts seen on the development network
  (about 800 or 115 packets a second). A loss of exactly one whole flow's
  worth would pass;
- the tolerance and idle floor were measured at 48 kHz.

If it restarts the endpoint over and over on a network that sounds fine,
raise `USB16X16_STARTCHECK_TOLERANCE` or set `USB16X16_STARTCHECK_MAX=0`;
`journalctl -u usb16x16-dante-startcheck` shows the rates it read.

## The clock service as an ordinary user

By default the PTP follower, Statime, runs as root with its clock socket in
`/tmp`, as the project was measured. `PTP_SANDBOX=1` in `install.conf`,
then `install` again, runs it as the audio account with only the two
capabilities it needs, sandboxed, with the socket in
`/run/usb16x16-statime` where only that account can reach it.

It is off by default for one reason: it changes the Statime unit and
config, one line of the Inferno config and the socket path in the Dante
unit, and the clock is what the whole audio path hangs on. Nobody has run
it. If you turn it on, check that `journalctl -u usb16x16-statime` shows no
permission errors, that the Dante service starts, and that audio passes;
then measure as for any change to the audio path. `PTP_SANDBOX=0` and
`install` puts everything back.

## Kernel upgrades

The gadget needs two kernel modules (`u_audio`, `usb_f_uac2`) with this
project's four patches. They are built by DKMS, which rebuilds them for any
new kernel: it fetches that kernel release's own copies of the five source
files, applies the patches, and builds.

The patches apply exactly to Linux 6.18.34 through 6.18.49. From 6.18.50
the upstream code changed and `uac2-rate-request` no longer applies. DKMS
then refuses, with the reason in its log, instead of building something
approximate; the stock modules load and the gadget does not start.

That is why the installer holds the kernel at `KERNEL_PIN`. To stay safe:

- leave the hold in place (`apt-mark showhold`);
- before moving to another kernel, check it:
  `kernel/dkms/prepare-sources.sh <release>` exits 0 if the patches apply;
- to pin a different release in the 6.18.34 to 6.18.49 range, set
  `KERNEL_PIN` and run `install` again. Only 6.18.34 has measurements
  behind it.

Without network at build time, put the five files
(`f_uac2.c u_audio.c u_audio.h u_uac2.h uac_common.h` from
`drivers/usb/gadget/function` of that release) in
`/var/cache/usb-aoip-uac2/<X.Y.Z>/`.

## A unit built by the old installer chain

The development unit was built by the incremental installers in
`history/installers/`, not by this one. `sudo install/install.sh adopt`
reads what is installed there and writes the `install.conf` and manifest
that describe it. It writes those two files and nothing else; `status` then
works on that unit. `install` is refused there while the old AES67 service
is enabled. `docs/install/author-pi-mapping.md` has the mapping.

## What gets installed where

| Path | What |
|---|---|
| `/etc/usb-aoip/install.conf` | The site config |
| `/etc/usb-aoip/web-auth`, `web.env`, `tls/` | The page's logins; its TLS and bind arguments; its key and certificate |
| `/var/spool/usb-aoip/inbox` | Requests from the page to the root helper: the page can drop files here and cannot list them |
| `/var/lib/usb16x16-apply` | The root helper's status and receipts |
| `/etc/usb16x16/dante/` | Inferno and Statime configs, `transport.conf`, `startcheck.conf`, `owner.conf` (written by the page) |
| `/etc/usb16x16/dsp/` | DSP presets applied from the page |
| `/usr/local/libexec/usb16x16-dante/` | The owner, Statime, the start wrapper, the start check |
| `/usr/local/lib/usb16x16-dante/alsa-plugins/` | The Inferno ALSA plugin |
| `/usr/local/sbin/setup-usb-aoip`, `usb16x16-stall-tuning` | The gadget script; governor tuning |
| `/usr/local/bin/usb16x16-web`, `usb16x16-apply` | The page's service; the root helper that applies its requests |
| `/etc/systemd/system/usb-16x16.service`, `usb16x16-*` | Units |
| `/lib/modules/<kernel>/updates/dkms/` | The two gadget modules |
| `/var/lib/usb16x16-dante/` | The Dante identity, saved subscriptions, the learned clock offset |
| `/var/lib/usb-aoip/` | The page's files and presets; the build tree; the manifest |
| `/etc/sysctl.d/90-usb16x16-compaction.conf`, `/etc/NetworkManager/conf.d/90-usb16x16-eth0-carrier.conf` | One sysctl; keep the audio port's address through a cable pull |

Unit, binary and directory names keep the project's older `usb16x16`
prefix. The device is `USB-AoIP` (or your `DEVICE_NAME`) wherever a user
sees it.
